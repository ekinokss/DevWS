# DevWS canonical terminal launch policy (Stage 2 two-warm-host architecture).
#
# ONE implementation of elevated managed-terminal planning, kickoff and
# completion. Both the persistent elevated broker
# (workers\elevated-broker.ps1) and the task-driven fallback worker
# (workers\elevated.ps1) call these functions; no terminal launch policy is
# duplicated anywhere else.
#
# Planning contract (side-effect free):
#   - state-first validation: a validated set-scoped runtime-state HWND makes a
#     terminal present/state and can never later be reclassified missing;
#   - a live but unreadable state or candidate HWND is `inaccessible`, never
#     `missing`, and the launch planner refuses creation for it;
#   - one fast native CASCADIA_HOSTING_WINDOW_CLASS enumeration;
#   - zero unmatched WT candidates => unresolved terminals are missing with no
#     UI Automation traversal at all (fast-missing);
#   - only unmatched candidate HWNDs receive managed per-HWND UI Automation
#     reads (never a global desktop scan, never raw IUIAutomation COM);
#   - an initializing WT window that momentarily exposes zero tabs is retried
#     boundedly before any conclusion (never attach to an existing window);
#   - duplicate windowId across distinct HWNDs is an explicit `ambiguous`
#     refusal (state HWND wins only when it itself validates); it is never
#     `missing` and never a first-match;
#   - the plan carries a cheap WT-generation token (sorted top-level HWND set)
#     revalidated immediately before kickoff.
#
# Each terminal record is built exactly once with final classification values;
# no ordered-dictionary/object is mutated after a copy is taken.
#
# Kickoff: one ProcessStartInfo WT invocation per missing terminal, back to
# back, exact argument boundaries, no waits.
#
# Completion: ONE shared polling loop resolves every pending windowId from one
# batch snapshot per tick; per-terminal failure aggregation stays in configured
# order.

$script:DevWSTerminalLaunchIdentityTimeoutSecondsDefault = 15
$script:DevWSTerminalLaunchPollMillisecondsDefault       = 250
$script:DevWSTerminalEmptyTabRetryCountDefault           = 2
$script:DevWSTerminalEmptyTabRetryDelayMilliseconds      = 250

function Test-DevWSTerminalTopLevelHwnd {
    # Exact-HWND class check for a state-associated window that was not in the
    # class-scoped candidate enumeration. No UI Automation and no mutation.
    param([Parameter(Mandatory)][long]$Hwnd)

    if (-not (Test-DevWSWindowHwnd -Hwnd $Hwnd)) {
        return $false
    }

    Initialize-DevWSNativeRuntime
    return [bool][DevWSTerminalNative]::IsWindowsTerminalTopLevelHwnd([long]$Hwnd)
}

function Get-DevWSTerminalTopLevelHwnds {
    # Fast class-scoped enumeration; the filter runs in C#.
    Initialize-DevWSNativeRuntime
    return [long[]][DevWSTerminalNative]::GetWindowsTerminalTopLevelHwnds()
}

function Read-DevWSTerminalHwndTabs {
    # One managed per-HWND UI Automation read. The result distinguishes HWND
    # liveness from successful tab observation and preserves bounded retries
    # for genuine Windows Terminal initialization. A failed or still-empty read
    # is not evidence of absence.
    param(
        [Parameter(Mandatory)][long]$Hwnd,
        [int]$EmptyRetryCount = $script:DevWSTerminalEmptyTabRetryCountDefault,
        [int]$EmptyRetryDelayMilliseconds = $script:DevWSTerminalEmptyTabRetryDelayMilliseconds,
        [scriptblock]$TabReadProvider = $null
    )

    if ($null -eq $TabReadProvider) {
        $TabReadProvider = { param([long]$ReadHwnd) Get-DevWSTabReadResultFromHwnd -Hwnd $ReadHwnd }
    }

    $attempt = 0

    while ($true) {
        $read = & $TabReadProvider $Hwnd

        $hasHwndPresent = $null -ne $read.PSObject.Properties["HwndPresent"]
        $hasReadOk      = $null -ne $read.PSObject.Properties["ReadOk"]
        $hasComplete    = $null -ne $read.PSObject.Properties["Complete"]

        $hwndPresent = if ($hasHwndPresent) { [bool]$read.HwndPresent } else { [bool]$read.Ok }
        $readOk      = if ($hasReadOk) { [bool]$read.ReadOk } else { [bool]$read.Ok }
        $complete    = if ($hasComplete) { [bool]$read.Complete } else { $true }
        $rawCount    = [int]$read.RawCount
        $nameFailures = if ($null -ne $read.PSObject.Properties["NameReadFailures"]) { [int]$read.NameReadFailures } else { 0 }

        if ($hwndPresent -and $readOk -and $rawCount -gt 0 -and $complete -and $nameFailures -eq 0) { break }
        if (-not $hwndPresent) { break }
        if (-not $readOk) { break }
        if ($attempt -ge $EmptyRetryCount) { break }

        $attempt++
        Start-Sleep -Milliseconds $EmptyRetryDelayMilliseconds
    }

    $tabNames = $read.TabNames

    if ($null -eq $tabNames) {
        $tabNames = New-DevWSPresentTabNameSet -Names @()
    }

    return [pscustomobject]@{
        Ok               = [bool]$hwndPresent
        HwndPresent      = [bool]$hwndPresent
        ReadOk           = [bool]$readOk
        Complete         = [bool]$complete
        TabNames         = $tabNames
        RawCount         = [int]$rawCount
        NameReadFailures = [int]$nameFailures
        EmptyRetries     = $attempt
        ErrorKind        = if ($null -ne $read.PSObject.Properties["ErrorKind"]) { [string]$read.ErrorKind } else { "none" }
        Error            = if ($null -ne $read.PSObject.Properties["Error"]) { [string]$read.Error } else { $null }
    }
}

function Get-DevWSTerminalWindowSnapshot {
    # One batch snapshot: every current WT top-level HWND with its process name,
    # tab-name set and raw tab count.
    param([long[]]$WtHwnds)

    if (-not $PSBoundParameters.ContainsKey("WtHwnds")) {
        $WtHwnds = Get-DevWSTerminalTopLevelHwnds
    }

    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($hwnd in @($WtHwnds)) {
        $read = Read-DevWSTerminalHwndTabs -Hwnd $hwnd

        $entries.Add([pscustomobject]@{
            Hwnd        = [long]$hwnd
            ProcessName = (Get-DevWSWindowHwndProcessName -Hwnd $hwnd)
            TabNames    = $read.TabNames
            RawCount    = [int]$read.RawCount
        }) | Out-Null
    }

    return $entries.ToArray()
}

function New-DevWSTerminalPlanRecord {
    # One terminal plan record, built once with final values. ApplyGeometry
    # and Layout are the FROZEN placement decision for this record: production
    # callers supply explicit placements; direct callers without a placement
    # map keep the historical default (move=true, Terminal.layout).
    param(
        [Parameter(Mandatory)][int]$Order,
        [Parameter(Mandatory)]$Terminal,
        [Parameter(Mandatory)][string]$SetId,
        [Parameter(Mandatory)][ValidateSet("present", "missing", "ambiguous", "failed")][string]$State,
        [string]$Source,
        [long]$Hwnd = 0,
        $TrackingContexts = $null,
        [AllowNull()][string[]]$CreateArguments = $null,
        [string]$Diagnostic = $null,
        [string]$Error = $null,
        [bool]$ApplyGeometry = $true,
        [AllowNull()]$Layout = $null
    )

    return [pscustomobject]@{
        Order           = $Order
        Terminal        = $Terminal
        TerminalId      = [string]$Terminal.id
        SetId           = $SetId
        WindowId        = [string]$Terminal.windowId
        ActiveTab       = [int]$Terminal.activeTab
        State           = $State
        Source          = $Source
        Hwnd            = [long]$Hwnd
        TrackingContexts = $TrackingContexts
        CreateArguments = $CreateArguments
        Diagnostic      = $Diagnostic
        Error           = $Error
        ApplyGeometry   = $ApplyGeometry
        Layout          = if ($null -ne $Layout) { $Layout } else { $Terminal.layout }
    }
}

function Test-DevWSTerminalPlacementRecords {
    # Shape validation for caller-supplied terminal placement records. This is
    # the ONE wire-shape parser (broker protocol, Helper request file and
    # reset request file all reuse it); correlation against configured
    # terminals lives in Resolve-DevWSTerminalPlacementPayload. Never touches
    # monitor/profile policy.
    #
    # Returns Ok/Error/Records. A record is:
    #   { "id": "<stable id>", "move": true, "x": 0, "y": 0, "w": 100, "h": 50 }
    #   { "id": "<stable id>", "move": false }
    param([AllowNull()]$Records)

    if ($null -eq $Records) {
        return [pscustomobject]@{ Ok = $false; Error = "terminalPlacements must be an array of placement records"; Records = @() }
    }

    if ($Records -isnot [array]) {
        return [pscustomobject]@{ Ok = $false; Error = "terminalPlacements must be an array of placement records"; Records = @() }
    }

    $validated = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $index = 0

    foreach ($record in @($Records)) {
        $label = "terminalPlacements[$index]"

        if ($null -eq $record -or $record -isnot [System.Management.Automation.PSCustomObject]) {
            return [pscustomobject]@{ Ok = $false; Error = "$label must be a JSON object"; Records = @() }
        }

        foreach ($property in @($record.PSObject.Properties)) {
            if (@("id", "move", "x", "y", "w", "h") -notcontains [string]$property.Name) {
                return [pscustomobject]@{ Ok = $false; Error = "$label has an unsupported field '$($property.Name)'"; Records = @() }
            }
        }

        $idProperty = $record.PSObject.Properties["id"]

        if ($null -eq $idProperty -or $idProperty.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$idProperty.Value) -or
            ([string]$idProperty.Value).Length -gt 200 -or
            -not (Test-DevWSStableIdSyntax -Id ([string]$idProperty.Value))) {
            return [pscustomobject]@{ Ok = $false; Error = "$label 'id' must be a non-empty stable identifier"; Records = @() }
        }

        $id = [string]$idProperty.Value

        if (-not $seen.Add($id)) {
            return [pscustomobject]@{ Ok = $false; Error = "terminalPlacements repeats terminal id '$id'"; Records = @() }
        }

        $moveProperty = $record.PSObject.Properties["move"]

        if ($null -eq $moveProperty -or $moveProperty.Value -isnot [bool]) {
            return [pscustomobject]@{ Ok = $false; Error = "$label 'move' must be a boolean"; Records = @() }
        }

        $move = [bool]$moveProperty.Value

        $xProperty = $record.PSObject.Properties["x"]
        $yProperty = $record.PSObject.Properties["y"]
        $wProperty = $record.PSObject.Properties["w"]
        $hProperty = $record.PSObject.Properties["h"]

        if (-not $move) {
            foreach ($geometryProperty in @($xProperty, $yProperty, $wProperty, $hProperty)) {
                if ($null -ne $geometryProperty) {
                    return [pscustomobject]@{ Ok = $false; Error = "$label must not carry geometry when move is false"; Records = @() }
                }
            }

            $validated.Add([pscustomobject]@{ Id = $id; Move = $false; X = 0; Y = 0; W = 0; H = 0 }) | Out-Null
            $index++
            continue
        }

        if ($null -eq $xProperty -or -not (Test-DevWSInteger $xProperty.Value) -or
            $null -eq $yProperty -or -not (Test-DevWSInteger $yProperty.Value) -or
            $null -eq $wProperty -or -not (Test-DevWSInteger $wProperty.Value) -or
            $null -eq $hProperty -or -not (Test-DevWSInteger $hProperty.Value) -or
            [int]$wProperty.Value -le 0 -or [int]$hProperty.Value -le 0) {
            return [pscustomobject]@{ Ok = $false; Error = "$label requires integer x, y and positive integer w, h when move is true"; Records = @() }
        }

        $validated.Add([pscustomobject]@{
            Id   = $id
            Move = $true
            X    = [int]$xProperty.Value
            Y    = [int]$yProperty.Value
            W    = [int]$wProperty.Value
            H    = [int]$hProperty.Value
        }) | Out-Null

        $index++
    }

    return [pscustomobject]@{ Ok = $true; Error = $null; Records = @($validated.ToArray()) }
}

function Resolve-DevWSTerminalPlacementPayload {
    # Shared validation/correlation of caller-supplied terminal placement
    # records against configured terminal definitions (broker prepare
    # payload, Helper request file, reset request file). Elevated hosts
    # receive final geometry decisions only; this function never samples
    # monitors and never resolves profiles.
    #
    # Modes:
    #   legacy ($null records)   - every configured terminal with the
    #                              historical default (move=true,
    #                              Terminal.layout); exact by construction.
    #   -RequireExactMembership  - launch: exactly one record per enabled
    #                              configured terminal.
    #   subset (default)         - reset: every record must name a configured
    #                              terminal; unlisted terminals are untouched.
    #
    # Returns:
    #   Terminals  - configured definitions targeted by the records
    #                (configured order)
    #   Placements - case-insensitive id -> { ApplyGeometry; Layout }
    param(
        [AllowNull()]$Placements,
        [AllowEmptyCollection()][object[]]$Terminals = @(),
        [switch]$RequireExactMembership
    )

    $terminalList = @($Terminals)
    $map = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($null -eq $Placements) {
        foreach ($terminal in $terminalList) {
            $map[[string]$terminal.id] = [pscustomobject]@{
                ApplyGeometry = $true
                Layout        = $terminal.layout
            }
        }

        return [pscustomobject]@{
            Terminals  = @($terminalList)
            Placements = $map
        }
    }

    $validation = Test-DevWSTerminalPlacementRecords -Records $Placements

    if (-not $validation.Ok) {
        throw "Invalid terminal placement payload: $($validation.Error)."
    }

    foreach ($record in @($validation.Records)) {
        $layout = $null

        if ([bool]$record.Move) {
            $layout = [pscustomobject]@{
                x = [int]$record.X
                y = [int]$record.Y
                w = [int]$record.W
                h = [int]$record.H
            }
        }

        $map[[string]$record.Id] = [pscustomobject]@{
            ApplyGeometry = [bool]$record.Move
            Layout        = $layout
        }
    }

    # Correlation: every record must name a configured terminal.
    foreach ($id in @($map.Keys)) {
        $known = $false

        foreach ($terminal in $terminalList) {
            if (([string]$terminal.id) -ieq [string]$id) { $known = $true; break }
        }

        if (-not $known) {
            throw "No configured terminal with id '$id' exists in the target set (configured: $(@($terminalList | ForEach-Object { [string]$_.id }) -join ', '))."
        }
    }

    # Launch mode: every configured terminal must have a record; never guess.
    if ($RequireExactMembership) {
        foreach ($terminal in $terminalList) {
            if (-not $map.Contains([string]$terminal.id)) {
                throw "Terminal '$([string]$terminal.id)' has no placement record; refusing to guess geometry."
            }
        }
    }

    $selected = [System.Collections.Generic.List[object]]::new()

    foreach ($terminal in $terminalList) {
        if ($map.Contains([string]$terminal.id)) {
            $selected.Add($terminal) | Out-Null
        }
    }

    return [pscustomobject]@{
        Terminals  = @($selected.ToArray())
        Placements = $map
    }
}

function Get-DevWSTerminalLaunchPlacement {
    # Frozen placement lookup for one terminal; the historical default
    # (move=true, Terminal.layout) applies for direct callers that supply no
    # explicit placement map or omit a terminal.
    param(
        [AllowNull()]$Placements,
        [AllowEmptyString()][string]$TerminalId,
        $Terminal
    )

    if ($null -ne $Placements -and $Placements.Contains($TerminalId)) {
        return $Placements[$TerminalId]
    }

    return [pscustomobject]@{
        ApplyGeometry = $true
        Layout        = $Terminal.layout
    }
}

function Get-DevWSTerminalPresenceSnapshot {
    # Pure read-only terminal classification for one resolved set (the launch
    # plan's Steps 1-2): state-first exact validation against the set-scoped
    # runtime cache, one shared WT candidate/tab-read cache, the fast-missing
    # optimization, and duplicate-windowId ambiguity. NEVER creates cwd
    # tracking contexts or creation arguments and never writes state.
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SetId,
        $State = $null,
        [AllowNull()][object[]]$Terminals = $null,
        [long[]]$WtHwnds,
        [scriptblock]$CandidateReader = $null,
        [scriptblock]$ProcessNameProvider = $null,
        [scriptblock]$HwndExistsProvider = $null,
        [scriptblock]$HwndValidator = $null
    )

    $target = Resolve-DevWSLifecycleTarget -Config $Config -SetId $SetId

    if ($null -eq $Terminals) {
        $Terminals = @(Get-DevWSWindows -Config $Config -Type "terminal" -EnabledOnly -Set $target.Set)
    }

    $terminalList = @($Terminals)

    Assert-DevWSElevatedTerminals -Terminals $terminalList

    if (-not $PSBoundParameters.ContainsKey("WtHwnds")) {
        # No terminals means no window candidates are needed at all; never pay
        # a native enumeration (or require the native runtime) for nothing.
        # @(...) keeps a zero-window enumeration a genuinely EMPTY array:
        # a bare empty result would bind $null and @($null) is a one-element
        # array, which would fabricate a ghost candidate and defeat fast-missing.
        $WtHwnds = @(if ($terminalList.Count -gt 0) { Get-DevWSTerminalTopLevelHwnds } else { @() })
    }

    $wtSet = [System.Collections.Generic.HashSet[long]]::new()
    $accounted = [System.Collections.Generic.HashSet[long]]::new()

    $resolvedWtHwnds = [System.Collections.Generic.List[long]]::new()
    foreach ($hwnd in @($WtHwnds)) {
        [void]$wtSet.Add([long]$hwnd)
        $resolvedWtHwnds.Add([long]$hwnd) | Out-Null
    }

    if ($null -eq $CandidateReader) {
        $CandidateReader = { param([long]$Hwnd) Read-DevWSTerminalHwndTabs -Hwnd $Hwnd }
    }

    if ($null -eq $ProcessNameProvider) {
        $ProcessNameProvider = { param([long]$Hwnd) Get-DevWSWindowHwndProcessName -Hwnd $Hwnd }
    }

    if ($null -eq $HwndExistsProvider) {
        $HwndExistsProvider = { param([long]$Hwnd) Test-DevWSWindowHwnd -Hwnd $Hwnd }
    }

    if ($null -eq $HwndValidator) {
        $HwndValidator = { param([long]$Hwnd) Test-DevWSTerminalTopLevelHwnd -Hwnd $Hwnd }
    }

    $readCache = @{}
    $readCount = 0
    $stateHits = 0
    $snapshotHits = 0
    $fastMissing = 0
    $ambiguousCount = 0
    $inaccessibleCount = 0
    $failedCount = 0
    $stateUncertainty = @{}

    # Final classification per configured index. Values are final once set:
    # this is a classification TABLE, not a mutable plan object, and the plan
    # records below are built from it exactly once.
    $classify = @{}
    $unresolved = [System.Collections.Generic.List[int]]::new()

    # ---- Step 1: state-first exact validation --------------------------------
    for ($index = 0; $index -lt $terminalList.Count; $index++) {
        $terminal = $terminalList[$index]
        $windowId = [string]$terminal.windowId
        $classification = $null

        if ($null -ne $State -and $null -ne $terminal.id -and -not [string]::IsNullOrWhiteSpace([string]$terminal.id)) {
            $entry = Get-DevWSRuntimeTerminal -State $State -SetId $target.SetId -Id ([string]$terminal.id)

            if ($null -ne $entry -and $entry.hwnd) {
                $hwnd = [long]$entry.hwnd

                if ($wtSet.Contains($hwnd)) {
                    if (-not $readCache.ContainsKey($hwnd)) {
                        $readCount++
                        $readCache[$hwnd] = & $CandidateReader $hwnd
                    }

                    $read = $readCache[$hwnd]
                    $hwndPresent = if ($null -ne $read.PSObject.Properties["HwndPresent"]) { [bool]$read.HwndPresent } else { [bool]$read.Ok }
                    $readOk      = if ($null -ne $read.PSObject.Properties["ReadOk"]) { [bool]$read.ReadOk } else { [bool]$read.Ok }
                    $complete    = if ($null -ne $read.PSObject.Properties["Complete"]) { [bool]$read.Complete } else { $true }
                    $rawCount    = [int]$read.RawCount
                    $tabNames    = $read.TabNames
                    if ($null -eq $tabNames) { $tabNames = New-DevWSPresentTabNameSet -Names @() }
                    $readKind    = if ($null -ne $read.PSObject.Properties["ErrorKind"]) { [string]$read.ErrorKind } else { "none" }
                    $readError   = if ($null -ne $read.PSObject.Properties["Error"]) { [string]$read.Error } else { $null }

                    if ($hwndPresent -and $readOk) {
                        $candidate = [pscustomobject]@{
                            Hwnd             = $hwnd
                            ExpectedWindowId = [string]$entry.windowId
                            ProcessName      = [string](& $ProcessNameProvider $hwnd)
                            TabNames         = $tabNames
                        }

                        $selected = Select-DevWSTerminalHwndCandidate -Candidates @($candidate) -WindowId $windowId -RequireProcess

                        if ($null -ne $selected) {
                            $classification = [pscustomobject]@{ State = "present"; Source = "state"; Hwnd = $hwnd; Diagnostic = $null }
                            $stateHits++
                            [void]$accounted.Add($hwnd)
                        }
                    }

                    if ($null -eq $classification -and $hwndPresent -and (-not $readOk -or -not $complete -or $tabNames.Count -eq 0)) {
                        $uncertainKind = if (-not $readOk) { $readKind } elseif ($rawCount -eq 0) { "empty-tab-observation" } elseif ($tabNames.Count -eq 0) { "unnamed-tab-observation" } else { "incomplete-tab-observation" }
                        $uncertainDetail = if ([string]::IsNullOrWhiteSpace($readError)) { $uncertainKind } else { "$uncertainKind; $readError" }
                        $stateUncertainty[$index] = [pscustomobject]@{
                            Hwnd       = [long]$hwnd
                            ErrorKind  = $uncertainKind
                            Error      = $readError
                            Diagnostic = "state HWND $hwnd exists but its managed tab identity could not be verified ($uncertainDetail)"
                        }
                    }
                }
                else {
                    # The cached HWND was not in the class-scoped candidate
                    # enumeration. A live, class-correct Windows Terminal HWND
                    # is still relevant evidence and must not reach fast-missing.
                    $procName = [string](& $ProcessNameProvider $hwnd)
                    $exists   = [bool](& $HwndExistsProvider $hwnd)
                    $classOk  = if ($exists) { [bool](& $HwndValidator $hwnd) } else { $false }

                    if ($exists -and $classOk -and (Test-DevWSProcessNameIsWindowsTerminal -ProcessName $procName)) {
                        $stateUncertainty[$index] = [pscustomobject]@{
                            Hwnd       = [long]$hwnd
                            ErrorKind  = "state-hwnd-not-enumerated"
                            Error      = $null
                            Diagnostic = "state HWND $hwnd is a live Windows Terminal window but was not present in the candidate enumeration"
                        }
                    }
                }
            }
        }

        if ($null -ne $classification) {
            $classify[$index] = $classification
        }
        else {
            $unresolved.Add($index) | Out-Null
        }
    }

    # ---- Step 2: unmatched candidates (or fast-missing) ----------------------
    if ($unresolved.Count -gt 0) {
        $candidateHwnds = [System.Collections.Generic.List[long]]::new()

        foreach ($hwnd in $resolvedWtHwnds) {
            if (-not $accounted.Contains($hwnd)) {
                $candidateHwnds.Add($hwnd) | Out-Null
            }
        }

        if ($candidateHwnds.Count -eq 0) {
            # Fast path: no unmatched class-scoped candidate. A cached live
            # state HWND that was not enumerated remains uncertainty; only
            # terminals with no such evidence are genuinely missing.
            foreach ($index in $unresolved) {
                if ($stateUncertainty.ContainsKey($index)) {
                    $uncertainty = $stateUncertainty[$index]
                    $classify[$index] = [pscustomobject]@{
                        State      = "inaccessible"
                        Source     = "state"
                        Hwnd       = [long]$uncertainty.Hwnd
                        Diagnostic = [string]$uncertainty.Diagnostic
                    }
                    $inaccessibleCount++
                }
                else {
                    $classify[$index] = [pscustomobject]@{ State = "missing"; Source = "fast-missing"; Hwnd = [long]0; Diagnostic = $null }
                    $fastMissing++
                }
            }
        }
        else {
            $facts = [System.Collections.Generic.List[object]]::new()

            foreach ($hwnd in $candidateHwnds) {
                if (-not $readCache.ContainsKey($hwnd)) {
                    $readCount++
                    $readCache[$hwnd] = & $CandidateReader $hwnd
                }

                $read = $readCache[$hwnd]
                $hwndPresent = if ($null -ne $read.PSObject.Properties["HwndPresent"]) { [bool]$read.HwndPresent } else { [bool]$read.Ok }
                $readOk      = if ($null -ne $read.PSObject.Properties["ReadOk"]) { [bool]$read.ReadOk } else { [bool]$read.Ok }
                $complete    = if ($null -ne $read.PSObject.Properties["Complete"]) { [bool]$read.Complete } else { $true }
                $tabNames    = $read.TabNames
                if ($null -eq $tabNames) { $tabNames = New-DevWSPresentTabNameSet -Names @() }
                $readKind    = if ($null -ne $read.PSObject.Properties["ErrorKind"]) { [string]$read.ErrorKind } else { "none" }
                $readError   = if ($null -ne $read.PSObject.Properties["Error"]) { [string]$read.Error } else { $null }

                $facts.Add([pscustomobject]@{
                    Hwnd           = [long]$hwnd
                    HwndPresent    = [bool]$hwndPresent
                    ProcessName    = [string](& $ProcessNameProvider $hwnd)
                    TabNames       = $tabNames
                    RawCount       = [int]$read.RawCount
                    ReadOk         = [bool]$readOk
                    Complete       = [bool]$complete
                    NameReadFailures = if ($null -ne $read.PSObject.Properties["NameReadFailures"]) { [int]$read.NameReadFailures } else { 0 }
                    ErrorKind      = $readKind
                    Error          = $readError
                }) | Out-Null
            }

            $uncertainFacts = @($facts | Where-Object {
                $_.HwndPresent -and
                (Test-DevWSProcessNameIsWindowsTerminal -ProcessName $_.ProcessName) -and
                ((-not $_.ReadOk) -or (-not $_.Complete) -or $_.TabNames.Count -eq 0)
            })

            foreach ($index in $unresolved) {
                $terminal = $terminalList[$index]
                $windowId = [string]$terminal.windowId

                $eligible = @($facts | Where-Object {
                    $_.HwndPresent -and
                    $_.ReadOk -and
                    (Test-DevWSProcessNameIsWindowsTerminal -ProcessName $_.ProcessName) -and
                    (Test-DevWSTerminalTitleFamily -WindowId $windowId -TabNames $_.TabNames)
                })

                if ($eligible.Count -eq 1) {
                    $classify[$index] = [pscustomobject]@{ State = "present"; Source = "snapshot"; Hwnd = [long]$eligible[0].Hwnd; Diagnostic = $null }
                    $snapshotHits++
                }
                elseif ($eligible.Count -gt 1) {
                    $hwndList = @($eligible | ForEach-Object { [long]$_.Hwnd }) -join ", "
                    $classify[$index] = [pscustomobject]@{
                        State      = "ambiguous"
                        Source     = "snapshot"
                        Hwnd       = [long]0
                        Diagnostic = "windowId '$windowId' is exposed by $($eligible.Count) Windows Terminal windows (HWNDs $hwndList); refusing to choose and refusing to launch."
                    }
                    $ambiguousCount++
                }
                else {
                    $hasStateUncertainty = $stateUncertainty.ContainsKey($index)

                    if ($hasStateUncertainty -or $uncertainFacts.Count -gt 0) {
                        $details = [System.Collections.Generic.List[string]]::new()

                        if ($hasStateUncertainty) {
                            $details.Add([string]$stateUncertainty[$index].Diagnostic) | Out-Null
                        }

                        foreach ($uncertain in $uncertainFacts) {
                            $detail = if ([string]::IsNullOrWhiteSpace([string]$uncertain.Error)) { [string]$uncertain.ErrorKind } else { "$($uncertain.ErrorKind); $($uncertain.Error)" }
                            $details.Add("candidate HWND $($uncertain.Hwnd) could not be verified ($detail)") | Out-Null
                        }

                        $classify[$index] = [pscustomobject]@{
                            State      = "inaccessible"
                            Source     = if ($hasStateUncertainty) { "state" } else { "snapshot" }
                            Hwnd       = if ($hasStateUncertainty) { [long]$stateUncertainty[$index].Hwnd } else { [long]0 }
                            Diagnostic = "presence could not be verified: $($details -join '; ')"
                        }
                        $inaccessibleCount++
                    }
                    else {
                        $classify[$index] = [pscustomobject]@{ State = "missing"; Source = "snapshot"; Hwnd = [long]0; Diagnostic = $null }
                    }
                }
            }
        }
    }

    # ---- final read-only records (classification only) -----------------------
    $records = [System.Collections.Generic.List[object]]::new()
    $missingClassified = 0
    $failedClassified = 0

    for ($index = 0; $index -lt $terminalList.Count; $index++) {
        $terminal = $terminalList[$index]
        $classification = $classify[$index]

        if ($null -eq $classification) {
            # Defensive: every terminal must be classified; an unclassified
            # entry is a failed terminal, never silently treated as missing.
            $records.Add([pscustomobject]@{
                Order      = $index
                Terminal   = $terminal
                TerminalId = [string]$terminal.id
                WindowId   = [string]$terminal.windowId
                State      = "failed"
                Source     = $null
                Hwnd       = [long]0
                Diagnostic = "terminal was not classified"
            }) | Out-Null
            $failedClassified++
            continue
        }

        if ($classification.State -eq "missing") { $missingClassified++ }

        $records.Add([pscustomobject]@{
            Order      = $index
            Terminal   = $terminal
            TerminalId = [string]$terminal.id
            WindowId   = [string]$terminal.windowId
            State      = [string]$classification.State
            Source     = $classification.Source
            Hwnd       = [long]$classification.Hwnd
            Diagnostic = $classification.Diagnostic
        }) | Out-Null
    }

    $sorted = @($resolvedWtHwnds | Sort-Object)

    return [pscustomobject]@{
        SetId     = $target.SetId
        WtHwnds   = $sorted
        Terminals = $records.ToArray()
        Counts    = [pscustomobject]@{
            Present      = $stateHits + $snapshotHits
            Missing      = $missingClassified
            Ambiguous    = $ambiguousCount
            Inaccessible = $inaccessibleCount
            Failed       = $failedClassified
        }
        Stats     = [pscustomobject]@{
            StateHits        = $stateHits
            SnapshotHits     = $snapshotHits
            FastMissing      = $fastMissing
            InaccessibleHits = $inaccessibleCount
            UiaReads         = $readCount
        }
    }
}

function Wait-DevWSResetTerminalPresence {
    # Bounded, read-only post-recreation identity wait. It reuses the shared
    # structured presence snapshot so the reset worker can report why a new
    # HWND could not be verified instead of returning a bare zero.
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SetId,
        $State = $null,
        [Parameter(Mandatory)]$Terminal,
        [int]$TimeoutSeconds = 15,
        [scriptblock]$PresenceProvider = $null
    )

    $terminalId = [string]$Terminal.id
    $windowId   = [string]$Terminal.windowId

    if ($null -eq $PresenceProvider) {
        $PresenceProvider = {
            param($Config, $SetId, $State, $Terminal)
            Get-DevWSTerminalPresenceSnapshot -Config $Config -SetId $SetId -State $State -Terminals @($Terminal)
        }
    }

    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
    $attempts = 0
    $last = $null

    while ($true) {
        $attempts++
        $snapshot = $null

        try {
            $snapshot = & $PresenceProvider $Config $SetId $State $Terminal
        }
        catch {
            $last = [pscustomobject]@{
                State      = "failed"
                Source     = "snapshot"
                Hwnd       = [long]0
                Diagnostic = (Get-DevWSUiaErrorText -Error $_)
            }
        }

        if ($null -ne $snapshot) {
            $records = @($snapshot.Terminals | Where-Object {
                [string]$_.TerminalId -ceq $terminalId -and [string]$_.WindowId -ceq $windowId
            })

            if ($records.Count -eq 1) {
                $last = $records[0]
            }
            else {
                $last = [pscustomobject]@{
                    State      = "failed"
                    Source     = "snapshot"
                    Hwnd       = [long]0
                    Diagnostic = "presence observation returned $($records.Count) records for terminal '$terminalId' ($windowId)"
                }
            }
        }

        if ($null -ne $last -and [string]$last.State -eq "present" -and [long]$last.Hwnd -gt 0) {
            return [pscustomobject]@{
                Ok         = $true
                Hwnd       = [long]$last.Hwnd
                State      = "present"
                Source     = [string]$last.Source
                Diagnostic = $null
                Attempts   = $attempts
            }
        }

        if ((Get-Date) -ge $deadline) {
            $state = if ($null -eq $last) { "failed" } else { [string]$last.State }
            $source = if ($null -eq $last) { "snapshot" } else { [string]$last.Source }
            $diagnostic = if ($null -eq $last) { "no presence observation was returned" } else { [string]$last.Diagnostic }

            return [pscustomobject]@{
                Ok         = $false
                Hwnd       = [long]0
                State      = $state
                Source     = $source
                Diagnostic = $diagnostic
                Attempts   = $attempts
            }
        }

        Start-Sleep -Milliseconds 250
    }
}

function Get-DevWSTerminalLaunchPlan {
    # Side-effect-free terminal launch plan for one resolved set.
    #
    # Classification is delegated to the shared read-only presence snapshot;
    # only genuinely missing terminals proceed to cwd tracking context and
    # creation arguments. The externally observable plan result is unchanged.
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SetId,
        $State = $null,
        [AllowNull()][object[]]$Terminals = $null,
        [long[]]$WtHwnds,
        [scriptblock]$CandidateReader = $null,
        [scriptblock]$ProcessNameProvider = $null,
        [scriptblock]$HwndExistsProvider = $null,
        [scriptblock]$HwndValidator = $null,
        [scriptblock]$TrackingContextFactory = $null,
        [scriptblock]$CreateArgumentsFactory = $null,
        [AllowNull()][System.Collections.IDictionary]$Placements = $null
    )

    if ($null -eq $TrackingContextFactory) {
        $TrackingContextFactory = {
            param($Terminal)
            New-DevWSCwdTrackingContexts -SetId $SetId -TerminalId ([string]$Terminal.id) -WindowId ([string]$Terminal.windowId) -Terminal $Terminal
        }
    }

    if ($null -eq $CreateArgumentsFactory) {
        $CreateArgumentsFactory = {
            param($Terminal, $TrackingContexts)
            [string[]]@(New-DevWSTerminalCreateArguments -Terminal $Terminal -TrackingContexts $TrackingContexts)
        }
    }

    $snapshotArgs = @{
        Config = $Config
        SetId  = $SetId
        State  = $State
    }

    if ($PSBoundParameters.ContainsKey("Terminals")) { $snapshotArgs.Terminals = $Terminals }
    if ($PSBoundParameters.ContainsKey("WtHwnds")) { $snapshotArgs.WtHwnds = $WtHwnds }
    if ($null -ne $CandidateReader) { $snapshotArgs.CandidateReader = $CandidateReader }
    if ($null -ne $ProcessNameProvider) { $snapshotArgs.ProcessNameProvider = $ProcessNameProvider }
    if ($null -ne $HwndExistsProvider) { $snapshotArgs.HwndExistsProvider = $HwndExistsProvider }
    if ($null -ne $HwndValidator) { $snapshotArgs.HwndValidator = $HwndValidator }

    $snapshot = Get-DevWSTerminalPresenceSnapshot @snapshotArgs

    # Frozen placement map (optional). Production callers (broker, Helper)
    # pass explicit lifecycle placements; direct callers without one keep the
    # historical default (move=true, Terminal.layout) with zero churn.
    $placementMap = $null

    if ($null -ne $Placements) {
        $placementMap = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($key in @($Placements.Keys)) {
            $placementMap[[string]$key] = $Placements[$key]
        }
    }

    # ---- Step 3: build the final records exactly once ------------------------
    $records = [System.Collections.Generic.List[object]]::new()
    $missingCount = 0
    $failedCount = 0

    foreach ($entry in @($snapshot.Terminals)) {
        $terminal = $entry.Terminal
        $setIdValue = [string]$snapshot.SetId
        $placement = Get-DevWSTerminalLaunchPlacement -Placements $placementMap -TerminalId ([string]$terminal.id) -Terminal $terminal

        if ($entry.State -eq "present") {
            $records.Add((New-DevWSTerminalPlanRecord `
                -Order ([int]$entry.Order) `
                -Terminal $terminal `
                -SetId $setIdValue `
                -State "present" `
                -Source $entry.Source `
                -Hwnd ([long]$entry.Hwnd) `
                -ApplyGeometry ([bool]$placement.ApplyGeometry) `
                -Layout $placement.Layout)) | Out-Null
            continue
        }

        if ($entry.State -eq "ambiguous") {
            $records.Add((New-DevWSTerminalPlanRecord `
                -Order ([int]$entry.Order) `
                -Terminal $terminal `
                -SetId $setIdValue `
                -State "ambiguous" `
                -Source $entry.Source `
                -Diagnostic $entry.Diagnostic `
                -ApplyGeometry ([bool]$placement.ApplyGeometry) `
                -Layout $placement.Layout)) | Out-Null
            continue
        }

        if ($entry.State -eq "inaccessible") {
            $errorText = if ([string]::IsNullOrWhiteSpace([string]$entry.Diagnostic)) { "terminal presence could not be verified" } else { [string]$entry.Diagnostic }
            $records.Add((New-DevWSTerminalPlanRecord `
                -Order ([int]$entry.Order) `
                -Terminal $terminal `
                -SetId $setIdValue `
                -State "failed" `
                -Source $entry.Source `
                -Diagnostic $entry.Diagnostic `
                -Error $errorText `
                -ApplyGeometry ([bool]$placement.ApplyGeometry) `
                -Layout $placement.Layout)) | Out-Null
            $failedCount++
            continue
        }

        if ($entry.State -eq "failed") {
            $errorText = if ([string]::IsNullOrWhiteSpace([string]$entry.Diagnostic)) { "terminal was not classified" } else { [string]$entry.Diagnostic }
            $records.Add((New-DevWSTerminalPlanRecord -Order ([int]$entry.Order) -Terminal $terminal -SetId $setIdValue -State "failed" -Error $errorText -ApplyGeometry ([bool]$placement.ApplyGeometry) -Layout $placement.Layout)) | Out-Null
            $failedCount++
            continue
        }

        if ($entry.State -ne "missing") {
            $records.Add((New-DevWSTerminalPlanRecord -Order ([int]$entry.Order) -Terminal $terminal -SetId $setIdValue -State "failed" -Error "unexpected classification '$($entry.State)'" -ApplyGeometry ([bool]$placement.ApplyGeometry) -Layout $placement.Layout)) | Out-Null
            $failedCount++
            continue
        }

        # Missing: build the per-tab cwd tracking bundle and the exact creation
        # arguments. A failure here fails only this terminal.
        try {
            $tracking = & $TrackingContextFactory $terminal
            $createArguments = [string[]]@(& $CreateArgumentsFactory $terminal $tracking)

            $records.Add((New-DevWSTerminalPlanRecord `
                -Order ([int]$entry.Order) `
                -Terminal $terminal `
                -SetId $setIdValue `
                -State "missing" `
                -Source $entry.Source `
                -TrackingContexts $tracking `
                -CreateArguments $createArguments `
                -ApplyGeometry ([bool]$placement.ApplyGeometry) `
                -Layout $placement.Layout)) | Out-Null
            $missingCount++
        }
        catch {
            $records.Add((New-DevWSTerminalPlanRecord -Order ([int]$entry.Order) -Terminal $terminal -SetId $setIdValue -State "failed" -Error $_.Exception.Message -ApplyGeometry ([bool]$placement.ApplyGeometry) -Layout $placement.Layout)) | Out-Null
            $failedCount++
        }
    }

    $sorted = @($snapshot.WtHwnds)

    return [pscustomobject]@{
        PlanId      = [guid]::NewGuid().ToString("N")
        SetId       = [string]$snapshot.SetId
        CreatedAtUtc = [DateTimeOffset]::UtcNow
        WtHwnds     = $sorted
        WtToken     = ($sorted -join ",")
        Terminals   = $records.ToArray()
        Counts      = [pscustomobject]@{
            Present   = [int]$snapshot.Counts.Present
            Missing   = $missingCount
            Ambiguous = [int]$snapshot.Counts.Ambiguous
            Failed    = $failedCount
        }
        Stats       = [pscustomobject]@{
            StateHits     = [int]$snapshot.Stats.StateHits
            SnapshotHits  = [int]$snapshot.Stats.SnapshotHits
            FastMissing   = [int]$snapshot.Stats.FastMissing
            UiaReads      = [int]$snapshot.Stats.UiaReads
            Candidates    = @($snapshot.WtHwnds).Count
        }
    }
}

function Test-DevWSTerminalLaunchPlanFresh {
    # Cheap plan-freshness token check: the sorted top-level WT HWND set must be
    # unchanged. Millisecond class; no UI Automation.
    #
    # A plan with no terminals performs no side effects, so it is trivially
    # fresh: there is nothing a changed window population could invalidate.
    param(
        [Parameter(Mandatory)]$Plan,
        [long[]]$WtHwnds
    )

    if (@($Plan.Terminals).Count -eq 0) {
        return $true
    }

    if (-not $PSBoundParameters.ContainsKey("WtHwnds")) {
        $WtHwnds = Get-DevWSTerminalTopLevelHwnds
    }

    $planned = @($Plan.WtHwnds)

    if (@($WtHwnds).Count -ne $planned.Count) {
        return $false
    }

    if ($planned.Count -eq 0) {
        return $true
    }

    $set = [System.Collections.Generic.HashSet[long]]::new()

    foreach ($hwnd in $planned) {
        [void]$set.Add([long]$hwnd)
    }

    foreach ($hwnd in @($WtHwnds)) {
        if (-not $set.Contains([long]$hwnd)) {
            return $false
        }
    }

    return $true
}

function Get-DevWSTerminalLaunchPlanSummary {
    # Compact wire/result summary of a plan (no window objects).
    param([Parameter(Mandatory)]$Plan)

    return [ordered]@{
        planId    = [string]$Plan.PlanId
        setId     = [string]$Plan.SetId
        counts    = [ordered]@{
            present   = [int]$Plan.Counts.Present
            missing   = [int]$Plan.Counts.Missing
            ambiguous = [int]$Plan.Counts.Ambiguous
            failed    = [int]$Plan.Counts.Failed
        }
        terminals = @($Plan.Terminals | ForEach-Object {
            [ordered]@{
                terminalId = [string]$_.TerminalId
                windowId   = [string]$_.WindowId
                state      = [string]$_.State
                source     = [string]$_.Source
                hwnd       = [long]$_.Hwnd
            }
        })
    }
}

function Start-DevWSTerminalLaunchPlan {
    # Back-to-back kickoff of every missing terminal: one ProcessStartInfo WT
    # invocation each, exact argument boundaries, no cmd.exe/PowerShell
    # re-parsing, no waits, prompt process-object disposal. One terminal's
    # invocation failure never blocks later independent terminals.
    param(
        [Parameter(Mandatory)]$Plan,
        [string]$WtPath,
        [scriptblock]$ProcessStarter = $null
    )

    $kicked = [System.Collections.Generic.List[object]]::new()
    $failures = [System.Collections.Generic.List[object]]::new()

    # The trusted Windows Terminal launcher (installed: the administrator-
    # protected package executable; repository: the explicit test stub) is
    # resolved lazily exactly once, immediately before the first actual
    # launch. A failed trust validation throws before any Process.Start.
    $resolvedWtPath = $WtPath

    foreach ($record in @($Plan.Terminals)) {
        if ($record.State -ne "missing") {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($resolvedWtPath)) {
            $resolvedWtPath = Resolve-DevWSTrustedWindowsTerminalPath
        }

        $startedAt = [DateTimeOffset]::UtcNow

        try {
            if ($null -ne $ProcessStarter) {
                & $ProcessStarter $record
            }
            else {
                $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
                $startInfo.FileName = $resolvedWtPath
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true

                foreach ($argument in @($record.CreateArguments)) {
                    [void]$startInfo.ArgumentList.Add([string]$argument)
                }

                $process = [System.Diagnostics.Process]::Start($startInfo)
                $process.Dispose()
            }
        }
        catch {
            $failures.Add([pscustomobject]@{
                Order      = [int]$record.Order
                TerminalId = [string]$record.TerminalId
                Ref        = "$([string]$Plan.SetId)/$($record.TerminalId)"
                Message    = $_.Exception.Message
            }) | Out-Null
            continue
        }

        $kicked.Add([pscustomobject]@{
            Order           = [int]$record.Order
            TerminalId      = [string]$record.TerminalId
            WindowId        = [string]$record.WindowId
            CreateArguments = $record.CreateArguments
            StartedAtUtc    = $startedAt
            DeadlineUtc     = $startedAt.AddSeconds($script:DevWSTerminalLaunchIdentityTimeoutSecondsDefault)
        }) | Out-Null
    }

    return [pscustomobject]@{
        Kicks    = $kicked.ToArray()
        Failures = $failures.ToArray()
    }
}

function Complete-DevWSTerminalLaunchPlan {
    # Shared completion: finalize present terminals exactly like the historic
    # worker (move + activeTab + runtime-state when the source was UIA), then
    # resolve every kicked terminal through ONE batch snapshot per polling tick.
    # Plan-level failures (ambiguous/failed classification) and kick failures
    # aggregate with completion failures in configured terminal order.
    param(
        [Parameter(Mandatory)]$Plan,
        $KickResult = $null,
        [AllowEmptyCollection()][object[]]$Kicks = @(),
        [int]$PollMilliseconds = $script:DevWSTerminalLaunchPollMillisecondsDefault,
        [scriptblock]$SnapshotProvider = $null
    )

    if ($null -eq $SnapshotProvider) {
        $SnapshotProvider = { Get-DevWSTerminalWindowSnapshot }
    }

    $failures = [System.Collections.Generic.List[object]]::new()
    $finalized = [System.Collections.Generic.List[string]]::new()
    $setId = [string]$Plan.SetId

    if ($null -ne $KickResult) {
        foreach ($failure in @($KickResult.Failures)) {
            $failures.Add($failure) | Out-Null
        }

        $kicks = @($KickResult.Kicks)
    }
    else {
        $kicks = @($Kicks)
    }

    # Classification-level refusals are terminal failures too: an ambiguous
    # windowId can never be launched and a failed terminal never started.
    foreach ($record in @($Plan.Terminals)) {
        if ($record.State -eq "ambiguous") {
            $failures.Add([pscustomobject]@{
                Order      = [int]$record.Order
                TerminalId = [string]$record.TerminalId
                Ref        = "$setId/$($record.TerminalId)"
                Message    = if (-not [string]::IsNullOrWhiteSpace([string]$record.Diagnostic)) { [string]$record.Diagnostic } else { "the managed windowId is ambiguous; refusing to choose." }
            }) | Out-Null
        }
        elseif ($record.State -eq "failed") {
            $failures.Add([pscustomobject]@{
                Order      = [int]$record.Order
                TerminalId = [string]$record.TerminalId
                Ref        = "$setId/$($record.TerminalId)"
                Message    = [string]$record.Error
            }) | Out-Null
        }
    }

    $recordsByOrder = @{}
    foreach ($record in @($Plan.Terminals)) {
        $recordsByOrder[[int]$record.Order] = $record
    }

    # ---- Present terminals: move + activeTab (+ state refresh when UIA) ------
    foreach ($record in @($Plan.Terminals)) {
        if ($record.State -ne "present") {
            continue
        }

        $ref = "$setId/$($record.TerminalId)"

        try {
            if ([bool]$record.ApplyGeometry) {
                Move-DevWSWindowHwnd `
                    -Hwnd ([long]$record.Hwnd) `
                    -Layout $record.Layout `
                    -Context "terminal '$ref' ($($record.WindowId))"
            }
            else {
                Write-DevWSLaunchTrace -Event "layout-geometry-skipped" -Data ([ordered]@{
                    set = $setId
                    id  = [string]$record.TerminalId
                })
            }

            [void](Select-DevWSTabByIndexFromHwnd `
                -Hwnd ([long]$record.Hwnd) `
                -Index ([int]$record.ActiveTab) `
                -Context "terminal '$ref' ($($record.WindowId))")

            if ([string]$record.Source -eq "snapshot") {
                Update-DevWSRuntimeTerminal -SetId $setId -Id $record.TerminalId -WindowId $record.WindowId -Hwnd ([long]$record.Hwnd)
            }

            $finalized.Add($ref) | Out-Null
        }
        catch {
            $failures.Add([pscustomobject]@{ Order = [int]$record.Order; TerminalId = [string]$record.TerminalId; Ref = $ref; Message = $_.Exception.Message }) | Out-Null
        }
    }

    # ---- Kicked terminals: one shared batch snapshot per tick ---------------
    $pending = [System.Collections.Generic.List[object]]::new()

    foreach ($kick in @($kicks)) {
        $record = $recordsByOrder[[int]$kick.Order]

        if ($null -eq $record -or $record.State -ne "missing") {
            continue
        }

        $pending.Add([pscustomobject]@{ Kick = $kick; Record = $record }) | Out-Null
    }

    while ($pending.Count -gt 0) {
        $snapshot = @(& $SnapshotProvider)
        $remaining = [System.Collections.Generic.List[object]]::new()

        foreach ($entry in $pending) {
            $record = $entry.Record
            $kick = $entry.Kick
            $windowId = [string]$record.WindowId
            $ref = "$setId/$($record.TerminalId)"

            $matches = @($snapshot | Where-Object {
                (Test-DevWSProcessNameIsWindowsTerminal -ProcessName $_.ProcessName) -and
                (Test-DevWSTerminalTitleFamily -WindowId $windowId -TabNames $_.TabNames)
            })

            if ($matches.Count -gt 1) {
                $hwndList = @($matches | ForEach-Object { [long]$_.Hwnd }) -join ", "
                $failures.Add([pscustomobject]@{
                    Order      = [int]$record.Order
                    TerminalId = [string]$record.TerminalId
                    Ref        = $ref
                    Message    = "the created windowId '$windowId' is exposed by $($matches.Count) Windows Terminal windows (HWNDs $hwndList); refusing to choose."
                }) | Out-Null
                continue
            }

            if ($matches.Count -eq 1) {
                $match = $matches[0]
                $configuredCount = @($record.Terminal.tabs).Count

                # Safety net: a freshly created window holds exactly the
                # configured tabs. More (raw, duplicate-preserving) TabItems
                # means `wt -w` attached to an existing window and must be
                # reported, never silently kept. A temporarily lower count is
                # tolerated (UIA materialization lag).
                if (-not (Test-DevWSCreatedTabCount -ActualCount ([int]$match.RawCount) -ConfiguredCount $configuredCount)) {
                    $failures.Add([pscustomobject]@{
                        Order      = [int]$record.Order
                        TerminalId = [string]$record.TerminalId
                        Ref        = $ref
                        Message    = "the window reports $($match.RawCount) tabs for $configuredCount configured tabs; wt may have attached to an existing window."
                    }) | Out-Null
                    continue
                }

                try {
                    if ([bool]$record.ApplyGeometry) {
                        Move-DevWSWindowHwnd `
                            -Hwnd ([long]$match.Hwnd) `
                            -Layout $record.Layout `
                            -Context "terminal '$ref' ($windowId)"
                    }
                    else {
                        Write-DevWSLaunchTrace -Event "layout-geometry-skipped" -Data ([ordered]@{
                            set = $setId
                            id  = [string]$record.TerminalId
                        })
                    }

                    Update-DevWSRuntimeTerminal -SetId $setId -Id $record.TerminalId -WindowId $windowId -Hwnd ([long]$match.Hwnd)

                    $finalized.Add($ref) | Out-Null
                }
                catch {
                    $failures.Add([pscustomobject]@{ Order = [int]$record.Order; TerminalId = [string]$record.TerminalId; Ref = $ref; Message = $_.Exception.Message }) | Out-Null
                }

                continue
            }

            if ([DateTimeOffset]::UtcNow -gt $kick.DeadlineUtc) {
                $failures.Add([pscustomobject]@{
                    Order      = [int]$record.Order
                    TerminalId = [string]$record.TerminalId
                    Ref        = $ref
                    Message    = "was created but could not be identified."
                }) | Out-Null
                continue
            }

            $remaining.Add($entry) | Out-Null
        }

        $pending = $remaining

        if ($pending.Count -gt 0) {
            Start-Sleep -Milliseconds $PollMilliseconds
        }
    }

    $orderedFailures = [System.Collections.Generic.List[string]]::new()

    foreach ($failure in @($failures | Sort-Object { $_.Order })) {
        $orderedFailures.Add("Terminal '$($failure.TerminalId)' in set '$setId': $($failure.Message)") | Out-Null
    }

    return [pscustomobject]@{
        SetId     = $setId
        Finalized = $finalized.ToArray()
        Failed    = @($failures | ForEach-Object { $_.Ref })
        Failures  = $orderedFailures.ToArray()
    }
}
