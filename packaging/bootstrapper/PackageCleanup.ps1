#requires -Version 7
param(
    [Parameter(Mandatory)][int]$ParentPid,
    [Parameter(Mandatory)][string]$SetupDirectory,
    [Parameter(Mandatory)][string]$ProgramFilesRoot,
    [Parameter(Mandatory)][string]$RootLeaf,
    [Parameter(Mandatory)][string]$Sid,
    [Parameter(Mandatory)][string]$StagingRoot
)

$ErrorActionPreference = 'Stop'

$programFiles = [IO.Path]::GetFullPath($ProgramFilesRoot).TrimEnd('\')
$expectedSetup = [IO.Path]::GetFullPath(
    (Join-Path $programFiles (Join-Path $RootLeaf (Join-Path 'setup' $Sid)))
).TrimEnd('\')
$actualSetup = [IO.Path]::GetFullPath($SetupDirectory).TrimEnd('\')
if (-not $actualSetup.Equals($expectedSetup, [StringComparison]::OrdinalIgnoreCase)) {
    exit 2
}

$stagingBase = [IO.Path]::GetFullPath(
    (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'DevWS\setup-staging')
).TrimEnd('\')
$stagingFull = [IO.Path]::GetFullPath($StagingRoot).TrimEnd('\')
if (-not $stagingFull.StartsWith($stagingBase + '\', [StringComparison]::OrdinalIgnoreCase)) {
    exit 3
}
if ((Split-Path -Leaf $stagingFull) -notmatch '^[0-9a-f]{32}$') {
    exit 3
}

for ($attempt = 0; $attempt -lt 240; $attempt++) {
    if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) {
        break
    }
    Start-Sleep -Milliseconds 250
}

function Remove-PackageTree([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing reparse point in package cleanup: $Path"
    }

    if ($item.PSIsContainer) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force)) {
            Remove-PackageTree $child.FullName
        }
        Remove-Item -LiteralPath $Path -Force
    }
    else {
        Remove-Item -LiteralPath $Path -Force
    }
}

try {
    Remove-PackageTree $actualSetup

    $setupParent = Join-Path $programFiles (Join-Path $RootLeaf 'setup')
    if (Test-Path -LiteralPath $setupParent) {
        $setupItem = Get-Item -LiteralPath $setupParent -Force
        if (($setupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
            @(Get-ChildItem -LiteralPath $setupParent -Force).Count -eq 0) {
            Remove-Item -LiteralPath $setupParent -Force
        }
    }

    $rootLeafPath = Join-Path $programFiles $RootLeaf
    if (Test-Path -LiteralPath $rootLeafPath) {
        $rootItem = Get-Item -LiteralPath $rootLeafPath -Force
        if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
            @(Get-ChildItem -LiteralPath $rootLeafPath -Force).Count -eq 0) {
            Remove-Item -LiteralPath $rootLeafPath -Force
        }
    }

    foreach ($child in @(Get-ChildItem -LiteralPath $stagingFull -Force)) {
        Remove-PackageTree $child.FullName
    }
    Remove-Item -LiteralPath $stagingFull -Force

    $stagingParent = Split-Path -Parent $stagingFull
    if (Test-Path -LiteralPath $stagingParent) {
        $stagingItem = Get-Item -LiteralPath $stagingParent -Force
        if (($stagingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
            @(Get-ChildItem -LiteralPath $stagingParent -Force).Count -eq 0) {
            Remove-Item -LiteralPath $stagingParent -Force
        }
    }
}
catch {
    exit 1
}

exit 0
