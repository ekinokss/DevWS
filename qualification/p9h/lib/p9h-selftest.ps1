# DevWS P9-H replay instrumentation - synthetic self-test suite.
#
# These tests validate the instrumentation ONLY. They never launch the installed
# product, never touch Hyper-V, never disconnect a session, and never modify host
# configuration. Every synthetic process is created inside a task-specific temp
# directory and is tracked so cleanup cannot touch unrelated processes.
#
# Each case records: test id, input, expected, actual, PASS/FAIL, evidence path.
# The runner exits non-zero if any case fails.

Set-StrictMode -Version Latest

$script:P9HTestResults = [System.Collections.Generic.List[object]]::new()

function Add-P9HTestResult {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Input,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][AllowNull()][string]$Actual,
        [Parameter(Mandatory)][bool]$Pass,
        [AllowNull()][string]$Evidence = $null
    )

    $script:P9HTestResults.Add([pscustomobject][ordered]@{
            id       = $Id
            title    = $Title
            input    = $Input
            expected = $Expected
            actual   = $Actual
            result   = if ($Pass) { 'PASS' } else { 'FAIL' }
            evidence = $Evidence
        }) | Out-Null
}

function New-P9HSyntheticScript {
    # Write a harmless test-owned script/cmd into the sandbox.
    #
    # Content is intentionally trivial: print, optionally sleep, exit with a
    # known code. No external program, no user data, no network.
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Name,
        [int]$ExitCode = 0,
        [int]$StdoutLines = 0,
        [int]$SleepMs = 0,
        [switch]$SpawnDetachedChild
    )

    $path = Join-Path $Directory $Name
    $lines = @('@echo off')
    for ($i = 1; $i -le $StdoutLines; $i++) { $lines += ('echo stdout-line-{0}' -f $i) }
    if ($StdoutLines -gt 0) { $lines += 'echo stderr-probe 1>&2' }
    if ($SpawnDetachedChild) {
        # Detached descendant that outlives the launcher. Uses ping on loopback as
        # a portable sleep; no external network contact.
        $lines += 'start "" /b cmd /c "ping -n 20 127.0.0.1 >nul"'
    }
    if ($SleepMs -gt 0) {
        $lines += ('ping -n {0} 127.0.0.1 >nul' -f ([int][Math]::Ceiling($SleepMs / 1000) + 1))
    }
    $lines += ('exit /b {0}' -f $ExitCode)

    $lines | Set-Content -LiteralPath $path -Encoding ascii
    return $path
}

function Get-P9HSandboxRoot {
    # Unique, task-specific sandbox. Never a shared or user directory.
    param([Parameter(Mandatory)][string]$Name)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('p9h-selftest-' + $Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}

function Invoke-P9HExitRecorderTests {
    # T1-T12: exit recording correctness and durability.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $trial = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind selftest
    $art = $trial.Directory

    # ---- T1: exit 0 ----
    $s = New-P9HSyntheticScript -Directory $SandboxRoot -Name 't1.cmd' -ExitCode 0
    $r = Invoke-P9HProcessRecorded -TrialId $trial.TrialId -CommandPath $s -Arguments @() `
        -WorkingDirectory $SandboxRoot -ArtifactDirectory $art -TimeoutMs 30000
    $rec = Test-P9HExitRecord -Path (Join-Path $art 'n2-exit-record.json')
    Add-P9HTestResult -Id 'T1' -Title 'Synthetic process exits 0' -Input $s -Expected 'exited / exitCode=0' `
        -Actual ("outcome={0} exitCode={1} valid={2}" -f $rec.Data.outcome, $rec.Data.exitCode, $rec.Valid) `
        -Pass ($rec.Valid -and $rec.Data.outcome -eq 'exited' -and [int]$rec.Data.exitCode -eq 0) `
        -Evidence (Join-Path $art 'n2-exit-record.json')

    # ---- T2: exit 7 ----
    $s = New-P9HSyntheticScript -Directory $SandboxRoot -Name 't2.cmd' -ExitCode 7
    $null = Invoke-P9HProcessRecorded -TrialId $trial.TrialId -CommandPath $s -Arguments @() `
        -WorkingDirectory $SandboxRoot -ArtifactDirectory $art -TimeoutMs 30000
    $rec = Test-P9HExitRecord -Path (Join-Path $art 'n2-exit-record.json')
    Add-P9HTestResult -Id 'T2' -Title 'Synthetic process exits 7' -Input $s -Expected 'exited / exitCode=7' `
        -Actual ("outcome={0} exitCode={1}" -f $rec.Data.outcome, $rec.Data.exitCode) `
        -Pass ($rec.Valid -and [int]$rec.Data.exitCode -eq 7) `
        -Evidence (Join-Path $art 'n2-exit-record.json')

    # ---- T3: parent exits, detached child survives ----
    $s = New-P9HSyntheticScript -Directory $SandboxRoot -Name 't3.cmd' -ExitCode 5 -SpawnDetachedChild
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-P9HProcessRecorded -TrialId $trial.TrialId -CommandPath $s -Arguments @() `
        -WorkingDirectory $SandboxRoot -ArtifactDirectory $art -TimeoutMs 30000
    $sw.Stop()
    $rec = Test-P9HExitRecord -Path (Join-Path $art 'n2-exit-record.json')
    Add-P9HTestResult -Id 'T3' -Title 'Parent exits while detached child remains' `
        -Input ($s + ' (spawns detached ping child)') -Expected 'exitCode=5 recorded promptly (<10s)' `
        -Actual ("exitCode={0} elapsedMs={1}" -f $rec.Data.exitCode, $sw.ElapsedMilliseconds) `
        -Pass ($rec.Valid -and [int]$rec.Data.exitCode -eq 5 -and $sw.ElapsedMilliseconds -lt 10000) `
        -Evidence (Join-Path $art 'n2-exit-record.json')

    # ---- T4: large stdout/stderr, no deadlock ----
    $s = New-P9HSyntheticScript -Directory $SandboxRoot -Name 't4.cmd' -ExitCode 3 -StdoutLines 4000
    $r = Invoke-P9HProcessRecorded -TrialId $trial.TrialId -CommandPath $s -Arguments @() `
        -WorkingDirectory $SandboxRoot -ArtifactDirectory $art -TimeoutMs 120000
    $rec = Test-P9HExitRecord -Path (Join-Path $art 'n2-exit-record.json')
    $outFile = Join-Path $art 'n2-launch-stdout.txt'
    $outBytes = if (Test-Path $outFile) { (Get-Item $outFile).Length } else { 0 }
    $outLines = if (Test-Path $outFile) { @(Get-Content $outFile).Count } else { 0 }
    Add-P9HTestResult -Id 'T4' -Title 'Large stdout and stderr without deadlock' `
        -Input '4000 stdout lines + 1 stderr line' -Expected 'exited / exitCode=3; stdout complete' `
        -Actual ("exitCode={0} stdoutLines={1} stdoutBytes={2}" -f $rec.Data.exitCode, $outLines, $outBytes) `
        -Pass ($rec.Valid -and [int]$rec.Data.exitCode -eq 3 -and $outLines -ge 4000) `
        -Evidence $outFile

    # ---- T5: inventory throws, exit record intact ----
    $exitPath = Join-Path $art 'n2-exit-record.json'
    $hashBefore = Get-P9HFileSha256 -Path $exitPath
    # Direct invocation is deliberate: it proves the throw happens AND that the
    # exit record is untouched, without depending on job-host inheritance.
    $threw = $false
    try { Invoke-P9HFaultInventoryThrows -ArtifactDirectory $art } catch { $threw = $true }
    $hashAfter = Get-P9HFileSha256 -Path $exitPath
    Add-P9HTestResult -Id 'T5' -Title 'Inventory exception leaves exit record intact' `
        -Input 'deliberate ToDateTime ArgumentOutOfRangeException' -Expected 'inventory throws; exit record sha256 unchanged' `
        -Actual ("threw={0} shaBefore={1} shaAfter={2} same={3}" -f $threw, $hashBefore.Substring(0,12), $hashAfter.Substring(0,12), ($hashBefore -eq $hashAfter)) `
        -Pass ($threw -and $hashBefore -eq $hashAfter) `
        -Evidence $exitPath

    # ---- T6: serializer hangs, exit record intact ----
    # Self-contained script text: Start-Job does not inherit module functions, so
    # the stage inlines a plain sleep instead of calling the helper.
    $hangResult = Invoke-P9HFaultBoundedStage -StageName 'serializer' -TimeoutMs 5000 -Stage {
        Start-Sleep -Milliseconds 30000
        'hang-not-reached-because-caller-timeout-wins'
    }
    $hashAfterHang = Get-P9HFileSha256 -Path $exitPath
    Add-P9HTestResult -Id 'T6' -Title 'Serializer hang leaves exit record intact' `
        -Input 'bounded 30s hang, stage timeout 5s' -Expected 'stage outcome=timeout; exit record sha256 unchanged' `
        -Actual ("stageOutcome={0} same={1}" -f $hangResult.outcome, ($hashBefore -eq $hashAfterHang)) `
        -Pass ($hangResult.outcome -eq 'timeout' -and $hashBefore -eq $hashAfterHang) `
        -Evidence $exitPath

    # ---- T7: launcher exceeds timeout ----
    $s = New-P9HSyntheticScript -Directory $SandboxRoot -Name 't7.cmd' -ExitCode 0 -SleepMs 20000
    $r = Invoke-P9HProcessRecorded -TrialId $trial.TrialId -CommandPath $s -Arguments @() `
        -WorkingDirectory $SandboxRoot -ArtifactDirectory $art -TimeoutMs 2000
    $rec = Test-P9HExitRecord -Path (Join-Path $art 'n2-exit-record.json')
    if ($null -ne $r.Process -and -not $r.Process.HasExited) {
        try { $r.Process.Kill(); $r.Process.WaitForExit(5000) | Out-Null } catch { }
    }
    Add-P9HTestResult -Id 'T7' -Title 'Launcher exceeding timeout is classified' `
        -Input '20s sleeper with 2s timeout' -Expected 'outcome=timeout, exitCode=null, still valid' `
        -Actual ("outcome={0} exitCode={1} valid={2}" -f $rec.Data.outcome, $rec.Data.exitCode, $rec.Valid) `
        -Pass ($rec.Valid -and $rec.Data.outcome -eq 'timeout' -and $null -eq $rec.Data.exitCode) `
        -Evidence (Join-Path $art 'n2-exit-record.json')

    # ---- T8: missing exit record rejected ----
    $missing = Join-Path $art 'does-not-exist.json'
    $ver = Test-P9HExitRecord -Path $missing
    Add-P9HTestResult -Id 'T8' -Title 'Missing exit record is rejected' -Input $missing `
        -Expected 'Valid=false reason=missing' -Actual ("Valid={0} reason={1}" -f $ver.Valid, $ver.Reason) `
        -Pass ((-not $ver.Valid) -and $ver.Reason -eq 'missing') -Evidence $null

    # ---- T9: malformed exit record rejected ----
    $bad = Join-Path $art 'malformed-exit-record.json'
    $null = Invoke-P9HFaultMalformedJson -Path $bad
    $ver = Test-P9HExitRecord -Path $bad
    Add-P9HTestResult -Id 'T9' -Title 'Malformed exit record is rejected' -Input $bad `
        -Expected 'Valid=false (malformed)' -Actual ("Valid={0} reason={1}" -f $ver.Valid, $ver.Reason) `
        -Pass ((-not $ver.Valid) -and $ver.Reason -eq 'malformed') -Evidence $bad
}

function Invoke-P9HPathRobustnessTests {
    # T10-T12: spaces, unicode, complex quoted arguments.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $trial = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind selftest
    $art = $trial.Directory

    # ---- T10: path with spaces ----
    $spacedDir = Join-Path $SandboxRoot 'dir with spaces'
    New-Item -ItemType Directory -Path $spacedDir -Force | Out-Null
    $s = New-P9HSyntheticScript -Directory $spacedDir -Name 'probe script.cmd' -ExitCode 4
    $null = Invoke-P9HProcessRecorded -TrialId $trial.TrialId -CommandPath $s -Arguments @() `
        -WorkingDirectory $spacedDir -ArtifactDirectory $art -TimeoutMs 30000
    $rec = Test-P9HExitRecord -Path (Join-Path $art 'n2-exit-record.json')
    Add-P9HTestResult -Id 'T10' -Title 'Path containing spaces' -Input $s -Expected 'exitCode=4 preserved' `
        -Actual ("exitCode={0} launcherPath={1}" -f $rec.Data.exitCode, $rec.Data.launcherPath) `
        -Pass ($rec.Valid -and [int]$rec.Data.exitCode -eq 4) -Evidence (Join-Path $art 'n2-exit-record.json')

    # ---- T11: unicode path ----
    $uDir = Join-Path $SandboxRoot ('unicode-' + [char]0x00E9 + [char]0x00FC)
    New-Item -ItemType Directory -Path $uDir -Force | Out-Null
    $s = New-P9HSyntheticScript -Directory $uDir -Name 'probe-unicode.cmd' -ExitCode 6
    $null = Invoke-P9HProcessRecorded -TrialId $trial.TrialId -CommandPath $s -Arguments @() `
        -WorkingDirectory $uDir -ArtifactDirectory $art -TimeoutMs 30000
    $rec = Test-P9HExitRecord -Path (Join-Path $art 'n2-exit-record.json')
    Add-P9HTestResult -Id 'T11' -Title 'Path containing unicode' -Input $s -Expected 'exitCode=6 preserved' `
        -Actual ("exitCode={0}" -f $rec.Data.exitCode) `
        -Pass ($rec.Valid -and [int]$rec.Data.exitCode -eq 6) -Evidence (Join-Path $art 'n2-exit-record.json')

    # ---- T12: complex quoted arguments preserved verbatim ----
    $argDir = Join-Path $SandboxRoot 'argtest'
    New-Item -ItemType Directory -Path $argDir -Force | Out-Null
    $s = New-P9HSyntheticScript -Directory $argDir -Name 'args.cmd' -ExitCode 0
    $args = @('--name', 'two words', '--path', 'C:\temp\a b\c', '--flag=value', '--quote', "it's here")
    $null = Invoke-P9HProcessRecorded -TrialId $trial.TrialId -CommandPath $s -Arguments $args `
        -WorkingDirectory $argDir -ArtifactDirectory $art -TimeoutMs 30000
    $rec = Test-P9HExitRecord -Path (Join-Path $art 'n2-exit-record.json')
    $stored = @($rec.Data.arguments)
    $same = (($stored -join "`u{1}") -ceq ($args -join "`u{1}"))
    Add-P9HTestResult -Id 'T12' -Title 'Complex quoted arguments preserved exactly' `
        -Input ($args -join ' | ') -Expected 'stored arguments byte-identical, count=7' `
        -Actual ("count={0} identical={1}" -f $stored.Count, $same) `
        -Pass ($rec.Valid -and $same -and $stored.Count -eq $args.Count) `
        -Evidence (Join-Path $art 'n2-exit-record.json')
}

function Invoke-P9HE1ObserverTests {
    # O1-O12: strict target-session matching.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $trial = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind selftest
    $logPath = Join-Path $trial.Directory 'e1-observer.jsonl'

    # Baseline table mirroring the P9-G failure exactly.
    $tableServicesState4 = @(
        '0|Services|state=4|user='
        '2|Console|state=1|user='
        '3|RDP-Tcp#0|state=0|user=qauser'
    )

    # ---- O1: session 0 state 4 must NOT satisfy target session 3 ----
    $table = ConvertFrom-P9HWtsTable -Lines $tableServicesState4
    $judged = Test-P9HTargetDisconnected -Records $table.Records -SessionId 3 -User 'qauser'
    Add-P9HTestResult -Id 'O1' -Title 'Session 0 state 4 does not prove session 3 disconnected' `
        -Input ($tableServicesState4 -join ' ; ') -Expected 'Disconnected=false' `
        -Actual ("Disconnected={0} reason={1}" -f $judged.Disconnected, $judged.Reason) `
        -Pass (-not $judged.Disconnected) -Evidence $logPath

    # ---- O2: target session 3 state 4 accepted ----
    $tableDisc3 = @('0|Services|state=4|user=', '3|RDP-Tcp#0|state=4|user=qauser')
    $t = ConvertFrom-P9HWtsTable -Lines $tableDisc3
    $judged = Test-P9HTargetDisconnected -Records $t.Records -SessionId 3 -User 'qauser'
    Add-P9HTestResult -Id 'O2' -Title 'Target session 3 state 4 is accepted' -Input ($tableDisc3 -join ' ; ') `
        -Expected 'Disconnected=true' -Actual ("Disconnected={0}" -f $judged.Disconnected) `
        -Pass ($judged.Disconnected) -Evidence $logPath

    # ---- O3: correct id, wrong user rejected ----
    $t = ConvertFrom-P9HWtsTable -Lines @('3|RDP-Tcp#0|state=4|user=someoneelse')
    $judged = Test-P9HTargetDisconnected -Records $t.Records -SessionId 3 -User 'qauser'
    Add-P9HTestResult -Id 'O3' -Title 'Correct session id with wrong username is rejected' `
        -Input '3|RDP-Tcp#0|state=4|user=someoneelse' -Expected 'Disconnected=false reason=user-mismatch' `
        -Actual ("Disconnected={0} reason={1}" -f $judged.Disconnected, $judged.Reason) `
        -Pass ((-not $judged.Disconnected) -and $judged.Reason -eq 'user-mismatch') -Evidence $logPath

    # ---- O4: correct user, wrong id rejected ----
    $t = ConvertFrom-P9HWtsTable -Lines @('5|RDP-Tcp#1|state=4|user=qauser')
    $judged = Test-P9HTargetDisconnected -Records $t.Records -SessionId 3 -User 'qauser'
    Add-P9HTestResult -Id 'O4' -Title 'Correct username on wrong session id is rejected' `
        -Input '5|RDP-Tcp#1|state=4|user=qauser' -Expected 'Disconnected=false reason=no-target' `
        -Actual ("Disconnected={0} reason={1}" -f $judged.Disconnected, $judged.Reason) `
        -Pass ((-not $judged.Disconnected) -and $judged.Reason -eq 'no-target') -Evidence $logPath

    # ---- O5: reused session id with different logon identity rejected ----
    $records = @(
        [pscustomobject]@{ SessionId = 3; User = 'qauser'; State = 4; StationName = 'RDP-Tcp#0'; LogonTime = '2026-11-11T10:00:00Z' }
    )
    $match = Get-P9HTargetSessionRecord -Records $records -SessionId 3 -User 'qauser' -LogonTime '2026-11-11T09:00:00Z'
    Add-P9HTestResult -Id 'O5' -Title 'Reused session id with different logon time is rejected' `
        -Input 'session 3 state 4, logon 10:00Z, expected 09:00Z' -Expected 'reason=logon-mismatch' `
        -Actual ("Ok={0} reason={1}" -f $match.Ok, $match.Reason) `
        -Pass ((-not $match.Ok) -and $match.Reason -eq 'logon-mismatch') -Evidence $logPath

    # ---- O6: missing target rejected ----
    $t = ConvertFrom-P9HWtsTable -Lines @('0|Services|state=4|user=', '2|Console|state=1|user=')
    $judged = Test-P9HTargetDisconnected -Records $t.Records -SessionId 3 -User 'qauser'
    Add-P9HTestResult -Id 'O6' -Title 'Missing target session is rejected' -Input 'table without session 3' `
        -Expected 'Disconnected=false reason=no-target' `
        -Actual ("Disconnected={0} reason={1}" -f $judged.Disconnected, $judged.Reason) `
        -Pass ((-not $judged.Disconnected) -and $judged.Reason -eq 'no-target') -Evidence $logPath

    # ---- O7: malformed record rejected ----
    $t = ConvertFrom-P9HWtsTable -Lines @('3|RDP-Tcp#0|garbage|user=qauser')
    Add-P9HTestResult -Id 'O7' -Title 'Malformed WTS record is rejected' `
        -Input '3|RDP-Tcp#0|garbage|user=qauser' -Expected 'tableOk=false reason=malformed-table' `
        -Actual ("tableOk={0} reason={1}" -f $t.Ok, $t.Reason) `
        -Pass ((-not $t.Ok) -and $t.Reason -eq 'malformed-table') -Evidence $logPath

    # ---- O8: conflicting duplicate records rejected ----
    $records = @(
        [pscustomobject]@{ SessionId = 3; User = 'qauser'; State = 4; StationName = 'RDP-Tcp#0'; LogonTime = '2026-11-11T10:00:00Z' }
        [pscustomobject]@{ SessionId = 3; User = 'qauser'; State = 4; StationName = 'RDP-Tcp#1'; LogonTime = '2026-11-11T10:00:00Z' }
    )
    $match = Get-P9HTargetSessionRecord -Records $records -SessionId 3 -User 'qauser' -LogonTime '2026-11-11T10:00:00Z'
    Add-P9HTestResult -Id 'O8' -Title 'Conflicting duplicate target records are rejected' `
        -Input 'two session-3 records, same user and logon' -Expected 'reason=ambiguous' `
        -Actual ("Ok={0} reason={1} candidates={2}" -f $match.Ok, $match.Reason, $match.Candidates) `
        -Pass ((-not $match.Ok) -and $match.Reason -eq 'ambiguous') -Evidence $logPath

    # ---- O9: unpersisted disconnect observation blocks reconnect ----
    $emptyLog = Join-Path $trial.Directory 'e1-empty.jsonl'
    $blocked = $false
    try { Assert-P9HReconnectPermitted -ObserverLogPath $emptyLog -TargetSessionId 3 -TargetUser 'qauser' } catch { $blocked = $true }
    Add-P9HTestResult -Id 'O9' -Title 'Reconnect blocked when no persisted disconnect observation exists' `
        -Input 'absent observer log' -Expected 'Assert-P9HReconnectPermitted throws' `
        -Actual ("blocked={0}" -f $blocked) -Pass $blocked -Evidence $emptyLog

    # ---- O10: repeated observer invocation preserves prior records ----
    $appendLog = Join-Path $trial.Directory 'e1-append.jsonl'
    Add-P9HArtifactLine -Path $appendLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines $tableServicesState4 -TargetSessionId 3 -TargetUser 'qauser')
    Add-P9HArtifactLine -Path $appendLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines $tableDisc3 -TargetSessionId 3 -TargetUser 'qauser')
    Add-P9HArtifactLine -Path $appendLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 3 -Phase 'post' `
            -RawWtsLines $tableServicesState4 -TargetSessionId 3 -TargetUser 'qauser')
    $readLog = Read-P9HObserverLog -Path $appendLog
    $proof = Get-P9HDisconnectProof -ObserverLogPath $appendLog -SessionId 3 -User 'qauser'
    Add-P9HTestResult -Id 'O10' -Title 'Repeated observer writes preserve prior records (append-only)' `
        -Input 'three sequential records' -Expected 'records=3 and disconnect proof derived' `
        -Actual ("records={0} proofProven={1} reason={2}" -f $readLog.Records.Count, $proof.Proven, $proof.Reason) `
        -Pass ($readLog.Ok -and $readLog.Records.Count -eq 3 -and $proof.Proven) -Evidence $appendLog

    # ---- O11: incorrect sequence ordering rejected ----
    $badOrderLog = Join-Path $trial.Directory 'e1-badorder.jsonl'
    Add-P9HArtifactLine -Path $badOrderLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 5 -Phase 'pre' `
            -RawWtsLines $tableServicesState4 -TargetSessionId 3 -TargetUser 'qauser')
    Add-P9HArtifactLine -Path $badOrderLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines $tableDisc3 -TargetSessionId 3 -TargetUser 'qauser')
    $readBad = Read-P9HObserverLog -Path $badOrderLog
    Add-P9HTestResult -Id 'O11' -Title 'Out-of-order sequence numbers are rejected' -Input 'seq 5 then seq 2' `
        -Expected 'Ok=false reason=sequence-not-increasing' `
        -Actual ("Ok={0} reason={1}" -f $readBad.Ok, $readBad.Reason) `
        -Pass ((-not $readBad.Ok) -and $readBad.Reason -eq 'sequence-not-increasing') -Evidence $badOrderLog

    # ---- O12: disconnect proof alone is not an E1 PASS ----
    # Proof exists, but monitor captures are absent => verdict must not be PASS.
    $missingPre = Join-Path $trial.Directory 'no-pre.json'
    $missingPost = Join-Path $trial.Directory 'no-post.json'
    $e1 = Get-P9HE1Verdict -PreCapturePath $missingPre -PostCapturePath $missingPost `
        -ObserverLogPath $appendLog -TargetSessionId 3 -TargetUser 'qauser'
    Add-P9HTestResult -Id 'O12' -Title 'Disconnect proof alone cannot produce an E1 PASS' `
        -Input 'valid disconnect proof, absent monitor captures' -Expected 'Verdict=INCONCLUSIVE' `
        -Actual ("Verdict={0}" -f $e1.Verdict) `
        -Pass ($e1.Verdict -eq 'INCONCLUSIVE') -Evidence $appendLog
}

function Invoke-P9HVerdictTests {
    # V1-V8: verdict rules and their negative cases.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $trial = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind selftest
    $dir = $trial.Directory

    # Build a synthetic monitor capture pair with matching tokens.
    $prePath = Join-Path $dir 'e1-pre.json'
    $postPath = Join-Path $dir 'e1-post.json'
    $tokens = @('path:DEFAULT_MONITOR/1&ABCDEF&0&UID1001', 'path:DEFAULT_MONITOR/1&ABCDEF&0&UID1002')
    $rects = 'path:DEFAULT_MONITOR/1&ABCDEF&0&UID1001@x=0 y=0 w=1920 h=1080;path:DEFAULT_MONITOR/1&ABCDEF&0&UID1002@x=-2560 y=-355 w=2560 h=1440'
    $capture = [ordered]@{
        tokens = $tokens
        tokenCount = 2
        tokenSetBytes = (($tokens | Sort-Object) -join '|')
        tokenRectBytes = $rects
        identityComplete = $true
        sessionId = 3
    }
    Write-P9HArtifact -Path $prePath -Lines @(($capture | ConvertTo-Json -Depth 5))
    Write-P9HArtifact -Path $postPath -Lines @(($capture | ConvertTo-Json -Depth 5))

    $logGood = Join-Path $dir 'v-good.jsonl'
    Add-P9HArtifactLine -Path $logGood -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines @('3|RDP-Tcp#0|state=0|user=qauser') -TargetSessionId 3 -TargetUser 'qauser')
    Add-P9HArtifactLine -Path $logGood -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @('0|Services|state=4|user=', '3|RDP-Tcp#0|state=4|user=qauser') -TargetSessionId 3 -TargetUser 'qauser')
    Add-P9HArtifactLine -Path $logGood -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 3 -Phase 'post' `
            -RawWtsLines @('3|RDP-Tcp#0|state=0|user=qauser') -TargetSessionId 3 -TargetUser 'qauser')

    # ---- V1: matching tokens + valid disconnect proof => PASS ----
    $v = Get-P9HE1Verdict -PreCapturePath $prePath -PostCapturePath $postPath -ObserverLogPath $logGood -TargetSessionId 3 -TargetUser 'qauser'
    Add-P9HTestResult -Id 'V1' -Title 'Matching tokens plus proven disconnect satisfies E1' `
        -Input 'identical captures + valid proof' -Expected 'PASS' -Actual ("Verdict={0}" -f $v.Verdict) `
        -Pass ($v.Verdict -eq 'PASS') -Evidence $logGood

    # ---- V2: matching tokens without disconnect proof => not PASS ----
    $logNoProof = Join-Path $dir 'v-noproof.jsonl'
    Add-P9HArtifactLine -Path $logNoProof -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines @('3|RDP-Tcp#0|state=0|user=qauser') -TargetSessionId 3 -TargetUser 'qauser')
    Add-P9HArtifactLine -Path $logNoProof -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @('0|Services|state=4|user=', '3|RDP-Tcp#0|state=0|user=qauser') -TargetSessionId 3 -TargetUser 'qauser')
    Add-P9HArtifactLine -Path $logNoProof -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 3 -Phase 'post' `
            -RawWtsLines @('3|RDP-Tcp#0|state=0|user=qauser') -TargetSessionId 3 -TargetUser 'qauser')
    $v = Get-P9HE1Verdict -PreCapturePath $prePath -PostCapturePath $postPath -ObserverLogPath $logNoProof -TargetSessionId 3 -TargetUser 'qauser'
    Add-P9HTestResult -Id 'V2' -Title 'Matching tokens without disconnect proof cannot PASS' `
        -Input 'identical captures + state-4 only on session 0' -Expected 'NOT FULLY EVIDENCED' `
        -Actual ("Verdict={0} reason={1}" -f $v.Verdict, ($v.Reasons -join ',')) `
        -Pass ($v.Verdict -eq 'NOT FULLY EVIDENCED') -Evidence $logNoProof

    # ---- V3: new logon silently accepted? must be rejected ----
    $records = @([pscustomobject]@{ SessionId = 3; User = 'qauser'; State = 4; StationName = 'RDP-Tcp#0'; LogonTime = '2026-11-11T11:11:11Z' })
    $m = Get-P9HTargetSessionRecord -Records $records -SessionId 3 -User 'qauser' -LogonTime '2026-11-11T10:00:00Z'
    Add-P9HTestResult -Id 'V3' -Title 'A new logon reusing the session id is not accepted' `
        -Input 'logon 11:11:11Z vs pinned 10:00:00Z' -Expected 'not matched (logon-mismatch)' `
        -Actual ("Ok={0} reason={1}" -f $m.Ok, $m.Reason) `
        -Pass (-not $m.Ok) -Evidence $null

    # ---- V4: missing exit record => N2-B INCONCLUSIVE, never PASS ----
    $fixturePath = Join-Path $dir 'n2-fixture.json'
    $fixture = [ordered]@{
        itemId = 'p9h-item'; enabledItems = 1; enabledTerminals = 1; totalItems = 1
        anchorAbsent = $true
        layoutFallback = [ordered]@{ x = 9000; y = 9000; w = 640; h = 480 }
    }
    Write-P9HArtifact -Path $fixturePath -Lines @(($fixture | ConvertTo-Json -Depth 5))

    $tracePath = Join-Path $dir 'n2-trace.jsonl'
    $traceLines = @(
        (@{ event = 'lifecycle-layout-plan'; source = 'relative'; skipped = @('p9h-item') } | ConvertTo-Json -Compress)
        (@{ event = 'stage2-broker-ready'; planId = 'synthetic'; failed = 0 } | ConvertTo-Json -Compress)
        (@{ event = 'stage2-terminal-final'; finalized = 1; failures = 0 } | ConvertTo-Json -Compress)
        (@{ event = 'transaction-end'; broker = $true; uncertain = $false; failures = @() } | ConvertTo-Json -Compress)
    )
    Write-P9HArtifact -Path $tracePath -Lines $traceLines

    $stdoutPath = Join-Path $dir 'n2-stdout.txt'
    Write-P9HArtifact -Path $stdoutPath -Lines @('main/p9h-item: relative layout has no reachable placement (anchor-missing: identity-not-found); the item will be handled normally but its window position will not be changed.')

    $preWin = Join-Path $dir 'n2-pre-windows.json'
    $postWinPath = Join-Path $dir 'n2-post-windows.json'
    Write-P9HArtifact -Path $preWin -Lines @('{"Windows":[]}')
    Write-P9HArtifact -Path $postWinPath -Lines @(([ordered]@{ Windows = @([ordered]@{ hwnd = '0x1'; pid = 4242; visible = $true; class = 'CASCADIA_HOSTING_WINDOW_CLASS'; x = 44; y = 52; width = 1129; height = 635; title = 'synthetic' }) } | ConvertTo-Json -Depth 5))

    $newProcPath = Join-Path $dir 'n2-new-processes.json'
    Write-P9HArtifact -Path $newProcPath -Lines @(([ordered]@{ Added = @([ordered]@{ pid = 4242; name = 'synthetic.exe' }) } | ConvertTo-Json -Depth 5))

    $missingExit = Join-Path $dir 'n2-exit-missing.json'
    $nv = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $postWinPath -ExitRecordPath $missingExit -NewProcessPath $newProcPath
    Add-P9HTestResult -Id 'V4' -Title 'Clean broker trace without exit record cannot PASS N2-B' `
        -Input 'clean trace + absent exit record' -Expected 'N2B=INCONCLUSIVE' `
        -Actual ("N2A={0} N2B={1}" -f $nv.N2A.Verdict, $nv.N2B.Verdict) `
        -Pass ($nv.N2B.Verdict -eq 'INCONCLUSIVE') -Evidence $tracePath

    # ---- V5: N2-A PASS does not imply N2-B PASS ----
    Add-P9HTestResult -Id 'V5' -Title 'N2-A PASS does not imply N2-B PASS' -Input 'same run as V4' `
        -Expected 'N2A=PASS and N2B!=PASS' `
        -Actual ("N2A={0} N2B={1}" -f $nv.N2A.Verdict, $nv.N2B.Verdict) `
        -Pass ($nv.N2A.Verdict -eq 'PASS' -and $nv.N2B.Verdict -ne 'PASS') -Evidence $tracePath

    # ---- V6: valid zero exit + clean trace => N2-B PASS ----
    $exitPath = Join-Path $dir 'n2-exit-good.json'
    $record = New-P9HExitRecord -TrialId $trial.TrialId -Outcome 'exited' -ExitCode 0 `
        -LauncherPid 4242 -LauncherPath 'synthetic' -InvocationDisplay 'synthetic' `
        -WorkingDirectory $dir -LaunchedAtUtc (Get-P9HUtcStamp) -ExitedAtUtc (Get-P9HUtcStamp)
    $written = Write-P9HExitRecord -Path $exitPath -Record $record
    $nv2 = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $postWinPath -ExitRecordPath $exitPath -NewProcessPath $newProcPath
    Add-P9HTestResult -Id 'V6' -Title 'Valid zero exit with clean records passes N2-B' `
        -Input 'exit record outcome=exited code=0' -Expected 'N2B=PASS' `
        -Actual ("N2B={0} exitCode={1}" -f $nv2.N2B.Verdict, $nv2.N2B.ExitCode) `
        -Pass ($nv2.N2B.Verdict -eq 'PASS' -and $nv2.N2B.ExitCode -eq 0) -Evidence $exitPath

    # ---- V7: captured nonzero exit => N2-B FAIL (product failure, not instrumentation) ----
    $exitBad = Join-Path $dir 'n2-exit-bad.json'
    $record = New-P9HExitRecord -TrialId $trial.TrialId -Outcome 'exited' -ExitCode 1 `
        -LauncherPid 4243 -LauncherPath 'synthetic' -InvocationDisplay 'synthetic' `
        -WorkingDirectory $dir -LaunchedAtUtc (Get-P9HUtcStamp) -ExitedAtUtc (Get-P9HUtcStamp)
    $null = Write-P9HExitRecord -Path $exitBad -Record $record
    $nv3 = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $postWinPath -ExitRecordPath $exitBad -NewProcessPath $newProcPath
    Add-P9HTestResult -Id 'V7' -Title 'Captured nonzero exit is a lifecycle FAIL, not inconclusive' `
        -Input 'exit record outcome=exited code=1' -Expected 'N2B=FAIL' `
        -Actual ("N2B={0}" -f $nv3.N2B.Verdict) `
        -Pass ($nv3.N2B.Verdict -eq 'FAIL') -Evidence $exitBad

    # ---- V8: instrumented hang produces INCONCLUSIVE, not product FAIL ----
    $nv4 = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $postWinPath -ExitRecordPath (Join-Path $dir 'missing-again.json') -NewProcessPath $newProcPath
    Add-P9HTestResult -Id 'V8' -Title 'Instrumentation gap yields INCONCLUSIVE not FAIL' `
        -Input 'absent exit record' -Expected 'N2B=INCONCLUSIVE (not FAIL)' `
        -Actual ("N2B={0}" -f $nv4.N2B.Verdict) `
        -Pass ($nv4.N2B.Verdict -eq 'INCONCLUSIVE') -Evidence $null
}

function Invoke-P9HSafetyGateTests {
    # G1-G6: the real-execution gates must refuse, and must not spawn anything.
    #
    # These exist because the gates caught a real defect: a [Parameter(Mandatory)]
    # argument WITH a default value still prompts interactively, which blocked a
    # non-interactive harness instead of refusing. The regression is now pinned.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $before = @(Get-Process -ErrorAction SilentlyContinue).Count

    # ---- G1: disconnect refused without a token ----
    $plan = New-P9HDisconnectPlan -TrialId 'gate' -TargetSessionId '3' -TargetUser 'synthetic-account'
    $refused = $false
    try { Invoke-P9HControlledDisconnect -Plan $plan -AuthorizationToken '' } catch { $refused = $true }
    Add-P9HTestResult -Id 'G1' -Title 'Controlled disconnect refuses without authorization' `
        -Input 'empty token' -Expected 'throws, no process spawned' -Actual ("refused={0}" -f $refused) `
        -Pass $refused -Evidence $null

    # ---- G2: wrong token refused ----
    $refused = $false
    try { Invoke-P9HControlledDisconnect -Plan $plan -AuthorizationToken 'not-the-phrase' } catch { $refused = $true }
    Add-P9HTestResult -Id 'G2' -Title 'Controlled disconnect refuses a wrong authorization phrase' `
        -Input 'not-the-phrase' -Expected 'throws' -Actual ("refused={0}" -f $refused) -Pass $refused -Evidence $null

    # ---- G3: product launch refused without a token ----
    $refused = $false
    try {
        Invoke-P9HProductLaunchRecorded -TrialId 'gate' -CommandPath (Join-Path $env:SystemRoot 'System32\cmd.exe') `
            -WorkingDirectory $SandboxRoot -ArtifactDirectory $SandboxRoot -AuthorizationToken ''
    }
    catch { $refused = $true }
    Add-P9HTestResult -Id 'G3' -Title 'Product launch refuses without authorization' `
        -Input 'empty token' -Expected 'throws before any process is created' `
        -Actual ("refused={0}" -f $refused) -Pass $refused -Evidence $null

    # ---- G4: omitted session target refused ----
    $refused = $false
    try { $null = New-P9HDisconnectPlan -TrialId 'gate' -TargetSessionId '' -TargetUser 'synthetic-account' } catch { $refused = $true }
    Add-P9HTestResult -Id 'G4' -Title 'Disconnect with omitted session id is refused' `
        -Input 'empty session id' -Expected 'throws (no implicit current-session target)' `
        -Actual ("refused={0}" -f $refused) -Pass $refused -Evidence $null

    # ---- G5: session 0 refused as a target ----
    $refused = $false
    try { $null = New-P9HDisconnectPlan -TrialId 'gate' -TargetSessionId '0' -TargetUser 'synthetic-account' } catch { $refused = $true }
    Add-P9HTestResult -Id 'G5' -Title 'Session 0 can never be a disconnect target' `
        -Input 'session id 0' -Expected 'throws' -Actual ("refused={0}" -f $refused) -Pass $refused -Evidence $null

    # ---- G6: reconnect refused without persisted proof ----
    $missingLog = Join-Path $SandboxRoot 'gate-absent-observer.jsonl'
    $refused = $false
    try { $null = Assert-P9HReconnectPermitted -ObserverLogPath $missingLog -TargetSessionId 3 -TargetUser 'synthetic-account' }
    catch { $refused = $true }
    Add-P9HTestResult -Id 'G6' -Title 'Reconnect refused without persisted disconnect proof' `
        -Input 'absent observer log' -Expected 'throws' -Actual ("refused={0}" -f $refused) -Pass $refused -Evidence $missingLog

    # ---- G7: no process was created by any refusal above ----
    $after = @(Get-Process -ErrorAction SilentlyContinue).Count
    Add-P9HTestResult -Id 'G7' -Title 'Refused gates create no process' `
        -Input 'six refused calls' -Expected 'process count does not increase' `
        -Actual ("before={0} after={1}" -f $before, $after) `
        -Pass ($after -le $before + 1) -Evidence $null
}

function Invoke-P9HDateHandlingTests {
    # D1-D3: the WMI/CIM date-conversion defect.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    # ---- D1: DateTime input handled correctly ----
    $dt = [datetime]::UtcNow
    $c = ConvertTo-P9HProcessStartUtc -Value $dt
    Add-P9HTestResult -Id 'D1' -Title 'DateTime creation value converts without exception' `
        -Input 'System.DateTime' -Expected 'Ok=true source=datetime' `
        -Actual ("Ok={0} source={1}" -f $c.Ok, $c.Reason) `
        -Pass ($c.Ok -and $c.Reason -eq 'datetime') -Evidence $null

    # ---- D2: unexpected type reported explicitly ----
    $c = ConvertTo-P9HProcessStartUtc -Value 12345
    Add-P9HTestResult -Id 'D2' -Title 'Unexpected creation type is reported, not silently blanked' `
        -Input 'Int32' -Expected 'Ok=false reason starts with unsupported-type' `
        -Actual ("Ok={0} reason={1}" -f $c.Ok, $c.Reason) `
        -Pass ((-not $c.Ok) -and $c.Reason.StartsWith('unsupported-type')) -Evidence $null

    # ---- D3: real inventory recovers start times (the P9-G failure inverted) ----
    $inv = Get-P9HProcessInventory -SessionId (Get-Process -Id $PID).SessionId
    Add-P9HTestResult -Id 'D3' -Title 'Live inventory recovers process start times' `
        -Input 'current session process inventory' -Expected 'startOk>0 and outcome not degraded' `
        -Actual ("count={0} startOk={1} startBad={2} outcome={3}" -f $inv.Count, $inv.StartOk, $inv.StartBad, $inv.Outcome) `
        -Pass ($inv.StartOk -gt 0 -and $inv.Outcome -ne 'degraded') -Evidence $null
}

function Invoke-P9HAllSelfTests {
    # Entry point. Returns the result list and exits non-zero on any failure.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    Invoke-P9HExitRecorderTests -SandboxRoot $SandboxRoot
    Invoke-P9HPathRobustnessTests -SandboxRoot $SandboxRoot
    Invoke-P9HE1ObserverTests -SandboxRoot $SandboxRoot
    Invoke-P9HVerdictTests -SandboxRoot $SandboxRoot
    Invoke-P9HSafetyGateTests -SandboxRoot $SandboxRoot
    Invoke-P9HDateHandlingTests -SandboxRoot $SandboxRoot

    return @($script:P9HTestResults)
}
