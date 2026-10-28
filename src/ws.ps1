param(
    # Deliberately a simple (non-advanced) parameter block with no array
    # parameter: PowerShell then does not attach its common parameters (such
    # as -WarningAction/-WarningVariable) and leaves every further token in
    # $args in original order. That is what lets literal tool arguments like
    # `-w 5` reach commands unchanged instead of being rejected or consumed
    # by the PowerShell binder.
    [string]$Command = "help",

    [string]$Arg1,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Everything after the command and its first argument, in original order,
# including switch-looking tool arguments such as `-w 5`.
$Remaining = @($args)

$LibDir = Join-Path $PSScriptRoot "lib"

. (Join-Path $LibDir "devws-paths.ps1")
. (Join-Path $LibDir "devws-config.ps1")
. (Join-Path $LibDir "devws-native.ps1")
. (Join-Path $LibDir "devws-app-ownership.ps1")
. (Join-Path $LibDir "devws-app-window.ps1")
. (Join-Path $LibDir "devws-bindings.ps1")
. (Join-Path $LibDir "devws-lifecycle.ps1")
. (Join-Path $LibDir "devws-terminal.ps1")
. (Join-Path $LibDir "devws-cwd-paths.ps1")
. (Join-Path $LibDir "devws-cwd.ps1")
. (Join-Path $LibDir "devws-state.ps1")
. (Join-Path $LibDir "devws-uia.ps1")
. (Join-Path $LibDir "devws-identity.ps1")
. (Join-Path $LibDir "devws-app.ps1")
. (Join-Path $LibDir "devws-capture.ps1")
. (Join-Path $LibDir "devws-display.ps1")
. (Join-Path $LibDir "devws-help.ps1")
. (Join-Path $LibDir "devws-mutation.ps1")

# Canonical terminal launch policy + elevated broker protocol (Stage 2).
# devws-launch.ps1 orchestrates them; both hosts share the same policy.
. (Join-Path $LibDir "devws-terminal.ps1")
. (Join-Path $LibDir "devws-terminal-launch.ps1")
. (Join-Path $LibDir "devws-broker-protocol.ps1")

# Canonical launch transaction + batch app fan-out (shared with the warm
# normal coordinator; the coordinator host loads the same library).
. (Join-Path $LibDir "devws-launch.ps1")

# Read-only `ws status` support: the coordinator client/generation helpers and
# the status model (observational only; never launches or repairs anything).
. (Join-Path $LibDir "devws-coordinator.ps1")
. (Join-Path $LibDir "devws-status.ps1")

# Read-only `ws monitors` support: monitor snapshot, identity normalization,
# topology signature/fingerprint and reachability primitives (observational
# only; no workspace-config, host or window awareness).
. (Join-Path $LibDir "devws-monitor.ps1")

# Relative-layout model (v0.3 Phase 1): anchor parsing/resolution, normalized
# rectangle math, anchored capture/restore primitives and the shared relative
# placement policy consumed by lifecycle execution and `ws show-layout`.
# Save/capture integration arrives in a later phase.
. (Join-Path $LibDir "devws-relative-layout.ps1")

# Topology layout-profile policy (Pass 5C): pure selection, write-scope
# routing, sparse effective layouts and in-memory profile mutations.
. (Join-Path $LibDir "devws-layout-profile.ps1")

# Lifecycle layout placement (Pass 5D): the normal-side preflight that freezes
# ONE topology/profile placement decision per launch/reset before any side
# effect. Elevated hosts receive final geometry only.
. (Join-Path $LibDir "devws-lifecycle-layout.ps1")

# Exact-HWND app operations: the standalone CLI must load the AHK helper
# layer first and then the window-operation wrapper that calls it.
. (Join-Path $LibDir "devws-ahk.ps1")
. (Join-Path $LibDir "devws-window-ops.ps1")

. (Join-Path $LibDir "devws-worker-protocol.ps1")
. (Join-Path $LibDir "devws-install.ps1")
. (Join-Path $LibDir "devws-health.ps1")
. (Join-Path $LibDir "devws-tools.ps1")

function Assert-DevWSNoExtraArguments {
    param(
        [Parameter(Mandatory)]
        [string]$CommandName,
        [Parameter(Mandatory)]
        [string]$Usage,
        [string]$FirstArgument,
        [AllowEmptyCollection()]
        [object[]]$RemainingArguments = @()
    )

    # Reject extra tokens instead of silently ignoring them.
    if (-not [string]::IsNullOrWhiteSpace($FirstArgument) -or @($RemainingArguments).Count -gt 0) {
        throw "'$CommandName' does not accept additional arguments. Usage: $Usage"
    }
}

function Get-DevWSContext {
    param(
        [switch]$RequireTerminalPaths
    )

    $location = Resolve-DevWSConfigLocation -StartPath $PSScriptRoot

    if ($location.Warning) {
        Write-Host $location.Warning -ForegroundColor DarkGray
    }

    $config = Get-DevWSConfig -Location $location -RequireTerminalPaths:$RequireTerminalPaths

    return [pscustomobject]@{
        Location = $location
        Config   = $config
    }
}

function Show-DevWSList {
    param([string]$SetId)

    $context = Get-DevWSContext
    $target  = Resolve-DevWSLifecycleTarget -Config $context.Config -SetId $SetId

    $defaultSet = Get-DevWSDefaultSet -Config $context.Config
    $suffix = ""

    if ($target.SetId -ieq ([string]$defaultSet.id)) {
        $suffix = " (default)"
    }

    Write-Host ""
    Write-Host "WORKSPACE: $($target.SetId)$suffix" -ForegroundColor Cyan
    Write-Host "────────────────────────────────────────────────────────"

    foreach ($line in @(Get-DevWSListLines -Config $context.Config -Set $target.Set)) {
        Write-Host $line
    }

    Write-Host ""
}

function Show-DevWSStatus {
    param([string]$SetId)

    $context = Get-DevWSContext
    $model   = Get-DevWSStatusModel -Config $context.Config -SetId $SetId

    foreach ($line in @(Get-DevWSStatusLines -Model $model)) {
        Write-Host $line
    }
}

function Show-DevWSMonitors {
    # Read-only monitor diagnostics. Deliberately config-free: it never loads
    # the workspace config, never contacts hosts and never touches windows or
    # display settings. An incomplete identity is an observed state (exit 0);
    # a failed topology acquisition exits non-zero after showing the error.
    $topology = Get-DevWSMonitorTopology

    foreach ($line in @(Get-DevWSMonitorLines -Topology $topology)) {
        Write-Host $line
    }

    if (-not [bool]$topology.Available) {
        exit 1
    }
}

function Show-DevWSSets {
    $context = Get-DevWSContext

    Write-Host ""
    Write-Host "SETS" -ForegroundColor Cyan
    Write-Host "────────────────────────────────────────────────────────"

    foreach ($line in @(Get-DevWSSetsLines -Config $context.Config)) {
        Write-Host $line
    }

    Write-Host ""
    Write-Host "* = default set (bare commands target it)" -ForegroundColor DarkGray
    Write-Host ""
}

function Get-DevWSEnabledItems {
    param(
        $Config,
        [string]$Type,
        $Set
    )

    return @(Get-DevWSWindows -Config $Config -Type $Type -EnabledOnly -Set $Set)
}

function Assert-DevWSNoRemainingArguments {
    param(
        [Parameter(Mandatory)]
        [string]$Usage,
        [AllowEmptyCollection()]
        [object[]]$RemainingArguments = @()
    )

    if (@($RemainingArguments).Count -gt 0) {
        throw "Usage: $Usage"
    }
}

function Invoke-DevWSLaunch {
    param([string]$SetId)

    $context = Get-DevWSContext

    # One canonical transaction shared with the warm coordinator: the same
    # validation, the same worker/terminal overlap and the same batch app
    # fan-out run on both paths. The transaction throws on failure and never
    # rolls back already-started work.
    $result = Invoke-DevWSLaunchTransaction -Config $context.Config -SetId $SetId

    if ($result.NoEnabledItems) {
        Write-Host "Set '$($result.SetId)' has no enabled items; nothing to launch." -ForegroundColor DarkGray
        return
    }

    Write-Host "Workspace '$($result.SetId)' restored." -ForegroundColor Green

    foreach ($warning in @($result.LayoutWarnings)) {
        Write-Host $warning -ForegroundColor Yellow
    }
}

function Invoke-DevWSFocus {
    param([string]$SetId)

    $context = Get-DevWSContext
    $target  = Resolve-DevWSLifecycleTarget -Config $context.Config -SetId $SetId

    # No directory validation: focus must still work for an already-running
    # terminal whose configured directory has since vanished.
    $terminals = @(Get-DevWSEnabledItems -Config $context.Config -Set $target.Set -Type "terminal")
    $apps      = @(Get-DevWSEnabledItems -Config $context.Config -Set $target.Set -Type "app")

    if (($terminals.Count + $apps.Count) -eq 0) {
        Write-Host "Set '$($target.SetId)' has no enabled items; nothing to focus." -ForegroundColor DarkGray
        return
    }

    # Existing desktop applications only; nothing is launched. Missing apps
    # are skipped, exactly as before.
    if ($apps.Count -gt 0) {
        Assert-DevWSAppInstanceModeExplicit -Apps $apps -SetId $target.SetId

        # One shared steady-state probe per focus invocation (the same Pass 3
        # pattern launch uses): every app is resolved from one coherent
        # snapshot instead of re-enumerating all live windows per app.
        $initialAppProbe = @(Get-DevWSAppWindowProbe -Config $context.Config)

        foreach ($app in $apps) {
            $hwnd = Resolve-DevWSAppLifecycleWindow `
                -Config $context.Config `
                -SetId $target.SetId `
                -App $app `
                -Operation "focus" `
                -InitialProbe $initialAppProbe

            if ($hwnd -gt 0) {
                Focus-DevWSWindowHwnd -Hwnd $hwnd -Context "app '$($target.SetId)/$($app.id)'"
            }
        }
    }

    # Existing elevated managed terminals only (target set only). The
    # persistent elevated broker owns the warm path; the scheduled Focus
    # worker remains the fallback before broker ACCEPTED and is never used
    # after acceptance.
    if ($terminals.Count -gt 0) {
        $operation = Invoke-DevWSElevatedBrokerTerminalOperation `
            -Command "focus-terminals" `
            -RequestId (New-DevWSLaunchRequestId) `
            -SetId $target.SetId

        if ($operation.Status -eq "AcceptedAndCompleted") {
            if (-not $operation.Ok) {
                throw "Terminal focus failed: $($operation.Message)"
            }
        }
        elseif ($operation.Status -eq "AcceptedButUncertain") {
            throw "Terminal focus completion is uncertain: the elevated broker accepted the operation but did not report FINAL. No fallback was attempted and the operation must not be repeated automatically."
        }
        else {
            [void](Invoke-DevWSWorkerRequest `
                -Kind "focus" `
                -TaskName "DevWorkspace-ElevatedFocus" `
                -Payload @{ setId = $target.SetId } `
                -TimeoutSeconds 60)
        }
    }

    Write-Host "Workspace '$($target.SetId)' focused." -ForegroundColor Green
}

function Get-DevWSLiveLayoutCapture {
    # Live geometry acquisition for one target set. Performs NO canonical
    # mutation and NO canonical save; any incomplete/invalid capture throws.
    # Both `ws save-layout` (geometry only) and `ws save` (geometry + tracked
    # per-tab cwd + optional active-tab observation) consume this one capture
    # path; the active-tab sidecar is optional state and can never affect
    # geometry completeness. The caller may pass the already-read context so
    # the write-plan and the capture share ONE config object graph (Pass 5C
    # profile routing); without it the context is read here.
    param(
        [string]$SetId,
        $Context
    )

    $context = $Context

    if ($null -eq $context) {
        $context = Get-DevWSContext
    }

    Assert-DevWSConfigWritable -Location $context.Location

    $target = Resolve-DevWSLifecycleTarget -Config $context.Config -SetId $SetId

    $terminals = @(Get-DevWSEnabledItems -Config $context.Config -Set $target.Set -Type "terminal")
    $apps      = @(Get-DevWSEnabledItems -Config $context.Config -Set $target.Set -Type "app")

    $runtimeRoot  = Get-DevWSRuntimeRoot
    $appOut       = Join-Path $runtimeRoot "capture-normal.txt"

    $capture = [pscustomobject]@{
        Context              = $context
        Target               = $target
        Terminals            = $terminals
        Apps                 = $apps
        AppGeometry          = @{}
        TerminalGeometry     = @{}
        TerminalTabSnapshots = $null
        CaptureFiles         = @($appOut)
    }

    if (($terminals.Count + $apps.Count) -eq 0) {
        # Empty sets never touch live capture; the caller reports the no-op.
        return $capture
    }

    Assert-DevWSElevatedTerminals -Terminals $terminals

    Remove-Item $appOut -Force -ErrorAction SilentlyContinue

    # Capture desktop applications (target set only) from exact resolved HWNDs.
    # All-or-nothing: any unresolved or invalid app fails before config changes.
    $appGeometry = @{}

    if ($apps.Count -gt 0) {
        Assert-DevWSAppInstanceModeExplicit -Apps $apps -SetId $target.SetId

        # One shared steady-state probe per capture invocation: every app is
        # resolved from one coherent snapshot instead of re-enumerating all
        # live windows per app.
        $initialAppProbe = @(Get-DevWSAppWindowProbe -Config $context.Config)

        foreach ($app in $apps) {
            $appRef = "$($target.SetId)/$($app.id)"
            $hwnd   = Resolve-DevWSAppLifecycleWindow `
                -Config $context.Config `
                -SetId $target.SetId `
                -App $app `
                -Operation "capture" `
                -InitialProbe $initialAppProbe

            if ($hwnd -le 0) {
                throw "Application '$appRef' window was not found; nothing was saved."
            }

            $rect = Get-DevWSWindowHwndRect -Hwnd $hwnd

            if ($null -eq $rect -or -not $rect.Valid) {
                throw "Application '$appRef' geometry is minimized or invalid; nothing was saved."
            }

            $appGeometry[$app.id] = $rect
        }
    }

    # Capture elevated managed terminals (target set only). The persistent
    # elevated broker owns the warm path; the scheduled Capture worker remains
    # the fallback before broker ACCEPTED and is never used after acceptance.
    # Phase 2-B: the Medium caller reads ONLY its own completed operation id
    # and High-generated publication identity, and consumes geometry plus the
    # optional snapshot under one verified publication lifetime.
    $terminalGeometry = @{}

    if ($terminals.Count -gt 0) {
        $captureRequestId = [string](New-DevWSCaptureRequestId)

        $operation = Invoke-DevWSElevatedBrokerTerminalOperation `
            -Command "capture-terminals" `
            -RequestId ([long]$captureRequestId) `
            -SetId $target.SetId

        if ($operation.Status -eq "AcceptedAndCompleted") {
            $publicationId = Get-DevWSBrokerCapturePublication -Operation $operation
            $publication = Read-DevWSProtectedCapturePublication `
                -OperationId $captureRequestId `
                -ExpectedPublication $publicationId
        }
        elseif ($operation.Status -eq "AcceptedButUncertain") {
            throw "Terminal capture completion is uncertain: the elevated broker accepted the operation but did not report FINAL. No fallback was attempted and no canonical save may proceed."
        }
        else {
            $workerResult = Invoke-DevWSWorkerRequest `
                -Kind "capture" `
                -TaskName "DevWorkspace-ElevatedCapture" `
                -Payload @{ setId = $target.SetId } `
                -TimeoutSeconds 90

            $workerPublication = Get-DevWSWorkerCapturePublication -Result $workerResult
            $publication = Read-DevWSProtectedCapturePublication `
                -OperationId $workerPublication.OperationId `
                -ExpectedPublication $workerPublication.Publication
        }

        $terminalGeometry = $publication.Geometry
        $capture.TerminalTabSnapshots = $publication.Snapshots
    }

    Assert-DevWSCaptureComplete `
        -Captured $appGeometry `
        -RequiredIds @($apps | ForEach-Object { $_.id }) `
        -SourceLabel "Application"

    Assert-DevWSCaptureComplete `
        -Captured $terminalGeometry `
        -RequiredIds @($terminals | ForEach-Object { $_.id }) `
        -SourceLabel "Terminal"

    $capture.AppGeometry      = $appGeometry
    $capture.TerminalGeometry = $terminalGeometry

    return $capture
}

function Set-DevWSTerminalTabPathValue {
    # In-memory ONLY setter for a tab path override inside the Pass 6D save
    # planner. Never removes an override (the planner decides when a value
    # changes and never normalizes a redundant override away); works with
    # parsed PSCustomObject configs and raw hashtable tab definitions alike.
    param(
        [Parameter(Mandatory)]
        $Tab,
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Tab -is [System.Collections.IDictionary]) {
        $Tab["path"] = $Path
        return
    }

    $Tab | Add-Member -NotePropertyName "path" -NotePropertyValue $Path -Force
}

function Get-DevWSTerminalSaveDecisions {
    # Read-only per-configured-tab tracked-cwd decisions for the ENABLED
    # terminals of one target set. Every configured tab of every enabled
    # terminal is resolved independently through the single resolver; a tab's
    # live state is never inferred from another tab, the controller process,
    # the visual tab order, or terminal.path. Disabled terminals are never
    # queried, and tracking state is never created, deleted, or rotated.
    #
    # Each decision carries the pre-mutation facts the encoder needs:
    #   terminalId / tabIndex / hadOverride / oldExplicitPath / oldEffective /
    #   status / reason / newCwd (reliable) / sessionId / windowId.
    #
    # An AVAILABLE tab decision additionally carries the resolved startup
    # metadata (startupState / startupSpecSha256) for the startup-intent
    # retirement predicate; unavailable tabs carry $null and can never retire.
    # This is the same single resolver result that feeds cwd persistence -
    # there is no second per-tab state-resolution pass.
    param(
        [Parameter(Mandatory)]
        [string]$SetId,
        [AllowEmptyCollection()]
        [object[]]$Terminals = @(),
        [string]$TestBaseRoot
    )

    $decisions = [ordered]@{}

    foreach ($terminal in @($Terminals)) {
        $terminalId = [string]$terminal.id
        $tabs       = @($terminal.tabs)
        $perTab     = [System.Collections.Generic.List[object]]::new()

        for ($tabIndex = 0; $tabIndex -lt $tabs.Count; $tabIndex++) {
            $tab = $tabs[$tabIndex]

            $hadOverride = $false
            $oldExplicit = $null

            if ($null -ne $tab) {
                $rawPath = $null

                if ($tab -is [System.Collections.IDictionary]) {
                    if ($tab.Contains("path")) { $rawPath = $tab["path"] }
                }
                elseif ($null -ne $tab.PSObject.Properties["path"]) {
                    $rawPath = $tab.path
                }

                if ($null -ne $rawPath -and -not [string]::IsNullOrWhiteSpace([string]$rawPath)) {
                    $hadOverride = $true
                    $oldExplicit = [string]$rawPath
                }
            }

            $oldEffective = [string](Get-DevWSTerminalTabEffectivePath -Terminal $terminal -TabIndex $tabIndex)
            $resolution   = Resolve-DevWSTrackedCwd -SetId $SetId -TerminalId $terminalId -TabIndex $tabIndex -TestBaseRoot $TestBaseRoot

            $available = $null -ne $resolution -and [string]$resolution.Status -eq "available"

            $perTab.Add([pscustomobject]@{
                terminalId      = $terminalId
                tabIndex        = $tabIndex
                hadOverride     = $hadOverride
                oldExplicitPath = $oldExplicit
                oldEffective    = $oldEffective
                status          = $(if ($available) { "available" } else { "unavailable" })
                reason          = [string]$(if ($null -ne $resolution) { $resolution.Reason } else { "" })
                newCwd          = $(if ($available) { [string]$resolution.cwd } else { $null })
                sessionId       = $(if ($available) { [string]$resolution.SessionId } else { $null })
                windowId        = $(if ($available) { [string]$resolution.WindowId } else { $null })
                startupState    = $(if ($available -and $null -ne $resolution.StartupState -and -not [string]::IsNullOrWhiteSpace([string]$resolution.StartupState)) { [string]$resolution.StartupState } else { $null })
                startupSpecSha256 = $(if ($available -and $null -ne $resolution.StartupSpecSha256 -and -not [string]::IsNullOrWhiteSpace([string]$resolution.StartupSpecSha256)) { [string]$resolution.StartupSpecSha256 } else { $null })
            }) | Out-Null
        }

        $decisions[$terminalId] = $perTab.ToArray()
    }

    return $decisions
}

function Get-DevWSTabStartupRetirementDecision {
    # Pure fail-closed startup-intent retirement verdict for ONE configured tab
    # (the accepted architecture/POC policy). Retirement requires ALL of:
    #   - the complete validated tracking pair (decision.status == available);
    #   - a genuine non-empty configured startup command;
    #   - the exact canonical lowercase "startup-child-returned" token;
    #   - a strictly formatted 64-hex expected startupSpecSha256;
    #   - that expected fingerprint case-insensitively equals the freshly
    #     computed fingerprint of the CURRENT configured command + ordered args.
    #
    # The lifecycle signal is solely the bootstrap-owned original invocation
    # returning control; exit codes, process trees, foreground processes,
    # executable names, window titles, terminal contents and shell history are
    # never consulted. The caller derives this verdict AFTER the final
    # generation gate, so a rotated generation can never retire.
    param(
        [AllowNull()]
        $Tab,
        [AllowNull()]
        $Decision
    )

    if ($null -eq $Tab) {
        return [pscustomobject]@{ Retire = $false; Reason = "no-tab"; Command = $null }
    }

    if ($null -eq $Tab.command -or [string]::IsNullOrWhiteSpace([string]$Tab.command)) {
        # An idle configured tab is already in the canonical retirement shape;
        # no metadata can ever invent startup intent.
        return [pscustomobject]@{ Retire = $false; Reason = "configured-idle"; Command = $null }
    }

    if ($null -eq $Decision -or [string]$Decision.status -cne "available") {
        return [pscustomobject]@{ Retire = $false; Reason = "cwd-unavailable"; Command = $null }
    }

    $state = [string]$Decision.startupState

    if ([string]::IsNullOrWhiteSpace($state)) {
        return [pscustomobject]@{ Retire = $false; Reason = "state-missing"; Command = $null }
    }

    # Case-sensitive: wrong-case tokens are malformed/tampered metadata and can
    # only preserve. The production bootstrap emits canonical lowercase only.
    if ($state -cnotin @("idle", "startup-child-active", "startup-child-returned")) {
        return [pscustomobject]@{ Retire = $false; Reason = "state-malformed"; Command = $null }
    }

    if ($state -cne "startup-child-returned") {
        return [pscustomobject]@{ Retire = $false; Reason = "state-not-returned"; Command = $null }
    }

    $expected = [string]$Decision.startupSpecSha256

    if (-not (Test-DevWSCwdChildSpecFingerprintFormat -Value $expected)) {
        return [pscustomobject]@{ Retire = $false; Reason = "fingerprint-missing-or-malformed"; Command = $null }
    }

    $current = Get-DevWSCwdChildSpecFingerprint -Command $Tab.command -Arguments @($Tab.args)

    if ($expected -ine $current) {
        return [pscustomobject]@{ Retire = $false; Reason = "fingerprint-mismatch"; Command = $null }
    }

    return [pscustomobject]@{ Retire = $true; Reason = "ok"; Command = [string]$Tab.command }
}

function Invoke-DevWSTabStartupRetirement {
    # Pure in-memory canonical retirement for ONE configured tab: the canonical
    # idle-tab shape, command=$null with NO orphan arguments. Never writes the
    # config file and never touches tracking state; the single canonical save
    # remains the caller's responsibility.
    param(
        [Parameter(Mandatory)]
        $Tab
    )

    $Tab.command = $null
    $Tab.args    = @()
}

function Confirm-DevWSTerminalSaveDecisions {
    # Save-transaction final consistency gate (Pass 6D). An available per-tab
    # cwd decision is only valid while the controller-owned expected record
    # still matches the generation identity accepted during resolution. Runs
    # immediately before the canonical commit; a reset may advance T1 -> T2 in
    # between. The shared expected-generation validator reproduces the tab-0
    # legacy rules and the indexed-tab exact rules; the accepted sessionId and
    # windowId must additionally still be present.
    #
    # Read-only: downgrades ONLY the failing tab (preserving its old effective
    # path), never fails the whole save, never re-reads another tab's state,
    # and never writes tracking state.
    param(
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        $Decisions,
        [string]$TestBaseRoot
    )

    foreach ($key in @($Decisions.Keys)) {
        foreach ($decision in @($Decisions[$key])) {
            if ([string]$decision.status -ne "available") {
                continue
            }

            if ((Get-DevWSCwdStorageMode -TestBaseRoot $TestBaseRoot) -eq "protected") {
                $trustOk     = $true
                $trustReason = ""

                try {
                    $trust = Test-DevWSCwdProtectedChainTrust `
                        -SidRoot (Resolve-DevWSCwdProtectedSidRoot -TestBaseRoot $TestBaseRoot) `
                        -Kind "sessions" `
                        -SetId $SetId `
                        -TerminalId ([string]$decision.terminalId) `
                        -TabIndex ([int]$decision.tabIndex)

                    $trustOk     = [bool]$trust.Ok
                    $trustReason = [string]$trust.Reason
                }
                catch {
                    $trustOk     = $false
                    $trustReason = "protected-root-unavailable"
                }

                if (-not $trustOk) {
                    $decision.status = "unavailable"
                    $decision.reason = "protected-" + $trustReason
                    $decision.newCwd = $null

                    $decision | Add-Member -NotePropertyName "startupState" -NotePropertyValue $null -Force
                    $decision | Add-Member -NotePropertyName "startupSpecSha256" -NotePropertyValue $null -Force
                    continue
                }
            }

            $expectedPath = Get-DevWSCwdSessionPath `
                -SetId $SetId `
                -TerminalId ([string]$decision.terminalId) `
                -TabIndex ([int]$decision.tabIndex) `
                -TestBaseRoot $TestBaseRoot

            $read  = Read-DevWSCwdStateFile -Path $expectedPath
            $check = Test-DevWSCwdExpectedGeneration `
                -Expected $read.Record `
                -ExpectedReadError $(if ($read.Ok) { "" } else { $read.Reason }) `
                -SetId $SetId `
                -TerminalId ([string]$decision.terminalId) `
                -TabIndex ([int]$decision.tabIndex) `
                -ExpectedSessionId ([string]$decision.sessionId) `
                -ExpectedWindowId ([string]$decision.windowId)

            if (-not [bool]$check.Ok) {
                $decision.status = "unavailable"
                $decision.reason = [string]$check.Reason
                $decision.newCwd = $null

                # Defense in depth: a downgraded (rotated) generation must also
                # clear the captured startup metadata so no later reader can
                # retire from a generation that no longer owns the tab. The
                # retirement predicate independently requires status available.
                $decision | Add-Member -NotePropertyName "startupState" -NotePropertyValue $null -Force
                $decision | Add-Member -NotePropertyName "startupSpecSha256" -NotePropertyValue $null -Force
            }
        }
    }
}

function Invoke-DevWSTerminalSaveState {
    # Pass 6D in-memory path encoding (the accepted policy). Pure: touches only
    # the supplied terminal object graph and never reads or writes tracking
    # state.
    #
    #   terminal.path changes ONLY from a reliable tab-0 cwd.
    #   tab 0:  no explicit override -> stays absent (the live tab-0 cwd lives
    #           in terminal.path); explicit override -> reliable: override and
    #           terminal.path track the live cwd; unavailable: both preserved
    #           exactly.
    #   tab N:  explicit override -> reliable: value updated; unavailable:
    #           value left exactly as-is (never normalized away, even when it
    #           equals terminal.path);
    #           no override -> materialized only when the desired effective
    #           path (reliable live cwd, otherwise the old effective path)
    #           differs from the resulting terminal.path.
    #
    # Invariant after planning: effective_after[N] == desired[N] for every
    # configured tab.
    param(
        [Parameter(Mandatory)]
        $Terminal,
        [AllowEmptyCollection()]
        [object[]]$TabDecisions = @()
    )

    $tabs = @($Terminal.tabs)

    if ($tabs.Count -eq 0) { return }

    $byIndex = @{}

    foreach ($decision in @($TabDecisions)) {
        $byIndex[[int]$decision.tabIndex] = $decision
    }

    if (-not $byIndex.ContainsKey(0)) { return }

    $tab0     = $byIndex[0]
    $tab0Live = ([string]$tab0.status -eq "available")

    if ($tab0Live) {
        $liveCwd = [string]$tab0.newCwd

        $Terminal.path = $liveCwd

        if ([bool]$tab0.hadOverride) {
            Set-DevWSTerminalTabPathValue -Tab $tabs[0] -Path $liveCwd
        }
    }

    $fallbackAfter = [string]$Terminal.path

    for ($tabIndex = 1; $tabIndex -lt $tabs.Count; $tabIndex++) {
        if (-not $byIndex.ContainsKey($tabIndex)) { continue }

        $decision = $byIndex[$tabIndex]
        $live     = ([string]$decision.status -eq "available")

        if ([bool]$decision.hadOverride) {
            if ($live) {
                Set-DevWSTerminalTabPathValue -Tab $tabs[$tabIndex] -Path ([string]$decision.newCwd)
            }

            continue
        }

        $desired = $(if ($live) { [string]$decision.newCwd } else { [string]$decision.oldEffective })

        if ($desired -ne $fallbackAfter) {
            Set-DevWSTerminalTabPathValue -Tab $tabs[$tabIndex] -Path $desired
        }
    }
}

function Get-DevWSTerminalActiveTabSaveDecision {
    # Pass 6D fail-closed activeTab correlation. The sidecar reader returns an
    # id-keyed map with duplicate ids marked by a $null value; an update
    # requires ALL of: exactly one record for the terminal, a genuine
    # non-empty string windowId that matches the configured windowId
    # case-insensitively, a genuine non-empty string status token exactly
    # "available", and a genuine integer selectedConfiguredTabIndex (the
    # project integer policy - never a numeric string, a floating value, a
    # boolean, or null) inside the configured tab range. Anything else
    # preserves the old canonical value (never a locator-selected or visually
    # inferred tab).
    param(
        [Parameter(Mandatory)]
        $Terminal,
        $SnapshotMap
    )

    $terminalId = [string]$Terminal.id

    if ($null -eq $SnapshotMap -or -not ($SnapshotMap -is [System.Collections.IDictionary])) {
        return [pscustomobject]@{ Update = $false; Index = $null; Reason = "no-observation" }
    }

    if (-not $SnapshotMap.Contains($terminalId)) {
        return [pscustomobject]@{ Update = $false; Index = $null; Reason = "no-observation" }
    }

    $entry = $SnapshotMap[$terminalId]

    if ($null -eq $entry) {
        return [pscustomobject]@{ Update = $false; Index = $null; Reason = "duplicate-record" }
    }

    # Identity fields must be genuine strings; numeric or otherwise coerced
    # values never become a configured identity.
    if ($entry.windowId -isnot [string] -or [string]::IsNullOrWhiteSpace($entry.windowId)) {
        return [pscustomobject]@{ Update = $false; Index = $null; Reason = "malformed-record" }
    }

    if ([string]$entry.windowId -ine [string]$Terminal.windowId) {
        return [pscustomobject]@{ Update = $false; Index = $null; Reason = "window-mismatch" }
    }

    if ($entry.status -isnot [string]) {
        return [pscustomobject]@{ Update = $false; Index = $null; Reason = "malformed-record" }
    }

    $status = [string]$entry.status

    if ($status -cne "available") {
        if ([string]::IsNullOrWhiteSpace($status)) { $status = "unknown-status" }

        return [pscustomobject]@{ Update = $false; Index = $null; Reason = $status }
    }

    # The selected index must be a genuine integer (Test-DevWSInteger accepts
    # only int/int16/long). Coercible forms - "2", "0", "+2", " 2 ", "02",
    # 2.0, 2.5, booleans, null - are all rejected. The configured range check
    # runs on the wide value before any narrowing conversion.
    $rawIndex = $entry.selectedConfiguredTabIndex

    if (-not (Test-DevWSInteger $rawIndex)) {
        return [pscustomobject]@{ Update = $false; Index = $null; Reason = "selected-index-invalid" }
    }

    $indexValue = [long]$rawIndex
    $tabCount = @($Terminal.tabs).Count

    if ($indexValue -lt 0 -or $indexValue -ge $tabCount) {
        return [pscustomobject]@{ Update = $false; Index = $null; Reason = "selected-index-out-of-range" }
    }

    return [pscustomobject]@{ Update = $true; Index = [int]$indexValue; Reason = "ok" }
}

function Get-DevWSLayoutSaveScopeText {
    # Human storage-scope text for save output ("fallback layout" /
    # "profile '<id>'"); always appended as a separate sentence so the
    # established "…saved for set 'X'." sentence stays intact.
    param($Plan)

    if ($Plan.Source -eq "profile") { return "profile '$($Plan.ProfileId)'" }

    return "fallback layout"
}

function Set-DevWSLayoutSaveEntry {
    # Writes one captured rectangle into the resolved storage scope (in
    # memory only; the caller owns the single canonical save).
    param($Plan, $Item, $Rect)

    if ($Plan.Source -eq "profile") {
        Set-DevWSLayoutProfileRect -Profile $Plan.Profile -ItemId ([string]$Item.id) -Rect $Rect
    }
    else {
        Set-DevWSLayout -Item $Item -Rect $Rect
    }
}

function Get-DevWSLayoutSaveEffectiveRect {
    param($Plan, $Item)

    if ($Plan.Source -eq "profile" -and $null -ne $Plan.Profile) {
        $entry = Get-DevWSLayoutProfileEntry -Profile $Plan.Profile -ItemId ([string]$Item.id)

        if ($null -ne $entry) { return $entry }
    }

    return $Item.layout
}

function Get-DevWSLayoutSavePlan {
    # Pass 5C write-scope resolution for `ws save` / `ws save-layout`.
    # Topology A is sampled exactly once, and only when required:
    #   - an explicit --profile target (create-or-update),
    #   - or the set has profiles and needs implicit routing.
    # A profile-free implicit fallback write keeps the legacy path with no
    # monitor dependency at all.
    param($Context, $Target, [string]$ProfileId)

    $set = $Target.Set

    if (-not [string]::IsNullOrWhiteSpace($ProfileId)) {
        $topologyA = Get-DevWSMonitorTopology
        $decision  = Resolve-DevWSLayoutProfileSaveTarget -Set $set -ProfileId $ProfileId -Topology $topologyA

        if (-not $decision.Ok) {
            return [pscustomobject]@{ Ok = $false; Refusal = $decision.Refusal }
        }

        return [pscustomobject]@{
            Ok                          = $true
            Refusal                     = $null
            Set                         = $set
            Source                      = "profile"
            Profile                     = $decision.Profile
            ProfileId                   = $ProfileId
            Create                      = [bool]$decision.Create
            TopologyA                   = $topologyA
            RequireTopologyRevalidation = $true
        }
    }

    if (-not (Test-DevWSSetHasLayoutProfiles -Set $set)) {
        return [pscustomobject]@{
            Ok                          = $true
            Refusal                     = $null
            Set                         = $set
            Source                      = "fallback"
            Profile                     = $null
            ProfileId                   = $null
            Create                      = $false
            TopologyA                   = $null
            RequireTopologyRevalidation = $false
        }
    }

    $topologyA = Get-DevWSMonitorTopology
    $scope     = Resolve-DevWSLayoutWriteScope -Set $set -Topology $topologyA

    if (-not $scope.Ok) {
        return [pscustomobject]@{ Ok = $false; Refusal = $scope.Refusal }
    }

    return [pscustomobject]@{
        Ok                          = $true
        Refusal                     = $null
        Set                         = $set
        Source                      = $scope.Source
        Profile                     = $scope.Profile
        ProfileId                   = $scope.ProfileId
        Create                      = $false
        TopologyA                   = $topologyA
        RequireTopologyRevalidation = $true
    }
}

function Confirm-DevWSLayoutSaveTopology {
    # Topology stability gate: re-sample immediately before the canonical
    # commit and abort when the topology changed during capture. The caller's
    # finally block cleans capture temp files on every failure path.
    param($Plan)

    if (-not [bool]$Plan.RequireTopologyRevalidation) { return }

    $topologyB = Get-DevWSMonitorTopology
    $stability = Test-DevWSLayoutTopologyStable -First $Plan.TopologyA -Second $topologyB

    if (-not $stability.Stable) {
        throw "The monitor topology changed while capturing geometry ($($stability.Reason)); nothing was saved. Wait for docking/undocking display changes to settle, then retry."
    }
}

function Get-DevWSLayoutSaveTargetProfile {
    # Materializes an explicit-profile creation only after capture succeeded
    # and the topology stability gate passed; a half-empty profile is never
    # created. The matcher tokens come from the canonical topology signature.
    param($Plan)

    if ($Plan.Source -ne "profile") { return $null }
    if ($null -ne $Plan.Profile) { return $Plan.Profile }

    $profileObject = New-DevWSLayoutProfile -Id $Plan.ProfileId -MonitorTokens (Get-DevWSLayoutTopologyTokens -Topology $Plan.TopologyA)
    Add-DevWSLayoutProfile -Set $Plan.Set -Profile $profileObject
    $Plan.Profile = $profileObject

    return $profileObject
}

function Save-DevWSLayout {
    param([string]$SetId, [string]$ProfileId)

    $context = Get-DevWSContext
    Assert-DevWSConfigWritable -Location $context.Location
    $target = Resolve-DevWSLifecycleTarget -Config $context.Config -SetId $SetId

    $plan = Get-DevWSLayoutSavePlan -Context $context -Target $target -ProfileId $ProfileId

    if (-not $plan.Ok) { throw $plan.Refusal }

    $capture = Get-DevWSLiveLayoutCapture -SetId $SetId -Context $context

    if (($capture.Terminals.Count + $capture.Apps.Count) -eq 0) {
        if (@($capture.CaptureFiles).Count -gt 0) {
            Remove-Item @($capture.CaptureFiles) -Force -ErrorAction SilentlyContinue
        }
        Write-Host "No enabled workspace items to capture for set '$($capture.Target.SetId)'." -ForegroundColor DarkGray
        return
    }

    try {
        Confirm-DevWSLayoutSaveTopology -Plan $plan
        $null = Get-DevWSLayoutSaveTargetProfile -Plan $plan

        foreach ($app in $capture.Apps) {
            Set-DevWSLayoutSaveEntry -Plan $plan -Item $app -Rect $capture.AppGeometry[$app.id]
        }

        foreach ($terminal in $capture.Terminals) {
            Set-DevWSLayoutSaveEntry -Plan $plan -Item $terminal -Rect $capture.TerminalGeometry[$terminal.id]
        }

        Save-DevWSConfig -Config $capture.Context.Config -Location $capture.Context.Location
    }
    finally {
        if (@($capture.CaptureFiles).Count -gt 0) {
            Remove-Item @($capture.CaptureFiles) -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Write-Host "Layout saved for set '$($capture.Target.SetId)'. Storage: $(Get-DevWSLayoutSaveScopeText -Plan $plan)." -ForegroundColor Green
    Write-Host ""

    foreach ($item in @(Get-DevWSWindows -Config $capture.Context.Config -Set $capture.Target.Set)) {
        if (-not $item.enabled) {
            continue
        }

        $rect = Get-DevWSLayoutSaveEffectiveRect -Plan $plan -Item $item

        Write-Host ("  {0,-14} " -f $item.id) -ForegroundColor Yellow -NoNewline
        Write-Host ("x={0,5} y={1,5} w={2,5} h={3,5}" -f $rect.x, $rect.y, $rect.w, $rect.h)
    }

    Write-Host ""
}

function Save-DevWSWorkspace {
    # `ws save [set] [--profile <id>]`: geometry is the required
    # all-or-nothing gate and routes through the Pass 5C write scope (matched
    # profile / created or updated explicit profile / fallback). Reliable
    # per-configured-tab tracked cwd and the reliable configured activeTab are
    # opportunistic and always GLOBAL (never per profile); unavailable
    # optional state preserves the existing canonical value.
    #
    # Gate order: capture (with optional active-tab sidecar), per-tab cwd
    # decisions, topology stability, per-tab expected-generation consistency,
    # then in-memory geometry + per-tab cwd/path + startup-intent-retirement +
    # activeTab apply and exactly one canonical save; any gate failure leaves
    # the canonical file unchanged and cleanup still removes capture temp
    # files. Startup retirement is optional state derived ONLY after the final
    # generation gate; it never fails the save.
    param([string]$SetId, [string]$ProfileId)

    $context = Get-DevWSContext
    Assert-DevWSConfigWritable -Location $context.Location
    $target = Resolve-DevWSLifecycleTarget -Config $context.Config -SetId $SetId

    $plan = Get-DevWSLayoutSavePlan -Context $context -Target $target -ProfileId $ProfileId

    if (-not $plan.Ok) { throw $plan.Refusal }

    $capture = Get-DevWSLiveLayoutCapture -SetId $SetId -Context $context

    if (($capture.Terminals.Count + $capture.Apps.Count) -eq 0) {
        if (@($capture.CaptureFiles).Count -gt 0) {
            Remove-Item @($capture.CaptureFiles) -Force -ErrorAction SilentlyContinue
        }
        Write-Host "No enabled workspace items to save for set '$($capture.Target.SetId)'." -ForegroundColor DarkGray
        return
    }

    $saveDecisions       = [ordered]@{}
    $activeTabDecisions  = [ordered]@{}

    try {
        # Geometry is completely valid at this point. Only now resolve the
        # per-tab tracked cwd for the enabled terminals of the target set.
        $saveDecisions = Get-DevWSTerminalSaveDecisions `
            -SetId $capture.Target.SetId `
            -Terminals $capture.Terminals

        # Gate 1: topology stability (geometry storage scope).
        Confirm-DevWSLayoutSaveTopology -Plan $plan

        # Gate 2: per-tab expected-generation consistency. A reset may have
        # advanced the expected generation after the initial resolution;
        # changed generations downgrade ONLY that tab to unavailable so a
        # stale cwd is never persisted.
        Confirm-DevWSTerminalSaveDecisions -SetId $capture.Target.SetId -Decisions $saveDecisions

        $null = Get-DevWSLayoutSaveTargetProfile -Plan $plan

        foreach ($app in $capture.Apps) {
            Set-DevWSLayoutSaveEntry -Plan $plan -Item $app -Rect $capture.AppGeometry[$app.id]
        }

        foreach ($terminal in $capture.Terminals) {
            Set-DevWSLayoutSaveEntry -Plan $plan -Item $terminal -Rect $capture.TerminalGeometry[$terminal.id]
        }

        # Pass 6D in-memory save-state plan: per-tab paths + terminal.path.
        foreach ($terminal in $capture.Terminals) {
            Invoke-DevWSTerminalSaveState `
                -Terminal $terminal `
                -TabDecisions @($saveDecisions[[string]$terminal.id])
        }

        # Startup-intent retirement (accepted policy): the verdict is derived
        # ONLY after the final generation gate above, per configured tab,
        # against the CURRENT configured child. Preserved tabs keep their exact
        # command/args; a retirement is optional state and never fails the save.
        $retiredStartupTabs = [System.Collections.Generic.List[object]]::new()

        foreach ($terminal in $capture.Terminals) {
            $tabs = @($terminal.tabs)

            foreach ($decision in @($saveDecisions[[string]$terminal.id])) {
                $tabIndex = [int]$decision.tabIndex

                if ($tabIndex -lt 0 -or $tabIndex -ge $tabs.Count) {
                    continue
                }

                $verdict = Get-DevWSTabStartupRetirementDecision -Tab $tabs[$tabIndex] -Decision $decision

                if ([bool]$verdict.Retire) {
                    Invoke-DevWSTabStartupRetirement -Tab $tabs[$tabIndex]

                    $retiredStartupTabs.Add([pscustomobject]@{
                        TerminalId = [string]$terminal.id
                        TabIndex   = $tabIndex
                        Command    = [string]$verdict.Command
                    }) | Out-Null
                }
            }
        }

        # Pass 6D configured activeTab: only a correlated available snapshot
        # updates it; every other observation preserves the old value.
        foreach ($terminal in $capture.Terminals) {
            $decision = Get-DevWSTerminalActiveTabSaveDecision `
                -Terminal $terminal `
                -SnapshotMap $capture.TerminalTabSnapshots

            $activeTabDecisions[[string]$terminal.id] = [pscustomobject]@{
                Update = [bool]$decision.Update
                Index  = $decision.Index
                Reason = [string]$decision.Reason
                Old    = [int]$terminal.activeTab
            }

            if ($decision.Update) {
                $terminal.activeTab = [int]$decision.Index
            }
        }

        Save-DevWSConfig -Config $capture.Context.Config -Location $capture.Context.Location
    }
    finally {
        if (@($capture.CaptureFiles).Count -gt 0) {
            Remove-Item @($capture.CaptureFiles) -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ""
    Write-Host "State saved for set '$($capture.Target.SetId)'. Storage: $(Get-DevWSLayoutSaveScopeText -Plan $plan)." -ForegroundColor Green
    Write-Host ""

    foreach ($item in @(Get-DevWSWindows -Config $capture.Context.Config -Set $capture.Target.Set)) {
        if (-not $item.enabled) {
            continue
        }

        $rect = Get-DevWSLayoutSaveEffectiveRect -Plan $plan -Item $item

        Write-Host ("  {0,-14} " -f $item.id) -ForegroundColor Yellow -NoNewline
        Write-Host ("x={0,5} y={1,5} w={2,5} h={3,5}" -f $rect.x, $rect.y, $rect.w, $rect.h)

        if ($item.type -ne "terminal") {
            continue
        }

        foreach ($tabDecision in @($saveDecisions[[string]$item.id] | Sort-Object { [int]$_.tabIndex })) {
            $prefix = "                 tab " + [int]$tabDecision.tabIndex + " "

            if ([string]$tabDecision.status -eq "available") {
                $liveCwd = [string]$tabDecision.newCwd

                if ([string]$tabDecision.oldEffective -eq $liveCwd) {
                    Write-Host ($prefix + "cwd unchanged: " + $liveCwd) -ForegroundColor DarkGray
                }
                else {
                    Write-Host ($prefix + "cwd updated: " + $liveCwd) -ForegroundColor DarkGray
                }
            }
            else {
                Write-Host ($prefix + "cwd unavailable (" + [string]$tabDecision.reason + "); path kept: " + [string]$tabDecision.oldEffective) -ForegroundColor DarkGray
            }
        }

        # Startup-intent retirement output is additive and only prints AFTER the
        # single canonical save has succeeded (this block runs post-commit);
        # preserved tabs produce no line.
        foreach ($retired in @($retiredStartupTabs | Where-Object { $_.TerminalId -ceq [string]$item.id } | Sort-Object { [int]$_.TabIndex })) {
            Write-Host ("                 tab " + [int]$retired.TabIndex + " startup retired: " + [string]$retired.Command) -ForegroundColor DarkGray
        }

        $activeDecision = $activeTabDecisions[[string]$item.id]

        if ($null -eq $activeDecision) {
            continue
        }

        if ([bool]$activeDecision.Update) {
            if ([int]$activeDecision.Old -eq [int]$activeDecision.Index) {
                Write-Host ("                 activeTab " + [int]$activeDecision.Index + " unchanged") -ForegroundColor DarkGray
            }
            else {
                Write-Host ("                 activeTab " + [int]$activeDecision.Index + " (was " + [int]$activeDecision.Old + ")") -ForegroundColor DarkGray
            }
        }
        else {
            Write-Host ("                 activeTab " + [int]$activeDecision.Old + " preserved (" + [string]$activeDecision.Reason + ")") -ForegroundColor DarkGray
        }
    }

    Write-Host ""
}

function Show-DevWSLayout {
    # Read-only operational-layout view: current topology, profile routing,
    # relative placement, and skipped/fallback diagnostics. Launch and reset
    # consume the same frozen policy; ordinary set launch and explicit targeted
    # resets differ only by target selection.
    param([string]$SetId)

    $context = Get-DevWSContext
    $target  = Resolve-DevWSLifecycleTarget -Config $context.Config -SetId $SetId

    $defaultSet = Get-DevWSDefaultSet -Config $context.Config
    $suffix = ""

    if ($target.SetId -ieq ([string]$defaultSet.id)) {
        $suffix = " (default)"
    }

    $topology = Get-DevWSMonitorTopology
    $model    = Get-DevWSEffectiveLayout -SetId $target.SetId -Set $target.Set -Topology $topology

    Write-Host ""
    Write-Host "Saved layout for set '$($target.SetId)'$suffix" -ForegroundColor Cyan

    foreach ($line in @(Get-DevWSEffectiveLayoutLines -Model $model)) {
        Write-Host $line -ForegroundColor Yellow
    }

    Write-Host ""
}

function ConvertFrom-DevWSSaveArguments {
    # Reconstructs and parses `ws save` / `ws save-layout` tokens (Arg1 plus
    # the remaining literal arguments) into an optional set and an optional
    # `--profile <id>` selector. Works whether --profile arrives as the first
    # unbound switch-looking token or after an explicit set. Rejects duplicate
    # --profile, a missing value, unknown options and extra positional values.
    param(
        [AllowEmptyCollection()]
        [object[]]$Tokens = @(),
        [Parameter(Mandatory)]
        [string]$CommandName,
        [Parameter(Mandatory)]
        [string]$Usage
    )

    $setId     = $null
    $profileId = $null
    $index     = 0
    $tokenList = @($Tokens)

    while ($index -lt $tokenList.Count) {
        $token = [string]$tokenList[$index]

        if ($token -ieq "--profile") {
            if ($null -ne $profileId) {
                throw "Duplicate --profile for $CommandName. Usage: $Usage"
            }

            if (($index + 1) -ge $tokenList.Count) {
                throw "--profile requires a profile id. Usage: $Usage"
            }

            $candidate = [string]$tokenList[$index + 1]

            if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate.StartsWith('-')) {
                throw "--profile requires a profile id. Usage: $Usage"
            }

            $profileId = $candidate
            $index += 2
            continue
        }

        if ($token.StartsWith('-')) {
            throw "Unknown option '$token' for $CommandName. Usage: $Usage"
        }

        if ($null -ne $setId) {
            throw "Unexpected argument '$token'. Usage: $Usage"
        }

        $setId = $token
        $index += 1
    }

    return [pscustomobject]@{
        SetId     = $setId
        ProfileId = $profileId
    }
}

function Invoke-DevWSLayoutProfileCommand {
    # `ws layout-profile list|remove|match` - config-shaped profile
    # management. Never moves windows and never touches the fallback
    # item.layout; `list` is strictly read-only.
    param(
        [string]$Subcommand,
        [AllowEmptyCollection()]
        [object[]]$Arguments = @(),
        [switch]$SkipConfirmation
    )

    switch ([string]$Subcommand) {
        "list" {
            if (@($Arguments).Count -gt 1) {
                throw "Usage: ws layout-profile list [set]"
            }

            $context = Get-DevWSContext
            $setId = $null

            if (@($Arguments).Count -eq 1) {
                $setId = [string]$Arguments[0]
            }

            $target  = Resolve-DevWSLifecycleTarget -Config $context.Config -SetId $setId
            $topology = Get-DevWSMonitorTopology
            $model   = Get-DevWSLayoutProfileListModel -SetId $target.SetId -Set $target.Set -Topology $topology

            $defaultSet = Get-DevWSDefaultSet -Config $context.Config
            $suffix = ""

            if ($target.SetId -ieq ([string]$defaultSet.id)) {
                $suffix = " (default)"
            }

            Write-Host ""
            Write-Host "LAYOUT PROFILES: $($target.SetId)$suffix" -ForegroundColor Cyan
            Write-Host "────────────────────────────────────────────────────────"

            foreach ($line in @(Get-DevWSLayoutProfileLines -Model $model)) {
                Write-Host $line -ForegroundColor Yellow
            }

            Write-Host ""
        }

        "remove" {
            if (@($Arguments).Count -ne 1) {
                throw "Usage: ws layout-profile remove <profile|set/profile> [-Force]"
            }

            $context = Get-DevWSContext
            Assert-DevWSConfigWritable -Location $context.Location

            $resolved = Resolve-DevWSLayoutProfileReference `
                -Config $context.Config `
                -Reference ([string]$Arguments[0]) `
                -CommandName "ws layout-profile remove"

            $profileObject = Get-DevWSLayoutProfile -Set $resolved.Set -Id $resolved.ProfileId

            if ($null -eq $profileObject) {
                throw "Layout profile '$($resolved.ProfileId)' does not exist in set '$($resolved.SetId)'."
            }

            if (-not $SkipConfirmation) {
                Write-Host ""
                Write-Host "Remove layout profile '$($resolved.ProfileId)' from set '$($resolved.SetId)'?" -ForegroundColor Yellow
                Write-Host "Only that profile is removed; the fallback item.layout and all other profiles are left unchanged." -ForegroundColor DarkGray

                $answer = Read-Host "Continue? [y/N]"

                if ($answer -notmatch '^(?i:y|yes)$') {
                    Write-Host "Cancelled." -ForegroundColor DarkGray
                    return
                }
            }

            Remove-DevWSLayoutProfile -Set $resolved.Set -ProfileId $resolved.ProfileId
            Assert-DevWSConfig -Config $context.Config -Source "workspace mutation"
            Save-DevWSConfig -Config $context.Config -Location $context.Location

            $remaining = @(Get-DevWSLayoutProfiles -Set $resolved.Set)

            Write-Host ""
            Write-Host "Removed layout profile '$($resolved.ProfileId)' from set '$($resolved.SetId)'." -ForegroundColor Green

            if ($remaining.Count -eq 0) {
                Write-Host "Set '$($resolved.SetId)' has no remaining profiles; the layoutProfiles property was removed." -ForegroundColor DarkGray
            }

            Write-Host ""
        }

        "match" {
            if (@($Arguments).Count -ne 1) {
                throw "Usage: ws layout-profile match <profile|set/profile>"
            }

            $context = Get-DevWSContext
            Assert-DevWSConfigWritable -Location $context.Location

            $resolved = Resolve-DevWSLayoutProfileReference `
                -Config $context.Config `
                -Reference ([string]$Arguments[0]) `
                -CommandName "ws layout-profile match"

            $profileObject = Get-DevWSLayoutProfile -Set $resolved.Set -Id $resolved.ProfileId

            if ($null -eq $profileObject) {
                throw "Layout profile '$($resolved.ProfileId)' does not exist in set '$($resolved.SetId)'."
            }

            $topology    = Get-DevWSMonitorTopology
            $eligibility = Test-DevWSLayoutTopologyMatchable -Topology $topology

            if (-not $eligibility.Eligible) {
                throw "The current monitor topology is not safely matchable ($($eligibility.Reason)); no profile was re-keyed. Nothing was changed."
            }

            $signature = [string]$topology.Signature

            foreach ($otherProfile in @(Get-DevWSLayoutProfiles -Set $resolved.Set)) {
                if (([string]$otherProfile.id) -ieq $resolved.ProfileId) { continue }

                $otherSignature = Get-DevWSLayoutProfileMatcherSignature -Profile $otherProfile

                if ($null -ne $otherSignature -and
                    [string]::Equals($otherSignature, $signature, [System.StringComparison]::Ordinal)) {
                    throw "The current topology is already matched by profile '$([string]$otherProfile.id)'; two profiles in one set cannot share a matcher. Nothing was changed."
                }
            }

            Set-DevWSLayoutProfileMatcher -Profile $profileObject -MonitorTokens (Get-DevWSLayoutTopologyTokens -Topology $topology)
            Assert-DevWSConfig -Config $context.Config -Source "workspace mutation"
            Save-DevWSConfig -Config $context.Config -Location $context.Location

            $monitorTokenCount = @(Get-DevWSLayoutTopologyTokens -Topology $topology).Count

            Write-Host ""
            Write-Host "Re-keyed layout profile '$($resolved.ProfileId)' in set '$($resolved.SetId)' to the current topology ($monitorTokenCount monitor token(s))." -ForegroundColor Green
            Write-Host "Stored layout overrides were preserved; only match.mode/match.monitors changed." -ForegroundColor DarkGray
            Write-Host ""
            Write-Host "The matching profile is applied automatically by 'ws launch' and terminal resets." -ForegroundColor DarkGray
            Write-Host ""
        }

        default {
            throw "Usage: ws layout-profile <list|remove|match> ... (see 'ws help layout-profile')"
        }
    }
}

function Invoke-DevWSTerminalReset {
    # The normal side owns the frozen placement decision; the elevated worker
    # receives final records only (id + move + exact geometry).
    param(
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$TerminalPlacements = @()
    )

    $taskName = "DevWorkspace-ElevatedReset"

    # TASK_STATE_RUNNING = 4; every other state proceeds exactly as before.
    $taskState = Get-DevWSRootScheduledTaskState -TaskName $taskName

    if ($taskState -eq 4) {
        throw "A workspace terminal reset is already running."
    }

    [void](Invoke-DevWSWorkerRequest `
        -Kind "reset" `
        -TaskName $taskName `
        -Payload @{ setId = $SetId; terminalPlacements = @($TerminalPlacements) } `
        -TimeoutSeconds 180)
}

function Reset-DevWSTerminal {
    param(
        [string]$Reference
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "Usage: ws reset <id|number|set/id>"
    }

    $context = Get-DevWSContext
    $configReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Reference -CommandName "ws reset"

    if ($configReference.Scoped) {
        # Scoped references are stable-id only; there are no scoped ordinals.
        $terminal = Resolve-DevWSTerminalById -Config $context.Config -Reference $configReference.ItemId -CommandName "ws reset" -Set $configReference.Set
    }
    else {
        # Unscoped numeric references keep the historical 1-based terminal
        # order within defaultSet.
        $terminal = Resolve-DevWSReference -Config $context.Config -Reference $configReference.ItemId -Type terminal -Set $configReference.Set
    }

    # A single reset validates only the selected terminal's path: another
    # enabled terminal in the same set with a missing directory must not block
    # resetting this one. The reset worker re-validates the exact terminal
    # before any destructive work.
    Assert-DevWSTerminalPath -Terminal $terminal -SetId $configReference.SetId -Source "ws reset"
    Assert-DevWSElevatedTerminals -Terminals @($terminal)

    # The frozen placement decision targets exactly this terminal (selected
    # even when disabled). Profile-aware fatals refuse here, before any
    # worker request; an unreachable fallback rectangle resets the terminal
    # without moving it.
    $layoutPlan = New-DevWSLifecycleLayoutPlan `
        -Config $context.Config `
        -SetId $configReference.SetId `
        -Set $configReference.Set `
        -Items @($terminal)

    Invoke-DevWSTerminalReset `
        -SetId $configReference.SetId `
        -TerminalPlacements @(Get-DevWSLifecycleTerminalPlacementRecords -Plan $layoutPlan)

    $label = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $configReference.SetId -ItemId $terminal.id -Scoped:$configReference.Scoped

    Write-Host ""
    Write-Host "Terminal '$label' recreated." -ForegroundColor Green
    Write-Host "  $($terminal.path)"
    Write-Host ""

    foreach ($warning in @($layoutPlan.Warnings)) {
        Write-Host $warning -ForegroundColor Yellow
    }
}

function Reset-DevWSTerminals {
    param(
        [string]$SetId,
        [switch]$SkipConfirmation
    )

    $context = Get-DevWSContext
    $target  = Resolve-DevWSLifecycleTarget -Config $context.Config -SetId $SetId

    $terminals = @(Get-DevWSEnabledItems -Config $context.Config -Set $target.Set -Type "terminal")

    if ($terminals.Count -eq 0) {
        Write-Host "Set '$($target.SetId)' has no enabled terminals to reset." -ForegroundColor DarkGray
        return
    }

    Assert-DevWSTerminalPaths -Config $context.Config -Set $target.Set -Source "ws reset-terminals"
    Assert-DevWSElevatedTerminals -Terminals $terminals

    if (-not $SkipConfirmation) {
        Write-Host ""
        Write-Host "This will close and recreate $($terminals.Count) managed Terminal window(s) in set '$($target.SetId)':" -ForegroundColor Yellow

        foreach ($terminal in $terminals) {
            Write-Host ("  {0}  {1}" -f $terminal.id, $terminal.path)
        }

        $answer = Read-Host "Continue? [y/N]"

        if ($answer -notmatch '^(?i:y|yes)$') {
            Write-Host "Cancelled." -ForegroundColor DarkGray
            return
        }
    }

    # One topology snapshot for ALL selected terminals: the frozen placement
    # plan is built once, after confirmation, before any worker request.
    $layoutPlan = New-DevWSLifecycleLayoutPlan `
        -Config $context.Config `
        -SetId $target.SetId `
        -Set $target.Set `
        -Items $terminals

    Invoke-DevWSTerminalReset `
        -SetId $target.SetId `
        -TerminalPlacements @(Get-DevWSLifecycleTerminalPlacementRecords -Plan $layoutPlan)

    Write-Host ""
    Write-Host "All enabled terminals in set '$($target.SetId)' recreated." -ForegroundColor Green

    foreach ($terminal in $terminals) {
        Write-Host ("  {0}  {1}" -f $terminal.id, $terminal.path)
    }

    Write-Host ""

    foreach ($warning in @($layoutPlan.Warnings)) {
        Write-Host $warning -ForegroundColor Yellow
    }
}

function Invoke-DevWSEnableItem {
    param([string]$Reference)

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "Usage: ws enable <id>"
    }

    $context = Get-DevWSContext
    $configReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Reference -CommandName "ws enable"
    $result = Set-DevWSItemEnabled -Config $context.Config -Reference $configReference.ItemId -Set $configReference.Set -Enabled $true -CommandName "ws enable"
    $label = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $configReference.SetId -ItemId $result.Item.id -Scoped:$configReference.Scoped

    if ($result.Changed) {
        Save-DevWSConfig -Config $context.Config -Location $context.Location
        Write-Host "Enabled '$label' [$($result.Item.type)]." -ForegroundColor Green
    }
    else {
        Write-Host "'$label' is already enabled." -ForegroundColor DarkGray
    }
}

function Invoke-DevWSDisableItem {
    param([string]$Reference)

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "Usage: ws disable <id>"
    }

    $context = Get-DevWSContext
    $configReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Reference -CommandName "ws disable"
    $result = Set-DevWSItemEnabled -Config $context.Config -Reference $configReference.ItemId -Set $configReference.Set -Enabled $false -CommandName "ws disable"
    $label = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $configReference.SetId -ItemId $result.Item.id -Scoped:$configReference.Scoped

    if ($result.Changed) {
        Save-DevWSConfig -Config $context.Config -Location $context.Location
        Write-Host "Disabled '$label' [$($result.Item.type)]." -ForegroundColor Green
    }
    else {
        Write-Host "'$label' is already disabled." -ForegroundColor DarkGray
    }

    Write-Host "Running windows were not closed." -ForegroundColor DarkGray
}

function Invoke-DevWSRemoveItem {
    param(
        [string]$Reference,
        [switch]$SkipConfirmation
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "Usage: ws remove <id> [-Force]"
    }

    $context = Get-DevWSContext
    $configReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Reference -CommandName "ws remove"
    $item = Resolve-DevWSItemById -Config $context.Config -Reference $configReference.ItemId -CommandName "ws remove" -Set $configReference.Set
    $label = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $configReference.SetId -ItemId $item.id -Scoped:$configReference.Scoped

    if (-not $SkipConfirmation) {
        $answer = Read-Host "Remove workspace item '$label' [$($item.type)]? [y/N]"

        if ($answer -notmatch '^(?i:y|yes)$') {
            Write-Host "Cancelled." -ForegroundColor DarkGray
            return
        }
    }

    [void](Remove-DevWSItem -Config $context.Config -Reference $item.id -Set $configReference.Set -CommandName "ws remove")
    Save-DevWSConfig -Config $context.Config -Location $context.Location

    Write-Host "Removed '$label' [$($item.type)] from the configuration." -ForegroundColor Green
    Write-Host "No running window was closed and no files were deleted." -ForegroundColor DarkGray
}

function Invoke-DevWSAddTerminal {
    param(
        [string]$Id,
        [string]$PathText,
        [AllowEmptyString()]
        [string]$CommandText,
        [AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($PathText)) {
        throw "Usage: ws add-terminal <id> <path> [command] [args...]"
    }

    $context = Get-DevWSContext
    $configReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Id -CommandName "ws add-terminal"
    $resolvedPath = Resolve-DevWSDirectoryPath -PathText $PathText

    $item = Add-DevWSTerminal `
        -Config $context.Config `
        -Set $configReference.Set `
        -Id $configReference.ItemId `
        -Path $resolvedPath `
        -Command $CommandText `
        -Arguments $Arguments

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    $label = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $configReference.SetId -ItemId $item.id -Scoped:$configReference.Scoped

    Write-Host "Added terminal '$label'." -ForegroundColor Green
    Write-Host "  windowId: $($item.windowId)"
    Write-Host "  path:     $($item.path)"
    Write-Host "  tabs:     $(Get-DevWSTerminalTabSummary -Terminal $item)"
    Write-Host "  layout:   x=$($item.layout.x) y=$($item.layout.y) w=$($item.layout.w) h=$($item.layout.h)"
    Write-Host ""
    Write-Host "Config only: the terminal was not launched." -ForegroundColor DarkGray
    Write-Host "Run 'ws launch', position the window, then 'ws save-layout' to persist its geometry." -ForegroundColor DarkGray
}

function Invoke-DevWSAddApp {
    param(
        [string]$Id,
        [string]$LaunchKind,
        [string]$LaunchValue,
        [string]$MatchKind,
        [string]$MatchValue,
        [string]$InstanceMode
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        throw "Usage: ws add-app <id> <launch-kind> <launch-value> <match-kind> <match-value> <instance-mode>"
    }

    if ([string]::IsNullOrWhiteSpace($InstanceMode)) {
        throw "Usage: ws add-app <id> <launch-kind> <launch-value> <match-kind> <match-value> <instance-mode>. Every app requires an explicit 'dedicated' or 'shared' instance mode."
    }

    $context = Get-DevWSContext
    $configReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Id -CommandName "ws add-app"

    $item = Add-DevWSApp `
        -Config $context.Config `
        -Set $configReference.Set `
        -Id $configReference.ItemId `
        -LaunchKind $LaunchKind `
        -LaunchValue $LaunchValue `
        -MatchKind $MatchKind `
        -MatchValue $MatchValue `
        -InstanceMode $InstanceMode

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    $label = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $configReference.SetId -ItemId $item.id -Scoped:$configReference.Scoped

    Write-Host "Added app '$label'." -ForegroundColor Green
    Write-Host "  match:    $($item.match.kind) '$($item.match.value)'"
    Write-Host "  launch:   $($item.launch.kind) '$($item.launch.value)'"
    Write-Host "  mode:     $($item.instanceMode)"
    Write-Host "  layout:   x=$($item.layout.x) y=$($item.layout.y) w=$($item.layout.w) h=$($item.layout.h)"
    Write-Host ""
    Write-Host "Config only: the app was not launched." -ForegroundColor DarkGray
    Write-Host "Run 'ws launch', position the window, then 'ws save-layout' to persist its geometry." -ForegroundColor DarkGray
}

function Invoke-DevWSSetInstanceMode {
    param(
        [string]$Reference,
        [string]$Mode
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "Usage: ws set-instance-mode <app-id> <dedicated|shared>"
    }

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        throw "Usage: ws set-instance-mode <app-id> <dedicated|shared>"
    }

    $context = Get-DevWSContext
    Assert-DevWSConfigWritable -Location $context.Location

    $canonicalMode = Resolve-DevWSInstanceModeValue -Mode $Mode

    # Resolve the reference (scoped references allowed) to learn the canonical
    # stable app id, then apply the mode to every app definition with that id
    # across all sets: instanceMode is a global same-id consistency contract.
    $configReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Reference -CommandName "ws set-instance-mode"
    $targetApp = Resolve-DevWSAppById -Config $context.Config -Reference $configReference.ItemId -CommandName "ws set-instance-mode" -Set $configReference.Set
    $appId = [string]$targetApp.id

    $changed = [System.Collections.Generic.List[string]]::new()

    foreach ($set in @(Get-DevWSSets -Config $context.Config)) {
        if ($null -eq $set) {
            continue
        }

        foreach ($item in @($set.windows)) {
            if ($null -eq $item -or $item.type -ne "app") {
                continue
            }

            if (([string]$item.id) -ine $appId) {
                continue
            }

            $item | Add-Member -NotePropertyName "instanceMode" -NotePropertyValue $canonicalMode -Force
            $changed.Add("$([string]$set.id)/$([string]$item.id)") | Out-Null
        }
    }

    Assert-DevWSConfig -Config $context.Config -Source "workspace mutation"

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    return [pscustomobject]@{
        AppId   = $appId
        Mode    = $canonicalMode
        Changed = @($changed.ToArray())
    }
}

function Invoke-DevWSSetLaunch {
    param(
        [string]$Reference,
        [string]$Kind,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "Usage: ws set-launch <app-id> <kind> <value>"
    }

    $context = Get-DevWSContext
    $configReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Reference -CommandName "ws set-launch"
    $app = Resolve-DevWSAppById -Config $context.Config -Reference $configReference.ItemId -CommandName "ws set-launch" -Set $configReference.Set

    [void](Set-DevWSAppLaunch -Config $context.Config -App $app -Kind $Kind -Value $Value)

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    $label = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $configReference.SetId -ItemId $app.id -Scoped:$configReference.Scoped

    Write-Host "App '$label' launch definition updated." -ForegroundColor Green
    Write-Host "  launch: $($app.launch.kind) '$($app.launch.value)'"
    Write-Host ""
    Write-Host "Config only: the running app was not relaunched." -ForegroundColor DarkGray
    Write-Host "The new definition applies the next time DevWS launches the app." -ForegroundColor DarkGray
}

function Invoke-DevWSSetMatch {
    param(
        [string]$Reference,
        [string]$Kind,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "Usage: ws set-match <app-id> <kind> <value>"
    }

    $context = Get-DevWSContext
    $configReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Reference -CommandName "ws set-match"
    $app = Resolve-DevWSAppById -Config $context.Config -Reference $configReference.ItemId -CommandName "ws set-match" -Set $configReference.Set

    [void](Set-DevWSAppMatch -Config $context.Config -App $app -Kind $Kind -Value $Value)

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    $label = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $configReference.SetId -ItemId $app.id -Scoped:$configReference.Scoped

    Write-Host "App '$label' match definition updated." -ForegroundColor Green
    Write-Host "  match: $($app.match.kind) '$($app.match.value)'"
    Write-Host ""
    Write-Host "Config only: no live window lookup was performed and the app was not restarted." -ForegroundColor DarkGray
}

function Invoke-DevWSSetAppArgs {
    param(
        [string]$Reference,
        [AllowEmptyCollection()]
        [string[]]$Arguments = @(),
        [switch]$Clear
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "Usage: ws set-app-args <app-id> <arg1> [arg2 ...] (use --clear to remove all arguments)"
    }

    $context = Get-DevWSContext
    $configReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Reference -CommandName "ws set-app-args"
    $app = Resolve-DevWSAppById -Config $context.Config -Reference $configReference.ItemId -CommandName "ws set-app-args" -Set $configReference.Set

    $argumentList = @()

    if (-not $Clear) {
        $argumentList = @($Arguments)
    }

    [void](Set-DevWSAppArguments -Config $context.Config -App $app -Arguments $argumentList)

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    $label = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $configReference.SetId -ItemId $app.id -Scoped:$configReference.Scoped

    if ($Clear) {
        Write-Host "App '$label' launch arguments cleared." -ForegroundColor Green
    }
    else {
        Write-Host "App '$label' launch arguments updated." -ForegroundColor Green
    }

    if (@($app.launch.args).Count -gt 0) {
        $quoted = @($app.launch.args | ForEach-Object { "'" + $_ + "'" })
        Write-Host "  args: $($quoted -join ' ')"
    }
    else {
        Write-Host "  args: (none)"
    }

    Write-Host ""
    Write-Host "Config only: the running app was not relaunched." -ForegroundColor DarkGray
}

function Invoke-DevWSRename {
    param(
        [string]$Reference,
        [string]$NewId
    )

    if ([string]::IsNullOrWhiteSpace($Reference) -or [string]::IsNullOrWhiteSpace($NewId)) {
        throw "Usage: ws rename <old-id> <new-id>"
    }

    if ($NewId.Contains('/')) {
        throw "Usage: ws rename <ref> <new-id>: the new id must not contain '/'; rename cannot move an item between sets."
    }

    $context = Get-DevWSContext
    $configReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Reference -CommandName "ws rename"
    $result = Rename-DevWSItem -Config $context.Config -Reference $configReference.ItemId -NewId $NewId -CommandName "ws rename" -Set $configReference.Set

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    $item = $result.Item
    $oldLabel = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $configReference.SetId -ItemId $result.OldId -Scoped:$configReference.Scoped
    $newLabel = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $configReference.SetId -ItemId $result.NewId -Scoped:$configReference.Scoped

    if ($item.type -eq "terminal") {
        Write-Host "Renamed terminal '$oldLabel' -> '$newLabel'." -ForegroundColor Green
        Write-Host "  windowId: $($item.windowId) (preserved)"
        Write-Host ""
        Write-Host "Config only: the running terminal was not renamed or recreated." -ForegroundColor DarkGray
        Write-Host "Runtime identity will be rediscovered on a later lifecycle operation if needed." -ForegroundColor DarkGray
    }
    else {
        Write-Host "Renamed app '$oldLabel' -> '$newLabel'." -ForegroundColor Green
        Write-Host ""
        Write-Host "Config only: the running app was not changed." -ForegroundColor DarkGray
    }
}

function Invoke-DevWSCloneTerminal {
    param(
        [string]$Reference,
        [string]$NewId
    )

    if ([string]::IsNullOrWhiteSpace($Reference) -or [string]::IsNullOrWhiteSpace($NewId)) {
        throw "Usage: ws clone-terminal <source-ref> <target-ref>"
    }

    $context = Get-DevWSContext
    $sourceReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Reference -CommandName "ws clone-terminal"
    $targetReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $NewId -CommandName "ws clone-terminal"

    # Scoped target -> explicit target set; unscoped target -> the source set
    # (historical same-set clone behavior).
    $targetSet = $sourceReference.Set

    if ($targetReference.Scoped) {
        $targetSet = $targetReference.Set
    }

    $result = Clone-DevWSTerminal `
        -Config $context.Config `
        -SourceId $sourceReference.ItemId `
        -NewId $targetReference.ItemId `
        -Set $targetSet `
        -SourceSet $sourceReference.Set `
        -CommandName "ws clone-terminal"

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    $clone = $result.Clone
    $sourceLabel = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $sourceReference.SetId -ItemId $result.SourceId -Scoped:$sourceReference.Scoped
    $cloneScoped = ($targetReference.Scoped -or -not (([string]$targetSet.id) -ieq $sourceReference.SetId))
    $cloneLabel = Get-DevWSItemDisplayLabel -Config $context.Config -SetId ([string]$targetSet.id) -ItemId $clone.id -Scoped:$cloneScoped

    Write-Host "Cloned terminal '$sourceLabel' -> '$cloneLabel'." -ForegroundColor Green
    Write-Host "  windowId: $($clone.windowId)"
    Write-Host "  path:     $($clone.path)"
    Write-Host "  tabs:     $(Get-DevWSTerminalTabSummary -Terminal $clone)"
    Write-Host "  enabled:  $($clone.enabled)"
    Write-Host "  elevated: $($clone.elevated)"
    Write-Host ""
    Write-Host "Config only: no terminal was launched." -ForegroundColor DarkGray
    Write-Host "Run 'ws launch', position the window, then 'ws save-layout' to persist its geometry." -ForegroundColor DarkGray
}

function Invoke-DevWSCloneApp {
    param(
        [string]$Reference,
        [string]$NewId
    )

    if ([string]::IsNullOrWhiteSpace($Reference) -or [string]::IsNullOrWhiteSpace($NewId)) {
        throw "Usage: ws clone-app <source-id> <new-id>"
    }

    $context = Get-DevWSContext
    $sourceReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Reference -CommandName "ws clone-app"
    $targetReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $NewId -CommandName "ws clone-app"

    # Scoped target -> explicit target set; unscoped target -> the source set
    # (historical same-set clone behavior).
    $targetSet = $sourceReference.Set

    if ($targetReference.Scoped) {
        $targetSet = $targetReference.Set
    }

    $result = Clone-DevWSApp `
        -Config $context.Config `
        -SourceId $sourceReference.ItemId `
        -NewId $targetReference.ItemId `
        -Set $targetSet `
        -SourceSet $sourceReference.Set `
        -CommandName "ws clone-app"

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    $clone = $result.Clone
    $sourceLabel = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $sourceReference.SetId -ItemId $result.SourceId -Scoped:$sourceReference.Scoped
    $cloneScoped = ($targetReference.Scoped -or -not (([string]$targetSet.id) -ieq $sourceReference.SetId))
    $cloneLabel = Get-DevWSItemDisplayLabel -Config $context.Config -SetId ([string]$targetSet.id) -ItemId $clone.id -Scoped:$cloneScoped

    Write-Host "Cloned app '$sourceLabel' -> '$cloneLabel'." -ForegroundColor Green
    Write-Host "  enabled: false"
    Write-Host "  match:   $($clone.match.kind) '$($clone.match.value)'"
    Write-Host "  launch:  $($clone.launch.kind) '$($clone.launch.value)'"
    Write-Host ""
    Write-Host "The clone is disabled because it initially shares the source match rule." -ForegroundColor DarkGray
    Write-Host "Configure its launch/match definition, then run:" -ForegroundColor DarkGray
    Write-Host "  ws enable $cloneLabel" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Config only: no app was launched." -ForegroundColor DarkGray
}

function Invoke-DevWSSetGeometry {
    # `ws set-geometry <item-ref> --x ... --y ... --width ... --height ...
    #  [--layout <profileId|fallback>]`
    #
    # Storage scope (Pass 5C):
    #   --layout fallback / --layout <profileId>  explicit; topology is NOT
    #                                             consulted or required;
    #   implicit: profile-free set -> fallback (legacy behavior, no monitor
    #             dependency); profile set -> the same routing a same-moment
    #             launch placement uses (matched profile else fallback), and an
    #             unsafe topology refuses the write.
    # Config only: the live window is never moved, resized or focused.
    param(
        [string]$Reference,
        [AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "Usage: ws set-geometry <id> --x <x> --y <y> --width <width> --height <height> [--layout <profileId|fallback>]"
    }

    $geometry = ConvertFrom-DevWSGeometryArguments -Parts $Arguments -CommandName "ws set-geometry" -AllowLayoutSelector

    $context = Get-DevWSContext
    $configReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Reference -CommandName "ws set-geometry"
    $item = Resolve-DevWSItemById -Config $context.Config -Reference $configReference.ItemId -CommandName "ws set-geometry" -Set $configReference.Set
    $itemSet = $configReference.Set

    $newRect = [pscustomobject]@{
        x = [int]$geometry.x
        y = [int]$geometry.y
        w = [int]$geometry.w
        h = [int]$geometry.h
    }

    $storageScope  = $null   # 'fallback' | 'profile'
    $targetProfile = $null

    if ($null -ne $geometry.Layout) {
        # Explicit storage selector: the user named the exact scope; no
        # monitor snapshot is taken merely to edit named config storage.
        if ($geometry.Layout -ieq "fallback") {
            $storageScope = "fallback"
        }
        else {
            $targetProfile = Get-DevWSLayoutProfile -Set $itemSet -Id $geometry.Layout

            if ($null -eq $targetProfile) {
                $known = @(Get-DevWSLayoutProfiles -Set $itemSet | ForEach-Object { [string]$_.id }) -join ", "

                if ([string]::IsNullOrWhiteSpace($known)) { $known = "(none)" }

                throw "Layout profile '$($geometry.Layout)' does not exist in set '$([string]$itemSet.id)'. Configured profiles: $known"
            }

            $storageScope = "profile"
        }
    }
    elseif (-not (Test-DevWSSetHasLayoutProfiles -Set $itemSet)) {
        $storageScope = "fallback"
    }
    else {
        $topology = Get-DevWSMonitorTopology
        $scope    = Resolve-DevWSLayoutWriteScope -Set $itemSet -Topology $topology

        if (-not $scope.Ok) {
            throw $scope.Refusal
        }

        if ($scope.Source -eq "profile") {
            $storageScope  = "profile"
            $targetProfile = $scope.Profile
        }
        else {
            $storageScope = "fallback"
        }
    }

    $oldText = $null

    if ($storageScope -eq "profile") {
        $oldEntry = Get-DevWSLayoutProfileEntry -Profile $targetProfile -ItemId ([string]$item.id)

        if ($null -ne $oldEntry) {
            $oldText = "x=$($oldEntry.x) y=$($oldEntry.y) w=$($oldEntry.w) h=$($oldEntry.h)"
        }
        else {
            $oldText = "(no profile entry yet)"
        }

        Set-DevWSLayoutProfileRect -Profile $targetProfile -ItemId ([string]$item.id) -Rect $newRect

        Assert-DevWSConfig -Config $context.Config -Source "workspace mutation"
    }
    else {
        $oldText = "x=$([int]$item.layout.x) y=$([int]$item.layout.y) w=$([int]$item.layout.w) h=$([int]$item.layout.h)"

        [void](Set-DevWSItemGeometry `
            -Config $context.Config `
            -Item $item `
            -X $geometry.x `
            -Y $geometry.y `
            -W $geometry.w `
            -H $geometry.h)
    }

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    $label = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $configReference.SetId -ItemId $item.id -Scoped:$configReference.Scoped

    if ($storageScope -eq "profile") {
        $scopeText = "profile '$([string]$targetProfile.id)'"
    }
    else {
        $scopeText = "fallback layout"
    }

    Write-Host "Updated layout for '$label'. Scope: $scopeText." -ForegroundColor Green
    Write-Host "  old: $oldText"
    Write-Host "  new: x=$($newRect.x) y=$($newRect.y) w=$($newRect.w) h=$($newRect.h)"
    Write-Host ""
    Write-Host "Config only: the live window was not moved or resized." -ForegroundColor DarkGray
    Write-Host "Layout changes take effect on the next 'ws launch' or terminal reset." -ForegroundColor DarkGray
}

function Invoke-DevWSResetLayout {
    param(
        [string]$SetId,
        [switch]$SkipConfirmation
    )

    $context = Get-DevWSContext

    # Bare reset-layout targets defaultSet; an explicit set id targets that set.
    # Sets are independent: no baseline is inherited from another set.
    $targetSet = Get-DevWSDefaultSet -Config $context.Config

    if (-not [string]::IsNullOrWhiteSpace($SetId)) {
        $targetSet = Resolve-DevWSSet -Config $context.Config -Reference $SetId
    }

    $defaultPath = Find-DevWSBundledDefaultConfig -StartPath $PSScriptRoot

    if ([string]::IsNullOrWhiteSpace($defaultPath)) {
        throw "Bundled default config not found (expected config\workspace.default.json in the repository or installed app layout)."
    }

    $defaultConfig = Read-DevWSConfigFile -Path $defaultPath

    # Check the bundled baseline before asking anything: if the set has no
    # bundled baseline there is nothing that could be reset.
    $result = Reset-DevWSLayoutsFromDefault `
        -Config $context.Config `
        -Set $targetSet `
        -DefaultConfig $defaultConfig `
        -DefaultSource $defaultPath

    if (-not $result.BaselineFound) {
        Write-Host ""
        Write-Host "Set '$($targetSet.id)' has no bundled default layout baseline; nothing was changed." -ForegroundColor DarkGray
        Write-Host "Bundled defaults define: $(@(Get-DevWSSets -Config $defaultConfig).id -join ', ')" -ForegroundColor DarkGray
        return
    }

    if (-not $SkipConfirmation) {
        Write-Host ""
        Write-Host "Restore saved geometry from the bundled default for matching items in set '$($targetSet.id)'?" -ForegroundColor Yellow
        Write-Host "Live windows will not be moved until a later lifecycle operation." -ForegroundColor DarkGray

        $answer = Read-Host "Continue? [y/N]"

        if ($answer -notmatch '^(?i:y|yes)$') {
            Write-Host "Cancelled." -ForegroundColor DarkGray
            return
        }
    }

    $matched = @($result.Matches)
    $skipped = @($result.Skipped)

    if ($matched.Count -eq 0) {
        Write-Host ""
        Write-Host "No configured items matched the bundled default layout." -ForegroundColor DarkGray
        Write-Host "Config unchanged." -ForegroundColor DarkGray
        return
    }

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    Write-Host ""
    Write-Host "Restored saved layout for $($matched.Count) item(s):" -ForegroundColor Green

    foreach ($match in $matched) {
        if ($match.MatchedBy -eq "windowId") {
            Write-Host "  $($match.Item.id) <- bundled terminal '$($match.Default.id)' via windowId $($match.Item.windowId)"
        }
        else {
            Write-Host "  $($match.Item.id)"
        }
    }

    if ($skipped.Count -gt 0) {
        Write-Host ""
        Write-Host "Skipped $($skipped.Count) item(s) with no bundled default match:"

        foreach ($item in $skipped) {
            Write-Host "  $($item.id)"
        }
    }

    if (Test-DevWSSetHasLayoutProfiles -Set $targetSet) {
        Write-Host ""
        Write-Host "Topology layout profiles were left unchanged (reset-layout restores fallback item.layout only)." -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "Config only: no live windows were moved or resized." -ForegroundColor DarkGray
    Write-Host "Run 'ws launch' to apply the restored layout." -ForegroundColor DarkGray
}

function Invoke-DevWSSetPath {
    param(
        [string]$Reference,
        [string]$PathText,
        [AllowEmptyCollection()]
        [string[]]$PathParts = @(),
        [switch]$AllowNumericAlias
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        if ($AllowNumericAlias) {
            throw "Usage: ws set <id|number> <path>"
        }

        throw "Usage: ws set-path <id> <path>"
    }

    $tokens   = @($PathParts)
    $useTab   = $false
    $tabIndex = -1
    $clearTab = $false

    # Flat Pass 6C grammar, parsed only in the CONTROL position (the tokens
    # before the path begins; switch-looking path content after that is never
    # reinterpreted):
    #   ws set-path <id> <path...>                     legacy: terminal.path
    #   ws set-path <id> --tab <n> <path...>           one tab's override
    #   ws set-path <id> --tab <n> --clear             remove that override
    if ($tokens.Count -gt 0 -and $tokens[0] -eq "--tab") {
        $useTab = $true

        if ($tokens.Count -lt 2) {
            throw "Usage: ws set-path <id> --tab <n> <path> | ws set-path <id> --tab <n> --clear"
        }

        if ($tokens[1] -notmatch '^\d+$') {
            throw "ws set-path: '--tab' requires a valid configured tab index (0-based). Got '$($tokens[1])'."
        }

        $tabIndex = -1

        if (-not [int]::TryParse($tokens[1], [ref]$tabIndex)) {
            throw "ws set-path: '--tab' requires a valid configured tab index (0-based). Got '$($tokens[1])'."
        }
        $rest     = @($tokens | Select-Object -Skip 2)

        if ($rest.Count -eq 0) {
            throw "Usage: ws set-path <id> --tab <n> <path> | ws set-path <id> --tab <n> --clear"
        }

        if ($rest[0] -eq "--clear") {
            if ($rest.Count -gt 1) {
                throw "ws set-path: '--clear' cannot be combined with a path."
            }

            $clearTab = $true
        }
        elseif ($rest[0] -eq "--tab") {
            throw "ws set-path: duplicate '--tab' is not allowed."
        }
        elseif ($rest[0].StartsWith("--")) {
            throw "ws set-path: unknown control switch '$($rest[0])'. Usage: ws set-path <id> <path> | ws set-path <id> --tab <n> <path> | ws set-path <id> --tab <n> --clear."
        }
        else {
            $PathText = ($rest -join " ")
        }
    }
    elseif ($tokens.Count -gt 0 -and $tokens[0].StartsWith("--")) {
        throw "ws set-path: unknown control switch '$($tokens[0])'. Usage: ws set-path <id> <path> | ws set-path <id> --tab <n> <path> | ws set-path <id> --tab <n> --clear."
    }
    elseif ($tokens.Count -gt 0) {
        $PathText = ($tokens -join " ")
    }

    if (-not $clearTab -and [string]::IsNullOrWhiteSpace($PathText)) {
        if ($AllowNumericAlias) {
            throw "Usage: ws set <id|number> <path>"
        }

        throw "Usage: ws set-path <id> <path>"
    }

    $context = Get-DevWSContext
    $commandName = "ws set-path"

    if ($AllowNumericAlias) {
        $commandName = "ws set"
    }

    $configReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Reference -CommandName $commandName

    if ($AllowNumericAlias -and -not $configReference.Scoped) {
        # Historical compatibility: unscoped numeric aliases resolve by
        # terminal order within defaultSet. Scoped references are stable-id
        # only; there are no scoped ordinal aliases.
        $terminal = Resolve-DevWSReference -Config $context.Config -Reference $configReference.ItemId -Type terminal -Set $configReference.Set
    }
    else {
        $terminal = Resolve-DevWSTerminalById -Config $context.Config -Reference $configReference.ItemId -CommandName $commandName -Set $configReference.Set
    }

    $label = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $configReference.SetId -ItemId $terminal.id -Scoped:$configReference.Scoped

    if ($useTab) {
        $tabs = @($terminal.tabs)

        if ($tabIndex -ge $tabs.Count) {
            throw "ws set-path: tab $tabIndex does not address an existing tab of terminal '$([string]$terminal.id)' (valid range: 0..$($tabs.Count - 1))."
        }

        $oldEffective = Get-DevWSTerminalTabEffectivePath -Terminal $terminal -TabIndex $tabIndex

        if ($clearTab) {
            [void](Clear-DevWSTerminalTabPath -Config $context.Config -Terminal $terminal -TabIndex $tabIndex)
        }
        else {
            $resolved = Resolve-DevWSDirectoryPath -PathText $PathText
            [void](Set-DevWSTerminalTabPath -Config $context.Config -Terminal $terminal -TabIndex $tabIndex -Path $resolved)
        }

        Save-DevWSConfig -Config $context.Config -Location $context.Location

        Write-Host "Terminal '$label' tab $tabIndex" -ForegroundColor Cyan
        Write-Host "  old: $oldEffective"

        if ($clearTab) {
            Write-Host "  new: inherits the terminal path ($([string]$terminal.path))" -ForegroundColor Green
        }
        else {
            Write-Host "  new: $resolved" -ForegroundColor Green
        }

        if ($tabIndex -eq 0 -and -not $clearTab) {
            Write-Host "  terminal path mirrors the tab-0 override for older builds." -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "Running terminals keep their current directory until reset." -ForegroundColor DarkGray
        return
    }

    $resolved = Resolve-DevWSDirectoryPath -PathText $PathText
    $old = [string]$terminal.path

    [void](Set-DevWSTerminalPath -Config $context.Config -Terminal $terminal -Path $resolved)
    Save-DevWSConfig -Config $context.Config -Location $context.Location

    Write-Host "Terminal '$label'" -ForegroundColor Cyan
    Write-Host "  old: $old"
    Write-Host "  new: $($resolved)" -ForegroundColor Green

    $overrideCount = @($terminal.tabs | Where-Object {
        $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.path)
    }).Count

    if ($overrideCount -gt 0) {
        Write-Host "  $overrideCount tab path override(s) were preserved; only the terminal default changed." -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "Running terminals keep their current directory until reset." -ForegroundColor DarkGray
}

function Invoke-DevWSSetCommand {
    param(
        [string]$Reference,
        [AllowEmptyString()]
        [string]$CommandText,
        [AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    if ([string]::IsNullOrWhiteSpace($Reference) -or [string]::IsNullOrWhiteSpace($CommandText)) {
        throw "Usage: ws set-command <id> <command> [args...]"
    }

    $context = Get-DevWSContext
    $configReference = Resolve-DevWSConfigReference -Config $context.Config -Reference $Reference -CommandName "ws set-command"
    $terminal = Resolve-DevWSTerminalById -Config $context.Config -Reference $configReference.ItemId -CommandName "ws set-command" -Set $configReference.Set

    [void](Set-DevWSTerminalCommand `
        -Config $context.Config `
        -Terminal $terminal `
        -CommandText $CommandText `
        -Arguments $Arguments)

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    $label = Get-DevWSItemDisplayLabel -Config $context.Config -SetId $configReference.SetId -ItemId $terminal.id -Scoped:$configReference.Scoped

    Write-Host "Terminal '$label' first tab command updated." -ForegroundColor Green
    Write-Host "  tabs: $(Get-DevWSTerminalTabSummary -Terminal $terminal)"
    Write-Host ""
    Write-Host "Running terminals keep their current command until reset." -ForegroundColor DarkGray
}

# --- Set management commands ---

function Invoke-DevWSAddSet {
    param([string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) {
        throw "Usage: ws add-set <id>"
    }

    $context = Get-DevWSContext
    $set = Add-DevWSSet -Config $context.Config -Id $Id

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    Write-Host "Added set '$($set.id)' (0 items)." -ForegroundColor Green
    Write-Host ""
    Write-Host "Config only: no window was launched and no shortcut was created." -ForegroundColor DarkGray
    Write-Host "Add items with scoped references, for example: ws add-terminal $($set.id)/term <path>" -ForegroundColor DarkGray
}

function Invoke-DevWSSetDefault {
    param([string]$Reference)

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "Usage: ws set-default <id>"
    }

    $context = Get-DevWSContext
    $result = Set-DevWSDefaultSet -Config $context.Config -Reference $Reference

    if ($result.Changed) {
        Save-DevWSConfig -Config $context.Config -Location $context.Location
        Write-Host "Default set is now '$($result.Set.id)'." -ForegroundColor Green
        Write-Host ""
        Write-Host "Bare commands (for example 'ws launch') will target it from now on." -ForegroundColor DarkGray
    }
    else {
        Write-Host "'$($result.Set.id)' is already the default set." -ForegroundColor DarkGray
    }
}

function Invoke-DevWSRemoveSet {
    param(
        [string]$Reference,
        [switch]$SkipConfirmation
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "Usage: ws remove-set <id> [-Force]"
    }

    $context = Get-DevWSContext
    $set = Resolve-DevWSSet -Config $context.Config -Reference $Reference

    if (-not $SkipConfirmation) {
        $answer = Read-Host "Remove workspace set '$($set.id)' from the configuration (config only; running windows stay open)? [y/N]"

        if ($answer -notmatch '^(?i:y|yes)$') {
            Write-Host "Cancelled." -ForegroundColor DarkGray
            return
        }
    }

    [void](Remove-DevWSSet -Config $context.Config -Reference $set.id)

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    Write-Host "Removed set '$($set.id)' from the configuration." -ForegroundColor Green
    Write-Host "No window was closed and no files were deleted." -ForegroundColor DarkGray
}

function Invoke-DevWSCloneSet {
    param(
        [string]$SourceReference,
        [string]$NewId
    )

    if ([string]::IsNullOrWhiteSpace($SourceReference) -or [string]::IsNullOrWhiteSpace($NewId)) {
        throw "Usage: ws clone-set <source-set> <new-set>"
    }

    $context = Get-DevWSContext
    $result = Clone-DevWSSet -Config $context.Config -SourceId $SourceReference -NewId $NewId

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    $clone = $result.Clone

    Write-Host "Cloned set '$($result.SourceId)' -> '$($clone.id)'." -ForegroundColor Green
    Write-Host "  items: $(@($clone.windows).Count)"

    foreach ($item in @($clone.windows)) {
        if ($item.type -eq "terminal") {
            Write-Host "  windowId: $($item.windowId)"
        }
    }

    Write-Host ""
    Write-Host "Config only: no window was launched and the default set is unchanged." -ForegroundColor DarkGray
    Write-Host "Cloned apps are independent definitions; each keeps its explicit dedicated/shared mode." -ForegroundColor DarkGray
}

function Invoke-DevWSRenameSet {
    param(
        [string]$OldReference,
        [string]$NewId
    )

    if ([string]::IsNullOrWhiteSpace($OldReference) -or [string]::IsNullOrWhiteSpace($NewId)) {
        throw "Usage: ws rename-set <old-set> <new-set>"
    }

    $context = Get-DevWSContext

    # Resolve the source and validate the target BEFORE any live observation:
    # an unknown source, an invalid target id or a collision never probes
    # windows and never touches canonical config.
    $set = Resolve-DevWSSet -Config $context.Config -Reference $OldReference
    Assert-DevWSRenameSetTarget -Config $context.Config -Set $set -NewId $NewId

    $oldId = [string]$set.id

    if ($oldId -ceq $NewId) {
        Write-Host "Set '$oldId' is already named '$NewId'; nothing changed." -ForegroundColor DarkGray
        return
    }

    $caseOnly = ($oldId -ieq $NewId)

    # Accepted Candidate B fail-closed ownership preflight for SEMANTIC
    # renames only: a case-only rename keeps the identical
    # invariant-lowercase ownership identity, so live dedicated owners must
    # not block it. This command never writes an ownership property, never
    # migrates ownership and never touches the blocked windows.
    if (-not $caseOnly) {
        $blockers = @(Get-DevWSRenameSetOwnershipBlockers -Set $set)

        if ($blockers.Count -gt 0) {
            throw (Format-DevWSSetRenameOwnershipRefusal -SetId $oldId -Blockers $blockers)
        }
    }

    $result = Rename-DevWSSet -Config $context.Config -OldReference $OldReference -NewId $NewId

    if (-not $result.Changed) {
        Write-Host "Set '$oldId' is already named '$NewId'; nothing changed." -ForegroundColor DarkGray
        return
    }

    # Canonical config is authoritative: one atomic save first, then the
    # existing derived-hotkey reconciliation only when a binding was
    # retargeted. A later sync failure never rolls canonical config back;
    # 'ws sync-hotkeys' is the repair path and doctor/health report the drift.
    Save-DevWSConfig -Config $context.Config -Location $context.Location

    if ($result.BindingsRewritten -gt 0) {
        Invoke-DevWSBindingDerivedSync -Config $context.Config
    }

    $suffix = ""

    if ($result.CaseOnly) {
        $suffix = " (casing only)"
    }

    Write-Host "Renamed set '$($result.OldId)' -> '$($result.NewId)'$suffix." -ForegroundColor Green

    if ($result.DefaultSetRewritten) {
        Write-Host "  default set updated"
    }

    if ($result.BindingsRewritten -gt 0) {
        Write-Host "  $($result.BindingsRewritten) launch binding(s) retargeted"
    }

    $hasTerminals = (@($set.windows) | Where-Object { $null -ne $_ -and $_.type -eq "terminal" }).Count -gt 0

    if ($hasTerminals) {
        Write-Host "  terminal windowIds preserved"
    }

    Write-Host "  running windows were not closed or moved"

    if (-not $result.CaseOnly -and $hasTerminals) {
        Write-Host ""
        Write-Host "Note: an already-running tracked terminal in '$($result.OldId)' keeps publishing cwd under that set until it is recreated." -ForegroundColor DarkGray
        Write-Host "      Until then 'ws save $($result.NewId)' treats that cwd as unavailable and preserves the already-saved effective path; the terminal stays fully usable." -ForegroundColor DarkGray
        Write-Host "      'ws reset-terminals $($result.NewId)' establishes fresh tracking when/if you want it (not required)." -ForegroundColor DarkGray
    }
}

# --- CLI tools: set launch bindings (config + derived hotkeys) ---

function Invoke-DevWSBindingDerivedSync {
    param(
        [Parameter(Mandatory)]
        $Config
    )

    try {
        $result = Sync-DevWSBindings -Config $Config

        if ($result.Status -eq "written") {
            Write-Host "  generated hotkeys: $($result.Path)"
        }
        else {
            Write-Host "  generated hotkeys already current"
        }

        if ($result.Reloaded) {
            Write-Host "  reloaded the managed AutoHotkey hotkey script"
        }
    }
    catch {
        throw ("The canonical config WAS updated, but the derived hotkeys are out of sync: $($_.Exception.Message) Run 'ws sync-hotkeys' after correcting the hotkey integration problem; doctor/health will report the drift until then.")
    }
}

function Invoke-DevWSBind {
    param(
        [string]$SetReference,
        [string]$Hotkey
    )

    if ([string]::IsNullOrWhiteSpace($SetReference) -or [string]::IsNullOrWhiteSpace($Hotkey)) {
        throw "Usage: ws bind <set> <hotkey>"
    }

    $context = Get-DevWSContext
    $binding = Add-DevWSBinding -Config $context.Config -SetId $SetReference -Hotkey $Hotkey

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    Write-Host "Bound $($binding.hotkey) -> set '$($binding.setId)'." -ForegroundColor Green

    Invoke-DevWSBindingDerivedSync -Config $context.Config
}

function Invoke-DevWSUnbind {
    param(
        [string]$Hotkey
    )

    if ([string]::IsNullOrWhiteSpace($Hotkey)) {
        throw "Usage: ws unbind <hotkey>"
    }

    $context = Get-DevWSContext
    $removed = Remove-DevWSBinding -Config $context.Config -Hotkey $Hotkey

    Save-DevWSConfig -Config $context.Config -Location $context.Location

    Write-Host "Unbound $($removed.hotkey) (was set '$($removed.setId)')." -ForegroundColor Green

    Invoke-DevWSBindingDerivedSync -Config $context.Config
}

function Show-DevWSBindings {
    $context = Get-DevWSContext
    $lines   = @(Get-DevWSBindingsLines -Config $context.Config)

    Write-Host "BINDINGS" -ForegroundColor Cyan
    Write-Host "------------------------------"

    if ($lines.Count -eq 0) {
        Write-Host "No additional set launch bindings configured."
        return
    }

    foreach ($line in $lines) {
        Write-Host $line
    }
}

function Invoke-DevWSSyncHotkeys {
    $context = Get-DevWSContext
    $result  = Sync-DevWSBindings -Config $context.Config

    if ($result.Status -eq "written") {
        Write-Host "Regenerated $($result.Path)" -ForegroundColor Green
    }
    else {
        Write-Host "Generated hotkeys already current: $($result.Path)" -ForegroundColor DarkGray
    }

    if ($result.Reloaded) {
        Write-Host "Reloaded the managed AutoHotkey hotkey script." -ForegroundColor Green
    }
    else {
        Write-Host "The managed AutoHotkey hotkey script was not reloaded." -ForegroundColor Yellow
    }
}

# --- CLI tools: edit, doctor, detect-app ---

function Invoke-DevWSEdit {
    $context = Get-DevWSContext
    $result  = Invoke-DevWSEditSession -Location $context.Location

    if ($result.Status -eq "unchanged") {
        Write-Host "No changes." -ForegroundColor DarkGray
        return
    }

    Write-Host "Saved edited workspace config." -ForegroundColor Green
    Write-Host "  $($context.Location.Path)"
    Write-Host ""
    Write-Host "Canonical config was replaced atomically after validation." -ForegroundColor DarkGray
}

function Invoke-DevWSDiagnostics {
    param(
        [string]$Title = "DevWS doctor"
    )

    $summary = Invoke-DevWSDoctorCheck -Title $Title
    $code    = Get-DevWSDoctorExitCode -Summary $summary

    if ($code -ne 0) {
        exit $code
    }
}

function Invoke-DevWSDetectApp {
    param(
        [AllowEmptyCollection()]
        [string[]]$FilterParts = @()
    )

    $filter  = (@($FilterParts) -join " ").Trim()
    $context = Get-DevWSContext

    # Read-only ownership-aware diagnostics: one visible top-level HWND per row, using
    # the same generic enumeration, match rules, and bounded ownership lookup
    # as the app lifecycle. No window is launched, moved, focused, closed,
    # tagged, or untagged.
    $candidates = @(Get-DevWSAppWindowCandidates)
    $probed     = @(Get-DevWSAppWindowProbe -Config $context.Config -Candidates $candidates -TolerantOwnership)

    $shown = 0

    foreach ($candidate in @($probed | Sort-Object processName, pid, hwnd)) {
        $matches = @(Get-DevWSConfiguredAppWindowMatches -Config $context.Config -Candidate $candidate)

        if (-not (Test-DevWSDetectAppFilter -Candidate $candidate -Matches $matches -Filter $filter)) {
            continue
        }

        $ownerApp = $null

        if (-not [string]::IsNullOrWhiteSpace([string]$candidate.ownerKey)) {
            $ownerApp = Get-DevWSConfiguredAppDefinition -Config $context.Config -ScopedId ([string]$candidate.ownerKey)
        }

        Write-Host ""
        foreach ($line in @(Get-DevWSDetectAppLines -Candidate $candidate -Matches $matches -OwnerApp $ownerApp)) {
            Write-Host $line
        }

        $shown++
    }

    if ($shown -eq 0) {
        Write-Host ""

        if ([string]::IsNullOrWhiteSpace($filter)) {
            Write-Host "No visible application windows found." -ForegroundColor DarkGray
        }
        else {
            Write-Host "No visible application windows matched '$filter'." -ForegroundColor DarkGray
        }
    }

    Write-Host ""
}

# --- end CLI tools ---

try {
    switch ($Command.ToLowerInvariant()) {
        { $_ -in "help", "-h", "--help", "/?" } {
            # PowerShell routes literal -h/--help tokens through $args while
            # $Command keeps its "help" default, so filter them out instead of
            # rejecting them; the remaining token is the optional target.
            $helpTokens = @(
                foreach ($candidate in @($Arg1) + @($Remaining)) {
                    if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
                        continue
                    }

                    if (@("-h", "--help", "/?") -contains ([string]$candidate).ToLowerInvariant()) {
                        continue
                    }

                    [string]$candidate
                }
            )

            if ($helpTokens.Count -gt 1) {
                throw "'ws help' accepts at most one command, topic, or 'all'. Usage: ws help [<command>|<topic>|all]"
            }

            $helpTarget = $null

            if ($helpTokens.Count -eq 1) {
                $helpTarget = $helpTokens[0]
            }

            Show-DevWSHelp -Target $helpTarget
        }

        { Test-DevWSHelpDirectTopic -Name $_ } {
            # Direct read-only command-group shortcuts (ws items|layout|
            # hotkeys|tools): presentation-only navigation that renders exactly
            # the matching help-topic view. The topic catalog's Direct flag is
            # the single source of truth; no config load, no runtime state, no
            # worker/broker/monitor/window access, and no nested command
            # syntax. Unexpected arguments are refused with an actionable
            # message instead of a generic unknown-command error.
            $directTopic = Get-DevWSHelpTopicByName -Name $Command
            $groupExtraTokens = @()

            if (-not [string]::IsNullOrWhiteSpace($Arg1)) { $groupExtraTokens += $Arg1 }
            if ($Remaining) { $groupExtraTokens += @($Remaining) }

            if ($groupExtraTokens.Count -gt 0) {
                $directTopicName = [string]$directTopic.Name
                $firstGroupCommand = [string](@($directTopic.Commands)[0])

                throw "'ws $directTopicName' is a read-only command-group browser and does not accept arguments. Run 'ws $directTopicName' to browse its commands, or run an individual command such as 'ws $firstGroupCommand'."
            }

            Show-DevWSHelpTopic -Topic $directTopic
        }

        "launch" {
            Assert-DevWSNoRemainingArguments -Usage "ws launch [set]" -RemainingArguments @($Remaining)
            Invoke-DevWSLaunch -SetId $Arg1
        }

        "focus" {
            Assert-DevWSNoRemainingArguments -Usage "ws focus [set]" -RemainingArguments @($Remaining)
            Invoke-DevWSFocus -SetId $Arg1
        }

        "list" {
            Assert-DevWSNoRemainingArguments -Usage "ws list [set]" -RemainingArguments @($Remaining)
            Show-DevWSList -SetId $Arg1
        }

        "status" {
            Assert-DevWSNoRemainingArguments -Usage "ws status [set]" -RemainingArguments @($Remaining)
            Show-DevWSStatus -SetId $Arg1
        }

        "monitors" {
            Assert-DevWSNoExtraArguments -CommandName "monitors" -Usage "ws monitors" -FirstArgument $Arg1 -RemainingArguments @($Remaining)
            Show-DevWSMonitors
        }

        "show" {
            Assert-DevWSNoRemainingArguments -Usage "ws show [set]" -RemainingArguments @($Remaining)
            Show-DevWSList -SetId $Arg1
        }

        "save-layout" {
            $saveLayoutTokens = @()

            if (-not [string]::IsNullOrWhiteSpace($Arg1)) {
                $saveLayoutTokens += $Arg1
            }

            $saveLayoutTokens += @($Remaining)

            $parsed = ConvertFrom-DevWSSaveArguments `
                -Tokens $saveLayoutTokens `
                -CommandName "save-layout" `
                -Usage "ws save-layout [set] [--profile <id>]"

            Save-DevWSLayout -SetId $parsed.SetId -ProfileId $parsed.ProfileId
        }

        "save" {
            $saveTokens = @()

            if (-not [string]::IsNullOrWhiteSpace($Arg1)) {
                $saveTokens += $Arg1
            }

            $saveTokens += @($Remaining)

            $parsed = ConvertFrom-DevWSSaveArguments `
                -Tokens $saveTokens `
                -CommandName "save" `
                -Usage "ws save [set] [--profile <id>]"

            Save-DevWSWorkspace -SetId $parsed.SetId -ProfileId $parsed.ProfileId
        }

        "show-layout" {
            Assert-DevWSNoRemainingArguments -Usage "ws show-layout [set]" -RemainingArguments @($Remaining)
            Show-DevWSLayout -SetId $Arg1
        }

        "layout-profile" {
            $layoutProfileParts = @()

            if ($Remaining) {
                $layoutProfileParts += $Remaining
            }

            Invoke-DevWSLayoutProfileCommand `
                -Subcommand $Arg1 `
                -Arguments $layoutProfileParts `
                -SkipConfirmation:$Force
        }

        "reset" {
            Assert-DevWSNoRemainingArguments -Usage "ws reset <id|number|set/id>" -RemainingArguments @($Remaining)
            Reset-DevWSTerminal -Reference $Arg1
        }

        "reset-terminal" {
            Assert-DevWSNoRemainingArguments -Usage "ws reset-terminal <id|number|set/id>" -RemainingArguments @($Remaining)
            Reset-DevWSTerminal -Reference $Arg1
        }

        "reset-terminals" {
            Assert-DevWSNoRemainingArguments -Usage "ws reset-terminals [set] [-Force]" -RemainingArguments @($Remaining)
            Reset-DevWSTerminals -SetId $Arg1 -SkipConfirmation:$Force
        }

        "enable" {
            Invoke-DevWSEnableItem -Reference $Arg1
        }

        "disable" {
            Invoke-DevWSDisableItem -Reference $Arg1
        }

        "add-terminal" {
            $parts = @()

            if ($Remaining) {
                $parts += $Remaining
            }

            if ($parts.Count -lt 1) {
                throw "Usage: ws add-terminal <id> <path> [command] [args...]"
            }

            $pathText    = $parts[0]
            $commandText = $null
            $commandArgs = @()

            if ($parts.Count -ge 2) {
                $commandText = $parts[1]

                if ($parts.Count -ge 3) {
                    $commandArgs = @($parts[2..($parts.Count - 1)])
                }
            }

            Invoke-DevWSAddTerminal `
                -Id $Arg1 `
                -PathText $pathText `
                -CommandText $commandText `
                -Arguments $commandArgs
        }

        "remove" {
            Invoke-DevWSRemoveItem -Reference $Arg1 -SkipConfirmation:$Force
        }

        "set-path" {
            $pathParts = @()

            if ($Remaining) {
                $pathParts += $Remaining
            }

            Invoke-DevWSSetPath -Reference $Arg1 -PathParts $pathParts
        }

        "set-command" {
            $parts = @()

            if ($Remaining) {
                $parts += $Remaining
            }

            if ($parts.Count -eq 0) {
                throw "Usage: ws set-command <id> <command> [args...]"
            }

            $commandText = $parts[0]
            $commandArgs = @()

            if ($parts.Count -ge 2) {
                $commandArgs = @($parts[1..($parts.Count - 1)])
            }

            Invoke-DevWSSetCommand `
                -Reference $Arg1 `
                -CommandText $commandText `
                -Arguments $commandArgs
        }

        "add-app" {
            $parts = @()

            if ($Remaining) {
                $parts += $Remaining
            }

            if ($parts.Count -ne 5) {
                throw "Usage: ws add-app <id> <launch-kind> <launch-value> <match-kind> <match-value> <instance-mode>. The instance-mode argument ('dedicated' or 'shared') is required; apps without an explicit mode are not valid."
            }

            Invoke-DevWSAddApp `
                -Id $Arg1 `
                -LaunchKind $parts[0] `
                -LaunchValue $parts[1] `
                -MatchKind $parts[2] `
                -MatchValue $parts[3] `
                -InstanceMode $parts[4]
        }

        "set-instance-mode" {
            if ([string]::IsNullOrWhiteSpace($Arg1) -or @($Remaining).Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$Remaining[0])) {
                throw "Usage: ws set-instance-mode <app-id> <dedicated|shared>"
            }

            $result = Invoke-DevWSSetInstanceMode -Reference $Arg1 -Mode ([string]$Remaining[0])

            Write-Host "Instance mode for app id '$($result.AppId)' set to '$($result.Mode)'." -ForegroundColor Green
            Write-Host ""
            Write-Host "Updated definitions:" -ForegroundColor DarkGray

            foreach ($scoped in @($result.Changed)) {
                Write-Host "  $scoped" -ForegroundColor DarkGray
            }

            if (@($result.Changed).Count -gt 1) {
                Write-Host ""
                Write-Host "All same-id definitions across sets were updated together because instanceMode must stay consistent." -ForegroundColor DarkGray
            }

            Write-Host ""
            Write-Host "Config only: running app windows and their DevWS ownership tags were not touched." -ForegroundColor DarkGray
        }

        "set-launch" {
            $parts = @()

            if ($Remaining) {
                $parts += $Remaining
            }

            if ($parts.Count -lt 2) {
                throw "Usage: ws set-launch <app-id> <kind> <value>"
            }

            $kind  = $parts[0]
            $value = $parts[1..($parts.Count - 1)] -join " "

            Invoke-DevWSSetLaunch -Reference $Arg1 -Kind $kind -Value $value
        }

        "set-match" {
            $parts = @()

            if ($Remaining) {
                $parts += $Remaining
            }

            if ($parts.Count -lt 2) {
                throw "Usage: ws set-match <app-id> <kind> <value>"
            }

            $kind  = $parts[0]
            $value = $parts[1..($parts.Count - 1)] -join " "

            Invoke-DevWSSetMatch -Reference $Arg1 -Kind $kind -Value $value
        }

        "set-app-args" {
            $parts = @()

            if ($Remaining) {
                $parts += $Remaining
            }

            if ($parts -contains "--clear") {
                if ($parts.Count -ne 1) {
                    throw "ws set-app-args: --clear must be used alone to clear all arguments."
                }

                Invoke-DevWSSetAppArgs -Reference $Arg1 -Clear
            }
            else {
                if ($parts.Count -eq 0) {
                    throw "Usage: ws set-app-args <app-id> <arg1> [arg2 ...] (use --clear to remove all arguments)"
                }

                Invoke-DevWSSetAppArgs -Reference $Arg1 -Arguments $parts
            }
        }

        "rename" {
            $parts = @()

            if ($Remaining) {
                $parts += $Remaining
            }

            if ($parts.Count -ne 1) {
                throw "Usage: ws rename <old-id> <new-id>"
            }

            Invoke-DevWSRename -Reference $Arg1 -NewId $parts[0]
        }

        "clone-terminal" {
            $parts = @()

            if ($Remaining) {
                $parts += $Remaining
            }

            if ($parts.Count -ne 1) {
                throw "Usage: ws clone-terminal <source-id> <new-id>"
            }

            Invoke-DevWSCloneTerminal -Reference $Arg1 -NewId $parts[0]
        }

        "clone-app" {
            $parts = @()

            if ($Remaining) {
                $parts += $Remaining
            }

            if ($parts.Count -ne 1) {
                throw "Usage: ws clone-app <source-id> <new-id>"
            }

            Invoke-DevWSCloneApp -Reference $Arg1 -NewId $parts[0]
        }

        "set-geometry" {
            $parts = @()

            if ($Remaining) {
                $parts += $Remaining
            }

            Invoke-DevWSSetGeometry -Reference $Arg1 -Arguments $parts
        }

        "reset-layout" {
            if (@($Remaining).Count -gt 0) {
                throw "Usage: ws reset-layout [set] [-Force]"
            }

            Invoke-DevWSResetLayout -SetId $Arg1 -SkipConfirmation:$Force
        }

        "sets" {
            Assert-DevWSNoExtraArguments -CommandName "ws sets" -Usage "ws sets" -FirstArgument $Arg1 -RemainingArguments @($Remaining)
            Show-DevWSSets
        }

        "add-set" {
            Assert-DevWSNoExtraArguments -CommandName "ws add-set" -Usage "ws add-set <id>" -FirstArgument $null -RemainingArguments @($Remaining)
            Invoke-DevWSAddSet -Id $Arg1
        }

        "clone-set" {
            $setParts = @()

            if ($Remaining) {
                $setParts += $Remaining
            }

            if ($setParts.Count -ne 1) {
                throw "Usage: ws clone-set <source-set> <new-set>"
            }

            Invoke-DevWSCloneSet -SourceReference $Arg1 -NewId $setParts[0]
        }

        "rename-set" {
            $setParts = @()

            if ($Remaining) {
                $setParts += $Remaining
            }

            # The locked grammar is exactly `ws rename-set <old-set> <new-set>`:
            # this command has no -Force option, so the global top-level switch
            # is rejected here instead of being silently ignored.
            if ($setParts.Count -ne 1 -or $Force) {
                throw "Usage: ws rename-set <old-set> <new-set>"
            }

            Invoke-DevWSRenameSet -OldReference $Arg1 -NewId ([string]$setParts[0])
        }

        "remove-set" {
            Assert-DevWSNoExtraArguments -CommandName "ws remove-set" -Usage "ws remove-set <id> [-Force]" -FirstArgument $null -RemainingArguments @($Remaining)
            Invoke-DevWSRemoveSet -Reference $Arg1 -SkipConfirmation:$Force
        }

        "set-default" {
            Assert-DevWSNoExtraArguments -CommandName "ws set-default" -Usage "ws set-default <id>" -FirstArgument $null -RemainingArguments @($Remaining)
            Invoke-DevWSSetDefault -Reference $Arg1
        }

        "bind" {
            $bindParts = @()

            if ($Remaining) {
                $bindParts += $Remaining
            }

            if ($bindParts.Count -ne 1) {
                throw "Usage: ws bind <set> <hotkey>"
            }

            Invoke-DevWSBind -SetReference $Arg1 -Hotkey ([string]$bindParts[0])
        }

        "unbind" {
            Assert-DevWSNoExtraArguments -CommandName "ws unbind" -Usage "ws unbind <hotkey>" -FirstArgument $null -RemainingArguments @($Remaining)
            Invoke-DevWSUnbind -Hotkey $Arg1
        }

        "bindings" {
            Assert-DevWSNoExtraArguments -CommandName "ws bindings" -Usage "ws bindings" -FirstArgument $Arg1 -RemainingArguments @($Remaining)
            Show-DevWSBindings
        }

        "sync-hotkeys" {
            Assert-DevWSNoExtraArguments -CommandName "ws sync-hotkeys" -Usage "ws sync-hotkeys" -FirstArgument $Arg1 -RemainingArguments @($Remaining)
            Invoke-DevWSSyncHotkeys
        }

        "edit" {
            Assert-DevWSNoExtraArguments -CommandName "ws edit" -Usage "ws edit" -FirstArgument $Arg1 -RemainingArguments @($Remaining)
            Invoke-DevWSEdit
        }

        "doctor" {
            Assert-DevWSNoExtraArguments -CommandName "ws doctor" -Usage "ws doctor" -FirstArgument $Arg1 -RemainingArguments @($Remaining)
            Invoke-DevWSDiagnostics
        }

        "health" {
            Assert-DevWSNoExtraArguments -CommandName "ws health" -Usage "ws health" -FirstArgument $Arg1 -RemainingArguments @($Remaining)
            Invoke-DevWSDiagnostics -Title "DevWS health"
        }

        "detect-app" {
            $parts = @()

            if (-not [string]::IsNullOrWhiteSpace($Arg1)) {
                $parts += $Arg1
            }

            if ($Remaining) {
                $parts += $Remaining
            }

            Invoke-DevWSDetectApp -FilterParts $parts
        }

        "set" {
            $pathParts = @()

            if ($Remaining) {
                $pathParts += $Remaining
            }

            if ($pathParts.Count -eq 0) {
                throw "Usage: ws set <id|number> <path>"
            }

            Invoke-DevWSSetPath `
                -Reference $Arg1 `
                -PathText ($pathParts -join " ") `
                -AllowNumericAlias
        }

        default {
            Write-Host ""
            Write-Host "Unknown command '$Command'." -ForegroundColor Red

            $suggestions = @(Get-DevWSCommandSuggestion -CommandName $Command)

            if ($suggestions.Count -gt 0) {
                Write-Host ""
                Write-Host "Did you mean:" -ForegroundColor Yellow

                foreach ($suggestion in $suggestions) {
                    Write-Host "  ws $suggestion" -ForegroundColor Green
                }
            }

            Write-Host ""
            Write-Host 'Run `ws help` for commands.' -ForegroundColor DarkGray
            exit 1
        }
    }
}
catch {
    Write-Host ""
    Write-Host "ws: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}
