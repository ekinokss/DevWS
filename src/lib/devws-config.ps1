# DevWS v3 configuration core.
#
# Responsibilities:
#   - resolve the active config file (DEVWS_CONFIG -> user config -> bundled default);
#   - load and validate the v3 workspace-set model;
#   - recognize the frozen v2 schema for installer-owned migration only;
#   - save config atomically after validating the serialized result;
#   - ordered selection and stable-ID / numeric reference resolution, scoped to a
#     resolved set (unscoped callers operate on defaultSet).
#
# Schemas:
#   v3 (runtime): { version, defaultSet, bindings, sets: [ { id, windows } ] }
#   v2 (recognition/migration only): { version, windows }
#
# Sources of truth:
#   docs/configuration.md  (schema and validation rules)
#   docs/architecture.md   (identity, failure rules)

# Path helpers (config location, runtime root, tool paths, install layout) live
# in devws-paths.ps1 and must be loaded first.

function Find-DevWSBundledDefaultConfig {
    param(
        [Parameter(Mandatory)]
        [string]$StartPath
    )

    $dir = $StartPath

    for ($i = 0; $i -lt 6; $i++) {
        $candidate = Join-Path $dir "config\workspace.default.json"

        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }

        $parent = [System.IO.Path]::GetDirectoryName($dir)

        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $dir) {
            break
        }

        $dir = $parent
    }

    return $null
}

function Resolve-DevWSConfigLocation {
    param(
        [string]$StartPath = ".",
        [string]$Override
    )

    $bundled   = Find-DevWSBundledDefaultConfig -StartPath $StartPath
    $canonical = Get-DevWSCanonicalConfigPath

    $selected = $null
    $source   = $null

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        if (-not (Test-Path -LiteralPath $Override -PathType Leaf)) {
            throw "Config file passed explicitly does not exist: $Override"
        }

        $selected = (Resolve-Path -LiteralPath $Override).Path
        $source   = "override"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:DEVWS_CONFIG)) {
        if (-not (Test-Path -LiteralPath $env:DEVWS_CONFIG -PathType Leaf)) {
            throw "Config file from DEVWS_CONFIG does not exist: $env:DEVWS_CONFIG"
        }

        $selected = (Resolve-Path -LiteralPath $env:DEVWS_CONFIG).Path
        $source   = "env"
    }
    elseif (Test-Path -LiteralPath $canonical -PathType Leaf) {
        $selected = (Resolve-Path -LiteralPath $canonical).Path
        $source   = "user"
    }
    elseif ($bundled) {
        $selected = $bundled
        $source   = "default"
    }
    else {
        throw "No workspace config found. Expected '$canonical' or a bundled 'config\workspace.default.json'. Run the DevWS installer or set the DEVWS_CONFIG environment variable."
    }

    $isBundled = $false

    if ($bundled -and [string]::Equals($selected, $bundled, [StringComparison]::OrdinalIgnoreCase)) {
        $isBundled = $true
    }

    $warning = $null

    if ($source -eq "default") {
        $warning = "Using the bundled default config (read-only): $selected"
    }

    return [pscustomobject]@{
        Path             = $selected
        Source           = $source
        IsBundledDefault = $isBundled
        IsWritable       = (-not $isBundled)
        Warning          = $warning
    }
}

function Assert-DevWSConfigWritable {
    param(
        [Parameter(Mandatory)]
        $Location
    )

    if (-not $Location.IsWritable) {
        throw "Refusing to modify the bundled default config '$($Location.Path)'. Copy it to '$(Get-DevWSCanonicalConfigPath)' or point DEVWS_CONFIG at a writable copy."
    }
}

function Read-DevWSConfigFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop

    try {
        return $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Invalid JSON in '$Path': $($_.Exception.Message)"
    }
}

function Get-DevWSConfig {
    param(
        [Parameter(Mandatory)]
        $Location,
        [switch]$RequireTerminalPaths
    )

    $config = Read-DevWSConfigFile -Path $Location.Path

    Assert-DevWSConfig -Config $config -Source $Location.Path -RequireTerminalPaths:$RequireTerminalPaths

    return $config
}

function Test-DevWSInteger {
    param($Value)

    if ($null -eq $Value) {
        return $false
    }

    return (
        $Value -is [int] -or
        $Value -is [long] -or
        $Value -is [int16]
    )
}

function Test-DevWSProperty {
    param($Object, [string]$Name)

    if ($null -eq $Object) {
        return $false
    }

    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-DevWSProperty {
    param($Object, [string]$Name)

    if (-not (Test-DevWSProperty -Object $Object -Name $Name)) {
        return $null
    }

    return ,$Object.PSObject.Properties[$Name].Value
}

function Throw-DevWSValidationErrors {
    param(
        [string]$Source,
        $Errors
    )

    if ($null -eq $Errors -or $Errors.Count -eq 0) {
        return
    }

    $lines = @(
        "Invalid workspace config: $Source",
        ""
    )

    foreach ($errorText in $Errors) {
        $lines += "  - $errorText"
    }

    throw ($lines -join [Environment]::NewLine)
}

# ---------------------------------------------------------------------------
# v3 set access helpers
# ---------------------------------------------------------------------------

function Test-DevWSStableIdSyntax {
    param(
        [AllowEmptyString()]
        [string]$Id
    )

    # Single source of truth for the conservative stable-identifier family
    # shared by v3 set ids, defaultSet, and v3 item ids: letters, digits, '.',
    # '_' and '-'. '/' is reserved for scoped references.
    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $false
    }

    return ($Id -match '^[A-Za-z0-9._-]+$')
}

# ---------------------------------------------------------------------------
# Pass 6C shared policy: managed configured-tab titles and per-tab effective
# paths. These are the ONLY implementations of both rules; creation, reset,
# validation, mutations, identity, and the read-only tab snapshot all call
# them.
# ---------------------------------------------------------------------------

function Get-DevWSTerminalTabTitle {
    param(
        [Parameter(Mandatory)]
        [string]$WindowId,
        [Parameter(Mandatory)]
        [int]$TabIndex
    )

    # Canonical managed configured-tab title family:
    #   tab 0  -> <windowId>            (historical exact title)
    #   tab N>0 -> <windowId>#DevWS:<N> (canonical decimal, no leading zeros)
    if ($TabIndex -lt 0) {
        throw "A configured tab index cannot be negative (got $TabIndex)."
    }

    if ($TabIndex -eq 0) {
        return $WindowId
    }

    return ("{0}#DevWS:{1}" -f $WindowId, $TabIndex)
}

function Resolve-DevWSTerminalTabTitle {
    param(
        [Parameter(Mandatory)]
        [string]$WindowId,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Title
    )

    # Exact parser for the managed configured-tab title family. Case handling
    # matches the existing case-insensitive windowId identity behavior. The
    # suffix grammar is exactly [1-9][0-9]*: 0, leading zeros, signs, empty
    # suffixes, and trailing text are all rejected. No substring guessing.
    $unmanaged = [pscustomobject]@{ IsManaged = $false; TabIndex = $null }

    if ([string]::IsNullOrWhiteSpace($WindowId) -or [string]::IsNullOrWhiteSpace($Title)) {
        return $unmanaged
    }

    if ($Title -ieq $WindowId) {
        return [pscustomobject]@{ IsManaged = $true; TabIndex = 0 }
    }

    $prefix = $WindowId + "#DevWS:"

    if ($Title.Length -le $prefix.Length -or -not $Title.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $unmanaged
    }

    $suffix = $Title.Substring($prefix.Length)

    if ($suffix -notmatch '^[1-9][0-9]*$') {
        return $unmanaged
    }

    # Live UI Automation tab names are external input: an arbitrarily long
    # decimal passes lexical validation but can exceed System.Int32. Bounded,
    # non-throwing parse; overflow is simply not a managed title.
    $tabIndex = 0

    if (-not [int]::TryParse($suffix, [ref]$tabIndex)) {
        return $unmanaged
    }

    return [pscustomobject]@{ IsManaged = $true; TabIndex = $tabIndex }
}

function Test-DevWSTerminalTitleFamily {
    param(
        [Parameter(Mandatory)]
        [string]$WindowId,
        $TabNames
    )

    # True when ANY name in the collection is a canonical managed title for
    # the requested windowId. Works with the UI Automation name HashSet and
    # plain string arrays alike.
    if ($null -eq $TabNames) {
        return $false
    }

    foreach ($name in @($TabNames)) {
        $resolved = Resolve-DevWSTerminalTabTitle -WindowId $WindowId -Title ([string]$name)

        if ([bool]$resolved.IsManaged) {
            return $true
        }
    }

    return $false
}

function Get-DevWSTerminalTabEffectivePath {
    param(
        [Parameter(Mandatory)]
        $Terminal,
        [Parameter(Mandatory)]
        [int]$TabIndex
    )

    # The ONE effective-path rule: a configured tab's explicit override when
    # present, otherwise the terminal default. Works with parsed PSCustomObject
    # configs and with raw hashtable tab definitions alike; never duplicated
    # per caller.
    if ($TabIndex -lt 0) {
        throw "A configured tab index cannot be negative (got $TabIndex)."
    }

    $tabsValue = $Terminal.tabs
    $tabs      = @()

    if ($null -ne $tabsValue) {
        $tabs = @($tabsValue)
    }

    if ($TabIndex -ge $tabs.Count) {
        $terminalId = [string]$Terminal.id
        throw "Configured tab index $TabIndex does not exist on terminal '$terminalId' ($($tabs.Count) tab(s))."
    }

    $tab = $tabs[$TabIndex]

    if ($null -ne $tab) {
        $override = [string]$tab.path

        if (-not [string]::IsNullOrWhiteSpace($override)) {
            return $override
        }
    }

    return [string]$Terminal.path
}

function Get-DevWSSets {
    param(
        [Parameter(Mandatory)]
        $Config
    )

    return @($Config.sets)
}

function Get-DevWSBindings {
    param(
        [Parameter(Mandatory)]
        $Config
    )

    $bindings = Get-DevWSProperty -Object $Config -Name "bindings"

    if ($bindings -isnot [array]) {
        return @()
    }

    return @($bindings)
}

function Get-DevWSDefaultSet {
    param(
        [Parameter(Mandatory)]
        $Config
    )

    $defaultId = [string](Get-DevWSProperty -Object $Config -Name "defaultSet")

    foreach ($set in @(Get-DevWSSets -Config $Config)) {
        if ($null -ne $set -and ([string]$set.id) -ieq $defaultId) {
            return $set
        }
    }

    $known = @(Get-DevWSSets -Config $Config | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.id }) -join ", "
    throw "The workspace config defaultSet '$defaultId' does not match a configured set. Configured sets: $known"
}

function Resolve-DevWSSet {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Reference
    )

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "A set id is required."
    }

    foreach ($set in @(Get-DevWSSets -Config $Config)) {
        if ($null -ne $set -and ([string]$set.id) -ieq $Reference) {
            return $set
        }
    }

    $known = @(Get-DevWSSets -Config $Config | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.id }) -join ", "
    throw "Unknown workspace set '$Reference'. Configured sets: $known"
}

function Resolve-DevWSTargetSet {
    param(
        [Parameter(Mandatory)]
        $Config,
        $Set
    )

    # Single set-resolution entry point for every set-aware helper: omit the set
    # to target defaultSet (the compatibility bridge), pass an id string or an
    # already-resolved set object.
    if ($null -eq $Set) {
        return Get-DevWSDefaultSet -Config $Config
    }

    if ($Set -is [string]) {
        return Resolve-DevWSSet -Config $Config -Reference $Set
    }

    return $Set
}

function Resolve-DevWSLifecycleTarget {
    param(
        [Parameter(Mandatory)]
        $Config,
        [AllowEmptyString()]
        [string]$SetId
    )

    # One shared optional-set resolver for lifecycle commands. An omitted set
    # means defaultSet; an explicit set resolves case-insensitively and NEVER
    # changes config.defaultSet. There is no persistent active-set state.
    if ([string]::IsNullOrWhiteSpace($SetId)) {
        $set = Get-DevWSDefaultSet -Config $Config

        return [pscustomobject]@{
            Set   = $set
            SetId = [string]$set.id
        }
    }

    $resolved = Resolve-DevWSSet -Config $Config -Reference $SetId

    return [pscustomobject]@{
        Set   = $resolved
        SetId = [string]$resolved.id
    }
}

function Resolve-DevWSConfigReference {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Reference,
        [string]$CommandName = "this command"
    )

    # Central scoped-reference model for config item references. Set ids and
    # v3 item ids cannot contain '/', so:
    #   item-a              -> defaultSet item 'item-a'
    #   set-b/item-a        -> item 'item-a' in set 'set-b'
    # Malformed forms (empty side, multiple separators, unknown set) are
    # rejected instead of reinterpreted.
    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "Usage: $CommandName requires an item reference (an id or <set>/<item>)."
    }

    $separatorIndex = $Reference.IndexOf('/')

    if ($separatorIndex -lt 0) {
        $defaultSet = Get-DevWSDefaultSet -Config $Config

        return [pscustomobject][ordered]@{
            Set       = $defaultSet
            SetId     = [string]$defaultSet.id
            ItemId    = $Reference
            Scoped    = $false
            Reference = $Reference
        }
    }

    if ($separatorIndex -ne $Reference.LastIndexOf('/')) {
        throw "Invalid item reference '$Reference': expected '<set>/<item>' with exactly one '/'."
    }

    $setPart  = $Reference.Substring(0, $separatorIndex)
    $itemPart = $Reference.Substring($separatorIndex + 1)

    if ([string]::IsNullOrWhiteSpace($setPart)) {
        throw "Invalid item reference '$Reference': the set id before '/' is empty."
    }

    if ([string]::IsNullOrWhiteSpace($itemPart)) {
        throw "Invalid item reference '$Reference': the item id after '/' is empty."
    }

    $set = Resolve-DevWSSet -Config $Config -Reference $setPart

    return [pscustomobject][ordered]@{
        Set       = $set
        SetId     = [string]$set.id
        ItemId    = $itemPart
        Scoped    = $true
        Reference = $Reference
    }
}

function Get-DevWSItemDisplayLabel {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ItemId,
        [switch]$Scoped
    )

    # One small helper so user-facing output can disambiguate sets without
    # repeating string assembly. Default-set items keep their familiar bare-id
    # output unless the command explicitly used a scoped reference.
    $defaultSet = Get-DevWSDefaultSet -Config $Config

    if ($Scoped -or -not ($SetId -ieq ([string]$defaultSet.id))) {
        return "$SetId/$ItemId"
    }

    return $ItemId
}

function Get-DevWSWindows {
    param(
        [Parameter(Mandatory)]
        $Config,
        [ValidateSet("terminal", "app")]
        [string]$Type,
        [switch]$EnabledOnly,
        $Set
    )

    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set

    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($target.windows)) {
        if ($null -eq $item) {
            continue
        }

        if ($Type -and $item.type -ne $Type) {
            continue
        }

        if ($EnabledOnly -and -not [bool]$item.enabled) {
            continue
        }

        $result.Add($item)
    }

    return $result.ToArray()
}

function Get-DevWSAppInstanceMode {
    param(
        [Parameter(Mandatory)]
        $Item
    )

    # Phase 8 transitional vocabulary. Returns the explicit normalized mode
    # ('dedicated' or 'shared') when an app item carries 'instanceMode', and
    # $null when the field is absent. A missing mode is NOT an implicit mode:
    # callers must never guess shared/dedicated behavior for it. Terminals
    # never carry a mode.
    if ((Get-DevWSProperty -Object $Item -Name "type") -ne "app") {
        return $null
    }

    if (-not (Test-DevWSProperty -Object $Item -Name "instanceMode")) {
        return $null
    }

    return ([string](Get-DevWSProperty -Object $Item -Name "instanceMode")).ToLowerInvariant()
}

function Resolve-DevWSInstanceModeValue {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Mode
    )

    # CLI/config-facing canonicalization for an explicit instance mode. Config
    # values are stored lowercase; user input may use any casing.
    if ([string]::IsNullOrWhiteSpace($Mode)) {
        throw "An instance mode is required. Use 'dedicated' or 'shared'."
    }

    $canonicalMode = $Mode.ToLowerInvariant()

    if ($canonicalMode -notin @("dedicated", "shared")) {
        throw "Unknown instance mode '$Mode'. Use 'dedicated' or 'shared'."
    }

    return $canonicalMode
}

function Get-DevWSSharedAppDefinitionDifference {
    param(
        [Parameter(Mandatory)]
        $First,
        [Parameter(Mandatory)]
        $Second
    )

    # Deterministic strict equivalence for same-id shared apps: identity and
    # launch fields must match exactly (case-sensitive, order-sensitive). Layout
    # and enabled state are set-local and deliberately not compared. Returns the
    # first differing field name, or $null when equivalent.
    foreach ($field in @("match.kind", "match.value", "launch.kind", "launch.value")) {
        $parts = $field -split "\."

        $leftObject  = Get-DevWSProperty -Object $First  -Name $parts[0]
        $rightObject = Get-DevWSProperty -Object $Second -Name $parts[0]

        $leftValue  = [string](Get-DevWSProperty -Object $leftObject  -Name $parts[1])
        $rightValue = [string](Get-DevWSProperty -Object $rightObject -Name $parts[1])

        if ($leftValue -cne $rightValue) {
            return $field
        }
    }

    $leftLaunchValue  = Get-DevWSProperty -Object (Get-DevWSProperty -Object $First  -Name "launch") -Name "args"
    $rightLaunchValue = Get-DevWSProperty -Object (Get-DevWSProperty -Object $Second -Name "launch") -Name "args"

    $leftArgs  = @()
    $rightArgs = @()

    if ($null -ne $leftLaunchValue)  { $leftArgs  = @($leftLaunchValue) }
    if ($null -ne $rightLaunchValue) { $rightArgs = @($rightLaunchValue) }

    $leftJson  = ConvertTo-Json -InputObject @($leftArgs)  -Depth 5 -Compress
    $rightJson = ConvertTo-Json -InputObject @($rightArgs) -Depth 5 -Compress

    if ($leftJson -cne $rightJson) {
        return "launch.args"
    }

    return $null
}

# ---------------------------------------------------------------------------
# Structural validation
# ---------------------------------------------------------------------------

function Add-DevWSBindingValidationErrors {
    param(
        [Parameter(Mandatory)]
        $Errors,
        [AllowNull()]
        $Bindings,
        [Parameter(Mandatory)]
        $KnownSetIds
    )

    if ($null -eq $Bindings -or $Bindings -isnot [array]) {
        return
    }

    $seenHotkeys = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::Ordinal)

    for ($b = 0; $b -lt $Bindings.Count; $b++) {
        $binding = $Bindings[$b]
        $label   = "bindings[$b]"

        if ($null -eq $binding -or $binding -isnot [System.Management.Automation.PSCustomObject]) {
            $Errors.Add("$label must be a JSON object with exactly 'hotkey' and 'setId'.")
            continue
        }

        foreach ($property in @($binding.PSObject.Properties)) {
            if ($property.Name -notin @("hotkey", "setId")) {
                $Errors.Add("$label has unknown property '$($property.Name)'. Bindings accept exactly 'hotkey' and 'setId'.")
            }
        }

        $rawHotkey = Get-DevWSProperty -Object $binding -Name "hotkey"
        $canonical = $null

        if (-not (Test-DevWSProperty -Object $binding -Name "hotkey") -or $rawHotkey -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$rawHotkey)) {
            $Errors.Add("$label is missing a non-empty string 'hotkey' like 'alt+shift+y'.")
        }
        else {
            try {
                $canonical = ConvertTo-DevWSBindingHotkey -Hotkey ([string]$rawHotkey)
            }
            catch {
                $Errors.Add("$label 'hotkey' '$rawHotkey' is invalid: $($_.Exception.Message)")
            }

            if ($null -ne $canonical) {
                if ([string]$rawHotkey -cne $canonical) {
                    $Errors.Add("$label 'hotkey' must be stored in canonical lowercase form: '$canonical' (got '$rawHotkey').")
                }
                elseif (Test-DevWSReservedBindingHotkey -Hotkey $canonical) {
                    $Errors.Add("$label 'hotkey' '$canonical' is reserved: $(Get-DevWSReservedBindingHotkeyReason -Hotkey $canonical)")
                }
                elseif ($seenHotkeys.ContainsKey($canonical)) {
                    $Errors.Add("$label 'hotkey' '$canonical' duplicates an earlier binding. One hotkey may target only one set.")
                }
                else {
                    $seenHotkeys[$canonical] = $true
                }
            }
        }

        $setId = Get-DevWSProperty -Object $binding -Name "setId"

        if (-not (Test-DevWSProperty -Object $binding -Name "setId") -or $setId -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$setId)) {
            $Errors.Add("$label is missing a non-empty string 'setId'.")
        }
        elseif (-not (Test-DevWSStableIdSyntax -Id ([string]$setId))) {
            $Errors.Add("$label 'setId' '$setId' contains unsupported characters. Set ids may only contain letters, digits, '.', '_' and '-'; '/' is reserved for scoped references.")
        }
        elseif (-not $KnownSetIds.ContainsKey([string]$setId)) {
            $Errors.Add("$label 'setId' '$setId' does not match a configured set.")
        }
    }
}

function Add-DevWSRectValidationErrors {
    # Shared absolute-rectangle validation for item.layout and topology-profile
    # layout entries. Identical messages and semantics for both callers.
    param(
        [Parameter(Mandatory)]
        $Errors,
        $Rect,
        [Parameter(Mandatory)]
        [string]$Label,
        [Parameter(Mandatory)]
        [string]$FieldLabel = "layout"
    )

    if ($null -eq $Rect -or $Rect -isnot [System.Management.Automation.PSCustomObject]) {
        $Errors.Add("$Label '$FieldLabel' must be an object with integer x, y, w, h.")
        return
    }

    foreach ($field in @("x", "y", "w", "h")) {
        if (-not (Test-DevWSProperty -Object $Rect -Name $field) -or -not (Test-DevWSInteger $Rect.$field)) {
            $Errors.Add("$Label $FieldLabel.$field must be an integer.")
        }
    }

    if ((Test-DevWSInteger $Rect.w) -and [int]$Rect.w -le 0) {
        $Errors.Add("$Label $FieldLabel.w must be greater than 0 (got $($Rect.w)).")
    }

    if ((Test-DevWSInteger $Rect.h) -and [int]$Rect.h -le 0) {
        $Errors.Add("$Label $FieldLabel.h must be greater than 0 (got $($Rect.h)).")
    }
}

function Test-DevWSFiniteNumber {
    # JSON numbers may arrive as integer or floating-point CLR types. Reject
    # booleans, strings and non-finite values; accept only finite numeric
    # values for the relative-layout fractions.
    param($Value)

    if ($null -eq $Value -or $Value -is [bool]) {
        return $false
    }

    $isNumeric = (
        $Value -is [int] -or
        $Value -is [long] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [uint32] -or
        $Value -is [uint64] -or
        $Value -is [single] -or
        $Value -is [double] -or
        $Value -is [decimal]
    )

    if (-not $isNumeric) {
        return $false
    }

    try {
        return [double]::IsFinite([double]$Value)
    }
    catch {
        return $false
    }
}

function Test-DevWSRelativeMonitorIdentitySyntax {
    # A relative anchor identity uses the same durable prefix family as the
    # topology signature: edid:<serial identity> or path:<hardwareId>/<instance>.
    # Ordinals are never accepted. Internal punctuation (including '@') is
    # allowed because the identity is not re-parsed from a signature token.
    param([AllowEmptyString()][string]$Identity)

    if ([string]::IsNullOrWhiteSpace($Identity)) {
        return $false
    }

    if ($Identity -cne $Identity.Trim()) {
        return $false
    }

    foreach ($character in $Identity.ToCharArray()) {
        if ([int]$character -lt 32 -or [int]$character -eq 127) {
            return $false
        }
    }

    if ($Identity.StartsWith("path:", [System.StringComparison]::Ordinal)) {
        $pathIdentity = $Identity.Substring(5)

        if ($pathIdentity -cne $pathIdentity.Trim()) {
            return $false
        }

        return ($pathIdentity -match '^[^/\\#\s]+/[^/\\#\s]+$')
    }

    if ($Identity.StartsWith("edid:", [System.StringComparison]::Ordinal)) {
        $serialIdentity = $Identity.Substring(5)
        return (-not [string]::IsNullOrWhiteSpace($serialIdentity) -and $serialIdentity -ceq $serialIdentity.Trim())
    }

    return $false
}

function Test-DevWSRelativeMonitorInstanceSyntax {
    # DevicePathInstance is the normalized <hardwareId>/<instance> form used by
    # the monitor topology model. It is a tie-breaker for EDID anchors, not an
    # ordinal or a path identity.
    param([AllowEmptyString()][string]$Instance)

    if ([string]::IsNullOrWhiteSpace($Instance)) {
        return $false
    }

    if ($Instance -cne $Instance.Trim()) {
        return $false
    }

    return ($Instance -match '^[^/\\#\s]+/[^/\\#\s]+$')
}

function Add-DevWSRelativeLayoutValidationErrors {
    # Additive v3 per-item relative-layout fields. Existing item properties stay
    # tolerant: this validator checks only layoutMode/layoutRelative and does
    # not introduce a general item allowlist.
    param(
        [Parameter(Mandatory)]
        $Errors,
        [Parameter(Mandatory)]
        $Item,
        [Parameter(Mandatory)]
        [string]$Label
    )

    $hasMode     = Test-DevWSProperty -Object $Item -Name "layoutMode"
    $hasRelative = Test-DevWSProperty -Object $Item -Name "layoutRelative"
    $relativeMode = $false

    if ($hasMode) {
        $mode = Get-DevWSProperty -Object $Item -Name "layoutMode"

        if ($mode -isnot [string]) {
            $Errors.Add("$Label 'layoutMode' must be the string 'absolute' or 'relative'.")
        }
        elseif ($mode -cne "absolute" -and $mode -cne "relative") {
            $Errors.Add("$Label 'layoutMode' must be exactly 'absolute' or 'relative' (got '$mode').")
        }
        elseif ($mode -ceq "relative") {
            $relativeMode = $true
        }
    }

    if ($hasRelative -and -not $relativeMode) {
        $Errors.Add("$Label 'layoutRelative' is only allowed when 'layoutMode' is 'relative'.")
        return
    }

    if ($relativeMode -and -not $hasRelative) {
        $Errors.Add("$Label 'layoutRelative' is required when 'layoutMode' is 'relative'.")
        return
    }

    if (-not $hasRelative) {
        return
    }

    $relative = Get-DevWSProperty -Object $Item -Name "layoutRelative"

    if ($null -eq $relative -or $relative -isnot [System.Management.Automation.PSCustomObject]) {
        $Errors.Add("$Label 'layoutRelative' must be an object with monitor, basis and rect.")
        return
    }

    foreach ($property in @($relative.PSObject.Properties)) {
        if ($property.Name -notin @("monitor", "basis", "rect")) {
            $Errors.Add("$Label layoutRelative has unexpected property '$($property.Name)'. Allowed: monitor, basis, rect.")
        }
    }

    $monitor = Get-DevWSProperty -Object $relative -Name "monitor"

    if ($null -eq $monitor -or $monitor -isnot [System.Management.Automation.PSCustomObject]) {
        $Errors.Add("$Label layoutRelative.monitor must be an object with identity and optional instance.")
    }
    else {
        foreach ($property in @($monitor.PSObject.Properties)) {
            if ($property.Name -notin @("identity", "instance")) {
                $Errors.Add("$Label layoutRelative.monitor has unexpected property '$($property.Name)'. Allowed: identity, instance.")
            }
        }

        $identity = Get-DevWSProperty -Object $monitor -Name "identity"

        if ($identity -isnot [string] -or -not (Test-DevWSRelativeMonitorIdentitySyntax -Identity ([string]$identity))) {
            $Errors.Add("$Label layoutRelative.monitor.identity must be a non-empty durable monitor identity beginning with 'edid:' or 'path:'.")
        }

        if (Test-DevWSProperty -Object $monitor -Name "instance") {
            $instance = Get-DevWSProperty -Object $monitor -Name "instance"

            if ($instance -isnot [string] -or -not (Test-DevWSRelativeMonitorInstanceSyntax -Instance ([string]$instance))) {
                $Errors.Add("$Label layoutRelative.monitor.instance must be a non-empty device-path instance '<hardwareId>/<instance>'.")
            }
            elseif ($identity -is [string] -and $identity.StartsWith("path:", [System.StringComparison]::Ordinal)) {
                $Errors.Add("$Label layoutRelative.monitor.instance is not allowed when monitor.identity uses the 'path:' prefix.")
            }
        }
    }

    $basis = Get-DevWSProperty -Object $relative -Name "basis"

    if ($basis -isnot [string] -or ($basis -cne "workArea" -and $basis -cne "monitor")) {
        $Errors.Add("$Label layoutRelative.basis must be exactly 'workArea' or 'monitor' (got '$basis').")
    }

    $rect = Get-DevWSProperty -Object $relative -Name "rect"

    if ($null -eq $rect -or $rect -isnot [System.Management.Automation.PSCustomObject]) {
        $Errors.Add("$Label layoutRelative.rect must be an object with finite numeric x, y, w, h.")
    }
    else {
        foreach ($property in @($rect.PSObject.Properties)) {
            if ($property.Name -notin @("x", "y", "w", "h")) {
                $Errors.Add("$Label layoutRelative.rect has unexpected property '$($property.Name)'. Allowed: x, y, w, h.")
            }
        }

        foreach ($field in @("x", "y", "w", "h")) {
            $value = Get-DevWSProperty -Object $rect -Name $field

            if (-not (Test-DevWSFiniteNumber -Value $value)) {
                $Errors.Add("$Label layoutRelative.rect.$field must be a finite number.")
            }
        }

        if ((Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $rect -Name "w")) -and [double]$rect.w -le 0) {
            $Errors.Add("$Label layoutRelative.rect.w must be greater than 0 (got $($rect.w)).")
        }

        if ((Test-DevWSFiniteNumber -Value (Get-DevWSProperty -Object $rect -Name "h")) -and [double]$rect.h -le 0) {
            $Errors.Add("$Label layoutRelative.rect.h must be greater than 0 (got $($rect.h)).")
        }
    }
}

function Add-DevWSWindowValidationErrors {
    param(
        [Parameter(Mandatory)]
        $Errors,
        [Parameter(Mandatory)]
        $Items,
        [Parameter(Mandatory)]
        [string]$LabelPrefix,
        [Parameter(Mandatory)]
        $SeenIds,
        [Parameter(Mandatory)]
        $SeenWindowIds,
        [ValidateSet("v2", "v3")]
        [string]$RuleSet = "v2",
        [switch]$AllowMissingInstanceMode
    )

    # Shared item validation for the v3 validator and the frozen v2
    # recognition path. The label prefix is either "windows" (v2) or
    # "sets[n] ('id') windows" (v3) so error messages stay unambiguous.
    # Terminal path existence is deliberately NOT checked here; it is
    # operation-scoped (see Assert-DevWSTerminalPaths), and since Pass 6C the
    # operation-scoped check validates the EFFECTIVE path of EVERY configured
    # tab (tab override when present, otherwise terminal.path).
    #
    # RuleSet selects the id policy:
    #   v2 - historical recognition rules only (frozen migration contract);
    #   v3 - additionally requires the stable-id character family and rejects
    #        digit-only app ids (numeric references stay reserved for terminal
    #        compatibility behavior).

    $supportedMatchKinds  = @("exe", "processPathContains")
    $supportedLaunchKinds = @("exe", "appId")

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $item = $Items[$i]
        $label = "$LabelPrefix[$i]"

        if ($null -eq $item -or $item -isnot [System.Management.Automation.PSCustomObject]) {
            $Errors.Add("$label must be a JSON object.")
            continue
        }

        $idText = $null

        if (-not (Test-DevWSProperty -Object $item -Name "id") -or $item.id -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item.id)) {
            $Errors.Add("$label is missing a non-empty string 'id'.")
        }
        else {
            $idText = [string]$item.id
            $label = "$LabelPrefix[$i] ('$idText')"

            if ($RuleSet -eq "v3" -and -not (Test-DevWSStableIdSyntax -Id $idText)) {
                $Errors.Add("$label 'id' contains unsupported characters. IDs may only contain letters, digits, '.', '_' and '-'; '/' is reserved for scoped references.")
            }

            if ($SeenIds.ContainsKey($idText)) {
                $Errors.Add("$label has a duplicate id. IDs are unique case-insensitively within a set.")
            }
            else {
                $SeenIds[$idText] = $true
            }
        }

        $type = Get-DevWSProperty -Object $item -Name "type"

        if ($type -notin @("terminal", "app")) {
            $Errors.Add("$label 'type' must be 'terminal' or 'app' (got '$type').")
            continue
        }

        if ($RuleSet -eq "v3" -and $null -ne $idText -and $type -eq "app" -and $idText -match '^\d+$') {
            $Errors.Add("$label app 'id' must not be digit-only. Numeric references are reserved for terminal aliases; use a descriptive id.")
        }

        if (-not (Test-DevWSProperty -Object $item -Name "enabled") -or $item.enabled -isnot [bool]) {
            $Errors.Add("$label 'enabled' must be true or false.")
        }

        # Layout is required for every item (shared absolute-rectangle rules).
        $layout = Get-DevWSProperty -Object $item -Name "layout"

        Add-DevWSRectValidationErrors -Errors $Errors -Rect $layout -Label $label -FieldLabel "layout"

        if ($RuleSet -eq "v3") {
            Add-DevWSRelativeLayoutValidationErrors -Errors $Errors -Item $item -Label $label
        }

        if ($type -eq "terminal") {
            if (-not (Test-DevWSProperty -Object $item -Name "windowId") -or $item.windowId -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item.windowId)) {
                $Errors.Add("$label 'windowId' must be a non-empty string.")
            }
            else {
                $windowId = [string]$item.windowId

                if ($SeenWindowIds.ContainsKey($windowId)) {
                    $Errors.Add("$label duplicate windowId '$windowId'. Terminal windowId values must be unique across all sets.")
                }
                else {
                    $SeenWindowIds[$windowId] = $true
                }
            }

            if (-not (Test-DevWSProperty -Object $item -Name "path") -or $item.path -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$item.path)) {
                $Errors.Add("$label 'path' must be a non-empty string.")
            }

            if (-not (Test-DevWSProperty -Object $item -Name "elevated") -or $item.elevated -isnot [bool]) {
                $Errors.Add("$label 'elevated' must be true or false.")
            }

            if ($RuleSet -eq "v3" -and (Test-DevWSProperty -Object $item -Name "instanceMode")) {
                $Errors.Add("$label is a terminal and must not define 'instanceMode'; app instance modes apply to apps only.")
            }

            $tabs = Get-DevWSProperty -Object $item -Name "tabs"

            if (-not (Test-DevWSProperty -Object $item -Name "tabs") -or $tabs -isnot [array] -or @($tabs).Count -lt 1) {
                $Errors.Add("$label 'tabs' must be an array with at least one tab.")
            }
            else {
                for ($t = 0; $t -lt $tabs.Count; $t++) {
                    $tab = $tabs[$t]
                    $tabLabel = "$label tabs[$t]"

                    if ($null -eq $tab -or $tab -isnot [System.Management.Automation.PSCustomObject]) {
                        $Errors.Add("$tabLabel must be a JSON object.")
                        continue
                    }

                    if (-not (Test-DevWSProperty -Object $tab -Name "command")) {
                        $Errors.Add("$tabLabel 'command' is required (use null for an idle PowerShell tab).")
                    }
                    elseif ($null -ne $tab.command -and ($tab.command -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$tab.command))) {
                        $Errors.Add("$tabLabel 'command' must be null or a non-empty string.")
                    }
                    elseif ($tab.command -is [string] -and $tab.command -match "[\r\n]") {
                        $Errors.Add("$tabLabel 'command' must not contain newline characters.")
                    }

                    if (Test-DevWSProperty -Object $tab -Name "args") {
                        if ($tab.args -isnot [array]) {
                            $Errors.Add("$tabLabel 'args' must be an array.")
                        }
                        else {
                            foreach ($argument in $tab.args) {
                                if ($argument -isnot [string] -and -not (Test-DevWSInteger $argument)) {
                                    $Errors.Add("$tabLabel 'args' entries must be strings or numbers.")
                                    break
                                }

                                if ($argument -is [string] -and $argument -match "[\r\n]") {
                                    $Errors.Add("$tabLabel 'args' entries must not contain newline characters.")
                                    break
                                }
                            }
                        }
                    }

                    # Pass 6C optional per-tab path override. Structural rules
                    # only: existence is operation-scoped validation.
                    if (Test-DevWSProperty -Object $tab -Name "path") {
                        $tabPath = $tab.path

                        if ($tabPath -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$tabPath)) {
                            $Errors.Add("$tabLabel 'path' must be a non-empty string when present.")
                        }
                        elseif (-not [System.IO.Path]::IsPathRooted([string]$tabPath)) {
                            $Errors.Add("$tabLabel 'path' must be an absolute path.")
                        }
                    }
                }
            }

            $activeTab = Get-DevWSProperty -Object $item -Name "activeTab"

            if (-not (Test-DevWSProperty -Object $item -Name "activeTab") -or -not (Test-DevWSInteger $activeTab)) {
                $Errors.Add("$label 'activeTab' must be an integer.")
            }
            elseif ($tabs -is [array] -and @($tabs).Count -ge 1 -and ([int]$activeTab -lt 0 -or [int]$activeTab -ge @($tabs).Count)) {
                $Errors.Add("$label 'activeTab' $activeTab does not address an existing tab (valid range: 0..$(@($tabs).Count - 1)).")
            }
        }
        else {
            $match = Get-DevWSProperty -Object $item -Name "match"

            if (-not (Test-DevWSProperty -Object $item -Name "match") -or $null -eq $match -or $match -isnot [System.Management.Automation.PSCustomObject]) {
                $Errors.Add("$label 'match' must be an object with 'kind' and 'value'.")
            }
            else {
                $matchKind = Get-DevWSProperty -Object $match -Name "kind"

                if ($matchKind -notin $supportedMatchKinds) {
                    $Errors.Add("$label match.kind must be one of: $($supportedMatchKinds -join ', ') (got '$matchKind').")
                }

                if (-not (Test-DevWSProperty -Object $match -Name "value") -or $match.value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$match.value)) {
                    $Errors.Add("$label match.value must be a non-empty string.")
                }
            }

            $launch = Get-DevWSProperty -Object $item -Name "launch"

            if (-not (Test-DevWSProperty -Object $item -Name "launch") -or $null -eq $launch -or $launch -isnot [System.Management.Automation.PSCustomObject]) {
                $Errors.Add("$label 'launch' must be an object with 'kind' and 'value'.")
            }
            else {
                $launchKind = Get-DevWSProperty -Object $launch -Name "kind"

                if ($launchKind -notin $supportedLaunchKinds) {
                    $Errors.Add("$label launch.kind must be one of: $($supportedLaunchKinds -join ', ') (got '$launchKind').")
                }

                if (-not (Test-DevWSProperty -Object $launch -Name "value") -or $launch.value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$launch.value)) {
                    $Errors.Add("$label launch.value must be a non-empty string.")
                }

                if (Test-DevWSProperty -Object $launch -Name "args") {
                    if ($launch.args -isnot [array]) {
                        $Errors.Add("$label launch.args must be an array.")
                    }
                    else {
                        foreach ($argument in $launch.args) {
                            if ($argument -isnot [string] -and -not (Test-DevWSInteger $argument)) {
                                $Errors.Add("$label launch.args entries must be strings or numbers.")
                                break
                            }

                            if ($argument -is [string] -and $argument -match "[\r\n]") {
                                $Errors.Add("$label launch.args entries must not contain newline characters.")
                                break
                            }
                        }
                    }
                }
            }

            if ($RuleSet -eq "v3") {
                # Final runtime v3 requires an explicit mode on every app. The
                # installer-only relaxed recognizer allows a missing mode on a
                # historical Phase 7 v3 config; an explicit mode is always
                # validated strictly.
                if (-not (Test-DevWSProperty -Object $item -Name "instanceMode")) {
                    if (-not $AllowMissingInstanceMode) {
                        $Errors.Add("$label is missing 'instanceMode'. Apps require an explicit 'dedicated' or 'shared' mode (run install.ps1 from an elevated PowerShell to upgrade a historical v3 config).")
                    }
                }
                else {
                    $instanceMode = $item.instanceMode

                    if ($instanceMode -isnot [string]) {
                        $Errors.Add("$label 'instanceMode' must be the string 'dedicated' or 'shared' (got a non-string value).")
                    }
                    elseif ($instanceMode -cne "dedicated" -and $instanceMode -cne "shared") {
                        $Errors.Add("$label 'instanceMode' must be exactly 'dedicated' or 'shared' (got '$instanceMode'). Use lower case.")
                    }
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Topology layout profiles (Pass 5C schema layer).
#
# layoutProfiles is an optional per-set array of topology-keyed absolute
# layout profiles. The canonical token parser and matcher signature helpers
# live here (not in the policy library) because every config-reading process
# validates configuration - including the installer and the scheduled
# workers, which do not load policy libraries. The pure selection/mutation
# policy lives in devws-layout-profile.ps1 and reuses these helpers.
# ---------------------------------------------------------------------------

function ConvertFrom-DevWSLayoutMonitorToken {
    # Canonical parser for one topology signature token:
    #   <identity>@<x>,<y>,<width>x<height>
    # The identity must carry a Pass-5B durable prefix (`edid:` or `path:`,
    # lower case canonical spelling) and is otherwise opaque. The rectangle
    # suffix is located robustly from the right (greedy identity match), so
    # identity punctuation - including '@' - is never mis-split. Returns
    # $null for anything malformed; monitor ordinals are never identities.
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) { return $null }

    $match = [regex]::Match($Token, '^(?<identity>.+)@(?<x>-?[0-9]+),(?<y>-?[0-9]+),(?<w>[0-9]+)x(?<h>[0-9]+)$')

    if (-not $match.Success) { return $null }

    $identity = [string]$match.Groups['identity'].Value

    if ($identity -cnotmatch '^(edid|path):.+$') { return $null }

    $x = 0
    $y = 0
    $w = 0
    $h = 0
    $style = [System.Globalization.NumberStyles]::AllowLeadingSign
    $culture = [System.Globalization.CultureInfo]::InvariantCulture

    if (-not [int]::TryParse([string]$match.Groups['x'].Value, $style, $culture, [ref]$x)) { return $null }
    if (-not [int]::TryParse([string]$match.Groups['y'].Value, $style, $culture, [ref]$y)) { return $null }
    if (-not [int]::TryParse([string]$match.Groups['w'].Value, $style, $culture, [ref]$w)) { return $null }
    if (-not [int]::TryParse([string]$match.Groups['h'].Value, $style, $culture, [ref]$h)) { return $null }

    if ($w -le 0 -or $h -le 0) { return $null }

    return [pscustomobject]@{
        Token    = $Token
        Identity = $identity
        X        = $x
        Y        = $y
        W        = $w
        H        = $h
    }
}

function Get-DevWSOrdinalSortedTokens {
    # Ordinal, culture-invariant token sort shared by the matcher signature
    # and profile creation (matches Pass-5B topology signature semantics).
    param([AllowEmptyCollection()][string[]]$Tokens = @())

    $array = [string[]]@($Tokens)

    if ($array.Length -gt 1) {
        [System.Array]::Sort($array, [System.StringComparer]::Ordinal)
    }

    return @($array)
}

function Get-DevWSLayoutMatcherSignature {
    # Canonical matcher signature: ordinal-sorted token strings joined with
    # ';' - byte-identical semantics to the Pass-5B topology signature.
    param([AllowEmptyCollection()][string[]]$Tokens = @())

    return ((Get-DevWSOrdinalSortedTokens -Tokens $Tokens) -join ';')
}

function Get-DevWSLayoutTopologyTokens {
    # The exact signature-token array of a Pass-5B topology model (never
    # reconstructed from diagnostics such as names, order or GDI device names).
    param($Topology)

    if ($null -eq $Topology) { return @() }

    $signature = [string](Get-DevWSProperty -Object $Topology -Name "Signature")

    if ([string]::IsNullOrWhiteSpace($signature)) { return @() }

    return @($signature -split ';')
}

function Test-DevWSLayoutProfileIdReserved {
    # `fallback` names the legacy item.layout storage scope and can never be
    # a profile id (case-insensitive).
    param([AllowEmptyString()][string]$Id)

    return ($Id -ieq "fallback")
}

function Add-DevWSLayoutProfileValidationErrors {
    # Validates an optional set.layoutProfiles array. Called from
    # Assert-DevWSConfig for normal runtime v3 validation and for the
    # installer's relaxed historical-v3 recognition; app instance-mode
    # relaxation never relaxes profile rules.
    param(
        [Parameter(Mandatory)]
        $Errors,
        [Parameter(Mandatory)]
        $Set,
        [Parameter(Mandatory)]
        [string]$SetLabel
    )

    if (-not (Test-DevWSProperty -Object $Set -Name "layoutProfiles")) { return }

    $profilesValue = $Set.layoutProfiles

    if ($null -eq $profilesValue -or $profilesValue -isnot [array]) {
        $Errors.Add("$SetLabel 'layoutProfiles' must be an array of profile objects; remove the property for none.")
        return
    }

    # Known item ids (case-insensitive) for referential layout-map checks.
    $itemIds = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $setItems = Get-DevWSProperty -Object $Set -Name "windows"

    foreach ($item in @($setItems)) {
        if ($null -ne $item -and $item -is [System.Management.Automation.PSCustomObject]) {
            $itemId = [string](Get-DevWSProperty -Object $item -Name "id")

            if (-not [string]::IsNullOrWhiteSpace($itemId)) {
                $itemIds[$itemId] = $itemId
            }
        }
    }

    $seenProfileIds = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenMatchers   = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)

    $profiles = @($profilesValue)

    for ($p = 0; $p -lt $profiles.Count; $p++) {
        $profile = $profiles[$p]
        $profileLabel = "$SetLabel layoutProfiles[$p]"

        if ($null -eq $profile -or $profile -isnot [System.Management.Automation.PSCustomObject]) {
            $Errors.Add("$profileLabel must be a JSON object with 'id', 'match' and 'layouts'.")
            continue
        }

        foreach ($property in @($profile.PSObject.Properties)) {
            if ($property.Name -notin @("id", "match", "layouts")) {
                $Errors.Add("$profileLabel has unexpected property '$($property.Name)'. Allowed: id, match, layouts.")
            }
        }

        if (-not (Test-DevWSProperty -Object $profile -Name "id") -or $profile.id -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$profile.id)) {
            $Errors.Add("$profileLabel is missing a non-empty string 'id'.")
        }
        else {
            $profileId = [string]$profile.id
            $profileLabel = "$SetLabel layoutProfiles[$p] ('$profileId')"

            if (-not (Test-DevWSStableIdSyntax -Id $profileId)) {
                $Errors.Add("$profileLabel 'id' contains unsupported characters. Profile ids may only contain letters, digits, '.', '_' and '-'; '/' is reserved for scoped references.")
            }

            if (Test-DevWSLayoutProfileIdReserved -Id $profileId) {
                $Errors.Add("$profileLabel 'id' is reserved: 'fallback' names the item.layout storage scope and cannot be a profile id.")
            }

            if ($seenProfileIds.ContainsKey($profileId)) {
                $Errors.Add("$profileLabel has a duplicate profile id. Profile ids are unique case-insensitively within a set.")
            }
            else {
                $seenProfileIds[$profileId] = $true
            }
        }

        # match (only 'exact' topology equality is supported).
        $matcherSignature = $null
        $match = Get-DevWSProperty -Object $profile -Name "match"

        if (-not (Test-DevWSProperty -Object $profile -Name "match") -or $null -eq $match -or $match -isnot [System.Management.Automation.PSCustomObject]) {
            $Errors.Add("$profileLabel 'match' must be an object with 'mode' and 'monitors'.")
        }
        else {
            foreach ($property in @($match.PSObject.Properties)) {
                if ($property.Name -notin @("mode", "monitors")) {
                    $Errors.Add("$profileLabel match has unexpected property '$($property.Name)'. Allowed: mode, monitors.")
                }
            }

            $mode = [string](Get-DevWSProperty -Object $match -Name "mode")

            if ($mode -cne "exact") {
                $Errors.Add("$profileLabel match.mode must be 'exact' (got '$mode'). Only exact topology matching is supported.")
            }

            $monitors = Get-DevWSProperty -Object $match -Name "monitors"

            if (-not (Test-DevWSProperty -Object $match -Name "monitors") -or $null -eq $monitors -or $monitors -isnot [array]) {
                $Errors.Add("$profileLabel match.monitors must be an array of topology signature tokens.")
            }
            elseif (@($monitors).Count -eq 0) {
                $Errors.Add("$profileLabel match.monitors must contain at least one topology signature token.")
            }
            else {
                $tokens = [System.Collections.Generic.List[string]]::new()
                $seenTokens = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::Ordinal)
                $tokenIndex = 0

                foreach ($tokenValue in @($monitors)) {
                    $tokenLabel = "$profileLabel match.monitors[$tokenIndex]"
                    $tokenIndex++

                    if ($tokenValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$tokenValue)) {
                        $Errors.Add("$tokenLabel must be a non-empty topology signature token (<edid|path identity>@<x>,<y>,<width>x<height>).")
                        continue
                    }

                    $tokenText = [string]$tokenValue
                    $parsed = ConvertFrom-DevWSLayoutMonitorToken -Token $tokenText

                    if ($null -eq $parsed) {
                        $Errors.Add("$tokenLabel is malformed: '$tokenText'. Expected an 'edid:' or 'path:' identity followed by @<x>,<y>,<width>x<height> with positive width/height; monitor ordinals such as \\.\DISPLAY1 are not identities.")
                        continue
                    }

                    if ($seenTokens.ContainsKey($tokenText)) {
                        $Errors.Add("$tokenLabel duplicates an earlier monitor token in the same profile.")
                        continue
                    }

                    $seenTokens[$tokenText] = $true
                    $tokens.Add($tokenText) | Out-Null
                }

                if ($tokens.Count -gt 0 -and $tokens.Count -eq @($monitors).Count) {
                    $matcherSignature = Get-DevWSLayoutMatcherSignature -Tokens $tokens.ToArray()
                }
            }
        }

        if ($null -ne $matcherSignature) {
            if ($seenMatchers.ContainsKey($matcherSignature)) {
                $Errors.Add("$profileLabel duplicates the monitor matcher of $($seenMatchers[$matcherSignature]). Two profiles in the same set must not match the same topology signature; profile order never resolves conflicts.")
            }
            else {
                $seenMatchers[$matcherSignature] = $profileLabel
            }
        }

        # layouts (sparse item-id -> absolute rectangle map).
        $layouts = Get-DevWSProperty -Object $profile -Name "layouts"

        if (-not (Test-DevWSProperty -Object $profile -Name "layouts") -or $null -eq $layouts -or $layouts -isnot [System.Management.Automation.PSCustomObject]) {
            $Errors.Add("$profileLabel 'layouts' must be an object mapping item ids to rectangles (it may be empty).")
        }
        else {
            foreach ($layoutProperty in @($layouts.PSObject.Properties)) {
                $key = [string]$layoutProperty.Name

                if (-not $itemIds.ContainsKey($key)) {
                    $Errors.Add("$profileLabel layouts['$key'] references an item id that does not exist in this set.")
                }

                Add-DevWSRectValidationErrors -Errors $Errors -Rect $layoutProperty.Value -Label $profileLabel -FieldLabel "layouts['$key']"
            }
        }
    }
}

function Add-DevWSTitleFamilyValidationErrors {
    param(
        [Parameter(Mandatory)]
        $Errors,
        [Parameter(Mandatory)]
        $Sets
    )

    # Pass 6C collision invariant: a configured base windowId must never be
    # interpretable as a managed tab-title family member of ANOTHER configured
    # terminal, and every generated canonical tab title must be unique across
    # the whole config. Ambiguity refuses by construction.
    $terminals = [System.Collections.Generic.List[object]]::new()
    $setList   = @($Sets)

    for ($s = 0; $s -lt $setList.Count; $s++) {
        $set = $setList[$s]

        if ($null -eq $set) { continue }

        $windows = $set.windows

        if ($null -eq $windows -or $windows -isnot [array]) { continue }

        $windowList = @($windows)

        for ($w = 0; $w -lt $windowList.Count; $w++) {
            $item = $windowList[$w]

            if ($null -eq $item -or [string]$item.type -ne "terminal") { continue }

            $windowId = [string]$item.windowId

            if ([string]::IsNullOrWhiteSpace($windowId)) { continue }

            $tabsValue = $item.tabs
            $tabCount  = 0

            if ($null -ne $tabsValue) {
                $tabCount = @($tabsValue).Count
            }

            $terminals.Add([pscustomobject]@{
                WindowId = $windowId
                TabCount = $tabCount
                Label    = "$($set.id)/$($item.id)"
            }) | Out-Null
        }
    }

    for ($a = 0; $a -lt $terminals.Count; $a++) {
        for ($b = 0; $b -lt $terminals.Count; $b++) {
            if ($a -eq $b) { continue }

            $base  = $terminals[$a]
            $other = $terminals[$b]
            $resolved = Resolve-DevWSTerminalTabTitle -WindowId $base.WindowId -Title $other.WindowId

            if ([bool]$resolved.IsManaged) {
                $Errors.Add("terminal '$($other.Label)' windowId '$($other.WindowId)' collides with the managed tab-title family of terminal '$($base.Label)' windowId '$($base.WindowId)' (it parses as configured tab $($resolved.TabIndex) of that terminal). Rename one of the windowIds.")
            }
        }
    }

    # Belt and braces: every generated canonical title is unique config-wide.
    $seenTitles = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($terminal in $terminals) {
        for ($tabIndex = 0; $tabIndex -lt $terminal.TabCount; $tabIndex++) {
            $title = Get-DevWSTerminalTabTitle -WindowId $terminal.WindowId -TabIndex $tabIndex

            if ($seenTitles.ContainsKey($title)) {
                $Errors.Add("terminal '$($terminal.Label)' generated managed tab title '$title' collides with $($seenTitles[$title]). Managed tab titles must be unique across the whole config.")
            }
            else {
                $seenTitles[$title] = "terminal '$($terminal.Label)'"
            }
        }
    }
}

function Assert-DevWSConfig {
    param(
        [Parameter(Mandatory)]
        $Config,
        [string]$Source = "workspace.json",
        [switch]$RequireTerminalPaths,
        [switch]$AllowMissingInstanceMode
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $Config -or $Config -isnot [System.Management.Automation.PSCustomObject]) {
        throw "${Source}: config root must be a JSON object."
    }

    $version = Get-DevWSProperty -Object $Config -Name "version"
    $versionOk = $false

    if (-not (Test-DevWSProperty -Object $Config -Name "version")) {
        $errors.Add("'version' is required and must be 3.")
    }
    elseif (-not (Test-DevWSInteger $version)) {
        $errors.Add("'version' must be 3 (got '$version').")
    }
    elseif ([int]$version -eq 2) {
        # Actionable runtime guard: normal DevWS commands never migrate config.
        $errors.Add("'version' is 2. This is a v2 workspace config; DevWS v3 requires the installer migration. Run install.ps1 from an elevated PowerShell to migrate it to v3. The config was not modified.")
    }
    elseif ([int]$version -ne 3) {
        $errors.Add("'version' must be 3 (got '$version'). Only the v3 schema is supported.")
    }
    else {
        $versionOk = $true
    }

    if (-not $versionOk) {
        Throw-DevWSValidationErrors -Source $Source -Errors $errors
        return
    }

    $defaultSetId = Get-DevWSProperty -Object $Config -Name "defaultSet"

    if (-not (Test-DevWSProperty -Object $Config -Name "defaultSet") -or $defaultSetId -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$defaultSetId)) {
        $errors.Add("'defaultSet' must be a non-empty configured set id.")
    }
    elseif (-not (Test-DevWSStableIdSyntax -Id ([string]$defaultSetId))) {
        $errors.Add("'defaultSet' '$defaultSetId' contains unsupported characters. Set ids may only contain letters, digits, '.', '_' and '-'; '/' is reserved for scoped references.")
    }

    $bindings = Get-DevWSProperty -Object $Config -Name "bindings"

    if (-not (Test-DevWSProperty -Object $Config -Name "bindings") -or $bindings -isnot [array]) {
        $errors.Add("'bindings' must be an array of { hotkey, setId } objects; use [] for none.")
    }

    $sets = Get-DevWSProperty -Object $Config -Name "sets"

    if (-not (Test-DevWSProperty -Object $Config -Name "sets") -or $sets -isnot [array]) {
        $errors.Add("'sets' must be an array of set definitions.")
        Throw-DevWSValidationErrors -Source $Source -Errors $errors
        return
    }

    if (@($sets).Count -eq 0) {
        $errors.Add("'sets' must contain at least one set definition.")
    }

    $seenSetIds   = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenWindowIds = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)

    for ($s = 0; $s -lt $sets.Count; $s++) {
        $set = $sets[$s]
        $setLabel = "sets[$s]"

        if ($null -eq $set -or $set -isnot [System.Management.Automation.PSCustomObject]) {
            $errors.Add("$setLabel must be a JSON object with 'id' and 'windows'.")
            continue
        }

        if (-not (Test-DevWSProperty -Object $set -Name "id") -or $set.id -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$set.id)) {
            $errors.Add("$setLabel is missing a non-empty string 'id'.")
        }
        else {
            $setId = [string]$set.id
            $setLabel = "sets[$s] ('$setId')"

            if (-not (Test-DevWSStableIdSyntax -Id $setId)) {
                $errors.Add("$setLabel 'id' contains unsupported characters. Set ids may only contain letters, digits, '.', '_' and '-'; '/' is reserved for scoped references.")
            }

            if ($seenSetIds.ContainsKey($setId)) {
                $errors.Add("$setLabel has a duplicate set id. Set ids are unique case-insensitively.")
            }
            else {
                $seenSetIds[$setId] = $true
            }
        }

        $windows = Get-DevWSProperty -Object $set -Name "windows"

        if (-not (Test-DevWSProperty -Object $set -Name "windows") -or $windows -isnot [array]) {
            $errors.Add("$setLabel 'windows' must be an array of window definitions.")
            continue
        }

        $seenItemIds = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)

        Add-DevWSWindowValidationErrors `
            -Errors $errors `
            -Items @($windows) `
            -LabelPrefix "$setLabel windows" `
            -SeenIds $seenItemIds `
            -SeenWindowIds $seenWindowIds `
            -RuleSet "v3" `
            -AllowMissingInstanceMode:$AllowMissingInstanceMode

        Add-DevWSLayoutProfileValidationErrors -Errors $errors -Set $set -SetLabel $setLabel
    }

    Add-DevWSTitleFamilyValidationErrors -Errors $errors -Sets $sets

    # Global set launch bindings (global config, not owned by a set; the
    # installer-only relaxed recognizer uses these same rules).
    Add-DevWSBindingValidationErrors -Errors $errors -Bindings $bindings -KnownSetIds $seenSetIds

    # Phase 8 transitional cross-set rule: when explicit instance modes are
    # present, the same app id (case-insensitive) must not be 'shared' in one
    # set and 'dedicated' in another. A missing mode is transitional and is
    # never interpreted as either mode here.
    $explicitAppModes = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

    for ($s = 0; $s -lt $sets.Count; $s++) {
        $set = $sets[$s]

        if ($null -eq $set -or $set -isnot [System.Management.Automation.PSCustomObject]) {
            continue
        }

        $setLabel = "sets[$s] ('$([string]$set.id)')"
        $windows  = Get-DevWSProperty -Object $set -Name "windows"

        if ($windows -isnot [array]) {
            continue
        }

        foreach ($item in @($windows)) {
            if ($null -eq $item -or $item -isnot [System.Management.Automation.PSCustomObject]) {
                continue
            }

            if ((Get-DevWSProperty -Object $item -Name "type") -ne "app") {
                continue
            }

            if (-not (Test-DevWSProperty -Object $item -Name "instanceMode")) {
                continue
            }

            $itemId = [string](Get-DevWSProperty -Object $item -Name "id")
            $mode   = Get-DevWSAppInstanceMode -Item $item

            if ($mode -notin @("dedicated", "shared")) {
                # The per-item validator already reported the invalid value.
                continue
            }

            if ($explicitAppModes.ContainsKey($itemId)) {
                $first = $explicitAppModes[$itemId]

                if ($first.Mode -ne $mode) {
                    $Errors.Add("App id '$itemId' is explicitly '$($first.Mode)' in $($first.Label) but explicitly '$mode' in $setLabel. The same app id must use one instance mode across sets; a missing 'instanceMode' is transitional and is not an implicit mode.")
                }
                elseif ($mode -eq "shared") {
                    $difference = Get-DevWSSharedAppDefinitionDifference -First $first.App -Second $item

                    if ($difference) {
                        $Errors.Add("App id '$itemId' is explicitly shared in $($first.Label) and in $setLabel, but the definitions differ on '$difference'. Shared definitions with the same app id must match on match/launch fields (layout and enabled state may differ).")
                    }
                }
            }
            else {
                $explicitAppModes[$itemId] = [pscustomobject]@{
                    Mode  = $mode
                    Label = $setLabel
                    App   = $item
                }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$defaultSetId) -and -not $seenSetIds.ContainsKey([string]$defaultSetId)) {
        $known = @($sets | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.id) } | ForEach-Object { [string]$_.id }) -join ", "
        $errors.Add("'defaultSet' '$defaultSetId' does not match a configured set. Configured sets: $known")
    }

    Throw-DevWSValidationErrors -Source $Source -Errors $errors

    if ($RequireTerminalPaths) {
        # Compatibility entry point used by tests and future callers: validate
        # paths for defaultSet. Lifecycle commands and workers validate their
        # resolved target set explicitly through Assert-DevWSTerminalPaths.
        Assert-DevWSTerminalPaths -Config $Config -Set (Get-DevWSDefaultSet -Config $Config) -Source $Source
    }
}

function Assert-DevWSPreInstanceModeV3Config {
    param(
        [Parameter(Mandatory)]
        $Config,
        [string]$Source = "workspace.json"
    )

    # Installer-only recognition of a historical Phase 7 v3 config that is
    # structurally valid but predates mandatory app instance modes. Normal
    # runtime commands and Save-DevWSConfig must never use this relaxed path.
    Assert-DevWSConfig -Config $Config -Source $Source -AllowMissingInstanceMode
}

function Add-DevWSTerminalPathValidationError {
    param(
        [Parameter(Mandatory)]
        $Errors,
        [AllowNull()]
        $Terminal,
        [AllowEmptyString()]
        [string]$SetId
    )

    # One shared operation-scoped path check for both single-terminal and
    # set-wide operations: EVERY configured tab's EFFECTIVE path (its explicit
    # override when present, otherwise the terminal default) must exist as a
    # directory BEFORE any creative/destructive side effect. No other code
    # repeats the Test-Path logic.
    if ($null -eq $Terminal) {
        return
    }

    $label = [string]$Terminal.id

    if (-not [string]::IsNullOrWhiteSpace($SetId)) {
        $label = "$SetId/$label"
    }

    $tabsValue = $Terminal.tabs
    $tabs      = @()

    if ($null -ne $tabsValue) {
        $tabs = @($tabsValue)
    }

    if ($tabs.Count -eq 0) {
        # Structurally invalid configs are reported separately; keep the
        # historical single-path check for this defensive fallback.
        $fallbackPath = [string]$Terminal.path

        if (-not (Test-Path -LiteralPath $fallbackPath -PathType Container)) {
            $Errors.Add("terminal '$label' working directory does not exist: $fallbackPath")
        }

        return
    }

    for ($tabIndex = 0; $tabIndex -lt $tabs.Count; $tabIndex++) {
        $effectivePath = Get-DevWSTerminalTabEffectivePath -Terminal $Terminal -TabIndex $tabIndex

        if (Test-Path -LiteralPath $effectivePath -PathType Container) {
            continue
        }

        $tab = $tabs[$tabIndex]
        $hasOverride = ($null -ne $tab) -and (-not [string]::IsNullOrWhiteSpace([string]$tab.path))

        if ($tabIndex -eq 0 -and -not $hasOverride) {
            # Historical message shape for the plain terminal.path case.
            $Errors.Add("terminal '$label' working directory does not exist: $effectivePath")
        }
        else {
            $Errors.Add("terminal '$label' tab $tabIndex working directory does not exist: $effectivePath")
        }
    }
}

function Assert-DevWSTerminalPath {
    param(
        [Parameter(Mandatory)]
        $Terminal,
        [AllowEmptyString()]
        [string]$SetId,
        [string]$Source = "workspace.json"
    )

    # Single-terminal variant: used by one-terminal operations (reset) so an
    # unrelated enabled terminal in the same set cannot block them.
    $errors = [System.Collections.Generic.List[string]]::new()

    Add-DevWSTerminalPathValidationError -Errors $errors -Terminal $Terminal -SetId $SetId

    Throw-DevWSValidationErrors -Source $Source -Errors $errors
}

function Assert-DevWSTerminalPaths {
    param(
        [Parameter(Mandatory)]
        $Config,
        $Set,
        [string]$Source = "workspace.json"
    )

    # Operation-scoped terminal path validation: only the selected target set is
    # checked, so launching one set never fails because of an unrelated set
    # whose project directory is missing right now.
    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($item in @($target.windows)) {
        if ($null -eq $item -or $item.type -ne "terminal" -or $item.enabled -ne $true) {
            continue
        }

        Add-DevWSTerminalPathValidationError -Errors $errors -Terminal $item -SetId ([string]$target.id)
    }

    Throw-DevWSValidationErrors -Source $Source -Errors $errors
}

# ---------------------------------------------------------------------------
# Frozen v2 recognition (installer migration only)
# ---------------------------------------------------------------------------

function Assert-DevWSV2Config {
    param(
        [Parameter(Mandatory)]
        $Config,
        [string]$Source = "workspace.json"
    )

    # This is the exact v2 schema validator, preserved for installer-owned
    # canonical migration recognition. Normal runtime validation is v3 only.
    $errors = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $Config -or $Config -isnot [System.Management.Automation.PSCustomObject]) {
        throw "${Source}: config root must be a JSON object."
    }

    $version = Get-DevWSProperty -Object $Config -Name "version"

    if (-not (Test-DevWSProperty -Object $Config -Name "version")) {
        $errors.Add("'version' is required and must be 2.")
    }
    elseif (-not (Test-DevWSInteger $version) -or [int]$version -ne 2) {
        $errors.Add("'version' must be 2 (got '$version').")
    }

    $windows = Get-DevWSProperty -Object $Config -Name "windows"

    if (-not (Test-DevWSProperty -Object $Config -Name "windows") -or $windows -isnot [array]) {
        $errors.Add("'windows' must be an array of window definitions.")
        Throw-DevWSValidationErrors -Source $Source -Errors $errors
        return
    }

    $seenIds       = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seenWindowIds = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)

    Add-DevWSWindowValidationErrors `
        -Errors $errors `
        -Items @($windows) `
        -LabelPrefix "windows" `
        -SeenIds $seenIds `
        -SeenWindowIds $seenWindowIds

    Throw-DevWSValidationErrors -Source $Source -Errors $errors
}

function Save-DevWSConfig {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $Location
    )

    Assert-DevWSConfigWritable -Location $Location

    $json = $Config | ConvertTo-Json -Depth 20

    $directory = [System.IO.Path]::GetDirectoryName($Location.Path)

    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tempPath = "$($Location.Path).tmp"

    try {
        [System.IO.File]::WriteAllText(
            $tempPath,
            $json + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )

        # Serialize/validate before replacing the canonical file.
        $reloaded = Read-DevWSConfigFile -Path $tempPath
        Assert-DevWSConfig -Config $reloaded -Source $tempPath

        [System.IO.File]::Move($tempPath, $Location.Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Reference resolution (set-scoped; unscoped calls target defaultSet)
# ---------------------------------------------------------------------------

function Resolve-DevWSReference {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$Reference,
        [ValidateSet("terminal", "app")]
        [string]$Type,
        $Set
    )

    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        $noun = if ($Type) { $Type } else { "window" }
        throw "Usage: a $noun id or number is required."
    }

    $all = @($target.windows)

    foreach ($item in $all) {
        if ($item.id -ieq $Reference) {
            if ($Type -and $item.type -ne $Type) {
                throw "'$Reference' is configured as type '$($item.type)', not '$Type'."
            }

            return $item
        }
    }

    if ($Reference -match '^\d+$') {
        $number = [int]$Reference
        $candidates = $all

        if ($Type) {
            $candidates = @($all | Where-Object { $_.type -eq $Type })
        }

        if ($number -ge 1 -and $number -le $candidates.Count) {
            return $candidates[$number - 1]
        }

        $noun = if ($Type) { $Type } else { "window" }
        throw "There is no $noun number $number. Configured $noun order: $(@($candidates | ForEach-Object { $_.id }) -join ', ')."
    }

    $known = @($all | ForEach-Object { "$($_.id) [$($_.type)]" }) -join ", "
    throw "Unknown workspace item '$Reference'. Configured items: $known"
}

function Resolve-DevWSItemById {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$Reference,
        [string]$CommandName = "this command",
        $Set
    )

    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set

    if ([string]::IsNullOrWhiteSpace($Reference)) {
        throw "Usage: $CommandName requires a stable item id."
    }

    $all = @($target.windows)

    foreach ($item in $all) {
        if ($item.id -ieq $Reference) {
            return $item
        }
    }

    # Generic item mutations never interpret numeric aliases: an alias could
    # silently target the wrong item type. Numeric references remain available
    # only where explicitly documented (ws set, ws reset, ws reset-terminal).
    if ($Reference -match '^\d+$') {
        $known = @($all | ForEach-Object { "$($_.id) [$($_.type)]" }) -join ", "
        throw "$CommandName does not accept numeric aliases ('$Reference'); use a stable item id. Configured items: $known"
    }

    $known = @($all | ForEach-Object { "$($_.id) [$($_.type)]" }) -join ", "
    throw "Unknown workspace item '$Reference'. Configured items: $known"
}

function Resolve-DevWSTerminalById {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$Reference,
        [string]$CommandName = "this command",
        $Set
    )

    $item = Resolve-DevWSItemById -Config $Config -Reference $Reference -CommandName $CommandName -Set $Set

    if ($item.type -ne "terminal") {
        throw "Workspace item '$($item.id)' is an app, not a terminal."
    }

    return $item
}

function Resolve-DevWSAppById {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$Reference,
        [string]$CommandName = "this command",
        $Set
    )

    $item = Resolve-DevWSItemById -Config $Config -Reference $Reference -CommandName $CommandName -Set $Set

    if ($item.type -ne "app") {
        throw "Workspace item '$($item.id)' is a terminal, not an app."
    }

    return $item
}

function Set-DevWSLayout {
    param(
        [Parameter(Mandatory)]
        $Item,
        [Parameter(Mandatory)]
        $Rect
    )

    $Item.layout.x = [int]$Rect.x
    $Item.layout.y = [int]$Rect.y
    $Item.layout.w = [int]$Rect.w
    $Item.layout.h = [int]$Rect.h
}
