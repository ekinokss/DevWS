# DevWS v0.4 P3 editor projection helpers.
#
# Pure, read-only composition around the existing DevWS configuration,
# monitor-topology, relative-layout, and topology-profile functions. This file
# is dot-sourced by ws-editor-backend.ps1 and by the focused P3 tests. It does
# not read or write configuration on its own except through the caller-provided
# snapshot function.

function Get-EditorSha256Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Read-EditorConfigSnapshot {
    # Reads the effective config bytes exactly once, hashes those bytes, parses
    # those same bytes, and validates the resulting document. The caller decides
    # how to report invalid or oversized snapshots.
    param(
        [Parameter(Mandatory)][string]$StartPath,
        [int]$MaxBytes = 4194304
    )

    try {
        $location = Resolve-DevWSConfigLocation -StartPath $StartPath
    }
    catch {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Code    = 'config-unavailable'
            Message = $_.Exception.Message
        }
    }

    $canonicalPath = Get-DevWSCanonicalConfigPath
    $canonicalExists = Test-Path -LiteralPath $canonicalPath -PathType Leaf

    try {
        $declaredLength = [System.IO.FileInfo]::new($location.Path).Length
    }
    catch {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Code    = 'config-unavailable'
            Message = "The effective configuration could not be inspected: $($_.Exception.Message)"
        }
    }

    if ($declaredLength -gt $MaxBytes) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Code    = 'config-too-large'
            Message = "The effective configuration is $declaredLength bytes; the P3 limit is $MaxBytes bytes."
            Location = $location
            CanonicalPath = $canonicalPath
            CanonicalExists = $canonicalExists
            SizeBytes = $declaredLength
        }
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($location.Path)
    }
    catch {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Code    = 'config-unavailable'
            Message = "The effective configuration could not be read: $($_.Exception.Message)"
        }
    }

    if ($bytes.Length -gt $MaxBytes) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Code    = 'config-too-large'
            Message = "The effective configuration is $($bytes.Length) bytes; the P3 limit is $MaxBytes bytes."
            Location = $location
            CanonicalPath = $canonicalPath
            CanonicalExists = $canonicalExists
            SizeBytes = $bytes.Length
        }
    }

    $sha256 = Get-EditorSha256Hex -Bytes $bytes

    try {
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    }
    catch {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Code    = 'config-invalid'
            Message = "The effective configuration is not valid UTF-8: $($_.Exception.Message)"
            Location = $location
            CanonicalPath = $canonicalPath
            CanonicalExists = $canonicalExists
            SizeBytes = $bytes.Length
            Sha256 = $sha256
        }
    }

    try {
        $config = $text | ConvertFrom-Json -Depth 32 -ErrorAction Stop
    }
    catch {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Code    = 'config-invalid'
            Message = "Invalid JSON in '$($location.Path)': $($_.Exception.Message)"
            Location = $location
            CanonicalPath = $canonicalPath
            CanonicalExists = $canonicalExists
            SizeBytes = $bytes.Length
            Sha256 = $sha256
        }
    }

    $valid = $true
    $validationError = $null

    try {
        Assert-DevWSConfig -Config $config -Source $location.Path
    }
    catch {
        $valid = $false
        $validationError = $_.Exception.Message
    }

    return [pscustomobject][ordered]@{
        Ok              = $true
        Code            = $null
        Message         = $null
        Location        = $location
        CanonicalPath   = $canonicalPath
        CanonicalExists = $canonicalExists
        SizeBytes       = $bytes.Length
        Bytes           = $bytes
        Text            = $text
        Sha256          = $sha256
        Config          = $config
        Valid           = $valid
        ValidationError = $validationError
    }
}

function Get-EditorConfigMetadata {
    param([Parameter(Mandatory)]$Snapshot)

    $config = $Snapshot.Config

    return [pscustomobject][ordered]@{
        canonicalPath   = [string]$Snapshot.CanonicalPath
        effectivePath   = [string]$Snapshot.Location.Path
        source          = [string]$Snapshot.Location.Source
        canonicalExists = [bool]$Snapshot.CanonicalExists
        writable        = [bool]$Snapshot.Location.IsWritable
        sha256          = [string]$Snapshot.Sha256
        sizeBytes       = [int]$Snapshot.SizeBytes
        version         = if ($null -ne $config -and $null -ne $config.PSObject.Properties['version']) { $config.version } else { $null }
        defaultSet      = if ($null -ne $config -and $null -ne $config.PSObject.Properties['defaultSet']) { [string]$config.defaultSet } else { $null }
        valid           = [bool]$Snapshot.Valid
    }
}

function Get-EditorSetMetadata {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DefaultSetId
    )

    $sets = @(Get-DevWSSets -Config $Config)
    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($set in $sets) {
        $profiles = @(Get-DevWSLayoutProfiles -Set $set)
        $result.Add([pscustomobject][ordered]@{
            id         = [string]$set.id
            isDefault  = ([string]$set.id -ieq $DefaultSetId)
            itemCount  = @($set.windows).Count
            profileIds = @($profiles | ForEach-Object { [string]$_.id })
        }) | Out-Null
    }

    return @($result.ToArray())
}

function Get-EditorTopologyProjection {
    param($Topology)

    if ($null -eq $Topology -or -not [bool]$Topology.Available) {
        return [pscustomobject][ordered]@{
            available           = $false
            identityComplete    = $false
            correlationComplete = $false
            identityAmbiguous   = $false
            signature           = $null
            fingerprint         = $null
            virtualScreenRect   = $null
            monitors            = @()
            error               = if ($null -ne $Topology) { [string]$Topology.Error } else { 'topology unavailable' }
        }
    }

    $monitors = [System.Collections.Generic.List[object]]::new()

    foreach ($monitor in @($Topology.Monitors)) {
        $monitors.Add([pscustomobject][ordered]@{
            identity         = [string]$monitor.IdentityToken
            instance         = [string]$monitor.DevicePathInstance
            friendlyName     = [string]$monitor.FriendlyName
            primary          = [bool]$monitor.Primary
            monitorRect      = [pscustomobject][ordered]@{
                x = [int]$monitor.MonitorRect.x
                y = [int]$monitor.MonitorRect.y
                w = [int]$monitor.MonitorRect.w
                h = [int]$monitor.MonitorRect.h
            }
            workRect         = [pscustomobject][ordered]@{
                x = [int]$monitor.WorkRect.x
                y = [int]$monitor.WorkRect.y
                w = [int]$monitor.WorkRect.w
                h = [int]$monitor.WorkRect.h
            }
            scalePercent     = $monitor.ScalePercent
            outputTechnology = [string]$monitor.OutputTechnology
        }) | Out-Null
    }

    return [pscustomobject][ordered]@{
        available           = $true
        identityComplete    = [bool]$Topology.IdentityComplete
        correlationComplete = [bool]$Topology.CorrelationComplete
        identityAmbiguous   = [bool]$Topology.IdentityAmbiguous
        signature           = [string]$Topology.Signature
        fingerprint         = [string]$Topology.Fingerprint
        virtualScreenRect   = [pscustomobject][ordered]@{
            x = [int]$Topology.VirtualScreenRect.x
            y = [int]$Topology.VirtualScreenRect.y
            w = [int]$Topology.VirtualScreenRect.w
            h = [int]$Topology.VirtualScreenRect.h
        }
        monitors            = @($monitors.ToArray())
        error               = $null
    }
}

function Get-EditorDraftValidation {
    # Structural validation of a complete draft document. This is the same
    # Assert-DevWSConfig gate used for the canonical file; it is not a semantic
    # preview and it does not authorize a save. Canonical error messages are
    # preserved, with best-effort set/item/field context.
    param(
        [Parameter(Mandatory)]$Draft,
        [string]$StartPath = $PSScriptRoot
    )

    $errors = [System.Collections.Generic.List[object]]::new()
    $valid = $true

    try {
        Assert-DevWSConfig -Config $Draft -Source 'editor draft'
    }
    catch {
        $valid = $false
        $message = [string]$_.Exception.Message

        foreach ($line in @($message -split "\r?\n")) {
            $trimmed = $line.Trim()

            if (-not $trimmed.StartsWith('- ')) {
                continue
            }

            $text = $trimmed.Substring(2).Trim()

            if ([string]::IsNullOrWhiteSpace($text)) {
                continue
            }

            $setId = $null
            $itemId = $null
            $field = $null
            $context = [regex]::Match(
                $text,
                "^sets\[(?<set>\d+)\] \('(?<setId>[^']+)'\) windows\[(?<item>\d+)\] \('(?<itemId>[^']+)'\) (?<field>layoutMode|layoutRelative(?:\.[A-Za-z0-9_.]+)?|layout(?:\.[xywh])?)\b")

            if ($context.Success) {
                $setId = [string]$context.Groups['setId'].Value
                $itemId = [string]$context.Groups['itemId'].Value
                $field = [string]$context.Groups['field'].Value
            }

            $errors.Add([pscustomobject][ordered]@{
                code    = 'config-schema-invalid'
                message = $text
                setId   = $setId
                itemId  = $itemId
                field   = $field
            }) | Out-Null
        }

        if ($errors.Count -eq 0) {
            $errors.Add([pscustomobject][ordered]@{
                code    = 'config-schema-invalid'
                message = $message
                setId   = $null
                itemId  = $null
                field   = $null
            }) | Out-Null
        }
    }

    $saveEligible = $false

    if ($valid) {
        try {
            $location = Resolve-DevWSConfigLocation -StartPath $StartPath
            $saveEligible = [bool]$location.IsWritable
        }
        catch {
            $saveEligible = $false
        }
    }

    return [pscustomobject][ordered]@{
        valid        = $valid
        saveEligible = $saveEligible
        errors       = @($errors.ToArray())
    }
}

function Get-EditorConvertFailure {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        $Details = $null
    )

    return [pscustomobject][ordered]@{
        Ok      = $false
        Code    = $Code
        Message = $Message
        Details = $Details
        Result  = $null
    }
}

function Get-EditorConvert {
    # Absolute rectangle -> normalized relative intent through the existing
    # relative-layout functions. The GUI never reimplements this math.
    param(
        $Rect,
        $Anchor,
        [bool]$SelectAnchor,
        [string]$Basis,
        [string]$TopologyFingerprint,
        $Topology
    )

    if ($null -eq $Topology -or -not [bool](Get-DevWSProperty -Object $Topology -Name 'Available')) {
        return Get-EditorConvertFailure -Code 'topology-unavailable' -Message 'The current monitor topology is unavailable; no relative conversion is possible.'
    }

    if ([bool](Get-DevWSProperty -Object $Topology -Name 'IdentityAmbiguous')) {
        return Get-EditorConvertFailure -Code 'topology-ambiguous' -Message 'Duplicate monitor identities make relative conversion ambiguous.'
    }

    if (-not [bool](Get-DevWSProperty -Object $Topology -Name 'IdentityComplete')) {
        return Get-EditorConvertFailure -Code 'topology-incomplete' -Message 'The current monitor topology does not provide complete durable identities.'
    }

    $actualFingerprint = [string](Get-DevWSProperty -Object $Topology -Name 'Fingerprint')

    if (-not [string]::IsNullOrWhiteSpace($TopologyFingerprint)) {
        if ([string]::IsNullOrWhiteSpace($actualFingerprint)) {
            return Get-EditorConvertFailure -Code 'topology-unavailable' -Message 'The current monitor topology has no fingerprint to compare.'
        }

        if ($actualFingerprint -cne $TopologyFingerprint) {
            return Get-EditorConvertFailure -Code 'topology-changed' -Message 'The monitor topology changed since the editing session began.' -Details ([ordered]@{
                expectedFingerprint = $TopologyFingerprint
                actualFingerprint   = $actualFingerprint
            })
        }
    }

    $monitorsValue = Get-DevWSProperty -Object $Topology -Name 'Monitors'
    $monitorRects = [System.Collections.Generic.List[object]]::new()

    if ($null -ne $monitorsValue -and $monitorsValue -is [array]) {
        foreach ($monitor in @($monitorsValue)) {
            if ($null -ne $monitor -and $null -ne (Get-DevWSProperty -Object $monitor -Name 'MonitorRect')) {
                $monitorRects.Add((Get-DevWSProperty -Object $monitor -Name 'MonitorRect')) | Out-Null
            }
        }
    }

    $anchorMonitor = $null
    $identity = $null
    $instance = $null
    $basisRect = $null

    if ($SelectAnchor) {
        $selection = Select-DevWSRelativeAnchorFromRect -Rect $Rect -Topology $Topology

        if (-not [bool]$selection.Ok) {
            $code = switch ([string]$selection.Status) {
                'topology-unavailable' { 'topology-unavailable' }
                'anchor-unpersistable' { 'anchor-unpersistable' }
                'rect-invalid'         { 'invalid-rect' }
                default                { 'anchor-missing' }
            }

            return Get-EditorConvertFailure -Code $code -Message ([string]$selection.Message) -Details ([ordered]@{
                reason = [string]$selection.Reason
            })
        }

        $anchorMonitor = $selection.Monitor
        $identity = [string](Get-DevWSProperty -Object $anchorMonitor -Name 'IdentityToken')
        $instance = [string](Get-DevWSProperty -Object $anchorMonitor -Name 'DevicePathInstance')

        if ($identity.StartsWith('path:', [System.StringComparison]::Ordinal)) {
            $instance = $null
        }

        $basisResult = Get-DevWSRelativeLayoutBasisRect -Monitor $anchorMonitor -Basis $Basis
    }
    else {
        $monitorSpec = [ordered]@{ identity = [string]$Anchor.identity }

        if ($null -ne $Anchor -and $null -ne $Anchor.PSObject.Properties['instance'] -and
            -not [string]::IsNullOrWhiteSpace([string]$Anchor.instance)) {
            $monitorSpec['instance'] = [string]$Anchor.instance
        }

        $probe = [pscustomobject][ordered]@{
            monitor = [pscustomobject]$monitorSpec
            basis   = $Basis
            rect    = [pscustomobject][ordered]@{ x = 0; y = 0; w = 1; h = 1 }
        }

        $resolved = Resolve-DevWSRelativeLayoutAnchor -RelativeLayout $probe -Topology $Topology

        if (-not [bool]$resolved.Ok) {
            $code = switch ([string]$resolved.Status) {
                'topology-unavailable' { 'topology-unavailable' }
                'anchor-missing'       { 'anchor-missing' }
                'anchor-ambiguous'     { 'anchor-ambiguous' }
                'basis-unavailable'    { 'basis-unavailable' }
                default                { 'anchor-unpersistable' }
            }

            return Get-EditorConvertFailure -Code $code -Message ([string]$resolved.Message) -Details ([ordered]@{
                reason   = [string]$resolved.Reason
                identity = [string]$resolved.Identity
                instance = [string]$resolved.Instance
            })
        }

        $anchorMonitor = $resolved.Monitor
        $identity = [string]$resolved.Identity
        $instance = [string]$resolved.Instance

        $persistable = Test-DevWSRelativeAnchorPersistable -Monitor $anchorMonitor -Topology $Topology

        if (-not [bool]$persistable.Ok) {
            return Get-EditorConvertFailure -Code 'anchor-unpersistable' -Message ([string]$persistable.Message) -Details ([ordered]@{
                reason = [string]$persistable.Reason
            })
        }

        $basisRect = $resolved.BasisRect
    }

    if ($null -eq $basisRect) {
        $basisResult = Get-DevWSRelativeLayoutBasisRect -Monitor $anchorMonitor -Basis $Basis

        if (-not [bool]$basisResult.Ok) {
            return Get-EditorConvertFailure -Code 'basis-unavailable' -Message ([string]$basisResult.Message) -Details ([ordered]@{
                reason = [string]$basisResult.Reason
            })
        }

        $basisRect = $basisResult.Rect
    }

    $converted = ConvertFrom-DevWSAbsoluteRectToRelative -Rect $Rect -BasisRect $basisRect

    if (-not [bool]$converted.Ok) {
        $code = if ([string]$converted.Status -eq 'basis-unavailable') { 'basis-unavailable' } else { 'invalid-rect' }
        return Get-EditorConvertFailure -Code $code -Message ([string]$converted.Message) -Details ([ordered]@{
            reason = [string]$converted.Reason
        })
    }

    $roundTrip = ConvertTo-DevWSRelativeAbsoluteRect -RelativeRect $converted.Rect -BasisRect $basisRect

    if (-not [bool]$roundTrip.Ok) {
        return Get-EditorConvertFailure -Code 'invalid-rect' -Message ([string]$roundTrip.Message) -Details ([ordered]@{
            reason = [string]$roundTrip.Reason
        })
    }

    $reachable = $false
    $visibleRatio = $null

    if ($monitorRects.Count -gt 0) {
        $metrics = Test-DevWSRectReachable -Rect $roundTrip.Rect -MonitorRects @($monitorRects.ToArray())
        $reachable = [bool]$metrics.Reachable
        $visibleRatio = [double]$metrics.VisibleRatio
    }

    $anchorResult = [ordered]@{ identity = $identity }

    if (-not [string]::IsNullOrWhiteSpace($instance)) {
        $anchorResult['instance'] = $instance
    }

    return [pscustomobject][ordered]@{
        Ok      = $true
        Code    = $null
        Message = $null
        Details = $null
        Result  = [pscustomobject][ordered]@{
            anchor        = [pscustomobject]$anchorResult
            basis         = $Basis
            basisRect     = [pscustomobject][ordered]@{
                x = [int]$basisRect.x
                y = [int]$basisRect.y
                w = [int]$basisRect.w
                h = [int]$basisRect.h
            }
            normalized    = [pscustomobject][ordered]@{
                x = [double]$converted.Rect.x
                y = [double]$converted.Rect.y
                w = [double]$converted.Rect.w
                h = [double]$converted.Rect.h
            }
            roundTripRect = [pscustomobject][ordered]@{
                x = [int]$roundTrip.Rect.x
                y = [int]$roundTrip.Rect.y
                w = [int]$roundTrip.Rect.w
                h = [int]$roundTrip.Rect.h
            }
            reachable     = $reachable
            visibleRatio  = $visibleRatio
        }
    }
}

function Get-EditorWarnings {
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][string]$SetId
    )

    $warnings = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    if (-not [string]::IsNullOrWhiteSpace([string]$Model.ProfileLifecycleRefusal)) {
        $reason = [string]$Model.ProfileLifecycleRefusal
        $id = "profile-refusal|$SetId|$reason"

        if ($seen.Add($id)) {
            $warnings.Add([pscustomobject][ordered]@{
                id                      = $id
                code                    = 'profile-refusal'
                message                 = (Get-DevWSLayoutWriteRefusalMessage -Reason $reason)
                requiresAcknowledgement = $true
                details                 = [pscustomobject][ordered]@{
                    setId  = $SetId
                    reason = $reason
                }
            }) | Out-Null
        }
    }

    foreach ($item in @($Model.Items)) {
        $relativeStatus = [string]$item.RelativeStatus
        $placementStatus = [string]$item.PlacementStatus
        $code = $null
        $message = $null

        switch ($relativeStatus) {
            'anchor-missing'      { $code = 'anchor-missing'; $message = [string]$item.RelativeMessage }
            'anchor-ambiguous'    { $code = 'anchor-ambiguous'; $message = [string]$item.RelativeMessage }
            'anchor-unpersistable' { $code = 'anchor-unpersistable'; $message = [string]$item.RelativeMessage }
            'relative-invalid'    { $code = 'relative-invalid'; $message = [string]$item.RelativeMessage }
            'basis-unavailable'   { $code = 'basis-unavailable'; $message = [string]$item.RelativeMessage }
            'relative-unreachable' { $code = 'relative-unreachable'; $message = [string]$item.RelativeMessage }
            'topology-unavailable' { $code = 'topology-unavailable'; $message = [string]$item.RelativeMessage }
        }

        if ($null -eq $code -and $placementStatus -eq 'profile-unreachable') {
            $code = 'profile-unreachable'
            $message = 'The matched profile entry is not reachable on the current topology.'
        }

        if ($null -eq $code -and $placementStatus -eq 'fallback-unreachable') {
            $code = 'fallback-unreachable'
            $message = 'The absolute fallback is not reachable on the current topology.'
        }

        if ($null -eq $code) {
            continue
        }

        $identity = if ($null -ne $item.RelativeLayout -and $null -ne $item.RelativeLayout.monitor) {
            [string]$item.RelativeLayout.monitor.identity
        } else {
            $null
        }

        $id = "$code|$SetId|$($item.ItemId)|$identity"
        if (-not $seen.Add($id)) {
            continue
        }

        $warnings.Add([pscustomobject][ordered]@{
            id                      = $id
            code                    = $code
            message                 = $message
            requiresAcknowledgement = $true
            details                 = [pscustomobject][ordered]@{
                setId           = $SetId
                itemId          = [string]$item.ItemId
                identity        = $identity
                relativeStatus  = $relativeStatus
                placementStatus = $placementStatus
                placementReason = [string]$item.PlacementReason
            }
        }) | Out-Null
    }

    return @($warnings.ToArray())
}

function Get-EditorProjection {
    # Read-only projection over Get-DevWSEffectiveLayout. The resolver remains
    # the sole authority for profile > relative > fallback precedence.
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Set,
        $Topology,
        [Parameter(Mandatory)][string]$ConfigRevision
    )

    $model = Get-DevWSEffectiveLayout -SetId ([string]$Set.id) -Set $Set -Topology $Topology
    $selection = Resolve-DevWSLayoutProfile -Set $Set -Topology $Topology
    $profile = if ($selection.Status -eq 'matched') { $selection.Profile } else { $null }
    $isDefault = ([string]$Set.id -ieq [string]$Config.defaultSet)

    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($model.Items)) {
        $profileEntry = if ($null -ne $profile) {
            Get-DevWSLayoutProfileEntry -Profile $profile -ItemId ([string]$item.ItemId)
        } else {
            $null
        }

        $items.Add([pscustomobject][ordered]@{
            itemId                    = [string]$item.ItemId
            type                      = [string]$item.Type
            enabled                   = [bool]$item.Enabled
            layoutMode                = [string]$item.LayoutMode
            rect                      = $item.Rect
            source                    = [string]$item.Source
            profileId                 = $item.ProfileId
            profileMatched            = [bool]$item.ProfileMatched
            profileOverridesRelative  = [bool]$item.ProfileOverridesRelative
            profileEntry              = $profileEntry
            relativeLayout            = $item.RelativeLayout
            relativeStatus            = [string]$item.RelativeStatus
            relativeReason            = $item.RelativeReason
            relativeMessage           = if ([string]::IsNullOrEmpty([string]$item.RelativeMessage)) { $null } else { [string]$item.RelativeMessage }
            relativeRect              = $item.RelativeRect
            relativeReachable         = $item.RelativeReachable
            fallbackRect              = $item.FallbackRect
            fallbackReachable         = $item.FallbackReachable
            fallbackUsed              = [bool]$item.FallbackUsed
            applyGeometry             = [bool]$item.ApplyGeometry
            placementStatus           = [string]$item.PlacementStatus
            placementReason           = [string]$item.PlacementReason
            reachable                 = $item.Reachable
            visibleRatio              = $item.VisibleRatio
            visibleWidth              = $item.VisibleWidth
            visibleHeight             = $item.VisibleHeight
        }) | Out-Null
    }

    $setProjection = [pscustomobject][ordered]@{
        id              = [string]$Set.id
        isDefault       = $isDefault
        profileAware    = [bool]$model.ProfileAware
        profileMatch    = [pscustomobject][ordered]@{
            status    = [string]$model.Status
            profileId = $model.ProfileId
            reason    = [string]$model.Reason
        }
        lifecycleRefusal = $model.ProfileLifecycleRefusal
        items            = @($items.ToArray())
    }

    $warningItems = @(Get-EditorWarnings -Model $model -SetId ([string]$Set.id))

    return [pscustomobject][ordered]@{
        configRevision = $ConfigRevision
        setId          = [string]$Set.id
        set            = $setProjection
        topology       = Get-EditorTopologyProjection -Topology $Topology
        warnings       = @($warningItems)
    }
}
