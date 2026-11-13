#requires -Version 5.1
<#
.SYNOPSIS
  Tesla Recycle Bin Detector - local Windows Recycle Bin scanner and monitor.
.DESCRIPTION
  Reads $I metadata records for the current user on local volumes.
  Shows items sent to the Recycle Bin in the last N hours and records
  additions/removals between scans. It never deletes or restores files.
  Items that have already been permanently deleted before the first scan
  cannot be reconstructed by this script.
.EXAMPLE
  .\Tesla-Recycle-Bin-Detector.ps1
.EXAMPLE
  .\Tesla-Recycle-Bin-Detector.ps1 -Hours 168
.EXAMPLE
  .\Tesla-Recycle-Bin-Detector.ps1 -Watch -Interval 30
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 8760)][int]$Hours = 24,
    [switch]$Watch,
    [ValidateRange(5, 3600)][int]$Interval = 60,
    [switch]$ExportCsv,
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Error 'Deze tool werkt alleen op Windows.'
    return
}

$storeDir  = Join-Path $env:LOCALAPPDATA 'TeslaRecycleBinDetector'
$stateFile = Join-Path $storeDir 'state.json'
$eventFile = Join-Path $storeDir 'events.jsonl'
$null = New-Item -ItemType Directory -Path $storeDir -Force
$mySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

function Read-RecycleMetadata {
    param([System.IO.FileInfo]$InfoFile)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($InfoFile.FullName)
        if ($bytes.Length -lt 26) { return $null }
        $version = [BitConverter]::ToInt64($bytes, 0)
        if ($version -ne 1 -and $version -ne 2) { return $null }
        $size = [BitConverter]::ToInt64($bytes, 8)
        $filetime = [BitConverter]::ToInt64($bytes, 16)
        if ($filetime -le 0) { return $null }
        $deletedAt = [DateTime]::FromFileTimeUtc($filetime).ToLocalTime()

        if ($version -eq 1) {
            $start = 24
            $byteCount = $bytes.Length - $start
        } else {
            if ($bytes.Length -lt 30) { return $null }
            $characters = [BitConverter]::ToInt32($bytes, 24)
            if ($characters -le 0 -or $characters -gt 32767) { return $null }
            $start = 28
            $byteCount = [Math]::Min($characters * 2, $bytes.Length - $start)
        }
        $byteCount = $byteCount - ($byteCount % 2)
        if ($byteCount -lt 2) { return $null }
        $original = [Text.Encoding]::Unicode.GetString($bytes, $start, $byteCount).Split([char]0)[0]
        if ([string]::IsNullOrWhiteSpace($original)) { return $null }

        $payloadName = '$R' + $InfoFile.Name.Substring(2)
        $payloadPath = Join-Path $InfoFile.DirectoryName $payloadName
        $isFolder = [System.IO.Directory]::Exists($payloadPath)
        $name = $original.TrimEnd([char]'\', [char]'/')
        $name = [System.IO.Path]::GetFileName($name)
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $original }
        $id = $InfoFile.FullName.ToLowerInvariant() + '|' + $deletedAt.ToString('o')

        return [pscustomobject]@{
            Id           = $id
            Name         = $name
            OriginalPath = $original
            DeletedAt    = $deletedAt.ToString('o')
            SizeBytes    = $size
            Type         = $(if ($isFolder) { 'Map' } else { 'Bestand' })
            Drive        = $InfoFile.FullName.Substring(0, 2)
            MetadataPath = $InfoFile.FullName
            PayloadFound = ([System.IO.File]::Exists($payloadPath) -or $isFolder)
        }
    } catch {
        return $null
    }
}

function Get-CurrentRecycleItems {
    $items = New-Object 'System.Collections.Generic.List[object]'
    $issues = New-Object 'System.Collections.Generic.List[string]'
    $readyDrives = New-Object 'System.Collections.Generic.List[string]'
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        if ($drive.DriveType -notin @([System.IO.DriveType]::Fixed, [System.IO.DriveType]::Removable)) { continue }
        $readyDrives.Add($drive.Name.Substring(0, 2).ToUpperInvariant())
        $binRoot = Join-Path $drive.RootDirectory.FullName '$Recycle.Bin'
        $userBin = Join-Path $binRoot $mySid
        if (-not [System.IO.Directory]::Exists($userBin)) { continue }
        try {
            $allInfo = Get-ChildItem -LiteralPath $userBin -File -Force -ErrorAction Stop |
                Where-Object { $_.Name.StartsWith('$I', [StringComparison]::OrdinalIgnoreCase) }
            foreach ($file in $allInfo) {
                $entry = Read-RecycleMetadata -InfoFile $file
                if ($null -ne $entry) { $items.Add($entry) }
            }
        } catch {
            $issues.Add($userBin + ': ' + $_.Exception.Message)
        }
    }
    return [pscustomobject]@{ Items = @($items.ToArray()); Issues = @($issues.ToArray()); ReadyDrives = @($readyDrives.ToArray()) }
}

function Load-State {
    if (-not [System.IO.File]::Exists($stateFile)) { return $null }
    try {
        $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.Version -ne 1) { return $null }
        return $state
    } catch {
        Write-Warning 'Vorige status is onleesbaar. Er wordt een nieuwe nulmeting gemaakt.'
        return $null
    }
}

function Save-State {
    param([object[]]$Items)
    $state = @{ Version = 1; CapturedAt = (Get-Date).ToString('o'); Items = @($Items) }
    $json = $state | ConvertTo-Json -Depth 6
    $tempFile = Join-Path $storeDir ('state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($tempFile, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempFile -Destination $stateFile -Force
    } finally {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
    }
}

function Add-Event {
    param([string]$Action, [object]$Item, [datetime]$ObservedAt)
    $ev = [pscustomobject]@{
        Action       = $Action
        ObservedAt   = $ObservedAt.ToString('o')
        Name         = $Item.Name
        OriginalPath = $Item.OriginalPath
        DeletedAt    = $Item.DeletedAt
        SizeBytes    = $Item.SizeBytes
        Type         = $Item.Type
        Drive        = $Item.Drive
        OriginalExistsAtCheck = $(if ($Action -eq 'LeftRecycleBin') {
            [System.IO.File]::Exists($Item.OriginalPath) -or [System.IO.Directory]::Exists($Item.OriginalPath)
        } else { $null })
    }
    $line = $ev | ConvertTo-Json -Depth 5 -Compress
    Add-Content -LiteralPath $eventFile -Value $line -Encoding UTF8
    return $ev
}

function Load-Events {
    $events = New-Object 'System.Collections.Generic.List[object]'
    if (Test-Path -LiteralPath $eventFile) {
        foreach ($line in Get-Content -LiteralPath $eventFile -Encoding UTF8) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $events.Add(($line | ConvertFrom-Json)) } catch { continue }
        }
    }
    return @($events.ToArray())
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -lt 1024) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

function Write-FileEntry {
    param([object]$Item, [int]$Number, [string]$Mode)
    Write-Host (('  [{0:00}] {1}' -f $Number, $Item.Name)) -ForegroundColor White
    Write-Host ('       Origineel : ' + $Item.OriginalPath) -ForegroundColor Gray
    if ($Mode -eq 'InBin') {
        Write-Host ('       Verwijderd: ' + ([datetime]$Item.DeletedAt).ToString('dd-MM-yyyy HH:mm:ss')) -ForegroundColor DarkGray
    } else {
        Write-Host ('       Gezien op : ' + ([datetime]$Item.ObservedAt).ToString('dd-MM-yyyy HH:mm:ss')) -ForegroundColor DarkGray
        $possibleRestore = $Item.OriginalExistsAtCheck -eq $true
        if ($possibleRestore) {
            Write-Host '       Status    : Weg uit Prullenbak; origineel pad bestaat (herstel niet bewezen)' -ForegroundColor Yellow
        } else {
            Write-Host '       Status    : Weg uit Prullenbak; herstel of definitieve verwijdering onbekend' -ForegroundColor Yellow
        }
    }
    Write-Host ('       Type      : ' + $Item.Type + '  |  Grootte: ' + (Format-Size -Bytes ([long]$Item.SizeBytes))) -ForegroundColor DarkGray
    Write-Host ''
}

function Run-Scan {
    $now = Get-Date
    $cutoff = $now.AddHours(-$Hours)
    $result = Get-CurrentRecycleItems
    $items = @($result.Items)
    $previous = Load-State
    $newEvents = New-Object 'System.Collections.Generic.List[object]'
    $preservedOffline = New-Object 'System.Collections.Generic.List[object]'
    $canCompare = ($null -ne $previous -and @($result.Issues).Count -eq 0)
    if ($canCompare) {
        $old = @{}
        foreach ($entry in @($previous.Items)) {
            if ($null -ne $entry -and $null -ne $entry.Id) { $old[[string]$entry.Id] = $entry }
        }
        $current = @{}
        foreach ($entry in $items) { $current[[string]$entry.Id] = $entry }
        foreach ($entry in $items) {
            if (-not $old.ContainsKey([string]$entry.Id)) {
                $newEvents.Add((Add-Event -Action 'EnteredRecycleBin' -Item $entry -ObservedAt $now))
            }
        }
        foreach ($key in $old.Keys) {
            if (-not $current.ContainsKey($key)) {
                $priorEntry = $old[$key]
                if ([string]$priorEntry.Drive -notin @($result.ReadyDrives)) {
                    # Keep the last snapshot for an unplugged or unavailable drive.
                    $preservedOffline.Add($priorEntry)
                    continue
                }
                $newEvents.Add((Add-Event -Action 'LeftRecycleBin' -Item $priorEntry -ObservedAt $now))
            }
        }
    }
    if (@($result.Issues).Count -eq 0) { Save-State -Items @($items + $preservedOffline.ToArray()) }

    $recentCurrent = @($items | Where-Object { [datetime]$_.DeletedAt -ge $cutoff -and [datetime]$_.DeletedAt -le $now.AddMinutes(5) } |
        Sort-Object { [datetime]$_.DeletedAt } -Descending)
    $recentEvents = @(Load-Events | Where-Object { [datetime]$_.ObservedAt -ge $cutoff } |
        Sort-Object { [datetime]$_.ObservedAt } -Descending)
    $recentLeft = @($recentEvents | Where-Object { $_.Action -eq 'LeftRecycleBin' })
    $recentEntered = @($recentEvents | Where-Object { $_.Action -eq 'EnteredRecycleBin' })

    if (-not $Quiet) {
        Write-Host ''
        Write-Host '  +----------------------------------------------------------+' -ForegroundColor DarkCyan
        Write-Host '  |           TESLA  /  RECYCLE BIN DETECTOR                  |' -ForegroundColor Cyan
        Write-Host '  |             Windows recycle bin activity                 |' -ForegroundColor DarkCyan
        Write-Host '  +----------------------------------------------------------+' -ForegroundColor DarkCyan
        Write-Host ('  Controleperiode : afgelopen {0} uur  |  {1}' -f $Hours, $now.ToString('dd-MM-yyyy HH:mm:ss')) -ForegroundColor Gray
        Write-Host ('  Huidig in prullenbak: {0}  |  Recent: {1}  |  Recent verdwenen: {2}' -f $items.Count, $recentCurrent.Count, $recentLeft.Count) -ForegroundColor White
        Write-Host ''
        Write-Host '  [1] NAAR PRULLENBAK (zit er nu nog in)' -ForegroundColor Green
        if ($recentCurrent.Count -eq 0) {
            Write-Host '      Geen bestanden gevonden in de gekozen periode.' -ForegroundColor DarkGray
        } else {
            for ($i=0; $i -lt $recentCurrent.Count; $i++) { Write-FileEntry -Item $recentCurrent[$i] -Number ($i+1) -Mode 'InBin' }
        }
        Write-Host ''
        Write-Host '  [2] UIT PRULLENBAK VERDWENEN (sinds eerdere scan)' -ForegroundColor Yellow
        if ($recentLeft.Count -eq 0) {
            Write-Host '      Geen geregistreerde verdwijningen in deze periode.' -ForegroundColor DarkGray
        } else {
            for ($i=0; $i -lt $recentLeft.Count; $i++) { Write-FileEntry -Item $recentLeft[$i] -Number ($i+1) -Mode 'LeftBin' }
        }
        Write-Host ''
        Write-Host ('  Geregistreerde toevoegingen in periode: {0}' -f $recentEntered.Count) -ForegroundColor DarkCyan
        if ($null -eq $previous) {
            Write-Host '  Eerste scan: nulmeting aangemaakt. Verdwijningen zijn pas vanaf nu te volgen.' -ForegroundColor Yellow
        }
        if (@($result.Issues).Count -gt 0) {
            Write-Host '  WAARSCHUWING: Een of meer schijven konden niet volledig worden gescand.' -ForegroundColor Red
            foreach ($issue in $result.Issues) { Write-Host ('   ' + $issue) -ForegroundColor Red }
            Write-Host '  Nulmeting is niet aangepast om foutieve verdwijningen te vermijden.' -ForegroundColor Red
        }
        Write-Host ('  Logmap: ' + $storeDir) -ForegroundColor DarkGray
        Write-Host '  LET OP: Verdwenen = hersteld OF definitief verwijderd; niet te onderscheiden.' -ForegroundColor DarkGray
        Write-Host ''
    }

    if ($ExportCsv) {
        $report = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $recentCurrent) {
            $report.Add([pscustomobject]@{
                Status='In prullenbak'; Naam=$item.Name; Origineel=$item.OriginalPath
                Datum=$item.DeletedAt; GrootteBytes=$item.SizeBytes; Type=$item.Type
            })
        }
        foreach ($item in $recentLeft) {
            $report.Add([pscustomobject]@{
                Status='Verdwenen uit prullenbak (reden onbekend)'; Naam=$item.Name
                Origineel=$item.OriginalPath; Datum=$item.ObservedAt
                GrootteBytes=$item.SizeBytes; Type=$item.Type
            })
        }
        $csvPath = Join-Path $storeDir ('report-' + $now.ToString('yyyyMMdd-HHmmss') + '.csv')
        if ($report.Count -gt 0) {
            $report.ToArray() | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'
        } else {
            'Status;Naam;Origineel;Datum;GrootteBytes;Type' | Set-Content -LiteralPath $csvPath -Encoding UTF8
        }
        if (-not $Quiet) { Write-Host ('  CSV opgeslagen: ' + $csvPath) -ForegroundColor Cyan }
    }
}

if ($Watch) {
    if (-not $Quiet) {
        Write-Host ('Monitoring actief: elke {0} seconden. Stop met Ctrl+C.' -f $Interval) -ForegroundColor Cyan
    }
    while ($true) {
        if (-not $Quiet) { Clear-Host }
        Run-Scan
        if (-not $Quiet) { Write-Host ('  Nieuwe scan over {0} seconden. Ctrl+C om te stoppen.' -f $Interval) -ForegroundColor Cyan }
        Start-Sleep -Seconds $Interval
    }
} else {
    Run-Scan
}
