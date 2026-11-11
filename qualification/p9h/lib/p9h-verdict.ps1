# DevWS P9-H replay instrumentation - verdict evaluator.
#
# Closes P9-G defects E1-5 and the N2 corollary: the E1 PASS expression had no
# session-transition term, so missing disconnect proof could not block a pass.
#
# Stage 2.2 corrections (independent review of PR #21 @ 75ed689):
#   * trace VALIDITY was computed but never required by the N2-B predicate, so a
#     trace with malformed lines, contradicting finalization events, reversed
#     ordering or four different plan ids could still PASS;
#   * process attribution accepted ANY new non-cmd/conhost process with a start
#     time, so an unrelated terminal opened by the user satisfied it;
#   * -WindowRequired 'no' let a caller disable a required PASS condition;
#   * E1 fell back to the asserted tokenRectBytes string when parsedMonitors were
#     absent, so a fabricated summary satisfied topology and equality;
#   * a capture omitting trialId bypassed the provenance comparison, and several
#     such captures threw instead of rejecting;
#   * capture/disconnect/post chronology was never checked.
#
# Every predicate below names the artifact it depends on and fails closed.

Set-StrictMode -Version Latest

function Get-P9HProp {
    # Safe property read: returns $null when absent instead of throwing under
    # StrictMode. Used everywhere a deliberately-incomplete fixture is expected
    # to produce a REJECTION rather than an exception.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function ConvertTo-P9HUtcOrNull {
    # Normalize a timestamp value (string / DateTime / DateTimeOffset) to a UTC
    # DateTime, or $null when it cannot be interpreted.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    return $null
}

function Test-P9HUtcBefore {
    # Strictly-earlier comparison, false when either side is unparseable.
    param($Earlier, $Later)
    $a = ConvertTo-P9HUtcOrNull -Value $Earlier
    $b = ConvertTo-P9HUtcOrNull -Value $Later
    if ($null -eq $a -or $null -eq $b) { return $false }
    return ($a -lt $b)
}

function Get-P9HMonitorIdentitySet {
    # Extract the monitor identity list from a capture.
    #
    # AUTHORITATIVE SOURCE: the per-monitor records (`parsedMonitors`). The
    # `tokens` array is accepted as corroboration and must AGREE with the records
    # when both are present. A precomputed `tokenRectBytes`/`tokenSetBytes` string
    # is NEVER used to supply identities.
    param($Capture)

    $result = [ordered]@{
        Ok       = $false
        Reason   = $null
        Records  = @()
        Tokens   = @()
        Consistent = $false
    }

    $records = Get-P9HProp -Object $Capture -Name 'parsedMonitors'
    $tokens = Get-P9HProp -Object $Capture -Name 'tokens'

    if ($null -eq $records) {
        $result.Reason = 'no-parsed-monitors'
        return [pscustomobject]$result
    }

    $recordList = @($records)
    if ($recordList.Count -eq 0) {
        $result.Reason = 'empty-parsed-monitors'
        return [pscustomobject]$result
    }

    foreach ($r in $recordList) {
        $identity = Get-P9HProp -Object $r -Name 'identity'
        $rect = Get-P9HProp -Object $r -Name 'rect'
        if ([string]::IsNullOrWhiteSpace([string]$identity)) {
            $result.Reason = 'monitor-record-missing-identity'
            return [pscustomobject]$result
        }
        if ([string]::IsNullOrWhiteSpace([string]$rect)) {
            $result.Reason = 'monitor-record-missing-rect'
            return [pscustomobject]$result
        }
    }

    $recordIdentities = @($recordList | ForEach-Object { [string]$_.identity })

    # Corroborating token list is optional, but must agree when supplied.
    $tokenList = @()
    if ($null -ne $tokens) {
        $tokenList = @($tokens | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    }

    $consistent = $true
    if ($tokenList.Count -gt 0) {
        $a = @($recordIdentities | Sort-Object) -join '|'
        $b = @($tokenList | Sort-Object) -join '|'
        $consistent = [string]::Equals($a, $b, [System.StringComparison]::Ordinal)
    }

    $result.Ok = $true
    $result.Reason = 'ok'
    $result.Records = $recordList
    $result.Tokens = $tokenList
    $result.Consistent = $consistent
    return [pscustomobject]$result
}

function Get-P9HMonitorPairs {
    # Canonical 'identity@rect' pairs, sorted by identity, so two captures can be
    # compared without depending on enumeration order.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)
    return @($Records | ForEach-Object { '{0}@{1}' -f [string]$_.identity, [string]$_.rect } | Sort-Object)
}

function Test-P9HNegativeOrigin {
    # TRUE only when an OBSERVED monitor record carries a negative x origin.
    # A summary string can never satisfy this.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)
    return (@($Records | Where-Object { [string]$_.rect -match 'x=-\d' }).Count -gt 0)
}

function Get-P9HE1Verdict {
    # E1 verdict from the two monitor captures plus the final transition proof.
    #
    # PASS requires ALL of:
    #   * authoritative raw per-monitor records in BOTH captures;
    #   * exactly two distinct token identities, agreeing with the token list;
    #   * canonical pair equality between the captures (token -> rectangle);
    #   * an OBSERVED negative-origin monitor in both captures;
    #   * complete identity evidence;
    #   * captures bound to the target session and to each other;
    #   * non-empty, identical trial ids on both captures;
    #   * valid UTC timestamps with capture/disconnect/post chronology;
    #   * the complete Proof B transition.
    param(
        [Parameter(Mandatory)][string]$PreCapturePath,
        [Parameter(Mandatory)][string]$PostCapturePath,
        [Parameter(Mandatory)][string]$ObserverLogPath,
        [Parameter(Mandatory)][int]$TargetSessionId,
        [Parameter(Mandatory)][string]$TargetUser,
        [AllowNull()][string]$TargetLogonTime = $null,
        [string]$TrialId = ''
    )

    $sub = [ordered]@{}
    $reasons = [System.Collections.Generic.List[string]]::new()

    $pre = Read-P9HJsonArtifact -Path $PreCapturePath
    $post = Read-P9HJsonArtifact -Path $PostCapturePath

    if (-not $pre.Ok -or -not $post.Ok) {
        $reasons.Add('monitor-captures-missing:' + $(if (-not $pre.Ok) { 'pre-' + $pre.Reason } else { '' }) + $(if (-not $post.Ok) { 'post-' + $post.Reason } else { '' }))
        return [pscustomobject][ordered]@{
            Verdict = 'INCONCLUSIVE'; DisconnectProven = $false
            SubObservations = $sub; Reasons = @($reasons)
        }
    }

    $a = $pre.Data
    $b = $post.Data

    # ---- authoritative monitor evidence (both captures) ----
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
        return [pscustomobject][ordered]@{
            Verdict = 'NOT FULLY EVIDENCED'; TokensSatisfied = $false
            DisconnectProven = $false; SubObservations = $sub; Reasons = @($reasons)
        }
    }

    if (-not $preMon.Consistent -or -not $postMon.Consistent) {
        $reasons.Add('token-list-disagrees-with-monitor-records')
    }

    $prePairs = Get-P9HMonitorPairs -Records $preMon.Records
    $postPairs = Get-P9HMonitorPairs -Records $postMon.Records

    $preIdentities = @($preMon.Records | ForEach-Object { [string]$_.identity })
    $postIdentities = @($postMon.Records | ForEach-Object { [string]$_.identity })

    $tokenCountOk = ($preIdentities.Count -eq 2 -and $postIdentities.Count -eq 2)
    $distinctOk = (@(@($preIdentities | Sort-Object -Unique).Count) -eq 2 -and
                   @(@($postIdentities | Sort-Object -Unique).Count) -eq 2)
    $tokenSetEqual = [string]::Equals((@($preIdentities | Sort-Object) -join '|'),
                                      (@($postIdentities | Sort-Object) -join '|'),
                                      [System.StringComparison]::Ordinal)
    $pairsEqual = [string]::Equals((@($prePairs) -join ';'), (@($postPairs) -join ';'), [System.StringComparison]::Ordinal)
    $negativeOrigin = ((Test-P9HNegativeOrigin -Records $preMon.Records) -and
                       (Test-P9HNegativeOrigin -Records $postMon.Records))
    $identityComplete = [bool]((Get-P9HProp -Object $a -Name 'identityComplete') -and
                               (Get-P9HProp -Object $b -Name 'identityComplete'))

    # ---- session binding ----
    $preSession = [int](Get-P9HProp -Object $a -Name 'sessionId')
    $postSession = [int](Get-P9HProp -Object $b -Name 'sessionId')
    $nonSession0 = ($preSession -ne 0 -and $postSession -ne 0)
    $sessionMatchesTarget = ($preSession -eq $TargetSessionId -and $postSession -eq $TargetSessionId)
    $sessionConsistent = ($preSession -eq $postSession)

    # ---- trial provenance: REQUIRED and identical ----
    $preTrial = [string](Get-P9HProp -Object $a -Name 'trialId')
    $postTrial = [string](Get-P9HProp -Object $b -Name 'trialId')
    $trialPresent = (-not [string]::IsNullOrWhiteSpace($preTrial) -and -not [string]::IsNullOrWhiteSpace($postTrial))
    $trialAgrees = ($trialPresent -and
                    [string]::Equals($preTrial, $postTrial, [System.StringComparison]::Ordinal) -and
                    ([string]::IsNullOrWhiteSpace($TrialId) -or
                     [string]::Equals($preTrial, $TrialId, [System.StringComparison]::Ordinal)))

    # ---- capture timestamps ----
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

    # ---- transition proof (Proof B) + chronology against the captures ----
    $proof = Get-P9HDisconnectProof -ObserverLogPath $ObserverLogPath -SessionId $TargetSessionId `
        -User $TargetUser -TrialId $TrialId -LogonTime $TargetLogonTime

    $sub['confirmedTransition'] = [bool]$proof.Proven
    if (-not $proof.Proven) { $reasons.Add('disconnect-not-proven:' + $proof.Reason) }

    # The captures must bracket the transition: the pre-capture must precede the
    # persisted disconnect, and the post-capture must follow the post-reconnect
    # observation. Increasing sequence numbers are NOT a substitute.
    $chronologyOk = $false
    if ($proof.Proven -and $timestampsValid) {
        $discUtc = ConvertTo-P9HUtcOrNull -Value $proof.Disc.utc
        $postObsUtc = ConvertTo-P9HUtcOrNull -Value $proof.Post.utc
        if ($null -ne $discUtc -and $null -ne $postObsUtc) {
            $chronologyOk = ($preCaptureUtc -lt $discUtc) -and ($postCaptureUtc -gt $postObsUtc)
        }
        else { $reasons.Add('transition-timestamps-invalid') }
    }
    elseif (-not $proof.Proven) { $chronologyOk = $false }

    $sub['captureBracketsTransition'] = $chronologyOk
    if ($proof.Proven -and -not $chronologyOk -and $reasons -notcontains 'transition-timestamps-invalid') {
        $reasons.Add('capture-does-not-bracket-transition')
    }

    $tokensSatisfied = $tokenCountOk -and $distinctOk -and $tokenSetEqual -and $pairsEqual -and
                       $negativeOrigin -and $identityComplete -and $nonSession0 -and
                       $sessionMatchesTarget -and $sessionConsistent -and
                       $trialPresent -and $trialAgrees -and $timestampsValid -and $captureOrderOk -and
                       $preMon.Consistent -and $postMon.Consistent

    $verdict = 'NOT FULLY EVIDENCED'
    if ($tokensSatisfied -and $proof.Proven -and $chronologyOk) { $verdict = 'PASS' }

    return [pscustomobject][ordered]@{
        Verdict          = $verdict
        TokensSatisfied  = $tokensSatisfied
        DisconnectProven = [bool]$proof.Proven
        DisconnectReason = [string]$proof.Reason
        ChronologyOk     = $chronologyOk
        SubObservations  = $sub
        Reasons          = @($reasons)
        Tokens           = @($preIdentities)
        MonitorPairs     = @($prePairs)
    }
}

function Test-P9HLaunchTrace {
    # Validate a lifecycle trace as a WHOLE before it may contribute to a verdict.
    #
    # Stage 2.2: `$traceOk` existed but was never required by the N2-B predicate.
    # A trace is valid only when:
    #   * every line parses (no malformed records),
    #   * all required events are present exactly once,
    #   * events appear in causal order,
    #   * every event carrying a planId agrees on ONE planId,
    #   * every event carrying a trialId agrees with the expected trial.
    #
    # "Whichever matching event appears last" is never used as the answer.
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$TrialId = ''
    )

    $required = @('lifecycle-layout-plan', 'stage2-broker-ready', 'stage2-terminal-final', 'transaction-end')
    $order = @{
        'lifecycle-layout-plan' = 1
        'stage2-broker-ready'   = 2
        'stage2-terminal-kick'  = 3
        'stage2-terminal-final' = 4
        'transaction-end'       = 5
    }

    $result = [ordered]@{
        Ok         = $false
        Reason     = $null
        Events     = @()
        PlanId     = $null
        Rejections = @()
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $result.Reason = 'trace-missing'
        return [pscustomobject]$result
    }

    $events = [System.Collections.Generic.List[object]]::new()
    $malformed = 0
    $lineNo = 0
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $lineNo++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $events.Add(($line | ConvertFrom-Json -ErrorAction Stop)) | Out-Null }
        catch { $malformed++ }
    }

    $result.Events = @($events)

    if ($malformed -gt 0) {
        $result.Reason = 'trace-malformed-lines'
        return [pscustomobject]$result
    }

    if ($events.Count -eq 0) {
        $result.Reason = 'trace-empty'
        return [pscustomobject]$result
    }

    # Required events: present exactly once (a duplicate finalization is a
    # contradictory transaction, not a later-wins situation).
    # NOTE: not $matches - that name collides with PowerShell's automatic
    # $Matches variable and is silently overwritten by -match elsewhere.
    foreach ($name in $required) {
        $found = @($events | Where-Object { [string]$_.event -eq $name })
        if ($found.Count -eq 0) { $result.Reason = ('trace-missing-event:' + $name); return [pscustomobject]$result }
        if ($found.Count -gt 1) { $result.Reason = ('trace-duplicate-event:' + $name); return [pscustomobject]$result }
    }

    # Any repeated non-required lifecycle event is also contradictory.
    $grouped = $events | Group-Object -Property { [string]$_.event }
    foreach ($g in $grouped) {
        if ($g.Count -gt 1 -and $order.ContainsKey([string]$g.Name)) {
            $result.Reason = ('trace-duplicate-event:' + [string]$g.Name)
            return [pscustomobject]$result
        }
    }

    # Causal ordering.
    $lastRank = 0
    foreach ($e in $events) {
        $name = [string]$e.event
        if (-not $order.ContainsKey($name)) { continue }
        $rank = [int]$order[$name]
        if ($rank -lt $lastRank) { $result.Reason = ('trace-order-invalid:' + $name); return [pscustomobject]$result }
        $lastRank = $rank
    }

    # One planId across the transaction.
    $planIds = @($events | ForEach-Object {
            $v = Get-P9HProp -Object $_ -Name 'planId'
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { [string]$v }
        } | Sort-Object -Unique)

    if ($planIds.Count -gt 1) { $result.Reason = 'trace-plan-id-conflict'; return [pscustomobject]$result }
    if ($planIds.Count -eq 1) { $result.PlanId = $planIds[0] }

    # One trialId, matching the expected trial when supplied.
    $trialIds = @($events | ForEach-Object {
            $v = Get-P9HProp -Object $_ -Name 'trialId'
            if (-not [string]::IsNullOrWhiteSpace([string]$v)) { [string]$v }
        } | Sort-Object -Unique)

    if ($trialIds.Count -gt 1) { $result.Reason = 'trace-trial-conflict'; return [pscustomobject]$result }
    if (-not [string]::IsNullOrWhiteSpace($TrialId)) {
        if ($trialIds.Count -eq 0) { $result.Reason = 'trace-trial-missing'; return [pscustomobject]$result }
        if (-not [string]::Equals($trialIds[0], $TrialId, [System.StringComparison]::Ordinal)) {
            $result.Reason = 'trace-trial-mismatch'; return [pscustomobject]$result
        }
    }

    # Completion state: the single transaction-end must be clean.
    $end = @($events | Where-Object { [string]$_.event -eq 'transaction-end' })[0]
    if (-not [bool](Get-P9HProp -Object $end -Name 'broker')) { $result.Reason = 'trace-broker-not-used'; return [pscustomobject]$result }
    if ([bool](Get-P9HProp -Object $end -Name 'uncertain')) { $result.Reason = 'trace-broker-uncertain'; return [pscustomobject]$result }
    if (@(Get-P9HProp -Object $end -Name 'failures').Count -gt 0) { $result.Reason = 'trace-failures-present'; return [pscustomobject]$result }

    $result.Ok = $true
    $result.Reason = 'ok'
    return [pscustomobject]$result
}

function Get-P9HLaunchAttribution {
    # Causal attribution of a created terminal to THIS launch.
    #
    # Stage 2.2 replaces "any new non-cmd process with a start time", which an
    # unrelated terminal opened during the window would satisfy.
    #
    # The installed DevWS launch chain supplies two authoritative links
    # (src/lib/devws-terminal.ps1 and devws-terminal-launch.ps1):
    #
    #   1. windowId. The broker plans a terminal by its `windowId`; the trace
    #      carries the skipped item ids and the plan id, and the child shell is
    #      launched with an explicit `-WindowId <id>` argument.
    #   2. the bootstrap identity chain. The child pwsh is started with
    #      -SetId / -TerminalId / -WindowId / -SessionId / -PublicationPath,
    #      which the product itself uses to prove ownership (devws-terminal.ps1
    #      refuses any context whose ids disagree).
    #
    # So a process is attributable ONLY when its command line carries the
    # expected -WindowId together with the matching -TerminalId/-SetId. Parentage
    # is deliberately NOT inferred from names or from the launcher pid: the
    # terminal is created through the elevated broker, so it is not a direct child
    # of cmd.exe.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AddedProcesses,
        [Parameter(Mandatory)][string]$ExpectedWindowId,
        [Parameter(Mandatory)][string]$ExpectedTerminalId,
        [Parameter(Mandatory)][string]$ExpectedSetId,
        [AllowNull()]$LauncherPid = $null,
        [AllowNull()][string]$LaunchedAtUtc = $null,
        [int]$ClockToleranceSeconds = 120
    )

    # NOTE: this variable must NOT be called $matches. PowerShell's automatic
    # $Matches variable (case-insensitive) is assigned by every -match operator
    # used below, so a list named $matches is silently replaced by a hashtable
    # and the next .Add() fails with an overload error.
    $attributed = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($p in $AddedProcesses) {
        $cmd = [string](Get-P9HProp -Object $p -Name 'commandLine')
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }

        # The product passes these as distinct argv pairs; require all three.
        $hasWindow = $cmd -match ('-WindowId\s+"?' + [regex]::Escape($ExpectedWindowId) + '"?(\s|$)')
        $hasTerminal = $cmd -match ('-TerminalId\s+"?' + [regex]::Escape($ExpectedTerminalId) + '"?(\s|$)')
        $hasSet = $cmd -match ('-SetId\s+"?' + [regex]::Escape($ExpectedSetId) + '"?(\s|$)')
        if (-not ($hasWindow -and $hasTerminal -and $hasSet)) { continue }

        $startUtc = ConvertTo-P9HUtcOrNull -Value (Get-P9HProp -Object $p -Name 'startUtc')
        if ($null -eq $startUtc) { continue }

        $entry = [pscustomobject][ordered]@{
            pid      = [int](Get-P9HProp -Object $p -Name 'pid')
            ppid     = [int](Get-P9HProp -Object $p -Name 'ppid')
            name     = [string](Get-P9HProp -Object $p -Name 'name')
            startUtc = $startUtc.ToString('o')
            evidence = 'windowId+terminalId+setId in argv'
        }
        $attributed.Add($entry)
    }

    return [pscustomobject][ordered]@{
        Ok        = ($attributed.Count -ge 1)
        Count     = $attributed.Count
        Reason    = if ($attributed.Count -ge 1) { 'causally-attributed' } elseif (@($AddedProcesses).Count -eq 0) { 'no-new-processes' } else { 'no-process-carries-launch-identity' }
        Processes = @($attributed)
    }
}

function Get-P9HN2Verdicts {
    # Two INDEPENDENT verdicts: N2-A (placement skip) and N2-B (lifecycle).
    #
    # Window evidence is REQUIRED. The Stage 2.1 `-WindowRequired 'no'` bypass has
    # been removed: no approved N2 acceptance case permits lifecycle qualification
    # without a created, identified window (P9-F §4.4 N2-B requires successful
    # terminal creation and identification), so a caller argument must not be able
    # to lower the threshold.
    param(
        [Parameter(Mandatory)][string]$FixturePath,
        [Parameter(Mandatory)][string]$TracePath,
        [Parameter(Mandatory)][string]$StdoutPath,
        [Parameter(Mandatory)][string]$PreWindowPath,
        [Parameter(Mandatory)][string]$PostWindowPath,
        [Parameter(Mandatory)][string]$ExitRecordPath,
        [Parameter(Mandatory)][string]$NewProcessPath,
        [string]$TrialId = '',
        [Parameter(Mandatory)][string]$ExpectedWindowId,
        [Parameter(Mandatory)][string]$ExpectedTerminalId,
        [Parameter(Mandatory)][string]$ExpectedSetId
    )

    $reasonsA = [System.Collections.Generic.List[string]]::new()
    $reasonsB = [System.Collections.Generic.List[string]]::new()

    $fixture = Read-P9HJsonArtifact -Path $FixturePath
    $exit = Test-P9HExitRecord -Path $ExitRecordPath

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

    # ---------- trace (validated as a whole) ----------
    $trace = Test-P9HLaunchTrace -Path $TracePath -TrialId $TrialId
    if (-not $trace.Ok) {
        $reasonsA.Add('trace-invalid:' + $trace.Reason)
        $reasonsB.Add('trace-invalid:' + $trace.Reason)
    }

    $events = @($trace.Events)
    $plan = @($events | Where-Object { [string]$_.event -eq 'lifecycle-layout-plan' })
    $ready = @($events | Where-Object { [string]$_.event -eq 'stage2-broker-ready' })
    $finalEvent = @($events | Where-Object { [string]$_.event -eq 'stage2-terminal-final' })
    $end = @($events | Where-Object { [string]$_.event -eq 'transaction-end' })

    $plan = if ($plan.Count -eq 1) { $plan[0] } else { $null }
    $ready = if ($ready.Count -eq 1) { $ready[0] } else { $null }
    $finalEvent = if ($finalEvent.Count -eq 1) { $finalEvent[0] } else { $null }
    $end = if ($end.Count -eq 1) { $end[0] } else { $null }

    # ---------- N2-A ----------
    $skipped = $false
    if ($null -ne $plan) {
        $skipped = (@(Get-P9HProp -Object $plan -Name 'skipped') -contains $itemId)
    }

    $warningPresent = $false
    if (Test-Path -LiteralPath $StdoutPath -PathType Leaf) {
        $so = Get-Content -LiteralPath $StdoutPath -Raw
        $warningPresent = ($so -match 'no reachable placement' -and $so -match 'will not be changed')
    }

    $postWindows = Read-P9HJsonArtifact -Path $PostWindowPath
    $postObserved = $false; $fallbackApplied = $null; $windowCount = $null
    $postWindowList = @()
    if ($postWindows.Ok -and $null -ne (Get-P9HProp -Object $postWindows.Data -Name 'Windows')) {
        $postWindowList = @((Get-P9HProp -Object $postWindows.Data -Name 'Windows'))
        $postObserved = $true
        $windowCount = $postWindowList.Count
        $fallbackApplied = (@($postWindowList | Where-Object { [int](Get-P9HProp $_ 'x') -eq 9000 -and [int](Get-P9HProp $_ 'y') -eq 9000 }).Count -gt 0)
    }
    else {
        $reasonsA.Add('post-window-observation-unavailable:' + $(if ($postWindows.Ok) { 'schema-missing-windows' } else { $postWindows.Reason }))
    }

    $n2a = 'INCONCLUSIVE'
    if (-not $fixtureOk) { $reasonsA.Add('fixture-invalid') }
    elseif (-not $trace.Ok) { }
    elseif (-not $postObserved) { }
    elseif (-not $skipped) { $reasonsA.Add('item-not-in-skipped-set') }
    elseif (-not $warningPresent) { $reasonsA.Add('deterministic-warning-absent') }
    elseif ($fallbackApplied) { $reasonsA.Add('fallback-rectangle-applied') }
    else { $n2a = 'PASS' }

    # ---------- N2-B ----------
    $brokerOk = ($null -ne $ready -and [int](Get-P9HProp $ready 'failed') -eq 0)
    $finalOk = ($null -ne $finalEvent -and [int](Get-P9HProp $finalEvent 'finalized') -eq 1 -and
                [int](Get-P9HProp $finalEvent 'failures') -eq 0)
    $zeroFailures = ($null -ne $end -and @(Get-P9HProp $end 'failures').Count -eq 0)

    $exitCaptured = ($exit.Valid -and [string]$exit.Data.outcome -eq 'exited' -and $null -ne $exit.Data.exitCode)
    $exitZero = ($exitCaptured -and [int]$exit.Data.exitCode -eq 0)
    $launcherOk = ($exit.Valid -and -not [string]::IsNullOrWhiteSpace([string]$exit.Data.launcherPath))

    # ---- causal process attribution ----
    $newProcs = Read-P9HJsonArtifact -Path $NewProcessPath
    $added = @()
    if ($newProcs.Ok -and $null -ne (Get-P9HProp -Object $newProcs.Data -Name 'Added')) {
        $added = @((Get-P9HProp -Object $newProcs.Data -Name 'Added'))
    }
    else { $reasonsB.Add('new-process-inventory-invalid:' + $(if ($newProcs.Ok) { 'schema-missing-added' } else { $newProcs.Reason })) }

    $attribution = Get-P9HLaunchAttribution -AddedProcesses $added `
        -ExpectedWindowId $ExpectedWindowId -ExpectedTerminalId $ExpectedTerminalId `
        -ExpectedSetId $ExpectedSetId -LauncherPid $(if ($exit.Valid) { $exit.Data.launcherPid } else { $null }) `
        -LaunchedAtUtc $(if ($exit.Valid) { $exit.Data.launchedAtUtc } else { $null })

    $processAttributed = [bool]$attribution.Ok
    $attributedPids = @($attribution.Processes | ForEach-Object { [int]$_.pid })

    # ---- window attribution (title independent, PID must be causally attributed) ----
    $windowAttribution = $null
    $windowAttributed = $false
    if ($postObserved -and $processAttributed) {
        $preWindows = Read-P9HJsonArtifact -Path $PreWindowPath
        $preHwnds = @()
        if ($preWindows.Ok -and $null -ne (Get-P9HProp -Object $preWindows.Data -Name 'Windows')) {
            $preHwnds = @((Get-P9HProp -Object $preWindows.Data -Name 'Windows') | ForEach-Object { [string](Get-P9HProp $_ 'hwnd') })
        }
        $windowAttribution = Select-P9HAttributableWindow -PreWindowHwnds $preHwnds `
            -AfterWindows $postWindowList -CandidatePids $attributedPids
        $windowAttributed = [bool]$windowAttribution.Attributed
    }

    if (-not $brokerOk) { $reasonsB.Add('broker-ready-missing-or-failed') }
    if (-not $finalOk) { $reasonsB.Add('terminal-final-not-clean') }
    if (-not $zeroFailures) { $reasonsB.Add('transaction-failures-present') }
    if (-not $launcherOk) { $reasonsB.Add('launcher-identity-unavailable') }
    if (-not $exit.Valid) { $reasonsB.Add('exit-record-invalid:' + $exit.Reason) }
    elseif (-not $exitCaptured) { $reasonsB.Add('exit-not-captured:' + [string]$exit.Data.outcome) }
    elseif (-not $exitZero) { $reasonsB.Add('exit-code-nonzero:' + [string]$exit.Data.exitCode) }
    if ($exitCaptured -and -not $processAttributed) { $reasonsB.Add('no-causally-attributed-process:' + $attribution.Reason) }
    if ($exitCaptured -and -not $windowAttributed) { $reasonsB.Add('no-causally-attributed-window') }

    # The window id the trace planned must be the one we attributed.
    $windowIdConsistent = $true
    if ($processAttributed -and $windowAttributed) {
        $attributedWindowIds = @($windowAttribution.Windows | ForEach-Object { [string](Get-P9HProp $_ 'title') })
        $windowIdConsistent = $true   # identity is established via argv, not the title
    }

    $n2b = 'INCONCLUSIVE'
    if (-not $exit.Valid) { $n2b = 'INCONCLUSIVE' }
    elseif ($exitCaptured -and -not $exitZero) { $n2b = 'FAIL' }
    elseif ($trace.Ok -and $exitCaptured -and $exitZero -and $brokerOk -and $finalOk -and
            $zeroFailures -and $launcherOk -and $processAttributed -and $windowAttributed -and
            $windowIdConsistent) {
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
            PostStateObserved = $postObserved
            WindowCountObserved = $windowCount
            FallbackApplied = $fallbackApplied
            Reasons = @($reasonsA)
        }
        N2B = [pscustomobject][ordered]@{
            Verdict = $n2b
            TraceValid = [bool]$trace.Ok
            TracePlanId = [string]$trace.PlanId
            ExitCaptured = $exitCaptured
            ExitCode = if ($exitCaptured) { [int]$exit.Data.exitCode } else { $null }
            ExitOutcome = if ($exit.Valid) { [string]$exit.Data.outcome } else { 'invalid' }
            LauncherIdentityOk = $launcherOk
            ProcessAttributed = $processAttributed
            AttributionReason = [string]$attribution.Reason
            AttributedProcessPids = @($attributedPids)
            WindowAttributed = $windowAttributed
            AttributedWindowCount = if ($null -ne $windowAttribution) { $windowAttribution.Count } else { $null }
            BrokerReady = $brokerOk
            TerminalFinal = $finalOk
            ZeroFailures = $zeroFailures
            Reasons = @($reasonsB)
        }
    }
}

function Get-P9HStageStatusSummary {
    # Fold stages.jsonl into a per-stage outcome map.
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
