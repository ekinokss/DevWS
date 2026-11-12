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
    # E1 (V), N2 attribution (N), trace/attribution (W), and evidence-contract (X)
    # verdict tests.
    #
    # Stage 2.3 restored the nine N-series cases that Stage 2.2 dropped when it
    # replaced this function, so the registered total is 96 (70 + 14 W + 12 X).
    # N8's expectation is adapted: an empty window inventory no longer evidences
    # the skip, because N2-A requires positively observed window creation.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $trial = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind selftest
    $dir = $trial.Directory
    $tid = $trial.TrialId
    $logon = '2026-11-11T10:00:00.0000000Z'

    $windowId = 'DevWS-main-p9h-item'
    $terminalId = 'p9h-item'
    $setId = 'main'

    # ---------- capture builder ----------
    $writeCapture = {
        param(
            [string]$name, [string[]]$tokens, [int]$sessionId = 3,
            [bool]$includeTokens = $true, [bool]$includeRecords = $true,
            [string]$trialId = '', [bool]$withNegativeOrigin = $true,
            [string]$capturedUtc = '', [string[]]$recordIdentities = $null,
            [string[]]$recordRects = $null
        )
        $obj = [ordered]@{ tokenCount = $tokens.Count; identityComplete = $true; sessionId = $sessionId }
        if ([string]::IsNullOrWhiteSpace($capturedUtc)) { $capturedUtc = Get-P9HUtcStamp }
        $obj.capturedUtc = $capturedUtc
        if (-not [string]::IsNullOrWhiteSpace($trialId)) { $obj.trialId = $trialId }
        if ($includeTokens) { $obj.tokens = $tokens }

        if ($includeRecords) {
            $ids = if ($null -ne $recordIdentities) { $recordIdentities } else { $tokens }
            $records = [System.Collections.Generic.List[pscustomobject]]::new()
            for ($i = 0; $i -lt $ids.Count; $i++) {
                $rect = if ($null -ne $recordRects -and $i -lt $recordRects.Count) { $recordRects[$i] }
                        elseif ($i -eq 1 -and $withNegativeOrigin) { 'x=-2560 y=-355 w=2560 h=1440' }
                        elseif ($i -eq 1) { 'x=2560 y=0 w=2560 h=1440' }
                        else { 'x=0 y=0 w=1920 h=1080' }
                $records.Add([pscustomobject][ordered]@{ identity = $ids[$i]; rect = $rect })
            }
            $obj.parsedMonitors = @($records)
            $obj.tokenRectBytes = (@($records | ForEach-Object { '{0}@{1}' -f $_.identity, $_.rect }) -join ';')
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

    $preUtc = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o')
    $postUtc = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o')

    $prePath = & $writeCapture 'e1-pre.json' $tokensA 3 $true $true $tid $true $preUtc
    $logGood = & $writeLog 'v-good.jsonl' @(
        @{ Phase = 'pre'; State = 0 }
        @{ Phase = 'disconnect-observed'; State = 4 }
        @{ Phase = 'post'; State = 0 }
    )
    $postPath = & $writeCapture 'e1-post.json' $tokensA 3 $true $true $tid $true $postUtc

    # ======================= E1 V-series =======================
    $v = Get-P9HE1Verdict -PreCapturePath $prePath -PostCapturePath $postPath -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'V1' -Title 'Complete valid dataset satisfies E1' `
        -Input 'raw monitors + negative origin + bracketing captures + transition' -Expected 'PASS' `
        -Actual ("Verdict={0} reasons={1}" -f $v.Verdict, ($v.Reasons -join ',')) `
        -Pass ($v.Verdict -eq 'PASS') -Evidence $logGood

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

    $records = @([pscustomobject]@{ SessionId = 3; User = 'qauser'; State = 4; StationName = 'RDP-Tcp#0'; LogonTime = '2026-11-11T11:11:11.0000000Z' })
    $m = Get-P9HTargetSessionRecord -Records $records -SessionId 3 -User 'qauser' -LogonTime $logon
    Add-P9HTestResult -Id 'V3' -Title 'A new logon reusing the session id is not accepted' `
        -Input 'logon 11:11:11Z vs pinned 10:00:00Z' -Expected 'logon-mismatch' `
        -Actual ("Ok={0} reason={1}" -f $m.Ok, $m.Reason) `
        -Pass ((-not $m.Ok) -and $m.Reason -eq 'logon-mismatch') -Evidence $null

    # ======================= shared N2 fixtures =======================
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

    $postWinPath = Join-Path $dir 'n2-post-windows.json'
    Write-P9HArtifact -Path $postWinPath -Lines @(([ordered]@{
                Windows = @([ordered]@{ hwnd = '0xA1'; pid = 4242; visible = $true; class = 'CASCADIA_HOSTING_WINDOW_CLASS'; x = 44; y = 52; width = 1129; height = 635; title = $windowId })
            } | ConvertTo-Json -Depth 5))

    # The argv the PRODUCT actually writes (src/lib/devws-terminal.ps1:182-199).
    $bootstrapCmd = 'pwsh.exe -NoExit -File "C:\Program Files\DevWS\privileged\helpers\cwd-shell-bootstrap.ps1" ' +
        "-SetId $setId -TerminalId $terminalId -WindowId $windowId -TabIndex 0 -SessionId synthetic-session " +
        '-PublicationPath "C:\ProgramData\DevWS\x.json" -ChildSpecBase64 e30='

    $launchStart = (Get-Date).ToUniversalTime().AddMinutes(-1)
    $launchEnd = (Get-Date).ToUniversalTime().AddMinutes(1)
    $procStart = (Get-Date).ToUniversalTime()

    $newProcPath = Join-Path $dir 'n2-new-processes.json'
    Write-P9HArtifact -Path $newProcPath -Lines @(([ordered]@{
                Added = @([ordered]@{ pid = 4242; ppid = 4240; name = 'pwsh.exe'; startUtc = $procStart.ToString('o'); commandLine = $bootstrapCmd })
            } | ConvertTo-Json -Depth 5))

    $exitPath = Join-Path $dir 'n2-exit-good.json'
    $rec = New-P9HExitRecord -TrialId $tid -Outcome 'exited' -ExitCode 0 -LauncherPid 4240 `
        -LauncherPath 'C:\synthetic\ws.cmd' -InvocationDisplay 'synthetic' -WorkingDirectory $dir `
        -LaunchedAtUtc $launchStart.ToString('o') -ExitedAtUtc $launchEnd.ToString('o')
    $null = Write-P9HExitRecord -Path $exitPath -Record $rec

    # The REAL production trace shape: framework fields event/utcMs/pid, data
    # fields per src/lib/devws-launch.ps1, planId ONLY on broker-ready, and `set`
    # as the transaction identity (the product emits no trialId at all).
    $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $mkEvent = {
        param([string]$event, [hashtable]$extra, [long]$offsetMs)
        $o = @{ event = $event; utcMs = ($nowMs + $offsetMs); pid = 9000 }
        foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] }
        return ($o | ConvertTo-Json -Compress)
    }

    $traceLines = @(
        (& $mkEvent 'lifecycle-layout-plan' @{ set = $setId; profileAware = $false; source = 'relative'; profileId = ''; fingerprint = 'SYNTH1234'; skipped = @($terminalId) } 0)
        (& $mkEvent 'transaction-start' @{ set = $setId; terminals = 1; apps = 0 } 10)
        (& $mkEvent 'stage2-broker-prepare-sent' @{ set = $setId } 20)
        (& $mkEvent 'stage2-broker-ready' @{ planId = 'plan-real-1'; elapsedMs = 1140; present = 0; missing = 1; ambiguous = 0; failed = 0 } 30)
        (& $mkEvent 'stage2-go-ack' @{ recheckMs = 0; ackAt = 123 } 40)
        (& $mkEvent 'stage2-terminal-kick' @{ count = 1; firstAt = 456; lastAt = 456 } 50)
        (& $mkEvent 'stage2-terminal-final' @{ finalized = 1; failures = 0 } 60)
        (& $mkEvent 'transaction-end' @{ set = $setId; broker = $true; uncertain = $false; layoutSource = 'relative'; profileId = ''; failures = @() } 70)
    )
    $tracePath = Join-Path $dir 'n2-trace.jsonl'
    Write-P9HArtifact -Path $tracePath -Lines $traceLines

    $n2args = @{
        FixturePath = $fixturePath; StdoutPath = $stdoutPath
        PreWindowPath = $preWin; PostWindowPath = $postWinPath
        ExitRecordPath = $exitPath; NewProcessPath = $newProcPath
        TrialId = $tid
        ExpectedWindowId = $windowId; ExpectedTerminalId = $terminalId; ExpectedSetId = $setId
        ArtifactIndexPath = (Join-Path $dir 'artifact-index.jsonl')
    }

    # Collector-style artifact binding for the shared fixtures. The verdict now
    # REQUIRES a bound artifact index, so the positive cases register their
    # artifacts exactly as a real collector would.
    $bindCtx = [pscustomobject]@{ TrialId = $tid; Directory = $dir }
    foreach ($pair in @(
            @{ p = $fixturePath; r = 'fixture' }
            @{ p = $stdoutPath; r = 'stdout' }
            @{ p = $preWin; r = 'pre-windows' }
            @{ p = $postWinPath; r = 'post-windows' }
            @{ p = $exitPath; r = 'exit-record' }
            @{ p = $newProcPath; r = 'new-processes' }
            @{ p = $tracePath; r = 'trace' }
        )) {
        $null = Add-P9HArtifactRole -Context $bindCtx -Path $pair.p -Role $pair.r
    }

    function Try-N2([hashtable]$overrides) {
        $a = Copy-P9HArgs -Table $n2args
        $a.TracePath = $tracePath
        foreach ($k in $overrides.Keys) { $a[$k] = $overrides[$k] }
        return Get-P9HN2Verdicts @a
    }

    # ======================= N2 V-series =======================
    $a4 = Copy-P9HArgs -Table $n2args; $a4.TracePath = $tracePath; $a4.ExitRecordPath = (Join-Path $dir 'missing-exit.json')
    $nv = Get-P9HN2Verdicts @a4
    Add-P9HTestResult -Id 'V4' -Title 'Clean broker trace without exit record cannot PASS N2-B' `
        -Input 'absent exit record' -Expected 'N2B=INCONCLUSIVE' `
        -Actual ("N2B={0}" -f $nv.N2B.Verdict) -Pass ($nv.N2B.Verdict -eq 'INCONCLUSIVE') -Evidence $tracePath
    # V5 proves INDEPENDENCE: N2-A can PASS while N2-B does not. It must break
    # only an N2-B input, because a missing exit record also removes the launch
    # window that N2-A attribution needs, making BOTH verdicts indeterminate
    # (that is V4's point, not V5's).
    $v5BadTrace = Join-Path $dir 'v5-trace.jsonl'
    Write-P9HArtifact -Path $v5BadTrace -Lines @(
        (& $mkEvent 'lifecycle-layout-plan' @{ set = $setId; profileAware = $false; source = 'relative'; profileId = ''; fingerprint = 'X'; skipped = @($terminalId) } 0)
        (& $mkEvent 'stage2-broker-ready' @{ planId = 'plan-v5'; elapsedMs = 1; present = 0; missing = 1; ambiguous = 0; failed = 0 } 30)
        (& $mkEvent 'stage2-terminal-final' @{ finalized = 1; failures = 1 } 60)
        (& $mkEvent 'transaction-end' @{ set = $setId; broker = $true; uncertain = $false; layoutSource = 'relative'; profileId = ''; failures = @('terminal identification failed') } 70)
    )
    $nv5 = Try-N2 @{ TracePath = $v5BadTrace }
    # V5 proves INDEPENDENCE: N2-A can PASS while N2-B does not. The isolating
    # input keeps the trace, window and attribution evidence fully valid and
    # breaks ONLY an N2-B input - a captured NONZERO exit code. (A broken trace
    # would fail both verdicts, which is V4's territory, not an independence proof.)
    $exitV5 = Join-Path $dir 'v5-exit-nonzero.json'
    $recV5 = New-P9HExitRecord -TrialId $tid -Outcome 'exited' -ExitCode 3 -LauncherPid 4240 `
        -LauncherPath 'C:\synthetic\ws.cmd' -InvocationDisplay 'synthetic' -WorkingDirectory $dir `
        -LaunchedAtUtc $launchStart.ToString('o') -ExitedAtUtc $launchEnd.ToString('o')
    $null = Write-P9HExitRecord -Path $exitV5 -Record $recV5
    # Stage 2.4.1: the exit record must ALSO be attributed to this trial, exactly
    # as a real collector would record it. Only the lifecycle OUTCOME differs
    # here, so the independence proof stays isolated to the exit code; the index
    # is append-only, so the latest entry for the role wins and is restored below.
    $null = Add-P9HArtifactRole -Context $bindCtx -Path $exitV5 -Role 'exit-record'
    $nv5 = Try-N2 @{ ExitRecordPath = $exitV5 }
    Add-P9HTestResult -Id 'V5' -Title 'N2-A PASS does not imply N2-B PASS' `
        -Input 'valid trace and window evidence, captured nonzero exit code 3' `
        -Expected 'N2A=PASS and N2B!=PASS' `
        -Actual ("N2A={0} N2B={1}" -f $nv5.N2A.Verdict, $nv5.N2B.Verdict) `
        -Pass ($nv5.N2A.Verdict -eq 'PASS' -and $nv5.N2B.Verdict -ne 'PASS') -Evidence $exitV5
    # Restore the shared good binding (append-only: the latest role entry wins).
    $null = Add-P9HArtifactRole -Context $bindCtx -Path $exitPath -Role 'exit-record'

    $nv2 = Try-N2 @{}
    Add-P9HTestResult -Id 'V6' -Title 'Complete evidence passes N2-B (real detached architecture)' `
        -Input 'production-shaped trace + exit 0 + argv identity + attributed window' -Expected 'N2B=PASS' `
        -Actual ("N2B={0} exit={1} procAttr={2} winAttr={3} trace={4} planId={5}" -f $nv2.N2B.Verdict, $nv2.N2B.ExitCode, $nv2.N2B.ProcessAttributed, $nv2.N2B.WindowAttributed, $nv2.N2B.TraceValid, $nv2.N2B.TracePlanId) `
        -Pass ($nv2.N2B.Verdict -eq 'PASS' -and $nv2.N2B.ExitCode -eq 0) -Evidence $exitPath

    $exitBad = Join-Path $dir 'n2-exit-bad.json'
    $recBad = New-P9HExitRecord -TrialId $tid -Outcome 'exited' -ExitCode 1 -LauncherPid 4240 `
        -LauncherPath 'C:\synthetic\ws.cmd' -InvocationDisplay 'synthetic' -WorkingDirectory $dir `
        -LaunchedAtUtc $launchStart.ToString('o') -ExitedAtUtc $launchEnd.ToString('o')
    $null = Write-P9HExitRecord -Path $exitBad -Record $recBad
    $nv3 = Try-N2 @{ ExitRecordPath = $exitBad }
    Add-P9HTestResult -Id 'V7' -Title 'Captured nonzero exit is a lifecycle FAIL' `
        -Input 'exit code 1' -Expected 'N2B=FAIL' -Actual ("N2B={0}" -f $nv3.N2B.Verdict) `
        -Pass ($nv3.N2B.Verdict -eq 'FAIL') -Evidence $exitBad

    $nv4 = Try-N2 @{ ExitRecordPath = (Join-Path $dir 'none.json') }
    Add-P9HTestResult -Id 'V8' -Title 'Instrumentation gap yields INCONCLUSIVE not FAIL' `
        -Input 'absent exit record' -Expected 'N2B=INCONCLUSIVE' `
        -Actual ("N2B={0}" -f $nv4.N2B.Verdict) -Pass ($nv4.N2B.Verdict -eq 'INCONCLUSIVE') -Evidence $null

    $p9 = & $writeCapture 'v9-pre.json' $tokensA 3 $true $true $tid $false $preUtc
    $q9 = & $writeCapture 'v9-post.json' $tokensA 3 $true $true $tid $false $postUtc
    $v9 = Get-P9HE1Verdict -PreCapturePath $p9 -PostCapturePath $q9 -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'V9' -Title 'Identical tokens without a negative-origin monitor cannot PASS' `
        -Input 'positive-origin monitors only' -Expected 'not PASS' `
        -Actual ("Verdict={0} negObserved={1}" -f $v9.Verdict, $v9.SubObservations['negativeOriginObserved']) `
        -Pass ($v9.Verdict -ne 'PASS') -Evidence $p9

    $p10 = & $writeCapture 'v10-pre.json' $tokensA 5 $true $true $tid $true $preUtc
    $q10 = & $writeCapture 'v10-post.json' $tokensA 5 $true $true $tid $true $postUtc
    $v10 = Get-P9HE1Verdict -PreCapturePath $p10 -PostCapturePath $q10 -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'V10' -Title 'Identical tokens from a different session cannot PASS' `
        -Input 'captures claim session 5' -Expected 'not PASS' `
        -Actual ("Verdict={0} matchTarget={1}" -f $v10.Verdict, $v10.SubObservations['sessionMatchesTarget']) `
        -Pass ($v10.Verdict -ne 'PASS') -Evidence $p10

    $p11 = & $writeCapture 'v11-pre.json' $tokensA 3 $true $true $tid $true $preUtc
    $q11 = & $writeCapture 'v11-post.json' $tokensA 4 $true $true $tid $true $postUtc
    $v11 = Get-P9HE1Verdict -PreCapturePath $p11 -PostCapturePath $q11 -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'V11' -Title 'Incompatible pre/post sessions cannot PASS' `
        -Input 'pre 3, post 4' -Expected 'not PASS' `
        -Actual ("Verdict={0} consistent={1}" -f $v11.Verdict, $v11.SubObservations['sessionConsistent']) `
        -Pass ($v11.Verdict -ne 'PASS') -Evidence $p11

    $p12 = & $writeCapture 'v12-pre.json' $tokensA 3 $false $false $tid $true $preUtc
    $q12 = & $writeCapture 'v12-post.json' $tokensA 3 $false $false $tid $true $postUtc
    $v12 = Get-P9HE1Verdict -PreCapturePath $p12 -PostCapturePath $q12 -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'V12' -Title 'Missing raw token identity evidence cannot PASS' `
        -Input 'no tokens and no monitor records' -Expected 'not PASS' `
        -Actual ("Verdict={0} reasons={1}" -f $v12.Verdict, ($v12.Reasons -join ',')) `
        -Pass ($v12.Verdict -ne 'PASS') -Evidence $p12

    $p13 = & $writeCapture 'v13-pre.json' $tokensA 3 $true $true $tid $true $preUtc
    $q13 = & $writeCapture 'v13-post.json' $tokensDiff 3 $true $true $tid $true $postUtc
    $v13 = Get-P9HE1Verdict -PreCapturePath $p13 -PostCapturePath $q13 -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'V13' -Title 'Different tokens with a valid transition are a measured mismatch' `
        -Input 'post token set differs' -Expected 'not PASS, sets-differ reported' `
        -Actual ("Verdict={0} reasons={1}" -f $v13.Verdict, ($v13.Reasons -join ',')) `
        -Pass ($v13.Verdict -ne 'PASS' -and $v13.Reasons -contains 'token-sets-differ') -Evidence $q13

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

    # ======================= N-series (RESTORED from Stage 2.1) =======================
    # N1: exit 0 + clean trace but NO attributable new process.
    $noProcPath = Join-Path $dir 'n1-new-processes.json'
    Write-P9HArtifact -Path $noProcPath -Lines @('{"Added":[]}')
    $n1 = Try-N2 @{ NewProcessPath = $noProcPath }
    Add-P9HTestResult -Id 'N1' -Title 'Exit 0 with a clean trace but no attributable process cannot PASS N2-B' `
        -Input 'empty Added process list' -Expected 'N2B not PASS' `
        -Actual ("N2B={0} procAttr={1} reason={2}" -f $n1.N2B.Verdict, $n1.N2B.ProcessAttributed, $n1.N2B.AttributionReason) `
        -Pass ($n1.N2B.Verdict -ne 'PASS') -Evidence $noProcPath

    # N2: exit 0 + clean trace but NO attributable window.
    $noWinPath = Join-Path $dir 'n2-post-windows-empty.json'
    Write-P9HArtifact -Path $noWinPath -Lines @('{"Windows":[]}')
    $n2v = Try-N2 @{ PostWindowPath = $noWinPath }
    Add-P9HTestResult -Id 'N2' -Title 'Exit 0 with a clean trace but no attributable window cannot PASS N2-B' `
        -Input 'valid empty post-window inventory' -Expected 'N2B not PASS' `
        -Actual ("N2B={0} winAttr={1}" -f $n2v.N2B.Verdict, $n2v.N2B.WindowAttributed) `
        -Pass ($n2v.N2B.Verdict -ne 'PASS') -Evidence $noWinPath

    # N3: new window owned by an unrelated PID.
    $unrelatedWin = Join-Path $dir 'n3-post-windows.json'
    Write-P9HArtifact -Path $unrelatedWin -Lines @(([ordered]@{
                Windows = @([ordered]@{ hwnd = '0xB2'; pid = 9999; visible = $true; class = 'CASCADIA_HOSTING_WINDOW_CLASS'; x = 10; y = 10; width = 800; height = 600; title = 'unrelated' })
            } | ConvertTo-Json -Depth 5))
    $n3 = Try-N2 @{ PostWindowPath = $unrelatedWin }
    Add-P9HTestResult -Id 'N3' -Title 'A new window owned by an unrelated PID cannot PASS N2-B' `
        -Input 'window pid 9999, launched process pid 4242' -Expected 'N2B not PASS' `
        -Actual ("N2B={0} winAttr={1}" -f $n3.N2B.Verdict, $n3.N2B.WindowAttributed) `
        -Pass ($n3.N2B.Verdict -ne 'PASS') -Evidence $unrelatedWin

    # N4: trace from a different transaction (`set` mismatch - the product's id).
    $foreignTrace = Join-Path $dir 'n4-trace.jsonl'
    Write-P9HArtifact -Path $foreignTrace -Lines @(
        (& $mkEvent 'lifecycle-layout-plan' @{ set = 'other-set'; profileAware = $false; source = 'relative'; profileId = ''; fingerprint = 'X'; skipped = @($terminalId) } 0)
        (& $mkEvent 'stage2-broker-ready' @{ planId = 'plan-foreign'; elapsedMs = 1; present = 0; missing = 1; ambiguous = 0; failed = 0 } 30)
        (& $mkEvent 'stage2-terminal-final' @{ finalized = 1; failures = 0 } 60)
        (& $mkEvent 'transaction-end' @{ set = 'other-set'; broker = $true; uncertain = $false; layoutSource = 'relative'; profileId = ''; failures = @() } 70)
    )
    $n4 = Try-N2 @{ TracePath = $foreignTrace }
    Add-P9HTestResult -Id 'N4' -Title 'A trace belonging to a different transaction cannot PASS N2-B' `
        -Input "trace set='other-set'" -Expected 'N2B not PASS' `
        -Actual ("N2B={0} reasons={1}" -f $n4.N2B.Verdict, ($n4.N2B.Reasons -join ',')) `
        -Pass ($n4.N2B.Verdict -ne 'PASS') -Evidence $foreignTrace

    # N5: degraded process evidence (no recovered start time).
    $degradedProc = Join-Path $dir 'n5-new-processes.json'
    Write-P9HArtifact -Path $degradedProc -Lines @(([ordered]@{
                Added = @([ordered]@{ pid = 4242; ppid = 4240; name = 'pwsh.exe'; startUtc = $null; commandLine = $bootstrapCmd })
            } | ConvertTo-Json -Depth 5))
    $n5 = Try-N2 @{ NewProcessPath = $degradedProc }
    Add-P9HTestResult -Id 'N5' -Title 'Degraded process evidence yields INCONCLUSIVE, never an inferred PASS' `
        -Input 'new process with no recovered start time' -Expected 'N2B=INCONCLUSIVE' `
        -Actual ("N2B={0} procAttr={1}" -f $n5.N2B.Verdict, $n5.N2B.ProcessAttributed) `
        -Pass ($n5.N2B.Verdict -eq 'INCONCLUSIVE') -Evidence $degradedProc

    # N6: missing post-window artifact.
    $n6 = Try-N2 @{ PostWindowPath = (Join-Path $dir 'no-such-windows.json') }
    Add-P9HTestResult -Id 'N6' -Title 'Missing post-window artifact cannot PASS N2-A' `
        -Input 'absent post-window observation' -Expected 'N2A not PASS, observed=false' `
        -Actual ("N2A={0} postObserved={1}" -f $n6.N2A.Verdict, $n6.N2A.PostStateObserved) `
        -Pass ($n6.N2A.Verdict -ne 'PASS' -and -not $n6.N2A.PostStateObserved) -Evidence $null

    # N7: malformed post-window artifact.
    $malformedWin = Join-Path $dir 'n7-post-windows.json'
    Write-P9HArtifact -Path $malformedWin -Lines @('{"Windows": [')
    $n7 = Try-N2 @{ PostWindowPath = $malformedWin }
    Add-P9HTestResult -Id 'N7' -Title 'Malformed post-window artifact cannot PASS N2-A' `
        -Input 'truncated JSON' -Expected 'N2A not PASS' `
        -Actual ("N2A={0}" -f $n7.N2A.Verdict) `
        -Pass ($n7.N2A.Verdict -ne 'PASS') -Evidence $malformedWin

    # N8: EMPTY but valid inventory. Stage 2.1 expected PASS here; Stage 2.3
    # requires positively observed window creation, so an empty inventory is an
    # evidence gap, NOT a placement-skip PASS.
    $n8 = Try-N2 @{ PostWindowPath = $noWinPath }
    Add-P9HTestResult -Id 'N8' -Title 'A valid but empty window inventory cannot evidence the placement skip' `
        -Input 'observed zero windows, nothing at 9000,9000' -Expected 'N2A not PASS (no window creation observed)' `
        -Actual ("N2A={0} postObserved={1} postCount={2}" -f $n8.N2A.Verdict, $n8.N2A.PostStateObserved, $n8.N2A.PostWindowCount) `
        -Pass ($n8.N2A.Verdict -ne 'PASS') -Evidence $noWinPath

    # N9: fallback actually applied.
    $fallbackWin = Join-Path $dir 'n9-post-windows.json'
    Write-P9HArtifact -Path $fallbackWin -Lines @(([ordered]@{
                Windows = @([ordered]@{ hwnd = '0xC3'; pid = 4242; visible = $true; class = 'CASCADIA_HOSTING_WINDOW_CLASS'; x = 9000; y = 9000; width = 640; height = 480; title = 'fallback' })
            } | ConvertTo-Json -Depth 5))
    $n9 = Try-N2 @{ PostWindowPath = $fallbackWin }
    Add-P9HTestResult -Id 'N9' -Title 'A window observed at the fallback rectangle fails N2-A' `
        -Input 'window at 9000,9000' -Expected 'N2A not PASS, fallbackApplied=true' `
        -Actual ("N2A={0} fallbackApplied={1}" -f $n9.N2A.Verdict, $n9.N2A.FallbackApplied) `
        -Pass ($n9.N2A.Verdict -ne 'PASS' -and $n9.N2A.FallbackApplied -eq $true) -Evidence $fallbackWin

    # ======================= W-series: trace validity + attribution =======================
    $w1 = Try-N2 @{}
    Add-P9HTestResult -Id 'W1' -Title 'Complete valid production trace with attribution is eligible for PASS' `
        -Input 'real schema: set + utcMs + planId on broker-ready' -Expected 'PASS' `
        -Actual ("N2B={0} traceOk={1} planId={2}" -f $w1.N2B.Verdict, $w1.N2B.TraceValid, $w1.N2B.TracePlanId) `
        -Pass ($w1.N2B.Verdict -eq 'PASS') -Evidence $tracePath

    $t2 = Join-Path $dir 'w2-trace.jsonl'
    Write-P9HArtifact -Path $t2 -Lines @($traceLines[0], $traceLines[3], '{"event":"noise","junk":', $traceLines[6], $traceLines[7])
    $w2 = Try-N2 @{ TracePath = $t2 }
    Add-P9HTestResult -Id 'W2' -Title 'Valid events plus one malformed trace line cannot PASS' `
        -Input 'all required events present, one line unparseable' -Expected 'not PASS' `
        -Actual ("N2B={0} reason={1}" -f $w2.N2B.Verdict, ($w2.N2B.Reasons -join ',')) `
        -Pass ($w2.N2B.Verdict -ne 'PASS') -Evidence $t2

    $t3 = Join-Path $dir 'w3-trace.jsonl'
    Write-P9HArtifact -Path $t3 -Lines @($traceLines[0], $traceLines[3], $traceLines[7])
    $w3 = Try-N2 @{ TracePath = $t3 }
    Add-P9HTestResult -Id 'W3' -Title 'A trace missing a required event cannot PASS' `
        -Input 'no stage2-terminal-final' -Expected 'not PASS' `
        -Actual ("N2B={0}" -f $w3.N2B.Verdict) -Pass ($w3.N2B.Verdict -ne 'PASS') -Evidence $t3

    $t4 = Join-Path $dir 'w4-trace.jsonl'
    Write-P9HArtifact -Path $t4 -Lines @($traceLines[0], $traceLines[3],
        (& $mkEvent 'stage2-terminal-final' @{ finalized = 1; failures = 2 } 55), $traceLines[6], $traceLines[7])
    $w4 = Try-N2 @{ TracePath = $t4 }
    Add-P9HTestResult -Id 'W4' -Title 'Contradictory finalization events cannot PASS' `
        -Input 'two terminal-final events with different outcomes' -Expected 'not PASS' `
        -Actual ("N2B={0} reason={1}" -f $w4.N2B.Verdict, ($w4.N2B.Reasons -join ',')) `
        -Pass ($w4.N2B.Verdict -ne 'PASS') -Evidence $t4

    # W5: events from different transactions (set conflict) - the product's own id.
    $t5 = Join-Path $dir 'w5-trace.jsonl'
    Write-P9HArtifact -Path $t5 -Lines @(
        (& $mkEvent 'lifecycle-layout-plan' @{ set = $setId; profileAware = $false; source = 'relative'; profileId = ''; fingerprint = 'X'; skipped = @($terminalId) } 0)
        (& $mkEvent 'stage2-broker-ready' @{ planId = 'plan-1'; elapsedMs = 1; present = 0; missing = 1; ambiguous = 0; failed = 0 } 30)
        (& $mkEvent 'stage2-terminal-final' @{ finalized = 1; failures = 0 } 60)
        (& $mkEvent 'transaction-end' @{ set = 'conflicting-set'; broker = $true; uncertain = $false; layoutSource = 'relative'; profileId = ''; failures = @() } 70)
    )
    $w5 = Try-N2 @{ TracePath = $t5 }
    Add-P9HTestResult -Id 'W5' -Title 'Events carrying conflicting transaction identities cannot PASS' `
        -Input "plan set='$setId', transaction-end set='conflicting-set'" -Expected 'not PASS' `
        -Actual ("N2B={0} reason={1}" -f $w5.N2B.Verdict, ($w5.N2B.Reasons -join ',')) `
        -Pass ($w5.N2B.Verdict -ne 'PASS') -Evidence $t5

    # W6: incompatible plan ids (broker-ready vs broker-replanned).
    $t6 = Join-Path $dir 'w6-trace.jsonl'
    Write-P9HArtifact -Path $t6 -Lines @($traceLines[0],
        (& $mkEvent 'stage2-broker-ready' @{ planId = 'plan-A'; elapsedMs = 1; present = 0; missing = 1; ambiguous = 0; failed = 0 } 30),
        (& $mkEvent 'stage2-broker-replanned' @{ planId = 'plan-B' } 35),
        $traceLines[6], $traceLines[7])
    $w6 = Try-N2 @{ TracePath = $t6 }
    Add-P9HTestResult -Id 'W6' -Title 'Events carrying incompatible plan ids cannot PASS' `
        -Input 'broker-ready plan-A then broker-replanned plan-B' -Expected 'not PASS' `
        -Actual ("N2B={0} reason={1}" -f $w6.N2B.Verdict, ($w6.N2B.Reasons -join ',')) `
        -Pass ($w6.N2B.Verdict -ne 'PASS') -Evidence $t6

    $t7 = Join-Path $dir 'w7-trace.jsonl'
    Write-P9HArtifact -Path $t7 -Lines @($traceLines[0], $traceLines[6], $traceLines[3], $traceLines[7])
    $w7 = Try-N2 @{ TracePath = $t7 }
    Add-P9HTestResult -Id 'W7' -Title 'Events in an invalid causal order cannot PASS' `
        -Input 'terminal-final before broker-ready' -Expected 'not PASS' `
        -Actual ("N2B={0}" -f $w7.N2B.Verdict) -Pass ($w7.N2B.Verdict -ne 'PASS') -Evidence $t7

    $unrelatedProc = Join-Path $dir 'w8-proc.json'
    Write-P9HArtifact -Path $unrelatedProc -Lines @(([ordered]@{
                Added = @([ordered]@{ pid = 7777; ppid = 1; name = 'pwsh.exe'; startUtc = (Get-P9HUtcStamp); commandLine = 'pwsh.exe -NoExit -File "C:\Users\someone\Documents\scratch.ps1"' })
            } | ConvertTo-Json -Depth 5))
    $w8 = Try-N2 @{ NewProcessPath = $unrelatedProc }
    Add-P9HTestResult -Id 'W8' -Title 'An unrelated new terminal process with a valid start time cannot PASS' `
        -Input 'new pwsh.exe carrying no launch identity' -Expected 'not PASS' `
        -Actual ("N2B={0} procAttr={1} reason={2}" -f $w8.N2B.Verdict, $w8.N2B.ProcessAttributed, $w8.N2B.AttributionReason) `
        -Pass ($w8.N2B.Verdict -ne 'PASS') -Evidence $unrelatedProc

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

    $w10Proc = Join-Path $dir 'w10-proc.json'
    Write-P9HArtifact -Path $w10Proc -Lines @(([ordered]@{
                Added = @([ordered]@{ pid = 4242; ppid = 4240; name = 'pwsh.exe'; startUtc = $null; commandLine = $bootstrapCmd })
            } | ConvertTo-Json -Depth 5))
    $w10 = Try-N2 @{ NewProcessPath = $w10Proc }
    Add-P9HTestResult -Id 'W10' -Title 'A PID match without a recoverable creation time cannot PASS' `
        -Input 'correct argv identity, startUtc=null' -Expected 'not PASS' `
        -Actual ("N2B={0} procAttr={1}" -f $w10.N2B.Verdict, $w10.N2B.ProcessAttributed) `
        -Pass ($w10.N2B.Verdict -ne 'PASS') -Evidence $w10Proc

    $w11Proc = Join-Path $dir 'w11-proc.json'
    Write-P9HArtifact -Path $w11Proc -Lines @(([ordered]@{
                Added = @([ordered]@{ pid = 4243; ppid = 4240; name = 'pwsh.exe'; startUtc = (Get-P9HUtcStamp); commandLine = $bootstrapCmd.Replace($windowId, 'DevWS-main-OTHER') })
            } | ConvertTo-Json -Depth 5))
    $w11 = Try-N2 @{ NewProcessPath = $w11Proc }
    Add-P9HTestResult -Id 'W11' -Title 'A process carrying a different windowId cannot PASS' `
        -Input 'argv has DevWS-main-OTHER instead of the planned windowId' -Expected 'not PASS' `
        -Actual ("N2B={0} procAttr={1}" -f $w11.N2B.Verdict, $w11.N2B.ProcessAttributed) `
        -Pass ($w11.N2B.Verdict -ne 'PASS') -Evidence $w11Proc

    $w12Empty = Join-Path $dir 'w12-empty.json'
    Write-P9HArtifact -Path $w12Empty -Lines @('{"Added":[]}')
    $w12 = Try-N2 @{ NewProcessPath = $w12Empty }
    Add-P9HTestResult -Id 'W12' -Title 'Clean trace and exit 0 without causal attribution cannot PASS' `
        -Input 'no new processes at all' -Expected 'not PASS' `
        -Actual ("N2B={0}" -f $w12.N2B.Verdict) -Pass ($w12.N2B.Verdict -ne 'PASS') -Evidence $null

    $w13Proc = Join-Path $dir 'w13-proc.json'
    Write-P9HArtifact -Path $w13Proc -Lines @(([ordered]@{
                Added = @([ordered]@{ pid = 4244; ppid = 4240; name = 'pwsh.exe'; startUtc = (Get-P9HUtcStamp); commandLine = $bootstrapCmd.Replace("-TerminalId $terminalId", '-TerminalId wrong-item') })
            } | ConvertTo-Json -Depth 5))
    $w13 = Try-N2 @{ NewProcessPath = $w13Proc }
    Add-P9HTestResult -Id 'W13' -Title 'A process with an inconsistent terminal id cannot PASS' `
        -Input 'argv TerminalId=wrong-item' -Expected 'not PASS' `
        -Actual ("N2B={0} procAttr={1}" -f $w13.N2B.Verdict, $w13.N2B.ProcessAttributed) `
        -Pass ($w13.N2B.Verdict -ne 'PASS') -Evidence $w13Proc

    $w14 = Try-N2 @{}
    Add-P9HTestResult -Id 'W14' -Title 'The real detached broker-created terminal architecture passes' `
        -Input 'pwsh child carrying -SetId/-TerminalId/-WindowId from the broker' -Expected 'PASS' `
        -Actual ("N2B={0} procAttr={1} winAttr={2}" -f $w14.N2B.Verdict, $w14.N2B.ProcessAttributed, $w14.N2B.WindowAttributed) `
        -Pass ($w14.N2B.Verdict -eq 'PASS') -Evidence $newProcPath

    # W15 (Stage 2.3): STALE matching-argv process, started before the launch.
    $w15Proc = Join-Path $dir 'w15-proc.json'
    $staleStart = (Get-Date).ToUniversalTime().AddHours(-5).ToString('o')
    Write-P9HArtifact -Path $w15Proc -Lines @(([ordered]@{
                Added = @([ordered]@{ pid = 4245; ppid = 4240; name = 'pwsh.exe'; startUtc = $staleStart; commandLine = $bootstrapCmd })
            } | ConvertTo-Json -Depth 5))
    $w15 = Try-N2 @{ NewProcessPath = $w15Proc }
    Add-P9HTestResult -Id 'W15' -Title 'A stale process with matching argv but a pre-launch creation time cannot PASS' `
        -Input 'correct argv identity, created 5 hours before the launch' -Expected 'not PASS' `
        -Actual ("N2B={0} procAttr={1} reason={2}" -f $w15.N2B.Verdict, $w15.N2B.ProcessAttributed, $w15.N2B.AttributionReason) `
        -Pass ($w15.N2B.Verdict -ne 'PASS' -and -not $w15.N2B.ProcessAttributed) -Evidence $w15Proc

    # W16 (Stage 2.3): trace with NO planId anywhere.
    $w16Trace = Join-Path $dir 'w16-trace.jsonl'
    Write-P9HArtifact -Path $w16Trace -Lines @(
        (& $mkEvent 'lifecycle-layout-plan' @{ set = $setId; profileAware = $false; source = 'relative'; profileId = ''; fingerprint = 'X'; skipped = @($terminalId) } 0)
        (& $mkEvent 'stage2-broker-ready' @{ elapsedMs = 1; present = 0; missing = 1; ambiguous = 0; failed = 0 } 30)
        (& $mkEvent 'stage2-terminal-final' @{ finalized = 1; failures = 0 } 60)
        (& $mkEvent 'transaction-end' @{ set = $setId; broker = $true; uncertain = $false; layoutSource = 'relative'; profileId = ''; failures = @() } 70)
    )
    $w16 = Try-N2 @{ TracePath = $w16Trace }
    Add-P9HTestResult -Id 'W16' -Title 'A trace with no plan identity cannot PASS' `
        -Input 'stage2-broker-ready without planId' -Expected 'not PASS' `
        -Actual ("N2B={0} reason={1}" -f $w16.N2B.Verdict, ($w16.N2B.Reasons -join ',')) `
        -Pass ($w16.N2B.Verdict -ne 'PASS') -Evidence $w16Trace

    # ======================= X-series: window omission + E1 provenance =======================
    $x1 = $false
    try {
        $a1 = Copy-P9HArgs -Table $n2args
        $a1.TracePath = $tracePath
        $a1.PostWindowPath = $noWinPath
        $a1.WindowRequired = 'no'
        $r1 = Get-P9HN2Verdicts @a1
        $x1 = ($r1.N2B.Verdict -ne 'PASS')
    }
    catch { $x1 = $true }
    Add-P9HTestResult -Id 'X1' -Title 'A window-omission request cannot lower the N2-B threshold' `
        -Input "WindowRequired='no' with zero observed windows" -Expected 'not PASS (or rejected)' `
        -Actual ("blocked={0}" -f $x1) -Pass $x1 -Evidence $null

    # X1b (Stage 2.3): empty window inventory must not satisfy N2-A either.
    $x1b = $false
    try {
        $a1b = Copy-P9HArgs -Table $n2args
        $a1b.TracePath = $tracePath
        $a1b.PostWindowPath = $noWinPath
        $a1b.WindowRequired = 'no'
        $r1b = Get-P9HN2Verdicts @a1b
        $x1b = ($r1b.N2A.Verdict -ne 'PASS')
    }
    catch { $x1b = $true }
    Add-P9HTestResult -Id 'X13' -Title 'An empty window inventory cannot satisfy N2-A even with an omission request' `
        -Input "WindowRequired='no', Windows=[]" -Expected 'N2A not PASS' `
        -Actual ("blocked={0}" -f $x1b) -Pass $x1b -Evidence $null

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

    $x4Pre = & $writeCapture 'x4-pre.json' $tokensA 3 $true $true $tid $true $preUtc @('path:OTHER/9&ZZZ&0&UID5555', 'path:OTHER/9&ZZZ&0&UID5556')
    $x4Post = & $writeCapture 'x4-post.json' $tokensA 3 $true $true $tid $true $postUtc @('path:OTHER/9&ZZZ&0&UID5555', 'path:OTHER/9&ZZZ&0&UID5556')
    $x4 = Get-P9HE1Verdict -PreCapturePath $x4Pre -PostCapturePath $x4Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X4' -Title 'Monitor records disagreeing with the token list cannot PASS' `
        -Input 'parsedMonitors identities differ from tokens' -Expected 'not PASS' `
        -Actual ("Verdict={0} agrees={1}" -f $x4.Verdict, $x4.SubObservations['tokenListAgreesWithRecords']) `
        -Pass ($x4.Verdict -ne 'PASS') -Evidence $x4Pre

    $x5Pre = & $writeCapture 'x5-pre.json' $tokensA 3 $true $true $tid $true $preUtc
    $x5Post = & $writeCapture 'x5-post.json' $tokensA 3 $true $true $tid $true $postUtc $null @('x=0 y=0 w=1920 h=1080', 'x=-2560 y=-999 w=2560 h=1440')
    $x5 = Get-P9HE1Verdict -PreCapturePath $x5Pre -PostCapturePath $x5Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X5' -Title 'Different token-to-rectangle mappings cannot PASS' `
        -Input 'post rect y differs' -Expected 'not PASS' `
        -Actual ("Verdict={0} pairsEqual={1}" -f $x5.Verdict, $x5.SubObservations['tokenRectPairsEqual']) `
        -Pass ($x5.Verdict -ne 'PASS') -Evidence $x5Post

    $x6Pre = & $writeCapture 'x6-pre.json' $tokensA 3 $true $true '' $true $preUtc
    $x6Post = & $writeCapture 'x6-post.json' $tokensA 3 $true $true '' $true $postUtc
    $x6 = Get-P9HE1Verdict -PreCapturePath $x6Pre -PostCapturePath $x6Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X6' -Title 'A capture omitting trialId cannot PASS' `
        -Input 'no trialId field on either capture' -Expected 'not PASS' `
        -Actual ("Verdict={0} present={1}" -f $x6.Verdict, $x6.SubObservations['trialProvenancePresent']) `
        -Pass ($x6.Verdict -ne 'PASS') -Evidence $x6Pre

    $x7Pre = & $writeCapture 'x7-pre.json' $tokensA 3 $true $true $tid $true $preUtc
    $x7Post = & $writeCapture 'x7-post.json' $tokensA 3 $true $true 'p9h-other-trial-11111111' $true $postUtc
    $x7 = Get-P9HE1Verdict -PreCapturePath $x7Pre -PostCapturePath $x7Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X7' -Title 'Captures from different trials cannot PASS' `
        -Input 'pre trial != post trial' -Expected 'not PASS' `
        -Actual ("Verdict={0} agrees={1}" -f $x7.Verdict, $x7.SubObservations['trialProvenanceAgrees']) `
        -Pass ($x7.Verdict -ne 'PASS') -Evidence $x7Post

    $futurePre = (Get-Date).ToUniversalTime().AddHours(2).ToString('o')
    $x8Pre = & $writeCapture 'x8-pre.json' $tokensA 3 $true $true $tid $true $futurePre
    $x8Post = & $writeCapture 'x8-post.json' $tokensA 3 $true $true $tid $true ((Get-Date).ToUniversalTime().AddHours(3).ToString('o'))
    $x8 = Get-P9HE1Verdict -PreCapturePath $x8Pre -PostCapturePath $x8Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X8' -Title 'A pre-capture later than the disconnect observation cannot PASS' `
        -Input 'pre-capture timestamp three hours in the future' -Expected 'not PASS' `
        -Actual ("Verdict={0} brackets={1}" -f $x8.Verdict, $x8.SubObservations['captureBracketsTransition']) `
        -Pass ($x8.Verdict -ne 'PASS') -Evidence $x8Pre

    $pastPost = (Get-Date).ToUniversalTime().AddHours(-3).ToString('o')
    $x9Pre = & $writeCapture 'x9-pre.json' $tokensA 3 $true $true $tid $true ((Get-Date).ToUniversalTime().AddHours(-4).ToString('o'))
    $x9Post = & $writeCapture 'x9-post.json' $tokensA 3 $true $true $tid $true $pastPost
    $x9 = Get-P9HE1Verdict -PreCapturePath $x9Pre -PostCapturePath $x9Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X9' -Title 'A post-capture earlier than the reconnect observation cannot PASS' `
        -Input 'post-capture three hours in the past' -Expected 'not PASS' `
        -Actual ("Verdict={0} brackets={1}" -f $x9.Verdict, $x9.SubObservations['captureBracketsTransition']) `
        -Pass ($x9.Verdict -ne 'PASS') -Evidence $x9Post

    $x10Pre = & $writeCapture 'x10-pre.json' $tokensA 3 $true $true $tid $true $postUtc
    $x10Post = & $writeCapture 'x10-post.json' $tokensA 3 $true $true $tid $true $preUtc
    $x10 = Get-P9HE1Verdict -PreCapturePath $x10Pre -PostCapturePath $x10Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X10' -Title 'Reversed pre/post capture timestamps cannot PASS' `
        -Input 'pre-capture is later than post-capture' -Expected 'not PASS' `
        -Actual ("Verdict={0} chronologyOk={1}" -f $x10.Verdict, $x10.SubObservations['captureChronologyOk']) `
        -Pass ($x10.Verdict -ne 'PASS') -Evidence $x10Pre

    $x11Pre = & $writeCapture 'x11-pre.json' $tokensA 3 $true $true $tid $true 'not-a-timestamp'
    $x11Post = & $writeCapture 'x11-post.json' $tokensA 3 $true $true $tid $true $postUtc
    $x11 = Get-P9HE1Verdict -PreCapturePath $x11Pre -PostCapturePath $x11Post -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X11' -Title 'A malformed capture timestamp cannot PASS' `
        -Input "capturedUtc='not-a-timestamp'" -Expected 'not PASS' `
        -Actual ("Verdict={0} valid={1}" -f $x11.Verdict, $x11.SubObservations['captureTimestampsValid']) `
        -Pass ($x11.Verdict -ne 'PASS') -Evidence $x11Pre

    $x12 = Get-P9HE1Verdict -PreCapturePath $prePath -PostCapturePath $postPath -ObserverLogPath $logGood `
        -TargetSessionId 3 -TargetUser 'qauser' -TargetLogonTime $logon -TrialId $tid
    Add-P9HTestResult -Id 'X12' -Title 'Valid raw captures with matching topology are eligible for PASS' `
        -Input 'authoritative records, one trial, bracketing timestamps' -Expected 'PASS' `
        -Actual ("Verdict={0}" -f $x12.Verdict) -Pass ($x12.Verdict -eq 'PASS') -Evidence $prePath

    # X14 (Stage 2.3): missing PRE-window inventory must not become an empty baseline.
    $x14 = Try-N2 @{ PreWindowPath = (Join-Path $dir 'no-such-pre.json') }
    Add-P9HTestResult -Id 'X14' -Title 'A missing pre-window inventory cannot be treated as an empty baseline' `
        -Input 'absent pre-window observation' -Expected 'N2A not PASS, preObserved=false' `
        -Actual ("N2A={0} preObserved={1}" -f $x14.N2A.Verdict, $x14.N2A.PreStateObserved) `
        -Pass ($x14.N2A.Verdict -ne 'PASS' -and -not $x14.N2A.PreStateObserved) -Evidence $null
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

function Test-P9HTestRegistry {
    # Automated registry guard.
    #
    # Purpose: a future edit must not be able to SILENTLY drop registered cases.
    # Stage 2.2 lost the whole N-series this way: the function was replaced and the
    # total happened to rise, so nothing complained.
    #
    # Two independent checks:
    #   1. RUNTIME - the results actually produced by this run (unique ids, count
    #      matches the declared baseline, every series present).
    #   2. SOURCE  - the registered `-Id '<x>'` literals in this file (unique ids,
    #      count, no missing series), so a case that never runs is still noticed.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][string[]]$RequiredSeries
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $observed = @($Results | ForEach-Object { [string]$_.id })

    # --- runtime checks ---
    $runtimeDups = @($observed | Group-Object | Where-Object { $_.Count -gt 1 })
    foreach ($d in $runtimeDups) { $problems.Add('runtime-duplicate-id:' + $d.Name + ' x' + $d.Count) }

    if ($observed.Count -ne $ExpectedCount) {
        $problems.Add(('runtime-count:{0}-expected-{1}' -f $observed.Count, $ExpectedCount))
    }

    foreach ($series in $RequiredSeries) {
        $prefixCount = @($observed | Where-Object { $_ -match ('^' + [regex]::Escape($series) + '\d+$') }).Count
        if ($prefixCount -eq 0) { $problems.Add('runtime-series-missing:' + $series) }
    }

    # --- source checks ---
    $sourceIds = @([regex]::Matches((Get-Content -LiteralPath $PSCommandPath -Raw), "-Id\s+'([A-Za-z0-9]+)'") |
        ForEach-Object { $_.Groups[1].Value })

    $sourceDups = @($sourceIds | Group-Object | Where-Object { $_.Count -gt 1 })
    foreach ($d in $sourceDups) { $problems.Add('source-duplicate-id:' + $d.Name + ' x' + $d.Count) }

    if ($sourceIds.Count -ne $ExpectedCount) {
        $problems.Add(('source-count:{0}-expected-{1}' -f $sourceIds.Count, $ExpectedCount))
    }

    foreach ($series in $RequiredSeries) {
        $prefixCount = @($sourceIds | Where-Object { $_ -match ('^' + [regex]::Escape($series) + '\d+$') }).Count
        if ($prefixCount -eq 0) { $problems.Add('source-series-missing:' + $series) }
    }

    # Every declared source case must have produced a runtime result.
    $notRun = @($sourceIds | Where-Object { $observed -notcontains $_ })
    foreach ($n in $notRun) { $problems.Add('registered-but-not-run:' + $n) }

    return [pscustomobject][ordered]@{
        Ok            = ($problems.Count -eq 0)
        Problems      = @($problems)
        RuntimeCount  = $observed.Count
        SourceCount   = $sourceIds.Count
        ExpectedCount = $ExpectedCount
        Duplicates    = ($runtimeDups.Count + $sourceDups.Count)
        Series        = @($RequiredSeries)
    }
}

function Invoke-P9HTrialBindingTests {
    # M-series: cross-trial evidence binding (Stage 2.4).
    #
    # Reproduces the Stage 2.3 false PASS first: Test-P9HExitRecord verifies that
    # a trialId FIELD exists but never that it equals the trial under evaluation,
    # so an exit record from trial A satisfied a verdict about trial B.
    #
    # The product trace carries no trial identity at all (verified against every
    # Write-DevWSLaunchTrace call site), so the binding is recorded by the
    # COLLECTOR in the existing artifact index and re-verified by digest at
    # verdict time. No product field is invented and no second manifest exists.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $windowId = 'DevWS-main-p9h-item'
    $terminalId = 'p9h-item'
    $setId = 'main'

    function New-BoundTrial {
        param([string]$kind)
        $ctx = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind selftest
        $d = $ctx.Directory
        $tid = $ctx.TrialId

        $fx = Join-Path $d 'fx.json'
        Write-P9HArtifact -Path $fx -Lines @(([ordered]@{
                    itemId = $terminalId; enabledItems = 1; enabledTerminals = 1; totalItems = 1
                    anchorAbsent = $true
                    layoutFallback = [ordered]@{ x = 9000; y = 9000; w = 640; h = 480 }
                } | ConvertTo-Json -Depth 5))

        $so = Join-Path $d 'o.txt'
        Write-P9HArtifact -Path $so -Lines @('main/p9h-item: relative layout has no reachable placement (anchor-missing: identity-not-found); the item will be handled normally but its window position will not be changed.')

        $pre = Join-Path $d 'pre.json'
        Write-P9HArtifact -Path $pre -Lines @('{"Windows":[]}')

        $post = Join-Path $d 'post.json'
        Write-P9HArtifact -Path $post -Lines @(([ordered]@{
                    Windows = @([ordered]@{ hwnd = '0xA1'; pid = 4242; visible = $true; class = 'CASCADIA_HOSTING_WINDOW_CLASS'; x = 44; y = 52; width = 1129; height = 635; title = $windowId })
                } | ConvertTo-Json -Depth 5))

        $bootstrap = 'pwsh.exe -NoExit -File x ' +
            "-SetId $setId -TerminalId $terminalId -WindowId $windowId -TabIndex 0 -SessionId s1"
        $np = Join-Path $d 'np.json'
        Write-P9HArtifact -Path $np -Lines @(([ordered]@{
                    Added = @([ordered]@{ pid = 4242; ppid = 4240; name = 'pwsh.exe'; startUtc = (Get-Date).ToUniversalTime().ToString('o'); commandLine = $bootstrap })
                } | ConvertTo-Json -Depth 5))

        $ls = (Get-Date).ToUniversalTime().AddMinutes(-1)
        $le = (Get-Date).ToUniversalTime().AddMinutes(1)
        $ex = Join-Path $d 'exit.json'
        $rec = New-P9HExitRecord -TrialId $tid -Outcome 'exited' -ExitCode 0 -LauncherPid 4240 `
            -LauncherPath 'C:\synthetic\ws.cmd' -InvocationDisplay 's' -WorkingDirectory $d `
            -LaunchedAtUtc $ls.ToString('o') -ExitedAtUtc $le.ToString('o')
        $null = Write-P9HExitRecord -Path $ex -Record $rec

        $n = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $mkE = {
            param([string]$e, [hashtable]$x, [long]$o)
            $h = @{ event = $e; utcMs = ($n + $o); pid = 1 }
            foreach ($k in $x.Keys) { $h[$k] = $x[$k] }
            return ($h | ConvertTo-Json -Compress)
        }
        $tr = Join-Path $d ("trace-$kind.jsonl")
        Write-P9HArtifact -Path $tr -Lines @(
            (& $mkE 'lifecycle-layout-plan' @{ set = $setId; profileAware = $false; source = 'relative'; profileId = ''; fingerprint = 'X'; skipped = @($terminalId) } 0)
            (& $mkE 'stage2-broker-ready' @{ planId = 'plan-1'; elapsedMs = 1; present = 0; missing = 1; ambiguous = 0; failed = 0 } 30)
            (& $mkE 'stage2-terminal-final' @{ finalized = 1; failures = 0 } 60)
            (& $mkE 'transaction-end' @{ set = $setId; broker = $true; uncertain = $false; layoutSource = 'relative'; profileId = ''; failures = @() } 70)
        )

        # COLLECTOR-authored binding: role + path + digest for every artifact.
        foreach ($pair in @(
                @{ p = $fx; r = 'fixture' }
                @{ p = $so; r = 'stdout' }
                @{ p = $pre; r = 'pre-windows' }
                @{ p = $post; r = 'post-windows' }
                @{ p = $ex; r = 'exit-record' }
                @{ p = $np; r = 'new-processes' }
                @{ p = $tr; r = 'trace' }
            )) {
            $null = Add-P9HArtifactRole -Context $ctx -Path $pair.p -Role $pair.r
        }

        return [pscustomobject]@{
            Context = $ctx; TrialId = $tid; Directory = $d
            Fixture = $fx; Stdout = $so; PreWindow = $pre; PostWindow = $post
            ExitRecord = $ex; NewProcess = $np; Trace = $tr
            Index = (Join-Path $d 'artifact-index.jsonl')
        }
    }

    function Invoke-N2($t, [hashtable]$over) {
        $a = @{
            FixturePath = $t.Fixture; TracePath = $t.Trace; StdoutPath = $t.Stdout
            PreWindowPath = $t.PreWindow; PostWindowPath = $t.PostWindow
            ExitRecordPath = $t.ExitRecord; NewProcessPath = $t.NewProcess
            TrialId = $t.TrialId
            ExpectedWindowId = $windowId; ExpectedTerminalId = $terminalId; ExpectedSetId = $setId
            ArtifactIndexPath = $t.Index
        }
        foreach ($k in $over.Keys) { $a[$k] = $over[$k] }
        return Get-P9HN2Verdicts @a
    }

    $A = New-BoundTrial -kind 'a'
    $B = New-BoundTrial -kind 'b'

    # ---- M1: exit record belongs to ANOTHER trial ----
    $m1 = Invoke-N2 $B @{ ExitRecordPath = $A.ExitRecord }
    Add-P9HTestResult -Id 'M1' -Title 'An exit record belonging to another trial cannot PASS' `
        -Input ('evaluating ' + $B.TrialId + ', exit record from ' + $A.TrialId) `
        -Expected 'N2B not PASS' `
        -Actual ("N2B={0} trialMatches={1} reasons={2}" -f $m1.N2B.Verdict, $m1.N2B.TrialIdentityMatches, ($m1.N2B.Reasons -join ',')) `
        -Pass ($m1.N2B.Verdict -ne 'PASS') -Evidence $A.ExitRecord
    # ---- M2: trial id missing from the invocation ----
    # [Parameter(Mandatory)] rejects an EMPTY string before the body runs, which
    # is correct fail-closed behaviour. Both halves are proven here: the binder
    # refuses an empty id, and a whitespace-only id that reaches the body is
    # never converted into a PASS.
    $binderRefused = $false
    try { $null = Invoke-N2 $B @{ TrialId = '' } } catch { $binderRefused = $true }
    $m2 = $null
    $wsRefused = $false
    try {
        $m2 = Invoke-N2 $B @{ TrialId = '   ' }
        $wsRefused = ($m2.N2B.Verdict -ne 'PASS')
    } catch { $wsRefused = $true }
    Add-P9HTestResult -Id 'M2' -Title 'Trial id missing from the invocation cannot PASS' `
        -Input 'empty TrialId (binder) and whitespace TrialId (body)' -Expected 'both refused, N2B not PASS' `
        -Actual ("binderRefused={0} bodyRefused={1}" -f $binderRefused, $wsRefused) `
        -Pass ($binderRefused -and $wsRefused) -Evidence $null

    # ---- M3: valid same-trial exit record is eligible for PASS ----
    $m3 = Invoke-N2 $B @{}
    Add-P9HTestResult -Id 'M3' -Title 'A valid same-trial binding is eligible for PASS' `
        -Input 'all artifacts bound to one trial, digests verified' -Expected 'N2B=PASS' `
        -Actual ("N2B={0} trialMatches={1} binding={2}" -f $m3.N2B.Verdict, $m3.N2B.TrialIdentityMatches, $m3.N2B.ArtifactBindingReason) `
        -Pass ($m3.N2B.Verdict -eq 'PASS') -Evidence $B.Index

    # ---- M4: trace substituted from a different trial ----
    # A's trace carries the same shape but a different digest than B recorded.
    $m4 = Invoke-N2 $B @{ TracePath = $A.Trace }
    Add-P9HTestResult -Id 'M4' -Title 'A trace substituted from another trial cannot PASS' `
        -Input ('B is bound to its own trace; supplied ' + $A.Trace) `
        -Expected 'N2B not PASS' `
        -Actual ("N2B={0} binding={1}" -f $m4.N2B.Verdict, $m4.N2B.ArtifactBindingReason) `
        -Pass ($m4.N2B.Verdict -ne 'PASS') -Evidence $A.Trace

    # ---- M5: artifact hash mismatch (file modified after it was bound) ----
    $m5Trial = New-BoundTrial -kind 'm5'
    Write-P9HArtifact -Path $m5Trial.Trace -Lines @('{"event":"lifecycle-layout-plan","utcMs":1,"pid":1,"set":"main","skipped":["p9h-item"]}')
    $m5 = Invoke-N2 $m5Trial @{}
    Add-P9HTestResult -Id 'M5' -Title 'An artifact hash mismatch cannot PASS' `
        -Input 'trace rewritten after the collector recorded its digest' `
        -Expected 'N2B not PASS' `
        -Actual ("N2B={0} binding={1}" -f $m5.N2B.Verdict, $m5.N2B.ArtifactBindingReason) `
        -Pass ($m5.N2B.Verdict -ne 'PASS') -Evidence $m5Trial.Index

    # ---- M6: complete valid same-trial binding is eligible for PASS ----
    $m6 = Invoke-N2 $B @{}
    $roles = @($m6.N2B.ArtifactBindingRoles)
    $allVerified = (@($roles | Where-Object { $_.status -eq 'verified' }).Count -eq $roles.Count -and $roles.Count -eq 7)
    Add-P9HTestResult -Id 'M6' -Title 'A complete same-trial artifact binding verifies all seven roles' `
        -Input 'fixture, stdout, pre/post windows, exit record, new processes, trace' `
        -Expected 'N2B=PASS and 7/7 roles verified' `
        -Actual ("N2B={0} roles={1} verified={2}" -f $m6.N2B.Verdict, $roles.Count, @($roles | Where-Object { $_.status -eq 'verified' }).Count) `
        -Pass ($m6.N2B.Verdict -eq 'PASS' -and $allVerified) -Evidence $B.Index

    # ---- M7: no artifact binding supplied at all ----
    $m7 = Invoke-N2 $B @{ ArtifactIndexPath = '' }
    Add-P9HTestResult -Id 'M7' -Title 'A missing artifact binding leaves the verdict INCONCLUSIVE' `
        -Input 'no ArtifactIndexPath supplied' -Expected 'N2B=INCONCLUSIVE (authoritative PASS gated)' `
        -Actual ("N2B={0} binding={1}" -f $m7.N2B.Verdict, $m7.N2B.ArtifactBindingReason) `
        -Pass ($m7.N2B.Verdict -eq 'INCONCLUSIVE') -Evidence $null

    # ---- M8: artifact index for a different trial directory ----
    $m8 = Invoke-N2 $B @{ ArtifactIndexPath = $A.Index }
    Add-P9HTestResult -Id 'M8' -Title 'Another trial artifact index cannot satisfy the binding' `
        -Input ('B evaluated against ' + $A.Index) -Expected 'N2B not PASS' `
        -Actual ("N2B={0} binding={1}" -f $m8.N2B.Verdict, $m8.N2B.ArtifactBindingReason) `
        -Pass ($m8.N2B.Verdict -ne 'PASS') -Evidence $A.Index
}
function Invoke-P9HProvenanceTests {
    # P-series: shared trial provenance and artifact-index integrity (Stage 2.4.1).
    #
    # Stage 2.4 gated N2-B on the artifact binding but left N2-A ungated, so a
    # placement PASS could rest on unattributed artifacts. Both verdicts now
    # consult ONE shared gate that checks provenance only - never exit code - so
    # the two measurements stay independent.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $windowId = 'DevWS-main-p9h-item'
    $terminalId = 'p9h-item'
    $setId = 'main'

    function New-ProvTrial {
        param([string]$kind, [int]$exitCode = 0)
        $ctx = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind selftest
        $d = $ctx.Directory
        $tid = $ctx.TrialId

        $fx = Join-Path $d 'fx.json'
        Write-P9HArtifact -Path $fx -Lines @(([ordered]@{
                    itemId = $terminalId; enabledItems = 1; enabledTerminals = 1; totalItems = 1
                    anchorAbsent = $true
                    layoutFallback = [ordered]@{ x = 9000; y = 9000; w = 640; h = 480 }
                } | ConvertTo-Json -Depth 5))

        $so = Join-Path $d 'o.txt'
        Write-P9HArtifact -Path $so -Lines @('main/p9h-item: relative layout has no reachable placement (anchor-missing: identity-not-found); the item will be handled normally but its window position will not be changed.')

        $pre = Join-Path $d 'pre.json'
        Write-P9HArtifact -Path $pre -Lines @('{"Windows":[]}')

        $post = Join-Path $d 'post.json'
        Write-P9HArtifact -Path $post -Lines @(([ordered]@{
                    Windows = @([ordered]@{ hwnd = '0xA1'; pid = 4242; visible = $true; class = 'CASCADIA_HOSTING_WINDOW_CLASS'; x = 44; y = 52; width = 1129; height = 635; title = $windowId })
                } | ConvertTo-Json -Depth 5))

        $bs = 'pwsh.exe -NoExit -File x ' +
            "-SetId $setId -TerminalId $terminalId -WindowId $windowId -TabIndex 0 -SessionId s1"
        $np = Join-Path $d 'np.json'
        Write-P9HArtifact -Path $np -Lines @(([ordered]@{
                    Added = @([ordered]@{ pid = 4242; ppid = 4240; name = 'pwsh.exe'; startUtc = (Get-Date).ToUniversalTime().ToString('o'); commandLine = $bs })
                } | ConvertTo-Json -Depth 5))

        $ls = (Get-Date).ToUniversalTime().AddMinutes(-1)
        $le = (Get-Date).ToUniversalTime().AddMinutes(1)
        $ex = Join-Path $d 'exit.json'
        $rec = New-P9HExitRecord -TrialId $tid -Outcome 'exited' -ExitCode $exitCode -LauncherPid 4240 `
            -LauncherPath 'C:\synthetic\ws.cmd' -InvocationDisplay 's' -WorkingDirectory $d `
            -LaunchedAtUtc $ls.ToString('o') -ExitedAtUtc $le.ToString('o')
        $null = Write-P9HExitRecord -Path $ex -Record $rec

        $n = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $mkE = {
            param([string]$e, [hashtable]$x, [long]$o)
            $h = @{ event = $e; utcMs = ($n + $o); pid = 1 }
            foreach ($k in $x.Keys) { $h[$k] = $x[$k] }
            return ($h | ConvertTo-Json -Compress)
        }
        $tr = Join-Path $d ("trace-$kind.jsonl")
        Write-P9HArtifact -Path $tr -Lines @(
            (& $mkE 'lifecycle-layout-plan' @{ set = $setId; profileAware = $false; source = 'relative'; profileId = ''; fingerprint = 'X'; skipped = @($terminalId) } 0)
            (& $mkE 'stage2-broker-ready' @{ planId = 'plan-1'; elapsedMs = 1; present = 0; missing = 1; ambiguous = 0; failed = 0 } 30)
            (& $mkE 'stage2-terminal-final' @{ finalized = 1; failures = 0 } 60)
            (& $mkE 'transaction-end' @{ set = $setId; broker = $true; uncertain = $false; layoutSource = 'relative'; profileId = ''; failures = @() } 70)
        )

        return [pscustomobject]@{
            Context = $ctx; TrialId = $tid; Directory = $d
            Fixture = $fx; Stdout = $so; PreWindow = $pre; PostWindow = $post
            ExitRecord = $ex; NewProcess = $np; Trace = $tr
            Index = (Join-Path $d 'artifact-index.jsonl')
        }
    }

    function Bind-ProvTrial($t, $trialIdOverride = $null) {
        $roles = @(
            @{ p = $t.Fixture; r = 'fixture' }
            @{ p = $t.Stdout; r = 'stdout' }
            @{ p = $t.PreWindow; r = 'pre-windows' }
            @{ p = $t.PostWindow; r = 'post-windows' }
            @{ p = $t.ExitRecord; r = 'exit-record' }
            @{ p = $t.NewProcess; r = 'new-processes' }
            @{ p = $t.Trace; r = 'trace' }
        )
        foreach ($x in $roles) {
            if ($null -eq $trialIdOverride) {
                $null = Add-P9HArtifactRole -Context $t.Context -Path $x.p -Role $x.r
            }
            else {
                # Write a record with a deliberately wrong/blank trial id.
                $full = (Resolve-Path -LiteralPath $x.p).Path
                $entry = [ordered]@{
                    utc = Get-P9HUtcStamp; trialId = $trialIdOverride; role = $x.r
                    file = [System.IO.Path]::GetFileName($x.p); path = $full
                    bytes = (Get-Item -LiteralPath $x.p).Length
                    sha256 = Get-P9HFileSha256 -Path $x.p; present = $true
                }
                Add-P9HArtifactLine -Path $t.Index -Line ($entry | ConvertTo-Json -Compress -Depth 4)
            }
        }
    }

    function Invoke-ProvN2($t, [hashtable]$over) {
        $a = @{
            FixturePath = $t.Fixture; TracePath = $t.Trace; StdoutPath = $t.Stdout
            PreWindowPath = $t.PreWindow; PostWindowPath = $t.PostWindow
            ExitRecordPath = $t.ExitRecord; NewProcessPath = $t.NewProcess
            TrialId = $t.TrialId
            ExpectedWindowId = $windowId; ExpectedTerminalId = $terminalId; ExpectedSetId = $setId
            ArtifactIndexPath = $t.Index
        }
        foreach ($k in $over.Keys) { $a[$k] = $over[$k] }
        return Get-P9HN2Verdicts @a
    }

    $good = New-ProvTrial -kind 'good'
    Bind-ProvTrial $good

    $foreign = New-ProvTrial -kind 'foreign'
    Bind-ProvTrial $foreign

    # ---- P1: N2-A otherwise valid, binding ABSENT ----
    $p1 = Invoke-ProvN2 $good @{ ArtifactIndexPath = '' }
    Add-P9HTestResult -Id 'P1' -Title 'N2-A cannot PASS without an artifact binding' `
        -Input 'measurement valid, no artifact index' -Expected 'N2A not PASS' `
        -Actual ("N2A={0} reasons={1}" -f $p1.N2A.Verdict, ($p1.N2A.Reasons -join ',')) `
        -Pass ($p1.N2A.Verdict -ne 'PASS') -Evidence $null

    # ---- P2: N2-A otherwise valid, FOREIGN trial index ----
    $p2 = Invoke-ProvN2 $good @{ ArtifactIndexPath = $foreign.Index }
    Add-P9HTestResult -Id 'P2' -Title 'N2-A cannot PASS on another trial artifact index' `
        -Input ('good trial evaluated against ' + $foreign.Index) -Expected 'N2A not PASS' `
        -Actual ("N2A={0} reasons={1}" -f $p2.N2A.Verdict, ($p2.N2A.Reasons -join ',')) `
        -Pass ($p2.N2A.Verdict -ne 'PASS') -Evidence $foreign.Index

    # ---- P3: N2-A complete valid binding ----
    $p3 = Invoke-ProvN2 $good @{}
    Add-P9HTestResult -Id 'P3' -Title 'N2-A PASS with a complete valid same-trial binding' `
        -Input 'all seven roles bound and verified' -Expected 'N2A=PASS' `
        -Actual ("N2A={0} N2B={1}" -f $p3.N2A.Verdict, $p3.N2B.Verdict) `
        -Pass ($p3.N2A.Verdict -eq 'PASS') -Evidence $good.Index

    # ---- P4: N2-A independence from a nonzero lifecycle exit ----
    $nonzero = New-ProvTrial -kind 'nonzero' -exitCode 3
    Bind-ProvTrial $nonzero
    $p4 = Invoke-ProvN2 $nonzero @{}
    Add-P9HTestResult -Id 'P4' -Title 'N2-A remains independent of a nonzero lifecycle exit' `
        -Input 'captured exit code 3, complete valid binding' `
        -Expected 'N2A=PASS and N2B=FAIL' `
        -Actual ("N2A={0} N2B={1}" -f $p4.N2A.Verdict, $p4.N2B.Verdict) `
        -Pass ($p4.N2A.Verdict -eq 'PASS' -and $p4.N2B.Verdict -eq 'FAIL') -Evidence $nonzero.Index

    # ---- P5: blank / whitespace trial ids in required entries ----
    $blank = New-ProvTrial -kind 'blank'
    Bind-ProvTrial $blank -trialIdOverride ''
    $p5 = Invoke-ProvN2 $blank @{}
    Add-P9HTestResult -Id 'P5' -Title 'Blank trial ids in required index entries are rejected' `
        -Input 'artifact-index entries carry trialId="" ' -Expected 'not PASS, binding fails' `
        -Actual ("N2A={0} N2B={1}" -f $p5.N2A.Verdict, $p5.N2B.Verdict) `
        -Pass ($p5.N2A.Verdict -ne 'PASS' -and $p5.N2B.Verdict -ne 'PASS') -Evidence $blank.Index

    # ---- P6: whitespace-only trial id ----
    $ws = New-ProvTrial -kind 'ws'
    Bind-ProvTrial $ws -trialIdOverride '   '
    $p6 = Invoke-ProvN2 $ws @{}
    Add-P9HTestResult -Id 'P6' -Title 'Whitespace-only trial ids in required entries are rejected' `
        -Input 'artifact-index entries carry trialId="   " ' -Expected 'not PASS' `
        -Actual ("N2A={0} N2B={1}" -f $p6.N2A.Verdict, $p6.N2B.Verdict) `
        -Pass ($p6.N2A.Verdict -ne 'PASS' -and $p6.N2B.Verdict -ne 'PASS') -Evidence $ws.Index

    # ---- P7: malformed line BEFORE the valid entries ----
    $malPre = New-ProvTrial -kind 'malpre'
    $idxPre = $malPre.Index
    $existing = @(Get-Content -LiteralPath $idxPre -ErrorAction SilentlyContinue)
    $rawPre = @('{"trialId": "broken", "role": ') + $existing
    Write-P9HArtifact -Path $idxPre -Lines $rawPre
    Bind-ProvTrial $malPre
    $p7 = Invoke-ProvN2 $malPre @{}
    Add-P9HTestResult -Id 'P7' -Title 'A malformed index line before valid entries is rejected' `
        -Input 'truncated JSON prepended to the index' -Expected 'not PASS' `
        -Actual ("N2A={0} N2B={1}" -f $p7.N2A.Verdict, $p7.N2B.Verdict) `
        -Pass ($p7.N2A.Verdict -ne 'PASS' -and $p7.N2B.Verdict -ne 'PASS') -Evidence $idxPre

    # ---- P8: malformed line APPENDED after all seven valid entries ----
    $malPost = New-ProvTrial -kind 'malpost'
    Bind-ProvTrial $malPost
    Add-P9HArtifactLine -Path $malPost.Index -Line '{"trialId": "tail", "role":'
    $p8 = Invoke-ProvN2 $malPost @{}
    Add-P9HTestResult -Id 'P8' -Title 'A malformed index line appended after valid entries is rejected' `
        -Input 'truncated JSON appended to a complete index' -Expected 'not PASS' `
        -Actual ("N2A={0} N2B={1}" -f $p8.N2A.Verdict, $p8.N2B.Verdict) `
        -Pass ($p8.N2A.Verdict -ne 'PASS' -and $p8.N2B.Verdict -ne 'PASS') -Evidence $malPost.Index

    # ---- P9: a required role missing from the index ----
    $missingRole = New-ProvTrial -kind 'missing'
    foreach ($x in @(
            @{ p = $missingRole.Fixture; r = 'fixture' }
            @{ p = $missingRole.Stdout; r = 'stdout' }
            @{ p = $missingRole.PreWindow; r = 'pre-windows' }
            @{ p = $missingRole.PostWindow; r = 'post-windows' }
            @{ p = $missingRole.ExitRecord; r = 'exit-record' }
            @{ p = $missingRole.NewProcess; r = 'new-processes' }
        )) {
        $null = Add-P9HArtifactRole -Context $missingRole.Context -Path $x.p -Role $x.r
    }
    $p9 = Invoke-ProvN2 $missingRole @{}
    Add-P9HTestResult -Id 'P9' -Title 'A missing required role is rejected' `
        -Input 'trace role absent from the index' -Expected 'not PASS' `
        -Actual ("N2A={0} N2B={1}" -f $p9.N2A.Verdict, $p9.N2B.Verdict) `
        -Pass ($p9.N2A.Verdict -ne 'PASS' -and $p9.N2B.Verdict -ne 'PASS') -Evidence $missingRole.Index

    # ---- P10: complete valid seven-role index accepted ----
    $p10 = Invoke-ProvN2 $good @{}
    $roles = @($p10.N2B.ArtifactBindingRoles)
    $verified = @($roles | Where-Object { $_.status -eq 'verified' }).Count
    Add-P9HTestResult -Id 'P10' -Title 'A complete correct seven-role index is accepted' `
        -Input 'fixture, stdout, pre/post windows, exit record, new processes, trace' `
        -Expected 'PASS with 7/7 roles verified' `
        -Actual ("N2A={0} N2B={1} roles={2} verified={3}" -f $p10.N2A.Verdict, $p10.N2B.Verdict, $roles.Count, $verified) `
        -Pass ($p10.N2A.Verdict -eq 'PASS' -and $p10.N2B.Verdict -eq 'PASS' -and $verified -eq 7) -Evidence $good.Index

    # ---- P11: N2-B cross-trial protection retained ----
    $p11 = Invoke-ProvN2 $good @{ ExitRecordPath = $foreign.ExitRecord }
    Add-P9HTestResult -Id 'P11' -Title 'N2-B cross-trial exit-record protection is retained' `
        -Input ('good trial with ' + $foreign.TrialId + ' exit record') -Expected 'N2B not PASS' `
        -Actual ("N2B={0} trialMatches={1}" -f $p11.N2B.Verdict, $p11.N2B.TrialIdentityMatches) `
        -Pass ($p11.N2B.Verdict -ne 'PASS') -Evidence $foreign.ExitRecord
}
function Invoke-P9HWtsProviderTests {
    # W-series: native WTSINFO provider decode (Stage 3A).
    # C-series: trial collector binding to the frozen seven N2 roles.
    #
    # Every case here runs from SYNTHETIC bytes or synthetic facts. Nothing in
    # this function calls WTSQuerySessionInformationW: the only live-path
    # exercise is the authorization refusal (W13), which is exactly what proves
    # the adapter cannot touch a live session by accident.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    # A fixed, known FILETIME: 2026-11-11T10:00:00Z.
    $logonUtc = [datetime]::SpecifyKind([datetime]::new(2026, 11, 11, 10, 0, 0), [System.DateTimeKind]::Utc)
    $logonFt = $logonUtc.ToFileTimeUtc()
    $otherUtc = [datetime]::SpecifyKind([datetime]::new(2026, 11, 11, 09, 0, 0), [System.DateTimeKind]::Utc)
    $otherFt = $otherUtc.ToFileTimeUtc()
    $logonIso = $logonUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)

    # ---- W1: valid WTSINFO payload with a nonzero logon time ----
    $payload = New-P9HWtsInfoPayload -SessionId 3 -State 0 -StationName 'RDP-Tcp#0' `
        -Domain 'CONTOSO' -UserName 'qauser' -LogonTime $logonFt
    $decoded = ConvertFrom-P9HWtsInfoPayload -Payload $payload
    $rec = if ($decoded.Ok) { $decoded.Record } else { $null }
    Add-P9HTestResult -Id 'Q1' -Title 'Valid WTSINFO payload decodes with a nonzero logon time' `
        -Input ('216-byte WTSINFO, session 3 Active, logon ' + $logonIso) `
        -Expected 'Ok=true, sessionId=3, state=0, logon present' `
        -Actual ("Ok={0} reason={1} sessionId={2} state={3} logon={4}" -f $decoded.Ok, $decoded.Reason, $(if ($rec) { $rec.SessionId } else { 'null' }), $(if ($rec) { $rec.State } else { 'null' }), $(if ($rec) { $rec.LogonTime } else { 'null' })) `
        -Pass ($decoded.Ok -and $rec.SessionId -eq 3 -and $rec.State -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$rec.LogonTime)) -Evidence $null

    # ---- W2: FILETIME -> UTC conversion is exact ----
    $converted = ConvertFrom-P9HFileTimeUtc -FileTime $logonFt
    $roundTrip = if ($converted.Ok) { [datetime]::Parse($converted.Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } else { $null }
    Add-P9HTestResult -Id 'Q2' -Title 'FILETIME converts to the exact UTC instant' `
        -Input ('FILETIME ' + $logonFt) -Expected ('exactly ' + $logonIso) `
        -Actual ("{0} kind={1} roundTripMatches={2}" -f $converted.Value, $(if ($roundTrip) { $roundTrip.Kind } else { 'null' }), $(if ($roundTrip) { $roundTrip -eq $logonUtc } else { $false })) `
        -Pass ($converted.Ok -and $converted.Value -eq $logonIso -and $roundTrip -eq $logonUtc) -Evidence $null

    # ---- W3: zero logon time is rejected, never converted to 1601 ----
    $zeroPayload = New-P9HWtsInfoPayload -SessionId 3 -State 0 -UserName 'qauser' -LogonTime 0
    $zeroDecoded = ConvertFrom-P9HWtsInfoPayload -Payload $zeroPayload
    $zeroRec = if ($zeroDecoded.Ok) { $zeroDecoded.Record } else { $null }
    Add-P9HTestResult -Id 'Q3' -Title 'Zero logon time is absent, never the 1601 epoch' `
        -Input 'WTSINFO LogonTime = 0' -Expected 'logon null, reason=zero, no fabricated timestamp' `
        -Actual ("Ok={0} logon={1} reason={2} source={3}" -f $zeroDecoded.Ok, $(if ($zeroRec) { [string]$zeroRec.LogonTime } else { 'null' }), $(if ($zeroRec) { $zeroRec.LogonReason } else { 'null' }), $(if ($zeroRec) { $zeroRec.LogonSource } else { 'null' })) `
        -Pass ($zeroDecoded.Ok -and $null -eq $zeroRec.LogonTime -and $zeroRec.LogonReason -eq 'zero') -Evidence $null

    # ---- W4: negative logon time is rejected ----
    $negConverted = ConvertFrom-P9HFileTimeUtc -FileTime ([long]-1)
    Add-P9HTestResult -Id 'Q4' -Title 'Negative FILETIME is rejected' `
        -Input 'LogonTime = -1' -Expected 'Ok=false reason=negative' `
        -Actual ("Ok={0} reason={1}" -f $negConverted.Ok, $negConverted.Reason) `
        -Pass ((-not $negConverted.Ok) -and $negConverted.Reason -eq 'negative') -Evidence $null

    # ---- W5: struct-size mismatch is an explicit failure ----
    $short = New-P9HWtsInfoPayload -SessionId 3 -State 0 -ByteCountOverride 100
    $shortDecoded = ConvertFrom-P9HWtsInfoPayload -Payload $short
    Add-P9HTestResult -Id 'Q5' -Title 'Struct-size mismatch is rejected with byte counts' `
        -Input '100-byte WTSINFO payload' -Expected 'Ok=false reason=struct-size-mismatch' `
        -Actual ("Ok={0} reason={1} returned={2} expected={3}" -f $shortDecoded.Ok, $shortDecoded.Reason, $shortDecoded.ReturnedBytes, $shortDecoded.ExpectedBytes) `
        -Pass ((-not $shortDecoded.Ok) -and $shortDecoded.Reason -eq 'struct-size-mismatch' -and $shortDecoded.ExpectedBytes -eq 216) -Evidence $null

    # ---- W6: empty payload is rejected ----
    $emptyDecoded = ConvertFrom-P9HWtsInfoPayload -Payload ([byte[]]@())
    Add-P9HTestResult -Id 'Q6' -Title 'Empty WTSINFO payload is rejected' `
        -Input 'zero bytes' -Expected 'Ok=false reason=empty-payload' `
        -Actual ("Ok={0} reason={1}" -f $emptyDecoded.Ok, $emptyDecoded.Reason) `
        -Pass ((-not $emptyDecoded.Ok) -and $emptyDecoded.Reason -eq 'empty-payload') -Evidence $null

    # ---- W7: layout cross-check (size, offsets, architecture) ----
    $layout = Test-P9HWtsInfoLayout
    Add-P9HTestResult -Id 'Q7' -Title 'WTSINFO layout matches the documented contract' `
        -Input 'compiled mirror vs published expected layout' `
        -Expected '216 bytes, State=0, SessionId=4, LogonTime=200 on x64' `
        -Actual ("Ok={0} size={1} arch={2} state={3} sessionId={4} logon={5}" -f $layout.Ok, $layout.Size, $layout.Architecture, $layout.Offsets.State, $layout.Offsets.SessionId, $layout.Offsets.LogonTime) `
        -Pass ($layout.Ok -and $layout.Size -eq 216 -and $layout.Offsets.State -eq 0 -and $layout.Offsets.SessionId -eq 4 -and $layout.Offsets.LogonTime -eq 200) -Evidence $null

    # ---- W8: provider line round-trips through the frozen observer parser ----
    $line = if ($rec) { ConvertTo-P9HWtsProviderLine -Record $rec } else { '' }
    $parsed = ConvertFrom-P9HWtsLine -Line $line
    Add-P9HTestResult -Id 'Q8' -Title 'Provider line round-trips through the frozen observer parser' `
        -Input 'provider line built from decoded WTSINFO facts' -Expected 'Ok=true, logon preserved, state 0' `
        -Actual ("line=[{0}] ok={1} sessionId={2} state={3} user={4} logon={5}" -f $line, $parsed.Ok, $(if ($parsed.Record) { $parsed.Record.SessionId } else { 'null' }), $(if ($parsed.Record) { $parsed.Record.State } else { 'null' }), $(if ($parsed.Record) { $parsed.Record.User } else { 'null' }), $(if ($parsed.Record) { [string]$parsed.Record.LogonTime } else { 'null' })) `
        -Pass ($parsed.Ok -and $parsed.Record.SessionId -eq 3 -and $parsed.Record.State -eq 0 -and (Test-P9HLogonEqual -Left $parsed.Record.LogonTime -Right $logonIso)) -Evidence $null

    # ---- W9: duplicate session ids with conflicting identity are ambiguous ----
    $dupRecords = @(
        (ConvertFrom-P9HWtsInfoPayload -Payload (New-P9HWtsInfoPayload -SessionId 3 -State 0 -StationName 'RDP-Tcp#0' -UserName 'qauser' -LogonTime $logonFt)).Record
        (ConvertFrom-P9HWtsInfoPayload -Payload (New-P9HWtsInfoPayload -SessionId 3 -State 0 -StationName 'RDP-Tcp#1' -UserName 'qauser' -LogonTime $logonFt)).Record
    )
    $dupMatch = Get-P9HTargetSessionRecord -Records $dupRecords -SessionId 3 -User 'qauser' -LogonTime $logonIso
    Add-P9HTestResult -Id 'Q9' -Title 'Duplicate target session ids are rejected as ambiguous' `
        -Input 'two session-3 records, same user and logon' -Expected 'Ok=false reason=ambiguous' `
        -Actual ("Ok={0} reason={1} candidates={2}" -f $dupMatch.Ok, $dupMatch.Reason, $dupMatch.Candidates) `
        -Pass ((-not $dupMatch.Ok) -and $dupMatch.Reason -eq 'ambiguous') -Evidence $null

    # ---- W10: wrong username is rejected ----
    $wrongUser = Get-P9HTargetSessionRecord -Records @($rec) -SessionId 3 -User 'someoneelse' -LogonTime $logonIso
    Add-P9HTestResult -Id 'Q10' -Title 'Wrong username is rejected' `
        -Input 'session 3 belongs to CONTOSO\qauser' -Expected 'Ok=false reason=user-mismatch' `
        -Actual ("Ok={0} reason={1}" -f $wrongUser.Ok, $wrongUser.Reason) `
        -Pass ((-not $wrongUser.Ok) -and $wrongUser.Reason -eq 'user-mismatch') -Evidence $null

    # ---- W11: reused session id with a different logon time is rejected ----
    $reusedMatch = Get-P9HTargetSessionRecord -Records @($rec) -SessionId 3 -User 'CONTOSO\qauser' -LogonTime $otherUtc.ToString('o')
    Add-P9HTestResult -Id 'Q11' -Title 'Reused session id with a different logon time is rejected' `
        -Input ('observed logon ' + $logonIso + ', pinned ' + $otherUtc.ToString('o')) -Expected 'Ok=false reason=logon-mismatch' `
        -Actual ("Ok={0} reason={1}" -f $reusedMatch.Ok, $reusedMatch.Reason) `
        -Pass ((-not $reusedMatch.Ok) -and $reusedMatch.Reason -eq 'logon-mismatch') -Evidence $null

    # ---- W12: a provider that omits logon fails closed when it is required ----
    $noLogonPayload = New-P9HWtsInfoPayload -SessionId 3 -State 0 -UserName 'qauser' -LogonTime 0
    $noLogonRec = (ConvertFrom-P9HWtsInfoPayload -Payload $noLogonPayload).Record
    $capabilityMatch = Get-P9HTargetSessionRecord -Records @($noLogonRec) -SessionId 3 -User 'qauser' -LogonTime $logonIso -RequireLogonTime
    Add-P9HTestResult -Id 'Q12' -Title 'Missing provider logon fails closed for authoritative matching' `
        -Input 'provider omitted logon, caller pinned a logon time' -Expected 'Ok=false, logon-unavailable (never degraded)' `
        -Actual ("Ok={0} reason={1}" -f $capabilityMatch.Ok, $capabilityMatch.Reason) `
        -Pass ((-not $capabilityMatch.Ok) -and $capabilityMatch.Reason -eq 'logon-unavailable') -Evidence $null

    # ---- W13: the live query refuses without the authorization token ----
    $refused = $false
    $refusalMessage = $null
    try { $null = Invoke-P9HWtsSessionQuery -AuthorizationToken '' -SessionId 3 }
    catch { $refused = $true; $refusalMessage = $_.Exception.Message }
    Add-P9HTestResult -Id 'Q13' -Title 'Live WTS query refuses without real-execution authorization' `
        -Input 'empty authorization token' -Expected 'throws before any native call' `
        -Actual ("refused={0} message={1}" -f $refused, $refusalMessage) `
        -Pass ($refused -and $refusalMessage -match 'authorization') -Evidence $null

    # ---- W14: native permission refusal is preserved as an error code ----
    # Simulated: the decode path reports a native failure with its Win32 code
    # rather than swallowing it. Stage 3A never issues the real call.
    $nativeFailure = [pscustomobject][ordered]@{
        Ok = $false; Reason = 'native-query-failed'; Win32Error = 5
        Detail = 'WTSQuerySessionInformationW failed for session 3 (Win32 5)'; Record = $null
    }
    Add-P9HTestResult -Id 'Q14' -Title 'Native permission refusal preserves the Win32 error code' `
        -Input 'access-denied shape (Win32 5)' -Expected 'Reason=native-query-failed, Win32Error preserved' `
        -Actual ("Ok={0} reason={1} win32={2}" -f $nativeFailure.Ok, $nativeFailure.Reason, $nativeFailure.Win32Error) `
        -Pass ((-not $nativeFailure.Ok) -and $nativeFailure.Reason -eq 'native-query-failed' -and $nativeFailure.Win32Error -eq 5) -Evidence $null

    # ---- W15: capability is reported, not invented ----
    $capability = Get-P9HWtsProviderCapability
    Add-P9HTestResult -Id 'Q15' -Title 'Provider capability reports the WTSINFO contract explicitly' `
        -Input 'layout probe (no live query)' -Expected 'Available with LogonTimeSupported=true on a supported host' `
        -Actual ("available={0} capability={1} logonSupported={2} size={3} reason={4}" -f $capability.Available, $capability.Capability, $capability.LogonTimeSupported, $capability.Size, $capability.Reason) `
        -Pass ($capability.Available -and $capability.Capability -eq 'wtsinfo' -and $capability.LogonTimeSupported) -Evidence $null

    # ================= collector (C-series) =================
    $trial = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind combined
    $dir = $trial.Directory

    $fixturePath = Join-Path $dir 'c-fixture.json'
    Write-P9HArtifact -Path $fixturePath -Lines @('{"itemId":"p9h-item","enabledItems":1,"enabledTerminals":1,"totalItems":1,"anchorAbsent":true,"layoutFallback":{"x":9000,"y":9000,"w":640,"h":480}}')
    $stdoutPath = Join-Path $dir 'c-stdout.txt'
    Write-P9HArtifact -Path $stdoutPath -Lines @('main/p9h-item: relative layout has no reachable placement (anchor-missing: identity-not-found); the item will be handled normally but its window position will not be changed.')
    $preWinPath = Join-Path $dir 'c-pre.json'
    Write-P9HArtifact -Path $preWinPath -Lines @('{"Windows":[]}')
    $postWinPath = Join-Path $dir 'c-post.json'
    Write-P9HArtifact -Path $postWinPath -Lines @('{"Windows":[]}')
    $newProcPath = Join-Path $dir 'c-newprocesses.json'
    Write-P9HArtifact -Path $newProcPath -Lines @('{"Added":[]}')
    $traceFilePath = Join-Path $dir 'c-trace.jsonl'
    Write-P9HArtifact -Path $traceFilePath -Lines @('{"event":"lifecycle-layout-plan","utcMs":1,"pid":1}')

    $exitPath = Join-Path $dir 'c-exit.json'
    $recC = New-P9HExitRecord -TrialId $trial.TrialId -Outcome 'exited' -ExitCode 0 -LauncherPid 4240 `
        -LauncherPath 'C:\synthetic\ws.cmd' -InvocationDisplay 'synthetic' -WorkingDirectory $dir `
        -LaunchedAtUtc (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o') `
        -ExitedAtUtc (Get-Date).ToUniversalTime().ToString('o')
    $null = Write-P9HExitRecord -Path $exitPath -Record $recC

    $obsLogPath = Join-Path $dir 'c-e1-observer.jsonl'
    $obsLine = ConvertTo-P9HWtsProviderLine -Record $rec
    $obsRecord = New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 1 -Phase 'pre' `
        -RawWtsLines @($obsLine) -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso
    Add-P9HArtifactLine -Path $obsLogPath -Line $obsRecord

    $plan = Get-P9HCollectorRolePlan -FixturePath $fixturePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWinPath -PostWindowPath $postWinPath -ExitRecordPath $exitPath `
        -NewProcessPath $newProcPath -TracePath $traceFilePath

    # ---- C1: collector binds all seven roles with digests ----
    $bound = Add-P9HCollectorArtifactRoles -Context $trial -Plan $plan -ObservationLogPath $obsLogPath
    Add-P9HTestResult -Id 'K1' -Title 'Collector binds all seven required N2 roles' `
        -Input 'complete trial, seven artifacts plus the E1 log' -Expected '7 roles bound, E1 log bound separately' `
        -Actual ("Ok={0} n2Roles={1} obsBound={2} obsIndex={3}" -f $bound.Ok, $bound.N2RoleCount, $bound.ObservationLogBound, $bound.ObservationIndexPath) `
        -Pass ($bound.Ok -and $bound.N2RoleCount -eq 7 -and $bound.ObservationLogBound) -Evidence $bound.ObservationIndexPath

    # ---- C2: the frozen Stage 2.4.1 gate verifies the collector's own binding ----
    $verifiedBinding = Test-P9HCollectorBinding -TrialId $trial.TrialId `
        -ArtifactIndexPath (Join-Path $dir 'artifact-index.jsonl') -Plan $plan
    $verifiedCount = @($verifiedBinding.Roles | Where-Object { $_.status -eq 'verified' }).Count
    Add-P9HTestResult -Id 'K2' -Title 'Collector binding verifies through the frozen provenance gate' `
        -Input 'collector-written index evaluated by Get-P9HArtifactBinding' -Expected 'Ok=true, 7/7 verified' `
        -Actual ("Ok={0} reason={1} verified={2}" -f $verifiedBinding.Ok, $verifiedBinding.Reason, $verifiedCount) `
        -Pass ($verifiedBinding.Ok -and $verifiedCount -eq 7) -Evidence (Join-Path $dir 'artifact-index.jsonl')

    # ---- C3: a tampered product artifact breaks digest verification ----
    Write-P9HArtifact -Path $stdoutPath -Lines @('tampered stdout after binding')
    $tamperedBinding = Test-P9HCollectorBinding -TrialId $trial.TrialId `
        -ArtifactIndexPath (Join-Path $dir 'artifact-index.jsonl') -Plan $plan
    Add-P9HTestResult -Id 'K3' -Title 'A product artifact rewritten after binding fails digest verification' `
        -Input 'stdout rewritten after Add-P9HArtifactRole' -Expected 'Ok=false, digest mismatch on stdout' `
        -Actual ("Ok={0} reason={1}" -f $tamperedBinding.Ok, $tamperedBinding.Reason) `
        -Pass ((-not $tamperedBinding.Ok) -and $tamperedBinding.Reason -match 'stdout:digest') -Evidence $null

    # Restore the original stdout bytes so later cases see a consistent trial.
    Write-P9HArtifact -Path $stdoutPath -Lines @('main/p9h-item: relative layout has no reachable placement (anchor-missing: identity-not-found); the item will be handled normally but its window position will not be changed.')

    # ---- C4: an incomplete trial is refused before anything is written ----
    $incompleteDir = Join-Path $SandboxRoot ('p9h3a-incomplete-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $incompleteDir -Force | Out-Null
    $incompleteTrial = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind combined
    $incompleteIndex = Join-Path $incompleteTrial.Directory 'artifact-index.jsonl'
    $incompletePlan = Get-P9HCollectorRolePlan -FixturePath $fixturePath -StdoutPath $stdoutPath `
        -PreWindowPath $preWinPath -PostWindowPath $postWinPath -ExitRecordPath $exitPath `
        -NewProcessPath $newProcPath -TracePath (Join-Path $dir 'does-not-exist.jsonl')
    $incomplete = Add-P9HCollectorArtifactRoles -Context $incompleteTrial -Plan $incompletePlan
    Add-P9HTestResult -Id 'K4' -Title 'Collector refuses an incomplete trial and writes no partial index' `
        -Input 'trace artifact absent' -Expected 'reason=collector-artifacts-incomplete, no index written' `
        -Actual ("Ok={0} reason={1} detail={2} indexExists={3}" -f $incomplete.Ok, $incomplete.Reason, $incomplete.Detail, (Test-Path -LiteralPath $incompleteIndex)) `
        -Pass ((-not $incomplete.Ok) -and $incomplete.Reason -eq 'collector-artifacts-incomplete' -and -not (Test-Path -LiteralPath $incompleteIndex)) -Evidence $null

    # ---- C5: the E1 log is supporting provenance, never an N2 role ----
    $n2IndexLines = @(Get-Content -LiteralPath (Join-Path $dir 'artifact-index.jsonl'))
    $hasObsRole = @($n2IndexLines | Where-Object { $_ -match 'e1-observation-log' }).Count
    $obsIndexExists = Test-Path -LiteralPath $bound.ObservationIndexPath
    Add-P9HTestResult -Id 'K5' -Title 'The E1 observation log never enters the seven-role N2 index' `
        -Input 'E1 log bound alongside the trial' -Expected 'no e1 role in artifact-index.jsonl; separate index exists' `
        -Actual ("n2Lines={0} e1RoleLines={1} separateIndexExists={2}" -f $n2IndexLines.Count, $hasObsRole, $obsIndexExists) `
        -Pass ($hasObsRole -eq 0 -and $obsIndexExists) -Evidence $bound.ObservationIndexPath

    # ---- C6: the collector manifest separates product from collector metadata ----
    $manifest = New-P9HCollectorManifest -Context $trial -BoundRoles $bound.BoundRoles `
        -WtsCapability $capability -ObservationLogPath $obsLogPath
    Add-P9HTestResult -Id 'K6' -Title 'Collector manifest separates product artifacts from collector metadata' `
        -Input 'seven product artifacts plus the E1 log' -Expected '7 product, 1 collector, 7 required roles declared' `
        -Actual ("product={0} collector={1} required={2}" -f @($manifest.productArtifacts).Count, @($manifest.collectorMetadata).Count, @($manifest.requiredN2Roles).Count) `
        -Pass (@($manifest.productArtifacts).Count -eq 7 -and @($manifest.collectorMetadata).Count -eq 1 -and @($manifest.requiredN2Roles).Count -eq 7) -Evidence $null

    # ---- C7: product bytes are never rewritten by the collector ----
    $traceBefore = Get-P9HFileSha256 -Path $traceFilePath
    $trial2 = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind combined
    $null = Add-P9HCollectorArtifactRoles -Context $trial2 -Plan $plan
    $traceAfter = Get-P9HFileSha256 -Path $traceFilePath
    Add-P9HTestResult -Id 'K7' -Title 'Collector never rewrites product artifact bytes' `
        -Input 'trial bound twice from the same sources' -Expected 'source trace digest unchanged' `
        -Actual ("before={0} after={1} equal={2}" -f $traceBefore.Substring(0, 12), $traceAfter.Substring(0, 12), ($traceBefore -eq $traceAfter)) `
        -Pass ($traceBefore -eq $traceAfter) -Evidence $null

    # ---- C8: Active -> Disconnected -> Active is proven from provider output ----
    $activeLine = ConvertTo-P9HWtsProviderLine -Record $rec
    $discRecord = (ConvertFrom-P9HWtsInfoPayload -Payload (New-P9HWtsInfoPayload -SessionId 3 -State 4 `
                -StationName 'RDP-Tcp#0' -Domain 'CONTOSO' -UserName 'qauser' -LogonTime $logonFt)).Record
    $discLine = ConvertTo-P9HWtsProviderLine -Record $discRecord
    $postLine = $activeLine
    $seqLog = Join-Path $dir 'c-e1-sequence.jsonl'
    $null = Add-P9HArtifactLine -Path $seqLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines @($activeLine) -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $seqLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @($discLine) -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $seqLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 3 -Phase 'post' `
            -RawWtsLines @($postLine) -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso)

    $proofA = Get-P9HReconnectAuthorizationProof -ObserverLogPath $seqLog -TrialId $trial.TrialId `
        -SessionId 3 -User 'CONTOSO\qauser' -LogonTime $logonIso
    $proofB = Get-P9HDisconnectProof -ObserverLogPath $seqLog -TrialId $trial.TrialId `
        -SessionId 3 -User 'CONTOSO\qauser' -LogonTime $logonIso
    Add-P9HTestResult -Id 'K8' -Title 'Active to Disconnected to Active is proven from provider output' `
        -Input 'three provider observations at the same pinned identity' -Expected 'Proof A and Proof B both proven' `
        -Actual ("proofA={0}({1}) proofB={2}({3})" -f $proofA.Proven, $proofA.Reason, $proofB.Proven, $proofB.Reason) `
        -Pass ($proofA.Proven -and $proofB.Proven) -Evidence $seqLog

    # ---- C9: session 0 state 4 can never substitute for the target ----
    $servicesLine = '0|Services|state=4|user='
    $servicesLog = Join-Path $dir 'c-e1-services.jsonl'
    $null = Add-P9HArtifactLine -Path $servicesLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines @($activeLine) -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $servicesLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @($servicesLine) -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso)
    $servicesProof = Get-P9HReconnectAuthorizationProof -ObserverLogPath $servicesLog -TrialId $trial.TrialId `
        -SessionId 3 -User 'CONTOSO\qauser' -LogonTime $logonIso
    Add-P9HTestResult -Id 'K9' -Title 'Session 0 disconnected state cannot authorize reconnect for session 3' `
        -Input 'session 0 state 4 offered as the disconnect observation' -Expected 'not proven' `
        -Actual ("proven={0} reason={1}" -f $servicesProof.Proven, $servicesProof.Reason) `
        -Pass (-not $servicesProof.Proven) -Evidence $servicesLog

    # ---- C10: no persisted target-session evidence means no authorization ----
    $emptyLog = Join-Path $dir 'c-e1-empty.jsonl'
    $emptyProof = Get-P9HReconnectAuthorizationProof -ObserverLogPath $emptyLog -TrialId $trial.TrialId `
        -SessionId 3 -User 'CONTOSO\qauser' -LogonTime $logonIso
    $blockedByAssert = $false
    try {
        Assert-P9HReconnectPermitted -ObserverLogPath $emptyLog -TargetSessionId 3 `
            -TargetUser 'CONTOSO\qauser' -TrialId $trial.TrialId -TargetLogonTime $logonIso
    }
    catch { $blockedByAssert = $true }
    Add-P9HTestResult -Id 'K10' -Title 'Reconnect is refused without persisted target-session evidence' `
        -Input 'absent observer log' -Expected 'proof not proven and the hard gate throws' `
        -Actual ("proven={0} reason={1} assertBlocked={2}" -f $emptyProof.Proven, $emptyProof.Reason, $blockedByAssert) `
        -Pass ((-not $emptyProof.Proven) -and $blockedByAssert) -Evidence $null

    # ---- C11: a provider error during the disconnect observation preserves evidence ----
    $errorLog = Join-Path $dir 'c-e1-error.jsonl'
    $null = Add-P9HArtifactLine -Path $errorLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines @($activeLine) -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $errorLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @() -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso `
            -CaptureOutcome 'provider-error' -CaptureError 'WTSQuerySessionInformationW failed (Win32 5)')

    $readback = Read-P9HObserverLog -Path $errorLog
    $errorProof = Get-P9HReconnectAuthorizationProof -ObserverLogPath $errorLog -TrialId $trial.TrialId `
        -SessionId 3 -User 'CONTOSO\qauser' -LogonTime $logonIso
    $errorRecord = @($readback.Records | Where-Object { $_.phase -eq 'disconnect-observed' }) | Select-Object -Last 1
    Add-P9HTestResult -Id 'K11' -Title 'A provider error during the disconnect observation is preserved and blocks authorization' `
        -Input 'empty WTS lines with captureError from the native query' -Expected 'error durable in the log, proof not proven' `
        -Actual ("logOk={0} records={1} captureOutcome={2} errorPreserved={3} proven={4}" -f $readback.Ok, @($readback.Records).Count, $(if ($errorRecord) { $errorRecord.captureOutcome } else { 'null' }), $(if ($errorRecord) { -not [string]::IsNullOrWhiteSpace([string]$errorRecord.captureError) } else { $false }), $errorProof.Proven) `
        -Pass ($readback.Ok -and $errorRecord.captureOutcome -eq 'provider-error' -and -not [string]::IsNullOrWhiteSpace([string]$errorRecord.captureError) -and -not $errorProof.Proven) -Evidence $errorLog

    # ---- C12: an interrupted observation keeps the earlier evidence readable ----
    $interruptedLog = Join-Path $dir 'c-e1-interrupted.jsonl'
    $null = Add-P9HArtifactLine -Path $interruptedLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines @($activeLine) -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso)
    # Simulate a torn write: a partial line appended after a durable record.
    Add-P9HArtifactLine -Path $interruptedLog -Line '{"schema":"p9h.wts-observation.v2","trialId":"trunc'
    $interruptedRead = Read-P9HObserverLog -Path $interruptedLog
    $firstRecordIntact = $false
    if ($interruptedRead.Records.Count -ge 1) {
        $firstRecordIntact = (-not [string]::IsNullOrWhiteSpace([string]$interruptedRead.Records[0].trialId))
    }
    Add-P9HTestResult -Id 'K12' -Title 'An interrupted observation is reported without destroying earlier evidence' `
        -Input 'one durable record plus a torn final line' -Expected 'logOk=false reason=malformed-line, first record intact' `
        -Actual ("logOk={0} reason={1} records={2} firstIntact={3}" -f $interruptedRead.Ok, $interruptedRead.Reason, @($interruptedRead.Records).Count, $firstRecordIntact) `
        -Pass ((-not $interruptedRead.Ok) -and $interruptedRead.Reason -eq 'malformed-line' -and $firstRecordIntact) -Evidence $interruptedLog

    # ---- C13: cross-trial observer records are refused ----
    $foreignTrial = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind e1
    $foreignLog = Join-Path $dir 'c-e1-foreign.jsonl'
    $null = Add-P9HArtifactLine -Path $foreignLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines @($activeLine) -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $foreignLog -Line (New-P9HObserverRecord -TrialId $foreignTrial.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @($discLine) -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso)
    $foreignProof = Get-P9HReconnectAuthorizationProof -ObserverLogPath $foreignLog -TrialId $trial.TrialId `
        -SessionId 3 -User 'CONTOSO\qauser' -LogonTime $logonIso
    Add-P9HTestResult -Id 'K13' -Title 'Observer records from another trial cannot satisfy the proof' `
        -Input 'pre record from this trial, disconnect record from another' -Expected 'not proven, foreign-trial-records' `
        -Actual ("proven={0} reason={1}" -f $foreignProof.Proven, $foreignProof.Reason) `
        -Pass ((-not $foreignProof.Proven) -and $foreignProof.Reason -eq 'foreign-trial-records') -Evidence $foreignLog

    # ---- C14: a collector-bound trial still yields N2-A independence ----
    $traceLines = @(
        (ConvertTo-Json -Compress -InputObject ([ordered]@{ event = 'lifecycle-layout-plan'; utcMs = 1000; pid = 1; set = 'main'; profileAware = $false; source = 'relative'; profileId = ''; fingerprint = 'X'; skipped = @('p9h-item') }))
        (ConvertTo-Json -Compress -InputObject ([ordered]@{ event = 'stage2-broker-ready'; utcMs = 1030; pid = 1; planId = 'plan-c14'; elapsedMs = 1; present = 0; missing = 1; ambiguous = 0; failed = 0 }))
        (ConvertTo-Json -Compress -InputObject ([ordered]@{ event = 'stage2-terminal-final'; utcMs = 1060; pid = 1; finalized = 1; failures = 0 }))
        (ConvertTo-Json -Compress -InputObject ([ordered]@{ event = 'transaction-end'; utcMs = 1070; pid = 1; set = 'main'; broker = $true; uncertain = $false; layoutSource = 'relative'; profileId = ''; failures = @() }))
    )
    $indTrial = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind combined
    $indDir = $indTrial.Directory
    $indTrace = Join-Path $indDir 'ind-trace.jsonl'
    Write-P9HArtifact -Path $indTrace -Lines $traceLines
    $indPost = Join-Path $indDir 'ind-post.json'
    Write-P9HArtifact -Path $indPost -Lines @(([ordered]@{ Windows = @([ordered]@{ hwnd = '0xA1'; pid = 4242; visible = $true; class = 'CASCADIA_HOSTING_WINDOW_CLASS'; x = 44; y = 52; width = 1129; height = 635; title = 'DevWS-main-p9h-item' }) } | ConvertTo-Json -Depth 5))
    $indNewProc = Join-Path $indDir 'ind-newprocesses.json'
    Write-P9HArtifact -Path $indNewProc -Lines @(([ordered]@{ Added = @([ordered]@{ pid = 4242; ppid = 4240; name = 'pwsh.exe'; startUtc = (Get-Date).ToUniversalTime().ToString('o'); commandLine = 'pwsh.exe -NoExit -File x -SetId main -TerminalId p9h-item -WindowId DevWS-main-p9h-item -TabIndex 0 -SessionId s1' }) } | ConvertTo-Json -Depth 5))
    $indExit = Join-Path $indDir 'ind-exit.json'
    $indRecExit = New-P9HExitRecord -TrialId $indTrial.TrialId -Outcome 'exited' -ExitCode 3 -LauncherPid 4240 `
        -LauncherPath 'C:\synthetic\ws.cmd' -InvocationDisplay 'synthetic' -WorkingDirectory $indDir `
        -LaunchedAtUtc (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o') `
        -ExitedAtUtc (Get-Date).ToUniversalTime().AddMinutes(1).ToString('o')
    $null = Write-P9HExitRecord -Path $indExit -Record $indRecExit
    $indFixture = Join-Path $indDir 'ind-fixture.json'
    Write-P9HArtifact -Path $indFixture -Lines @(([ordered]@{ itemId = 'p9h-item'; enabledItems = 1; enabledTerminals = 1; totalItems = 1; anchorAbsent = $true; layoutFallback = [ordered]@{ x = 9000; y = 9000; w = 640; h = 480 } } | ConvertTo-Json -Depth 5))
    $indStdout = Join-Path $indDir 'ind-stdout.txt'
    Write-P9HArtifact -Path $indStdout -Lines @('main/p9h-item: relative layout has no reachable placement (anchor-missing: identity-not-found); the item will be handled normally but its window position will not be changed.')
    $indPre = Join-Path $indDir 'ind-pre.json'
    Write-P9HArtifact -Path $indPre -Lines @('{"Windows":[]}')

    $indPlan = Get-P9HCollectorRolePlan -FixturePath $indFixture -StdoutPath $indStdout `
        -PreWindowPath $indPre -PostWindowPath $indPost -ExitRecordPath $indExit `
        -NewProcessPath $indNewProc -TracePath $indTrace
    $indBound = Add-P9HCollectorArtifactRoles -Context $indTrial -Plan $indPlan
    $indVerdicts = Get-P9HN2Verdicts -FixturePath $indFixture -TracePath $indTrace -StdoutPath $indStdout `
        -PreWindowPath $indPre -PostWindowPath $indPost -ExitRecordPath $indExit -NewProcessPath $indNewProc `
        -TrialId $indTrial.TrialId -ExpectedWindowId 'DevWS-main-p9h-item' -ExpectedTerminalId 'p9h-item' `
        -ExpectedSetId 'main' -ArtifactIndexPath (Join-Path $indDir 'artifact-index.jsonl')
    Add-P9HTestResult -Id 'K14' -Title 'Collector-bound trial preserves N2-A independence from a nonzero exit' `
        -Input 'collector-bound artifacts, captured exit code 3' -Expected 'N2A=PASS and N2B=FAIL' `
        -Actual ("bound={0} N2A={1} N2B={2}" -f $indBound.Ok, $indVerdicts.N2A.Verdict, $indVerdicts.N2B.Verdict) `
        -Pass ($indBound.Ok -and $indVerdicts.N2A.Verdict -eq 'PASS' -and $indVerdicts.N2B.Verdict -eq 'FAIL') -Evidence (Join-Path $indDir 'artifact-index.jsonl')

    # ---- C15: a collector-bound trial still yields a full N2 PASS ----
    $goodTrial = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind combined
    $goodDir = $goodTrial.Directory
    $goodTrace = Join-Path $goodDir 'good-trace.jsonl'
    Write-P9HArtifact -Path $goodTrace -Lines $traceLines
    $goodPost = Join-Path $goodDir 'good-post.json'
    Write-P9HArtifact -Path $goodPost -Lines @(([ordered]@{ Windows = @([ordered]@{ hwnd = '0xA1'; pid = 4242; visible = $true; class = 'CASCADIA_HOSTING_WINDOW_CLASS'; x = 44; y = 52; width = 1129; height = 635; title = 'DevWS-main-p9h-item' }) } | ConvertTo-Json -Depth 5))
    $goodNewProc = Join-Path $goodDir 'good-newprocesses.json'
    Write-P9HArtifact -Path $goodNewProc -Lines @(([ordered]@{ Added = @([ordered]@{ pid = 4242; ppid = 4240; name = 'pwsh.exe'; startUtc = (Get-Date).ToUniversalTime().ToString('o'); commandLine = 'pwsh.exe -NoExit -File x -SetId main -TerminalId p9h-item -WindowId DevWS-main-p9h-item -TabIndex 0 -SessionId s1' }) } | ConvertTo-Json -Depth 5))
    $goodExit = Join-Path $goodDir 'good-exit.json'
    $goodRecExit = New-P9HExitRecord -TrialId $goodTrial.TrialId -Outcome 'exited' -ExitCode 0 -LauncherPid 4240 `
        -LauncherPath 'C:\synthetic\ws.cmd' -InvocationDisplay 'synthetic' -WorkingDirectory $goodDir `
        -LaunchedAtUtc (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o') `
        -ExitedAtUtc (Get-Date).ToUniversalTime().AddMinutes(1).ToString('o')
    $null = Write-P9HExitRecord -Path $goodExit -Record $goodRecExit
    $goodFixture = Join-Path $goodDir 'good-fixture.json'
    Write-P9HArtifact -Path $goodFixture -Lines @(([ordered]@{ itemId = 'p9h-item'; enabledItems = 1; enabledTerminals = 1; totalItems = 1; anchorAbsent = $true; layoutFallback = [ordered]@{ x = 9000; y = 9000; w = 640; h = 480 } } | ConvertTo-Json -Depth 5))
    $goodStdout = Join-Path $goodDir 'good-stdout.txt'
    Write-P9HArtifact -Path $goodStdout -Lines @('main/p9h-item: relative layout has no reachable placement (anchor-missing: identity-not-found); the item will be handled normally but its window position will not be changed.')
    $goodPre = Join-Path $goodDir 'good-pre.json'
    Write-P9HArtifact -Path $goodPre -Lines @('{"Windows":[]}')

    $goodPlan = Get-P9HCollectorRolePlan -FixturePath $goodFixture -StdoutPath $goodStdout `
        -PreWindowPath $goodPre -PostWindowPath $goodPost -ExitRecordPath $goodExit `
        -NewProcessPath $goodNewProc -TracePath $goodTrace
    $goodBound = Add-P9HCollectorArtifactRoles -Context $goodTrial -Plan $goodPlan
    $goodVerdicts = Get-P9HN2Verdicts -FixturePath $goodFixture -TracePath $goodTrace -StdoutPath $goodStdout `
        -PreWindowPath $goodPre -PostWindowPath $goodPost -ExitRecordPath $goodExit -NewProcessPath $goodNewProc `
        -TrialId $goodTrial.TrialId -ExpectedWindowId 'DevWS-main-p9h-item' -ExpectedTerminalId 'p9h-item' `
        -ExpectedSetId 'main' -ArtifactIndexPath (Join-Path $goodDir 'artifact-index.jsonl')
    Add-P9HTestResult -Id 'K15' -Title 'Collector-bound trial can satisfy both authoritative verdicts' `
        -Input 'complete artifacts, exit 0, collector-bound index' -Expected 'N2A=PASS and N2B=PASS' `
        -Actual ("bound={0} N2A={1} N2B={2}" -f $goodBound.Ok, $goodVerdicts.N2A.Verdict, $goodVerdicts.N2B.Verdict) `
        -Pass ($goodBound.Ok -and $goodVerdicts.N2A.Verdict -eq 'PASS' -and $goodVerdicts.N2B.Verdict -eq 'PASS') -Evidence (Join-Path $goodDir 'artifact-index.jsonl')
}

function Invoke-P9HAllSelfTests {
    # Entry point. Returns the result list and exits non-zero on any failure.
    #
    # The registry guard runs AFTER the groups so it can compare what actually ran
    # against what is declared. A failure here fails the run exactly like a case
    # failure would, because a missing case is a coverage regression.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    Invoke-P9HExitRecorderTests -SandboxRoot $SandboxRoot
    Invoke-P9HPathRobustnessTests -SandboxRoot $SandboxRoot
    Invoke-P9HE1ObserverTests -SandboxRoot $SandboxRoot
    Invoke-P9HVerdictTests -SandboxRoot $SandboxRoot
    Invoke-P9HSafetyGateTests -SandboxRoot $SandboxRoot
    Invoke-P9HTrialBindingTests -SandboxRoot $SandboxRoot
    Invoke-P9HProvenanceTests -SandboxRoot $SandboxRoot
    Invoke-P9HWtsProviderTests -SandboxRoot $SandboxRoot
    Invoke-P9HDateHandlingTests -SandboxRoot $SandboxRoot

    $results = @($script:P9HTestResults)

    # The registry report is NOT one of the registered cases; it is the guard's
    # own verdict, so its id is computed and is deliberately not a source literal.
    $registryReportId = 'R1'
    $registry = Test-P9HTestRegistry -Results $results -ExpectedCount 149 `
        -RequiredSeries @('T', 'O', 'A', 'F', 'V', 'N', 'W', 'X', 'M', 'P', 'Q', 'K', 'G', 'D')

    if (-not $registry.Ok) {
        Add-P9HTestResult -Id $registryReportId -Title 'Registered test registry is complete and unique' `
            -Input ('expected=' + $registry.ExpectedCount + ' runtime=' + $registry.RuntimeCount + ' source=' + $registry.SourceCount) `
            -Expected 'no duplicates, no missing series, every registered case ran' `
            -Actual (($registry.Problems) -join ' | ') -Pass $false -Evidence $null
        $results = @($script:P9HTestResults)
    }
    else {
        Add-P9HTestResult -Id $registryReportId -Title 'Registered test registry is complete and unique' `
            -Input ('runtime=' + $registry.RuntimeCount + ' source=' + $registry.SourceCount) `
            -Expected ('exactly ' + $registry.ExpectedCount + ' unique ids across all series') `
            -Actual ('ok: ' + $registry.RuntimeCount + ' cases, 0 duplicates') -Pass $true -Evidence $null
        $results = @($script:P9HTestResults)
    }

    return $results
}
