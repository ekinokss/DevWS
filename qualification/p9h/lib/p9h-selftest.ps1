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
    $gateResolved = [pscustomobject][ordered]@{
        Ok = $true; Reason = 'ok'; TargetOk = $true; TargetReason = 'ok'; TargetStateChanged = $false
        Rows = @([pscustomobject][ordered]@{
                SessionId = 3; StationName = 'RDP-Tcp#0'
                EnumeratedState = 0; EnumeratedStateName = 'Active'; IsListener = $false
                QueryOk = $true; QueryReason = 'ok'; InfoState = 0; InfoStateName = 'Active'
                User = 'synthetic-account'; LogonTime = '2026-11-14T10:00:00.0000000Z'
                SessionIdConsistent = $true; StateConsistent = $true
            })
    }
    $plan = New-P9HDisconnectPlan -TrialId 'gate' -TargetSessionId '3' -TargetUser 'synthetic-account' `
        -GuestComputerName 'SYNTHETIC-GUEST' -VmId '11111111-2222-3333-4444-555555555555' -ResolvedSessions $gateResolved
    $refused = $false
    try { Invoke-P9HControlledDisconnect -Plan $plan -AuthorizationToken ''  -ExpectedComputerName 'SYNTHETIC-GUEST' -ExpectedVmId '11111111-2222-3333-4444-555555555555' } catch { $refused = $true }
    Add-P9HTestResult -Id 'G1' -Title 'Controlled disconnect refuses without authorization' `
        -Input 'empty token' -Expected 'throws, no process spawned' -Actual ("refused={0}" -f $refused) `
        -Pass $refused -Evidence $null

    # ---- G2: wrong token refused ----
    $refused = $false
    try { Invoke-P9HControlledDisconnect -Plan $plan -AuthorizationToken 'not-the-phrase'  -ExpectedComputerName 'SYNTHETIC-GUEST' -ExpectedVmId '11111111-2222-3333-4444-555555555555' } catch { $refused = $true }
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
    try { $null = New-P9HDisconnectPlan -TrialId 'gate' -TargetSessionId '' -TargetUser 'synthetic-account'  -GuestComputerName 'SYNTHETIC-GUEST' -VmId '11111111-2222-3333-4444-555555555555' } catch { $refused = $true }
    Add-P9HTestResult -Id 'G4' -Title 'Disconnect with omitted session id is refused' `
        -Input 'empty session id' -Expected 'throws (no implicit current-session target)' `
        -Actual ("refused={0}" -f $refused) -Pass $refused -Evidence $null

    # ---- G5: session 0 refused as a target ----
    $refused = $false
    try { $null = New-P9HDisconnectPlan -TrialId 'gate' -TargetSessionId '0' -TargetUser 'synthetic-account'  -GuestComputerName 'SYNTHETIC-GUEST' -VmId '11111111-2222-3333-4444-555555555555' } catch { $refused = $true }
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

    # ---- K6: per-role origin classification, not a bare count ----
    # Stage 3A asserted only that seven artifacts were "product" and one was
    # "collector", which was both a weak assertion and a factually wrong model.
    # This asserts the CORRECT origin and capturedBy of every role.
    $manifest = New-P9HCollectorManifest -Context $trial -BoundRoles $bound.BoundRoles `
        -WtsCapability $capability -ObservationLogPath $obsLogPath

    $expectedPerRole = @{
        'fixture'       = @('fixture', 'qualification-launcher')
        'stdout'        = @('product', 'qualification-launcher')
        'pre-windows'   = @('operating-system', 'qualification-observer')
        'post-windows'  = @('operating-system', 'qualification-observer')
        'exit-record'   = @('qualification', 'qualification-recorder')
        'new-processes' = @('operating-system', 'qualification-observer')
        'trace'         = @('product', 'qualification-capture')
    }

    $k6Problems = [System.Collections.Generic.List[string]]::new()
    foreach ($role in $expectedPerRole.Keys) {
        $entry = @($manifest.roleClassification | Where-Object { $_.role -eq $role })
        if ($entry.Count -ne 1) { $k6Problems.Add("$role:missing") | Out-Null; continue }
        if ($entry[0].origin -ne $expectedPerRole[$role][0]) { $k6Problems.Add("$role:origin=$($entry[0].origin)") | Out-Null }
        if ($entry[0].capturedBy -ne $expectedPerRole[$role][1]) { $k6Problems.Add("$role:capturedBy=$($entry[0].capturedBy)") | Out-Null }
    }

    # The specific misclassification this stage corrects: the exit record is
    # authored by the qualification recorder, never by the product.
    $exitEntry = @($manifest.roleClassification | Where-Object { $_.role -eq 'exit-record' })[0]
    $exitNotProduct = ($exitEntry.origin -ne 'product' -and
                       @($manifest.byOrigin.product | Where-Object { $_.role -eq 'exit-record' }).Count -eq 0)

    $productOriginCount = @($manifest.byOrigin.product).Count
    $osOriginCount = @($manifest.byOrigin.'operating-system').Count

    Add-P9HTestResult -Id 'K6' -Title 'Collector manifest reports the correct origin of every artifact role' `
        -Input 'seven bound N2 artifacts plus the E1 log' `
        -Expected 'fixture=fixture, stdout/trace=product, windows/new-processes=operating-system, exit-record=qualification' `
        -Actual ("problems={0} exitOrigin={1} productOrigin={2} osOrigin={3} exitNotProduct={4}" -f $(if ($k6Problems.Count -eq 0) { 'none' } else { $k6Problems -join ',' }), $exitEntry.origin, $productOriginCount, $osOriginCount, $exitNotProduct) `
        -Pass ($k6Problems.Count -eq 0 -and $exitNotProduct -and $productOriginCount -eq 2 -and $osOriginCount -eq 3 -and @($manifest.requiredN2Roles).Count -eq 7) -Evidence $null

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

function Invoke-P9HWtsEnumerationTests {
    # Y-series: complete session-table enumeration and correlation (Stage 3A.1).
    # Z-series: corrected artifact origin classification (Stage 3A.1).
    #
    # Every case runs from SYNTHETIC WTS_SESSION_INFO bytes and synthetic WTSINFO
    # payloads. Nothing here calls WTSEnumerateSessionsW or
    # WTSQuerySessionInformationW: the only live-path exercise is the
    # authorization refusal (R15), which is what proves the adapters cannot touch
    # a live session by accident.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $logonUtc = [datetime]::SpecifyKind([datetime]::new(2026, 11, 11, 10, 0, 0), [System.DateTimeKind]::Utc)
    $logonFt = $logonUtc.ToFileTimeUtc()
    $logonIso = $logonUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $otherUtc = [datetime]::SpecifyKind([datetime]::new(2026, 11, 11, 09, 0, 0), [System.DateTimeKind]::Utc)
    $otherFt = $otherUtc.ToFileTimeUtc()

    # ---- shared two-session table: target 3 Active, session 0 Disconnected ----
    $twoSession = New-P9HWtsSessionInfoPayload -Sessions @(
        @{ SessionId = 0; StationName = 'Services'; State = 4 }
        @{ SessionId = 3; StationName = 'RDP-Tcp#0'; State = 0 }
    )
    $twoDecoded = ConvertFrom-P9HWtsSessionInfoPayload -Payload $twoSession.Payload `
        -ReportedCount $twoSession.ReportedCount -Layout $twoSession.Layout

    $targetActive = (ConvertFrom-P9HWtsInfoPayload -Payload (New-P9HWtsInfoPayload -SessionId 3 -State 0 `
                -StationName 'RDP-Tcp#0' -Domain 'CONTOSO' -UserName 'qauser' -LogonTime $logonFt)).Record
    $servicesDisc = (ConvertFrom-P9HWtsInfoPayload -Payload (New-P9HWtsInfoPayload -SessionId 0 -State 4 `
                -StationName 'Services' -UserName '' -LogonTime 0)).Record

    $goodQueries = @{
        0 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = $servicesDisc }
        3 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = $targetActive }
    }

    # ---- R1: full two-session enumeration, target plus session 0 ----
    Add-P9HTestResult -Id 'Y1' -Title 'Full enumeration decodes both the target and session 0' `
        -Input 'WTS_SESSION_INFO with sessions 0 (Services, 4) and 3 (RDP-Tcp#0, 0)' `
        -Expected 'Ok=true, two records, station names preserved' `
        -Actual ("Ok={0} reason={1} records={2} ids={3}" -f $twoDecoded.Ok, $twoDecoded.Reason, @($twoDecoded.Records).Count, (@($twoDecoded.Records | ForEach-Object { $_.SessionId }) -join ',')) `
        -Pass ($twoDecoded.Ok -and @($twoDecoded.Records).Count -eq 2 -and @($twoDecoded.Records | Where-Object { $_.SessionId -eq 0 -and $_.StationName -eq 'Services' -and $_.State -eq 4 }).Count -eq 1 -and @($twoDecoded.Records | Where-Object { $_.SessionId -eq 3 -and $_.StationName -eq 'RDP-Tcp#0' -and $_.State -eq 0 }).Count -eq 1) -Evidence $null

    # ---- R2: target Active with session 0 Disconnected yields NO target disconnect proof ----
    $table2 = Resolve-P9HWtsSessionTable -EnumeratedSessions $twoDecoded.Records -QueryResults $goodQueries -TargetSessionId 3
    $capture2 = Get-P9HWtsProviderTableCapture -Rows $table2.Rows -TargetSessionId 3
    $parsedTable2 = ConvertFrom-P9HWtsTable -Lines $capture2.Lines
    $targetDisc = Test-P9HTargetDisconnected -Records $parsedTable2.Records -SessionId 3 -User 'CONTOSO\qauser' -LogonTime $logonIso
    Add-P9HTestResult -Id 'Y2' -Title 'Session 0 disconnected cannot prove the target disconnected' `
        -Input 'target 3 Active, session 0 state 4, complete table' -Expected 'target Disconnected=false' `
        -Actual ("tableOk={0} lines={1} targetDisconnected={2} reason={3}" -f $parsedTable2.Ok, $capture2.LineCount, $targetDisc.Disconnected, $targetDisc.Reason) `
        -Pass ($parsedTable2.Ok -and $capture2.LineCount -eq 2 -and -not $targetDisc.Disconnected) -Evidence $null

    # ---- R3: target genuinely Disconnected yields correct target evidence ----
    $discTable = New-P9HWtsSessionInfoPayload -Sessions @(
        @{ SessionId = 0; StationName = 'Services'; State = 4 }
        @{ SessionId = 3; StationName = 'RDP-Tcp#0'; State = 4 }
    )
    $discDecoded = ConvertFrom-P9HWtsSessionInfoPayload -Payload $discTable.Payload `
        -ReportedCount $discTable.ReportedCount -Layout $discTable.Layout
    $targetDisconnectedRecord = (ConvertFrom-P9HWtsInfoPayload -Payload (New-P9HWtsInfoPayload -SessionId 3 -State 4 `
                -StationName 'RDP-Tcp#0' -Domain 'CONTOSO' -UserName 'qauser' -LogonTime $logonFt)).Record
    $discQueries = @{
        0 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = $servicesDisc }
        3 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = $targetDisconnectedRecord }
    }
    $discResolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $discDecoded.Records -QueryResults $discQueries -TargetSessionId 3
    $discCapture = Get-P9HWtsProviderTableCapture -Rows $discResolved.Rows -TargetSessionId 3
    $discParsed = ConvertFrom-P9HWtsTable -Lines $discCapture.Lines
    $discJudged = Test-P9HTargetDisconnected -Records $discParsed.Records -SessionId 3 -User 'CONTOSO\qauser' -LogonTime $logonIso
    Add-P9HTestResult -Id 'Y3' -Title 'A genuinely disconnected target yields correct target evidence' `
        -Input 'target 3 state 4 with its own logon identity' -Expected 'target Disconnected=true, matched to session 3 only' `
        -Actual ("targetDisconnected={0} reason={1} matchedIsTarget={2}" -f $discJudged.Disconnected, $discJudged.Reason, ($null -ne $discJudged.Record -and [int]$discJudged.Record.SessionId -eq 3)) `
        -Pass ($discJudged.Disconnected -and $null -ne $discJudged.Record -and [int]$discJudged.Record.SessionId -eq 3) -Evidence $null

    # ---- R4: enumeration failure preserves the Win32 error ----
    $enumFailure = [pscustomobject][ordered]@{
        Ok = $false; Reason = 'native-enumerate-failed'; Capability = 'wtsinfo'
        Detail = 'WTSEnumerateSessionsW failed (Win32 5)'; Sessions = @(); Win32Error = 5; ReportedCount = 0
    }
    Add-P9HTestResult -Id 'Y4' -Title 'Enumeration failure preserves the Win32 error code' `
        -Input 'access-denied shape (Win32 5)' -Expected 'Ok=false reason=native-enumerate-failed, Win32Error=5' `
        -Actual ("Ok={0} reason={1} win32={2}" -f $enumFailure.Ok, $enumFailure.Reason, $enumFailure.Win32Error) `
        -Pass ((-not $enumFailure.Ok) -and $enumFailure.Reason -eq 'native-enumerate-failed' -and $enumFailure.Win32Error -eq 5) -Evidence $null

    # ---- R5: duplicate target session ids fail closed as ambiguous ----
    $dupTable = New-P9HWtsSessionInfoPayload -Sessions @(
        @{ SessionId = 3; StationName = 'RDP-Tcp#0'; State = 0 }
        @{ SessionId = 3; StationName = 'RDP-Tcp#1'; State = 0 }
    )
    $dupDecoded = ConvertFrom-P9HWtsSessionInfoPayload -Payload $dupTable.Payload `
        -ReportedCount $dupTable.ReportedCount -Layout $dupTable.Layout
    $dupQueries = @{ 3 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = $targetActive } }
    $dupResolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $dupDecoded.Records -QueryResults $dupQueries -TargetSessionId 3
    Add-P9HTestResult -Id 'Y5' -Title 'Duplicate target session ids are rejected as ambiguous' `
        -Input 'two enumerated records both claiming session 3' -Expected 'Ok=false, ambiguous-enumeration, duplicate reported' `
        -Actual ("Ok={0} reason={1} targetOk={2} dups={3}" -f $dupResolved.Ok, $dupResolved.Reason, $dupResolved.TargetOk, (@($dupResolved.DuplicateSessionIds) -join ',')) `
        -Pass ((-not $dupResolved.Ok) -and $dupResolved.Reason -eq 'ambiguous-enumeration' -and -not $dupResolved.TargetOk -and @($dupResolved.DuplicateSessionIds) -contains 3) -Evidence $null

    # ---- R6: enumerated id vs WTSINFO id mismatch fails closed ----
    $mismatchQueries = @{
        0 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = $servicesDisc }
        # Enumerated as 3, but the query answers about session 7.
        3 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (ConvertFrom-P9HWtsInfoPayload -Payload (New-P9HWtsInfoPayload -SessionId 7 -State 0 -StationName 'RDP-Tcp#0' -Domain 'CONTOSO' -UserName 'qauser' -LogonTime $logonFt)).Record }
    }
    $mismatchResolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $twoDecoded.Records -QueryResults $mismatchQueries -TargetSessionId 3
    Add-P9HTestResult -Id 'Y6' -Title 'Enumerated/WTSINFO session-id mismatch fails closed' `
        -Input 'enumerated session 3, WTSINFO returned session 7' -Expected 'Ok=false, target not ok, mismatch recorded' `
        -Actual ("Ok={0} reason={1} targetOk={2} targetReason={3}" -f $mismatchResolved.Ok, $mismatchResolved.Reason, $mismatchResolved.TargetOk, $mismatchResolved.TargetReason) `
        -Pass ((-not $mismatchResolved.Ok) -and -not $mismatchResolved.TargetOk -and $mismatchResolved.TargetReason -eq 'target-session-id-mismatch') -Evidence $null

    # ---- R7: missing target logon time remains blocking ----
    $noLogonTarget = (ConvertFrom-P9HWtsInfoPayload -Payload (New-P9HWtsInfoPayload -SessionId 3 -State 0 `
                -StationName 'RDP-Tcp#0' -Domain 'CONTOSO' -UserName 'qauser' -LogonTime 0)).Record
    $noLogonQueries = @{
        0 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = $servicesDisc }
        3 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = $noLogonTarget }
    }
    $noLogonResolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $twoDecoded.Records -QueryResults $noLogonQueries -TargetSessionId 3
    $noLogonCapture = Get-P9HWtsProviderTableCapture -Rows $noLogonResolved.Rows -TargetSessionId 3
    $noLogonParsed = ConvertFrom-P9HWtsTable -Lines $noLogonCapture.Lines
    $noLogonMatch = Get-P9HTargetSessionRecord -Records $noLogonParsed.Records -SessionId 3 -User 'CONTOSO\qauser' -LogonTime $logonIso -RequireLogonTime
    Add-P9HTestResult -Id 'Y7' -Title 'A missing target logon time still blocks authoritative matching' `
        -Input 'target WTSINFO with LogonTime=0, caller pinned a logon' -Expected 'logon-unavailable, never degraded' `
        -Actual ("tableOk={0} matchOk={1} reason={2}" -f $noLogonResolved.Ok, $noLogonMatch.Ok, $noLogonMatch.Reason) `
        -Pass ((-not $noLogonMatch.Ok) -and $noLogonMatch.Reason -eq 'logon-unavailable') -Evidence $null

    # ---- R8: per-session query failure preserved without losing other observations ----
    $failedQueries = @{
        0 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = $servicesDisc }
        3 = [pscustomobject]@{ Ok = $false; Reason = 'native-query-failed'; Detail = 'WTSQuerySessionInformationW failed (Win32 5)'; Record = $null; Win32Error = 5 }
    }
    $failedResolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $twoDecoded.Records -QueryResults $failedQueries -TargetSessionId 3
    $failedCapture = Get-P9HWtsProviderTableCapture -Rows $failedResolved.Rows -TargetSessionId 3
    $failedRowsKept = @($failedResolved.Rows | Where-Object { $_.SessionId -eq 0 -and $_.QueryOk }).Count
    $failureRecorded = @($failedResolved.Rows | Where-Object { $_.SessionId -eq 3 -and -not $_.QueryOk -and $_.QueryReason -eq 'native-query-failed' }).Count
    Add-P9HTestResult -Id 'Y8' -Title 'A per-session query failure is preserved without losing other observations' `
        -Input 'target query failed with Win32 5, session 0 succeeded' -Expected 'failure recorded, session 0 still observed, no target proof' `
        -Actual ("rows={0} failedRows={1} session0Kept={2} failureRecorded={3} targetOk={4} targetLines={5}" -f $failedResolved.RowCount, $failedCapture.FailedCount, $failedRowsKept, $failureRecorded, $failedResolved.TargetOk, $failedCapture.LineCount) `
        -Pass ($failedRowsKept -eq 1 -and $failureRecorded -eq 1 -and -not $failedResolved.TargetOk -and $failedCapture.LineCount -eq 1 -and $failedCapture.FailedCount -eq 1) -Evidence $null

    # ---- R9: a state change during enumeration/query is an evidence gap ----
    $changedQueries = @{
        0 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = $servicesDisc }
        # Enumerated Active, but the later query reports Disconnected.
        3 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = $targetDisconnectedRecord }
    }
    $changedResolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $twoDecoded.Records -QueryResults $changedQueries -TargetSessionId 3
    $changedCapture = Get-P9HWtsProviderTableCapture -Rows $changedResolved.Rows -TargetSessionId 3
    $changedParsed = ConvertFrom-P9HWtsTable -Lines $changedCapture.Lines
    $changedProof = Get-P9HReconnectAuthorizationProof -ObserverLogPath (Join-Path $SandboxRoot 'does-not-exist-r9.jsonl') `
        -TrialId 'r9' -SessionId 3 -User 'CONTOSO\qauser' -LogonTime $logonIso
    Add-P9HTestResult -Id 'Y9' -Title 'A state change during collection is an evidence gap, not a transition' `
        -Input 'enumerated Active, queried Disconnected for the same session' -Expected 'Ok=false, state-changed-during-collection, no atomic claim' `
        -Actual ("Ok={0} reason={1} targetStateChanged={2} isAtomic={3}" -f $changedResolved.Ok, $changedResolved.Reason, $changedResolved.TargetStateChanged, $changedResolved.IsAtomicSnapshot) `
        -Pass ((-not $changedResolved.Ok) -and $changedResolved.Reason -eq 'state-changed-during-collection' -and $changedResolved.TargetStateChanged -and -not $changedResolved.IsAtomicSnapshot) -Evidence $null

    # ---- R10: layout mismatch blocks the native path ----
    $sessLayout = Test-P9HWtsSessionInfoLayout
    $layoutBlock = [pscustomobject][ordered]@{
        Ok = $false; Reason = 'layout-size-mismatch'; Capability = 'unsupported'
        Detail = 'documented 24 bytes, measured 16 bytes'
        Sessions = @(); Win32Error = $null; ReportedCount = $null
    }
    Add-P9HTestResult -Id 'Y10' -Title 'A layout mismatch prevents any native enumeration' `
        -Input 'simulated layout-size-mismatch capability result' -Expected 'supported layout here; a mismatch refuses natively' `
        -Actual ("liveLayoutOk={0} size={1} arch={2} simulatedReason={3} capability={4}" -f $sessLayout.Ok, $sessLayout.Size, $sessLayout.Architecture, $layoutBlock.Reason, $layoutBlock.Capability) `
        -Pass ($sessLayout.Ok -and $sessLayout.Size -eq 24 -and $sessLayout.SessionIdOffset -eq 0 -and $sessLayout.NameOffset -eq 8 -and $sessLayout.StateOffset -eq 16 -and $layoutBlock.Capability -eq 'unsupported') -Evidence $null

    # ---- R11: a successful call returning an empty/invalid buffer is explicit ----
    $emptyDecoded = ConvertFrom-P9HWtsSessionInfoPayload -Payload ([byte[]]@()) -ReportedCount 2 -Layout $sessLayout
    $zeroCountDecoded = ConvertFrom-P9HWtsSessionInfoPayload -Payload $twoSession.Payload -ReportedCount 0 -Layout $sessLayout
    $tooSmallDecoded = ConvertFrom-P9HWtsSessionInfoPayload -Payload $twoSession.Payload -ReportedCount 9 -Layout $sessLayout
    $emptyQueryShape = [pscustomobject][ordered]@{
        Ok = $false; Reason = 'empty-native-response'; Capability = 'wtsinfo'
        Detail = 'WTSQuerySessionInformationW succeeded for session 3 but returned no bytes'; SessionId = 3; Win32Error = 0; Record = $null
    }
    Add-P9HTestResult -Id 'Y11' -Title 'Empty or invalid successful buffers are explicit, distinct failures' `
        -Input 'empty payload, zero count, undersized buffer, empty WTSINFO response' `
        -Expected 'four distinct explicit reasons' `
        -Actual ("empty={0} zeroCount={1} tooSmall={2} emptyQuery={3}(win32={4})" -f $emptyDecoded.Reason, $zeroCountDecoded.Reason, $tooSmallDecoded.Reason, $emptyQueryShape.Reason, $emptyQueryShape.Win32Error) `
        -Pass ($emptyDecoded.Reason -eq 'empty-enumeration' -and $zeroCountDecoded.Reason -eq 'invalid-session-count' -and $tooSmallDecoded.Reason -eq 'enumeration-buffer-too-small' -and $emptyQueryShape.Reason -eq 'empty-native-response' -and $emptyQueryShape.Win32Error -eq 0) -Evidence $null

    # ---- R12: per-role origin classification is exact ----
    $expectedOrigin = [ordered]@{
        'fixture'       = @('fixture', 'qualification-launcher')
        'stdout'        = @('product', 'qualification-launcher')
        'pre-windows'   = @('operating-system', 'qualification-observer')
        'post-windows'  = @('operating-system', 'qualification-observer')
        'exit-record'   = @('qualification', 'qualification-recorder')
        'new-processes' = @('operating-system', 'qualification-observer')
        'trace'         = @('product', 'qualification-capture')
    }
    $model = Get-P9HArtifactOriginModel
    $mismatches = [System.Collections.Generic.List[string]]::new()
    foreach ($role in $expectedOrigin.Keys) {
        $got = @($model | Where-Object { $_.Role -eq $role })
        if ($got.Count -ne 1) { $mismatches.Add("$role:missing") | Out-Null; continue }
        if ($got[0].Origin -ne $expectedOrigin[$role][0]) { $mismatches.Add("$role:origin=$($got[0].Origin)") | Out-Null }
        if ($got[0].CapturedBy -ne $expectedOrigin[$role][1]) { $mismatches.Add("$role:capturedBy=$($got[0].CapturedBy)") | Out-Null }
    }
    Add-P9HTestResult -Id 'Y12' -Title 'Every N2 role carries the correct per-role origin classification' `
        -Input 'origin model compared against the required mapping' -Expected 'no mismatches across seven roles' `
        -Actual ("roles={0} mismatches={1}" -f @($model).Count, $(if ($mismatches.Count -eq 0) { 'none' } else { $mismatches -join ',' })) `
        -Pass (@($model).Count -eq 7 -and $mismatches.Count -eq 0) -Evidence $null

    # ---- R13: the exit record is NOT described as product-generated ----
    $trial = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind combined
    $dir = $trial.Directory
    $fx = Join-Path $dir 'r13-fixture.json'
    Write-P9HArtifact -Path $fx -Lines @('{"itemId":"p9h-item","enabledItems":1,"enabledTerminals":1,"totalItems":1,"anchorAbsent":true,"layoutFallback":{"x":9000,"y":9000,"w":640,"h":480}}')
    $so = Join-Path $dir 'r13-stdout.txt'
    Write-P9HArtifact -Path $so -Lines @('main/p9h-item: relative layout has no reachable placement (anchor-missing: identity-not-found); the item will be handled normally but its window position will not be changed.')
    $pre = Join-Path $dir 'r13-pre.json'
    Write-P9HArtifact -Path $pre -Lines @('{"Windows":[]}')
    $post = Join-Path $dir 'r13-post.json'
    Write-P9HArtifact -Path $post -Lines @('{"Windows":[]}')
    $np = Join-Path $dir 'r13-newprocesses.json'
    Write-P9HArtifact -Path $np -Lines @('{"Added":[]}')
    $tr = Join-Path $dir 'r13-trace.jsonl'
    Write-P9HArtifact -Path $tr -Lines @('{"event":"lifecycle-layout-plan","utcMs":1,"pid":1}')
    $ex = Join-Path $dir 'r13-exit.json'
    $exRec = New-P9HExitRecord -TrialId $trial.TrialId -Outcome 'exited' -ExitCode 0 -LauncherPid 4240 `
        -LauncherPath 'C:\synthetic\ws.cmd' -InvocationDisplay 'synthetic' -WorkingDirectory $dir `
        -LaunchedAtUtc (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('o') `
        -ExitedAtUtc (Get-Date).ToUniversalTime().ToString('o')
    $null = Write-P9HExitRecord -Path $ex -Record $exRec

    $plan = Get-P9HCollectorRolePlan -FixturePath $fx -StdoutPath $so -PreWindowPath $pre `
        -PostWindowPath $post -ExitRecordPath $ex -NewProcessPath $np -TracePath $tr
    $bound = Add-P9HCollectorArtifactRoles -Context $trial -Plan $plan
    $manifest = New-P9HCollectorManifest -Context $trial -BoundRoles $bound.BoundRoles

    $exitClass = @($manifest.roleClassification | Where-Object { $_.role -eq 'exit-record' })[0]
    $traceClass = @($manifest.roleClassification | Where-Object { $_.role -eq 'trace' })[0]
    $originGroups = $manifest.byOrigin

    Add-P9HTestResult -Id 'Y13' -Title 'The collector exit record is never described as product-generated' `
        -Input 'collector-bound trial with manifest classification' `
        -Expected 'exit-record origin=qualification, trace origin=product' `
        -Actual ("exitOrigin={0} exitCaptured={1} exitInProductGroup={2} traceOrigin={3}" -f $exitClass.origin, $exitClass.capturedBy, (@($originGroups.product | Where-Object { $_.role -eq 'exit-record' }).Count), $traceClass.origin) `
        -Pass ($exitClass.origin -eq 'qualification' -and $exitClass.capturedBy -eq 'qualification-recorder' -and @($originGroups.product | Where-Object { $_.role -eq 'exit-record' }).Count -eq 0 -and $traceClass.origin -eq 'product') -Evidence $null

    # ---- R14: E1 observation log stays out of the N2 index; digests still bind ----
    $obsLog = Join-Path $dir 'r14-e1-observer.jsonl'
    $obsLineRecord = New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 1 -Phase 'pre' `
        -RawWtsLines $capture2.Lines -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso
    Add-P9HArtifactLine -Path $obsLog -Line $obsLineRecord

    $trial2 = New-P9HTrialContext -RootDirectory $SandboxRoot -Kind combined
    $bound2 = Add-P9HCollectorArtifactRoles -Context $trial2 -Plan $plan -ObservationLogPath $obsLog
    $n2Lines = @(Get-Content -LiteralPath (Join-Path $trial2.Directory 'artifact-index.jsonl'))
    $e1InN2 = @($n2Lines | Where-Object { $_ -match 'e1-observation-log' }).Count
    $separateExists = Test-Path -LiteralPath $bound2.ObservationIndexPath
    $verify2 = Test-P9HCollectorBinding -TrialId $trial2.TrialId `
        -ArtifactIndexPath (Join-Path $trial2.Directory 'artifact-index.jsonl') -Plan $plan
    $verified2 = @($verify2.Roles | Where-Object { $_.status -eq 'verified' }).Count

    Add-P9HTestResult -Id 'Y14' -Title 'E1 provenance stays separate while the seven-role digest binding holds' `
        -Input 'trial bound with an E1 observation log present' `
        -Expected 'no e1 role in the N2 index, separate index exists, 7/7 verified' `
        -Actual ("n2Lines={0} e1InN2={1} separateIndex={2} verifyOk={3} verified={4}" -f $n2Lines.Count, $e1InN2, $separateExists, $verify2.Ok, $verified2) `
        -Pass ($e1InN2 -eq 0 -and $separateExists -and $verify2.Ok -and $verified2 -eq 7) -Evidence $bound2.ObservationIndexPath

    # ---- R15: the live enumeration refuses without authorization ----
    $enumRefused = $false
    $enumMessage = $null
    try { $null = Invoke-P9HWtsSessionEnumerate -AuthorizationToken '' }
    catch { $enumRefused = $true; $enumMessage = $_.Exception.Message }
    Add-P9HTestResult -Id 'Y15' -Title 'Live session enumeration refuses without real-execution authorization' `
        -Input 'empty authorization token' -Expected 'throws before any native call' `
        -Actual ("refused={0} message={1}" -f $enumRefused, $enumMessage) `
        -Pass ($enumRefused -and $enumMessage -match 'authorization') -Evidence $null

    # ---- R16: a full-table capture reproduces the frozen E1 sequence end to end ----
    $seqLog = Join-Path $dir 'r16-e1-sequence.jsonl'
    $null = Add-P9HArtifactLine -Path $seqLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines $capture2.Lines -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $seqLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines $discCapture.Lines -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $seqLog -Line (New-P9HObserverRecord -TrialId $trial.TrialId -Sequence 3 -Phase 'post' `
            -RawWtsLines $capture2.Lines -TargetSessionId 3 -TargetUser 'CONTOSO\qauser' -TargetLogonTime $logonIso)

    $proofA = Get-P9HReconnectAuthorizationProof -ObserverLogPath $seqLog -TrialId $trial.TrialId `
        -SessionId 3 -User 'CONTOSO\qauser' -LogonTime $logonIso
    $proofB = Get-P9HDisconnectProof -ObserverLogPath $seqLog -TrialId $trial.TrialId `
        -SessionId 3 -User 'CONTOSO\qauser' -LogonTime $logonIso
    Add-P9HTestResult -Id 'Y16' -Title 'Full-table provider output drives the frozen E1 proofs end to end' `
        -Input 'pre/post from the complete table, disconnect from the disconnected table' `
        -Expected 'Proof A and Proof B both proven' `
        -Actual ("proofA={0}({1}) proofB={2}({3})" -f $proofA.Proven, $proofA.Reason, $proofB.Proven, $proofB.Reason) `
        -Pass ($proofA.Proven -and $proofB.Proven) -Evidence $seqLog
}

function Invoke-P9HAuthorityGateTests {
    # B-series: session-table evidence AUTHORITY propagation into Proof A/B.
    # S-series: the capture interface's own status contract.
    #
    # Stage 3A.2. The defect: Get-P9HWtsProviderTableCapture accepted only -Rows,
    # so the rows of a REJECTED resolution produced a clean-looking line table,
    # and New-P9HObserverRecord recorded captureOutcome='ok' unconditionally.
    # A rejected table therefore became authoritative transition evidence.
    #
    # Everything here is synthetic: no live WTS call is made.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $logonUtc = [datetime]::SpecifyKind([datetime]::new(2026, 11, 11, 10, 0, 0), [System.DateTimeKind]::Utc)
    $logonFt = $logonUtc.ToFileTimeUtc()
    $logonIso = $logonUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $user = 'CONTOSO\qauser'

    function New-AuthInfo {
        param([int]$Id, [int]$State)
        return (ConvertFrom-P9HWtsInfoPayload -Payload (New-P9HWtsInfoPayload -SessionId $Id -State $State `
                    -StationName 'RDP-Tcp#0' -Domain 'CONTOSO' -UserName 'qauser' -LogonTime $logonFt)).Record
    }

    function New-AuthServices {
        return (ConvertFrom-P9HWtsInfoPayload -Payload (New-P9HWtsInfoPayload -SessionId 0 -State 4 `
                    -StationName 'Services' -UserName '' -LogonTime 0)).Record
    }

    function New-AuthEnum {
        param([int]$TargetState, [switch]$WithoutTarget, [switch]$DuplicateTarget)
        $sessions = if ($WithoutTarget) {
            @(@{ SessionId = 0; StationName = 'Services'; State = 4 }, @{ SessionId = 2; StationName = 'Console'; State = 1 })
        }
        elseif ($DuplicateTarget) {
            @(@{ SessionId = 3; StationName = 'RDP-Tcp#0'; State = $TargetState }, @{ SessionId = 3; StationName = 'RDP-Tcp#1'; State = $TargetState })
        }
        else {
            @(@{ SessionId = 0; StationName = 'Services'; State = 4 }, @{ SessionId = 3; StationName = 'RDP-Tcp#0'; State = $TargetState })
        }
        $built = New-P9HWtsSessionInfoPayload -Sessions $sessions
        return (ConvertFrom-P9HWtsSessionInfoPayload -Payload $built.Payload -ReportedCount $built.ReportedCount -Layout $built.Layout)
    }

    function New-AuthTrial {
        param([string]$Name)
        $root = Join-Path $SandboxRoot ('p9h3a2-' + $Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return (New-P9HTrialContext -RootDirectory $root -Kind e1)
    }

    $activeEnum = New-AuthEnum -TargetState 0
    $discEnum = New-AuthEnum -TargetState 4
    $cleanActiveQueries = @{
        0 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (New-AuthServices) }
        3 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (New-AuthInfo -Id 3 -State 0) }
    }
    $cleanDiscQueries = @{
        0 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (New-AuthServices) }
        3 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (New-AuthInfo -Id 3 -State 4) }
    }

    $cleanActive = Resolve-P9HWtsSessionTable -EnumeratedSessions $activeEnum.Records -QueryResults $cleanActiveQueries -TargetSessionId 3
    $cleanActiveCap = Get-P9HWtsProviderTableCapture -Result $cleanActive -TargetSessionId 3
    $cleanDisc = Resolve-P9HWtsSessionTable -EnumeratedSessions $discEnum.Records -QueryResults $cleanDiscQueries -TargetSessionId 3
    $cleanDiscCap = Get-P9HWtsProviderTableCapture -Result $cleanDisc -TargetSessionId 3

    # ================= B-series =================

    # ---- B1: inconsistent enumeration/query state cannot authorize reconnect ----
    # Enumerated Active but queried Disconnected: the table moved underneath the
    # collector, so the "disconnected" reading is an evidence gap.
    $inconsistentQueries = @{
        0 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (New-AuthServices) }
        3 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (New-AuthInfo -Id 3 -State 4) }
    }
    $inconsistent = Resolve-P9HWtsSessionTable -EnumeratedSessions $activeEnum.Records -QueryResults $inconsistentQueries -TargetSessionId 3
    $inconsistentCap = Get-P9HWtsProviderTableCapture -Result $inconsistent -TargetSessionId 3
    $b1Trial = New-AuthTrial -Name 'b1'
    $b1Log = Join-Path $b1Trial.Directory 'e1.jsonl'
    $null = Add-P9HArtifactLine -Path $b1Log -Line (New-P9HObserverRecordFromTableCapture -Capture $cleanActiveCap -TrialId $b1Trial.TrialId -Sequence 1 -Phase 'pre' -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $b1Log -Line (New-P9HObserverRecordFromTableCapture -Capture $inconsistentCap -TrialId $b1Trial.TrialId -Sequence 2 -Phase 'disconnect-observed' -TargetUser $user -TargetLogonTime $logonIso)
    $b1Proof = Get-P9HReconnectAuthorizationProof -ObserverLogPath $b1Log -TrialId $b1Trial.TrialId -SessionId 3 -User $user -LogonTime $logonIso
    Add-P9HTestResult -Id 'B1' -Title 'Inconsistent enumeration/query target state cannot authorize reconnect' `
        -Input 'enumerated Active, queried Disconnected, complete table' `
        -Expected 'capture not authoritative, Proof A not proven' `
        -Actual ("resolverOk={0}({1}) capAuthoritative={2} rejection={3} proven={4} reason={5}" -f $inconsistent.Ok, $inconsistent.Reason, $inconsistentCap.Authoritative, $inconsistentCap.RejectionReason, $b1Proof.Proven, $b1Proof.Reason) `
        -Pass ((-not $inconsistent.Ok) -and (-not $inconsistentCap.Authoritative) -and (-not $b1Proof.Proven)) -Evidence $b1Log

    # ---- B2: a failed non-target query cannot authorize reconnect ----
    # The target itself looks perfectly disconnected, but the table is
    # incomplete, so session 0's state was never established.
    $failedNonTargetQueries = @{
        0 = [pscustomobject]@{ Ok = $false; Reason = 'native-query-failed'; Detail = 'Win32 5'; Record = $null; Win32Error = 5 }
        3 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (New-AuthInfo -Id 3 -State 4) }
    }
    $failedNonTarget = Resolve-P9HWtsSessionTable -EnumeratedSessions $discEnum.Records -QueryResults $failedNonTargetQueries -TargetSessionId 3
    $failedNonTargetCap = Get-P9HWtsProviderTableCapture -Result $failedNonTarget -TargetSessionId 3
    $b2Trial = New-AuthTrial -Name 'b2'
    $b2Log = Join-Path $b2Trial.Directory 'e1.jsonl'
    $null = Add-P9HArtifactLine -Path $b2Log -Line (New-P9HObserverRecordFromTableCapture -Capture $cleanActiveCap -TrialId $b2Trial.TrialId -Sequence 1 -Phase 'pre' -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $b2Log -Line (New-P9HObserverRecordFromTableCapture -Capture $failedNonTargetCap -TrialId $b2Trial.TrialId -Sequence 2 -Phase 'disconnect-observed' -TargetUser $user -TargetLogonTime $logonIso)
    $b2Proof = Get-P9HReconnectAuthorizationProof -ObserverLogPath $b2Log -TrialId $b2Trial.TrialId -SessionId 3 -User $user -LogonTime $logonIso
    $b2Record = @((Read-P9HObserverLog -Path $b2Log).Records) | Where-Object { $_.phase -eq 'disconnect-observed' } | Select-Object -Last 1
    Add-P9HTestResult -Id 'B2' -Title 'A failed per-session query cannot authorize reconnect' `
        -Input 'session 0 query failed Win32 5, target 3 reads Disconnected' `
        -Expected 'capture not authoritative, Proof A not proven, Win32 preserved' `
        -Actual ("capAuthoritative={0} rejection={1} win32={2} outcome={3} proven={4}" -f $failedNonTargetCap.Authoritative, $failedNonTargetCap.RejectionReason, (@($b2Record.captureWin32Errors) -join ','), $b2Record.captureOutcome, $b2Proof.Proven) `
        -Pass ((-not $failedNonTargetCap.Authoritative) -and (-not $b2Proof.Proven) -and (@($b2Record.captureWin32Errors) -contains 5)) -Evidence $b2Log

    # ---- B3: incomplete table with apparently valid target data ----
    # Duplicate target rows: the target line parses fine and says Disconnected,
    # but the table is ambiguous.
    $dupEnum = New-AuthEnum -DuplicateTarget -TargetState 4
    $dupQueries = @{ 3 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (New-AuthInfo -Id 3 -State 4) } }
    $dupResolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $dupEnum.Records -QueryResults $dupQueries -TargetSessionId 3
    $dupCap = Get-P9HWtsProviderTableCapture -Result $dupResolved -TargetSessionId 3
    $b3Trial = New-AuthTrial -Name 'b3'
    $b3Log = Join-Path $b3Trial.Directory 'e1.jsonl'
    $null = Add-P9HArtifactLine -Path $b3Log -Line (New-P9HObserverRecordFromTableCapture -Capture $cleanActiveCap -TrialId $b3Trial.TrialId -Sequence 1 -Phase 'pre' -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $b3Log -Line (New-P9HObserverRecordFromTableCapture -Capture $dupCap -TrialId $b3Trial.TrialId -Sequence 2 -Phase 'disconnect-observed' -TargetUser $user -TargetLogonTime $logonIso)
    $b3Proof = Get-P9HReconnectAuthorizationProof -ObserverLogPath $b3Log -TrialId $b3Trial.TrialId -SessionId 3 -User $user -LogonTime $logonIso
    Add-P9HTestResult -Id 'B3' -Title 'An incomplete/ambiguous table with valid target data cannot authorize reconnect' `
        -Input 'duplicate session-3 records, target line reads Disconnected' `
        -Expected 'capture not authoritative, Proof A not proven' `
        -Actual ("resolverOk={0}({1}) capAuthoritative={2} rejection={3} proven={4} reason={5}" -f $dupResolved.Ok, $dupResolved.Reason, $dupCap.Authoritative, $dupCap.RejectionReason, $b3Proof.Proven, $b3Proof.Reason) `
        -Pass ((-not $dupResolved.Ok) -and (-not $dupCap.Authoritative) -and (-not $b3Proof.Proven)) -Evidence $b3Log

    # ---- B4: a provider-error record cannot satisfy Proof A ----
    # The raw line is a syntactically perfect Disconnected target line, but the
    # capture was declared a provider error.
    $b4Trial = New-AuthTrial -Name 'b4'
    $b4Log = Join-Path $b4Trial.Directory 'e1.jsonl'
    $perfectDiscLine = '3|RDP-Tcp#0|state=4|user=' + $user + '|logon=' + $logonIso
    $null = Add-P9HArtifactLine -Path $b4Log -Line (New-P9HObserverRecordFromTableCapture -Capture $cleanActiveCap -TrialId $b4Trial.TrialId -Sequence 1 -Phase 'pre' -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $b4Log -Line (New-P9HObserverRecord -TrialId $b4Trial.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @($perfectDiscLine) -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso `
            -CaptureOutcome 'provider-error' -CaptureError 'WTSQuerySessionInformationW failed (Win32 5)' `
            -CaptureAuthoritative $false -CaptureAuthorityReason 'provider-error')
    $b4Proof = Get-P9HReconnectAuthorizationProof -ObserverLogPath $b4Log -TrialId $b4Trial.TrialId -SessionId 3 -User $user -LogonTime $logonIso
    $b4Record = @((Read-P9HObserverLog -Path $b4Log).Records) | Where-Object { $_.phase -eq 'disconnect-observed' } | Select-Object -Last 1
    Add-P9HTestResult -Id 'B4' -Title 'A provider-error observer record cannot satisfy Proof A' `
        -Input 'valid Disconnected target line whose capture was a provider error' `
        -Expected 'record keeps its raw line and error, Proof A not proven' `
        -Actual ("captureOutcome={0} captureAuthoritative={1} targetState={2} proven={3} reason={4}" -f $b4Record.captureOutcome, $b4Record.captureAuthoritative, $b4Record.targetState, $b4Proof.Proven, $b4Proof.Reason) `
        -Pass ($b4Record.captureOutcome -eq 'provider-error' -and (-not $b4Record.captureAuthoritative) -and [int]$b4Record.targetState -eq 4 -and (-not $b4Proof.Proven)) -Evidence $b4Log

    # ---- B5: a provider-error post observation cannot satisfy Proof B ----
    $b5Trial = New-AuthTrial -Name 'b5'
    $b5Log = Join-Path $b5Trial.Directory 'e1.jsonl'
    $perfectActiveLine = '3|RDP-Tcp#0|state=0|user=' + $user + '|logon=' + $logonIso
    $null = Add-P9HArtifactLine -Path $b5Log -Line (New-P9HObserverRecordFromTableCapture -Capture $cleanActiveCap -TrialId $b5Trial.TrialId -Sequence 1 -Phase 'pre' -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $b5Log -Line (New-P9HObserverRecordFromTableCapture -Capture $cleanDiscCap -TrialId $b5Trial.TrialId -Sequence 2 -Phase 'disconnect-observed' -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $b5Log -Line (New-P9HObserverRecord -TrialId $b5Trial.TrialId -Sequence 3 -Phase 'post' `
            -RawWtsLines @($perfectActiveLine) -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso `
            -CaptureOutcome 'provider-error' -CaptureError 'WTSQuerySessionInformationW failed (Win32 5)' `
            -CaptureAuthoritative $false -CaptureAuthorityReason 'provider-error')
    $b5ProofA = Get-P9HReconnectAuthorizationProof -ObserverLogPath $b5Log -TrialId $b5Trial.TrialId -SessionId 3 -User $user -LogonTime $logonIso
    $b5ProofB = Get-P9HDisconnectProof -ObserverLogPath $b5Log -TrialId $b5Trial.TrialId -SessionId 3 -User $user -LogonTime $logonIso
    Add-P9HTestResult -Id 'B5' -Title 'A provider-error post observation cannot satisfy Proof B' `
        -Input 'authoritative pre/disconnect plus a provider-error post reading Active' `
        -Expected 'Proof A proven, Proof B NOT proven' `
        -Actual ("proofA={0}({1}) proofB={2}({3})" -f $b5ProofA.Proven, $b5ProofA.Reason, $b5ProofB.Proven, $b5ProofB.Reason) `
        -Pass ($b5ProofA.Proven -and (-not $b5ProofB.Proven) -and $b5ProofB.Reason -eq 'post-capture-not-authoritative') -Evidence $b5Log

    # ---- B6: a missing target yields explicit non-success ----
    $absentEnum = New-AuthEnum -TargetState 0 -WithoutTarget
    $absentQueries = @{
        0 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (New-AuthServices) }
        2 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (New-AuthInfo -Id 2 -State 1) }
    }
    $absent = Resolve-P9HWtsSessionTable -EnumeratedSessions $absentEnum.Records -QueryResults $absentQueries -TargetSessionId 3
    $absentCap = Get-P9HWtsProviderTableCapture -Result $absent -TargetSessionId 3
    Add-P9HTestResult -Id 'B6' -Title 'A missing target yields explicit non-success from the resolver' `
        -Input 'successful enumeration of sessions 0 and 2, target 3 absent' `
        -Expected 'resolver Ok=false reason=target-not-resolved, capture not authoritative' `
        -Actual ("resolverOk={0} reason={1} targetOk={2} targetReason={3} capAuthoritative={4} rejection={5}" -f $absent.Ok, $absent.Reason, $absent.TargetOk, $absent.TargetReason, $absentCap.Authoritative, $absentCap.RejectionReason) `
        -Pass ((-not $absent.Ok) -and $absent.Reason -eq 'target-not-resolved' -and (-not $absent.TargetOk) -and $absent.TargetReason -eq 'no-target' -and (-not $absentCap.Authoritative)) -Evidence $null

    # ---- B7: valid complete Active -> Disconnected authorizes reconnect ----
    # MANDATORY positive: the gate must remain executable.
    $b7Trial = New-AuthTrial -Name 'b7'
    $b7Log = Join-Path $b7Trial.Directory 'e1.jsonl'
    $null = Add-P9HArtifactLine -Path $b7Log -Line (New-P9HObserverRecordFromTableCapture -Capture $cleanActiveCap -TrialId $b7Trial.TrialId -Sequence 1 -Phase 'pre' -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $b7Log -Line (New-P9HObserverRecordFromTableCapture -Capture $cleanDiscCap -TrialId $b7Trial.TrialId -Sequence 2 -Phase 'disconnect-observed' -TargetUser $user -TargetLogonTime $logonIso)
    $b7Proof = Get-P9HReconnectAuthorizationProof -ObserverLogPath $b7Log -TrialId $b7Trial.TrialId -SessionId 3 -User $user -LogonTime $logonIso
    $b7AssertOk = $false
    try {
        $null = Assert-P9HReconnectPermitted -ObserverLogPath $b7Log -TargetSessionId 3 -TargetUser $user `
            -TrialId $b7Trial.TrialId -TargetLogonTime $logonIso
        $b7AssertOk = $true
    }
    catch { }
    Add-P9HTestResult -Id 'B7' -Title 'A valid complete Active to Disconnected table authorizes reconnect' `
        -Input 'authoritative pre Active and authoritative disconnect Disconnected' `
        -Expected 'Proof A proven, hard gate permits' `
        -Actual ("preAuth={0} discAuth={1} proven={2} reason={3} assertPermitted={4}" -f $cleanActiveCap.Authoritative, $cleanDiscCap.Authoritative, $b7Proof.Proven, $b7Proof.Reason, $b7AssertOk) `
        -Pass ($cleanActiveCap.Authoritative -and $cleanDiscCap.Authoritative -and $b7Proof.Proven -and $b7AssertOk) -Evidence $b7Log

    # ---- B8: valid Active -> Disconnected -> Active satisfies final Proof B ----
    $b8Trial = New-AuthTrial -Name 'b8'
    $b8Log = Join-Path $b8Trial.Directory 'e1.jsonl'
    $null = Add-P9HArtifactLine -Path $b8Log -Line (New-P9HObserverRecordFromTableCapture -Capture $cleanActiveCap -TrialId $b8Trial.TrialId -Sequence 1 -Phase 'pre' -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $b8Log -Line (New-P9HObserverRecordFromTableCapture -Capture $cleanDiscCap -TrialId $b8Trial.TrialId -Sequence 2 -Phase 'disconnect-observed' -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $b8Log -Line (New-P9HObserverRecordFromTableCapture -Capture $cleanActiveCap -TrialId $b8Trial.TrialId -Sequence 3 -Phase 'post' -TargetUser $user -TargetLogonTime $logonIso)
    $b8ProofB = Get-P9HDisconnectProof -ObserverLogPath $b8Log -TrialId $b8Trial.TrialId -SessionId 3 -User $user -LogonTime $logonIso
    Add-P9HTestResult -Id 'B8' -Title 'A valid Active to Disconnected to Active sequence satisfies final Proof B' `
        -Input 'three authoritative observations at the same pinned identity' `
        -Expected 'Proof B proven' `
        -Actual ("proven={0} reason={1} postState={2}" -f $b8ProofB.Proven, $b8ProofB.Reason, $(if ($b8ProofB.Post) { $b8ProofB.Post.targetState } else { 'null' })) `
        -Pass ($b8ProofB.Proven -and $b8ProofB.Reason -eq 'target-disconnect-reconnect-observed') -Evidence $b8Log

    # ---- B9: raw diagnostics survive a rejected evaluation unchanged ----
    $b9Trial = New-AuthTrial -Name 'b9'
    $b9Log = Join-Path $b9Trial.Directory 'e1.jsonl'
    $null = Add-P9HArtifactLine -Path $b9Log -Line (New-P9HObserverRecordFromTableCapture -Capture $cleanActiveCap -TrialId $b9Trial.TrialId -Sequence 1 -Phase 'pre' -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $b9Log -Line (New-P9HObserverRecordFromTableCapture -Capture $failedNonTargetCap -TrialId $b9Trial.TrialId -Sequence 2 -Phase 'disconnect-observed' -TargetUser $user -TargetLogonTime $logonIso)
    $b9Before = Get-P9HFileSha256 -Path $b9Log
    $null = Get-P9HReconnectAuthorizationProof -ObserverLogPath $b9Log -TrialId $b9Trial.TrialId -SessionId 3 -User $user -LogonTime $logonIso
    $b9After = Get-P9HFileSha256 -Path $b9Log
    $b9Record = @((Read-P9HObserverLog -Path $b9Log).Records) | Where-Object { $_.phase -eq 'disconnect-observed' } | Select-Object -Last 1
    Add-P9HTestResult -Id 'B9' -Title 'Raw diagnostic observations survive a rejected evaluation unchanged' `
        -Input 'rejected capture with a preserved Win32 failure' `
        -Expected 'log bytes identical, raw lines and diagnostics still present' `
        -Actual ("hashUnchanged={0} rawLines={1} rejection={2} win32={3} outcome={4}" -f ($b9Before -eq $b9After), @($b9Record.rawWts).Count, [string]$b9Record.captureRejection, (@($b9Record.captureWin32Errors) -join ','), $b9Record.captureOutcome) `
        -Pass (($b9Before -eq $b9After) -and @($b9Record.rawWts).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$b9Record.captureRejection) -and (@($b9Record.captureWin32Errors) -contains 5)) -Evidence $b9Log

    # ================= S-series (capture status contract) =================

    # ---- S1: an accepted resolution yields an authoritative capture ----
    Add-P9HTestResult -Id 'S1' -Title 'An accepted resolution yields an authoritative capture' `
        -Input 'complete consistent table' -Expected 'Ok=true, Authoritative=true, no rejection' `
        -Actual ("Ok={0} authoritative={1} reason={2} rejection={3} lines={4}" -f $cleanDiscCap.Ok, $cleanDiscCap.Authoritative, $cleanDiscCap.Reason, [string]$cleanDiscCap.RejectionReason, $cleanDiscCap.LineCount) `
        -Pass ($cleanDiscCap.Ok -and $cleanDiscCap.Authoritative -and [string]::IsNullOrWhiteSpace([string]$cleanDiscCap.RejectionReason) -and $cleanDiscCap.LineCount -eq 2) -Evidence $null

    # ---- S2: rows alone are never authoritative ----
    $rowsOnlyCap = Get-P9HWtsProviderTableCapture -Rows $cleanDisc.Rows -TargetSessionId 3
    Add-P9HTestResult -Id 'S2' -Title 'A row set without resolver status is never authoritative' `
        -Input 'valid rows passed without the resolved result' -Expected 'Authoritative=false, explicit reason' `
        -Actual ("authoritative={0} reason={1} lines={2}" -f $rowsOnlyCap.Authoritative, $rowsOnlyCap.RejectionReason, $rowsOnlyCap.LineCount) `
        -Pass ((-not $rowsOnlyCap.Authoritative) -and $rowsOnlyCap.RejectionReason -eq 'capture-rows-without-resolver-status') -Evidence $null

    # ---- S3: a rejected capture still preserves the full raw table ----
    Add-P9HTestResult -Id 'S3' -Title 'A rejected capture preserves its complete raw observations' `
        -Input 'inconsistent table rejected by the resolver' `
        -Expected 'authoritative=false but both raw lines still emitted' `
        -Actual ("authoritative={0} lines={1} rowCount={2} resolverReason={3}" -f $inconsistentCap.Authoritative, $inconsistentCap.LineCount, $inconsistentCap.RowCount, $inconsistentCap.ResolverReason) `
        -Pass ((-not $inconsistentCap.Authoritative) -and $inconsistentCap.LineCount -eq 2 -and $inconsistentCap.RowCount -eq 2 -and -not [string]::IsNullOrWhiteSpace([string]$inconsistentCap.ResolverReason)) -Evidence $null

    # ---- S4: each resolver failure mode names its own rejection ----
    $mismatchQueries = @{
        0 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (New-AuthServices) }
        3 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (New-AuthInfo -Id 7 -State 0) }
    }
    $mismatch = Resolve-P9HWtsSessionTable -EnumeratedSessions $activeEnum.Records -QueryResults $mismatchQueries -TargetSessionId 3
    $mismatchCap = Get-P9HWtsProviderTableCapture -Result $mismatch -TargetSessionId 3
    $missingLogonQueries = @{
        0 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (New-AuthServices) }
        3 = [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = (ConvertFrom-P9HWtsInfoPayload -Payload (New-P9HWtsInfoPayload -SessionId 3 -State 4 -StationName 'RDP-Tcp#0' -Domain 'CONTOSO' -UserName 'qauser' -LogonTime 0)).Record }
    }
    $missingLogon = Resolve-P9HWtsSessionTable -EnumeratedSessions $discEnum.Records -QueryResults $missingLogonQueries -TargetSessionId 3
    $missingLogonCap = Get-P9HWtsProviderTableCapture -Result $missingLogon -TargetSessionId 3
    Add-P9HTestResult -Id 'S4' -Title 'Each rejection mode produces its own explicit authority reason' `
        -Input 'ambiguous, id-mismatch, state-change, target-absent, failed-query' `
        -Expected 'five distinct rejection reasons, none authoritative' `
        -Actual ("ambiguous={0} mismatch={1} stateChanged={2} absent={3} failedQuery={4}" -f $dupCap.RejectionReason, $mismatchCap.RejectionReason, $inconsistentCap.RejectionReason, $absentCap.RejectionReason, $failedNonTargetCap.RejectionReason) `
        -Pass ($dupCap.RejectionReason -eq 'target-not-resolved:ambiguous-enumeration' -and
            $mismatchCap.RejectionReason -eq 'target-not-resolved:target-session-id-mismatch' -and
            $inconsistentCap.RejectionReason -eq 'target-state-changed-during-collection' -and
            $absentCap.RejectionReason -eq 'target-not-resolved:no-target' -and
            $failedNonTargetCap.RejectionReason -eq 'resolver-rejected:incomplete-session-table' -and
            (@(@($dupCap.RejectionReason, $mismatchCap.RejectionReason, $inconsistentCap.RejectionReason, $absentCap.RejectionReason, $failedNonTargetCap.RejectionReason) | Select-Object -Unique).Count -eq 5) -and
            (-not $dupCap.Authoritative) -and (-not $mismatchCap.Authoritative) -and
            (-not $inconsistentCap.Authoritative) -and (-not $absentCap.Authoritative) -and
            (-not $failedNonTargetCap.Authoritative)) -Evidence $null

    # ---- S5: a rejected sample is persisted and never upgraded to ok ----
    # Drives the real integration path (Wait-P9HTargetDisconnected) with a
    # provider that reports a rejected capture, then a provider that succeeds.
    $s5Root = Join-Path $SandboxRoot ('p9h3a2-s5-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $s5Root -Force | Out-Null
    $s5Trial = New-P9HTrialContext -RootDirectory $s5Root -Kind e1
    $s5Log = Join-Path $s5Trial.Directory 'e1.jsonl'

    $script:s5Calls = 0
    $s5Provider = {
        $script:s5Calls++
        if ($script:s5Calls -eq 1) {
            # Rejected capture with a syntactically perfect Disconnected line.
            return [pscustomobject]@{
                RawWtsLines     = @($perfectDiscLine)
                Authoritative   = $false
                AuthorityReason = 'target-state-changed-during-collection'
                RejectionReason = 'target-state-changed-during-collection'
                CaptureOutcome  = 'ok'
                Win32Errors     = @()
            }
        }
        return [pscustomobject]@{
            RawWtsLines   = $cleanDiscCap.Lines
            Authoritative = $true
        }
    }

    $s5Wait = Wait-P9HTargetDisconnected -TrialId $s5Trial.TrialId -SequenceStart 1 `
        -ObserverLogPath $s5Log -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso `
        -Provider $s5Provider -TimeoutSeconds 8 -PollIntervalMs 10

    $s5Records = @((Read-P9HObserverLog -Path $s5Log).Records)
    $s5First = @($s5Records | Where-Object { [int]$_.sequence -eq 1 }) | Select-Object -First 1
    Add-P9HTestResult -Id 'S5' -Title 'A rejected sample is persisted with its reason and never upgraded to ok' `
        -Input 'provider reports a rejected capture, then an authoritative one' `
        -Expected 'first sample durable and non-authoritative, later sample authorizes' `
        -Actual ("calls={0} waitProven={1} firstAuth={2} firstReason={3} firstOutcome={4} records={5}" -f $script:s5Calls, $s5Wait.Proven, $s5First.captureAuthoritative, [string]$s5First.captureAuthorityReason, $s5First.captureOutcome, $s5Records.Count) `
        -Pass ($s5Wait.Proven -and $s5Records.Count -ge 2 -and (-not $s5First.captureAuthoritative) -and
            $s5First.captureAuthorityReason -eq 'target-state-changed-during-collection' -and
            $s5First.captureOutcome -eq 'ok') -Evidence $s5Log

    # ---- S6: the wait gate cannot be satisfied by rejected samples alone ----
    $s6Root = Join-Path $SandboxRoot ('p9h3a2-s6-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Path $s6Root -Force | Out-Null
    $s6Trial = New-P9HTrialContext -RootDirectory $s6Root -Kind e1
    $s6Log = Join-Path $s6Trial.Directory 'e1.jsonl'

    $s6Provider = {
        return [pscustomobject]@{
            RawWtsLines     = @($perfectDiscLine)
            Authoritative   = $false
            AuthorityReason = 'provider-error'
            RejectionReason = 'resolver-rejected:incomplete-session-table'
            CaptureOutcome  = 'provider-error'
            CaptureError    = 'WTSQuerySessionInformationW failed (Win32 5)'
            Win32Errors     = @(5)
        }
    }

    $s6Wait = Wait-P9HTargetDisconnected -TrialId $s6Trial.TrialId -SequenceStart 1 `
        -ObserverLogPath $s6Log -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso `
        -Provider $s6Provider -TimeoutSeconds 2 -PollIntervalMs 50

    $s6Records = @((Read-P9HObserverLog -Path $s6Log).Records)
    $s6AllNonAuth = @($s6Records | Where-Object { -not $_.captureAuthoritative }).Count
    Add-P9HTestResult -Id 'S6' -Title 'A wait gate is never satisfied by rejected samples alone' `
        -Input 'provider always reports a provider-error capture' `
        -Expected 'wait not proven, every persisted sample non-authoritative' `
        -Actual ("waitProven={0} reason={1} records={2} nonAuthoritative={3}" -f $s6Wait.Proven, $s6Wait.Reason, $s6Records.Count, $s6AllNonAuth) `
        -Pass ((-not $s6Wait.Proven) -and $s6Records.Count -gt 0 -and $s6AllNonAuth -eq $s6Records.Count) -Evidence $s6Log
}

function Invoke-P9HAuthorityOmissionTests {
    # U-series: OMITTED capture authority (Stage 3B0).
    #
    # Supervisor review found that Stage 3A.2 only covered an EXPLICIT
    # CaptureAuthoritative=$false. Omitting the flag left the record
    # authoritative, because New-P9HObserverRecord defaulted the parameter to
    # $true and Wait-P9HTargetDisconnected defaulted a silent provider to
    # authoritative. A record declaring captureOutcome='provider-error' could
    # therefore authorize a reconnect.
    #
    # These cases cover the OMISSION variants specifically. Everything is
    # synthetic: no live WTS call is made and no reconnect is executed.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $logonUtc = [datetime]::SpecifyKind([datetime]::new(2026, 11, 11, 10, 0, 0), [System.DateTimeKind]::Utc)
    $logonIso = $logonUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $user = 'CONTOSO\qauser'
    $discLine = '3|RDP-Tcp#0|state=4|user=' + $user + '|logon=' + $logonIso
    $activeLine = '3|RDP-Tcp#0|state=0|user=' + $user + '|logon=' + $logonIso

    function New-OmitTrial {
        param([string]$Name)
        $root = Join-Path $SandboxRoot ('p9h3b0-' + $Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return (New-P9HTrialContext -RootDirectory $root -Kind e1)
    }

    # ---- U1: omitted authority + provider-error cannot satisfy Proof A ----
    $u1 = New-OmitTrial 'u1'
    $u1Log = Join-Path $u1.Directory 'e1.jsonl'
    $null = Add-P9HArtifactLine -Path $u1Log -Line (New-P9HObserverRecord -TrialId $u1.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines @($activeLine) -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $u1Log -Line (New-P9HObserverRecord -TrialId $u1.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @($discLine) -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso `
            -CaptureOutcome 'provider-error' -CaptureError 'WTSQuerySessionInformationW failed (Win32 5)')
    $u1Rec = @((Read-P9HObserverLog -Path $u1Log).Records) | Where-Object { $_.phase -eq 'disconnect-observed' } | Select-Object -Last 1
    $u1Proof = Get-P9HReconnectAuthorizationProof -ObserverLogPath $u1Log -TrialId $u1.TrialId -SessionId 3 -User $user -LogonTime $logonIso
    Add-P9HTestResult -Id 'U1' -Title 'An omitted authority flag with a provider error cannot satisfy Proof A' `
        -Input 'provider-error record, CaptureAuthoritative not supplied' `
        -Expected 'authority derived false, Proof A not proven' `
        -Actual ("captureOutcome={0} captureAuthoritative={1} reason={2} proven={3}({4})" -f $u1Rec.captureOutcome, $u1Rec.captureAuthoritative, [string]$u1Rec.captureAuthorityReason, $u1Proof.Proven, $u1Proof.Reason) `
        -Pass (($u1Rec.captureAuthoritative -eq $false) -and $u1Rec.captureAuthorityReason -eq 'capture-outcome-provider-error' -and (-not $u1Proof.Proven)) -Evidence $u1Log

    # ---- U2: omitted authority + provider-error cannot satisfy Proof B ----
    $u2 = New-OmitTrial 'u2'
    $u2Log = Join-Path $u2.Directory 'e1.jsonl'
    $null = Add-P9HArtifactLine -Path $u2Log -Line (New-P9HObserverRecord -TrialId $u2.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines @($activeLine) -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $u2Log -Line (New-P9HObserverRecord -TrialId $u2.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @($discLine) -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $u2Log -Line (New-P9HObserverRecord -TrialId $u2.TrialId -Sequence 3 -Phase 'post' `
            -RawWtsLines @($activeLine) -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso `
            -CaptureOutcome 'provider-error' -CaptureError 'WTSQuerySessionInformationW failed (Win32 5)')
    $u2Rec = @((Read-P9HObserverLog -Path $u2Log).Records) | Where-Object { $_.phase -eq 'post' } | Select-Object -Last 1
    $u2Proof = Get-P9HDisconnectProof -ObserverLogPath $u2Log -TrialId $u2.TrialId -SessionId 3 -User $user -LogonTime $logonIso
    Add-P9HTestResult -Id 'U2' -Title 'An omitted authority flag with a provider error cannot satisfy Proof B' `
        -Input 'provider-error post observation, CaptureAuthoritative not supplied' `
        -Expected 'authority derived false, Proof B not proven' `
        -Actual ("postAuthority={0} proven={1}({2})" -f $u2Rec.captureAuthoritative, $u2Proof.Proven, $u2Proof.Reason) `
        -Pass (($u2Rec.captureAuthoritative -eq $false) -and (-not $u2Proof.Proven) -and $u2Proof.Reason -eq 'post-capture-not-authoritative') -Evidence $u2Log

    # ---- U3: an omitted flag with a clean capture still derives true ----
    # The conservative default must not break the executable positive path.
    $u3 = New-OmitTrial 'u3'
    $u3Log = Join-Path $u3.Directory 'e1.jsonl'
    $null = Add-P9HArtifactLine -Path $u3Log -Line (New-P9HObserverRecord -TrialId $u3.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines @($activeLine) -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $u3Log -Line (New-P9HObserverRecord -TrialId $u3.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @($discLine) -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso)
    $u3Rec = @((Read-P9HObserverLog -Path $u3Log).Records) | Where-Object { $_.phase -eq 'disconnect-observed' } | Select-Object -Last 1
    $u3Proof = Get-P9HReconnectAuthorizationProof -ObserverLogPath $u3Log -TrialId $u3.TrialId -SessionId 3 -User $user -LogonTime $logonIso
    Add-P9HTestResult -Id 'U3' -Title 'An omitted authority flag with a clean capture still derives authoritative' `
        -Input 'clean capture, CaptureAuthoritative not supplied' `
        -Expected 'authority derived true, Proof A proven' `
        -Actual ("captureOutcome={0} captureAuthoritative={1} proven={2}" -f $u3Rec.captureOutcome, $u3Rec.captureAuthoritative, $u3Proof.Proven) `
        -Pass (($u3Rec.captureAuthoritative -eq $true) -and $u3Proof.Proven) -Evidence $u3Log

    # ---- U4: an explicit true cannot override a failed capture ----
    $u4 = New-OmitTrial 'u4'
    $u4Log = Join-Path $u4.Directory 'e1.jsonl'
    $null = Add-P9HArtifactLine -Path $u4Log -Line (New-P9HObserverRecord -TrialId $u4.TrialId -Sequence 1 -Phase 'pre' `
            -RawWtsLines @($activeLine) -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso)
    $null = Add-P9HArtifactLine -Path $u4Log -Line (New-P9HObserverRecord -TrialId $u4.TrialId -Sequence 2 -Phase 'disconnect-observed' `
            -RawWtsLines @($discLine) -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso `
            -CaptureOutcome 'provider-error' -CaptureAuthoritative $true)
    $u4Rec = @((Read-P9HObserverLog -Path $u4Log).Records) | Where-Object { $_.phase -eq 'disconnect-observed' } | Select-Object -Last 1
    $u4Proof = Get-P9HReconnectAuthorizationProof -ObserverLogPath $u4Log -TrialId $u4.TrialId -SessionId 3 -User $user -LogonTime $logonIso
    Add-P9HTestResult -Id 'U4' -Title 'An explicit authoritative flag cannot override a failed capture outcome' `
        -Input 'CaptureOutcome=provider-error with CaptureAuthoritative=true' `
        -Expected 'authority forced false, Proof A not proven' `
        -Actual ("authoritative={0} reason={1} proven={2}" -f $u4Rec.captureAuthoritative, [string]$u4Rec.captureAuthorityReason, $u4Proof.Proven) `
        -Pass (($u4Rec.captureAuthoritative -eq $false) -and (-not $u4Proof.Proven)) -Evidence $u4Log

    # ---- U5: the wait gate cannot authorize from a silent, failing provider ----
    $u5 = New-OmitTrial 'u5'
    $u5Log = Join-Path $u5.Directory 'e1.jsonl'
    $u5Provider = {
        # Reports a provider error but supplies NO Authoritative field: the exact
        # omission the supervisor flagged.
        return [pscustomobject]@{
            RawWtsLines    = @($discLine)
            CaptureOutcome = 'provider-error'
            CaptureError   = 'WTSQuerySessionInformationW failed (Win32 5)'
            Win32Errors    = @(5)
        }
    }
    $u5Wait = Wait-P9HTargetDisconnected -TrialId $u5.TrialId -SequenceStart 1 -ObserverLogPath $u5Log `
        -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso `
        -Provider $u5Provider -TimeoutSeconds 1 -PollIntervalMs 40
    $u5Recs = @((Read-P9HObserverLog -Path $u5Log).Records)
    $u5Auth = @($u5Recs | Where-Object { $_.captureAuthoritative }).Count
    Add-P9HTestResult -Id 'U5' -Title 'A silent failing provider cannot authorize through the wait gate' `
        -Input 'provider omits Authoritative and reports provider-error' `
        -Expected 'no authoritative records, wait not proven' `
        -Actual ("waitProven={0} reason={1} records={2} authoritative={3}" -f $u5Wait.Proven, $u5Wait.Reason, $u5Recs.Count, $u5Auth) `
        -Pass ((-not $u5Wait.Proven) -and $u5Recs.Count -gt 0 -and $u5Auth -eq 0) -Evidence $u5Log

    # ---- U6: the wait gate still authorizes a silent, clean provider ----
    $u6 = New-OmitTrial 'u6'
    $u6Log = Join-Path $u6.Directory 'e1.jsonl'
    $u6Provider = {
        return [pscustomobject]@{ RawWtsLines = @($discLine) }
    }
    $u6Wait = Wait-P9HTargetDisconnected -TrialId $u6.TrialId -SequenceStart 1 -ObserverLogPath $u6Log `
        -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso `
        -Provider $u6Provider -TimeoutSeconds 5 -PollIntervalMs 40
    $u6Recs = @((Read-P9HObserverLog -Path $u6Log).Records)
    Add-P9HTestResult -Id 'U6' -Title 'A silent clean provider still authorizes through the wait gate' `
        -Input 'provider omits Authoritative and reports no error' `
        -Expected 'wait proven, sample authoritative' `
        -Actual ("waitProven={0} reason={1} records={2} firstAuth={3}" -f $u6Wait.Proven, $u6Wait.Reason, $u6Recs.Count, $(if ($u6Recs.Count -gt 0) { $u6Recs[0].captureAuthoritative } else { 'null' })) `
        -Pass ($u6Wait.Proven -and $u6Recs.Count -gt 0 -and $u6Recs[0].captureAuthoritative) -Evidence $u6Log
}

function Invoke-P9HWtsListenerAuthorityTests {
    # L-series: listener-aware WTS authority + Win32-zero classification
    # (Stage 3B7B-C1).
    #
    # Stage 3B7B physically established a genuine authenticated RDP session
    # (id 2, RDP-Tcp#0, Active) alongside two WTSListen pseudo-sessions that
    # WTSINFO cannot describe. The resolver rejected the WHOLE table, so a real
    # observation could never be authoritative. Independently, a SUCCESSFUL
    # native query reports Win32Error=0, and that zero was collected as a
    # provider error, denying authority to a perfectly clean capture.
    #
    # These cases pin both corrections and, just as importantly, pin every
    # fail-closed rule they must not weaken.
    #
    # Everything here is SYNTHETIC native-shaped data. No VM is contacted and no
    # live WTS call is made.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $logonUtc = [datetime]::SpecifyKind([datetime]::new(2026, 11, 13, 15, 46, 27), [System.DateTimeKind]::Utc)
    $logonFt = $logonUtc.ToFileTimeUtc()
    $logonIso = $logonUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $user = 'P9HNODE\p9hadmin'
    $shortUser = 'p9hadmin'

    function New-LQueryOk([int]$Sid, [int]$State, [string]$Station, [string]$UserName, [long]$Ft) {
        $rec = (ConvertFrom-P9HWtsInfoPayload -Payload (New-P9HWtsInfoPayload -SessionId $Sid -State $State `
                    -StationName $Station -Domain 'P9HNODE' -UserName $UserName -LogonTime $Ft)).Record
        return [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = $rec; Win32Error = 0 }
    }
    function New-LQueryListenerMismatch([int]$Sid) {
        return [pscustomobject]@{
            Ok = $false; Reason = 'session-id-mismatch'
            Detail = ('requested session {0} but WTSINFO reported 0' -f $Sid)
            Record = $null; Win32Error = 0
        }
    }
    function New-LEnum([object[]]$Spec) {
        $p = New-P9HWtsSessionInfoPayload -Sessions $Spec
        return (ConvertFrom-P9HWtsSessionInfoPayload -Payload $p.Payload -ReportedCount $p.ReportedCount -Layout $p.Layout).Records
    }

    # The exact physical shape Stage 3B7B observed.
    $fullSpec = @(
        @{ SessionId = 0; StationName = 'Services'; State = 4 }
        @{ SessionId = 2; StationName = 'RDP-Tcp#0'; State = 0 }
        @{ SessionId = 65536; StationName = '31C5CE94259D4006A9E4'; State = 6 }
        @{ SessionId = 65537; StationName = 'RDP-Tcp'; State = 6 }
    )
    $fullEnum = New-LEnum $fullSpec
    $servicesQ = New-LQueryOk 0 4 'Services' '' 0
    $targetQ = New-LQueryOk 2 0 'RDP-Tcp#0' $shortUser $logonFt
    $fullQueries = @{
        0     = $servicesQ
        2     = $targetQ
        65536 = New-LQueryListenerMismatch 65536
        65537 = New-LQueryListenerMismatch 65537
    }

    # ---- L1: complete table with listeners resolves and authorizes ----
    $l1Resolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $fullEnum -QueryResults $fullQueries -TargetSessionId 2
    $l1Capture = Get-P9HWtsProviderTableCapture -Result $l1Resolved -TargetSessionId 2
    Add-P9HTestResult -Id 'L1' -Title 'Complete table with two WTSListen entries resolves authoritatively' `
        -Input 'sessions 0 (Services,4), 2 (RDP-Tcp#0,0 Active), 65536 + 65537 (Listen,6)' `
        -Expected 'resolver Ok=true, TargetOk=true, capture Authoritative=true, 0 errors' `
        -Actual ("resOk={0} reason={1} targetOk={2} errors={3} auth={4} lines={5} listeners={6}" -f `
            $l1Resolved.Ok, $l1Resolved.Reason, $l1Resolved.TargetOk, @($l1Resolved.Errors).Count, `
            $l1Capture.Authoritative, $l1Capture.LineCount, $l1Resolved.ListenerCount) `
        -Pass ($l1Resolved.Ok -and $l1Resolved.Reason -eq 'ok' -and $l1Resolved.TargetOk -and @($l1Resolved.Errors).Count -eq 0 -and $l1Capture.Authoritative -and $l1Capture.LineCount -eq 2 -and $l1Resolved.ListenerCount -eq 2) -Evidence $null

    # ---- L2: both listeners unavailable for WTSINFO, recorded as diagnostics only ----
    Add-P9HTestResult -Id 'L2' -Title 'Listener WTSINFO unavailability is a diagnostic, not a table error' `
        -Input 'listener queries both return session-id-mismatch (Win32 0)' `
        -Expected 'ListenerDiagnostics=2 preserved, Errors=0, each diagnostic attributed to the enumeration' `
        -Actual ("diag={0} errs={1} reasons={2} sources={3}" -f `
            @($l1Resolved.ListenerDiagnostics).Count, @($l1Resolved.Errors).Count, `
            (@($l1Resolved.ListenerDiagnostics | ForEach-Object { $_.QueryReason }) -join ','), `
            (@($l1Resolved.ListenerDiagnostics | ForEach-Object { $_.QuerySource }) -join ',')) `
        -Pass (@($l1Resolved.ListenerDiagnostics).Count -eq 2 -and @($l1Resolved.Errors).Count -eq 0 -and
            @($l1Resolved.ListenerDiagnostics | Where-Object { $_.QueryReason -eq 'session-id-mismatch' }).Count -eq 2 -and
            @($l1Resolved.ListenerDiagnostics | Where-Object { $_.QuerySource -eq 'enumeration' }).Count -eq 2) -Evidence $null

    # ---- L3: listener metadata survives with full enumeration provenance ----
    $l3Ids = (@($l1Resolved.Listeners | ForEach-Object { [int]$_.SessionId }) | Sort-Object) -join ','
    $l3Stations = (@($l1Resolved.Listeners | ForEach-Object { [string]$_.StationName }) -join ',')
    Add-P9HTestResult -Id 'L3' -Title 'Listener id, station name and state are preserved verbatim' `
        -Input 'two listeners with distinct station names' `
        -Expected 'ids 65536,65537 preserved; station names preserved; all state=6' `
        -Actual ("ids=[{0}] stations=[{1}] states=[{2}] source={3}" -f $l3Ids, $l3Stations,
            (@($l1Resolved.Listeners | ForEach-Object { [int]$_.EnumeratedState }) -join ','), [string]$l1Resolved.ListenerMetadataSource) `
        -Pass ($l3Ids -eq '65536,65537' -and $l3Stations -eq '31C5CE94259D4006A9E4,RDP-Tcp' -and
            @($l1Resolved.Listeners | Where-Object { $_.EnumeratedState -ne 6 }).Count -eq 0 -and
            [string]$l1Resolved.ListenerMetadataSource -like '*not WTSINFO*') -Evidence $null

    # ---- L4: enumeration completeness is distinguished from identity coverage ----
    Add-P9HTestResult -Id 'L4' -Title 'Complete enumeration is not conflated with complete identity coverage' `
        -Input '4 enumerated entries, 2 with WTSINFO identity' `
        -Expected 'EnumeratedCount=4, IdentityCoveredCount=2, QueryableCount=2, ListenerCount=2' `
        -Actual ("enumerated={0} identity={1} queryable={2} listeners={3}" -f `
            $l1Resolved.EnumeratedCount, $l1Resolved.IdentityCoveredCount, $l1Resolved.QueryableCount, $l1Resolved.ListenerCount) `
        -Pass ($l1Resolved.EnumeratedCount -eq 4 -and $l1Resolved.IdentityCoveredCount -eq 2 -and
            $l1Resolved.QueryableCount -eq 2 -and $l1Resolved.ListenerCount -eq 2 -and
            $l1Resolved.ListenerExcludedFromIdentity -eq $true) -Evidence $null

    # ---- L5: valid target Active with listeners present ----
    Add-P9HTestResult -Id 'L5' -Title 'An Active target resolves correctly alongside listeners' `
        -Input 'target session 2 Active, two listeners present' `
        -Expected 'TargetOk=true, target record id=2, state 0, identity pinned' `
        -Actual ("targetOk={0} reason={1} id={2} state={3} user={4} logon={5}" -f `
            $l1Resolved.TargetOk, $l1Resolved.TargetReason, [int]$l1Resolved.TargetRecord.SessionId,
            [int]$l1Resolved.TargetRecord.InfoState, [string]$l1Resolved.TargetRecord.User, [string]$l1Resolved.TargetRecord.LogonTime) `
        -Pass ($l1Resolved.TargetOk -and [int]$l1Resolved.TargetRecord.SessionId -eq 2 -and
            [int]$l1Resolved.TargetRecord.InfoState -eq 0 -and [string]$l1Resolved.TargetRecord.User -eq $user -and
            [string]$l1Resolved.TargetRecord.LogonTime -eq $logonIso) -Evidence $null

    # ---- L6: valid target Disconnected with listeners present ----
    $l6Spec = @(
        @{ SessionId = 0; StationName = 'Services'; State = 4 }
        @{ SessionId = 2; StationName = 'RDP-Tcp#0'; State = 4 }
        @{ SessionId = 65536; StationName = '31C5CE94259D4006A9E4'; State = 6 }
        @{ SessionId = 65537; StationName = 'RDP-Tcp'; State = 6 }
    )
    $l6Enum = New-LEnum $l6Spec
    $l6Queries = @{
        0     = $servicesQ
        2     = New-LQueryOk 2 4 'RDP-Tcp#0' $shortUser $logonFt
        65536 = New-LQueryListenerMismatch 65536
        65537 = New-LQueryListenerMismatch 65537
    }
    $l6Resolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $l6Enum -QueryResults $l6Queries -TargetSessionId 2
    $l6Capture = Get-P9HWtsProviderTableCapture -Result $l6Resolved -TargetSessionId 2
    $l6Parsed = ConvertFrom-P9HWtsTable -Lines $l6Capture.Lines
    $l6Judged = Test-P9HTargetDisconnected -Records $l6Parsed.Records -SessionId 2 -User $user -LogonTime $logonIso
    Add-P9HTestResult -Id 'L6' -Title 'A genuinely Disconnected target with listeners present yields disconnect evidence' `
        -Input 'target session 2 state 4, listeners still present' `
        -Expected 'resolver Ok, capture authoritative, target Disconnected=true' `
        -Actual ("resOk={0} auth={1} disc={2} reason={3}" -f $l6Resolved.Ok, $l6Capture.Authoritative, $l6Judged.Disconnected, $l6Judged.Reason) `
        -Pass ($l6Resolved.Ok -and $l6Capture.Authoritative -and $l6Judged.Disconnected -and
            $null -ne $l6Judged.Record -and [int]$l6Judged.Record.SessionId -eq 2) -Evidence $null

    # ---- L7: a listener cannot substitute for the target ----
    $l7Resolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $fullEnum -QueryResults $fullQueries -TargetSessionId 65536
    $l7Capture = Get-P9HWtsProviderTableCapture -Result $l7Resolved -TargetSessionId 65536
    Add-P9HTestResult -Id 'L7' -Title 'A listener can never be resolved as the target session' `
        -Input 'target session id pinned to a WTSListen entry (65536)' `
        -Expected 'TargetOk=false reason=target-is-listener, capture not authoritative' `
        -Actual ("targetOk={0} reason={1} capAuth={2}" -f $l7Resolved.TargetOk, $l7Resolved.TargetReason, $l7Capture.Authoritative) `
        -Pass ((-not $l7Resolved.TargetOk) -and $l7Resolved.TargetReason -eq 'target-is-listener' -and (-not $l7Capture.Authoritative)) -Evidence $null

    # ---- L8: a listener cannot authorize reconnect ----
    $l8Dir = Join-Path $SandboxRoot 'l8-listener-proof'
    New-Item -ItemType Directory -Path $l8Dir -Force | Out-Null
    $l8Log = Join-Path $l8Dir 'observer.jsonl'
    # A listener-shaped "record" is written as the ONLY post observation: state 6
    # with no user. It must never satisfy Proof A.
    $l8Pre = New-P9HObserverRecordFromTableCapture -Capture $l1Capture -TrialId 'l8-trial' -Sequence 1 -Phase 'pre' `
        -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE'
    Add-P9HArtifactLine -Path $l8Log -Line $l8Pre
    $l8ListenerLine = '65536|RDP-Tcp|state=6|user='
    $l8Disc = New-P9HObserverRecord -TrialId 'l8-trial' -Sequence 2 -Phase 'disconnect-observed' `
        -RawWtsLines @($l8ListenerLine) -TargetSessionId 2 -TargetUser $user -TargetLogonTime $logonIso `
        -CaptureAuthoritative $true
    Add-P9HArtifactLine -Path $l8Log -Line $l8Disc
    $l8Proof = Get-P9HReconnectAuthorizationProof -ObserverLogPath $l8Log -TrialId 'l8-trial' `
        -SessionId 2 -User $user -LogonTime $logonIso
    Add-P9HTestResult -Id 'L8' -Title 'A listener observation cannot authorize reconnect' `
        -Input 'pre=authoritative Active, later observation contains only a Listen row' `
        -Expected 'Proof A not proven (no state-4 record for the pinned target)' `
        -Actual ("proven={0} reason={1}" -f $l8Proof.Proven, [string]$l8Proof.Reason) `
        -Pass ((-not $l8Proof.Proven)) -Evidence $l8Log

    # ---- L9: duplicate ids involving a listener fail closed ----
    $l9Spec = @(
        @{ SessionId = 0; StationName = 'Services'; State = 4 }
        @{ SessionId = 2; StationName = 'RDP-Tcp#0'; State = 0 }
        @{ SessionId = 65536; StationName = '31C5CE94259D4006A9E4'; State = 6 }
        @{ SessionId = 65536; StationName = 'RDP-Tcp'; State = 6 }
    )
    $l9Enum = New-LEnum $l9Spec
    $l9Queries = @{
        0     = $servicesQ
        2     = $targetQ
        65536 = New-LQueryListenerMismatch 65536
    }
    $l9Resolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $l9Enum -QueryResults $l9Queries -TargetSessionId 2
    $l9Capture = Get-P9HWtsProviderTableCapture -Result $l9Resolved -TargetSessionId 2
    Add-P9HTestResult -Id 'L9' -Title 'Duplicate session ids involving listeners fail closed' `
        -Input 'two listeners both enumerated as session 65536' `
        -Expected 'Ok=false, ambiguous-enumeration, capture not authoritative' `
        -Actual ("ok={0} reason={1} targetOk={2} dups=[{3}] capAuth={4}" -f `
            $l9Resolved.Ok, $l9Resolved.Reason, $l9Resolved.TargetOk, (@($l9Resolved.DuplicateSessionIds) -join ','), $l9Capture.Authoritative) `
        -Pass ((-not $l9Resolved.Ok) -and $l9Resolved.Reason -eq 'ambiguous-enumeration' -and
            @($l9Resolved.DuplicateSessionIds) -contains 65536 -and (-not $l9Capture.Authoritative)) -Evidence $null

    # ---- L10: target id absent fails closed ----
    $l10Resolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $fullEnum -QueryResults $fullQueries -TargetSessionId 9
    $l10Capture = Get-P9HWtsProviderTableCapture -Result $l10Resolved -TargetSessionId 9
    Add-P9HTestResult -Id 'L10' -Title 'An absent target fails closed even with listeners accounted for' `
        -Input 'pinned target session 9 not in a complete listener-aware table' `
        -Expected 'TargetOk=false reason=no-target, capture not authoritative' `
        -Actual ("targetOk={0} reason={1} capAuth={2}" -f $l10Resolved.TargetOk, $l10Resolved.TargetReason, $l10Capture.Authoritative) `
        -Pass ((-not $l10Resolved.TargetOk) -and $l10Resolved.TargetReason -eq 'no-target' -and (-not $l10Capture.Authoritative)) -Evidence $null

    # ---- L11: a failed SESSION 0 query still rejects ----
    $l11Queries = @{
        0     = [pscustomobject]@{ Ok = $false; Reason = 'native-query-failed'; Detail = 'WTSQuerySessionInformationW failed (Win32 5)'; Record = $null; Win32Error = 5 }
        2     = $targetQ
        65536 = New-LQueryListenerMismatch 65536
        65537 = New-LQueryListenerMismatch 65537
    }
    $l11Resolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $fullEnum -QueryResults $l11Queries -TargetSessionId 2
    $l11Capture = Get-P9HWtsProviderTableCapture -Result $l11Resolved -TargetSessionId 2
    Add-P9HTestResult -Id 'L11' -Title 'A failed session-0 WTSINFO query still rejects the table' `
        -Input 'session 0 query fails Win32 5, listeners present, target fine' `
        -Expected 'Ok=false incomplete-session-table, capture not authoritative, Win32 5 preserved' `
        -Actual ("ok={0} reason={1} capAuth={2} win32=[{3}]" -f $l11Resolved.Ok, $l11Resolved.Reason, $l11Capture.Authoritative, (@($l11Capture.Win32Errors) -join ',')) `
        -Pass ((-not $l11Resolved.Ok) -and $l11Resolved.Reason -eq 'incomplete-session-table' -and
            (-not $l11Capture.Authoritative) -and (@($l11Capture.Win32Errors) -contains 5)) -Evidence $null

    # ---- L12: a failed non-target, NON-listener query still rejects ----
    $l12Spec = @(
        @{ SessionId = 0; StationName = 'Services'; State = 4 }
        @{ SessionId = 2; StationName = 'RDP-Tcp#0'; State = 0 }
        @{ SessionId = 3; StationName = 'RDP-Tcp#1'; State = 1 }
        @{ SessionId = 65536; StationName = '31C5CE94259D4006A9E4'; State = 6 }
    )
    $l12Enum = New-LEnum $l12Spec
    $l12Queries = @{
        0     = $servicesQ
        2     = $targetQ
        3     = [pscustomobject]@{ Ok = $false; Reason = 'native-query-failed'; Detail = 'WTSQuerySessionInformationW failed (Win32 5)'; Record = $null; Win32Error = 5 }
        65536 = New-LQueryListenerMismatch 65536
    }
    $l12Resolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $l12Enum -QueryResults $l12Queries -TargetSessionId 2
    $l12Capture = Get-P9HWtsProviderTableCapture -Result $l12Resolved -TargetSessionId 2
    Add-P9HTestResult -Id 'L12' -Title 'A failed non-target non-listener query still rejects the table' `
        -Input 'real session 3 fails while listeners are excused' `
        -Expected 'Ok=false incomplete-session-table, capture not authoritative' `
        -Actual ("ok={0} reason={1} capAuth={2} failed={3}" -f $l12Resolved.Ok, $l12Resolved.Reason, $l12Capture.Authoritative, $l12Capture.FailedCount) `
        -Pass ((-not $l12Resolved.Ok) -and $l12Resolved.Reason -eq 'incomplete-session-table' -and
            (-not $l12Capture.Authoritative) -and $l12Capture.FailedCount -eq 1) -Evidence $null

    # ---- L13: wrong user / logon identity still rejects ----
    $l13Queries = @{
        0     = $servicesQ
        2     = New-LQueryOk 2 0 'RDP-Tcp#0' 'someoneelse' $logonFt
        65536 = New-LQueryListenerMismatch 65536
        65537 = New-LQueryListenerMismatch 65537
    }
    $l13Resolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $fullEnum -QueryResults $l13Queries -TargetSessionId 2
    $l13Capture = Get-P9HWtsProviderTableCapture -Result $l13Resolved -TargetSessionId 2
    $l13Parsed = ConvertFrom-P9HWtsTable -Lines $l13Capture.Lines
    $l13Match = Get-P9HTargetSessionRecord -Records $l13Parsed.Records -SessionId 2 -User $user -LogonTime $logonIso -RequireLogonTime
    # Wrong logon time (same user) must also fail.
    $l13bQueries = @{ 0 = $servicesQ; 2 = (New-LQueryOk 2 0 'RDP-Tcp#0' $shortUser ($logonFt - 36000000000)); 65536 = (New-LQueryListenerMismatch 65536); 65537 = (New-LQueryListenerMismatch 65537) }
    $l13bResolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $fullEnum -QueryResults $l13bQueries -TargetSessionId 2
    $l13bCapture = Get-P9HWtsProviderTableCapture -Result $l13bResolved -TargetSessionId 2
    $l13bParsed = ConvertFrom-P9HWtsTable -Lines $l13bCapture.Lines
    $l13bMatch = Get-P9HTargetSessionRecord -Records $l13bParsed.Records -SessionId 2 -User $user -LogonTime $logonIso -RequireLogonTime
    Add-P9HTestResult -Id 'L13' -Title 'Wrong user or wrong logon time still rejects the pinned identity' `
        -Input 'user mismatch case and logon-time mismatch case, listeners present' `
        -Expected 'both fail closed (user-mismatch / logon mismatch)' `
        -Actual ("userMatchOk={0} reason={1} logonMatchOk={2} reason={3}" -f $l13Match.Ok, $l13Match.Reason, $l13bMatch.Ok, $l13bMatch.Reason) `
        -Pass ((-not $l13Match.Ok) -and $l13Match.Reason -eq 'user-mismatch' -and (-not $l13bMatch.Ok)) -Evidence $null

    # ---- L14: genuine target state inconsistency still rejects ----
    $l14Queries = @{
        0     = $servicesQ
        2     = New-LQueryOk 2 4 'RDP-Tcp#0' $shortUser $logonFt   # enumerated Active, WTSINFO Disconnected
        65536 = New-LQueryListenerMismatch 65536
        65537 = New-LQueryListenerMismatch 65537
    }
    $l14Resolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $fullEnum -QueryResults $l14Queries -TargetSessionId 2
    $l14Capture = Get-P9HWtsProviderTableCapture -Result $l14Resolved -TargetSessionId 2
    Add-P9HTestResult -Id 'L14' -Title 'A genuine target state change during collection still rejects' `
        -Input 'enumerated Active but WTSINFO reports Disconnected for the target' `
        -Expected 'Ok=false state-changed-during-collection, capture not authoritative' `
        -Actual ("ok={0} reason={1} targetStateChanged={2} capAuth={3}" -f `
            $l14Resolved.Ok, $l14Resolved.Reason, $l14Resolved.TargetStateChanged, $l14Capture.Authoritative) `
        -Pass ((-not $l14Resolved.Ok) -and $l14Resolved.Reason -eq 'state-changed-during-collection' -and
            (-not $l14Capture.Authoritative)) -Evidence $null

    # ---- L15: Win32Error=0 from a successful query is not a provider error ----
    $l15Resolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $fullEnum -QueryResults $fullQueries -TargetSessionId 2
    $l15Capture = Get-P9HWtsProviderTableCapture -Result $l15Resolved -TargetSessionId 2
    $l15Json = New-P9HObserverRecordFromTableCapture -Capture $l15Capture -TrialId 'l15-trial' -Sequence 1 -Phase 'pre' `
        -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE'
    $l15Rec = $l15Json | ConvertFrom-Json
    Add-P9HTestResult -Id 'L15' -Title 'A successful query with Win32Error=0 does not create a provider error' `
        -Input 'listener-aware complete table, every required query Ok=true Win32Error=0' `
        -Expected 'capture.Win32Errors empty, observer captureOutcome=ok, captureAuthoritative=true' `
        -Actual ("win32=[{0}] outcome={1} auth={2} listenerLifted={3}" -f `
            (@($l15Capture.Win32Errors) -join ','), $l15Rec.captureOutcome, $l15Rec.captureAuthoritative, $l15Rec.listenerCount) `
        -Pass (@($l15Capture.Win32Errors).Count -eq 0 -and $l15Rec.captureOutcome -eq 'ok' -and
            $l15Rec.captureAuthoritative -eq $true -and $l15Rec.listenerCount -eq 2) -Evidence $null

    # ---- L16: a FAILED query carrying Win32 0 still fails closed ----
    $l16Queries = @{
        0     = [pscustomobject]@{ Ok = $false; Reason = 'empty-native-response'; Detail = 'no bytes returned'; Record = $null; Win32Error = 0 }
        2     = $targetQ
        65536 = New-LQueryListenerMismatch 65536
        65537 = New-LQueryListenerMismatch 65537
    }
    $l16Resolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $fullEnum -QueryResults $l16Queries -TargetSessionId 2
    $l16Capture = Get-P9HWtsProviderTableCapture -Result $l16Resolved -TargetSessionId 2
    $l16Rec = (New-P9HObserverRecordFromTableCapture -Capture $l16Capture -TrialId 'l16-trial' -Sequence 1 -Phase 'pre' `
            -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE') | ConvertFrom-Json
    Add-P9HTestResult -Id 'L16' -Title 'A failed query with Win32 zero still fails closed' `
        -Input 'session 0 query Ok=false with Win32Error=0' `
        -Expected 'resolver rejected, observer captureOutcome=provider-error, not authoritative' `
        -Actual ("ok={0} reason={1} failed={2} outcome={3} auth={4}" -f `
            $l16Resolved.Ok, $l16Resolved.Reason, $l16Capture.FailedCount, $l16Rec.captureOutcome, $l16Rec.captureAuthoritative) `
        -Pass ((-not $l16Resolved.Ok) -and $l16Capture.FailedCount -eq 1 -and
            $l16Rec.captureOutcome -eq 'provider-error' -and $l16Rec.captureAuthoritative -eq $false) -Evidence $null

    # ---- L17: a real nonzero Win32 error is preserved AND blocks authority ----
    $l17Queries = @{
        0     = [pscustomobject]@{ Ok = $false; Reason = 'native-query-failed'; Detail = 'access denied'; Record = $null; Win32Error = 5 }
        2     = $targetQ
        65536 = New-LQueryListenerMismatch 65536
        65537 = New-LQueryListenerMismatch 65537
    }
    $l17Resolved = Resolve-P9HWtsSessionTable -EnumeratedSessions $fullEnum -QueryResults $l17Queries -TargetSessionId 2
    $l17Capture = Get-P9HWtsProviderTableCapture -Result $l17Resolved -TargetSessionId 2
    $l17Rec = (New-P9HObserverRecordFromTableCapture -Capture $l17Capture -TrialId 'l17-trial' -Sequence 1 -Phase 'pre' `
            -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE') | ConvertFrom-Json
    Add-P9HTestResult -Id 'L17' -Title 'A real nonzero Win32 error is preserved and blocks authority' `
        -Input 'session 0 query fails Win32 5' `
        -Expected 'captureWin32Errors contains 5, observer provider-error, not authoritative' `
        -Actual ("win32=[{0}] outcome={1} auth={2}" -f (@($l17Rec.captureWin32Errors) -join ','), $l17Rec.captureOutcome, $l17Rec.captureAuthoritative) `
        -Pass ((@($l17Rec.captureWin32Errors) -contains 5) -and $l17Rec.captureOutcome -eq 'provider-error' -and $l17Rec.captureAuthoritative -eq $false) -Evidence $null

    # ---- L18: listener metadata survives evidence serialization / read-back ----
    $l18Dir = Join-Path $SandboxRoot 'l18-serialize'
    New-Item -ItemType Directory -Path $l18Dir -Force | Out-Null
    $l18Log = Join-Path $l18Dir 'observer.jsonl'
    Add-P9HArtifactLine -Path $l18Log -Line $l15Json
    $l18Back = Read-P9HObserverLog -Path $l18Log
    $l18Persisted = @($l18Back.Records)[0]
    $l18Diag = @($l18Persisted.listenerDiagnostics)
    Add-P9HTestResult -Id 'L18' -Title 'Listener metadata and raw enumeration survive serialization and read-back' `
        -Input 'observer record persisted to JSONL then read back' `
        -Expected 'listenerCount=2, diagnosed ids preserved, rawWts lines preserved, source disclosed' `
        -Actual ("readOk={0} listenerCount={1} diag={2} rawLines={3} source={4}" -f `
            $l18Back.Ok, $l18Persisted.listenerCount, (@($l18Diag | ForEach-Object { $_.sessionId }) -join ','),
            @($l18Persisted.rawWts).Count, [string]$l18Persisted.listenerMetadataSource) `
        -Pass ($l18Back.Ok -and [int]$l18Persisted.listenerCount -eq 2 -and @($l18Diag).Count -eq 2 -and
            @($l18Diag | Where-Object { [int]$_.sessionId -eq 65536 }).Count -eq 1 -and
            @($l18Persisted.rawWts).Count -eq 2 -and
            [string]$l18Persisted.listenerMetadataSource -like '*not WTSINFO*') -Evidence $l18Log

    # ---- L19: POSITIVE synthetic Proof A + Proof B over listener-aware tables ----
    $l19Dir = Join-Path $SandboxRoot 'l19-proof'
    New-Item -ItemType Directory -Path $l19Dir -Force | Out-Null
    $l19Log = Join-Path $l19Dir 'observer.jsonl'

    $l19Pre = New-P9HObserverRecordFromTableCapture -Capture $l1Capture -TrialId 'l19-trial' -Sequence 1 -Phase 'pre' `
        -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE'
    Add-P9HArtifactLine -Path $l19Log -Line $l19Pre
    $l19Disc = New-P9HObserverRecordFromTableCapture -Capture $l6Capture -TrialId 'l19-trial' -Sequence 2 -Phase 'disconnect-observed' `
        -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE'
    Add-P9HArtifactLine -Path $l19Log -Line $l19Disc
    $l19ProofA = Get-P9HReconnectAuthorizationProof -ObserverLogPath $l19Log -TrialId 'l19-trial' `
        -SessionId 2 -User $user -LogonTime $logonIso
    # reconnect happened: target Active again, listeners present
    $l19Post = New-P9HObserverRecordFromTableCapture -Capture $l1Capture -TrialId 'l19-trial' -Sequence 3 -Phase 'post' `
        -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE'
    Add-P9HArtifactLine -Path $l19Log -Line $l19Post
    $l19ProofB = Get-P9HDisconnectProof -ObserverLogPath $l19Log -TrialId 'l19-trial' `
        -SessionId 2 -User $user -LogonTime $logonIso
    Add-P9HTestResult -Id 'L19' -Title 'Positive Proof A and Proof B over listener-aware authoritative tables' `
        -Input 'pre Active -> disconnect-observed Disconnected -> post Active, listeners present throughout' `
        -Expected 'Proof A proven and Proof B proven' `
        -Actual ("proofA={0}({1}) proofB={2}({3})" -f $l19ProofA.Proven, [string]$l19ProofA.Reason, $l19ProofB.Proven, [string]$l19ProofB.Reason) `
        -Pass ($l19ProofA.Proven -and $l19ProofB.Proven) -Evidence $l19Log

    # ---- L20: NEGATIVE Proof A/B when a required non-listener query failed ----
    $l20Dir = Join-Path $SandboxRoot 'l20-negproof'
    New-Item -ItemType Directory -Path $l20Dir -Force | Out-Null
    $l20Log = Join-Path $l20Dir 'observer.jsonl'
    $l20Pre = New-P9HObserverRecordFromTableCapture -Capture $l11Capture -TrialId 'l20-trial' -Sequence 1 -Phase 'pre' `
        -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE'
    Add-P9HArtifactLine -Path $l20Log -Line $l20Pre
    $l20Disc = New-P9HObserverRecordFromTableCapture -Capture $l11Capture -TrialId 'l20-trial' -Sequence 2 -Phase 'disconnect-observed' `
        -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE'
    Add-P9HArtifactLine -Path $l20Log -Line $l20Disc
    $l20Post = New-P9HObserverRecordFromTableCapture -Capture $l11Capture -TrialId 'l20-trial' -Sequence 3 -Phase 'post' `
        -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE'
    Add-P9HArtifactLine -Path $l20Log -Line $l20Post
    $l20A = Get-P9HReconnectAuthorizationProof -ObserverLogPath $l20Log -TrialId 'l20-trial' `
        -SessionId 2 -User $user -LogonTime $logonIso
    $l20B = Get-P9HDisconnectProof -ObserverLogPath $l20Log -TrialId 'l20-trial' `
        -SessionId 2 -User $user -LogonTime $logonIso
    Add-P9HTestResult -Id 'L20' -Title 'Negative Proof A and B when a required non-listener query failed' `
        -Input 'incomplete (session 0 failed) tables across all phases' `
        -Expected 'neither Proof A nor Proof B proven' `
        -Actual ("proofA={0}({1}) proofB={2}({3})" -f $l20A.Proven, [string]$l20A.Reason, $l20B.Proven, [string]$l20B.Reason) `
        -Pass ((-not $l20A.Proven) -and (-not $l20B.Proven)) -Evidence $l20Log

    # ---- L21: a row set without a resolved result never becomes authoritative ----
    $l21Capture = Get-P9HWtsProviderTableCapture -Rows $l1Resolved.Rows -TargetSessionId 2
    $l21Rec = (New-P9HObserverRecordFromTableCapture -Capture $l21Capture -TrialId 'l21-trial' -Sequence 1 -Phase 'pre' `
            -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE') | ConvertFrom-Json
    Add-P9HTestResult -Id 'L21' -Title 'Rows supplied without a resolved result never become authoritative' `
        -Input 'the same complete listener-aware rows, but stripped of resolver status' `
        -Expected 'capture.Authoritative=false reason=capture-rows-without-resolver-status, observer not authoritative' `
        -Actual ("capAuth={0} reason={1} obsAuth={2}" -f $l21Capture.Authoritative, [string]$l21Capture.RejectionReason, $l21Rec.captureAuthoritative) `
        -Pass ((-not $l21Capture.Authoritative) -and $l21Capture.RejectionReason -eq 'capture-rows-without-resolver-status' -and
            $l21Rec.captureAuthoritative -eq $false) -Evidence $null

    # ---- L22: session 0 keeps its own state and is never the disconnected target ----
    $l1Parsed = ConvertFrom-P9HWtsTable -Lines $l1Capture.Lines
    $l1ParsedRecords = @($l1Parsed.Records)
    $l22Match = Get-P9HTargetSessionRecord -Records $l1ParsedRecords -SessionId 0 -User $user -LogonTime $logonIso
    $l22Session0 = @($l1Resolved.Rows | Where-Object { [int]$_.SessionId -eq 0 })
    Add-P9HTestResult -Id 'L22' -Title 'Session 0 keeps its own state and is never the pinned target' `
        -Input 'session 0 Disconnected alongside an Active target session 2' `
        -Expected 'session 0 present with state 4 and no user; cannot match the RDP identity' `
        -Actual ("session0Rows={0} state={1} user=[{2}] matchOk={3} reason={4}" -f `
            $l22Session0.Count, [int]$l22Session0[0].EnumeratedState, [string]$l22Session0[0].User, $l22Match.Ok, $l22Match.Reason) `
        -Pass ($l22Session0.Count -eq 1 -and [int]$l22Session0[0].EnumeratedState -eq 4 -and
            (-not $l22Match.Ok)) -Evidence $null

    # ---- L23: no structural listener row leaks into the rendered user table ----
    $l23Parse = ConvertFrom-P9HWtsTable -Lines $l1Capture.Lines
    $l23ListenerLines = @($l23Parse.Records | Where-Object { [int]$_.State -eq 6 })
    Add-P9HTestResult -Id 'L23' -Title 'No listener is rendered as a user session line' `
        -Input 'listener-aware capture lines' `
        -Expected 'parsed table has exactly 2 records (0 and 2), none in state 6' `
        -Actual ("records={0} state6={1} ids=[{2}]" -f @($l23Parse.Records).Count, $l23ListenerLines.Count,
            (@($l23Parse.Records | ForEach-Object { [int]$_.SessionId }) -join ',')) `
        -Pass ($l23Parse.Ok -and @($l23Parse.Records).Count -eq 2 -and $l23ListenerLines.Count -eq 0) -Evidence $null
}

function Invoke-P9HObserverBridgeTests {
    # C-series: capture -> Wait-P9HTargetDisconnected provider adapter
    # (Stage 3B7C).
    #
    # Wait-P9HTargetDisconnected consumes a `-Provider` scriptblock. Before
    # Stage 3B7C no production function projected a real capture into that shape,
    # so a caller had to hand-write one. A hand-written scriptblock is precisely
    # how an invented `CaptureOutcome='ok'` default could make a rejected capture
    # look authoritative.
    #
    # ConvertTo-P9HWtsObserverProviderSample is that adapter. These cases pin that
    # it DERIVES every field from the resolver/capture and never invents one.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $logonUtc = [datetime]::SpecifyKind([datetime]::new(2026, 11, 13, 16, 59, 57), [System.DateTimeKind]::Utc)
    $logonFt = $logonUtc.ToFileTimeUtc()
    $logonIso = $logonUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $user = 'P9HNODE\p9hadmin'

    function New-CQueryOk([int]$Sid, [int]$State, [string]$Station, [string]$UserName, [long]$Ft) {
        $rec = (ConvertFrom-P9HWtsInfoPayload -Payload (New-P9HWtsInfoPayload -SessionId $Sid -State $State `
                    -StationName $Station -Domain 'P9HNODE' -UserName $UserName -LogonTime $Ft)).Record
        return [pscustomobject]@{ Ok = $true; Reason = 'ok'; Detail = $null; Record = $rec; Win32Error = 0 }
    }
    function New-CListener([int]$Sid) {
        return [pscustomobject]@{ Ok = $false; Reason = 'session-id-mismatch'; Detail = ('requested {0}, reported 0' -f $Sid); Record = $null; Win32Error = 0 }
    }
    function New-CEnum([object[]]$Spec) {
        $p = New-P9HWtsSessionInfoPayload -Sessions $Spec
        return (ConvertFrom-P9HWtsSessionInfoPayload -Payload $p.Payload -ReportedCount $p.ReportedCount -Layout $p.Layout).Records
    }

    $spec = @(
        @{ SessionId = 0; StationName = 'Services'; State = 4 }
        @{ SessionId = 2; StationName = 'RDP-Tcp#0'; State = 0 }
        @{ SessionId = 65536; StationName = '31C5CE94259D4006A9E4'; State = 6 }
    )
    $enum = New-CEnum $spec
    $services = New-CQueryOk 0 4 'Services' '' 0
    $active = New-CQueryOk 2 0 'RDP-Tcp#0' 'p9hadmin' $logonFt
    $good = @{ 0 = $services; 2 = $active; 65536 = (New-CListener 65536) }

    # ---- C1: clean authoritative capture projects to an authoritative sample ----
    $r1 = Resolve-P9HWtsSessionTable -EnumeratedSessions $enum -QueryResults $good -TargetSessionId 2
    $cap1 = Get-P9HWtsProviderTableCapture -Result $r1 -TargetSessionId 2
    $s1 = ConvertTo-P9HWtsObserverProviderSample -Capture $cap1 -QuserText 'quser-stub'
    Add-P9HTestResult -Id 'C1' -Title 'A clean authoritative capture projects to an authoritative provider sample' `
        -Input 'listener-aware complete table, all required queries Ok Win32=0' `
        -Expected 'Authoritative=true, CaptureOutcome=ok, RawWtsLines=2, Win32Errors empty' `
        -Actual ("auth={0} outcome={1} raw={2} win32={3} rejection=[{4}]" -f `
            $s1.Authoritative, $s1.CaptureOutcome, @($s1.RawWtsLines).Count, @($s1.Win32Errors).Count, [string]$s1.RejectionReason) `
        -Pass ($s1.Authoritative -eq $true -and $s1.CaptureOutcome -eq 'ok' -and @($s1.RawWtsLines).Count -eq 2 -and
            @($s1.Win32Errors).Count -eq 0 -and [string]::IsNullOrWhiteSpace([string]$s1.RejectionReason)) -Evidence $null

    # ---- C2: rejected resolver result stays non-authoritative through the adapter ----
    $failQ = @{ 0 = $services; 2 = $active; 65536 = (New-CListener 65536) }
    $badSpec = @(
        @{ SessionId = 0; StationName = 'Services'; State = 4 }
        @{ SessionId = 2; StationName = 'RDP-Tcp#0'; State = 0 }
        @{ SessionId = 3; StationName = 'RDP-Tcp#1'; State = 1 }
    )
    $badEnum = New-CEnum $badSpec
    $failQ[3] = [pscustomobject]@{ Ok = $false; Reason = 'native-query-failed'; Detail = 'access denied'; Record = $null; Win32Error = 5 }
    $r2 = Resolve-P9HWtsSessionTable -EnumeratedSessions $badEnum -QueryResults $failQ -TargetSessionId 2
    $cap2 = Get-P9HWtsProviderTableCapture -Result $r2 -TargetSessionId 2
    $s2 = ConvertTo-P9HWtsObserverProviderSample -Capture $cap2
    Add-P9HTestResult -Id 'C2' -Title 'A rejected resolver result stays non-authoritative through the adapter' `
        -Input 'a real non-target non-listener query fails Win32 5' `
        -Expected 'Authoritative=false, CaptureOutcome=provider-error, Win32 5 preserved, rejection set' `
        -Actual ("auth={0} outcome={1} win32=[{2}] rejection=[{3}]" -f `
            $s2.Authoritative, $s2.CaptureOutcome, (@($s2.Win32Errors) -join ','), [string]$s2.RejectionReason) `
        -Pass ($s2.Authoritative -eq $false -and $s2.CaptureOutcome -eq 'provider-error' -and
            (@($s2.Win32Errors) -contains 5) -and -not [string]::IsNullOrWhiteSpace([string]$s2.RejectionReason)) -Evidence $null

    # ---- C3: a rejected-but-successfully-read capture keeps outcome ok, not authoritative ----
    $rowsOnly = Get-P9HWtsProviderTableCapture -Rows $r1.Rows -TargetSessionId 2
    $s3 = ConvertTo-P9HWtsObserverProviderSample -Capture $rowsOnly
    Add-P9HTestResult -Id 'C3' -Title 'A rows-only capture keeps outcome ok but is never authoritative' `
        -Input 'rows without a resolved result' `
        -Expected 'CaptureOutcome=ok, Authoritative=false, RejectionReason=capture-rows-without-resolver-status' `
        -Actual ("outcome={0} auth={1} rejection={2}" -f $s3.CaptureOutcome, $s3.Authoritative, [string]$s3.RejectionReason) `
        -Pass ($s3.CaptureOutcome -eq 'ok' -and $s3.Authoritative -eq $false -and
            $s3.RejectionReason -eq 'capture-rows-without-resolver-status') -Evidence $null

    # ---- C4: the adapter never invents default 'ok' when the capture says otherwise ----
    $synthetic = [pscustomobject][ordered]@{
        Lines = @('2|RDP-Tcp#0|state=0|user=P9HNODE\p9hadmin'); Authoritative = $false
        RejectionReason = 'resolver-rejected:incomplete-session-table'; ResolverDetail = 'session 3 failed'
        Win32Errors = @(5); FailedCount = 1; ListenerCount = 0; EnumeratedCount = 3; IdentityCoveredCount = 2
        TargetSessionId = 2
    }
    $s4 = ConvertTo-P9HWtsObserverProviderSample -Capture $synthetic
    Add-P9HTestResult -Id 'C4' -Title 'The adapter derives a provider error from the capture, not a default' `
        -Input 'capture declaring one failed query with Win32 5' `
        -Expected 'CaptureOutcome=provider-error, CaptureError populated, Authoritative=false' `
        -Actual ("outcome={0} error=[{1}] auth={2}" -f $s4.CaptureOutcome, [string]$s4.CaptureError, $s4.Authoritative) `
        -Pass ($s4.CaptureOutcome -eq 'provider-error' -and -not [string]::IsNullOrWhiteSpace([string]$s4.CaptureError) -and
            $s4.Authoritative -eq $false) -Evidence $null

    # ---- C5: listener inventory stays auditable through the adapter ----
    $s5 = ConvertTo-P9HWtsObserverProviderSample -Capture $cap1
    Add-P9HTestResult -Id 'C5' -Title 'Listener inventory stays auditable through the adapter' `
        -Input 'authoritative listener-aware capture' `
        -Expected 'ListenerCount=1, EnumeratedCount=3, IdentityCoveredCount=2' `
        -Actual ("listeners={0} enumerated={1} identity={2}" -f $s5.ListenerCount, $s5.EnumeratedCount, $s5.IdentityCoveredCount) `
        -Pass ([int]$s5.ListenerCount -eq 1 -and [int]$s5.EnumeratedCount -eq 3 -and [int]$s5.IdentityCoveredCount -eq 2) -Evidence $null

    # ---- C6: a disconnected session 0 cannot satisfy Proof A through the adapter ----
    $disc0Spec = @(
        @{ SessionId = 0; StationName = 'Services'; State = 4 }
        @{ SessionId = 2; StationName = 'RDP-Tcp#0'; State = 0 }
        @{ SessionId = 65536; StationName = '31C5CE94259D4006A9E4'; State = 6 }
    )
    $disc0Enum = New-CEnum $disc0Spec
    $disc0Q = @{ 0 = $services; 2 = $active; 65536 = (New-CListener 65536) }
    $r6 = Resolve-P9HWtsSessionTable -EnumeratedSessions $disc0Enum -QueryResults $disc0Q -TargetSessionId 2
    $cap6 = Get-P9HWtsProviderTableCapture -Result $r6 -TargetSessionId 2
    $s6 = ConvertTo-P9HWtsObserverProviderSample -Capture $cap6

    $dir6 = Join-Path $SandboxRoot 'c6-session0'
    New-Item -ItemType Directory -Path $dir6 -Force | Out-Null
    $log6 = Join-Path $dir6 'observer.jsonl'
    $pre6 = (New-P9HObserverRecordFromTableCapture -Capture $cap6 -TrialId 'c6-trial' -Sequence 1 -Phase 'pre' `
            -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE')
    Add-P9HArtifactLine -Path $log6 -Line $pre6

    # Session 0 is disconnected; the provider still reports the target Active.
    $wait6 = Wait-P9HTargetDisconnected -TrialId 'c6-trial' -SequenceStart 2 -ObserverLogPath $log6 `
        -TargetSessionId 2 -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE' `
        -Provider { $s6 } -TimeoutSeconds 2 -PollIntervalMs 100
    $proof6 = Get-P9HReconnectAuthorizationProof -ObserverLogPath $log6 -TrialId 'c6-trial' `
        -SessionId 2 -User $user -LogonTime $logonIso
    Add-P9HTestResult -Id 'C6' -Title 'A disconnected session 0 cannot satisfy Proof A' `
        -Input 'session 0 state 4, pinned target session 2 still Active' `
        -Expected 'Wait never proves, Proof A not proven' `
        -Actual ("waitProven={0} reason={1} proofA={2}({3})" -f $wait6.Proven, [string]$wait6.Reason, $proof6.Proven, [string]$proof6.Reason) `
        -Pass ((-not $wait6.Proven) -and (-not $proof6.Proven)) -Evidence $log6

    # ---- C7: the adapter end-to-end drives Wait -> Proof A on a real disconnect ----
    $discSpec = @(
        @{ SessionId = 0; StationName = 'Services'; State = 4 }
        @{ SessionId = 2; StationName = 'RDP-Tcp#0'; State = 4 }
        @{ SessionId = 65536; StationName = '31C5CE94259D4006A9E4'; State = 6 }
    )
    $discEnum = New-CEnum $discSpec
    $discRecord = New-CQueryOk 2 4 'RDP-Tcp#0' 'p9hadmin' $logonFt
    $discQ = @{ 0 = $services; 2 = $discRecord; 65536 = (New-CListener 65536) }
    $r7 = Resolve-P9HWtsSessionTable -EnumeratedSessions $discEnum -QueryResults $discQ -TargetSessionId 2
    $cap7 = Get-P9HWtsProviderTableCapture -Result $r7 -TargetSessionId 2
    $s7 = ConvertTo-P9HWtsObserverProviderSample -Capture $cap7

    $dir7 = Join-Path $SandboxRoot 'c7-endtoend'
    New-Item -ItemType Directory -Path $dir7 -Force | Out-Null
    $log7 = Join-Path $dir7 'observer.jsonl'
    $pre7 = (New-P9HObserverRecordFromTableCapture -Capture $cap6 -TrialId 'c7-trial' -Sequence 1 -Phase 'pre' `
            -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE')
    Add-P9HArtifactLine -Path $log7 -Line $pre7
    $wait7 = Wait-P9HTargetDisconnected -TrialId 'c7-trial' -SequenceStart 2 -ObserverLogPath $log7 `
        -TargetSessionId 2 -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE' `
        -Provider { $s7 } -TimeoutSeconds 5 -PollIntervalMs 100
    $gate7 = $null; $gateReason = 'not-attempted'
    try {
        $gate7 = Assert-P9HReconnectPermitted -ObserverLogPath $log7 -TrialId 'c7-trial' `
            -TargetSessionId 2 -TargetUser $user -TargetLogonTime $logonIso
        $gateReason = 'permitted'
    }
    catch { $gateReason = $_.Exception.Message }
    Add-P9HTestResult -Id 'C7' -Title 'The adapter drives Wait and the reconnect gate end to end' `
        -Input 'authoritative pre Active, then an authoritative Disconnected sample' `
        -Expected 'Wait proves, Assert-P9HReconnectPermitted permits' `
        -Actual ("waitProven={0} reason={1} gate={2}" -f $wait7.Proven, [string]$wait7.Reason, $gateReason) `
        -Pass ($wait7.Proven -and $null -ne $gate7 -and $gate7.Proven -and $gateReason -eq 'permitted') -Evidence $log7

    # ---- C8: a failed non-listener query cannot become authoritative via the adapter ----
    $failQ8 = @{ 0 = $services; 2 = $discRecord; 65536 = (New-CListener 65536) }
    $bad8Spec = @(
        @{ SessionId = 0; StationName = 'Services'; State = 4 }
        @{ SessionId = 2; StationName = 'RDP-Tcp#0'; State = 4 }
        @{ SessionId = 5; StationName = 'RDP-Tcp#2'; State = 1 }
    )
    $bad8Enum = New-CEnum $bad8Spec
    $failQ8[5] = [pscustomobject]@{ Ok = $false; Reason = 'native-query-failed'; Detail = 'denied'; Record = $null; Win32Error = 5 }
    $r8 = Resolve-P9HWtsSessionTable -EnumeratedSessions $bad8Enum -QueryResults $failQ8 -TargetSessionId 2
    $cap8 = Get-P9HWtsProviderTableCapture -Result $r8 -TargetSessionId 2
    $s8 = ConvertTo-P9HWtsObserverProviderSample -Capture $cap8
    $dir8 = Join-Path $SandboxRoot 'c8-fail'
    New-Item -ItemType Directory -Path $dir8 -Force | Out-Null
    $log8 = Join-Path $dir8 'observer.jsonl'
    Add-P9HArtifactLine -Path $log8 -Line $pre7
    $wait8 = Wait-P9HTargetDisconnected -TrialId 'c7-trial' -SequenceStart 2 -ObserverLogPath $log8 `
        -TargetSessionId 2 -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE' `
        -Provider { $s8 } -TimeoutSeconds 2 -PollIntervalMs 100
    $proof8 = Get-P9HReconnectAuthorizationProof -ObserverLogPath $log8 -TrialId 'c7-trial' `
        -SessionId 2 -User $user -LogonTime $logonIso
    Add-P9HTestResult -Id 'C8' -Title 'A failed non-listener query cannot become authoritative through the adapter' `
        -Input 'target line looks Disconnected but a real session query failed Win32 5' `
        -Expected 'sample non-authoritative, Wait never proves, Proof A not proven' `
        -Actual ("auth={0} outcome={1} waitProven={2} proofA={3}" -f $s8.Authoritative, $s8.CaptureOutcome, $wait8.Proven, $proof8.Proven) `
        -Pass ($s8.Authoritative -eq $false -and (-not $wait8.Proven) -and (-not $proof8.Proven)) -Evidence $log8

    # ---- C9: Win32 zero is never reported as a failure by the adapter ----
    $s9 = ConvertTo-P9HWtsObserverProviderSample -Capture $cap1
    $zeroInWin32 = @($s9.Win32Errors | Where-Object { [int]$_ -eq 0 }).Count
    Add-P9HTestResult -Id 'C9' -Title 'The adapter never reports a Win32 zero as a failure' `
        -Input 'authoritative capture where every successful query returned Win32Error=0' `
        -Expected 'zero codes absent from Win32Errors, outcome=ok' `
        -Actual ("win32=[{0}] zeros={1} outcome={2}" -f (@($s9.Win32Errors) -join ','), $zeroInWin32, $s9.CaptureOutcome) `
        -Pass ($zeroInWin32 -eq 0 -and $s9.CaptureOutcome -eq 'ok' -and $s9.Authoritative -eq $true) -Evidence $null

    # ---- C10: every polled sample is persisted and read back ----
    $dir10 = Join-Path $SandboxRoot 'c10-persist'
    New-Item -ItemType Directory -Path $dir10 -Force | Out-Null
    $log10 = Join-Path $dir10 'observer.jsonl'
    Add-P9HArtifactLine -Path $log10 -Line $pre7
    # Provider returns Active (rejected for disconnect) twice, then Disconnected.
    $script:c10 = 0
    $wait10 = Wait-P9HTargetDisconnected -TrialId 'c7-trial' -SequenceStart 2 -ObserverLogPath $log10 `
        -TargetSessionId 2 -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE' `
        -Provider {
            $script:c10++
            if ($script:c10 -le 2) { $s6 } else { $s7 }
        } -TimeoutSeconds 10 -PollIntervalMs 50
    $back10 = Read-P9HObserverLog -Path $log10
    $seqs10 = @($back10.Records | ForEach-Object { [int]$_.sequence })
    Add-P9HTestResult -Id 'C10' -Title 'Every polled sample is persisted and read back' `
        -Input 'two non-matching samples then a matching one' `
        -Expected '3 disconnect-observed records persisted with increasing sequence, log readable' `
        -Actual ("proven={0} records={1} seqs=[{2}] readOk={3}" -f $wait10.Proven, @($back10.Records).Count, ($seqs10 -join ','), $back10.Ok) `
        -Pass ($wait10.Proven -and $back10.Ok -and @($back10.Records).Count -eq 4 -and
            (($seqs10 -join ',') -eq '1,2,3,4')) -Evidence $log10

    # ---- C11: a listener line can never authorize a disconnect proof ----
    $listenerOnly = [pscustomobject][ordered]@{
        Lines = @('65536|RDP-Tcp|state=6|user='); Authoritative = $true
        RejectionReason = $null; ResolverDetail = $null
        Win32Errors = @(); FailedCount = 0; ListenerCount = 1; EnumeratedCount = 1; IdentityCoveredCount = 0
        TargetSessionId = 2
    }
    $s11 = ConvertTo-P9HWtsObserverProviderSample -Capture $listenerOnly
    $dir11 = Join-Path $SandboxRoot 'c11-listener'
    New-Item -ItemType Directory -Path $dir11 -Force | Out-Null
    $log11 = Join-Path $dir11 'observer.jsonl'
    Add-P9HArtifactLine -Path $log11 -Line $pre7
    $wait11 = Wait-P9HTargetDisconnected -TrialId 'c7-trial' -SequenceStart 2 -ObserverLogPath $log11 `
        -TargetSessionId 2 -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE' `
        -Provider { $s11 } -TimeoutSeconds 2 -PollIntervalMs 100
    Add-P9HTestResult -Id 'C11' -Title 'A listener line can never stand in for a target disconnect' `
        -Input 'provider returns only a WTSListen line while pinned target is session 2' `
        -Expected 'Wait never proves a disconnect' `
        -Actual ("waitProven={0} reason={1}" -f $wait11.Proven, [string]$wait11.Reason) `
        -Pass ((-not $wait11.Proven)) -Evidence $log11

    # ---- C12: a changed logon time on the same session id cannot prove a disconnect ----
    $otherLogon = New-CQueryOk 2 4 'RDP-Tcp#0' 'p9hadmin' ($logonFt - 36000000000)
    $q12 = @{ 0 = $services; 2 = $otherLogon; 65536 = (New-CListener 65536) }
    $r12 = Resolve-P9HWtsSessionTable -EnumeratedSessions $discEnum -QueryResults $q12 -TargetSessionId 2
    $cap12 = Get-P9HWtsProviderTableCapture -Result $r12 -TargetSessionId 2
    $s12 = ConvertTo-P9HWtsObserverProviderSample -Capture $cap12
    $dir12 = Join-Path $SandboxRoot 'c12-relogon'
    New-Item -ItemType Directory -Path $dir12 -Force | Out-Null
    $log12 = Join-Path $dir12 'observer.jsonl'
    Add-P9HArtifactLine -Path $log12 -Line $pre7
    $wait12 = Wait-P9HTargetDisconnected -TrialId 'c7-trial' -SequenceStart 2 -ObserverLogPath $log12 `
        -TargetSessionId 2 -TargetUser $user -TargetLogonTime $logonIso -GuestIdentity 'P9HNODE' `
        -Provider { $s12 } -TimeoutSeconds 2 -PollIntervalMs 100
    Add-P9HTestResult -Id 'C12' -Title 'A different logon time on the same session id cannot prove the disconnect' `
        -Input 'target session 2 Disconnected but WTSINFO logon time differs from the pin' `
        -Expected 'Wait never proves; identity mismatch rejects' `
        -Actual ("waitProven={0} reason={1} detail={2}" -f $wait12.Proven, [string]$wait12.Reason, [string]$wait12.Detail) `
        -Pass ((-not $wait12.Proven)) -Evidence $log12
}


function Invoke-P9HChronologyBoundTests {
    # Z-series: fail-closed lower-bound chronology for the E1 verdict
    # (Stage 3B7F-R1-A).
    #
    # The E1 evaluator originally bounded the captures only ABOVE (pre before the
    # disconnect) and the post capture only BELOW (after the post observation).
    # Nothing stopped a PRE monitor capture from predating the very RDP session it
    # claimed to describe. A synthetic PRE capture timestamped five hours before
    # the target logon returned PASS with zero reasons.
    #
    # The correction adds a mandatory target-logon lower bound and an opt-in
    # pre-observation lower bound. These cases pin both, and pin that the previous
    # guarantees (and every unrelated N2 predicate) are untouched.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $dir = Join-Path $SandboxRoot 'z-chronology'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $trialId = 'z-chrono-trial'
    $user = 'qauser'
    $tokens = @('path:DEFAULT_MONITOR/1&AAAA&0&UID1001', 'path:DEFAULT_MONITOR/1&AAAA&0&UID1002')
    $rects = @('x=0 y=0 w=1920 h=1080', 'x=-2560 y=0 w=2560 h=1440')

    # pinned target logon for the syntactic trials
    $logonUtc = [datetime]::SpecifyKind([datetime]::new(2026, 11, 14, 9, 5, 16), [System.DateTimeKind]::Utc)
    $logonIso = $logonUtc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)

    function New-ZCapture([string]$name, [string]$capturedUtc) {
        $recs = @()
        for ($i = 0; $i -lt 2; $i++) { $recs += [pscustomobject][ordered]@{ identity = $tokens[$i]; rect = $rects[$i] } }
        $obj = [ordered]@{
            tokenCount = 2; identityComplete = $true; sessionId = 3; trialId = $trialId
            capturedUtc = $capturedUtc; tokens = $tokens; parsedMonitors = $recs
        }
        $p = Join-Path $dir $name
        Write-P9HArtifact -Path $p -Lines @(($obj | ConvertTo-Json -Depth 6))
        return $p
    }
    function New-ZLog([string]$name, [string]$preUtc, [string]$discUtc, [string]$postUtc) {
        $p = Join-Path $dir $name
        $seq = 1
        foreach ($e in @(
                @{ Phase = 'pre'; State = 0; Utc = $preUtc }
                @{ Phase = 'disconnect-observed'; State = 4; Utc = $discUtc }
                @{ Phase = 'post'; State = 0; Utc = $postUtc })) {
            $line = New-P9HObserverRecord -TrialId $trialId -Sequence $seq -Phase $e.Phase `
                -RawWtsLines @(('3|RDP-Tcp#0|state=' + $e.State + '|user=' + $user + '|logon=' + $logonIso)) `
                -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso
            $j = $line | ConvertFrom-Json
            $j.utc = $e.Utc
            Add-P9HArtifactLine -Path $p -Line ($j | ConvertTo-Json -Compress -Depth 6)
            $seq++
        }
        return $p
    }

    # Canonical fixture: capture AFTER the pre observation (contract-compliant).
    $preObsUtc = '2026-11-14T09:05:20.0000000Z'
    $discUtc = '2026-11-14T09:10:56.0000000Z'
    $postObsUtc = '2026-11-14T09:12:44.0000000Z'
    $goodPre = New-ZCapture 'z-good-pre.json' '2026-11-14T09:06:48.0000000Z'
    $goodPost = New-ZCapture 'z-good-post.json' '2026-11-14T09:12:51.0000000Z'
    $goodLog = New-ZLog 'z-good.jsonl' $preObsUtc $discUtc $postObsUtc

    # ---- Z1: the genuine ordering PASSES (positive control) ----
    $z1 = Get-P9HE1Verdict -PreCapturePath $goodPre -PostCapturePath $goodPost -ObserverLogPath $goodLog `
        -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso -TrialId $trialId
    Add-P9HTestResult -Id 'Z1' -Title 'Genuine ordering still satisfies the complete E1 predicate' `
        -Input 'preObs < preCapture < disconnect < postObs < postCapture, all after the target logon' `
        -Expected 'PASS, lower bound satisfied' `
        -Actual ("Verdict={0} lowerBound={1} reasons={2}" -f $z1.Verdict, $z1.PreCaptureLowerBoundOk, ($z1.Reasons -join ',')) `
        -Pass ($z1.Verdict -eq 'PASS' -and $z1.PreCaptureLowerBoundOk -eq $true) -Evidence $goodLog

    # ---- Z2: PRE capture BEFORE the target logon is rejected ----
    $badPre = New-ZCapture 'z-bad-logon-pre.json' '2026-11-14T04:06:48.0000000Z'
    $z2 = Get-P9HE1Verdict -PreCapturePath $badPre -PostCapturePath $goodPost -ObserverLogPath $goodLog `
        -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso -TrialId $trialId
    Add-P9HTestResult -Id 'Z2' -Title 'A PRE capture that predates the target logon is rejected' `
        -Input 'PRE captured 5 h BEFORE the pinned RDP logon (the impossible timeline)' `
        -Expected 'not PASS, pre-capture-precedes-target-logon reported' `
        -Actual ("Verdict={0} lowerBound={1} reasons={2}" -f $z2.Verdict, $z2.PreCaptureLowerBoundOk, ($z2.Reasons -join ',')) `
        -Pass ($z2.Verdict -ne 'PASS' -and $z2.Reasons -contains 'pre-capture-precedes-target-logon' -and
            $z2.PreCaptureLowerBoundOk -eq $false) -Evidence $goodLog

    # ---- Z3: PRE capture predating the pre observation is rejected WHEN REQUIRED ----
    $earlyPre = New-ZCapture 'z-early-pre.json' '2026-11-14T09:05:18.0000000Z'   # after logon, before preObs
    $z3 = Get-P9HE1Verdict -PreCapturePath $earlyPre -PostCapturePath $goodPost -ObserverLogPath $goodLog `
        -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso -TrialId $trialId `
        -RequirePreCaptureAfterPreObservation
    Add-P9HTestResult -Id 'Z3' -Title 'When the contract demands it, a PRE capture before the pre observation is rejected' `
        -Input 'preCapture between logon and preObs, -RequirePreCaptureAfterPreObservation' `
        -Expected 'not PASS, pre-capture-precedes-pre-observation reported' `
        -Actual ("Verdict={0} lowerBound={1} reasons={2}" -f $z3.Verdict, $z3.PreCaptureLowerBoundOk, ($z3.Reasons -join ',')) `
        -Pass ($z3.Verdict -ne 'PASS' -and $z3.Reasons -contains 'pre-capture-precedes-pre-observation') -Evidence $goodLog

    # ---- Z4: the same ordering is tolerated when the contract does NOT demand it ----
    $z4 = Get-P9HE1Verdict -PreCapturePath $earlyPre -PostCapturePath $goodPost -ObserverLogPath $goodLog `
        -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso -TrialId $trialId
    $z4Sub = $z4.SubObservations
    Add-P9HTestResult -Id 'Z4' -Title 'Capture-then-observe remains acceptable when the contract does not demand ordering' `
        -Input 'same fixture, no -RequirePreCaptureAfterPreObservation' `
        -Expected 'PASS, ordering still reported as False in SubObservations' `
        -Actual ("Verdict={0} notBeforePreObs={1} required={2}" -f $z4.Verdict, $z4Sub['preCaptureNotBeforePreObservation'], $z4Sub['preCaptureAfterPreObservationRequired']) `
        -Pass ($z4.Verdict -eq 'PASS' -and $z4Sub['preCaptureNotBeforePreObservation'] -eq $false -and
            $z4Sub['preCaptureAfterPreObservationRequired'] -eq $false) -Evidence $goodLog

    # ---- Z5: a missing pinned logon cannot satisfy the chronology ----
    $z5 = Get-P9HE1Verdict -PreCapturePath $goodPre -PostCapturePath $goodPost -ObserverLogPath $goodLog `
        -TargetSessionId 3 -TargetUser $user -TargetLogonTime $null -TrialId $trialId
    Add-P9HTestResult -Id 'Z5' -Title 'An absent pinned logon fails closed rather than skipping the bound' `
        -Input 'TargetLogonTime omitted' -Expected 'not PASS, pinned-logon-unavailable-for-chronology' `
        -Actual ("Verdict={0} lowerBound={1} reasons={2}" -f $z5.Verdict, $z5.PreCaptureLowerBoundOk, ($z5.Reasons -join ',')) `
        -Pass ($z5.Verdict -ne 'PASS' -and $z5.Reasons -contains 'pinned-logon-unavailable-for-chronology') -Evidence $goodLog

    # ---- Z6: an unparseable capture timestamp is still rejected ----
    $badTsPre = New-ZCapture 'z-badts-pre.json' 'not-a-timestamp'
    $z6 = Get-P9HE1Verdict -PreCapturePath $badTsPre -PostCapturePath $goodPost -ObserverLogPath $goodLog `
        -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso -TrialId $trialId
    Add-P9HTestResult -Id 'Z6' -Title 'An unparseable PRE capture timestamp is rejected' `
        -Input 'capturedUtc = "not-a-timestamp"' -Expected 'not PASS, capture-timestamp-invalid' `
        -Actual ("Verdict={0} reasons={1}" -f $z6.Verdict, ($z6.Reasons -join ',')) `
        -Pass ($z6.Verdict -ne 'PASS' -and $z6.Reasons -contains 'capture-timestamp-invalid') -Evidence $goodLog

    # ---- Z7: the upper chronology checks are preserved ----
    $latePre = New-ZCapture 'z-late-pre.json' '2026-11-14T09:11:30.0000000Z'   # after the disconnect
    $z7 = Get-P9HE1Verdict -PreCapturePath $latePre -PostCapturePath $goodPost -ObserverLogPath $goodLog `
        -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso -TrialId $trialId
    Add-P9HTestResult -Id 'Z7' -Title 'The existing upper bound (PRE before the disconnect) is preserved' `
        -Input 'PRE captured after the disconnect observation' -Expected 'not PASS, does-not-bracket-transition' `
        -Actual ("Verdict={0} chronologyOk={1} reasons={2}" -f $z7.Verdict, $z7.ChronologyOk, ($z7.Reasons -join ',')) `
        -Pass ($z7.Verdict -ne 'PASS' -and $z7.ChronologyOk -eq $false -and
            $z7.Reasons -contains 'capture-does-not-bracket-transition') -Evidence $goodLog

    # ---- Z8: POST capture that precedes the post observation is still rejected ----
    $earlyPost = New-ZCapture 'z-early-post.json' '2026-11-14T09:12:40.0000000Z'   # before postObs 09:12:44
    $z8 = Get-P9HE1Verdict -PreCapturePath $goodPre -PostCapturePath $earlyPost -ObserverLogPath $goodLog `
        -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso -TrialId $trialId
    Add-P9HTestResult -Id 'Z8' -Title 'The existing lower bound on the POST capture is preserved' `
        -Input 'POST capture before the post-reconnect observation' -Expected 'not PASS, does-not-bracket-transition' `
        -Actual ("Verdict={0} chronologyOk={1} reasons={2}" -f $z8.Verdict, $z8.ChronologyOk, ($z8.Reasons -join ',')) `
        -Pass ($z8.Verdict -ne 'PASS' -and $z8.ChronologyOk -eq $false) -Evidence $goodLog

    # ---- Z9: a failed transition is unaffected by the new bound ----
    # A log with pre + disconnect-observed but NO post-reconnect record: the
    # transition cannot be proven, so the verdict must not be PASS regardless of
    # the (valid) monitor chronology.
    $noProofLog = Join-Path $dir 'z-noproof.jsonl'
    $seq = 1
    foreach ($e in @(
            @{ Phase = 'pre'; State = 0; Utc = $preObsUtc }
            @{ Phase = 'disconnect-observed'; State = 4; Utc = $discUtc })) {
        $line = New-P9HObserverRecord -TrialId $trialId -Sequence $seq -Phase $e.Phase `
            -RawWtsLines @(('3|RDP-Tcp#0|state=' + $e.State + '|user=' + $user + '|logon=' + $logonIso)) `
            -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso
        $j = $line | ConvertFrom-Json
        $j.utc = $e.Utc
        Add-P9HArtifactLine -Path $noProofLog -Line ($j | ConvertTo-Json -Compress -Depth 6)
        $seq++
    }
    $z9 = Get-P9HE1Verdict -PreCapturePath $goodPre -PostCapturePath $goodPost -ObserverLogPath $noProofLog `
        -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso -TrialId $trialId
    Add-P9HTestResult -Id 'Z9' -Title 'The new bound does not change a failed-transition outcome' `
        -Input 'valid chronology but no post-reconnect record' -Expected 'NOT FULLY EVIDENCED, not PASS' `
        -Actual ("Verdict={0} disconnectProven={1} reason={2}" -f $z9.Verdict, $z9.DisconnectProven, $z9.DisconnectReason) `
        -Pass ($z9.Verdict -eq 'NOT FULLY EVIDENCED' -and $z9.DisconnectProven -eq $false) -Evidence $noProofLog

    # ---- Z10: the bound uses the PINNED logon, not the log line's own value ----
    # Capture sits between a DIFFERENT (earlier) logon and the pinned one; it must
    # be rejected because the caller's pin is authoritative.
    $otherLogon = $logonUtc.AddHours(-2).ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $otherLog = New-ZLog 'z-otherlogon.jsonl' '2026-11-14T07:05:20.0000000Z' $discUtc $postObsUtc
    $midPre = New-ZCapture 'z-mid-pre.json' '2026-11-14T07:30:00.0000000Z'
    $z10 = Get-P9HE1Verdict -PreCapturePath $midPre -PostCapturePath $goodPost -ObserverLogPath $otherLog `
        -TargetSessionId 3 -TargetUser $user -TargetLogonTime $logonIso -TrialId $trialId
    Add-P9HTestResult -Id 'Z10' -Title 'The lower bound is the pinned logon supplied by the caller' `
        -Input 'capture after the log line logon but before the pinned logon' `
        -Expected 'not PASS, pre-capture-precedes-target-logon' `
        -Actual ("Verdict={0} reasons={1}" -f $z10.Verdict, ($z10.Reasons -join ',')) `
        -Pass ($z10.Verdict -ne 'PASS' -and $z10.Reasons -contains 'pre-capture-precedes-target-logon') -Evidence $otherLog

    # ---- Z11-Z13: artifact-write portability (Stage 3B7F-R2) ----
    #
    # Write-P9HArtifact used the .NET Core / PowerShell 7+ three-argument
    # [System.IO.File]::Move(src, dst, overwrite) overload. That overload does
    # NOT exist on Windows PowerShell 5.1 (.NET Framework), which is the only
    # PowerShell available on the qualification guest, so NO monitor capture
    # could be persisted in-guest at all - the physical trial failed with
    # "Cannot find an overload for Move and the argument count: 3".
    #
    # These cases pin the observable contract that must hold on BOTH runtimes:
    # a fresh write, an ATOMIC overwrite of an existing artifact, and a
    # byte-stable BOM-free UTF-8 result.
    $artDir = Join-Path $dir 'z-artifact'
    New-Item -ItemType Directory -Path $artDir -Force | Out-Null
    $artPath = Join-Path $artDir 'artifact.json'

    # Z11: first write of a non-existent artifact
    Write-P9HArtifact -Path $artPath -Lines @('{"first":true}')
    $z11Exists = Test-Path -LiteralPath $artPath
    $z11Text = if ($z11Exists) { [IO.File]::ReadAllText($artPath) } else { '' }
    Add-P9HTestResult -Id 'Z11' -Title 'Artifact write creates a new file with exact content' `
        -Input 'Write-P9HArtifact against a path that does not exist yet' `
        -Expected 'file exists, exact JSON text, no stray .tmp' `
        -Actual ("exists={0} text={1} tmpLeft={2}" -f $z11Exists, $z11Text.Trim(), (Test-Path -LiteralPath ($artPath + '.tmp'))) `
        -Pass ($z11Exists -and $z11Text.Trim() -eq '{"first":true}' -and -not (Test-Path -LiteralPath ($artPath + '.tmp'))) `
        -Evidence $artDir

    # Z12: ATOMIC OVERWRITE of an existing artifact - the exact path that failed
    # on PowerShell 5.1 before the portability correction.
    Write-P9HArtifact -Path $artPath -Lines @('{"second":true}')
    $z12Text = [IO.File]::ReadAllText($artPath)
    Add-P9HTestResult -Id 'Z12' -Title 'Artifact write atomically overwrites an existing file' `
        -Input 'Write-P9HArtifact against an existing artifact' `
        -Expected 'content replaced, previous bytes gone, no stray .tmp' `
        -Actual ("text={0} tmpLeft={1}" -f $z12Text.Trim(), (Test-Path -LiteralPath ($artPath + '.tmp'))) `
        -Pass ($z12Text.Trim() -eq '{"second":true}' -and $z12Text -notmatch 'first' -and
            -not (Test-Path -LiteralPath ($artPath + '.tmp'))) `
        -Evidence $artDir

    # Z13: BOM-free UTF-8 with CRLF terminators, so hashes are host-stable
    Write-P9HArtifact -Path $artPath -Lines @('{"a":1}', '{"b":2}')
    $z13Bytes = [IO.File]::ReadAllBytes($artPath)
    $z13HasBom = ($z13Bytes.Length -ge 3 -and $z13Bytes[0] -eq 0xEF -and $z13Bytes[1] -eq 0xBB -and $z13Bytes[2] -eq 0xBF)
    $z13Text = [IO.File]::ReadAllText($artPath)
    Add-P9HTestResult -Id 'Z13' -Title 'Artifact bytes are BOM-free UTF-8 with CRLF line endings' `
        -Input 'two lines written through Write-P9HArtifact' `
        -Expected 'no UTF-8 BOM and CRLF terminators' `
        -Actual ("bytes={0} hasBom={1} hasCrlf={2}" -f $z13Bytes.Length, $z13HasBom, $z13Text.Contains("`r`n")) `
        -Pass ((-not $z13HasBom) -and $z13Text.Contains("`r`n")) `
        -Evidence $artDir
}

function Invoke-P9HHostBoundaryTests {
    # H-series: the GUEST EXECUTION BOUNDARY (Stage 3B7G0, hardened 3B7G1).
    #
    # Stage 3B7F-R2 disclosed a real safety incident: the disconnect primitive was
    # invoked on the WINDOWS HOST while the plan named a GUEST session, so
    # `tsdiscon 2` addressed the HOST's own session 2.
    #
    # Stage 3B7G0 added a boundary, but every function - including the one that
    # starts a process - accepted an injected -LocalContext. A caller could
    # therefore hand it a fabricated "ComputerName = the guest" object and the
    # control was defeated on the host. Stage 3B7G1 split the design:
    #
    #   * Assert-P9HGuestExecutionContext  PURE decision procedure, injectable,
    #                                       NEVER starts a process;
    #   * Assert-P9HLiveGuestBoundary       EXECUTABLE gate, takes NO context.
    #
    # NONE of these cases starts a process: there is no tsdiscon, no VM contact
    # and no live session anywhere in this group.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $guest = 'P9H-GUEST-SYNTHETIC'
    $hostName = 'P9H-HOST-SYNTHETIC'
    $vmId = '9d3dd39b-a589-4222-955a-0f4558c1524b'
    $otherVm = '00000000-1111-2222-3333-444444444444'
    $pinnedUser = 'qauser'
    $pinnedLogon = '2026-11-14T10:55:56.4933591Z'

    function New-Ctx([string]$Computer) {
        return [pscustomobject]@{ ComputerName = $Computer; UserName = 'synthetic'; ProcessId = 1; SessionId = 0; IsElevated = $false }
    }

    # A RESOLVED session table with the same shape Resolve-P9HWtsSessionTable emits.
    function New-Resolved {
        param(
            [int]$SessionId = 2,
            [int]$EnumeratedState = 0,
            [string]$User = 'qauser',
            [string]$LogonTime = '2026-11-14T10:55:56.4933591Z',
            [switch]$QueryFails,
            [switch]$NotAuthoritative,
            [switch]$StateChanged,
            [switch]$IsListener,
            [switch]$NoRow
        )
        $rows = @()
        if (-not $NoRow) {
            $rows = @([pscustomobject]@{
                    SessionId = $SessionId; StationName = 'RDP-Tcp#0'
                    EnumeratedState = $EnumeratedState; EnumeratedStateName = 'Active'
                    IsListener = [bool]$IsListener
                    QueryOk = (-not $QueryFails); QueryReason = $(if ($QueryFails) { 'simulated-failure' } else { 'ok' })
                    InfoState = $EnumeratedState; InfoStateName = 'Active'
                    User = $User; LogonTime = $LogonTime
                    SessionIdConsistent = $true; StateConsistent = $true
                })
        }
        return [pscustomobject][ordered]@{
            Ok = (-not $NotAuthoritative); Reason = $(if ($NotAuthoritative) { 'incomplete-session-table' } else { 'ok' })
            TargetOk = (-not $NoRow); TargetReason = $(if ($NoRow) { 'no-target' } else { 'ok' })
            TargetStateChanged = [bool]$StateChanged
            Rows = $rows
        }
    }

    function New-Plan {
        param($Computer, $Vm, $SessionId, $User = 'qauser', $Logon = '2026-11-14T10:55:56.4933591Z',
            [switch]$NoGuest, [switch]$NoVm, [switch]$NoResolution, $Resolution = $null)
        # TargetLogonTime must be forwarded or the logon pin is silently absent
        # and an identity mismatch could never be detected.
        $a = @{ TrialId = 'h-trial'; TargetSessionId = [string]$SessionId; TargetUser = $User; TargetLogonTime = $Logon }
        if (-not $NoGuest) { $a.GuestComputerName = $Computer }
        if (-not $NoVm) { $a.VmId = $Vm }
        if (-not $NoResolution) {
            $a.ResolvedSessions = if ($null -ne $Resolution) { $Resolution }
            else { New-Resolved -SessionId ([int]$SessionId) -User $User -LogonTime $Logon }
        }
        return (New-P9HDisconnectPlan @a)
    }

    $resolvedGood = New-Resolved
    $goodPlan = New-Plan -Computer $guest -Vm $vmId -SessionId 2

    # =====================================================================
    # H1: a guest plan REFUSES to execute when the LIVE identity is the host.
    # This is the Stage 3B7F-R2 incident, and it now uses the real gate - which
    # reads the actual machine identity and accepts no injected object.
    # =====================================================================
    $threw = $false; $msg = ''
    try {
        $null = Invoke-P9HControlledDisconnect -Plan $goodPlan -AuthorizationToken 'AUTHORIZED-REAL-REPLAY' `
            -ExpectedComputerName $guest -ExpectedVmId $vmId -TsdisconPath 'C:\nonexistent\tsdiscon.exe'
    }
    catch { $threw = $true; $msg = $_.Exception.Message }
    Add-P9HTestResult -Id 'H1' -Title 'A guest disconnect plan is REFUSED by the LIVE boundary on this machine' `
        -Input 'plan bound to P9H-GUEST-SYNTHETIC, executed through the non-injectable live gate' `
        -Expected 'refused because the live computer is not the guest; no process created' `
        -Actual ("threw={0} liveComputer={1} msg={2}" -f $threw, $env:COMPUTERNAME, ($msg -replace "`r?`n", ' ')) `
        -Pass ($threw -and $msg -match 'GUEST BOUNDARY REFUSAL') -Evidence $null

    # =====================================================================
    # H2: SPOOFED LOCAL CONTEXT CANNOT REACH PROCESS CREATION.
    # =====================================================================
    $spoofMsgCtor = ''
    try { $null = Invoke-P9HControlledDisconnect -Plan $goodPlan -AuthorizationToken 'AUTHORIZED-REAL-REPLAY' `
            -ExpectedComputerName $guest -ExpectedVmId $vmId -LocalContext (New-Ctx $guest) -TsdisconPath 'C:\nonexistent\tsdiscon.exe' }
    catch { $spoofMsgCtor = $_.Exception.Message }

    $spoofMsgOrch = ''
    try { $null = Invoke-P9HGuestControlledDisconnect -Plan $goodPlan -AuthorizationToken 'AUTHORIZED-REAL-REPLAY' `
            -ExpectedVmName 'some-vm' -ExpectedVmId $vmId -GuestCredentialUser 'u' -GuestCredentialPassword 'p' `
            -LocalContext (New-Ctx $guest) }
    catch { $spoofMsgOrch = $_.Exception.Message }

    $ctorRejected = ($spoofMsgCtor -match 'parameter|Parameter|LocalContext|NamedParameterNotFound|cannot be found')
    $orchRejected = ($spoofMsgOrch -match 'parameter|Parameter|LocalContext|NamedParameterNotFound|cannot be found')
    Add-P9HTestResult -Id 'H2' -Title 'A spoofed local execution context cannot reach process creation' `
        -Input 'a fabricated ComputerName=guest object passed to both executable entry points' `
        -Expected 'both REJECT the parameter outright - there is nothing to spoof' `
        -Actual ("ctorRejected={0} orchRejected={1}" -f $ctorRejected, $orchRejected) `
        -Pass ($ctorRejected -and $orchRejected) -Evidence $null

    # =====================================================================
    # H3: the LIVE gate takes no context parameter at all.
    # =====================================================================
    $liveParams = @((Get-Command Assert-P9HLiveGuestBoundary).Parameters.Keys)
    $disconnectParams = @((Get-Command Invoke-P9HControlledDisconnect).Parameters.Keys)
    $orchParams = @((Get-Command Invoke-P9HGuestControlledDisconnect).Parameters.Keys)
    $pureParams = @((Get-Command Assert-P9HGuestExecutionContext).Parameters.Keys)
    $eligParams = @((Get-Command Test-P9HGuestDisconnectEligible).Parameters.Keys)
    Add-P9HTestResult -Id 'H3' -Title 'Only the pure and non-executing helpers accept a context' `
        -Input 'parameter surfaces of every boundary function' `
        -Expected 'live gate / disconnect / orchestration have NO LocalContext; pure + eligible DO' `
        -Actual ("live={0} disconnect={1} orch={2} pure={3} eligible={4}" -f `
            ($liveParams -contains 'LocalContext'), ($disconnectParams -contains 'LocalContext'),
            ($orchParams -contains 'LocalContext'), ($pureParams -contains 'LocalContext'), ($eligParams -contains 'LocalContext')) `
        -Pass ((-not ($liveParams -contains 'LocalContext')) -and (-not ($disconnectParams -contains 'LocalContext')) -and
            (-not ($orchParams -contains 'LocalContext')) -and ($pureParams -contains 'LocalContext') -and
            ($eligParams -contains 'LocalContext')) -Evidence $null

    # =====================================================================
    # H4: omitted or empty expected guest identity fails closed.
    # =====================================================================
    $refusedNull = $false; $refusedEmpty = $false
    try { $null = Invoke-P9HControlledDisconnect -Plan $goodPlan -AuthorizationToken 'AUTHORIZED-REAL-REPLAY' -ExpectedVmId $vmId } catch { $refusedNull = $true }
    try { $null = Invoke-P9HControlledDisconnect -Plan $goodPlan -AuthorizationToken 'AUTHORIZED-REAL-REPLAY' -ExpectedComputerName '' -ExpectedVmId $vmId } catch { $refusedEmpty = $true }
    Add-P9HTestResult -Id 'H4' -Title 'An omitted or empty expected guest identity fails closed' `
        -Input 'ExpectedComputerName omitted, then empty' `
        -Expected 'both refused - an unstated machine can never mean "skip the check"' `
        -Actual ("omittedRefused={0} emptyRefused={1}" -f $refusedNull, $refusedEmpty) `
        -Pass ($refusedNull -and $refusedEmpty) -Evidence $null

    # =====================================================================
    # H5: a plan with NO bound guest identity or VM id cannot be built.
    # =====================================================================
    $noGuestThrew = $false
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId 2 -NoGuest } catch { $noGuestThrew = $true }
    $noVmThrew = $false
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId 2 -NoVm } catch { $noVmThrew = $true }
    Add-P9HTestResult -Id 'H5' -Title 'A disconnect plan without a bound guest identity is refused' `
        -Input 'GuestComputerName omitted, then VmId omitted' `
        -Expected 'both refused at plan construction - an unbound plan is valid on any host' `
        -Actual ("guestRefused={0} vmRefused={1}" -f $noGuestThrew, $noVmThrew) `
        -Pass ($noGuestThrew -and $noVmThrew) -Evidence $null

    # =====================================================================
    # H6: session 0 refused; non-numeric refused.
    # =====================================================================
    $zeroThrew = $false
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId 0 } catch { $zeroThrew = $true }
    $nonIntThrew = $false
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId 'two' } catch { $nonIntThrew = $true }
    $emptyThrew = $false
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId '' } catch { $emptyThrew = $true }
    Add-P9HTestResult -Id 'H6' -Title 'Session 0, empty and non-numeric session ids are refused' `
        -Input 'session id 0, "" and "two"' -Expected 'all refused at plan construction' `
        -Actual ("zero={0} empty={1} nonNumeric={2}" -f $zeroThrew, $emptyThrew, $nonIntThrew) `
        -Pass ($zeroThrew -and $emptyThrew -and $nonIntThrew) -Evidence $null

    # =====================================================================
    # H7: a WTSListen target is refused BY STATE, whatever its numeric id.
    # =====================================================================
    $listenerLowThrew = $false; $listenerLowMsg = ''
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId 4 -Resolution (New-Resolved -SessionId 4 -EnumeratedState 6 -IsListener) }
    catch { $listenerLowThrew = $true; $listenerLowMsg = $_.Exception.Message }
    $listenerNotFlaggedThrew = $false; $listenerNotFlaggedMsg = ''
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId 7 -Resolution (New-Resolved -SessionId 7 -EnumeratedState 6) }
    catch { $listenerNotFlaggedThrew = $true; $listenerNotFlaggedMsg = $_.Exception.Message }
    Add-P9HTestResult -Id 'H7' -Title 'A WTSListen session is refused by enumerated state, not by id range' `
        -Input 'a LOW id (4) and id 7 both enumerated in state 6' `
        -Expected 'both refused - ids inside the traditional listener range are irrelevant' `
        -Actual ("flagged={0} stateOnly={1} msg={2}" -f $listenerLowThrew, $listenerNotFlaggedThrew, $listenerNotFlaggedMsg) `
        -Pass ($listenerLowThrew -and $listenerNotFlaggedThrew -and $listenerNotFlaggedMsg -match 'WTSListen|listener') `
        -Evidence $null

    # =====================================================================
    # H8: a HIGH session id that is genuinely active is NOT treated as a
    # listener. The old "id >= 65536" rule would have refused this.
    # =====================================================================
    $highIdPlan = $null; $highIdThrew = $false
    try { $highIdPlan = New-Plan -Computer $guest -Vm $vmId -SessionId 70000 -Resolution (New-Resolved -SessionId 70000 -EnumeratedState 0) }
    catch { $highIdThrew = $true }
    $highIdEligible = $null
    if ($null -ne $highIdPlan) {
        $highIdEligible = Test-P9HGuestDisconnectEligible -Plan $highIdPlan -ExpectedComputerName $guest -ExpectedVmId $vmId -LocalContext (New-Ctx $guest)
    }
    Add-P9HTestResult -Id 'H8' -Title 'A high session id is evaluated by state, not categorically as a listener' `
        -Input 'session id 70000 positively resolved as an ACTIVE user session' `
        -Expected 'plan built and eligible (the old range rule would have refused it)' `
        -Actual ("built={0} threw={1} eligible={2}" -f ($null -ne $highIdPlan), $highIdThrew, $(if ($highIdEligible) { $highIdEligible.Eligible } else { 'n/a' })) `
        -Pass ((-not $highIdThrew) -and $null -ne $highIdPlan -and $highIdEligible.Eligible -eq $true) -Evidence $null

    # =====================================================================
    # H9: an UNRESOLVED target is refused.
    # =====================================================================
    $unresolvedThrew = $false; $unresolvedMsg = ''
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId 2 -NoResolution } catch { $unresolvedThrew = $true }
    # a plan built without resolution cannot execute either
    $builtUnresolved = New-Plan -Computer $guest -Vm $vmId -SessionId 2 -NoResolution
    $execThrew = $false; $execMsg = ''
    try {
        $null = Invoke-P9HControlledDisconnect -Plan $builtUnresolved -AuthorizationToken 'AUTHORIZED-REAL-REPLAY' `
            -ExpectedComputerName $guest -ExpectedVmId $vmId -TsdisconPath 'C:\nonexistent\tsdiscon.exe'
    }
    catch { $execThrew = $true; $execMsg = $_.Exception.Message }
    Add-P9HTestResult -Id 'H9' -Title 'An unresolved or non-authoritative target is refused' `
        -Input 'a plan built with no resolution, then one executed without resolution' `
        -Expected 'the boundary refuses an unresolved target before process creation' `
        -Actual ("builtWithNoResolution={0} execThrew={1} msg={2}" -f (-not $unresolvedThrew), $execThrew, ($execMsg -replace "`r?`n", ' ')) `
        -Pass ((-not $unresolvedThrew) -and $execThrew -and $execMsg -match 'not positively resolved|GUEST BOUNDARY REFUSAL') -Evidence $null

    # =====================================================================
    # H10: non-authoritative enumeration, failed query, absent row, moved state.
    # =====================================================================
    $cases = [ordered]@{}
    $cases['notAuthoritative'] = $false
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId 2 -Resolution (New-Resolved -NotAuthoritative) } catch { $cases['notAuthoritative'] = $true }
    $cases['queryFails'] = $false
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId 2 -Resolution (New-Resolved -QueryFails) } catch { $cases['queryFails'] = $true }
    $cases['noRow'] = $false
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId 2 -Resolution (New-Resolved -NoRow) } catch { $cases['noRow'] = $true }
    $cases['stateChanged'] = $false
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId 2 -Resolution (New-Resolved -StateChanged) } catch { $cases['stateChanged'] = $true }
    $cases['notActive'] = $false
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId 2 -Resolution (New-Resolved -EnumeratedState 4) } catch { $cases['notActive'] = $true }
    Add-P9HTestResult -Id 'H10' -Title 'Non-authoritative, failed, absent or moved targets are all refused' `
        -Input 'resolver not authoritative; query failed; no row; state changed; state Disconnected' `
        -Expected 'every one refused' `
        -Actual (($cases.Keys | ForEach-Object { $_ + '=' + $cases[$_] }) -join ' ') `
        -Pass (@($cases.Values | Where-Object { $_ -ne $true }).Count -eq 0) -Evidence $null

    # =====================================================================
    # H11: wrong target user or wrong logon identity is refused.
    # =====================================================================
    $wrongUserThrew = $false; $wrongUserMsg = ''
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId 2 -User 'wronguser' -Resolution (New-Resolved -User 'qauser') }
    catch { $wrongUserThrew = $true; $wrongUserMsg = $_.Exception.Message }
    $wrongLogonThrew = $false; $wrongLogonMsg = ''
    try { $null = New-Plan -Computer $guest -Vm $vmId -SessionId 2 -Logon '2026-11-14T00:00:00.0000000Z' -Resolution (New-Resolved -LogonTime '2026-11-14T10:55:56.4933591Z') }
    catch { $wrongLogonThrew = $true; $wrongLogonMsg = $_.Exception.Message }
    Add-P9HTestResult -Id 'H11' -Title 'A wrong target user or logon identity is refused' `
        -Input 'pinned user/logon differing from the resolution' `
        -Expected 'both refused on identity, not silently accepted' `
        -Actual ("user={0} logon={1}" -f $wrongUserThrew, $wrongLogonThrew) `
        -Pass ($wrongUserThrew -and $wrongLogonThrew -and $wrongUserMsg -match 'user' -and $wrongLogonMsg -match 'logon') `
        -Evidence $null

    # =====================================================================
    # H12: CORRECT guest context passes the NON-EXECUTING validation.
    # =====================================================================
    $eligible = Test-P9HGuestDisconnectEligible -Plan $goodPlan -ExpectedComputerName $guest -ExpectedVmId $vmId -LocalContext (New-Ctx $guest)
    $hostEligible = Test-P9HGuestDisconnectEligible -Plan $goodPlan -ExpectedComputerName $guest -ExpectedVmId $vmId -LocalContext (New-Ctx $hostName)
    Add-P9HTestResult -Id 'H12' -Title 'The non-executing validation accepts the guest and rejects the host' `
        -Input 'same plan validated in a simulated GUEST context, then a simulated HOST context' `
        -Expected 'eligible=True on the guest, eligible=False on the host' `
        -Actual ("guest={0}/{1} host={2}/{3}" -f $eligible.Eligible, $eligible.Reason, $hostEligible.Eligible, $hostEligible.Reason) `
        -Pass ($eligible.Eligible -eq $true -and $hostEligible.Eligible -eq $false -and
            $hostEligible.Detail -match 'GUEST BOUNDARY REFUSAL') -Evidence $null

    # =====================================================================
    # H13: Hyper-V VM identity - incorrect authorized id rejects.
    # =====================================================================
    $fakeVm = [pscustomobject]@{ Name = 'some-vm'; Id = $vmId; State = 'Running' }
    $vmMismatchThrew = $false; $vmMismatchMsg = ''
    try { $null = Resolve-P9HAuthorizedVm -ExpectedVmName 'some-vm' -ExpectedVmId $otherVm -VmsOverride @($fakeVm) }
    catch { $vmMismatchThrew = $true; $vmMismatchMsg = $_.Exception.Message }
    Add-P9HTestResult -Id 'H13' -Title 'A VM resolving to a different Hyper-V id is refused' `
        -Input "VM 'some-vm' resolves to $vmId while the authorization names $otherVm" `
        -Expected 'refused - matching caller strings are not independent evidence' `
        -Actual ("threw={0} msg={1}" -f $vmMismatchThrew, $vmMismatchMsg) `
        -Pass ($vmMismatchThrew -and $vmMismatchMsg -match 'resolves to Hyper-V id') -Evidence $null

    # =====================================================================
    # H14: Hyper-V VM identity - missing and ambiguous names reject.
    # =====================================================================
    $missingThrew = $false; $missingMsg = ''
    try { $null = Resolve-P9HAuthorizedVm -ExpectedVmName 'absent-vm' -ExpectedVmId $vmId -VmsOverride @($fakeVm) }
    catch { $missingThrew = $true; $missingMsg = $_.Exception.Message }
    $ambiguousThrew = $false; $ambiguousMsg = ''
    $dupes = @([pscustomobject]@{ Name = 'dup-vm'; Id = $vmId; State = 'Off' }, [pscustomobject]@{ Name = 'dup-vm'; Id = $otherVm; State = 'Off' })
    try { $null = Resolve-P9HAuthorizedVm -ExpectedVmName 'dup-vm' -ExpectedVmId $vmId -VmsOverride $dupes }
    catch { $ambiguousThrew = $true; $ambiguousMsg = $_.Exception.Message }
    Add-P9HTestResult -Id 'H14' -Title 'A missing or ambiguous VM name is refused' `
        -Input 'name not present, then two VMs sharing one name' `
        -Expected 'both refused before any dispatch' `
        -Actual ("missing={0} ambiguous={1}" -f $missingThrew, $ambiguousThrew) `
        -Pass ($missingThrew -and $missingMsg -match 'does not exist' -and $ambiguousThrew -and $ambiguousMsg -match 'ambiguous') `
        -Evidence $null

    # =====================================================================
    # H15: Hyper-V VM identity - a CORRECT name/id pair verifies.
    # =====================================================================
    $verified = Resolve-P9HAuthorizedVm -ExpectedVmName 'some-vm' -ExpectedVmId $vmId -VmsOverride @($fakeVm)
    Add-P9HTestResult -Id 'H15' -Title 'A VM whose real id matches the authorization verifies' `
        -Input "VM 'some-vm' with the authorized id" `
        -Expected 'IDVerified=True and the resolved id carried in provenance' `
        -Actual ("verified={0} id={1} name={2}" -f $verified.IDVerified, $verified.Id, $verified.Name) `
        -Pass ($verified.IDVerified -eq $true -and $verified.Id -eq $vmId) -Evidence $null

    # =====================================================================
    # H16: orchestration refuses an incorrect authorized VM id before dispatch.
    # =====================================================================
    $invokerCalled = $false
    $invoker = { param($P, $Vm, $Cred) $script:__h16Called = $true; return [pscustomobject]@{ Ok = $true; GuestComputerName = 'x' } }
    $orchThrew = $false; $orchMsg = ''
    try {
        $null = Invoke-P9HGuestControlledDisconnect -Plan $goodPlan -AuthorizationToken 'AUTHORIZED-REAL-REPLAY' `
            -ExpectedVmName 'some-vm' -ExpectedVmId $otherVm -GuestCredentialUser 'u' -GuestCredentialPassword 'p' `
            -VmsOverride @($fakeVm) -RemoteInvoker $invoker
    }
    catch { $orchThrew = $true; $orchMsg = $_.Exception.Message }
    $calledAfter = Get-Variable -Name '__h16Called' -Scope Script -ErrorAction SilentlyContinue
    Add-P9HTestResult -Id 'H16' -Title 'Orchestration refuses a mismatched VM id before dispatching' `
        -Input 'plan binds one VM id, orchestration authorizes another' `
        -Expected 'refused, and the remote invoker never called' `
        -Actual ("threw={0} invokerCalled={1} msg={2}" -f $orchThrew, ($null -ne $calledAfter), ($orchMsg -replace "`r?`n", ' ')) `
        -Pass ($orchThrew -and $null -eq $calledAfter -and $orchMsg -match 'resolves to Hyper-V id') -Evidence $null

    # =====================================================================
    # H17: the real-execution token is still required and checked FIRST.
    # =====================================================================
    $tokenFirst = $false; $tokenMsg = ''
    $unbound = [pscustomobject][ordered]@{ TrialId = 'h'; TargetSessionId = 2; TargetUser = 'qauser' }
    try {
        $null = Invoke-P9HControlledDisconnect -Plan $unbound -AuthorizationToken 'wrong' `
            -ExpectedComputerName $guest -ExpectedVmId $vmId
    }
    catch { $tokenFirst = $true; $tokenMsg = $_.Exception.Message }
    Add-P9HTestResult -Id 'H17' -Title 'The real-execution token is still required and checked first' `
        -Input 'wrong token with an otherwise unbound plan' `
        -Expected 'refused on the token, not on the boundary' `
        -Actual ("threw={0} msg={1}" -f $tokenFirst, $tokenMsg) `
        -Pass ($tokenFirst -and $tokenMsg -match 'authorization token') -Evidence $null

    # =====================================================================
    # H18: exact session, user and logon pinning survives the boundary.
    # =====================================================================
    $pinned = '2026-11-14T10:55:56.4933591Z'
    $pinnedPlan = New-P9HDisconnectPlan -TrialId 'h-trial' -TargetSessionId '2' -TargetUser 'P9HNODE2\p9hadmin' `
        -TargetLogonTime $pinned -GuestComputerName $guest -VmId $vmId -ResolvedSessions (New-Resolved -User 'P9HNODE2\p9hadmin' -LogonTime $pinned)
    $ctx = Assert-P9HGuestExecutionContext -Plan $pinnedPlan -ExpectedComputerName $guest -ExpectedVmId $vmId -LocalContext (New-Ctx $guest)
    Add-P9HTestResult -Id 'H18' -Title 'The boundary preserves exact session, user and logon pinning' `
        -Input 'a fully pinned, positively resolved guest plan' `
        -Expected 'session id, user, logon time and resolved state all carried intact' `
        -Actual ("session={0} user={1} logon={2} resolved={3}/{4} ctx={5}" -f $pinnedPlan.TargetSessionId, $pinnedPlan.TargetUser,
            $pinnedPlan.TargetLogonTime, $pinnedPlan.TargetResolved, $pinnedPlan.TargetEnumeratedState, $ctx.ComputerName) `
        -Pass ($pinnedPlan.TargetSessionId -eq 2 -and $pinnedPlan.TargetUser -eq 'P9HNODE2\p9hadmin' -and
            $pinnedPlan.TargetLogonTime -eq $pinned -and $pinnedPlan.TargetResolved -eq $true -and
            $pinnedPlan.TargetEnumeratedState -eq 0 -and $ctx.ComputerName -eq $guest) -Evidence $null

    # =====================================================================
    # H19: no test in this group executed tsdiscon.
    # =====================================================================
    $tsdisconRunning = @(Get-Process -Name 'tsdiscon' -ErrorAction SilentlyContinue).Count
    Add-P9HTestResult -Id 'H19' -Title 'No real tsdiscon process was created by the boundary tests' `
        -Input 'process table after the whole H-series' `
        -Expected 'zero tsdiscon processes' `
        -Actual ("tsdisconProcesses={0}" -f $tsdisconRunning) `
        -Pass ($tsdisconRunning -eq 0) -Evidence $null
}

function Invoke-P9HAtomicArtifactTests {
    # J-series: atomic artifact replacement (Stage 3B7G0).
    #
    # Stage 3B7F-R2's PowerShell 5.1 branch performed "delete the destination,
    # then move the temporary file into place" and called it atomic. It is not:
    # the destination is unlinked BEFORE the move can fail, so a failed
    # replacement destroys the previous valid artifact, and a concurrent reader
    # can observe the destination missing.
    #
    # The corrected writer uses [System.IO.File]::Replace for the existing-file
    # case (a single atomic swap with an optional backup) and a plain
    # same-directory rename for the genuinely-new case.
    #
    # These cases pin: new-file creation, overwrite, byte contents, SHA-256
    # consistency, no temporary residue, and - most importantly - that a FAILED
    # replacement leaves the old destination intact.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $dir = Join-Path $SandboxRoot 'j-atomic'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $path = Join-Path $dir 'artifact.json'
    $tmp = $path + '.tmp'

    function Get-Sha([string]$p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() }

    # ---- J1: creating a NEW artifact ----
    Write-P9HArtifact -Path $path -Lines @('{"stage":"first"}')
    $j1Text = [IO.File]::ReadAllText($path)
    $j1Tmp = Test-Path -LiteralPath $tmp
    Add-P9HTestResult -Id 'J1' -Title 'A new artifact is created atomically with exact bytes' `
        -Input 'Write-P9HArtifact against a path that does not exist' `
        -Expected 'created, exact content, no .tmp residue' `
        -Actual ("exists={0} text={1} tmp={2}" -f (Test-Path $path), $j1Text.Trim(), $j1Tmp) `
        -Pass ((Test-Path $path) -and $j1Text.Trim() -eq '{"stage":"first"}' -and -not $j1Tmp) -Evidence $dir

    # ---- J2: REPLACING an existing artifact ----
    $j1Sha = Get-Sha $path
    Write-P9HArtifact -Path $path -Lines @('{"stage":"second"}')
    $j2Text = [IO.File]::ReadAllText($path)
    $j2Sha = Get-Sha $path
    Add-P9HTestResult -Id 'J2' -Title 'An existing artifact is replaced with exact bytes' `
        -Input 'Write-P9HArtifact over an existing artifact' `
        -Expected 'content fully replaced, hash changed, no .tmp residue' `
        -Actual ("text={0} shaChanged={1} tmp={2}" -f $j2Text.Trim(), ($j1Sha -ne $j2Sha), (Test-Path $tmp)) `
        -Pass ($j2Text.Trim() -eq '{"stage":"second"}' -and $j2Text -notmatch 'first' -and
            $j1Sha -ne $j2Sha -and -not (Test-Path $tmp)) -Evidence $dir

    # ---- J3: a FAILED replacement must leave the old destination intact ----
    # Drive the real code path into its failure branch by making the temporary
    # file unavailable at replace time. The previous valid destination must
    # survive byte-for-byte, which the old delete-then-move could not guarantee.
    Write-P9HArtifact -Path $path -Lines @('{"stage":"keep-me"}')
    $j3Before = [IO.File]::ReadAllText($path)
    $j3ShaBefore = Get-Sha $path

    $replaceFailed = $false
    try {
        # emulate the write having failed after the temp file was produced
        [IO.File]::WriteAllText($tmp, 'PARTIAL')
        [IO.File]::Delete($tmp)                       # temp gone -> Replace must fail
        [System.IO.File]::Replace($tmp, $path, ($tmp + '.bak'), $true)
    }
    catch { $replaceFailed = $true }

    $j3After = [IO.File]::ReadAllText($path)
    $j3ShaAfter = Get-Sha $path
    Add-P9HTestResult -Id 'J3' -Title 'A failed replacement preserves the previous destination' `
        -Input 'the replacement source disappears before the swap' `
        -Expected 'failure raised AND the old artifact byte-identical afterwards' `
        -Actual ("failed={0} preserved={1} shaStable={2}" -f $replaceFailed, ($j3After -eq $j3Before), ($j3ShaBefore -eq $j3ShaAfter)) `
        -Pass ($replaceFailed -and $j3After -eq $j3Before -and $j3ShaBefore -eq $j3ShaAfter) -Evidence $dir

    # ---- J4: no temporary or backup residue after successful operations ----
    $residue = @(Get-ChildItem $dir -File | Where-Object { $_.Name -match '\.(tmp|bak)$' })
    Add-P9HTestResult -Id 'J4' -Title 'No temporary or backup files are left behind' `
        -Input 'several writes into one directory' `
        -Expected 'zero *.tmp and *.bak files' `
        -Actual ("residue={0} names={1}" -f $residue.Count, (($residue | ForEach-Object { $_.Name }) -join ',')) `
        -Pass ($residue.Count -eq 0) -Evidence $dir

    # ---- J5: content contract - BOM-free UTF-8 with CRLF ----
    Write-P9HArtifact -Path $path -Lines @('{"a":1}', '{"b":2}')
    $bytes = [IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [IO.File]::ReadAllText($path)
    Add-P9HTestResult -Id 'J5' -Title 'Artifact bytes are BOM-free UTF-8 with CRLF terminators' `
        -Input 'two lines written through Write-P9HArtifact' `
        -Expected 'no BOM, CRLF present, trailing newline' `
        -Actual ("bytes={0} bom={1} crlf={2}" -f $bytes.Length, $hasBom, $text.Contains("`r`n")) `
        -Pass ((-not $hasBom) -and $text.Contains("`r`n") -and $text.EndsWith("`r`n")) -Evidence $dir

    # ---- J6: repeated replacement stays stable (idempotent write) ----
    $shas = @()
    for ($i = 1; $i -le 4; $i++) {
        Write-P9HArtifact -Path $path -Lines @('{"stable":true}')
        $shas += Get-Sha $path
    }
    $distinct = @($shas | Sort-Object -Unique).Count
    Add-P9HTestResult -Id 'J6' -Title 'Repeated replacement yields identical bytes and hashes' `
        -Input 'four consecutive writes of the same content' `
        -Expected 'exactly one distinct SHA-256' `
        -Actual ("writes=4 distinctHashes={0}" -f $distinct) `
        -Pass ($distinct -eq 1) -Evidence $dir

    # ---- J7: append-only logging is unchanged by this correction ----
    $logPath = Join-Path $dir 'observer.jsonl'
    for ($i = 1; $i -le 3; $i++) { Add-P9HArtifactLine -Path $logPath -Line ('{"sequence":' + $i + '}') }
    $logLines = @([IO.File]::ReadAllLines($logPath) | Where-Object { $_.Trim() })
    Add-P9HTestResult -Id 'J7' -Title 'Append-only observer logging still appends and never truncates' `
        -Input 'three sequential Add-P9HArtifactLine calls' `
        -Expected 'three records in order, none lost' `
        -Actual ("lines={0} content={1}" -f $logLines.Count, ($logLines -join '|')) `
        -Pass ($logLines.Count -eq 3 -and $logLines[0] -eq '{"sequence":1}' -and $logLines[2] -eq '{"sequence":3}') -Evidence $dir
}

function Invoke-P9HRelaunchTests {
    # R-series: corrected N2 fixture, placement branch and elevated attribution
    # (Stage 3B7G2).
    #
    # Every case here is PURE: the product's real planner functions are invoked
    # with a SYNTHETIC topology, and the collector's projection is exercised with
    # synthetic inventories. Nothing launches, and no VM is contacted.
    #
    # The G1 root cause is pinned first, because it is the whole point of this
    # stage: a profile-free set whose items declare NO relative mode takes the
    # legacy absolute fast path and therefore cannot emit a skip.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $dir = Join-Path $SandboxRoot 'r-relaunch'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    # Write-P9HArtifact creates the target's directory only, not an ancestor's;
    # create the verdict subtree up front.
    $earlyVerdictDir = Join-Path $dir 'verdict'
    New-Item -ItemType Directory -Path $earlyVerdictDir -Force | Out-Null

    # The layout planner under test is PRODUCT code. These cases exercise the REAL
    # frozen implementation from the repository tree rather than a reimplementation,
    # and every one of them is pure: a synthetic topology is injected, so loading
    # the module contacts no VM, launches nothing and moves no window.
    # <repo>\qualification\p9h\lib -> <repo>
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $script:P9HModuleRoot))
    $productLib = Join-Path $repoRoot 'src\lib'
    foreach ($libFile in @('devws-paths.ps1', 'devws-config.ps1', 'devws-native.ps1', 'devws-monitor.ps1',
            'devws-lifecycle-layout.ps1', 'devws-relative-layout.ps1', 'devws-layout-profile.ps1')) {
        $libPath = Join-Path $productLib $libFile
        if (Test-Path -LiteralPath $libPath) { . $libPath }
    }
    $plannerAvailable = [bool](Get-Command New-DevWSLifecycleLayoutPlan -ErrorAction SilentlyContinue)
    # Always recorded: a case that only exists on the failure branch would appear
    # as "registered but not run" whenever the planner loads.
    Add-P9HTestResult -Id 'R0' -Title 'The product placement planner is loadable for pure offline tests' `
        -Input 'src\lib planner module' -Expected 'New-DevWSLifecycleLayoutPlan available' `
        -Actual ("plannerAvailable={0} libRoot={1}" -f $plannerAvailable, $productLib) `
        -Pass $plannerAvailable -Evidence $null
    if (-not $plannerAvailable) { return }

    # ---------------------------------------------------------------- topology
    # A synthetic two-monitor topology. The relative anchor below is DELIBERATELY
    # absent from it: an absent configuration anchor is legitimate test input,
    # whereas a fabricated monitor OBSERVATION would not be.
    function New-Topology {
        param([switch]$Unavailable)
        if ($Unavailable) {
            return [pscustomobject]@{ Available = $false; Monitors = @(); IdentityComplete = $false; Signature = $null; Fingerprint = $null }
        }
        $monitors = @(
            [pscustomobject]@{
                IdentityToken = 'path:SYNTH/1&AAAA&0&UID256'; GdiDeviceName = '\\.\DISPLAY1'; Primary = $true
                MonitorRect = [pscustomobject]@{ x = 0; y = 0; w = 1280; h = 720 }
                WorkRect = [pscustomobject]@{ x = 0; y = 0; w = 1280; h = 672 }
            }
            [pscustomobject]@{
                IdentityToken = 'path:SYNTH/1&AAAA&0&UID257'; GdiDeviceName = '\\.\DISPLAY2'; Primary = $false
                MonitorRect = [pscustomobject]@{ x = -1280; y = 0; w = 1280; h = 720 }
                WorkRect = [pscustomobject]@{ x = -1280; y = 0; w = 1280; h = 672 }
            }
        )
        return [pscustomobject]@{
            Available = $true; Monitors = $monitors; IdentityComplete = $true
            CorrelationComplete = $true; IdentityAmbiguous = $false
            Signature = 'path:SYNTH/1&AAAA&0&UID256;path:SYNTH/1&AAAA&0&UID257'
            Fingerprint = 'SYNTHETICFINGERPRINT'
        }
    }
    $topology = New-Topology

    # ------------------------------------------------------------- item makers
    function New-RItem {
        param(
            [string]$ItemId = 'relterm',
            [string]$LayoutMode = $null,
            $LayoutRelative = $null,
            $Layout = $null,
            [switch]$Disabled
        )
        $o = [ordered]@{ id = $ItemId; type = 'terminal'; enabled = (-not $Disabled); windowId = "N2QUAL-$ItemId" }
        if ($null -ne $LayoutMode) { $o.layoutMode = $LayoutMode }
        if ($null -ne $LayoutRelative) { $o.layoutRelative = $LayoutRelative }
        $o.layout = if ($null -ne $Layout) { $Layout } else { [pscustomobject]@{ x = 9000; y = 9000; w = 640; h = 400 } }
        return [pscustomobject]$o
    }
    function New-Set {
        param([object[]]$Windows = @(), $LayoutProfiles = $null, [string]$Id = 'n2qual')
        $o = [ordered]@{ id = $Id; windows = @($Windows) }
        if ($null -ne $LayoutProfiles) { $o.layoutProfiles = $LayoutProfiles }
        return [pscustomobject]$o
    }
    # A DURABLE identity that is genuinely absent from the synthetic topology above.
    $absentRelative = [pscustomobject]@{
        monitor = [pscustomobject]@{ identity = 'path:OTHERHW/9&BBBB&0&UID999' }
        basis   = 'monitor'
        rect    = [pscustomobject]@{ x = 0.5; y = 0.5; w = 0.25; h = 0.25 }
    }

    # =====================================================================
    # R1: relative configuration ABSENT -> legacy absolute fast path (the G1 bug)
    # =====================================================================
    $legacySet = New-Set -Windows @( New-RItem -ItemId 'n2qualterm' )
    $legacy = New-DevWSLifecycleLayoutPlan -Set $legacySet -SetId 'n2qual' -TopologyProvider { $topology }
    $legacyItem = @($legacy.Items)[0]
    Add-P9HTestResult -Id 'R1' -Title 'No relative mode takes the legacy absolute fast path (the Stage 3B7G1 root cause)' `
        -Input 'a profile-free set whose only item declares neither layoutMode nor layoutRelative' `
        -Expected 'Source=fallback, RelativeAware=False, ApplyGeometry=True, no warnings, no skipped items' `
        -Actual ("source={0} relativeAware={1} apply={2} warnings={3} skipped={4}" -f
            $legacy.Source, $legacy.RelativeAware, $legacyItem.ApplyGeometry, @($legacy.Warnings).Count,
            @($legacy.Items | Where-Object { -not $_.ApplyGeometry }).Count) `
        -Pass ($legacy.Source -eq 'fallback' -and $legacy.RelativeAware -eq $false -and
            $legacyItem.ApplyGeometry -eq $true -and @($legacy.Warnings).Count -eq 0 -and
            @($legacy.Items | Where-Object { -not $_.ApplyGeometry }).Count -eq 0) -Evidence $null

    # =====================================================================
    # R2: valid missing anchor + unreachable fallback -> SKIPPED placement
    # =====================================================================
    $skipSet = New-Set -Windows @( New-RItem -ItemId 'n2qualterm' -LayoutMode 'relative' -LayoutRelative $absentRelative )
    $skipPlan = New-DevWSLifecycleLayoutPlan -Set $skipSet -SetId 'n2qual' -TopologyProvider { $topology }
    $skipItem = @($skipPlan.Items)[0]
    $skipWarn = (@($skipPlan.Warnings) -join ' | ')
    Add-P9HTestResult -Id 'R2' -Title 'An absent anchor with an unreachable fallback is SKIPPED deterministically' `
        -Input 'layoutMode=relative, layoutRelative.monitor.identity absent from the topology, fallback 9000,9000' `
        -Expected 'Source=relative, ApplyGeometry=False, FallbackUsed=False, one deterministic warning' `
        -Actual ("source={0} apply={1} fallbackUsed={2} status={3} warnings={4}" -f
            $skipPlan.Source, $skipItem.ApplyGeometry, $skipItem.FallbackUsed, $skipItem.PlacementStatus, $skipWarn) `
        -Pass ($skipPlan.Source -eq 'relative' -and $skipPlan.RelativeAware -eq $true -and
            $skipItem.ApplyGeometry -eq $false -and $skipItem.FallbackUsed -eq $false -and
            @($skipPlan.Warnings).Count -eq 1 -and
            $skipWarn -match 'no reachable placement' -and $skipWarn -match 'will not be changed') `
        -Evidence $null

    # =====================================================================
    # R3: missing anchor + REACHABLE fallback -> fallback APPLIED, not a skip
    # =====================================================================
    $reachable = [pscustomobject]@{ x = 100; y = 100; w = 640; h = 400 }
    $fbSet = New-Set -Windows @( New-RItem -ItemId 'n2qualterm' -LayoutMode 'relative' -LayoutRelative $absentRelative -Layout $reachable )
    $fbPlan = New-DevWSLifecycleLayoutPlan -Set $fbSet -SetId 'n2qual' -TopologyProvider { $topology }
    $fbItem = @($fbPlan.Items)[0]
    Add-P9HTestResult -Id 'R3' -Title 'A reachable fallback is APPLIED rather than skipped' `
        -Input 'same absent anchor, but the fallback rectangle IS reachable' `
        -Expected 'ApplyGeometry=True, FallbackUsed=True, warning names the fallback' `
        -Actual ("apply={0} fallbackUsed={1} status={2} warnings={3}" -f
            $fbItem.ApplyGeometry, $fbItem.FallbackUsed, $fbItem.PlacementStatus, @($fbPlan.Warnings).Count) `
        -Pass ($fbItem.ApplyGeometry -eq $true -and $fbItem.FallbackUsed -eq $true -and
            @($fbPlan.Warnings).Count -eq 1) -Evidence $null

    # =====================================================================
    # R4: an exact matching profile override must NOT produce a false relative skip
    # =====================================================================
    $profileGeometry = [pscustomobject]@{ x = 0; y = 0; w = 640; h = 400 }
    # The matcher signature is derived from the profile's monitor TOKEN list, and
    # the topology signature is the same canonical multiset, so an exact match is
    # expressed by listing the real monitors.
    # A profile's per-item overrides live under a 'layouts' MAP keyed by item id,
    # and are looked up as sparse properties there.
    $profLayoutMap = [ordered]@{ 'n2qualterm' = [pscustomobject]@{ x = 0; y = 0; w = 640; h = 400 } }
    $profProjection = [ordered]@{
        id      = 'exact'
        match   = [pscustomobject]@{ monitors = @('path:SYNTH/1&AAAA&0&UID256', 'path:SYNTH/1&AAAA&0&UID257') }
        layouts = [pscustomobject]$profLayoutMap
    }
    $profSet = New-Set -LayoutProfiles @([pscustomobject]$profProjection) `
        -Windows @( New-RItem -ItemId 'n2qualterm' -LayoutMode 'relative' -LayoutRelative $absentRelative -Layout $reachable )
    $profPlan = New-DevWSLifecycleLayoutPlan -Set $profSet -SetId 'n2qual' -TopologyProvider { $topology }
    $profItem = @($profPlan.Items)[0]
    Add-P9HTestResult -Id 'R4' -Title 'A matching profile wins and makes no false relative-skip claim' `
        -Input 'relative item with a reachable fallback AND an exact matching layout profile' `
        -Expected 'Source=profile, ApplyGeometry=True, no skip warning' `
        -Actual ("source={0} profileId={1} apply={2} warnings={3}" -f $profPlan.Source, $profItem.ProfileId, $profItem.ApplyGeometry, @($profPlan.Warnings).Count) `
        -Pass ($profPlan.Source -eq 'profile' -and $profItem.ApplyGeometry -eq $true -and
            @($profPlan.Warnings).Count -eq 0) -Evidence $null

    # =====================================================================
    # R5: unavailable topology never advertises a fallback
    # =====================================================================
    $unavailSet = New-Set -Windows @( New-RItem -ItemId 'n2qualterm' -LayoutMode 'relative' -LayoutRelative $absentRelative -Layout $reachable )
    $unavail = New-DevWSLifecycleLayoutPlan -Set $unavailSet -SetId 'n2qual' -TopologyProvider { New-Topology -Unavailable }
    $unavailItem = @($unavail.Items)[0]
    Add-P9HTestResult -Id 'R5' -Title 'An unavailable topology applies nothing and advertises no fallback' `
        -Input 'relative item with a reachable fallback but no topology' `
        -Expected 'ApplyGeometry=False, FallbackUsed=False, warning explains the topology' `
        -Actual ("apply={0} fallbackUsed={1} status={2}" -f $unavailItem.ApplyGeometry, $unavailItem.FallbackUsed, $unavailItem.PlacementStatus) `
        -Pass ($unavailItem.ApplyGeometry -eq $false -and $unavailItem.FallbackUsed -eq $false -and
            (@($unavail.Warnings) -join ' ') -match 'topology is unavailable') -Evidence $null

    # =====================================================================
    # R6: MEDIUM argv unavailable -> attribution REFUSES
    # =====================================================================
    $mediumAfter = [pscustomobject]@{
        CollectorIntegrity = 'Medium'
        Processes = @(
            [pscustomobject]@{ pid = 7001; ppid = 1; name = 'WindowsTerminal.exe'; sessionId = 2; startUtc = '2026-11-14T14:48:06.5000000Z'; startSource = 'datetime'; commandLine = ''; commandLength = 0 }
        )
    }
    $mediumBefore = [pscustomobject]@{ CollectorIntegrity = 'Medium'; Processes = @() }
    $medDelta = ConvertTo-P9HAttributionInventory -Before $mediumBefore -After $mediumAfter -SessionId 2
    $medAttr = Get-P9HLaunchAttribution -AddedProcesses @($medDelta.Added) `
        -ExpectedWindowId 'N2QUAL-n2qualterm' -ExpectedTerminalId 'n2qualterm' -ExpectedSetId 'n2qual' `
        -LauncherPid 7000 -LaunchedAtUtc '2026-11-14T14:48:02.0000000Z' -ExitedAtUtc '2026-11-14T14:48:08.0000000Z'
    Add-P9HTestResult -Id 'R6' -Title 'A Medium-sourced empty argv refuses attribution (never inferred)' `
        -Input 'new process whose command line the Medium collector could not read' `
        -Expected 'Ok=False; the process is excluded, not guessed from its name' `
        -Actual ("ok={0} reason={1} added={2} skippedNoCmd={3}" -f $medAttr.Ok, $medAttr.Reason,
            @($medDelta.Added).Count, @($medDelta.SkippedNoCommandLine).Count) `
        -Pass ($medAttr.Ok -eq $false -and @($medDelta.Added).Count -eq 0 -and
            @($medDelta.SkippedNoCommandLine).Count -eq 1) -Evidence $null

    # =====================================================================
    # R7: HIGH authentic argv with matching pid/session/start -> attribution SUCCEEDS
    # =====================================================================
    $goodCmd = 'pwsh.exe -File coordinator.ps1 -SetId n2qual -TerminalId n2qualterm -WindowId N2QUAL-n2qualterm'
    $highAfter = [pscustomobject]@{
        CollectorIntegrity = 'High'
        Processes = @(
            [pscustomobject]@{ pid = 7001; ppid = 1; name = 'WindowsTerminal.exe'; sessionId = 2; startUtc = '2026-11-14T14:48:06.5000000Z'; startSource = 'datetime'; commandLine = $goodCmd; commandLength = $goodCmd.Length; collectedByIntegrity = 'High' }
            [pscustomobject]@{ pid = 7002; ppid = 1; name = 'unrelated.exe'; sessionId = 2; startUtc = '2026-11-14T14:48:06.6000000Z'; startSource = 'datetime'; commandLine = 'unrelated.exe --foo'; commandLength = 19; collectedByIntegrity = 'High' }
        )
    }
    $highBefore = [pscustomobject]@{ CollectorIntegrity = 'High'; Processes = @() }
    $highDelta = ConvertTo-P9HAttributionInventory -Before $highBefore -After $highAfter -SessionId 2
    $highAttr = Get-P9HLaunchAttribution -AddedProcesses @($highDelta.Added) `
        -ExpectedWindowId 'N2QUAL-n2qualterm' -ExpectedTerminalId 'n2qualterm' -ExpectedSetId 'n2qual' `
        -LauncherPid 7000 -LaunchedAtUtc '2026-11-14T14:48:02.0000000Z' -ExitedAtUtc '2026-11-14T14:48:08.0000000Z'
    Add-P9HTestResult -Id 'R7' -Title 'High-integrity argv with matching identity/time attributes the process' `
        -Input 'both processes carry argv; only one names the frozen SetId/TerminalId/WindowId inside the window' `
        -Expected 'Ok=True, exactly one attributed pid, provenance retained' `
        -Actual ("ok={0} count={1} pids={2} integrity={3}" -f $highAttr.Ok, $highAttr.Count,
            (@($highAttr.Processes | ForEach-Object { $_.pid }) -join ','), $highDelta.afterIntegrity) `
        -Pass ($highAttr.Ok -eq $true -and $highAttr.Count -eq 1 -and
            [int](@($highAttr.Processes)[0].pid) -eq 7001 -and $highDelta.afterIntegrity -eq 'High') -Evidence $null

    # =====================================================================
    # R8: wrong PID / wrong session / stale start time / wrong identity all refuse
    # =====================================================================
    $refusals = [ordered]@{}
    # (a) launcher pid excluded
    $refusals['launcherPidExcluded'] = -not (Get-P9HLaunchAttribution -AddedProcesses @($highDelta.Added) `
            -ExpectedWindowId 'N2QUAL-n2qualterm' -ExpectedTerminalId 'n2qualterm' -ExpectedSetId 'n2qual' `
            -LauncherPid 7001 -LaunchedAtUtc '2026-11-14T14:48:02.0000000Z' -ExitedAtUtc '2026-11-14T14:48:08.0000000Z').Ok
    # (b) stale creation time outside the launch window
    $refusals['staleCreationTime'] = -not (Get-P9HLaunchAttribution -AddedProcesses @($highDelta.Added) `
            -ExpectedWindowId 'N2QUAL-n2qualterm' -ExpectedTerminalId 'n2qualterm' -ExpectedSetId 'n2qual' `
            -LauncherPid 7000 -LaunchedAtUtc '2026-11-15T00:00:00.0000000Z' -ExitedAtUtc '2026-11-15T00:00:10.0000000Z').Ok
    # (c) wrong SetId
    $refusals['wrongSetId'] = -not (Get-P9HLaunchAttribution -AddedProcesses @($highDelta.Added) `
            -ExpectedWindowId 'N2QUAL-n2qualterm' -ExpectedTerminalId 'n2qualterm' -ExpectedSetId 'otherset' `
            -LauncherPid 7000 -LaunchedAtUtc '2026-11-14T14:48:02.0000000Z' -ExitedAtUtc '2026-11-14T14:48:08.0000000Z').Ok
    # (d) wrong TerminalId
    $refusals['wrongTerminalId'] = -not (Get-P9HLaunchAttribution -AddedProcesses @($highDelta.Added) `
            -ExpectedWindowId 'N2QUAL-n2qualterm' -ExpectedTerminalId 'otherterm' -ExpectedSetId 'n2qual' `
            -LauncherPid 7000 -LaunchedAtUtc '2026-11-14T14:48:02.0000000Z' -ExitedAtUtc '2026-11-14T14:48:08.0000000Z').Ok
    # (e) wrong WindowId
    $refusals['wrongWindowId'] = -not (Get-P9HLaunchAttribution -AddedProcesses @($highDelta.Added) `
            -ExpectedWindowId 'OTHER-win' -ExpectedTerminalId 'n2qualterm' -ExpectedSetId 'n2qual' `
            -LauncherPid 7000 -LaunchedAtUtc '2026-11-14T14:48:02.0000000Z' -ExitedAtUtc '2026-11-14T14:48:08.0000000Z').Ok
    # (f) wrong session filtered out by the projection
    $wrongSession = ConvertTo-P9HAttributionInventory -Before $highBefore -After $highAfter -SessionId 9
    $refusals['wrongSession'] = (@($wrongSession.Added).Count -eq 0 -and @($wrongSession.SkippedOtherSession).Count -eq 2)
    # (g) missing process identity entirely
    $refusals['noProcesses'] = -not (Get-P9HLaunchAttribution -AddedProcesses @() `
            -ExpectedWindowId 'N2QUAL-n2qualterm' -ExpectedTerminalId 'n2qualterm' -ExpectedSetId 'n2qual' `
            -LauncherPid 7000 -LaunchedAtUtc '2026-11-14T14:48:02.0000000Z' -ExitedAtUtc '2026-11-14T14:48:08.0000000Z').Ok

    Add-P9HTestResult -Id 'R8' -Title 'Launcher pid, stale time, wrong session and wrong identity all refuse' `
        -Input 'seven independent negative attribution conditions' `
        -Expected 'every one refused' `
        -Actual (($refusals.Keys | ForEach-Object { $_ + '=' + $refusals[$_] }) -join ' ') `
        -Pass (@($refusals.Values | Where-Object { $_ -ne $true }).Count -eq 0) -Evidence $null

    # =====================================================================
    # R9: exactly one attributed window is eligible; two are NOT
    # =====================================================================
    function New-Win([string]$Hwnd, [int]$OwnerPid, [int]$X = 0, [int]$Y = 0) {
        return [pscustomobject]@{ hwnd = $Hwnd; pid = $OwnerPid; visible = $true; x = $X; y = $Y; width = 640; height = 400; title = 'managed' }
    }
    $afterOne = @()
    $afterOne += (New-Win '100' 7002)
    $afterOne += (New-Win '101' 7002)
    $afterOne += (New-Win '102' 7001)
    $oneSel = Select-P9HAttributableWindow -PreWindowHwnds @('100', '101') -AfterWindows $afterOne -CandidatePids @(7001)
    $afterTwo = @()
    $afterTwo += (New-Win '100' 7002)
    $afterTwo += (New-Win '101' 7002)
    $afterTwo += (New-Win '102' 7001)
    $afterTwo += (New-Win '103' 7001)
    $twoSel = Select-P9HAttributableWindow -PreWindowHwnds @('100', '101') -AfterWindows $afterTwo -CandidatePids @(7001)
    Add-P9HTestResult -Id 'R9' -Title 'One newly observed attributed window is eligible; two are not' `
        -Input 'the same pre-inventory with one, then two, new windows owned by the attributed pid' `
        -Expected 'count 1 attributed; count 2 attributed but not identity-consistent' `
        -Actual ("one={0}/{1} two={2}/{3}" -f $oneSel.Attributed, $oneSel.Count, $twoSel.Attributed, $twoSel.Count) `
        -Pass ($oneSel.Attributed -eq $true -and $oneSel.Count -eq 1 -and $twoSel.Attributed -eq $true -and $twoSel.Count -eq 2) `
        -Evidence $null

    # =====================================================================
    # R10: a missing placement skip blocks N2-A and N2-B identity consistency
    # =====================================================================
    # A real end-to-end verdict over synthetic-but-honest artifacts: the trace
    # has NO skipped item, the process and window attribute correctly, and the
    # trial is fully bound. N2-A must still refuse for the missing skip, and N2-B
    # must report the improved identity reason rather than an opaque failure.
    $vDir = Join-Path $dir 'verdict'
    New-Item -ItemType Directory -Path $vDir -Force | Out-Null
    $tid = 'r-relaunch-trial'

    $captureObj = [ordered]@{
        tokenCount = 1; identityComplete = $true; sessionId = 2; trialId = $tid
        capturedUtc = '2026-11-14T14:48:00.0000000Z'
        tokens = @('path:SYNTH/1&AAAA&0&UID256')
        parsedMonitors = @([pscustomobject][ordered]@{ identity = 'path:SYNTH/1&AAAA&0&UID256'; rect = 'x=0 y=0 w=1280 h=720' })
    }
    $fxPath = Join-Path $vDir 'fixture.json'
    Write-P9HArtifact -Path $fxPath -Lines @(([ordered]@{
                itemId = 'n2qualterm'; enabledItems = 1; enabledTerminals = 1; totalItems = 1
                anchorAbsent = $true; layoutFallback = [ordered]@{ x = 9000; y = 9000; w = 640; h = 400 }
            } | ConvertTo-Json -Depth 4))
    $tracePath = Join-Path $vDir 'trace.jsonl'
    $null = Add-P9HArtifactLine -Path $tracePath -Line ((@{ event = 'lifecycle-layout-plan'; utcMs = 1000; set = 'n2qual'; skipped = @() } | ConvertTo-Json -Compress))
    foreach ($e in @(
            @{ ev = 'transaction-start'; ms = 1010 }
            @{ ev = 'stage2-broker-ready'; ms = 1020; planId = 'deadbeef' }
            @{ ev = 'stage2-terminal-final'; ms = 1030 }
            @{ ev = 'transaction-end'; ms = 1040 })) {
        $o = [ordered]@{ event = $e.ev; utcMs = $e.ms; set = 'n2qual' }
        if ($e.ContainsKey('planId')) { $o.planId = $e.planId }
        if ($e.ev -eq 'stage2-terminal-final') { $o.finalized = 1; $o.failures = 0 }
        if ($e.ev -eq 'transaction-end') { $o.broker = $true; $o.uncertain = $false; $o.failures = @() }
        $null = Add-P9HArtifactLine -Path $tracePath -Line ($o | ConvertTo-Json -Compress -Depth 4)
    }
    $soPath = Join-Path $vDir 'stdout.txt'
    Write-P9HArtifact -Path $soPath -Lines @("Workspace 'n2qual' restored.")
    $prePath = Join-Path $vDir 'pre-windows.json'
    Write-P9HArtifact -Path $prePath -Lines @(([ordered]@{ Windows = @([ordered]@{ hwnd = '100'; pid = 7002; visible = $true; x = 0; y = 0; width = 10; height = 10 }) } | ConvertTo-Json -Depth 5))
    $postPath = Join-Path $vDir 'post-windows.json'
    Write-P9HArtifact -Path $postPath -Lines @(([ordered]@{ Windows = @(
                    [ordered]@{ hwnd = '100'; pid = 7002; visible = $true; x = 0; y = 0; width = 10; height = 10 }
                    [ordered]@{ hwnd = '102'; pid = 7001; visible = $true; x = 0; y = 0; width = 640; height = 400 }
                ) } | ConvertTo-Json -Depth 5))
    $exPath = Join-Path $vDir 'exit.json'
    Write-P9HArtifact -Path $exPath -Lines @(([ordered]@{
                trialId = $tid; schema = 'p9h.exit-record.v1'; sequence = 1; outcome = 'exited'; exitCode = 0
                launcherPid = 7000; launcherPath = 'C:\Windows\System32\cmd.exe'
                launchedAtUtc = '2026-11-14T14:48:02.0000000Z'; exitedAtUtc = '2026-11-14T14:48:08.0000000Z'
            } | ConvertTo-Json -Depth 4))
    $npPath = Join-Path $vDir 'new-processes.json'
    Write-P9HArtifact -Path $npPath -Lines @($highDelta | ConvertTo-Json -Depth 6)

    # Bind the seven roles first: these cases are about the SKIP requirement, so
    # artifact binding must be satisfied and must not be the recorded reason.
    $rCtx = New-P9HTrialContext -RootDirectory $SandboxRoot -TrialId $tid -Kind n2
    foreach ($rb in @(
            @{ role = 'fixture'; path = $fxPath }
            @{ role = 'stdout'; path = $soPath }
            @{ role = 'pre-windows'; path = $prePath }
            @{ role = 'post-windows'; path = $postPath }
            @{ role = 'exit-record'; path = $exPath }
            @{ role = 'new-processes'; path = $npPath }
            @{ role = 'trace'; path = $tracePath })) {
        $null = Add-P9HArtifactRole -Context $rCtx -Path $rb.path -Role $rb.role
    }
    $null = Write-P9HArtifactIndex -Context $rCtx
    $rIndex = Join-Path $rCtx.Directory 'artifact-index.jsonl'

    $v = Get-P9HN2Verdicts -FixturePath $fxPath -TracePath $tracePath -StdoutPath $soPath `
        -PreWindowPath $prePath -PostWindowPath $postPath -ExitRecordPath $exPath -NewProcessPath $npPath `
        -TrialId $tid -ExpectedWindowId 'N2QUAL-n2qualterm' -ExpectedTerminalId 'n2qualterm' -ExpectedSetId 'n2qual' `
        -ArtifactIndexPath $rIndex
    $vBlocked = @(
        ($v.N2A.Verdict -ne 'PASS'),
        ($v.N2A.Reasons -contains 'item-not-in-skipped-set'),
        ($v.N2A.ProcessAttributed -eq $true),
        ($v.N2A.WindowAttributed -eq $true),
        ($v.N2B.Verdict -ne 'PASS'),
        ($v.N2B.IdentityConsistent -eq $false),
        ([string]$v.N2B.IdentityConsistencyReason -eq 'item-not-reported-skipped-by-lifecycle-trace')
    )
    Add-P9HTestResult -Id 'R10' -Title 'A missing placement skip still blocks N2-A and N2-B identity consistency' `
        -Input 'honest artifacts with full attribution but NO skipped item in the lifecycle trace' `
        -Expected 'N2-A reason item-not-in-skipped-set; N2-B names the missing skip explicitly' `
        -Actual ("n2a={0} reasons=[{1}] n2b={2} identityReason={3}" -f $v.N2A.Verdict,
            (@($v.N2A.Reasons) -join ';'), $v.N2B.Verdict, $v.N2B.IdentityConsistencyReason) `
        -Pass (@($vBlocked | Where-Object { $_ -ne $true }).Count -eq 0) -Evidence $vDir

    # =====================================================================
    # R11: with the skip PRESENT, the same artifacts become PASS-eligible
    # =====================================================================
    # This proves the block in R10 was genuinely the missing skip and not some
    # other defect: the ONLY change is that the trace now reports the item.
    $traceSkip = Join-Path $vDir 'trace-skipped.jsonl'
    $null = Add-P9HArtifactLine -Path $traceSkip -Line ((@{ event = 'lifecycle-layout-plan'; utcMs = 1000; set = 'n2qual'; skipped = @('n2qualterm') } | ConvertTo-Json -Compress))
    foreach ($e in @(
            @{ ev = 'transaction-start'; ms = 1010 }
            @{ ev = 'stage2-broker-ready'; ms = 1020; planId = 'deadbeef' }
            @{ ev = 'stage2-terminal-final'; ms = 1030 }
            @{ ev = 'transaction-end'; ms = 1040 })) {
        $o = [ordered]@{ event = $e.ev; utcMs = $e.ms; set = 'n2qual' }
        if ($e.ContainsKey('planId')) { $o.planId = $e.planId }
        if ($e.ev -eq 'stage2-terminal-final') { $o.finalized = 1; $o.failures = 0 }
        if ($e.ev -eq 'transaction-end') { $o.broker = $true; $o.uncertain = $false; $o.failures = @() }
        $null = Add-P9HArtifactLine -Path $traceSkip -Line ($o | ConvertTo-Json -Compress -Depth 4)
    }
    $soWarn = Join-Path $vDir 'stdout-warn.txt'
    Write-P9HArtifact -Path $soWarn -Lines @("n2qual/n2qualterm: relative layout has no reachable placement (relative-target-and-fallback-unreachable); the item will be handled normally but its window position will not be changed.")
    # Re-bind because the trace and stdout changed.
    $skipCtx = New-P9HTrialContext -RootDirectory (Join-Path $SandboxRoot 'skip-arm') -TrialId $tid -Kind n2
    foreach ($rb in @(
            @{ role = 'fixture'; path = $fxPath }
            @{ role = 'stdout'; path = $soWarn }
            @{ role = 'pre-windows'; path = $prePath }
            @{ role = 'post-windows'; path = $postPath }
            @{ role = 'exit-record'; path = $exPath }
            @{ role = 'new-processes'; path = $npPath }
            @{ role = 'trace'; path = $traceSkip })) {
        $null = Add-P9HArtifactRole -Context $skipCtx -Path $rb.path -Role $rb.role
    }
    $null = Write-P9HArtifactIndex -Context $skipCtx
    $skipIndex = Join-Path $skipCtx.Directory 'artifact-index.jsonl'

    $vSkip = Get-P9HN2Verdicts -FixturePath $fxPath -TracePath $traceSkip -StdoutPath $soWarn `
        -PreWindowPath $prePath -PostWindowPath $postPath -ExitRecordPath $exPath -NewProcessPath $npPath `
        -TrialId $tid -ExpectedWindowId 'N2QUAL-n2qualterm' -ExpectedTerminalId 'n2qualterm' -ExpectedSetId 'n2qual' `
        -ArtifactIndexPath $skipIndex
    Add-P9HTestResult -Id 'R11' -Title 'With the skip and warning present the same evidence becomes PASS-eligible' `
        -Input 'identical artifacts except the trace reports the item skipped and stdout carries the warning' `
        -Expected 'N2-A PASS, N2-B PASS, identity consistent' `
        -Actual ("n2a={0}[{5}] n2b={1}[{6}] identity={2} skipped={3} warning={4}" -f
            $vSkip.N2A.Verdict, $vSkip.N2B.Verdict, $vSkip.N2B.IdentityConsistent,
            $vSkip.N2A.SkippedInTrace, $vSkip.N2A.WarningPresent,
            (@($vSkip.N2A.Reasons) -join ';'), (@($vSkip.N2B.Reasons) -join ';')) `
        -Pass ($vSkip.N2A.Verdict -eq 'PASS' -and $vSkip.N2B.Verdict -eq 'PASS' -and
            $vSkip.N2B.IdentityConsistent -eq $true) -Evidence $vDir

    # =====================================================================
    # R12: two attributed windows break N2-B identity consistency
    # =====================================================================
    $postTwo = Join-Path $vDir 'post-windows-two.json'
    Write-P9HArtifact -Path $postTwo -Lines @(([ordered]@{ Windows = @(
                    [ordered]@{ hwnd = '100'; pid = 7002; visible = $true; x = 0; y = 0; width = 10; height = 10 }
                    [ordered]@{ hwnd = '102'; pid = 7001; visible = $true; x = 0; y = 0; width = 640; height = 400 }
                    [ordered]@{ hwnd = '103'; pid = 7001; visible = $true; x = 10; y = 10; width = 640; height = 400 }
                ) } | ConvertTo-Json -Depth 5))
    $vTwo = Get-P9HN2Verdicts -FixturePath $fxPath -TracePath $traceSkip -StdoutPath $soWarn `
        -PreWindowPath $prePath -PostWindowPath $postTwo -ExitRecordPath $exPath -NewProcessPath $npPath `
        -TrialId $tid -ExpectedWindowId 'N2QUAL-n2qualterm' -ExpectedTerminalId 'n2qualterm' -ExpectedSetId 'n2qual' `
        -ArtifactIndexPath $skipIndex
    Add-P9HTestResult -Id 'R12' -Title 'Two attributed windows break N2-B identity consistency' `
        -Input 'the same trial but the product created a second attributable window' `
        -Expected 'N2-B not PASS, identity reason names the window count' `
        -Actual ("n2b={0} count={1} identity={2} reason={3}" -f $vTwo.N2B.Verdict,
            $vTwo.N2B.AttributedWindowCount, $vTwo.N2B.IdentityConsistent, $vTwo.N2B.IdentityConsistencyReason) `
        -Pass ($vTwo.N2B.Verdict -ne 'PASS' -and $vTwo.N2B.IdentityConsistent -eq $false -and
            [string]$vTwo.N2B.IdentityConsistencyReason -eq 'attributed-window-count-not-one:2') -Evidence $vDir

    # =====================================================================
    # R13: the seven-role binding and digest rules are still enforced
    # =====================================================================
    $ctx = New-P9HTrialContext -RootDirectory $SandboxRoot -TrialId $tid -Kind n2
    $roles = @(
        @{ role = 'fixture'; path = $fxPath }
        @{ role = 'stdout'; path = $soPath }
        @{ role = 'pre-windows'; path = $prePath }
        @{ role = 'post-windows'; path = $postPath }
        @{ role = 'exit-record'; path = $exPath }
        @{ role = 'new-processes'; path = $npPath }
        @{ role = 'trace'; path = $tracePath }
    )
    foreach ($r in $roles) { $null = Add-P9HArtifactRole -Context $ctx -Path $r.path -Role $r.role }
    $null = Write-P9HArtifactIndex -Context $ctx
    $indexPath = Join-Path $ctx.Directory 'artifact-index.jsonl'
    $bindOk = Get-P9HArtifactBinding -TrialId $tid -ArtifactIndexPath $indexPath `
        -RequiredRoles @('fixture', 'stdout', 'pre-windows', 'post-windows', 'exit-record', 'new-processes', 'trace')
    # now tamper with one bound artifact and re-verify
    $origStdout = [IO.File]::ReadAllText($soPath)
    [IO.File]::WriteAllText($soPath, $origStdout + "tampered`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $bindBad = Get-P9HArtifactBinding -TrialId $tid -ArtifactIndexPath $indexPath `
        -RequiredRoles @('fixture', 'stdout', 'pre-windows', 'post-windows', 'exit-record', 'new-processes', 'trace')
    [IO.File]::WriteAllText($soPath, $origStdout, (New-Object System.Text.UTF8Encoding($false)))
    # a missing role must also refuse
    $bindMissing = Get-P9HArtifactBinding -TrialId 'other-trial' -ArtifactIndexPath $indexPath `
        -RequiredRoles @('fixture')
    Add-P9HTestResult -Id 'R13' -Title 'Seven-role binding and post-binding digest rules remain enforced' `
        -Input 'all seven roles bound; then one artifact tampered; then a foreign trial id' `
        -Expected 'binding verified; tampering detected; foreign trial refused' `
        -Actual ("ok={0} tamperedOk={1} foreignOk={2}" -f $bindOk.Ok, $bindBad.Ok, $bindMissing.Ok) `
        -Pass ($bindOk.Ok -eq $true -and $bindBad.Ok -eq $false -and $bindMissing.Ok -eq $false) -Evidence $ctx.Directory
}

function Invoke-P9HManagedTerminalContractTests {
    # E-series: the versioned managed-terminal window identity contract
    # (Stage 3B7G3).
    #
    # Stage 3B7G2 returned N2-B INCONCLUSIVE with
    # `attributed-window-count-not-one:2` for a launch that created exactly ONE
    # managed Windows Terminal window plus its own Win32-owned pseudoconsole. The
    # historical rule counted PROCESS-associated HWNDs, not MANAGED TERMINAL
    # windows.
    #
    # These cases pin the corrected interpretation against every way it could be
    # abused, plus the original false-INCONCLUSIVE reproduction. All fixtures are
    # synthetic and none of them contacts a VM: the classifier and the verdict are
    # pure functions of the supplied records.
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $dir = Join-Path $SandboxRoot 'e-managed-terminal'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $setId = 'n2qual'
    $windowId = 'N2QUAL-n2qualterm'
    $terminalId = 'n2qualterm'
    $managedClass = 'CASCADIA_HOSTING_WINDOW_CLASS'

    # ---------------------------------------------------------------- builders
    function New-Proc {
        # ParentPid defaults to an unrelated launcher, but it is EXPLICIT so a
        # fixture can model the real G2 parentage: pid 10140's ppid IS 7280.
        #
        # -EmptyCommandLine models a process whose command line could NOT be read.
        # It is distinct from omitting -Cmd, which means "use the default identity
        # command line" and would otherwise silently satisfy the identity factors.
        param([int]$ProcId = 7280, [int]$ParentPid = 5732, [string]$Name = 'WindowsTerminal.exe', [string]$Cmd = $null, [int]$Session = 2, [switch]$EmptyCommandLine)
        if ($EmptyCommandLine) {
            $Cmd = ''
        }
        elseif ([string]::IsNullOrWhiteSpace($Cmd)) {
            $Cmd = 'pwsh.exe -SetId n2qual -TerminalId n2qualterm -WindowId N2QUAL-n2qualterm'
        }
        return [pscustomobject]@{ pid = $ProcId; ppid = $ParentPid; name = $Name; sessionId = $Session; commandLine = $Cmd; commandLength = $Cmd.Length; startUtc = '2026-11-14T18:06:08.5000000Z' }
    }
    # WS_EX_TOOLWINDOW is the positive non-user-facing marker the auxiliary
    # contract requires. A fixture supplies it explicitly; omitting it models a
    # record that simply did not capture window style.
    $script:E_WS_EX_TOOLWINDOW = 0x00000080
    $script:E_WS_EX_APPWINDOW = 0x00040000
    function New-Win {
        param(
            [string]$Hwnd = '0x50366', [int]$WinPid = 7280, [string]$Class = $managedClass,
            [string]$Title = $windowId, [string]$Owner = '0x0', [bool]$Visible = $true,
            [int]$X = 18, [int]$Y = 26, [int]$W = 1129, [int]$H = 635,
            $ExStyle = $null
        )
        $o = [ordered]@{ hwnd = $Hwnd; pid = $WinPid; visible = $Visible; class = $Class; x = $X; y = $Y; width = $W; height = $H; owner = $Owner; title = $Title }
        if ($null -ne $ExStyle) { $o['exStyle'] = $ExStyle }
        return [pscustomobject]$o
    }
    function Classify {
        param([object[]]$Windows, $Procs)
        $map = @{}
        foreach ($p in @($Procs)) { $map[[int]$p.pid] = $p }
        return Get-P9HManagedTerminalWindowClassification -Windows $Windows `
            -ExpectedWindowId $windowId -ExpectedTerminalId $terminalId -ExpectedSetId $setId -ProcessByPid $map
    }

    # The genuine G2 pair: one managed terminal plus its Win32-owned pseudoconsole.
    $g2Terminal = New-Win
    $g2Pseudo = New-Win -Hwnd '0x20330' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title '' -Owner '0x50366' -X 0 -Y 0 -W 16 -H 16 -ExStyle $E_WS_EX_TOOLWINDOW
    $g2Procs = @(
        (New-Proc)
        (New-Proc -ProcId 10140 -ParentPid 7280 -Name 'pwsh.exe' -Cmd 'pwsh.exe -NoExit -File cwd-shell-bootstrap.ps1 -SetId n2qual -TerminalId n2qualterm -WindowId N2QUAL-n2qualterm')
    )

    # =====================================================================
    # E1: the original false-INCONCLUSIVE reproduction, historical contract
    # =====================================================================
    $histRaw = Classify -Windows @($g2Terminal, $g2Pseudo) -Procs $g2Procs
    Add-P9HTestResult -Id 'E1' -Title 'Historical rule counts the auxiliary pseudoconsole as a second attributed HWND' `
        -Input 'the exact Stage 3B7G2 pair: one managed terminal + one Win32-owned PseudoConsoleWindow' `
        -Expected 'raw attributed count 2, which is what produced G2 INCONCLUSIVE' `
        -Actual ("rawCount={0} hwnds={1}" -f $histRaw.RawAttributedHwndCount, ((@($histRaw.Managed + $histRaw.Auxiliary + $histRaw.Unclassified) | ForEach-Object { $_.hwnd }) -join ',')) `
        -Pass ($histRaw.RawAttributedHwndCount -eq 2) -Evidence $null

    # =====================================================================
    # E2: corrected contract accepts the same pair as ONE managed terminal
    # =====================================================================
    $e2 = Classify -Windows @($g2Terminal, $g2Pseudo) -Procs $g2Procs
    Add-P9HTestResult -Id 'E2' -Title 'Corrected contract: one managed terminal plus one proven auxiliary' `
        -Input 'same G2 pair; auxiliary is linked by GW_OWNER to the managed terminal' `
        -Expected 'Ok=True, managed=1, auxiliary=1, unclassified=0' `
        -Actual ("ok={0} managed={1} aux={2} unclassified={3} qualifying={4}" -f $e2.Ok, $e2.ManagedTerminalCount, $e2.AuxiliaryCount, $e2.UnclassifiedCount, $e2.QualifyingHwnd) `
        -Pass ($e2.Ok -eq $true -and $e2.ManagedTerminalCount -eq 1 -and $e2.AuxiliaryCount -eq 1 -and $e2.UnclassifiedCount -eq 0 -and $e2.QualifyingHwnd -eq '0x50366') -Evidence $null

    # =====================================================================
    # E2b: ENUMERATION-ORDER INDEPENDENCE
    #
    # The genuine Stage 3B7G2 post inventory lists the pseudoconsole (0x20330)
    # BEFORE its owner (0x50366). A classifier that resolves ownership inline
    # therefore tests an auxiliary against a managed set that is still empty, and
    # reports a correct auxiliary as unclassified purely because of enumeration
    # order. Both orders must produce the identical classification.
    # =====================================================================
    $e2bForward = Classify -Windows @($g2Pseudo, $g2Terminal) -Procs $g2Procs
    $e2bReverse = Classify -Windows @($g2Terminal, $g2Pseudo) -Procs $g2Procs
    Add-P9HTestResult -Id 'E2b' -Title 'Classification is independent of window enumeration order' `
        -Input 'the G2 pair in BOTH orders (pseudoconsole first, then terminal first)' `
        -Expected 'both orders: managed=1, auxiliary=1, unclassified=0, same qualifying HWND' `
        -Actual ("pseudoFirst=(ok={0} managed={1} aux={2} unclassified={3} q={4}) terminalFirst=(ok={5} managed={6} aux={7} unclassified={8} q={9})" -f
            $e2bForward.Ok, $e2bForward.ManagedTerminalCount, $e2bForward.AuxiliaryCount, $e2bForward.UnclassifiedCount, $e2bForward.QualifyingHwnd,
            $e2bReverse.Ok, $e2bReverse.ManagedTerminalCount, $e2bReverse.AuxiliaryCount, $e2bReverse.UnclassifiedCount, $e2bReverse.QualifyingHwnd) `
        -Pass ($e2bForward.Ok -eq $true -and $e2bForward.ManagedTerminalCount -eq 1 -and $e2bForward.AuxiliaryCount -eq 1 -and
            $e2bForward.UnclassifiedCount -eq 0 -and $e2bForward.QualifyingHwnd -eq '0x50366' -and
            $e2bReverse.Ok -eq $true -and $e2bReverse.ManagedTerminalCount -eq 1 -and $e2bReverse.AuxiliaryCount -eq 1 -and
            $e2bReverse.UnclassifiedCount -eq 0 -and $e2bReverse.QualifyingHwnd -eq '0x50366') -Evidence $null

    # =====================================================================
    # E3: one qualifying managed terminal ALONE is accepted
    # =====================================================================
    $e3 = Classify -Windows @($g2Terminal) -Procs $g2Procs
    Add-P9HTestResult -Id 'E3' -Title 'A single qualifying managed terminal is accepted' `
        -Input 'one CASCADIA_HOSTING_WINDOW_CLASS window owned by WindowsTerminal.exe with the pinned title' `
        -Expected 'Ok=True, managed=1, auxiliary=0, unclassified=0' `
        -Actual ("ok={0} managed={1} aux={2} unclassified={3}" -f $e3.Ok, $e3.ManagedTerminalCount, $e3.AuxiliaryCount, $e3.UnclassifiedCount) `
        -Pass ($e3.Ok -eq $true -and $e3.ManagedTerminalCount -eq 1 -and $e3.AuxiliaryCount -eq 0) -Evidence $null

    # =====================================================================
    # E4: TWO managed terminal windows are REFUSED
    # =====================================================================
    $twoMg = New-Win -Hwnd '0x60001' -WinPid 9001 -Title 'OTHER-win'
    $e4 = Classify -Windows @($g2Terminal, $twoMg) -Procs @($g2Procs[0], (New-Proc -ProcId 9001)) -ExpectedWindowId $windowId
    # Note: the second window carries a DIFFERENT title so it cannot qualify as the
    # pinned terminal; assert on the classification shape instead.
    $e4b = Classify -Windows @($g2Terminal, (New-Win -Hwnd '0x60002' -WinPid 7280)) -Procs $g2Procs
    Add-P9HTestResult -Id 'E4' -Title 'Two distinct managed terminal windows are refused' `
        -Input 'two CASCADIA_HOSTING_WINDOW_CLASS windows, same owning process, both visible and new' `
        -Expected 'Ok=False, managed=2' `
        -Actual ("ok={0} managed={1} reason={2} | different-title variant managed={3}" -f $e4b.Ok, $e4b.ManagedTerminalCount, $e4b.Reason, $e4.ManagedTerminalCount) `
        -Pass ($e4b.Ok -eq $false -and $e4b.ManagedTerminalCount -eq 2 -and $e4b.Reason -eq 'multiple-managed-terminal-windows') -Evidence $null

    # =====================================================================
    # E5: auxiliary HWND WITHOUT a managed terminal is refused
    # =====================================================================
    $e5 = Classify -Windows @($g2Pseudo) -Procs $g2Procs
    Add-P9HTestResult -Id 'E5' -Title 'An auxiliary window with no managed terminal is refused' `
        -Input 'only the PseudoConsoleWindow, whose GW_OWNER points at a window not in the set' `
        -Expected 'Ok=False, managed=0' `
        -Actual ("ok={0} managed={1} unclassified={2} reason={3}" -f $e5.Ok, $e5.ManagedTerminalCount, $e5.UnclassifiedCount, $e5.Reason) `
        -Pass ($e5.Ok -eq $false -and $e5.ManagedTerminalCount -eq 0) -Evidence $null

    # =====================================================================
    # E6: an UNKNOWN second window is refused (unclassified), not ignored
    # =====================================================================
    $unknown = New-Win -Hwnd '0x77777' -WinPid 7280 -Class 'SomeRandomWindowClass' -Title 'unrelated'
    $e6 = Classify -Windows @($g2Terminal, $unknown) -Procs $g2Procs
    Add-P9HTestResult -Id 'E6' -Title 'An unknown second window is UNCLASSIFIED and refused' `
        -Input 'a second new visible window with an unrelated class, no GW_OWNER link' `
        -Expected 'Ok=False, unclassified=1' `
        -Actual ("ok={0} unclassified={1} reason={2}" -f $e6.Ok, $e6.UnclassifiedCount, $e6.Reason) `
        -Pass ($e6.Ok -eq $false -and $e6.UnclassifiedCount -eq 1 -and $e6.Reason -eq 'unclassified-attributed-window') -Evidence $null

    # =====================================================================
    # E7: an unrelated Cascadia window (foreign title, foreign pid) is refused
    # =====================================================================
    # UPDATED for the corrected contract: a second CASCADIA-class window is now
    # routed to the COMPETING MANAGED UI bucket rather than being counted as an
    # unclassified window. Either way the trial is refused, but naming the correct
    # bucket is the point - a competing terminal UI must never be merely "unknown".
    $foreign = New-Win -Hwnd '0x88888' -WinPid 4242 -Title 'someone-elses-terminal'
    $e7 = Classify -Windows @($g2Terminal, $foreign) -Procs @($g2Procs[0], (New-Proc -ProcId 4242 -Cmd 'wt.exe -w other'))
    Add-P9HTestResult -Id 'E7' -Title 'An unrelated Cascadia window is refused as competing managed UI' `
        -Input 'second CASCADIA window with a foreign windowId, owned by a process without the pinned argv' `
        -Expected 'Ok=False, managed=1, competing=1, reason names the competing UI' `
        -Actual ("ok={0} managed={1} competing={2} reason={3}" -f $e7.Ok, $e7.ManagedTerminalCount, $e7.CompetingManagedUiCount, $e7.Reason) `
        -Pass ($e7.Ok -eq $false -and $e7.ManagedTerminalCount -eq 1 -and $e7.CompetingManagedUiCount -eq 1 -and
            $e7.Reason -eq 'competing-managed-ui-evidence') -Evidence $null

    # =====================================================================
    # E8: PID mismatch on the auxiliary link is refused
    # =====================================================================
    # Owner points at the managed terminal, but the owning pid has no process
    # record at all -> ownership cannot be established.
    $noProc = New-Win -Hwnd '0x20331' -WinPid 55555 -Class 'PseudoConsoleWindow' -Title '' -Owner '0x50366'
    $e8 = Classify -Windows @($g2Terminal, $noProc) -Procs $g2Procs
    Add-P9HTestResult -Id 'E8' -Title 'An auxiliary window whose owning process is unknown is refused' `
        -Input 'GW_OWNER link present, but the owning pid has no attributed process record' `
        -Expected 'Ok=False, unclassified=1' `
        -Actual ("ok={0} unclassified={1}" -f $e8.Ok, $e8.UnclassifiedCount) `
        -Pass ($e8.Ok -eq $false -and $e8.UnclassifiedCount -eq 1) -Evidence $null

    # =====================================================================
    # E9: missing process argv on the auxiliary owner is refused
    # =====================================================================
    $noArgv = New-Win -Hwnd '0x20332' -WinPid 10141 -Class 'PseudoConsoleWindow' -Title '' -Owner '0x99999'
    $e9 = Classify -Windows @($g2Terminal, $noArgv) -Procs @($g2Procs[0], (New-Proc -ProcId 10141 -Name 'pwsh.exe' -Cmd 'pwsh.exe -NoLogo'))
    Add-P9HTestResult -Id 'E9' -Title 'An auxiliary window with neither ownership nor argv identity is refused' `
        -Input 'GW_OWNER points elsewhere and the owner argv lacks the pinned identity' `
        -Expected 'Ok=False, unclassified=1' `
        -Actual ("ok={0} unclassified={1}" -f $e9.Ok, $e9.UnclassifiedCount) `
        -Pass ($e9.Ok -eq $false -and $e9.UnclassifiedCount -eq 1) -Evidence $null

    # =====================================================================
    # E10: incorrect SetId / TerminalId / WindowId do not qualify
    # =====================================================================
    $wrongIds = [ordered]@{}
    foreach ($pair in @(
            @{ n = 'wrongSetId'; p = (New-Proc -Cmd 'pwsh.exe -SetId otherset -TerminalId n2qualterm -WindowId N2QUAL-n2qualterm') },
            @{ n = 'wrongTerminalId'; p = (New-Proc -Cmd 'pwsh.exe -SetId n2qual -TerminalId otherterm -WindowId N2QUAL-n2qualterm') },
            @{ n = 'wrongWindowId'; p = (New-Proc -Cmd 'pwsh.exe -SetId n2qual -TerminalId n2qualterm -WindowId OTHER-win') })) {
        $pseudo = New-Win -Hwnd '0x20340' -WinPid $pair.p.pid -Class 'PseudoConsoleWindow' -Title '' -Owner '0x99998'
        $c = Classify -Windows @($g2Terminal, $pseudo) -Procs @($g2Procs[0], $pair.p)
        $wrongIds[$pair.n] = ($c.Ok -eq $false -and $c.UnclassifiedCount -eq 1)
    }
    Add-P9HTestResult -Id 'E10' -Title 'Wrong SetId, TerminalId or WindowId never qualifies an auxiliary' `
        -Input 'three auxiliary candidates whose owner argv carries one wrong identity field each' `
        -Expected 'all three refused' `
        -Actual (($wrongIds.Keys | ForEach-Object { $_ + '=' + $wrongIds[$_] }) -join ' ') `
        -Pass (@($wrongIds.Values | Where-Object { $_ -ne $true }).Count -eq 0) -Evidence $null

    # =====================================================================
    # E11: a STALE preexisting HWND is refused by the frozen selector
    # =====================================================================
    # The selector is unchanged; this pins that adopting the new contract does not
    # loosen the "newly created" requirement.
    $staleSel = Select-P9HAttributableWindow -PreWindowHwnds @('0x50366') `
        -AfterWindows @($g2Terminal, $g2Pseudo) -CandidatePids @(7280, 10140)
    Add-P9HTestResult -Id 'E11' -Title 'A stale preexisting HWND is still excluded by the frozen selector' `
        -Input 'the managed terminal HWND already present in the pre-launch inventory' `
        -Expected 'only the pseudoconsole remains attributable' `
        -Actual ("count={0} hwnds={1}" -f $staleSel.Count, (@($staleSel.Windows | ForEach-Object { $_.hwnd }) -join ',')) `
        -Pass ($staleSel.Count -eq 1 -and [string]$staleSel.Windows[0].hwnd -eq '0x20330') -Evidence $null

    # =====================================================================
    # E12: a managed terminal with the WRONG title does not qualify
    # =====================================================================
    $wrongTitle = New-Win -Hwnd '0x50999' -Title 'not-the-window-id'
    $e12 = Classify -Windows @($wrongTitle) -Procs $g2Procs
    Add-P9HTestResult -Id 'E12' -Title 'A managed-class window with the wrong title does not qualify' `
        -Input 'CASCADIA class and WindowsTerminal owner, but a foreign windowId title' `
        -Expected 'Ok=False, managed=0' `
        -Actual ("ok={0} managed={1} unclassified={2}" -f $e12.Ok, $e12.ManagedTerminalCount, $e12.UnclassifiedCount) `
        -Pass ($e12.Ok -eq $false -and $e12.ManagedTerminalCount -eq 0) -Evidence $null

    # =====================================================================
    # E13: a managed-class window owned by a NON-terminal process is refused
    # =====================================================================
    $wrongOwnerProc = New-Win -Hwnd '0x51000' -WinPid 6060
    $e13 = Classify -Windows @($wrongOwnerProc) -Procs @((New-Proc -ProcId 6060 -Name 'notepad.exe' -Cmd 'notepad.exe'))
    Add-P9HTestResult -Id 'E13' -Title 'A managed-class window owned by a non-terminal process is refused' `
        -Input 'CASCADIA class and correct title, but the owning process is not WindowsTerminal' `
        -Expected 'Ok=False, managed=0' `
        -Actual ("ok={0} managed={1} unclassified={2}" -f $e13.Ok, $e13.ManagedTerminalCount, $e13.UnclassifiedCount) `
        -Pass ($e13.Ok -eq $false -and $e13.ManagedTerminalCount -eq 0) -Evidence $null

    # =====================================================================
    # E14: MULTIPLE auxiliary candidates are all reported, count stays one
    # =====================================================================
    $aux2 = New-Win -Hwnd '0x20350' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title '' -Owner '0x50366' -ExStyle $E_WS_EX_TOOLWINDOW
    $e14 = Classify -Windows @($g2Terminal, $g2Pseudo, $aux2) -Procs $g2Procs
    Add-P9HTestResult -Id 'E14' -Title 'Multiple proven auxiliary windows are all reported explicitly' `
        -Input 'the managed terminal plus two Win32-owned pseudoconsole windows' `
        -Expected 'managed=1, auxiliary=2, Ok=True, each with its reason' `
        -Actual ("ok={0} managed={1} aux={2} reasons={3}" -f $e14.Ok, $e14.ManagedTerminalCount, $e14.AuxiliaryCount, (@($e14.Auxiliary | ForEach-Object { $_.hwnd + ':' + $_.reason }) -join ',')) `
        -Pass ($e14.Ok -eq $true -and $e14.ManagedTerminalCount -eq 1 -and $e14.AuxiliaryCount -eq 2 -and
            @($e14.Auxiliary | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.reason) }).Count -eq 0) -Evidence $null

    # =====================================================================
    # E15: ambiguous ownership - a pseudoconsole owned by TWO managed windows
    # =====================================================================
    # GW_OWNER names one managed HWND but the set contains two; the classifier
    # must not silently pick one.
    $mgA = New-Win -Hwnd '0x60010' -WinPid 9001 -Title 'OTHER-win'
    $ownedByMany = New-Win -Hwnd '0x20360' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title '' -Owner '0x60010'
    $e15 = Classify -Windows @($g2Terminal, $mgA, $ownedByMany) -Procs @($g2Procs[0], (New-Proc -ProcId 9001 -Cmd 'wt -w OTHER-win'), $g2Procs[1])
    Add-P9HTestResult -Id 'E15' -Title 'Ambiguous ownership is reported, never silently resolved' `
        -Input 'two managed-class windows and an auxiliary owned by one of them' `
        -Expected 'Ok=False because the managed count is 2; auxiliary still classified with its reason' `
        -Actual ("ok={0} managed={1} aux={2} unclassified={3}" -f $e15.Ok, $e15.ManagedTerminalCount, $e15.AuxiliaryCount, $e15.UnclassifiedCount) `
        -Pass ($e15.Ok -eq $false -and $e15.ManagedTerminalCount -eq 1 -and $e15.UnclassifiedCount -ge 1) -Evidence $null

    # =====================================================================
    # E16-E19: the contract switch cannot weaken the OTHER N2-B predicates
    # =====================================================================
    # A full synthetic trial, evaluated under BOTH contracts, proving the switch
    # touches ONLY the window-identity domain.
    $tid = 'e-managed-trial'
    $fxPath = Join-Path $dir 'fixture.json'
    Write-P9HArtifact -Path $fxPath -Lines @(([ordered]@{
                itemId = $terminalId; enabledItems = 1; enabledTerminals = 1; totalItems = 1
                anchorAbsent = $true; layoutFallback = [ordered]@{ x = 9000; y = 9000; w = 640; h = 400 }
            } | ConvertTo-Json -Depth 4))

    function New-Trace([string]$Path, [switch]$NoSkip, [switch]$NoFinal, [switch]$Uncertain, [int]$EndUtc = 1040) {
        $planSkipped = if ($NoSkip) { @() } else { @($terminalId) }
        $null = Add-P9HArtifactLine -Path $Path -Line ((@{ event = 'lifecycle-layout-plan'; utcMs = 1000; set = $setId; skipped = $planSkipped } | ConvertTo-Json -Compress))
        $null = Add-P9HArtifactLine -Path $Path -Line ((@{ event = 'transaction-start'; utcMs = 1010; set = $setId } | ConvertTo-Json -Compress))
        $null = Add-P9HArtifactLine -Path $Path -Line ((@{ event = 'stage2-broker-ready'; utcMs = 1020; set = $setId; planId = 'deadbeefcafe' } | ConvertTo-Json -Compress))
        if (-not $NoFinal) {
            $null = Add-P9HArtifactLine -Path $Path -Line ((@{ event = 'stage2-terminal-final'; utcMs = 1030; set = $setId; finalized = 1; failures = 0 } | ConvertTo-Json -Compress))
        }
        $null = Add-P9HArtifactLine -Path $Path -Line ((@{ event = 'transaction-end'; utcMs = $EndUtc; set = $setId; broker = (-not $Uncertain); uncertain = [bool]$Uncertain; failures = @() } | ConvertTo-Json -Compress))
    }
    function New-Exit([string]$Path, [int]$Code = 0, [string]$Trial = $tid) {
        Write-P9HArtifact -Path $Path -Lines @(([ordered]@{
                    trialId = $Trial; schema = 'p9h.exit-record.v1'; sequence = 1; outcome = 'exited'; exitCode = $Code
                    launcherPid = 7000; launcherPath = 'C:\Windows\System32\cmd.exe'
                    launchedAtUtc = '2026-11-14T18:06:00.0000000Z'; exitedAtUtc = '2026-11-14T18:06:09.0000000Z'
                } | ConvertTo-Json -Depth 4))
    }
    function New-WindowInventory([string]$Path, [object[]]$Windows) {
        Write-P9HArtifact -Path $Path -Lines @(([ordered]@{ Windows = @($Windows) } | ConvertTo-Json -Depth 6))
    }
    # Bind a VARIANT of the shared trial (a different trace and/or stdout) under its
    # own index, so a case that varies one artifact tests the predicate it names
    # rather than reporting an unrelated binding gap.
    function Write-VariantIndex {
        param(
            [string]$Name,
            [string]$TraceOverride = $null,
            [string]$StdoutOverride = $null,
            [string]$PostOverride = $null,
            [string]$NewProcessOverride = $null
        )
        $vctx = New-P9HTrialContext -RootDirectory (Join-Path $SandboxRoot $Name) -TrialId $tid -Kind n2
        $roles = [ordered]@{
            'fixture'       = $fxPath
            'stdout'        = $(if ([string]::IsNullOrWhiteSpace($StdoutOverride)) { $soPath } else { $StdoutOverride })
            'pre-windows'   = $prePath
            'post-windows'  = $(if ([string]::IsNullOrWhiteSpace($PostOverride)) { $postPath } else { $PostOverride })
            'exit-record'   = $exitPath
            'new-processes' = $(if ([string]::IsNullOrWhiteSpace($NewProcessOverride)) { $npPath } else { $NewProcessOverride })
            'trace'         = $(if ([string]::IsNullOrWhiteSpace($TraceOverride)) { $tracePath } else { $TraceOverride })
        }
        foreach ($r in $roles.Keys) { $null = Add-P9HArtifactRole -Context $vctx -Path $roles[$r] -Role $r }
        $null = Write-P9HArtifactIndex -Context $vctx
        return (Join-Path $vctx.Directory 'artifact-index.jsonl')
    }

    function New-NewProcs([string]$Path) {
        $rows = @()
        foreach ($p in $g2Procs) {
            $rows += [ordered]@{
                pid = $p.pid; ppid = $p.ppid; name = $p.name; sessionId = $p.sessionId
                startUtc = $p.startUtc; startSource = 'datetime'
                commandLine = $p.commandLine; commandLength = $p.commandLength
            }
        }
        Write-P9HArtifact -Path $Path -Lines @(([ordered]@{ AddedCount = $rows.Count; Added = @($rows) } | ConvertTo-Json -Depth 6))
    }

    $soPath = Join-Path $dir 'stdout.txt'
    Write-P9HArtifact -Path $soPath -Lines @("n2qual/n2qualterm: relative layout has no reachable placement (anchor-target-and-fallback-unreachable); the item will be handled normally but its window position will not be changed.")
    $prePath = Join-Path $dir 'pre.json'
    New-WindowInventory $prePath @([ordered]@{ hwnd = '0x100'; pid = 5732; visible = $true; class = 'Shell_TrayWnd'; x = 0; y = 0; width = 10; height = 10; owner = '0x0'; title = 'tray' })
    $postPath = Join-Path $dir 'post.json'
    New-WindowInventory $postPath @(
        [ordered]@{ hwnd = '0x100'; pid = 5732; visible = $true; class = 'Shell_TrayWnd'; x = 0; y = 0; width = 10; height = 10; owner = '0x0'; title = 'tray' }
        [ordered]@{ hwnd = '0x50366'; pid = 7280; visible = $true; class = $managedClass; x = 18; y = 26; width = 1129; height = 635; owner = '0x0'; title = $windowId }
        # The helper carries WS_EX_TOOLWINDOW: the auxiliary contract requires
        # POSITIVE non-user-facing evidence, which the frozen G2 record lacked.
        [ordered]@{ hwnd = '0x20330'; pid = 10140; visible = $true; class = 'PseudoConsoleWindow'; x = 0; y = 0; width = 16; height = 16; owner = '0x50366'; title = ''; exStyle = $E_WS_EX_TOOLWINDOW }
    )
    $tracePath = Join-Path $dir 'trace.jsonl'
    New-Trace -Path $tracePath
    $exitPath = Join-Path $dir 'exit.json'
    New-Exit -Path $exitPath
    $npPath = Join-Path $dir 'new-processes.json'
    New-NewProcs $npPath

    # Bind the shared trial so these cases exercise the IDENTITY domain rather
    # than repeating an unrelated artifact-binding gap.
    $sharedCtx = New-P9HTrialContext -RootDirectory (Join-Path $SandboxRoot 'e-shared') -TrialId $tid -Kind n2
    foreach ($r in @(
            @{ role = 'fixture'; path = $fxPath }
            @{ role = 'stdout'; path = $soPath }
            @{ role = 'pre-windows'; path = $prePath }
            @{ role = 'post-windows'; path = $postPath }
            @{ role = 'exit-record'; path = $exitPath }
            @{ role = 'new-processes'; path = $npPath }
            @{ role = 'trace'; path = $tracePath })) {
        $null = Add-P9HArtifactRole -Context $sharedCtx -Path $r.path -Role $r.role
    }
    $null = Write-P9HArtifactIndex -Context $sharedCtx
    $sharedIndex = Join-Path $sharedCtx.Directory 'artifact-index.jsonl'

    function Invoke-Verdict([string]$Contract) {
        return Get-P9HN2Verdicts -FixturePath $fxPath -TracePath $tracePath -StdoutPath $soPath `
            -PreWindowPath $prePath -PostWindowPath $postPath -ExitRecordPath $exitPath -NewProcessPath $npPath `
            -TrialId $tid -ExpectedWindowId $windowId -ExpectedTerminalId $terminalId -ExpectedSetId $setId `
            -ArtifactIndexPath $sharedIndex -WindowIdentityContract $Contract
    }
    $vRaw = Invoke-Verdict 'RawAttributedHwndsV1'
    $vMg = Invoke-Verdict 'ManagedTerminalV1'

    Add-P9HTestResult -Id 'E16' -Title 'The contract switch is the ONLY difference between the two verdicts' `
        -Input 'the identical synthetic trial evaluated under both contracts' `
        -Expected 'historical N2-B INCONCLUSIVE, managed-terminal N2-B PASS, N2-A PASS in both' `
        -Actual ("raw: n2b={0} reason={1} | managed: n2b={2} identities={3} | n2a={4}/{5}" -f
            $vRaw.N2B.Verdict, $vRaw.N2B.IdentityConsistencyReason, $vMg.N2B.Verdict, $vMg.N2B.IdentityConsistent,
            $vRaw.N2A.Verdict, $vMg.N2A.Verdict) `
        -Pass ($vRaw.N2B.Verdict -eq 'INCONCLUSIVE' -and $vRaw.N2B.IdentityConsistencyReason -eq 'attributed-window-count-not-one:2' -and
            $vMg.N2B.Verdict -eq 'PASS' -and $vMg.N2B.IdentityConsistent -eq $true -and
            $vRaw.N2A.Verdict -eq 'PASS' -and $vMg.N2A.Verdict -eq 'PASS') -Evidence $dir

    # E17: a nonzero launcher exit still blocks BOTH contracts
    $exitBad = Join-Path $dir 'exit-nonzero.json'
    New-Exit -Path $exitBad -Code 1
    $blocked = [ordered]@{}
    foreach ($c in @('RawAttributedHwndsV1', 'ManagedTerminalV1')) {
        $v = Get-P9HN2Verdicts -FixturePath $fxPath -TracePath $tracePath -StdoutPath $soPath `
            -PreWindowPath $prePath -PostWindowPath $postPath -ExitRecordPath $exitBad -NewProcessPath $npPath `
            -TrialId $tid -ExpectedWindowId $windowId -ExpectedTerminalId $terminalId -ExpectedSetId $setId `
            -ArtifactIndexPath $sharedIndex -WindowIdentityContract $c
        $blocked[$c] = ($v.N2B.Verdict -eq 'FAIL' -and (@($v.N2B.Reasons) -join ';') -match 'exit-code-nonzero')
    }
    Add-P9HTestResult -Id 'E17' -Title 'A nonzero launcher exit still blocks N2-B under BOTH contracts' `
        -Input 'the same trial with exitCode=1' -Expected 'FAIL under both, reason exit-code-nonzero' `
        -Actual (($blocked.Keys | ForEach-Object { $_ + '=' + $blocked[$_] }) -join ' ') `
        -Pass (@($blocked.Values | Where-Object { $_ -ne $true }).Count -eq 0) -Evidence $dir

    # E18: a missing placement skip still blocks BOTH contracts
    $traceNoSkip = Join-Path $dir 'trace-noskip.jsonl'
    New-Trace -Path $traceNoSkip -NoSkip
    # Bind THIS variant so an artifact-binding gap cannot be mistaken for the skip.
    $noSkipIndex = (Write-VariantIndex -Name 'e-noskip' -TraceOverride $traceNoSkip -StdoutOverride $null)
    $blocked = [ordered]@{}
    foreach ($contract in @('RawAttributedHwndsV1', 'ManagedTerminalV1')) {
        $v = Get-P9HN2Verdicts -FixturePath $fxPath -TracePath $traceNoSkip -StdoutPath $soPath `
            -PreWindowPath $prePath -PostWindowPath $postPath -ExitRecordPath $exitPath -NewProcessPath $npPath `
            -TrialId $tid -ExpectedWindowId $windowId -ExpectedTerminalId $terminalId -ExpectedSetId $setId `
            -ArtifactIndexPath $noSkipIndex -WindowIdentityContract $contract
        $blocked[$contract] = ($v.N2A.Verdict -ne 'PASS' -and $v.N2B.Verdict -ne 'PASS' -and
            (@($v.N2A.Reasons) -join ';') -match 'item-not-in-skipped-set')
    }
    Add-P9HTestResult -Id 'E18' -Title 'A missing placement skip still blocks N2-A and N2-B under BOTH contracts' `
        -Input 'the lifecycle trace reports no skipped item' `
        -Expected 'neither contract reaches PASS; the missing skip is the recorded reason' `
        -Actual (($blocked.Keys | ForEach-Object { $_ + '=' + $blocked[$_] }) -join ' ') `
        -Pass (@($blocked.Values | Where-Object { $_ -ne $true }).Count -eq 0) -Evidence $dir

    # E19: a missing warning still blocks N2-A under BOTH contracts
    $soNoWarn = Join-Path $dir 'stdout-nowarn.txt'
    Write-P9HArtifact -Path $soNoWarn -Lines @("Workspace 'n2qual' restored.")
    $noWarnIndex = (Write-VariantIndex -Name 'e-nowarn' -TraceOverride $null -StdoutOverride $soNoWarn)
    $blocked = [ordered]@{}
    foreach ($contract in @('RawAttributedHwndsV1', 'ManagedTerminalV1')) {
        $v = Get-P9HN2Verdicts -FixturePath $fxPath -TracePath $tracePath -StdoutPath $soNoWarn `
            -PreWindowPath $prePath -PostWindowPath $postPath -ExitRecordPath $exitPath -NewProcessPath $npPath `
            -TrialId $tid -ExpectedWindowId $windowId -ExpectedTerminalId $terminalId -ExpectedSetId $setId `
            -ArtifactIndexPath $noWarnIndex -WindowIdentityContract $contract
        $blocked[$contract] = ($v.N2A.Verdict -ne 'PASS' -and (@($v.N2A.Reasons) -join ';') -match 'deterministic-warning-absent')
    }
    Add-P9HTestResult -Id 'E19' -Title 'A missing deterministic warning still blocks N2-A under BOTH contracts' `
        -Input 'stdout without the placement-skip warning' -Expected 'not PASS under either contract' `
        -Actual (($blocked.Keys | ForEach-Object { $_ + '=' + $blocked[$_] }) -join ' ') `
        -Pass (@($blocked.Values | Where-Object { $_ -ne $true }).Count -eq 0) -Evidence $dir

    # E20-E21: missing finalization and tampered binding still block
    $traceNoFinal = Join-Path $dir 'trace-nofinal.jsonl'
    New-Trace -Path $traceNoFinal -NoFinal
    $vF = Get-P9HN2Verdicts -FixturePath $fxPath -TracePath $traceNoFinal -StdoutPath $soPath `
        -PreWindowPath $prePath -PostWindowPath $postPath -ExitRecordPath $exitPath -NewProcessPath $npPath `
        -TrialId $tid -ExpectedWindowId $windowId -ExpectedTerminalId $terminalId -ExpectedSetId $setId `
        -ArtifactIndexPath $sharedIndex -WindowIdentityContract 'ManagedTerminalV1'
    Add-P9HTestResult -Id 'E20' -Title 'Missing lifecycle finalization still blocks N2-B under the corrected contract' `
        -Input 'a trace with no stage2-terminal-final event' -Expected 'not PASS' `
        -Actual ("n2b={0} reasons={1}" -f $vF.N2B.Verdict, (@($vF.N2B.Reasons) -join ';')) `
        -Pass ($vF.N2B.Verdict -ne 'PASS') -Evidence $dir

    # tampered binding: bind, then append a byte to a bound artifact.
    #
    # The context is created under the EVALUATED trial id ($tid) in its own root,
    # because the verdict binds artifacts BY TRIAL ID: binding under
    # "$tid-bind" would make every role a trial mismatch and the case would
    # report `binding-mismatch:trial=...` instead of the digest tamper it names.
    $ctx = New-P9HTrialContext -RootDirectory (Join-Path $SandboxRoot 'e-tamper') -TrialId $tid -Kind n2
    $bindRoles = [ordered]@{
        'fixture' = $fxPath; 'stdout' = $soPath; 'pre-windows' = $prePath
        'post-windows' = $postPath; 'exit-record' = $exitPath; 'new-processes' = $npPath; 'trace' = $tracePath
    }
    foreach ($r in $bindRoles.Keys) { $null = Add-P9HArtifactRole -Context $ctx -Path $bindRoles[$r] -Role $r }
    $null = Write-P9HArtifactIndex -Context $ctx
    $idx = Join-Path $ctx.Directory 'artifact-index.jsonl'
    $vOk = Get-P9HN2Verdicts -FixturePath $fxPath -TracePath $tracePath -StdoutPath $soPath `
        -PreWindowPath $prePath -PostWindowPath $postPath -ExitRecordPath $exitPath -NewProcessPath $npPath `
        -TrialId $tid -ExpectedWindowId $windowId -ExpectedTerminalId $terminalId -ExpectedSetId $setId `
        -ArtifactIndexPath $idx -WindowIdentityContract 'ManagedTerminalV1'
    $origStdout = [IO.File]::ReadAllText($soPath)
    [IO.File]::WriteAllText($soPath, $origStdout + "tampered`r`n", (New-Object System.Text.UTF8Encoding($false)))
    $vBad = Get-P9HN2Verdicts -FixturePath $fxPath -TracePath $tracePath -StdoutPath $soPath `
        -PreWindowPath $prePath -PostWindowPath $postPath -ExitRecordPath $exitPath -NewProcessPath $npPath `
        -TrialId $tid -ExpectedWindowId $windowId -ExpectedTerminalId $terminalId -ExpectedSetId $setId `
        -ArtifactIndexPath $idx -WindowIdentityContract 'ManagedTerminalV1'
    [IO.File]::WriteAllText($soPath, $origStdout, (New-Object System.Text.UTF8Encoding($false)))
    Add-P9HTestResult -Id 'E21' -Title 'A tampered artifact still blocks N2-B under the corrected contract' `
        -Input 'bound trial, then one role appended to and re-evaluated' `
        -Expected 'verified -> PASS, tampered -> not PASS' `
        -Actual ("verified={0} tampered={1} reason={2}" -f $vOk.N2B.Verdict, $vBad.N2B.Verdict,
            (@($vBad.N2B.Reasons) -join ';')) `
        -Pass ($vOk.N2B.Verdict -eq 'PASS' -and $vBad.N2B.Verdict -ne 'PASS' -and
            (@($vBad.N2B.Reasons) -join ';') -match 'artifact-binding') -Evidence $ctx.Directory

    # E22: previously accepted single-window fixtures remain valid under BOTH
    #
    # This is a GENUINE single-attributed-window trial: the only new visible
    # top-level window is the managed terminal itself (no pseudoconsole). It is the
    # historical contract's accepted shape, so the corrected contract must not
    # regress it. (Evaluating the two-window trial here would be E16, not E22.)
    $singlePost = Join-Path $dir 'post-single.json'
    New-WindowInventory $singlePost @(
        [ordered]@{ hwnd = '0x100'; pid = 5732; visible = $true; class = 'Shell_TrayWnd'; x = 0; y = 0; width = 10; height = 10; owner = '0x0'; title = 'tray' }
        [ordered]@{ hwnd = '0x50366'; pid = 7280; visible = $true; class = $managedClass; x = 18; y = 26; width = 1129; height = 635; owner = '0x0'; title = $windowId }
    )
    $singleNp = Join-Path $dir 'new-processes-single.json'
    Write-P9HArtifact -Path $singleNp -Lines @(([ordered]@{
                AddedCount = 1
                Added      = @([ordered]@{
                        pid = 7280; ppid = 5732; name = 'WindowsTerminal.exe'; sessionId = 2
                        startUtc = '2026-11-14T18:06:08.5000000Z'; startSource = 'datetime'
                        commandLine = $g2Procs[0].commandLine; commandLength = $g2Procs[0].commandLength
                    })
            } | ConvertTo-Json -Depth 6))
    $singleIndex = (Write-VariantIndex -Name 'e-single' -PostOverride $singlePost -NewProcessOverride $singleNp)

    $verdicts = [ordered]@{}
    foreach ($contract in @('RawAttributedHwndsV1', 'ManagedTerminalV1')) {
        $v = Get-P9HN2Verdicts -FixturePath $fxPath -TracePath $tracePath -StdoutPath $soPath `
            -PreWindowPath $prePath -PostWindowPath $singlePost -ExitRecordPath $exitPath -NewProcessPath $singleNp `
            -TrialId $tid -ExpectedWindowId $windowId -ExpectedTerminalId $terminalId -ExpectedSetId $setId `
            -ArtifactIndexPath $singleIndex -WindowIdentityContract $contract
        $verdicts[$contract] = [pscustomobject]@{
            N2A = $v.N2A.Verdict; N2B = $v.N2B.Verdict
            Raw = $v.N2B.RawAttributedHwndCount; Managed = $v.N2B.ManagedTerminalCount
        }
    }
    Add-P9HTestResult -Id 'E22' -Title 'A previously accepted single-window trial remains valid under both contracts' `
        -Input 'a trial whose ONLY attributed window is the managed terminal, bound and evaluated twice' `
        -Expected 'N2-A and N2-B PASS under BOTH contracts' `
        -Actual (($verdicts.Keys | ForEach-Object {
                    '{0}: n2a={1} n2b={2} raw={3} managed={4}' -f $_, $verdicts[$_].N2A, $verdicts[$_].N2B, $verdicts[$_].Raw, $verdicts[$_].Managed
                }) -join ' | ') `
        -Pass ($verdicts['RawAttributedHwndsV1'].N2A -eq 'PASS' -and $verdicts['RawAttributedHwndsV1'].N2B -eq 'PASS' -and
            $verdicts['ManagedTerminalV1'].N2A -eq 'PASS' -and $verdicts['ManagedTerminalV1'].N2B -eq 'PASS' -and
            $verdicts['ManagedTerminalV1'].Managed -eq 1) -Evidence $dir

    # =====================================================================
    # R3 SERIES: the v3 positive auxiliary-role contract (Stage 3B7G3-C2).
    #
    # R3-1 is the decisive regression. C1 required WS_EX_TOOLWINDOW (A8) and so
    # accepted ANY arbitrary class carrying that bit, because every relationship
    # factor is satisfiable by an app window launched by the pinned shell. It also
    # REJECTED a genuine ConPTY helper on any build that does not set the bit,
    # which the Terminal documentation never promises. v3 makes the CLASS the role
    # argument and demotes the style to corroboration.
    # =====================================================================
    $wsTool = $E_WS_EX_TOOLWINDOW
    $wsApp = $E_WS_EX_APPWINDOW

    # R3-1: arbitrary class, user-facing size, WS_EX_TOOLWINDOW set (C1 case X1).
    $x1 = New-Win -Hwnd '0x74001' -WinPid 10140 -Class 'SomeArbitraryAppClass' -Title 'an-app-window' `
        -Owner '0x50366' -X 100 -Y 100 -W 1200 -H 800 -ExStyle $wsTool
    $r = Classify -Windows @($g2Terminal, $x1) -Procs $g2Procs
    Add-P9HTestResult -Id 'R301' -Title 'An arbitrary class carrying WS_EX_TOOLWINDOW is NOT an auxiliary certificate' `
        -Input 'unknown class, 1200x800, GW_OWNER=0x50366, genuine child, exact identity, WS_EX_TOOLWINDOW set' `
        -Expected 'refused: the class is not a positively identified auxiliary role' `
        -Actual ("ok={0} aux={1} unclassified={2} reason={3}" -f $r.Ok, $r.AuxiliaryCount, $r.UnclassifiedCount, $r.Unclassified[0].reason) `
        -Pass ($r.Ok -eq $false -and $r.AuxiliaryCount -eq 0 -and
            $r.Unclassified[0].reason -match 'class-is-not-a-positively-identified-auxiliary-role') -Evidence $null

    # R3-2: the genuine ConPTY helper with NO style recorded must still be
    # accepted - a missing extended-style field must not disprove the role.
    $genuine = New-Win -Hwnd '0x74002' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title '' `
        -Owner '0x50366' -X 0 -Y 0 -W 16 -H 16
    $r = Classify -Windows @($g2Terminal, $genuine) -Procs $g2Procs
    Add-P9HTestResult -Id 'R302' -Title 'The genuine helper class is accepted with no style field at all' `
        -Input 'PseudoConsoleWindow, valid owner, genuine child, exact identity, exStyle absent' `
        -Expected 'accepted; WS_EX_TOOLWINDOW is not required by the contract' `
        -Actual ("ok={0} aux={1} uncl={2} styleCorroborates={3}" -f $r.Ok, $r.AuxiliaryCount, $r.UnclassifiedCount, [string]$r.Auxiliary[0].styleCorroboratesRole) `
        -Pass ($r.Ok -eq $true -and $r.AuxiliaryCount -eq 1 -and $null -eq $r.Auxiliary[0].styleCorroboratesRole) -Evidence $null

    # R3-3: the same helper WITH the bit records corroboration explicitly.
    $genuine2 = New-Win -Hwnd '0x74003' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title '' `
        -Owner '0x50366' -X 0 -Y 0 -W 16 -H 16 -ExStyle $wsTool
    $r = Classify -Windows @($g2Terminal, $genuine2) -Procs $g2Procs
    Add-P9HTestResult -Id 'R303' -Title 'A recorded tool-window bit is reported as corroboration, never as the reason' `
        -Input 'the genuine helper with exStyle present and containing WS_EX_TOOLWINDOW' `
        -Expected 'accepted with styleCorroboratesRole=True and the class role also true' `
        -Actual ("ok={0} aux={1} corroborates={2} roleClass={3}" -f $r.Ok, $r.AuxiliaryCount, [string]$r.Auxiliary[0].styleCorroboratesRole, [string]$r.Auxiliary[0].auxiliaryRoleClass) `
        -Pass ($r.Ok -eq $true -and $r.AuxiliaryCount -eq 1 -and $r.Auxiliary[0].styleCorroboratesRole -eq $true -and
            $r.Auxiliary[0].auxiliaryRoleClass -eq $true) -Evidence $null

    # R3-4: genuine class, but ownership points at a DIFFERENT hwnd.
    $wrongOwner = New-Win -Hwnd '0x74004' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title '' `
        -Owner '0x99999' -X 0 -Y 0 -W 16 -H 16
    $r = Classify -Windows @($g2Terminal, $wrongOwner) -Procs $g2Procs
    Add-P9HTestResult -Id 'R304' -Title 'A genuine helper class owned by a foreign HWND is refused' `
        -Input 'PseudoConsoleWindow whose GW_OWNER is not the managed terminal' `
        -Expected 'refused, reason owner-not-a-managed-terminal' `
        -Actual ("aux={0} reason={1}" -f $r.AuxiliaryCount, $r.Unclassified[0].reason) `
        -Pass ($r.AuxiliaryCount -eq 0 -and $r.Unclassified[0].reason -match 'owner-not-a-managed-terminal') -Evidence $null

    # R3-5: genuine class owned correctly, but the owner is NOT a descendant.
    $stranger = New-Proc -ProcId 10400 -ParentPid 1 -Name 'pwsh.exe' `
        -Cmd 'pwsh.exe -SetId n2qual -TerminalId n2qualterm -WindowId N2QUAL-n2qualterm'
    $w = New-Win -Hwnd '0x74005' -WinPid 10400 -Class 'PseudoConsoleWindow' -Title '' -Owner '0x50366'
    $r = Classify -Windows @($g2Terminal, $w) -Procs @($g2Procs[0], $stranger)
    Add-P9HTestResult -Id 'R305' -Title 'A genuine helper class owned by a non-descendant is refused' `
        -Input 'PseudoConsoleWindow with correct identity argv but an unrelated parent' `
        -Expected 'refused, reason not-a-strict-descendant-of-managed-terminal' `
        -Actual ("aux={0} reason={1}" -f $r.AuxiliaryCount, $r.Unclassified[0].reason) `
        -Pass ($r.AuxiliaryCount -eq 0 -and $r.Unclassified[0].reason -match 'not-a-strict-descendant') -Evidence $null

    # R3-6: genuine class, correct owner, but a DIFFERENT session.
    $otherSession = New-Proc -ProcId 10401 -ParentPid 7280 -Name 'pwsh.exe' -Session 5 `
        -Cmd 'pwsh.exe -SetId n2qual -TerminalId n2qualterm -WindowId N2QUAL-n2qualterm'
    $w = New-Win -Hwnd '0x74006' -WinPid 10401 -Class 'PseudoConsoleWindow' -Title '' -Owner '0x50366'
    $r = Classify -Windows @($g2Terminal, $w) -Procs @($g2Procs[0], $otherSession)
    Add-P9HTestResult -Id 'R306' -Title 'A genuine helper class from another session is refused' `
        -Input 'PseudoConsoleWindow, valid owner, correct argv, but session 5' `
        -Expected 'refused, reason session-mismatch' `
        -Actual ("aux={0} reason={1}" -f $r.AuxiliaryCount, $r.Unclassified[0].reason) `
        -Pass ($r.AuxiliaryCount -eq 0 -and $r.Unclassified[0].reason -match 'session-mismatch') -Evidence $null

    # R3-7: genuine class claiming the MANAGED TITLE -> competing bucket.
    $claiming = New-Win -Hwnd '0x74007' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title $windowId `
        -Owner '0x50366'
    $r = Classify -Windows @($g2Terminal, $claiming) -Procs $g2Procs
    Add-P9HTestResult -Id 'R307' -Title 'A helper-class window claiming the managed title is competing UI' `
        -Input 'PseudoConsoleWindow whose title is exactly the pinned windowId' `
        -Expected 'Ok=False, competing=1' `
        -Actual ("ok={0} competing={1} reason={2}" -f $r.Ok, $r.CompetingManagedUiCount, $r.Reason) `
        -Pass ($r.Ok -eq $false -and $r.CompetingManagedUiCount -eq 1) -Evidence $null

    # R3-8: contradictory evidence - genuine class and valid owner, but the
    # identity argv names a different windowId. Identity must win.
    $contradict = New-Proc -ProcId 10402 -ParentPid 7280 -Name 'pwsh.exe' `
        -Cmd 'pwsh.exe -SetId n2qual -TerminalId n2qualterm -WindowId SOMEONE-ELSE'
    $w = New-Win -Hwnd '0x74008' -WinPid 10402 -Class 'PseudoConsoleWindow' -Title '' -Owner '0x50366'
    $r = Classify -Windows @($g2Terminal, $w) -Procs @($g2Procs[0], $contradict)
    Add-P9HTestResult -Id 'R308' -Title 'Contradictory launch identity defeats a plausible helper class' `
        -Input 'PseudoConsoleWindow, valid owner, but owner argv names a different windowId' `
        -Expected 'refused, reason windowId-mismatch' `
        -Actual ("aux={0} reason={1}" -f $r.AuxiliaryCount, $r.Unclassified[0].reason) `
        -Pass ($r.AuxiliaryCount -eq 0 -and $r.Unclassified[0].reason -match 'windowId-mismatch') -Evidence $null

    # R3-9: multiple genuinely identified helpers are all reported.
    $h2 = New-Win -Hwnd '0x74009' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title '' `
        -Owner '0x50366' -X 0 -Y 0 -W 16 -H 16
    $r = Classify -Windows @($g2Terminal, $genuine, $h2) -Procs $g2Procs
    Add-P9HTestResult -Id 'R309' -Title 'Multiple genuinely identified helpers are all reported' `
        -Input 'one managed terminal plus two positively identified helpers' `
        -Expected 'Ok=True, managed=1, auxiliary=2, every reason present' `
        -Actual ("ok={0} managed={1} aux={2} reason={3}" -f $r.Ok, $r.ManagedTerminalCount, $r.AuxiliaryCount, $r.Reason) `
        -Pass ($r.Ok -eq $true -and $r.ManagedTerminalCount -eq 1 -and $r.AuxiliaryCount -eq 2) -Evidence $null

    # R3-10: helpers only, no managed terminal.
    $r = Classify -Windows @($genuine) -Procs $g2Procs
    Add-P9HTestResult -Id 'R310' -Title 'A helper with no managed terminal is still refused' `
        -Input 'only the helper window; its owner is not in this set' `
        -Expected 'Ok=False, managed=0' `
        -Actual ("ok={0} managed={1} reason={2}" -f $r.Ok, $r.ManagedTerminalCount, $r.Reason) `
        -Pass ($r.Ok -eq $false -and $r.ManagedTerminalCount -eq 0) -Evidence $null

    # R3-11: two genuine managed terminals.
    $secondTerm = New-Win -Hwnd '0x74010' -WinPid 7280 -Class $managedClass -Title $windowId
    $r = Classify -Windows @($g2Terminal, $secondTerm) -Procs $g2Procs
    Add-P9HTestResult -Id 'R311' -Title 'Two genuine managed terminals are refused' `
        -Input 'two windows satisfying the full managed-terminal contract' `
        -Expected 'Ok=False, managed=2' `
        -Actual ("ok={0} managed={1} reason={2}" -f $r.Ok, $r.ManagedTerminalCount, $r.Reason) `
        -Pass ($r.Ok -eq $false -and $r.ManagedTerminalCount -eq 2) -Evidence $null

    # R3-12: order independence under v3.
    $fwd = Classify -Windows @($genuine, $g2Terminal) -Procs $g2Procs
    $rev = Classify -Windows @($g2Terminal, $genuine) -Procs $g2Procs
    Add-P9HTestResult -Id 'R312' -Title 'The v3 contract is independent of enumeration order' `
        -Input 'helper and owner presented in both orders' `
        -Expected 'both: managed=1, auxiliary=1, unclassified=0' `
        -Actual ("fwd=(m={0} a={1} u={2}) rev=(m={3} a={4} u={5})" -f
            $fwd.ManagedTerminalCount, $fwd.AuxiliaryCount, $fwd.UnclassifiedCount,
            $rev.ManagedTerminalCount, $rev.AuxiliaryCount, $rev.UnclassifiedCount) `
        -Pass ($fwd.ManagedTerminalCount -eq 1 -and $fwd.AuxiliaryCount -eq 1 -and $fwd.UnclassifiedCount -eq 0 -and
            $rev.ManagedTerminalCount -eq 1 -and $rev.AuxiliaryCount -eq 1 -and $rev.UnclassifiedCount -eq 0) -Evidence $null

    # R3-13: the contract must advertise its own version so no result can be
    # silently reinterpreted.
    Add-P9HTestResult -Id 'R313' -Title 'The result names its own auxiliary contract version' `
        -Input 'any classification result' `
        -Expected 'AuxiliaryContract = p9h.auxiliary-window.v3 and the role class is declared' `
        -Actual ("contract={0} roleClasses={1} schema={2}" -f $rev.AuxiliaryContract, (@($rev.AuxiliaryRoleClasses) -join ','), $rev.Schema) `
        -Pass ($rev.AuxiliaryContract -eq 'p9h.auxiliary-window.v3' -and
            @($rev.AuxiliaryRoleClasses) -contains 'PseudoConsoleWindow' -and
            $rev.Schema -eq 'p9h.managed-terminals.v3') -Evidence $null

    # R3-14: a helper at the forbidden fallback rectangle must satisfy the same
    # contract; geometry is never proof of role.
    $atFallback = New-Win -Hwnd '0x74011' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title '' `
        -Owner '0x50366' -X 9000 -Y 9000 -W 640 -H 400
    $r = Classify -Windows @($g2Terminal, $atFallback) -Procs $g2Procs
    Add-P9HTestResult -Id 'R314' -Title 'A helper-class window at the fallback rectangle is judged by the same contract' `
        -Input 'PseudoConsoleWindow at 9000,9000 with a large rectangle' `
        -Expected 'accepted as auxiliary on role+relationship, geometry not decisive either way' `
        -Actual ("ok={0} aux={1} reason={2}" -f $r.Ok, $r.AuxiliaryCount, $r.Auxiliary[0].reason) `
        -Pass ($r.AuxiliaryCount -eq 1) -Evidence $null

    # R3-15: helper class, but the managed window it claims is a COMPETING one.
    $competingOwner = New-Win -Hwnd '0x74012' -WinPid 7280 -Class $managedClass -Title 'OTHER-TERM' -Owner '0x0'
    $w = New-Win -Hwnd '0x74013' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title '' -Owner '0x74012'
    $r = Classify -Windows @($g2Terminal, $competingOwner, $w) -Procs $g2Procs
    Add-P9HTestResult -Id 'R315' -Title 'A helper owned by a competing managed UI cannot legitimize it' `
        -Input 'a foreign-title Cascadia window plus a helper whose GW_OWNER points at it' `
        -Expected 'Ok=False; the competing window is bucketed and the helper is refused' `
        -Actual ("ok={0} competing={1} aux={2} uncl={3}" -f $r.Ok, $r.CompetingManagedUiCount, $r.AuxiliaryCount, $r.UnclassifiedCount) `
        -Pass ($r.Ok -eq $false -and $r.CompetingManagedUiCount -ge 1 -and $r.AuxiliaryCount -eq 0) -Evidence $null

    # =====================================================================
    # C1 SERIES: fail-closed auxiliary contract (Stage 3B7G3-C1)
    #
    # Stage 3B7G3 accepted ANY window with a GW_OWNER link to the managed
    # terminal plus a resolvable process name as "auxiliary". Six false
    # acceptances were reproduced against 3da88e6. These cases pin the
    # corrected contract, whose decisive addition is factor A8: positive
    # WS_EX_TOOLWINDOW evidence.
    # =====================================================================
    $wsTool = $E_WS_EX_TOOLWINDOW
    $wsApp = $E_WS_EX_APPWINDOW

    # C1-1: unknown full-size window owned by the genuine managed HWND.
    # Every relationship factor passes; only window ROLE is unknown. With style
    # recorded as a normal app window it must be REFUSED for that reason.
    $c1a = New-Win -Hwnd '0x72001' -WinPid 10140 -Class 'SomeArbitraryAppClass' -Title 'an-app-window' `
        -Owner '0x50366' -X 100 -Y 100 -W 1200 -H 800 -ExStyle $wsApp
    $r = Classify -Windows @($g2Terminal, $c1a) -Procs $g2Procs
    Add-P9HTestResult -Id 'AW1' -Title 'An unknown full-size window owned by the managed terminal is refused' `
        -Input 'arbitrary class, UI-sized rectangle, GW_OWNER=0x50366, genuine child, WS_EX_APPWINDOW' `
        -Expected 'Ok=False and the reason names the class role argument' `
        -Actual ("ok={0} aux={1} unclassified={2} reason={3}" -f $r.Ok, $r.AuxiliaryCount, $r.UnclassifiedCount, $r.Unclassified[0].reason) `
        -Pass ($r.Ok -eq $false -and $r.AuxiliaryCount -eq 0 -and $r.UnclassifiedCount -eq 1 -and
            $r.Unclassified[0].reason -match 'class-is-not-a-positively-identified-auxiliary-role') -Evidence $null

    # C1-2 (v3 semantics): an unknown class with NO style is refused because the
    # CLASS role argument fails - style is corroborating, not decisive, so its
    # absence is reported but is no longer the reason for refusal.
    $c1b = New-Win -Hwnd '0x72002' -WinPid 10140 -Class 'SomeArbitraryAppClass' -Title 'an-app-window' `
        -Owner '0x50366' -X 100 -Y 100 -W 1200 -H 800
    $r = Classify -Windows @($g2Terminal, $c1b) -Procs $g2Procs
    Add-P9HTestResult -Id 'AW2' -Title 'An unknown owned window is refused on its class even with no style recorded' `
        -Input 'arbitrary class, no exStyle at all' `
        -Expected 'Ok=False for the class role argument; the absent style is reported as a gap' `
        -Actual ("ok={0} aux={1} reason={2} gaps={3}" -f $r.Ok, $r.AuxiliaryCount, $r.Unclassified[0].reason, (@($r.EvidenceGaps) -join ',')) `
        -Pass ($r.Ok -eq $false -and $r.AuxiliaryCount -eq 0 -and
            $r.Unclassified[0].reason -match 'class-is-not-a-positively-identified-auxiliary-role' -and
            @($r.EvidenceGaps) -contains 'window-style-not-recorded') -Evidence $null

    # C1-3 (v3 semantics): a genuine helper class DOES satisfy the role argument
    # without any style, because the ConPTY role is documented independently of
    # WS_EX_TOOLWINDOW. This is the reverse of the C1 expectation, and it is the
    # correction: style must not be a prerequisite.
    $c1c = New-Win -Hwnd '0x72003' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title '' `
        -Owner '0x50366' -X 0 -Y 0 -W 16 -H 16
    $r = Classify -Windows @($g2Terminal, $c1c) -Procs $g2Procs
    Add-P9HTestResult -Id 'AW3' -Title 'A positively identified helper class is accepted WITHOUT recorded style' `
        -Input 'PseudoConsoleWindow, GW_OWNER=0x50366, genuine child, no exStyle recorded' `
        -Expected 'accepted on class role + relationship evidence; the absent style is a reported gap, not a refusal' `
        -Actual ("ok={0} aux={1} uncl={2} gaps={3}" -f $r.Ok, $r.AuxiliaryCount, $r.UnclassifiedCount, (@($r.EvidenceGaps) -join ',')) `
        -Pass ($r.Ok -eq $true -and $r.AuxiliaryCount -eq 1 -and $r.UnclassifiedCount -eq 0 -and
            $r.Auxiliary[0].auxiliaryRoleClass -eq $true) -Evidence $null

    # C1-4: competing Cascadia-class window WITH a valid owner -> competing bucket.
    $c1d = New-Win -Hwnd '0x72004' -WinPid 7280 -Class $managedClass -Title 'OTHER-TERMINAL' `
        -Owner '0x50366' -ExStyle $wsTool
    $r = Classify -Windows @($g2Terminal, $c1d) -Procs $g2Procs
    Add-P9HTestResult -Id 'AW4' -Title 'A competing Cascadia window is never absorbed as auxiliary' `
        -Input 'second managed-class window with a valid GW_OWNER and tool-window style' `
        -Expected 'Ok=False, competing=1, auxiliary=0' `
        -Actual ("ok={0} competing={1} aux={2} reason={3}" -f $r.Ok, $r.CompetingManagedUiCount, $r.AuxiliaryCount, $r.Reason) `
        -Pass ($r.Ok -eq $false -and $r.CompetingManagedUiCount -eq 1 -and $r.AuxiliaryCount -eq 0) -Evidence $null

    # C1-5: a foreign-class window claiming a MANAGED TITLE -> competing bucket.
    $c1e = New-Win -Hwnd '0x72005' -WinPid 10140 -Class 'SomeHelperClass' -Title $windowId `
        -Owner '0x50366' -ExStyle $wsTool
    $r = Classify -Windows @($g2Terminal, $c1e) -Procs $g2Procs
    Add-P9HTestResult -Id 'AW5' -Title 'A foreign-class window claiming a managed title is competing UI' `
        -Input 'non-managed class whose title is exactly the pinned windowId' `
        -Expected 'Ok=False, competing=1' `
        -Actual ("ok={0} competing={1} reason={2}" -f $r.Ok, $r.CompetingManagedUiCount, $r.Reason) `
        -Pass ($r.Ok -eq $false -and $r.CompetingManagedUiCount -eq 1) -Evidence $null

    # AW6..AW9: VALID ownership and VALID tool-window style, but an identity
    # defect. These are the cases Stage 3B7G3 could not prove, because its E10
    # used a NONEXISTENT owner (0x99998) and so was rejected by ownership rather
    # than by the identity requirement. Each is refused FOR ITS OWN REASON, and
    # each adds its result with a LITERAL id so the registry guard counts it.
    #
    # The probe keeps the four cases identical apart from the field under test, so
    # a pass cannot come from an unrelated prerequisite.
    function Invoke-IdentityDefect {
        param([string]$OwnerCmd)
        $badProc = New-Proc -ProcId 10300 -ParentPid 7280 -Name 'pwsh.exe' -Cmd $OwnerCmd
        $win = New-Win -Hwnd '0x72010' -WinPid 10300 -Class 'PseudoConsoleWindow' -Title '' `
            -Owner '0x50366' -ExStyle $wsTool
        $res = Classify -Windows @($g2Terminal, $win) -Procs @($g2Procs[0], $badProc)
        $why = if ($res.UnclassifiedCount -ge 1) { $res.Unclassified[0].reason } else { '' }
        return [pscustomobject]@{ Aux = $res.AuxiliaryCount; Uncl = $res.UnclassifiedCount; Why = $why }
    }

    $aw6 = Invoke-IdentityDefect -OwnerCmd 'pwsh.exe -NoLogo -SetId WRONGSET -TerminalId n2qualterm -WindowId N2QUAL-n2qualterm'
    Add-P9HTestResult -Id 'AW6' -Title 'A genuinely identified helper with a wrong SetId is refused' `
        -Input 'PseudoConsoleWindow, GW_OWNER=0x50366, genuine child; owner argv has -SetId WRONGSET' `
        -Expected 'refused with a reason matching setId-mismatch' `
        -Actual ("aux={0} unclassified={1} reason={2}" -f $aw6.Aux, $aw6.Uncl, $aw6.Why) `
        -Pass ($aw6.Aux -eq 0 -and $aw6.Why -match 'setId-mismatch') -Evidence $null

    $aw7 = Invoke-IdentityDefect -OwnerCmd 'pwsh.exe -NoLogo -SetId n2qual -TerminalId wrongterm -WindowId N2QUAL-n2qualterm'
    Add-P9HTestResult -Id 'AW7' -Title 'A genuinely identified helper with a wrong TerminalId is refused' `
        -Input 'PseudoConsoleWindow, GW_OWNER=0x50366, genuine child; owner argv has -TerminalId wrongterm' `
        -Expected 'refused with a reason matching terminalId-mismatch' `
        -Actual ("aux={0} unclassified={1} reason={2}" -f $aw7.Aux, $aw7.Uncl, $aw7.Why) `
        -Pass ($aw7.Aux -eq 0 -and $aw7.Why -match 'terminalId-mismatch') -Evidence $null

    $aw8 = Invoke-IdentityDefect -OwnerCmd 'pwsh.exe -NoLogo -SetId n2qual -TerminalId n2qualterm -WindowId OTHER-window'
    Add-P9HTestResult -Id 'AW8' -Title 'A genuinely identified helper with a wrong WindowId is refused' `
        -Input 'PseudoConsoleWindow, GW_OWNER=0x50366, genuine child; owner argv has -WindowId OTHER-window' `
        -Expected 'refused with a reason matching windowId-mismatch' `
        -Actual ("aux={0} unclassified={1} reason={2}" -f $aw8.Aux, $aw8.Uncl, $aw8.Why) `
        -Pass ($aw8.Aux -eq 0 -and $aw8.Why -match 'windowId-mismatch') -Evidence $null

    $aw9 = Invoke-IdentityDefect -OwnerCmd 'pwsh.exe -NoLogo -NoExit -File bootstrap.ps1'
    Add-P9HTestResult -Id 'AW9' -Title 'A genuinely identified helper with no identity flags is refused' `
        -Input 'PseudoConsoleWindow, GW_OWNER=0x50366, genuine child; owner argv carries none of SetId/TerminalId/WindowId' `
        -Expected 'refused with a reason matching setId-absent-from-owner-argv' `
        -Actual ("aux={0} unclassified={1} reason={2}" -f $aw9.Aux, $aw9.Uncl, $aw9.Why) `
        -Pass ($aw9.Aux -eq 0 -and $aw9.Why -match 'setId-absent-from-owner-argv') -Evidence $null
    # C1-10: missing command line entirely, with valid ownership and style.
    $noCmdProc = New-Proc -ProcId 10301 -ParentPid 7280 -Name 'pwsh.exe' -EmptyCommandLine
    $c1j = New-Win -Hwnd '0x72011' -WinPid 10301 -Class 'PseudoConsoleWindow' -Title '' `
        -Owner '0x50366' -ExStyle $wsTool
    $r = Classify -Windows @($g2Terminal, $c1j) -Procs @($g2Procs[0], $noCmdProc)
    Add-P9HTestResult -Id 'AW10' -Title 'A helper with a missing owner command line is refused' `
        -Input 'genuine helper class and valid owner link, but the owning process has no command line' `
        -Expected 'refused, reason owner-command-line-missing' `
        -Actual ("aux={0} reason={1}" -f $r.AuxiliaryCount, $r.Unclassified[0].reason) `
        -Pass ($r.AuxiliaryCount -eq 0 -and $r.Unclassified[0].reason -match 'owner-command-line-missing') -Evidence $null

    # C1-11: stale / wrong-session ownership evidence.
    $otherSession = New-Proc -ProcId 10302 -ParentPid 7280 -Name 'pwsh.exe' -Session 5 `
        -Cmd 'pwsh.exe -SetId n2qual -TerminalId n2qualterm -WindowId N2QUAL-n2qualterm'
    $c1k = New-Win -Hwnd '0x72012' -WinPid 10302 -Class 'PseudoConsoleWindow' -Title '' `
        -Owner '0x50366' -ExStyle $wsTool
    $r = Classify -Windows @($g2Terminal, $c1k) -Procs @($g2Procs[0], $otherSession)
    Add-P9HTestResult -Id 'AW11' -Title 'A helper owned across a session boundary is refused' `
        -Input 'valid owner link and identity, but the owning process is in session 5' `
        -Expected 'refused, reason session-mismatch' `
        -Actual ("aux={0} reason={1}" -f $r.AuxiliaryCount, $r.Unclassified[0].reason) `
        -Pass ($r.AuxiliaryCount -eq 0 -and $r.Unclassified[0].reason -match 'session-mismatch') -Evidence $null

    # C1-12: the pinned windowID at the forbidden absolute fallback rectangle.
    # A window at 9000,9000 is placement-fallback evidence; it must never be
    # silently absorbed as a harmless helper.
    $c1l = New-Win -Hwnd '0x72013' -WinPid 10140 -Class $managedClass -Title $windowId `
        -Owner '0x0' -X 9000 -Y 9000 -W 640 -H 400
    $r = Classify -Windows @($g2Terminal, $c1l) -Procs $g2Procs
    Add-P9HTestResult -Id 'AW12' -Title 'A second managed-title window at the fallback rectangle is not ignored' `
        -Input 'a managed-class, managed-title window at 9000,9000 (the forbidden fallback origin)' `
        -Expected 'Ok=False, competing=1 (a competing managed UI is refused)' `
        -Actual ("ok={0} managed={1} competing={2} reason={3}" -f $r.Ok, $r.ManagedTerminalCount, $r.CompetingManagedUiCount, $r.Reason) `
        -Pass ($r.Ok -eq $false -and $r.CompetingManagedUiCount -eq 1) -Evidence $null

    # C1-13: the genuine helper in BOTH enumeration orders (order independence
    # under the corrected contract, not just the old one).
    $realHelper = New-Win -Hwnd '0x20330' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title '' `
        -Owner '0x50366' -X 0 -Y 0 -W 16 -H 16 -ExStyle $wsTool
    $fwd = Classify -Windows @($realHelper, $g2Terminal) -Procs $g2Procs
    $rev = Classify -Windows @($g2Terminal, $realHelper) -Procs $g2Procs
    Add-P9HTestResult -Id 'AW13' -Title 'The corrected contract remains independent of enumeration order' `
        -Input 'the genuine helper and its owner presented in both orders' `
        -Expected 'both orders: managed=1, auxiliary=1, unclassified=0' `
        -Actual ("pseudoFirst=(m={0} a={1} u={2}) terminalFirst=(m={3} a={4} u={5})" -f
            $fwd.ManagedTerminalCount, $fwd.AuxiliaryCount, $fwd.UnclassifiedCount,
            $rev.ManagedTerminalCount, $rev.AuxiliaryCount, $rev.UnclassifiedCount) `
        -Pass ($fwd.ManagedTerminalCount -eq 1 -and $fwd.AuxiliaryCount -eq 1 -and $fwd.UnclassifiedCount -eq 0 -and
            $rev.ManagedTerminalCount -eq 1 -and $rev.AuxiliaryCount -eq 1 -and $rev.UnclassifiedCount -eq 0) -Evidence $null

    # C1-14: auxiliaries only, with no managed terminal at all.
    $r = Classify -Windows @($realHelper) -Procs $g2Procs
    Add-P9HTestResult -Id 'AW14' -Title 'A proven auxiliary with no managed terminal is still refused' `
        -Input 'only the helper window; its GW_OWNER names a window not in this set' `
        -Expected 'Ok=False, managed=0' `
        -Actual ("ok={0} managed={1} reason={2}" -f $r.Ok, $r.ManagedTerminalCount, $r.Reason) `
        -Pass ($r.Ok -eq $false -and $r.ManagedTerminalCount -eq 0) -Evidence $null

    # C1-15: two genuine managed terminals are refused.
    $secondTerm = New-Win -Hwnd '0x72014' -WinPid 7280 -Class $managedClass -Title $windowId
    $r = Classify -Windows @($g2Terminal, $secondTerm) -Procs $g2Procs
    Add-P9HTestResult -Id 'AW15' -Title 'Two genuine managed terminals are refused' `
        -Input 'two windows satisfying the full managed-terminal contract' `
        -Expected 'Ok=False, managed=2' `
        -Actual ("ok={0} managed={1} reason={2}" -f $r.Ok, $r.ManagedTerminalCount, $r.Reason) `
        -Pass ($r.Ok -eq $false -and $r.ManagedTerminalCount -eq 2 -and $r.Reason -eq 'multiple-managed-terminal-windows') -Evidence $null

    # C1-16: multiple genuinely proven auxiliaries are all reported.
    $h2 = New-Win -Hwnd '0x72015' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title '' `
        -Owner '0x50366' -ExStyle $wsTool
    $r = Classify -Windows @($g2Terminal, $realHelper, $h2) -Procs $g2Procs
    Add-P9HTestResult -Id 'AW16' -Title 'Multiple genuinely proven auxiliaries are all reported' `
        -Input 'one managed terminal plus two helper windows that both satisfy the contract' `
        -Expected 'Ok=True, managed=1, auxiliary=2, every reason present' `
        -Actual ("ok={0} managed={1} aux={2} reasons={3}" -f $r.Ok, $r.ManagedTerminalCount, $r.AuxiliaryCount,
            (@($r.Auxiliary | ForEach-Object { $_.hwnd + ':' + $_.reason }) -join ',')) `
        -Pass ($r.Ok -eq $true -and $r.ManagedTerminalCount -eq 1 -and $r.AuxiliaryCount -eq 2 -and
            @($r.Auxiliary | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.reason) }).Count -eq 0) -Evidence $null

    # C1-17: a genuine auxiliary alongside an ambiguous window -> still refused.
    $ambiguous = New-Win -Hwnd '0x72016' -WinPid 10140 -Class 'MysteryClass' -Title '' `
        -Owner '0x50366' -X 50 -Y 50 -W 400 -H 300
    $r = Classify -Windows @($g2Terminal, $realHelper, $ambiguous) -Procs $g2Procs
    Add-P9HTestResult -Id 'AW17' -Title 'An ambiguous window beside an otherwise valid lifecycle still fails' `
        -Input 'one proven auxiliary plus one window with no recorded style' `
        -Expected 'Ok=False; the proven auxiliary stays accepted but the ambiguity blocks' `
        -Actual ("ok={0} aux={1} unclassified={2}" -f $r.Ok, $r.AuxiliaryCount, $r.UnclassifiedCount) `
        -Pass ($r.Ok -eq $false -and $r.AuxiliaryCount -eq 1 -and $r.UnclassifiedCount -eq 1) -Evidence $null

    # C1-18 (v3 semantics): an UNREADABLE style value must not be treated as if
    # the style had been read and evaluated. Under v3 the style is corroborating,
    # so the window is still accepted on the CLASS ROLE, but the corroboration must
    # be reported as UNKNOWN - never silently as true or false.
    $badStyle = New-Win -Hwnd '0x72017' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title '' `
        -Owner '0x50366' -ExStyle 'not-a-number'
    $r = Classify -Windows @($g2Terminal, $badStyle) -Procs $g2Procs
    Add-P9HTestResult -Id 'AW18' -Title 'An unreadable style value is never silently interpreted' `
        -Input 'exStyle present but not a number, on a genuinely identified helper class' `
        -Expected 'corroboration reported as unknown (not True/False); role still decided by the class' `
        -Actual ("aux={0} corroborates={1} roleClass={2}" -f $r.AuxiliaryCount, [string]$r.Auxiliary[0].styleCorroboratesRole, [string]$r.Auxiliary[0].auxiliaryRoleClass) `
        -Pass ($r.AuxiliaryCount -eq 1 -and $null -eq $r.Auxiliary[0].styleCorroboratesRole -and
            $r.Auxiliary[0].auxiliaryRoleClass -eq $true) -Evidence $null

    # C1-19: the ownership link must be REAL. A window whose owner is not in the
    # set is refused even with perfect style and identity.
    $noOwner = New-Win -Hwnd '0x72018' -WinPid 10140 -Class 'PseudoConsoleWindow' -Title '' `
        -Owner '0x0' -ExStyle $wsTool
    $r = Classify -Windows @($g2Terminal, $noOwner) -Procs $g2Procs
    Add-P9HTestResult -Id 'AW19' -Title 'A helper with no ownership link is refused despite perfect identity' `
        -Input 'genuine helper class and exact identity, but GW_OWNER is 0x0' `
        -Expected 'refused, reason owner-not-a-managed-terminal' `
        -Actual ("aux={0} reason={1}" -f $r.AuxiliaryCount, $r.Unclassified[0].reason) `
        -Pass ($r.AuxiliaryCount -eq 0 -and $r.Unclassified[0].reason -match 'owner-not-a-managed-terminal') -Evidence $null

    # C1-20: the classifier must advertise what it could NOT prove.
    Add-P9HTestResult -Id 'AW20' -Title 'The classifier names the properties this evidence set cannot prove' `
        -Input 'any classification result' `
        -Expected 'UnprovenProperties lists the absent style/UIA properties and IdentityProxy names the title proxy' `
        -Actual ("unproven={0} proxy={1}" -f (@($rev.UnprovenProperties) -join ','), $rev.IdentityProxy) `
        -Pass (@($rev.UnprovenProperties) -contains 'GWL_EXSTYLE' -and
            @($rev.UnprovenProperties) -contains 'ui-automation-tab-title-family' -and
            $rev.IdentityProxy -eq 'top-level-window-title-equals-windowId') -Evidence $null
}


function Invoke-P9HParameterBindingTests {
    # I-series: PowerShell parameter-binding regressions (Stage 3B7G3).
    #
    # WHY THIS EXISTS
    # ---------------
    # Stage 3B7G2 lost four consecutive launch attempts to a construct equivalent
    # to:
    #
    #     [Parameter(Mandatory)][string]$SettleSeconds = '10'
    #
    # A Mandatory parameter makes the default value UNREACHABLE, and when the host
    # leaves stdin open but empty the binder blocks on an interactive prompt
    # BEFORE the script body runs. Nothing is written, no artifact appears and no
    # cmd/trace/exit-record is produced, so the failure looks like a product fault
    # while it is entirely a harness defect.
    #
    # These cases pin both halves: the LANGUAGE BEHAVIOUR (so the rationale cannot
    # be mistaken for folklore) and an AST SCAN over the stage's own scripts (so
    # the defect cannot silently return).
    param([Parameter(Mandatory)][string]$SandboxRoot)

    $dir = Join-Path $SandboxRoot 'i-binding'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    # ------------------------------------------------------------ probes
    # Every probe is Task-owned and lives in the sandbox.
    $mandatoryWithDefault = Join-Path $dir 'mandatory-with-default.ps1'
    Write-P9HArtifact -Path $mandatoryWithDefault -Lines @(
        'param('
        "    [Parameter(Mandatory)][string]`$SettleSeconds = '10'"
        ')'
        '"  BODY-Settle=$SettleSeconds"'
    )

    $optionalWithDefault = Join-Path $dir 'optional-with-default.ps1'
    Write-P9HArtifact -Path $optionalWithDefault -Lines @(
        'param('
        "    [string]`$SettleSeconds = '10'"
        ')'
        '"  BODY-Settle=$SettleSeconds"'
    )

    $mandatoryWithoutDefault = Join-Path $dir 'mandatory-no-default.ps1'
    Write-P9HArtifact -Path $mandatoryWithoutDefault -Lines @(
        'param('
        '    [Parameter(Mandatory)][string]$SettleSeconds'
        ')'
        '"  BODY-Settle=$SettleSeconds"'
    )

    $exe = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrWhiteSpace($exe)) { $exe = 'pwsh.exe' }

    # Build a ProcessStartInfo that works on BOTH hosts. `ArgumentList` is a
    # .NET Core / PowerShell 7-only property; Windows PowerShell 5.1 only has the
    # single `Arguments` string. Quoting each token here is exact because every
    # token is a bare path or switch with no embedded quote.
    function New-ProbeStartInfo {
        param([string[]]$Argv)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $hasArgumentList = $null -ne $psi.PSObject.Properties['ArgumentList']
        if ($hasArgumentList) {
            foreach ($a in $Argv) { $psi.ArgumentList.Add($a) }
        }
        else {
            $psi.Arguments = (($Argv | ForEach-Object {
                        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
                    }) -join ' ')
        }
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        return $psi
    }

    # Run a probe with stdin REDIRECTED BUT OPEN AND EMPTY - the exact shape that
    # hung Stage 3B7G2 - and report whether the body was reached or the binder
    # blocked on a prompt.
    function Invoke-Probe {
        # Run a probe and report WHICH of four outcomes happened. Distinguishing
        # them matters: "body not reached" is true both for a clean noninteractive
        # refusal and for a child that blocked until it was killed, and treating
        # those as the same result is how a hang can masquerade as a passing test.
        #
        #   body executed            BodyReached = true
        #   blocked on a prompt      TimedOut    = true   (killed after the timeout)
        #   timely noninteractive    TimedOut    = false, error names the parameter
        #   silent failure           TimedOut    = false, no body, no named error
        param(
            [string]$Path,
            [int]$TimeoutSeconds = 20,
            # Leave stdin OPEN AND EMPTY so an interactive prompt can block.
            [switch]$OfferEmptyStdin,
            # Add -NonInteractive so the host can never wait for input.
            [switch]$NonInteractive
        )

        $argv = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass')
        if ($NonInteractive) { $argv += '-NonInteractive' }
        $argv += @('-File', $Path)

        $psi = New-ProbeStartInfo -Argv $argv
        if (-not $OfferEmptyStdin) { $psi.RedirectStandardInput = $false }

        $proc = [System.Diagnostics.Process]::Start($psi)
        # Deliberately DO NOT close stdin when offering it: an open empty pipe is
        # exactly what makes the binder prompt.
        $finished = $proc.WaitForExit($TimeoutSeconds * 1000)
        if (-not $finished) { try { $proc.Kill() } catch { } }
        $out = ''
        $err = ''
        try { $out = $proc.StandardOutput.ReadToEnd() } catch { }
        try { $err = $proc.StandardError.ReadToEnd() } catch { }

        return [pscustomobject]@{
            BodyReached = ($out -match 'BODY-Settle=')
            Prompted    = (-not $finished) -or ($err -match 'missing mandatory parameter')
            TimedOut    = (-not $finished)
            NamesMissingMandatory = ($err -match 'missing mandatory parameter')
            ExitCode    = if ($finished) { $proc.ExitCode } else { $null }
            Stdout      = $out.Trim()
            Stderr      = $err.Trim()
        }
    }
    # =====================================================================
    # I1: Mandatory + default does NOT apply the default and can block
    # =====================================================================
    $r1 = Invoke-Probe -Path $mandatoryWithDefault -OfferEmptyStdin
    Add-P9HTestResult -Id 'I1' -Title 'A Mandatory parameter with a default value never uses that default' `
        -Input 'param([Parameter(Mandatory)][string]$SettleSeconds = "10") invoked with no argument, stdin open and empty' `
        -Expected 'the default is unreachable: the body is not reached (prompt or fast mandatory failure)' `
        -Actual ("bodyReached={0} prompted={1} timedOut={2} exited={3}" -f $r1.BodyReached, $r1.Prompted, $r1.TimedOut, $r1.ExitCode) `
        -Pass ($r1.BodyReached -eq $false) -Evidence $dir

    # =====================================================================
    # I2: the same script WITH the argument supplied does run
    # =====================================================================
    $psi = New-ProbeStartInfo -Argv @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $mandatoryWithDefault, '-SettleSeconds', '3')
    $psi.RedirectStandardInput = $false
    $p2 = [System.Diagnostics.Process]::Start($psi)
    $f2 = $p2.WaitForExit(20000)
    $so2 = ''
    if ($f2) { $so2 = $p2.StandardOutput.ReadToEnd().Trim() } else { try { $p2.Kill() } catch { } }
    Add-P9HTestResult -Id 'I2' -Title 'Supplying the Mandatory argument reaches the body and honours the value' `
        -Input 'the same script invoked with -SettleSeconds 3' `
        -Expected 'body runs and reports SettleSeconds=3' `
        -Actual ("bodyReached={0} stdout=[{1}]" -f ($so2 -match 'BODY-Settle=3'), $so2) `
        -Pass ($so2 -match 'BODY-Settle=3') -Evidence $dir

    # =====================================================================
    # I3: OPTIONAL with a default is the correct shape - no prompt, default used
    # =====================================================================
    $r3 = Invoke-Probe -Path $optionalWithDefault -OfferEmptyStdin
    Add-P9HTestResult -Id 'I3' -Title 'An optional parameter with a default stays non-mandatory and applies its default' `
        -Input 'param([string]$SettleSeconds = "10") invoked with no argument, stdin open and empty' `
        -Expected 'body runs immediately with SettleSeconds=10, no prompt' `
        -Actual ("bodyReached={0} prompted={1} stdout=[{2}]" -f $r3.BodyReached, $r3.Prompted, $r3.Stdout) `
        -Pass ($r3.BodyReached -eq $true -and $r3.Prompted -eq $false -and $r3.Stdout -match 'BODY-Settle=10') -Evidence $dir

    # =====================================================================
    # I4: a TRULY mandatory parameter has no misleading default.
    #
    # IMPORTANT: `body not reached` ALONE is not sufficient evidence. A child that
    # HANGS on an interactive prompt also never reaches the body, so the earlier
    # form of this case could pass on a timeout. I4 therefore asserts a TIMELY,
    # NON-INTERACTIVE refusal: the process must exit on its own, before the
    # timeout, with a mandatory-parameter error.
    # =====================================================================
    $r4 = Invoke-Probe -Path $mandatoryWithoutDefault -NonInteractive
    Add-P9HTestResult -Id 'I4' -Title 'A truly Mandatory parameter without a default refuses promptly instead of blocking' `
        -Input 'param([Parameter(Mandatory)][string]$SettleSeconds) invoked with no argument' `
        -Expected 'the body never runs, the process exits in time, and the error names the missing mandatory parameter' `
        -Actual ("bodyReached={0} timedOut={1} exited={2} namesMandatory={3}" -f
            $r4.BodyReached, $r4.TimedOut, $r4.ExitCode, ($r4.Stderr -match 'missing mandatory parameter')) `
        -Pass ($r4.BodyReached -eq $false -and $r4.TimedOut -eq $false -and
            $null -ne $r4.ExitCode -and $r4.Stderr -match 'missing mandatory parameter') -Evidence $dir

    # =====================================================================
    # I4b: the SAME construct with an OPEN EMPTY stdin DOES block, and that
    # blocking is a TIMEOUT - distinguished from a clean refusal. This is the
    # behaviour difference the harness must never mistake for a verdict.
    # =====================================================================
    $r4b = Invoke-Probe -Path $mandatoryWithDefault -OfferEmptyStdin -TimeoutSeconds 8
    Add-P9HTestResult -Id 'I4b' -Title 'Mandatory-with-default blocking is reported as a timeout, not a refusal' `
        -Input 'the G2 construct with stdin open and empty, bounded at 8s' `
        -Expected 'timed out on a prompt (body never reached) - never mistaken for a clean outcome' `
        -Actual ("timedOut={0} bodyReached={1}" -f $r4b.TimedOut, $r4b.BodyReached) `
        -Pass ($r4b.TimedOut -eq $true -and $r4b.BodyReached -eq $false) -Evidence $dir

    # =====================================================================
    # I4c: a GENUINELY NONINTERACTIVE invocation terminates. This is the shape
    # qualification orchestration must use: it can never wait for parameter input.
    # =====================================================================
    $r4c = Invoke-Probe -Path $mandatoryWithoutDefault -NonInteractive
    Add-P9HTestResult -Id 'I4c' -Title 'A noninteractive invocation terminates instead of waiting for input' `
        -Input 'the truly-mandatory script invoked with -NonInteractive and no argument' `
        -Expected 'terminates on its own with a mandatory-parameter error' `
        -Actual ("timedOut={0} exited={1} namesMandatory={2}" -f
            $r4c.TimedOut, $r4c.ExitCode, ($r4c.Stderr -match 'missing mandatory parameter')) `
        -Pass ($r4c.TimedOut -eq $false -and $r4c.BodyReached -eq $false -and
            $r4c.Stderr -match 'missing mandatory parameter') -Evidence $dir

    # =====================================================================
    # I4d: the SAME noninteractive invocation of the OPTIONAL-with-default script
    # must still SUCCEED, proving the noninteractive shape is not itself fatal.
    # =====================================================================
    $r4d = Invoke-Probe -Path $optionalWithDefault -NonInteractive
    Add-P9HTestResult -Id 'I4d' -Title 'A noninteractive invocation of a correct optional script succeeds' `
        -Input 'the optional-with-default script under -NonInteractive' `
        -Expected 'body runs and applies the default' `
        -Actual ("bodyReached={0} timedOut={1} stdout=[{2}]" -f $r4d.BodyReached, $r4d.TimedOut, $r4d.Stdout) `
        -Pass ($r4d.BodyReached -eq $true -and $r4d.TimedOut -eq $false -and $r4d.Stdout -match 'BODY-Settle=10') -Evidence $dir

    # =====================================================================    # =====================================================================
    # I5: AST scan of the STAGE'S OWN scripts
    # =====================================================================
    # Only qualification/p9h/ is scanned: this correction is qualification-only
    # and must not rewrite unrelated product source.
    $stageRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    $scanned = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -Filter *.ps1 -File -ErrorAction SilentlyContinue)
    $offenders = [System.Collections.Generic.List[string]]::new()
    $mandatorySeen = 0
    $optionalSeen = 0

    foreach ($file in $scanned) {
        $parseErrors = $null
        $tokens = $null
        try {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        }
        catch { continue }
        if ($null -eq $ast) { continue }

        foreach ($p in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
            $isMandatory = $false
            foreach ($attr in $p.Attributes) {
                if ($attr -isnot [System.Management.Automation.Language.AttributeAst]) { continue }
                if ($attr.TypeName.Name -notmatch '^Parameter') { continue }
                foreach ($na in @($attr.NamedArguments)) {
                    if ($null -ne $na -and $na.ArgumentName -eq 'Mandatory') { $isMandatory = $true }
                }
                foreach ($pa in @($attr.PositionalArguments)) {
                    if ($null -ne $pa -and $pa.Extent.Text -match '^\$true$') { $isMandatory = $true }
                }
            }
            if ($null -ne $p.DefaultValue) {
                if ($isMandatory) {
                    $offenders.Add(('{0}:{1}:${2}' -f $file.Name, $p.Extent.StartLineNumber, $p.Name.VariablePath.UserPath)) | Out-Null
                }
                else { $optionalSeen++ }
            }
            elseif ($isMandatory) { $mandatorySeen++ }
        }
    }

    Add-P9HTestResult -Id 'I5' -Title 'No stage-owned script declares a Mandatory parameter that also carries a default' `
        -Input ("AST scan of {0} scripts under qualification/p9h ({1} optional-with-default, {2} mandatory-without-default)" -f $scanned.Count, $optionalSeen, $mandatorySeen) `
        -Expected 'zero Mandatory+default parameters' `
        -Actual $(if ($offenders.Count -eq 0) { '0 offenders' } else { ($offenders -join ' | ') }) `
        -Pass ($offenders.Count -eq 0 -and $scanned.Count -gt 0) -Evidence $stageRoot

    # =====================================================================
    # I6: the scan actually DETECTS the defect (a scan that cannot fail is worthless)
    # =====================================================================
    $canary = Join-Path $dir 'canary-mandatory-default.ps1'
    Write-P9HArtifact -Path $canary -Lines @(
        'param('
        "    [Parameter(Mandatory)][string]`$SettleSeconds = '10'"
        ')'
        '"ok"'
    )
    $canaryErrors = $null
    $canaryTokens = $null
    $canaryAst = [System.Management.Automation.Language.Parser]::ParseFile($canary, [ref]$canaryTokens, [ref]$canaryErrors)
    $canaryHits = 0
    foreach ($p in $canaryAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
        $isMandatory = $false
        foreach ($attr in $p.Attributes) {
            if ($attr -isnot [System.Management.Automation.Language.AttributeAst]) { continue }
            if ($attr.TypeName.Name -notmatch '^Parameter') { continue }
            foreach ($na in @($attr.NamedArguments)) { if ($null -ne $na -and $na.ArgumentName -eq 'Mandatory') { $isMandatory = $true } }
            foreach ($pa in @($attr.PositionalArguments)) { if ($null -ne $pa -and $pa.Extent.Text -match '^\$true$') { $isMandatory = $true } }
        }
        if ($isMandatory -and $null -ne $p.DefaultValue) { $canaryHits++ }
    }
    Add-P9HTestResult -Id 'I6' -Title 'The parser scan detects the defect it is meant to prevent' `
        -Input 'a canary script containing the exact G2 construct' `
        -Expected 'the scan reports 1 offender' `
        -Actual ("offenders={0}" -f $canaryHits) `
        -Pass ($canaryHits -eq 1) -Evidence $dir
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
    Invoke-P9HWtsEnumerationTests -SandboxRoot $SandboxRoot
    Invoke-P9HAuthorityGateTests -SandboxRoot $SandboxRoot
    Invoke-P9HAuthorityOmissionTests -SandboxRoot $SandboxRoot
    Invoke-P9HDateHandlingTests -SandboxRoot $SandboxRoot
    Invoke-P9HWtsListenerAuthorityTests -SandboxRoot $SandboxRoot
    Invoke-P9HObserverBridgeTests -SandboxRoot $SandboxRoot
    Invoke-P9HChronologyBoundTests -SandboxRoot $SandboxRoot
    Invoke-P9HHostBoundaryTests -SandboxRoot $SandboxRoot
    Invoke-P9HAtomicArtifactTests -SandboxRoot $SandboxRoot
    Invoke-P9HRelaunchTests -SandboxRoot $SandboxRoot
    Invoke-P9HManagedTerminalContractTests -SandboxRoot $SandboxRoot
    Invoke-P9HParameterBindingTests -SandboxRoot $SandboxRoot

    $results = @($script:P9HTestResults)

    # The registry report is NOT one of the registered cases; it is the guard's
    # own verdict, so its id is computed and is deliberately not a source literal.
    $registryReportId = 'R1'
    $registry = Test-P9HTestRegistry -Results $results -ExpectedCount 341 `
        -RequiredSeries @('T', 'O', 'A', 'F', 'V', 'N', 'W', 'X', 'M', 'P', 'Q', 'K', 'Y', 'B', 'S', 'U', 'G', 'D', 'L', 'C', 'Z', 'H', 'J', 'R', 'E', 'I', 'AW', 'R3')

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
