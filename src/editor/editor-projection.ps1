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

function Test-EditorWarningRequiresAcknowledgement {
    param([string]$Code)

    if ($Code -ceq 'deferred-qualification') {
        return $false
    }

    return $Code -in @(
        'anchor-missing',
        'anchor-ambiguous',
        'anchor-unpersistable',
        'relative-unreachable',
        'fallback-unreachable',
        'profile-unreachable',
        'topology-unavailable',
        'topology-incomplete',
        'topology-ambiguous'
    )
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
                requiresAcknowledgement = (Test-EditorWarningRequiresAcknowledgement -Code 'profile-refusal')
                details                 = [pscustomobject][ordered]@{
                    setId           = $SetId
                    itemId          = $null
                    profileId       = $null
                    identity        = $null
                    instance        = $null
                    reason          = $reason
                    relativeStatus  = $null
                    placementStatus = $null
                    placementReason = $null
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

        $instance = if ($null -ne $item.RelativeLayout -and $null -ne $item.RelativeLayout.monitor -and
            $null -ne $item.RelativeLayout.monitor.PSObject.Properties['instance']) {
            [string]$item.RelativeLayout.monitor.instance
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
            requiresAcknowledgement = (Test-EditorWarningRequiresAcknowledgement -Code $code)
            details                 = [pscustomobject][ordered]@{
                setId           = $SetId
                itemId          = [string]$item.ItemId
                profileId       = $item.ProfileId
                identity        = $identity
                instance        = $instance
                reason          = [string]$item.RelativeReason
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

# ---------------------------------------------------------------------------
# P6 preview helpers
# ---------------------------------------------------------------------------

function ConvertTo-EditorJsonPointerToken {
    param([Parameter(Mandatory)][string]$Token)

    return $Token.Replace('~', '~0').Replace('/', '~1')
}

function Get-EditorJsonKind {
    param($Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return 'object' }
    if ($Value -is [array]) { return 'array' }
    if ($Value -is [string]) { return 'string' }
    if ($Value -is [bool]) { return 'boolean' }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or
        $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        return 'number'
    }

    return 'other'
}

function Test-EditorJsonNumber {
    param($Value)

    return $Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or
        $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]
}

function Test-EditorJsonEqual {
    param($Left, $Right)

    $leftKind = Get-EditorJsonKind -Value $Left
    $rightKind = Get-EditorJsonKind -Value $Right

    if ($leftKind -cne $rightKind) {
        return $false
    }

    switch ($leftKind) {
        'null' { return $true }
        'number' { return ([double]$Left -eq [double]$Right) }
        'string' { return ($Left -ceq $Right) }
        'boolean' { return ([bool]$Left -eq [bool]$Right) }
        'array' {
            if ($Left.Count -ne $Right.Count) {
                return $false
            }

            for ($index = 0; $index -lt $Left.Count; $index++) {
                if (-not (Test-EditorJsonEqual -Left $Left[$index] -Right $Right[$index])) {
                    return $false
                }
            }

            return $true
        }
        'object' {
            $leftNames = @($Left.PSObject.Properties | ForEach-Object { [string]$_.Name })
            $rightNames = @($Right.PSObject.Properties | ForEach-Object { [string]$_.Name })

            if ($leftNames.Count -ne $rightNames.Count) {
                return $false
            }

            $rightSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($name in $rightNames) {
                $rightSet.Add($name) | Out-Null
            }

            foreach ($name in $leftNames) {
                if (-not $rightSet.Contains($name)) {
                    return $false
                }

                if (-not (Test-EditorJsonEqual -Left $Left.$name -Right $Right.$name)) {
                    return $false
                }
            }

            return $true
        }
        default {
            return ([string]$Left -ceq [string]$Right)
        }
    }
}

function Compare-EditorJson {
    param(
        $Left,
        $Right,
        [string]$Path,
        [System.Collections.Generic.List[object]]$Differences
    )

    if (Test-EditorJsonEqual -Left $Left -Right $Right) {
        return
    }

    $leftKind = Get-EditorJsonKind -Value $Left
    $rightKind = Get-EditorJsonKind -Value $Right

    if ($leftKind -eq 'object' -and $rightKind -eq 'object') {
        $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

        foreach ($property in $Left.PSObject.Properties) {
            $names.Add([string]$property.Name) | Out-Null
        }

        foreach ($property in $Right.PSObject.Properties) {
            $names.Add([string]$property.Name) | Out-Null
        }

        $ordered = @($names)
        [System.Array]::Sort($ordered, [System.StringComparer]::Ordinal)

        foreach ($name in $ordered) {
            $token = ConvertTo-EditorJsonPointerToken -Token $name
            $childPath = "$Path/$token"
            $leftHas = $null -ne $Left.PSObject.Properties[$name]
            $rightHas = $null -ne $Right.PSObject.Properties[$name]

            if (-not $leftHas -or -not $rightHas) {
                $Differences.Add([pscustomobject][ordered]@{
                    path   = $childPath
                    reason = 'presence'
                    before = if ($leftHas) { $Left.$name } else { $null }
                    after  = if ($rightHas) { $Right.$name } else { $null }
                }) | Out-Null
                continue
            }

            Compare-EditorJson -Left $Left.$name -Right $Right.$name -Path $childPath -Differences $Differences
        }

        return
    }

    if ($leftKind -eq 'array' -and $rightKind -eq 'array') {
        if ($Left.Count -ne $Right.Count) {
            $Differences.Add([pscustomobject][ordered]@{
                path   = $Path
                reason = 'array-length'
                before = $Left.Count
                after  = $Right.Count
            }) | Out-Null
            return
        }

        for ($index = 0; $index -lt $Left.Count; $index++) {
            Compare-EditorJson -Left $Left[$index] -Right $Right[$index] -Path "$Path/$index" -Differences $Differences
        }

        return
    }

    $Differences.Add([pscustomobject][ordered]@{
        path   = $Path
        reason = 'value'
        before = $Left
        after  = $Right
    }) | Out-Null
}

function Get-EditorSetIndex {
    param(
        $Config,
        [Parameter(Mandatory)][string]$SetId
    )

    $sets = $Config.sets

    if ($null -eq $sets -or $sets -isnot [array]) {
        return -1
    }

    for ($index = 0; $index -lt $sets.Count; $index++) {
        if ([string](Get-DevWSProperty -Object $sets[$index] -Name 'id') -ieq $SetId) {
            return $index
        }
    }

    return -1
}

function Get-EditorNormalizedPreviewConfig {
    # Clone the complete document and apply the contract's semantic
    # equivalences: absent layoutMode equals "absolute", and absent/empty
    # layoutProfiles are equivalent when no profiles are present.
    param([Parameter(Mandatory)]$Config)

    $copy = $Config | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $sets = $copy.sets

    if ($null -eq $sets -or $sets -isnot [array]) {
        return $copy
    }

    foreach ($set in @($sets)) {
        $profiles = $set.layoutProfiles

        if ($null -eq $profiles -or $profiles -isnot [array] -or @($profiles).Count -eq 0) {
            $set.PSObject.Properties.Remove('layoutProfiles')
        }

        $windows = $set.windows

        foreach ($item in @($windows)) {
            if ($null -eq $item -or $item -isnot [System.Management.Automation.PSCustomObject]) {
                continue
            }

            if ($null -eq $item.PSObject.Properties['layoutMode']) {
                $item | Add-Member -NotePropertyName 'layoutMode' -NotePropertyValue 'absolute' -Force
            }
        }
    }

    return $copy
}

function Test-EditorAllowedMutationPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$TargetSetIndex
    )

    $prefix = "/sets/$TargetSetIndex"
    $patterns = @(
        "^$prefix/windows/\d+/layout/(x|y|w|h)$",
        "^$prefix/windows/\d+/layoutMode$",
        "^$prefix/windows/\d+/layoutRelative$",
        "^$prefix/windows/\d+/layoutRelative/monitor/(identity|instance)$",
        "^$prefix/windows/\d+/layoutRelative/basis$",
        "^$prefix/windows/\d+/layoutRelative/rect/(x|y|w|h)$",
        "^$prefix/layoutProfiles/\d+/layouts/[^/]+/(x|y|w|h)$"
    )

    foreach ($pattern in $patterns) {
        if ($Path -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-EditorDraftAudit {
    param(
        [Parameter(Mandatory)]$CanonicalConfig,
        [Parameter(Mandatory)]$DraftConfig,
        [Parameter(Mandatory)][string]$SetId
    )

    $canonical = Get-EditorNormalizedPreviewConfig -Config $CanonicalConfig
    $draft = Get-EditorNormalizedPreviewConfig -Config $DraftConfig
    $targetIndex = Get-EditorSetIndex -Config $canonical -SetId $SetId

    if ($targetIndex -lt 0) {
        return [pscustomobject][ordered]@{
            Ok              = $false
            Code            = 'set-not-found'
            Message         = "The canonical configuration does not contain set '$SetId'."
            Details         = [ordered]@{ setId = $SetId }
            Diff            = @()
            Violations      = @()
            RequiresTopology = $false
        }
    }

    if ((Get-EditorSetIndex -Config $draft -SetId $SetId) -lt 0) {
        return [pscustomobject][ordered]@{
            Ok              = $false
            Code            = 'set-not-found'
            Message         = "The draft does not contain set '$SetId'."
            Details         = [ordered]@{ setId = $SetId }
            Diff            = @()
            Violations      = @()
            RequiresTopology = $false
        }
    }

    $differences = [System.Collections.Generic.List[object]]::new()
    Compare-EditorJson -Left $canonical -Right $draft -Path '' -Differences $differences
    $violations = [System.Collections.Generic.List[object]]::new()
    $requiresTopology = $false

    foreach ($difference in $differences) {
        if (-not (Test-EditorAllowedMutationPath -Path ([string]$difference.path) -TargetSetIndex $targetIndex)) {
            $violations.Add($difference) | Out-Null
            continue
        }

        if ($difference.path -match '/layoutMode$' -or
            $difference.path -match '/layoutRelative' -or
            $difference.path -match '/layoutProfiles/\d+/layouts/') {
            $requiresTopology = $true
        }
    }

    $draftSet = @($draft.sets)[$targetIndex]
    $itemIndex = 0

    foreach ($item in @(Get-DevWSProperty -Object $draftSet -Name 'windows')) {
        if ($null -eq $item -or $item -isnot [System.Management.Automation.PSCustomObject]) {
            $itemIndex++
            continue
        }

        $mode = [string](Get-DevWSProperty -Object $item -Name 'layoutMode')
        $relative = Get-DevWSProperty -Object $item -Name 'layoutRelative'

        if ($mode -ceq 'relative' -and $null -eq $relative) {
            $violations.Add([pscustomobject][ordered]@{
                path   = "/sets/$targetIndex/windows/$itemIndex/layoutRelative"
                reason = 'mode-incoherent'
                before = $null
                after  = $null
            }) | Out-Null
            $requiresTopology = $true
        }
        elseif ($mode -cne 'relative' -and $null -ne $relative) {
            $violations.Add([pscustomobject][ordered]@{
                path   = "/sets/$targetIndex/windows/$itemIndex/layoutRelative"
                reason = 'mode-incoherent'
                before = $null
                after  = $null
            }) | Out-Null
            $requiresTopology = $true
        }

        $itemIndex++
    }

    if ($violations.Count -gt 0) {
        $first = $violations[0]
        $reasonCode = switch ([string]$first.reason) {
            'value'        { 'field-not-allowed' }
            'presence'     { 'structural-identity' }
            'array-length' { 'structural-identity' }
            'mode-incoherent' { 'mode-incoherent' }
            default        { 'field-not-allowed' }
        }

        return [pscustomobject][ordered]@{
            Ok              = $false
            Code            = 'unsupported-mutation'
            Message         = 'The draft changes a field that the v0.4 editor is not authorized to modify.'
            Details         = [ordered]@{
                path           = [string]$first.path
                reason         = $reasonCode
                differenceReason = [string]$first.reason
                targetSetId    = $SetId
                allowedScopes  = @('geometry', 'relative-geometry', 'existing-profile-entry-geometry')
            }
            Diff            = @()
            Violations      = @($violations.ToArray())
            RequiresTopology = $requiresTopology
        }
    }

    $diff = @(Get-EditorSemanticDiff -CanonicalConfig $canonical -DraftConfig $draft -SetId $SetId)

    return [pscustomobject][ordered]@{
        Ok              = $true
        Code            = $null
        Message         = $null
        Details         = $null
        Diff            = $diff
        Violations      = @()
        RequiresTopology = ($requiresTopology -or @($diff | Where-Object {
            $_.scope -eq 'relative' -or $_.scope -eq 'mode' -or $_.scope.StartsWith('profile:', [System.StringComparison]::Ordinal)
        }).Count -gt 0)
    }
}

function Get-EditorSemanticDiff {
    param(
        [Parameter(Mandatory)]$CanonicalConfig,
        [Parameter(Mandatory)]$DraftConfig,
        [Parameter(Mandatory)][string]$SetId
    )

    $targetIndex = Get-EditorSetIndex -Config $CanonicalConfig -SetId $SetId

    if ($targetIndex -lt 0) {
        return @()
    }

    $canonicalSet = @($CanonicalConfig.sets)[$targetIndex]
    $draftSet = @($DraftConfig.sets)[$targetIndex]
    $canonicalItems = @($canonicalSet.windows)
    $draftItems = @($draftSet.windows)
    $diff = [System.Collections.Generic.List[object]]::new()

    for ($itemIndex = 0; $itemIndex -lt [Math]::Min($canonicalItems.Count, $draftItems.Count); $itemIndex++) {
        $beforeItem = $canonicalItems[$itemIndex]
        $afterItem = $draftItems[$itemIndex]
        $itemId = [string](Get-DevWSProperty -Object $afterItem -Name 'id')

        $beforeLayout = Get-DevWSProperty -Object $beforeItem -Name 'layout'
        $afterLayout = Get-DevWSProperty -Object $afterItem -Name 'layout'

        if (-not (Test-EditorJsonEqual -Left $beforeLayout -Right $afterLayout)) {
            $diff.Add([pscustomobject][ordered]@{
                setId  = $SetId
                itemId = $itemId
                scope  = 'fallback'
                field  = 'layout'
                before = $beforeLayout
                after  = $afterLayout
            }) | Out-Null
        }

        $beforeMode = [string](Get-DevWSProperty -Object $beforeItem -Name 'layoutMode')
        $afterMode = [string](Get-DevWSProperty -Object $afterItem -Name 'layoutMode')

        if ($beforeMode -cne $afterMode) {
            $diff.Add([pscustomobject][ordered]@{
                setId  = $SetId
                itemId = $itemId
                scope  = 'mode'
                field  = 'layoutMode'
                before = $beforeMode
                after  = $afterMode
            }) | Out-Null
        }

        $beforeRelative = Get-DevWSProperty -Object $beforeItem -Name 'layoutRelative'
        $afterRelative = Get-DevWSProperty -Object $afterItem -Name 'layoutRelative'

        if (($null -eq $beforeRelative) -ne ($null -eq $afterRelative)) {
            $diff.Add([pscustomobject][ordered]@{
                setId  = $SetId
                itemId = $itemId
                scope  = 'relative'
                field  = 'layoutRelative'
                before = $beforeRelative
                after  = $afterRelative
            }) | Out-Null
        }
        elseif ($null -ne $beforeRelative -and $null -ne $afterRelative) {
            $beforeMonitor = Get-DevWSProperty -Object $beforeRelative -Name 'monitor'
            $afterMonitor = Get-DevWSProperty -Object $afterRelative -Name 'monitor'
            $beforeIdentity = Get-DevWSProperty -Object $beforeMonitor -Name 'identity'
            $afterIdentity = Get-DevWSProperty -Object $afterMonitor -Name 'identity'
            $beforeInstance = Get-DevWSProperty -Object $beforeMonitor -Name 'instance'
            $afterInstance = Get-DevWSProperty -Object $afterMonitor -Name 'instance'
            $beforeBasis = Get-DevWSProperty -Object $beforeRelative -Name 'basis'
            $afterBasis = Get-DevWSProperty -Object $afterRelative -Name 'basis'

            if (-not (Test-EditorJsonEqual -Left $beforeIdentity -Right $afterIdentity)) {
                $diff.Add([pscustomobject][ordered]@{
                    setId  = $SetId
                    itemId = $itemId
                    scope  = 'relative'
                    field  = 'layoutRelative.monitor.identity'
                    before = $beforeIdentity
                    after  = $afterIdentity
                }) | Out-Null
            }

            if (-not (Test-EditorJsonEqual -Left $beforeInstance -Right $afterInstance)) {
                $diff.Add([pscustomobject][ordered]@{
                    setId  = $SetId
                    itemId = $itemId
                    scope  = 'relative'
                    field  = 'layoutRelative.monitor.instance'
                    before = $beforeInstance
                    after  = $afterInstance
                }) | Out-Null
            }

            if (-not (Test-EditorJsonEqual -Left $beforeBasis -Right $afterBasis)) {
                $diff.Add([pscustomobject][ordered]@{
                    setId  = $SetId
                    itemId = $itemId
                    scope  = 'relative'
                    field  = 'layoutRelative.basis'
                    before = $beforeBasis
                    after  = $afterBasis
                }) | Out-Null
            }

            $beforeRect = Get-DevWSProperty -Object $beforeRelative -Name 'rect'
            $afterRect = Get-DevWSProperty -Object $afterRelative -Name 'rect'

            foreach ($fieldName in @('x', 'y', 'w', 'h')) {
                $beforeValue = Get-DevWSProperty -Object $beforeRect -Name $fieldName
                $afterValue = Get-DevWSProperty -Object $afterRect -Name $fieldName

                if (-not (Test-EditorJsonEqual -Left $beforeValue -Right $afterValue)) {
                    $diff.Add([pscustomobject][ordered]@{
                        setId  = $SetId
                        itemId = $itemId
                        scope  = 'relative'
                        field  = "layoutRelative.rect.$fieldName"
                        before = $beforeValue
                        after  = $afterValue
                    }) | Out-Null
                }
            }
        }
    }

    $canonicalProfiles = $canonicalSet.layoutProfiles
    $draftProfiles = $draftSet.layoutProfiles

    if ($null -ne $canonicalProfiles -and $null -ne $draftProfiles) {
        for ($profileIndex = 0; $profileIndex -lt [Math]::Min(@($canonicalProfiles).Count, @($draftProfiles).Count); $profileIndex++) {
            $canonicalProfile = @($canonicalProfiles)[$profileIndex]
            $draftProfile = @($draftProfiles)[$profileIndex]
            $profileId = [string](Get-DevWSProperty -Object $draftProfile -Name 'id')
            $canonicalLayouts = $canonicalProfile.layouts
            $draftLayouts = $draftProfile.layouts

            if ($null -eq $canonicalLayouts -or $null -eq $draftLayouts) {
                continue
            }

            foreach ($property in @($canonicalLayouts.PSObject.Properties)) {
                $itemId = [string]$property.Name
                $beforeRect = Get-DevWSProperty -Object $canonicalLayouts -Name $itemId
                $afterRect = Get-DevWSProperty -Object $draftLayouts -Name $itemId

                if (-not (Test-EditorJsonEqual -Left $beforeRect -Right $afterRect)) {
                    $diff.Add([pscustomobject][ordered]@{
                        setId  = $SetId
                        itemId = $itemId
                        scope  = "profile:$profileId"
                        field  = "layouts.$itemId"
                        before = $beforeRect
                        after  = $afterRect
                    }) | Out-Null
                }
            }
        }
    }

    return @($diff.ToArray())
}

function Get-EditorWarningReviewKey {
    param([Parameter(Mandatory)]$Warning)

    $details = Get-DevWSProperty -Object $Warning -Name 'details'

    return [pscustomobject][ordered]@{
        id              = [string](Get-DevWSProperty -Object $Warning -Name 'id')
        code            = [string](Get-DevWSProperty -Object $Warning -Name 'code')
        setId           = [string](Get-DevWSProperty -Object $details -Name 'setId')
        itemId          = [string](Get-DevWSProperty -Object $details -Name 'itemId')
        profileId       = [string](Get-DevWSProperty -Object $details -Name 'profileId')
        identity        = [string](Get-DevWSProperty -Object $details -Name 'identity')
        instance        = [string](Get-DevWSProperty -Object $details -Name 'instance')
        reason          = [string](Get-DevWSProperty -Object $details -Name 'reason')
        relativeStatus  = [string](Get-DevWSProperty -Object $details -Name 'relativeStatus')
        placementStatus = [string](Get-DevWSProperty -Object $details -Name 'placementStatus')
        placementReason = [string](Get-DevWSProperty -Object $details -Name 'placementReason')
    }
}

function Get-EditorWarningReview {
    param(
        [object[]]$Warnings = @(),
        [Parameter(Mandatory)][string]$BaseSha256,
        [AllowNull()][string]$TopologyFingerprint = $null,
        [bool]$HasChanges = $false
    )

    $acknowledgementWarnings = @($Warnings | Where-Object {
        [bool](Get-DevWSProperty -Object $_ -Name 'requiresAcknowledgement') -and
        [string](Get-DevWSProperty -Object $_ -Name 'code') -cne 'deferred-qualification'
    })

    if (-not $HasChanges -or $acknowledgementWarnings.Count -eq 0) {
        return [pscustomobject][ordered]@{
            baseSha256             = $BaseSha256
            topologyFingerprint    = $TopologyFingerprint
            warningIds             = @()
            warningDigest          = $null
            requiresAcknowledgement = $false
            reviewToken            = $null
        }
    }

    $warningIds = [System.Collections.Generic.List[string]]::new()
    $keysById = @{}

    foreach ($warning in $acknowledgementWarnings) {
        $id = [string](Get-DevWSProperty -Object $warning -Name 'id')
        if ($keysById.ContainsKey($id)) {
            continue
        }

        $warningIds.Add($id) | Out-Null
        $keysById[$id] = Get-EditorWarningReviewKey -Warning $warning
    }

    $warningIds.Sort([System.StringComparer]::Ordinal)
    $keys = @($warningIds | ForEach-Object { $keysById[$_] })
    $keyJson = ConvertTo-Json -InputObject @($keys) -Compress -Depth 12
    $digestBytes = [System.Text.Encoding]::UTF8.GetBytes($keyJson)
    $warningDigest = Get-EditorSha256Hex -Bytes $digestBytes
    $tokenSource = "devws-editor/1`n$BaseSha256`n$([string]$TopologyFingerprint)`n$warningDigest"
    $reviewToken = Get-EditorSha256Hex -Bytes ([System.Text.Encoding]::UTF8.GetBytes($tokenSource))

    return [pscustomobject][ordered]@{
        baseSha256             = $BaseSha256
        topologyFingerprint    = $TopologyFingerprint
        warningIds             = @($warningIds.ToArray())
        warningDigest          = $warningDigest
        requiresAcknowledgement = $true
        reviewToken            = $reviewToken
    }
}

function Get-EditorSaveConfirmation {
    # Classify the post-commit re-read. A failed or contradictory re-read is
    # uncertain, never a claim that the file stayed unchanged.
    param(
        [Parameter(Mandatory)]$Snapshot,
        $AfterSnapshot,
        [bool]$Changed = $true,
        [AllowNull()][string]$WrittenSha256 = $null
    )

    if ($null -eq $AfterSnapshot -or -not [bool]$AfterSnapshot.Ok -or
        -not [bool]$AfterSnapshot.Valid -or [string]::IsNullOrWhiteSpace([string]$AfterSnapshot.Sha256)) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Code    = 'save-outcome-uncertain'
            Message = 'The save was submitted, but the persisted configuration could not be re-read and validated.'
            Details = [ordered]@{ observedPath = [string]$Snapshot.Location.Path }
            Result  = $null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($WrittenSha256) -and
        [string]$AfterSnapshot.Sha256 -cne $WrittenSha256) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Code    = 'save-outcome-uncertain'
            Message = 'The save was submitted, but the persisted bytes do not match the validated temporary write.'
            Details = [ordered]@{
                observedSha256 = [string]$AfterSnapshot.Sha256
                writtenSha256  = $WrittenSha256
                canonicalPath  = [string]$Snapshot.Location.Path
            }
            Result  = $null
        }
    }

    if ([string]$AfterSnapshot.Sha256 -ceq [string]$Snapshot.Sha256) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Code    = 'save-outcome-uncertain'
            Message = 'The save was submitted, but the persisted revision still matches the base revision.'
            Details = [ordered]@{
                observedSha256 = [string]$AfterSnapshot.Sha256
                canonicalPath  = [string]$Snapshot.Location.Path
            }
            Result  = $null
        }
    }

    return [pscustomobject][ordered]@{
        Ok      = $true
        Code    = $null
        Message = $null
        Details = $null
        Result  = [pscustomobject][ordered]@{
            saved          = $true
            changed        = $Changed
            previousSha256 = [string]$Snapshot.Sha256
            newSha256      = [string]$AfterSnapshot.Sha256
            canonicalPath  = [string]$Snapshot.Location.Path
        }
    }
}

function Get-EditorPreviewFailure {
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
        Warnings = @()
    }
}

function Get-EditorPreviewCore {
    # Pure preview composition over the canonical/draft documents and one
    # topology snapshot. The backend owns file reads and structural
    # validation; this helper owns the allowlist, diff, projections, and
    # review binding.
    param(
        [Parameter(Mandatory)]$CanonicalConfig,
        [Parameter(Mandatory)]$DraftConfig,
        [Parameter(Mandatory)][string]$SetId,
        $Topology,
        [Parameter(Mandatory)][string]$BaseSha256,
        [Parameter(Mandatory)][string]$CurrentSha256,
        [AllowNull()][string]$BaseTopologyFingerprint = $null
    )

    $audit = Get-EditorDraftAudit -CanonicalConfig $CanonicalConfig -DraftConfig $DraftConfig -SetId $SetId

    if (-not [bool]$audit.Ok) {
        return Get-EditorPreviewFailure -Code ([string]$audit.Code) -Message ([string]$audit.Message) -Details $audit.Details
    }

    $topologyAvailable = $null -ne $Topology -and [bool](Get-DevWSProperty -Object $Topology -Name 'Available')
    $identityComplete = $topologyAvailable -and [bool](Get-DevWSProperty -Object $Topology -Name 'IdentityComplete')
    $correlationComplete = $topologyAvailable -and [bool](Get-DevWSProperty -Object $Topology -Name 'CorrelationComplete')
    $actualFingerprint = if ($topologyAvailable) { [string](Get-DevWSProperty -Object $Topology -Name 'Fingerprint') } else { $null }
    $requiresTopology = [bool]$audit.RequiresTopology

    if ($requiresTopology) {
        if (-not $topologyAvailable) {
            return Get-EditorPreviewFailure -Code 'topology-unavailable' -Message 'The draft changes relative or profile geometry, but the monitor topology is unavailable.'
        }

        if (-not $identityComplete -or -not $correlationComplete) {
            return Get-EditorPreviewFailure -Code 'topology-incomplete' -Message 'The draft changes relative or profile geometry, but the monitor topology is incomplete.'
        }

        if ([string]::IsNullOrWhiteSpace($BaseTopologyFingerprint)) {
            return Get-EditorPreviewFailure -Code 'request-invalid' -Message "preview 'baseTopologyFingerprint' is required for relative/profile changes." -Details ([ordered]@{
                reason = 'topology-fingerprint-required'
            })
        }

        if ([string]::IsNullOrWhiteSpace($actualFingerprint)) {
            return Get-EditorPreviewFailure -Code 'topology-unavailable' -Message 'The monitor topology has no fingerprint to compare.'
        }

        if ($actualFingerprint -cne $BaseTopologyFingerprint) {
            return Get-EditorPreviewFailure -Code 'topology-changed' -Message 'The monitor topology changed since the draft was created.' -Details ([ordered]@{
                expectedFingerprint = $BaseTopologyFingerprint
                actualFingerprint   = $actualFingerprint
            })
        }
    }
    elseif ($topologyAvailable -and -not [string]::IsNullOrWhiteSpace($BaseTopologyFingerprint) -and
        $actualFingerprint -cne $BaseTopologyFingerprint) {
        return Get-EditorPreviewFailure -Code 'topology-changed' -Message 'The monitor topology changed since the draft was created.' -Details ([ordered]@{
            expectedFingerprint = $BaseTopologyFingerprint
            actualFingerprint   = $actualFingerprint
        })
    }

    try {
        $canonicalSet = Resolve-DevWSTargetSet -Config $CanonicalConfig -Set $SetId
        $draftSet = Resolve-DevWSTargetSet -Config $DraftConfig -Set $SetId
    }
    catch {
        return Get-EditorPreviewFailure -Code 'set-not-found' -Message $_.Exception.Message -Details ([ordered]@{ setId = $SetId })
    }

    $savedProjection = Get-EditorProjection `
        -Config $CanonicalConfig `
        -Set $canonicalSet `
        -Topology $Topology `
        -ConfigRevision $CurrentSha256

    $draftProjection = Get-EditorProjection `
        -Config $DraftConfig `
        -Set $draftSet `
        -Topology $Topology `
        -ConfigRevision $BaseSha256

    $warnings = @($draftProjection.warnings)
    $diff = @($audit.Diff)
    $review = Get-EditorWarningReview `
        -Warnings $warnings `
        -BaseSha256 $BaseSha256 `
        -TopologyFingerprint $(if ($topologyAvailable) { $actualFingerprint } else { $null }) `
        -HasChanges:($diff.Count -gt 0)

    $result = [pscustomobject][ordered]@{
        baseSha256        = $BaseSha256
        currentSha256     = $CurrentSha256
        baseMatches       = ($BaseSha256 -ceq $CurrentSha256)
        setId             = $SetId
        topologyFingerprint = if ($topologyAvailable) { $actualFingerprint } else { $null }
        savedSet          = $savedProjection.set
        draftSet          = $draftProjection.set
        diff              = @($diff)
        review            = $review
    }

    return [pscustomobject][ordered]@{
        Ok      = $true
        Code    = $null
        Message = $null
        Details = $null
        Result  = $result
        Warnings = @($warnings)
    }
}
