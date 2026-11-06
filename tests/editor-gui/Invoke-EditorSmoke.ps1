param(
    [ValidateSet('synthetic', 'real')]
    [string]$Mode = 'synthetic',
    [int]$Repeat = 1,
    [int]$ItemCount = 0,
    [string]$RepoRoot = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'

$repo = [System.IO.Path]::GetFullPath($RepoRoot)
$exe = Join-Path $repo 'src\editor\gui\bin\Release\net8.0-windows\win-x64\DevWS.Editor.exe'

if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Build the editor first: dotnet build src\editor\gui\DevWS.Editor.csproj -c Release"
}

if ($Repeat -lt 1) {
    throw 'Repeat must be at least 1.'
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $env:TEMP ('devws-p4-smoke-output-' + [guid]::NewGuid().ToString('N'))
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

. (Join-Path $repo 'src\lib\devws-paths.ps1')
. (Join-Path $repo 'src\lib\devws-config.ps1')
. (Join-Path $repo 'src\lib\devws-native.ps1')
. (Join-Path $repo 'src\lib\devws-monitor.ps1')

function New-Terminal {
    param(
        [string]$Id,
        [string]$WindowId,
        [hashtable]$Layout,
        [string]$Mode = 'absolute',
        [hashtable]$RelativeLayout = $null
    )

    $terminal = [ordered]@{
        id = $Id
        type = 'terminal'
        enabled = $true
        windowId = $WindowId
        path = 'C:\Windows'
        elevated = $true
        tabs = @([ordered]@{ command = $null; args = @() })
        activeTab = 0
        layout = $Layout
    }

    if ($Mode -eq 'relative') {
        $terminal['layoutMode'] = 'relative'
        $terminal['layoutRelative'] = $RelativeLayout
    }

    return $terminal
}

function New-SyntheticConfig {
    $topology = Get-DevWSMonitorTopology
    if (-not $topology.Available) {
        throw 'The host monitor topology is unavailable; the synthetic smoke cannot build a matching profile.'
    }

    $tokens = @($topology.Signature -split ';')
    $primary = @($topology.Monitors | Where-Object { $_.Primary } | Select-Object -First 1)
    if ($primary.Count -eq 0) {
        $primary = @($topology.Monitors | Select-Object -First 1)
    }

    $identity = [string]$primary[0].IdentityToken

    $main = [ordered]@{
        id = 'main'
        windows = @(
            (New-Terminal -Id 'demo-profile' -WindowId 'DEVWS-P4-PROFILE' -Layout ([ordered]@{ x = 100; y = 100; w = 600; h = 500 })),
            (New-Terminal -Id 'demo-relative' -WindowId 'DEVWS-P4-RELATIVE' -Layout ([ordered]@{ x = 20; y = 20; w = 500; h = 400 }) -Mode 'relative' -RelativeLayout ([ordered]@{
                monitor = [ordered]@{ identity = $identity }
                basis = 'workArea'
                rect = [ordered]@{ x = 0.0; y = 0.0; w = 0.5; h = 1.0 }
            })),
            (New-Terminal -Id 'demo-fallback' -WindowId 'DEVWS-P4-FALLBACK' -Layout ([ordered]@{ x = 1100; y = 180; w = 480; h = 360 })),
            (New-Terminal -Id 'demo-missing' -WindowId 'DEVWS-P4-MISSING' -Layout ([ordered]@{ x = 200; y = 200; w = 300; h = 300 }) -Mode 'relative' -RelativeLayout ([ordered]@{
                monitor = [ordered]@{ identity = 'path:P4/MISSING' }
                basis = 'monitor'
                rect = [ordered]@{ x = 0.1; y = 0.1; w = 0.4; h = 0.4 }
            })),
            (New-Terminal -Id 'demo-negative' -WindowId 'DEVWS-P4-NEGATIVE' -Layout ([ordered]@{ x = -180; y = 240; w = 400; h = 300 }))
        )
        layoutProfiles = @([ordered]@{
            id = 'demo-docked'
            match = [ordered]@{
                mode = 'exact'
                monitors = $tokens
            }
            layouts = [ordered]@{
                'demo-profile' = [ordered]@{ x = 120; y = 120; w = 620; h = 520 }
            }
        })
    }

    if ($ItemCount -gt $main.windows.Count) {
        $windows = [System.Collections.Generic.List[object]]::new()
        foreach ($window in $main.windows) { $windows.Add($window) | Out-Null }

        for ($index = $main.windows.Count; $index -lt $ItemCount; $index++) {
            $windows.Add((New-Terminal `
                -Id ('demo-stress-{0:000}' -f $index) `
                -WindowId ('DEVWS-P4-STRESS-{0:000}' -f $index) `
                -Layout ([ordered]@{
                    x = ($index % 10) * 130
                    y = [int]([Math]::Floor($index / 10)) * 90
                    w = 120
                    h = 80
                }))) | Out-Null
        }

        $main.windows = @($windows.ToArray())
    }

    return [ordered]@{
        version = 3
        defaultSet = 'main'
        bindings = @()
        sets = @(
            $main,
            [ordered]@{ id = 'empty'; windows = @() }
        )
    }
}

$results = [System.Collections.Generic.List[object]]::new()

for ($run = 1; $run -le $Repeat; $run++) {
    $runRoot = Join-Path $OutputDirectory ("run-$run")
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $logPath = Join-Path $runRoot 'smoke.json'
    $snapshotPath = Join-Path $runRoot 'smoke.png'
    $cmdPath = Join-Path $runRoot 'smoke.cmd'

    $configPath = $null
    $configBefore = $null
    $canonicalPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config\devws\workspace.json'
    $canonicalBefore = $null

    if ($Mode -eq 'synthetic') {
        $configPath = Join-Path $runRoot 'workspace.json'
        $config = New-SyntheticConfig
        $config | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $configPath -Encoding UTF8
        Assert-DevWSConfig -Config ($config | ConvertTo-Json -Depth 30 | ConvertFrom-Json) -Source $configPath
        $configBefore = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    else {
        if (-not (Test-Path -LiteralPath $canonicalPath -PathType Leaf)) {
            throw "The real-mode smoke requires the canonical configuration at '$canonicalPath'."
        }

        $canonicalBefore = (Get-FileHash -LiteralPath $canonicalPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    $arguments = @('--smoke', '--log', ('"' + $logPath + '"'), '--snapshot', ('"' + $snapshotPath + '"'))
    if ($Mode -eq 'synthetic') {
        $arguments += @('--dev-config', ('"' + $configPath + '"'))
    }

    $commandLine = '@echo off' + "`r`n" + '"' + $exe + '" ' + ($arguments -join ' ') + "`r`n"
    Set-Content -LiteralPath $cmdPath -Value $commandLine -Encoding ASCII

    Start-Process -FilePath 'explorer.exe' -ArgumentList @($cmdPath)
    $deadline = (Get-Date).AddSeconds(120)
    while (-not (Test-Path -LiteralPath $logPath) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }

    if (-not (Test-Path -LiteralPath $logPath)) {
        throw "The editor smoke did not produce a log. See '$runRoot'."
    }

    $evidence = Get-Content -LiteralPath $logPath -Raw | ConvertFrom-Json

    if (-not $evidence.success) {
        throw "The editor smoke failed: $($evidence.error)"
    }

    if ($evidence.integrity -notmatch 'Medium') {
        throw "The editor smoke did not run at Medium integrity: $($evidence.integrity)"
    }

    if ($evidence.applied -ne $true) {
        throw 'The editor smoke did not commit a numeric draft edit.'
    }

    if ($evidence.canvasCommit -ne $true) {
        throw 'The editor smoke did not commit a canvas/drag-style draft edit.'
    }

    if ($evidence.finalDraftDirty -ne $true) {
        throw 'The editor smoke did not retain an unsaved draft for the close-confirmation path.'
    }

    if ($evidence.draftValidation -notmatch 'structurally valid') {
        throw "The editor smoke draft was not structurally valid: $($evidence.draftValidation)."
    }

    if ($evidence.previewOk -ne $true) {
        throw 'The editor smoke did not obtain an authoritative preview.'
    }

    if ($evidence.previewAckOk -ne $true) {
        throw 'The editor smoke did not explicitly acknowledge required preview warnings.'
    }

    if ($evidence.previewDiffCount -lt 1 -or $evidence.previewNoChanges -eq $true) {
        throw "The editor smoke preview did not report the draft change (diff=$($evidence.previewDiffCount))."
    }

    if ([string]::IsNullOrWhiteSpace([string]$evidence.previewSavedRect) -or
        [string]::IsNullOrWhiteSpace([string]$evidence.previewProposedRect)) {
        throw 'The editor smoke preview did not report saved and proposed effective rectangles.'
    }

    if ($evidence.backendExited -ne $true) {
        throw 'The editor backend child did not exit.'
    }

    if ($evidence.backendExitCode -ne 0) {
        throw "The editor backend exited with $($evidence.backendExitCode)."
    }

    if (-not (Test-Path -LiteralPath $snapshotPath -PathType Leaf)) {
        throw "The editor smoke did not produce a screenshot at '$snapshotPath'."
    }

    if ($Mode -eq 'synthetic') {
        if ($evidence.configSource -ne 'env') {
            throw "Expected the development config source 'env', got '$($evidence.configSource)'."
        }
        if ($null -eq $configBefore -or (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $configBefore) {
            throw 'The synthetic development configuration changed during the smoke.'
        }
        if ($ItemCount -gt 0) {
            if ($evidence.itemCount -lt $ItemCount) {
                throw "Expected at least $ItemCount synthetic items, got $($evidence.itemCount)."
            }
        }
        elseif ($evidence.itemCount -lt 5) {
            throw "Expected at least 5 synthetic items, got $($evidence.itemCount)."
        }
        if ($evidence.warningCount -lt 1) {
            throw "Expected at least one warning, got $($evidence.warningCount)."
        }
        if ($evidence.relativeEditOk -ne $true) {
            throw "The synthetic relative edit did not succeed: $($evidence.relativeError)"
        }
        if ($evidence.previewReviewRequired -ne $true -or $evidence.previewAcknowledged -ne $true) {
            throw 'The synthetic preview did not require and receive an explicit warning review.'
        }
        if (([string]$evidence.previewWarningDigest).Length -ne 64 -or
            ([string]$evidence.previewReviewToken).Length -ne 64) {
            throw 'The synthetic preview did not return a 64-character warning digest and review token.'
        }
    }
    else {
        if ($null -eq $canonicalBefore -or (Get-FileHash -LiteralPath $canonicalPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $canonicalBefore) {
            throw 'The real canonical configuration changed during the smoke.'
        }
        if ($evidence.configSource -ne 'user') {
            throw "Expected the real source 'user', got '$($evidence.configSource)'."
        }
    }

    $results.Add([pscustomobject][ordered]@{
        Mode = $Mode
        Run = $run
        Integrity = $evidence.integrity
        ConfigSource = $evidence.configSource
        ConfigRevision = $evidence.configRevision
        SetCount = $evidence.setCount
        MonitorCount = $evidence.monitorCount
        ItemCount = $evidence.itemCount
        WarningCount = $evidence.warningCount
        SelectedSetId = $evidence.selectedSetId
        SelectedItemId = $evidence.selectedItemId
        SelectedItemSource = $evidence.selectedItemSource
        SelectedItemPlacement = $evidence.selectedItemPlacement
        SelectedItemRect = $evidence.selectedItemRect
        EditScope = $evidence.editScope
        EditBefore = $evidence.editBefore
        EditAfter = $evidence.editAfter
        Applied = $evidence.applied
        DraftDirtyAfterApply = $evidence.draftDirtyAfterApply
        DraftValidation = $evidence.draftValidation
        CanvasCommit = $evidence.canvasCommit
        CanvasBefore = $evidence.canvasBefore
        CanvasAfter = $evidence.canvasAfter
        RevertedDirty = $evidence.revertedDirty
        RelativeEditOk = $evidence.relativeEditOk
        RelativeBefore = $evidence.relativeBefore
        RelativeAfter = $evidence.relativeAfter
        RelativeNormalized = $evidence.relativeNormalized
        FinalProposed = $evidence.finalProposed
        PreviewOk = $evidence.previewOk
        PreviewDiffCount = $evidence.previewDiffCount
        PreviewNoChanges = $evidence.previewNoChanges
        PreviewReviewRequired = $evidence.previewReviewRequired
        PreviewAcknowledged = $evidence.previewAcknowledged
        PreviewSavedRect = $evidence.previewSavedRect
        PreviewProposedRect = $evidence.previewProposedRect
        PreviewEffectiveChanged = $evidence.previewEffectiveChanged
        PreviewWarningCount = $evidence.previewWarningCount
        PreviewWarningDigest = $evidence.previewWarningDigest
        PreviewReviewToken = $evidence.previewReviewToken
        PreviewMs = $evidence.previewMs
        PreviewTransportMs = $evidence.previewTransportMs
        PreviewParseMs = $evidence.previewParseMs
        PreviewModelMs = $evidence.previewModelMs
        PreviewDiffSnapshotPath = $evidence.previewDiffSnapshotPath
        EditApplyMs = $evidence.editApplyMs
        EditCommitMs = $evidence.editCommitMs
        ValidateMs = $evidence.validateMs
        ConvertMs = $evidence.convertMs
        DraftCreateMs = $evidence.draftCreateMs
        ProjectionApplyMs = $evidence.projectionApplyMs
        ItemsUpdateMs = $evidence.itemsUpdateMs
        HandshakeMs = $evidence.handshakeMs
        LoadMs = $evidence.loadMs
        RefreshMs = $evidence.refreshMs
        SmokeElapsedMs = $evidence.smokeElapsedMs
        WorkingSetMB = $evidence.workingSetMB
        ProjectResponseBytes = $evidence.projectResponseBytes
        ProjectParseMs = $evidence.projectParseMs
        ProjectModelMs = $evidence.projectModelMs
        ProjectRequestMs = $evidence.projectRequestMs
        CanvasRenderMs = $evidence.canvasRenderMs
        CanvasRenderCount = $evidence.canvasRenderCount
        CachedTextCount = $evidence.cachedTextCount
        BackendPid = $evidence.backendPid
        BackendExited = $evidence.backendExited
        BackendExitCode = $evidence.backendExitCode
        SnapshotPath = $snapshotPath
        DiffSnapshotPath = $evidence.previewDiffSnapshotPath
        LogPath = $logPath
    }) | Out-Null

    if ($Mode -eq 'synthetic') {
        $summaryName = if ($run -eq $Repeat) { 'p6-editor-preview.png' } else { "p6-editor-preview-run-$run.png" }
        Copy-Item -LiteralPath $snapshotPath -Destination (Join-Path $OutputDirectory $summaryName) -Force
        if (-not [string]::IsNullOrWhiteSpace([string]$evidence.previewDiffSnapshotPath) -and
            (Test-Path -LiteralPath $evidence.previewDiffSnapshotPath -PathType Leaf)) {
            $diffName = if ($run -eq $Repeat) { 'p6-editor-preview-diff.png' } else { "p6-editor-preview-diff-run-$run.png" }
            Copy-Item -LiteralPath $evidence.previewDiffSnapshotPath -Destination (Join-Path $OutputDirectory $diffName) -Force
        }
    }
}

$summary = [ordered]@{
    mode = $Mode
    repeat = $Repeat
    outputDirectory = $OutputDirectory
    runs = @($results.ToArray())
    medianHandshakeMs = (@($results | ForEach-Object { $_.HandshakeMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianLoadMs = (@($results | ForEach-Object { $_.LoadMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianRefreshMs = (@($results | ForEach-Object { $_.RefreshMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianSmokeElapsedMs = (@($results | ForEach-Object { $_.SmokeElapsedMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianWorkingSetMB = (@($results | ForEach-Object { $_.WorkingSetMB }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianEditCommitMs = (@($results | ForEach-Object { $_.EditCommitMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianValidateMs = (@($results | ForEach-Object { $_.ValidateMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianConvertMs = (@($results | ForEach-Object { $_.ConvertMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianDraftCreateMs = (@($results | ForEach-Object { $_.DraftCreateMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianProjectionApplyMs = (@($results | ForEach-Object { $_.ProjectionApplyMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianItemsUpdateMs = (@($results | ForEach-Object { $_.ItemsUpdateMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianCanvasRenderMs = (@($results | ForEach-Object { $_.CanvasRenderMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianPreviewMs = (@($results | ForEach-Object { $_.PreviewMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianPreviewParseMs = (@($results | ForEach-Object { $_.PreviewParseMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianPreviewModelMs = (@($results | ForEach-Object { $_.PreviewModelMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianProjectParseMs = (@($results | ForEach-Object { $_.ProjectParseMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
    medianProjectModelMs = (@($results | ForEach-Object { $_.ProjectModelMs }) | Sort-Object)[[Math]::Floor($results.Count / 2)]
}

$summary | ConvertTo-Json -Depth 10
