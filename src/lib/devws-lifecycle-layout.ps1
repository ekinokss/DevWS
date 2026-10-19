# DevWS lifecycle layout placement preflight (Pass 5D).
#
# Normal-side, READ-ONLY orchestration between the Pass-5B monitor topology
# library (devws-monitor.ps1) and the Pass-5C pure layout-profile policy
# (devws-layout-profile.ps1). For ONE lifecycle operation it:
#
#   - decides whether topology is required at all (a set with no
#     layoutProfiles never touches the monitor layer);
#   - acquires the topology snapshot AT MOST ONCE when profiles exist;
#   - refuses the operation before any side effect when a profile-aware set
#     cannot be placed safely (topology unavailable/incomplete/ambiguous,
#     duplicate matchers, or an unreachable explicit profile rectangle);
#   - resolves the effective rectangle per target item (exact matched profile
#     override, sparse per-item fallback, or whole-set fallback on no match);
#   - downgrades an unreachable FALLBACK rectangle to a deterministic warning
#     plus ApplyGeometry=false ("handle the item, do not move it");
#   - freezes the whole decision into one plan that every consumer (app
#     lifecycle, elevated broker, Helper fallback, reset worker) uses without
#     ever re-sampling topology.
#
# Frozen semantics (deliberate difference from save/save-layout): launch and
# reset do not persist geometry, so one operation keeps ONE topology decision
# even if the user docks mid-launch; the NEXT explicit command samples the
# new topology. save/save-layout revalidate topology A/B because they PERSIST
# configuration.
#
# This library never moves windows, never launches processes, never starts
# workers, never calls the broker, never writes config/state and never
# persists an active profile.

function Get-DevWSLifecycleTopologyRefusalMessage {
    # Deterministic lifecycle refusal text for an unsafe profile-aware
    # topology. Read-only commands may degrade to fallback; launch and reset
    # must not (an exact-topology placement cannot be chosen safely).
    param([string]$Reason)

    switch ($Reason) {
        "topology-unavailable" {
            return "This set has layout profiles but the current monitor topology is unavailable, so profile-aware placement cannot be chosen safely. The operation was refused before any side effect. Run 'ws monitors' for diagnostics."
        }
        "topology-incomplete" {
            return "This set has layout profiles but the current monitor topology is not safely matchable (monitor identity or correlation is incomplete), so profile-aware placement cannot be chosen safely. The operation was refused before any side effect. Run 'ws monitors' for diagnostics."
        }
        "topology-ambiguous" {
            return "This set has layout profiles but the current monitor topology contains ambiguous monitor identities, so profile-aware placement cannot be chosen safely. The operation was refused before any side effect. Run 'ws monitors' for diagnostics."
        }
        "ambiguous-matchers" {
            return "This set has two or more layout profiles with the same monitor matcher, so profile-aware placement cannot be chosen safely. The operation was refused before any side effect. Run 'ws layout-profile list' for diagnostics."
        }
        default {
            return "This set has layout profiles but no safe placement decision could be made ($Reason). The operation was refused before any side effect."
        }
    }
}

function New-DevWSLifecycleLayoutPlan {
    # One frozen, read-only lifecycle placement decision for one explicit
    # operation. See the file header for the full policy.
    #
    # Inputs:
    #   Config/SetId - target set resolution (skipped when -Set is supplied)
    #   Set          - optional pre-resolved set object
    #   Items        - optional explicit target items (a single reset may name
    #                  a DISABLED item); default: every enabled set window
    #   TopologyProvider - optional injection for tests; the default samples
    #                  the real topology exactly once
    #
    # The returned plan carries the frozen decision only; warnings are
    # deterministic per affected item in configured order.
    param(
        $Config,
        [AllowEmptyString()][string]$SetId,
        $Set = $null,
        [AllowNull()][object[]]$Items = $null,
        [AllowNull()]$TopologyProvider = $null
    )

    $setValue   = $Set
    $setIdValue = $SetId

    if ($null -eq $setValue) {
        $target     = Resolve-DevWSLifecycleTarget -Config $Config -SetId $SetId
        $setValue   = $target.Set
        $setIdValue = $target.SetId
    }
    elseif ([string]::IsNullOrWhiteSpace($setIdValue)) {
        $setIdValue = [string]$setValue.id
    }

    # ---- target item selection (configured order is authoritative) ---------
    $targetItems = [System.Collections.Generic.List[object]]::new()

    if ($null -eq $Items) {
        foreach ($window in @($setValue.windows)) {
            if ($null -eq $window -or $window -isnot [System.Management.Automation.PSCustomObject]) { continue }
            if (-not [bool]$window.enabled) { continue }
            $targetItems.Add($window) | Out-Null
        }
    }
    else {
        $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($item in @($Items)) {
            if ($null -eq $item) { continue }
            $wanted.Add([string]$item.id) | Out-Null
        }

        foreach ($window in @($setValue.windows)) {
            if ($null -eq $window -or $window -isnot [System.Management.Automation.PSCustomObject]) { continue }
            if (-not $wanted.Contains([string]$window.id)) { continue }
            $targetItems.Add($window) | Out-Null
        }
    }

    $profileAware = Test-DevWSSetHasLayoutProfiles -Set $setValue

    # ---- no profiles: the hard legacy fast path ----------------------------
    # No monitor snapshot, no topology dependency, no reachability gate; every
    # item keeps its fallback item.layout with movement enabled. This must
    # keep working even when Get-DevWSMonitorTopology would throw.
    if (-not $profileAware) {
        $legacyItems = [System.Collections.Generic.List[object]]::new()

        foreach ($window in $targetItems) {
            $legacyItems.Add([pscustomobject]@{
                ItemId        = [string]$window.id
                Type          = [string]$window.type
                Source        = "fallback"
                ProfileId     = $null
                ApplyGeometry = $true
                Layout        = $window.layout
                Reachable     = $null
                VisibleRatio  = $null
                VisibleWidth  = $null
                VisibleHeight = $null
            }) | Out-Null
        }

        return [pscustomobject]@{
            SetId               = $setIdValue
            ProfileAware        = $false
            Source              = "fallback"
            ProfileId           = $null
            Reason              = "no-profiles"
            TopologySignature   = $null
            TopologyFingerprint = $null
            Items               = @($legacyItems.ToArray())
            Warnings            = @()
        }
    }

    # ---- no target items: nothing to place, no topology cost ---------------
    if ($targetItems.Count -eq 0) {
        return [pscustomobject]@{
            SetId               = $setIdValue
            ProfileAware        = $true
            Source              = "fallback"
            ProfileId           = $null
            Reason              = "no-targets"
            TopologySignature   = $null
            TopologyFingerprint = $null
            Items               = @()
            Warnings            = @()
        }
    }

    if ($null -eq $TopologyProvider) {
        $TopologyProvider = { Get-DevWSMonitorTopology }
    }

    # Exactly ONE snapshot for the whole operation (never re-sampled).
    $topology = & $TopologyProvider

    $eligibility = Test-DevWSLayoutTopologyMatchable -Topology $topology

    if (-not $eligibility.Eligible) {
        throw ("Set '$setIdValue': " + (Get-DevWSLifecycleTopologyRefusalMessage -Reason $eligibility.Reason))
    }

    $selection = Resolve-DevWSLayoutProfile -Set $setValue -Topology $topology

    if ($selection.Status -eq "ambiguous") {
        throw ("Set '$setIdValue': " + (Get-DevWSLifecycleTopologyRefusalMessage -Reason "ambiguous-matchers"))
    }

    $monitorRects = [System.Collections.Generic.List[object]]::new()

    foreach ($topologyMonitor in @($topology.Monitors)) {
        if ($null -ne $topologyMonitor -and $null -ne $topologyMonitor.MonitorRect) {
            $monitorRects.Add($topologyMonitor.MonitorRect) | Out-Null
        }
    }

    $monitorRectValues = @($monitorRects.ToArray())
    $planItems = [System.Collections.Generic.List[object]]::new()
    $warnings  = [System.Collections.Generic.List[string]]::new()

    foreach ($window in $targetItems) {
        $itemId     = [string]$window.id
        $effective  = $window.layout
        $itemSource = "fallback"
        $profileId  = $null

        if ($selection.Status -eq "matched") {
            $entry = Get-DevWSLayoutProfileEntry -Profile $selection.Profile -ItemId $itemId

            if ($null -ne $entry) {
                $effective  = $entry
                $itemSource = "profile"
                $profileId  = $selection.ProfileId
            }
        }

        $metrics = Test-DevWSRectReachable -Rect $effective -MonitorRects $monitorRectValues
        $apply   = $true

        if (-not [bool]$metrics.Reachable) {
            if ($itemSource -eq "profile") {
                # An exact-topology profile with unreachable explicit geometry
                # is a configuration error, not a compatibility fallback.
                throw "Set '$setIdValue' matches layout profile '$profileId' on the current monitor topology, but the profile rectangle for item '$itemId' (x=$([int]$effective.x) y=$([int]$effective.y) w=$([int]$effective.w) h=$([int]$effective.h)) is not reachable on that topology (visibleRatio=$([Math]::Round([double]$metrics.VisibleRatio, 4)), visible=$([int]$metrics.VisibleWidth)x$([int]$metrics.VisibleHeight)). The operation was refused before any side effect; fix the profile rectangle for '$setIdValue/$itemId' with 'ws set-geometry $setIdValue/$itemId --x ... --y ... --width ... --height ... --layout $profileId', or re-key the profile with 'ws layout-profile match $setIdValue/$profileId'."
            }

            $apply = $false
            $warnings.Add(("$setIdValue/$itemId" + ": fallback layout is not reachable on the current monitor topology; the item will be handled normally but its window position will not be changed.")) | Out-Null
        }

        $planItems.Add([pscustomobject]@{
            ItemId        = $itemId
            Type          = [string]$window.type
            Source        = $itemSource
            ProfileId     = $profileId
            ApplyGeometry = $apply
            Layout        = $effective
            Reachable     = [bool]$metrics.Reachable
            VisibleRatio  = [double]$metrics.VisibleRatio
            VisibleWidth  = [int]$metrics.VisibleWidth
            VisibleHeight = [int]$metrics.VisibleHeight
        }) | Out-Null
    }

    return [pscustomobject]@{
        SetId               = $setIdValue
        ProfileAware        = $true
        Source              = if ($selection.Status -eq "matched") { "profile" } else { "fallback" }
        ProfileId           = $selection.ProfileId
        Reason              = $selection.Reason
        TopologySignature   = [string]$topology.Signature
        TopologyFingerprint = [string]$topology.Fingerprint
        Items               = @($planItems.ToArray())
        Warnings            = @($warnings.ToArray())
    }
}

function Assert-DevWSLifecycleLayoutPlan {
    # API-misuse guard for a precomputed plan crossing the coordinator ->
    # transaction boundary (or a test). Validates shape/correlation ONLY;
    # never samples topology and never re-resolves policy.
    param(
        [Parameter(Mandatory)]$Plan,
        [AllowEmptyString()][string]$SetId,
        [AllowNull()][object[]]$Items = $null
    )

    if (-not [string]::Equals([string]$Plan.SetId, [string]$SetId, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "The supplied lifecycle layout plan belongs to set '$($Plan.SetId)', not '$SetId'. Nothing was launched."
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($item in @($Plan.Items)) {
        $itemId = [string]$item.ItemId

        if ([string]::IsNullOrWhiteSpace($itemId)) {
            throw "The supplied lifecycle layout plan contains an item without an id. Nothing was launched."
        }

        if (-not $seen.Add($itemId)) {
            throw "The supplied lifecycle layout plan contains duplicate item '$itemId'. Nothing was launched."
        }

        if ([bool]$item.ApplyGeometry) {
            $layout = $item.Layout

            if ($null -eq $layout -or $layout -isnot [System.Management.Automation.PSCustomObject] -or
                -not (Test-DevWSInteger $layout.x) -or -not (Test-DevWSInteger $layout.y) -or
                -not (Test-DevWSInteger $layout.w) -or -not (Test-DevWSInteger $layout.h) -or
                [int]$layout.w -le 0 -or [int]$layout.h -le 0) {
                throw "The supplied lifecycle layout plan carries an invalid rectangle for item '$itemId'. Nothing was launched."
            }
        }
    }

    if ($null -ne $Items) {
        $wanted = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($target in @($Items)) {
            if ($null -ne $target) { $wanted.Add([string]$target.id) | Out-Null }
        }

        foreach ($itemId in $seen) {
            if (-not $wanted.Contains($itemId)) {
                throw "The supplied lifecycle layout plan contains item '$itemId', which is not a target of this operation. Nothing was launched."
            }
        }

        foreach ($targetId in $wanted) {
            if (-not $seen.Contains($targetId)) {
                throw "The supplied lifecycle layout plan is missing a placement record for target '$targetId'. Nothing was launched."
            }
        }
    }
}

function Get-DevWSLifecycleItemPlacement {
    # Frozen placement lookup over one lifecycle plan; $null when the item is
    # not represented.
    param(
        [Parameter(Mandatory)]$Plan,
        [AllowEmptyString()][string]$ItemId
    )

    foreach ($item in @($Plan.Items)) {
        if (([string]$item.ItemId) -ieq $ItemId) {
            return [pscustomobject]@{
                ApplyGeometry = [bool]$item.ApplyGeometry
                Layout        = $item.Layout
            }
        }
    }

    return $null
}

function Get-DevWSLifecycleTerminalPlacementRecords {
    # Wire-shaped terminal placement records for one lifecycle plan in plan
    # (configured) order. Final geometry/move decisions only: no profile id,
    # no monitor identity and no topology signature are transported, because
    # elevated hosts must never interpret placement policy.
    param([Parameter(Mandatory)]$Plan)

    $records = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($Plan.Items)) {
        if ([string]$item.Type -ine "terminal") { continue }

        $record = [ordered]@{
            id   = [string]$item.ItemId
            move = [bool]$item.ApplyGeometry
        }

        if ([bool]$item.ApplyGeometry) {
            $record.x = [int]$item.Layout.x
            $record.y = [int]$item.Layout.y
            $record.w = [int]$item.Layout.w
            $record.h = [int]$item.Layout.h
        }

        $records.Add([pscustomobject]$record) | Out-Null
    }

    return $records.ToArray()
}
