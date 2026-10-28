# DevWS topology layout-profile policy (Pass 5C).
#
# Pure, config-shaped policy for the optional per-set `layoutProfiles`
# topology-keyed absolute layout profiles:
#
#   - profile access and case-insensitive lookup
#   - shared matcher canonicalization reuse (the canonical token parser and
#     matcher-signature helpers live in devws-config.ps1, which every
#     config-reading process loads for validation; this library reuses them)
#   - pure topology/profile selection and sparse effective-layout resolution
#   - deterministic write-scope routing (implicit and explicit)
#   - topology stability comparison for the save transaction
#   - in-memory profile CRUD and sparse profile-map maintenance helpers
#   - profile reference resolution for the `ws layout-profile` command
#
# This library never performs Win32 acquisition, never persists configuration,
# never prints console output, never moves windows, never starts hosts, and
# never mutates monitor settings. Callers own topology sampling, persistence
# and output.
#
# Lifecycle boundary (Pass 5D, extended in v0.3 Phase 3): launch/reset
# placement consumes the frozen effective decision (exact matched profile
# override, relative placement with verified absolute fallback, or absolute
# fallback) through devws-lifecycle-layout.ps1. Preview and execution share
# devws-relative-layout's placement policy; this library itself stays pure
# policy for configuration routing, diagnostics and that lifecycle preflight.

# ---------------------------------------------------------------------------
# Profile access
# ---------------------------------------------------------------------------

function Get-DevWSLayoutProfiles {
    # Configured profiles of a set in configured order; absent property or a
    # non-array value returns an empty array. Never mutates.
    param($Set)

    if ($null -eq $Set) { return @() }
    if (-not (Test-DevWSProperty -Object $Set -Name "layoutProfiles")) { return @() }

    $profiles = $Set.layoutProfiles

    if ($null -eq $profiles -or $profiles -isnot [array]) { return @() }

    return @($profiles)
}

function Test-DevWSSetHasLayoutProfiles {
    param($Set)

    return (@(Get-DevWSLayoutProfiles -Set $Set).Count -gt 0)
}

function Get-DevWSLayoutProfile {
    # Case-insensitive profile lookup by id; $null when absent.
    param(
        $Set,
        [AllowEmptyString()][string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }

    foreach ($profileObject in @(Get-DevWSLayoutProfiles -Set $Set)) {
        if ($null -ne $profileObject -and ([string]$profileObject.id) -ieq $Id) {
            return $profileObject
        }
    }

    return $null
}

function Get-DevWSLayoutProfileMatcherSignature {
    # Canonical matcher signature of one profile; $null when the profile has no
    # usable matcher (invalid config; validation normally prevents this).
    param($Profile)

    if ($null -eq $Profile) { return $null }

    $match = Get-DevWSProperty -Object $Profile -Name "match"

    if ($null -eq $match) { return $null }

    $monitors = Get-DevWSProperty -Object $match -Name "monitors"

    if ($null -eq $monitors -or $monitors -isnot [array] -or @($monitors).Count -eq 0) { return $null }

    return (Get-DevWSLayoutMatcherSignature -Tokens @($monitors))
}

# ---------------------------------------------------------------------------
# Topology eligibility and stability (pure; no Win32)
# ---------------------------------------------------------------------------

function Test-DevWSLayoutTopologyMatchable {
    # A topology is eligible for profile matching only when it is available,
    # complete, unambiguous, and carries a non-empty canonical signature.
    param($Topology)

    if ($null -eq $Topology) {
        return [pscustomobject]@{ Eligible = $false; Reason = "topology-unavailable" }
    }

    if (-not [bool](Get-DevWSProperty -Object $Topology -Name "Available")) {
        return [pscustomobject]@{ Eligible = $false; Reason = "topology-unavailable" }
    }

    if ([string]::IsNullOrWhiteSpace([string](Get-DevWSProperty -Object $Topology -Name "Signature")) -or
        -not [bool](Get-DevWSProperty -Object $Topology -Name "IdentityComplete") -or
        -not [bool](Get-DevWSProperty -Object $Topology -Name "CorrelationComplete")) {
        return [pscustomobject]@{ Eligible = $false; Reason = "topology-incomplete" }
    }

    if ([bool](Get-DevWSProperty -Object $Topology -Name "IdentityAmbiguous")) {
        return [pscustomobject]@{ Eligible = $false; Reason = "topology-ambiguous" }
    }

    return [pscustomobject]@{ Eligible = $true; Reason = "matchable" }
}

function Test-DevWSLayoutTopologyStable {
    # Save-transaction stability gate: both snapshots must remain safely
    # matchable and carry the identical canonical signature and fingerprint.
    param($First, $Second)

    $firstEligibility  = Test-DevWSLayoutTopologyMatchable -Topology $First
    $secondEligibility = Test-DevWSLayoutTopologyMatchable -Topology $Second

    if (-not $firstEligibility.Eligible -or -not $secondEligibility.Eligible) {
        return [pscustomobject]@{ Stable = $false; Reason = "topology-not-matchable" }
    }

    if (-not [string]::Equals([string]$First.Signature, [string]$Second.Signature, [System.StringComparison]::Ordinal)) {
        return [pscustomobject]@{ Stable = $false; Reason = "topology-signature-changed" }
    }

    if (-not [string]::Equals([string]$First.Fingerprint, [string]$Second.Fingerprint, [System.StringComparison]::Ordinal)) {
        return [pscustomobject]@{ Stable = $false; Reason = "topology-fingerprint-changed" }
    }

    return [pscustomobject]@{ Stable = $true; Reason = "stable" }
}

# ---------------------------------------------------------------------------
# Pure selection
# ---------------------------------------------------------------------------

function Resolve-DevWSLayoutProfile {
    # Pure profile selection for one set against one topology snapshot.
    #
    # Status:  matched | fallback | ambiguous
    # Source:  profile | fallback | $null (ambiguous)
    # Reason:  matched | no-profiles | no-match | topology-unavailable |
    #          topology-incomplete | topology-ambiguous | ambiguous-matchers
    #
    # Read-only resolution may return fallback whenever topology is missing or
    # unsafe; profile order never participates in selection.
    param($Set, $Topology)

    $profiles = @(Get-DevWSLayoutProfiles -Set $Set)

    if ($profiles.Count -eq 0) {
        return [pscustomobject]@{
            Status           = "fallback"
            Source           = "fallback"
            ProfileId        = $null
            Profile          = $null
            Reason           = "no-profiles"
            TopologyEligible = $false
        }
    }

    $eligibility = Test-DevWSLayoutTopologyMatchable -Topology $Topology

    if (-not $eligibility.Eligible) {
        return [pscustomobject]@{
            Status           = "fallback"
            Source           = "fallback"
            ProfileId        = $null
            Profile          = $null
            Reason           = $eligibility.Reason
            TopologyEligible = $false
        }
    }

    $signature = [string]$Topology.Signature
    $matches = [System.Collections.Generic.List[object]]::new()

    foreach ($profileObject in $profiles) {
        $profileSignature = Get-DevWSLayoutProfileMatcherSignature -Profile $profileObject

        if ($null -ne $profileSignature -and
            [string]::Equals($profileSignature, $signature, [System.StringComparison]::Ordinal)) {
            $matches.Add($profileObject) | Out-Null
        }
    }

    if ($matches.Count -eq 1) {
        $matchedProfile = $matches[0]

        return [pscustomobject]@{
            Status           = "matched"
            Source           = "profile"
            ProfileId        = [string]$matchedProfile.id
            Profile          = $matchedProfile
            Reason           = "matched"
            TopologyEligible = $true
        }
    }

    if ($matches.Count -eq 0) {
        return [pscustomobject]@{
            Status           = "fallback"
            Source           = "fallback"
            ProfileId        = $null
            Profile          = $null
            Reason           = "no-match"
            TopologyEligible = $true
        }
    }

    # Defensive: validation rejects duplicate matchers statically; never guess.
    return [pscustomobject]@{
        Status           = "ambiguous"
        Source           = $null
        ProfileId        = $null
        Profile          = $null
        Reason           = "ambiguous-matchers"
        TopologyEligible = $true
    }
}

function Get-DevWSLayoutWriteRefusalMessage {
    # Shared, actionable refusal text for implicit writes that cannot safely
    # choose a storage scope.
    param([string]$Reason)

    switch ($Reason) {
        "topology-unavailable" {
            return "The current monitor topology is unavailable, and this set has layout profiles, so the storage scope cannot be determined safely. Nothing was changed."
        }
        "topology-incomplete" {
            return "The current monitor topology is not safely matchable (monitor identity or correlation is incomplete), and this set has layout profiles, so the storage scope cannot be determined safely. Nothing was changed."
        }
        "topology-ambiguous" {
            return "The current monitor topology contains ambiguous monitor identities, and this set has layout profiles, so the storage scope cannot be determined safely. Nothing was changed."
        }
        "ambiguous-matchers" {
            return "This set has two or more layout profiles with the same monitor matcher; the storage scope cannot be determined safely. Nothing was changed."
        }
        default {
            return "The storage scope cannot be determined safely ($Reason). Nothing was changed."
        }
    }
}

function Resolve-DevWSLayoutWriteScope {
    # Write routing for an implicit layout write (no explicit --layout
    # selector):
    #   - no profiles            -> fallback; topology not required
    #   - safe topology + match  -> that profile
    #   - safe topology + miss   -> fallback
    #   - unsafe topology        -> refuse (canonical must stay unchanged)
    param($Set, $Topology)

    if (-not (Test-DevWSSetHasLayoutProfiles -Set $Set)) {
        return [pscustomobject]@{
            Ok               = $true
            Source           = "fallback"
            ProfileId        = $null
            Profile          = $null
            Reason           = "no-profiles"
            Refusal          = $null
            TopologyRequired = $false
        }
    }

    $selection = Resolve-DevWSLayoutProfile -Set $Set -Topology $Topology

    if ($selection.Status -eq "matched") {
        return [pscustomobject]@{
            Ok               = $true
            Source           = "profile"
            ProfileId        = $selection.ProfileId
            Profile          = $selection.Profile
            Reason           = "matched"
            Refusal          = $null
            TopologyRequired = $true
        }
    }

    if ($selection.Status -eq "fallback" -and $selection.Reason -eq "no-match") {
        return [pscustomobject]@{
            Ok               = $true
            Source           = "fallback"
            ProfileId        = $null
            Profile          = $null
            Reason           = "no-match"
            Refusal          = $null
            TopologyRequired = $true
        }
    }

    return [pscustomobject]@{
        Ok               = $false
        Source           = $null
        ProfileId        = $null
        Profile          = $null
        Reason           = $selection.Reason
        Refusal          = (Get-DevWSLayoutWriteRefusalMessage -Reason $selection.Reason)
        TopologyRequired = $true
    }
}

function Resolve-DevWSLayoutProfileSaveTarget {
    # Explicit `--profile <id>` create-or-update target resolution. An explicit
    # profile save ALWAYS requires a safely matchable current topology because
    # it creates or verifies the profile's topology matcher.
    #
    # Returns Ok / Profile (existing or $null) / Create / Refusal.
    param(
        $Set,
        [string]$ProfileId,
        $Topology
    )

    if ([string]::IsNullOrWhiteSpace($ProfileId)) {
        return [pscustomobject]@{ Ok = $false; Profile = $null; Create = $false; Refusal = "--profile requires a profile id." }
    }

    if (-not (Test-DevWSStableIdSyntax -Id $ProfileId) -or (Test-DevWSLayoutProfileIdReserved -Id $ProfileId)) {
        return [pscustomobject]@{ Ok = $false; Profile = $null; Create = $false; Refusal = "'$ProfileId' is not a valid profile id. Profile ids use letters, digits, '.', '_' and '-' ('fallback' is reserved for the item.layout scope)." }
    }

    $eligibility = Test-DevWSLayoutTopologyMatchable -Topology $Topology

    if (-not $eligibility.Eligible) {
        return [pscustomobject]@{
            Ok      = $false
            Profile = $null
            Create  = $false
            Refusal = "The current monitor topology is not safely matchable ($($eligibility.Reason)); creating or updating an explicit layout profile always requires an exact current topology. Nothing was changed."
        }
    }

    $signature    = [string]$Topology.Signature
    $existing     = Get-DevWSLayoutProfile -Set $Set -Id $ProfileId

    if ($null -ne $existing) {
        $existingSignature = Get-DevWSLayoutProfileMatcherSignature -Profile $existing

        if ($null -eq $existingSignature -or
            -not [string]::Equals($existingSignature, $signature, [System.StringComparison]::Ordinal)) {
            return [pscustomobject]@{
                Ok      = $false
                Profile = $null
                Create  = $false
                Refusal = "Layout profile '$ProfileId' matches a different monitor topology than the current one. Run 'ws layout-profile match $ProfileId' to deliberately re-key it, or choose another profile. Nothing was changed."
            }
        }

        return [pscustomobject]@{ Ok = $true; Profile = $existing; Create = $false; Refusal = $null }
    }

    # Creation: refuse when the current topology already belongs to another
    # profile; never create two equivalent profiles.
    foreach ($profileObject in @(Get-DevWSLayoutProfiles -Set $Set)) {
        $profileSignature = Get-DevWSLayoutProfileMatcherSignature -Profile $profileObject

        if ($null -ne $profileSignature -and
            [string]::Equals($profileSignature, $signature, [System.StringComparison]::Ordinal)) {
            return [pscustomobject]@{
                Ok      = $false
                Profile = $null
                Create  = $false
                Refusal = "The current topology is already matched by profile '$([string]$profileObject.id)'; update that profile or re-key/remove it first. Nothing was changed."
            }
        }
    }

    return [pscustomobject]@{ Ok = $true; Profile = $null; Create = $true; Refusal = $null }
}

# ---------------------------------------------------------------------------
# Effective layout resolution (sparse-safe, non-mutating)
# ---------------------------------------------------------------------------

function Get-DevWSEffectiveLayout {
    # Read-only effective layout policy for the current topology.
    #
    # Absolute and matched-profile rectangles retain their established display
    # semantics. Relative layouts are resolved through the same shared
    # placement policy lifecycle execution uses, so `ws show-layout` reports
    # the applied, fallback, or skipped decision rather than a separate view.
    #
    # Resolution policy mirrors the approved fallback rules:
    #   - matched profile entry wins, including over relative intent;
    #   - relative item with unavailable topology has no verified geometry;
    #   - available topology + missing/ambiguous/unusable anchor uses the
    #     absolute fallback only when the existing reachability rule accepts it;
    #   - an unreachable relative target uses the fallback only when it is
    #     reachable; otherwise no verified geometry is advertised.
    param(
        [string]$SetId,
        $Set,
        $Topology
    )

    $selection = Resolve-DevWSLayoutProfile -Set $Set -Topology $Topology
    $profiles  = @(Get-DevWSLayoutProfiles -Set $Set)
    $profileAware = ($profiles.Count -gt 0)

    $monitorRects = @()

    if ($null -ne $Topology -and [bool](Get-DevWSProperty -Object $Topology -Name "Available")) {
        $topologyMonitors = Get-DevWSProperty -Object $Topology -Name "Monitors"

        if ($null -ne $topologyMonitors -and $topologyMonitors -is [array]) {
            foreach ($topologyMonitor in @($topologyMonitors)) {
                if ($null -ne $topologyMonitor -and $null -ne $topologyMonitor.MonitorRect) {
                    $monitorRects += $topologyMonitor.MonitorRect
                }
            }
        }
    }

    $measureReachability = {
        param($Candidate)

        if ($monitorRects.Count -eq 0 -or $null -eq $Candidate -or $Candidate -isnot [System.Management.Automation.PSCustomObject]) {
            return $null
        }

        return Test-DevWSRectReachable -Rect $Candidate -MonitorRects $monitorRects
    }

    $fingerprint = $null
    $signature   = $null

    if ($null -ne $Topology) {
        $fingerprint = [string](Get-DevWSProperty -Object $Topology -Name "Fingerprint")
        $signature   = [string](Get-DevWSProperty -Object $Topology -Name "Signature")
    }

    # Ordinary set launch targets enabled items only. The no-target lifecycle
    # path returns before topology/profile refusal, so the display model must
    # not advertise a refusal that ordinary launch would never reach. Disabled
    # items remain fully visible below for inspection and targeted operations.
    $enabledItemCount = 0
    $hasDisabledItems = $false

    foreach ($window in @($Set.windows)) {
        if ($null -eq $window -or $window -isnot [System.Management.Automation.PSCustomObject]) {
            continue
        }

        if ([bool]$window.enabled) {
            $enabledItemCount++
        }
        else {
            $hasDisabledItems = $true
        }
    }

    $profileRefusalReason = $null

    if ($profileAware -and $enabledItemCount -gt 0) {
        $eligibility = Test-DevWSLayoutTopologyMatchable -Topology $Topology

        if (-not $eligibility.Eligible) {
            $profileRefusalReason = $eligibility.Reason
        }
        elseif ($selection.Status -eq "ambiguous") {
            $profileRefusalReason = "ambiguous-matchers"
        }
    }

    $hasRelativeItems = $false
    $profileEntryUnreachable = $false
    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($Set.windows)) {
        if ($null -eq $item -or $item -isnot [System.Management.Automation.PSCustomObject]) {
            continue
        }

        $itemId       = [string]$item.id
        $layoutMode   = if ((Get-DevWSProperty -Object $item -Name "layoutMode") -ceq "relative") { "relative" } else { "absolute" }
        $relativeLayout = $null
        $profileMatched = ($selection.Status -eq "matched")
        $profileEntry   = $null
        $profileId      = $null
        $effective      = $item.layout
        $itemSource     = "fallback"

        if ($layoutMode -eq "relative") {
            $hasRelativeItems = $true
            $relativeLayout = Get-DevWSProperty -Object $item -Name "layoutRelative"
        }

        if ($profileMatched) {
            $profileEntry = Get-DevWSLayoutProfileEntry -Profile $selection.Profile -ItemId $itemId

            if ($null -ne $profileEntry) {
                $effective   = $profileEntry
                $itemSource  = "profile"
                $profileId   = $selection.ProfileId
            }
        }

        $profileOverridesRelative = ($layoutMode -eq "relative" -and $null -ne $profileEntry)
        $relativeStatus    = "not-applicable"
        $relativeReason    = $null
        $relativeMessage   = $null
        $relativeRect      = $null
        $relativeReachable = $null
        $fallbackReachable = $null
        $fallbackUsed      = $false

        if ($layoutMode -eq "relative") {
            $relativeDecision = Resolve-DevWSRelativePlacement `
                -RelativeLayout $relativeLayout `
                -Topology $Topology `
                -MonitorRects $monitorRects `
                -FallbackRect $item.layout

            $relativeStatus    = [string]$relativeDecision.Status
            $relativeReason    = [string]$relativeDecision.Reason
            $relativeMessage   = [string]$relativeDecision.Message
            $relativeRect      = $relativeDecision.RelativeRect
            $relativeReachable = $relativeDecision.RelativeReachable
            $fallbackReachable = $relativeDecision.FallbackReachable

            if (-not $profileOverridesRelative) {
                $effective   = $relativeDecision.EffectiveRect
                $itemSource  = [string]$relativeDecision.Source
                $fallbackUsed = [bool]$relativeDecision.FallbackUsed
            }
        }

        $reachable    = $null
        $visibleRatio = $null
        $visibleWidth = $null
        $visibleHeight = $null
        $applyGeometry = $true
        $placementStatus = "absolute"
        $placementReason = "absolute"

        if ($null -ne $profileEntry) {
            $effectiveMetrics = & $measureReachability $effective

            if ($null -ne $effectiveMetrics) {
                $reachable     = [bool]$effectiveMetrics.Reachable
                $visibleRatio  = [double]$effectiveMetrics.VisibleRatio
                $visibleWidth  = [int]$effectiveMetrics.VisibleWidth
                $visibleHeight = [int]$effectiveMetrics.VisibleHeight
                $applyGeometry = $reachable
                $placementStatus = if ($applyGeometry) { "profile" } else { "profile-unreachable" }
                $placementReason = $placementStatus
            }
            else {
                $applyGeometry = $false
                $placementStatus = "profile-unreachable"
                $placementReason = "profile-no-reachability"
            }

            if ([bool]$item.enabled -and -not $applyGeometry) {
                $profileEntryUnreachable = $true
            }
        }
        elseif ($layoutMode -eq "relative") {
            $reachable       = $relativeDecision.EffectiveReachable
            $applyGeometry   = [bool]$relativeDecision.ApplyGeometry
            $placementStatus = [string]$relativeDecision.Status
            $placementReason = [string]$relativeDecision.Reason

            if ($null -ne $effective) {
                $effectiveMetrics = & $measureReachability $effective

                if ($null -ne $effectiveMetrics) {
                    $visibleRatio  = [double]$effectiveMetrics.VisibleRatio
                    $visibleWidth  = [int]$effectiveMetrics.VisibleWidth
                    $visibleHeight = [int]$effectiveMetrics.VisibleHeight
                }
            }
        }
        elseif ($profileAware) {
            $effectiveMetrics = & $measureReachability $effective

            if ($null -ne $effectiveMetrics) {
                $reachable     = [bool]$effectiveMetrics.Reachable
                $visibleRatio  = [double]$effectiveMetrics.VisibleRatio
                $visibleWidth  = [int]$effectiveMetrics.VisibleWidth
                $visibleHeight = [int]$effectiveMetrics.VisibleHeight
                $applyGeometry = $reachable
            }
            else {
                $applyGeometry = $false
            }

            $placementStatus = if ($applyGeometry) { "fallback" } else { "fallback-unreachable" }
            $placementReason = $placementStatus
        }
        else {
            # Profile-free absolute targets retain the legacy placement
            # semantics: applied without a reachability gate.
            $reachable       = $null
            $applyGeometry   = $true
            $placementStatus = "absolute"
            $placementReason = "legacy-absolute"
        }

        $items.Add([pscustomobject]@{
            ItemId                    = $itemId
            Type                      = [string]$item.type
            Enabled                   = [bool]$item.enabled
            LayoutMode                = $layoutMode
            Rect                      = $effective
            Source                    = $itemSource
            ProfileId                 = $profileId
            ProfileMatched            = $profileMatched
            ProfileOverridesRelative  = $profileOverridesRelative
            RelativeLayout            = $relativeLayout
            RelativeStatus            = $relativeStatus
            RelativeReason            = $relativeReason
            RelativeMessage           = $relativeMessage
            RelativeRect              = $relativeRect
            RelativeReachable         = $relativeReachable
            FallbackRect              = $item.layout
            FallbackReachable         = $fallbackReachable
            FallbackUsed              = $fallbackUsed
            ApplyGeometry             = $applyGeometry
            PlacementStatus           = $placementStatus
            PlacementReason           = $placementReason
            Reachable                 = $reachable
            VisibleRatio              = $visibleRatio
            VisibleWidth              = $visibleWidth
            VisibleHeight             = $visibleHeight
        }) | Out-Null
    }

    if ($enabledItemCount -gt 0 -and $null -eq $profileRefusalReason -and $profileEntryUnreachable) {
        $profileRefusalReason = "unreachable-profile-entry"
    }

    $profileIds = @(Get-DevWSLayoutProfiles -Set $Set | ForEach-Object { [string]$_.id })

    return [pscustomobject]@{
        SetId                   = $SetId
        Status                  = $selection.Status
        Source                  = $selection.Source
        ProfileId               = $selection.ProfileId
        Reason                  = $selection.Reason
        ProfileAware            = $profileAware
        ProfileLifecycleRefusal = $profileRefusalReason
        EnabledItemCount        = $enabledItemCount
        HasDisabledItems        = $hasDisabledItems
        TopologyAvailable       = ($null -ne $Topology -and [bool](Get-DevWSProperty -Object $Topology -Name "Available"))
        TopologySignature       = $signature
        TopologyFingerprint     = $fingerprint
        HasRelativeItems        = $hasRelativeItems
        RelativeOperational     = $hasRelativeItems
        Profiles                = $profileIds
        Items                   = @($items.ToArray())
    }
}

function Get-DevWSLayoutProfileListModel {
    # Read-only listing model for `ws layout-profile list`.
    param(
        [string]$SetId,
        $Set,
        $Topology
    )

    $eligibility = Test-DevWSLayoutTopologyMatchable -Topology $Topology
    $selection   = Resolve-DevWSLayoutProfile -Set $Set -Topology $Topology

    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($profileObject in @(Get-DevWSLayoutProfiles -Set $Set)) {
        $monitors = Get-DevWSProperty -Object $profileObject.match -Name "monitors"
        $layouts  = Get-DevWSProperty -Object $profileObject -Name "layouts"

        $overrideCount = 0

        if ($null -ne $layouts -and $layouts -is [System.Management.Automation.PSCustomObject]) {
            $overrideCount = @($layouts.PSObject.Properties).Count
        }

        $matchesCurrent = ($selection.Status -eq "matched" -and ([string]$profileObject.id) -ieq ([string]$selection.ProfileId))

        $rows.Add([pscustomobject]@{
            Id            = [string]$profileObject.id
            MonitorCount  = @($monitors).Count
            OverrideCount = $overrideCount
            MatchesCurrent = $matchesCurrent
        }) | Out-Null
    }

    $fingerprint = $null

    if ($null -ne $Topology) {
        $fingerprint = [string](Get-DevWSProperty -Object $Topology -Name "Fingerprint")
    }

    return [pscustomobject]@{
        SetId               = $SetId
        Profiles            = @($rows.ToArray())
        TopologyStatus      = $eligibility.Reason
        TopologyFingerprint = $fingerprint
        SelectionStatus     = $selection.Status
        SelectionReason     = $selection.Reason
        MatchedProfileId    = $selection.ProfileId
        RoutedToFallback    = ($selection.Status -eq "fallback")
    }
}

# ---------------------------------------------------------------------------
# Profile references (`ws layout-profile` command surface)
# ---------------------------------------------------------------------------

function Resolve-DevWSLayoutProfileReference {
    # <profile>            -> defaultSet/profile
    # <set>/<profile>      -> explicit set
    # Rejects empty sides, more than one '/', unknown sets, and invalid or
    # reserved profile ids. Profile existence is checked by the caller.
    param(
        [Parameter(Mandatory)]
        $Config,
        [AllowEmptyString()]
        [string]$Reference,
        [string]$CommandName = "ws layout-profile"
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "$CommandName requires a profile reference: <profile> or <set>/<profile>."
    }

    $parts = @($Reference -split '/')

    if ($parts.Count -gt 2) {
        throw "${CommandName}: '$Reference' is not a valid profile reference. Use <profile> or <set>/<profile> (at most one '/')."
    }

    $scoped = ($parts.Count -eq 2)

    if ($scoped) {
        $setReference = [string]$parts[0]
        $profileId    = [string]$parts[1]

        if ([string]::IsNullOrWhiteSpace($setReference) -or [string]::IsNullOrWhiteSpace($profileId)) {
            throw "${CommandName}: '$Reference' is not a valid profile reference. Both sides of '/' must be non-empty."
        }

        $target = Resolve-DevWSSet -Config $Config -Reference $setReference
    }
    else {
        $profileId = [string]$parts[0]

        if ([string]::IsNullOrWhiteSpace($profileId)) {
            throw "${CommandName}: '$Reference' is not a valid profile reference."
        }

        $target = Get-DevWSDefaultSet -Config $Config
    }

    if (-not (Test-DevWSStableIdSyntax -Id $profileId) -or (Test-DevWSLayoutProfileIdReserved -Id $profileId)) {
        throw "${CommandName}: '$profileId' is not a valid profile id. Profile ids use letters, digits, '.', '_' and '-' ('fallback' is reserved for the item.layout scope)."
    }

    return [pscustomobject]@{
        Set       = $target
        SetId     = [string]$target.id
        ProfileId = $profileId
        Scoped    = $scoped
    }
}

# ---------------------------------------------------------------------------
# In-memory profile CRUD (caller owns persistence)
# ---------------------------------------------------------------------------

function New-DevWSLayoutProfile {
    # New empty profile with a canonical (ordinal-sorted) exact matcher.
    param(
        [Parameter(Mandatory)][string]$Id,
        [AllowEmptyCollection()][string[]]$MonitorTokens = @()
    )

    return [pscustomobject][ordered]@{
        id      = $Id
        match   = [pscustomobject][ordered]@{
            mode     = "exact"
            monitors = @(Get-DevWSOrdinalSortedTokens -Tokens $MonitorTokens)
        }
        layouts = [pscustomobject][ordered]@{}
    }
}

function Add-DevWSLayoutProfile {
    param(
        $Set,
        $Profile
    )

    if (Test-DevWSProperty -Object $Set -Name "layoutProfiles") {
        $Set.layoutProfiles = @($Set.layoutProfiles) + $Profile
    }
    else {
        $Set | Add-Member -MemberType NoteProperty -Name "layoutProfiles" -Value @($Profile)
    }
}

function Remove-DevWSLayoutProfile {
    # Removes one profile. When it was the final profile the optional property
    # is removed entirely, returning the set to the simplest legacy shape.
    param(
        $Set,
        [Parameter(Mandatory)][string]$ProfileId
    )

    $remaining = @(@(Get-DevWSLayoutProfiles -Set $Set) | Where-Object { -not (([string]$_.id) -ieq $ProfileId) })

    if ($remaining.Count -eq 0) {
        $Set.PSObject.Properties.Remove("layoutProfiles")
    }
    else {
        $Set.layoutProfiles = @($remaining)
    }
}

function Set-DevWSLayoutProfileMatcher {
    # Re-keys a profile matcher to the supplied canonical tokens (sorted
    # ordinal). The layouts map is never touched.
    param(
        $Profile,
        [AllowEmptyCollection()][string[]]$MonitorTokens = @()
    )

    $Profile.match = [pscustomobject][ordered]@{
        mode     = "exact"
        monitors = @(Get-DevWSOrdinalSortedTokens -Tokens $MonitorTokens)
    }
}

# ---------------------------------------------------------------------------
# Sparse profile layout-map helpers (case-insensitive, order preserving)
# ---------------------------------------------------------------------------

function Get-DevWSLayoutProfileLayoutProperties {
    param($Profile)

    if ($null -eq $Profile) { return @() }

    $layouts = Get-DevWSProperty -Object $Profile -Name "layouts"

    if ($null -eq $layouts -or $layouts -isnot [System.Management.Automation.PSCustomObject]) { return @() }

    return @($layouts.PSObject.Properties)
}

function ConvertTo-DevWSLayoutMapObject {
    # Rebuilds a layouts map as an ordered PSCustomObject. Uses an
    # ordinal-keyed ordered dictionary internally so exact casing and
    # configured order are preserved deterministically; this is the single
    # place that materializes profile maps.
    param([AllowEmptyCollection()][object[]]$Entries = @())

    $ordered = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)

    foreach ($entry in @($Entries)) {
        $ordered[[string]$entry.Key] = $entry.Value
    }

    $map = [pscustomobject]@{}

    foreach ($key in @($ordered.Keys)) {
        $map | Add-Member -MemberType NoteProperty -Name $key -Value $ordered[$key]
    }

    return $map
}

function Get-DevWSLayoutProfileEntry {
    # Case-insensitive sparse entry lookup; $null when the item has no override.
    param(
        $Profile,
        [AllowEmptyString()][string]$ItemId
    )

    if ([string]::IsNullOrWhiteSpace($ItemId)) { return $null }

    foreach ($property in @(Get-DevWSLayoutProfileLayoutProperties -Profile $Profile)) {
        if ($property.Name -ieq $ItemId) {
            return ,$property.Value
        }
    }

    return $null
}

function Set-DevWSLayoutProfileRect {
    # Creates or replaces one sparse entry (canonical item casing), preserving
    # the existing entry order. The stored rectangle is normalized to plain
    # integers exactly like item.layout.
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)]$Rect
    )

    $normalized = [pscustomobject][ordered]@{
        x = [int]$Rect.x
        y = [int]$Rect.y
        w = [int]$Rect.w
        h = [int]$Rect.h
    }

    $entries  = [System.Collections.Generic.List[object]]::new()
    $replaced = $false

    foreach ($property in @(Get-DevWSLayoutProfileLayoutProperties -Profile $Profile)) {
        if ($property.Name -ieq $ItemId) {
            $entries.Add([pscustomobject]@{ Key = $ItemId; Value = $normalized }) | Out-Null
            $replaced = $true
        }
        else {
            $entries.Add([pscustomobject]@{ Key = $property.Name; Value = $property.Value }) | Out-Null
        }
    }

    if (-not $replaced) {
        $entries.Add([pscustomobject]@{ Key = $ItemId; Value = $normalized }) | Out-Null
    }

    $map = ConvertTo-DevWSLayoutMapObject -Entries $entries.ToArray()

    if (Test-DevWSProperty -Object $Profile -Name "layouts") {
        $Profile.layouts = $map
    }
    else {
        $Profile | Add-Member -MemberType NoteProperty -Name "layouts" -Value $map
    }
}

function Remove-DevWSLayoutProfileEntry {
    # Removes one sparse entry (case-insensitive) when present; otherwise a
    # no-op. Other entries and their order are preserved.
    param(
        [Parameter(Mandatory)]$Profile,
        [AllowEmptyString()][string]$ItemId
    )

    if ([string]::IsNullOrWhiteSpace($ItemId)) { return }

    $entries  = [System.Collections.Generic.List[object]]::new()
    $removed  = $false

    foreach ($property in @(Get-DevWSLayoutProfileLayoutProperties -Profile $Profile)) {
        if ($property.Name -ieq $ItemId) {
            $removed = $true
            continue
        }

        $entries.Add([pscustomobject]@{ Key = $property.Name; Value = $property.Value }) | Out-Null
    }

    if ($removed) {
        $Profile.layouts = ConvertTo-DevWSLayoutMapObject -Entries $entries.ToArray()
    }
}

function Rename-DevWSLayoutProfileEntry {
    # Re-keys one sparse entry to the new canonical item id, preserving its
    # position and rectangle. Case-only renames update the stored casing.
    # Duplicate case-variant keys are collapsed deterministically (first wins).
    param(
        [Parameter(Mandatory)]$Profile,
        [AllowEmptyString()][string]$OldId,
        [AllowEmptyString()][string]$NewId
    )

    if ([string]::IsNullOrWhiteSpace($OldId) -or [string]::IsNullOrWhiteSpace($NewId)) { return }

    $entries = [System.Collections.Generic.List[object]]::new()
    $found   = $false

    foreach ($property in @(Get-DevWSLayoutProfileLayoutProperties -Profile $Profile)) {
        if ($property.Name -ieq $OldId) {
            if (-not $found) {
                $entries.Add([pscustomobject]@{ Key = $NewId; Value = $property.Value }) | Out-Null
                $found = $true
            }

            continue
        }

        $entries.Add([pscustomobject]@{ Key = $property.Name; Value = $property.Value }) | Out-Null
    }

    if ($found) {
        $Profile.layouts = ConvertTo-DevWSLayoutMapObject -Entries $entries.ToArray()
    }
}

function Copy-DevWSLayoutProfileMap {
    # Deep copy of one profile's sparse layout map (plain integer rectangles).
    param($Profile)

    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($property in @(Get-DevWSLayoutProfileLayoutProperties -Profile $Profile)) {
        $value = $property.Value

        $entries.Add([pscustomobject]@{
            Key   = $property.Name
            Value = [pscustomobject][ordered]@{
                x = [int]$value.x
                y = [int]$value.y
                w = [int]$value.w
                h = [int]$value.h
            }
        }) | Out-Null
    }

    return ConvertTo-DevWSLayoutMapObject -Entries $entries.ToArray()
}

function Copy-DevWSLayoutProfiles {
    # Deep copy of a profile array (ids, matchers, sparse maps); used by
    # clone-set. Source and clone share no object references.
    param([AllowEmptyCollection()][object[]]$Profiles = @())

    $clones = [System.Collections.Generic.List[object]]::new()

    foreach ($profileObject in @($Profiles)) {
        $clones.Add([pscustomobject][ordered]@{
            id      = [string]$profileObject.id
            match   = [pscustomobject][ordered]@{
                mode     = [string]$profileObject.match.mode
                monitors = @($profileObject.match.monitors)
            }
            layouts = Copy-DevWSLayoutProfileMap -Profile $profileObject
        }) | Out-Null
    }

    return @($clones.ToArray())
}

function Copy-DevWSItemProfileOverrides {
    # Item-clone profile maintenance:
    #   - same set: copy the source item's sparse override in every target
    #     profile that carries one to the new item id;
    #   - cross-set: for every TARGET profile, copy from the exactly one
    #     SOURCE profile with the identical canonical matcher signature when
    #     that profile carries the source override.
    # Never creates profiles, never copies by profile name, never copies from
    # an unrelated topology. Target profiles without a source override stay
    # sparse (the clone then uses its fallback item.layout inside them).
    param(
        $SourceSet,
        $TargetSet,
        [Parameter(Mandatory)][string]$SourceItemId,
        [Parameter(Mandatory)][string]$TargetItemId,
        [switch]$SameSet
    )

    $targetProfiles = @(Get-DevWSLayoutProfiles -Set $TargetSet)

    if ($targetProfiles.Count -eq 0) { return }

    if ($SameSet) {
        foreach ($targetProfile in $targetProfiles) {
            $entry = Get-DevWSLayoutProfileEntry -Profile $targetProfile -ItemId $SourceItemId

            if ($null -ne $entry) {
                Set-DevWSLayoutProfileRect -Profile $targetProfile -ItemId $TargetItemId -Rect $entry
            }
        }

        return
    }

    $sourceProfiles = @(Get-DevWSLayoutProfiles -Set $SourceSet)

    foreach ($targetProfile in $targetProfiles) {
        $targetSignature = Get-DevWSLayoutProfileMatcherSignature -Profile $targetProfile

        if ($null -eq $targetSignature) { continue }

        $equivalentSources = @($sourceProfiles | Where-Object {
            $sourceSignature = Get-DevWSLayoutProfileMatcherSignature -Profile $_
            $null -ne $sourceSignature -and [string]::Equals($sourceSignature, $targetSignature, [System.StringComparison]::Ordinal)
        })

        if ($equivalentSources.Count -ne 1) { continue }

        $sourceEntry = Get-DevWSLayoutProfileEntry -Profile $equivalentSources[0] -ItemId $SourceItemId

        if ($null -ne $sourceEntry) {
            Set-DevWSLayoutProfileRect -Profile $targetProfile -ItemId $TargetItemId -Rect $sourceEntry
        }
    }
}
