# Tesla Recycle Bin Detector v2.0
# Read-only scanner for the current Windows user's Recycle Bin.
# Designed to work both as a .ps1 file and via: iex (irm 'https://.../script.ps1')
# No top-level param/CmdletBinding or UTF-8 BOM (avoids Invoke-Expression parser issues).

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Write-Host 'Tesla Recycle Bin Detector is alleen voor Windows.' -ForegroundColor Red
    return
}
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host 'Tesla Recycle Bin Detector is alleen voor Windows.' -ForegroundColor Red
    return
}

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
    Write-Host ('De Windows GUI kon niet starten: ' + $_.Exception.Message) -ForegroundColor Red
    return
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    [System.Windows.Forms.MessageBox]::Show(
        'Start dit script met Windows PowerShell in STA-modus (powershell.exe -STA -File script.ps1).',
        'Tesla Recycle Bin Detector',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
    return
}

[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- Local read-only scan and change history --------------------------------
$script:DataDir = Join-Path $env:LOCALAPPDATA 'TeslaRecycleBinDetector'
$script:SnapshotPath = Join-Path $script:DataDir 'snapshot.json'
$script:EventsPath = Join-Path $script:DataDir 'events.jsonl'
$script:MySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:Items = @()
$script:Events = @()
$script:Displayed = @()
$script:Page = 'current'
$script:HasBaseline = $false
$script:LastScanAt = $null
$script:Warnings = @()
$script:Busy = $false
$script:FirstRunNote = $false
$null = New-Item -ItemType Directory -Path $script:DataDir -Force

function Get-RecycleEntry {
    param([System.IO.FileInfo]$Info)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Info.FullName)
        if ($bytes.Length -lt 26) { return $null }
        $version = [BitConverter]::ToInt64($bytes, 0)
        if ($version -ne 1 -and $version -ne 2) { return $null }
        $size = [BitConverter]::ToInt64($bytes, 8)
        $fileTime = [BitConverter]::ToInt64($bytes, 16)
        if ($fileTime -le 0 -or $size -lt 0) { return $null }
        $deleted = [DateTime]::FromFileTimeUtc($fileTime).ToLocalTime()

        if ($version -eq 1) {
            $offset = 24
            $count = $bytes.Length - $offset
        } else {
            if ($bytes.Length -lt 30) { return $null }
            $chars = [BitConverter]::ToInt32($bytes, 24)
            if ($chars -le 0 -or $chars -gt 32767) { return $null }
            $offset = 28
            $count = [Math]::Min(($chars * 2), ($bytes.Length - $offset))
        }
        $count -= ($count % 2)
        if ($count -lt 2) { return $null }
        $original = [Text.Encoding]::Unicode.GetString($bytes, $offset, $count).Split([char]0)[0]
        if ([string]::IsNullOrWhiteSpace($original)) { return $null }

        $dataPath = Join-Path $Info.DirectoryName ('$R' + $Info.Name.Substring(2))
        $folderExists = [System.IO.Directory]::Exists($dataPath)
        $fileExists = [System.IO.File]::Exists($dataPath)
        $name = [System.IO.Path]::GetFileName($original.TrimEnd([char]'\', [char]'/'))
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $original }
        $type = 'Onbekend'
        if ($folderExists) { $type = 'Map' }
        elseif ($fileExists) { $type = 'Bestand' }
        return [pscustomobject]@{
            Id           = ($Info.FullName.ToLowerInvariant() + '|' + $deleted.ToString('o'))
            Name         = $name
            OriginalPath = $original
            DeletedAt    = $deleted.ToString('o')
            SizeBytes    = $size
            Type         = $type
            Drive        = $Info.FullName.Substring(0, 2).ToUpperInvariant()
            PayloadFound = ($folderExists -or $fileExists)
        }
    } catch {
        return $null
    }
}

function Get-RecycleSnapshot {
    $items = New-Object 'System.Collections.Generic.List[object]'
    $scanned = New-Object 'System.Collections.Generic.List[string]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drive.IsReady) { continue }
            if ($drive.DriveType -ne [System.IO.DriveType]::Fixed -and
                $drive.DriveType -ne [System.IO.DriveType]::Removable) { continue }
            $letter = $drive.Name.Substring(0, 2).ToUpperInvariant()
            $userRecycleBin = Join-Path $drive.RootDirectory.FullName ('$Recycle.Bin\' + $script:MySid)
            if (Test-Path -LiteralPath $userRecycleBin -PathType Container) {
                $infoFiles = Get-ChildItem -LiteralPath $userRecycleBin -Force -File -ErrorAction Stop |
                    Where-Object { $_.Name.StartsWith('$I', [StringComparison]::OrdinalIgnoreCase) }
                foreach ($file in $infoFiles) {
                    $entry = Get-RecycleEntry -Info $file
                    if ($null -ne $entry) { [void]$items.Add($entry) }
                }
            }
            [void]$scanned.Add($letter)
        } catch {
            $driveName = '?'
            try { $driveName = $drive.Name } catch {}
            [void]$warnings.Add(($driveName + ': ' + $_.Exception.Message))
        }
    }
    return [pscustomobject]@{
        Items = @($items.ToArray())
        Scanned = @($scanned.ToArray())
        Warnings = @($warnings.ToArray())
    }
}

function Read-PreviousSnapshot {
    $source = $script:SnapshotPath
    # Import a baseline created by the v1 command-line detector if necessary.
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        $source = Join-Path $script:DataDir 'state.json'
    }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { return $null }
    try {
        $result = Get-Content -LiteralPath $source -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($result.Version -ne 1 -and $result.Version -ne 2) { return $null }
        return $result
    } catch {
        return $null
    }
}

function Write-Snapshot {
    param([object[]]$AllItems)
    $data = [pscustomobject]@{
        Version = 2
        SavedAt = (Get-Date).ToString('o')
        Items = @($AllItems)
    }
    $tmp = Join-Path $script:DataDir ('snapshot-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $data | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $script:SnapshotPath -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Add-RecycleEvent {
    param([string]$Action, [object]$Entry, [datetime]$At)
    $originalExists = $null
    if ($Action -eq 'Left') {
        $originalExists = ([IO.File]::Exists([string]$Entry.OriginalPath) -or
                           [IO.Directory]::Exists([string]$Entry.OriginalPath))
    }
    $ev = [pscustomobject]@{
        Action = $Action
        ObservedAt = $At.ToString('o')
        Id = $Entry.Id
        Name = $Entry.Name
        OriginalPath = $Entry.OriginalPath
        DeletedAt = $Entry.DeletedAt
        SizeBytes = $Entry.SizeBytes
        Type = $Entry.Type
        Drive = $Entry.Drive
        OriginalExistsAtCheck = $originalExists
    }
    $line = $ev | ConvertTo-Json -Depth 4 -Compress
    Add-Content -LiteralPath $script:EventsPath -Value $line -Encoding UTF8
    return $ev
}

function Read-EventLog {
    $history = New-Object 'System.Collections.Generic.List[object]'
    if (Test-Path -LiteralPath $script:EventsPath -PathType Leaf) {
        foreach ($line in (Get-Content -LiteralPath $script:EventsPath -Tail 20000 -Encoding UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $event = $line | ConvertFrom-Json
                if ($event.Action -eq 'LeftRecycleBin') { $event.Action = 'Left' }
                if ($event.Action -eq 'EnteredRecycleBin') { $event.Action = 'Entered' }
                [void]$history.Add($event)
            } catch {}
        }
    }
    return @($history.ToArray())
}

function Update-ScanData {
    $now = Get-Date
    $scan = Get-RecycleSnapshot
    $oldSnapshot = Read-PreviousSnapshot
    $script:FirstRunNote = ($null -eq $oldSnapshot)
    $script:HasBaseline = ($null -ne $oldSnapshot)
    $current = @($scan.Items)
    $retained = New-Object 'System.Collections.Generic.List[object]'
    $old = @{}
    $new = @{}

    if ($null -ne $oldSnapshot) {
        foreach ($entry in @($oldSnapshot.Items)) {
            if ($null -ne $entry -and $null -ne $entry.Id) {
                $old[[string]$entry.Id] = $entry
            }
        }
    }
    foreach ($entry in $current) { $new[[string]$entry.Id] = $entry }

    # A successful scan must exist for the drive before we infer a disappearance.
    if ($null -ne $oldSnapshot) {
        foreach ($entry in $current) {
            if (-not $old.ContainsKey([string]$entry.Id)) {
                [void](Add-RecycleEvent -Action 'Entered' -Entry $entry -At $now)
            }
        }
        foreach ($entry in $old.Values) {
            if ($new.ContainsKey([string]$entry.Id)) { continue }
            if ([string]$entry.Drive -notin @($scan.Scanned)) {
                [void]$retained.Add($entry)
                continue
            }
            [void](Add-RecycleEvent -Action 'Left' -Entry $entry -At $now)
        }
    }
    Write-Snapshot -AllItems @($current + @($retained.ToArray()))
    $script:Items = $current
    $script:Events = @(Read-EventLog)
    $script:Warnings = @($scan.Warnings)
    $script:LastScanAt = $now
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -lt 1024) { return ('{0} B' -f $Bytes) }
    if ($Bytes -lt 1MB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

function Format-Date {
    param([object]$DateValue)
    try { return ([datetime]$DateValue).ToLocalTime().ToString('dd-MM-yyyy HH:mm:ss') }
    catch { return '-' }
}

function Get-DateFilter {
    $now = Get-Date
    switch ($script:PeriodCombo.SelectedIndex) {
        1 { return $now.AddDays(-7) }
        2 { return $now.AddDays(-30) }
        3 { return [datetime]::MinValue }
        default { return $now.AddHours(-24) }
    }
}

# ---- Visual theme -----------------------------------------------------------
function HexColor {
    param([string]$Hex)
    return [System.Drawing.ColorTranslator]::FromHtml($Hex)
}
$script:Theme = @{
    Back = (HexColor '#0B1220')
    Side = (HexColor '#0F1A2B')
    Surface = (HexColor '#131F30')
    Surface2 = (HexColor '#17253A')
    Border = (HexColor '#26374D')
    Text = (HexColor '#EAF2FB')
    Muted = (HexColor '#91A4BC')
    Accent = (HexColor '#4CE0C3')
    Blue = (HexColor '#78AEFF')
    Amber = (HexColor '#FFCB79')
    Red = (HexColor '#FF8392')
}

function New-Font {
    param([float]$Size, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    return (New-Object -TypeName System.Drawing.Font -ArgumentList @('Segoe UI', $Size, $Style))
}

function Make-Label {
    param([string]$Text, [float]$Size = 10, [System.Drawing.Color]$Color = $script:Theme.Text,
          [int]$X = 0, [int]$Y = 0, [int]$Width = 220, [int]$Height = 25,
          [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Font = New-Font -Size $Size -Style $Style
    $label.ForeColor = $Color
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    $label.AutoEllipsis = $true
    return $label
}

function Make-Button {
    param([string]$Text, [System.Drawing.Color]$Back = $script:Theme.Surface2,
          [System.Drawing.Color]$Fore = $script:Theme.Text)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.FlatAppearance.MouseOverBackColor = $script:Theme.Border
    $button.BackColor = $Back
    $button.ForeColor = $Fore
    $button.Font = New-Font -Size 9.5 -Style ([System.Drawing.FontStyle]::Bold)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.UseVisualStyleBackColor = $false
    return $button
}

function Add-Metric {
    param([System.Windows.Forms.TableLayoutPanel]$Grid, [int]$Index,
          [string]$Caption, [System.Drawing.Color]$Highlight)
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Fill'
    $panel.Margin = New-Object System.Windows.Forms.Padding(7, 9, 7, 9)
    $panel.BackColor = $script:Theme.Surface
    $tag = New-Object System.Windows.Forms.Panel
    $tag.BackColor = $Highlight
    $tag.Size = New-Object System.Drawing.Size(4, 49)
    $tag.Location = New-Object System.Drawing.Point(0, 19)
    $panel.Controls.Add($tag)
    $captionLabel = Make-Label -Text $Caption -Size 9 -Color $script:Theme.Muted -X 18 -Y 14 -Width 236 -Height 19
    $valueLabel = Make-Label -Text '0' -Size 23 -Style ([System.Drawing.FontStyle]::Bold) -X 18 -Y 33 -Width 240 -Height 42
    $captionLabel.Anchor = 'Left,Top,Right'
    $valueLabel.Anchor = 'Left,Top,Right'
    $panel.Controls.Add($captionLabel)
    $panel.Controls.Add($valueLabel)
    $Grid.Controls.Add($panel, $Index, 0)
    return $valueLabel
}

# ---- GUI --------------------------------------------------------------------
$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'Tesla Recycle Bin Detector  |  v2.0'
$script:Form.BackColor = $script:Theme.Back
$script:Form.ForeColor = $script:Theme.Text
$script:Form.ClientSize = New-Object System.Drawing.Size(1250, 785)
$script:Form.MinimumSize = New-Object System.Drawing.Size(1040, 650)
$script:Form.StartPosition = 'CenterScreen'
$script:Form.Font = New-Font -Size 9.5
$script:Form.AutoScaleMode = 'Dpi'

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.Margin = New-Object System.Windows.Forms.Padding(0)
$layout.Padding = New-Object System.Windows.Forms.Padding(0)
$layout.RowCount = 1
$layout.ColumnCount = 2
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 235)))
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
$script:Form.Controls.Add($layout)

$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Dock = 'Fill'
$sidebar.BackColor = $script:Theme.Side
$sidebar.Margin = New-Object System.Windows.Forms.Padding(0)
$layout.Controls.Add($sidebar, 0, 0)

$mark = Make-Label -Text 'T' -Size 22 -Color $script:Theme.Accent -X 22 -Y 22 -Width 41 -Height 47 -Style ([System.Drawing.FontStyle]::Bold)
$sidebar.Controls.Add($mark)
$sidebar.Controls.Add((Make-Label -Text 'TESLA' -Size 17 -X 65 -Y 23 -Width 148 -Height 34 -Style ([System.Drawing.FontStyle]::Bold)))
$sidebar.Controls.Add((Make-Label -Text 'RECYCLE BIN DETECTOR' -Size 8.5 -Color $script:Theme.Muted -X 26 -Y 76 -Width 190 -Height 24))
$sidebar.Controls.Add((Make-Label -Text 'NAVIGATIE' -Size 8.5 -Color $script:Theme.Muted -X 26 -Y 139 -Width 164 -Height 20 -Style ([System.Drawing.FontStyle]::Bold)))

$script:NavButtons = @{}
$navList = @(
    @{Key='current'; Text='  Prullenbak'; Y=174},
    @{Key='left'; Text='  Verdwenen items'; Y=226},
    @{Key='history'; Text='  Activiteitenlog'; Y=278},
    @{Key='info'; Text='  Info & uitleg'; Y=330}
)
foreach ($nav in $navList) {
    $b = Make-Button -Text $nav.Text -Back $script:Theme.Side -Fore $script:Theme.Muted
    $b.TextAlign = 'MiddleLeft'
    $b.Location = New-Object System.Drawing.Point(15, $nav.Y)
    $b.Size = New-Object System.Drawing.Size(205, 44)
    $b.Tag = $nav.Key
    $b.Add_Click({ param($sender, $e) Set-Page ([string]$sender.Tag) })
    $sidebar.Controls.Add($b)
    $script:NavButtons[$nav.Key] = $b
}
$sideBottom = New-Object System.Windows.Forms.Panel
$sideBottom.Dock = 'Bottom'
$sideBottom.Height = 109
$sideBottom.BackColor = $script:Theme.Side
$sideBottom.Controls.Add((Make-Label -Text 'LOKAAL & PRIVE' -Size 8.5 -Color $script:Theme.Accent -X 23 -Y 12 -Width 183 -Height 20 -Style ([System.Drawing.FontStyle]::Bold)))
$sideBottom.Controls.Add((Make-Label -Text 'Alle scans blijven op deze pc.' -Size 8.5 -Color $script:Theme.Muted -X 23 -Y 38 -Width 192 -Height 24))
$sideBottom.Controls.Add((Make-Label -Text 'Tesla Detector  /  v2.0' -Size 8.5 -Color $script:Theme.Muted -X 23 -Y 70 -Width 192 -Height 24))
$sidebar.Controls.Add($sideBottom)

$main = New-Object System.Windows.Forms.TableLayoutPanel
$main.Dock = 'Fill'
$main.BackColor = $script:Theme.Back
$main.Margin = New-Object System.Windows.Forms.Padding(0)
$main.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)
$main.RowCount = 5
$main.ColumnCount = 1
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 99)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 120)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 66)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 40)))
$layout.Controls.Add($main, 1, 0)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Fill'
$header.BackColor = $script:Theme.Back
$main.Controls.Add($header, 0, 0)
$script:TitleLabel = Make-Label -Text 'Prullenbak' -Size 20 -X 14 -Y 14 -Width 510 -Height 39 -Style ([System.Drawing.FontStyle]::Bold)
$script:TitleLabel.Anchor = 'Left,Top,Right'
$header.Controls.Add($script:TitleLabel)
$script:SubLabel = Make-Label -Text 'Bestanden die op dit moment in de Prullenbak staan.' -Size 9.5 -Color $script:Theme.Muted -X 15 -Y 56 -Width 580 -Height 26
$script:SubLabel.Anchor = 'Left,Top,Right'
$header.Controls.Add($script:SubLabel)
$headerActions = New-Object System.Windows.Forms.FlowLayoutPanel
$headerActions.Dock = 'Right'
$headerActions.Width = 316
$headerActions.FlowDirection = 'RightToLeft'
$headerActions.WrapContents = $false
$headerActions.Padding = New-Object System.Windows.Forms.Padding(0, 22, 8, 0)
$header.Controls.Add($headerActions)
$script:ExportButton = Make-Button -Text 'Exporteer CSV'
$script:ExportButton.Size = New-Object System.Drawing.Size(135, 41)
$script:ExportButton.Margin = New-Object System.Windows.Forms.Padding(7, 0, 0, 0)
$headerActions.Controls.Add($script:ExportButton)
$script:RefreshButton = Make-Button -Text 'Opnieuw scannen' -Back $script:Theme.Accent -Fore $script:Theme.Back
$script:RefreshButton.Size = New-Object System.Drawing.Size(148, 41)
$script:RefreshButton.Margin = New-Object System.Windows.Forms.Padding(0)
$headerActions.Controls.Add($script:RefreshButton)

$metrics = New-Object System.Windows.Forms.TableLayoutPanel
$metrics.Dock = 'Fill'
$metrics.Margin = New-Object System.Windows.Forms.Padding(0)
$metrics.ColumnCount = 4
$metrics.RowCount = 1
for ($i=0; $i -lt 4; $i++) {
    [void]$metrics.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 25)))
}
$main.Controls.Add($metrics, 0, 1)
$script:MetricAll = Add-Metric -Grid $metrics -Index 0 -Caption 'NU IN PRULLENBAK' -Highlight $script:Theme.Accent
$script:MetricRecent = Add-Metric -Grid $metrics -Index 1 -Caption 'RECENT IN PRULLENBAK' -Highlight $script:Theme.Blue
$script:MetricLeft = Add-Metric -Grid $metrics -Index 2 -Caption 'VERDWENEN (LOG)' -Highlight $script:Theme.Amber
$script:MetricEvents = Add-Metric -Grid $metrics -Index 3 -Caption 'ACTIES (LOG)' -Highlight $script:Theme.Muted

$filters = New-Object System.Windows.Forms.TableLayoutPanel
$filters.Dock = 'Fill'
$filters.Margin = New-Object System.Windows.Forms.Padding(7, 5, 7, 7)
$filters.Padding = New-Object System.Windows.Forms.Padding(8, 7, 8, 6)
$filters.BackColor = $script:Theme.Surface
$filters.RowCount = 1
$filters.ColumnCount = 4
[void]$filters.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 170)))
[void]$filters.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$filters.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 169)))
[void]$filters.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 104)))
$main.Controls.Add($filters, 0, 2)
$script:PeriodCombo = New-Object System.Windows.Forms.ComboBox
$script:PeriodCombo.Dock = 'Fill'
$script:PeriodCombo.DropDownStyle = 'DropDownList'
$script:PeriodCombo.FlatStyle = 'Flat'
$script:PeriodCombo.BackColor = $script:Theme.Surface2
$script:PeriodCombo.ForeColor = $script:Theme.Text
$script:PeriodCombo.Font = New-Font -Size 9.3
$script:PeriodCombo.Margin = New-Object System.Windows.Forms.Padding(3, 6, 9, 6)
[void]$script:PeriodCombo.Items.AddRange([object[]]@('Laatste 24 uur','Laatste 7 dagen','Laatste 30 dagen','Alles'))
$filters.Controls.Add($script:PeriodCombo, 0, 0)
$script:SearchBox = New-Object System.Windows.Forms.TextBox
$script:SearchBox.Dock = 'Fill'
$script:SearchBox.Margin = New-Object System.Windows.Forms.Padding(5, 8, 8, 7)
$script:SearchBox.BackColor = $script:Theme.Surface2
$script:SearchBox.ForeColor = $script:Theme.Text
$script:SearchBox.BorderStyle = 'FixedSingle'
$script:SearchBox.Font = New-Font -Size 10
$script:SearchBox.Text = ''
$filters.Controls.Add($script:SearchBox, 1, 0)
$script:AutoCheck = New-Object System.Windows.Forms.CheckBox
$script:AutoCheck.Dock = 'Fill'
$script:AutoCheck.Text = 'Auto-scan (60 sec)'
$script:AutoCheck.Checked = $true
$script:AutoCheck.ForeColor = $script:Theme.Text
$script:AutoCheck.Margin = New-Object System.Windows.Forms.Padding(12, 0, 2, 0)
$script:AutoCheck.Font = New-Font -Size 9
$filters.Controls.Add($script:AutoCheck, 2, 0)
$script:ResultCount = Make-Label -Text '0 resultaten' -Size 8.5 -Color $script:Theme.Muted -X 0 -Y 0 -Width 90 -Height 34
$script:ResultCount.Dock = 'Fill'
$script:ResultCount.TextAlign = 'MiddleRight'
$filters.Controls.Add($script:ResultCount, 3, 0)

$content = New-Object System.Windows.Forms.TableLayoutPanel
$content.Dock = 'Fill'
$content.Margin = New-Object System.Windows.Forms.Padding(7, 1, 7, 0)
$content.ColumnCount = 2
$content.RowCount = 1
[void]$content.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
[void]$content.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 294)))
$main.Controls.Add($content, 0, 3)

$listHost = New-Object System.Windows.Forms.Panel
$listHost.Dock = 'Fill'
$listHost.BackColor = $script:Theme.Surface
$listHost.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$content.Controls.Add($listHost, 0, 0)

$script:Grid = New-Object System.Windows.Forms.DataGridView
$script:Grid.Dock = 'Fill'
$script:Grid.BackgroundColor = $script:Theme.Surface
$script:Grid.BorderStyle = 'None'
$script:Grid.GridColor = $script:Theme.Surface
$script:Grid.ColumnHeadersBorderStyle = 'None'
$script:Grid.CellBorderStyle = 'SingleHorizontal'
$script:Grid.RowHeadersVisible = $false
$script:Grid.AllowUserToAddRows = $false
$script:Grid.AllowUserToDeleteRows = $false
$script:Grid.AllowUserToResizeRows = $false
$script:Grid.ReadOnly = $true
$script:Grid.MultiSelect = $false
$script:Grid.SelectionMode = 'FullRowSelect'
$script:Grid.ColumnHeadersHeight = 46
$script:Grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$script:Grid.RowTemplate.Height = 42
$script:Grid.AutoSizeColumnsMode = 'Fill'
$script:Grid.EnableHeadersVisualStyles = $false
$script:Grid.Font = New-Font -Size 9.3
$script:Grid.ColumnHeadersDefaultCellStyle.BackColor = $script:Theme.Surface2
$script:Grid.ColumnHeadersDefaultCellStyle.ForeColor = $script:Theme.Muted
$script:Grid.ColumnHeadersDefaultCellStyle.Font = New-Font -Size 9 -Style ([System.Drawing.FontStyle]::Bold)
$script:Grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $script:Theme.Surface2
$script:Grid.DefaultCellStyle.BackColor = $script:Theme.Surface
$script:Grid.DefaultCellStyle.ForeColor = $script:Theme.Text
$script:Grid.DefaultCellStyle.SelectionBackColor = (HexColor '#253E57')
$script:Grid.DefaultCellStyle.SelectionForeColor = $script:Theme.Text
$script:Grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(7, 0, 5, 0)
$script:Grid.AlternatingRowsDefaultCellStyle.BackColor = (HexColor '#162339')
$script:Grid.DefaultCellStyle.WrapMode = 'False'
$script:Grid.RowTemplate.DefaultCellStyle.Alignment = 'MiddleLeft'
$script:Grid.ScrollBars = 'Both'
[void]$script:Grid.Columns.Add('FileName', 'BESTAND')
[void]$script:Grid.Columns.Add('FilePath', 'OORSPRONKELIJK PAD')
[void]$script:Grid.Columns.Add('When', 'DATUM')
[void]$script:Grid.Columns.Add('Size', 'GROOTTE')
[void]$script:Grid.Columns.Add('State', 'STATUS')
$script:Grid.Columns[0].FillWeight = 26
$script:Grid.Columns[1].FillWeight = 37
$script:Grid.Columns[2].FillWeight = 21
$script:Grid.Columns[3].FillWeight = 12
$script:Grid.Columns[4].FillWeight = 19
$listHost.Controls.Add($script:Grid)

$script:InfoPanel = New-Object System.Windows.Forms.Panel
$script:InfoPanel.Dock = 'Fill'
$script:InfoPanel.BackColor = $script:Theme.Surface
$script:InfoPanel.Visible = $false
$listHost.Controls.Add($script:InfoPanel)
$infoTitle = Make-Label -Text 'Hoe werkt Tesla Detector?' -Size 15 -X 24 -Y 25 -Width 610 -Height 40 -Style ([System.Drawing.FontStyle]::Bold)
$infoTitle.Anchor = 'Left,Top,Right'
$script:InfoPanel.Controls.Add($infoTitle)
$script:InfoText = New-Object System.Windows.Forms.RichTextBox
$script:InfoText.Location = New-Object System.Drawing.Point(24, 78)
$script:InfoText.Size = New-Object System.Drawing.Size(600, 370)
$script:InfoText.Anchor = 'Top,Bottom,Left,Right'
$script:InfoText.BackColor = $script:Theme.Surface
$script:InfoText.ForeColor = $script:Theme.Text
$script:InfoText.BorderStyle = 'None'
$script:InfoText.ReadOnly = $true
$script:InfoText.ScrollBars = 'Vertical'
$script:InfoText.Font = New-Font -Size 10.5
$script:InfoText.Text = @'
WAT KAN DE TOOL ZIEN?

1. PRULLENBAK
   Bestanden die nu nog in je eigen Windows Prullenbak staan.
   Je ziet de originele naam, locatie, grootte en verwijdertijd.

2. VERDWENEN ITEMS
   Bestanden die bij een vorige scan aanwezig waren maar bij een
   latere scan niet meer gevonden werden.

   Let op: dit kan komen door definitief verwijderen OF herstellen.
   Dat verschil kan de tool niet met zekerheid bepalen.

3. ACTIVITEITENLOG
   Nieuwe toevoegingen en verdwijningen sinds je eerste scan.
   De monitor vergelijkt de Prullenbak elke 60 seconden zolang
   de applicatie open is en auto-scan is ingeschakeld.

WAT KAN DE TOOL NIET?

- Bestanden terughalen die al voor je eerste scan definitief
  verwijderd waren.
- Bewijzen dat een verdwenen bestand definitief is gewist.
- Bestanden zien die met Shift+Delete de Prullenbak overslaan.
- Zien wat andere gebruikers in hun eigen Prullenbak hebben.

PRIVACY EN VEILIGHEID

Deze tool verwijdert, herstelt en uploadt geen bestanden.
De geschiedenis wordt lokaal opgeslagen in jouw AppData-map.
'@
$script:InfoPanel.Controls.Add($script:InfoText)

$detail = New-Object System.Windows.Forms.Panel
$detail.Dock = 'Fill'
$detail.BackColor = $script:Theme.Surface
$detail.AutoScroll = $true
$detail.Margin = New-Object System.Windows.Forms.Padding(1, 0, 0, 0)
$content.Controls.Add($detail, 1, 0)
$detail.Controls.Add((Make-Label -Text 'DETAILS' -Size 9 -Color $script:Theme.Accent -X 19 -Y 23 -Width 230 -Height 23 -Style ([System.Drawing.FontStyle]::Bold)))
$script:DetailTitle = Make-Label -Text 'Selecteer een bestand' -Size 14 -X 19 -Y 51 -Width 250 -Height 50 -Style ([System.Drawing.FontStyle]::Bold)
$script:DetailTitle.Anchor = 'Left,Top,Right'
$detail.Controls.Add($script:DetailTitle)
$detail.Controls.Add((Make-Label -Text 'OORSPRONKELIJKE LOCATIE' -Size 8 -Color $script:Theme.Muted -X 19 -Y 113 -Width 259 -Height 22))
$script:DetailPath = Make-Label -Text '-' -Size 9 -X 19 -Y 137 -Width 250 -Height 43
$script:DetailPath.Anchor = 'Top,Left,Right'
$detail.Controls.Add($script:DetailPath)
$detail.Controls.Add((Make-Label -Text 'DATUM / TIJD' -Size 8 -Color $script:Theme.Muted -X 19 -Y 189 -Width 250 -Height 22))
$script:DetailDate = Make-Label -Text '-' -Size 10 -X 19 -Y 211 -Width 254 -Height 29
$detail.Controls.Add($script:DetailDate)
$detail.Controls.Add((Make-Label -Text 'GROOTTE EN TYPE' -Size 8 -Color $script:Theme.Muted -X 19 -Y 250 -Width 250 -Height 22))
$script:DetailType = Make-Label -Text '-' -Size 10 -X 19 -Y 272 -Width 250 -Height 29
$detail.Controls.Add($script:DetailType)
$detail.Controls.Add((Make-Label -Text 'STATUS' -Size 8 -Color $script:Theme.Muted -X 19 -Y 311 -Width 250 -Height 22))
$script:DetailStatus = Make-Label -Text 'Nog niets geselecteerd.' -Size 9 -Color $script:Theme.Amber -X 19 -Y 333 -Width 250 -Height 53
$detail.Controls.Add($script:DetailStatus)
$copyButton = Make-Button -Text 'Kopieer origineel pad' -Back $script:Theme.Surface2
$copyButton.Location = New-Object System.Drawing.Point(18, 398)
$copyButton.Size = New-Object System.Drawing.Size(255, 42)
$copyButton.Anchor = 'Left,Top,Right'
$detail.Controls.Add($copyButton)
$script:SelectedEntry = $null

$footer = New-Object System.Windows.Forms.Panel
$footer.Dock = 'Fill'
$footer.BackColor = $script:Theme.Back
$main.Controls.Add($footer, 0, 4)
$script:StatusLabel = Make-Label -Text 'Gereed voor eerste scan.' -Size 8.8 -Color $script:Theme.Muted -X 9 -Y 9 -Width 650 -Height 25
$script:StatusLabel.Anchor = 'Top,Left,Right'
$footer.Controls.Add($script:StatusLabel)

# ---- Presentation and commands ----------------------------------------------
function Get-RowsForPage {
    $cutoff = Get-DateFilter
    $needle = $script:SearchBox.Text.Trim()
    $out = New-Object 'System.Collections.Generic.List[object]'
    if ($script:Page -eq 'current') {
        foreach ($item in $script:Items) {
            if ([datetime]$item.DeletedAt -lt $cutoff) { continue }
            if ($needle -and (($item.Name + ' ' + $item.OriginalPath).IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
            [void]$out.Add([pscustomobject]@{ Item=$item; Action='Current'; When=$item.DeletedAt })
        }
    } elseif ($script:Page -eq 'left' -or $script:Page -eq 'history') {
        foreach ($ev in $script:Events) {
            if ($script:Page -eq 'left' -and $ev.Action -ne 'Left') { continue }
            if ([datetime]$ev.ObservedAt -lt $cutoff) { continue }
            if ($needle -and (($ev.Name + ' ' + $ev.OriginalPath).IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
            [void]$out.Add([pscustomobject]@{ Item=$ev; Action=$ev.Action; When=$ev.ObservedAt })
        }
    }
    return @($out.ToArray() | Sort-Object { [datetime]$_.When } -Descending)
}

function Refresh-Metrics {
    $cutoff = Get-DateFilter
    $currentRecent = @($script:Items | Where-Object { [datetime]$_.DeletedAt -ge $cutoff }).Count
    $recentEvents = @($script:Events | Where-Object { [datetime]$_.ObservedAt -ge $cutoff })
    $leftCount = @($recentEvents | Where-Object { $_.Action -eq 'Left' }).Count
    $script:MetricAll.Text = [string]$script:Items.Count
    $script:MetricRecent.Text = [string]$currentRecent
    $script:MetricLeft.Text = [string]$leftCount
    $script:MetricEvents.Text = [string]$recentEvents.Count
}

function Show-Details {
    param([object]$Record)
    $script:SelectedEntry = $Record
    if ($null -eq $Record) {
        $script:DetailTitle.Text = 'Selecteer een bestand'
        $script:DetailPath.Text = '-'
        $script:DetailDate.Text = '-'
        $script:DetailType.Text = '-'
        $script:DetailStatus.Text = 'Nog niets geselecteerd.'
        return
    }
    $entry = $Record.Item
    $script:DetailTitle.Text = [string]$entry.Name
    $script:DetailPath.Text = [string]$entry.OriginalPath
    $script:DetailDate.Text = Format-Date -DateValue $Record.When
    $script:DetailType.Text = ((Format-Bytes -Bytes ([long]$entry.SizeBytes)) + '   /   ' + $entry.Type)
    if ($Record.Action -eq 'Current') {
        $script:DetailStatus.ForeColor = $script:Theme.Accent
        $script:DetailStatus.Text = 'Staat momenteel in de Prullenbak.'
        if (-not $entry.PayloadFound) {
            $script:DetailStatus.ForeColor = $script:Theme.Amber
            $script:DetailStatus.Text = 'Metadata gevonden, maar de inhoud ontbreekt.'
        }
    } elseif ($Record.Action -eq 'Entered') {
        $script:DetailStatus.ForeColor = $script:Theme.Blue
        $script:DetailStatus.Text = 'Toevoeging gezien tijdens een scan.'
    } else {
        $script:DetailStatus.ForeColor = $script:Theme.Amber
        $script:DetailStatus.Text = 'Niet meer in de Prullenbak. Hersteld of definitief verwijderd: onbekend.'
    }
}

function Refresh-Table {
    Refresh-Metrics
    $script:Displayed = @(Get-RowsForPage)
    $script:Grid.SuspendLayout()
    try {
        $script:Grid.Rows.Clear()
        foreach ($record in $script:Displayed) {
            $state = 'IN PRULLENBAK'
            $color = $script:Theme.Accent
            if ($record.Action -eq 'Entered') { $state = 'TOEGEVOEGD'; $color = $script:Theme.Blue }
            elseif ($record.Action -eq 'Left') { $state = 'VERDWENEN'; $color = $script:Theme.Amber }
            $item = $record.Item
            $index = $script:Grid.Rows.Add(
                [string]$item.Name, [string]$item.OriginalPath,
                (Format-Date -DateValue $record.When),
                (Format-Bytes -Bytes ([long]$item.SizeBytes)), $state
            )
            $script:Grid.Rows[$index].Tag = $record
            $script:Grid.Rows[$index].Cells[4].Style.ForeColor = $color
        }
        $script:Grid.ClearSelection()
        $script:ResultCount.Text = ('{0} resultaten' -f $script:Displayed.Count)
        Show-Details -Record $null
    } finally {
        $script:Grid.ResumeLayout()
    }
}

function Set-Page {
    param([string]$Page)
    $script:Page = $Page
    $headings = @{
        current = @('Prullenbak', 'Bestanden die nu in de Prullenbak staan.')
        left = @('Verdwenen items', 'Niet meer gevonden sinds een eerdere scan. Oorzaak onbekend.')
        history = @('Activiteitenlog', 'Toevoegingen en verdwijningen die de monitor heeft waargenomen.')
        info = @('Info & uitleg', 'Wat de tool kan zien en welke beperkingen Windows heeft.')
    }
    $script:TitleLabel.Text = $headings[$Page][0]
    $script:SubLabel.Text = $headings[$Page][1]
    foreach ($key in @($script:NavButtons.Keys)) {
        $button = $script:NavButtons[$key]
        if ($key -eq $Page) {
            $button.BackColor = $script:Theme.Surface2
            $button.ForeColor = $script:Theme.Accent
        } else {
            $button.BackColor = $script:Theme.Side
            $button.ForeColor = $script:Theme.Muted
        }
    }
    $script:Grid.Visible = ($Page -ne 'info')
    $script:InfoPanel.Visible = ($Page -eq 'info')
    $script:Grid.SendToBack()
    if ($Page -eq 'info') { $script:InfoPanel.BringToFront() }
    $script:ExportButton.Enabled = ($Page -ne 'info')
    Refresh-Table
}

function Run-Scan {
    if ($script:Busy) { return }
    $script:Busy = $true
    $script:RefreshButton.Enabled = $false
    $script:StatusLabel.Text = 'Scannen...'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        Update-ScanData
        Refresh-Table
        $status = 'Laatste scan: ' + $script:LastScanAt.ToString('dd-MM-yyyy HH:mm:ss')
        if ($script:FirstRunNote) { $status += '  |  Eerste nulmeting aangemaakt.' }
        if ($script:Warnings.Count -gt 0) { $status += '  |  Niet alle schijven konden worden gelezen.' }
        $script:StatusLabel.Text = $status
        $script:StatusLabel.ForeColor = $(if ($script:Warnings.Count -gt 0) { $script:Theme.Amber } else { $script:Theme.Muted })
    } catch {
        $script:StatusLabel.Text = 'Scan mislukt: ' + $_.Exception.Message
        $script:StatusLabel.ForeColor = $script:Theme.Red
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Scanfout', 'OK', 'Error') | Out-Null
    } finally {
        $script:RefreshButton.Enabled = $true
        $script:Busy = $false
    }
}

function Export-VisibleCsv {
    if ($script:Page -eq 'info') { return }
    $save = New-Object System.Windows.Forms.SaveFileDialog
    $save.Filter = 'CSV bestanden (*.csv)|*.csv'
    $save.FileName = 'tesla-recycle-bin-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.csv'
    $save.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($save.ShowDialog($script:Form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
    try {
        $report = New-Object 'System.Collections.Generic.List[object]'
        foreach ($record in $script:Displayed) {
            $entry = $record.Item
            $status = switch ($record.Action) {
                'Current' { 'In prullenbak' }
                'Entered' { 'Toegevoegd aan prullenbak' }
                'Left' { 'Verdwenen (oorzaak onbekend)' }
            }
            [void]$report.Add([pscustomobject]@{
                Status = $status
                Naam = $entry.Name
                OorspronkelijkPad = $entry.OriginalPath
                Datum = (Format-Date -DateValue $record.When)
                VerwijderdOp = (Format-Date -DateValue $entry.DeletedAt)
                GrootteBytes = $entry.SizeBytes
                Type = $entry.Type
            })
        }
        if ($report.Count -gt 0) {
            $report.ToArray() | Export-Csv -LiteralPath $save.FileName -NoTypeInformation -Delimiter ';' -Encoding UTF8
        } else {
            'Status;Naam;OorspronkelijkPad;Datum;VerwijderdOp;GrootteBytes;Type' |
                Set-Content -LiteralPath $save.FileName -Encoding UTF8
        }
        $script:StatusLabel.Text = 'CSV opgeslagen: ' + $save.FileName
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Export mislukt', 'OK', 'Error') | Out-Null
    } finally {
        $save.Dispose()
    }
}

$script:ScanTimer = New-Object System.Windows.Forms.Timer
$script:ScanTimer.Interval = 60000
$script:ScanTimer.Add_Tick({ Run-Scan })
$script:SearchBox.Add_TextChanged({ Refresh-Table })
$script:PeriodCombo.Add_SelectedIndexChanged({ Refresh-Table })
$script:RefreshButton.Add_Click({ Run-Scan })
$script:ExportButton.Add_Click({ Export-VisibleCsv })
$script:AutoCheck.Add_CheckedChanged({
    if ($script:AutoCheck.Checked) { $script:ScanTimer.Start() }
    else { $script:ScanTimer.Stop() }
})
$script:Grid.Add_SelectionChanged({
    if ($script:Grid.SelectedRows.Count -gt 0) {
        Show-Details -Record $script:Grid.SelectedRows[0].Tag
    }
})
$copyButton.Add_Click({
    if ($null -ne $script:SelectedEntry) {
        [System.Windows.Forms.Clipboard]::SetText([string]$script:SelectedEntry.Item.OriginalPath)
        $script:StatusLabel.Text = 'Oorspronkelijk pad gekopieerd.'
    }
})
$script:PeriodCombo.SelectedIndex = 0
Set-Page 'current'
$script:Form.Add_Shown({
    Run-Scan
    if ($script:AutoCheck.Checked) { $script:ScanTimer.Start() }
})
$script:Form.Add_FormClosed({
    $script:ScanTimer.Stop()
    $script:ScanTimer.Dispose()
})

try {
    [void]$script:Form.ShowDialog()
} finally {
    $script:Form.Dispose()
}
