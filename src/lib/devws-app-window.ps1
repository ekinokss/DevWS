# DevWS Phase 8 app window resolution.
#
# Responsibilities:
#   - generic Win32 enumeration of real top-level windows (one process may own
#     several windows, so Get-Process.MainWindowHandle is never used);
#   - pure app match evaluation for the configured match kinds (exe,
#     processPathContains);
#   - bounded ownership classification against configured dedicated apps;
#   - pure selection/lifecycle resolution with the Pass 2 ambiguity policy:
#       dedicated: unique exact owner, otherwise adopt exactly one matching
#                  unowned window, otherwise fail ambiguity;
#       shared:    exactly one eligible (unowned by any dedicated item) match,
#                  otherwise fail ambiguity;
#   - ownership tagging for adopted/created dedicated windows only (shared
#     windows never receive a DevWS ownership property).
#
# Required libraries (dot-source first): devws-config.ps1 (config helpers),
# devws-app-ownership.ps1 (Win32 ownership primitives) and devws-native.ps1
# (shared native runtime).

$script:DevWSAppLaunchTimeoutSecondsDefault = 12
$script:DevWSAppLaunchPollMillisecondsDefault = 500

function Initialize-DevWSAppWindowNative {
    # Guarded subsystem access to the shared native runtime. Repeated
    # dot-sourcing or repeated initialization is a type-presence no-op.
    if ($null -ne ([System.Management.Automation.PSTypeName]'DevWSAppWindowNative').Type) {
        return
    }

    Initialize-DevWSNativeRuntime
}

function Get-DevWSAppWindowCandidates {
    param([switch]$IncludeInvisible)

    Initialize-DevWSAppWindowNative

    # Fact acquisition is native: one EnumWindows pass plus visible-process
    # metadata, preserving enumeration order and the historical candidate
    # semantics (hidden records keep empty metadata, an inaccessible path
    # degrades to unavailable, disappearing processes never abort the pass).
    # PowerShell member lookup is case-insensitive, so the CLR candidate
    # properties keep every existing lowercase consumer working; matching,
    # ownership and lifecycle policy stay in PowerShell.
    return [DevWSAppWindowCandidateCollector]::CollectAppWindowCandidates($IncludeInvisible.IsPresent)
}

function Test-DevWSAppWindowMatch {
    param(
        [Parameter(Mandatory)]
        $Candidate,
        [Parameter(Mandatory)]
        $Match
    )

    # Pure match evaluation. Hidden windows (including Chromium helper
    # top-level windows) are never normal app candidates.
    if (-not [bool]$Candidate.visible) {
        return $false
    }

    $kind  = [string]$Match.kind
    $value = [string]$Match.value

    switch ($kind) {
        "exe" {
            $name = $null

            if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.processPath)) {
                $name = [System.IO.Path]::GetFileName([string]$Candidate.processPath)
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$Candidate.processName)) {
                $name = [string]$Candidate.processName
            }

            return ($null -ne $name -and $name -ieq $value)
        }

        "processPathContains" {
            if ([string]::IsNullOrWhiteSpace([string]$Candidate.processPath)) {
                return $false
            }

            return (([string]$Candidate.processPath).IndexOf($value, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        }

        default {
            throw "Unsupported app match.kind '$kind' (supported: exe, processPathContains)."
        }
    }
}

function Get-DevWSConfiguredAppWindowMatches {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $Candidate
    )

    # Read-only diagnostic matching with full scoped identity: every matching
    # configured app across every set in config order, with its explicit mode.
    $matches = [System.Collections.Generic.List[object]]::new()

    foreach ($set in @(Get-DevWSSets -Config $Config)) {
        if ($null -eq $set) {
            continue
        }

        $setId = [string]$set.id

        foreach ($item in @($set.windows)) {
            if ($null -eq $item -or $item.type -ne "app") {
                continue
            }

            if (Test-DevWSAppWindowMatch -Candidate $Candidate -Match $item.match) {
                $matches.Add([pscustomobject]@{
                    SetId        = $setId
                    ItemId       = [string]$item.id
                    ScopedId     = "$setId/$([string]$item.id)"
                    InstanceMode = (Get-DevWSAppInstanceMode -Item $item)
                    App          = $item
                }) | Out-Null
            }
        }
    }

    return $matches.ToArray()
}

function Get-DevWSConfiguredAppDefinition {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$ScopedId
    )

    # Resolve one configured app definition by scoped identity
    # ('<set>/<item>', case-insensitive); used to verify that an owned HWND
    # still matches the definition that owns it.
    foreach ($set in @(Get-DevWSSets -Config $Config)) {
        if ($null -eq $set) {
            continue
        }

        foreach ($item in @($set.windows)) {
            if ($null -eq $item -or $item.type -ne "app") {
                continue
            }

            if ("$([string]$set.id)/$([string]$item.id)" -ieq $ScopedId) {
                return $item
            }
        }
    }

    return $null
}

function Get-DevWSConfiguredDedicatedAppIdentities {
    param(
        [Parameter(Mandatory)]
        $Config
    )

    # Every explicitly dedicated app across all sets, in config order. The
    # bounded ownership lookup only ever checks these scoped identities.
    $identities = [System.Collections.Generic.List[object]]::new()

    foreach ($set in @(Get-DevWSSets -Config $Config)) {
        if ($null -eq $set) {
            continue
        }

        $setId = [string]$set.id

        foreach ($item in @($set.windows)) {
            if ($null -eq $item -or $item.type -ne "app") {
                continue
            }

            if ((Get-DevWSAppInstanceMode -Item $item) -eq "dedicated") {
                $identities.Add([pscustomobject]@{
                    SetId  = $setId
                    ItemId = [string]$item.id
                    Key    = "$setId/$([string]$item.id)"
                }) | Out-Null
            }
        }
    }

    return $identities.ToArray()
}

function Get-DevWSRenameSetDedicatedIdentities {
    param(
        [Parameter(Mandatory)]
        $Set
    )

    # The dedicated-ownership identities of exactly ONE set, in config order.
    # `ws rename-set` ownership lookups are ALWAYS bounded to this list: an
    # ownership property belonging only to another set (or to no configured
    # set) is invisible to the rename preflight and can never block it.
    $identities = [System.Collections.Generic.List[object]]::new()
    $setId = [string]$Set.id

    foreach ($item in @($Set.windows)) {
        if ($null -eq $item -or $item.type -ne "app") {
            continue
        }

        if ((Get-DevWSAppInstanceMode -Item $item) -eq "dedicated") {
            $identities.Add([pscustomobject]@{
                SetId  = $setId
                ItemId = [string]$item.id
            }) | Out-Null
        }
    }

    return $identities.ToArray()
}

function Get-DevWSRenameSetOwnershipBlockers {
    # Read-only fail-closed preflight for `ws rename-set` (accepted Candidate B
    # policy: refuse, never migrate). Reports every live window that carries an
    # exact ownership property of one of the TARGET SET's configured dedicated
    # apps (invariant-lowercase scoped identity, bounded lookups only). Shared
    # apps never carry ownership and therefore never block.
    #
    # Ownership-read corruption among the target set's bounded descriptors is
    # never guessed past: the helper throws so the rename refuses. Corruption
    # that does not involve this set's descriptors cannot be observed here.
    #
    # Synthetic callers may inject -Candidates (top-level candidate records)
    # and -OwnershipReader (bounded per-HWND ownership read) for deterministic
    # tests; production uses the real enumeration and real primitives.
    param(
        [Parameter(Mandatory)]
        $Set,
        [AllowNull()]
        [object[]]$Candidates = $null,
        [scriptblock]$OwnershipReader = $null
    )

    $setId = [string]$Set.id
    $identities = @(Get-DevWSRenameSetDedicatedIdentities -Set $Set)

    if ($identities.Count -eq 0) {
        # A set with no dedicated apps (shared-only or itemless) can never own
        # a window, so there is nothing to observe and nothing can block.
        return @()
    }

    $descriptors = @(Get-DevWSAppOwnershipDescriptors -Candidates $identities)

    if ($null -eq $OwnershipReader) {
        $OwnershipReader = {
            param($Hwnd, $BoundDescriptors)
            return (Get-DevWSAppOwnershipFromDescriptors -Hwnd $Hwnd -Descriptors $BoundDescriptors)
        }
    }

    if ($null -eq $Candidates) {
        $Candidates = @(Get-DevWSAppWindowCandidates -IncludeInvisible)
    }

    $blockers = [System.Collections.Generic.List[object]]::new()

    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) {
            continue
        }

        $owner = $null

        try {
            $owner = & $OwnershipReader ([long]$candidate.hwnd) $descriptors
        }
        catch {
            throw ("Cannot rename set '$setId': the dedicated-ownership preflight failed closed on window HWND $($candidate.hwnd). " + $_.Exception.Message)
        }

        if ($null -eq $owner) {
            continue
        }

        $ownerItemId = [string]$owner.ItemId

        $blockers.Add([pscustomobject]@{
            SetId       = $setId
            ItemId      = $ownerItemId
            ScopedId    = "$setId/$ownerItemId"
            Hwnd        = [long]$candidate.hwnd
            ProcessName = [string]$candidate.processName
            Title       = [string]$candidate.title
        }) | Out-Null
    }

    return $blockers.ToArray()
}

function Format-DevWSSetRenameOwnershipRefusal {
    # Actionable refusal text for a blocked rename. Identifies the set, every
    # live old-scoped dedicated owner (scoped id + HWND, plus process/title
    # when reliably available) and the recovery action.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Blockers
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Cannot rename set '$SetId' while dedicated apps still own live windows:") | Out-Null

    foreach ($blocker in @($Blockers)) {
        $detail = ""

        if (-not [string]::IsNullOrWhiteSpace([string]$blocker.ProcessName)) {
            $detail = " (" + [string]$blocker.ProcessName

            if (-not [string]::IsNullOrWhiteSpace([string]$blocker.Title)) {
                $detail += " - '" + [string]$blocker.Title + "'"
            }

            $detail += ")"
        }

        $lines.Add("  dedicated app '$($blocker.ScopedId)' still owns live window HWND $($blocker.Hwnd)$detail.") | Out-Null
    }

    $lines.Add("Close that app and retry. No window was changed by this refusal.") | Out-Null

    return ($lines -join [Environment]::NewLine)
}

function Get-DevWSAppWindowProbe {
    param(
        [Parameter(Mandatory)]
        $Config,
        [AllowEmptyCollection()]
        [object[]]$Candidates,
        [switch]$TolerantOwnership
    )

    # Read-only classification of every live top-level window: match state plus
    # the single scoped dedicated owner (if any). Multiple ownership properties
    # on one window are corruption and fail through Get-DevWSAppOwnership.
    # -TolerantOwnership is diagnostic-only (detect-app): the corruption error
    # is captured per window instead of aborting the whole probe.
    if (-not $PSBoundParameters.ContainsKey("Candidates")) {
        $Candidates = @(Get-DevWSAppWindowCandidates -IncludeInvisible)
    }

    $identities  = @(Get-DevWSConfiguredDedicatedAppIdentities -Config $Config)
    $descriptors = @(Get-DevWSAppOwnershipDescriptors -Candidates $identities)
    $probed = [System.Collections.Generic.List[object]]::new()

    foreach ($candidate in @($Candidates)) {
        $owner      = $null
        $ownerError = $null

        try {
            $owner = Get-DevWSAppOwnershipFromDescriptors -Hwnd ([long]$candidate.hwnd) -Descriptors $descriptors
        }
        catch {
            if (-not $TolerantOwnership) {
                throw
            }

            $ownerError = $_.Exception.Message
        }

        $probed.Add([pscustomobject]@{
            hwnd         = [long]$candidate.hwnd
            pid          = [uint32]$candidate.pid
            processName  = [string]$candidate.processName
            processPath  = [string]$candidate.processPath
            visible      = [bool]$candidate.visible
            class        = [string]$candidate.class
            title        = [string]$candidate.title
            ownerSetId   = if ($owner) { [string]$owner.SetId } else { $null }
            ownerItemId  = if ($owner) { [string]$owner.ItemId } else { $null }
            ownerKey     = if ($owner) { "$($owner.SetId)/$($owner.ItemId)" } else { $null }
            ownerError   = $ownerError
        }) | Out-Null
    }

    return $probed.ToArray()
}

function Test-DevWSProbedWindowOwned {
    param(
        [Parameter(Mandatory)]
        $Probed
    )

    # Tolerant ownership predicate: a synthetic caller may expose a missing
    # owner key as an empty string rather than $null.
    return (-not [string]::IsNullOrWhiteSpace([string]$Probed.ownerKey))
}

function Set-DevWSProbedWindowOwnership {
    param(
        [AllowEmptyCollection()]
        [object[]]$Probed = @(),
        [Parameter(Mandatory)]
        [long]$Hwnd,
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [string]$ItemId
    )

    # Synchronize an already-captured in-memory probe snapshot with a
    # successful Win32 ownership write. This is NOT a replacement for the Win32
    # ownership verification; it only updates the matching record so later
    # resolutions in the same launch transaction see the newly scoped owner.
    # An HWND that is not present in the supplied snapshot is never invented.
    foreach ($record in @($Probed)) {
        if ($null -eq $record) {
            continue
        }

        if ([long]$record.hwnd -eq $Hwnd) {
            # PowerShell 7.6 does not allow assigning a property that does not
            # already exist on a PSCustomObject; Add-Member -Force creates or
            # replaces the four ownership fields on any probe record shape.
            $record | Add-Member -MemberType NoteProperty -Name ownerSetId -Value $SetId -Force
            $record | Add-Member -MemberType NoteProperty -Name ownerItemId -Value $ItemId -Force
            $record | Add-Member -MemberType NoteProperty -Name ownerKey -Value "$SetId/$ItemId" -Force
            $record | Add-Member -MemberType NoteProperty -Name ownerError -Value $null -Force
        }
    }
}

function Resolve-DevWSAppWindowSelection {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Probed,
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [string]$ItemId,
        [Parameter(Mandatory)]
        $Match,
        [Parameter(Mandatory)]
        [ValidateSet("dedicated", "shared")]
        [string]$Mode
    )

    # Pure steady-state selection. Returns:
    #   resolved       - Hwnd usable as-is
    #   adopt          - exactly one matching unowned window, caller tags it
    #   missing        - nothing suitable is currently visible
    #   ambiguous      - fail; DevWS never chooses arbitrarily
    #   owned-mismatch - exact owner exists but no longer matches the definition
    $targetKey = "$SetId/$ItemId"
    $matching  = @($Probed | Where-Object { Test-DevWSAppWindowMatch -Candidate $_ -Match $Match })

    if ($Mode -eq "dedicated") {
        $exact = @($Probed | Where-Object { (Test-DevWSProbedWindowOwned -Probed $_) -and ([string]$_.ownerKey) -ieq $targetKey })

        if ($exact.Count -gt 1) {
            $hwnds = @($exact | ForEach-Object { $_.hwnd }) -join ", "
            return [pscustomobject]@{
                Status  = "ambiguous"
                Hwnd    = 0
                Message = "App '$targetKey' ownership is corrupt: multiple live windows ($hwnds) carry ownership '$targetKey'. Close the duplicate windows or remove the stale ownership."
            }
        }

        if ($exact.Count -eq 1) {
            $ownedHwnd = [long]$exact[0].hwnd
            $ownedStillMatches = @($matching | Where-Object { [long]$_.hwnd -eq $ownedHwnd }).Count -gt 0

            if (-not $ownedStillMatches) {
                return [pscustomobject]@{
                    Status  = "owned-mismatch"
                    Hwnd    = $ownedHwnd
                    Message = "Window $ownedHwnd is owned by '$targetKey' but no longer matches the app definition (match $($Match.kind) '$($Match.value)'). DevWS will not claim a different window; update the app definition or close that window."
                }
            }

            return [pscustomobject]@{ Status = "resolved"; Hwnd = $ownedHwnd; Message = $null }
        }

        $unownedMatching = @($matching | Where-Object { -not (Test-DevWSProbedWindowOwned -Probed $_) })

        if ($unownedMatching.Count -eq 1) {
            return [pscustomobject]@{ Status = "adopt"; Hwnd = [long]$unownedMatching[0].hwnd; Message = $null }
        }

        if ($unownedMatching.Count -gt 1) {
            $hwnds = @($unownedMatching | ForEach-Object { $_.hwnd }) -join ", "
            return [pscustomobject]@{
                Status  = "ambiguous"
                Hwnd    = 0
                Message = "App '$targetKey' has $($unownedMatching.Count) matching unowned windows ($hwnds). Close the extra windows or make the app definition match exactly one window; DevWS never chooses arbitrarily."
            }
        }

        return [pscustomobject]@{ Status = "missing"; Hwnd = 0; Message = $null }
    }

    # shared: windows owned by ANY dedicated item are never eligible.
    $eligible = @($matching | Where-Object { -not (Test-DevWSProbedWindowOwned -Probed $_) })

    if ($eligible.Count -eq 1) {
        return [pscustomobject]@{ Status = "resolved"; Hwnd = [long]$eligible[0].hwnd; Message = $null }
    }

    if ($eligible.Count -gt 1) {
        $hwnds = @($eligible | ForEach-Object { $_.hwnd }) -join ", "
        return [pscustomobject]@{
            Status  = "ambiguous"
            Hwnd    = 0
            Message = "App '$targetKey' is configured shared but $($eligible.Count) eligible matching windows exist ($hwnds). Close the extra windows or make the configuration/window ownership unambiguous."
        }
    }

    return [pscustomobject]@{ Status = "missing"; Hwnd = 0; Message = $null }
}

function Resolve-DevWSAppLaunchOutcome {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Probed,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [long[]]$PreLaunchHwnds,
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [string]$ItemId,
        [Parameter(Mandatory)]
        $Match,
        [Parameter(Mandatory)]
        [ValidateSet("dedicated", "shared")]
        [string]$Mode
    )

    # Pure post-launch evaluation. For dedicated apps only windows that
    # appeared after the launch snapshot are eligible, so focusing an existing
    # window is never mistaken for creating a distinct one.
    $targetKey = "$SetId/$ItemId"

    if ($Mode -eq "dedicated") {
        $newMatching = @(
            $Probed |
                Where-Object { $PreLaunchHwnds -notcontains [long]$_.hwnd } |
                Where-Object { Test-DevWSAppWindowMatch -Candidate $_ -Match $Match }
        )

        $suitable = @($newMatching | Where-Object { -not (Test-DevWSProbedWindowOwned -Probed $_) -or ([string]$_.ownerKey) -ieq $targetKey })

        if ($suitable.Count -eq 1) {
            return [pscustomobject]@{
                Status       = "resolved"
                Hwnd         = [long]$suitable[0].hwnd
                NeedsTagging = (-not (Test-DevWSProbedWindowOwned -Probed $suitable[0]))
                Message      = $null
            }
        }

        if ($suitable.Count -gt 1) {
            $hwnds = @($suitable | ForEach-Object { $_.hwnd }) -join ", "
            return [pscustomobject]@{
                Status       = "ambiguous"
                Hwnd         = 0
                NeedsTagging = $false
                Message      = "Dedicated app '$targetKey' created multiple new matching windows ($hwnds); refusing to choose one. Close the extra windows and retry."
            }
        }

        return [pscustomobject]@{ Status = "missing"; Hwnd = 0; NeedsTagging = $false; Message = $null }
    }

    # shared: re-evaluate the eligible set (any dedicated-owned match excluded).
    $matching = @($Probed | Where-Object { Test-DevWSAppWindowMatch -Candidate $_ -Match $Match })
    $eligible = @($matching | Where-Object { -not (Test-DevWSProbedWindowOwned -Probed $_) })

    if ($eligible.Count -eq 1) {
        return [pscustomobject]@{ Status = "resolved"; Hwnd = [long]$eligible[0].hwnd; NeedsTagging = $false; Message = $null }
    }

    if ($eligible.Count -gt 1) {
        $hwnds = @($eligible | ForEach-Object { $_.hwnd }) -join ", "
        return [pscustomobject]@{
            Status       = "ambiguous"
            Hwnd         = 0
            NeedsTagging = $false
            Message      = "Shared app '$targetKey' has $($eligible.Count) eligible matching windows ($hwnds); refusing to choose one. Close the extra windows and retry."
        }
    }

    return [pscustomobject]@{ Status = "missing"; Hwnd = 0; NeedsTagging = $false; Message = $null }
}

function Assert-DevWSAppInstanceModeExplicit {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Apps,
        [Parameter(Mandatory)]
        [string]$SetId
    )

    # Pass 2 lifecycle never guesses a mode. Structural validation still allows
    # the transitional missing field; the live lifecycle does not.
    foreach ($app in @($Apps)) {
        if ($null -eq $app) {
            continue
        }

        if ((Get-DevWSAppInstanceMode -Item $app) -notin @("dedicated", "shared")) {
            throw "App '$SetId/$($app.id)' has no instanceMode. Phase 8 app lifecycle requires explicit 'dedicated' or 'shared' mode."
        }
    }
}

function Complete-DevWSAppLaunchAttempt {
    # One shared evaluation step for a launched app: pure post-launch outcome
    # resolution, ownership tagging/verification and the bounded timeout
    # errors. Used by the per-app resolver loop and by the batch launch
    # finalization loop so both share identical policy.
    param(
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        $App,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Probed,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [long[]]$PreLaunchHwnds,
        [Parameter(Mandatory)]
        [datetime]$Deadline,
        [Parameter(Mandatory)]
        [int]$LaunchTimeoutSeconds
    )

    $mode   = Get-DevWSAppInstanceMode -Item $App
    $itemId = [string]$App.id
    $appRef = "$SetId/$itemId"

    $outcome = Resolve-DevWSAppLaunchOutcome `
        -Probed $Probed `
        -PreLaunchHwnds $PreLaunchHwnds `
        -SetId $SetId `
        -ItemId $itemId `
        -Match $App.match `
        -Mode $mode

    if ($outcome.Status -eq "resolved") {
        $hwnd = [long]$outcome.Hwnd

        if ($outcome.NeedsTagging) {
            [void](Set-DevWSAppOwnership -Hwnd $hwnd -SetId $SetId -ItemId $itemId)

            if (-not (Test-DevWSAppOwnership -Hwnd $hwnd -SetId $SetId -ItemId $itemId)) {
                throw "Failed to verify DevWS ownership '$appRef' on newly created window $hwnd."
            }
        }

        return [pscustomobject]@{ Status = "resolved"; Hwnd = $hwnd }
    }

    if ($outcome.Status -eq "ambiguous") {
        throw $outcome.Message
    }

    if ((Get-Date) -ge $Deadline) {
        if ($mode -eq "dedicated") {
            throw "Dedicated app '$appRef' did not create a distinct window. The configured application may be single-instance; configure it shared instead if that is the intended behavior."
        }

        throw "Shared app '$appRef' did not produce exactly one matching window within $LaunchTimeoutSeconds seconds."
    }

    return [pscustomobject]@{ Status = "pending"; Hwnd = [long]0 }
}

function Resolve-DevWSAppLifecycleWindow {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        $App,
        [Parameter(Mandatory)]
        [ValidateSet("launch", "focus", "capture", "classify")]
        [string]$Operation,
        [scriptblock]$ProbeProvider,
        [scriptblock]$Launcher,
        [AllowEmptyCollection()]
        [object[]]$InitialProbe,
        [int]$LaunchTimeoutSeconds = $script:DevWSAppLaunchTimeoutSecondsDefault,
        [int]$PollMilliseconds = $script:DevWSAppLaunchPollMillisecondsDefault
    )

    # Ownership-aware app lifecycle entry point. Returns the exact HWND to
    # operate on, or 0 when the app is missing for a non-launch operation.
    # Every failure throws an actionable error; there is no silent fallback.
    $mode = Get-DevWSAppInstanceMode -Item $App
    $itemId = [string]$App.id
    $appRef = "$SetId/$itemId"

    if ($mode -notin @("dedicated", "shared")) {
        throw "App '$appRef' has no instanceMode. Phase 8 app lifecycle requires explicit 'dedicated' or 'shared' mode."
    }

    if (-not $ProbeProvider) {
        $ProbeProvider = { Get-DevWSAppWindowProbe -Config $Config }
    }

    if (-not $Launcher) {
        $Launcher = { param($LaunchApp) Invoke-DevWSAppLaunchCommand -App $LaunchApp }
    }

    # Pass 3: a caller may supply one shared steady-state probe for several
    # apps. It is used only for this first selection; a launch that is still
    # missing always refreshes immediately before launching (below).
    $hasInitialProbe = ($PSBoundParameters.ContainsKey("InitialProbe") -and $null -ne $InitialProbe)

    if ($hasInitialProbe) {
        $probed = @($InitialProbe)
    }
    else {
        $probed = @(& $ProbeProvider)
    }

    $selection = Resolve-DevWSAppWindowSelection -Probed $probed -SetId $SetId -ItemId $itemId -Match $App.match -Mode $mode

    if ($selection.Status -eq "missing" -and $Operation -eq "launch" -and $hasInitialProbe) {
        # A shared snapshot is never trusted as the launch baseline: refresh
        # immediately before launching so an app that appeared after the shared
        # probe is never duplicated, and so dedicated pre-launch HWNDs describe
        # the real world immediately before this specific launch.
        $probed = @(& $ProbeProvider)
        $selection = Resolve-DevWSAppWindowSelection -Probed $probed -SetId $SetId -ItemId $itemId -Match $App.match -Mode $mode
    }

    switch ([string]$selection.Status) {
        "resolved" {
            return [long]$selection.Hwnd
        }

        "adopt" {
            $hwnd = [long]$selection.Hwnd
            [void](Set-DevWSAppOwnership -Hwnd $hwnd -SetId $SetId -ItemId $itemId)

            if (-not (Test-DevWSAppOwnership -Hwnd $hwnd -SetId $SetId -ItemId $itemId)) {
                throw "Failed to verify DevWS ownership '$appRef' on window $hwnd."
            }

            # Keep a supplied shared snapshot coherent for later apps: the
            # window is now owned and must be ineligible for them.
            Set-DevWSProbedWindowOwnership -Probed $probed -Hwnd $hwnd -SetId $SetId -ItemId $itemId

            return $hwnd
        }

        "ambiguous" {
            throw $selection.Message
        }

        "owned-mismatch" {
            throw $selection.Message
        }

        "missing" {
            if ($Operation -ne "launch") {
                return 0
            }
        }

        default {
            throw "Unexpected app window selection status '$($selection.Status)' for '$appRef'."
        }
    }

    # Dedicated/shared launch: snapshot, invoke the configured launch once,
    # then poll for a bounded time.
    $preLaunchHwnds = @($probed | ForEach-Object { [long]$_.hwnd })
    & $Launcher $App

    $deadline = (Get-Date).AddSeconds($LaunchTimeoutSeconds)

    while ($true) {
        $post    = @(& $ProbeProvider)
        $attempt = Complete-DevWSAppLaunchAttempt `
            -SetId $SetId `
            -App $App `
            -Probed $post `
            -PreLaunchHwnds $preLaunchHwnds `
            -Deadline $deadline `
            -LaunchTimeoutSeconds $LaunchTimeoutSeconds

        if ($attempt.Status -eq "resolved") {
            return [long]$attempt.Hwnd
        }

        Start-Sleep -Milliseconds $PollMilliseconds
    }
}
