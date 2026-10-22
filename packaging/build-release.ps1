#requires -Version 7
[CmdletBinding()]
param(
    [string]$DotNetPath = 'dotnet',
    [string]$OutputDir = ''
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$BuildSetup = Join-Path $PSScriptRoot 'build-setup.ps1'
$VerifyRelease = Join-Path $PSScriptRoot 'verify-release.ps1'
$ProductPath = Join-Path $PSScriptRoot 'product.json'

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

Assert-Condition ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) 'build-release.ps1 requires Windows.'
Assert-Condition ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq [System.Runtime.InteropServices.Architecture]::X64) 'build-release.ps1 requires an x64 build host.'
Assert-Condition (Test-Path -LiteralPath $BuildSetup -PathType Leaf) "Setup build entry point not found: $BuildSetup"
Assert-Condition (Test-Path -LiteralPath $VerifyRelease -PathType Leaf) "Release verifier not found: $VerifyRelease"
Assert-Condition (Test-Path -LiteralPath $ProductPath -PathType Leaf) "Product identity not found: $ProductPath"

$sdkVersion = (& $DotNetPath --version 2>&1 | Out-String).Trim()
Assert-Condition ($LASTEXITCODE -eq 0 -and $sdkVersion -match '^10\.') "A .NET 10 SDK is required; found '$sdkVersion'."

$sourceSha = (& git -C $RepoRoot rev-parse HEAD 2>&1 | Out-String).Trim()
Assert-Condition ($LASTEXITCODE -eq 0 -and $sourceSha -match '^[0-9a-f]{40}$') 'Could not resolve an exact 40-character source commit.'
$sourceStatus = @(& git -C $RepoRoot status --porcelain=v1)
Assert-Condition ($sourceStatus.Count -eq 0) "The release-candidate build requires a clean worktree. Dirty paths: $($sourceStatus -join '; ')"

$product = Get-Content -LiteralPath $ProductPath -Raw | ConvertFrom-Json
$productVersion = [string]$product.version
$productId = [string]$product.productId
$displayName = [string]$product.displayName
$publisher = [string]$product.publisher
$sourceRepository = [string]$product.urlInfoAbout
Assert-Condition ($productVersion -match '^\d+\.\d+\.\d+$') "Product version '$productVersion' is not major.minor.patch."
Assert-Condition ($productId -eq 'ekinokss.DevWS') 'Production release builds must use the canonical product id.'
Assert-Condition ($displayName -eq 'DevWS') 'Production release builds must use the canonical display name.'
Assert-Condition ($publisher -eq 'ekinokss') 'Production release builds must use the canonical publisher.'
Assert-Condition ($sourceRepository -eq 'https://github.com/ekinokss/DevWS') 'Production release builds must use the canonical source repository.'

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path ([IO.Path]::GetTempPath()) ('devws-release-' + $productVersion + '-win-x64-' + $sourceSha.Substring(0, 12) + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}
$outputFull = [IO.Path]::GetFullPath($OutputDir).TrimEnd('\')
$repoFull = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
Assert-Condition (-not ($outputFull.Equals($repoFull, [StringComparison]::OrdinalIgnoreCase) -or $outputFull.StartsWith($repoFull + '\', [StringComparison]::OrdinalIgnoreCase))) 'The release candidate output must be outside the repository.'
if (Test-Path -LiteralPath $outputFull) {
    Assert-Condition (Test-Path -LiteralPath $outputFull -PathType Container) "Output path is not a directory: $outputFull"
    Assert-Condition (@(Get-ChildItem -LiteralPath $outputFull -Force).Count -eq 0) "The output directory must be empty: $outputFull"
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('devws-release-build-' + [guid]::NewGuid().ToString('N'))
$setupOutput = Join-Path $tempRoot 'setup'
$bundleTemp = Join-Path $tempRoot 'bundle'
$outputCreated = $false
$outputFiles = @('DevWS-Setup.exe', 'LICENSE', 'provenance.json', 'SHA256SUMS.txt')

try {
    New-Item -ItemType Directory -Path $setupOutput -Force | Out-Null
    New-Item -ItemType Directory -Path $bundleTemp -Force | Out-Null

    & $BuildSetup -DotNetPath $DotNetPath -OutputDir $setupOutput
    Assert-Condition ($LASTEXITCODE -eq 0) 'build-setup.ps1 failed while producing the release setup executable.'

    $setupExe = Join-Path $setupOutput 'DevWS-Setup.exe'
    Assert-Condition (Test-Path -LiteralPath $setupExe -PathType Leaf) 'build-setup.ps1 did not produce DevWS-Setup.exe.'
    $exeHash = (Get-FileHash -LiteralPath $setupExe -Algorithm SHA256).Hash.ToLowerInvariant()
    $exeSize = (Get-Item -LiteralPath $setupExe).Length

    $versionOutput = (& $setupExe --version 2>&1 | Out-String).Trim()
    Assert-Condition ($LASTEXITCODE -eq 0) 'DevWS-Setup.exe --version failed.'
    Assert-Condition ($versionOutput -match [regex]::Escape($displayName)) 'The setup version output does not identify the product display name.'
    Assert-Condition ($versionOutput -match [regex]::Escape($productVersion)) 'The setup version output does not identify the product version.'
    Assert-Condition ($versionOutput -match [regex]::Escape($sourceSha)) 'The setup executable source SHA does not match git HEAD.'

    Copy-Item -LiteralPath $setupExe -Destination (Join-Path $bundleTemp 'DevWS-Setup.exe') -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'LICENSE') -Destination (Join-Path $bundleTemp 'LICENSE') -Force

    $provenance = [ordered]@{
        schemaVersion = 1
        productId = $productId
        displayName = $displayName
        publisher = $publisher
        version = $productVersion
        architecture = 'x64'
        runtimeIdentifier = 'win-x64'
        sourceRepository = $sourceRepository
        sourceCommit = $sourceSha
        artifact = [ordered]@{
            file = 'DevWS-Setup.exe'
            sha256 = $exeHash
            sizeBytes = $exeSize
        }
        build = [ordered]@{
            configuration = 'Release'
            nativeAot = $true
            selfContained = $true
            dotnetSdk = $sdkVersion
        }
    }
    $provenanceJson = $provenance | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Join-Path $bundleTemp 'provenance.json'), $provenanceJson, [Text.UTF8Encoding]::new($false))

    $sumLines = foreach ($name in @('DevWS-Setup.exe', 'LICENSE', 'provenance.json')) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $bundleTemp $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name"
    }
    [IO.File]::WriteAllText((Join-Path $bundleTemp 'SHA256SUMS.txt'), (($sumLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

    & $VerifyRelease -BundleDir $bundleTemp -ExpectedSourceSha $sourceSha
    Assert-Condition ($LASTEXITCODE -eq 0) 'The assembled release candidate failed verification.'

    New-Item -ItemType Directory -Path $outputFull -Force | Out-Null
    $outputCreated = $true
    foreach ($name in $outputFiles) {
        Copy-Item -LiteralPath (Join-Path $bundleTemp $name) -Destination (Join-Path $outputFull $name) -Force
    }

    & $VerifyRelease -BundleDir $outputFull -ExpectedSourceSha $sourceSha
    Assert-Condition ($LASTEXITCODE -eq 0) 'The final release candidate failed verification.'

    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $outputFull 'DevWS-Setup.exe')
    Write-Output "[release] source commit: $sourceSha"
    Write-Output "[release] product version: $productVersion"
    Write-Output "[release] bundle: $outputFull"
    Write-Output "[release] DevWS-Setup.exe size: $exeSize bytes"
    Write-Output "[release] DevWS-Setup.exe SHA-256: $exeHash"
    Write-Output "[release] Authenticode: $($signature.Status)"
}
catch {
    if ($outputCreated) {
        foreach ($name in $outputFiles) {
            Remove-Item -LiteralPath (Join-Path $outputFull $name) -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $outputFull -PathType Container) {
            if (@(Get-ChildItem -LiteralPath $outputFull -Force).Count -eq 0) {
                Remove-Item -LiteralPath $outputFull -Force -ErrorAction SilentlyContinue
            }
        }
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
