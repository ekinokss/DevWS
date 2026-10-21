#requires -Version 7
[CmdletBinding()]
param(
    [string]$DotNetPath = 'dotnet',
    [string]$OutputDir = '',
    [string]$PayloadZip = '',
    [switch]$Fixture,
    [string]$ProductVersion = '',
    [string]$ProductId = '',
    [string]$DisplayName = '',
    [string]$ProgramFilesRootLeaf = '',
    [string]$InstallRootLeaf = ''
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ProjectPath = Join-Path $PSScriptRoot 'bootstrapper\DevWS.Setup.csproj'
$ProductPath = Join-Path $PSScriptRoot 'product.json'

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

Assert-Condition ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) 'build-setup.ps1 requires Windows.'
Assert-Condition ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq [System.Runtime.InteropServices.Architecture]::X64) 'build-setup.ps1 requires an x64 build host.'

$sdkVersion = (& $DotNetPath --version 2>&1 | Out-String).Trim()
Assert-Condition ($LASTEXITCODE -eq 0) "The .NET SDK command failed: $DotNetPath --version"
Assert-Condition ($sdkVersion -match '^10\.') "DevWS-Setup requires the .NET 10 SDK; found '$sdkVersion' from '$DotNetPath'."
Assert-Condition (Test-Path -LiteralPath $ProjectPath -PathType Leaf) "Bootstrapper project not found: $ProjectPath"

$sourceSha = (& git -C $RepoRoot rev-parse HEAD 2>&1 | Out-String).Trim()
Assert-Condition ($LASTEXITCODE -eq 0 -and $sourceSha -match '^[0-9a-f]{40}$') "Could not resolve the source commit."
$sourceStatus = @(& git -C $RepoRoot status --porcelain=v1)
$isFixture = -not [string]::IsNullOrWhiteSpace($PayloadZip)

if ($isFixture -and -not $Fixture) {
    throw 'A custom PayloadZip is accepted only with the explicit -Fixture switch.'
}
if ($Fixture -and -not $isFixture) {
    throw '-Fixture requires -PayloadZip.'
}
if (-not $isFixture -and $sourceStatus.Count -gt 0) {
    throw "The production setup build requires a clean committed worktree. Dirty paths: $($sourceStatus -join '; ')"
}

Assert-Condition (Test-Path -LiteralPath $ProductPath -PathType Leaf) "Product identity not found: $ProductPath"
$product = Get-Content -LiteralPath $ProductPath -Raw | ConvertFrom-Json

if ($isFixture) {
    foreach ($item in @(
        @{ Name = 'ProductVersion'; Value = $ProductVersion },
        @{ Name = 'ProductId'; Value = $ProductId },
        @{ Name = 'DisplayName'; Value = $DisplayName },
        @{ Name = 'ProgramFilesRootLeaf'; Value = $ProgramFilesRootLeaf },
        @{ Name = 'InstallRootLeaf'; Value = $InstallRootLeaf }
    )) {
        Assert-Condition (-not [string]::IsNullOrWhiteSpace($item.Value)) "Fixture builds require -$($item.Name)."
    }
    Assert-Condition ($ProductId -ne [string]$product.productId) 'Fixture ProductId must differ from the production product id.'
    Assert-Condition ($ProgramFilesRootLeaf -ne [string]$product.programFilesRootLeaf) 'Fixture Program Files root must differ from production.'
    Assert-Condition ($InstallRootLeaf -ne [string]$product.installRootLeaf) 'Fixture install root must differ from production.'
}
else {
    foreach ($item in @($ProductVersion, $ProductId, $DisplayName, $ProgramFilesRootLeaf, $InstallRootLeaf)) {
        Assert-Condition ([string]::IsNullOrWhiteSpace($item)) 'Product identity overrides are accepted only with -Fixture.'
    }

    $ProductVersion = [string]$product.version
    $ProductId = [string]$product.productId
    $DisplayName = [string]$product.displayName
    $ProgramFilesRootLeaf = [string]$product.programFilesRootLeaf
    $InstallRootLeaf = [string]$product.installRootLeaf
}

Assert-Condition ($ProductVersion -match '^\d+\.\d+\.\d+$') "Product version '$ProductVersion' is not major.minor.patch."
Assert-Condition ($ProductId -match '^[A-Za-z0-9._-]+$') "Product id '$ProductId' contains unsupported characters."
Assert-Condition ($ProgramFilesRootLeaf -notmatch '[\\/]' -and $ProgramFilesRootLeaf -notin @('.', '..')) 'ProgramFilesRootLeaf is not a safe leaf.'
Assert-Condition ($InstallRootLeaf -notmatch '[\\/]' -and $InstallRootLeaf -notin @('.', '..')) 'InstallRootLeaf is not a safe leaf.'

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path ([IO.Path]::GetTempPath()) ('devws-setup-artifact-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}

$repoFull = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
$outputFull = [IO.Path]::GetFullPath($OutputDir).TrimEnd('\')
Assert-Condition (-not ($outputFull.Equals($repoFull, [StringComparison]::OrdinalIgnoreCase) -or $outputFull.StartsWith($repoFull + '\', [StringComparison]::OrdinalIgnoreCase))) 'The setup artifact output must be outside the repository.'

$buildRoot = Join-Path ([IO.Path]::GetTempPath()) ('devws-setup-build-' + [guid]::NewGuid().ToString('N'))
$payloadRoot = Join-Path $buildRoot 'payload'
$objRoot = Join-Path $buildRoot 'obj\'
$binRoot = Join-Path $buildRoot 'bin\'
$payloadFile = $null

try {
    New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Assert-Condition (@(Get-ChildItem -LiteralPath $OutputDir -Force).Count -eq 0) "The output directory must be empty: $OutputDir"

    if ($isFixture) {
        $payloadFile = [IO.Path]::GetFullPath($PayloadZip)
        Assert-Condition (Test-Path -LiteralPath $payloadFile -PathType Leaf) "Fixture payload not found: $payloadFile"
    }
    else {
        $payloadFile = Join-Path $payloadRoot 'payload.zip'
        & git -C $RepoRoot archive --format=zip --output=$payloadFile HEAD -- install.ps1 uninstall.ps1 LICENSE src config
        Assert-Condition ($LASTEXITCODE -eq 0) 'git archive failed while building the setup payload.'
    }

    # Read the payload to prove the payload allowlist and required installer
    # entry are present without extracting it into the repository.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($payloadFile)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    }
    finally {
        $zip.Dispose()
    }

    Assert-Condition ($names -contains 'install.ps1') 'The payload does not contain install.ps1.'
    if (-not $isFixture) {
        foreach ($requiredPrefix in @('src/', 'config/')) {
            Assert-Condition (@($names | Where-Object { $_.StartsWith($requiredPrefix, [StringComparison]::Ordinal) }).Count -gt 0) "The payload does not contain $requiredPrefix."
        }
    }
    foreach ($forbiddenPrefix in @('.git/', '.github/', 'tests/', 'docs/')) {
        Assert-Condition (@($names | Where-Object { $_.StartsWith($forbiddenPrefix, [StringComparison]::Ordinal) }).Count -eq 0) "The payload unexpectedly contains $forbiddenPrefix."
    }

    $sourceIdentity = if ($isFixture) { $sourceSha + '-fixture' } else { $sourceSha }
    $publishArguments = @(
        'publish', $ProjectPath,
        '-c', 'Release',
        '-r', 'win-x64',
        '-o', $OutputDir,
        '-p:PublishAot=true',
        '-p:SelfContained=true',
        "-p:DevWSPayloadZip=$payloadFile",
        "-p:DevWSSourceSha=$sourceIdentity",
        "-p:DevWSProductId=$ProductId",
        "-p:DevWSDisplayName=$DisplayName",
        "-p:DevWSPublisher=$($product.publisher)",
        "-p:DevWSProductVersion=$ProductVersion",
        "-p:DevWSProgramFilesRootLeaf=$ProgramFilesRootLeaf",
        "-p:DevWSInstallRootLeaf=$InstallRootLeaf",
        "-p:DevWSURLInfoAbout=$($product.urlInfoAbout)",
        "-p:Version=$ProductVersion",
        "-p:BaseIntermediateOutputPath=$objRoot",
        "-p:BaseOutputPath=$binRoot"
    )

    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    & $DotNetPath @publishArguments
    Assert-Condition ($LASTEXITCODE -eq 0) 'dotnet publish failed for DevWS-Setup.exe.'

    $executables = @(Get-ChildItem -LiteralPath $OutputDir -Filter '*.exe' -File)
    Assert-Condition ($executables.Count -eq 1) "Expected exactly one executable in the artifact directory; found $($executables.Count)."
    Assert-Condition ($executables[0].Name -eq 'DevWS-Setup.exe') "Unexpected executable name '$($executables[0].Name)'."

    # Native AOT symbol files are not part of the setup artifact.
    Get-ChildItem -LiteralPath $OutputDir -File | Where-Object { $_.Extension -in @('.pdb', '.dbg') } | Remove-Item -Force

    $artifact = $executables[0].FullName
    $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash
    $size = (Get-Item -LiteralPath $artifact).Length

    Write-Output "[setup-build] source commit: $sourceSha"
    Write-Output "[setup-build] source identity embedded: $sourceIdentity"
    Write-Output "[setup-build] product id: $ProductId"
    Write-Output "[setup-build] product version: $ProductVersion"
    Write-Output "[setup-build] display name: $DisplayName"
    Write-Output "[setup-build] Program Files root leaf: $ProgramFilesRootLeaf"
    Write-Output "[setup-build] build mode: $(if ($isFixture) { 'fixture payload' } else { 'production payload' })"
    Write-Output "[setup-build] .NET SDK: $sdkVersion"
    Write-Output "[setup-build] host architecture: win-x64"
    Write-Output "[setup-build] artifact: $artifact"
    Write-Output "[setup-build] size: $size bytes"
    Write-Output "[setup-build] SHA-256: $hash"
}
finally {
    foreach ($directory in @($objRoot, $binRoot, $buildRoot)) {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
