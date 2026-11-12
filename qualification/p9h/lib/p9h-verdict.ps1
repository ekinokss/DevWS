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

function Get-P9HE1Verdict {
    # E1 verdict from the two monitor captures plus the final transition proof.
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

    $tokensSatisfied = $tokenCountOk -and $distinctOk -and $tokenSetEqual -and $pairsEqual -and
                       $negativeOrigin -and $identityComplete -and $nonSession0 -and
                       $sessionMatchesTarget -and $sessionConsistent -and
                       $trialPresent -and $trialAgrees -and $timestampsValid -and $captureOrderOk -and
                       $preMon.Consistent -and $postMon.Consistent

    $verdict = 'NOT FULLY EVIDENCED'
    if ($tokensSatisfied -and $proof.Proven -and $chronologyOk) { $verdict = 'PASS' }

    return [pscustomobject][ordered]@{
        Verdict = $verdict
        TokensSatisfied = $tokensSatisfied
        DisconnectProven = [bool]$proof.Proven
        DisconnectReason = [string]$proof.Reason
        ChronologyOk = $chronologyOk
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
        [string]$ArtifactIndexPath = ''
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
    $identityConsistent = $false
    if ($processAttributed -and $windowAttributed) {
        $identityConsistent = ($skipped -and $newWindowCount -eq 1)
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
        $reasonsB.Add('window-identity-inconsistent-with-plan')
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
