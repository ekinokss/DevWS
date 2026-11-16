param(
    [string]$Project = (Join-Path $PSScriptRoot '..\DevWS.WpfSpike.csproj'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\results\publish-measurements.json'),
    [int]$StartupRuns = 5
)

$ErrorActionPreference = 'Stop'
$projectFull = [IO.Path]::GetFullPath($Project)
$outputFull = [IO.Path]::GetFullPath($OutputPath)
$root = Join-Path ([IO.Path]::GetTempPath()) ("devws-wpf-publish-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null

$results = [System.Collections.Generic.List[object]]::new()

function Get-LargestFiles {
    param([string]$Directory, [int]$Count = 5)
    Get-ChildItem -LiteralPath $Directory -Recurse -File |
        Sort-Object Length -Descending |
        Select-Object -First $Count |
        ForEach-Object {
            [ordered]@{
                name = $_.FullName.Substring($Directory.Length).TrimStart('\')
                bytes = $_.Length
            }
        }
}

function Invoke-Publish {
    param(
        [string]$Name,
        [string]$RequiredRuntime,
        [string[]]$Arguments
    )

    $outDir = Join-Path $root $Name
    $logPath = Join-Path $root "$Name.log"
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    $publishArgs = @(
        'publish', $projectFull,
        '-c', 'Release',
        '-r', 'win-x64',
        '-o', $outDir
    ) + $Arguments

    & dotnet @publishArgs *> $logPath
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $results.Add([ordered]@{
            name = $Name
            ok = $false
            exitCode = $exitCode
            log = $logPath
            requiredRuntime = $RequiredRuntime
        }) | Out-Null
        return
    }

    $files = @(Get-ChildItem -LiteralPath $outDir -Recurse -File)
    $totalBytes = [long](($files | Measure-Object Length -Sum).Sum)
    $exe = Get-ChildItem -LiteralPath $outDir -File -Filter 'DevWS.WpfSpike.exe' | Select-Object -First 1
    $zipPath = Join-Path $root "$Name.zip"
    Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force
    $zipBytes = (Get-Item -LiteralPath $zipPath).Length

    $startup = $null
    if ($null -ne $exe -and $StartupRuns -gt 0) {
        $startupPath = Join-Path $root "$Name-startup.json"
        try {
            & pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Measure-Startup.ps1') `
                -Exe $exe.FullName `
                -Fixture (Join-Path $PSScriptRoot '..\Fixtures\two-monitors-10-items.json') `
                -Runs $StartupRuns `
                -ExitAfterMs 800 `
                -OutputPath $startupPath *> (Join-Path $root "$Name-startup.log")
            if (Test-Path -LiteralPath $startupPath) {
                $startup = Get-Content -LiteralPath $startupPath -Raw | ConvertFrom-Json
            }
        }
        catch {
            $startup = [ordered]@{ error = $_.Exception.Message }
        }
    }

    $results.Add([ordered]@{
        name = $Name
        ok = $true
        requiredRuntime = $RequiredRuntime
        outputDirectory = $outDir
        fileCount = $files.Count
        totalBytes = $totalBytes
        totalMB = [Math]::Round($totalBytes / 1MB, 2)
        zipBytes = $zipBytes
        zipMB = [Math]::Round($zipBytes / 1MB, 2)
        largestFiles = @(Get-LargestFiles -Directory $outDir)
        executable = if ($null -ne $exe) { $exe.FullName } else { $null }
        executableSha256 = if ($null -ne $exe) { (Get-FileHash -LiteralPath $exe.FullName -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
        zipSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        startup = $startup
    }) | Out-Null
}

Invoke-Publish -Name 'framework-dependent' -RequiredRuntime '.NET Desktop Runtime 8.0 (x64)' -Arguments @(
    '--self-contained', 'false',
    '-p:PublishSingleFile=false'
)

Invoke-Publish -Name 'self-contained-folder' -RequiredRuntime 'None' -Arguments @(
    '--self-contained', 'true',
    '-p:PublishSingleFile=false'
)

Invoke-Publish -Name 'self-contained-single-file' -RequiredRuntime 'None' -Arguments @(
    '--self-contained', 'true',
    '-p:PublishSingleFile=true',
    '-p:IncludeNativeLibrariesForSelfExtract=true'
)

$currentInstallerBytes = 3231744
$report = [ordered]@{
    generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    project = $projectFull
    publishRoot = $root
    currentInstallerBytes = $currentInstallerBytes
    currentInstallerMB = [Math]::Round($currentInstallerBytes / 1MB, 2)
    results = @($results)
}

$directory = [IO.Path]::GetDirectoryName($outputFull)
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $outputFull -Encoding UTF8
Write-Output "wrote $outputFull"
Write-Output "publish root: $root"
foreach ($result in $results) {
    if ($result.ok) {
        Write-Output ("{0}: files={1}, total={2} MB, zip={3} MB, startupMedian={4} ms, wsMedian={5} MB" -f $result.name, $result.fileCount, $result.totalMB, $result.zipMB, $result.startup.summary.processReadyMs.median, $result.startup.summary.workingSetMB.median)
    }
    else {
        Write-Output ("{0}: FAILED exit={1}" -f $result.name, $result.exitCode)
    }
}
