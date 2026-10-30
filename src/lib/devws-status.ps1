# DevWS read-only workspace status model.
#
# `ws status [set]` acquisition/aggregation only. This library NEVER launches,
# focuses, moves, closes, repairs, adopts, tags, restarts, or persists
# anything. It composes existing read-only primitives:
#
#   - the shared terminal presence snapshot (launch-plan classification);
#   - the read-only tracked-cwd resolver (Resolve-DevWSTrackedCwd);
#   - one shared tolerant app window probe + the pure steady-state selection;
#   - bounded observational host `status` queries (a stale host stays resident;
#     these never use the launch-path ping or any recovery path).
#
# Console formatting lives in devws-display.ps1 (`Get-DevWSStatusLines`); the
# CLI adapter in ws.ps1 owns only Get-DevWSContext + Write-Host.
#
# Required libraries (dot-source first): devws-paths.ps1, devws-config.ps1,
# devws-state.ps1, devws-terminal-launch.ps1, devws-cwd.ps1,
# devws-app-window.ps1, devws-broker-protocol.ps1, devws-coordinator.ps1.

function Get-DevWSAppStatusObservation {
    # Observational translation of the pure app selection result:
    #   resolved       -> present
    #   adopt          -> unowned   (observed only; status never adopts/tags)
    #   owned-mismatch -> mismatch
    #   ambiguous      -> ambiguous
    #   missing        -> missing
    #
    # Tolerant ownership errors on matching candidates become item-level
    # `error`/`ownership-corrupt`; unrelated windows never affect this app.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Probed,
        [Parameter(Mandatory)][string]$SetId,
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)]$Match,
        [Parameter(Mandatory)]
        [ValidateSet("dedicated", "shared")]
        [string]$Mode
    )

    $selection = Resolve-DevWSAppWindowSelection -Probed $Probed -SetId $SetId -ItemId $ItemId -Match $Match -Mode $Mode

    $matching = @($Probed | Where-Object { $null -ne $_ -and (Test-DevWSAppWindowMatch -Candidate $_ -Match $Match) })
    $candidateHwnds = @($matching | ForEach-Object { [long]$_.hwnd })

    $observation = [ordered]@{
        State          = "error"
        Reason         = $null
        Hwnd           = [long]0
        CandidateHwnds = @()
        OwnerKey       = $null
        Diagnostic     = $null
    }

    switch ([string]$selection.Status) {
        "resolved" {
            $observation.State = "present"
            $observation.Hwnd = [long]$selection.Hwnd
        }

        "adopt" {
            $observation.State = "unowned"
            $observation.Reason = "unowned-candidate"
            $observation.CandidateHwnds = @([long]$selection.Hwnd)
        }

        "owned-mismatch" {
            $observation.State = "mismatch"
            $observation.Reason = "owned-mismatch"
            $observation.Hwnd = [long]$selection.Hwnd
            $observation.CandidateHwnds = @([long]$selection.Hwnd)
        }

        "ambiguous" {
            $observation.State = "ambiguous"
            $observation.Reason = "ambiguous"
            $observation.CandidateHwnds = $candidateHwnds
        }

        "missing" {
            $observation.State = "missing"
        }

        default {
            $observation.State = "error"
            $observation.Reason = "unexpected selection '$($selection.Status)'"
        }
    }

    if ($null -ne $selection.Message -and -not [string]::IsNullOrWhiteSpace([string]$selection.Message)) {
        $observation.Diagnostic = [string]$selection.Message
    }

    # Tolerant ownership errors win for matching candidates: one corrupt window
    # must never be read as unowned/missing by status.
    $corrupt = @($matching | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.ownerError) })

    if ($corrupt.Count -gt 0) {
        $observation.State = "error"
        $observation.Reason = "ownership-corrupt"
        $observation.Hwnd = [long]0
        $observation.CandidateHwnds = @($corrupt | ForEach-Object { [long]$_.hwnd })
    }

    if ([long]$observation.Hwnd -gt 0) {
        $ownerRow = @($Probed | Where-Object { $null -ne $_ -and [long]$_.hwnd -eq [long]$observation.Hwnd } | Select-Object -First 1)

        if ($ownerRow.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$ownerRow[0].ownerKey)) {
            $observation.OwnerKey = [string]$ownerRow[0].ownerKey
        }
    }

    return [pscustomobject]$observation
}

function Get-DevWSStatusModel {
    # One read-only workspace status model for one resolved set. Every enabled
    # terminal/app is classified from shared read-only snapshots; disabled
    # items are reported as `disabled` without any live discovery or
    # cwd/ownership inspection. Never throws for ordinary item-level failures;
    # config/set resolution errors propagate as command-level failures.
    param(
        [Parameter(Mandatory)]$Config,
        [string]$SetId,
        [scriptblock]$TerminalSnapshotProvider = $null
    )

    $target     = Resolve-DevWSLifecycleTarget -Config $Config -SetId $SetId
    $defaultSet = Get-DevWSDefaultSet -Config $Config
    $state      = Read-DevWSRuntimeState

    $installRoot = Get-DevWSInstallRoot
    $installedGeneration = Get-DevWSEffectiveRuntimeGeneration -InstallRoot $installRoot

    # ---- terminals (configured order; disabled items are not probed) --------
    $terminalItems    = @(Get-DevWSWindows -Config $Config -Type "terminal" -Set $target.Set)
    $enabledTerminals = @($terminalItems | Where-Object { [bool]$_.enabled })

    $snapshot = $null

    if ($enabledTerminals.Count -gt 0) {
        if ($null -ne $TerminalSnapshotProvider) {
            $snapshot = & $TerminalSnapshotProvider -Config $Config -SetId $target.SetId -State $state -Terminals $enabledTerminals
        }
        else {
            $snapshot = Get-DevWSTerminalPresenceSnapshot -Config $Config -SetId $target.SetId -State $state -Terminals $enabledTerminals
        }
    }

    $terminals = [System.Collections.Generic.List[object]]::new()
    $enabledIndex = 0

    foreach ($item in $terminalItems) {
        $scopedId = "$($target.SetId)/$([string]$item.id)"

        if (-not [bool]$item.enabled) {
            $terminals.Add([pscustomobject]@{
                ItemId         = [string]$item.id
                ScopedId       = $scopedId
                Enabled        = $false
                WindowId       = [string]$item.windowId
                State          = "disabled"
                Source         = $null
                Hwnd           = [long]0
                ConfiguredPath = [string]$item.path
                ActiveTab      = [int]$item.activeTab
                Diagnostic     = $null
                CwdStatus      = $null
                Cwd            = $null
                CwdReason      = $null
            }) | Out-Null
            continue
        }

        $entry = $snapshot.Terminals[$enabledIndex]
        $enabledIndex++

        $cwd = Resolve-DevWSTrackedCwd -SetId $target.SetId -TerminalId ([string]$item.id)

        $terminals.Add([pscustomobject]@{
            ItemId         = [string]$item.id
            ScopedId       = $scopedId
            Enabled        = $true
            WindowId       = [string]$item.windowId
            State          = [string]$entry.State
            Source         = [string]$entry.Source
            Hwnd           = [long]$entry.Hwnd
            ConfiguredPath = [string]$item.path
            ActiveTab      = [int]$item.activeTab
            Diagnostic     = [string]$entry.Diagnostic
            CwdStatus      = [string]$cwd.Status
            Cwd            = [string]$cwd.Cwd
            CwdReason      = [string]$cwd.Reason
        }) | Out-Null
    }

    # ---- apps (one shared candidate enumeration + one tolerant probe) -------
    $appItems    = @(Get-DevWSWindows -Config $Config -Type "app" -Set $target.Set)
    $enabledApps = @($appItems | Where-Object { [bool]$_.enabled })
    $probe       = @()

    if ($enabledApps.Count -gt 0) {
        $candidates = @(Get-DevWSAppWindowCandidates -IncludeInvisible)
        $probe      = @(Get-DevWSAppWindowProbe -Config $Config -Candidates $candidates -TolerantOwnership)
    }

    $apps = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $appItems) {
        $scopedId   = "$($target.SetId)/$([string]$item.id)"
        $matchKind  = [string]$item.match.kind
        $matchValue = [string]$item.match.value

        if (-not [bool]$item.enabled) {
            $apps.Add([pscustomobject]@{
                ItemId         = [string]$item.id
                ScopedId       = $scopedId
                Enabled        = $false
                InstanceMode   = (Get-DevWSAppInstanceMode -Item $item)
                State          = "disabled"
                Reason         = $null
                Hwnd           = [long]0
                CandidateHwnds = @()
                OwnerKey       = $null
                MatchKind      = $matchKind
                MatchValue     = $matchValue
                Diagnostic     = $null
            }) | Out-Null
            continue
        }

        $mode = Get-DevWSAppInstanceMode -Item $item

        if ($mode -notin @("dedicated", "shared")) {
            $apps.Add([pscustomobject]@{
                ItemId         = [string]$item.id
                ScopedId       = $scopedId
                Enabled        = $true
                InstanceMode   = $null
                State          = "error"
                Reason         = "no-instanceMode"
                Hwnd           = [long]0
                CandidateHwnds = @()
                OwnerKey       = $null
                MatchKind      = $matchKind
                MatchValue     = $matchValue
                Diagnostic     = $null
            }) | Out-Null
            continue
        }

        $observation = Get-DevWSAppStatusObservation -Probed $probe -SetId $target.SetId -ItemId ([string]$item.id) -Match $item.match -Mode $mode

        $apps.Add([pscustomobject]@{
            ItemId         = [string]$item.id
            ScopedId       = $scopedId
            Enabled        = $true
            InstanceMode   = $mode
            State          = [string]$observation.State
            Reason         = [string]$observation.Reason
            Hwnd           = [long]$observation.Hwnd
            CandidateHwnds = @($observation.CandidateHwnds)
            OwnerKey       = [string]$observation.OwnerKey
            MatchKind      = $matchKind
            MatchValue     = $matchValue
            Diagnostic     = [string]$observation.Diagnostic
        }) | Out-Null
    }

    # ---- hosts (observational status; stale hosts stay resident) ------------
    $broker      = Get-DevWSElevatedBrokerStatus
    $coordinator = Get-DevWSCoordinatorStatus

    # ---- summary (workspace items only; hosts are reported separately) ------
    $summary = [ordered]@{
        Present      = 0
        Missing      = 0
        Inaccessible = 0
        Ambiguous    = 0
        Mismatch     = 0
        Unowned      = 0
        Disabled     = 0
        Error        = 0
    }

    foreach ($row in @($terminals) + @($apps)) {
        $stateKey = [string]$row.State

        if ($summary.Contains($stateKey)) {
            $summary[$stateKey]++
        }
    }

    return [pscustomobject]@{
        SetId               = $target.SetId
        IsDefault           = ($target.SetId -ieq ([string]$defaultSet.id))
        InstalledGeneration = $installedGeneration
        Terminals           = $terminals.ToArray()
        Apps                = $apps.ToArray()
        Broker              = $broker
        Coordinator         = $coordinator
        Summary             = [pscustomobject]$summary
    }
}
