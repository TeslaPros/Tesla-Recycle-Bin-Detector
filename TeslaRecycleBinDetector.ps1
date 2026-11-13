# TeslaRecycleBinDetector.ps1
# Windows 10 / 11 | PowerShell 5.1+ | CMD console only
# This script never deletes, restores, or uploads files.

$ErrorActionPreference = 'Stop'
$WindowHours = 24
$Now = Get-Date
$Cutoff = $Now.AddHours(-$WindowHours)
$StorageDirectory = Join-Path $env:LOCALAPPDATA 'TeslaRecycleBinDetector'
$StatePath = Join-Path $StorageDirectory 'state.json'

# Compact, colored CMD layout. ASCII-only characters keep it readable in every console.
$Line = '  ' + ('-' * 64)
function Write-Rule {
    param([ConsoleColor]$Color = [ConsoleColor]::DarkCyan)
    Write-Host $Line -ForegroundColor $Color
}
function Write-Section {
    param([string]$Number, [string]$Label, [int]$Count, [ConsoleColor]$Color)
    Write-Host ''
    Write-Host ('  [' + $Number + '] ') -NoNewline -ForegroundColor $Color
    Write-Host $Label -NoNewline -ForegroundColor White
    Write-Host ('  (' + $Count + ')') -ForegroundColor $Color
    Write-Rule -Color DarkGray
}
function Format-When {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return 'Not available' }
    try { return ([datetime]$Value).ToString('dd-MM-yyyy HH:mm:ss') } catch { return 'Not available' }
}
function Format-Size {
    param([long]$Bytes)
    if ($Bytes -lt 1024) { return ('{0} B' -f $Bytes) }
    if ($Bytes -lt 1048576) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1073741824) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}
function Read-DeletedItem {
    param([System.IO.FileInfo]$MetadataFile)
    try {
        $data = [System.IO.File]::ReadAllBytes($MetadataFile.FullName)
        if ($data.Length -lt 26) { return $null }

        # Microsoft Recycle Bin $I record: v1 and v2 use the same size/time fields.
        $version = [BitConverter]::ToInt64($data, 0)
        if ($version -ne 1 -and $version -ne 2) { return $null }
        $bytes = [BitConverter]::ToInt64($data, 8)
        $fileTime = [BitConverter]::ToInt64($data, 16)
        if ($fileTime -le 0 -or $bytes -lt 0) { return $null }
        $deleted = [datetime]::FromFileTimeUtc($fileTime).ToLocalTime()

        if ($version -eq 1) {
            $pathOffset = 24
            $pathByteCount = $data.Length - 24
        } else {
            if ($data.Length -lt 30) { return $null }
            $pathChars = [BitConverter]::ToInt32($data, 24)
            if ($pathChars -le 0 -or $pathChars -gt 32767) { return $null }
            $pathOffset = 28
            $pathByteCount = [Math]::Min($pathChars * 2, $data.Length - 28)
        }
        $pathByteCount = $pathByteCount - ($pathByteCount % 2)
        if ($pathByteCount -lt 2) { return $null }

        $originalPath = ([Text.Encoding]::Unicode.GetString($data, $pathOffset, $pathByteCount) -split "`0", 2)[0]
        if ([string]::IsNullOrWhiteSpace($originalPath)) { return $null }
        $cleanPath = $originalPath.TrimEnd([char]'\', [char]'/')
        $name = [System.IO.Path]::GetFileName($cleanPath)
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $originalPath }

        $dataName = '$R' + $MetadataFile.Name.Substring(2)
        $dataPath = Join-Path $MetadataFile.DirectoryName $dataName
        $isDirectory = [System.IO.Directory]::Exists($dataPath)
        $extension = if ($isDirectory) { 'FOLDER' } else {
            $rawExtension = [System.IO.Path]::GetExtension($name)
            if ([string]::IsNullOrWhiteSpace($rawExtension)) { 'FILE' } else { $rawExtension.TrimStart('.').ToUpperInvariant() }
        }

        return [pscustomobject]@{
            Id           = ($MetadataFile.FullName.ToLowerInvariant() + '|' + $fileTime.ToString())
            Name         = $name
            OriginalPath = $originalPath
            DeletedAt    = $deleted.ToString('o')
            SizeBytes    = $bytes
            Extension    = $extension
            Drive        = $MetadataFile.FullName.Substring(0, 2).ToUpperInvariant()
        }
    } catch {
        return $null
    }
}
function Read-State {
    if (-not [System.IO.File]::Exists($StatePath)) { return $null }
    try {
        $saved = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($saved.Version -ne 3) { return $null }
        return $saved
    } catch { return $null }
}
function Save-State {
    param([object[]]$Items, [object[]]$Removals)
    $state = [pscustomobject]@{
        Version = 3
        ScannedAt = (Get-Date).ToString('o')
        Items = @($Items)
        Removals = @($Removals)
    }
    $temp = Join-Path $StorageDirectory ('state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $state | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($temp, $json, ([System.Text.UTF8Encoding]::new($false)))
        Move-Item -LiteralPath $temp -Destination $StatePath -Force
    } finally {
        if ([System.IO.File]::Exists($temp)) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}
function Write-Item {
    param($Item, [int]$Index, [bool]$IsRemoval)
    $type = [string]$Item.Extension
    if ([string]::IsNullOrWhiteSpace($type)) { $type = 'FILE' }
    $when = if ($IsRemoval) { $Item.ObservedAt } else { $Item.DeletedAt }
    $badgeColor = if ($type -in @('JAR', 'EXE', 'DLL', 'MSI', 'BAT', 'CMD', 'PS1')) { 'Magenta' } else { 'Cyan' }

    Write-Host ('  {0:00}  ' -f $Index) -NoNewline -ForegroundColor DarkGray
    Write-Host ('[{0}] ' -f $type) -NoNewline -ForegroundColor $badgeColor
    Write-Host ([string]$Item.Name) -ForegroundColor White
    Write-Host ('      ' + (Format-When $when)) -NoNewline -ForegroundColor Gray
    Write-Host ('  |  ' + (Format-Size ([long]$Item.SizeBytes))) -ForegroundColor DarkGray
    Write-Host ('      ' + [string]$Item.OriginalPath) -ForegroundColor DarkGray
    if ($IsRemoval) {
        Write-Host '      Removed or restored (not distinguishable)' -ForegroundColor DarkYellow
    }
    Write-Host ''
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This script only works on Windows 10/11.'
    }
    $null = New-Item -Path $StorageDirectory -ItemType Directory -Force
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $previous = Read-State

    $entries = [System.Collections.Generic.List[object]]::new()
    $observedDrives = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $folderTimes = [System.Collections.Generic.List[datetime]]::new()

    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drive.IsReady) { continue }
            if ($drive.DriveType -ne [System.IO.DriveType]::Fixed -and
                $drive.DriveType -ne [System.IO.DriveType]::Removable) { continue }
            $driveLetter = $drive.Name.Substring(0, 2).ToUpperInvariant()
            $recycleFolder = Join-Path $drive.RootDirectory.FullName ('$Recycle.Bin\' + $sid)
            if (-not [System.IO.Directory]::Exists($recycleFolder)) {
                # A drive with no user Recycle Bin is treated as having no current records.
                $observedDrives.Add($driveLetter)
                continue
            }
            $metadata = @(Get-ChildItem -LiteralPath $recycleFolder -File -Force -ErrorAction Stop |
                Where-Object { $_.Name.StartsWith('$I', [StringComparison]::OrdinalIgnoreCase) })
            foreach ($record in $metadata) {
                $item = Read-DeletedItem -MetadataFile $record
                if ($null -ne $item) { $entries.Add($item) }
            }
            $observedDrives.Add($driveLetter)
            try { $folderTimes.Add([System.IO.Directory]::GetLastWriteTime($recycleFolder)) } catch { }
        } catch {
            $warnings.Add(('Could not fully read {0}: {1}' -f $drive.Name, $_.Exception.Message))
        }
    }

    $present = @($entries.ToArray())
    $presentIds = @{}
    foreach ($entry in $present) { $presentIds[[string]$entry.Id] = $true }

    $pastRemovals = [System.Collections.Generic.List[object]]::new()
    $pastItems = @()
    if ($null -ne $previous) {
        $pastItems = @($previous.Items | Where-Object { $null -ne $_ -and $null -ne $_.Id })
        foreach ($pastRemoval in @($previous.Removals)) {
            if ($null -eq $pastRemoval) { continue }
            try {
                if ([datetime]$pastRemoval.ObservedAt -ge $Cutoff) { $pastRemovals.Add($pastRemoval) }
            } catch { }
        }
    }

    $carryForward = [System.Collections.Generic.List[object]]::new()
    foreach ($oldItem in $pastItems) {
        if ($presentIds.ContainsKey([string]$oldItem.Id)) { continue }
        if ([string]$oldItem.Drive -notin @($observedDrives.ToArray())) {
            # Inaccessible/removed drive: don't invent a deletion event.
            $carryForward.Add($oldItem)
            continue
        }
        $pastRemovals.Add([pscustomobject]@{
            Name         = $oldItem.Name
            OriginalPath = $oldItem.OriginalPath
            DeletedAt    = $oldItem.DeletedAt
            ObservedAt   = $Now.ToString('o')
            SizeBytes    = $oldItem.SizeBytes
            Extension    = $oldItem.Extension
        })
    }

    $allItemsToSave = @($present) + @($carryForward.ToArray())
    Save-State -Items $allItemsToSave -Removals @($pastRemovals.ToArray())

    $recentInBin = @($present | Where-Object {
        try { ([datetime]$_.DeletedAt -ge $Cutoff -and [datetime]$_.DeletedAt -le $Now.AddMinutes(5)) } catch { $false }
    } | Sort-Object -Property DeletedAt -Descending)
    $recentGone = @($pastRemovals.ToArray() | Sort-Object -Property ObservedAt -Descending)

    $lastActivity = $null
    $lastActivitySource = 'No timestamp available'
    foreach ($folderTime in @($folderTimes.ToArray())) {
        if ($null -eq $lastActivity -or $folderTime -gt $lastActivity) {
            $lastActivity = $folderTime
            $lastActivitySource = 'Recycle Bin folder timestamp (approximate)'
        }
    }
    foreach ($item in $present) {
        $timestamp = [datetime]$item.DeletedAt
        if ($null -eq $lastActivity -or $timestamp -gt $lastActivity) {
            $lastActivity = $timestamp
            $lastActivitySource = 'Item moved to Recycle Bin'
        }
    }
    foreach ($event in @($pastRemovals.ToArray())) {
        $timestamp = [datetime]$event.ObservedAt
        if ($null -eq $lastActivity -or $timestamp -gt $lastActivity) {
            $lastActivity = $timestamp
            $lastActivitySource = 'Item disappeared (observed by scanner)'
        }
    }

    try { $Host.UI.RawUI.WindowTitle = 'TeslaRecycleBinDetector | 24h' } catch { }
    Write-Host ''
    Write-Rule -Color Cyan
    Write-Host '   TESLA' -NoNewline -ForegroundColor Cyan
    Write-Host '  /  RECYCLE BIN DETECTOR' -ForegroundColor White
    Write-Rule -Color Cyan
    Write-Host ''
    Write-Host '  RECYCLE BIN MODIFIED AT  ' -NoNewline -ForegroundColor DarkGray
    if ($null -ne $lastActivity) {
        $activityColor = if ($lastActivity -ge $Cutoff) { 'Green' } else { 'Yellow' }
        Write-Host (Format-When $lastActivity) -ForegroundColor $activityColor
    } else {
        Write-Host 'Unknown' -ForegroundColor Yellow
    }
    Write-Host '  TIME WINDOW              ' -NoNewline -ForegroundColor DarkGray
    Write-Host 'LAST 24 HOURS' -ForegroundColor Cyan
    Write-Host '  FILES IN BIN             ' -NoNewline -ForegroundColor DarkGray
    Write-Host ([string]$recentInBin.Count) -NoNewline -ForegroundColor Green
    Write-Host '    |    LEFT BIN  ' -NoNewline -ForegroundColor DarkGray
    Write-Host ([string]$recentGone.Count) -ForegroundColor Yellow

    Write-Section -Number '01' -Label 'SENT TO RECYCLE BIN' -Count $recentInBin.Count -Color Green
    if ($recentInBin.Count -eq 0) {
        Write-Host '  No files found in the last 24 hours.' -ForegroundColor DarkGray
    } else {
        for ($i = 0; $i -lt $recentInBin.Count; $i++) {
            Write-Item -Item $recentInBin[$i] -Index ($i + 1) -IsRemoval $false
        }
    }

    Write-Section -Number '02' -Label 'LEFT RECYCLE BIN' -Count $recentGone.Count -Color Yellow
    if ($recentGone.Count -eq 0) {
        Write-Host '  No previously tracked files disappeared.' -ForegroundColor DarkGray
    } else {
        for ($i = 0; $i -lt $recentGone.Count; $i++) {
            Write-Item -Item $recentGone[$i] -Index ($i + 1) -IsRemoval $true
        }
    }

    if ($null -eq $previous) {
        Write-Host ''
        Write-Host '  * Removal tracking starts with this scan.' -ForegroundColor DarkYellow
    }
    if ($warnings.Count -gt 0) {
        Write-Host ''
        foreach ($warning in @($warnings.ToArray())) {
            Write-Host ('  ! ' + $warning) -ForegroundColor Yellow
        }
    }

    Write-Host ''
    Write-Rule -Color DarkCyan
    Write-Host '  DISCORD  ' -NoNewline -ForegroundColor DarkGray
    Write-Host 'teamwsf' -ForegroundColor Magenta
    Write-Rule -Color DarkCyan
    Write-Host ''

} catch {
    Write-Host ''
    Write-Host '  TESLA RECYCLE BIN DETECTOR - ERROR' -ForegroundColor Red
    Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Yellow
    Write-Host '  Check your Windows PowerShell version and permissions.' -ForegroundColor DarkGray
    Write-Host ''
}
