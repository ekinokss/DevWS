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
. (Join-Path $LibDir "devws-native.ps1")
. (Join-Path $LibDir "devws-window-ops.ps1")
. (Join-Path $LibDir "devws-uia.ps1")
. (Join-Path $LibDir "devws-state.ps1")
. (Join-Path $LibDir "devws-identity.ps1")
. (Join-Path $LibDir "devws-worker-protocol.ps1")
. (Join-Path $LibDir "devws-terminal-launch.ps1")

# One-shot authenticated pipe transport (Public Security Phase 2-D): exactly
# one connection, one request, ACCEPTED before the first side effect, FINAL
# with the outcome, then exit. There are no request/result files.
$location = Resolve-DevWSConfigLocation -StartPath $PSScriptRoot
$kind = "launch"

$server = New-DevWSWorkerPipeServer -Kind $kind

try {
    if (-not (Wait-DevWSWorkerPipeConnection -Server $server -TimeoutSeconds 60)) {
        # No caller appeared within the bounded no-client wait: exit without
        # any side effect.
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
        [void](Send-DevWSWorkerError -Server $server -Kind $kind -RequestId $requestId -Error "Launch request is missing the required 'setId'.")
        exit 0
    }

    $config = $null
    $target = $null
    $terminals = $null
    $placementPayload = $null

    try {
        $config = Get-DevWSConfig -Location $location
        $target = Resolve-DevWSLifecycleTarget -Config $config -SetId ([string]$payload.setId)

        # Path validation applies only to the requested set; another set's
        # missing directory must never block this launch.
        Assert-DevWSTerminalPaths -Config $config -Set $target.Set -Source "launch worker"

        $terminals = @(Get-DevWSWindows -Config $config -Type terminal -EnabledOnly -Set $target.Set)

        # Frozen normal-side placements: the Helper applies the caller-supplied
        # decisions verbatim (same records the broker would have received). A
        # legacy request without placements keeps the historical default; the
        # Helper never resolves topology or profiles.
        $placementRecords = $null

        if (Test-DevWSProperty -Object $payload -Name "terminalPlacements") {
            $placementRecords = $payload.terminalPlacements
        }

        $placementPayload = Resolve-DevWSTerminalPlacementPayload `
            -Placements $placementRecords `
            -Terminals $terminals `
            -RequireExactMembership
    }
    catch {
        [void](Send-DevWSWorkerError -Server $server -Kind $kind -RequestId $requestId -Error $_.Exception.Message)
        exit 0
    }

    # ---- ACCEPTED boundary: after complete request/policy validation and
    # before the first side effect (protected tracking-generation creation /
    # terminal kickoff) ------------------------------------------------
    [void](Send-DevWSWorkerAccepted -Server $server -Kind $kind -RequestId $requestId)

    try {
        # Canonical terminal launch policy (shared with the elevated broker):
        # side-effect-free state-first plan, back-to-back WT kickoff, one shared
        # completion loop. Identity, readiness, tab-count and tracking rules are
        # identical in both hosts.
        $state = Read-DevWSRuntimeState
        $plan = Get-DevWSTerminalLaunchPlan -Config $config -SetId $target.SetId -State $state -Terminals $placementPayload.Terminals -Placements $placementPayload.Placements

        $startResult = Start-DevWSTerminalLaunchPlan -Plan $plan
        $summary = Complete-DevWSTerminalLaunchPlan -Plan $plan -KickResult $startResult

        if (@($summary.Failures).Count -gt 0) {
            throw (@($summary.Failures) -join " | ")
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
