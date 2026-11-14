# DevWS P9-H replay instrumentation - verdict evaluator.
#
# Closes P9-G defects E1-5 and the N2 corollary: the E1 PASS expression had no
# session-transition term, so missing disconnect proof could not block a pass.
#
# Stage 2.3 corrections (independent review of PR #21 @ 8e0f156):
#   * N2-A accepted a valid-but-EMPTY post-window inventory, so "no window was
#     observed" satisfied a criterion that requires positively observed window
#     creation and attribution;
#   * a missing PRE-window inventory silently became an empty baseline;
#   * attribution ignored LauncherPid/LaunchedAtUtc, so a stale process carrying
#     the matching argv (started hours earlier) counted as newly created;
#   * Test-P9HLaunchTrace required a per-event `trialId` that DevWS NEVER emits,
#     which made every REAL production trace invalid (proven by reading
#     src/lib/devws-paths.ps1 + every Write-DevWSLaunchTrace call site).
#
# Trace schema discipline: only fields the product actually emits may be
# required. Verified against source:
#   framework fields : event, utcMs, pid
#   data fields      : ackAt ambiguous app apps broker count elapsedMs failed
#                      failures finalized fingerprint firstAt id kicked lastAt
#                      layoutSource missing planId present probes profileAware
#                      profileId recheckMs set skipped source terminals type
#                      uncertain
#   planId carriers  : stage2-broker-ready, stage2-broker-replanned
#   transaction id   : `set` (the product's SetId), NOT a trial id
#
# Every predicate below names the artifact it depends on and fails closed.

Set-StrictMode -Version Latest

function Test-P9HHasProperty {
    # Explicit property-presence test.
    #
    # '$null -ne $value' is NOT a presence test when the value is an array:
    # comparing $null against @() returns @(), which is falsy. That made a valid
    # but EMPTY 'Windows' array look like a missing inventory and silently blocked
    # every window-attribution path.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-P9HProp {
    # Safe property read: returns $null when absent instead of throwing under
    # StrictMode.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function ConvertTo-P9HUtcOrNull {
    # Normalize a timestamp value (string / DateTime / DateTimeOffset) to UTC.
    #
    # CRITICAL: ConvertFrom-Json converts an ISO-8601 "...Z" string into a
    # DateTime with Kind=Local whose Ticks are LOCAL wall-clock ticks, so the Kind
    # must be honoured explicitly. Blindly calling ToUniversalTime() on every
    # DateTime double-applies the host offset and shifts the instant by the UTC
    # offset - which silently moved valid process start times out of the launch
    # window and broke attribution.
    param($Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }

    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Local) { return $Value.ToUniversalTime() }
        # Utc and Unspecified are both treated as already-UTC instants: every
        # timestamp this instrumentation writes is UTC ('o' format).
        return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $null
    }

    if ($parsed.Kind -eq [System.DateTimeKind]::Local) { return $parsed.ToUniversalTime() }
    return [datetime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)
}
function ConvertFrom-P9HEpochMs {
    # Trace events carry `utcMs` (Unix epoch milliseconds), not ISO text.
    param($Value)
    if ($null -eq $Value) { return $null }
    $ms = 0L
    if (-not [long]::TryParse([string]$Value, [ref]$ms)) { return $null }
    if ($ms -le 0) { return $null }
    return [DateTimeOffset]::FromUnixTimeMilliseconds($ms).UtcDateTime
}

function Get-P9HMonitorIdentitySet {
    # Extract the monitor identity list from a capture.
    #
    # AUTHORITATIVE SOURCE: per-monitor records (`parsedMonitors`). The `tokens`
    # array is corroboration and must agree when both exist. A precomputed
    # `tokenRectBytes`/`tokenSetBytes` string is NEVER used to supply identities.
    param($Capture)

    $result = [ordered]@{
        Ok = $false; Reason = $null; Records = @(); Tokens = @(); Consistent = $false
    }

    $records = Get-P9HProp -Object $Capture -Name 'parsedMonitors'
    $tokens = Get-P9HProp -Object $Capture -Name 'tokens'

    if ($null -eq $records) { $result.Reason = 'no-parsed-monitors'; return [pscustomobject]$result }

    $recordList = @($records)
    if ($recordList.Count -eq 0) { $result.Reason = 'empty-parsed-monitors'; return [pscustomobject]$result }

    foreach ($r in $recordList) {
        if ([string]::IsNullOrWhiteSpace([string](Get-P9HProp -Object $r -Name 'identity'))) {
            $result.Reason = 'monitor-record-missing-identity'; return [pscustomobject]$result
        }
        if ([string]::IsNullOrWhiteSpace([string](Get-P9HProp -Object $r -Name 'rect'))) {
            $result.Reason = 'monitor-record-missing-rect'; return [pscustomobject]$result
        }
    }

    $recordIdentities = @($recordList | ForEach-Object { [string]$_.identity })
    $tokenList = @()
    if ($null -ne $tokens) {
        $tokenList = @($tokens | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    }

    $consistent = $true
    if ($tokenList.Count -gt 0) {
        $consistent = [string]::Equals((@($recordIdentities | Sort-Object) -join '|'),
                                       (@($tokenList | Sort-Object) -join '|'),
                                       [System.StringComparison]::Ordinal)
    }

    $result.Ok = $true
    $result.Reason = 'ok'
    $result.Records = $recordList
    $result.Tokens = $tokenList
    $result.Consistent = $consistent
    return [pscustomobject]$result
}

function Get-P9HMonitorPairs {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)
    return @($Records | ForEach-Object { '{0}@{1}' -f [string]$_.identity, [string]$_.rect } | Sort-Object)
}

function Test-P9HNegativeOrigin {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)
    return (@($Records | Where-Object { [string]$_.rect -match 'x=-\d' }).Count -gt 0)
}

function Get-P9HManagedTerminalWindowClassification {
    # Classify ATTRIBUTED windows against the PRODUCT'S managed terminal identity
    # contract, with a POSITIVE auxiliary-role contract.
    #
    # WHAT THIS IS FOR
    # ----------------
    # The frozen N2-B identity rule counted EVERY newly created visible top-level
    # HWND owned by an attributed PID (`Select-P9HAttributableWindow`). That is a
    # PROCESS association rule, not a TERMINAL-WINDOW identity rule, and Stage
    # 3B7G2 returned INCONCLUSIVE (`attributed-window-count-not-one:2`) for a launch
    # that created one managed terminal plus one owned ConPTY helper window.
    #
    # The product does NOT identify managed terminal windows that way. From
    # src\native\devws-terminal-candidates.cs it enumerates them by EXACT class:
    #
    #     private const string WindowsTerminalTopLevelClass = "CASCADIA_HOSTING_WINDOW_CLASS";
    #     ... string.Equals(className.ToString(), WindowsTerminalTopLevelClass, Ordinal)
    #
    # and src\lib\devws-identity.ps1 additionally requires the owning process to be
    # `WindowsTerminal` and the UI-Automation tab names to form a canonical title
    # family for the pinned windowId.
    #
    # CONTRACT HISTORY (each result keeps its own version)
    # ---------------------------------------------------
    #   p9h.auxiliary-window.v1  (G3): GW_OWNER + resolvable process == auxiliary.
    #       REFUTED: six false acceptances, including a competing Cascadia UI.
    #   p9h.auxiliary-window.v2  (C1): added ancestry, session, exact argv identity,
    #       competing-UI exclusion, and required WS_EX_TOOLWINDOW (A8).
    #       STILL WRONG in two ways:
    #         (a) FALSE ACCEPTANCE - WS_EX_TOOLWINDOW was treated as a universal
    #             role certificate. An arbitrary 1200x800 class carrying that bit
    #             was accepted (reproduced as case X1).
    #         (b) FALSE REJECTION - the ConPTY pseudo window is documented and
    #             observed to be a `WS_POPUP` owned by the hosting terminal
    #             (ConptyReparentPseudoConsole). WS_EX_TOOLWINDOW is an
    #             implementation detail, NOT a documented guarantee, so requiring
    #             it can reject genuine helpers on other builds.
    #   p9h.auxiliary-window.v3  (C2, this function): the window CLASS participates
    #       in a positive role argument. WS_EX_TOOLWINDOW is CORROBORATING evidence
    #       only - never sufficient, never required.
    #
    # WHY WS_EX_TOOLWINDOW CANNOT BE DECISIVE
    # ---------------------------------------
    # Microsoft documents WS_EX_TOOLWINDOW as a PRESENTATION style: "a floating
    # toolbar ... does not appear in the taskbar or in the dialog that appears when
    # the user presses ALT+TAB". It says nothing about the window being
    # noninteractive, harmless or internal. On a live host the bit is also set by
    # Shell_TrayWnd, SystemTray_Main, tooltips_class32 and many others.
    #
    # THE POSITIVE AUXILIARY CONTRACT (schema p9h.auxiliary-window.v3)
    # ----------------------------------------------------------------
    # A non-managed attributed window is `auxiliary` only when ALL of these hold:
    #
    #   A1  GW_OWNER names exactly one managed terminal in THIS set
    #   A2  its class is NOT the managed terminal class
    #   A3  its owning process record RESOLVES from the attributed inventory
    #   A4  the owning process shares the managed terminal's session
    #   A5  the owning process is a STRICT descendant of the managed terminal
    #   A6  the owner command line carries all three pinned identity values, each
    #       EXACTLY equal (missing / unreadable / wrong => REFUSAL)
    #   A7  it does not claim a managed terminal title
    #   A8  its WINDOW CLASS is POSITIVELY identified as an auxiliary role class
    #
    # A1-A7 are RELATIONSHIP and CAUSAL evidence. They are necessary, and each is
    # independently refutable, but they are NOT sufficient: a user-facing
    # application window launched by the pinned shell inherits the same command
    # line (argv identity is PROCESS-level, not WINDOW-level), is a genuine strict
    # descendant, is owned, and need not carry a managed title.
    #
    # A8 is therefore about the CLASS, not about a style bit. The recognized
    # auxiliary class is the ConPTY pseudo-console window, whose role is
    # established independently of this qualification suite:
    #
    #   * Microsoft documents the pseudoconsole as a mechanism that "replace[s] the
    #     user interactivity portion of the default console host window"; the
    #     hosting application owns its presentation.
    #   * microsoft/terminal documents ConptyReparentPseudoConsole: the pseudo
    #     window's owner is set to "the actual hosting terminal's HWND", which is
    #     exactly the GW_OWNER relation A1 requires.
    #   * A Windows Terminal maintainer describes the object as "the fake
    #     PseudoConsoleWindow ... basically just a 0*0 pixel sized WS_POPUP window,
    #     which is owned by Windows Terminal", existing so GetConsoleWindow returns
    #     a handle, and "simply just isn't visible".
    #
    # That establishes the class's ROLE. It does NOT establish that any individual
    # window of that class belongs to THIS launch, which is why A1-A7 are still
    # required and why the class alone is never sufficient.
    #
    # Everything else - including an arbitrary class that happens to carry
    # WS_EX_TOOLWINDOW - is `unclassified` and fails closed.
    #
    # EVIDENCE GAPS (reported, never invented)
    # ----------------------------------------
    # The frozen window inventory records hwnd/pid/visible/class/rect/owner/title.
    # It does NOT record GWL_STYLE or GWL_EXSTYLE. Under v3 that absence is NOT
    # fatal: style is corroborating, not decisive. It is still reported, because it
    # is the one field that could turn a corroborated identity into a confirmed one.
    #
    # The qualification title check is a NARROW PROXY for the product's
    # UI-Automation tab-title-family validator; it is not that validator.
    #
    # Parameters are pure data; this function touches no window and no VM.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Windows,
        [Parameter(Mandatory)][string]$ExpectedWindowId,
        [Parameter(Mandatory)][string]$ExpectedTerminalId,
        [Parameter(Mandatory)][string]$ExpectedSetId,
        # Managed terminal contract, supplied by the caller so the source of truth
        # is explicit rather than embedded as a magic string in two places.
        [string]$ManagedWindowClass = 'CASCADIA_HOSTING_WINDOW_CLASS',
        [string]$ManagedProcessName = 'WindowsTerminal',
        # The positively identified auxiliary-role class. This is a ROLE class, not
        # an exclusion list: membership is necessary but never sufficient (A1-A7).
        [string[]]$AuxiliaryRoleClasses = @('PseudoConsoleWindow'),
        # Corroborating extended-style marker. NOT required, NOT sufficient.
        [long]$CorroboratingExStyleMask = 0x00000080,
        [AllowNull()]$ProcessByPid = $null
    )

    $managed = [System.Collections.Generic.List[object]]::new()
    $auxiliary = [System.Collections.Generic.List[object]]::new()
    $unclassified = [System.Collections.Generic.List[object]]::new()
    $competing = [System.Collections.Generic.List[object]]::new()

    function ConvertFrom-StyleText {
        param($Value)
        if ($null -eq $Value) { return $null }
        $text = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        if ($text -match '^0[xX](?<h>[0-9a-fA-F]+)$') {
            try { return [Convert]::ToInt64($Matches['h'], 16) } catch { return $null }
        }
        $parsed = 0L
        if ([int64]::TryParse($text, [ref]$parsed)) { return $parsed }
        return $null
    }

    # Mirrors the grammar of Resolve-DevWSTerminalTabTitle in src/lib/devws-config.ps1:
    # exactly <windowId>, or <windowId>#DevWS:<N> with canonical decimal N>=1.
    function Test-ManagedTitleFamily {
        param([string]$Title, [string]$WindowId)
        if ([string]::IsNullOrWhiteSpace($Title) -or [string]::IsNullOrWhiteSpace($WindowId)) { return $false }
        if ($Title -ieq $WindowId) { return $true }
        $prefix = $WindowId + '#DevWS:'
        if ($Title.Length -le $prefix.Length) { return $false }
        if (-not $Title.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        return ($Title.Substring($prefix.Length) -match '^[1-9][0-9]*$')
    }

    # PASS 1: identify every MANAGED terminal window.
    #
    # This must be a separate pass. EnumWindows order is not guaranteed, and in the
    # genuine Stage 3B7G2 evidence the helper window (0x20330) is enumerated BEFORE
    # its owner (0x50366). Evaluating relationships inline would test an auxiliary
    # against a managed set that is still empty.
    $candidates = [System.Collections.Generic.List[object]]::new()

    foreach ($w in @($Windows)) {
        if ($null -eq $w) { continue }

        $hwnd = [string](Get-P9HProp -Object $w -Name 'hwnd')
        $class = [string](Get-P9HProp -Object $w -Name 'class')
        $title = [string](Get-P9HProp -Object $w -Name 'title')
        $owner = [string](Get-P9HProp -Object $w -Name 'owner')
        $pidValue = [int](Get-P9HProp -Object $w -Name 'pid')

        $proc = $null
        if ($null -ne $ProcessByPid -and $ProcessByPid.ContainsKey($pidValue)) { $proc = $ProcessByPid[$pidValue] }
        $procName = if ($null -ne $proc) { [string](Get-P9HProp -Object $proc -Name 'name') } else { $null }
        $argv = if ($null -ne $proc) { [string](Get-P9HProp -Object $proc -Name 'commandLine') } else { '' }

        $classOk = ($class -ceq $ManagedWindowClass)
        $procOk = (-not [string]::IsNullOrWhiteSpace($procName) -and
            [string]::Equals($procName, ($ManagedProcessName + '.exe'), [System.StringComparison]::OrdinalIgnoreCase))
        $titleOk = ([string]::Equals($title, $ExpectedWindowId, [System.StringComparison]::Ordinal))

        $record = [ordered]@{
            hwnd = $hwnd; class = $class; pid = $pidValue; processName = $procName
            title = $title; owner = $owner
            rect = ('{0},{1} {2}x{3}' -f (Get-P9HProp $w 'x'), (Get-P9HProp $w 'y'), (Get-P9HProp $w 'width'), (Get-P9HProp $w 'height'))
        }
        $candidates.Add([pscustomobject]@{
                Record        = $record
                IsManaged     = ($classOk -and $procOk -and $titleOk)
                Argv          = $argv
                Proc          = $proc
                SessionId     = if ($null -ne $proc) { [int](Get-P9HProp -Object $proc -Name 'sessionId') } else { $null }
                ExStyle       = (ConvertFrom-StyleText (Get-P9HProp -Object $w -Name 'exStyle'))
                StyleRecorded = ($null -ne (ConvertFrom-StyleText (Get-P9HProp -Object $w -Name 'exStyle')))
            }) | Out-Null
    }

    # The managed set is now COMPLETE before any ownership question is asked.
    foreach ($cand in $candidates) {
        if (-not $cand.IsManaged) { continue }
        $cand.Record['classification'] = 'managed-terminal'
        $managed.Add([pscustomobject]$cand.Record) | Out-Null
    }

    $managedPids = @($managed | ForEach-Object { [int]$_.pid })

    function Test-StrictDescendant {
        param([int]$StartPid)
        if ($null -eq $ProcessByPid) { return $false }
        $seen = @{}
        $cursor = $StartPid
        $hops = 0
        while ($true) {
            if ($hops -gt 32) { return $false }
            if ($seen.ContainsKey($cursor)) { return $false }
            $seen[$cursor] = $true

            if (-not $ProcessByPid.ContainsKey($cursor)) { return $false }
            $node = $ProcessByPid[$cursor]
            $parent = [int](Get-P9HProp -Object $node -Name 'ppid')
            $hops++
            if ($parent -le 0) { return $false }
            if ($managedPids -contains $parent) { return $true }
            $cursor = $parent
        }
    }

    function Get-ArgvFlag {
        param([string]$Argv, [string]$Flag)
        if ([string]::IsNullOrWhiteSpace($Argv)) { return $null }
        $m = [regex]::Match($Argv, '(?:^|\s)-' + [regex]::Escape($Flag) + '\s+(?:"(?<v>[^"]*)"|(?<v>\S+))')
        if (-not $m.Success) { return $null }
        return [string]$m.Groups['v'].Value
    }

    # PASS 2: classify every non-managed attributed window under the positive
    # auxiliary-role contract.
    foreach ($cand in $candidates) {
        if ($cand.IsManaged) { continue }
        $record = $cand.Record
        $argv = [string]$cand.Argv
        $owner = [string]$record['owner']
        $class = [string]$record['class']
        $title = [string]$record['title']
        $procName = [string]$record['processName']

        $failed = [System.Collections.Generic.List[string]]::new()
        $gaps = [System.Collections.Generic.List[string]]::new()

        # --- COMPETING MANAGED UI -------------------------------------------------
        # Positive evidence of another managed UI, reported on its own so a
        # competing terminal can never be mistaken for a harmless helper.
        $claimsManagedClass = [string]::Equals($class, $ManagedWindowClass, [System.StringComparison]::Ordinal)
        $claimsManagedTitle = (Test-ManagedTitleFamily -Title $title -WindowId $ExpectedWindowId)
        if ($claimsManagedClass -or $claimsManagedTitle) {
            $record['classification'] = 'competing-managed-ui'
            $why = @()
            if ($claimsManagedClass) { $why += 'managed-terminal-class' }
            if ($claimsManagedTitle) { $why += 'managed-title-family' }
            $record['reason'] = 'competing-managed-ui:' + ($why -join '+')
            $competing.Add([pscustomobject]$record) | Out-Null
            continue
        }

        # --- A8: the CLASS must be a positively identified auxiliary role --------
        # This is the factor that stops a user-facing application window - or an
        # arbitrary class that merely carries WS_EX_TOOLWINDOW - from being
        # absorbed. Membership of the role set is NECESSARY, never sufficient.
        $roleClassOk = (@($AuxiliaryRoleClasses) -contains $class)
        if (-not $roleClassOk) {
            $failed.Add(('class-is-not-a-positively-identified-auxiliary-role:' + $class)) | Out-Null
        }

        # --- A1: GW_OWNER names exactly one managed terminal in THIS set ---------
        # The @() wrapper must surround the WHOLE expression: an `if` used as an
        # expression unrolls a single-element result to a scalar under StrictMode.
        $ownerMatches = @(if (-not [string]::IsNullOrWhiteSpace($owner) -and $owner -ne '0x0') {
                $managed | Where-Object { [string]::Equals([string]$_.hwnd, $owner, [System.StringComparison]::OrdinalIgnoreCase) }
            })
        if ($ownerMatches.Count -ne 1) { $failed.Add('owner-not-a-managed-terminal') | Out-Null }

        # --- A3: the owning process record must RESOLVE --------------------------
        if ($null -eq $cand.Proc -or [string]::IsNullOrWhiteSpace($procName)) {
            $failed.Add('owning-process-unresolved') | Out-Null
        }

        # --- A4: same session as the managed terminal ----------------------------
        if ($null -ne $cand.Proc -and $ownerMatches.Count -eq 1) {
            $terminalPid = [int]$ownerMatches[0].pid
            $terminalProc = if ($ProcessByPid -and $ProcessByPid.ContainsKey($terminalPid)) { $ProcessByPid[$terminalPid] } else { $null }
            if ($null -eq $terminalProc) {
                $failed.Add('managed-terminal-process-unresolved') | Out-Null
            }
            elseif ([int](Get-P9HProp -Object $terminalProc -Name 'sessionId') -ne [int]$cand.SessionId) {
                $failed.Add('session-mismatch') | Out-Null
            }
        }

        # --- A5: STRICT descendant of the managed terminal -----------------------
        if ($null -ne $cand.Proc) {
            if (-not (Test-StrictDescendant -StartPid ([int]$record['pid']))) {
                $failed.Add('not-a-strict-descendant-of-managed-terminal') | Out-Null
            }
        }

        # --- A6: ALL THREE pinned identity values, exactly equal -----------------
        $argvSet = Get-ArgvFlag -Argv $argv -Flag 'SetId'
        $argvTerm = Get-ArgvFlag -Argv $argv -Flag 'TerminalId'
        $argvWin = Get-ArgvFlag -Argv $argv -Flag 'WindowId'

        if ([string]::IsNullOrWhiteSpace($argv)) {
            $failed.Add('owner-command-line-missing') | Out-Null
        }
        else {
            if ($null -eq $argvSet) { $failed.Add('setId-absent-from-owner-argv') | Out-Null }
            elseif (-not [string]::Equals($argvSet, $ExpectedSetId, [System.StringComparison]::Ordinal)) {
                $failed.Add(('setId-mismatch:' + $argvSet)) | Out-Null
            }

            if ($null -eq $argvTerm) { $failed.Add('terminalId-absent-from-owner-argv') | Out-Null }
            elseif (-not [string]::Equals($argvTerm, $ExpectedTerminalId, [System.StringComparison]::Ordinal)) {
                $failed.Add(('terminalId-mismatch:' + $argvTerm)) | Out-Null
            }

            if ($null -eq $argvWin) { $failed.Add('windowId-absent-from-owner-argv') | Out-Null }
            elseif (-not [string]::Equals($argvWin, $ExpectedWindowId, [System.StringComparison]::Ordinal)) {
                $failed.Add(('windowId-mismatch:' + $argvWin)) | Out-Null
            }
        }

        # --- CORROBORATION: extended style -------------------------------------
        # Recorded, never decisive. Absence is an evidence gap; a recorded value is
        # supporting evidence. Neither can accept or reject on its own.
        $corroborated = $null
        if (-not $cand.StyleRecorded) {
            $gaps.Add('window-style-not-recorded') | Out-Null
        }
        else {
            $corroborated = (($cand.ExStyle -band $CorroboratingExStyleMask) -ne 0)
        }

        $record['auxiliaryContract'] = 'p9h.auxiliary-window.v3'
        $record['auxiliaryRoleClass'] = $roleClassOk
        $record['identitySetId'] = $argvSet
        $record['identityTerminalId'] = $argvTerm
        $record['identityWindowId'] = $argvWin
        $record['exStyle'] = if ($cand.StyleRecorded) { ('0x{0:X8}' -f $cand.ExStyle) } else { $null }
        $record['styleCorroboratesRole'] = $corroborated

        if ($failed.Count -eq 0) {
            $record['classification'] = 'auxiliary'
            $record['reason'] = 'auxiliary-role-contract-satisfied'
            $auxiliary.Add([pscustomobject]$record) | Out-Null
        }
        else {
            $record['classification'] = 'unclassified'
            $record['reason'] = ($failed -join ';')
            if ($gaps.Count -gt 0) { $record['evidenceGaps'] = @($gaps.ToArray()) }
            $unclassified.Add([pscustomobject]$record) | Out-Null
        }
    }

    $count = $managed.Count
    $ok = ($count -eq 1 -and $unclassified.Count -eq 0 -and $competing.Count -eq 0)

    $reason = if ($competing.Count -gt 0) { 'competing-managed-ui-evidence' }
              elseif ($unclassified.Count -gt 0) { 'unclassified-attributed-window' }
              elseif ($count -eq 0) { 'no-managed-terminal-window' }
              elseif ($count -gt 1) { 'multiple-managed-terminal-windows' }
              else { 'one-managed-terminal-window' }

    $gapList = @($unclassified | ForEach-Object {
            $g = Get-P9HProp -Object $_ -Name 'evidenceGaps'
            if ($null -ne $g) { @($g) }
        } | Sort-Object -Unique)

    return [pscustomobject][ordered]@{
        Schema                   = 'p9h.managed-terminals.v3'
        AuxiliaryContract        = 'p9h.auxiliary-window.v3'
        AuxiliaryRoleClasses     = @($AuxiliaryRoleClasses)
        ManagedWindowClass       = $ManagedWindowClass
        ManagedProcessName       = $ManagedProcessName
        ExpectedWindowId         = $ExpectedWindowId
        ExpectedTerminalId       = $ExpectedTerminalId
        ExpectedSetId            = $ExpectedSetId
        CorroboratingExStyleMask = ('0x{0:X8}' -f $CorroboratingExStyleMask)
        RawAttributedHwndCount   = @($Windows).Count
        ManagedTerminalCount     = $count
        AuxiliaryCount           = $auxiliary.Count
        UnclassifiedCount        = $unclassified.Count
        CompetingManagedUiCount  = $competing.Count
        QualifyingHwnd           = if ($count -eq 1) { [string]$managed[0].hwnd } else { $null }
        QualifyingPid            = if ($count -eq 1) { [int]$managed[0].pid } else { $null }
        Managed                  = @($managed.ToArray())
        Auxiliary                = @($auxiliary.ToArray())
        Unclassified             = @($unclassified.ToArray())
        CompetingManagedUi       = @($competing.ToArray())
        # The qualification title check is a PROXY for the product's UI-Automation
        # tab-title-family validator, not that validator.
        IdentityProxy            = 'top-level-window-title-equals-windowId'
        # Properties this evidence set cannot establish. Reported, never assumed.
        UnprovenProperties       = @(
            'GWL_STYLE'
            'GWL_EXSTYLE'
            'WS_CHILD'
            'ui-automation-tab-title-family'
        )
        EvidenceGaps             = @($gapList)
        Ok                       = $ok
        Reason                   = $reason
    }
}

function Get-P9HE1Verdict {
    # E1 verdict from the two monitor captures plus the final transition proof.
    param(
        [Parameter(Mandatory)][string]$PreCapturePath,
        [Parameter(Mandatory)][string]$PostCapturePath,
        [Parameter(Mandatory)][string]$ObserverLogPath,
        [Parameter(Mandatory)][int]$TargetSessionId,
        [Parameter(Mandatory)][string]$TargetUser,
        [AllowNull()][string]$TargetLogonTime = $null,
        [string]$TrialId = '',
        # Stage 3B7F-R1-A: demand that the PRE monitor capture follow the
        # authoritative pre WTS observation. Off by default (a capture-then-observe
        # sequence is coherent); the R1 trial contract requires it.
        [switch]$RequirePreCaptureAfterPreObservation
    )

    $sub = [ordered]@{}
    $reasons = [System.Collections.Generic.List[string]]::new()

    $pre = Read-P9HJsonArtifact -Path $PreCapturePath
    $post = Read-P9HJsonArtifact -Path $PostCapturePath

    if (-not $pre.Ok -or -not $post.Ok) {
        $reasons.Add('monitor-captures-missing:' + $(if (-not $pre.Ok) { 'pre-' + $pre.Reason } else { '' }) + $(if (-not $post.Ok) { 'post-' + $post.Reason } else { '' }))
        return [pscustomobject][ordered]@{ Verdict = 'INCONCLUSIVE'; DisconnectProven = $false; SubObservations = $sub; Reasons = @($reasons) }
    }

    $a = $pre.Data
    $b = $post.Data

    $preMon = Get-P9HMonitorIdentitySet -Capture $a
    $postMon = Get-P9HMonitorIdentitySet -Capture $b

    $sub['preRawMonitorsPresent'] = [bool]$preMon.Ok
    $sub['postRawMonitorsPresent'] = [bool]$postMon.Ok
    $sub['tokenListAgreesWithRecords'] = ([bool]$preMon.Consistent -and [bool]$postMon.Consistent)

    if (-not $preMon.Ok -or -not $postMon.Ok) {
        $why = @()
        if (-not $preMon.Ok) { $why += 'pre-' + $preMon.Reason }
        if (-not $postMon.Ok) { $why += 'post-' + $postMon.Reason }
        $reasons.Add('raw-monitor-evidence-missing:' + ($why -join ','))
        return [pscustomobject][ordered]@{ Verdict = 'NOT FULLY EVIDENCED'; TokensSatisfied = $false; DisconnectProven = $false; SubObservations = $sub; Reasons = @($reasons) }
    }

    if (-not $preMon.Consistent -or -not $postMon.Consistent) {
        $reasons.Add('token-list-disagrees-with-monitor-records')
    }

    $prePairs = Get-P9HMonitorPairs -Records $preMon.Records
    $postPairs = Get-P9HMonitorPairs -Records $postMon.Records
    $preIdentities = @($preMon.Records | ForEach-Object { [string]$_.identity })
    $postIdentities = @($postMon.Records | ForEach-Object { [string]$_.identity })

    $tokenCountOk = ($preIdentities.Count -eq 2 -and $postIdentities.Count -eq 2)
    $distinctOk = (@(@($preIdentities | Sort-Object -Unique).Count) -eq 2 -and @(@($postIdentities | Sort-Object -Unique).Count) -eq 2)
    $tokenSetEqual = [string]::Equals((@($preIdentities | Sort-Object) -join '|'), (@($postIdentities | Sort-Object) -join '|'), [System.StringComparison]::Ordinal)
    $pairsEqual = [string]::Equals((@($prePairs) -join ';'), (@($postPairs) -join ';'), [System.StringComparison]::Ordinal)
    $negativeOrigin = ((Test-P9HNegativeOrigin -Records $preMon.Records) -and (Test-P9HNegativeOrigin -Records $postMon.Records))
    $identityComplete = [bool]((Get-P9HProp -Object $a -Name 'identityComplete') -and (Get-P9HProp -Object $b -Name 'identityComplete'))

    $preSession = [int](Get-P9HProp -Object $a -Name 'sessionId')
    $postSession = [int](Get-P9HProp -Object $b -Name 'sessionId')
    $nonSession0 = ($preSession -ne 0 -and $postSession -ne 0)
    $sessionMatchesTarget = ($preSession -eq $TargetSessionId -and $postSession -eq $TargetSessionId)
    $sessionConsistent = ($preSession -eq $postSession)

    $preTrial = [string](Get-P9HProp -Object $a -Name 'trialId')
    $postTrial = [string](Get-P9HProp -Object $b -Name 'trialId')
    $trialPresent = (-not [string]::IsNullOrWhiteSpace($preTrial) -and -not [string]::IsNullOrWhiteSpace($postTrial))
    $trialAgrees = ($trialPresent -and
                    [string]::Equals($preTrial, $postTrial, [System.StringComparison]::Ordinal) -and
                    ([string]::IsNullOrWhiteSpace($TrialId) -or [string]::Equals($preTrial, $TrialId, [System.StringComparison]::Ordinal)))

    $preCaptureUtc = ConvertTo-P9HUtcOrNull -Value (Get-P9HProp -Object $a -Name 'capturedUtc')
    $postCaptureUtc = ConvertTo-P9HUtcOrNull -Value (Get-P9HProp -Object $b -Name 'capturedUtc')
    $timestampsValid = ($null -ne $preCaptureUtc -and $null -ne $postCaptureUtc)
    $captureOrderOk = ($timestampsValid -and $preCaptureUtc -lt $postCaptureUtc)

    $sub['twoDistinctTokens'] = ($tokenCountOk -and $distinctOk)
    $sub['tokenSetsEqual'] = $tokenSetEqual
    $sub['tokenRectPairsEqual'] = $pairsEqual
    $sub['negativeOriginObserved'] = $negativeOrigin
    $sub['identityComplete'] = $identityComplete
    $sub['nonSession0Evidence'] = $nonSession0
    $sub['sessionMatchesTarget'] = $sessionMatchesTarget
    $sub['sessionConsistent'] = $sessionConsistent
    $sub['trialProvenancePresent'] = $trialPresent
    $sub['trialProvenanceAgrees'] = $trialAgrees
    $sub['captureTimestampsValid'] = $timestampsValid
    $sub['captureChronologyOk'] = $captureOrderOk

    if (-not $tokenCountOk) { $reasons.Add('token-count-not-two') }
    if ($tokenCountOk -and -not $distinctOk) { $reasons.Add('tokens-not-distinct') }
    if (-not $tokenSetEqual) { $reasons.Add('token-sets-differ') }
    if (-not $pairsEqual) { $reasons.Add('token-rect-pairs-differ') }
    if (-not $negativeOrigin) { $reasons.Add('negative-origin-not-observed') }
    if (-not $identityComplete) { $reasons.Add('identity-incomplete') }
    if (-not $nonSession0) { $reasons.Add('session-0-evidence') }
    if ($nonSession0 -and -not $sessionMatchesTarget) { $reasons.Add('capture-session-not-target') }
    if (-not $sessionConsistent) { $reasons.Add('capture-sessions-incompatible') }
    if (-not $trialPresent) { $reasons.Add('trial-provenance-missing') }
    elseif (-not $trialAgrees) { $reasons.Add('trial-provenance-conflict') }
    if (-not $timestampsValid) { $reasons.Add('capture-timestamp-invalid') }
    elseif (-not $captureOrderOk) { $reasons.Add('capture-chronology-invalid') }

    $proof = Get-P9HDisconnectProof -ObserverLogPath $ObserverLogPath -SessionId $TargetSessionId `
        -User $TargetUser -TrialId $TrialId -LogonTime $TargetLogonTime

    $sub['confirmedTransition'] = [bool]$proof.Proven
    if (-not $proof.Proven) { $reasons.Add('disconnect-not-proven:' + $proof.Reason) }

    $chronologyOk = $false
    if ($proof.Proven -and $timestampsValid) {
        $discUtc = ConvertTo-P9HUtcOrNull -Value $proof.Disc.utc
        $postObsUtc = ConvertTo-P9HUtcOrNull -Value $proof.Post.utc
        if ($null -ne $discUtc -and $null -ne $postObsUtc) {
            $chronologyOk = ($preCaptureUtc -lt $discUtc) -and ($postCaptureUtc -gt $postObsUtc)
        }
        else { $reasons.Add('transition-timestamps-invalid') }
    }

    $sub['captureBracketsTransition'] = $chronologyOk
    if ($proof.Proven -and -not $chronologyOk -and $reasons -notcontains 'transition-timestamps-invalid') {
        $reasons.Add('capture-does-not-bracket-transition')
    }

    # ---------------------------------------------------------------------
    # Stage 3B7F-R1-A: FAIL-CLOSED LOWER-BOUND CHRONOLOGY
    #
    # The checks above only bound the captures from ABOVE (pre must precede the
    # disconnect) and the post capture from BELOW (post must follow the post
    # observation). Nothing bounded the PRE capture from BELOW, so a PRE capture
    # that predates the very session it claims to describe - an impossible
    # timeline - still satisfied the complete predicate. That was reproduced with
    # a synthetic PRE capture timestamped five hours before the target logon and
    # the evaluator returned PASS with no reasons.
    #
    # TWO bounds are now available, with deliberately different strengths:
    #
    # (1) TARGET LOGON - ALWAYS ENFORCED.
    #     A monitor snapshot of a session cannot legitimately have been taken
    #     before that session existed. This is an EVIDENTIAL impossibility, so it
    #     is unconditional and is part of the acceptance predicate.
    #
    # (2) AUTHORITATIVE PRE OBSERVATION - ENFORCED ONLY ON REQUEST.
    #     Some trial contracts prescribe "collect the pre observation, THEN capture
    #     the monitors". Where a contract says that, the ordering is a procedural
    #     requirement and the caller can demand it with
    #     -RequirePreCaptureAfterPreObservation. It is NOT implied by default,
    #     because capturing the monitors first and persisting the pre WTS
    #     observation immediately afterwards is still a coherent, truthful
    #     sequence - both precede the disconnect, and the capture does not claim
    #     knowledge of a session that did not yet exist.
    #
    # Both bounds are conditioned on the bound being AVAILABLE and parseable: an
    # absent or unreadable bound is reported as its own reason rather than being
    # silently skipped, so the predicate cannot be satisfied by omitting evidence.
    # ---------------------------------------------------------------------
    $preLowerBoundOk = $true

    # (1) target logon lower bound (mandatory)
    $pinnedLogonUtc = ConvertTo-P9HUtcOrNull -Value $TargetLogonTime
    $logonBoundOk = $null
    if ($null -eq $pinnedLogonUtc) {
        # Without a pinned logon there is no session identity to bound against.
        $logonBoundOk = $false
        $preLowerBoundOk = $false
        $reasons.Add('pinned-logon-unavailable-for-chronology')
    }
    else {
        $logonBoundOk = ($preCaptureUtc -ge $pinnedLogonUtc)
        if (-not $logonBoundOk) {
            $preLowerBoundOk = $false
            $reasons.Add('pre-capture-precedes-target-logon')
        }
    }

    # (2) authoritative pre-observation lower bound (opt-in per trial contract)
    $preObsUtcForBound = $null
    if ($proof.Proven -and $null -ne $proof.Pre) {
        $preObsUtcForBound = ConvertTo-P9HUtcOrNull -Value $proof.Pre.utc
    }
    $preObsBoundOk = $null
    if ($RequirePreCaptureAfterPreObservation) {
        if ($null -eq $preObsUtcForBound) {
            $preObsBoundOk = $false
            $preLowerBoundOk = $false
            $reasons.Add('pre-observation-timestamp-unavailable-for-chronology')
        }
        else {
            $preObsBoundOk = ($preCaptureUtc -ge $preObsUtcForBound)
            if (-not $preObsBoundOk) {
                $preLowerBoundOk = $false
                $reasons.Add('pre-capture-precedes-pre-observation')
            }
        }
    }
    else {
        # Not required by this contract; still REPORT the relationship so the
        # ordering is visible in the verdict object either way.
        $preObsBoundOk = if ($null -ne $preObsUtcForBound) { ($preCaptureUtc -ge $preObsUtcForBound) } else { $null }
    }

    $sub['preCaptureNotBeforeTargetLogon'] = $logonBoundOk
    $sub['preCaptureAfterPreObservationRequired'] = [bool]$RequirePreCaptureAfterPreObservation
    $sub['preCaptureNotBeforePreObservation'] = $preObsBoundOk
    $sub['preCaptureLowerBoundOk'] = $preLowerBoundOk

    $tokensSatisfied = $tokenCountOk -and $distinctOk -and $tokenSetEqual -and $pairsEqual -and
                       $negativeOrigin -and $identityComplete -and $nonSession0 -and
                       $sessionMatchesTarget -and $sessionConsistent -and
                       $trialPresent -and $trialAgrees -and $timestampsValid -and $captureOrderOk -and
                       $preMon.Consistent -and $postMon.Consistent

    # Stage 3B7F-R1-A: the lower-bound chronology is part of the acceptance
    # predicate, not a separate advisory observation. A capture that cannot have
    # existed when it claims to have been taken is not evidence of a transition.
    $verdict = 'NOT FULLY EVIDENCED'
    if ($tokensSatisfied -and $proof.Proven -and $chronologyOk -and $preLowerBoundOk) { $verdict = 'PASS' }

    return [pscustomobject][ordered]@{
        Verdict = $verdict
        TokensSatisfied = $tokensSatisfied
        DisconnectProven = [bool]$proof.Proven
        DisconnectReason = [string]$proof.Reason
        ChronologyOk = $chronologyOk
        PreCaptureLowerBoundOk = $preLowerBoundOk
        SubObservations = $sub
        Reasons = @($reasons)
        Tokens = @($preIdentities)
        MonitorPairs = @($prePairs)
    }
}

function Test-P9HLaunchTrace {
    # Validate a lifecycle trace as a WHOLE, using ONLY fields DevWS emits.
    #
    # Required for a valid trace:
    #   * every line parses (no malformed records);
    #   * the required events are present exactly once;
    #   * lifecycle events appear in causal order (rank AND increasing utcMs);
    #   * a NON-EMPTY planId is present on stage2-broker-ready, and matches any
    #     stage2-broker-replanned event;
    #   * the product's transaction identity (`set`) matches the expected SetId;
    #   * the single transaction-end reports a clean, non-uncertain broker result.
    #
    # Deliberately NOT required: a per-event `trialId`. The product never emits
    # one (verified: zero occurrences of any trial identifier across src/), so
    # requiring it would invalidate every real trace. Trial identity is carried by
    # the artifact itself plus the `set` correlation below.
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$TrialId = '',
        [string]$ExpectedSetId = ''
    )

    $required = @('lifecycle-layout-plan', 'stage2-broker-ready', 'stage2-terminal-final', 'transaction-end')
    $order = @{
        'lifecycle-layout-plan'  = 1
        'transaction-start'      = 2
        'stage2-broker-prepare-sent' = 3
        'stage2-broker-ready'    = 4
        'stage2-broker-replanned' = 5
        'stage2-go-ack'          = 6
        'stage2-terminal-kick'   = 7
        'stage2-terminal-final'  = 8
        'transaction-end'        = 9
    }

    $result = [ordered]@{
        Ok = $false; Reason = $null; Events = @(); PlanId = $null; SetId = $null; Rejections = @(); Skipped = @()
    }

    if (-not [string]::IsNullOrWhiteSpace($TrialId)) {
        # The trace is an artifact of the trial; require the caller to name it so
        # a trace cannot be scored without a trial binding.
        $result.TrialId = $TrialId
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $result.Reason = 'trace-missing'; return [pscustomobject]$result }

    $events = [System.Collections.Generic.List[object]]::new()
    $malformed = 0
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $events.Add(($line | ConvertFrom-Json -ErrorAction Stop)) | Out-Null } catch { $malformed++ }
    }

    $result.Events = @($events)

    if ($malformed -gt 0) { $result.Reason = 'trace-malformed-lines'; return [pscustomobject]$result }
    if ($events.Count -eq 0) { $result.Reason = 'trace-empty'; return [pscustomobject]$result }

    foreach ($name in $required) {
        $found = @($events | Where-Object { [string]$_.event -eq $name })
        if ($found.Count -eq 0) { $result.Reason = ('trace-missing-event:' + $name); return [pscustomobject]$result }
        if ($found.Count -gt 1) { $result.Reason = ('trace-duplicate-event:' + $name); return [pscustomobject]$result }
    }

    # Value-level completeness of the required events.
    $planEvent = @($events | Where-Object { [string]$_.event -eq 'lifecycle-layout-plan' })[0]
    $brokerEvent = @($events | Where-Object { [string]$_.event -eq 'stage2-broker-ready' })[0]
    $finalEvent = @($events | Where-Object { [string]$_.event -eq 'stage2-terminal-final' })[0]
    $endEvent = @($events | Where-Object { [string]$_.event -eq 'transaction-end' })[0]

    # planId: the ONLY authoritative carriers are broker-ready and broker-replanned.
    $brokerPlanId = [string](Get-P9HProp -Object $brokerEvent -Name 'planId')
    if ([string]::IsNullOrWhiteSpace($brokerPlanId)) { $result.Reason = 'trace-plan-id-missing'; return [pscustomobject]$result }
    $result.PlanId = $brokerPlanId

    $replanned = @($events | Where-Object { [string]$_.event -eq 'stage2-broker-replanned' })
    foreach ($rp in $replanned) {
        $rpPlan = [string](Get-P9HProp -Object $rp -Name 'planId')
        if ([string]::IsNullOrWhiteSpace($rpPlan)) { $result.Reason = 'trace-replanned-plan-id-missing'; return [pscustomobject]$result }
        if (-not [string]::Equals($rpPlan, $brokerPlanId, [System.StringComparison]::Ordinal)) {
            $result.Reason = 'trace-plan-id-conflict'; return [pscustomobject]$result
        }
    }

    # Transaction identity: the product's `set`.
    $planSet = [string](Get-P9HProp -Object $planEvent -Name 'set')
    $endSet = [string](Get-P9HProp -Object $endEvent -Name 'set')
    if ([string]::IsNullOrWhiteSpace($planSet)) { $result.Reason = 'trace-set-missing'; return [pscustomobject]$result }
    $result.SetId = $planSet

    if (-not [string]::IsNullOrWhiteSpace($endSet) -and
        -not [string]::Equals($planSet, $endSet, [System.StringComparison]::Ordinal)) {
        $result.Reason = 'trace-set-conflict'; return [pscustomobject]$result
    }

    if (-not [string]::IsNullOrWhiteSpace($ExpectedSetId) -and
        -not [string]::Equals($planSet, $ExpectedSetId, [System.StringComparison]::Ordinal)) {
        $result.Reason = ('trace-set-mismatch:expected=' + $ExpectedSetId + ',observed=' + $planSet)
        return [pscustomobject]$result
    }

    # Causal ordering: rank, then utcMs monotonicity where the product supplied it.
    $lastRank = 0
    $lastMs = 0L
    $sawMs = $false
    foreach ($e in $events) {
        $name = [string]$e.event
        if (-not $order.ContainsKey($name)) { continue }
        $rank = [int]$order[$name]
        if ($rank -lt $lastRank) { $result.Reason = ('trace-order-invalid:' + $name); return [pscustomobject]$result }
        $lastRank = $rank

        $ms = ConvertFrom-P9HEpochMs -Value (Get-P9HProp -Object $e -Name 'utcMs')
        if ($null -ne $ms) {
            $value = ([DateTimeOffset]$ms).ToUnixTimeMilliseconds()
            if ($sawMs -and $value -lt $lastMs) { $result.Reason = ('trace-time-invalid:' + $name); return [pscustomobject]$result }
            $lastMs = $value
            $sawMs = $true
        }
    }

    # Completion state.
    if ([int](Get-P9HProp -Object $finalEvent -Name 'failures') -ne 0) { $result.Reason = 'trace-final-failures-present'; return [pscustomobject]$result }
    if ([int](Get-P9HProp -Object $finalEvent -Name 'finalized') -ne 1) { $result.Reason = 'trace-finalized-not-one'; return [pscustomobject]$result }
    if (-not [bool](Get-P9HProp -Object $endEvent -Name 'broker')) { $result.Reason = 'trace-broker-not-used'; return [pscustomobject]$result }
    if ([bool](Get-P9HProp -Object $endEvent -Name 'uncertain')) { $result.Reason = 'trace-broker-uncertain'; return [pscustomobject]$result }
    if (@(Get-P9HProp -Object $endEvent -Name 'failures').Count -gt 0) { $result.Reason = 'trace-failures-present'; return [pscustomobject]$result }

    # N2-A skip evidence, from the plan event's `skipped` array.
    $result.Skipped = @(Get-P9HProp -Object $planEvent -Name 'skipped')

    $result.Ok = $true
    $result.Reason = 'ok'
    return [pscustomobject]$result
}

function Get-P9HLaunchAttribution {
    # Causal attribution of a created terminal to THIS launch.
    #
    # Stage 2.3: LauncherPid and LaunchedAtUtc are now USED. A process qualifies
    # only when ALL hold:
    #   1. its argv carries the launch identity the product writes
    #      (-SetId, -TerminalId, -WindowId), per src/lib/devws-terminal.ps1;
    #   2. its creation time was recovered;
    #   3. its creation time falls inside the launch window
    #      [launchedAt - tolerance, exitedAt + tolerance], so a stale process left
    #      over from an earlier run cannot match by argv alone;
    #   4. it is not the launcher process itself.
    #
    # Parentage is never inferred: the terminal is created by the elevated broker,
    # so it is not a direct child of cmd.exe.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AddedProcesses,
        [Parameter(Mandatory)][string]$ExpectedWindowId,
        [Parameter(Mandatory)][string]$ExpectedTerminalId,
        [Parameter(Mandatory)][string]$ExpectedSetId,
        [AllowNull()]$LauncherPid = $null,
        [AllowNull()][string]$LaunchedAtUtc = $null,
        [AllowNull()][string]$ExitedAtUtc = $null,
        [int]$ClockToleranceSeconds = 120
    )

    $windowStart = ConvertTo-P9HUtcOrNull -Value $LaunchedAtUtc
    $windowEnd = ConvertTo-P9HUtcOrNull -Value $ExitedAtUtc

    # NOTE: not $matches - that name collides with PowerShell's automatic
    # $Matches and is silently overwritten by every -match below.
    $attributed = [System.Collections.Generic.List[pscustomobject]]::new()
    $rejectedForTime = 0
    $rejectedForIdentity = 0

    foreach ($p in $AddedProcesses) {
        $cmd = [string](Get-P9HProp -Object $p -Name 'commandLine')
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }

        $hasWindow = $cmd -match ('-WindowId\s+"?' + [regex]::Escape($ExpectedWindowId) + '"?(\s|$)')
        $hasTerminal = $cmd -match ('-TerminalId\s+"?' + [regex]::Escape($ExpectedTerminalId) + '"?(\s|$)')
        $hasSet = $cmd -match ('-SetId\s+"?' + [regex]::Escape($ExpectedSetId) + '"?(\s|$)')
        if (-not ($hasWindow -and $hasTerminal -and $hasSet)) { $rejectedForIdentity++; continue }

        $pidValue = [int](Get-P9HProp -Object $p -Name 'pid')
        if ($null -ne $LauncherPid -and $pidValue -eq [int]$LauncherPid) { $rejectedForIdentity++; continue }

        $startUtc = ConvertTo-P9HUtcOrNull -Value (Get-P9HProp -Object $p -Name 'startUtc')
        if ($null -eq $startUtc) { $rejectedForTime++; continue }

        # Launch-window correlation. Without both bounds we cannot place the
        # process relative to the launch, so it is not attributable.
        if ($null -eq $windowStart -or $null -eq $windowEnd) {
            $rejectedForTime++
            continue
        }

        $tolerance = [TimeSpan]::FromSeconds($ClockToleranceSeconds)
        if ($startUtc -lt $windowStart.Subtract($tolerance) -or $startUtc -gt $windowEnd.Add($tolerance)) {
            $rejectedForTime++
            continue
        }

        $entry = [pscustomobject][ordered]@{
            pid      = $pidValue
            ppid     = [int](Get-P9HProp -Object $p -Name 'ppid')
            name     = [string](Get-P9HProp -Object $p -Name 'name')
            startUtc = $startUtc.ToString('o')
            evidence = 'argv identity + creation time inside launch window'
        }
        $attributed.Add($entry)
    }

    $reason = if ($attributed.Count -ge 1) { 'causally-attributed' }
              elseif (@($AddedProcesses).Count -eq 0) { 'no-new-processes' }
              elseif ($rejectedForTime -gt 0) { 'creation-time-outside-launch-window' }
              else { 'no-process-carries-launch-identity' }

    return [pscustomobject][ordered]@{
        Ok        = ($attributed.Count -ge 1)
        Count     = $attributed.Count
        Reason    = $reason
        Processes = @($attributed)
        RejectedByIdentity = $rejectedForIdentity
        RejectedByTime = $rejectedForTime
    }
}

function Get-P9HTrialProvenance {
    # SHARED provenance gate for both N2 verdicts.
    #
    # Stage 2.4.1: N2-B required the artifact binding but N2-A did not, so a
    # placement PASS could rest on artifacts that were never attributed to the
    # trial. Attribution is a property of the EVIDENCE, not of which measurement
    # consumed it, so both verdicts now consult this single gate.
    #
    # Independence is preserved: this gate checks ONLY provenance and trial
    # identity. It never inspects the exit code, terminal finalization or any
    # lifecycle success signal, so N2-A cannot inherit an N2-B failure.
    param(
        [string]$TrialId,
        [string]$ArtifactIndexPath,
        $ExitRecordValidation,
        [AllowNull()][hashtable]$ExpectedPaths = $null
    )

    $trialIdPresent = -not [string]::IsNullOrWhiteSpace($TrialId)
    $exitTrial = if ($null -ne $ExitRecordValidation -and $ExitRecordValidation.Valid) {
        [string](Get-P9HProp -Object $ExitRecordValidation.Data -Name 'trialId')
    } else { $null }
    $exitTrialPresent = -not [string]::IsNullOrWhiteSpace($exitTrial)
    $exitTrialMatches = ($trialIdPresent -and $exitTrialPresent -and
                         [string]::Equals($exitTrial, $TrialId, [System.StringComparison]::Ordinal))

    if ([string]::IsNullOrWhiteSpace($ArtifactIndexPath)) {
        # The binding is MANDATORY for an authoritative PASS. An absent index is
        # an evidence gap, not a reason to skip the check: without it there is no
        # way to know the trace and inventories belong to this trial at all.
        $binding = [pscustomobject][ordered]@{
            Ok = $false; Reason = 'artifact-index-not-supplied'; Roles = @()
            MissingRoles = @('artifact-index'); Mismatches = @(); BadLines = @()
        }
    }
    else {
        $binding = Get-P9HArtifactBinding -TrialId $TrialId -ArtifactIndexPath $ArtifactIndexPath `
            -RequiredRoles @('fixture', 'stdout', 'pre-windows', 'post-windows', 'exit-record', 'new-processes', 'trace') `
            -ExpectedPaths $ExpectedPaths
    }

    $reasons = [System.Collections.Generic.List[string]]::new()
    if (-not $trialIdPresent) { $reasons.Add('trial-id-missing') }
    elseif (-not $exitTrialPresent) { $reasons.Add('exit-record-trial-id-missing') }
    elseif (-not $exitTrialMatches) { $reasons.Add('exit-record-trial-mismatch:' + [string]$exitTrial) }
    if (-not $binding.Ok) { $reasons.Add('artifact-binding:' + $binding.Reason) }

    return [pscustomobject][ordered]@{
        Ok                 = ($reasons.Count -eq 0)
        Reasons            = @($reasons)
        TrialIdPresent     = $trialIdPresent
        TrialIdFromExit    = $exitTrial
        TrialIdMatches     = $exitTrialMatches
        Binding            = $binding
    }
}

function Get-P9HN2Verdicts {
    # Two INDEPENDENT verdicts: N2-A (placement skip) and N2-B (lifecycle).
    #
    # Stage 2.3: N2-A now requires POSITIVELY OBSERVED window creation with
    # attribution. A valid-but-empty inventory is evidence that no window was
    # observed, which cannot satisfy a criterion about a created window.
    # A missing pre-inventory is no longer treated as an empty baseline.
    param(
        [Parameter(Mandatory)][string]$FixturePath,
        [Parameter(Mandatory)][string]$TracePath,
        [Parameter(Mandatory)][string]$StdoutPath,
        [Parameter(Mandatory)][string]$PreWindowPath,
        [Parameter(Mandatory)][string]$PostWindowPath,
        [Parameter(Mandatory)][string]$ExitRecordPath,
        [Parameter(Mandatory)][string]$NewProcessPath,
        # Trial identity is REQUIRED for an authoritative verdict. An empty
        # value is an evidence gap, never an implicit "any trial".
        [Parameter(Mandatory)][string]$TrialId,
        [Parameter(Mandatory)][string]$ExpectedWindowId,
        [Parameter(Mandatory)][string]$ExpectedTerminalId,
        [Parameter(Mandatory)][string]$ExpectedSetId,
        # Trial artifact binding (Stage 2.4). When supplied, every required
        # artifact must be recorded in that trial artifact index with a digest
        # that still matches the bytes on disk.
        [string]$ArtifactIndexPath = '',
        # Stage 3B7G3 CONTRACT VERSION SELECTOR.
        #
        # 'RawAttributedHwndsV1'  (default, historical): N2-B identity requires
        #                          exactly one newly attributed visible top-level
        #                          HWND of ANY class. That is a PROCESS
        #                          association rule, and it counts an auxiliary
        #                          pseudoconsole owned by the launched terminal as
        #                          a second terminal window.
        #
        # 'ManagedTerminalV1'     (opt-in): N2-B identity requires exactly one
        #                          window matching the PRODUCT'S managed terminal
        #                          contract (exact CASCADIA_HOSTING_WINDOW_CLASS,
        #                          owning process WindowsTerminal, canonical title
        #                          family), while every OTHER attributed window
        #                          must be positively proven auxiliary - linked to
        #                          that one managed window by Win32 ownership or by
        #                          an owning process whose argv carries the SAME
        #                          pinned SetId/TerminalId/WindowId. Anything else
        #                          is UNCLASSIFIED and fails closed.
        #
        # The default is deliberately the HISTORICAL rule so no existing verdict
        # silently changes meaning.
        [ValidateSet('RawAttributedHwndsV1', 'ManagedTerminalV1')]
        [string]$WindowIdentityContract = 'RawAttributedHwndsV1'
    )

    $reasonsA = [System.Collections.Generic.List[string]]::new()
    $reasonsB = [System.Collections.Generic.List[string]]::new()

    $fixture = Read-P9HJsonArtifact -Path $FixturePath
    $exit = Test-P9HExitRecord -Path $ExitRecordPath

    # ---- SHARED trial provenance (Stage 2.4.1) ----
    # One gate, consulted by BOTH verdicts. It verifies only that the evidence
    # is attributed to this trial; it never inspects lifecycle success, so N2-A
    # stays independent of exit code and terminal finalization.
    $provenance = Get-P9HTrialProvenance -TrialId $TrialId -ArtifactIndexPath $ArtifactIndexPath `
        -ExitRecordValidation $exit -ExpectedPaths @{
            'fixture'       = $FixturePath
            'stdout'        = $StdoutPath
            'pre-windows'   = $PreWindowPath
            'post-windows'  = $PostWindowPath
            'exit-record'   = $ExitRecordPath
            'new-processes' = $NewProcessPath
            'trace'         = $TracePath
        }
    $trialIdPresent = $provenance.TrialIdPresent
    $exitTrial = $provenance.TrialIdFromExit
    $exitTrialPresent = -not [string]::IsNullOrWhiteSpace([string]$exitTrial)
    $exitTrialMatches = $provenance.TrialIdMatches
    $binding = $provenance.Binding

    # ---------- fixture ----------
    $fixtureOk = $false; $itemCountOne = $false; $anchorAbsent = $false
    $fallbackUnreachable = $false; $fallbackRectText = $null; $itemId = $null
    if ($fixture.Ok) {
        $fx = $fixture.Data
        $itemId = [string](Get-P9HProp -Object $fx -Name 'itemId')
        $itemCountOne = ([int](Get-P9HProp -Object $fx -Name 'enabledItems') -eq 1 -and
                         [int](Get-P9HProp -Object $fx -Name 'enabledTerminals') -eq 1 -and
                         [int](Get-P9HProp -Object $fx -Name 'totalItems') -eq 1)
        $anchorAbsent = [bool](Get-P9HProp -Object $fx -Name 'anchorAbsent')
        $lf = Get-P9HProp -Object $fx -Name 'layoutFallback'
        if ($null -ne $lf) {
            $fallbackRectText = ('{0},{1} {2}x{3}' -f (Get-P9HProp $lf 'x'), (Get-P9HProp $lf 'y'), (Get-P9HProp $lf 'w'), (Get-P9HProp $lf 'h'))
            $fallbackUnreachable = ([int](Get-P9HProp $lf 'x') -eq 9000 -and [int](Get-P9HProp $lf 'y') -eq 9000)
        }
        $fixtureOk = ($itemCountOne -and $anchorAbsent -and $fallbackUnreachable)
    }
    else { $reasonsA.Add('fixture-unreadable:' + $fixture.Reason) }

    # ---------- trace ----------
    $trace = Test-P9HLaunchTrace -Path $TracePath -TrialId $TrialId -ExpectedSetId $ExpectedSetId
    if (-not $trace.Ok) {
        $reasonsA.Add('trace-invalid:' + $trace.Reason)
        $reasonsB.Add('trace-invalid:' + $trace.Reason)
    }

    $events = @($trace.Events)

    # ---------- BOTH window inventories must be readable ----------
    $preWindows = Read-P9HJsonArtifact -Path $PreWindowPath
    $preObserved = $false
    $preList = @()
    if ($preWindows.Ok -and (Test-P9HHasProperty -Object $preWindows.Data -Name 'Windows')) {
        $preList = @((Get-P9HProp -Object $preWindows.Data -Name 'Windows'))
        $preObserved = $true
    }

    $postWindows = Read-P9HJsonArtifact -Path $PostWindowPath
    $postObserved = $false
    $postList = @()
    if ($postWindows.Ok -and (Test-P9HHasProperty -Object $postWindows.Data -Name 'Windows')) {
        $postList = @((Get-P9HProp -Object $postWindows.Data -Name 'Windows'))
        $postObserved = $true
    }

    # ---------- causal process attribution (shared by both verdicts) ----------
    $newProcs = Read-P9HJsonArtifact -Path $NewProcessPath
    $added = @()
    if ($newProcs.Ok -and (Test-P9HHasProperty -Object $newProcs.Data -Name 'Added')) {
        $added = @((Get-P9HProp -Object $newProcs.Data -Name 'Added'))
    }
    else { $reasonsB.Add('new-process-inventory-invalid:' + $(if ($newProcs.Ok) { 'schema-missing-added' } else { $newProcs.Reason })) }

    $attribution = Get-P9HLaunchAttribution -AddedProcesses $added `
        -ExpectedWindowId $ExpectedWindowId -ExpectedTerminalId $ExpectedTerminalId -ExpectedSetId $ExpectedSetId `
        -LauncherPid $(if ($exit.Valid) { $exit.Data.launcherPid } else { $null }) `
        -LaunchedAtUtc $(if ($exit.Valid) { $exit.Data.launchedAtUtc } else { $null }) `
        -ExitedAtUtc $(if ($exit.Valid) { $exit.Data.exitedAtUtc } else { $null })

    $processAttributed = [bool]$attribution.Ok
    $attributedPids = @($attribution.Processes | ForEach-Object { [int]$_.pid })

    # ---------- N2-A: skip requires an OBSERVED, attributed new window ----------
    $skipped = $false
    if ($null -ne $trace.Skipped) {
        $skipped = (@($trace.Skipped) -contains $itemId)
    }

    $warningPresent = $false
    if (Test-Path -LiteralPath $StdoutPath -PathType Leaf) {
        $so = Get-Content -LiteralPath $StdoutPath -Raw
        $warningPresent = ($so -match 'no reachable placement' -and $so -match 'will not be changed')
    }

    $windowAttribution = $null
    $windowAttributed = $false
    $newWindowCount = 0
    $fallbackApplied = $null
    if ($preObserved -and $postObserved -and $processAttributed) {
        $preHwnds = @($preList | ForEach-Object { [string](Get-P9HProp $_ 'hwnd') })
        $windowAttribution = Select-P9HAttributableWindow -PreWindowHwnds $preHwnds `
            -AfterWindows $postList -CandidatePids $attributedPids
        $windowAttributed = [bool]$windowAttribution.Attributed
        $newWindowCount = [int]$windowAttribution.Count

        # Was the unreachable fallback applied to the ATTRIBUTED window(s)?
        if ($windowAttributed) {
            $fallbackApplied = (@($windowAttribution.Windows | Where-Object {
                        [int](Get-P9HProp $_ 'x') -eq 9000 -and [int](Get-P9HProp $_ 'y') -eq 9000
                    }).Count -gt 0)
        }
        else {
            $fallbackApplied = $null
        }
    }
    else {
        if (-not $preObserved) { $reasonsA.Add('pre-window-observation-unavailable:' + $(if ($preWindows.Ok) { 'schema-missing-windows' } else { $preWindows.Reason })) }
        if (-not $postObserved) { $reasonsA.Add('post-window-observation-unavailable:' + $(if ($postWindows.Ok) { 'schema-missing-windows' } else { $postWindows.Reason })) }
        if ($preObserved -and $postObserved -and -not $processAttributed) {
            $reasonsA.Add('window-attribution-unavailable:' + $attribution.Reason)
        }
    }

    $n2a = 'INCONCLUSIVE'
    # Provenance is required for an AUTHORITATIVE placement result, exactly as
    # it is for lifecycle. It does not depend on exit code: a nonzero exit can
    # still leave the placement measurement valid, so this gate deliberately
    # reads only evidence attribution and never the lifecycle outcome.
    if (-not $provenance.Ok) { foreach ($r in @($provenance.Reasons)) { $reasonsA.Add($r) } }
    if (-not $fixtureOk) { $reasonsA.Add('fixture-invalid') }
    elseif (-not $provenance.Ok) { }   # reasons already recorded above
    elseif (-not $trace.Ok) { }
    elseif (-not $preObserved -or -not $postObserved) { }
    elseif (-not $processAttributed) { }
    elseif (-not $skipped) { $reasonsA.Add('item-not-in-skipped-set') }
    elseif (-not $warningPresent) { $reasonsA.Add('deterministic-warning-absent') }
    elseif (-not $windowAttributed) { $reasonsA.Add('no-newly-observed-attributed-window') }
    elseif ($fallbackApplied) { $reasonsA.Add('fallback-rectangle-applied') }
    else { $n2a = 'PASS' }

    # ---------- N2-B: lifecycle completion ----------
    $brokerOk = ($null -ne $trace.PlanId -and -not [string]::IsNullOrWhiteSpace([string]$trace.PlanId))
    $finalOk = $trace.Ok
    $zeroFailures = $trace.Ok

    $exitCaptured = ($exit.Valid -and [string]$exit.Data.outcome -eq 'exited' -and $null -ne $exit.Data.exitCode)
    $exitZero = ($exitCaptured -and [int]$exit.Data.exitCode -eq 0)
    $launcherOk = ($exit.Valid -and -not [string]::IsNullOrWhiteSpace([string]$exit.Data.launcherPath))

    # The attributed window's identity must be consistent with the plan: the
    # terminal we attributed must be the one the trace planned to skip.
    #
    # Stage 3B7G2 improved only the DIAGNOSTIC here.
    #
    # Stage 3B7G3 makes the measured IDENTITY DOMAIN explicit and versioned. The
    # historical rule counted PROCESS-associated HWNDs, which is a different
    # question from "how many MANAGED TERMINAL WINDOWS did the product create".
    # Under -WindowIdentityContract ManagedTerminalV1 the cardinality is taken from
    # the product's own contract instead, and every non-managed attributed window
    # must be POSITIVELY proven auxiliary or the verdict fails closed.
    $identityConsistent = $false
    $identityReason = $null
    $terminalClass = $null

    if ($WindowIdentityContract -eq 'ManagedTerminalV1') {
        # Build the pid -> process lookup from the attributed NEW processes, so a
        # window's owning process identity is evidence rather than an assumption.
        $procByPid = @{}
        foreach ($p in @($added)) { $procByPid[[int](Get-P9HProp -Object $p -Name 'pid')] = $p }
        $attributedWindowRecords = @($windowAttribution.Windows)
        $terminalClass = Get-P9HManagedTerminalWindowClassification -Windows $attributedWindowRecords `
            -ExpectedWindowId $ExpectedWindowId -ExpectedTerminalId $ExpectedTerminalId -ExpectedSetId $ExpectedSetId `
            -ProcessByPid $procByPid

        if ($processAttributed -and $windowAttributed) {
            $identityConsistent = ($skipped -and $terminalClass.Ok)
            if (-not $identityConsistent) {
                if (-not $skipped) { $identityReason = 'item-not-reported-skipped-by-lifecycle-trace' }
                elseif ($terminalClass.CompetingManagedUiCount -gt 0) { $identityReason = ('competing-managed-ui:' + $terminalClass.CompetingManagedUiCount) }
                elseif ($terminalClass.UnclassifiedCount -gt 0) { $identityReason = ('unclassified-attributed-window:' + $terminalClass.UnclassifiedCount) }
                elseif ($terminalClass.ManagedTerminalCount -ne 1) { $identityReason = ('managed-terminal-count:' + $terminalClass.ManagedTerminalCount) }
                else { $identityReason = 'identity-inconsistent' }
            }
        }
        elseif ($processAttributed -and -not $windowAttributed -and -not $skipped) {
            $identityReason = 'item-not-reported-skipped-by-lifecycle-trace'
        }
        elseif ($processAttributed -and -not $windowAttributed -and -not $windowAttribution) {
            $identityReason = 'window-attribution-not-evaluated'
        }
    }
    else {
        if ($processAttributed -and $windowAttributed) {
            $identityConsistent = ($skipped -and $newWindowCount -eq 1)
            if (-not $identityConsistent) {
                if (-not $skipped) { $identityReason = 'item-not-reported-skipped-by-lifecycle-trace' }
                elseif ($newWindowCount -ne 1) { $identityReason = ('attributed-window-count-not-one:' + [int]$newWindowCount) }
                else { $identityReason = 'identity-inconsistent' }
            }
        }
        elseif ($processAttributed -and -not $windowAttributed -and -not $skipped) {
            # Neither the skip nor the window is present: say so explicitly rather
            # than letting the attribution failure obscure a missing placement skip.
            $identityReason = 'item-not-reported-skipped-by-lifecycle-trace'
        }
        elseif ($processAttributed -and -not $windowAttributed -and -not $windowAttribution) {
            $identityReason = 'window-attribution-not-evaluated'
        }
    }

    if (-not $trialIdPresent) { $reasonsB.Add('trial-id-missing') }
    elseif (-not $exitTrialPresent) { $reasonsB.Add('exit-record-trial-id-missing') }
    elseif (-not $exitTrialMatches) { $reasonsB.Add('exit-record-trial-mismatch:' + [string]$exitTrial) }
    if (-not $binding.Ok) { $reasonsB.Add('artifact-binding:' + $binding.Reason) }
    if (-not $brokerOk) { $reasonsB.Add('trace-plan-id-unavailable') }
    if (-not $launcherOk) { $reasonsB.Add('launcher-identity-unavailable') }
    if (-not $exit.Valid) { $reasonsB.Add('exit-record-invalid:' + $exit.Reason) }
    elseif (-not $exitCaptured) { $reasonsB.Add('exit-not-captured:' + [string]$exit.Data.outcome) }
    elseif (-not $exitZero) { $reasonsB.Add('exit-code-nonzero:' + [string]$exit.Data.exitCode) }
    if ($exitCaptured -and -not $processAttributed) { $reasonsB.Add('no-causally-attributed-process:' + $attribution.Reason) }
    if ($exitCaptured -and -not $windowAttributed) { $reasonsB.Add('no-causally-attributed-window') }
    if ($exitCaptured -and $processAttributed -and $windowAttributed -and -not $identityConsistent) {
        $reasonsB.Add('window-identity-inconsistent-with-plan:' + [string]$identityReason)
    }
    elseif ($exitCaptured -and $identityReason -eq 'item-not-reported-skipped-by-lifecycle-trace') {
        $reasonsB.Add('identity-consistency-blocked:' + [string]$identityReason)
    }

    $n2b = 'INCONCLUSIVE'
    if (-not $exit.Valid) { $n2b = 'INCONCLUSIVE' }
    elseif ($exitCaptured -and -not $exitZero) { $n2b = 'FAIL' }
    elseif ($trace.Ok -and $exitCaptured -and $exitZero -and $brokerOk -and $launcherOk -and
            $finalOk -and $zeroFailures -and $processAttributed -and $windowAttributed -and
            $identityConsistent -and $trialIdPresent -and $exitTrialMatches -and
            $binding.Ok) {
        $n2b = 'PASS'
    }
    else { $n2b = 'INCONCLUSIVE' }

    return [pscustomobject][ordered]@{
        N2A = [pscustomobject][ordered]@{
            Verdict = $n2a
            FixtureOk = $fixtureOk
            TraceValid = [bool]$trace.Ok
            TraceReason = [string]$trace.Reason
            SkippedInTrace = $skipped
            WarningPresent = $warningPresent
            PreStateObserved = $preObserved
            PostStateObserved = $postObserved
            PreWindowCount = if ($preObserved) { $preList.Count } else { $null }
            PostWindowCount = if ($postObserved) { $postList.Count } else { $null }
            NewAttributedWindows = $newWindowCount
            WindowAttributed = $windowAttributed
            ProcessAttributed = $processAttributed
            FallbackApplied = $fallbackApplied
            # Stage 3B7G3: the contract this verdict was evaluated under, and the
            # classification it produced. Null under the historical contract.
            WindowIdentityContract = [string]$WindowIdentityContract
            ManagedTerminalCount = if ($null -ne $terminalClass) { $terminalClass.ManagedTerminalCount } else { $null }
            AuxiliaryWindowCount = if ($null -ne $terminalClass) { $terminalClass.AuxiliaryCount } else { $null }
            UnclassifiedWindowCount = if ($null -ne $terminalClass) { $terminalClass.UnclassifiedCount } else { $null }
            CompetingManagedUiCount = if ($null -ne $terminalClass) { $terminalClass.CompetingManagedUiCount } else { $null }
            EvidenceGaps = if ($null -ne $terminalClass) { @($terminalClass.EvidenceGaps) } else { @() }
            Reasons = @($reasonsA)
        }
        N2B = [pscustomobject][ordered]@{
            Verdict = $n2b
            TraceValid = [bool]$trace.Ok
            TracePlanId = [string]$trace.PlanId
            TraceSetId = [string]$trace.SetId
            ExitCaptured = $exitCaptured
            ExitCode = if ($exitCaptured) { [int]$exit.Data.exitCode } else { $null }
            ExitOutcome = if ($exit.Valid) { [string]$exit.Data.outcome } else { 'invalid' }
            LauncherIdentityOk = $launcherOk
            ProcessAttributed = $processAttributed
            AttributionReason = [string]$attribution.Reason
            AttributedProcessPids = @($attributedPids)
            WindowAttributed = $windowAttributed
            AttributedWindowCount = $newWindowCount
            IdentityConsistent = $identityConsistent
            IdentityConsistencyReason = $identityReason
            # Stage 3B7G3 versioned identity domain: the full classification so a
            # reviewer can see exactly which window qualified and why any other was
            # accepted as auxiliary or rejected as unclassified.
            WindowIdentityContract = [string]$WindowIdentityContract
            ManagedTerminalCount = if ($null -ne $terminalClass) { $terminalClass.ManagedTerminalCount } else { $null }
            AuxiliaryWindowCount = if ($null -ne $terminalClass) { $terminalClass.AuxiliaryCount } else { $null }
            UnclassifiedWindowCount = if ($null -ne $terminalClass) { $terminalClass.UnclassifiedCount } else { $null }
            CompetingManagedUiCount = if ($null -ne $terminalClass) { $terminalClass.CompetingManagedUiCount } else { $null }
            CompetingManagedUiWindows = if ($null -ne $terminalClass) { @($terminalClass.CompetingManagedUi) } else { @() }
            EvidenceGaps = if ($null -ne $terminalClass) { @($terminalClass.EvidenceGaps) } else { @() }
            AuxiliaryContract = if ($null -ne $terminalClass) { $terminalClass.AuxiliaryContract } else { $null }
            IdentityProxy = if ($null -ne $terminalClass) { $terminalClass.IdentityProxy } else { $null }
            QualifyingTerminalHwnd = if ($null -ne $terminalClass) { $terminalClass.QualifyingHwnd } else { $null }
            QualifyingTerminalPid = if ($null -ne $terminalClass) { $terminalClass.QualifyingPid } else { $null }
            AuxiliaryWindows = if ($null -ne $terminalClass) { @($terminalClass.Auxiliary) } else { @() }
            UnclassifiedWindows = if ($null -ne $terminalClass) { @($terminalClass.Unclassified) } else { @() }
            RawAttributedHwndCount = if ($null -ne $terminalClass) { $terminalClass.RawAttributedHwndCount } else { $newWindowCount }
            TrialIdRequested = $TrialId
            TrialIdFromExitRecord = $exitTrial
            TrialIdentityMatches = $exitTrialMatches
            ArtifactBindingOk = if ($null -ne $binding) { [bool]$binding.Ok } else { $null }
            ArtifactBindingReason = if ($null -ne $binding) { [string]$binding.Reason } else { 'not-supplied' }
            ArtifactBindingRoles = if ($null -ne $binding) { @($binding.Roles) } else { @() }
            BrokerReady = $brokerOk
            TerminalFinal = $finalOk
            ZeroFailures = $zeroFailures
            Reasons = @($reasonsB)
        }
    }
}

function Get-P9HStageStatusSummary {
    param([Parameter(Mandatory)][string]$StagesPath)

    $result = [ordered]@{}
    if (-not (Test-Path -LiteralPath $StagesPath -PathType Leaf)) { return $result }

    foreach ($line in (Get-Content -LiteralPath $StagesPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $r = $line | ConvertFrom-Json } catch { continue }
        $result[[string]$r.stage] = [string]$r.outcome
    }

    return $result
}
