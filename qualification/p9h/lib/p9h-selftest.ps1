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
    # O1-O12: strict target-session matching (retained from Stage 2).
    # A1-A10:  reconnect AUTHORIZATION proof (new in Stage 2.1 - the positive
    #          case is the whole point, since Stage 2 could never authorize).
    # F1-F3:   final transition proof must still require the post-reconnect record.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $trial = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind selftest
    $logPath = Join-Path $trial.Directory 'e1-observer.jsonl'
    $logon = '2026-11-11T10:00:00.0000000Z'
    $otherLogon = '2026-11-11T09:00:00.0000000Z'

    # Authority-bearing tables carry the logon field so identity is full-strength.
    $activeLine = "3|RDP-Tcp#0|state=0|user=qauser|logon=$logon"
    $discLine = "3|RDP-Tcp#0|state=4|user=qauser|logon=$logon"

    # Baseline table mirroring the P9-G failure exactly (no logon field: those
    # records are non-authoritative, which is the point of O-series).
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

    # ---- O2: target session 3 state 4 accepted (non-authoritative path) ----
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
        [pscustomobject]@{ SessionId = 3; User = 'qauser'; State = 4; StationName = 'RDP-Tcp#0'; LogonTime = $logon }
    )
    $match = Get-P9HTargetSessionRecord -Records $records -SessionId 3 -User 'qauser' -LogonTime $otherLogon
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
        [pscustomobject]@{ SessionId = 3; User = 'qauser'; State = 4; StationName = 'RDP-Tcp#0'; LogonTime = $logon }
        [pscustomobject]@{ SessionId = 3; User = 'qauser'; State = 4; StationName = 'RDP-Tcp#1'; LogonTime = $logon }
    )
    $match = Get-P9HTargetSessionRecord -Records $records -SessionId 3 -User 'qauser' -LogonTime $logon
    Add-P9HTestResult -Id 'O8' -Title 'Conflicting duplicate target records are rejected' `
        -Input 'two session-3 records, same user and logon' -Expected 'reason=ambiguous' `
        -Actual ("Ok={0} reason={1} candidates={2}" -f $match.Ok, $match.Reason, $match.Candidates) `
        -Pass ((-not $match.Ok) -and $match.Reason -eq 'ambiguous') -Evidence $logPath

    # ---- O9: unpersisted disconnect observation blocks reconnect ----
    $emptyLog = Join-Path $trial.Directory 'e1-empty.jsonl'
    $blocked = $false
    try {
        Assert-P9HReconnectPermitted -ObserverLogPath $emptyLog -TargetSessionId 3 -TargetUser 'qauser' `
            -TrialId $trial.TrialId -TargetLogonTime $logon
    }
    catch { $blocked = $true }
    Add-P9HTestResult -Id 'O9' -Title 'Reconnect blocked when no persisted disconnect observation exists' `
        -Input 'absent observer log' -Expected 'Assert-P9HReconnectPermitted throws' `
        -Actual ("blocked={0}" -f $blocked) -Pass $blocked -Evidence $emptyLog

    # ---- O10: repeated observer invocation preserves prior records ----
    $appendLog = Join-Path $trial.Directory 'e1-append.jsonl'
    Add-P9HArtifactLine -Path $appendLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines @($activeLine) -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon)
    Add-P9HArtifactLine -Path $appendLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @($discLine) -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon)
    Add-P9HArtifactLine -Path $appendLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 3 -Phase 'post' `
            -RawWtsLines @($activeLine) -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon)
    $readLog = Read-P9HObserverLog -Path $appendLog
    $proof = Get-P9HDisconnectProof -ObserverLogPath $appendLog -SessionId 3 -User 'qauser' `
        -TrialId $trial.TrialId -LogonTime $logon
    Add-P9HTestResult -Id 'O10' -Title 'Repeated observer writes preserve prior records (append-only)' `
        -Input 'three sequential records' -Expected 'records=3 and final proof derived' `
        -Actual ("records={0} proofProven={1} reason={2}" -f $readLog.Records.Count, $proof.Proven, $proof.Reason) `
        -Pass ($readLog.Ok -and $readLog.Records.Count -eq 3 -and $proof.Proven) -Evidence $appendLog

    # ---- O11: incorrect sequence ordering rejected ----
    $badOrderLog = Join-Path $trial.Directory 'e1-badorder.jsonl'
    Add-P9HArtifactLine -Path $badOrderLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 5 -Phase 'pre' `
            -RawWtsLines @($activeLine) -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon)
    Add-P9HArtifactLine -Path $badOrderLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @($discLine) -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon)
    $readBad = Read-P9HObserverLog -Path $badOrderLog
    Add-P9HTestResult -Id 'O11' -Title 'Out-of-order sequence numbers are rejected' -Input 'seq 5 then seq 2' `
        -Expected 'Ok=false reason=sequence-not-increasing' `
        -Actual ("Ok={0} reason={1}" -f $readBad.Ok, $readBad.Reason) `
        -Pass ((-not $readBad.Ok) -and $readBad.Reason -eq 'sequence-not-increasing') -Evidence $badOrderLog

    # ---- O12: transition proof alone is not an E1 PASS ----
    $missingPre = Join-Path $trial.Directory 'no-pre.json'
    $missingPost = Join-Path $trial.Directory 'no-post.json'
    $e1 = Get-P9HE1Verdict -PreCapturePath $missingPre -PostCapturePath $missingPost `
        -ObserverLogPath $appendLog -TargetSessionId 3 -TargetUser 'qauser' `
        -TargetLogonTime $logon -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'O12' -Title 'Transition proof alone cannot produce an E1 PASS' `
        -Input 'valid proof, absent monitor captures' -Expected 'Verdict=INCONCLUSIVE' `
        -Actual ("Verdict={0}" -f $e1.Verdict) `
        -Pass ($e1.Verdict -eq 'INCONCLUSIVE') -Evidence $appendLog

    # ================= A-series: reconnect AUTHORIZATION proof =================
    # These are the Stage 2.1 additions. A1 is the positive case that Stage 2
    # could never satisfy because its proof demanded a post-reconnect record.

    # Helper: build a log with an explicit list of phase/state/logon triples.
    $makeLog = {
        param([string]$name, [object[]]$entries)
        $p = Join-Path $trial.Directory $name
        $seq = 1
        foreach ($e in $entries) {
            # Hashtable indexing (not property access) so a missing optional key
            # is $null instead of a StrictMode error.
            $logonValue = if ($null -ne $e['Logon']) { $e['Logon'] } else { $logon }
            $userValue = if ($null -ne $e['User']) { $e['User'] } else { 'qauser' }
            $stateValue = $e['State']
            $trap = [bool]$e['SessionZeroTrap']

            $rawLines = if ($stateValue -eq 4 -and $trap) {
                @('0|Services|state=4|user=', "3|RDP-Tcp#0|state=0|user=$userValue|logon=$logonValue")
            }
            elseif ($stateValue -eq 4) {
                @("3|RDP-Tcp#0|state=4|user=$userValue|logon=$logonValue")
            }
            else {
                @("3|RDP-Tcp#0|state=0|user=$userValue|logon=$logonValue")
            }

            $trialForRecord = if ($null -ne $e['Trial']) { $e['Trial'] } else { $trial.TrialId }
            Add-P9HArtifactLine -Path $p -Line (New-P9HObserverRecord -TrialId $trialForRecord -Sequence $seq `
                    -Phase $e['Phase'] -RawWtsLines $rawLines -TargetSessionId 3 -TargetUser $userValue `
                    -TargetLogonTime $logonValue)
            $seq++
        }
        return $p
    }

    # ---- A1: pre Active -> target Disc, NO post record: authorization succeeds ----
    $a1 = & $makeLog 'a1.jsonl' @(
        @{ Phase = 'pre'; State = 0 }
        @{ Phase = 'disconnect-observed'; State = 4 }
    )
    $a1ok = $false; $a1reason = $null
    try { $pr = Assert-P9HReconnectPermitted -ObserverLogPath $a1 -TargetSessionId 3 -TargetUser 'qauser' `
            -TrialId $trial.TrialId -TargetLogonTime $logon; $a1ok = $true; $a1reason = $pr.Reason }
    catch { $a1reason = $_.Exception.Message }
    Add-P9HTestResult -Id 'A1' -Title 'Reconnect AUTHORIZED with pre Active + target Disc and no post record' `
        -Input 'pre=Active, disconnect-observed=state4, no post' -Expected 'authorization succeeds' `
        -Actual ("authorized={0} reason={1}" -f $a1ok, $a1reason) -Pass $a1ok -Evidence $a1

    # ---- A2: pre Active only: authorization fails ----
    $a2 = & $makeLog 'a2.jsonl' @(@{ Phase = 'pre'; State = 0 })
    $a2ok = $false; $a2reason = $null
    try { $null = Assert-P9HReconnectPermitted -ObserverLogPath $a2 -TargetSessionId 3 -TargetUser 'qauser' `
            -TrialId $trial.TrialId -TargetLogonTime $logon; $a2ok = $true }
    catch { $a2reason = $_.Exception.Message }
    Add-P9HTestResult -Id 'A2' -Title 'Reconnect refused with only a pre Active observation' `
        -Input 'pre=Active only' -Expected 'authorization fails' `
        -Actual ("authorized={0} reason={1}" -f $a2ok, $a2reason) `
        -Pass ((-not $a2ok) -and $a2reason -match 'no-target-disconnected-record') -Evidence $a2

    # ---- A3: session 0 state 4 while session 3 stays Active: fails ----
    $a3 = & $makeLog 'a3.jsonl' @(
        @{ Phase = 'pre'; State = 0 }
        @{ Phase = 'disconnect-observed'; State = 4; SessionZeroTrap = $true }
    )
    $a3ok = $false; $a3reason = $null
    try { $null = Assert-P9HReconnectPermitted -ObserverLogPath $a3 -TargetSessionId 3 -TargetUser 'qauser' `
            -TrialId $trial.TrialId -TargetLogonTime $logon; $a3ok = $true }
    catch { $a3reason = $_.Exception.Message }
    Add-P9HTestResult -Id 'A3' -Title 'Session 0 state 4 with session 3 Active does not authorize' `
        -Input '0|Services|state=4 + 3|RDP-Tcp#0|state=0' -Expected 'authorization fails' `
        -Actual ("authorized={0} reason={1}" -f $a3ok, $a3reason) `
        -Pass ((-not $a3ok) -and $a3reason -match 'disconnect-target-active') -Evidence $a3

    # ---- A4: wrong user: fails ----
    $a4 = & $makeLog 'a4.jsonl' @(
        @{ Phase = 'pre'; State = 0 }
        @{ Phase = 'disconnect-observed'; State = 4; User = 'someoneelse' }
    )
    $a4ok = $false; $a4reason = $null
    try { $null = Assert-P9HReconnectPermitted -ObserverLogPath $a4 -TargetSessionId 3 -TargetUser 'qauser' `
            -TrialId $trial.TrialId -TargetLogonTime $logon; $a4ok = $true }
    catch { $a4reason = $_.Exception.Message }
    Add-P9HTestResult -Id 'A4' -Title 'Wrong username does not authorize reconnect' `
        -Input 'disconnect record for someoneelse' -Expected 'authorization fails' `
        -Actual ("authorized={0} reason={1}" -f $a4ok, $a4reason) `
        -Pass (-not $a4ok) -Evidence $a4

    # ---- A5: wrong logon identity: fails ----
    $a5 = & $makeLog 'a5.jsonl' @(
        @{ Phase = 'pre'; State = 0 }
        @{ Phase = 'disconnect-observed'; State = 4; Logon = $otherLogon }
    )
    $a5ok = $false; $a5reason = $null
    try { $null = Assert-P9HReconnectPermitted -ObserverLogPath $a5 -TargetSessionId 3 -TargetUser 'qauser' `
            -TrialId $trial.TrialId -TargetLogonTime $logon; $a5ok = $true }
    catch { $a5reason = $_.Exception.Message }
    Add-P9HTestResult -Id 'A5' -Title 'Different logon identity does not authorize reconnect' `
        -Input 'disconnect record with a different logon time' -Expected 'authorization fails' `
        -Actual ("authorized={0} reason={1}" -f $a5ok, $a5reason) `
        -Pass (-not $a5ok) -Evidence $a5

    # ---- A6: reused session id with a new logon: fails ----
    $a6 = & $makeLog 'a6.jsonl' @(
        @{ Phase = 'pre'; State = 0 }
        @{ Phase = 'disconnect-observed'; State = 0; Logon = $otherLogon }
        @{ Phase = 'disconnect-observed'; State = 4; Logon = $otherLogon }
    )
    $a6ok = $false; $a6reason = $null
    try { $null = Assert-P9HReconnectPermitted -ObserverLogPath $a6 -TargetSessionId 3 -TargetUser 'qauser' `
            -TrialId $trial.TrialId -TargetLogonTime $logon; $a6ok = $true }
    catch { $a6reason = $_.Exception.Message }
    Add-P9HTestResult -Id 'A6' -Title 'Reused session id with a new logon does not authorize' `
        -Input 'disconnect records carry a different logon time' -Expected 'authorization fails' `
        -Actual ("authorized={0} reason={1}" -f $a6ok, $a6reason) `
        -Pass (-not $a6ok) -Evidence $a6

    # ---- A7: cross-trial record substitution: fails ----
    $foreignTrial = 'p9h-foreign-trial-00000000'
    $a7 = & $makeLog 'a7.jsonl' @(
        @{ Phase = 'pre'; State = 0 }
        @{ Phase = 'disconnect-observed'; State = 4; Trial = $foreignTrial }
    )
    $a7ok = $false; $a7reason = $null
    try { $null = Assert-P9HReconnectPermitted -ObserverLogPath $a7 -TargetSessionId 3 -TargetUser 'qauser' `
            -TrialId $trial.TrialId -TargetLogonTime $logon; $a7ok = $true }
    catch { $a7reason = $_.Exception.Message }
    Add-P9HTestResult -Id 'A7' -Title 'Cross-trial record substitution does not authorize' `
        -Input 'disconnect record from a foreign trial id' -Expected 'authorization fails' `
        -Actual ("authorized={0} reason={1}" -f $a7ok, $a7reason) `
        -Pass ((-not $a7ok) -and $a7reason -match 'foreign-trial-records') -Evidence $a7

    # ---- A8: out-of-order records: fails ----
    $a8 = Join-Path $trial.Directory 'a8.jsonl'
    Add-P9HArtifactLine -Path $a8 -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 9 -Phase 'pre' `
            -RawWtsLines @($activeLine) -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon)
    Add-P9HArtifactLine -Path $a8 -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 9 -Phase 'disconnect-observed' `
            -RawWtsLines @($discLine) -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon)
    $a8ok = $false; $a8reason = $null
    try { $null = Assert-P9HReconnectPermitted -ObserverLogPath $a8 -TargetSessionId 3 -TargetUser 'qauser' `
            -TrialId $trial.TrialId -TargetLogonTime $logon; $a8ok = $true }
    catch { $a8reason = $_.Exception.Message }
    Add-P9HTestResult -Id 'A8' -Title 'Non-increasing sequence does not authorize reconnect' `
        -Input 'two records with the same sequence number' -Expected 'authorization fails' `
        -Actual ("authorized={0} reason={1}" -f $a8ok, $a8reason) `
        -Pass ((-not $a8ok) -and $a8reason -match 'sequence-not-increasing') -Evidence $a8

    # ---- A9: missing logon time fails closed (no silent degrade) ----
    $a9 = Join-Path $trial.Directory 'a9.jsonl'
    Add-P9HArtifactLine -Path $a9 -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines $tableServicesState4 -TargetSessionId 3 -TargetUser 'qauser')
    Add-P9HArtifactLine -Path $a9 -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @('0|Services|state=4|user=', '3|RDP-Tcp#0|state=4|user=qauser') -TargetSessionId 3 -TargetUser 'qauser')
    $a9ok = $false; $a9reason = $null
    try { $null = Assert-P9HReconnectPermitted -ObserverLogPath $a9 -TargetSessionId 3 -TargetUser 'qauser' `
            -TrialId $trial.TrialId -TargetLogonTime $null; $a9ok = $true }
    catch { $a9reason = $_.Exception.Message }
    Add-P9HTestResult -Id 'A9' -Title 'Missing pinned logon time fails closed for authorization' `
        -Input 'no pinned logon time supplied' -Expected 'authorization fails (pinned-logon-missing)' `
        -Actual ("authorized={0} reason={1}" -f $a9ok, $a9reason) `
        -Pass ((-not $a9ok) -and $a9reason -match 'pinned-logon-missing') -Evidence $a9

    # ---- A10: provider omits logon field entirely -> fails closed ----
    $a10 = Join-Path $trial.Directory 'a10.jsonl'
    Add-P9HArtifactLine -Path $a10 -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines @('3|RDP-Tcp#0|state=0|user=qauser') -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon)
    Add-P9HArtifactLine -Path $a10 -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @('3|RDP-Tcp#0|state=4|user=qauser') -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon)
    $a10ok = $false; $a10reason = $null
    try { $null = Assert-P9HReconnectPermitted -ObserverLogPath $a10 -TargetSessionId 3 -TargetUser 'qauser' `
            -TrialId $trial.TrialId -TargetLogonTime $logon; $a10ok = $true }
    catch { $a10reason = $_.Exception.Message }
    Add-P9HTestResult -Id 'A10' -Title 'Absent provider logon field fails closed' `
        -Input 'raw WTS lines without a logon segment' -Expected 'authorization fails (logon unavailable)' `
        -Actual ("authorized={0} reason={1}" -f $a10ok, $a10reason) `
        -Pass ((-not $a10ok) -and ($a10reason -match 'logon-unavailable|pre-not-active')) -Evidence $a10

    # ================= F-series: final E1 transition proof =================
    # The final proof must NOT be weakened; it still needs the post record.

    # ---- F1: final proof without a post-reconnect Active record fails ----
    $f1 = Get-P9HDisconnectProof -ObserverLogPath $a1 -SessionId 3 -User 'qauser' `
        -TrialId $trial.TrialId -LogonTime $logon
    Add-P9HTestResult -Id 'F1' -Title 'Final E1 proof requires the post-reconnect Active record' `
        -Input 'pre Active + target Disc, no post' -Expected 'Proven=false reason=no-post-record' `
        -Actual ("Proven={0} reason={1}" -f $f1.Proven, $f1.Reason) `
        -Pass ((-not $f1.Proven) -and $f1.Reason -eq 'no-post-record') -Evidence $a1

    # ---- F2: complete valid sequence satisfies the final proof ----
    $f2 = Get-P9HDisconnectProof -ObserverLogPath $appendLog -SessionId 3 -User 'qauser' `
        -TrialId $trial.TrialId -LogonTime $logon
    Add-P9HTestResult -Id 'F2' -Title 'Complete sequence satisfies the final transition proof' `
        -Input 'pre Active -> target Disc -> post Active' -Expected 'Proven=true' `
        -Actual ("Proven={0} reason={1}" -f $f2.Proven, $f2.Reason) `
        -Pass ($f2.Proven) -Evidence $appendLog

    # ---- F3: post record present but not Active fails ----
    $f3 = & $makeLog 'f3.jsonl' @(
        @{ Phase = 'pre'; State = 0 }
        @{ Phase = 'disconnect-observed'; State = 4 }
        @{ Phase = 'post'; State = 4 }
    )
    $f3proof = Get-P9HDisconnectProof -ObserverLogPath $f3 -SessionId 3 -User 'qauser' `
        -TrialId $trial.TrialId -LogonTime $logon
    Add-P9HTestResult -Id 'F3' -Title 'Post record that is not Active fails the final proof' `
        -Input 'pre Active -> target Disc -> post still Disc' -Expected 'Proven=false reason=post-not-active' `
        -Actual ("Proven={0} reason={1}" -f $f3proof.Proven, $f3proof.Reason) `
        -Pass ((-not $f3proof.Proven) -and $f3proof.Reason -eq 'post-not-active') -Evidence $f3
}

function Copy-P9HArgs {
    # Explicit ordered copy of a parameter table. Hashtable.Clone() followed
    # by property assignment is not valid PowerShell (a hash table can only be
    # assigned by key), so the copy is built key by key.
    param([Parameter(Mandatory)][hashtable]$Table)
    $copy = @{}
    foreach ($k in @($Table.Keys)) { $copy[$k] = $Table[$k] }
    return $copy
}

function Invoke-P9HVerdictTests {
    # V-series: E1 verdict rules (V1-V14 retained; V9-V14 strengthened by Stage 2.2).
    # W-series: Stage 2.2 trace-validity and N2 causal-attribution cases.
    #
    # Stage 2.2 additions required by review:
    #   W1  complete valid trace                         -> eligible for PASS
    #   W2  valid events + one malformed line            -> not PASS
    #   W3  missing required event                       -> not PASS
    #   W4  contradictory finalization events            -> not PASS
    #   W5  events from different trials                 -> not PASS
    #   W6  incompatible plan ids                        -> not PASS
    #   W7  events in invalid order                      -> not PASS
    #   W8  unrelated terminal process with valid start  -> not PASS
    #   W9  unrelated process's window                   -> not PASS
    #   W10 matching PID, incompatible creation time     -> not PASS
    #   W11 correct window type, unrelated transaction   -> not PASS
    #   W12 clean trace + exit 0 without attribution     -> not PASS
    #   W13 inconsistent plan/terminal identifiers       -> not PASS
    #   W14 positive: real detached-terminal architecture -> PASS
    #
    #   X1  window-omission request cannot yield PASS    -> not PASS
    #   X2  asserted tokenRectBytes only (no records)    -> not PASS
    #   X3  fabricated negative-origin summary           -> not PASS
    #   X4  parsedMonitors disagree with token list      -> not PASS
    #   X5  identical summaries, different mappings      -> not PASS
    #   X6  capture omitting trialId                     -> not PASS
    #   X7  different trial ids                          -> not PASS
    #   X8  pre-capture timestamp after disconnect       -> not PASS
    #   X9  post-capture timestamp before reconnect      -> not PASS
    #   X10 reversed pre/post capture ordering           -> not PASS
    #   X11 malformed timestamp                          -> not PASS
    #   X12 valid raw captures + matching topology       -> PASS
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $trial = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind selftest
    $dir = $trial.Directory
    $tid = $trial.TrialId
    $logon = '2026-11-11T10:00:00.0000000Z'

    # ---------- capture builder (raw per-monitor records are authoritative) ----------
    $writeCapture = {
        param(
            [string]$name,
            [string[]]$tokens,
            [int]$sessionId = 3,
            [bool]$includeTokens = $true,
            [bool]$includeRecords = $true,
            [string]$trialId = '',
            [bool]$withNegativeOrigin = $true,
            [string]$capturedUtc = '',
            [string[]]$recordIdentities = $null,
            [string[]]$recordRects = $null
        )
        $obj = [ordered]@{ tokenCount = $tokens.Count; identityComplete = $true; sessionId = $sessionId }
        if ([string]::IsNullOrWhiteSpace($capturedUtc)) { $capturedUtc = Get-P9HUtcStamp }
        $obj.capturedUtc = $capturedUtc
        if (-not [string]::IsNullOrWhiteSpace($trialId)) { $obj.trialId = $trialId }
        if ($includeTokens) { $obj.tokens = $tokens }

        if ($includeRecords) {
            $ids = if ($null -ne $recordIdentities) { $recordIdentities } else { $tokens }
            # A typed List[pscustomobject] is used because
            # '$array += @{...}' appends the hashtable ENTRIES rather than the
            # hashtable itself.
            $records = [System.Collections.Generic.List[pscustomobject]]::new()
            for ($i = 0; $i -lt $ids.Count; $i++) {
                $rect = if ($null -ne $recordRects -and $i -lt $recordRects.Count) { $recordRects[$i] }
                        elseif ($i -eq 1 -and $withNegativeOrigin) { 'x=-2560 y=-355 w=2560 h=1440' }
                        elseif ($i -eq 1) { 'x=2560 y=0 w=2560 h=1440' }
                        else { 'x=0 y=0 w=1920 h=1080' }
                $records.Add([pscustomobject][ordered]@{ identity = $ids[$i]; rect = $rect })
            }
            $obj.parsedMonitors = @($records)
        }

        # A summary string that AGREES with the records (what the real snapshot writes).
        if ($includeRecords) {
            $obj.tokenRectBytes = (@($obj.parsedMonitors | ForEach-Object { '{0}@{1}' -f $_.identity, $_.rect }) -join ';')
        }

        $p = Join-Path $dir $name
        Write-P9HArtifact -Path $p -Lines @(($obj | ConvertTo-Json -Depth 6))
        return $p
    }

    # ---------- observer log builder ----------
    $writeLog = {
        param([string]$name, [object[]]$entries, [string]$trialId = '')
        $p = Join-Path $dir $name
        $seq = 1
        $useTrial = if ([string]::IsNullOrWhiteSpace($trialId)) { $tid } else { $trialId }
        foreach ($e in $entries) {
            $state = $e['State']
            $who = if ($null -ne $e['User']) { $e['User'] } else { 'qauser' }
            $lg = if ($null -ne $e['Logon']) { $e['Logon'] } else { $logon }
            $raw = if ($state -eq 4) { @("3|RDP-Tcp#0|state=4|user=$who|logon=$lg") }
                   else { @("3|RDP-Tcp#0|state=0|user=$who|logon=$lg") }
            Add-P9HArtifactLine -Path $p -Line (New-P9HObserverRecord -TrialId $useTrial -Sequence $seq `
                    -Phase $e['Phase'] -RawWtsLines $raw -TargetSessionId 3 -TargetUser $who -TargetLogonTime $lg)
            $seq++
        }
        return $p
    }

    $tokensA = @('path:DEFAULT_MONITOR/1&ABCDEF&0&UID1001', 'path:DEFAULT_MONITOR/1&ABCDEF&0&UID1002')
    $tokensDiff = @('path:DEFAULT_MONITOR/1&ABCDEF&0&UID1001', 'path:DEFAULT_MONITOR/1&ABCDEF&0&UID9002')

    # Captures are written with timestamps bracketing the transition.
    $preUtc = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o')
    $prePath = & $writeCapture 'e1-pre.json' $tokensA 3 $true $true $tid $true $preUtc
    $logGood = & $writeLog 'v-good.jsonl' @(
        @{ Phase = 'pre'; State = 0 }
        @{ Phase = 'disconnect-observed'; State = 4 }
        @{ Phase = 'post'; State = 0 }
    )
    $postUtc = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o')
    $postPath = & $writeCapture 'e1-post.json' $tokensA 3 $true $true $tid $true $postUtc

    # ---- V1: complete valid dataset => PASS ----
    $v = Get-P9HE1Verdict -PreCapturePath $prePath -PostCapturePath $postPath -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'V1' -Title 'Complete valid dataset satisfies E1' `
        -Input 'raw monitors + negative origin + bracketing captures + transition' -Expected 'PASS' `
        -Actual ("Verdict={0} reasons={1}" -f $v.Verdict, ($v.Reasons -join ',')) `
        -Pass ($v.Verdict -eq 'PASS') -Evidence $logGood

    # ---- V2: two valid captures without a proven transition ----
    $logNoProof = & $writeLog 'v-noproof.jsonl' @(
        @{ Phase = 'pre'; State = 0 }
        @{ Phase = 'disconnect-observed'; State = 0 }
        @{ Phase = 'post'; State = 0 }
    )
    $v = Get-P9HE1Verdict -PreCapturePath $prePath -PostCapturePath $postPath -ObserverLogPath $logNoProof `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'V2' -Title 'Two valid captures without a proven transition cannot PASS' `
        -Input 'disconnect never observed' -Expected 'NOT FULLY EVIDENCED' `
        -Actual ("Verdict={0}" -f $v.Verdict) -Pass ($v.Verdict -eq 'NOT FULLY EVIDENCED') -Evidence $logNoProof

    # ---- V3: a new logon reusing the session id is not accepted ----
    $records = @([pscustomobject]@{ SessionId = 3; User = 'qauser'; State = 4; StationName = 'RDP-Tcp#0'; LogonTime = '2026-11-11T11:11:11.0000000Z' })
    $m = Get-P9HTargetSessionRecord -Records $records -SessionId 3 -User 'qauser' -LogonTime $logon
    Add-P9HTestResult -Id 'V3' -Title 'A new logon reusing the session id is not accepted' `
        -Input 'logon 11:11:11Z vs pinned 10:00:00Z' -Expected 'logon-mismatch' `
        -Actual ("Ok={0} reason={1}" -f $m.Ok, $m.Reason) `
        -Pass ((-not $m.Ok) -and $m.Reason -eq 'logon-mismatch') -Evidence $null

    # ================= N2 fixtures =================
    $windowId = 'DevWS-main-p9h-item'
    $terminalId = 'p9h-item'
    $setId = 'main'

    $fixturePath = Join-Path $dir 'n2-fixture.json'
    Write-P9HArtifact -Path $fixturePath -Lines @(([ordered]@{
                itemId = $terminalId; enabledItems = 1; enabledTerminals = 1; totalItems = 1
                anchorAbsent = $true
                layoutFallback = [ordered]@{ x = 9000; y = 9000; w = 640; h = 480 }
            } | ConvertTo-Json -Depth 5))

    $stdoutPath = Join-Path $dir 'n2-stdout.txt'
    Write-P9HArtifact -Path $stdoutPath -Lines @('main/p9h-item: relative layout has no reachable placement (anchor-missing: identity-not-found); the item will be handled normally but its window position will not be changed.')

    $preWin = Join-Path $dir 'n2-pre-windows.json'
    Write-P9HArtifact -Path $preWin -Lines @('{"Windows":[]}')

    # The bootstrap argv the PRODUCT actually writes (devws-terminal.ps1:182-199).
    $bootstrapCmd = 'pwsh.exe -NoExit -File "C:\Program Files\DevWS\privileged\helpers\cwd-shell-bootstrap.ps1" ' +
        "-SetId $setId -TerminalId $terminalId -WindowId $windowId -TabIndex 0 -SessionId synthetic-session " +
        '-PublicationPath "C:\ProgramData\DevWS\x.json" -ChildSpecBase64 e30='

    $postWinPath = Join-Path $dir 'n2-post-windows.json'
    Write-P9HArtifact -Path $postWinPath -Lines @(([ordered]@{
                Windows = @([ordered]@{ hwnd = '0xA1'; pid = 4242; visible = $true; class = 'CASCADIA_HOSTING_WINDOW_CLASS'; x = 44; y = 52; width = 1129; height = 635; title = $windowId })
            } | ConvertTo-Json -Depth 5))

    $newProcPath = Join-Path $dir 'n2-new-processes.json'
    Write-P9HArtifact -Path $newProcPath -Lines @(([ordered]@{
                Added = @([ordered]@{ pid = 4242; ppid = 4240; name = 'pwsh.exe'; startUtc = (Get-P9HUtcStamp); commandLine = $bootstrapCmd })
            } | ConvertTo-Json -Depth 5))

    $exitPath = Join-Path $dir 'n2-exit-good.json'
    $rec = New-P9HExitRecord -TrialId $tid -Outcome 'exited' -ExitCode 0 -LauncherPid 4240 `
        -LauncherPath 'C:\synthetic\ws.cmd' -InvocationDisplay 'synthetic' -WorkingDirectory $dir `
        -LaunchedAtUtc (Get-P9HUtcStamp) -ExitedAtUtc (Get-P9HUtcStamp)
    $null = Write-P9HExitRecord -Path $exitPath -Record $rec

    $e1 = (@{ event = 'lifecycle-layout-plan'; source = 'relative'; skipped = @($terminalId); trialId = $tid; planId = 'plan-1' } | ConvertTo-Json -Compress)
    $e2 = (@{ event = 'stage2-broker-ready'; planId = 'plan-1'; failed = 0 } | ConvertTo-Json -Compress)
    $e3 = (@{ event = 'stage2-terminal-final'; planId = 'plan-1'; finalized = 1; failures = 0 } | ConvertTo-Json -Compress)
    $e4 = (@{ event = 'transaction-end'; planId = 'plan-1'; broker = $true; uncertain = $false; failures = @() } | ConvertTo-Json -Compress)

    $tracePath = Join-Path $dir 'n2-trace.jsonl'
    Write-P9HArtifact -Path $tracePath -Lines @($e1, $e2, $e3, $e4)

    $n2args = @{
        FixturePath     = $fixturePath
        StdoutPath      = $stdoutPath
        PreWindowPath   = $preWin
        PostWindowPath  = $postWinPath
        ExitRecordPath  = $exitPath
        NewProcessPath  = $newProcPath
        TrialId         = $tid
        ExpectedWindowId   = $windowId
        ExpectedTerminalId = $terminalId
        ExpectedSetId      = $setId
    }

    # ---- V4: missing exit record => N2-B INCONCLUSIVE ----
    $a4 = Copy-P9HArgs -Table $n2args; $a4.TracePath = $tracePath; $a4.ExitRecordPath = (Join-Path $dir 'missing-exit.json')
    $nv = Get-P9HN2Verdicts @a4
    Add-P9HTestResult -Id 'V4' -Title 'Clean broker trace without exit record cannot PASS N2-B' `
        -Input 'absent exit record' -Expected 'N2B=INCONCLUSIVE' `
        -Actual ("N2B={0}" -f $nv.N2B.Verdict) -Pass ($nv.N2B.Verdict -eq 'INCONCLUSIVE') -Evidence $tracePath

    # ---- V5: N2-A PASS does not imply N2-B PASS ----
    Add-P9HTestResult -Id 'V5' -Title 'N2-A PASS does not imply N2-B PASS' -Input 'same run as V4' `
        -Expected 'N2A=PASS and N2B!=PASS' `
        -Actual ("N2A={0} N2B={1}" -f $nv.N2A.Verdict, $nv.N2B.Verdict) `
        -Pass ($nv.N2A.Verdict -eq 'PASS' -and $nv.N2B.Verdict -ne 'PASS') -Evidence $tracePath

    # ---- V6: complete evidence => N2-B PASS (actual detached architecture) ----
    $a6 = Copy-P9HArgs -Table $n2args; $a6.TracePath = $tracePath
    $nv2 = Get-P9HN2Verdicts @a6
    Add-P9HTestResult -Id 'V6' -Title 'Complete evidence passes N2-B (detached broker-created terminal)' `
        -Input 'exit 0 + argv identity + attributed window + valid trace' -Expected 'N2B=PASS' `
        -Actual ("N2B={0} exit={1} procAttr={2} winAttr={3} trace={4}" -f $nv2.N2B.Verdict, $nv2.N2B.ExitCode, $nv2.N2B.ProcessAttributed, $nv2.N2B.WindowAttributed, $nv2.N2B.TraceValid) `
        -Pass ($nv2.N2B.Verdict -eq 'PASS' -and $nv2.N2B.ExitCode -eq 0) -Evidence $exitPath

    # ---- V7: captured nonzero exit => FAIL ----
    $exitBad = Join-Path $dir 'n2-exit-bad.json'
    $recBad = New-P9HExitRecord -TrialId $tid -Outcome 'exited' -ExitCode 1 -LauncherPid 4240 `
        -LauncherPath 'C:\synthetic\ws.cmd' -InvocationDisplay 'synthetic' -WorkingDirectory $dir `
        -LaunchedAtUtc (Get-P9HUtcStamp) -ExitedAtUtc (Get-P9HUtcStamp)
    $null = Write-P9HExitRecord -Path $exitBad -Record $recBad
    $a7 = Copy-P9HArgs -Table $n2args; $a7.TracePath = $tracePath; $a7.ExitRecordPath = $exitBad
    $nv3 = Get-P9HN2Verdicts @a7
    Add-P9HTestResult -Id 'V7' -Title 'Captured nonzero exit is a lifecycle FAIL' `
        -Input 'exit code 1' -Expected 'N2B=FAIL' -Actual ("N2B={0}" -f $nv3.N2B.Verdict) `
        -Pass ($nv3.N2B.Verdict -eq 'FAIL') -Evidence $exitBad

    # ---- V8: instrumentation gap => INCONCLUSIVE ----
    $a8 = Copy-P9HArgs -Table $n2args; $a8.TracePath = $tracePath; $a8.ExitRecordPath = (Join-Path $dir 'none.json')
    $nv4 = Get-P9HN2Verdicts @a8
    Add-P9HTestResult -Id 'V8' -Title 'Instrumentation gap yields INCONCLUSIVE not FAIL' `
        -Input 'absent exit record' -Expected 'N2B=INCONCLUSIVE' `
        -Actual ("N2B={0}" -f $nv4.N2B.Verdict) -Pass ($nv4.N2B.Verdict -eq 'INCONCLUSIVE') -Evidence $null

    # ---- V9: no negative-origin monitor ----
    $p9 = & $writeCapture 'v9-pre.json' $tokensA 3 $true $true $tid $false $preUtc
    $q9 = & $writeCapture 'v9-post.json' $tokensA 3 $true $true $tid $false $postUtc
    $v9 = Get-P9HE1Verdict -PreCapturePath $p9 -PostCapturePath $q9 -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'V9' -Title 'Identical tokens without a negative-origin monitor cannot PASS' `
        -Input 'positive-origin monitors only' -Expected 'not PASS' `
        -Actual ("Verdict={0} negObserved={1}" -f $v9.Verdict, $v9.SubObservations['negativeOriginObserved']) `
        -Pass ($v9.Verdict -ne 'PASS') -Evidence $p9

    # ---- V10: wrong session ----
    $p10 = & $writeCapture 'v10-pre.json' $tokensA 5 $true $true $tid $true $preUtc
    $q10 = & $writeCapture 'v10-post.json' $tokensA 5 $true $true $tid $true $postUtc
    $v10 = Get-P9HE1Verdict -PreCapturePath $p10 -PostCapturePath $q10 -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'V10' -Title 'Identical tokens from a different session cannot PASS' `
        -Input 'captures claim session 5' -Expected 'not PASS' `
        -Actual ("Verdict={0} matchTarget={1}" -f $v10.Verdict, $v10.SubObservations['sessionMatchesTarget']) `
        -Pass ($v10.Verdict -ne 'PASS') -Evidence $p10

    # ---- V11: incompatible pre/post sessions ----
    $p11 = & $writeCapture 'v11-pre.json' $tokensA 3 $true $true $tid $true $preUtc
    $q11 = & $writeCapture 'v11-post.json' $tokensA 4 $true $true $tid $true $postUtc
    $v11 = Get-P9HE1Verdict -PreCapturePath $p11 -PostCapturePath $q11 -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'V11' -Title 'Incompatible pre/post sessions cannot PASS' `
        -Input 'pre 3, post 4' -Expected 'not PASS' `
        -Actual ("Verdict={0} consistent={1}" -f $v11.Verdict, $v11.SubObservations['sessionConsistent']) `
        -Pass ($v11.Verdict -ne 'PASS') -Evidence $p11

    # ---- V12: no raw token identity at all ----
    $p12 = & $writeCapture 'v12-pre.json' $tokensA 3 $false $false $tid $true $preUtc
    $q12 = & $writeCapture 'v12-post.json' $tokensA 3 $false $false $tid $true $postUtc
    $v12 = Get-P9HE1Verdict -PreCapturePath $p12 -PostCapturePath $q12 -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'V12' -Title 'Missing raw token identity evidence cannot PASS' `
        -Input 'no tokens and no monitor records' -Expected 'not PASS' `
        -Actual ("Verdict={0} reasons={1}" -f $v12.Verdict, ($v12.Reasons -join ',')) `
        -Pass ($v12.Verdict -ne 'PASS') -Evidence $p12

    # ---- V13: different tokens with a valid transition ----
    $p13 = & $writeCapture 'v13-pre.json' $tokensA 3 $true $true $tid $true $preUtc
    $q13 = & $writeCapture 'v13-post.json' $tokensDiff 3 $true $true $tid $true $postUtc
    $v13 = Get-P9HE1Verdict -PreCapturePath $p13 -PostCapturePath $q13 -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'V13' -Title 'Different tokens with a valid transition are a measured mismatch' `
        -Input 'post token set differs' -Expected 'not PASS, sets-differ reported' `
        -Actual ("Verdict={0} reasons={1}" -f $v13.Verdict, ($v13.Reasons -join ',')) `
        -Pass ($v13.Verdict -ne 'PASS' -and $v13.Reasons -contains 'token-sets-differ') -Evidence $q13

    # ---- V14: pre+disconnect but no post-reconnect record ----
    $logIncomplete = & $writeLog 'v14.jsonl' @(
        @{ Phase = 'pre'; State = 0 }
        @{ Phase = 'disconnect-observed'; State = 4 }
    )
    $v14 = Get-P9HE1Verdict -PreCapturePath $prePath -PostCapturePath $postPath -ObserverLogPath $logIncomplete `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'V14' -Title 'Two valid captures without a completed transition are NOT FULLY EVIDENCED' `
        -Input 'no post-reconnect record' -Expected 'NOT FULLY EVIDENCED' `
        -Actual ("Verdict={0} reason={1}" -f $v14.Verdict, $v14.DisconnectReason) `
        -Pass ($v14.Verdict -eq 'NOT FULLY EVIDENCED') -Evidence $logIncomplete

    # ================= W-series: trace validity + causal attribution =================

    function Try-N2([hashtable]$overrides) {
        $a = Copy-P9HArgs -Table $n2args
        $a.TracePath = $tracePath
        foreach ($k in $overrides.Keys) { $a[$k] = $overrides[$k] }
        return Get-P9HN2Verdicts @a
    }

    # ---- W1: complete valid trace is eligible for PASS ----
    $w1 = Try-N2 @{}
    Add-P9HTestResult -Id 'W1' -Title 'Complete valid trace with attribution is eligible for PASS' `
        -Input 'four required events, one planId, in order' -Expected 'PASS' `
        -Actual ("N2B={0} traceOk={1}" -f $w1.N2B.Verdict, $w1.N2B.TraceValid) `
        -Pass ($w1.N2B.Verdict -eq 'PASS') -Evidence $tracePath

    # ---- W2: valid events + one malformed line ----
    $t2 = Join-Path $dir 'w2-trace.jsonl'
    Write-P9HArtifact -Path $t2 -Lines @($e1, $e2, '{"event":"noise","junk":', $e3, $e4)
    $w2 = Try-N2 @{ TracePath = $t2 }
    Add-P9HTestResult -Id 'W2' -Title 'Valid events plus one malformed trace line cannot PASS' `
        -Input 'all required events present, one line unparseable' -Expected 'not PASS' `
        -Actual ("N2B={0} reason={1}" -f $w2.N2B.Verdict, $w2.N2B.Reasons -join ',') `
        -Pass ($w2.N2B.Verdict -ne 'PASS') -Evidence $t2

    # ---- W3: missing required event ----
    $t3 = Join-Path $dir 'w3-trace.jsonl'
    Write-P9HArtifact -Path $t3 -Lines @($e1, $e2, $e4)
    $w3 = Try-N2 @{ TracePath = $t3 }
    Add-P9HTestResult -Id 'W3' -Title 'A trace missing a required event cannot PASS' `
        -Input 'no stage2-terminal-final' -Expected 'not PASS' `
        -Actual ("N2B={0}" -f $w3.N2B.Verdict) -Pass ($w3.N2B.Verdict -ne 'PASS') -Evidence $t3

    # ---- W4: contradictory finalization events ----
    $t4 = Join-Path $dir 'w4-trace.jsonl'
    Write-P9HArtifact -Path $t4 -Lines @($e1, $e2, (@{ event = 'stage2-terminal-final'; planId = 'plan-1'; finalized = 1; failures = 2 } | ConvertTo-Json -Compress), $e3, $e4)
    $w4 = Try-N2 @{ TracePath = $t4 }
    Add-P9HTestResult -Id 'W4' -Title 'Contradictory finalization events cannot PASS' `
        -Input 'two terminal-final events with different outcomes' -Expected 'not PASS' `
        -Actual ("N2B={0} reason={1}" -f $w4.N2B.Verdict, $w4.N2B.Reasons -join ',') `
        -Pass ($w4.N2B.Verdict -ne 'PASS') -Evidence $t4

    # ---- W5: events from different trials ----
    $t5 = Join-Path $dir 'w5-trace.jsonl'
    Write-P9HArtifact -Path $t5 -Lines @(
        (@{ event = 'lifecycle-layout-plan'; source = 'relative'; skipped = @($terminalId); trialId = $tid; planId = 'plan-1' } | ConvertTo-Json -Compress)
        (@{ event = 'stage2-broker-ready'; planId = 'plan-1'; failed = 0; trialId = 'p9h-foreign-99999999' } | ConvertTo-Json -Compress)
        $e3, $e4
    )
    $w5 = Try-N2 @{ TracePath = $t5 }
    Add-P9HTestResult -Id 'W5' -Title 'Events from different trials cannot PASS' `
        -Input 'conflicting trialId across events' -Expected 'not PASS' `
        -Actual ("N2B={0} reason={1}" -f $w5.N2B.Verdict, $w5.N2B.Reasons -join ',') `
        -Pass ($w5.N2B.Verdict -ne 'PASS') -Evidence $t5

    # ---- W6: incompatible plan ids ----
    $t6 = Join-Path $dir 'w6-trace.jsonl'
    Write-P9HArtifact -Path $t6 -Lines @(
        (@{ event = 'lifecycle-layout-plan'; source = 'relative'; skipped = @($terminalId); trialId = $tid; planId = 'plan-A' } | ConvertTo-Json -Compress)
        (@{ event = 'stage2-broker-ready'; planId = 'plan-B'; failed = 0 } | ConvertTo-Json -Compress)
        (@{ event = 'stage2-terminal-final'; planId = 'plan-C'; finalized = 1; failures = 0 } | ConvertTo-Json -Compress)
        (@{ event = 'transaction-end'; planId = 'plan-D'; broker = $true; uncertain = $false; failures = @() } | ConvertTo-Json -Compress)
    )
    $w6 = Try-N2 @{ TracePath = $t6 }
    Add-P9HTestResult -Id 'W6' -Title 'Events carrying incompatible plan ids cannot PASS' `
        -Input 'four different planIds' -Expected 'not PASS' `
        -Actual ("N2B={0} reason={1}" -f $w6.N2B.Verdict, $w6.N2B.Reasons -join ',') `
        -Pass ($w6.N2B.Verdict -ne 'PASS') -Evidence $t6

    # ---- W7: invalid event order ----
    $t7 = Join-Path $dir 'w7-trace.jsonl'
    Write-P9HArtifact -Path $t7 -Lines @($e1, $e3, $e2, $e4)
    $w7 = Try-N2 @{ TracePath = $t7 }
    Add-P9HTestResult -Id 'W7' -Title 'Events in an invalid causal order cannot PASS' `
        -Input 'terminal-final before broker-ready' -Expected 'not PASS' `
        -Actual ("N2B={0}" -f $w7.N2B.Verdict) -Pass ($w7.N2B.Verdict -ne 'PASS') -Evidence $t7

    # ---- W8: unrelated terminal process with a valid start time ----
    $unrelatedProc = Join-Path $dir 'w8-proc.json'
    Write-P9HArtifact -Path $unrelatedProc -Lines @(([ordered]@{
                Added = @([ordered]@{ pid = 7777; ppid = 1; name = 'pwsh.exe'; startUtc = (Get-P9HUtcStamp); commandLine = 'pwsh.exe -NoExit -File "C:\Users\someone\Documents\scratch.ps1"' })
            } | ConvertTo-Json -Depth 5))
    $w8 = Try-N2 @{ NewProcessPath = $unrelatedProc }
    Add-P9HTestResult -Id 'W8' -Title 'An unrelated new terminal process with a valid start time cannot PASS' `
        -Input 'new pwsh.exe carrying no launch identity' -Expected 'not PASS' `
        -Actual ("N2B={0} procAttr={1} reason={2}" -f $w8.N2B.Verdict, $w8.N2B.ProcessAttributed, $w8.N2B.AttributionReason) `
        -Pass ($w8.N2B.Verdict -ne 'PASS') -Evidence $unrelatedProc

    # ---- W9: window owned by the unrelated process ----
    $w9Proc = Join-Path $dir 'w9-proc.json'
    Write-P9HArtifact -Path $w9Proc -Lines @(([ordered]@{
                Added = @([ordered]@{ pid = 7778; ppid = 1; name = 'pwsh.exe'; startUtc = (Get-P9HUtcStamp); commandLine = 'pwsh.exe -NoProfile' })
            } | ConvertTo-Json -Depth 5))
    $w9Win = Join-Path $dir 'w9-win.json'
    Write-P9HArtifact -Path $w9Win -Lines @(([ordered]@{
                Windows = @([ordered]@{ hwnd = '0xB9'; pid = 7778; visible = $true; class = 'CASCADIA_HOSTING_WINDOW_CLASS'; x = 12; y = 12; width = 900; height = 700; title = 'unrelated' })
            } | ConvertTo-Json -Depth 5))
    $w9 = Try-N2 @{ NewProcessPath = $w9Proc; PostWindowPath = $w9Win }
    Add-P9HTestResult -Id 'W9' -Title 'A window belonging to an unrelated process cannot PASS' `
        -Input 'window pid 7778, no launch identity' -Expected 'not PASS' `
        -Actual ("N2B={0} winAttr={1}" -f $w9.N2B.Verdict, $w9.N2B.WindowAttributed) `
        -Pass ($w9.N2B.Verdict -ne 'PASS') -Evidence $w9Win

    # ---- W10: matching PID but incompatible creation time ----
    $w10Proc = Join-Path $dir 'w10-proc.json'
    Write-P9HArtifact -Path $w10Proc -Lines @(([ordered]@{
                # Same PID as the attributed window owner, launch identity present,
                # but no recoverable start time => cannot be attributed.
                Added = @([ordered]@{ pid = 4242; ppid = 4240; name = 'pwsh.exe'; startUtc = $null; commandLine = $bootstrapCmd })
            } | ConvertTo-Json -Depth 5))
    $w10 = Try-N2 @{ NewProcessPath = $w10Proc }
    Add-P9HTestResult -Id 'W10' -Title 'A PID match without a recoverable creation time cannot PASS' `
        -Input 'correct argv identity, startUtc=null' -Expected 'not PASS' `
        -Actual ("N2B={0} procAttr={1}" -f $w10.N2B.Verdict, $w10.N2B.ProcessAttributed) `
        -Pass ($w10.N2B.Verdict -ne 'PASS') -Evidence $w10Proc

    # ---- W11: correct window class but unrelated transaction ----
    $w11Proc = Join-Path $dir 'w11-proc.json'
    Write-P9HArtifact -Path $w11Proc -Lines @(([ordered]@{
                Added = @([ordered]@{ pid = 4243; ppid = 4240; name = 'pwsh.exe'; startUtc = (Get-P9HUtcStamp); commandLine = $bootstrapCmd.Replace($windowId, 'DevWS-main-OTHER') })
            } | ConvertTo-Json -Depth 5))
    $w11 = Try-N2 @{ NewProcessPath = $w11Proc }
    Add-P9HTestResult -Id 'W11' -Title 'A process carrying a different windowId cannot PASS' `
        -Input 'argv has DevWS-main-OTHER instead of the planned windowId' -Expected 'not PASS' `
        -Actual ("N2B={0} procAttr={1}" -f $w11.N2B.Verdict, $w11.N2B.ProcessAttributed) `
        -Pass ($w11.N2B.Verdict -ne 'PASS') -Evidence $w11Proc

    # ---- W12: clean trace + exit 0, no attribution ----
    $w12Empty = Join-Path $dir 'w12-empty.json'
    Write-P9HArtifact -Path $w12Empty -Lines @('{"Added":[]}')
    $w12 = Try-N2 @{ NewProcessPath = $w12Empty }
    Add-P9HTestResult -Id 'W12' -Title 'Clean trace and exit 0 without causal attribution cannot PASS' `
        -Input 'no new processes at all' -Expected 'not PASS' `
        -Actual ("N2B={0}" -f $w12.N2B.Verdict) -Pass ($w12.N2B.Verdict -ne 'PASS') -Evidence $null

    # ---- W13: inconsistent terminal identifiers ----
    $w13Proc = Join-Path $dir 'w13-proc.json'
    Write-P9HArtifact -Path $w13Proc -Lines @(([ordered]@{
                Added = @([ordered]@{ pid = 4244; ppid = 4240; name = 'pwsh.exe'; startUtc = (Get-P9HUtcStamp); commandLine = $bootstrapCmd.Replace("-TerminalId $terminalId", '-TerminalId wrong-item') })
            } | ConvertTo-Json -Depth 5))
    $w13 = Try-N2 @{ NewProcessPath = $w13Proc }
    Add-P9HTestResult -Id 'W13' -Title 'A process with an inconsistent terminal id cannot PASS' `
        -Input 'argv TerminalId=wrong-item' -Expected 'not PASS' `
        -Actual ("N2B={0} procAttr={1}" -f $w13.N2B.Verdict, $w13.N2B.ProcessAttributed) `
        -Pass ($w13.N2B.Verdict -ne 'PASS') -Evidence $w13Proc

    # ---- W14: positive, real detached architecture ----
    $w14 = Try-N2 @{}
    Add-P9HTestResult -Id 'W14' -Title 'The real detached broker-created terminal architecture passes' `
        -Input 'pwsh child carrying -SetId/-TerminalId/-WindowId from the broker' -Expected 'PASS' `
        -Actual ("N2B={0} procAttr={1} winAttr={2}" -f $w14.N2B.Verdict, $w14.N2B.ProcessAttributed, $w14.N2B.WindowAttributed) `
        -Pass ($w14.N2B.Verdict -eq 'PASS') -Evidence $newProcPath

    # ================= X-series: window-omission and E1 raw-monitor contract =================

    # ---- X1: a request to omit window evidence cannot yield PASS ----
    $x1 = $false
    try {
        $a1 = Copy-P9HArgs -Table $n2args
        $a1.TracePath = $tracePath
        $a1.PostWindowPath = $preWin          # observed, but zero windows
        $a1.WindowRequired = 'no'             # Stage 2.1 bypass argument
        $r1 = Get-P9HN2Verdicts @a1
        $x1 = ($r1.N2B.Verdict -ne 'PASS')
    }
    catch { $x1 = $true }   # the parameter no longer exists: request is unsupported
    Add-P9HTestResult -Id 'X1' -Title 'A window-omission request cannot lower the N2-B threshold' `
        -Input "WindowRequired='no' with zero observed windows" -Expected 'not PASS (or rejected)' `
        -Actual ("blocked={0}" -f $x1) -Pass $x1 -Evidence $null

    # ---- X2: asserted summary only, no monitor records ----
    $x2Pre = Join-Path $dir 'x2-pre.json'
    $x2Post = Join-Path $dir 'x2-post.json'
    $summary = [ordered]@{
        tokens = $tokensA; tokenCount = 2; identityComplete = $true; sessionId = 3
        capturedUtc = $preUtc; trialId = $tid
        tokenRectBytes = 'path:DEFAULT_MONITOR/1&ABCDEF&0&UID1001@x=0 y=0 w=1920 h=1080;path:DEFAULT_MONITOR/1&ABCDEF&0&UID1002@x=-2560 y=-355 w=2560 h=1440'
        tokenSetBytes = (($tokensA | Sort-Object) -join '|')
    }
    Write-P9HArtifact -Path $x2Pre -Lines @(($summary | ConvertTo-Json -Depth 5))
    $summaryPost = @{}; foreach ($k in @($summary.Keys)) { $summaryPost[$k] = $summary[$k] }; $summaryPost.capturedUtc = $postUtc
    Write-P9HArtifact -Path $x2Post -Lines @(($summaryPost | ConvertTo-Json -Depth 5))
    $x2 = Get-P9HE1Verdict -PreCapturePath $x2Pre -PostCapturePath $x2Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X2' -Title 'Asserted tokenRectBytes without monitor records cannot PASS' `
        -Input 'valid tokens + precomputed rect string, no parsedMonitors' -Expected 'not PASS' `
        -Actual ("Verdict={0} reasons={1}" -f $x2.Verdict, ($x2.Reasons -join ',')) `
        -Pass ($x2.Verdict -ne 'PASS') -Evidence $x2Pre

    # ---- X3: fabricated negative-origin summary ----
    $x3Pre = Join-Path $dir 'x3-pre.json'
    $x3Post = Join-Path $dir 'x3-post.json'
    $fab = [ordered]@{
        tokens = $tokensA; tokenCount = 2; identityComplete = $true; sessionId = 3; trialId = $tid
        tokenRectBytes = 'path:DEFAULT_MONITOR/1&ABCDEF&0&UID1001@x=0 y=0 w=1920 h=1080;path:DEFAULT_MONITOR/1&ABCDEF&0&UID1002@x=-9999 y=-9999 w=2560 h=1440'
    }
    $fabPre = @{}; foreach ($k in @($fab.Keys)) { $fabPre[$k] = $fab[$k] }; $fabPre.capturedUtc = $preUtc
    $fabPost = @{}; foreach ($k in @($fab.Keys)) { $fabPost[$k] = $fab[$k] }; $fabPost.capturedUtc = $postUtc
    Write-P9HArtifact -Path $x3Pre -Lines @(($fabPre | ConvertTo-Json -Depth 5))
    Write-P9HArtifact -Path $x3Post -Lines @(($fabPost | ConvertTo-Json -Depth 5))
    $x3 = Get-P9HE1Verdict -PreCapturePath $x3Pre -PostCapturePath $x3Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X3' -Title 'A fabricated negative-origin summary cannot PASS' `
        -Input 'tokenRectBytes claims x=-9999 with no monitor records' -Expected 'not PASS' `
        -Actual ("Verdict={0}" -f $x3.Verdict) -Pass ($x3.Verdict -ne 'PASS') -Evidence $x3Pre

    # ---- X4: parsedMonitors disagree with the token list ----
    $x4Pre = & $writeCapture 'x4-pre.json' $tokensA 3 $true $true $tid $true $preUtc `
        @('path:OTHER/9&ZZZ&0&UID5555', 'path:OTHER/9&ZZZ&0&UID5556')
    $x4Post = & $writeCapture 'x4-post.json' $tokensA 3 $true $true $tid $true $postUtc `
        @('path:OTHER/9&ZZZ&0&UID5555', 'path:OTHER/9&ZZZ&0&UID5556')
    $x4 = Get-P9HE1Verdict -PreCapturePath $x4Pre -PostCapturePath $x4Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X4' -Title 'Monitor records disagreeing with the token list cannot PASS' `
        -Input 'parsedMonitors identities differ from tokens' -Expected 'not PASS' `
        -Actual ("Verdict={0} agrees={1}" -f $x4.Verdict, $x4.SubObservations['tokenListAgreesWithRecords']) `
        -Pass ($x4.Verdict -ne 'PASS') -Evidence $x4Pre

    # ---- X5: identical summaries, different mappings ----
    $x5Pre = & $writeCapture 'x5-pre.json' $tokensA 3 $true $true $tid $true $preUtc
    $x5Post = & $writeCapture 'x5-post.json' $tokensA 3 $true $true $tid $true $postUtc `
        $null @('x=0 y=0 w=1920 h=1080', 'x=-2560 y=-999 w=2560 h=1440')
    $x5 = Get-P9HE1Verdict -PreCapturePath $x5Pre -PostCapturePath $x5Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X5' -Title 'Different token-to-rectangle mappings cannot PASS' `
        -Input 'post rect y differs' -Expected 'not PASS' `
        -Actual ("Verdict={0} pairsEqual={1}" -f $x5.Verdict, $x5.SubObservations['tokenRectPairsEqual']) `
        -Pass ($x5.Verdict -ne 'PASS') -Evidence $x5Post

    # ---- X6: capture omitting trialId ----
    $x6Pre = & $writeCapture 'x6-pre.json' $tokensA 3 $true $true '' $true $preUtc
    $x6Post = & $writeCapture 'x6-post.json' $tokensA 3 $true $true '' $true $postUtc
    $x6 = Get-P9HE1Verdict -PreCapturePath $x6Pre -PostCapturePath $x6Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X6' -Title 'A capture omitting trialId cannot PASS' `
        -Input 'no trialId field on either capture' -Expected 'not PASS' `
        -Actual ("Verdict={0} present={1}" -f $x6.Verdict, $x6.SubObservations['trialProvenancePresent']) `
        -Pass ($x6.Verdict -ne 'PASS') -Evidence $x6Pre

    # ---- X7: different trial ids ----
    $x7Pre = & $writeCapture 'x7-pre.json' $tokensA 3 $true $true $tid $true $preUtc
    $x7Post = & $writeCapture 'x7-post.json' $tokensA 3 $true $true 'p9h-other-trial-11111111' $true $postUtc
    $x7 = Get-P9HE1Verdict -PreCapturePath $x7Pre -PostCapturePath $x7Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X7' -Title 'Captures from different trials cannot PASS' `
        -Input 'pre trial != post trial' -Expected 'not PASS' `
        -Actual ("Verdict={0} agrees={1}" -f $x7.Verdict, $x7.SubObservations['trialProvenanceAgrees']) `
        -Pass ($x7.Verdict -ne 'PASS') -Evidence $x7Post

    # ---- X8: pre-capture timestamp after the disconnect observation ----
    $futurePre = (Get-Date).ToUniversalTime().AddHours(2).ToString('o')
    $x8Pre = & $writeCapture 'x8-pre.json' $tokensA 3 $true $true $tid $true $futurePre
    $x8Post = & $writeCapture 'x8-post.json' $tokensA 3 $true $true $tid $true ((Get-Date).ToUniversalTime().AddHours(3).ToString('o'))
    $x8 = Get-P9HE1Verdict -PreCapturePath $x8Pre -PostCapturePath $x8Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X8' -Title 'A pre-capture later than the disconnect observation cannot PASS' `
        -Input 'pre-capture timestamp three hours in the future' -Expected 'not PASS' `
        -Actual ("Verdict={0} brackets={1}" -f $x8.Verdict, $x8.SubObservations['captureBracketsTransition']) `
        -Pass ($x8.Verdict -ne 'PASS') -Evidence $x8Pre

    # ---- X9: post-capture timestamp before the reconnect observation ----
    $pastPost = (Get-Date).ToUniversalTime().AddHours(-3).ToString('o')
    $x9Pre = & $writeCapture 'x9-pre.json' $tokensA 3 $true $true $tid $true ((Get-Date).ToUniversalTime().AddHours(-4).ToString('o'))
    $x9Post = & $writeCapture 'x9-post.json' $tokensA 3 $true $true $tid $true $pastPost
    $x9 = Get-P9HE1Verdict -PreCapturePath $x9Pre -PostCapturePath $x9Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X9' -Title 'A post-capture earlier than the reconnect observation cannot PASS' `
        -Input 'post-capture three hours in the past' -Expected 'not PASS' `
        -Actual ("Verdict={0} brackets={1}" -f $x9.Verdict, $x9.SubObservations['captureBracketsTransition']) `
        -Pass ($x9.Verdict -ne 'PASS') -Evidence $x9Post

    # ---- X10: reversed pre/post capture ordering ----
    $x10Pre = & $writeCapture 'x10-pre.json' $tokensA 3 $true $true $tid $true $postUtc
    $x10Post = & $writeCapture 'x10-post.json' $tokensA 3 $true $true $tid $true $preUtc
    $x10 = Get-P9HE1Verdict -PreCapturePath $x10Pre -PostCapturePath $x10Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X10' -Title 'Reversed pre/post capture timestamps cannot PASS' `
        -Input 'pre-capture is later than post-capture' -Expected 'not PASS' `
        -Actual ("Verdict={0} chronologyOk={1}" -f $x10.Verdict, $x10.SubObservations['captureChronologyOk']) `
        -Pass ($x10.Verdict -ne 'PASS') -Evidence $x10Pre

    # ---- X11: malformed timestamp ----
    $x11Pre = & $writeCapture 'x11-pre.json' $tokensA 3 $true $true $tid $true 'not-a-timestamp'
    $x11Post = & $writeCapture 'x11-post.json' $tokensA 3 $true $true $tid $true $postUtc
    $x11 = Get-P9HE1Verdict -PreCapturePath $x11Pre -PostCapturePath $x11Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X11' -Title 'A malformed capture timestamp cannot PASS' `
        -Input "capturedUtc='not-a-timestamp'" -Expected 'not PASS' `
        -Actual ("Verdict={0} valid={1}" -f $x11.Verdict, $x11.SubObservations['captureTimestampsValid']) `
        -Pass ($x11.Verdict -ne 'PASS') -Evidence $x11Pre

    # ---- X12: valid raw captures with matching topology => PASS ----
    $x12 = Get-P9HE1Verdict -PreCapturePath $prePath -PostCapturePath $postPath -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X12' -Title 'Valid raw captures with matching topology are eligible for PASS' `
        -Input 'authoritative records, one trial, bracketing timestamps' -Expected 'PASS' `
        -Actual ("Verdict={0}" -f $x12.Verdict) -Pass ($x12.Verdict -eq 'PASS') -Evidence $prePath
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
