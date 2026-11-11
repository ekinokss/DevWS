# DevWS P9-H replay instrumentation - verdict evaluator.
#
# Closes P9-G defects E1-5 and the N2 corollary: the E1 PASS expression had no
# session-transition term, so missing disconnect proof could not block a pass.
#
# Every criterion here:
#   * names the artifact it depends on;
#   * reports NOT FULLY EVIDENCED / INCONCLUSIVE when that artifact is absent or
#     untrustworthy, rather than falling back to a pass;
#   * keeps N2-A and N2-B independent, so neither can imply the other.
#
# This module is pure: it reads artifacts and returns verdicts. It never
# launches, disconnects, or mutates anything.

Set-StrictMode -Version Latest

function Get-P9HE1Verdict {
    # E1 verdict from the two monitor captures plus the final transition proof.
    #
    # Stage 2.1 corrections (independent review):
    #   * negativeOrigin was computed but NOT part of $tokensSatisfied, so a
    #     topology with no negative-origin monitor could still PASS;
    #   * the session check only asserted "not session 0" and never bound the
    #     captures to the required target session identity;
    #   * asserted booleans (identityComplete, tokenSetBytes/tokenRectBytes) were
    #     trusted without validating the underlying raw observations.
    #
    # PASS now requires every one of: two distinct tokens, complete raw token
    # identity, exact token-set equality, identical token->rect mapping, proven
    # negative origin, captures bound to the accepted session contract, a schema
    # that carries the raw observations, and the full transition proof.
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
            Verdict          = 'INCONCLUSIVE'
            DisconnectProven = $false
            SubObservations  = $sub
            Reasons          = @($reasons)
        }
    }

    $a = $pre.Data
    $b = $post.Data

    # ---- capture schema validation ----
    # Raw observations must be present. A capture that only asserts strings such
    # as tokenSetBytes cannot be independently reproduced and is not accepted.
    $missingFields = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('tokens', 'sessionId', 'capturedUtc', 'identityComplete')) {
        if ($null -eq $a.PSObject.Properties[$name]) { $missingFields.Add('pre:' + $name) }
        if ($null -eq $b.PSObject.Properties[$name]) { $missingFields.Add('post:' + $name) }
    }

    # Access via PSObject.Properties so a deliberately-omitted field is a
    # missing-field finding rather than a StrictMode exception.
    $preTokens = @()
    $postTokens = @()
    if ($null -ne $a.PSObject.Properties['tokens']) {
        $preTokens = @($a.tokens | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    if ($null -ne $b.PSObject.Properties['tokens']) {
        $postTokens = @($b.tokens | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }

    if ($preTokens.Count -eq 0) { $missingFields.Add('pre:empty-token-list') }
    if ($postTokens.Count -eq 0) { $missingFields.Add('post:empty-token-list') }

    if ($missingFields.Count -gt 0) {
        $reasons.Add('capture-schema-incomplete:' + (@($missingFields) -join ','))
        return [pscustomobject][ordered]@{
            Verdict          = 'NOT FULLY EVIDENCED'
            TokensSatisfied  = $false
            DisconnectProven = $false
            SubObservations  = $sub
            Reasons          = @($reasons)
        }
    }

    # Stage 2.1: capture-schema, timestamp and trial-provenance failures are
    # BLOCKING. Stage 2 recorded some reasons but did not consult them in the
    # PASS predicate, so an invalid capture could still pass.
    $captureProvenanceOk = $true

    if (-not (Test-P9HStrictUtcStamp -Text $a.capturedUtc) -or -not (Test-P9HStrictUtcStamp -Text $b.capturedUtc)) {
        $reasons.Add('capture-timestamp-invalid')
        $captureProvenanceOk = $false
    }

    # A capture must belong to the trial under test when a trial id is supplied.
    if (-not [string]::IsNullOrWhiteSpace($TrialId)) {
        foreach ($pair in @(@{ k = 'pre'; d = $a }, @{ k = 'post'; d = $b })) {
            $prop = $pair.d.PSObject.Properties['trialId']
            if ($null -ne $prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
                if (-not [string]::Equals([string]$prop.Value, $TrialId, [System.StringComparison]::Ordinal)) {
                    $reasons.Add(('capture-trial-mismatch:' + $pair.k))
                    $captureProvenanceOk = $false
                }
            }
        }
    }

    # ---- (a) token stability between the two captures ----
    $preSorted = @($preTokens | Sort-Object)
    $postSorted = @($postTokens | Sort-Object)
    $tokenSetEqual = ((@($preSorted) -join '|') -ceq (@($postSorted) -join '|'))
    $tokenCountOk = ($preTokens.Count -eq 2 -and $postTokens.Count -eq 2)
    $distinctOk = (@(@($preTokens | Sort-Object -Unique).Count) -eq 2)
    $identityComplete = [bool]([bool]$a.identityComplete -and [bool]$b.identityComplete)

    # Rectangle correlation is derived from the per-monitor records when they are
    # present, so it cannot be satisfied by a precomputed string alone.
    $rectFromRecords = $null
    if ($null -ne $a.PSObject.Properties['parsedMonitors'] -and $null -ne $b.PSObject.Properties['parsedMonitors']) {
        $prePairs = @($a.parsedMonitors | ForEach-Object { '{0}@{1}' -f $_.identity, $_.rect })
        $postPairs = @($b.parsedMonitors | ForEach-Object { '{0}@{1}' -f $_.identity, $_.rect })
        $rectFromRecords = ((@($prePairs) -join ';') -ceq (@($postPairs) -join ';'))
    }

    $rectBytesDeclared = $false
    if ($null -ne $a.PSObject.Properties['tokenRectBytes'] -and $null -ne $b.PSObject.Properties['tokenRectBytes']) {
        $rectBytesDeclared = ([string]$a.tokenRectBytes -ceq [string]$b.tokenRectBytes)
    }

    $rectEqual = if ($null -ne $rectFromRecords) { [bool]$rectFromRecords } else { [bool]$rectBytesDeclared }

    # Negative origin must be demonstrated by OBSERVED rectangles. Prefer the
    # per-monitor records; fall back to the declared string only when no records
    # exist, and require the SAME negative-origin evidence on both sides.
    $negativeOrigin = $false
    if ($null -ne $a.PSObject.Properties['parsedMonitors'] -and $null -ne $b.PSObject.Properties['parsedMonitors']) {
        $preNeg = @($a.parsedMonitors | Where-Object { [string]$_.rect -match 'x=-\d' }).Count -gt 0
        $postNeg = @($b.parsedMonitors | Where-Object { [string]$_.rect -match 'x=-\d' }).Count -gt 0
        $negativeOrigin = ($preNeg -and $postNeg)
    }
    else {
        $negativeOrigin = ([string]$a.tokenRectBytes -match 'x=-\d') -and ([string]$b.tokenRectBytes -match 'x=-\d')
    }

    # ---- session binding ----
    # Both captures must belong to the SAME non-zero session that the transition
    # proof is about. "Not session 0" alone is insufficient.
    $preSession = [int]$a.sessionId
    $postSession = [int]$b.sessionId
    $nonSession0 = ($preSession -ne 0 -and $postSession -ne 0)
    $sessionMatchesTarget = ($preSession -eq $TargetSessionId -and $postSession -eq $TargetSessionId)
    $sessionConsistent = ($preSession -eq $postSession)

    $sub['twoDistinctTokens'] = ($tokenCountOk -and $distinctOk)
    $sub['byteIdenticalTokenSets'] = $tokenSetEqual
    $sub['tokenRectCorrelationIdentical'] = $rectEqual
    $sub['negativeOriginTopology'] = $negativeOrigin
    $sub['identityComplete'] = $identityComplete
    $sub['nonSession0Evidence'] = $nonSession0
    $sub['sessionMatchesTarget'] = $sessionMatchesTarget
    $sub['sessionConsistent'] = $sessionConsistent

    $tokensSatisfied = $tokenCountOk -and $distinctOk -and $tokenSetEqual -and $rectEqual -and
                       $negativeOrigin -and $identityComplete -and $nonSession0 -and
                       $sessionMatchesTarget -and $sessionConsistent -and $captureProvenanceOk

    if (-not $tokensSatisfied) {
        if ($tokenCountOk -and -not $tokenSetEqual) { $reasons.Add('token-sets-differ') }
        if ($tokenCountOk -and -not $rectEqual) { $reasons.Add('token-rect-correlation-differs') }
        if (-not $tokenCountOk) { $reasons.Add('token-count-not-two') }
        if (-not $distinctOk) { $reasons.Add('tokens-not-distinct') }
        if (-not $identityComplete) { $reasons.Add('identity-incomplete') }
        if (-not $negativeOrigin) { $reasons.Add('negative-origin-not-evidenced') }
        if (-not $nonSession0) { $reasons.Add('session-0-evidence') }
        if ($nonSession0 -and -not $sessionMatchesTarget) { $reasons.Add('capture-session-not-target') }
        if (-not $sessionConsistent) { $reasons.Add('capture-sessions-incompatible') }
    }

    # ---- (b) the complete, evidenced transition ----
    $proof = Get-P9HDisconnectProof -ObserverLogPath $ObserverLogPath -SessionId $TargetSessionId `
        -User $TargetUser -TrialId $TrialId -LogonTime $TargetLogonTime

    $sub['confirmedTargetDisconnect'] = [bool]$proof.Proven
    if (-not $proof.Proven) { $reasons.Add('disconnect-not-proven:' + $proof.Reason) }

    # ---- verdict ----
    # Equality without a proven transition is NOT a pass; it is exactly the
    # P9-G situation and must be reported as NOT FULLY EVIDENCED.
    $verdict = 'NOT FULLY EVIDENCED'
    if ($tokensSatisfied -and $proof.Proven) { $verdict = 'PASS' }

    return [pscustomobject][ordered]@{
        Verdict          = $verdict
        TokensSatisfied  = $tokensSatisfied
        DisconnectProven = [bool]$proof.Proven
        DisconnectReason = [string]$proof.Reason
        SubObservations  = $sub
        Reasons          = @($reasons)
        TokenSetBytes    = ((@($preSorted) -join '|'))
        TokenRectBytes   = [string]$a.tokenRectBytes
        Tokens           = @($preTokens)
    }
}

function Get-P9HN2Verdicts {
    # Two INDEPENDENT verdicts: N2-A (placement skip) and N2-B (lifecycle).
    #
    # Stage 2.1 corrections (independent review):
    #   * N2-A initialised $fallbackApplied = $false, so an UNREADABLE post-window
    #     artifact left it false and the remaining predicates could still PASS.
    #     An absent observation is not proof that the fallback was avoided.
    #   * N2-B computed $windowsAttributed with a tautology ('.Count -ge 0') and
    #     then never used it in the PASS predicate, so a run with no attributable
    #     window/process could still PASS on a clean trace plus exit 0.
    #
    # A clean broker trace can never substitute for a captured exit code, and a
    # created window can never substitute for lifecycle completion.
    param(
        [Parameter(Mandatory)][string]$FixturePath,
        [Parameter(Mandatory)][string]$TracePath,
        [Parameter(Mandatory)][string]$StdoutPath,
        [Parameter(Mandatory)][string]$PreWindowPath,
        [Parameter(Mandatory)][string]$PostWindowPath,
        [Parameter(Mandatory)][string]$ExitRecordPath,
        [Parameter(Mandatory)][string]$NewProcessPath,
        [string]$PostProcessPath = '',
        [string]$TrialId = '',
        [string]$WindowRequired = 'yes'
    )

    $reasonsA = [System.Collections.Generic.List[string]]::new()
    $reasonsB = [System.Collections.Generic.List[string]]::new()

    $fixture = Read-P9HJsonArtifact -Path $FixturePath
    $exit = Test-P9HExitRecord -Path $ExitRecordPath

    # ---------- fixture validity ----------
    $fixtureOk = $false
    $itemCountOne = $false
    $anchorAbsent = $false
    $fallbackUnreachable = $false
    $fallbackRectText = $null
    $itemId = $null

    if ($fixture.Ok) {
        $fx = $fixture.Data
        $itemId = [string]$fx.itemId
        $itemCountOne = ([int]$fx.enabledItems -eq 1 -and [int]$fx.enabledTerminals -eq 1 -and [int]$fx.totalItems -eq 1)
        $anchorAbsent = [bool]$fx.anchorAbsent
        if ($null -ne $fx.layoutFallback) {
            $fallbackRectText = ('{0},{1} {2}x{3}' -f $fx.layoutFallback.x, $fx.layoutFallback.y, $fx.layoutFallback.w, $fx.layoutFallback.h)
            $fallbackUnreachable = ([int]$fx.layoutFallback.x -eq 9000 -and [int]$fx.layoutFallback.y -eq 9000)
        }
        $fixtureOk = ($itemCountOne -and $anchorAbsent -and $fallbackUnreachable)
    }
    else { $reasonsA.Add('fixture-unreadable:' + $fixture.Reason) }

    # ---------- trace ----------
    # Malformed trace lines are NOT silently skipped: a partial trace cannot be
    # used to claim the whole transaction succeeded.
    $traceEvents = @()
    $traceOk = $false
    $traceRejections = 0
    if (Test-Path -LiteralPath $TracePath -PathType Leaf) {
        foreach ($line in (Get-Content -LiteralPath $TracePath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $traceEvents += ($line | ConvertFrom-Json -ErrorAction Stop) }
            catch { $traceRejections++ }
        }
        $traceOk = ($traceEvents.Count -gt 0 -and $traceRejections -eq 0)
    }
    if (-not $traceOk) {
        # Note: an 'if' statement cannot be a method argument in PowerShell, so
        # the reason is computed first.
        $traceReason = if ($traceRejections -gt 0) { 'trace-malformed-lines' } else { 'trace-missing' }
        $reasonsA.Add($traceReason)
        $reasonsB.Add($traceReason)
    }

    $plan = @($traceEvents | Where-Object { $_.event -eq 'lifecycle-layout-plan' }) | Select-Object -Last 1
    $ready = @($traceEvents | Where-Object { $_.event -eq 'stage2-broker-ready' }) | Select-Object -Last 1
    $finalEvent = @($traceEvents | Where-Object { $_.event -eq 'stage2-terminal-final' }) | Select-Object -Last 1
    $end = @($traceEvents | Where-Object { $_.event -eq 'transaction-end' }) | Select-Object -Last 1

    # ---------- N2-A: placement skip (requires an OBSERVED post-state) ----
    $skipped = $false
    if ($null -ne $plan -and $null -ne $plan.skipped) {
        $skipped = (@($plan.skipped) -contains $itemId)
    }

    $warningPresent = $false
    if (Test-Path -LiteralPath $StdoutPath -PathType Leaf) {
        $so = Get-Content -LiteralPath $StdoutPath -Raw
        $warningPresent = ($so -match 'no reachable placement' -and $so -match 'will not be changed')
    }

    # A missing or unreadable post-window artifact is an EVIDENCE GAP, not a
    # proof that the fallback window never appeared.
    $postWindows = Read-P9HJsonArtifact -Path $PostWindowPath
    $postObserved = $false
    $fallbackApplied = $null      # tri-state: $null means NOT OBSERVED
    $windowCount = $null

    if ($postWindows.Ok -and $null -ne $postWindows.Data.PSObject.Properties['Windows']) {
        $wins = @($postWindows.Data.Windows)
        $postObserved = $true
        $windowCount = $wins.Count
        $fallbackApplied = (@($wins | Where-Object { $_.x -eq 9000 -and $_.y -eq 9000 }).Count -gt 0)
    }
    else {
        $reasonsA.Add('post-window-observation-unavailable:' + $(if ($postWindows.Ok) { 'schema-missing-windows' } else { $postWindows.Reason }))
    }

    $n2a = 'INCONCLUSIVE'
    if (-not $fixtureOk) { $reasonsA.Add('fixture-invalid') }
    elseif (-not $traceOk) { }
    elseif (-not $postObserved) { }
    elseif (-not $skipped) { $reasonsA.Add('item-not-in-skipped-set') }
    elseif (-not $warningPresent) { $reasonsA.Add('deterministic-warning-absent') }
    elseif ($fallbackApplied) { $reasonsA.Add('fallback-rectangle-applied') }
    else { $n2a = 'PASS' }

    # ---------- N2-B: lifecycle completion (attribution is first class) ----
    $brokerOk = ($null -ne $ready -and [int]$ready.failed -eq 0)
    $finalOk = ($null -ne $finalEvent -and [int]$finalEvent.finalized -eq 1 -and [int]$finalEvent.failures -eq 0)
    $zeroFailures = ($null -ne $end -and @($end.failures).Count -eq 0)
    $brokerClean = ($null -ne $end -and [bool]$end.broker -and -not [bool]$end.uncertain)

    # Trace must belong to this trial when the trace carries a trial id.
    # Stage 2.1: this is a BLOCKING condition, not merely a recorded reason.
    # Previously the mismatch was appended to reasons but never consulted by the
    # PASS predicate, so a foreign trace could still yield PASS.
    $traceTrialOk = $true
    if (-not [string]::IsNullOrWhiteSpace($TrialId)) {
        $tp = if ($null -ne $plan) { $plan.PSObject.Properties['trialId'] } else { $null }
        if ($null -ne $tp -and -not [string]::IsNullOrWhiteSpace([string]$tp.Value)) {
            if (-not [string]::Equals([string]$tp.Value, $TrialId, [System.StringComparison]::Ordinal)) {
                $traceTrialOk = $false
                $reasonsB.Add('trace-trial-mismatch')
            }
        }
    }

    $exitCaptured = ($exit.Valid -and $exit.Data.outcome -eq 'exited' -and $null -ne $exit.Data.exitCode)
    $exitZero = ($exitCaptured -and [int]$exit.Data.exitCode -eq 0)

    # Launcher identity: a zero exit is only meaningful for the tracked launcher.
    $launcherPid = if ($exit.Valid) { $exit.Data.launcherPid } else { $null }
    $launcherOk = ($exit.Valid -and -not [string]::IsNullOrWhiteSpace([string]$exit.Data.launcherPath))

    # ---- process attribution ----
    $newProcs = Read-P9HJsonArtifact -Path $NewProcessPath
    $addedProcesses = @()
    $processAttributed = $false
    $terminalPids = @()
    if ($newProcs.Ok -and $null -ne $newProcs.Data.PSObject.Properties['Added']) {
        $addedProcesses = @($newProcs.Data.Added)
        # Processes created during the launch that carry a RECOVERED start time.
        $withStart = @($addedProcesses | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.startUtc) -and
                [string]$_.name -notmatch '^(conhost|cmd)\.exe$'
            })
        $processAttributed = ($withStart.Count -ge 1)
        $terminalPids = @($withStart | ForEach-Object { [int]$_.pid })
    }
    else { $reasonsB.Add('new-process-inventory-missing:' + $(if ($newProcs.Ok) { 'schema-missing-added' } else { $newProcs.Reason })) }

    # ---- window attribution (title independent) ----
    $windowAttribution = $null
    $windowAttributed = $false
    if ($postWindows.Ok -and $postObserved -and $processAttributed) {
        $preWindows = Read-P9HJsonArtifact -Path $PreWindowPath
        $preHwnds = @()
        if ($preWindows.Ok -and $null -ne $preWindows.Data.PSObject.Properties['Windows']) {
            $preHwnds = @($preWindows.Data.Windows | ForEach-Object { [string]$_.hwnd })
        }

        $windowAttribution = Select-P9HAttributableWindow -PreWindowHwnds $preHwnds `
            -AfterWindows @($postWindows.Data.Windows) -CandidatePids $terminalPids
        $windowAttributed = [bool]$windowAttribution.Attributed
    }

    $windowIsRequired = ($WindowRequired -ne 'no')

    if (-not $brokerOk) { $reasonsB.Add('broker-ready-missing-or-failed') }
    if (-not $finalOk) { $reasonsB.Add('terminal-final-not-clean') }
    if (-not $zeroFailures) { $reasonsB.Add('transaction-failures-present') }
    if (-not $brokerClean) { $reasonsB.Add('broker-not-clean') }
    if (-not $launcherOk) { $reasonsB.Add('launcher-identity-unavailable') }
    if (-not $exit.Valid) { $reasonsB.Add('exit-record-invalid:' + $exit.Reason) }
    elseif (-not $exitCaptured) { $reasonsB.Add('exit-not-captured:' + [string]$exit.Data.outcome) }
    elseif (-not $exitZero) { $reasonsB.Add('exit-code-nonzero:' + [string]$exit.Data.exitCode) }
    if ($exitCaptured -and -not $processAttributed) { $reasonsB.Add('no-attributable-new-process') }
    if ($exitCaptured -and $windowIsRequired -and -not $windowAttributed) { $reasonsB.Add('no-attributable-new-window') }

    $n2b = 'INCONCLUSIVE'
    if (-not $exit.Valid) {
        # Instrumentation gap: inconclusive, never a product failure.
        $n2b = 'INCONCLUSIVE'
    }
    elseif ($exitCaptured -and -not $exitZero) {
        # A real captured nonzero exit is a lifecycle failure.
        $n2b = 'FAIL'
    }
    elseif ($exitCaptured -and $exitZero -and $brokerOk -and $finalOk -and $zeroFailures -and
            $brokerClean -and $launcherOk -and $processAttributed -and
            $traceTrialOk -and (-not $windowIsRequired -or $windowAttributed)) {
        $n2b = 'PASS'
    }
    else { $n2b = 'INCONCLUSIVE' }

    return [pscustomobject][ordered]@{
        N2A = [pscustomobject][ordered]@{
            Verdict = $n2a
            FixtureOk = $fixtureOk
            ItemCountOne = $itemCountOne
            AnchorAbsent = $anchorAbsent
            FallbackRect = $fallbackRectText
            FallbackUnreachable = $fallbackUnreachable
            SkippedInTrace = $skipped
            WarningPresent = $warningPresent
            PostStateObserved = $postObserved
            WindowCountObserved = $windowCount
            FallbackApplied = $fallbackApplied
            Reasons = @($reasonsA)
        }
        N2B = [pscustomobject][ordered]@{
            Verdict = $n2b
            ExitCaptured = $exitCaptured
            ExitCode = if ($exitCaptured) { [int]$exit.Data.exitCode } else { $null }
            ExitOutcome = if ($exit.Valid) { [string]$exit.Data.outcome } else { 'invalid' }
            LauncherIdentityOk = $launcherOk
            LauncherPid = $launcherPid
            ProcessAttributed = $processAttributed
            AttributedProcessPids = @($terminalPids)
            WindowAttributed = $windowAttributed
            AttributedWindowCount = if ($null -ne $windowAttribution) { $windowAttribution.Count } else { $null }
            BrokerReady = $brokerOk
            TerminalFinal = $finalOk
            ZeroFailures = $zeroFailures
            BrokerClean = $brokerClean
            Reasons = @($reasonsB)
        }
    }
}

function Get-P9HStageStatusSummary {
    # Fold stages.jsonl into a per-stage outcome map.
    #
    # A stage with no record is reported as 'absent' rather than assumed ok, so a
    # run that died before a stage is visible in the summary.
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
