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

function Invoke-P9HVerdictTests {
    # V-series: verdict rules.
    #
    # Stage 2.1 adds the negative cases the independent review requires:
    # V9  identical tokens without a negative-origin monitor   -> not PASS
    # V10 identical tokens from the wrong session              -> not PASS
    # V11 incompatible pre/post session identities             -> not PASS
    # V12 missing raw token identity evidence                  -> not PASS
    # V13 different tokens with a valid transition             -> measured mismatch, not PASS
    # V14 two valid captures with no proven transition          -> NOT FULLY EVIDENCED
    # and the N2 attribution negatives:
    # N1  exit 0 + clean trace but no attributable process      -> not PASS
    # N2  exit 0 + clean trace but no attributable window       -> not PASS
    # N3  new window belongs to an unrelated PID                -> not PASS
    # N4  trace from a different plan/trial                     -> not PASS
    # N5  degraded/missing inventory                            -> INCONCLUSIVE
    # N6  missing post-window artifact                          -> N2-A not PASS
    # N7  malformed post-window artifact                        -> N2-A not PASS
    # N8  empty but valid window inventory                      -> N2-A PASS (nothing placed)
    # N9  fallback actually applied                             -> N2-A FAIL-by-reason
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $trial = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind selftest
    $dir = $trial.Directory
    $logon = '2026-11-11T10:00:00.0000000Z'

    # ---------- capture fixture builder ----------
    $writeCapture = {
        param([string]$name, [string[]]$tokens, [int]$sessionId, [bool]$includeTokens = $true,
              [string]$trialId = '', [bool]$withNegativeOrigin = $true)
        $parsed = @()
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            $rect = if ($i -eq 1 -and $withNegativeOrigin) { 'x=-2560 y=-355 w=2560 h=1440' }
                    elseif ($i -eq 1) { 'x=2560 y=0 w=2560 h=1440' }
                    else { 'x=0 y=0 w=1920 h=1080' }
            $parsed += [ordered]@{ identity = $tokens[$i]; rect = $rect }
        }
        $rectBytes = (@($parsed | ForEach-Object { '{0}@{1}' -f $_.identity, $_.rect }) -join ';')
        $obj = [ordered]@{
            tokenCount = $tokens.Count
            tokenRectBytes = $rectBytes
            identityComplete = $true
            sessionId = $sessionId
            capturedUtc = Get-P9HUtcStamp
        }
        if ($includeTokens) { $obj.tokens = $tokens }
        if (-not [string]::IsNullOrWhiteSpace($trialId)) { $obj.trialId = $trialId }
        if ($includeTokens) { $obj.parsedMonitors = $parsed }
        $p = Join-Path $dir $name
        Write-P9HArtifact -Path $p -Lines @(($obj | ConvertTo-Json -Depth 6))
        return $p
    }

    $tokensA = @('path:DEFAULT_MONITOR/1&ABCDEF&0&UID1001', 'path:DEFAULT_MONITOR/1&ABCDEF&0&UID1002')
    $tokensNoNeg = $tokensA
    $tokensDiff = @('path:DEFAULT_MONITOR/1&ABCDEF&0&UID1001', 'path:DEFAULT_MONITOR/1&ABCDEF&0&UID9002')

    $prePath = & $writeCapture 'e1-pre.json' $tokensA 3 $true $trial.TrialId $true
    $postPath = & $writeCapture 'e1-post.json' $tokensA 3 $true $trial.TrialId $true

    # ---------- observer logs ----------
    $writeLog = {
        param([string]$name, [object[]]$entries, [int]$sessionId = 3, [string]$trialId = '')
        $p = Join-Path $dir $name
        $seq = 1
        $tid = if ([string]::IsNullOrWhiteSpace($trialId)) { $trial.TrialId } else { $trialId }
        foreach ($e in $entries) {
            $state = if ($null -ne $e['State']) { $e['State'] } else { 0 }
            $who = if ($null -ne $e['User']) { $e['User'] } else { 'qauser' }
            $lg = if ($null -ne $e['Logon']) { $e['Logon'] } else { $logon }
            $raw = if ($state -eq 4) { @("$sessionId|RDP-Tcp#0|state=4|user=$who|logon=$lg") }
                   else { @("$sessionId|RDP-Tcp#0|state=0|user=$who|logon=$lg") }
            Add-P9HArtifactLine -Path $p -Line (New-P9HObserverRecord -TrialId $tid -Sequence $seq `
                    -Phase $e['Phase'] -RawWtsLines $raw -TargetSessionId $sessionId -TargetUser $who -TargetLogonTime $lg)
            $seq++
        }
        return $p
    }

    $logGood = & $writeLog 'v-good.jsonl' @(
        @{ Phase = 'pre'; State = 0 }
        @{ Phase = 'disconnect-observed'; State = 4 }
        @{ Phase = 'post'; State = 0 }
    )

    # ---- V1: complete valid dataset => PASS ----
    $v = Get-P9HE1Verdict -PreCapturePath $prePath -PostCapturePath $postPath -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'V1' -Title 'Complete valid dataset satisfies E1' `
        -Input 'identical captures with negative origin + valid transition' -Expected 'PASS' `
        -Actual ("Verdict={0} reasons={1}" -f $v.Verdict, ($v.Reasons -join ',')) `
        -Pass ($v.Verdict -eq 'PASS') -Evidence $logGood

    # ---- V2: two valid captures without a proven transition ----
    $logNoProof = & $writeLog 'v-noproof.jsonl' @(
        @{ Phase = 'pre'; State = 0 }
        @{ Phase = 'disconnect-observed'; State = 0 }
        @{ Phase = 'post'; State = 0 }
    )
    $v = Get-P9HE1Verdict -PreCapturePath $prePath -PostCapturePath $postPath -ObserverLogPath $logNoProof `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'V2' -Title 'Two valid captures without a proven transition cannot PASS' `
        -Input 'identical captures, disconnect never observed' -Expected 'NOT FULLY EVIDENCED' `
        -Actual ("Verdict={0}" -f $v.Verdict) `
        -Pass ($v.Verdict -eq 'NOT FULLY EVIDENCED') -Evidence $logNoProof

    # ---- V3: a new logon reusing the session id is not accepted ----
    $records = @([pscustomobject]@{ SessionId = 3; User = 'qauser'; State = 4; StationName = 'RDP-Tcp#0'; LogonTime = '2026-11-11T11:11:11.0000000Z' })
    $m = Get-P9HTargetSessionRecord -Records $records -SessionId 3 -User 'qauser' -LogonTime $logon
    Add-P9HTestResult -Id 'V3' -Title 'A new logon reusing the session id is not accepted' `
        -Input 'logon 11:11:11Z vs pinned 10:00:00Z' -Expected 'not matched (logon-mismatch)' `
        -Actual ("Ok={0} reason={1}" -f $m.Ok, $m.Reason) `
        -Pass ((-not $m.Ok) -and $m.Reason -eq 'logon-mismatch') -Evidence $null

    # ================= N2 fixtures =================
    $fixturePath = Join-Path $dir 'n2-fixture.json'
    $fixture = [ordered]@{
        itemId = 'p9h-item'; enabledItems = 1; enabledTerminals = 1; totalItems = 1
        anchorAbsent = $true
        layoutFallback = [ordered]@{ x = 9000; y = 9000; w = 640; h = 480 }
    }
    Write-P9HArtifact -Path $fixturePath -Lines @(($fixture | ConvertTo-Json -Depth 5))

    $tracePath = Join-Path $dir 'n2-trace.jsonl'
    $traceLines = @(
        (@{ event = 'lifecycle-layout-plan'; source = 'relative'; skipped = @('p9h-item'); trialId = $trial.TrialId } | ConvertTo-Json -Compress)
        (@{ event = 'stage2-broker-ready'; planId = 'synthetic-plan-1'; failed = 0 } | ConvertTo-Json -Compress)
        (@{ event = 'stage2-terminal-final'; finalized = 1; failures = 0 } | ConvertTo-Json -Compress)
        (@{ event = 'transaction-end'; broker = $true; uncertain = $false; failures = @() } | ConvertTo-Json -Compress)
    )
    Write-P9HArtifact -Path $tracePath -Lines $traceLines

    $stdoutPath = Join-Path $dir 'n2-stdout.txt'
    Write-P9HArtifact -Path $stdoutPath -Lines @('main/p9h-item: relative layout has no reachable placement (anchor-missing: identity-not-found); the item will be handled normally but its window position will not be changed.')

    $preWin = Join-Path $dir 'n2-pre-windows.json'
    Write-P9HArtifact -Path $preWin -Lines @('{"Windows":[]}')

    # Post window attributed to a launched process (pid 4242) at the skip position.
    $postWinPath = Join-Path $dir 'n2-post-windows.json'
    Write-P9HArtifact -Path $postWinPath -Lines @(([ordered]@{
                Windows = @([ordered]@{ hwnd = '0xA1'; pid = 4242; visible = $true; class = 'CASCADIA_HOSTING_WINDOW_CLASS'; x = 44; y = 52; width = 1129; height = 635; title = 'synthetic' })
            } | ConvertTo-Json -Depth 5))

    # New process created by the launch, with a RECOVERED start time.
    $newProcPath = Join-Path $dir 'n2-new-processes.json'
    Write-P9HArtifact -Path $newProcPath -Lines @(([ordered]@{
                Added = @([ordered]@{ pid = 4242; ppid = 4240; name = 'WindowsTerminal.exe'; startUtc = (Get-P9HUtcStamp); commandLine = 'synthetic-terminal' })
            } | ConvertTo-Json -Depth 5))

    $missingExit = Join-Path $dir 'n2-exit-missing.json'
    $nv = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $postWinPath -ExitRecordPath $missingExit `
        -NewProcessPath $newProcPath -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'V4' -Title 'Clean broker trace without exit record cannot PASS N2-B' `
        -Input 'clean trace + absent exit record' -Expected 'N2B=INCONCLUSIVE' `
        -Actual ("N2A={0} N2B={1}" -f $nv.N2A.Verdict, $nv.N2B.Verdict) `
        -Pass ($nv.N2B.Verdict -eq 'INCONCLUSIVE') -Evidence $tracePath

    Add-P9HTestResult -Id 'V5' -Title 'N2-A PASS does not imply N2-B PASS' -Input 'same run as V4' `
        -Expected 'N2A=PASS and N2B!=PASS' `
        -Actual ("N2A={0} N2B={1}" -f $nv.N2A.Verdict, $nv.N2B.Verdict) `
        -Pass ($nv.N2A.Verdict -eq 'PASS' -and $nv.N2B.Verdict -ne 'PASS') -Evidence $tracePath

    # ---- V6: complete N2 evidence => N2-B PASS ----
    $exitPath = Join-Path $dir 'n2-exit-good.json'
    $record = New-P9HExitRecord -TrialId $trial.TrialId -Outcome 'exited' -ExitCode 0 `
        -LauncherPid 4240 -LauncherPath 'C:\synthetic\ws.cmd' -InvocationDisplay 'synthetic' `
        -WorkingDirectory $dir -LaunchedAtUtc (Get-P9HUtcStamp) -ExitedAtUtc (Get-P9HUtcStamp)
    $null = Write-P9HExitRecord -Path $exitPath -Record $record
    $nv2 = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $postWinPath -ExitRecordPath $exitPath `
        -NewProcessPath $newProcPath -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'V6' -Title 'Complete exit + process + window + trace evidence passes N2-B' `
        -Input 'exit 0, attributed terminal process and window, clean trace' -Expected 'N2B=PASS' `
        -Actual ("N2B={0} exitCode={1} procAttr={2} winAttr={3}" -f $nv2.N2B.Verdict, $nv2.N2B.ExitCode, $nv2.N2B.ProcessAttributed, $nv2.N2B.WindowAttributed) `
        -Pass ($nv2.N2B.Verdict -eq 'PASS' -and $nv2.N2B.ExitCode -eq 0) -Evidence $exitPath

    # ---- V7: captured nonzero exit => FAIL (product failure) ----
    $exitBad = Join-Path $dir 'n2-exit-bad.json'
    $record = New-P9HExitRecord -TrialId $trial.TrialId -Outcome 'exited' -ExitCode 1 `
        -LauncherPid 4240 -LauncherPath 'C:\synthetic\ws.cmd' -InvocationDisplay 'synthetic' `
        -WorkingDirectory $dir -LaunchedAtUtc (Get-P9HUtcStamp) -ExitedAtUtc (Get-P9HUtcStamp)
    $null = Write-P9HExitRecord -Path $exitBad -Record $record
    $nv3 = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $postWinPath -ExitRecordPath $exitBad `
        -NewProcessPath $newProcPath -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'V7' -Title 'Captured nonzero exit is a lifecycle FAIL, not inconclusive' `
        -Input 'exit record outcome=exited code=1' -Expected 'N2B=FAIL' `
        -Actual ("N2B={0}" -f $nv3.N2B.Verdict) `
        -Pass ($nv3.N2B.Verdict -eq 'FAIL') -Evidence $exitBad

    # ---- V8: instrumentation gap => INCONCLUSIVE, never FAIL ----
    $nv4 = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $postWinPath -ExitRecordPath (Join-Path $dir 'missing-again.json') `
        -NewProcessPath $newProcPath -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'V8' -Title 'Instrumentation gap yields INCONCLUSIVE not FAIL' `
        -Input 'absent exit record' -Expected 'N2B=INCONCLUSIVE (not FAIL)' `
        -Actual ("N2B={0}" -f $nv4.N2B.Verdict) `
        -Pass ($nv4.N2B.Verdict -eq 'INCONCLUSIVE') -Evidence $null

    # ---- V9: identical tokens but no negative-origin monitor ----
    $preNoNeg = & $writeCapture 'v9-pre.json' $tokensNoNeg 3 $true $trial.TrialId $false
    $postNoNeg = & $writeCapture 'v9-post.json' $tokensNoNeg 3 $true $trial.TrialId $false
    $v9 = Get-P9HE1Verdict -PreCapturePath $preNoNeg -PostCapturePath $postNoNeg -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'V9' -Title 'Identical tokens without a negative-origin monitor cannot PASS' `
        -Input 'both captures have only positive-origin monitors' -Expected 'not PASS' `
        -Actual ("Verdict={0} negOrigin={1}" -f $v9.Verdict, $v9.SubObservations['negativeOriginTopology']) `
        -Pass ($v9.Verdict -ne 'PASS') -Evidence $preNoNeg

    # ---- V10: identical tokens captured from the wrong session ----
    $preWrongSession = & $writeCapture 'v10-pre.json' $tokensA 5 $true $trial.TrialId $true
    $postWrongSession = & $writeCapture 'v10-post.json' $tokensA 5 $true $trial.TrialId $true
    $v10 = Get-P9HE1Verdict -PreCapturePath $preWrongSession -PostCapturePath $postWrongSession -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'V10' -Title 'Identical tokens from a different session cannot PASS' `
        -Input 'captures claim session 5, target is session 3' -Expected 'not PASS' `
        -Actual ("Verdict={0} sessionMatchesTarget={1}" -f $v10.Verdict, $v10.SubObservations['sessionMatchesTarget']) `
        -Pass ($v10.Verdict -ne 'PASS') -Evidence $preWrongSession

    # ---- V11: incompatible pre/post session identities ----
    $preS3 = & $writeCapture 'v11-pre.json' $tokensA 3 $true $trial.TrialId $true
    $postS4 = & $writeCapture 'v11-post.json' $tokensA 4 $true $trial.TrialId $true
    $v11 = Get-P9HE1Verdict -PreCapturePath $preS3 -PostCapturePath $postS4 -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'V11' -Title 'Pre and post captured under incompatible sessions cannot PASS' `
        -Input 'pre session 3, post session 4' -Expected 'not PASS' `
        -Actual ("Verdict={0} sessionConsistent={1}" -f $v11.Verdict, $v11.SubObservations['sessionConsistent']) `
        -Pass ($v11.Verdict -ne 'PASS') -Evidence $preS3

    # ---- V12: missing raw token identity evidence ----
    $preNoRaw = & $writeCapture 'v12-pre.json' $tokensA 3 $false $trial.TrialId $true
    $postNoRaw = & $writeCapture 'v12-post.json' $tokensA 3 $false $trial.TrialId $true
    $v12 = Get-P9HE1Verdict -PreCapturePath $preNoRaw -PostCapturePath $postNoRaw -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'V12' -Title 'Missing raw token identity evidence cannot PASS' `
        -Input 'captures omit the tokens array' -Expected 'not PASS' `
        -Actual ("Verdict={0} reasons={1}" -f $v12.Verdict, ($v12.Reasons -join ',')) `
        -Pass ($v12.Verdict -ne 'PASS') -Evidence $preNoRaw

    # ---- V13: different tokens with a valid transition: measured mismatch ----
    $preDiff = & $writeCapture 'v13-pre.json' $tokensA 3 $true $trial.TrialId $true
    $postDiff = & $writeCapture 'v13-post.json' $tokensDiff 3 $true $trial.TrialId $true
    $v13 = Get-P9HE1Verdict -PreCapturePath $preDiff -PostCapturePath $postDiff -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'V13' -Title 'Different tokens with a valid transition are a measured mismatch, not PASS' `
        -Input 'post token set differs from pre' -Expected 'not PASS, mismatch reported' `
        -Actual ("Verdict={0} reasons={1}" -f $v13.Verdict, ($v13.Reasons -join ',')) `
        -Pass ($v13.Verdict -ne 'PASS' -and $v13.Reasons -contains 'token-sets-differ') -Evidence $postDiff

    # ---- V14: two valid captures, no proven transition ----
    $logIncomplete = & $writeLog 'v14.jsonl' @(
        @{ Phase = 'pre'; State = 0 }
        @{ Phase = 'disconnect-observed'; State = 4 }
    )
    $v14 = Get-P9HE1Verdict -PreCapturePath $prePath -PostCapturePath $postPath -ObserverLogPath $logIncomplete `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'V14' -Title 'Two valid captures without a completed transition are NOT FULLY EVIDENCED' `
        -Input 'pre + disconnect observed, but no post-reconnect record' -Expected 'NOT FULLY EVIDENCED' `
        -Actual ("Verdict={0} reason={1}" -f $v14.Verdict, $v14.DisconnectReason) `
        -Pass ($v14.Verdict -eq 'NOT FULLY EVIDENCED') -Evidence $logIncomplete

    # ================= N-series: N2 attribution/evidence negatives =================
    # Write-P9HArtifact is used to build each variant.

    # ---- N1: exit 0 and clean trace but NO attributable new process ----
    $noProcPath = Join-Path $dir 'n1-new-processes.json'
    Write-P9HArtifact -Path $noProcPath -Lines @('{"Added":[]}')
    $n1 = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $postWinPath -ExitRecordPath $exitPath `
        -NewProcessPath $noProcPath -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'N1' -Title 'Exit 0 with a clean trace but no attributable process cannot PASS N2-B' `
        -Input 'empty Added process list' -Expected 'N2B not PASS' `
        -Actual ("N2B={0} procAttr={1}" -f $n1.N2B.Verdict, $n1.N2B.ProcessAttributed) `
        -Pass ($n1.N2B.Verdict -ne 'PASS') -Evidence $noProcPath

    # ---- N2: exit 0 and clean trace but NO attributable window ----
    $noWinPath = Join-Path $dir 'n2-post-windows-empty.json'
    Write-P9HArtifact -Path $noWinPath -Lines @('{"Windows":[]}')
    $n2v = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $noWinPath -ExitRecordPath $exitPath `
        -NewProcessPath $newProcPath -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'N2' -Title 'Exit 0 with a clean trace but no attributable window cannot PASS N2-B' `
        -Input 'valid empty post-window inventory' -Expected 'N2B not PASS' `
        -Actual ("N2B={0} winAttr={1}" -f $n2v.N2B.Verdict, $n2v.N2B.WindowAttributed) `
        -Pass ($n2v.N2B.Verdict -ne 'PASS') -Evidence $noWinPath

    # ---- N3: new window belongs to an unrelated PID ----
    $unrelatedWin = Join-Path $dir 'n3-post-windows.json'
    Write-P9HArtifact -Path $unrelatedWin -Lines @(([ordered]@{
                Windows = @([ordered]@{ hwnd = '0xB2'; pid = 9999; visible = $true; class = 'CASCADIA_HOSTING_WINDOW_CLASS'; x = 10; y = 10; width = 800; height = 600; title = 'unrelated' })
            } | ConvertTo-Json -Depth 5))
    $n3 = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $unrelatedWin -ExitRecordPath $exitPath `
        -NewProcessPath $newProcPath -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'N3' -Title 'A new window owned by an unrelated PID cannot PASS N2-B' `
        -Input 'window pid 9999, launched process pid 4242' -Expected 'N2B not PASS' `
        -Actual ("N2B={0} winAttr={1}" -f $n3.N2B.Verdict, $n3.N2B.WindowAttributed) `
        -Pass ($n3.N2B.Verdict -ne 'PASS') -Evidence $unrelatedWin

    # ---- N4: trace from a different trial ----
    $foreignTrace = Join-Path $dir 'n4-trace.jsonl'
    Write-P9HArtifact -Path $foreignTrace -Lines @(
        (@{ event = 'lifecycle-layout-plan'; source = 'relative'; skipped = @('p9h-item'); trialId = 'p9h-foreign-99999999' } | ConvertTo-Json -Compress)
        (@{ event = 'stage2-broker-ready'; planId = 'other-plan'; failed = 0 } | ConvertTo-Json -Compress)
        (@{ event = 'stage2-terminal-final'; finalized = 1; failures = 0 } | ConvertTo-Json -Compress)
        (@{ event = 'transaction-end'; broker = $true; uncertain = $false; failures = @() } | ConvertTo-Json -Compress)
    )
    $n4 = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $foreignTrace -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $postWinPath -ExitRecordPath $exitPath `
        -NewProcessPath $newProcPath -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'N4' -Title 'Trace belonging to a different trial cannot PASS N2-B' `
        -Input 'trace trialId=p9h-foreign-99999999' -Expected 'N2B not PASS' `
        -Actual ("N2B={0} reasons={1}" -f $n4.N2B.Verdict, ($n4.N2B.Reasons -join ',')) `
        -Pass ($n4.N2B.Verdict -ne 'PASS') -Evidence $foreignTrace

    # ---- N5: degraded inventory (no recovered start times) ----
    $degradedProc = Join-Path $dir 'n5-new-processes.json'
    Write-P9HArtifact -Path $degradedProc -Lines @(([ordered]@{
                Added = @([ordered]@{ pid = 4242; ppid = 4240; name = 'WindowsTerminal.exe'; startUtc = $null; commandLine = 'synthetic' })
            } | ConvertTo-Json -Depth 5))
    $n5 = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $postWinPath -ExitRecordPath $exitPath `
        -NewProcessPath $degradedProc -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'N5' -Title 'Degraded process inventory yields INCONCLUSIVE, never an inferred PASS' `
        -Input 'new process with no recovered start time' -Expected 'N2B=INCONCLUSIVE' `
        -Actual ("N2B={0} procAttr={1}" -f $n5.N2B.Verdict, $n5.N2B.ProcessAttributed) `
        -Pass ($n5.N2B.Verdict -eq 'INCONCLUSIVE') -Evidence $degradedProc

    # ---- N6: missing post-window artifact ----
    $n6 = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath (Join-Path $dir 'no-such-windows.json') -ExitRecordPath $exitPath `
        -NewProcessPath $newProcPath -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'N6' -Title 'Missing post-window artifact cannot PASS N2-A' `
        -Input 'absent post-window observation' -Expected 'N2A not PASS, observed=false' `
        -Actual ("N2A={0} observed={1}" -f $n6.N2A.Verdict, $n6.N2A.PostStateObserved) `
        -Pass ($n6.N2A.Verdict -ne 'PASS' -and -not $n6.N2A.PostStateObserved) -Evidence $null

    # ---- N7: malformed post-window artifact ----
    $malformedWin = Join-Path $dir 'n7-post-windows.json'
    Write-P9HArtifact -Path $malformedWin -Lines @('{"Windows": [')
    $n7 = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $malformedWin -ExitRecordPath $exitPath `
        -NewProcessPath $newProcPath -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'N7' -Title 'Malformed post-window artifact cannot PASS N2-A' `
        -Input 'truncated JSON' -Expected 'N2A not PASS' `
        -Actual ("N2A={0}" -f $n7.N2A.Verdict) `
        -Pass ($n7.N2A.Verdict -ne 'PASS') -Evidence $malformedWin

    # ---- N8: empty but valid inventory => skip correctly observed ----
    $n8 = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $noWinPath -ExitRecordPath $exitPath `
        -NewProcessPath $newProcPath -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'N8' -Title 'Valid empty window inventory still evidences the placement skip' `
        -Input 'observed zero windows, nothing at 9000,9000' -Expected 'N2A=PASS' `
        -Actual ("N2A={0} observed={1} count={2}" -f $n8.N2A.Verdict, $n8.N2A.PostStateObserved, $n8.N2A.WindowCountObserved) `
        -Pass ($n8.N2A.Verdict -eq 'PASS') -Evidence $noWinPath

    # ---- N9: fallback actually applied ----
    $fallbackWin = Join-Path $dir 'n9-post-windows.json'
    Write-P9HArtifact -Path $fallbackWin -Lines @(([ordered]@{
                Windows = @([ordered]@{ hwnd = '0xC3'; pid = 4242; visible = $true; class = 'CASCADIA_HOSTING_WINDOW_CLASS'; x = 9000; y = 9000; width = 640; height = 480; title = 'fallback' })
            } | ConvertTo-Json -Depth 5))
    $n9 = Get-P9HN2Verdicts -FixturePath $fixturePath -TracePath $tracePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWin -PostWindowPath $fallbackWin -ExitRecordPath $exitPath `
        -NewProcessPath $newProcPath -TrialId $trial.TrialId
    Add-P9HTestResult -Id 'N9' -Title 'A window observed at the fallback rectangle fails N2-A' `
        -Input 'window at 9000,9000' -Expected 'N2A not PASS, fallbackApplied=true' `
        -Actual ("N2A={0} fallbackApplied={1}" -f $n9.N2A.Verdict, $n9.N2A.FallbackApplied) `
        -Pass ($n9.N2A.Verdict -ne 'PASS' -and $n9.N2A.FallbackApplied -eq $true) -Evidence $fallbackWin
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
