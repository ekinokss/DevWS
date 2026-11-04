param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\Fixtures')
)

$ErrorActionPreference = 'Stop'
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputFull -Force | Out-Null

function New-Rect([int]$X, [int]$Y, [int]$W, [int]$H) {
    [ordered]@{ x = $X; y = $Y; w = $W; h = $H }
}

function New-Monitor([string]$Id, [string]$Name, [bool]$Primary, $Rect, $WorkRect, [int]$ScalePercent) {
    [ordered]@{
        id = $Id
        name = $Name
        primary = $Primary
        monitorRect = $Rect
        workRect = $WorkRect
        scalePercent = $ScalePercent
    }
}

function Add-ItemGrid {
    param(
        [System.Collections.Generic.List[object]]$Items,
        [string]$MonitorId,
        $WorkRect,
        [int]$Count,
        [int]$StartIndex
    )

    $columns = [Math]::Max(1, [int][Math]::Ceiling([Math]::Sqrt($Count)))
    $rows = [Math]::Max(1, [int][Math]::Ceiling($Count / $columns))
    $margin = 36
    $gap = 12
    $cellW = [int][Math]::Floor(($WorkRect.w - 2 * $margin - ($columns - 1) * $gap) / $columns)
    $cellH = [int][Math]::Floor(($WorkRect.h - 2 * $margin - ($rows - 1) * $gap) / $rows)

    for ($i = 0; $i -lt $Count; $i++) {
        $col = $i % $columns
        $row = [int][Math]::Floor($i / $columns)
        $x = $WorkRect.x + $margin + $col * ($cellW + $gap)
        $y = $WorkRect.y + $margin + $row * ($cellH + $gap)
        $Items.Add([ordered]@{
            id = ('item-{0:D3}' -f ($StartIndex + $i + 1))
            kind = $(if (($StartIndex + $i) % 5 -eq 0) { 'app' } else { 'terminal' })
            monitorId = $MonitorId
            enabled = $true
            rect = New-Rect $x $y $cellW $cellH
        })
    }
}

function Write-Fixture([string]$Name, $VirtualRect, $Monitors, $Items) {
    $fixture = [ordered]@{
        name = $Name
        virtualScreenRect = $VirtualRect
        monitors = @($Monitors)
        items = @($Items)
    }
    $path = Join-Path $outputFull "$Name.json"
    $fixture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Output "wrote $path"
}

# Two monitors: secondary to the left with a negative origin; synthetic mixed DPI.
$twoMonitors = @(
    (New-Monitor 'left' 'Left (synthetic)' $false (New-Rect -1920 0 1920 1080) (New-Rect -1920 0 1920 1040) 100),
    (New-Monitor 'right' 'Right (synthetic)' $true (New-Rect 0 0 2560 1440) (New-Rect 0 0 2560 1400) 150)
)
$twoItems = [System.Collections.Generic.List[object]]::new()
Add-ItemGrid -Items $twoItems -MonitorId 'left' -WorkRect (New-Rect -1920 0 1920 1040) -Count 5 -StartIndex 0
Add-ItemGrid -Items $twoItems -MonitorId 'right' -WorkRect (New-Rect 0 0 2560 1400) -Count 5 -StartIndex 5
Write-Fixture 'two-monitors-10-items' (New-Rect -1920 0 4480 1440) $twoMonitors $twoItems

# Four monitors in a 2x2 arrangement with negative X and Y origins.
$fourMonitors = @(
    (New-Monitor 'top-left' 'Top Left' $false (New-Rect -1920 -1080 1920 1080) (New-Rect -1920 -1080 1920 1040) 100),
    (New-Monitor 'top-right' 'Top Right' $false (New-Rect 0 -1080 2560 1440) (New-Rect 0 -1080 2560 1400) 125),
    (New-Monitor 'bottom-left' 'Bottom Left' $false (New-Rect -1920 0 1920 1080) (New-Rect -1920 0 1920 1040) 100),
    (New-Monitor 'bottom-right' 'Bottom Right' $true (New-Rect 0 0 2560 1440) (New-Rect 0 0 2560 1400) 150)
)
$fourItems = [System.Collections.Generic.List[object]]::new()
$fourCounts = @(12, 13, 12, 13)
for ($i = 0; $i -lt $fourMonitors.Count; $i++) {
    $monitor = $fourMonitors[$i]
    Add-ItemGrid -Items $fourItems -MonitorId $monitor.id -WorkRect $monitor.workRect -Count $fourCounts[$i] -StartIndex $fourItems.Count
}
Write-Fixture 'four-monitors-50-items' (New-Rect -1920 -1080 4480 2520) $fourMonitors $fourItems

# Eight monitors: four columns by two rows, varied dimensions, negative origins.
$eightMonitors = @(
    (New-Monitor 'r0-c0' 'Row 0 Col 0' $false (New-Rect -1920 -1440 1920 1080) (New-Rect -1920 -1440 1920 1040) 100),
    (New-Monitor 'r0-c1' 'Row 0 Col 1' $false (New-Rect 0 -1440 2560 1440) (New-Rect 0 -1440 2560 1400) 150),
    (New-Monitor 'r0-c2' 'Row 0 Col 2' $false (New-Rect 2560 -1440 1920 1080) (New-Rect 2560 -1440 1920 1040) 100),
    (New-Monitor 'r0-c3' 'Row 0 Col 3' $false (New-Rect 4480 -1440 2560 1440) (New-Rect 4480 -1440 2560 1400) 125),
    (New-Monitor 'r1-c0' 'Row 1 Col 0' $false (New-Rect -1920 0 1920 1080) (New-Rect -1920 0 1920 1040) 100),
    (New-Monitor 'r1-c1' 'Row 1 Col 1' $true (New-Rect 0 0 2560 1440) (New-Rect 0 0 2560 1400) 150),
    (New-Monitor 'r1-c2' 'Row 1 Col 2' $false (New-Rect 2560 0 1920 1080) (New-Rect 2560 0 1920 1040) 100),
    (New-Monitor 'r1-c3' 'Row 1 Col 3' $false (New-Rect 4480 0 2560 1440) (New-Rect 4480 0 2560 1400) 125)
)
$eightItems = [System.Collections.Generic.List[object]]::new()
foreach ($monitor in $eightMonitors) {
    Add-ItemGrid -Items $eightItems -MonitorId $monitor.id -WorkRect $monitor.workRect -Count 25 -StartIndex $eightItems.Count
}
Write-Fixture 'eight-monitors-200-items' (New-Rect -1920 -1440 8960 2880) $eightMonitors $eightItems
