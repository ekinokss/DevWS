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
        $Terminal,
        $State,
        [Parameter(Mandatory)]
        [string]$SetId,
        [bool]$ApplyGeometry = $true,
        [AllowNull()]$Layout = $null
    )

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

    $identity = Resolve-DevWSTerminalHwnd -WindowId $windowId -SetId $SetId -State $State -TerminalId $terminalId
    $locator  = $null

    if ($identity.Status -ne "present") {
        # Locator-assisted attach: works whether the window already exists but
        # was not discoverable, or is actually missing (creates a locator-only
        # window that is closed again below).
        $locator  = Start-DevWSLocator -WindowId $windowId
        $identity = [pscustomobject]@{
            Status = "present"
            Hwnd   = [long]$locator.Hwnd
            Source = "locator"
        }
    }

    try {
        # Close the whole managed Windows Terminal window using the proven
        # close-all flow (Alt+F4 then confirm).
        Close-DevWSWindowHwnd -Hwnd $identity.Hwnd -Context "terminal '$terminalId' ($windowId)"

        if (-not (Wait-DevWSWindowHwndGone -Hwnd $identity.Hwnd -TimeoutSeconds 10)) {
            throw "Terminal '$terminalId' ($windowId) did not close."
        }
    }
    finally {
        # If the window survived (close failed), remove the locator tab so the
        # user's window is left as configured.
        if ($null -ne $locator -and (Test-DevWSWindowHwnd -Hwnd $locator.Hwnd)) {
            [void](Remove-DevWSLocator -Locator $locator)
        }
    }

    # The old window is confirmed gone. ONLY NOW create the new generation: a
    # failed/cancelled close above must not invalidate tracking for the
    # still-running old shells. If recreation later fails, the new expected
    # generations simply have no valid publication (resolver: unavailable) and
    # a future reset overwrites them. One tracking context per configured tab.
    $trackingContexts = New-DevWSCwdTrackingContexts `
        -SetId $SetId `
        -TerminalId $terminalId `
        -WindowId $windowId `
        -Terminal $Terminal `
        -BootstrapPath $bootstrapPath

    # Recreate exactly the configured tab set (any count, command-only
    # terminals included), then restore geometry and the configured activeTab.
    [string[]]$createArguments = @(New-DevWSTerminalCreateArguments -Terminal $Terminal -TrackingContexts $trackingContexts)
    & $Wt @createArguments

    $hwnd = Wait-DevWSTerminalHwnd -WindowId $windowId -TimeoutSeconds 15

    if (-not $hwnd) {
        throw "Terminal '$terminalId' ($windowId) was recreated but could not be identified."
    }

    # Safety net: a recreated window holds exactly the configured tabs. More
    # (raw, duplicate-preserving) TabItems means `wt -w` attached to an
    # existing window.
    $configuredCount = @($Terminal.tabs).Count
    $actualCount = Wait-DevWSTabCountFromHwnd `
        -Hwnd $hwnd `
        -MinimumCount $configuredCount `
        -TimeoutSeconds 5

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
    Update-DevWSRuntimeTerminal -SetId $SetId -Id $terminalId -WindowId $windowId -Hwnd $hwnd
}

# One-shot authenticated pipe transport (Public Security Phase 2-D): exactly
# one connection, one request, ACCEPTED after complete placement validation
# and before the first destructive side effect (locator creation, close or
# recreation), FINAL with the outcome, then exit. There are no request/result
# files; a lost ACCEPTED or FINAL never causes automatic Reset repetition.
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
    # before locator creation, close or recreation -----------------------
    [void](Send-DevWSWorkerAccepted -Server $server -Kind $kind -RequestId $requestId)

    try {
        foreach ($terminal in @($placementPayload.Terminals)) {
            $placement = $placementPayload.Placements[[string]$terminal.id]

            Reset-DevWSTerminal `
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
