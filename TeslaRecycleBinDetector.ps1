# TeslaRecycleBinDetector.ps1
# Windows PowerShell 5.1 / Windows 10 and 11 | CMD only | Last 24 hours
# Read-only scanner. The only file it writes is its own local scan history.
# No admin rights required for the current user's Recycle Bin.

$ErrorActionPreference = 'Stop'
$now = Get-Date
$since = $now.AddHours(-24)
$store = Join-Path $env:LOCALAPPDATA 'TeslaRecycleBinDetector'
$statePath = Join-Path $store 'state.json'
$separator = '  ' + ('-' * 68)

function Line([string]$color = 'DarkCyan') {
    Write-Host $separator -ForegroundColor $color
}
function DateText($value) {
    if ($null -eq $value) { return 'Not available' }
    try { return ([datetime]$value).ToString('dd-MM-yyyy HH:mm:ss') }
    catch { return 'Not available' }
}
function SizeText($value) {
    $n = 0L
    try { $n = [long]$value } catch { }
    if ($n -lt 1024) { return ('{0} B' -f $n) }
    if ($n -lt 1MB) { return ('{0:N1} KB' -f ($n / 1KB)) }
    if ($n -lt 1GB) { return ('{0:N1} MB' -f ($n / 1MB)) }
    return ('{0:N2} GB' -f ($n / 1GB))
}
function ItemKey($item) {
    # Both the $I method and Windows Shell use this stable identity.
    $path = ([string]$item.OriginalPath).ToUpperInvariant()
    try { $stamp = ([datetime]$item.DeletedAt).ToString('yyyyMMddHHmmss') }
    catch { $stamp = 'unknown' }
    return ($path + '|' + $stamp)
}
function New-Entry([string]$name, [string]$original, [datetime]$deleted,
                   [long]$size, [bool]$isFolder, [string]$source) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    if ([string]::IsNullOrWhiteSpace($original)) { $original = $name }
    $extension = 'FILE'
    if ($isFolder) { $extension = 'FOLDER' }
    else {
        $e = [System.IO.Path]::GetExtension($name)
        if (-not [string]::IsNullOrWhiteSpace($e)) { $extension = $e.TrimStart('.').ToUpperInvariant() }
    }
    $drive = ''
    if ($original -match '^[a-zA-Z]:') { $drive = $original.Substring(0,2).ToUpperInvariant() }
    return [pscustomobject]@{
        Name = $name; OriginalPath = $original; DeletedAt = $deleted.ToString('o')
        SizeBytes = $size; Extension = $extension; Drive = $drive; Source = $source
    }
}
function Parse-InfoFile([System.IO.FileInfo]$file) {
    # Windows Recycle Bin $I records: version 1 (offset 24), version 2 (offset 28).
    try {
        $b = [System.IO.File]::ReadAllBytes($file.FullName)
        if ($b.Length -lt 26) { return $null }
        $v = [BitConverter]::ToInt64($b, 0)
        if ($v -ne 1 -and $v -ne 2) { return $null }
        $size = [BitConverter]::ToInt64($b, 8)
        $ft = [BitConverter]::ToInt64($b, 16)
        if ($size -lt 0 -or $ft -le 0) { return $null }
        $when = [datetime]::FromFileTimeUtc($ft).ToLocalTime()
        $offset = 24
        $length = $b.Length - $offset
        if ($v -eq 2) {
            if ($b.Length -lt 30) { return $null }
            $chars = [BitConverter]::ToInt32($b, 24)
            if ($chars -le 0 -or $chars -gt 32767) { return $null }
            $offset = 28
            $length = [Math]::Min($chars * 2, $b.Length - $offset)
        }
        $length -= ($length % 2)
        if ($length -lt 2) { return $null }
        $original = [Text.Encoding]::Unicode.GetString($b, $offset, $length)
        $nullPos = $original.IndexOf([char]0)
        if ($nullPos -ge 0) { $original = $original.Substring(0, $nullPos) }
        if ([string]::IsNullOrWhiteSpace($original)) { return $null }
        $name = [IO.Path]::GetFileName($original.TrimEnd([char]'\', [char]'/'))
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $original }
        $contentPath = Join-Path $file.DirectoryName ('$R' + $file.Name.Substring(2))
        $folder = [IO.Directory]::Exists($contentPath)
        return (New-Entry $name $original $when $size $folder 'metadata')
    } catch { return $null }
}
function Get-ShellItems {
    # Documented Windows Shell property API; avoids direct access problems to $Recycle.Bin.
    $items = [System.Collections.Generic.List[object]]::new()
    $ok = $false
    $failed = 0
    $shell = $null
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.NameSpace(10)
        if ($null -eq $bin) { return [pscustomobject]@{ Ok = $false; Complete = $false; Items = @() } }
        $collection = $bin.Items()
        if ($null -eq $collection) { return [pscustomobject]@{ Ok = $false; Complete = $false; Items = @() } }
        $ok = $true
        for ($i = 0; $i -lt $collection.Count; $i++) {
            try {
                $f = $collection.Item($i)
                if ($null -eq $f) { continue }
                $dateValue = $f.ExtendedProperty('System.Recycle.DateDeleted')
                if ($null -eq $dateValue -or [string]::IsNullOrWhiteSpace([string]$dateValue)) { continue }
                $date = [datetime]$dateValue
                $name = [string]$f.Name
                $originalFolder = [string]$f.ExtendedProperty('System.Recycle.DeletedFrom')
                $original = if ($originalFolder) { [IO.Path]::Combine($originalFolder, $name) } else { $name }
                $n = 0L
                try { $n = [long]$f.Size } catch { }
                $isFolder = $false
                try { $isFolder = [bool]$f.IsFolder } catch { }
                $entry = New-Entry $name $original $date $n $isFolder 'shell'
                if ($null -ne $entry) { $items.Add($entry) }
            } catch { $failed++; continue }
        }
    } catch { $ok = $false }
    finally {
        if ($null -ne $shell) { try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) } catch { } }
    }
    return [pscustomobject]@{ Ok = $ok; Complete = ($ok -and $failed -eq 0); Items = @($items.ToArray()) }
}
function Read-Previous {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
    try {
        $s = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($s.Version -ne 3 -and $s.Version -ne 4) { return $null }
        return $s
    } catch { return $null }
}
function Save-Current($items, $events) {
    $saved = [pscustomobject]@{
        Version = 4; ScannedAt = $now.ToString('o'); Items = @($items); Removals = @($events)
    }
    $tmp = Join-Path $store ('state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = ConvertTo-Json -InputObject $saved -Depth 7
        [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $statePath -Force
    } finally { if ([IO.File]::Exists($tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
}
function Section([string]$title, [int]$count, [string]$color) {
    Write-Host ''
    Write-Host ('  ' + $title) -NoNewline -ForegroundColor $color
    Write-Host ('   [' + $count + ']') -ForegroundColor Gray
    Line 'DarkGray'
}
function Show-Entry($e, [int]$number, [bool]$gone) {
    $type = [string]$e.Extension
    if (-not $type) { $type = 'FILE' }
    $color = 'Cyan'
    if ($type -in @('JAR','EXE','DLL','MSI','BAT','CMD','PS1','ZIP','RAR')) { $color = 'Magenta' }
    Write-Host ('  {0:00}  ' -f $number) -NoNewline -ForegroundColor DarkGray
    Write-Host ('[' + $type + '] ') -NoNewline -ForegroundColor $color
    Write-Host ([string]$e.Name) -ForegroundColor White
    $when = if ($gone) { $e.ObservedAt } else { $e.DeletedAt }
    Write-Host ('      ' + (DateText $when)) -NoNewline -ForegroundColor Gray
    Write-Host ('  /  ' + (SizeText $e.SizeBytes)) -ForegroundColor DarkGray
    Write-Host ('      ' + [string]$e.OriginalPath) -ForegroundColor DarkGray
    if ($gone) { Write-Host '      Removed from bin OR restored' -ForegroundColor DarkYellow }
    Write-Host ''
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Windows 10/11 is required.'
    }
    [void](New-Item -Path $store -ItemType Directory -Force)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $previous = Read-Previous
    $itemsByKey = @{}
    $times = [System.Collections.Generic.List[datetime]]::new()
    $availableDrives = [System.Collections.Generic.List[string]]::new()
    $issues = [System.Collections.Generic.List[string]]::new()
    $fileCount = 0
    $parseCount = 0
    $metadataIncomplete = $false

    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drive.IsReady) { continue }
            if ($drive.DriveType -notin @([IO.DriveType]::Fixed, [IO.DriveType]::Removable)) { continue }
            $driveId = $drive.Name.Substring(0, 2).ToUpperInvariant()
            $availableDrives.Add($driveId)
            $binDir = Join-Path $drive.RootDirectory.FullName ('$Recycle.Bin\' + $sid)
            if (-not [IO.Directory]::Exists($binDir)) { continue }
            try { $times.Add([IO.Directory]::GetLastWriteTime($binDir)) } catch { }
            try {
                $files = @(Get-ChildItem -LiteralPath $binDir -File -Force -ErrorAction Stop |
                    Where-Object { $_.Name.StartsWith('$I', [StringComparison]::OrdinalIgnoreCase) })
                foreach ($f in $files) {
                    $fileCount++
                    $entry = Parse-InfoFile $f
                    if ($null -eq $entry) { $metadataIncomplete = $true; continue }
                    $parseCount++
                    $itemsByKey[(ItemKey $entry)] = $entry
                }
            } catch {
                $metadataIncomplete = $true
                $issues.Add(('Cannot read Recycle Bin on ' + $driveId))
            }
        } catch {
            $metadataIncomplete = $true
            $issues.Add(('Cannot inspect ' + $drive.Name))
        }
    }

    # Always use Windows Shell as a cross-check and fallback (no admin needed).
    $shellResult = Get-ShellItems
    if ($shellResult.Ok) {
        foreach ($entry in @($shellResult.Items)) {
            $key = ItemKey $entry
            if (-not $itemsByKey.ContainsKey($key)) { $itemsByKey[$key] = $entry }
        }
    }
    $allCurrent = @($itemsByKey.Values)
    $recent = @($allCurrent | Where-Object {
        try { ([datetime]$_.DeletedAt -ge $since -and [datetime]$_.DeletedAt -le $now.AddMinutes(5)) }
        catch { $false }
    } | Sort-Object { [datetime]$_.DeletedAt } -Descending)

    $removalHistory = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $previous) {
        foreach ($ev in @($previous.Removals)) {
            if ($null -eq $ev) { continue }
            try { if ([datetime]$ev.ObservedAt -ge $since) { $removalHistory.Add($ev) } }
            catch { }
        }
    }

    # Don't manufacture a removal when a drive was disconnected or a scan was incomplete.
    $comparisonSafe = (-not $metadataIncomplete -or $shellResult.Complete)
    $carry = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $previous) {
        foreach ($old in @($previous.Items)) {
            if ($null -eq $old) { continue }
            $key = ItemKey $old
            if ($itemsByKey.ContainsKey($key)) { continue }
            $oldDrive = [string]$old.Drive
            $driveReady = ($oldDrive -eq '' -or $availableDrives.Contains($oldDrive))
            if (-not $comparisonSafe -or -not $driveReady) {
                $carry.Add($old)
                continue
            }
            $removalHistory.Add([pscustomobject]@{
                Name = $old.Name; OriginalPath = $old.OriginalPath
                DeletedAt = $old.DeletedAt; ObservedAt = $now.ToString('o')
                SizeBytes = $old.SizeBytes; Extension = $old.Extension
            })
        }
    }
    # Don't silently replace a good baseline with a partial scan.
    if ($comparisonSafe) { Save-Current (@($allCurrent) + @($carry.ToArray())) @($removalHistory.ToArray()) }
    $gone = @($removalHistory.ToArray() | Sort-Object { [datetime]$_.ObservedAt } -Descending)

    $modified = $null
    foreach ($t in @($times.ToArray())) { if ($null -eq $modified -or $t -gt $modified) { $modified = $t } }
    foreach ($e in @($allCurrent)) {
        $t = [datetime]$e.DeletedAt
        if ($null -eq $modified -or $t -gt $modified) { $modified = $t }
    }
    foreach ($e in $gone) {
        $t = [datetime]$e.ObservedAt
        if ($null -eq $modified -or $t -gt $modified) { $modified = $t }
    }

    try { $Host.UI.RawUI.WindowTitle = 'TeslaRecycleBinDetector' } catch { }
    Write-Host ''
    Line 'Cyan'
    Write-Host '   TESLA' -NoNewline -ForegroundColor Cyan
    Write-Host '  //  RECYCLE BIN DETECTOR' -ForegroundColor White
    Line 'Cyan'
    Write-Host ''
    Write-Host '  RECYCLE BIN MODIFIED AT   ' -NoNewline -ForegroundColor Gray
    if ($null -ne $modified) {
        $c = if ($modified -ge $since) { 'Green' } else { 'DarkYellow' }
        Write-Host (DateText $modified) -ForegroundColor $c
    } else { Write-Host 'Unknown' -ForegroundColor DarkYellow }
    Write-Host '  SCAN WINDOW               ' -NoNewline -ForegroundColor Gray
    Write-Host 'LAST 24 HOURS' -ForegroundColor Cyan
    Write-Host '  RESULTS                   ' -NoNewline -ForegroundColor Gray
    Write-Host ('IN BIN ' + $recent.Count) -NoNewline -ForegroundColor Green
    Write-Host '  /  ' -NoNewline -ForegroundColor DarkGray
    Write-Host ('LEFT BIN ' + $gone.Count) -ForegroundColor Yellow

    Section '01  SENT TO RECYCLE BIN' $recent.Count 'Green'
    if ($recent.Count -gt 0) {
        for ($i = 0; $i -lt $recent.Count; $i++) { Show-Entry $recent[$i] ($i+1) $false }
    } else { Write-Host '  No files still in the bin from the last 24 hours.' -ForegroundColor DarkGray }

    Section '02  LEFT RECYCLE BIN' $gone.Count 'Yellow'
    if ($gone.Count -gt 0) {
        for ($i = 0; $i -lt $gone.Count; $i++) { Show-Entry $gone[$i] ($i+1) $true }
    } else { Write-Host '  No changes recorded since the previous scan.' -ForegroundColor DarkGray }

    if ($recent.Count -eq 0 -and $gone.Count -eq 0 -and $null -ne $modified -and $modified -ge $since) {
        Write-Host '  ! Recent bin-folder activity, but no file names remain available.' -ForegroundColor DarkYellow
    }
    if ($null -eq $previous) { Write-Host '  * Tracking of files leaving the bin begins with this scan.' -ForegroundColor DarkGray }
    if ($metadataIncomplete -and -not $shellResult.Ok) {
        Write-Host '  ! Some data could not be read. Try CMD as administrator.' -ForegroundColor Yellow
    }
    if ($parseCount -eq 0 -and -not $shellResult.Ok -and $fileCount -eq 0 -and $times.Count -eq 0) {
        Write-Host '  ! Recycle Bin access unavailable. No results could be confirmed.' -ForegroundColor Yellow
    }

    Write-Host ''
    Line 'DarkCyan'
    Write-Host '   DISCORD  ' -NoNewline -ForegroundColor DarkGray
    Write-Host 'teamwsf' -ForegroundColor Magenta
    Line 'DarkCyan'
    Write-Host ''
} catch {
    Write-Host ''
    Write-Host '  TESLA / ERROR' -ForegroundColor Red
    Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Yellow
    Write-Host '  DISCORD: teamwsf' -ForegroundColor Magenta
    Write-Host ''
}
