$ErrorActionPreference = "Stop"

# Public Security hardening: installed workers resolve libraries ONLY from the
# administrator-protected privileged root next to them
# (<privileged root>\workers -> <privileged root>\lib). Repository execution
# resolves <repo>\src\lib. There is no fallback to user-writable install
# copies.
$LibDir = Join-Path (Split-Path -Parent $PSScriptRoot) "lib"

if (-not (Test-Path -LiteralPath (Join-Path $LibDir "devws-paths.ps1") -PathType Leaf)) {
    throw "DevWS runtime libraries were not found at '$LibDir'. Installed workers require the administrator-protected privileged root next to them; run install.ps1."
}

. (Join-Path $LibDir "devws-paths.ps1")
Assert-DevWSWorkerLibraryRoot -LibDir $LibDir
. (Join-Path $LibDir "devws-config.ps1")
. (Join-Path $LibDir "devws-bindings.ps1")
. (Join-Path $LibDir "devws-terminal.ps1")
. (Join-Path $LibDir "devws-cwd-paths.ps1")
. (Join-Path $LibDir "devws-cwd.ps1")
. (Join-Path $LibDir "devws-ahk.ps1")
. (Join-Path $LibDir "devws-native.ps1")
. (Join-Path $LibDir "devws-window-ops.ps1")
. (Join-Path $LibDir "devws-uia.ps1")
. (Join-Path $LibDir "devws-state.ps1")
. (Join-Path $LibDir "devws-identity.ps1")
. (Join-Path $LibDir "devws-locator.ps1")
. (Join-Path $LibDir "devws-worker-protocol.ps1")
. (Join-Path $LibDir "devws-terminal-launch.ps1")

$location = Resolve-DevWSConfigLocation -StartPath $PSScriptRoot

# Trusted Windows Terminal launcher (the administrator-protected package
# executable); a failed trust validation refuses the reset before ACCEPTED.
$Wt = $null

function Reset-DevWSTerminal {
    param(
        [Parameter(Mandatory)]$Config,
        $Terminal,
        $State,
        [Parameter(Mandatory)]
        [string]$SetId,
        [bool]$ApplyGeometry = $true,
        [AllowNull()]$Layout = $null,
        # Injectable side-effect seam. Production callers pass none of these and
        # get the real observation/close/creation/publication primitives; the
        # deterministic suite injects recording providers to prove the
        # destructive boundary behaviorally.
        [scriptblock]$PresenceProvider = $null,
        [scriptblock]$ConflictProvider = $null,
        [scriptblock]$IdentityProvider = $null,
        [scriptblock]$CloseProvider = $null,
        [scriptblock]$WaitGoneProvider = $null,
        [scriptblock]$TrackingProvider = $null,
        [scriptblock]$CreateProvider = $null,
        [scriptblock]$RecoveryProvider = $null,
        [scriptblock]$TabCountProvider = $null,
        [scriptblock]$StatePublisher = $null
    )

    if ($null -eq $PresenceProvider) {
        $PresenceProvider = {
            param($TargetConfig, $TargetSetId, $TargetState, $TargetTerminal)
            Get-DevWSTerminalPresenceSnapshot -Config $TargetConfig -SetId $TargetSetId -State $TargetState -Terminals @($TargetTerminal)
        }
    }

    if ($null -eq $ConflictProvider) {
        $ConflictProvider = {
            param([long]$SelectedHwnd, $WtHwnds, [string]$TargetWindowId)
            Get-DevWSResetIdentityConflict -SelectedHwnd $SelectedHwnd -WtHwnds @($WtHwnds) -WindowId $TargetWindowId
        }
    }

    if ($null -eq $IdentityProvider) {
        $IdentityProvider = {
            param([long]$TargetHwnd, [string]$TargetWindowId)
            Test-DevWSResetTargetIdentity -Hwnd $TargetHwnd -WindowId $TargetWindowId
        }
    }

    if ($null -eq $CloseProvider) {
        $CloseProvider = {
            param([long]$TargetHwnd, [string]$TargetContext)
            Close-DevWSWindowHwnd -Hwnd $TargetHwnd -Context $TargetContext
        }
    }

    if ($null -eq $WaitGoneProvider) {
        $WaitGoneProvider = {
            param([long]$TargetHwnd)
            Wait-DevWSWindowHwndGone -Hwnd $TargetHwnd -TimeoutSeconds 10
        }
    }

    if ($null -eq $TrackingProvider) {
        $TrackingProvider = {
            param([string]$TargetSetId, [string]$TargetTerminalId, [string]$TargetWindowId, $TargetTerminal, [string]$TargetBootstrapPath)
            New-DevWSCwdTrackingContexts -SetId $TargetSetId -TerminalId $TargetTerminalId -WindowId $TargetWindowId -Terminal $TargetTerminal -BootstrapPath $TargetBootstrapPath
        }
    }

    if ($null -eq $CreateProvider) {
        $CreateProvider = {
            param([string[]]$CreateArguments)
            & $Wt @CreateArguments
        }
    }

    if ($null -eq $RecoveryProvider) {
        $RecoveryProvider = {
            param($TargetConfig, $TargetSetId, $TargetState, $TargetTerminal)
            Wait-DevWSResetTerminalPresence -Config $TargetConfig -SetId $TargetSetId -State $TargetState -Terminal $TargetTerminal -TimeoutSeconds 15
        }
    }

    if ($null -eq $TabCountProvider) {
        $TabCountProvider = {
            param([long]$TargetHwnd, [int]$MinimumCount)
            Wait-DevWSTabCountFromHwnd -Hwnd $TargetHwnd -MinimumCount $MinimumCount -TimeoutSeconds 5
        }
    }

    if ($null -eq $StatePublisher) {
        $StatePublisher = {
            param([string]$TargetSetId, [string]$TargetTerminalId, [string]$TargetWindowId, [long]$TargetHwnd)
            Update-DevWSRuntimeTerminal -SetId $TargetSetId -Id $TargetTerminalId -WindowId $TargetWindowId -Hwnd $TargetHwnd
        }
    }

    $terminalId = [string]$Terminal.id
    $windowId   = [string]$Terminal.windowId

    if (-not [bool]$Terminal.elevated) {
        throw "Terminal '$terminalId' has elevated=false. Managed terminals require elevated=true; update this terminal in the workspace config and retry."
    }

    # Pass 6C: every configured tab's EFFECTIVE path (tab override when
    # present, otherwise terminal.path) must exist as a directory before the
    # first destructive close. A reset must never close a terminal it cannot
    # fully recreate.
    #
    # Operational note (Public Security Phase 2-D): this per-terminal check
    # runs AFTER ACCEPTED (it guards each individual close), so a failure here
    # is an unsuccessful FINAL for an already-accepted operation - never a
    # pre-acceptance rejection, and never an automatic Reset repetition.
    Assert-DevWSTerminalPath -Terminal $Terminal -SetId $SetId -Source "reset worker"

    # Tracked terminals: resolve the staged cwd bootstrap up front and refuse
    # before any close when it is missing. A reset must never close a terminal
    # it cannot recreate as tracked shells.
    $bootstrapPath = Get-DevWSCwdBootstrapPath

    if (-not (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) {
        throw "DevWS cwd tracking bootstrap helper is missing: $bootstrapPath. Refusing to reset terminal '$terminalId'."
    }

    # Mandatory pre-close identity gate. Only the shared structured presence
    # snapshot may authorize closure: present means the exact managed window
    # identity was observed; missing means no existing managed window was
    # observed and no parent may be closed; inaccessible, ambiguous, failed or
    # correlated-to-another terminal all refuse before any destructive call.
    # A locator HWND or Win32 title match is never sufficient by itself.
    try {
        $preflight = & $PresenceProvider $Config $SetId $State $Terminal
    }
    catch {
        throw "Refusing to reset terminal '$terminalId' ($windowId): presence preflight failed before the destructive close: $($_.Exception.Message)"
    }

    $observations = @($preflight.Terminals | Where-Object {
        [string]$_.TerminalId -ceq $terminalId -and [string]$_.WindowId -ceq $windowId
    })

    if ($observations.Count -ne 1) {
        throw "Refusing to reset terminal '$terminalId' ($windowId): presence preflight returned $($observations.Count) observations for this terminal."
    }

    $decision = Get-DevWSResetPreflightDecision `
        -Observation $observations[0] `
        -TerminalId $terminalId `
        -WindowId $windowId

    if ($decision.Action -eq "refuse") {
        throw $decision.Message
    }

    if ($decision.Action -eq "close-recreate") {
        # Only a positively verified present identity with no conflicting
        # managed window identity may reach this close.
        try {
            $conflict = & $ConflictProvider ([long]$decision.Hwnd) @($preflight.WtHwnds) $windowId
        }
        catch {
            throw "Refusing to reset terminal '$terminalId' ($windowId): duplicate-identity preflight failed before the destructive close: $($_.Exception.Message)"
        }

        if ($conflict.Conflict) {
            throw "Refusing to reset terminal '$terminalId' ($windowId): $($conflict.Diagnostic)."
        }

        # Time-of-check/time-of-use: the presence snapshot, duplicate check and
        # close are separate reads. Re-observe the EXACT selected HWND directly
        # before the destructive call; a gone, foreign, unreadable, or
        # title-family-mismatched target refuses instead of guessing identity.
        try {
            $revalidation = & $IdentityProvider ([long]$decision.Hwnd) $windowId
        }
        catch {
            throw "Refusing to reset terminal '$terminalId' ($windowId): target identity revalidation failed immediately before the destructive close: $($_.Exception.Message)"
        }

        if (-not [bool]$revalidation.Ok) {
            throw "Refusing to reset terminal '$terminalId' ($windowId): the verified target changed immediately before the destructive close ($($revalidation.Reason)); $($revalidation.Diagnostic)."
        }

        & $CloseProvider ([long]$decision.Hwnd) "terminal '$terminalId' ($windowId)"

        if (-not (& $WaitGoneProvider ([long]$decision.Hwnd))) {
            throw "Terminal '$terminalId' ($windowId) did not close."
        }
    }
    elseif ($decision.Action -ne "recreate") {
        throw "Refusing to reset terminal '$terminalId' ($windowId): unsupported preflight action '$($decision.Action)'."
    }

    # The old window is confirmed gone. ONLY NOW create the new generation: a
    # failed/cancelled close above must not invalidate tracking for the
    # still-running old shells. If recreation later fails, the new expected
    # generations simply have no valid publication (resolver: unavailable) and
    # a future reset overwrites them. One tracking context per configured tab.
    $trackingContexts = & $TrackingProvider $SetId $terminalId $windowId $Terminal $bootstrapPath

    # Recreate exactly the configured tab set (any count, command-only
    # terminals included), then restore geometry and the configured activeTab.
    [string[]]$createArguments = @(New-DevWSTerminalCreateArguments -Terminal $Terminal -TrackingContexts $trackingContexts)
    & $CreateProvider ([string[]]$createArguments)

    $recovery = & $RecoveryProvider $Config $SetId $State $Terminal

    if (-not $recovery.Ok) {
        $detail = if ([string]::IsNullOrWhiteSpace([string]$recovery.Diagnostic)) {
            [string]$recovery.State
        }
        else {
            "$($recovery.State); $($recovery.Diagnostic)"
        }

        throw "Terminal '$terminalId' ($windowId) was recreated but could not be identified after $($recovery.Attempts) observation attempt(s): $detail"
    }

    $hwnd = [long]$recovery.Hwnd

    # Safety net: a recreated window holds exactly the configured tabs. More
    # (raw, duplicate-preserving) TabItems means `wt -w` attached to an
    # existing window.
    $configuredCount = @($Terminal.tabs).Count
    $actualCount = & $TabCountProvider $hwnd $configuredCount

    if (-not (Test-DevWSCreatedTabCount -ActualCount $actualCount -ConfiguredCount $configuredCount)) {
        throw "Terminal '$terminalId' ($windowId): the recreated window reports $actualCount tabs for $configuredCount configured tabs."
    }

    # Movement uses the FROZEN normal-side placement; an unreachable fallback
    # rectangle arrives as ApplyGeometry=false and skips movement while the
    # recreation, tab count, activeTab and runtime-state work stays unchanged.
    if ($ApplyGeometry) {
        $layoutValue = if ($null -ne $Layout) { $Layout } else { $Terminal.layout }
        Move-DevWSWindowHwnd -Hwnd $hwnd -Layout $layoutValue -Context "terminal '$terminalId' ($windowId)"
    }

    # New-DevWSTerminalCreateArguments already selected activeTab via the
    # creation argument list; no post-create `wt` selection is needed.
    & $StatePublisher $SetId $terminalId $windowId $hwnd
}

# One-shot authenticated pipe transport (Public Security Phase 2-D): exactly
# one connection, one request, ACCEPTED after complete placement validation
# and before the first destructive side effect (any close or recreation),
# FINAL with the outcome, then exit. There are no request/result files; a lost
# ACCEPTED or FINAL never causes automatic Reset repetition.
$kind = "reset"

$server = New-DevWSWorkerPipeServer -Kind $kind

try {
    if (-not (Wait-DevWSWorkerPipeConnection -Server $server -TimeoutSeconds 60)) {
        exit 0
    }

    $request = Read-DevWSWorkerPipeRequest -Server $server -Kind $kind -TimeoutSeconds 20

    if (-not $request.Ok) {
        [void](Send-DevWSWorkerError -Server $server -Kind $kind -RequestId ([string]$request.RequestId) -Error ([string]$request.Error))
        exit 0
    }

    $requestId = [string]$request.RequestId
    $payload = $request.Payload

    # ---- pre-accept validation (any failure: explicit rejection, no side
    # effects) ---------------------------------------------------------------
    if (-not (Test-DevWSProperty -Object $payload -Name "setId") -or [string]::IsNullOrWhiteSpace([string]$payload.setId)) {
        [void](Send-DevWSWorkerError -Server $server -Kind $kind -RequestId $requestId -Error "Reset request is missing the required 'setId'.")
        exit 0
    }

    $config = $null
    $target = $null
    $state = $null
    $terminals = $null
    $placementPayload = $null

    try {
        $config = Get-DevWSConfig -Location $location
        $target = Resolve-DevWSLifecycleTarget -Config $config -SetId ([string]$payload.setId)
        $state = Read-DevWSRuntimeState
        $terminals = @(Get-DevWSWindows -Config $config -Type terminal -Set $target.Set)

        # v3 requests carry a required setId plus frozen terminal placement
        # records (id + move + exact geometry) that the NORMAL side selected
        # from the effective topology/profile decision. Legacy v1 `slots`
        # requests are not accepted here: the retained v1 CLI writes its
        # request under %USERPROFILE%\.ws, which never reaches this worker.
        if (-not (Test-DevWSProperty -Object $payload -Name "terminalPlacements")) {
            throw "Reset request is missing the required 'terminalPlacements'."
        }

        # Validate/correlate the COMPLETE request before ACCEPTED: a malformed
        # or unknown second placement must never surface after a destructive
        # close.
        $placementPayload = Resolve-DevWSTerminalPlacementPayload `
            -Placements (Get-DevWSProperty -Object $payload -Name "terminalPlacements") `
            -Terminals $terminals

        if (@($placementPayload.Terminals).Count -eq 0) {
            throw "Reset request contains no terminal placements."
        }

        # Trusted Windows Terminal launcher (the administrator-protected
        # package executable); a failed trust validation refuses before any
        # side effect.
        $Wt = Resolve-DevWSTrustedWindowsTerminalPath
    }
    catch {
        [void](Send-DevWSWorkerError -Server $server -Kind $kind -RequestId $requestId -Error $_.Exception.Message)
        exit 0
    }

    # ---- ACCEPTED boundary: after complete request/policy validation and
    # before any close or recreation --------------------------------------
    [void](Send-DevWSWorkerAccepted -Server $server -Kind $kind -RequestId $requestId)

    try {
        foreach ($terminal in @($placementPayload.Terminals)) {
            $placement = $placementPayload.Placements[[string]$terminal.id]

            Reset-DevWSTerminal `
                -Config $config `
                -Terminal $terminal `
                -State $state `
                -SetId $target.SetId `
                -ApplyGeometry ([bool]$placement.ApplyGeometry) `
                -Layout $placement.Layout
        }

        [void](Send-DevWSWorkerFinal -Server $server -Kind $kind -RequestId $requestId -Ok $true -Message "OK")
    }
    catch {
        [void](Send-DevWSWorkerFinal -Server $server -Kind $kind -RequestId $requestId -Ok $false -Message $_.Exception.Message)
        throw
    }
}
finally {
    # Ensure the caller consumed the buffered response (or that its handle is gone)
    # before the one-shot pipe instance is destroyed.
    Wait-DevWSWorkerFrameDelivery -Server $server
    $server.Dispose()
}
