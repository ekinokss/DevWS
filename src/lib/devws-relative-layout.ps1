# DevWS relative-layout pure model (v0.3 Phase 1).
#
# Scope:
#   - monitor anchor parsing and durable identity matching;
#   - optional device-path instance disambiguation;
#   - work-area / full-monitor basis selection;
#   - normalized rectangle capture and relative-to-absolute conversion;
#   - deterministic edge rounding and Int32 overflow detection;
#   - anchor selection from greatest visible area, including tie / no-visible
#     handling;
#   - deep copying of relative-layout data;
#   - structured status/failure objects.
#
# This library is deliberately observational and pure: it never samples a
# monitor, never writes configuration, never moves a window, never starts a
# host and never calls the broker. Callers own topology acquisition and every
# side effect. It reuses the topology model produced by devws-monitor.ps1.
#
# Loading contract: devws-config.ps1 is loaded first because the small
# Get-DevWSProperty / Test-DevWSFiniteNumber helpers are shared with schema
# validation. The library itself adds no native API and no monitor watcher.

function Get-DevWSRelativeLayoutBasisRect {
    # Select the explicit basis rectangle of one topology monitor. The work
    # area is used for ordinary window placement; the full monitor rectangle
    # is available for edge-to-edge or deliberately overlapping layouts.
    param(
        $Monitor,
        [string]$Basis
    )

    if ($null -eq $Monitor -or $Monitor -isnot [System.Management.Automation.PSCustomObject]) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "basis-unavailable"
            Reason  = "monitor-invalid"
            Message = "No monitor was supplied for the relative-layout basis."
            Rect    = $null
        }
    }

    if ($Basis -cne "workArea" -and $Basis -cne "monitor") {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "relative-invalid"
            Reason  = "basis-invalid"
            Message = "The relative-layout basis must be 'workArea' or 'monitor' (got '$Basis')."
            Rect    = $null
        }
    }

    $propertyName = if ($Basis -ceq "workArea") { "WorkRect" } else { "MonitorRect" }
    $rect = Get-DevWSProperty -Object $Monitor -Name $propertyName

    if ($null -eq $rect -or $rect -isnot [System.Management.Automation.PSCustomObject] -or
        -not (Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $rect -Name "x")) -or
        -not (Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $rect -Name "y")) -or
        -not (Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $rect -Name "w")) -or
        -not (Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $rect -Name "h")) -or
        [double](Get-DevWSProperty -Object $rect -Name "w") -le 0 -or
        [double](Get-DevWSProperty -Object $rect -Name "h") -le 0) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "basis-unavailable"
            Reason  = if ($Basis -ceq "workArea") { "work-area-unavailable" } else { "monitor-rect-unavailable" }
            Message = "The selected monitor's $Basis rectangle is unavailable or has non-positive width/height."
            Rect    = $null
        }
    }

    return [pscustomobject][ordered]@{
        Ok      = $true
        Status  = "ok"
        Reason  = "basis"
        Message = $null
        Rect    = $rect
    }
}

function Resolve-DevWSRelativeLayoutAnchor {
    # Pure anchor resolution: exact durable identity first, optional
    # DevicePathInstance as a tie-breaker. A unique identity still resolves
    # when a supplied instance changed (for example the monitor moved ports);
    # duplicate identities without a matching instance are ambiguous and are
    # never guessed.
    param(
        $RelativeLayout,
        $Topology
    )

    if ($null -eq $Topology -or -not [bool](Get-DevWSProperty -Object $Topology -Name "Available")) {
        return [pscustomobject][ordered]@{
            Ok         = $false
            Status     = "topology-unavailable"
            Reason     = "topology-unavailable"
            Message    = "The current monitor topology is unavailable; no monitor rectangles are available."
            Monitor    = $null
            Identity   = $null
            Instance   = $null
            Basis      = $null
            BasisRect  = $null
        }
    }

    $monitorsValue = Get-DevWSProperty -Object $Topology -Name "Monitors"
    $monitors = @()

    if ($null -ne $monitorsValue -and $monitorsValue -is [array]) {
        $monitors = @($monitorsValue)
    }

    if ($monitors.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Ok         = $false
            Status     = "topology-unavailable"
            Reason     = "no-monitors"
            Message    = "The current monitor topology contains no monitor rectangles."
            Monitor    = $null
            Identity   = $null
            Instance   = $null
            Basis      = $null
            BasisRect  = $null
        }
    }

    if ($null -eq $RelativeLayout -or $RelativeLayout -isnot [System.Management.Automation.PSCustomObject]) {
        return [pscustomobject][ordered]@{
            Ok         = $false
            Status     = "relative-invalid"
            Reason     = "relative-layout-invalid"
            Message    = "The relative-layout object is missing or invalid."
            Monitor    = $null
            Identity   = $null
            Instance   = $null
            Basis      = $null
            BasisRect  = $null
        }
    }

    $monitorSpec = Get-DevWSProperty -Object $RelativeLayout -Name "monitor"
    $identity    = Get-DevWSProperty -Object $monitorSpec -Name "identity"
    $instance    = Get-DevWSProperty -Object $monitorSpec -Name "instance"
    $basis       = Get-DevWSProperty -Object $RelativeLayout -Name "basis"

    if ($null -eq $monitorSpec -or $monitorSpec -isnot [System.Management.Automation.PSCustomObject] -or
        $identity -isnot [string] -or [string]::IsNullOrWhiteSpace($identity) -or
        -not (Test-DevWSRelativeMonitorIdentitySyntax -Identity ([string]$identity))) {
        return [pscustomobject][ordered]@{
            Ok         = $false
            Status     = "relative-invalid"
            Reason     = "monitor-identity-invalid"
            Message    = "The relative-layout monitor identity is missing or invalid."
            Monitor    = $null
            Identity   = $identity
            Instance   = $instance
            Basis      = $basis
            BasisRect  = $null
        }
    }

    if ($null -ne $instance -and ($instance -isnot [string] -or [string]::IsNullOrWhiteSpace($instance) -or
        -not (Test-DevWSRelativeMonitorInstanceSyntax -Instance ([string]$instance)))) {
        return [pscustomobject][ordered]@{
            Ok         = $false
            Status     = "relative-invalid"
            Reason     = "monitor-instance-invalid"
            Message    = "The relative-layout device-path instance is invalid."
            Monitor    = $null
            Identity   = $identity
            Instance   = $instance
            Basis      = $basis
            BasisRect  = $null
        }
    }

    if ($identity.StartsWith("path:", [System.StringComparison]::Ordinal) -and $null -ne $instance) {
        return [pscustomobject][ordered]@{
            Ok         = $false
            Status     = "relative-invalid"
            Reason     = "path-identity-with-instance"
            Message    = "A path: identity already contains the device-path instance; monitor.instance must be omitted."
            Monitor    = $null
            Identity   = $identity
            Instance   = $instance
            Basis      = $basis
            BasisRect  = $null
        }
    }

    $candidates = [System.Collections.Generic.List[object]]::new()

    foreach ($candidate in $monitors) {
        if ($null -eq $candidate -or $candidate -isnot [System.Management.Automation.PSCustomObject]) {
            continue
        }

        $candidateIdentity = [string](Get-DevWSProperty -Object $candidate -Name "IdentityToken")

        if ($candidateIdentity -ceq $identity) {
            $candidates.Add($candidate) | Out-Null
        }
    }

    if ($candidates.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Ok         = $false
            Status     = "anchor-missing"
            Reason     = "identity-not-found"
            Message    = "The relative monitor identity '$identity' is not present in the current topology."
            Monitor    = $null
            Identity   = $identity
            Instance   = $instance
            Basis      = $basis
            BasisRect  = $null
        }
    }

    $selected = $null
    $matchReason = $null

    if ($null -ne $instance) {
        $instanceMatches = [System.Collections.Generic.List[object]]::new()

        foreach ($candidate in $candidates) {
            $candidateInstance = [string](Get-DevWSProperty -Object $candidate -Name "DevicePathInstance")

            if ($candidateInstance -ieq ([string]$instance)) {
                $instanceMatches.Add($candidate) | Out-Null
            }
        }

        if ($instanceMatches.Count -eq 1) {
            $selected = $instanceMatches[0]
            $matchReason = "identity-instance"
        }
        elseif ($instanceMatches.Count -gt 1) {
            return [pscustomobject][ordered]@{
                Ok         = $false
                Status     = "anchor-ambiguous"
                Reason     = "duplicate-identity-instance"
                Message    = "The relative monitor identity and device-path instance match multiple monitors."
                Monitor    = $null
                Identity   = $identity
                Instance   = $instance
                Basis      = $basis
                BasisRect  = $null
            }
        }
        elseif ($candidates.Count -eq 1) {
            $selected = $candidates[0]
            $matchReason = "identity-port-changed"
        }
        else {
            return [pscustomobject][ordered]@{
                Ok         = $false
                Status     = "anchor-ambiguous"
                Reason     = "duplicate-identity"
                Message    = "Multiple monitors share the relative identity '$identity'; the supplied device-path instance did not disambiguate them."
                Monitor    = $null
                Identity   = $identity
                Instance   = $instance
                Basis      = $basis
                BasisRect  = $null
            }
        }
    }
    else {
        if ($candidates.Count -eq 1) {
            $selected = $candidates[0]
            $matchReason = "identity"
        }
        else {
            return [pscustomobject][ordered]@{
                Ok         = $false
                Status     = "anchor-ambiguous"
                Reason     = "duplicate-identity"
                Message    = "Multiple monitors share the relative identity '$identity'; add a device-path instance to disambiguate."
                Monitor    = $null
                Identity   = $identity
                Instance   = $instance
                Basis      = $basis
                BasisRect  = $null
            }
        }
    }

    $basisResult = Get-DevWSRelativeLayoutBasisRect -Monitor $selected -Basis $basis

    if (-not [bool]$basisResult.Ok) {
        return [pscustomobject][ordered]@{
            Ok         = $false
            Status     = "basis-unavailable"
            Reason     = $basisResult.Reason
            Message    = $basisResult.Message
            Monitor    = $selected
            Identity   = $identity
            Instance   = $instance
            Basis      = $basis
            BasisRect  = $null
        }
    }

    return [pscustomobject][ordered]@{
        Ok         = $true
        Status     = "resolved"
        Reason     = $matchReason
        Message    = $null
        Monitor    = $selected
        Identity   = $identity
        Instance   = $instance
        Basis      = $basis
        BasisRect  = $basisResult.Rect
    }
}

function ConvertTo-DevWSRelativeAbsoluteRect {
    # Convert normalized fractions to an absolute rectangle using edge-based
    # rounding. The left/top/right/bottom edges are rounded first; width and
    # height are derived afterwards. A valid target is at least 1x1.
    param(
        $RelativeRect,
        $BasisRect
    )

    if ($null -eq $RelativeRect -or $RelativeRect -isnot [System.Management.Automation.PSCustomObject]) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "rect-invalid"
            Reason  = "relative-rect-invalid"
            Message = "The normalized relative rectangle is missing or invalid."
            Rect    = $null
        }
    }

    foreach ($field in @("x", "y", "w", "h")) {
        if (-not (Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $RelativeRect -Name $field))) {
            return [pscustomobject][ordered]@{
                Ok      = $false
                Status  = "rect-invalid"
                Reason  = "relative-$field-invalid"
                Message = "The normalized relative rectangle field '$field' must be a finite number."
                Rect    = $null
            }
        }
    }

    if ([double]$RelativeRect.w -le 0 -or [double]$RelativeRect.h -le 0) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "rect-invalid"
            Reason  = "relative-size-not-positive"
            Message = "The normalized relative rectangle width and height must be greater than 0."
            Rect    = $null
        }
    }

    if ($null -eq $BasisRect -or $BasisRect -isnot [System.Management.Automation.PSCustomObject]) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "basis-unavailable"
            Reason  = "basis-invalid"
            Message = "The relative-layout basis rectangle is missing or invalid."
            Rect    = $null
        }
    }

    foreach ($field in @("x", "y", "w", "h")) {
        if (-not (Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $BasisRect -Name $field))) {
            return [pscustomobject][ordered]@{
                Ok      = $false
                Status  = "basis-unavailable"
                Reason  = "basis-$field-invalid"
                Message = "The relative-layout basis field '$field' must be a finite number."
                Rect    = $null
            }
        }
    }

    if ([double]$BasisRect.w -le 0 -or [double]$BasisRect.h -le 0) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "basis-unavailable"
            Reason  = "basis-size-not-positive"
            Message = "The relative-layout basis width and height must be greater than 0."
            Rect    = $null
        }
    }

    $relativeX = [double]$RelativeRect.x
    $relativeY = [double]$RelativeRect.y
    $relativeW = [double]$RelativeRect.w
    $relativeH = [double]$RelativeRect.h
    $basisX    = [double]$BasisRect.x
    $basisY    = [double]$BasisRect.y
    $basisW    = [double]$BasisRect.w
    $basisH    = [double]$BasisRect.h

    $leftRaw   = $basisX + ($relativeX * $basisW)
    $rightRaw  = $basisX + (($relativeX + $relativeW) * $basisW)
    $topRaw    = $basisY + ($relativeY * $basisH)
    $bottomRaw = $basisY + (($relativeY + $relativeH) * $basisH)

    if (-not [double]::IsFinite($leftRaw) -or -not [double]::IsFinite($rightRaw) -or
        -not [double]::IsFinite($topRaw) -or -not [double]::IsFinite($bottomRaw)) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "overflow"
            Reason  = "non-finite-resolved-coordinate"
            Message = "The relative rectangle resolves to a non-finite coordinate."
            Rect    = $null
        }
    }

    $left   = [Math]::Round($leftRaw, [System.MidpointRounding]::AwayFromZero)
    $right  = [Math]::Round($rightRaw, [System.MidpointRounding]::AwayFromZero)
    $top    = [Math]::Round($topRaw, [System.MidpointRounding]::AwayFromZero)
    $bottom = [Math]::Round($bottomRaw, [System.MidpointRounding]::AwayFromZero)

    $minimum = [double][int]::MinValue
    $maximum = [double][int]::MaxValue

    if ($left -lt $minimum -or $left -gt $maximum -or
        $right -lt $minimum -or $right -gt $maximum -or
        $top -lt $minimum -or $top -gt $maximum -or
        $bottom -lt $minimum -or $bottom -gt $maximum) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "overflow"
            Reason  = "int32-coordinate-overflow"
            Message = "The relative rectangle does not fit the Windows 32-bit coordinate range."
            Rect    = $null
        }
    }

    $widthRaw  = $right - $left
    $heightRaw = $bottom - $top

    if (-not [double]::IsFinite($widthRaw) -or -not [double]::IsFinite($heightRaw) -or
        $widthRaw -gt $maximum -or $heightRaw -gt $maximum) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "overflow"
            Reason  = "int32-size-overflow"
            Message = "The relative rectangle's resolved width or height does not fit a 32-bit size."
            Rect    = $null
        }
    }

    $width  = [int][Math]::Max(1.0, $widthRaw)
    $height = [int][Math]::Max(1.0, $heightRaw)
    $leftInt = [int]$left
    $topInt  = [int]$top

    # The edge checks above happen before the 1-pixel minimum is applied. A
    # zero-width target at the positive Int32 boundary would otherwise become
    # x=Int32.MaxValue, w=1, whose right edge is not representable. Use Int64
    # intermediates so the final edge checks cannot wrap.
    $finalRight  = [long]$leftInt + [long]$width
    $finalBottom = [long]$topInt + [long]$height

    if ($finalRight -lt [long][int]::MinValue -or $finalRight -gt [long][int]::MaxValue -or
        $finalBottom -lt [long][int]::MinValue -or $finalBottom -gt [long][int]::MaxValue) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "overflow"
            Reason  = "int32-output-edge-overflow"
            Message = "The final relative rectangle's right or bottom edge does not fit the Windows 32-bit coordinate range."
            Rect    = $null
        }
    }

    return [pscustomobject][ordered]@{
        Ok      = $true
        Status  = "ok"
        Reason  = "edge-rounded"
        Message = $null
        Rect    = [pscustomobject][ordered]@{
            x = $leftInt
            y = $topInt
            w = $width
            h = $height
        }
    }
}

function ConvertFrom-DevWSAbsoluteRectToRelative {
    # Capture an absolute rectangle as normalized fractions of the selected
    # basis. Fractions are rounded to six decimal places; the width/height are
    # derived from the rounded edges and remain strictly positive.
    param(
        $Rect,
        $BasisRect
    )

    if ($null -eq $Rect -or $Rect -isnot [System.Management.Automation.PSCustomObject]) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "rect-invalid"
            Reason  = "absolute-rect-invalid"
            Message = "The absolute rectangle is missing or invalid."
            Rect    = $null
        }
    }

    foreach ($field in @("x", "y", "w", "h")) {
        if (-not (Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $Rect -Name $field))) {
            return [pscustomobject][ordered]@{
                Ok      = $false
                Status  = "rect-invalid"
                Reason  = "absolute-$field-invalid"
                Message = "The absolute rectangle field '$field' must be a finite number."
                Rect    = $null
            }
        }
    }

    if ([double]$Rect.w -le 0 -or [double]$Rect.h -le 0) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "rect-invalid"
            Reason  = "absolute-size-not-positive"
            Message = "The absolute rectangle width and height must be greater than 0."
            Rect    = $null
        }
    }

    if ($null -eq $BasisRect -or $BasisRect -isnot [System.Management.Automation.PSCustomObject]) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "basis-unavailable"
            Reason  = "basis-invalid"
            Message = "The relative-layout basis rectangle is missing or invalid."
            Rect    = $null
        }
    }

    foreach ($field in @("x", "y", "w", "h")) {
        if (-not (Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $BasisRect -Name $field))) {
            return [pscustomobject][ordered]@{
                Ok      = $false
                Status  = "basis-unavailable"
                Reason  = "basis-$field-invalid"
                Message = "The relative-layout basis field '$field' must be a finite number."
                Rect    = $null
            }
        }
    }

    if ([double]$BasisRect.w -le 0 -or [double]$BasisRect.h -le 0) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "basis-unavailable"
            Reason  = "basis-size-not-positive"
            Message = "The relative-layout basis width and height must be greater than 0."
            Rect    = $null
        }
    }

    $rectX  = [double]$Rect.x
    $rectY  = [double]$Rect.y
    $rectW  = [double]$Rect.w
    $rectH  = [double]$Rect.h
    $basisX = [double]$BasisRect.x
    $basisY = [double]$BasisRect.y
    $basisW = [double]$BasisRect.w
    $basisH = [double]$BasisRect.h

    $leftRaw   = ($rectX - $basisX) / $basisW
    $rightRaw  = (($rectX + $rectW) - $basisX) / $basisW
    $topRaw    = ($rectY - $basisY) / $basisH
    $bottomRaw = (($rectY + $rectH) - $basisY) / $basisH

    if (-not [double]::IsFinite($leftRaw) -or -not [double]::IsFinite($rightRaw) -or
        -not [double]::IsFinite($topRaw) -or -not [double]::IsFinite($bottomRaw)) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Status  = "overflow"
            Reason  = "non-finite-relative-coordinate"
            Message = "The captured rectangle does not produce finite normalized fractions."
            Rect    = $null
        }
    }

    $left   = [Math]::Round($leftRaw, 6, [System.MidpointRounding]::AwayFromZero)
    $right  = [Math]::Round($rightRaw, 6, [System.MidpointRounding]::AwayFromZero)
    $top    = [Math]::Round($topRaw, 6, [System.MidpointRounding]::AwayFromZero)
    $bottom = [Math]::Round($bottomRaw, 6, [System.MidpointRounding]::AwayFromZero)
    $width  = [Math]::Round($right - $left, 6, [System.MidpointRounding]::AwayFromZero)
    $height = [Math]::Round($bottom - $top, 6, [System.MidpointRounding]::AwayFromZero)

    if ($width -le 0) {
        $width = 0.000001
    }

    if ($height -le 0) {
        $height = 0.000001
    }

    return [pscustomobject][ordered]@{
        Ok      = $true
        Status  = "ok"
        Reason  = "six-decimal-fractions"
        Message = $null
        Rect    = [pscustomobject][ordered]@{
            x = [double]$left
            y = [double]$top
            w = [double]$width
            h = [double]$height
        }
    }
}

function Resolve-DevWSRelativeLayout {
    # Convenience composition: resolve the anchor and convert the normalized
    # rectangle to an absolute one. Failure objects retain the anchor details
    # so callers can report the exact reason without re-resolving.
    param(
        $RelativeLayout,
        $Topology
    )

    $anchor = Resolve-DevWSRelativeLayoutAnchor -RelativeLayout $RelativeLayout -Topology $Topology

    if (-not [bool]$anchor.Ok) {
        return $anchor
    }

    $relativeRect = Get-DevWSProperty -Object $RelativeLayout -Name "rect"
    $converted = ConvertTo-DevWSRelativeAbsoluteRect -RelativeRect $relativeRect -BasisRect $anchor.BasisRect

    if (-not [bool]$converted.Ok) {
        return [pscustomobject][ordered]@{
            Ok         = $false
            Status     = $converted.Status
            Reason     = $converted.Reason
            Message    = $converted.Message
            Monitor    = $anchor.Monitor
            Identity   = $anchor.Identity
            Instance   = $anchor.Instance
            Basis      = $anchor.Basis
            BasisRect  = $anchor.BasisRect
            Rect       = $null
        }
    }

    return [pscustomobject][ordered]@{
        Ok         = $true
        Status     = "resolved"
        Reason     = $anchor.Reason
        Message    = $null
        Monitor    = $anchor.Monitor
        Identity   = $anchor.Identity
        Instance   = $anchor.Instance
        Basis      = $anchor.Basis
        BasisRect  = $anchor.BasisRect
        Rect       = $converted.Rect
    }
}

function Test-DevWSRelativeAnchorPersistable {
    # Validate that one selected monitor can be written as a durable relative
    # anchor and resolved uniquely on restore using the approved identity rules.
    # Greatest-visible-area selection alone is not enough: a monitor without
    # an identity, or one whose identity needs an absent/non-unique instance,
    # cannot be persisted without falling back to ordinals or positions.
    param(
        $Monitor,
        $Topology
    )

    if ($null -eq $Monitor -or $Monitor -isnot [System.Management.Automation.PSCustomObject]) {
        return [pscustomobject][ordered]@{
            Ok        = $false
            Status    = "anchor-unpersistable"
            Reason    = "monitor-invalid"
            Message   = "The selected monitor is missing or invalid."
            Monitor   = $null
            Identity  = $null
            Instance  = $null
        }
    }

    $identity = [string](Get-DevWSProperty -Object $Monitor -Name "IdentityToken")

    if ([string]::IsNullOrWhiteSpace($identity)) {
        return [pscustomobject][ordered]@{
            Ok        = $false
            Status    = "anchor-unpersistable"
            Reason    = "identity-unavailable"
            Message   = "The selected monitor has no usable durable identity; its anchor cannot be persisted."
            Monitor   = $Monitor
            Identity  = $identity
            Instance  = $null
        }
    }

    $instance = [string](Get-DevWSProperty -Object $Monitor -Name "DevicePathInstance")

    if ($identity.StartsWith("path:", [System.StringComparison]::Ordinal)) {
        # A path identity already embeds the device-path instance.
        $instance = $null
    }

    $monitorFields = [ordered]@{ identity = $identity }

    if (-not [string]::IsNullOrWhiteSpace($instance)) {
        $monitorFields["instance"] = $instance
    }

    $probe = [pscustomobject][ordered]@{
        monitor = [pscustomobject]$monitorFields
        basis   = "monitor"
        rect    = [pscustomobject][ordered]@{ x = 0; y = 0; w = 1; h = 1 }
    }

    $resolved = Resolve-DevWSRelativeLayoutAnchor -RelativeLayout $probe -Topology $Topology

    if (-not [bool]$resolved.Ok) {
        return [pscustomobject][ordered]@{
            Ok             = $false
            Status         = "anchor-unpersistable"
            Reason         = $resolved.Reason
            Message        = "The selected monitor's identity cannot be persisted as a unique relative anchor: $($resolved.Message)"
            Monitor        = $Monitor
            Identity       = $identity
            Instance       = $instance
            ResolvedStatus = $resolved.Status
        }
    }

    return [pscustomobject][ordered]@{
        Ok             = $true
        Status         = "persistable"
        Reason         = $resolved.Reason
        Message        = $null
        Monitor        = $Monitor
        Identity       = $identity
        Instance       = $instance
        ResolvedStatus = $resolved.Status
    }
}

function Select-DevWSRelativeAnchorFromRect {
    # Choose the monitor with the strictly greatest visible intersection area
    # for a captured rectangle. Ties are ambiguous and refuse. A rectangle
    # with no visible area may retain an existing relative anchor only when
    # that anchor resolves uniquely; otherwise it has no usable anchor. The
    # selected monitor must also be persistable as a durable relative anchor.
    param(
        $Rect,
        $Topology,
        $ExistingRelativeLayout = $null
    )

    if ($null -eq $Topology -or -not [bool](Get-DevWSProperty -Object $Topology -Name "Available")) {
        return [pscustomobject][ordered]@{
            Ok          = $false
            Status      = "topology-unavailable"
            Reason      = "topology-unavailable"
            Message     = "The current monitor topology is unavailable; an anchor cannot be selected."
            Monitor     = $null
            VisibleArea = [double]0
            WinnerCount = 0
        }
    }

    $monitorsValue = Get-DevWSProperty -Object $Topology -Name "Monitors"

    if ($null -eq $monitorsValue -or $monitorsValue -isnot [array] -or @($monitorsValue).Count -eq 0) {
        return [pscustomobject][ordered]@{
            Ok          = $false
            Status      = "topology-unavailable"
            Reason      = "no-monitors"
            Message     = "The current monitor topology contains no monitor rectangles."
            Monitor     = $null
            VisibleArea = [double]0
            WinnerCount = 0
        }
    }

    if ($null -eq $Rect -or $Rect -isnot [System.Management.Automation.PSCustomObject]) {
        return [pscustomobject][ordered]@{
            Ok          = $false
            Status      = "rect-invalid"
            Reason      = "absolute-rect-invalid"
            Message     = "The captured rectangle is missing or invalid."
            Monitor     = $null
            VisibleArea = [double]0
            WinnerCount = 0
        }
    }

    foreach ($field in @("x", "y", "w", "h")) {
        if (-not (Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $Rect -Name $field))) {
            return [pscustomobject][ordered]@{
                Ok          = $false
                Status      = "rect-invalid"
                Reason      = "absolute-$field-invalid"
                Message     = "The captured rectangle field '$field' must be a finite number."
                Monitor     = $null
                VisibleArea = [double]0
                WinnerCount = 0
            }
        }
    }

    if ([double]$Rect.w -le 0 -or [double]$Rect.h -le 0) {
        return [pscustomobject][ordered]@{
            Ok          = $false
            Status      = "rect-invalid"
            Reason      = "absolute-size-not-positive"
            Message     = "The captured rectangle width and height must be greater than 0."
            Monitor     = $null
            VisibleArea = [double]0
            WinnerCount = 0
        }
    }

    $rectX = [double]$Rect.x
    $rectY = [double]$Rect.y
    $rectW = [double]$Rect.w
    $rectH = [double]$Rect.h
    $maxArea = [double]0
    $winners = [System.Collections.Generic.List[object]]::new()

    foreach ($monitor in @($monitorsValue)) {
        if ($null -eq $monitor -or $monitor -isnot [System.Management.Automation.PSCustomObject]) {
            continue
        }

        $basisResult = Get-DevWSRelativeLayoutBasisRect -Monitor $monitor -Basis "monitor"

        if (-not [bool]$basisResult.Ok) {
            continue
        }

        $monitorRect = $basisResult.Rect
        $left   = [Math]::Max($rectX, [double]$monitorRect.x)
        $top    = [Math]::Max($rectY, [double]$monitorRect.y)
        $right  = [Math]::Min($rectX + $rectW, [double]$monitorRect.x + [double]$monitorRect.w)
        $bottom = [Math]::Min($rectY + $rectH, [double]$monitorRect.y + [double]$monitorRect.h)
        $area   = [double]0

        if ($right -gt $left -and $bottom -gt $top) {
            $area = ($right - $left) * ($bottom - $top)
        }

        if ($area -gt $maxArea) {
            $maxArea = $area
            $winners.Clear()
            $winners.Add($monitor) | Out-Null
        }
        elseif ($area -eq $maxArea -and $area -gt 0) {
            $winners.Add($monitor) | Out-Null
        }
    }

    if ($winners.Count -eq 1) {
        $persistable = Test-DevWSRelativeAnchorPersistable -Monitor $winners[0] -Topology $Topology

        if (-not [bool]$persistable.Ok) {
            return [pscustomobject][ordered]@{
                Ok          = $false
                Status      = $persistable.Status
                Reason      = $persistable.Reason
                Message     = $persistable.Message
                Monitor     = $null
                Identity    = $persistable.Identity
                Instance    = $persistable.Instance
                VisibleArea = [double]$maxArea
                WinnerCount = 1
            }
        }

        return [pscustomobject][ordered]@{
            Ok          = $true
            Status      = "selected"
            Reason      = "greatest-visible-area"
            Message     = $null
            Monitor     = $winners[0]
            Identity    = $persistable.Identity
            Instance    = $persistable.Instance
            VisibleArea = [double]$maxArea
            WinnerCount = 1
        }
    }

    if ($winners.Count -gt 1) {
        return [pscustomobject][ordered]@{
            Ok          = $false
            Status      = "ambiguous-visible-area"
            Reason      = "tie"
            Message     = "The captured rectangle has equal visible area on multiple monitors; choose the anchor explicitly."
            Monitor     = $null
            VisibleArea = [double]$maxArea
            WinnerCount = $winners.Count
        }
    }

    if ($null -ne $ExistingRelativeLayout) {
        $existing = Resolve-DevWSRelativeLayoutAnchor -RelativeLayout $ExistingRelativeLayout -Topology $Topology

        if ([bool]$existing.Ok) {
            $persistable = Test-DevWSRelativeAnchorPersistable -Monitor $existing.Monitor -Topology $Topology

            if (-not [bool]$persistable.Ok) {
                return [pscustomobject][ordered]@{
                    Ok          = $false
                    Status      = $persistable.Status
                    Reason      = $persistable.Reason
                    Message     = $persistable.Message
                    Monitor     = $null
                    Identity    = $persistable.Identity
                    Instance    = $persistable.Instance
                    VisibleArea = [double]0
                    WinnerCount = 0
                }
            }

            return [pscustomobject][ordered]@{
                Ok          = $true
                Status      = "selected"
                Reason      = "existing-anchor"
                Message     = $null
                Monitor     = $existing.Monitor
                Identity    = $persistable.Identity
                Instance    = $persistable.Instance
                VisibleArea = [double]0
                WinnerCount = 0
            }
        }
    }

    return [pscustomobject][ordered]@{
        Ok          = $false
        Status      = "no-visible-area"
        Reason      = "no-visible-area"
        Message     = "The captured rectangle is not visible on any monitor and no resolvable existing anchor is available."
        Monitor     = $null
        VisibleArea = [double]0
        WinnerCount = 0
    }
}

function Copy-DevWSRelativeLayout {
    # Deep copy of the relative-layout object. Unknown properties are not
    # copied (schema validation rejects them), and no nested object is shared
    # with the source.
    param($RelativeLayout)

    if ($null -eq $RelativeLayout) {
        return $null
    }

    if ($RelativeLayout -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Cannot copy relative layout: the value is not an object."
    }

    $monitor = Get-DevWSProperty -Object $RelativeLayout -Name "monitor"

    if ($null -eq $monitor -or $monitor -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Cannot copy relative layout: monitor is missing or invalid."
    }

    $identity = Get-DevWSProperty -Object $monitor -Name "identity"

    if ($identity -isnot [string] -or [string]::IsNullOrWhiteSpace($identity)) {
        throw "Cannot copy relative layout: monitor.identity is missing or invalid."
    }

    $monitorCopy = [ordered]@{
        identity = [string]$identity
    }

    if (Test-DevWSProperty -Object $monitor -Name "instance") {
        $monitorCopy["instance"] = [string](Get-DevWSProperty -Object $monitor -Name "instance")
    }

    $basis = Get-DevWSProperty -Object $RelativeLayout -Name "basis"
    $rect  = Get-DevWSProperty -Object $RelativeLayout -Name "rect"

    if ($basis -isnot [string] -or ($basis -cne "workArea" -and $basis -cne "monitor")) {
        throw "Cannot copy relative layout: basis is missing or invalid."
    }

    if ($null -eq $rect -or $rect -isnot [System.Management.Automation.PSCustomObject] -or
        -not (Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $rect -Name "x")) -or
        -not (Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $rect -Name "y")) -or
        -not (Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $rect -Name "w")) -or
        -not (Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $rect -Name "h")) -or
        [double]$rect.w -le 0 -or [double]$rect.h -le 0) {
        throw "Cannot copy relative layout: rect is missing or invalid."
    }

    return [pscustomobject][ordered]@{
        monitor = [pscustomobject]$monitorCopy
        basis   = [string]$basis
        rect    = [pscustomobject][ordered]@{
            x = [double]$rect.x
            y = [double]$rect.y
            w = [double]$rect.w
            h = [double]$rect.h
        }
    }
}
