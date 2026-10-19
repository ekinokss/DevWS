# DevWS Phase 8 app ownership primitives.
#
# Ownership identity is encoded in the Win32 window property NAME:
#
#     DevWS.Owner.v1.<lower-set-id>/<lower-item-id>
#
# The property value is only the pointer-sized sentinel (IntPtr)1. No
# process-local memory is stored in the property value, so ownership survives
# the setter process exiting and disappears with the HWND itself. There is no
# durable ownership database and no generated app instanceId.
#
# The Phase 8 ownership proof-of-concept validated this mechanism on the real
# machine on 2026-10-01: an exact top-level application HWND can be tagged,
# a fresh process can read the tag after the setter exited, two simultaneously
# live windows can carry different scoped ownership keys, and destroying the
# HWND removes the practical ownership.
#
# Required libraries (dot-source first): devws-config.ps1
# (Test-DevWSStableIdSyntax) and devws-native.ps1 (shared native runtime).

$script:DevWSAppOwnershipPropertyPrefix = "DevWS.Owner.v1."
$script:DevWSAppOwnershipSentinel = [IntPtr]::new(1)

function Initialize-DevWSAppOwnershipNative {
    # Guarded subsystem access to the shared native runtime. Repeated
    # dot-sourcing or repeated initialization is a type-presence no-op.
    if ($null -ne ([System.Management.Automation.PSTypeName]'DevWSAppOwnershipNative').Type) {
        return
    }

    Initialize-DevWSNativeRuntime
}

function Get-DevWSAppOwnershipWin32ErrorText {
    param([int]$Code)

    if ($Code -le 0) {
        return ""
    }

    try {
        return ([System.ComponentModel.Win32Exception]::new($Code)).Message
    }
    catch {
        return ""
    }
}

function ConvertTo-DevWSAppOwnershipId {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Id,
        [Parameter(Mandatory)]
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        throw "App ownership requires a non-empty $Label."
    }

    if ($Id -match '[\r\n]') {
        throw "App ownership $Label must not contain newline characters."
    }

    if ($Id.Contains('/')) {
        throw "App ownership $Label '$Id' must not contain '/': a scoped identity uses exactly one '/' between the set id and the item id."
    }

    if (-not (Test-DevWSStableIdSyntax -Id $Id)) {
        throw "App ownership $Label '$Id' contains unsupported characters. Ownership ids use the DevWS stable-id character family (letters, digits, '.', '_' and '-')."
    }

    return $Id.ToLowerInvariant()
}

function Get-DevWSAppOwnershipPropertyName {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ItemId
    )

    # Deterministic invariant-lowercase property name. DevWS set/item ids are
    # case-insensitive, so equivalent config references must never produce
    # different Win32 property keys.
    $normalizedSet  = ConvertTo-DevWSAppOwnershipId -Id $SetId -Label "set id"
    $normalizedItem = ConvertTo-DevWSAppOwnershipId -Id $ItemId -Label "item id"

    return "$($script:DevWSAppOwnershipPropertyPrefix)$normalizedSet/$normalizedItem"
}

function Set-DevWSAppOwnership {
    param(
        [Parameter(Mandatory)]
        [long]$Hwnd,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ItemId
    )

    $propertyName = Get-DevWSAppOwnershipPropertyName -SetId $SetId -ItemId $ItemId

    Initialize-DevWSAppOwnershipNative

    if ($Hwnd -le 0) {
        throw "Cannot set app ownership '$propertyName': HWND $Hwnd is not a valid window handle."
    }

    $handle = [IntPtr]$Hwnd

    if (-not [DevWSAppOwnershipNative]::IsWindow($handle)) {
        throw "Cannot set app ownership '$propertyName': HWND $Hwnd no longer exists."
    }

    if (-not [DevWSAppOwnershipNative]::SetPropW($handle, $propertyName, $script:DevWSAppOwnershipSentinel)) {
        $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $text = Get-DevWSAppOwnershipWin32ErrorText -Code $code
        throw "Could not set app ownership '$propertyName' on HWND $Hwnd (Win32 error ${code}: $text)."
    }

    $readBack = [DevWSAppOwnershipNative]::GetPropW($handle, $propertyName)

    if (([long]$readBack) -ne ([long]$script:DevWSAppOwnershipSentinel)) {
        $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $text = Get-DevWSAppOwnershipWin32ErrorText -Code $code
        throw "App ownership '$propertyName' was not verified on HWND $Hwnd after SetPropW (read back $([long]$readBack), Win32 error ${code}: $text)."
    }

    return $propertyName
}

function Test-DevWSAppOwnership {
    param(
        [Parameter(Mandatory)]
        [long]$Hwnd,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ItemId
    )

    $propertyName = Get-DevWSAppOwnershipPropertyName -SetId $SetId -ItemId $ItemId

    if ($Hwnd -le 0) {
        return $false
    }

    Initialize-DevWSAppOwnershipNative

    $handle = [IntPtr]$Hwnd

    if (-not [DevWSAppOwnershipNative]::IsWindow($handle)) {
        return $false
    }

    return (([long][DevWSAppOwnershipNative]::GetPropW($handle, $propertyName)) -eq ([long]$script:DevWSAppOwnershipSentinel))
}

function Remove-DevWSAppOwnership {
    param(
        [Parameter(Mandatory)]
        [long]$Hwnd,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ItemId
    )

    $propertyName = Get-DevWSAppOwnershipPropertyName -SetId $SetId -ItemId $ItemId

    $result = [ordered]@{
        PropertyName = $propertyName
        Hwnd         = $Hwnd
        Result       = $null
        Removed      = $false
    }

    if ($Hwnd -le 0) {
        $result.Result = "window-gone"
        return [pscustomobject]$result
    }

    Initialize-DevWSAppOwnershipNative

    $handle = [IntPtr]$Hwnd

    if (-not [DevWSAppOwnershipNative]::IsWindow($handle)) {
        $result.Result = "window-gone"
        return [pscustomobject]$result
    }

    $existing = [DevWSAppOwnershipNative]::GetPropW($handle, $propertyName)

    if (([long]$existing) -eq 0) {
        $result.Result = "absent"
        return [pscustomobject]$result
    }

    $removed = [DevWSAppOwnershipNative]::RemovePropW($handle, $propertyName)

    if (([long]$removed) -eq 0) {
        $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()

        # A window can disappear between IsWindow and RemovePropW; report that
        # as window-gone instead of a hard failure.
        if ($code -eq 1400) {
            $result.Result = "window-gone"
            return [pscustomobject]$result
        }

        $text = Get-DevWSAppOwnershipWin32ErrorText -Code $code
        throw "Could not remove app ownership '$propertyName' from HWND $Hwnd (Win32 error ${code}: $text)."
    }

    $after = [DevWSAppOwnershipNative]::GetPropW($handle, $propertyName)

    if (([long]$after) -ne 0) {
        throw "App ownership '$propertyName' is still present on HWND $Hwnd after RemovePropW."
    }

    $result.Result  = "removed"
    $result.Removed = $true

    return [pscustomobject]$result
}

function Get-DevWSAppOwnershipDescriptors {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Candidates
    )

    # Invariant normalization of the configured dedicated identities: property
    # names are built once per probe so the per-HWND ownership reader only does
    # IsWindow + GetPropW. Accepts the same candidate shapes as
    # Get-DevWSAppOwnership and deduplicates identical property names in order.
    $descriptors = [System.Collections.Generic.List[object]]::new()
    $seenNames   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) {
            throw "App ownership candidates must not contain null entries."
        }

        $candidateSetId  = $null
        $candidateItemId = $null

        if ($candidate -is [string]) {
            $separatorIndex = $candidate.IndexOf('/')

            if ($separatorIndex -lt 0 -or $separatorIndex -ne $candidate.LastIndexOf('/')) {
                throw "App ownership candidate '$candidate' is not a scoped identity '<set>/<item>'."
            }

            $candidateSetId  = $candidate.Substring(0, $separatorIndex)
            $candidateItemId = $candidate.Substring($separatorIndex + 1)
        }
        else {
            $candidateSetId  = [string](Get-DevWSProperty -Object $candidate -Name "SetId")
            $candidateItemId = [string](Get-DevWSProperty -Object $candidate -Name "ItemId")
        }

        $propertyName = Get-DevWSAppOwnershipPropertyName -SetId $candidateSetId -ItemId $candidateItemId

        if (-not $seenNames.Add($propertyName)) {
            continue
        }

        $descriptors.Add([pscustomobject]@{
            SetId        = $candidateSetId
            ItemId       = $candidateItemId
            PropertyName = $propertyName
        }) | Out-Null
    }

    return $descriptors.ToArray()
}

function Get-DevWSAppOwnershipFromDescriptors {
    param(
        [Parameter(Mandatory)]
        [long]$Hwnd,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Descriptors
    )

    # Bounded ownership lookup with precomputed property descriptors. Only the
    # supplied configured keys are checked; nothing is discovered from the
    # window itself.
    if ($Hwnd -le 0) {
        return $null
    }

    Initialize-DevWSAppOwnershipNative

    $handle = [IntPtr]$Hwnd

    if (-not [DevWSAppOwnershipNative]::IsWindow($handle)) {
        return $null
    }

    $foundOwners = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in @($Descriptors)) {
        $value = [DevWSAppOwnershipNative]::GetPropW($handle, $entry.PropertyName)

        if (([long]$value) -ne 0) {
            $foundOwners.Add($entry)
        }
    }

    if ($foundOwners.Count -eq 0) {
        return $null
    }

    if ($foundOwners.Count -gt 1) {
        $names = @($foundOwners | ForEach-Object { $_.PropertyName }) -join ", "
        throw "HWND $Hwnd carries multiple DevWS ownership properties ($names). Refusing to guess an owner."
    }

    return [pscustomobject]@{
        SetId        = [string]$foundOwners[0].SetId
        ItemId       = [string]$foundOwners[0].ItemId
        PropertyName = [string]$foundOwners[0].PropertyName
        Hwnd         = $Hwnd
    }
}

function Get-DevWSAppOwnership {
    param(
        [Parameter(Mandatory)]
        [long]$Hwnd,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Candidates
    )

    # Public primitive: normalize the supplied bounded candidates into property
    # descriptors, then read the window's configured ownership keys. The probe
    # builds descriptors once and calls Get-DevWSAppOwnershipFromDescriptors
    # directly for every HWND.
    $descriptors = Get-DevWSAppOwnershipDescriptors -Candidates $Candidates

    return (Get-DevWSAppOwnershipFromDescriptors -Hwnd $Hwnd -Descriptors $descriptors)
}
