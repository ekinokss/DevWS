# DevWS config mutation helpers.
#
# All mutations are CONFIG ONLY. Helpers mutate an in-memory config object and
# validate the complete resulting config; they never launch, close, focus,
# move, or reset anything. Callers persist through Save-DevWSConfig, which
# validates the serialized result before replacing the canonical file
# atomically.
#
# A failed mutation therefore never persists: either the helper throws before
# any save, or Save-DevWSConfig refuses to replace the file.

function Resolve-DevWSDirectoryPath {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$PathText
    )

    if ([string]::IsNullOrWhiteSpace($PathText)) {
        throw "A directory path is required."
    }

    $resolved = Resolve-Path -LiteralPath $PathText -ErrorAction Stop

    if (-not (Test-Path -LiteralPath $resolved.Path -PathType Container)) {
        throw "Not a directory: $($resolved.Path)"
    }

    return $resolved.Path
}

function Get-DevWSTerminalWindowId {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ItemId
    )

    # New v3 terminal definitions use set-qualified generated identities:
    # DevWS-<set-id>-<item-id>. Existing terminals keep whatever windowId they
    # already have; this helper is only used when generating an identity for a
    # new definition.
    return "DevWS-$SetId-$ItemId"
}

function Assert-DevWSItemIdSyntax {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        throw "A non-empty item id is required."
    }

    if ($Id -match '[\r\n]') {
        throw "Item id must not contain newline characters."
    }

    # Conservative personal-tool rule shared with structural validation: ids
    # are used as CLI references, JSON keys, AHK string literals, and
    # capture-file keys, so keep them simple. '/' is reserved for scoped
    # references.
    if (-not (Test-DevWSStableIdSyntax -Id $Id)) {
        throw "Item id '$Id' may only contain letters, digits, '.', '_' and '-'."
    }
}

function Assert-DevWSNewItemId {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Id,
        $Set
    )

    # Generic new-item validation only: ID syntax and case-insensitive
    # uniqueness within the target set. Terminal windowId generation/collision
    # belongs to the terminal-specific helper below so app IDs are never
    # constrained by it.
    Assert-DevWSItemIdSyntax -Id $Id

    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set

    foreach ($item in @($target.windows)) {
        if ($item.id -ieq $Id) {
            throw "Workspace item '$Id' already exists in set '$([string]$target.id)'."
        }
    }
}

function Assert-DevWSNewAppId {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Id,
        $Set
    )

    # Pass 1 app-ID policy: numeric ids are reserved for terminal aliases,
    # and an app never owns a terminal windowId.
    if ($Id -match '^\d+$') {
        throw "App id '$Id' must not be numeric. Numeric references are reserved for terminal aliases; use a descriptive id."
    }

    Assert-DevWSNewItemId -Config $Config -Id $Id -Set $Set
}

function Assert-DevWSNewTerminalId {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Id,
        $Set
    )

    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set

    Assert-DevWSNewItemId -Config $Config -Id $Id -Set $target

    $windowId = Get-DevWSTerminalWindowId -SetId ([string]$target.id) -ItemId $Id

    # Terminal named-window identities are not set-local, so the generated
    # windowId must be collision-free across every configured set.
    foreach ($candidateSet in @(Get-DevWSSets -Config $Config)) {
        if ($null -eq $candidateSet) {
            continue
        }

        foreach ($item in @($candidateSet.windows)) {
            if ($item.type -eq "terminal" -and ([string]$item.windowId) -ieq $windowId) {
                throw "Generated windowId '$windowId' for new terminal '$Id' collides with terminal '$($item.id)' in set '$([string]$candidateSet.id)'."
            }
        }
    }

    return $windowId
}

function Get-DevWSDefaultTerminalLayout {
    param(
        [Parameter(Mandatory)]
        $Config,
        $Set
    )

    $terminals = @(Get-DevWSWindows -Config $Config -Set $Set -Type terminal)

    if ($terminals.Count -gt 0) {
        # Copy the last configured terminal's layout; never alter another
        # item's layout. The user repositions the new window and runs
        # `ws save-layout` to persist real geometry.
        $last = $terminals[$terminals.Count - 1].layout

        return [pscustomobject]@{
            x = [int]$last.x
            y = [int]$last.y
            w = [int]$last.w
            h = [int]$last.h
        }
    }

    # Fallback rectangle when no terminal exists yet: one default-size column.
    return [pscustomobject]@{
        x = 0
        y = 0
        w = 654
        h = 1407
    }
}

function New-DevWSTerminalDefinition {
    param(
        [Parameter(Mandatory)]
        [string]$Id,
        [Parameter(Mandatory)]
        [string]$WindowId,
        [Parameter(Mandatory)]
        [string]$Path,
        [AllowEmptyString()]
        [string]$Command,
        [AllowEmptyCollection()]
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)]
        $Layout
    )

    $argumentList = @()

    if ($null -ne $Arguments) {
        $argumentList = @($Arguments)
    }

    $tabs = [System.Collections.Generic.List[object]]::new()

    if (-not [string]::IsNullOrWhiteSpace($Command)) {
        $tabs.Add([pscustomobject][ordered]@{
            command = $Command
            args    = $argumentList
        })
        $tabs.Add([pscustomobject][ordered]@{
            command = $null
            args    = @()
        })
    }
    else {
        $tabs.Add([pscustomobject][ordered]@{
            command = $null
            args    = @()
        })
    }

    return [pscustomobject][ordered]@{
        id        = $Id
        type      = "terminal"
        enabled   = $true
        windowId  = $WindowId
        path      = $Path
        elevated  = $true
        tabs      = @($tabs.ToArray())
        activeTab = 0
        layout    = [pscustomobject][ordered]@{
            x = [int]$Layout.x
            y = [int]$Layout.y
            w = [int]$Layout.w
            h = [int]$Layout.h
        }
    }
}

function Add-DevWSTerminal {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$Id,
        [Parameter(Mandatory)]
        [string]$Path,
        [AllowEmptyString()]
        [string]$Command,
        [AllowEmptyCollection()]
        [string[]]$Arguments = @(),
        $Set
    )

    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set

    $windowId = Assert-DevWSNewTerminalId -Config $Config -Id $Id -Set $target

    $layout = Get-DevWSDefaultTerminalLayout -Config $Config -Set $target
    $item = New-DevWSTerminalDefinition `
        -Id $Id `
        -WindowId $windowId `
        -Path $Path `
        -Command $Command `
        -Arguments $Arguments `
        -Layout $layout

    $target.windows = @($target.windows) + $item

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $item
}

function Remove-DevWSItem {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$Reference,
        [string]$CommandName = "ws remove",
        $Set
    )

    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set
    $item = Resolve-DevWSItemById -Config $Config -Reference $Reference -CommandName $CommandName -Set $target

    $target.windows = @($target.windows | Where-Object { -not ($_.id -ieq $item.id) })

    # Topology layout profiles are sparse and keyed by item id: sweep every
    # profile in the target set so no orphan key remains.
    foreach ($profileObject in @(Get-DevWSLayoutProfiles -Set $target)) {
        Remove-DevWSLayoutProfileEntry -Profile $profileObject -ItemId ([string]$item.id)
    }

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $item
}

function Set-DevWSItemEnabled {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$Reference,
        [Parameter(Mandatory)]
        [bool]$Enabled,
        [string]$CommandName = "ws enable/disable",
        $Set
    )

    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set
    $item = Resolve-DevWSItemById -Config $Config -Reference $Reference -CommandName $CommandName -Set $target
    $changed = ([bool]$item.enabled -ne $Enabled)

    if ($changed) {
        $item.enabled = $Enabled
        Assert-DevWSConfig -Config $Config -Source "workspace mutation"
    }

    return [pscustomobject]@{
        Item    = $item
        Changed = $changed
    }
}

function Set-DevWSTerminalPath {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $Terminal,
        [Parameter(Mandatory)]
        [string]$Path
    )

    $Terminal.path = $Path

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $Terminal
}

function Set-DevWSTerminalTabPath {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $Terminal,
        [Parameter(Mandatory)]
        [int]$TabIndex,
        [Parameter(Mandatory)]
        [string]$Path
    )

    # Pass 6C per-tab path override. Tab 0 mirrors into terminal.path so an
    # older runtime (which ignores tab overrides) still opens every tab from
    # the most important tab-0 directory; tabs 1+ only change their own
    # override.
    $tabs = @($Terminal.tabs)

    if ($TabIndex -lt 0 -or $TabIndex -ge $tabs.Count) {
        throw "ws set-path: tab $TabIndex does not address an existing tab of terminal '$([string]$Terminal.id)' (valid range: 0..$($tabs.Count - 1))."
    }

    $tab = $tabs[$TabIndex]

    if ($tab -is [System.Collections.IDictionary]) {
        $tab["path"] = $Path
    }
    else {
        $tab | Add-Member -NotePropertyName "path" -NotePropertyValue $Path -Force
    }

    if ($TabIndex -eq 0) {
        $Terminal.path = $Path
    }

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $Terminal
}

function Clear-DevWSTerminalTabPath {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $Terminal,
        [Parameter(Mandatory)]
        [int]$TabIndex
    )

    # Remove one explicit per-tab path override; the tab inherits terminal.path
    # again. Tab 0 keeps terminal.path unchanged (intentional).
    $tabs = @($Terminal.tabs)

    if ($TabIndex -lt 0 -or $TabIndex -ge $tabs.Count) {
        throw "ws set-path: tab $TabIndex does not address an existing tab of terminal '$([string]$Terminal.id)' (valid range: 0..$($tabs.Count - 1))."
    }

    $tab = $tabs[$TabIndex]

    if ($tab -is [System.Collections.IDictionary]) {
        [void]$tab.Remove("path")
    }
    else {
        $property = $tab.PSObject.Properties["path"]

        if ($null -ne $property) {
            $tab.PSObject.Properties.Remove("path")
        }
    }

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $Terminal
}

function Set-DevWSTerminalCommand {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $Terminal,
        [Parameter(Mandatory)]
        [string]$CommandText,
        [AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    if ([string]::IsNullOrWhiteSpace($CommandText)) {
        throw "A non-empty command is required."
    }

    $argumentList = @()

    if ($null -ne $Arguments) {
        $argumentList = @($Arguments)
    }

    $tabs = @($Terminal.tabs)

    if ($tabs.Count -eq 0) {
        throw "Terminal '$($Terminal.id)' has no tabs to update."
    }

    # Replace/convert the first configured tab and preserve the rest.
    $tabs[0].command = $CommandText
    $tabs[0].args = $argumentList

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $Terminal
}

function Resolve-DevWSAppLaunchKind {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Kind
    )

    if ($Kind -ieq "exe") {
        return "exe"
    }

    if ($Kind -ieq "appId") {
        return "appId"
    }

    throw "Unsupported launch kind '$Kind'. Supported launch kinds: exe, appId."
}

function Resolve-DevWSAppMatchKind {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Kind
    )

    if ($Kind -ieq "exe") {
        return "exe"
    }

    if ($Kind -ieq "processPathContains") {
        return "processPathContains"
    }

    throw "Unsupported match kind '$Kind'. Supported match kinds: exe, processPathContains."
}

function Get-DevWSDefaultAppLayout {
    param(
        [Parameter(Mandatory)]
        $Config,
        $Set
    )

    $apps = @(Get-DevWSWindows -Config $Config -Set $Set -Type app)

    if ($apps.Count -gt 0) {
        # Copy the last configured app's layout; never alter another item's
        # layout. The user repositions the new window and runs
        # `ws save-layout` to persist real geometry.
        $last = $apps[$apps.Count - 1].layout

        return [pscustomobject]@{
            x = [int]$last.x
            y = [int]$last.y
            w = [int]$last.w
            h = [int]$last.h
        }
    }

    # Fallback rectangle when no app exists yet: one default-size column,
    # matching the terminal fallback.
    return [pscustomobject]@{
        x = 0
        y = 0
        w = 654
        h = 1407
    }
}

function New-DevWSAppDefinition {
    param(
        [Parameter(Mandatory)]
        [string]$Id,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$LaunchKind,
        [AllowEmptyString()]
        [string]$LaunchValue,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$MatchKind,
        [AllowEmptyString()]
        [string]$MatchValue,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$InstanceMode,
        [Parameter(Mandatory)]
        $Layout
    )

    $canonicalMode = Resolve-DevWSInstanceModeValue -Mode $InstanceMode

    return [pscustomobject][ordered]@{
        id           = $Id
        type         = "app"
        enabled      = $true
        match        = [pscustomobject][ordered]@{
            kind  = $MatchKind
            value = $MatchValue
        }
        launch       = [pscustomobject][ordered]@{
            kind  = $LaunchKind
            value = $LaunchValue
            args  = @()
        }
        instanceMode = $canonicalMode
        layout       = [pscustomobject][ordered]@{
            x = [int]$Layout.x
            y = [int]$Layout.y
            w = [int]$Layout.w
            h = [int]$Layout.h
        }
    }
}

function Add-DevWSApp {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Id,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$LaunchKind,
        [AllowEmptyString()]
        [string]$LaunchValue,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$MatchKind,
        [AllowEmptyString()]
        [string]$MatchValue,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$InstanceMode,
        $Set
    )

    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set

    $null = Assert-DevWSNewAppId -Config $Config -Id $Id -Set $target

    $launchKind = Resolve-DevWSAppLaunchKind -Kind $LaunchKind
    $matchKind  = Resolve-DevWSAppMatchKind -Kind $MatchKind

    if ([string]::IsNullOrWhiteSpace($LaunchValue)) {
        throw "An app launch value is required."
    }

    if ([string]::IsNullOrWhiteSpace($MatchValue)) {
        throw "An app match value is required."
    }

    $canonicalMode = Resolve-DevWSInstanceModeValue -Mode $InstanceMode

    $layout = Get-DevWSDefaultAppLayout -Config $Config -Set $target
    $item = New-DevWSAppDefinition `
        -Id $Id `
        -LaunchKind $launchKind `
        -LaunchValue $LaunchValue `
        -MatchKind $matchKind `
        -MatchValue $MatchValue `
        -InstanceMode $canonicalMode `
        -Layout $layout

    $target.windows = @($target.windows) + $item

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $item
}

function Set-DevWSAppLaunch {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $App,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Kind,
        [AllowEmptyString()]
        [string]$Value
    )

    $canonicalKind = Resolve-DevWSAppLaunchKind -Kind $Kind

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "An app launch value is required."
    }

    if ($canonicalKind -eq "appId" -and @($App.launch.args).Count -gt 0) {
        throw "App '$($App.id)' has launch args configured and launch.kind 'appId' does not support arguments. Clear them first with: ws set-app-args $($App.id) --clear"
    }

    $App.launch.kind = $canonicalKind
    $App.launch.value = $Value

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $App
}

function Set-DevWSAppMatch {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $App,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Kind,
        [AllowEmptyString()]
        [string]$Value
    )

    $canonicalKind = Resolve-DevWSAppMatchKind -Kind $Kind

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "An app match value is required."
    }

    $App.match.kind = $canonicalKind
    $App.match.value = $Value

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $App
}

function Set-DevWSAppArguments {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $App,
        [AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    if ([string]$App.launch.kind -ne "exe") {
        throw "App '$($App.id)' uses launch.kind '$($App.launch.kind)' and launch arguments are only supported for executable (exe) launches. Use 'ws set-launch $($App.id) exe <path>' first."
    }

    $argumentList = @()

    if ($null -ne $Arguments) {
        $argumentList = @($Arguments)
    }

    $App.launch.args = $argumentList

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $App
}

function Copy-DevWSLayout {
    param(
        [Parameter(Mandatory)]
        $Layout
    )

    return [pscustomobject][ordered]@{
        x = [int]$Layout.x
        y = [int]$Layout.y
        w = [int]$Layout.w
        h = [int]$Layout.h
    }
}

function Get-DevWSItemRelativeLayoutCopyFields {
    # Ordered copy of the optional v3 relative-layout properties. Every clone
    # path merges these fields into its rebuilt definition so relative intent
    # cannot be silently dropped. The relative object is deep-copied through
    # the Phase 1 helper; Copy-DevWSLayout remains absolute-only.
    param(
        [Parameter(Mandatory)]
        $Item
    )

    $fields = [ordered]@{}

    if (Test-DevWSProperty -Object $Item -Name "layoutMode") {
        $fields["layoutMode"] = [string](Get-DevWSProperty -Object $Item -Name "layoutMode")
    }

    if (Test-DevWSProperty -Object $Item -Name "layoutRelative") {
        $relative = Get-DevWSProperty -Object $Item -Name "layoutRelative"

        if ($null -ne $relative) {
            $fields["layoutRelative"] = Copy-DevWSRelativeLayout -RelativeLayout $relative
        }
    }

    return $fields
}

function Test-DevWSItemRelativeMode {
    # Explicit relative mode is authoritative; a relative object without the
    # explicit mode is not valid schema, but treating it as relative here makes
    # every mutation fail safe rather than silently overwriting intent.
    param(
        [Parameter(Mandatory)]
        $Item
    )

    if ([string](Get-DevWSProperty -Object $Item -Name "layoutMode") -ceq "relative") {
        return $true
    }

    return (Test-DevWSProperty -Object $Item -Name "layoutRelative")
}

function Clear-DevWSItemRelativeMode {
    # Intentional absolute conversion used by `set-geometry --mode absolute`
    # and reset-layout only. It removes layoutRelative and records the explicit
    # absolute mode when the item was relative; an already-absolute item keeps
    # its existing representation (absent or explicit 'absolute').
    param(
        [Parameter(Mandatory)]
        $Item
    )

    $changed = $false

    if (Test-DevWSProperty -Object $Item -Name "layoutRelative") {
        $Item.PSObject.Properties.Remove("layoutRelative")
        $changed = $true
    }

    if ([string](Get-DevWSProperty -Object $Item -Name "layoutMode") -ceq "relative") {
        $Item.layoutMode = "absolute"
        $changed = $true
    }
    elseif ($changed -and -not (Test-DevWSProperty -Object $Item -Name "layoutMode")) {
        $Item | Add-Member -NotePropertyName "layoutMode" -NotePropertyValue "absolute" -Force
    }

    return $changed
}

function Set-DevWSItemRelativeGeometry {
    # Config-only relative authoring. No monitor snapshot is taken and the
    # anchor is not required to be connected; syntax and intent are stored,
    # while launch/show-layout report resolution separately.
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $Item,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Anchor,
        [AllowEmptyString()]
        [string]$Instance = $null,
        [Parameter(Mandatory)]
        [string]$Basis,
        [Parameter(Mandatory)]
        [double]$X,
        [Parameter(Mandatory)]
        [double]$Y,
        [Parameter(Mandatory)]
        [double]$W,
        [Parameter(Mandatory)]
        [double]$H
    )

    if (-not (Test-DevWSRelativeMonitorIdentitySyntax -Identity $Anchor)) {
        throw "Relative anchor must be a durable monitor identity beginning with 'edid:' or 'path:' (got '$Anchor')."
    }

    $hasInstance = -not [string]::IsNullOrWhiteSpace($Instance)

    if ($hasInstance) {
        if (-not (Test-DevWSRelativeMonitorInstanceSyntax -Instance $Instance)) {
            throw "Relative monitor instance must use the '<hardwareId>/<instance>' form (got '$Instance')."
        }

        if ($Anchor.StartsWith("path:", [System.StringComparison]::Ordinal)) {
            throw "A 'path:' relative anchor already embeds the device-path instance; omit --instance."
        }
    }

    if ($Basis -cne "workArea" -and $Basis -cne "monitor") {
        throw "Relative basis must be exactly 'workArea' or 'monitor' (got '$Basis')."
    }

    foreach ($pair in @(
        @{ Name = "x"; Value = $X },
        @{ Name = "y"; Value = $Y },
        @{ Name = "width"; Value = $W },
        @{ Name = "height"; Value = $H }
    )) {
        if (-not [double]::IsFinite([double]$pair.Value)) {
            throw "Relative $($pair.Name) must be a finite number."
        }
    }

    if ($W -le 0) {
        throw "Relative width must be greater than 0 (got $W)."
    }

    if ($H -le 0) {
        throw "Relative height must be greater than 0 (got $H)."
    }

    $monitorFields = [ordered]@{ identity = $Anchor }

    if ($hasInstance) {
        $monitorFields["instance"] = $Instance
    }

    $relativeLayout = [pscustomobject][ordered]@{
        monitor = [pscustomobject]$monitorFields
        basis   = $Basis
        rect    = [pscustomobject][ordered]@{
            x = $X
            y = $Y
            w = $W
            h = $H
        }
    }

    $Item | Add-Member -NotePropertyName "layoutMode" -NotePropertyValue "relative" -Force
    $Item | Add-Member -NotePropertyName "layoutRelative" -NotePropertyValue $relativeLayout -Force

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $Item
}

function Set-DevWSItemAbsoluteGeometry {
    # Explicit relative-to-absolute conversion. The universal fallback
    # item.layout is preserved unless a replacement rectangle is supplied.
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $Item,
        $Rect = $null
    )

    if ($null -ne $Rect) {
        Set-DevWSLayout -Item $Item -Rect $Rect
    }

    $null = Clear-DevWSItemRelativeMode -Item $Item

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $Item
}

function Copy-DevWSTerminalTabs {
    param(
        [Parameter(Mandatory)]
        $Tabs
    )

    $copies = [System.Collections.Generic.List[object]]::new()

    foreach ($tab in @($Tabs)) {
        $arguments = @()

        if ($null -ne $tab.args) {
            $arguments = @($tab.args | ForEach-Object { $_ })
        }

        $copy = [ordered]@{
            command = $tab.command
            args    = $arguments
        }

        # Pass 6C: preserve an explicit per-tab path override exactly. A tab
        # without an override stays without one; never materialize a redundant
        # inherited path during cloning.
        if ($null -ne $tab) {
            $tabPath = [string]$tab.path

            if (-not [string]::IsNullOrWhiteSpace($tabPath)) {
                $copy["path"] = $tabPath
            }
        }

        $copies.Add([pscustomobject]$copy)
    }

    # The leading comma prevents PowerShell from unrolling a single-tab array
    # on return: tabs must always remain an array.
    return ,$copies.ToArray()
}

function Copy-DevWSAppLaunch {
    param(
        [Parameter(Mandatory)]
        $App
    )

    $arguments = @()

    if ($null -ne $App.launch.args) {
        $arguments = @($App.launch.args | ForEach-Object { $_ })
    }

    return [pscustomobject][ordered]@{
        kind  = [string]$App.launch.kind
        value = [string]$App.launch.value
        args  = $arguments
    }
}

function Assert-DevWSRenameTarget {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $Item,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$NewId,
        $Set
    )

    Assert-DevWSItemIdSyntax -Id $NewId

    # Pass 1 app-ID policy: numeric app ids are reserved for terminal aliases.
    if ($Item.type -eq "app" -and $NewId -match '^\d+$') {
        throw "App id '$NewId' must not be numeric. Numeric references are reserved for terminal aliases; use a descriptive id."
    }

    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set

    foreach ($candidate in @($target.windows)) {
        if (-not ($candidate.id -ieq $NewId)) {
            continue
        }

        # Case-only renames target the item itself and are not duplicates.
        if ([object]::ReferenceEquals($candidate, $Item)) {
            continue
        }

        throw "Workspace item '$NewId' already exists in set '$([string]$target.id)'."
    }

    # A terminal rename deliberately preserves the existing windowId, so the
    # generated default windowId for the new id is never created or checked.
}

function Rename-DevWSItem {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Reference,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$NewId,
        [string]$CommandName = "ws rename",
        $Set
    )

    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set
    $item = Resolve-DevWSItemById -Config $Config -Reference $Reference -CommandName $CommandName -Set $target

    Assert-DevWSRenameTarget -Config $Config -Item $item -NewId $NewId -Set $target

    $oldId = [string]$item.id

    # Identity model: `id` is the stable CLI/config identity; a terminal's
    # `windowId` is the Windows Terminal named-window identity. Rename changes
    # only the config id and deliberately preserves windowId so an existing
    # live window can still be recovered through UI Automation. Runtime HWND
    # state is disposable and is never migrated by this config mutation.
    $item.id = $NewId

    # Re-key the item's sparse entries in every layout profile of the target
    # set (case-only renames update the stored key casing in place).
    foreach ($profileObject in @(Get-DevWSLayoutProfiles -Set $target)) {
        Rename-DevWSLayoutProfileEntry -Profile $profileObject -OldId $oldId -NewId $NewId
    }

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return [pscustomobject]@{
        Item  = $item
        OldId = $oldId
        NewId = $NewId
    }
}

function Clone-DevWSTerminal {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SourceId,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$NewId,
        [string]$CommandName = "ws clone-terminal",
        $Set,
        $SourceSet
    )

    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set
    $sourceTarget = $target

    if ($PSBoundParameters.ContainsKey("SourceSet") -and $null -ne $SourceSet) {
        $sourceTarget = Resolve-DevWSTargetSet -Config $Config -Set $SourceSet
    }

    $source = Resolve-DevWSTerminalById -Config $Config -Reference $SourceId -CommandName $CommandName -Set $sourceTarget

    # New item validation: syntax, target-set uniqueness, and collision of the
    # generated set-qualified windowId against every configured terminal
    # windowId across all sets.
    $windowId = Assert-DevWSNewTerminalId -Config $Config -Id $NewId -Set $target

    $clone = [pscustomobject][ordered]@{
        id        = $NewId
        type      = "terminal"
        enabled   = [bool]$source.enabled
        windowId  = $windowId
        path      = [string]$source.path
        elevated  = [bool]$source.elevated
        tabs      = Copy-DevWSTerminalTabs -Tabs $source.tabs
        activeTab = [int]$source.activeTab
        layout    = Copy-DevWSLayout -Layout $source.layout
    }

    $relativeFields = Get-DevWSItemRelativeLayoutCopyFields -Item $source

    foreach ($name in @($relativeFields.Keys)) {
        $clone | Add-Member -NotePropertyName $name -NotePropertyValue $relativeFields[$name] -Force
    }

    $target.windows = @($target.windows) + $clone

    Copy-DevWSItemProfileOverrides `
        -SourceSet $sourceTarget `
        -TargetSet $target `
        -SourceItemId ([string]$source.id) `
        -TargetItemId ([string]$clone.id) `
        -SameSet:([string]$target.id -ieq [string]$sourceTarget.id)

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return [pscustomobject]@{
        SourceId = [string]$source.id
        Clone    = $clone
    }
}

function Clone-DevWSApp {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SourceId,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$NewId,
        [string]$CommandName = "ws clone-app",
        $Set,
        $SourceSet
    )

    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set
    $sourceTarget = $target

    if ($PSBoundParameters.ContainsKey("SourceSet") -and $null -ne $SourceSet) {
        $sourceTarget = Resolve-DevWSTargetSet -Config $Config -Set $SourceSet
    }

    $source = Resolve-DevWSAppById -Config $Config -Reference $SourceId -CommandName $CommandName -Set $sourceTarget

    $null = Assert-DevWSNewAppId -Config $Config -Id $NewId -Set $target

    # A clone initially shares the source match rule, so enabling it by
    # default could make two config items resolve to the same live window.
    # Clones are disabled templates until their match/launch definitions are
    # deliberately edited.
    $cloneDefinition = [ordered]@{
        id      = $NewId
        type    = "app"
        enabled = $false
        match   = [pscustomobject][ordered]@{
            kind  = [string]$source.match.kind
            value = [string]$source.match.value
        }
        launch  = Copy-DevWSAppLaunch -App $source
        layout  = Copy-DevWSLayout -Layout $source.layout
    }

    # Phase 8: a direct clone is an independent/dedicated template and must
    # never silently establish sharing with its source, so the clone is always
    # explicit 'dedicated' (even when the source is shared or transitional).
    $cloneDefinition["instanceMode"] = "dedicated"

    $relativeFields = Get-DevWSItemRelativeLayoutCopyFields -Item $source

    foreach ($name in @($relativeFields.Keys)) {
        $cloneDefinition[$name] = $relativeFields[$name]
    }

    $clone = [pscustomobject]$cloneDefinition

    $target.windows = @($target.windows) + $clone

    Copy-DevWSItemProfileOverrides `
        -SourceSet $sourceTarget `
        -TargetSet $target `
        -SourceItemId ([string]$source.id) `
        -TargetItemId ([string]$clone.id) `
        -SameSet:([string]$target.id -ieq [string]$sourceTarget.id)

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return [pscustomobject]@{
        SourceId = [string]$source.id
        Clone    = $clone
    }
}

function Copy-DevWSAppMatch {
    param(
        [Parameter(Mandatory)]
        $App
    )

    return [pscustomobject][ordered]@{
        kind  = [string]$App.match.kind
        value = [string]$App.match.value
    }
}

function Copy-DevWSTerminalDefinition {
    param(
        [Parameter(Mandatory)]
        $Terminal,
        [Parameter(Mandatory)]
        [string]$WindowId
    )

    $definition = [ordered]@{
        id        = [string]$Terminal.id
        type      = "terminal"
        enabled   = [bool]$Terminal.enabled
        windowId  = $WindowId
        path      = [string]$Terminal.path
        elevated  = [bool]$Terminal.elevated
        tabs      = Copy-DevWSTerminalTabs -Tabs $Terminal.tabs
        activeTab = [int]$Terminal.activeTab
        layout    = Copy-DevWSLayout -Layout $Terminal.layout
    }

    $relativeFields = Get-DevWSItemRelativeLayoutCopyFields -Item $Terminal

    foreach ($name in @($relativeFields.Keys)) {
        $definition[$name] = $relativeFields[$name]
    }

    return [pscustomobject]$definition
}

function Copy-DevWSAppDefinition {
    param(
        [Parameter(Mandatory)]
        $App
    )

    $definition = [ordered]@{
        id      = [string]$App.id
        type    = "app"
        enabled = [bool]$App.enabled
        match   = Copy-DevWSAppMatch -App $App
        launch  = Copy-DevWSAppLaunch -App $App
        layout  = Copy-DevWSLayout -Layout $App.layout
    }

    # Phase 8 transitional: a deep copy must never silently drop an explicit
    # instanceMode. A missing mode stays missing.
    $instanceMode = Get-DevWSAppInstanceMode -Item $App

    if ($null -ne $instanceMode) {
        $definition["instanceMode"] = $instanceMode
    }

    $relativeFields = Get-DevWSItemRelativeLayoutCopyFields -Item $App

    foreach ($name in @($relativeFields.Keys)) {
        $definition[$name] = $relativeFields[$name]
    }

    return [pscustomobject]$definition
}

# ---------------------------------------------------------------------------
# Set management (config only; callers persist once through Save-DevWSConfig)
# ---------------------------------------------------------------------------

function Assert-DevWSNewSetId {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Id
    )

    if ([string]::IsNullOrWhiteSpace($Id)) {
        throw "A non-empty set id is required."
    }

    if ($Id -match '[\r\n]') {
        throw "Set id must not contain newline characters."
    }

    if (-not (Test-DevWSStableIdSyntax -Id $Id)) {
        throw "Set id '$Id' may only contain letters, digits, '.', '_' and '-'; '/' is reserved for scoped references."
    }

    foreach ($set in @(Get-DevWSSets -Config $Config)) {
        if ($null -ne $set -and ([string]$set.id) -ieq $Id) {
            throw "Workspace set '$Id' already exists."
        }
    }
}

function Add-DevWSSet {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Id
    )

    Assert-DevWSNewSetId -Config $Config -Id $Id

    $set = [pscustomobject][ordered]@{
        id      = $Id
        windows = @()
    }

    $Config.sets = @($Config.sets) + $set

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $set
}

function Set-DevWSDefaultSet {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Reference
    )

    $set = Resolve-DevWSSet -Config $Config -Reference $Reference
    $changed = (-not (([string]$Config.defaultSet) -ieq ([string]$set.id)))

    if ($changed) {
        $Config.defaultSet = [string]$set.id
        Assert-DevWSConfig -Config $Config -Source "workspace mutation"
    }

    return [pscustomobject]@{
        Set     = $set
        Changed = $changed
    }
}

function Remove-DevWSSet {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Reference
    )

    $set = Resolve-DevWSSet -Config $Config -Reference $Reference

    $boundHotkeys = @()

    foreach ($binding in @(Get-DevWSBindings -Config $Config)) {
        if ($null -eq $binding -or $binding -isnot [System.Management.Automation.PSCustomObject]) {
            continue
        }

        $bindingSetId = Get-DevWSProperty -Object $binding -Name "setId"

        if ($bindingSetId -is [string] -and $bindingSetId -ieq ([string]$set.id)) {
            $boundHotkeys += [string](Get-DevWSProperty -Object $binding -Name "hotkey")
        }
    }

    if ($boundHotkeys.Count -gt 0) {
        $list = (@($boundHotkeys) | ForEach-Object { "  $_" }) -join [Environment]::NewLine

        throw ("Cannot remove set '$($set.id)': launch bindings still target it:" + [Environment]::NewLine + $list + [Environment]::NewLine + "Unbind them first with: ws unbind <hotkey>")
    }

    if (@(Get-DevWSSets -Config $Config).Count -le 1) {
        throw "Cannot remove the last remaining set. At least one workspace set must remain configured."
    }

    if (([string]$set.id) -ieq ([string]$Config.defaultSet)) {
        throw "Cannot remove the default set '$($set.id)'. Change the default first with: ws set-default <id>"
    }

    $Config.sets = @($Config.sets | Where-Object { -not (([string]$_.id) -ieq ([string]$set.id)) })

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $set
}

function Assert-DevWSRenameSetTarget {
    # Rename-specific stable-id validation for ONE resolved source set. Every
    # rule runs before any mutation so a refused rename can never partially
    # modify the supplied config object. The source set itself is excluded from
    # the collision scan: a case-only rename of the source is allowed, while a
    # case-insensitive collision with ANY other configured set is refused.
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $Set,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$NewId
    )

    if ([string]::IsNullOrWhiteSpace($NewId)) {
        throw "A non-empty new set id is required."
    }

    if ($NewId -match '[\r\n]') {
        throw "Set id must not contain newline characters."
    }

    if (-not (Test-DevWSStableIdSyntax -Id $NewId)) {
        throw "Set id '$NewId' may only contain letters, digits, '.', '_' and '-'; '/' is reserved for scoped references."
    }

    foreach ($other in @(Get-DevWSSets -Config $Config)) {
        if ($null -eq $other -or [object]::ReferenceEquals($other, $Set)) {
            continue
        }

        if (([string]$other.id) -ieq $NewId) {
            throw "Workspace set '$NewId' already exists."
        }
    }
}

function Rename-DevWSSet {
    # Identity-preserving canonical set rename (`ws rename-set`). NOT clone +
    # remove: the source set object keeps its array position and every item,
    # definition, windowId, tab, geometry and layout profile is preserved
    # exactly. Only the set identity and the canonical references that point to
    # it change:
    #   - set.id                     -> the exact requested new casing;
    #   - defaultSet                 -> rewritten only when it targets the set;
    #   - every bindings[].setId     -> rewritten only when it targets the set
    #                                   (binding hotkeys are never touched).
    #
    # Exact same spelling/casing is a no-op (Changed = $false, no mutation).
    # All validation failures happen before the first mutation. The completed
    # config is validated with Assert-DevWSConfig before the metadata returns;
    # persistence stays with the caller's existing single-save contract.
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$OldReference,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$NewId
    )

    $set = Resolve-DevWSSet -Config $Config -Reference $OldReference

    Assert-DevWSRenameSetTarget -Config $Config -Set $set -NewId $NewId

    $oldId = [string]$set.id

    if ($oldId -ceq $NewId) {
        return [pscustomobject]@{
            OldId               = $oldId
            NewId               = $NewId
            Changed             = $false
            CaseOnly            = $false
            DefaultSetRewritten = $false
            BindingsRewritten   = 0
            Set                 = $set
        }
    }

    $caseOnly = ($oldId -ieq $NewId)

    # ---- mutation (every validation above) ---------------------------------
    $set.id = $NewId

    $bindingsRewritten = 0

    foreach ($binding in @(Get-DevWSBindings -Config $Config)) {
        if ($null -eq $binding -or $binding -isnot [System.Management.Automation.PSCustomObject]) {
            continue
        }

        $bindingSetId = Get-DevWSProperty -Object $binding -Name "setId"

        if ($bindingSetId -is [string] -and $bindingSetId -ieq $oldId) {
            $binding.setId = $NewId
            $bindingsRewritten++
        }
    }

    $defaultSetRewritten = $false

    if (([string](Get-DevWSProperty -Object $Config -Name "defaultSet")) -ieq $oldId) {
        $Config.defaultSet = $NewId
        $defaultSetRewritten = $true
    }

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return [pscustomobject]@{
        OldId               = $oldId
        NewId               = $NewId
        Changed             = $true
        CaseOnly            = $caseOnly
        DefaultSetRewritten = $defaultSetRewritten
        BindingsRewritten   = $bindingsRewritten
        Set                 = $set
    }
}

function Add-DevWSBinding {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [string]$Hotkey
    )

    $set       = Resolve-DevWSSet -Config $Config -Reference $SetId
    $canonical = ConvertTo-DevWSBindingHotkey -Hotkey $Hotkey

    if (Test-DevWSReservedBindingHotkey -Hotkey $canonical) {
        throw "Hotkey '$canonical' is reserved: $(Get-DevWSReservedBindingHotkeyReason -Hotkey $canonical)"
    }

    foreach ($binding in @(Get-DevWSBindings -Config $Config)) {
        if ($null -eq $binding -or $binding -isnot [System.Management.Automation.PSCustomObject]) {
            continue
        }

        $existing = Get-DevWSProperty -Object $binding -Name "hotkey"
        $existingCanonical = $null

        if ($existing -is [string]) {
            try {
                $existingCanonical = ConvertTo-DevWSBindingHotkey -Hotkey $existing
            }
            catch {
                continue
            }
        }

        if ($existingCanonical -ceq $canonical) {
            $existingSetId = [string](Get-DevWSProperty -Object $binding -Name "setId")
            throw "Hotkey '$canonical' is already bound to set '$existingSetId'. Unbind it first with: ws unbind $canonical"
        }
    }

    $definition = [pscustomobject][ordered]@{
        hotkey = $canonical
        setId  = [string]$set.id
    }

    $Config.bindings = @(Get-DevWSBindings -Config $Config) + $definition

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $definition
}

function Remove-DevWSBinding {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$Hotkey
    )

    $canonical = ConvertTo-DevWSBindingHotkey -Hotkey $Hotkey
    $bindings  = @(Get-DevWSBindings -Config $Config)
    $match     = $null

    foreach ($binding in $bindings) {
        if ($null -eq $binding -or $binding -isnot [System.Management.Automation.PSCustomObject]) {
            continue
        }

        $existing = Get-DevWSProperty -Object $binding -Name "hotkey"

        if ($existing -isnot [string]) {
            continue
        }

        $existingCanonical = $null

        try {
            $existingCanonical = ConvertTo-DevWSBindingHotkey -Hotkey $existing
        }
        catch {
            continue
        }

        if ($existingCanonical -ceq $canonical) {
            $match = $binding
            break
        }
    }

    if ($null -eq $match) {
        throw "Hotkey '$canonical' is not a configured set launch binding. Run 'ws bindings' to list them."
    }

    $kept = @()

    foreach ($binding in $bindings) {
        if (-not [object]::ReferenceEquals($binding, $match)) {
            $kept += $binding
        }
    }

    $Config.bindings = $kept

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $match
}

function Clone-DevWSSet {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SourceId,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$NewId
    )

    $source = Resolve-DevWSSet -Config $Config -Reference $SourceId

    Assert-DevWSNewSetId -Config $Config -Id $NewId

    # Precompute every cloned definition and every generated terminal windowId
    # before mutating the config, so a collision cannot leave a partially
    # cloned set behind. Cloned terminals always receive a NEW set-qualified
    # identity; source windowIds are never copied.
    $planned = [System.Collections.Generic.List[object]]::new()
    $plannedWindowIds = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $existingWindowIds = [System.Collections.Generic.Dictionary[string, bool]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($candidateSet in @(Get-DevWSSets -Config $Config)) {
        if ($null -eq $candidateSet) {
            continue
        }

        foreach ($item in @($candidateSet.windows)) {
            if ($item.type -eq "terminal" -and -not [string]::IsNullOrWhiteSpace([string]$item.windowId)) {
                $existingWindowIds[[string]$item.windowId] = $true
            }
        }
    }

    foreach ($item in @($source.windows)) {
        if ($item.type -eq "terminal") {
            $windowId = Get-DevWSTerminalWindowId -SetId $NewId -ItemId ([string]$item.id)

            if ($existingWindowIds.ContainsKey($windowId)) {
                throw "Cannot clone set '$($source.id)' to '$NewId': generated windowId '$windowId' for terminal '$($item.id)' collides with an existing terminal."
            }

            if ($plannedWindowIds.ContainsKey($windowId)) {
                throw "Cannot clone set '$($source.id)' to '$NewId': duplicate generated windowId '$windowId'."
            }

            $plannedWindowIds[$windowId] = $true
            $planned.Add((Copy-DevWSTerminalDefinition -Terminal $item -WindowId $windowId))
        }
        else {
            $planned.Add((Copy-DevWSAppDefinition -App $item))
        }
    }

    # Set definitions deep-copy: item ids are preserved, so sparse profile
    # layout-map keys remain valid; profile ids, matchers and layout maps are
    # copied by logical content with no shared object references.
    $clonedSetFields = [ordered]@{
        id = $NewId
    }

    if (Test-DevWSSetHasLayoutProfiles -Set $source) {
        $clonedSetFields["layoutProfiles"] = @(Copy-DevWSLayoutProfiles -Profiles @(Get-DevWSLayoutProfiles -Set $source))
    }

    $clonedSetFields["windows"] = @($planned.ToArray())
    $newSet = [pscustomobject]$clonedSetFields

    $Config.sets = @($Config.sets) + $newSet

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return [pscustomobject]@{
        SourceId = [string]$source.id
        Clone    = $newSet
    }
}

function ConvertFrom-DevWSGeometryArguments {
    param(
        [AllowEmptyCollection()]
        [string[]]$Parts = @(),
        [string]$CommandName = "ws set-geometry",
        [switch]$AllowLayoutSelector
    )

    # Parses the ordinary absolute form, explicit relative authoring, and the
    # explicit `--mode absolute` conversion. Configuration-only: no topology
    # is read and no live window is inspected here.
    $names = @{
        x      = "x"
        y      = "y"
        width  = "w"
        height = "h"
    }

    $values = @{
        x        = $null
        y        = $null
        w        = $null
        h        = $null
        anchor   = $null
        instance = $null
        basis    = $null
        mode     = $null
    }

    $relative    = $false
    $layoutValue = $null
    $tokens      = @($Parts)
    $index       = 0

    $supportedSwitches = "--x, --y, --width, --height, --relative, --anchor, --instance, --basis, --mode"

    if ($AllowLayoutSelector) {
        $supportedSwitches = "--x, --y, --width, --height, --layout, --relative, --anchor, --instance, --basis, --mode"
    }

    while ($index -lt $tokens.Count) {
        $token = [string]$tokens[$index]

        if ($token -notmatch '^--?[A-Za-z]+$') {
            throw "$CommandName expects --x/--y/--width/--height switches; got '$token'."
        }

        $name       = $token.TrimStart('-').ToLowerInvariant()
        $doubleDash = $token.StartsWith("--", [System.StringComparison]::Ordinal)

        if ($name -eq "relative") {
            if (-not $doubleDash) {
                throw "Unknown switch '$token'. Supported switches: $supportedSwitches."
            }

            if ($relative) {
                throw "Duplicate switch '--relative'."
            }

            $relative = $true
            $index += 1
            continue
        }

        if ($name -eq "layout") {
            if (-not $AllowLayoutSelector -or -not $doubleDash) {
                throw "Unknown switch '$token'. Supported switches: $supportedSwitches."
            }

            if ($null -ne $layoutValue) {
                throw "Duplicate switch '$token'."
            }

            if (($index + 1) -ge $tokens.Count) {
                throw "Switch '--layout' requires a profile id or 'fallback'."
            }

            $layoutValue = [string]$tokens[$index + 1]

            if ([string]::IsNullOrWhiteSpace($layoutValue) -or $layoutValue.StartsWith('-')) {
                throw "Switch '--layout' requires a profile id or 'fallback'."
            }

            if (-not ($layoutValue -ieq "fallback" -or
                (Test-DevWSStableIdSyntax -Id $layoutValue -and -not (Test-DevWSLayoutProfileIdReserved -Id $layoutValue)))) {
                throw "Switch '--layout' expects 'fallback' or a profile id (letters, digits, '.', '_' and '-')."
            }

            $index += 2
            continue
        }

        if ($name -in @("anchor", "instance", "basis", "mode")) {
            if (-not $doubleDash) {
                throw "Unknown switch '$token'. Supported switches: $supportedSwitches."
            }

            if ($null -ne $values[$name]) {
                throw "Duplicate switch '$token'."
            }

            if (($index + 1) -ge $tokens.Count) {
                throw "Switch '--$name' requires a value."
            }

            $raw = [string]$tokens[$index + 1]

            if ([string]::IsNullOrWhiteSpace($raw) -or $raw.StartsWith('-')) {
                throw "Switch '--$name' requires a value."
            }

            $values[$name] = $raw
            $index += 2
            continue
        }

        if (-not $names.ContainsKey($name)) {
            throw "Unknown switch '$token'. Supported switches: $supportedSwitches."
        }

        $valueName = $names[$name]

        if ($null -ne $values[$valueName]) {
            throw "Duplicate switch '$token'."
        }

        if (($index + 1) -ge $tokens.Count) {
            throw "Switch '$token' requires an integer value."
        }

        $values[$valueName] = [string]$tokens[$index + 1]
        $index += 2
    }

    $modeExplicit = $null -ne $values.mode

    if ($relative -and $modeExplicit) {
        throw "--relative cannot be combined with --mode for $CommandName."
    }

    if ($relative -and $null -ne $layoutValue) {
        throw "--relative cannot be combined with --layout; relative authoring always edits the fallback relative layout for $CommandName."
    }

    if ($modeExplicit -and $null -ne $layoutValue) {
        throw "--mode cannot be combined with --layout for $CommandName."
    }

    if (-not $relative -and
        ($null -ne $values.anchor -or $null -ne $values.instance -or $null -ne $values.basis)) {
        throw "--anchor, --instance and --basis are only valid with --relative for $CommandName."
    }

    if ($modeExplicit -and $values.mode -ine "absolute") {
        if ($values.mode -ieq "relative") {
            throw "Use --relative to author relative geometry; --mode accepts only 'absolute' for $CommandName."
        }

        throw "Unsupported --mode value '$($values.mode)' for $CommandName; only 'absolute' is accepted."
    }

    $hasAnyCoordinate = $false

    foreach ($field in @("x", "y", "w", "h")) {
        if ($null -ne $values[$field]) {
            $hasAnyCoordinate = $true
        }
    }

    if ($relative) {
        if ($null -eq $values.anchor) {
            throw "--relative requires --anchor <identity> for $CommandName."
        }

        if ($null -eq $values.basis) {
            throw "--relative requires --basis workArea|monitor for $CommandName."
        }

        if (-not $hasAnyCoordinate) {
            throw "Usage: $CommandName <id> --relative --anchor <identity> [--instance <instance>] --basis workArea|monitor --x <fx> --y <fy> --width <fw> --height <fh>"
        }

        if (-not (Test-DevWSRelativeMonitorIdentitySyntax -Identity ([string]$values.anchor))) {
            throw "Relative anchor must be a durable monitor identity beginning with 'edid:' or 'path:' (got '$($values.anchor)')."
        }

        if ($null -ne $values.instance -and
            -not (Test-DevWSRelativeMonitorInstanceSyntax -Instance ([string]$values.instance))) {
            throw "Relative monitor instance must use the '<hardwareId>/<instance>' form (got '$($values.instance)')."
        }

        if ($null -ne $values.instance -and
            ([string]$values.anchor).StartsWith("path:", [System.StringComparison]::Ordinal)) {
            throw "A 'path:' relative anchor already embeds the device-path instance; omit --instance."
        }

        if ($values.basis -cne "workArea" -and $values.basis -cne "monitor") {
            throw "Relative basis must be exactly 'workArea' or 'monitor' (got '$($values.basis)')."
        }

        $fractionNames = @{ x = "--x"; y = "--y"; w = "--width"; h = "--height" }
        $fractions     = @{}

        foreach ($field in @("x", "y", "w", "h")) {
            if ($null -eq $values[$field]) {
                throw "Usage: $CommandName <id> --relative --anchor <identity> [--instance <instance>] --basis workArea|monitor --x <fx> --y <fy> --width <fw> --height <fh>"
            }

            $parsed = [double]0
            $raw    = [string]$values[$field]

            if (-not [double]::TryParse(
                $raw,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$parsed) -or
                -not [double]::IsFinite($parsed)) {
                throw "Switch '$($fractionNames[$field])' requires a finite fraction (got '$raw')."
            }

            $fractions[$field] = $parsed
        }

        if ($fractions.w -le 0) {
            throw "Relative width must be greater than 0 (got $($fractions.w))."
        }

        if ($fractions.h -le 0) {
            throw "Relative height must be greater than 0 (got $($fractions.h))."
        }

        return [pscustomobject][ordered]@{
            x            = [double]$fractions.x
            y            = [double]$fractions.y
            w            = [double]$fractions.w
            h            = [double]$fractions.h
            Layout       = $layoutValue
            Relative     = $true
            Anchor       = [string]$values.anchor
            Instance     = if ($null -ne $values.instance) { [string]$values.instance } else { $null }
            Basis        = [string]$values.basis
            Mode         = "relative"
            ModeExplicit = $false
        }
    }

    if ($modeExplicit) {
        if (-not $hasAnyCoordinate) {
            return [pscustomobject][ordered]@{
                x            = $null
                y            = $null
                w            = $null
                h            = $null
                Layout       = $layoutValue
                Relative     = $false
                Anchor       = $null
                Instance     = $null
                Basis        = $null
                Mode         = "absolute"
                ModeExplicit = $true
            }
        }

        $missingModeCoordinate = $false

        foreach ($field in @("x", "y", "w", "h")) {
            if ($null -eq $values[$field]) {
                $missingModeCoordinate = $true
            }
        }

        if ($missingModeCoordinate) {
            throw "Usage: $CommandName <id> --mode absolute [--x <x> --y <y> --width <width> --height <height>]"
        }
    }
    else {
        foreach ($field in @("x", "y", "w", "h")) {
            if ($null -eq $values[$field]) {
                $usageSuffix = ""

                if ($AllowLayoutSelector) {
                    $usageSuffix = " [--layout <profileId|fallback>]"
                }

                throw "Usage: $CommandName <id> --x <x> --y <y> --width <width> --height <height>$usageSuffix"
            }
        }
    }

    $parsedValues = @{}

    foreach ($field in @("x", "y", "w", "h")) {
        $raw    = [string]$values[$field]
        $parsed = 0

        if (-not [int]::TryParse($raw, [ref]$parsed)) {
            $switchName = switch ($field) { "x" { "--x" } "y" { "--y" } "w" { "--width" } "h" { "--height" } }
            throw "Switch '$switchName' requires an integer value (got '$raw'); decimals are not accepted."
        }

        $parsedValues[$field] = $parsed
    }

    if ([int]$parsedValues.w -le 0) {
        throw "Width must be greater than 0 (got $($parsedValues.w))."
    }

    if ([int]$parsedValues.h -le 0) {
        throw "Height must be greater than 0 (got $($parsedValues.h))."
    }

    return [pscustomobject][ordered]@{
        x            = [int]$parsedValues.x
        y            = [int]$parsedValues.y
        w            = [int]$parsedValues.w
        h            = [int]$parsedValues.h
        Layout       = $layoutValue
        Relative     = $false
        Anchor       = $null
        Instance     = $null
        Basis        = $null
        Mode         = "absolute"
        ModeExplicit = [bool]$modeExplicit
    }
}

function Set-DevWSItemGeometry {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $Item,
        [Parameter(Mandatory)]
        [int]$X,
        [Parameter(Mandatory)]
        [int]$Y,
        [Parameter(Mandatory)]
        [int]$W,
        [Parameter(Mandatory)]
        [int]$H
    )

    if ($W -le 0) {
        throw "Width must be greater than 0 (got $W)."
    }

    if ($H -le 0) {
        throw "Height must be greater than 0 (got $H)."
    }

    # Saved geometry only: the layout rectangle is replaced exactly like a
    # capture would; no live window is moved, resized, or touched.
    Set-DevWSLayout -Item $Item -Rect ([pscustomobject]@{
        x = $X
        y = $Y
        w = $W
        h = $H
    })

    Assert-DevWSConfig -Config $Config -Source "workspace mutation"

    return $Item
}

function Reset-DevWSLayoutsFromDefault {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $DefaultConfig,
        [string]$DefaultSource = "bundled default",
        $Set
    )

    $target = Resolve-DevWSTargetSet -Config $Config -Set $Set

    # The default is validated independently before anything is copied.
    Assert-DevWSConfig -Config $DefaultConfig -Source $DefaultSource

    # Sets are independent: only a same-id set in the bundled default can act
    # as a baseline. Never inherit another set's geometry.
    $defaultSetObject = $null

    foreach ($candidateSet in @(Get-DevWSSets -Config $DefaultConfig)) {
        if ($null -ne $candidateSet -and ([string]$candidateSet.id) -ieq ([string]$target.id)) {
            $defaultSetObject = $candidateSet
            break
        }
    }

    if ($null -eq $defaultSetObject) {
        return [pscustomobject]@{
            BaselineFound  = $false
            Matches        = @()
            Skipped        = @($target.windows)
            RelativeCleared = @()
        }
    }

    # Pass 1: resolve deterministic matches without mutating the config.
    $defaultById             = @{}
    $defaultTerminalByWindow = @{}

    foreach ($defaultItem in @($defaultSetObject.windows)) {
        $idKey = ([string]$defaultItem.id).ToLowerInvariant()

        if ($defaultById.ContainsKey($idKey)) {
            throw "$DefaultSource has duplicate ids; layout matching cannot be deterministic."
        }

        $defaultById[$idKey] = $defaultItem

        if ($defaultItem.type -eq "terminal") {
            $windowKey = ([string]$defaultItem.windowId).ToLowerInvariant()

            if ($defaultTerminalByWindow.ContainsKey($windowKey)) {
                throw "$DefaultSource has an ambiguous terminal windowId '$($defaultItem.windowId)'; layout matching cannot be deterministic."
            }

            $defaultTerminalByWindow[$windowKey] = $defaultItem
        }
    }

    $matches = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($target.windows)) {
        $idKey       = ([string]$item.id).ToLowerInvariant()
        $defaultItem = $null
        $matchedBy   = $null

        if ($defaultById.ContainsKey($idKey)) {
            $defaultItem = $defaultById[$idKey]
            $matchedBy   = "id"

            if ($defaultItem.type -ne $item.type) {
                throw "reset-layout type conflict for '$($item.id)': the bundled default defines it as '$($defaultItem.type)' while the configured item is '$($item.type)'. Layouts are only copied between matching ids of the same type."
            }
        }
        elseif ($item.type -eq "terminal") {
            # Renamed terminals keep their windowId (see ws rename); the
            # named-window identity is the fallback match. Apps never use it.
            $windowKey = ([string]$item.windowId).ToLowerInvariant()

            if ($defaultTerminalByWindow.ContainsKey($windowKey)) {
                $defaultItem = $defaultTerminalByWindow[$windowKey]
                $matchedBy   = "windowId"
            }
        }

        if ($null -eq $defaultItem) {
            $skipped.Add($item)
            continue
        }

        $matches.Add([pscustomobject]@{
            Item             = $item
            Default          = $defaultItem
            MatchedBy        = $matchedBy
            ClearedRelative  = $false
        })
    }

    # Pass 2: apply every resolved match in memory; the caller saves once.
    foreach ($match in $matches) {
        Set-DevWSLayout -Item $match.Item -Rect (Copy-DevWSLayout -Layout $match.Default.layout)
        $match.ClearedRelative = Clear-DevWSItemRelativeMode -Item $match.Item
    }

    if ($matches.Count -gt 0) {
        Assert-DevWSConfig -Config $Config -Source "workspace mutation"
    }

    $relativeCleared = @($matches | Where-Object { [bool]$_.ClearedRelative } | ForEach-Object { $_.Item })

    return [pscustomobject]@{
        BaselineFound   = $true
        Matches         = $matches.ToArray()
        Skipped         = $skipped.ToArray()
        RelativeCleared = $relativeCleared
    }
}
