#requires -Version 7
[CmdletBinding()]
param(
    [string]$DotNetPath = 'dotnet',
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$BuildScript = Join-Path $PSScriptRoot 'build-setup.ps1'
$ChecksProject = Join-Path $PSScriptRoot 'bootstrapper-checks\DevWS.Setup.Checks.csproj'
$BootstrapperProject = Join-Path $PSScriptRoot 'bootstrapper\DevWS.Setup.csproj'
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('devws-bootstrapper-tests-' + [guid]::NewGuid().ToString('N'))

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Contains([string]$Text, [string]$Needle, [string]$Message) {
    Assert-Condition ($Text.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) "$Message (missing '$Needle')"
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    Assert-Condition ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'test-bootstrapper.ps1 must run from an elevated PowerShell so fixture staging can be exercised.'

    New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
    $fixtureSource = Join-Path $TestRoot 'fixture-source'
    $fixtureZip = Join-Path $TestRoot 'fixture-payload.zip'
    $fixtureArtifact = Join-Path $TestRoot 'fixture-artifact'
    $fixtureOutput = Join-Path $TestRoot 'fixture-output'
    New-Item -ItemType Directory -Path $fixtureSource -Force | Out-Null
    New-Item -ItemType Directory -Path $fixtureOutput -Force | Out-Null

    $fixtureInstall = @'
param(
    [switch]$PackageMode,
    [switch]$Force,
    [switch]$ResetConfig,
    [switch]$Purge
)

$record = [ordered]@{
    packageMode = [bool]$PackageMode
    force = [bool]$Force
    resetConfig = [bool]$ResetConfig
    purge = [bool]$Purge
    cwd = (Get-Location).Path
    script = $PSCommandPath
    psMajor = $PSVersionTable.PSVersion.Major
}
[IO.File]::WriteAllText($env:DEVWS_SETUP_FIXTURE_OUTPUT, ($record | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
$exitCode = 0
if (-not [int]::TryParse($env:DEVWS_SETUP_FIXTURE_EXIT, [ref]$exitCode)) { $exitCode = 0 }
exit $exitCode
'@
    Set-Content -LiteralPath (Join-Path $fixtureSource 'install.ps1') -Value $fixtureInstall -Encoding utf8NoBOM
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($fixtureSource, $fixtureZip, [System.IO.Compression.CompressionLevel]::Optimal, $false)

    Write-Output '[test] Running bootstrapper source checks...'
    & $DotNetPath run --project $ChecksProject -c Release
    Assert-Condition ($LASTEXITCODE -eq 0) 'Bootstrapper source checks failed.'

    Write-Output '[test] Building fixture payload bootstrapper (Native AOT)...'
    & $BuildScript -DotNetPath $DotNetPath -Fixture -PayloadZip $fixtureZip -OutputDir $fixtureArtifact
    Assert-Condition ($LASTEXITCODE -eq 0) 'Fixture bootstrapper build failed.'

    $fixtureExe = Join-Path $fixtureArtifact 'DevWS-Setup.exe'
    Assert-Condition (Test-Path -LiteralPath $fixtureExe -PathType Leaf) 'Fixture DevWS-Setup.exe was not produced.'

    $helpRecord = Join-Path $fixtureOutput 'should-not-exist-help.json'
    $env:DEVWS_SETUP_FIXTURE_OUTPUT = $helpRecord
    $env:DEVWS_SETUP_FIXTURE_EXIT = '0'
    $helpOutput = & $fixtureExe --help 2>&1 | Out-String
    $helpCode = $LASTEXITCODE
    Assert-Condition ($helpCode -eq 0) "Fixture --help exited $helpCode instead of 0.`n$helpOutput"
    Assert-Contains $helpOutput 'Windows x64 thin setup bootstrapper' 'Fixture --help did not print its usage.'
    Assert-Condition (-not (Test-Path -LiteralPath $helpRecord)) 'Fixture --help unexpectedly staged or invoked install.ps1.'

    $badOutput = & $fixtureExe --bogus 2>&1 | Out-String
    $badCode = $LASTEXITCODE
    Assert-Condition ($badCode -eq 2) "Fixture malformed invocation exited $badCode instead of 2.`n$badOutput"
    Assert-Contains $badOutput 'Malformed DevWS-Setup invocation' 'Malformed invocation was not rejected explicitly.'
    Assert-Condition (-not (Test-Path -LiteralPath $helpRecord)) 'Malformed invocation unexpectedly staged or invoked install.ps1.'
    Write-Output 'PASS: --help and malformed invocations do not stage or install'

    $programFiles = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    $programFilesPwsh = Join-Path $programFiles 'PowerShell\7\pwsh.exe'
    $expectedPowerShell = $null
    if (Test-Path -LiteralPath $programFilesPwsh -PathType Leaf) {
        $version = (Get-Item -LiteralPath $programFilesPwsh).VersionInfo
        if ($version.FileMajorPart -ge 7 -or $version.ProductMajorPart -ge 7) {
            $expectedPowerShell = $programFilesPwsh
        }
    }
    if (-not $expectedPowerShell) {
        $package = @(Get-AppxPackage -Name 'Microsoft.PowerShell' | Select-Object -First 1)
        Assert-Condition ($package.Count -eq 1) 'No trusted PowerShell installation is available for fixture acceptance.'
        $expectedPowerShell = Join-Path $package[0].InstallLocation 'pwsh.exe'
    }

    $recordPath = Join-Path $fixtureOutput 'fixture-record-success.json'
    $output = & {
        $env:DEVWS_SETUP_FIXTURE_OUTPUT = $recordPath
        $env:DEVWS_SETUP_FIXTURE_EXIT = '0'
        & $fixtureExe 2>&1 | Out-String
    }
    $successCode = $LASTEXITCODE
    Assert-Condition ($successCode -eq 0) "Fixture success exited $successCode instead of 0.`n$output"
    Assert-Condition (Test-Path -LiteralPath $recordPath -PathType Leaf) 'Fixture install.ps1 did not record its invocation.'
    $record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json

    Assert-Condition ([bool]$record.packageMode) 'Fixture install.ps1 did not receive -PackageMode.'
    Assert-Condition (-not [bool]$record.force) 'Fixture install.ps1 received -Force.'
    Assert-Condition (-not [bool]$record.resetConfig) 'Fixture install.ps1 received -ResetConfig.'
    Assert-Condition (-not [bool]$record.purge) 'Fixture install.ps1 received -Purge.'
    Assert-Condition ([int]$record.psMajor -ge 7) 'Fixture install.ps1 did not run under PowerShell 7+.'
    Assert-Condition ([string]$record.script -eq (Join-Path ([string]$record.cwd) 'install.ps1')) 'Fixture install.ps1 did not run from the staged payload root.'
    Assert-Condition (([string]$record.cwd).StartsWith((Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'DevWS\setup-staging\'), [StringComparison]::OrdinalIgnoreCase)) 'Fixture staging was not under ProgramData\DevWS\setup-staging.'
    Assert-Condition (-not ([string]$record.cwd).StartsWith($env:TEMP, [StringComparison]::OrdinalIgnoreCase)) 'Fixture staging was under TEMP.'
    Assert-Condition (-not ([string]$record.cwd).StartsWith($env:LOCALAPPDATA, [StringComparison]::OrdinalIgnoreCase)) 'Fixture staging was under LOCALAPPDATA.'
    Assert-Contains $output '[setup] trusted PowerShell:' 'Bootstrapper did not report its trusted PowerShell.'
    Assert-Contains $output $expectedPowerShell 'Bootstrapper did not use the expected trusted PowerShell candidate.'
    Assert-Condition (-not (Test-Path -LiteralPath ([string]$record.cwd))) 'Fixture staging was not removed after success.'
    Assert-Condition (-not (Test-Path -LiteralPath ([string]$record.script))) 'Fixture install.ps1 remained after success.'

    $recordPath2 = Join-Path $fixtureOutput 'fixture-record-failure.json'
    $output2 = & {
        $env:DEVWS_SETUP_FIXTURE_OUTPUT = $recordPath2
        $env:DEVWS_SETUP_FIXTURE_EXIT = '23'
        & $fixtureExe 2>&1 | Out-String
    }
    $failureCode = $LASTEXITCODE
    Assert-Condition ($failureCode -eq 23) "Fixture failure exited $failureCode instead of 23.`n$output2"
    Assert-Condition (Test-Path -LiteralPath $recordPath2 -PathType Leaf) 'Failure fixture did not record its invocation.'
    $record2 = Get-Content -LiteralPath $recordPath2 -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Condition (-not (Test-Path -LiteralPath ([string]$record2.cwd))) 'Fixture staging was not removed after failure.'

    Write-Output 'PASS: fixture bootstrapper success and nonzero propagation paths'
    Write-Output 'PASS: fixture invocation is package-mode-only from protected ProgramData staging'
    Write-Output 'PASS: fixture staging cleanup completed on success and failure'
}
finally {
    Remove-Item Env:\DEVWS_SETUP_FIXTURE_OUTPUT -ErrorAction SilentlyContinue
    Remove-Item Env:\DEVWS_SETUP_FIXTURE_EXIT -ErrorAction SilentlyContinue

    foreach ($directory in @(
        (Join-Path $PSScriptRoot 'bootstrapper-checks\bin'),
        (Join-Path $PSScriptRoot 'bootstrapper-checks\obj'),
        (Join-Path $PSScriptRoot 'bootstrapper\bin'),
        (Join-Path $PSScriptRoot 'bootstrapper\obj')
    )) {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $TestRoot)) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    elseif ($KeepArtifacts) {
        Write-Output "[test] artifacts retained at $TestRoot"
    }
}
