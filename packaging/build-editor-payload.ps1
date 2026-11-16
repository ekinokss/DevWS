#requires -Version 7
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [Parameter(Mandatory)][string]$OutputZip,
    [string]$DotNetPath = 'dotnet'
)

$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
$output = [IO.Path]::GetFullPath($OutputZip)
$editorProject = Join-Path $repo 'src\editor\gui\DevWS.Editor.csproj'
$backend = Join-Path $repo 'src\editor\ws-editor-backend.ps1'
$projection = Join-Path $repo 'src\editor\editor-projection.ps1'

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

Assert-Condition ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) 'The editor payload requires Windows.'
Assert-Condition ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq [Runtime.InteropServices.Architecture]::X64) 'The editor payload requires an x64 build host.'
Assert-Condition (Test-Path -LiteralPath $editorProject -PathType Leaf) "Editor project not found: $editorProject"
Assert-Condition (Test-Path -LiteralPath $backend -PathType Leaf) "Editor backend not found: $backend"
Assert-Condition (Test-Path -LiteralPath $projection -PathType Leaf) "Editor projection helper not found: $projection"
Assert-Condition (-not ($output.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase))) 'The payload output must be outside the repository.'

$sourceSha = (& git -C $repo rev-parse HEAD 2>&1 | Out-String).Trim()
Assert-Condition ($LASTEXITCODE -eq 0 -and $sourceSha -match '^[0-9a-f]{40}$') 'Could not resolve the committed source SHA.'
$sdkVersion = (& $DotNetPath --version 2>&1 | Out-String).Trim()
Assert-Condition ($LASTEXITCODE -eq 0) 'dotnet --version failed.'
$runtimes = @(& $DotNetPath --list-runtimes 2>&1 | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^Microsoft\.WindowsDesktop\.App 8\.' })
Assert-Condition ($runtimes.Count -ge 1) 'No Microsoft.WindowsDesktop.App 8.x runtime is available to publish the editor.'

$buildRoot = Join-Path ([IO.Path]::GetTempPath()) ('devws-editor-payload-' + [guid]::NewGuid().ToString('N'))
$publishRoot = Join-Path $buildRoot 'editor'
$baseZip = Join-Path $buildRoot 'base.zip'

try {
    New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null
    $outputDirectory = Split-Path -Parent $output
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) { New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null }
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }

    & git -C $repo archive --format=zip --output=$baseZip HEAD -- install.ps1 uninstall.ps1 LICENSE src config
    Assert-Condition ($LASTEXITCODE -eq 0) 'git archive failed while constructing the editor payload base.'

    $publishArgs = @(
        'publish', $editorProject,
        '-c', 'Release',
        '-r', 'win-x64',
        '--self-contained', 'true',
        '-p:PublishSingleFile=false',
        '-p:DebugType=None',
        '-p:DebugSymbols=false',
        '-o', $publishRoot
    )
    & $DotNetPath @publishArgs
    Assert-Condition ($LASTEXITCODE -eq 0) 'dotnet publish failed for the production WPF editor.'

    foreach ($script in @($backend, $projection)) {
        Copy-Item -LiteralPath $script -Destination (Join-Path $publishRoot (Split-Path -Leaf $script)) -Force
    }

    Get-ChildItem -LiteralPath $publishRoot -Recurse -File | Where-Object { $_.Extension -in @('.pdb', '.dbg') } | Remove-Item -Force

    foreach ($required in @('DevWS.Editor.exe', 'DevWS.Editor.dll', 'DevWS.Editor.deps.json', 'DevWS.Editor.runtimeconfig.json', 'PresentationFramework.dll', 'PresentationCore.dll', 'ws-editor-backend.ps1', 'editor-projection.ps1')) {
        Assert-Condition (Test-Path -LiteralPath (Join-Path $publishRoot $required) -PathType Leaf) "The published editor payload is missing required file '$required'."
    }
    foreach ($forbidden in @('*.pdb', '*.xml', '*.cs', '*.csproj', '*.xaml', 'bin', 'obj', 'tests')) {
        $hits = @(Get-ChildItem -LiteralPath $publishRoot -Recurse -Force | Where-Object { $_.Name -like $forbidden })
        Assert-Condition ($hits.Count -eq 0) "The published editor payload contains forbidden development content '$forbidden'."
    }

    $files = @(Get-ChildItem -LiteralPath $publishRoot -Recurse -File | Sort-Object FullName)
    $inventory = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($publishRoot.Length + 1).Replace('\', '/')
        $inventory.Add([ordered]@{
            path   = $relative
            size   = [long]$file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }) | Out-Null
    }

    $manifest = [ordered]@{
        schemaVersion       = 1
        sourceSha           = $sourceSha
        targetFramework     = 'net8.0-windows'
        runtimeIdentifier   = 'win-x64'
        selfContained       = $true
        publishSingleFile   = $false
        sdkVersion          = $sdkVersion
        windowsDesktopRuntimes = $runtimes
        files               = @($inventory.ToArray())
    }
    $manifestPath = Join-Path $publishRoot 'editor-payload.json'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    Copy-Item -LiteralPath $baseZip -Destination $output -Force
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($output, [System.IO.Compression.ZipArchiveMode]::Update)
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $publishRoot -Recurse -File | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($publishRoot.Length + 1).Replace('\', '/')
            $entryName = 'editor/' + $relative
            $entry = $zip.GetEntry($entryName)
            if ($null -ne $entry) { $entry.Delete() }
            $created = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip,
                $file.FullName,
                $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal)
            $created.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
        }
    }
    finally {
        $zip.Dispose()
    }

    $verify = [System.IO.Compression.ZipFile]::OpenRead($output)
    try {
        $names = @($verify.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    }
    finally {
        $verify.Dispose()
    }
    Assert-Condition ($names -contains 'install.ps1' -and $names -contains 'uninstall.ps1') 'The payload is missing the lifecycle scripts.'
    foreach ($required in @('editor/DevWS.Editor.exe', 'editor/DevWS.Editor.dll', 'editor/ws-editor-backend.ps1', 'editor/editor-projection.ps1', 'editor/editor-payload.json')) {
        Assert-Condition ($names -contains $required) "The payload is missing '$required'."
    }
    foreach ($forbiddenPrefix in @('editor/tests/', 'editor/docs/', 'editor/bin/', 'editor/obj/')) {
        Assert-Condition (@($names | Where-Object { $_.StartsWith($forbiddenPrefix, [StringComparison]::Ordinal) }).Count -eq 0) "The payload unexpectedly contains $forbiddenPrefix."
    }

    $compressedLength = (Get-Item -LiteralPath $output).Length
    Write-Output "[editor-payload] source commit: $sourceSha"
    Write-Output "[editor-payload] SDK: $sdkVersion"
    Write-Output "[editor-payload] WindowsDesktop runtime: $($runtimes -join '; ')"
    Write-Output "[editor-payload] editor files: $($files.Count)"
    Write-Output "[editor-payload] editor bytes: $((($files | Measure-Object Length -Sum).Sum))"
    Write-Output "[editor-payload] payload bytes: $compressedLength"
    Write-Output "[editor-payload] payload SHA-256: $((Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant())"
    Write-Output "[editor-payload] output: $output"
}
finally {
    if (Test-Path -LiteralPath $buildRoot) { Remove-Item -LiteralPath $buildRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
