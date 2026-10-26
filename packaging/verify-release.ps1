#requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundleDir,
    [string]$ExpectedSourceSha = '',
    # Test-only path for the release-license regression. It still requires the
    # exact inventory, provenance and checksums, but skips executable surfaces
    # so the regression does not need a Native AOT build. The release workflow
    # never passes this switch.
    [switch]$LicenseCheckOnly,
    # Optional signed-release policy. Unsigned release verification keeps the
    # historical behavior when this switch is absent.
    [switch]$RequireSignature,
    [string]$ExpectedSignerSubject = ''
)

$ErrorActionPreference = 'Stop'

if (-not $RequireSignature -and -not [string]::IsNullOrWhiteSpace($ExpectedSignerSubject)) {
    throw 'ExpectedSignerSubject requires RequireSignature.'
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ProductPath = Join-Path $PSScriptRoot 'product.json'
$ExpectedFiles = @('DevWS-Setup.exe', 'LICENSE', 'provenance.json', 'SHA256SUMS.txt')
$ChecksummedFiles = @('DevWS-Setup.exe', 'LICENSE', 'provenance.json')

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Test-ByteArrayEqual([byte[]]$Left, [byte[]]$Right) {
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [Convert]::ToHexString($sha.ComputeHash($Bytes)).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-CommittedGitBlob([string]$Commit, [string]$Path) {
    # git archive can apply checkout EOL conversion. Plumbing cat-file returns the
    # exact bytes of the committed blob and never reads the materialized worktree.
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = 'git'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    foreach ($argument in @('-C', $RepoRoot, 'cat-file', 'blob', "$Commit`:$Path")) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) { throw "Could not start git while reading committed '$Path'." }
    try {
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $memory = [System.IO.MemoryStream]::new()
        try {
            $process.StandardOutput.BaseStream.CopyTo($memory)
            $stderr = $stderrTask.GetAwaiter().GetResult()
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) {
                throw "Expected source commit '$Commit' cannot supply '$Path': $($stderr.Trim())"
            }
            return ,$memory.ToArray()
        }
        finally {
            $memory.Dispose()
        }
    }
    finally {
        $process.Dispose()
    }
}

if ([string]::IsNullOrWhiteSpace($ExpectedSourceSha)) {
    $status = @(& git -C $RepoRoot status --porcelain=v1)
    Assert-Condition ($status.Count -eq 0) 'ExpectedSourceSha was omitted and the worktree is not clean; refusing to infer a source SHA.'
    $ExpectedSourceSha = (& git -C $RepoRoot rev-parse HEAD 2>&1 | Out-String).Trim()
}
Assert-Condition ($ExpectedSourceSha -match '^[0-9a-f]{40}$') "ExpectedSourceSha is not a 40-character lowercase SHA: '$ExpectedSourceSha'."

$bundle = [IO.Path]::GetFullPath($BundleDir).TrimEnd('\')
Assert-Condition (Test-Path -LiteralPath $bundle -PathType Container) "Release bundle directory not found: $bundle"

$entries = @(Get-ChildItem -LiteralPath $bundle -Force)
$entryNames = @($entries | ForEach-Object { $_.Name })
Assert-Condition ($entries.Count -eq 4) "Release bundle must contain exactly four entries; found $($entries.Count)."
foreach ($expected in $ExpectedFiles) {
    Assert-Condition ($entryNames -contains $expected) "Release bundle is missing '$expected'."
    Assert-Condition (Test-Path -LiteralPath (Join-Path $bundle $expected) -PathType Leaf) "'$expected' must be a regular file."
}
foreach ($entry in $entries) {
    Assert-Condition ($ExpectedFiles -contains $entry.Name) "Unexpected release-bundle entry: $($entry.Name)"
}

$product = Get-Content -LiteralPath $ProductPath -Raw | ConvertFrom-Json
$version = [string]$product.version
$expectedRepository = [string]$product.urlInfoAbout
$expectedDisplayName = [string]$product.displayName
$expectedProductId = [string]$product.productId
$expectedPublisher = [string]$product.publisher
Assert-Condition ($version -match '^\d+\.\d+\.\d+$') "Product version '$version' is not major.minor.patch."

$provenancePath = Join-Path $bundle 'provenance.json'
$provenanceText = Get-Content -LiteralPath $provenancePath -Raw -Encoding UTF8
try {
    $provenance = $provenanceText | ConvertFrom-Json
}
catch {
    throw "provenance.json is not valid JSON: $($_.Exception.Message)"
}
Assert-Condition ([int]$provenance.schemaVersion -eq 1) 'provenance.schemaVersion must be 1.'
Assert-Condition ([string]$provenance.productId -eq $expectedProductId) 'provenance.productId does not match product.json.'
Assert-Condition ([string]$provenance.displayName -eq $expectedDisplayName) 'provenance.displayName does not match product.json.'
Assert-Condition ([string]$provenance.publisher -eq $expectedPublisher) 'provenance.publisher does not match product.json.'
Assert-Condition ([string]$provenance.version -eq $version) 'provenance.version does not match product.json.'
Assert-Condition ([string]$provenance.architecture -eq 'x64') 'provenance.architecture must be x64.'
Assert-Condition ([string]$provenance.runtimeIdentifier -eq 'win-x64') 'provenance.runtimeIdentifier must be win-x64.'
Assert-Condition ([string]$provenance.sourceRepository -eq $expectedRepository) 'provenance.sourceRepository does not match product.json.'
Assert-Condition ([string]$provenance.sourceCommit -eq $ExpectedSourceSha) 'provenance.sourceCommit does not match ExpectedSourceSha.'
Assert-Condition ([string]$provenance.artifact.file -eq 'DevWS-Setup.exe') 'provenance artifact file must be DevWS-Setup.exe.'
Assert-Condition ([string]$provenance.artifact.sha256 -match '^[0-9a-f]{64}$') 'provenance artifact SHA-256 is malformed.'
Assert-Condition ([long]$provenance.artifact.sizeBytes -gt 0) 'provenance artifact sizeBytes must be positive.'
Assert-Condition ([string]$provenance.build.configuration -eq 'Release') 'provenance build configuration must be Release.'
Assert-Condition ($provenance.build.nativeAot -eq $true) 'provenance nativeAot must be true.'
Assert-Condition ($provenance.build.selfContained -eq $true) 'provenance selfContained must be true.'
Assert-Condition ([string]$provenance.build.dotnetSdk -match '^10\.') 'provenance dotnetSdk must identify a .NET 10 SDK.'

$sumPath = Join-Path $bundle 'SHA256SUMS.txt'
$sumText = Get-Content -LiteralPath $sumPath -Raw -Encoding UTF8
$sumLines = @($sumText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
Assert-Condition ($sumLines.Count -eq 3) "SHA256SUMS.txt must contain exactly three checksum lines; found $($sumLines.Count)."

$recorded = [ordered]@{}
for ($index = 0; $index -lt $ChecksummedFiles.Count; $index++) {
    $name = $ChecksummedFiles[$index]
    $match = [regex]::Match($sumLines[$index], '^([0-9a-f]{64})  ([^ ]+)$')
    Assert-Condition $match.Success "SHA256SUMS.txt line $($index + 1) is not canonical lowercase '<hash>  <filename>' syntax."
    Assert-Condition ($match.Groups[2].Value -eq $name) "SHA256SUMS.txt line $($index + 1) must reference '$name'."
    $recorded[$name] = $match.Groups[1].Value
}

$actualHashes = [ordered]@{}
foreach ($name in $ChecksummedFiles) {
    $filePath = Join-Path $bundle $name
    $actual = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $actualHashes[$name] = $actual
    Assert-Condition ($recorded[$name] -eq $actual) "Checksum mismatch for '$name'."
}
Assert-Condition ($recorded['DevWS-Setup.exe'] -eq ([string]$provenance.artifact.sha256)) 'SHA256SUMS.txt EXE digest does not equal provenance.artifact.sha256.'
Assert-Condition ((Get-Item -LiteralPath (Join-Path $bundle 'DevWS-Setup.exe')).Length -eq [long]$provenance.artifact.sizeBytes) 'provenance.artifact.sizeBytes does not match DevWS-Setup.exe.'

$bundleLicenseBytes = [IO.File]::ReadAllBytes((Join-Path $bundle 'LICENSE'))
$committedLicenseBytes = Get-CommittedGitBlob -Commit $ExpectedSourceSha -Path 'LICENSE'
$bundleLicenseHash = Get-BytesSha256 $bundleLicenseBytes
$committedLicenseHash = Get-BytesSha256 $committedLicenseBytes
if (-not (Test-ByteArrayEqual $bundleLicenseBytes $committedLicenseBytes)) {
    throw "Release bundle LICENSE does not match the LICENSE committed at $ExpectedSourceSha (bundle: $($bundleLicenseBytes.Length) bytes, $bundleLicenseHash; committed: $($committedLicenseBytes.Length) bytes, $committedLicenseHash)."
}
Write-Output "[verify] committed LICENSE SHA-256: $committedLicenseHash"

$exePath = Join-Path $bundle 'DevWS-Setup.exe'
$signature = Get-AuthenticodeSignature -LiteralPath $exePath

if ($RequireSignature) {
    Assert-Condition ($signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid) "DevWS-Setup.exe does not have a valid Authenticode signature; status: $($signature.Status)."
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSignerSubject)) {
        $signerSubject = if ($null -ne $signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
        Assert-Condition ($signerSubject.IndexOf($ExpectedSignerSubject, [StringComparison]::OrdinalIgnoreCase) -ge 0) "DevWS-Setup.exe signer subject '$signerSubject' does not contain the expected '$ExpectedSignerSubject'."
    }
}

if ($LicenseCheckOnly) {
    if ($RequireSignature) { Write-Output "[verify] Authenticode: $($signature.Status)" }
    Write-Output '[verify] PASS (license-check-only; executable surfaces were not invoked)'
    return
}

$versionOutput = (& $exePath --version 2>&1 | Out-String).Trim()
Assert-Condition ($LASTEXITCODE -eq 0) 'DevWS-Setup.exe --version failed.'
Assert-Condition ($versionOutput.Contains($expectedDisplayName, [StringComparison]::Ordinal)) '--version does not identify the product display name.'
Assert-Condition ($versionOutput.Contains($version, [StringComparison]::Ordinal)) '--version does not identify the configured product version.'
Assert-Condition ($versionOutput.Contains($ExpectedSourceSha, [StringComparison]::Ordinal)) '--version does not identify the expected source SHA.'
$helpOutput = (& $exePath --help 2>&1 | Out-String)
Assert-Condition ($LASTEXITCODE -eq 0) 'DevWS-Setup.exe --help failed.'
Assert-Condition ($helpOutput -match 'Windows x64') '--help does not identify the x64 setup lifecycle surface.'

$fileVersion = (Get-Item -LiteralPath $exePath).VersionInfo
Assert-Condition ([string]$fileVersion.FileVersion -like "$version*") "EXE FileVersion '$($fileVersion.FileVersion)' does not represent $version."
Assert-Condition ([string]$fileVersion.ProductVersion -like "$version*") "EXE ProductVersion '$($fileVersion.ProductVersion)' does not represent $version."
Assert-Condition ([string]$fileVersion.ProductName -eq 'DevWS') "EXE ProductName '$($fileVersion.ProductName)' is not 'DevWS'."
Assert-Condition ([string]$fileVersion.CompanyName -eq 'ekinokss') "EXE CompanyName '$($fileVersion.CompanyName)' is not 'ekinokss'."
Assert-Condition ([string]$fileVersion.FileDescription -eq 'DevWS setup') "EXE FileDescription '$($fileVersion.FileDescription)' is not 'DevWS setup'."

$forbidden = [System.Collections.Generic.List[string]]::new()
foreach ($value in @(
    $RepoRoot,
    $env:USERPROFILE,
    $env:GITHUB_WORKSPACE,
    $env:RUNNER_WORKSPACE,
    'devws-base',
    'bc760f8d62f245ca4843ea660662c4862847f37e'
)) {
    if (-not [string]::IsNullOrWhiteSpace($value) -and -not $forbidden.Contains($value)) {
        $forbidden.Add($value)
    }
}
foreach ($name in $ExpectedFiles) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $bundle $name))
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    $utf16 = [Text.Encoding]::Unicode.GetString($bytes)
    $utf16be = [Text.Encoding]::BigEndianUnicode.GetString($bytes)
    foreach ($token in $forbidden) {
        Assert-Condition ($ascii.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -lt 0) "Release bundle '$name' contains local path/private marker '$token' (ASCII)."
        Assert-Condition ($utf16.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -lt 0) "Release bundle '$name' contains local path/private marker '$token' (UTF-16LE)."
        Assert-Condition ($utf16be.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -lt 0) "Release bundle '$name' contains local path/private marker '$token' (UTF-16BE)."
    }
}

Write-Output "[verify] source commit: $ExpectedSourceSha"
Write-Output "[verify] product version: $version"
Write-Output "[verify] artifacts: $($ExpectedFiles -join ', ')"
Write-Output "[verify] DevWS-Setup.exe SHA-256: $($actualHashes['DevWS-Setup.exe'])"
Write-Output "[verify] LICENSE SHA-256: $($actualHashes['LICENSE'])"
Write-Output "[verify] provenance SHA-256: $($actualHashes['provenance.json'])"
Write-Output "[verify] --version: $versionOutput"
Write-Output "[verify] Authenticode: $($signature.Status)"
Write-Output "[verify] PASS"
