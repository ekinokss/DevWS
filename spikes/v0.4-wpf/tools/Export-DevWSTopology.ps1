param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\Fixtures\host-topology.json'),
    [switch]$IncludeMonitorNames
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))

. (Join-Path $repoRoot 'src\lib\devws-paths.ps1')
. (Join-Path $repoRoot 'src\lib\devws-native.ps1')
. (Join-Path $repoRoot 'src\lib\devws-monitor.ps1')

$topology = Get-DevWSMonitorTopology

if (-not $topology.Available) {
    throw "The current monitor topology is unavailable: $($topology.Error)"
}

$monitors = [System.Collections.Generic.List[object]]::new()
$items = [System.Collections.Generic.List[object]]::new()
$index = 0

foreach ($monitor in @($topology.Monitors)) {
    $index++
    $monitorId = "monitor-$index"
    $monitorName = if ($IncludeMonitorNames -and -not [string]::IsNullOrWhiteSpace([string]$monitor.FriendlyName)) {
        [string]$monitor.FriendlyName
    } else {
        "Monitor $index"
    }

    $monitors.Add([ordered]@{
        id = $monitorId
        name = $monitorName
        primary = [bool]$monitor.Primary
        monitorRect = [ordered]@{
            x = [int]$monitor.MonitorRect.x
            y = [int]$monitor.MonitorRect.y
            w = [int]$monitor.MonitorRect.w
            h = [int]$monitor.MonitorRect.h
        }
        workRect = [ordered]@{
            x = [int]$monitor.WorkRect.x
            y = [int]$monitor.WorkRect.y
            w = [int]$monitor.WorkRect.w
            h = [int]$monitor.WorkRect.h
        }
        scalePercent = if ($null -ne $monitor.ScalePercent) { [int]$monitor.ScalePercent } else { 100 }
    }) | Out-Null

    $work = $monitor.WorkRect
    $itemWidth = [Math]::Min(720, [Math]::Max(320, [int][Math]::Floor($work.w / 2) - 60))
    $itemHeight = [Math]::Min(520, [Math]::Max(240, [int][Math]::Floor($work.h / 2) - 60))

    for ($itemIndex = 0; $itemIndex -lt 2; $itemIndex++) {
        $x = [int]$work.x + 40 + $itemIndex * ($itemWidth + 20)
        $y = [int]$work.y + 40
        $items.Add([ordered]@{
            id = ('host-item-{0}-{1}' -f $index, ($itemIndex + 1))
            kind = $(if ($itemIndex -eq 0) { 'terminal' } else { 'app' })
            monitorId = $monitorId
            enabled = $true
            rect = [ordered]@{ x = $x; y = $y; w = $itemWidth; h = $itemHeight }
        }) | Out-Null
    }
}

$fixture = [ordered]@{
    name = 'host-topology-redacted'
    virtualScreenRect = [ordered]@{
        x = [int]$topology.VirtualScreenRect.x
        y = [int]$topology.VirtualScreenRect.y
        w = [int]$topology.VirtualScreenRect.w
        h = [int]$topology.VirtualScreenRect.h
    }
    monitors = @($monitors)
    items = @($items)
}

$outputFull = [IO.Path]::GetFullPath($OutputPath)
$directory = [IO.Path]::GetDirectoryName($outputFull)
if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$fixture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $outputFull -Encoding UTF8
Write-Output "wrote $outputFull"
Write-Output ("topology: {0} monitors, signature {1}" -f $monitors.Count, $topology.Signature)
