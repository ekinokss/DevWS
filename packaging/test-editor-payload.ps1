param(
    [Parameter(Mandatory)][string]$PayloadZip,
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath($RepoRoot)
$zipPath = [IO.Path]::GetFullPath($PayloadZip)
$root = Join-Path $env:TEMP ('devws-p8-payload-test-' + [guid]::NewGuid().ToString('N'))
$passed = 0
$failed = [System.Collections.Generic.List[string]]::new()

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++ } else { $script:failed.Add($Message) | Out-Null }
}

. (Join-Path $repo 'src\lib\devws-paths.ps1')
. (Join-Path $repo 'src\lib\devws-config.ps1')
. (Join-Path $repo 'src\lib\devws-install.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $payload = Join-Path $root 'payload'
    [IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $payload)

    $editorRoot = Join-Path $payload 'editor'
    $manifestPath = Join-Path $editorRoot 'editor-payload.json'
    Assert-True (Test-Path $manifestPath -PathType Leaf) 'editor-payload.json is present'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-True ([int]$manifest.schemaVersion -eq 1) 'manifest schema version'
    Assert-True ([string]$manifest.sourceSha -match '^[0-9a-f]{40}$') 'manifest source SHA'
    Assert-True ([string]$manifest.targetFramework -eq 'net8.0-windows') 'manifest target framework'
    Assert-True ([string]$manifest.runtimeIdentifier -eq 'win-x64') 'manifest runtime identifier'
    Assert-True ([bool]$manifest.selfContained) 'manifest self-contained'
    Assert-True ([bool]$manifest.publishSingleFile -eq $false) 'manifest folder deployment'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$manifest.sdkVersion)) 'manifest records the SDK version'
    Assert-True (@($manifest.windowsDesktopRuntimes).Count -ge 1) 'manifest records the WindowsDesktop runtime'

    $manifestFiles = @($manifest.files)
    Assert-True ($manifestFiles.Count -ge 400) 'manifest file count is a full self-contained payload'
    $expected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $editorBytes = [long]0
    foreach ($entry in $manifestFiles) {
        $relative = [string]$entry.path
        $expected.Add($relative) | Out-Null
        $path = Join-Path $editorRoot $relative.Replace('/', '\')
        Assert-True (Test-Path $path -PathType Leaf) "manifest file exists: $relative"
        if (Test-Path $path -PathType Leaf) {
            $file = Get-Item -LiteralPath $path
            Assert-True ($file.Length -eq [long]$entry.size) "manifest size: $relative"
            Assert-True ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -eq [string]$entry.sha256) "manifest hash: $relative"
            $editorBytes += $file.Length
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $editorRoot -Recurse -File)) {
        $relative = $file.FullName.Substring($editorRoot.Length + 1).Replace('\', '/')
        if ($relative -ieq 'editor-payload.json') { continue }
        Assert-True ($expected.Contains($relative)) "unexpected editor file: $relative"
    }
    foreach ($required in @('DevWS.Editor.exe', 'DevWS.Editor.dll', 'DevWS.Editor.deps.json', 'DevWS.Editor.runtimeconfig.json', 'PresentationFramework.dll', 'ws-editor-backend.ps1', 'editor-projection.ps1')) {
        Assert-True ($expected.Contains($required)) "required editor file: $required"
    }
    foreach ($forbidden in @($manifestFiles | Where-Object { $_.path -match '(^|/)(tests|docs|bin|obj)(/|$)' -or $_.path -match '\.(pdb|cs|csproj|xaml)$' })) {
        Assert-True $false "forbidden editor file: $($forbidden.path)"
    }

    $installRoot = Join-Path $root 'install'
    $entries = @(Get-DevWSInstallManifest -RepoRoot $payload)
    $editorEntries = @($entries | Where-Object { $_.Target -like 'app\editor\*' })
    Assert-True ($editorEntries.Count -eq ($manifestFiles.Count + 1)) 'installer manifest parity for editor files'
    Assert-True (@($entries | Where-Object { $_.Target -eq 'app\editor\DevWS.Editor.exe' }).Count -eq 1) 'installer maps DevWS.Editor.exe to app\editor'
    Assert-True (@($entries | Where-Object { $_.Target -eq 'app\lib\devws-config.ps1' }).Count -eq 1) 'installer retains app\lib mapping'

    $installed = @(Install-DevWSApplicationFiles -RepoRoot $payload -InstallRoot $installRoot)
    $installedEditor = Join-Path $installRoot 'app\editor'
    Assert-True (Test-Path (Join-Path $installedEditor 'DevWS.Editor.exe')) 'installed editor executable'
    Assert-True (Test-Path (Join-Path $installedEditor 'ws-editor-backend.ps1')) 'installed editor backend'
    Assert-True (Test-Path (Join-Path $installRoot 'app\lib\devws-config.ps1')) 'installed app libraries'
    Assert-True (Test-DevWSEditorPayloadIntegrity -EditorRoot $installedEditor) 'installed editor payload integrity'
    Assert-True (@(Get-DevWSMissingInstalledFiles -RepoRoot $payload -InstallRoot $installRoot).Count -eq 0) 'no missing installed files'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $installRoot 'app') -Force | Where-Object { $_.Name -like '.editor-*' }).Count -eq 0) 'no editor staging debris'

    $exe = Join-Path $installedEditor 'DevWS.Editor.exe'
    Set-Content -LiteralPath $exe -Value 'corrupt' -Encoding ASCII
    Assert-True (-not (Test-DevWSEditorPayloadIntegrity -EditorRoot $installedEditor)) 'corruption detected'
    Assert-True (@(Get-DevWSMissingInstalledFiles -RepoRoot $payload -InstallRoot $installRoot).Count -ge 1) 'corruption reported as missing'
    Install-DevWSApplicationFiles -RepoRoot $payload -InstallRoot $installRoot | Out-Null
    Assert-True (Test-DevWSEditorPayloadIntegrity -EditorRoot $installedEditor) 'reinstall repairs corruption'

    Remove-Item -LiteralPath (Join-Path $installedEditor 'DevWS.Editor.dll') -Force
    Assert-True (@(Get-DevWSMissingInstalledFiles -RepoRoot $payload -InstallRoot $installRoot).Count -ge 1) 'missing dependency detected'
    Install-DevWSApplicationFiles -RepoRoot $payload -InstallRoot $installRoot | Out-Null
    Assert-True (Test-DevWSEditorPayloadIntegrity -EditorRoot $installedEditor) 'reinstall repairs a missing dependency'

    # A tampered source must fail before replacing the previously installed editor.
    $goodHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant()
    Add-Content -LiteralPath (Join-Path $editorRoot 'DevWS.Editor.dll') -Value 'tampered' -Encoding ASCII
    $threw = $false
    try { Install-DevWSApplicationFiles -RepoRoot $payload -InstallRoot $installRoot | Out-Null } catch { $threw = $true }
    Assert-True $threw 'tampered payload refused before promotion'
    Assert-True ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLowerInvariant() -eq $goodHash) 'tampered install preserved the prior editor'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $installRoot 'app') -Force | Where-Object { $_.Name -like '.editor-*' }).Count -eq 0) 'tampered install cleaned staging'

    # Source-mode manifest: no editor directory means no editor requirement.
    $sourceRoot = Join-Path $root 'source-mode'
    New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'src\lib') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'src\coordinator') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'src\shim') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'config') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $sourceRoot 'src\helpers') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'src\ws.ps1') -Destination (Join-Path $sourceRoot 'src\ws.ps1')
    Copy-Item -LiteralPath (Join-Path $repo 'src\coordinator\coordinator.ps1') -Destination (Join-Path $sourceRoot 'src\coordinator\coordinator.ps1')
    Copy-Item -LiteralPath (Join-Path $repo 'config\workspace.default.json') -Destination (Join-Path $sourceRoot 'config\workspace.default.json')
    Copy-Item -LiteralPath (Join-Path $repo 'src\shim\ws.cmd') -Destination (Join-Path $sourceRoot 'src\shim\ws.cmd')
    Copy-Item -LiteralPath (Join-Path $repo 'src\lib\devws-config.ps1') -Destination (Join-Path $sourceRoot 'src\lib\devws-config.ps1')
    $sourceEntries = @(Get-DevWSInstallManifest -RepoRoot $sourceRoot)
    Assert-True (@($sourceEntries | Where-Object { $_.Target -like 'app\editor\*' }).Count -eq 0) 'source mode has no editor payload requirement'

    $compressed = (Get-Item -LiteralPath $zipPath).Length
    $summary = [ordered]@{
        payloadZip = $zipPath
        payloadSha256 = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        payloadBytes = $compressed
        editorFiles = $manifestFiles.Count
        editorBytes = $editorBytes
        installedFiles = $installed.Count
        manifestEntries = $entries.Count
        passed = $passed
        failed = $failed.Count
        failures = @($failed)
    }
    $summary | ConvertTo-Json -Depth 8
    if ($failed.Count -gt 0) { exit 1 }
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
