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
