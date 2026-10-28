# DevWS display formatting.
#
# Pure functions returning display lines so `ws list` / `ws show-layout`
# output is testable without a live workspace.

function Get-DevWSListLines {
    param(
        [Parameter(Mandatory)]
        $Config,
        $Set
    )

    $lines = @()

    foreach ($item in @(Get-DevWSWindows -Config $Config -Set $Set)) {
        $state = "disabled"

        if ($item.enabled) {
            $state = "enabled"
        }

        if ($item.type -eq "terminal") {
            $summary = Get-DevWSTerminalTabSummary -Terminal $item
            $lines += ("  {0,-14} {1,-9} {2,-9} {3}  tabs: {4} (active {5})" -f $item.id, $item.type, $state, $item.path, $summary, $item.activeTab)
        }
        else {
            $lines += ("  {0,-14} {1,-9} {2,-9} {3}  {4}" -f $item.id, $item.type, $state, (Get-DevWSAppLaunchSummary -App $item), (Get-DevWSAppMatchSummary -App $item))
        }
    }

    return $lines
}

function Get-DevWSLayoutLines {
    param(
        [Parameter(Mandatory)]
        $Config,
        $Set
    )

    $lines = @()

    foreach ($item in @(Get-DevWSWindows -Config $Config -Set $Set)) {
        $layout = $item.layout
        $suffix = ""

        if (-not $item.enabled) {
            $suffix = "  [disabled]"
        }

        $lines += ("  {0,-14} {1,-9} x={2,5} y={3,5} w={4,5} h={5,5}{6}" -f `
            $item.id, $item.type, $layout.x, $layout.y, $layout.w, $layout.h, $suffix)
    }

    return $lines
}

function Get-DevWSBindingsLines {
    param(
        [Parameter(Mandatory)]
        $Config
    )

    $lines = @()

    foreach ($binding in @(Get-DevWSBindings -Config $Config)) {
        if ($null -eq $binding -or $binding -isnot [System.Management.Automation.PSCustomObject]) {
            continue
        }

        $hotkey = [string](Get-DevWSProperty -Object $binding -Name "hotkey")
        $setId  = [string](Get-DevWSProperty -Object $binding -Name "setId")

        $lines += ("{0,-16} -> {1}" -f $hotkey, $setId)
    }

    return $lines
}

function Get-DevWSSetsLines {
    param(
        [Parameter(Mandatory)]
        $Config
    )

    $defaultSet = Get-DevWSDefaultSet -Config $Config
    $lines = @()

    foreach ($set in @(Get-DevWSSets -Config $Config)) {
        if ($null -eq $set) {
            continue
        }

        $marker = " "
        $suffix = ""

        if (([string]$set.id) -ieq ([string]$defaultSet.id)) {
            $marker = "*"
            $suffix = "  (default)"
        }

        $count = @($set.windows).Count
        $noun = "items"

        if ($count -eq 1) {
            $noun = "item"
        }

        $hotkeys = @()

        foreach ($binding in @(Get-DevWSBindings -Config $Config)) {
            if ($null -eq $binding -or $binding -isnot [System.Management.Automation.PSCustomObject]) {
                continue
            }

            if (([string](Get-DevWSProperty -Object $binding -Name "setId")) -ieq ([string]$set.id)) {
                $hotkeys += [string](Get-DevWSProperty -Object $binding -Name "hotkey")
            }
        }

        if ($hotkeys.Count -gt 0) {
            $suffix += "  [" + ($hotkeys -join ", ") + "]"
        }

        $lines += ("  {0} {1,-16} {2,3} {3}{4}" -f $marker, [string]$set.id, $count, $noun, $suffix)
    }

    return $lines
}

function Get-DevWSStatusShortGeneration {
    # Human display shortening only; the model keeps full generation hashes.
    param([string]$Generation)

    if ([string]::IsNullOrWhiteSpace($Generation) -or $Generation.Length -le 8) {
        return [string]$Generation
    }

    return $Generation.Substring(0, 8)
}

function Get-DevWSStatusLines {
    # Read-only hybrid-compact status rendering (Pass 4B). Pure: returns lines
    # and never writes. State words carry the meaning; color is optional.
    #   - present terminals show live cwd (or `cwd unavailable (reason)`)
    #   - missing terminals show the configured path (never stale cwd)
    #   - ambiguous rows carry the refusal diagnostic (never a chosen HWND)
    param([Parameter(Mandatory)]$Model)

    $lines = @()
    $suffix = ""

    if ([bool]$Model.IsDefault) { $suffix = " (default)" }

    $lines += ""
    $lines += "WORKSPACE: $($Model.SetId)$suffix"
    $lines += "────────────────────────────────────────────────────────"

    foreach ($t in @($Model.Terminals)) {
        $detail = ""

        if ($t.State -eq "present") {
            if ([string]$t.CwdStatus -eq "available") {
                $detail = "cwd $($t.Cwd)"
            }
            else {
                $detail = "cwd unavailable ($($t.CwdReason))"
            }
        }
        elseif ($t.State -eq "missing") {
            $detail = "path $($t.ConfiguredPath)"
        }
        elseif ($t.State -eq "ambiguous") {
            $detail = [string]$t.Diagnostic
        }
        elseif ($t.State -eq "disabled") {
            $detail = "path $($t.ConfiguredPath)"
        }

        $lines += ("  {0,-10}{1,-15}{2,-11}{3}" -f "terminal", [string]$t.ItemId, [string]$t.State, $detail)
    }

    foreach ($a in @($Model.Apps)) {
        $detail = ""

        switch ([string]$a.State) {
            "present" {
                $detail = "$($a.InstanceMode) · hwnd $(('0x{0:X}' -f [long]$a.Hwnd))"
            }

            "unowned" {
                $hwnds = @($a.CandidateHwnds | ForEach-Object { '0x{0:X}' -f [long]$_ })
                $detail = "$($a.InstanceMode) · unowned candidate $($hwnds -join ', ')"
            }

            "mismatch" {
                $detail = "$($a.InstanceMode) · owned hwnd $(('0x{0:X}' -f [long]$a.Hwnd)) no longer matches"
            }

            "ambiguous" {
                $hwnds = @($a.CandidateHwnds | ForEach-Object { '0x{0:X}' -f [long]$_ })
                $detail = "$($a.InstanceMode) · $(@($a.CandidateHwnds).Count) candidates ($($hwnds -join ', '))"
            }

            "error" {
                $detail = "$($a.InstanceMode) · $($a.Reason)"
            }

            "disabled" {
                if (-not [string]::IsNullOrWhiteSpace([string]$a.InstanceMode)) { $detail = [string]$a.InstanceMode }
            }
        }

        $lines += ("  {0,-10}{1,-15}{2,-11}{3}" -f "app", [string]$a.ItemId, [string]$a.State, $detail)
    }

    # ---- hosts (compact; stale facts are explicit) ----
    $hostParts = @()

    foreach ($pair in @(
        [pscustomobject]@{ Name = "broker"; Info = $Model.Broker },
        [pscustomobject]@{ Name = "coordinator"; Info = $Model.Coordinator }
    )) {
        $info  = $pair.Info
        $state = [string]$info.State

        if ($state -eq "ready") {
            $hostParts += "$($pair.Name) ready pid $($info.Pid)"
        }
        elseif ($state -eq "stale") {
            $hostParts += "$($pair.Name) stale pid $($info.Pid) gen $(Get-DevWSStatusShortGeneration ([string]$info.Generation)) -> $(Get-DevWSStatusShortGeneration ([string]$info.CurrentGeneration))"
        }
        elseif ($state -eq "unavailable") {
            $hostParts += "$($pair.Name) unavailable"
        }
        else {
            $hostParts += "$($pair.Name) error"
        }
    }

    $readyHosts = @(@($Model.Broker) + @($Model.Coordinator) | Where-Object { [string]$_.State -eq "ready" })

    if ($readyHosts.Count -gt 0) {
        $readyGenerations = @($readyHosts | ForEach-Object { [string]$_.Generation } | Sort-Object -Unique)

        if ($readyGenerations.Count -eq 1) {
            $hostParts += "gen $(Get-DevWSStatusShortGeneration $readyGenerations[0]) current"
        }
    }

    $lines += ("  {0,-10}{1}" -f "hosts", ($hostParts -join " · "))

    $summary = $Model.Summary
    $lines += ("  {0} present · {1} missing · {2} ambiguous · {3} mismatch · {4} unowned · {5} disabled · {6} error" -f `
        $summary.Present, $summary.Missing, $summary.Ambiguous, $summary.Mismatch, $summary.Unowned, $summary.Disabled, $summary.Error)
    $lines += ""

    return $lines
}

function Get-DevWSMonitorDisplayLabel {
    # Human label fallback order: non-empty friendly name, meaningful EDID
    # monitor-name descriptor, "Internal display" for internal panels, the GDI
    # device name, then a generic label. The identity token is never used as
    # the primary human label when a friendlier fallback exists.
    param([Parameter(Mandatory)]$Monitor)

    if (-not [string]::IsNullOrWhiteSpace([string]$Monitor.FriendlyName)) {
        return [string]$Monitor.FriendlyName
    }

    if ($null -ne $Monitor.Edid -and -not [string]::IsNullOrWhiteSpace([string]$Monitor.Edid.MonitorName)) {
        return [string]$Monitor.Edid.MonitorName
    }

    if ([bool]$Monitor.IsInternal) {
        return "Internal display"
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Monitor.GdiDeviceName)) {
        return [string]$Monitor.GdiDeviceName
    }

    return "Display"
}

function Get-DevWSMonitorLines {
    # Read-only monitor diagnostics rendering (Pass 5B). Pure: returns lines
    # and never writes. The full identity token is always rendered (only the
    # fingerprint is shortened for humans); negative coordinates render as-is;
    # no color is required to understand the output.
    param([Parameter(Mandatory)]$Topology)

    $lines = @()
    $lines += ""
    $lines += "MONITORS"
    $lines += "────────────────────────────────────────────────────────"

    if (-not [bool]$Topology.Available) {
        $lines += ("  unavailable: " + [string]$Topology.Error)
        $lines += ""
        return $lines
    }

    $index = 0

    foreach ($monitor in @($Topology.Monitors)) {
        $index++

        if ($index -gt 1) {
            $lines += ""
        }

        $marker = "  "

        if ([bool]$monitor.Primary) {
            $marker = "* "
        }

        $lines += ($marker + (Get-DevWSMonitorDisplayLabel -Monitor $monitor))

        $token = [string]$monitor.IdentityToken

        if ([string]::IsNullOrWhiteSpace($token)) {
            $token = "(identity unavailable)"
        }

        $lines += ("  id      " + $token)
        $lines += ("  rect    x={0} y={1} w={2} h={3}" -f $monitor.MonitorRect.x, $monitor.MonitorRect.y, $monitor.MonitorRect.w, $monitor.MonitorRect.h)
        $lines += ("  work    x={0} y={1} w={2} h={3}" -f $monitor.WorkRect.x, $monitor.WorkRect.y, $monitor.WorkRect.w, $monitor.WorkRect.h)

        if ($null -ne $monitor.ScalePercent) {
            $lines += ("  scale   {0}% ({1} dpi)" -f $monitor.ScalePercent, $monitor.DpiEffective)
        }
        else {
            $lines += "  scale   unavailable"
        }

        $lines += ("  output  " + [string]$monitor.OutputTechnology)
    }

    $lines += ""
    $lines += "TOPOLOGY"

    $fingerprint = [string]$Topology.Fingerprint

    if (-not [string]::IsNullOrWhiteSpace($fingerprint)) {
        $lines += ("  fingerprint  " + $fingerprint.Substring(0, [Math]::Min(12, $fingerprint.Length)))
    }
    elseif (-not [bool]$Topology.IdentityComplete) {
        $lines += "  fingerprint  unavailable (identity incomplete)"
    }
    elseif (-not [bool]$Topology.CorrelationComplete) {
        $lines += "  fingerprint  unavailable (correlation incomplete)"
    }
    else {
        $lines += "  fingerprint  unavailable"
    }

    $identityText = "incomplete"

    if ([bool]$Topology.IdentityComplete) {
        $identityText = "complete"
    }

    $lines += ("  identity     " + $identityText)
    $lines += ("  monitors     " + @($Topology.Monitors).Count)

    if ([bool]$Topology.IdentityAmbiguous) {
        $lines += "  warning      duplicate identity at identical monitor rectangles"
    }

    if (-not [bool]$Topology.CorrelationComplete -and [bool]$Topology.IdentityComplete) {
        $lines += ("  warning      " + [int]$Topology.UncorrelatedPathCount + " active path(s) without monitor geometry")
    }

    $lines += ""
    return $lines
}

function Format-DevWSRelativeDisplayNumber {
    param([double]$Value)
    return $Value.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-DevWSRelativeDisplayRect {
    param($Rect)

    if ($null -eq $Rect -or $Rect -isnot [System.Management.Automation.PSCustomObject]) {
        return "unavailable"
    }

    return ("x={0} y={1} w={2} h={3}" -f `
        (Format-DevWSRelativeDisplayNumber -Value ([double]$Rect.x)), `
        (Format-DevWSRelativeDisplayNumber -Value ([double]$Rect.y)), `
        (Format-DevWSRelativeDisplayNumber -Value ([double]$Rect.w)), `
        (Format-DevWSRelativeDisplayNumber -Value ([double]$Rect.h)))
}

function Get-DevWSRelativeDisplayStatusText {
    param([string]$Status, [string]$Reason)

    switch ($Status) {
        "resolved"              { return "resolved" }
        "relative-unreachable"  {
            if ($Reason -eq "relative-target-and-fallback-unreachable") {
                return "relative target and fallback unreachable"
            }
            return "relative target unreachable"
        }
        "anchor-missing"        { return "anchor missing ($Reason)" }
        "anchor-ambiguous"      { return "anchor ambiguous ($Reason)" }
        "topology-unavailable"  { return "topology unavailable" }
        "basis-unavailable"     { return "basis unavailable ($Reason)" }
        "relative-invalid"      { return "relative layout invalid ($Reason)" }
        "rect-invalid"          { return "relative rectangle invalid ($Reason)" }
        "overflow"              { return "relative rectangle overflow ($Reason)" }
        "not-applicable"        { return "not applicable" }
        default                 { return "$Status ($Reason)" }
    }
}

function Get-DevWSRelativeDisplayPreviewText {
    param($Item, [string]$ProfileLifecycleRefusal)

    if (-not [string]::IsNullOrWhiteSpace($ProfileLifecycleRefusal)) {
        return "profile-aware lifecycle refuses this topology; relative preview is not applied"
    }

    switch ([string]$Item.Source) {
        "profile" {
            if ($null -ne $Item.Reachable -and -not [bool]$Item.Reachable) {
                return "profile '$($Item.ProfileId)' overrides relative intent; profile entry is unreachable (lifecycle would refuse)"
            }

            return "profile '$($Item.ProfileId)' is current lifecycle placement; relative preview is not used"
        }
        "relative" {
            return "relative preview only; current ws launch/reset use the absolute fallback until Phase 3"
        }
        "relative-fallback" {
            $reason = Get-DevWSRelativeDisplayStatusText -Status ([string]$Item.RelativeStatus) -Reason ([string]$Item.RelativeReason)
            return "absolute fallback preview ($reason); current ws launch/reset use the absolute fallback until Phase 3"
        }
        "relative-unavailable" {
            if ([string]$Item.RelativeStatus -eq "topology-unavailable") {
                return "no verified geometry (topology unavailable); current ws launch/reset still use the absolute fallback until Phase 3"
            }

            if ($null -ne $Item.FallbackReachable -and -not [bool]$Item.FallbackReachable) {
                return "no verified geometry (absolute fallback is not reachable); current ws launch/reset still use the absolute fallback until Phase 3"
            }

            return "no verified geometry; current ws launch/reset still use the absolute fallback until Phase 3"
        }
        default {
            return "relative preview only; lifecycle integration is Phase 3"
        }
    }
}

function Get-DevWSEffectiveLayoutLines {
    # Read-only effective-layout rendering for `ws show-layout`.
    #
    # Absolute and matched-profile items preserve the established one-line
    # rendering. Relative items add explicit preview detail lines and never
    # claim that relative placement is applied by lifecycle commands yet.
    param([Parameter(Mandatory)]$Model)

    $lines = @()

    $topologyText = "unavailable"

    if ([bool]$Model.TopologyAvailable) {
        $fingerprint = [string]$Model.TopologyFingerprint

        if (-not [string]::IsNullOrWhiteSpace($fingerprint)) {
            $topologyText = "fingerprint " + $fingerprint.Substring(0, [Math]::Min(12, $fingerprint.Length))
        }
        else {
            $topologyText = "identity incomplete"
        }
    }

    $sourceText = "fallback"

    if ([string]$Model.Status -eq "matched") {
        $sourceText = "profile '$($Model.ProfileId)'"
    }
    elseif ([string]$Model.Status -eq "ambiguous") {
        $sourceText = "ambiguous (config error)"
    }

    $reasonText = switch ([string]$Model.Reason) {
        "no-profiles"          { "no profiles configured" }
        "matched"              { "exact topology match" }
        "no-match"             { "no profile matches the current topology" }
        "topology-unavailable" { "topology unavailable" }
        "topology-incomplete"  { "topology not fully identified" }
        "topology-ambiguous"   { "ambiguous monitor identities" }
        "ambiguous-matchers"   { "duplicate profile matchers" }
        default                { [string]$Model.Reason }
    }

    $lines += "  topology    $topologyText"
    $lines += "  layout      $sourceText  ($reasonText)"

    if ([bool]$Model.ProfileAware -and -not [string]::IsNullOrWhiteSpace([string]$Model.ProfileLifecycleRefusal)) {
        $lifecycleReason = switch ([string]$Model.ProfileLifecycleRefusal) {
            "topology-unavailable"    { "topology unavailable" }
            "topology-incomplete"     { "topology not fully identified" }
            "topology-ambiguous"      { "ambiguous monitor identities" }
            "ambiguous-matchers"      { "duplicate profile matchers" }
            "unreachable-profile-entry" { "matched profile entry is unreachable" }
            default                   { [string]$Model.ProfileLifecycleRefusal }
        }

        $lines += "  lifecycle   profile-aware launch/reset would refuse ($lifecycleReason)"
    }

    if (@($Model.Profiles).Count -gt 0) {
        $lines += "  profiles    " + (@($Model.Profiles) -join ", ")
    }

    $lines += ""

    foreach ($item in @($Model.Items)) {
        $suffix = ""

        if (-not [bool]$item.Enabled) {
            $suffix += "  [disabled]"
        }

        if ([string]$item.Source -eq "fallback" -and [string]$Model.Status -eq "matched") {
            $suffix += "  [fallback]"
        }

        if ([string]$item.LayoutMode -eq "relative") {
            if ([bool]$item.ProfileOverridesRelative) {
                $suffix += "  [profile overrides relative]"
            }
            elseif ([bool]$item.ProfileMatched) {
                $suffix += "  [profile omits item]"
            }

            switch ([string]$item.Source) {
                "relative"             { $suffix += "  [relative preview]" }
                "relative-fallback"    { $suffix += "  [relative fallback preview]" }
                "relative-unavailable" { $suffix += "  [relative unavailable]" }
            }
        }

        if ($null -ne $item.Reachable -and -not [bool]$item.Reachable) {
            $suffix += "  [unreachable]"
        }

        $rect = $item.Rect

        if ($null -eq $rect -or $rect -isnot [System.Management.Automation.PSCustomObject]) {
            $lines += ("  {0,-14} {1,-9} no verified geometry{2}" -f `
                $item.ItemId, $item.Type, $suffix)
        }
        else {
            $lines += ("  {0,-14} {1,-9} x={2,5} y={3,5} w={4,5} h={5,5}{6}" -f `
                $item.ItemId, $item.Type, $rect.x, $rect.y, $rect.w, $rect.h, $suffix)
        }

        if ([string]$item.LayoutMode -eq "relative") {
            $relative = $item.RelativeLayout
            $monitorSpec = Get-DevWSProperty -Object $relative -Name "monitor"
            $identity = [string](Get-DevWSProperty -Object $monitorSpec -Name "identity")
            $instance = [string](Get-DevWSProperty -Object $monitorSpec -Name "instance")
            $basis = [string](Get-DevWSProperty -Object $relative -Name "basis")
            $normalizedRect = Get-DevWSProperty -Object $relative -Name "rect"

            if ([string]::IsNullOrWhiteSpace($identity)) {
                $identity = "(not configured)"
            }

            $anchorText = $identity

            if (-not [string]::IsNullOrWhiteSpace($instance)) {
                $anchorText += "  instance $instance"
            }

            if ([string]::IsNullOrWhiteSpace($basis)) {
                $basis = "(not configured)"
            }

            $previewText = Get-DevWSRelativeDisplayPreviewText -Item $item -ProfileLifecycleRefusal ([string]$Model.ProfileLifecycleRefusal)
            $statusText = Get-DevWSRelativeDisplayStatusText -Status ([string]$item.RelativeStatus) -Reason ([string]$item.RelativeReason)

            $lines += "      mode        relative"
            $lines += "      anchor      $anchorText"
            $lines += "      basis       $basis"
            $lines += "      normalized  $(Format-DevWSRelativeDisplayRect -Rect $normalizedRect)"
            $lines += "      resolved    $(Format-DevWSRelativeDisplayRect -Rect $item.RelativeRect)"
            $lines += "      preview     $previewText"
            $lines += "      status      $statusText"
        }
    }

    $lines += ""

    if (-not [string]::IsNullOrWhiteSpace([string]$Model.ProfileLifecycleRefusal)) {
        if ([bool]$Model.HasRelativeItems) {
            $lines += "  note        Relative previews are read-only. Profile-aware launch/reset would refuse this topology; relative placement becomes operational in Phase 3."
        }
        else {
            $lines += "  note        Profile-aware launch/reset would refuse this topology; no effective layout is applied by lifecycle commands."
        }
    }
    elseif ([bool]$Model.HasRelativeItems) {
        $lines += "  note        Relative previews are read-only. Current launch/reset use absolute/profile geometry; relative placement becomes operational in Phase 3."
    }
    else {
        $lines += "  note        'ws launch' and terminal resets apply exactly this effective layout."
    }

    $lines += ""

    return $lines
}

function Get-DevWSLayoutProfileLines {
    # Read-only rendering for `ws layout-profile list` (Pass 5C).
    param([Parameter(Mandatory)]$Model)

    $lines = @()

    if (@($Model.Profiles).Count -eq 0) {
        $lines += "  No topology layout profiles configured for set '$($Model.SetId)'."
        $lines += "  Layout writes use the fallback item.layout for this set; create a profile with 'ws save-layout --profile <id>'."
    }
    else {
        foreach ($row in @($Model.Profiles)) {
            $marker = " "
            if ([bool]$row.MatchesCurrent) { $marker = "*" }

            $monitorNoun = "monitors"
            if ([int]$row.MonitorCount -eq 1) { $monitorNoun = "monitor" }

            $lines += ("  {0} {1,-16} {2,3} {3} · {4} layout override(s)" -f `
                $marker, $row.Id, $row.MonitorCount, $monitorNoun, $row.OverrideCount)
        }

        $lines += "  (* matches the current topology)"
    }

    $lines += ""

    $matchingText = switch ([string]$Model.TopologyStatus) {
        "matchable"            { "current topology is matchable" }
        "topology-unavailable" { "current topology is unavailable; matching is not possible" }
        "topology-incomplete"  { "current topology is not fully identified; matching is not possible" }
        "topology-ambiguous"   { "current topology has ambiguous monitor identities; matching is not possible" }
        default                { [string]$Model.TopologyStatus }
    }

    $lines += "  topology  $matchingText"

    if ([string]$Model.TopologyStatus -eq "matchable") {
        $fingerprint = [string]$Model.TopologyFingerprint

        if (-not [string]::IsNullOrWhiteSpace($fingerprint)) {
            $lines += "  fingerprint  " + $fingerprint.Substring(0, [Math]::Min(12, $fingerprint.Length))
        }

        if ($null -ne $Model.MatchedProfileId) {
            $lines += "  routing   profile '$($Model.MatchedProfileId)' matches the current topology"
        }
        else {
            $lines += "  routing   no profile matches; writes route to the fallback item.layout"
        }
    }
    else {
        $lines += "  routing   implicit layout writes that would need a profile are refused until the topology is safely matchable"
    }

    $lines += ""
    $lines += "  note      the matching profile is applied automatically by 'ws launch' and terminal resets."
    $lines += ""

    return $lines
}
