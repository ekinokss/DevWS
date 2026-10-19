# DevWS canonical launch transaction (Stage 2 two-warm-host architecture).
#
# One shared orchestration is used by the cold CLI path (`ws launch`) and by
# the warm normal coordinator:
#
#   PREPARE (concurrent, side-effect free)
#     app:      Phase A shared probe -> Phase B exactly one fresh refresh
#     broker:   side-effect-free terminal plan over the secure pipe
#   GO barrier
#     broker:   cheap WT-generation revalidation -> GO-ACK -> terminal kickoff
#     app:      back-to-back app kickoff immediately on GO-ACK
#   FINALIZE
#     app:      one shared polling loop
#     broker:   one shared terminal completion loop (its own process)
#
# Ownership, adoption, ambiguity and exact-HWND semantics are unchanged: they
# live in devws-app-window.ps1 and are reused here. Terminal launch policy
# lives in devws-terminal-launch.ps1 and is shared by the broker and the
# fallback worker.
#
# Failure boundary:
#   - before GO-ACK the Helper worker remains a permissible fallback (worker
#     first, then the app batch, preserving Stage-1 overlap);
#   - once GO-ACK is received terminal side effects may have started and the
#     Helper is NEVER used for that request; a lost FINAL is reported as an
#     uncertain broker completion and no terminal work is repeated.
#
# Lifecycle placement (Pass 5D): before the lock the transaction freezes ONE
# placement decision (New-DevWSLaunchLayoutPlan -> New-DevWSLifecycleLayoutPlan).
# A profile-free set never touches the monitor layer; a profile-aware set is
# sampled exactly once; an unsafe topology or an unreachable explicit profile
# rectangle refuses the launch before any side effect. The frozen plan feeds
# the app preparation and the broker/Helper terminal placement transport;
# nothing below re-samples topology or re-resolves profiles, so a launch keeps
# one coherent decision even if the display state changes mid-launch.

# Write-DevWSLaunchTrace lives in devws-paths.ps1 (shared by the CLI, the
# coordinator, every worker and the elevated broker).

function New-DevWSAppLaunchPlan {
    # App PREPARE: exactly the historic Phase A (one shared probe, classify
    # every app) plus Phase B (exactly one fresh batch refresh when anything is
    # still missing). NO launch and NO window move happens here; present apps
    # are moved by Start-DevWSAppLaunchPlan after the GO barrier.
    #
    # -Placements carries the FROZEN lifecycle placement decisions (id ->
    # { ApplyGeometry; Layout }); direct callers without a map keep the
    # historical App.layout behavior.
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Apps,
        [AllowNull()]
        [System.Collections.IDictionary]$Placements = $null
    )

    $appList = @($Apps)
    $placementMap = $null

    if ($null -ne $Placements) {
        $placementMap = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($key in @($Placements.Keys)) {
            $placementMap[[string]$key] = $Placements[$key]
        }
    }

    $failures = [System.Collections.Generic.List[object]]::new()
    $present = [System.Collections.Generic.List[object]]::new()

    Write-DevWSLaunchTrace -Event "app-prepare-start" -Data ([ordered]@{
        set  = $SetId
        apps = @($appList | ForEach-Object { [string]$_.id })
    })

    # ---- Phase A: one shared snapshot classifies every app ----
    $sharedProbe = @(Get-DevWSAppWindowProbe -Config $Config)
    $pending = [System.Collections.Generic.List[object]]::new()

    foreach ($app in $appList) {
        $appRef = "$SetId/$([string]$app.id)"

        try {
            $hwnd = [long](Resolve-DevWSAppLifecycleWindow `
                -Config $Config `
                -SetId $SetId `
                -App $app `
                -Operation "classify" `
                -InitialProbe $sharedProbe)
        }
        catch {
            $failures.Add([pscustomobject]@{ Ref = $appRef; Message = $_.Exception.Message }) | Out-Null
            continue
        }

        if ($hwnd -gt 0) {
            $present.Add([pscustomobject]@{ Ref = $appRef; App = $app; Hwnd = $hwnd }) | Out-Null
        }
        else {
            $pending.Add($app)
        }
    }

    # ---- Phase B: exactly one fresh batch refresh for apps still missing ----
    $missing = [System.Collections.Generic.List[object]]::new()
    $probeHwnds = @($sharedProbe | ForEach-Object { [long]$_.hwnd })
    $sharedProbes = 1

    if ($pending.Count -gt 0) {
        $freshProbe = @(Get-DevWSAppWindowProbe -Config $Config)
        $sharedProbes = 2
        $probeHwnds = @($freshProbe | ForEach-Object { [long]$_.hwnd })

        foreach ($app in $pending) {
            $appRef = "$SetId/$([string]$app.id)"

            try {
                $hwnd = [long](Resolve-DevWSAppLifecycleWindow `
                    -Config $Config `
                    -SetId $SetId `
                    -App $app `
                    -Operation "classify" `
                    -InitialProbe $freshProbe)
            }
            catch {
                $failures.Add([pscustomobject]@{ Ref = $appRef; Message = $_.Exception.Message }) | Out-Null
                continue
            }

            if ($hwnd -gt 0) {
                $present.Add([pscustomobject]@{ Ref = $appRef; App = $app; Hwnd = $hwnd }) | Out-Null
            }
            else {
                $missing.Add($app)
            }
        }
    }

    $plan = [pscustomobject]@{
        SetId        = $SetId
        Apps         = $appList
        Present      = $present.ToArray()
        Missing      = $missing.ToArray()
        ProbeHwnds   = $probeHwnds
        Failures     = $failures.ToArray()
        SharedProbes = $sharedProbes
        Placements   = $placementMap
        ReadyAtUtc   = [DateTimeOffset]::UtcNow
    }

    Write-DevWSLaunchTrace -Event "app-prepare-ready" -Data ([ordered]@{
        set     = $SetId
        present = @($plan.Present | ForEach-Object { $_.Ref })
        missing = @($plan.Missing | ForEach-Object { "$SetId/$([string]$_.id)" })
        probes  = $sharedProbes
    })

    return $plan
}

function Update-DevWSAppLaunchPlan {
    # Part 27: the frozen app evidence may become stale while the broker plans.
    # Re-run Phase B exactly once; a missing app that became resolvable moves to
    # Present (never launched), ambiguity/owned-mismatch still refuses.
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SetId
    )

    $failures = [System.Collections.Generic.List[object]]::new()
    foreach ($failure in @($Plan.Failures)) {
        $failures.Add($failure) | Out-Null
    }

    $present = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($Plan.Present)) {
        $present.Add($entry) | Out-Null
    }

    $missing = [System.Collections.Generic.List[object]]::new()
    $probeHwnds = @($Plan.ProbeHwnds)
    $extraProbes = 0

    if (@($Plan.Missing).Count -gt 0) {
        $freshProbe = @(Get-DevWSAppWindowProbe -Config $Config)
        $extraProbes = 1
        $probeHwnds = @($freshProbe | ForEach-Object { [long]$_.hwnd })

        foreach ($app in @($Plan.Missing)) {
            $appRef = "$SetId/$([string]$app.id)"

            try {
                $hwnd = [long](Resolve-DevWSAppLifecycleWindow `
                    -Config $Config `
                    -SetId $SetId `
                    -App $app `
                    -Operation "classify" `
                    -InitialProbe $freshProbe)
            }
            catch {
                $failures.Add([pscustomobject]@{ Ref = $appRef; Message = $_.Exception.Message }) | Out-Null
                continue
            }

            if ($hwnd -gt 0) {
                $present.Add([pscustomobject]@{ Ref = $appRef; App = $app; Hwnd = $hwnd }) | Out-Null
            }
            else {
                $missing.Add($app) | Out-Null
            }
        }
    }

    Write-DevWSLaunchTrace -Event "app-plan-refreshed" -Data ([ordered]@{
        set     = $SetId
        missing = @($missing | ForEach-Object { "$SetId/$([string]$_.id)" })
    })

    return [pscustomobject]@{
        SetId        = $Plan.SetId
        Apps         = $Plan.Apps
        Present      = $present.ToArray()
        Missing      = $missing.ToArray()
        ProbeHwnds   = $probeHwnds
        Failures     = $failures.ToArray()
        SharedProbes = [int]$Plan.SharedProbes + $extraProbes
        Placements   = (Get-DevWSProperty -Object $Plan -Name "Placements")
        ReadyAtUtc   = [DateTimeOffset]::UtcNow
    }
}

function Get-DevWSAppLaunchPlacement {
    # Frozen placement lookup for one app from the launch plan. The lifecycle
    # layout plan is resolved once per launch; refresh/finalization must never
    # re-resolve it. Direct callers without a placement map keep the
    # historical behavior (move=true, App.layout).
    param(
        $Plan,
        $App
    )

    $placements = Get-DevWSProperty -Object $Plan -Name "Placements"

    if ($null -ne $placements -and $placements.Contains([string]$App.id)) {
        return $placements[[string]$App.id]
    }

    return [pscustomobject]@{
        ApplyGeometry = $true
        Layout        = $App.layout
    }
}

function Start-DevWSAppLaunchPlan {
    # App KICK: move every present app, then invoke every genuinely missing
    # app's launch command back-to-back. One app's launch failure never blocks
    # later independent apps. Movement uses the FROZEN plan placement; a
    # skipped (unreachable fallback) placement never fails the app.
    param([Parameter(Mandatory)]$Plan)

    $failures = [System.Collections.Generic.List[object]]::new()
    $moved = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    $kicks = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in @($Plan.Present)) {
        $placement = Get-DevWSAppLaunchPlacement -Plan $Plan -App $entry.App

        try {
            if ([bool]$placement.ApplyGeometry) {
                Move-DevWSWindowHwnd -Hwnd ([long]$entry.Hwnd) -Layout $placement.Layout -Context "app '$($entry.Ref)'"
                $moved.Add([string]$entry.Ref) | Out-Null
            }
            else {
                $skipped.Add([string]$entry.Ref) | Out-Null

                Write-DevWSLaunchTrace -Event "layout-geometry-skipped" -Data ([ordered]@{
                    set = [string]$Plan.SetId
                    app = [string]$entry.App.id
                })
            }
        }
        catch {
            $failures.Add([pscustomobject]@{ Ref = [string]$entry.Ref; Message = $_.Exception.Message }) | Out-Null
        }
    }

    foreach ($app in @($Plan.Missing)) {
        $appRef = "$($Plan.SetId)/$([string]$app.id)"
        $record = [pscustomobject]@{
            Ref            = $appRef
            App            = $app
            PreLaunchHwnds = @($Plan.ProbeHwnds)
            Deadline       = $null
        }

        try {
            Invoke-DevWSAppLaunchCommand -App $app
            $record.Deadline = (Get-Date).AddSeconds($script:DevWSAppLaunchTimeoutSecondsDefault)
            $kicks.Add($record) | Out-Null

            Write-DevWSLaunchTrace -Event "app-kickoff" -Data ([ordered]@{
                set = $Plan.SetId
                app = [string]$app.id
            })
        }
        catch {
            $failures.Add([pscustomobject]@{ Ref = $appRef; Message = $_.Exception.Message }) | Out-Null
        }
    }

    return [pscustomobject]@{
        Moved    = $moved.ToArray()
        Skipped  = $skipped.ToArray()
        Kicks    = $kicks.ToArray()
        Failures = $failures.ToArray()
    }
}

function Complete-DevWSAppLaunchPlan {
    # App FINALIZE: one shared polling loop for every kicked app (one probe per
    # tick), with the existing pre-launch evidence, deadlines, adoption and
    # move semantics.
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Config,
        [AllowEmptyCollection()][object[]]$Kicks = @(),
        [int]$PollMilliseconds = $script:DevWSAppLaunchPollMillisecondsDefault
    )

    $failures = [System.Collections.Generic.List[object]]::new()
    $finalized = [System.Collections.Generic.List[string]]::new()
    $active = @($Kicks)

    while ($active.Count -gt 0) {
        $postProbe = @(Get-DevWSAppWindowProbe -Config $Config)
        $remaining = [System.Collections.Generic.List[object]]::new()

        foreach ($record in $active) {
            $attempt = $null

            try {
                $attempt = Complete-DevWSAppLaunchAttempt `
                    -SetId $Plan.SetId `
                    -App $record.App `
                    -Probed $postProbe `
                    -PreLaunchHwnds $record.PreLaunchHwnds `
                    -Deadline $record.Deadline `
                    -LaunchTimeoutSeconds $script:DevWSAppLaunchTimeoutSecondsDefault
            }
            catch {
                $failures.Add([pscustomobject]@{ Ref = [string]$record.Ref; Message = $_.Exception.Message }) | Out-Null
                continue
            }

            if ($null -ne $attempt -and $attempt.Status -eq "resolved") {
                $placement = Get-DevWSAppLaunchPlacement -Plan $Plan -App $record.App

                try {
                    if ([bool]$placement.ApplyGeometry) {
                        Move-DevWSWindowHwnd `
                            -Hwnd ([long]$attempt.Hwnd) `
                            -Layout $placement.Layout `
                            -Context "app '$($record.Ref)'"
                    }
                    else {
                        Write-DevWSLaunchTrace -Event "layout-geometry-skipped" -Data ([ordered]@{
                            set = [string]$Plan.SetId
                            app = [string]$record.App.id
                        })
                    }

                    $finalized.Add([string]$record.Ref) | Out-Null

                    Write-DevWSLaunchTrace -Event "app-finalized" -Data ([ordered]@{
                        set = $Plan.SetId
                        app = [string]$record.App.id
                    })
                }
                catch {
                    $failures.Add([pscustomobject]@{ Ref = [string]$record.Ref; Message = $_.Exception.Message }) | Out-Null
                }

                continue
            }

            if ($null -ne $attempt -and $attempt.Status -eq "pending") {
                $remaining.Add($record) | Out-Null
            }
        }

        $active = $remaining.ToArray()

        if ($active.Count -gt 0) {
            Start-Sleep -Milliseconds $PollMilliseconds
        }
    }

    return [pscustomobject]@{
        Finalized = $finalized.ToArray()
        Failures  = $failures.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Canonical launch transaction
# ---------------------------------------------------------------------------

function New-DevWSLaunchLayoutPlan {
    # Normal-side lifecycle placement preflight for one launch target: the
    # frozen per-item effective rectangles (exact matched profile override,
    # sparse fallback per item, or whole-set fallback). Read-only.
    #
    # Returns $null when the target has no enabled items: a no-op launch has
    # no placement policy and therefore pays no topology cost. Otherwise the
    # set's layoutProfiles decide whether exactly one monitor snapshot is
    # required (profile-free sets never touch the monitor layer).
    param(
        $Config,
        [string]$SetId,
        [AllowNull()][object[]]$Terminals = $null,
        [AllowNull()][object[]]$Apps = $null,
        [AllowNull()]$TopologyProvider = $null
    )

    $target = Resolve-DevWSLifecycleTarget -Config $Config -SetId $SetId

    if ($null -eq $Terminals) {
        $Terminals = @(Get-DevWSWindows -Config $Config -Type "terminal" -EnabledOnly -Set $target.Set)
    }

    if ($null -eq $Apps) {
        $Apps = @(Get-DevWSWindows -Config $Config -Type "app" -EnabledOnly -Set $target.Set)
    }

    if ((@($Terminals).Count + @($Apps).Count) -eq 0) {
        return $null
    }

    $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in @(@($Terminals) + @($Apps))) {
        if ($null -ne $item) { $wanted.Add([string]$item.id) | Out-Null }
    }

    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($window in @($target.Set.windows)) {
        if ($null -eq $window -or $window -isnot [System.Management.Automation.PSCustomObject]) { continue }
        if (-not [bool]$window.enabled) { continue }
        if (-not $wanted.Contains([string]$window.id)) { continue }
        $items.Add($window) | Out-Null
    }

    $planArgs = @{
        Config = $Config
        SetId  = $target.SetId
        Set    = $target.Set
        Items  = @($items.ToArray())
    }

    if ($null -ne $TopologyProvider) { $planArgs.TopologyProvider = $TopologyProvider }

    return (New-DevWSLifecycleLayoutPlan @planArgs)
}

function New-DevWSLaunchRequestId {
    # Unique enough inside one session for the broker's single pending plan.
    return [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString() + [string](Get-Random -Minimum 100 -Maximum 999))
}

function New-DevWSCaptureRequestId {
    # Capture-specific broker request id: millisecond time scaled by 1_000_000
    # plus a 0..999999 random slot (positive Int64, digits only). The launch id
    # generator above is deliberately unchanged. Generator uniqueness is NOT
    # the ownership mechanism: the protected claim (exclusive creation) is the
    # authoritative collision defense and fails closed on any residual
    # collision.
    return [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000000 + (Get-Random -Minimum 0 -Maximum 1000000))
}

function Invoke-DevWSLaunchTransaction {
    # Canonical `launch` orchestration: pure validation (including the
    # Pass-5D lifecycle placement preflight) before the lifecycle lock, every
    # live side effect inside it. The elevated broker prepares the terminal
    # plan concurrently with the app prepare, side effects start only after
    # the GO barrier, and the Helper fallback remains available only before
    # GO-ACK.
    #
    # -LayoutPlan is the optional precomputed placement decision from the
    # warm coordinator (built before its accepted ACK). When supplied it is
    # validated and NEVER re-derived; when absent exactly one lifecycle plan
    # is computed here before any side effect.
    param(
        [Parameter(Mandatory)]
        $Config,
        [string]$SetId,
        [AllowNull()]
        $LayoutPlan = $null
    )

    $target = Resolve-DevWSLifecycleTarget -Config $Config -SetId $SetId

    # Path validation applies only to the selected set; another set's missing
    # directory must never block this launch.
    Assert-DevWSTerminalPaths -Config $Config -Set $target.Set -Source "ws launch"

    $terminals = @(Get-DevWSWindows -Config $Config -Type "terminal" -EnabledOnly -Set $target.Set)
    $apps      = @(Get-DevWSWindows -Config $Config -Type "app" -EnabledOnly -Set $target.Set)

    Assert-DevWSElevatedTerminals -Terminals $terminals

    if (($terminals.Count + $apps.Count) -eq 0) {
        return [pscustomobject]@{
            SetId          = $target.SetId
            NoEnabledItems = $true
            AppSummary     = $null
            LayoutSource   = $null
            ProfileId      = $null
            LayoutWarnings = @()
        }
    }

    if ($apps.Count -gt 0) {
        Assert-DevWSAppInstanceModeExplicit -Apps $apps -SetId $target.SetId
    }

    # ---- Pass 5D lifecycle placement preflight (read-only, pre-lock) ------
    # The placement decision is frozen before ANY side effect: a precomputed
    # plan (warm coordinator pre-ack) is validated instead, and topology is
    # never re-sampled for it. A profile-free set performs no monitor access.
    $frozenPlan = $LayoutPlan

    if ($null -ne $frozenPlan) {
        Assert-DevWSLifecycleLayoutPlan -Plan $frozenPlan -SetId $target.SetId -Items (@($terminals) + @($apps))
    }
    else {
        $frozenPlan = New-DevWSLaunchLayoutPlan -Config $Config -SetId $target.SetId -Terminals $terminals -Apps $apps
    }

    $terminalPlacements = @(Get-DevWSLifecycleTerminalPlacementRecords -Plan $frozenPlan)
    $appPlacements = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($planItem in @($frozenPlan.Items)) {
        if ([string]$planItem.Type -ine "app") { continue }

        $appPlacements[[string]$planItem.ItemId] = [pscustomobject]@{
            ApplyGeometry = [bool]$planItem.ApplyGeometry
            Layout        = $planItem.Layout
        }
    }

    $fingerprintShort = [string]$frozenPlan.TopologyFingerprint

    if (-not [string]::IsNullOrWhiteSpace($fingerprintShort)) {
        $fingerprintShort = $fingerprintShort.Substring(0, [Math]::Min(12, $fingerprintShort.Length))
    }
    else {
        $fingerprintShort = $null
    }

    Write-DevWSLaunchTrace -Event "lifecycle-layout-plan" -Data ([ordered]@{
        set          = $target.SetId
        profileAware = [bool]$frozenPlan.ProfileAware
        source       = [string]$frozenPlan.Source
        profileId    = [string]$frozenPlan.ProfileId
        fingerprint  = $fingerprintShort
        skipped      = @($frozenPlan.Items | Where-Object { -not [bool]$_.ApplyGeometry } | ForEach-Object { [string]$_.ItemId })
    })

    $state = [pscustomobject]@{
        AppSummary       = $null
        AppFailures      = @()
        TerminalFailures = @()
        BrokerUsed       = $false
        BrokerUncertain  = $false
    }

    Write-DevWSLaunchTrace -Event "transaction-start" -Data ([ordered]@{
        set       = $target.SetId
        terminals = $terminals.Count
        apps      = $apps.Count
    })

    [void](Invoke-DevWSWithLifecycleLock -ScriptBlock {
        $requestId = New-DevWSLaunchRequestId
        $connection = $null
        $brokerReady = $null
        $goAck = $null
        $brokerUsable = $false

        # ---- Phase 1: initate the broker terminal plan (no wait) ----------
        if ($terminals.Count -gt 0) {
            try {
                if (-not (Test-DevWSElevatedBrokerAvailable)) {
                    [void](Request-DevWSElevatedBrokerRecovery -TimeoutSeconds 20)
                }

                $connection = New-DevWSElevatedBrokerPrepare -RequestId $requestId -SetId $target.SetId -TerminalPlacements $terminalPlacements
                $brokerUsable = $true

                Write-DevWSLaunchTrace -Event "stage2-broker-prepare-sent" -Data ([ordered]@{
                    set = $target.SetId
                })
            }
            catch {
                $connection = $null
                $brokerUsable = $false
            }
        }

        # ---- Phase 2: app prepare (concurrent with the broker plan) -------
        $appPlan = $null

        if ($apps.Count -gt 0) {
            try {
                $appPlan = New-DevWSAppLaunchPlan -Config $Config -SetId $target.SetId -Apps $apps -Placements $appPlacements
            }
            catch {
                $state.AppFailures = @($_.Exception.Message)
            }
        }

        # ---- Phase 3: settle broker READY --------------------------------
        if ($brokerUsable) {
            try {
                $brokerReady = Wait-DevWSElevatedBrokerPrepare -Connection $connection -TimeoutMilliseconds 30000
            }
            catch {
                $brokerReady = $null
            }

            if ($null -eq $brokerReady -or [string]$brokerReady.type -ne "ready") {
                if ($null -ne $brokerReady -and [string]$brokerReady.type -ne "prepare-failed") {
                    Write-DevWSLaunchTrace -Event "stage2-broker-declined" -Data ([ordered]@{
                        type = [string]$brokerReady.type
                    })
                }

                $brokerUsable = $false
            }
            else {
                Write-DevWSLaunchTrace -Event "stage2-broker-ready" -Data ([ordered]@{
                    planId    = [string]$brokerReady.planId
                    elapsedMs = [long]$brokerReady.elapsedMs
                    present   = [int]$brokerReady.plan.counts.present
                    missing   = [int]$brokerReady.plan.counts.missing
                    ambiguous = [int]$brokerReady.plan.counts.ambiguous
                    failed    = [int]$brokerReady.plan.counts.failed
                })
            }
        }

        # ---- Phase 4: app plan age guard (refresh exactly once) -----------
        if ($brokerUsable -and $null -ne $appPlan -and
            ([DateTimeOffset]::UtcNow - $appPlan.ReadyAtUtc).TotalMilliseconds -gt 500) {
            try {
                $appPlan = Update-DevWSAppLaunchPlan -Plan $appPlan -Config $Config -SetId $target.SetId
            }
            catch {
                $state.AppFailures = @($state.AppFailures) + @($_.Exception.Message)
            }
        }

        # ---- Phase 5: GO barrier ------------------------------------------
        if ($brokerUsable) {
            try {
                $goAck = Send-DevWSElevatedBrokerGo -Connection $connection -RequestId $requestId -PlanId ([string]$brokerReady.planId)
            }
            catch {
                $goAck = $null
            }

            if ($null -ne $goAck -and [string]$goAck.type -eq "replan-required") {
                # One bounded re-prepare for a changed WT population.
                try { Close-DevWSElevatedBrokerConnection -Connection $connection } catch { }
                $connection = $null
                $brokerUsable = $false

                try {
                    if (Test-DevWSElevatedBrokerAvailable) {
                        $connection = New-DevWSElevatedBrokerPrepare -RequestId $requestId -SetId $target.SetId -TerminalPlacements $terminalPlacements
                        $retryReady = Wait-DevWSElevatedBrokerPrepare -Connection $connection -TimeoutMilliseconds 30000

                        if ($null -ne $retryReady -and [string]$retryReady.type -eq "ready") {
                            $goAck = Send-DevWSElevatedBrokerGo -Connection $connection -RequestId $requestId -PlanId ([string]$retryReady.planId)

                            if ($null -ne $goAck -and [string]$goAck.type -eq "go-ack") {
                                $brokerUsable = $true

                                Write-DevWSLaunchTrace -Event "stage2-broker-replanned" -Data ([ordered]@{
                                    planId = [string]$retryReady.planId
                                })
                            }
                        }
                    }
                }
                catch {
                    $brokerUsable = $false
                }
            }
        }

        if ($brokerUsable -and $null -ne $goAck -and [string]$goAck.type -eq "go-ack") {
            # ---- GO-ACK received: app kickoff starts immediately -----------
            $state.BrokerUsed = $true

            Write-DevWSLaunchTrace -Event "stage2-go-ack" -Data ([ordered]@{
                recheckMs = [long]$goAck.recheckMs
                ackAt     = [long]$goAck.ackAt
            })

            $startResult = $null
            $completeResult = $null

            if ($null -ne $appPlan) {
                $startResult = Start-DevWSAppLaunchPlan -Plan $appPlan
                $completeResult = Complete-DevWSAppLaunchPlan -Plan $appPlan -Config $Config -Kicks $startResult.Kicks
            }

            $appFailuresByRef = [ordered]@{}

            foreach ($failure in @($appPlan.Failures) + @($startResult.Failures) + @($completeResult.Failures)) {
                if (-not $appFailuresByRef.Contains([string]$failure.Ref)) {
                    $appFailuresByRef[[string]$failure.Ref] = [string]$failure.Message
                }
            }

            foreach ($app in $apps) {
                $appRef = "$($target.SetId)/$([string]$app.id)"

                if ($appFailuresByRef.Contains($appRef)) {
                    $state.AppFailures = @($state.AppFailures) + @([string]$appFailuresByRef[$appRef])
                }
            }

            if ($null -ne $appPlan) {
                Write-DevWSLaunchTrace -Event "stage2-app-kicked" -Data ([ordered]@{
                    kicked = @($startResult.Kicks).Count
                })
            }

            # ---- Terminal FINAL (bounded; NO fallback after GO-ACK) --------
            $final = Read-DevWSElevatedBrokerFinal -Connection $connection -TimeoutMilliseconds 120000

            if ($null -eq $final -or [string]$final.type -ne "final") {
                $state.BrokerUncertain = $true
                $state.TerminalFailures = @("Terminal launch completion is uncertain: the elevated broker did not report FINAL after GO-ACK. No fallback was attempted and no terminal work will be repeated.")

                Write-DevWSLaunchTrace -Event "stage2-broker-uncertain" -Data ([ordered]@{})
            }
            else {
                if ($null -ne $final.kicked -and @($final.kicked).Count -gt 0) {
                    Write-DevWSLaunchTrace -Event "stage2-terminal-kick" -Data ([ordered]@{
                        count     = @($final.kicked).Count
                        firstAt   = [long]$final.kicked[0].startedAt
                        lastAt    = [long]$final.kicked[@($final.kicked).Count - 1].startedAt
                    })
                }

                $state.TerminalFailures = @($final.summary.failures)

                Write-DevWSLaunchTrace -Event "stage2-terminal-final" -Data ([ordered]@{
                    finalized = @($final.summary.finalized).Count
                    failures  = @($final.summary.failures).Count
                })
            }

            if ($null -ne $appPlan) {
                Write-DevWSLaunchTrace -Event "stage2-app-finalized" -Data ([ordered]@{
                    finalized = @($completeResult.Finalized).Count
                })
            }

            $state.AppSummary = [pscustomobject]@{
                Present   = @($startResult.Moved)
                Launched  = @($startResult.Kicks | ForEach-Object { [string]$_.Ref })
                Finalized = @($completeResult.Finalized)
                Failures  = @($state.AppFailures)
            }
        }
        else {
            # ---- Pre-GO failure: Helper fallback remains permissible -------
            if ($null -ne $connection) {
                try { Close-DevWSElevatedBrokerConnection -Connection $connection } catch { }
                $connection = $null
            }

            Write-DevWSLaunchTrace -Event "stage2-helper-fallback" -Data ([ordered]@{
                set = $target.SetId
            })

            # Model A one-shot worker transport (Public Security Phase 2-D):
            # Start establishes the authenticated pipe transport and obtains
            # ACCEPTED before the app pipeline begins, so the High terminal
            # worker executes concurrently with the Medium application work.
            # Start-level NotTransmitted/Rejected/UncertainNoAck outcomes
            # propagate as state-tagged failures and are never retried or
            # replaced here.
            $workerRequest = $null
            $appException = $null

            if ($terminals.Count -gt 0) {
                $workerRequest = Start-DevWSWorkerRequest `
                    -Kind "launch" `
                    -TaskName "DevWorkspace-ElevatedHelper" `
                    -Payload @{ setId = $target.SetId; terminalPlacements = @($terminalPlacements) } `
                    -TimeoutSeconds 120

                Write-DevWSLaunchTrace -Event "worker-requested" -Data ([ordered]@{ set = $target.SetId })
            }

            try {
                $startResult = $null
                $completeResult = $null

                if ($null -ne $appPlan) {
                    $startResult = Start-DevWSAppLaunchPlan -Plan $appPlan
                    $completeResult = Complete-DevWSAppLaunchPlan -Plan $appPlan -Config $Config -Kicks $startResult.Kicks
                }

                $appFailuresByRef = [ordered]@{}

                if ($null -ne $appPlan) {
                    foreach ($failure in @($appPlan.Failures) + @($startResult.Failures) + @($completeResult.Failures)) {
                        if (-not $appFailuresByRef.Contains([string]$failure.Ref)) {
                            $appFailuresByRef[[string]$failure.Ref] = [string]$failure.Message
                        }
                    }
                }

                foreach ($app in $apps) {
                    $appRef = "$($target.SetId)/$([string]$app.id)"

                    if ($appFailuresByRef.Contains($appRef)) {
                        $state.AppFailures = @($state.AppFailures) + @([string]$appFailuresByRef[$appRef])
                    }
                }

                if ($null -ne $appPlan) {
                    $state.AppSummary = [pscustomobject]@{
                        Present   = @($startResult.Moved)
                        Launched  = @($startResult.Kicks | ForEach-Object { [string]$_.Ref })
                        Finalized = @($completeResult.Finalized)
                        Failures  = @($state.AppFailures)
                    }
                }
            }
            catch {
                # The Helper operation was already accepted: settle the worker
                # inside this frame so the connection is never leaked and the
                # terminal outcome stays explicit (Completed or
                # UncertainAfterAccept), then rethrow the app failure.
                $appException = $_
            }

            if ($null -ne $workerRequest) {
                try {
                    [void](Complete-DevWSWorkerRequest -Request $workerRequest)
                }
                catch {
                    $state.TerminalFailures = @($state.TerminalFailures) + @("Terminal worker failed: $($_.Exception.Message)")
                }

                Write-DevWSLaunchTrace -Event "worker-settled" -Data ([ordered]@{ set = $target.SetId })
            }

            if ($null -ne $appException) {
                throw $appException
            }
        }

        if ($null -ne $connection) {
            try { Close-DevWSElevatedBrokerConnection -Connection $connection } catch { }
            $connection = $null
        }

        $appFailureText = if (@($state.AppFailures).Count -gt 0) { @($state.AppFailures) -join " | " } else { $null }
        $terminalFailureText = if (@($state.TerminalFailures).Count -gt 0) { @($state.TerminalFailures) -join " | " } else { $null }

        if ($null -ne $appFailureText -and $null -ne $terminalFailureText) {
            throw "App launch failed: $appFailureText | Terminal launch failed: $terminalFailureText"
        }

        if ($null -ne $appFailureText) {
            throw $appFailureText
        }

        if ($null -ne $terminalFailureText) {
            throw $terminalFailureText
        }
    })

    Write-DevWSLaunchTrace -Event "transaction-end" -Data ([ordered]@{
        set         = $target.SetId
        broker      = [bool]$state.BrokerUsed
        uncertain   = [bool]$state.BrokerUncertain
        layoutSource = [string]$frozenPlan.Source
        profileId   = [string]$frozenPlan.ProfileId
        failures    = @($state.AppFailures) + @($state.TerminalFailures)
    })

    return [pscustomobject]@{
        SetId          = $target.SetId
        NoEnabledItems = $false
        AppSummary     = $state.AppSummary
        LayoutSource   = [string]$frozenPlan.Source
        ProfileId      = $frozenPlan.ProfileId
        LayoutWarnings = @($frozenPlan.Warnings)
    }
}
