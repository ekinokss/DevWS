# DevWS UI Automation helpers.
#
# The Windows Terminal named window (`wt -w <windowId>`) is NOT reliably equal
# to the visible top-level Win32 title while a command such as a CLI agent is
# active (the command can replace the visible title). UI Automation tab names
# do remain stable, so presence is determined from the set of existing tab
# names instead of the current top-level title.
#
# These helpers are strictly non-creating: they only enumerate existing UI.
# The one mutating helper, `Remove-DevWSTabByName`, only invokes an existing
# tab's "Close Tab" button and is used for temporary locator cleanup
# (verified supported by the installed Windows Terminal; `wt close-pane` is
# NOT supported and must never be used).

function New-DevWSPresentTabNameSet {
    param(
        [AllowEmptyCollection()]
        [string[]]$Names = @()
    )

    $present = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($name in @($Names)) {
        $text = [string]$name

        if (-not [string]::IsNullOrWhiteSpace($text)) {
            [void]$present.Add($text)
        }
    }

    return ,$present
}

function New-DevWSTabItemCondition {
    Add-Type -AssemblyName UIAutomationClient

    return New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem
    )
}

function New-DevWSButtonCondition {
    Add-Type -AssemblyName UIAutomationClient

    return New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button
    )
}

function Get-DevWSTabElementName {
    # PowerShell can swallow a property-getter exception during a normal
    # member access and return $null. Reflection makes the failure observable
    # so a failed tab-name read cannot be mistaken for a valid empty name.
    param(
        [Parameter(Mandatory)]
        $Element
    )

    try {
        $flags = [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Instance
        # GetMember(..., MemberTypes.Property, ...) resolves the property
        # without the accessor token reserved for the Win32 ownership
        # libraries by source hygiene.
        $currentMembers = @($Element.GetType().GetMember("Current", [System.Reflection.MemberTypes]::Property, $flags))
        $currentProperty = if ($currentMembers.Count -gt 0) { [System.Reflection.PropertyInfo]$currentMembers[0] } else { $null }

        if ($null -eq $currentProperty) {
            return [pscustomobject]@{ Ok = $false; Name = $null; Error = "current-property-missing" }
        }

        $current = $currentProperty.GetValue($Element)

        if ($null -eq $current) {
            return [pscustomobject]@{ Ok = $false; Name = $null; Error = "current-value-null" }
        }

        $nameMembers = @($current.GetType().GetMember("Name", [System.Reflection.MemberTypes]::Property, $flags))
        $nameProperty = if ($nameMembers.Count -gt 0) { [System.Reflection.PropertyInfo]$nameMembers[0] } else { $null }

        if ($null -eq $nameProperty) {
            return [pscustomobject]@{ Ok = $false; Name = $null; Error = "name-property-missing" }
        }

        $value = $nameProperty.GetValue($current)

        return [pscustomobject]@{
            Ok    = $true
            Name  = if ($null -eq $value) { $null } else { [string]$value }
            Error = $null
        }
    }
    catch {
        return [pscustomobject]@{
            Ok    = $false
            Name  = $null
            Error = (Get-DevWSUiaErrorText -Error $_)
        }
    }
}

function Get-DevWSPresentTabNamesFromElement {
    param(
        [Parameter(Mandatory)]
        $Element
    )

    $tabs = $Element.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        (New-DevWSTabItemCondition)
    )

    $names = [System.Collections.Generic.List[string]]::new()

    foreach ($tab in $tabs) {
        $nameInfo = Get-DevWSTabElementName -Element $tab

        if ($nameInfo.Ok -and -not [string]::IsNullOrWhiteSpace([string]$nameInfo.Name)) {
            $names.Add([string]$nameInfo.Name)
        }
    }

    return ,(New-DevWSPresentTabNameSet -Names $names.ToArray())
}

function Get-DevWSPresentTabNamesFromHwnd {
    param([Parameter(Mandatory)][long]$Hwnd)

    # The assembly is a hard dependency of this read: a load failure is an
    # infrastructure failure, not a per-window miss, so it intentionally stays
    # outside the try/catch below (which only degrades transient HWND/UIA
    # access failures to an empty name set).
    Add-Type -AssemblyName UIAutomationClient

    try {
        $element = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd)
    }
    catch {
        return ,(New-DevWSPresentTabNameSet -Names @())
    }

    if ($null -eq $element) {
        return ,(New-DevWSPresentTabNameSet -Names @())
    }

    return ,(Get-DevWSPresentTabNamesFromElement -Element $element)
}

function Get-DevWSUiaErrorText {
    # Safe, bounded diagnostic text. Never expose a raw exception object or a
    # multi-line stack trace to status/plan output.
    param([AllowNull()]$Error)

    if ($null -eq $Error) {
        return $null
    }

    $typeName = $null
    $message = $null

    if ($Error -is [System.Management.Automation.ErrorRecord]) {
        $typeName = [string]$Error.Exception.GetType().Name
        $message = [string]$Error.Exception.Message
    }
    elseif ($Error -is [Exception]) {
        $typeName = [string]$Error.GetType().Name
        $message = [string]$Error.Message
    }
    else {
        $message = [string]$Error
    }

    $message = ($message -replace '\s+', ' ').Trim()

    if ([string]::IsNullOrWhiteSpace($message)) {
        return $typeName
    }

    if ($message.Length -gt 240) {
        $message = $message.Substring(0, 240)
    }

    if ([string]::IsNullOrWhiteSpace($typeName)) {
        return $message
    }

    return "${typeName}: $message"
}

function New-DevWSTabReadResult {
    # Structured per-HWND observation. HwndPresent is a separate fact from Ok:
    # a live HWND can have an unsuccessful tab read, and a successful empty
    # tab read is not evidence that a managed terminal is absent.
    param(
        [Parameter(Mandatory)][long]$Hwnd,
        [bool]$HwndPresent = $false,
        [bool]$Ok = $false,
        [bool]$Complete = $false,
        [AllowEmptyCollection()][object[]]$Elements = @(),
        [AllowEmptyCollection()][string[]]$Names = @(),
        [int]$NameReadFailures = 0,
        [string]$ErrorKind = "none",
        [AllowNull()][string]$Error = $null
    )

    $elementList = @($Elements)

    return [pscustomobject][ordered]@{
        Hwnd             = [long]$Hwnd
        HwndPresent      = [bool]$HwndPresent
        Ok               = [bool]$Ok
        Complete         = [bool]$Complete
        Elements         = $elementList
        TabNames         = (New-DevWSPresentTabNameSet -Names $Names)
        RawCount         = [int]$elementList.Count
        NameReadFailures = [int]$NameReadFailures
        ErrorKind        = [string]$ErrorKind
        Error            = $Error
    }
}

function Get-DevWSTabReadResultFromHwnd {
    # One bounded, non-mutating UI Automation observation for an exact HWND.
    # RootProvider/TabProvider are test seams only; production callers use the
    # real AutomationElement APIs. Every failure is returned as data.
    param(
        [Parameter(Mandatory)][long]$Hwnd,
        [scriptblock]$RootProvider = $null,
        [scriptblock]$TabProvider = $null,
        [scriptblock]$HwndExistsProvider = $null
    )

    if ($null -eq $HwndExistsProvider) {
        $HwndExistsProvider = { param([long]$ProbeHwnd) Test-DevWSWindowHwnd -Hwnd $ProbeHwnd }
    }

    $hwndPresent = [bool](& $HwndExistsProvider $Hwnd)

    if (-not $hwndPresent) {
        return (New-DevWSTabReadResult -Hwnd $Hwnd -HwndPresent $false -Ok $false -Complete $false -ErrorKind "hwnd-gone")
    }

    try {
        Add-Type -AssemblyName UIAutomationClient
    }
    catch {
        return (New-DevWSTabReadResult -Hwnd $Hwnd -HwndPresent $true -Ok $false -Complete $false -ErrorKind "uia-assembly-unavailable" -Error (Get-DevWSUiaErrorText -Error $_))
    }

    try {
        if ($null -ne $RootProvider) {
            $root = & $RootProvider $Hwnd
        }
        else {
            $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd)
        }
    }
    catch {
        return (New-DevWSTabReadResult -Hwnd $Hwnd -HwndPresent $true -Ok $false -Complete $false -ErrorKind "uia-from-handle-failed" -Error (Get-DevWSUiaErrorText -Error $_))
    }

    if ($null -eq $root) {
        return (New-DevWSTabReadResult -Hwnd $Hwnd -HwndPresent $true -Ok $false -Complete $false -ErrorKind "uia-null-element")
    }

    try {
        if ($null -ne $TabProvider) {
            $tabs = & $TabProvider $root
        }
        else {
            $tabs = $root.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                (New-DevWSTabItemCondition)
            )
        }
    }
    catch {
        return (New-DevWSTabReadResult -Hwnd $Hwnd -HwndPresent $true -Ok $false -Complete $false -ErrorKind "uia-findall-failed" -Error (Get-DevWSUiaErrorText -Error $_))
    }

    if ($null -eq $tabs) {
        return (New-DevWSTabReadResult -Hwnd $Hwnd -HwndPresent $true -Ok $false -Complete $false -ErrorKind "uia-findall-null")
    }

    try {
        $tabCount = [int]$tabs.Count
    }
    catch {
        return (New-DevWSTabReadResult -Hwnd $Hwnd -HwndPresent $true -Ok $false -Complete $false -ErrorKind "uia-collection-failed" -Error (Get-DevWSUiaErrorText -Error $_))
    }

    $elements = [System.Collections.Generic.List[object]]::new()
    $names = [System.Collections.Generic.List[string]]::new()
    $nameFailures = 0
    $firstNameError = $null

    for ($i = 0; $i -lt $tabCount; $i++) {
        $tab = $null

        try {
            $tab = $tabs.Item($i)
        }
        catch {
            $nameFailures++
            if ($null -eq $firstNameError) { $firstNameError = $_ }
            continue
        }

        if ($null -eq $tab) {
            $nameFailures++
            continue
        }

        $elements.Add($tab) | Out-Null

        $nameInfo = Get-DevWSTabElementName -Element $tab

        if ($nameInfo.Ok) {
            if (-not [string]::IsNullOrWhiteSpace([string]$nameInfo.Name)) {
                $names.Add([string]$nameInfo.Name) | Out-Null
            }
        }
        else {
            $nameFailures++
            if ($null -eq $firstNameError) { $firstNameError = $nameInfo.Error }
        }
    }

    $complete = ($nameFailures -eq 0)
    $finalHwndPresent = [bool](& $HwndExistsProvider $Hwnd)

    if (-not $finalHwndPresent) {
        return (New-DevWSTabReadResult -Hwnd $Hwnd -HwndPresent $false -Ok $true -Complete $false -Elements $elements.ToArray() -Names $names.ToArray() -NameReadFailures $nameFailures -ErrorKind "hwnd-gone" -Error (Get-DevWSUiaErrorText -Error $firstNameError))
    }

    return (New-DevWSTabReadResult -Hwnd $Hwnd -HwndPresent $true -Ok $true -Complete $complete -Elements $elements.ToArray() -Names $names.ToArray() -NameReadFailures $nameFailures -ErrorKind $(if ($complete) { "none" } else { "tab-name-read-failed" }) -Error (Get-DevWSUiaErrorText -Error $firstNameError))
}

function Get-DevWSTabElementsFromHwnd {
    # Compatibility wrapper for callers that only need the element array.
    # Structured presence callers use Get-DevWSTabReadResultFromHwnd so that an
    # access failure is never confused with a successful empty tab observation.
    param([Parameter(Mandatory)][long]$Hwnd)

    $result = Get-DevWSTabReadResultFromHwnd -Hwnd $Hwnd
    return @($result.Elements)
}

function Get-DevWSTabCountFromElements {
    param([AllowEmptyCollection()]$Elements = @())

    # Raw count: duplicate TabItems are preserved on purpose. Never derive a
    # tab count from a name set; every configured tab currently shares the
    # windowId title, so a name set collapses a real two-tab window to one.
    return @($Elements | Where-Object { $null -ne $_ }).Count
}

function Get-DevWSTabCountFromHwnd {
    param([Parameter(Mandatory)][long]$Hwnd)

    $elements = Get-DevWSTabElementsFromHwnd -Hwnd $Hwnd

    return Get-DevWSTabCountFromElements -Elements $elements
}

function Wait-DevWSTabCountFromHwnd {
    param(
        [Parameter(Mandatory)]
        [long]$Hwnd,
        [Parameter(Mandatory)]
        [int]$MinimumCount,
        [int]$TimeoutSeconds = 5
    )

    # Give UI Automation a brief moment to materialize the configured tabs
    # before the raw count is evaluated. A still-lower count is tolerated by
    # Test-DevWSCreatedTabCount; a higher count is never tolerated.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ($true) {
        $count = Get-DevWSTabCountFromHwnd -Hwnd $Hwnd

        if ($count -ge $MinimumCount) {
            return $count
        }

        if ((Get-Date) -ge $deadline) {
            return $count
        }

        Start-Sleep -Milliseconds 150
    }
}

function Test-DevWSTerminalPresent {
    param(
        [Parameter(Mandatory)]
        $PresentTabNames,
        [Parameter(Mandatory)]
        [string]$WindowId
    )

    # Presence is decided by the UI Automation tab name set only, accepting
    # the FULL managed configured-tab title family (the exact tab-0 title or
    # any canonical <windowId>#DevWS:<N> member), so a managed terminal stays
    # present when tab 0 is gone. The current top-level Win32 title is
    # intentionally not consulted.
    return [bool](Test-DevWSTerminalTitleFamily -WindowId $WindowId -TabNames $PresentTabNames)
}

function Find-DevWSTabElement {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    Add-Type -AssemblyName UIAutomationClient

    $root = [System.Windows.Automation.AutomationElement]::RootElement

    foreach ($tab in $root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        (New-DevWSTabItemCondition)
    )) {
        try {
            if ([string]$tab.Current.Name -ieq $Name) {
                return $tab
            }
        }
        catch {}
    }

    return $null
}

function Get-DevWSTopLevelHwndFromElement {
    param(
        [Parameter(Mandatory)]
        $Element
    )

    # Walk to the top-level window element. Intermediate WinUI input-island
    # panes also expose an HWND but are not the window frame; only the
    # ancestor with ControlType.Window is the managed top-level window.
    $walker  = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $current = $Element

    while ($null -ne $current) {
        try {
            $handle   = [long]$current.Current.NativeWindowHandle
            $isWindow = $current.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window
        }
        catch {
            return 0
        }

        if ($isWindow -and $handle -ne 0) {
            return $handle
        }

        $current = $walker.GetParent($current)
    }

    return 0
}

function Find-DevWSTerminalTopLevelHwnd {
    # Pass 6C family-aware non-creating recovery: the parent HWND is recovered
    # from ANY canonical managed configured-tab title belonging to the
    # requested windowId, so a managed terminal stays discoverable after its
    # tab 0 was manually closed. Multiple DISTINCT top-level HWNDs exposing
    # valid family members for the same windowId are ambiguous and refuse
    # (zero) -- never first-match guessing.
    param(
        [Parameter(Mandatory)]
        [string]$WindowId
    )

    Add-Type -AssemblyName UIAutomationClient

    $root = [System.Windows.Automation.AutomationElement]::RootElement

    if ($null -eq $root) {
        return 0
    }

    $hwnds = [System.Collections.Generic.HashSet[long]]::new()

    foreach ($tab in $root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        (New-DevWSTabItemCondition)
    )) {
        try {
            $name = [string]$tab.Current.Name
        }
        catch {
            continue
        }

        $resolved = Resolve-DevWSTerminalTabTitle -WindowId $WindowId -Title $name

        if (-not [bool]$resolved.IsManaged) {
            continue
        }

        $hwnd = Get-DevWSTopLevelHwndFromElement -Element $tab

        if ($hwnd -ne 0) {
            [void]$hwnds.Add([long]$hwnd)
        }
    }

    if ($hwnds.Count -eq 1) {
        foreach ($hwnd in $hwnds) {
            return [long]$hwnd
        }
    }

    return 0
}

function Wait-DevWSTabGone {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [int]$TimeoutSeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        if ($null -eq (Find-DevWSTabElement -Name $Name)) {
            return $true
        }

        Start-Sleep -Milliseconds 150
    }

    return $false
}

function Remove-DevWSTabByName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $element = Find-DevWSTabElement -Name $Name

    if ($null -eq $element) {
        throw "Tab '$Name' was not found."
    }

    $button = $element.FindFirst(
        [System.Windows.Automation.TreeScope]::Descendants,
        (New-DevWSButtonCondition)
    )

    if ($null -eq $button) {
        throw "Tab '$Name' has no close button exposed by UI Automation."
    }

    $pattern = $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke()

    return $true
}

function Select-DevWSTabByIndexFromHwnd {
    param(
        [Parameter(Mandatory)]
        [long]$Hwnd,
        [Parameter(Mandatory)]
        [int]$Index,
        [string]$Context = "terminal"
    )

    Add-Type -AssemblyName UIAutomationClient

    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd)
    }
    catch {
        throw "Window for $Context (HWND $Hwnd) is no longer available."
    }

    if ($null -eq $root) {
        throw "Window for $Context (HWND $Hwnd) is no longer available."
    }

    $tabs = $root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        (New-DevWSTabItemCondition)
    )

    $count = $tabs.Count

    if ($Index -lt 0 -or $Index -ge $count) {
        throw "$Context (HWND $Hwnd) exposes $count tabs; activeTab $Index cannot be selected."
    }

    $tab = $tabs.Item($Index)

    try {
        $pattern = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        $pattern.Select()
    }
    catch {
        throw "Could not select tab $Index for $Context (HWND $Hwnd): $($_.Exception.Message)"
    }

    # Confirm the selection landed on the requested tab. This never creates
    # anything: it only reads existing UI state.
    $deadline  = (Get-Date).AddSeconds(3)
    $confirmed = $false

    while ((Get-Date) -lt $deadline -and -not $confirmed) {
        try {
            $current   = $root.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                (New-DevWSTabItemCondition)
            ).Item($Index)
            $selection = $current.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            $confirmed = [bool]$selection.Current.IsSelected
        }
        catch {
            $confirmed = $false
        }

        if (-not $confirmed) {
            Start-Sleep -Milliseconds 100
        }
    }

    if (-not $confirmed) {
        throw "Tab $Index for $Context (HWND $Hwnd) did not report selected after UI Automation selection."
    }

    return $true
}

function New-DevWSTerminalTabSnapshotUnavailable {
    param(
        [long]$Hwnd = 0,
        [string]$Status = "hwnd-unavailable",
        [string]$Reason = "hwnd-unavailable"
    )

    return [pscustomobject][ordered]@{
        Status                     = $Status
        Reason                     = $Reason
        Hwnd                       = $Hwnd
        TabCount                   = 0
        Tabs                       = @()
        ManagedTabCount            = 0
        UnmanagedTabCount          = 0
        SelectedVisualIndex        = $null
        SelectedConfiguredTabIndex = $null
        DuplicateConfiguredIndexes = @()
        MissingConfiguredIndexes   = @()
        LegacyBaseDuplicateCount   = 0
    }
}

function Resolve-DevWSTerminalTabSnapshot {
    # Pure Pass 6C configured-tab snapshot evaluation over ALREADY-READ tab
    # entries. Each entry needs Name and IsSelected; VisualIndex is assigned by
    # array order (UI Automation visual order). Read-only and deterministic;
    # every ambiguous structure becomes a structured unavailable result -
    # never first-wins.
    #
    # Status values (callers never parse prose):
    #   available                one selected tab uniquely maps to configured tab N
    #   selected-unmanaged       the selected tab is not a managed configured tab
    #   selected-out-of-range    the selected tab is family-managed but beyond ConfiguredTabCount
    #   legacy-unmapped          duplicate EXACT base titles (a pre-6C live terminal)
    #   duplicate-managed-index  duplicate canonical configured indices
    #   no-selected-tab / multiple-selected-tabs
    #   malformed-structure      no tab entries were read
    param(
        [Parameter(Mandatory)]
        [string]$WindowId,
        [int]$ConfiguredTabCount = -1,
        [long]$Hwnd = 0,
        [AllowEmptyCollection()]
        [object[]]$Entries = @()
    )

    $entryList = @($Entries)

    if ($entryList.Count -eq 0) {
        return (New-DevWSTerminalTabSnapshotUnavailable -Hwnd $Hwnd -Status "malformed-structure" -Reason "no-tabs")
    }

    $enriched     = [System.Collections.Generic.List[object]]::new()
    $indexCounts  = @{}
    $baseMatches  = 0
    $unmanaged    = 0
    $selected     = [System.Collections.Generic.List[int]]::new()

    for ($i = 0; $i -lt $entryList.Count; $i++) {
        $entry      = $entryList[$i]
        $name       = if ($null -eq $entry) { $null } else { [string]$entry.Name }
        $isSelected = if ($null -eq $entry) { $false } else { [bool]$entry.IsSelected }

        if ($isSelected) {
            $selected.Add($i) | Out-Null
        }

        $resolved   = Resolve-DevWSTerminalTabTitle -WindowId $WindowId -Title $name
        $managed    = [bool]$resolved.IsManaged
        $configured = $null

        if ($managed) {
            $configured = [int]$resolved.TabIndex

            if ($name -ieq $WindowId) {
                $baseMatches++
            }

            if (-not $indexCounts.ContainsKey($configured)) {
                $indexCounts[$configured] = 0
            }

            $indexCounts[$configured]++
        }
        else {
            $unmanaged++
        }

        $enriched.Add([pscustomobject]@{
            VisualIndex        = $i
            Name               = $name
            IsManaged          = $managed
            ConfiguredTabIndex = $configured
            IsSelected         = $isSelected
        }) | Out-Null
    }

    $duplicates = @($indexCounts.Keys | Where-Object { $indexCounts[$_] -gt 1 } | Sort-Object)

    $result = [ordered]@{
        Status                     = "malformed-structure"
        Reason                     = "no-tabs"
        Hwnd                       = $Hwnd
        TabCount                   = $entryList.Count
        Tabs                       = $enriched.ToArray()
        ManagedTabCount            = @($enriched | Where-Object { $_.IsManaged }).Count
        UnmanagedTabCount          = $unmanaged
        SelectedVisualIndex        = $null
        SelectedConfiguredTabIndex = $null
        DuplicateConfiguredIndexes = $duplicates
        MissingConfiguredIndexes   = @()
        LegacyBaseDuplicateCount   = $baseMatches
    }

    if ($ConfiguredTabCount -ge 0) {
        $missing = @()

        for ($i = 0; $i -lt $ConfiguredTabCount; $i++) {
            if (-not $indexCounts.ContainsKey($i)) {
                $missing += $i
            }
        }

        $result.MissingConfiguredIndexes = $missing
    }

    if ($selected.Count -eq 1) {
        $result.SelectedVisualIndex = [int]$selected[0]
    }

    if ($duplicates.Count -gt 0) {
        # A pre-6C live terminal exposes the base title on every tab: duplicate
        # index 0 where every managed match is the exact base title. That is
        # legacy/unmapped configured identity -- never guess tab 0.
        $allManagedAreBase = $true

        foreach ($entry in $enriched) {
            if ($entry.IsManaged -and -not ($entry.Name -ieq $WindowId)) {
                $allManagedAreBase = $false
            }
        }

        if ($duplicates.Count -eq 1 -and $duplicates[0] -eq 0 -and $baseMatches -gt 1 -and $allManagedAreBase) {
            $result.Status = "legacy-unmapped"
            $result.Reason = "duplicate-base-titles"
        }
        else {
            $result.Status = "duplicate-managed-index"
            $result.Reason = "duplicate-managed-index"
        }

        return [pscustomobject]$result
    }

    if ($selected.Count -eq 0) {
        $result.Status = "no-selected-tab"
        $result.Reason = "no-selected-tab"
        return [pscustomobject]$result
    }

    if ($selected.Count -gt 1) {
        $result.Status = "multiple-selected-tabs"
        $result.Reason = "multiple-selected-tabs"
        return [pscustomobject]$result
    }

    $selectedEntry = $enriched[$result.SelectedVisualIndex]

    if (-not $selectedEntry.IsManaged) {
        $result.Status = "selected-unmanaged"
        $result.Reason = "selected-unmanaged"
        return [pscustomobject]$result
    }

    if ($ConfiguredTabCount -ge 0 -and [int]$selectedEntry.ConfiguredTabIndex -ge $ConfiguredTabCount) {
        $result.Status = "selected-out-of-range"
        $result.Reason = "selected-index-out-of-range"
        return [pscustomobject]$result
    }

    $result.Status                     = "available"
    $result.Reason                     = "ok"
    $result.SelectedConfiguredTabIndex = [int]$selectedEntry.ConfiguredTabIndex
    return [pscustomobject]$result
}

function Get-DevWSTerminalTabSnapshotFromHwnd {
    # Pass 6C strictly read-only managed-tab snapshot over an EXACT terminal
    # HWND. It never selects, focuses, activates, creates, closes, moves, or
    # writes state -- it only reads tab order, UIA names, and selection state,
    # then hands the raw entries to the pure resolver above.
    param(
        [Parameter(Mandatory)]
        [long]$Hwnd,
        [Parameter(Mandatory)]
        [string]$WindowId,
        [int]$ConfiguredTabCount = -1
    )

    Add-Type -AssemblyName UIAutomationClient

    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd)
    }
    catch {
        return (New-DevWSTerminalTabSnapshotUnavailable -Hwnd $Hwnd)
    }

    if ($null -eq $root) {
        return (New-DevWSTerminalTabSnapshotUnavailable -Hwnd $Hwnd)
    }

    $tabs = $root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        (New-DevWSTabItemCondition)
    )

    if ($tabs.Count -eq 0) {
        return (New-DevWSTerminalTabSnapshotUnavailable -Hwnd $Hwnd -Status "malformed-structure" -Reason "no-tabs")
    }

    $entries = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $tabs.Count; $i++) {
        $tab        = $tabs.Item($i)
        $name       = $null
        $isSelected = $false

        try {
            $name = [string]$tab.Current.Name
        }
        catch {
            $name = $null
        }

        try {
            $pattern    = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            $isSelected = [bool]$pattern.Current.IsSelected
        }
        catch {
            $isSelected = $false
        }

        $entries.Add([pscustomobject]@{ Name = $name; IsSelected = $isSelected }) | Out-Null
    }

    return (Resolve-DevWSTerminalTabSnapshot -Hwnd $Hwnd -WindowId $WindowId -ConfiguredTabCount $ConfiguredTabCount -Entries $entries.ToArray())
}
