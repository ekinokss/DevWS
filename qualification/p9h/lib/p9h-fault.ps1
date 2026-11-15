# DevWS P9-H replay instrumentation - fault-injection harness.
#
# Purpose: prove that a later-stage failure CANNOT damage an already persisted
# exit record. This is the primary Stage 2 acceptance gate.
#
# Every injection here operates only on test-owned data in a temp directory. No
# product, VM, session or host configuration is touched.
#
# The three injections mirror the P9-G failure modes exactly:
#   * inventory-throws   - the WMI date defect raised during inventory
#   * serializer-hangs   - the post-launch serialization never returned
#   * malformed-json     - a downstream artifact was written incorrectly

Set-StrictMode -Version Latest

function Invoke-P9HFaultInventoryThrows {
    # Inventory stage that throws. Models P9-G's ArgumentOutOfRangeException.
    param([Parameter(Mandatory)][string]$ArtifactDirectory)

    $text = 'Exception calling "ToDateTime" with "1" argument(s): "Specified argument was out of the range of valid values.' + "`r`n" + 'Parameter name: dmtfDate"'
    throw $text
}

function Invoke-P9HFaultSerializerHangs {
    # Serializer stage that never completes. Models the P9-G hang.
    #
    # Bounded by -TimeoutMs so the self-test itself terminates; the point is that
    # the caller treats the timeout as a stage failure, while the exit record is
    # untouched. It performs no I/O and consumes no measurable CPU, matching the
    # observed 'Responding=True but never finished' behaviour.
    param(
        [Parameter(Mandatory)][string]$ArtifactDirectory,
        [int]$TimeoutMs = 5000
    )

    Start-Sleep -Milliseconds $TimeoutMs
    return 'hang-not-reached-because-caller-timeout-wins'
}

function Invoke-P9HFaultMalformedJson {
    # Writes a structurally invalid downstream artifact. Models a corrupted
    # analysis output, to prove the verifier rejects rather than assumes.
    param([Parameter(Mandatory)][string]$Path)

    Write-P9HArtifact -Path $Path -Lines @('{"trialId": "broken", "outcome": ')
    return $Path
}

function Invoke-P9HFaultMissingArtifact {
    # Simulates a stage that produced nothing at all.
    param([Parameter(Mandatory)][string]$Path)
    return [pscustomobject][ordered]@{ Path = $Path; Exists = (Test-Path -LiteralPath $Path) }
}

function Invoke-P9HFaultBoundedStage {
    # Run an arbitrary stage with a hard bound, classifying the three outcomes.
    #
    # Runs in a child process so a genuinely wedged stage cannot wedge the test
    # runner. The child is test-owned and is killed on timeout.
    #
    # IMPORTANT: Start-Job runs in a SEPARATE process that does NOT inherit the
    # loaded module functions. A closure that calls one of them fails instantly
    # (self-test T6 caught this, reporting 'failed' instead of 'timeout'). The
    # caller must therefore pass self-contained script text, or use
    # -DefinitionFiles to dot-source the module inside the job.
    param(
        [Parameter(Mandatory)][string]$StageName,
        [Parameter(Mandatory)][scriptblock]$Stage,
        [int]$TimeoutMs = 5000,
        [string[]]$DefinitionFiles = @()
    )

    $result = [ordered]@{
        stage    = $StageName
        outcome  = 'ok'
        detail   = $null
        elapsedMs = 0
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($DefinitionFiles.Count -gt 0) {
            $loader = ($DefinitionFiles | ForEach-Object { '. ''' + $_ + '''' }) -join '; '
            $trigger = $Stage.ToString()
            $handle = Start-Job -ScriptBlock ([scriptblock]::Create($loader + "`r`n" + $trigger))
        }
        else {
            $handle = Start-Job -ScriptBlock $Stage
        }

        # Wait-Job returns a job object even on timeout, so its return value is
        # not a completion signal. Completion must be read from the job STATE.
        $null = Wait-Job -Job $handle -Timeout ([Math]::Max(1, [int]($TimeoutMs / 1000)))
        $state = [string]$handle.State

        if ($state -eq 'Running' -or $state -eq 'NotStarted') {
            $result.outcome = 'timeout'
            $result.detail = ('stage still {0} after {1} ms' -f $state, $TimeoutMs)
            Stop-Job -Job $handle -ErrorAction SilentlyContinue
        }
        elseif ($state -eq 'Failed' -or $state -eq 'Blocked') {
            $err = @($handle.ChildJobs[0].Error)
            $result.outcome = 'failed'
            $result.detail = ($err | ForEach-Object { [string]$_ }) -join ' | '
        }
        elseif ($state -eq 'Completed') {
            $err = @($handle.ChildJobs[0].Error)
            if ($err.Count -gt 0) {
                $result.outcome = 'failed'
                $result.detail = ($err | ForEach-Object { [string]$_ }) -join ' | '
            }
        }
        else {
            $result.outcome = 'failed'
            $result.detail = ('unexpected job state: ' + $state)
        }
        Remove-Job -Job $handle -Force -ErrorAction SilentlyContinue
    }
    catch {
        $result.outcome = 'failed'
        $result.detail = $_.Exception.Message
    }
    finally { $sw.Stop() }

    $result.elapsedMs = $sw.ElapsedMilliseconds
    return [pscustomobject]$result
}
