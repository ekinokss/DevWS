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
    # E1 verdict from the two monitor captures plus the disconnect proof.
    #
    # PASS requires BOTH:
    #   (a) exact token equality with stable token->rect correlation; and
    #   (b) a proven target-session disconnect/reconnect transition.
    #
    # Sub-observations are reported separately so a reviewer can see exactly
    # which part of E1 is evidenced, mirroring the corrected P9-G wording.
    param(
        [Parameter(Mandatory)][string]$PreCapturePath,
        [Parameter(Mandatory)][string]$PostCapturePath,
        [Parameter(Mandatory)][string]$ObserverLogPath,
        [Parameter(Mandatory)][int]$TargetSessionId,
        [Parameter(Mandatory)][string]$TargetUser
    )

    $pre = Read-P9HJsonArtifact -Path $PreCapturePath
    $post = Read-P9HJsonArtifact -Path $PostCapturePath

    $sub = [ordered]@{}
    $reasons = [System.Collections.Generic.List[string]]::new()

    if (-not $pre.Ok -or -not $post.Ok) {
        $reasons.Add('monitor-captures-missing:' + $(if (-not $pre.Ok) { 'pre-' + $pre.Reason } else { '' }) + $(if (-not $post.Ok) { 'post-' + $post.Reason } else { '' }))
        return [pscustomobject][ordered]@{
            Verdict         = 'INCONCLUSIVE'
            DisconnectProven = $false
            SubObservations = $sub
            Reasons         = @($reasons)
        }
    }

    $a = $pre.Data
    $b = $post.Data

    # ---- (a) token stability between the two captures ----
    $preTokens = @($a.tokens)
    $postTokens = @($b.tokens)
    $preSorted = @($preTokens | Sort-Object)
    $postSorted = @($postTokens | Sort-Object)
    $tokenSetEqual = ((@($preSorted) -join '|') -ceq (@($postSorted) -join '|'))
    $tokenCountOk = ($preTokens.Count -eq 2 -and $postTokens.Count -eq 2)
    $distinctOk = (@(@($preTokens | Sort-Object -Unique).Count) -eq 2)
    $rectEqual = ([string]$a.tokenRectBytes -ceq [string]$b.tokenRectBytes)
    $negativeOrigin = ([string]$a.tokenRectBytes -match 'x=-\d')
    $identityComplete = [bool]([bool]$a.identityComplete -and [bool]$b.identityComplete)
    $nonSession0 = ([int]$a.sessionId -ne 0 -and [int]$b.sessionId -ne 0)

    $sub['twoDistinctTokens'] = $tokenCountOk -and $distinctOk
    $sub['byteIdenticalTokenSets'] = $tokenSetEqual
    $sub['tokenRectCorrelationIdentical'] = $rectEqual
    $sub['negativeOriginTopology'] = $negativeOrigin
    $sub['identityComplete'] = $identityComplete
    $sub['nonSession0Evidence'] = $nonSession0

    $tokensSatisfied = $tokenCountOk -and $distinctOk -and $tokenSetEqual -and $rectEqual -and $identityComplete -and $nonSession0

    if (-not $tokensSatisfied) {
        # A measured mismatch is reported, never normalised.
        if ($tokenCountOk -and -not $tokenSetEqual) { $reasons.Add('token-sets-differ') }
        if ($tokenCountOk -and -not $rectEqual) { $reasons.Add('token-rect-correlation-differs') }
        if (-not $tokenCountOk) { $reasons.Add('token-count-not-two') }
        if (-not $identityComplete) { $reasons.Add('identity-incomplete') }
        if (-not $nonSession0) { $reasons.Add('session-0-evidence') }
    }

    # ---- (b) target-session disconnect proof ----
    $proof = Get-P9HDisconnectProof -ObserverLogPath $ObserverLogPath -SessionId $TargetSessionId -User $TargetUser
    $sub['confirmedTargetDisconnect'] = [bool]$proof.Proven

    if (-not $proof.Proven) { $reasons.Add('disconnect-not-proven:' + $proof.Reason) }

    # ---- verdict ----
    $verdict = 'NOT FULLY EVIDENCED'
    if ($tokensSatisfied -and $proof.Proven) { $verdict = 'PASS' }

    return [pscustomobject][ordered]@{
        Verdict          = $verdict
        TokensSatisfied  = $tokensSatisfied
        DisconnectProven = [bool]$proof.Proven
        DisconnectReason = [string]$proof.Reason
        SubObservations  = $sub
        Reasons          = @($reasons)
        TokenSetBytes    = [string]$a.tokenSetBytes
        TokenRectBytes   = [string]$a.tokenRectBytes
    }
}

function Get-P9HN2Verdicts {
    # Two INDEPENDENT verdicts: N2-A (placement skip) and N2-B (lifecycle).
    #
    # A clean broker trace can never substitute for a captured exit code, and a
    # created window can never substitute for lifecycle completion. Instrumentation
    # gaps produce INCONCLUSIVE; they are not converted into product failures.
    param(
        [Parameter(Mandatory)][string]$FixturePath,
        [Parameter(Mandatory)][string]$TracePath,
        [Parameter(Mandatory)][string]$StdoutPath,
        [Parameter(Mandatory)][string]$PreWindowPath,
        [Parameter(Mandatory)][string]$PostWindowPath,
        [Parameter(Mandatory)][string]$ExitRecordPath,
        [Parameter(Mandatory)][string]$NewProcessPath
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

    if ($fixture.Ok) {
        $fx = $fixture.Data
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
    $traceEvents = @()
    $traceOk = $false
    if (Test-Path -LiteralPath $TracePath -PathType Leaf) {
        foreach ($line in (Get-Content -LiteralPath $TracePath)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $traceEvents += ($line | ConvertFrom-Json) } catch { }
        }
        $traceOk = ($traceEvents.Count -gt 0)
    }
    if (-not $traceOk) { $reasonsA.Add('trace-missing'); $reasonsB.Add('trace-missing') }

    $plan = @($traceEvents | Where-Object { $_.event -eq 'lifecycle-layout-plan' }) | Select-Object -Last 1
    $ready = @($traceEvents | Where-Object { $_.event -eq 'stage2-broker-ready' }) | Select-Object -Last 1
    $finalEvent = @($traceEvents | Where-Object { $_.event -eq 'stage2-terminal-final' }) | Select-Object -Last 1
    $end = @($traceEvents | Where-Object { $_.event -eq 'transaction-end' }) | Select-Object -Last 1

    # ---------- N2-A: placement skip ----------
    $skipped = $false
    if ($null -ne $plan -and $null -ne $plan.skipped) {
        $itemId = if ($fixture.Ok) { [string]$fixture.Data.itemId } else { $null }
        $skipped = (@($plan.skipped) -contains $itemId)
    }

    $warningPresent = $false
    if (Test-Path -LiteralPath $StdoutPath -PathType Leaf) {
        $so = Get-Content -LiteralPath $StdoutPath -Raw
        $warningPresent = ($so -match 'no reachable placement' -and $so -match 'will not be changed')
    }

    $postWindows = Read-P9HJsonArtifact -Path $PostWindowPath
    $fallbackApplied = $false
    if ($postWindows.Ok) {
        $fallbackApplied = (@($postWindows.Data.Windows | Where-Object { $_.x -eq 9000 -and $_.y -eq 9000 }).Count -gt 0)
    }

    $windowsAttributed = $false
    if ($exit.Valid -and $exit.Data.outcome -eq 'exited') {
        $launcherPid = $exit.Data.launcherPid
        $newProcs = Read-P9HJsonArtifact -Path $NewProcessPath
        if ($newProcs.Ok -and $null -ne $launcherPid) {
            $windowsAttributed = (@($postWindows.Data.Windows | Where-Object { $_.pid -eq [int]$launcherPid }).Count -ge 0)
        }
    }

    $n2a = 'INCONCLUSIVE'
    if (-not $fixtureOk) { $reasonsA.Add('fixture-invalid') }
    elseif (-not $traceOk) { }
    elseif (-not $skipped) { $reasonsA.Add('item-not-in-skipped-set') }
    elseif (-not $warningPresent) { $reasonsA.Add('deterministic-warning-absent') }
    elseif ($fallbackApplied) { $reasonsA.Add('fallback-rectangle-applied') }
    else { $n2a = 'PASS' }

    # ---------- N2-B: lifecycle completion ----------
    $brokerOk = ($null -ne $ready -and [int]$ready.failed -eq 0)
    $finalOk = ($null -ne $finalEvent -and [int]$finalEvent.finalized -eq 1 -and [int]$finalEvent.failures -eq 0)
    $zeroFailures = ($null -ne $end -and @($end.failures).Count -eq 0)
    $brokerClean = ($null -ne $end -and [bool]$end.broker -and -not [bool]$end.uncertain)

    $exitCaptured = ($exit.Valid -and $exit.Data.outcome -eq 'exited' -and $null -ne $exit.Data.exitCode)
    $exitZero = ($exitCaptured -and [int]$exit.Data.exitCode -eq 0)

    if (-not $brokerOk) { $reasonsB.Add('broker-ready-missing-or-failed') }
    if (-not $finalOk) { $reasonsB.Add('terminal-final-not-clean') }
    if (-not $zeroFailures) { $reasonsB.Add('transaction-failures-present') }
    if (-not $brokerClean) { $reasonsB.Add('broker-not-clean') }
    if (-not $exit.Valid) { $reasonsB.Add('exit-record-invalid:' + $exit.Reason) }
    elseif (-not $exitCaptured) { $reasonsB.Add('exit-not-captured:' + [string]$exit.Data.outcome) }
    elseif (-not $exitZero) { $reasonsB.Add('exit-code-nonzero:' + [string]$exit.Data.exitCode) }

    $n2b = 'INCONCLUSIVE'
    if (-not $exit.Valid) {
        # Instrumentation gap: inconclusive, never a product failure.
        $n2b = 'INCONCLUSIVE'
    }
    elseif ($exitCaptured -and -not $exitZero) {
        # A real captured nonzero exit is a lifecycle failure, not a placement one.
        $n2b = 'FAIL'
    }
    elseif ($exitCaptured -and $exitZero -and $brokerOk -and $finalOk -and $zeroFailures -and $brokerClean) {
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
            FallbackApplied = $fallbackApplied
            Reasons = @($reasonsA)
        }
        N2B = [pscustomobject][ordered]@{
            Verdict = $n2b
            ExitCaptured = $exitCaptured
            ExitCode = if ($exitCaptured) { [int]$exit.Data.exitCode } else { $null }
            ExitOutcome = if ($exit.Valid) { [string]$exit.Data.outcome } else { 'invalid' }
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
