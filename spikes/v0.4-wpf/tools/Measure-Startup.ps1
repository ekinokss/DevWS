param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Fixture,
    [int]$Runs = 10,
    [int]$ExitAfterMs = 1200,
    [switch]$Interaction,
    [int]$Frames = 120,
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\results\startup.json')
)

$ErrorActionPreference = 'Stop'
$exeFull = [IO.Path]::GetFullPath($Exe)
$fixtureFull = [IO.Path]::GetFullPath($Fixture)

if (-not (Test-Path -LiteralPath $exeFull -PathType Leaf)) { throw "Executable not found: $exeFull" }
if (-not (Test-Path -LiteralPath $fixtureFull -PathType Leaf)) { throw "Fixture not found: $fixtureFull" }

function Invoke-MediumRun {
    param([int]$Index)

    $runRoot = Join-Path ([IO.Path]::GetTempPath()) ("devws-wpf-run-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $logPath = Join-Path $runRoot 'result.json'
    $cmdPath = Join-Path $runRoot 'run.cmd'

    $mode = if ($Interaction) { '--interaction-benchmark' } else { '--benchmark' }
    $arguments = @(
        $mode,
        '--fixture', "`"$fixtureFull`"",
        '--exit-after-ms', $ExitAfterMs,
        '--frames', $Frames,
        '--log', "`"$logPath`""
    ) -join ' '

    $content = "@echo off`r`n`"$exeFull`" $arguments`r`nexit /b"
    Set-Content -LiteralPath $cmdPath -Value $content -Encoding ASCII

    # Explorer launches the batch file with the interactive user's medium token.
    & explorer.exe $cmdPath

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $logPath)) {
        Start-Sleep -Milliseconds 100
    }

    if (-not (Test-Path -LiteralPath $logPath)) {
        return [pscustomobject]@{
            index = $Index
            ok = $false
            error = 'benchmark log not created'
            runRoot = $runRoot
        }
    }

    $result = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json
    $result | Add-Member -NotePropertyName index -NotePropertyValue $Index -Force
    $result | Add-Member -NotePropertyName ok -NotePropertyValue $true -Force
    $result | Add-Member -NotePropertyName runRoot -NotePropertyValue $runRoot -Force
    return $result
}

function Get-Summary {
    param($Values)

    $numbers = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($numbers.Count -eq 0) { return $null }
    $mid = [int][Math]::Floor($numbers.Count / 2)
    $median = if ($numbers.Count % 2 -eq 0) { ($numbers[$mid - 1] + $numbers[$mid]) / 2 } else { $numbers[$mid] }
    return [ordered]@{
        count = $numbers.Count
        median = [Math]::Round($median, 2)
        min = [Math]::Round($numbers[0], 2)
        max = [Math]::Round($numbers[-1], 2)
    }
}

$measurements = [System.Collections.Generic.List[object]]::new()
$firstRun = $null

if ($Runs -gt 0) {
    $firstRun = Invoke-MediumRun -Index 0
}

for ($index = 1; $index -le $Runs; $index++) {
    $measurements.Add((Invoke-MediumRun -Index $index)) | Out-Null
}

$all = @($measurements)
$summary = [ordered]@{
    processReadyMs = Get-Summary ($all | ForEach-Object { $_.processReadyMs })
    canvasReadyMs = Get-Summary ($all | ForEach-Object { $_.canvasReadyMs })
    workingSetMB = Get-Summary ($all | ForEach-Object { $_.workingSetMB })
    cpuTotalMs = Get-Summary ($all | ForEach-Object { $_.cpuTotalMs })
}

if ($Interaction) {
    $summary['interactionElapsedMs'] = Get-Summary ($all | ForEach-Object { $_.interaction.elapsedMs })
    $summary['interactionWorkingSetDeltaMB'] = Get-Summary ($all | ForEach-Object {
        if ($null -ne $_.interaction) {
            ([double]$_.interaction.workingSetAfterBytes - [double]$_.interaction.workingSetBeforeBytes) / 1MB
        }
    })
    $summary['interactionCpuDeltaMs'] = Get-Summary ($all | ForEach-Object {
        if ($null -ne $_.interaction) { [double]$_.interaction.cpuAfterMs - [double]$_.interaction.cpuBeforeMs }
    })
}

$report = [ordered]@{
    generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    mode = if ($Interaction) { 'interaction' } else { 'startup' }
    exe = $exeFull
    fixture = $fixtureFull
    launch = 'explorer.exe batch wrapper (interactive user token)'
    runs = $Runs
    exitAfterMs = $ExitAfterMs
    frames = if ($Interaction) { $Frames } else { $null }
    firstRun = $firstRun
    measurements = $all
    summary = $summary
}

$outputFull = [IO.Path]::GetFullPath($OutputPath)
$directory = [IO.Path]::GetDirectoryName($outputFull)
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outputFull -Encoding UTF8
Write-Output "wrote $outputFull"
Write-Output ("integrity values: " + (($all | ForEach-Object { $_.integrity } | Sort-Object -Unique) -join ', '))
Write-Output ("processReady median: {0} ms; canvasReady median: {1} ms; working set median: {2} MB" -f $summary.processReadyMs.median, $summary.canvasReadyMs.median, $summary.workingSetMB.median)
