# DevWS P9-H replay instrumentation - N2 launcher and exit recorder.
#
# Closes P9-G defects N2-1, N2-2 and N2-6:
#   * the exit code lived only in memory;
#   * inventories ran before it was persisted;
#   * the authoritative result file was never written.
#
# Ordering guarantee: Write-P9HExitRecord is called IMMEDIATELY after the tracked
# launcher exits and BEFORE any inventory, window enumeration, trace read or
# aggregate serialization. See Invoke-P9HLaunchRecorded for the enforcing
# sequence, and the synthetic self-tests for the fault-injection proof.
#
# Why cmd.exe is the tracked process: the installed entry point is ws.cmd, whose
# last line is `exit /b %ERRORLEVEL%`. Tracking cmd.exe therefore observes the
# CLI's own status. Tracking a terminal descendant instead would wait for the
# terminal's lifetime, which is exactly the trap that makes Start-Process -Wait
# unusable as an acceptance oracle here.

Set-StrictMode -Version Latest

function Get-P9HLauncherSpec {
    # Resolve and validate the launcher. An explicit command interpreter is used
    # so no file-association or shell-quoting layer can reinterpret arguments.
    param(
        [Parameter(Mandatory)][string]$CommandPath,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$CommandInterpreter = $null
    )

    if ([string]::IsNullOrWhiteSpace($CommandInterpreter)) {
        $CommandInterpreter = Join-Path $env:SystemRoot 'System32\cmd.exe'
    }

    if (-not (Test-Path -LiteralPath $CommandInterpreter -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Reason  = 'interpreter-missing'
            Detail  = "Command interpreter not found at '$CommandInterpreter'."
            Spec    = $null
        }
    }

    if (-not (Test-Path -LiteralPath $CommandPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Reason  = 'command-missing'
            Detail  = "Launch target not found at '$CommandPath'."
            Spec    = $null
        }
    }

    if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Reason  = 'workdir-missing'
            Detail  = "Working directory not found at '$WorkingDirectory'."
            Spec    = $null
        }
    }

    # cmd.exe argument passing is NOT argv-safe for a batch file: without /s the
    # interpreter splits the tail on spaces, so 'two words' becomes two arguments
    # (proven by self-test). The correct form is a single /s /c string whose
    # content is:
    #     ""<script>" "<arg1>" "<arg2>" ..."
    # The leading double quote plus /s makes cmd strip the outer pair and pass
    # every quoted token through verbatim. Embedded double quotes are escaped so
    # they cannot terminate the inner quoting.
    $quotedScript = '"' + $CommandPath + '"'
    $quotedArgs = @($Arguments | ForEach-Object { '"' + ([string]$_ -replace '"', '\"') + '"' })
    $innerCommand = '"' + $quotedScript + $(if ($quotedArgs.Count -gt 0) { ' ' + ($quotedArgs -join ' ') } else { '' }) + '"'
    $argv = @('/d', '/s', '/c', $innerCommand)

    return [pscustomobject][ordered]@{
        Ok                  = $true
        Reason              = 'ok'
        Detail              = $null
        Spec                = [pscustomobject][ordered]@{
            InterpreterPath = (Resolve-Path -LiteralPath $CommandInterpreter).Path
            InterpreterSha  = Get-P9HFileSha256 -Path $CommandInterpreter
            CommandPath     = (Resolve-Path -LiteralPath $CommandPath).Path
            CommandSha      = Get-P9HFileSha256 -Path $CommandPath
            Arguments       = @($Arguments)
            ArgumentCount   = @($Arguments).Count
            WorkingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
            Argv            = @($argv)
            ArgvDisplay     = (@($argv) | ForEach-Object { '"{0}"' -f $_ }) -join ' '
            InnerCommand    = $innerCommand
        }
    }
}

function Get-P9HProcessIntegrity {
    # Report the integrity level of the CURRENT process so the evidence shows
    # which authority the launch was made under.
    #
    # P9-G learned that DEVWS_LAUNCH_TRACE is only written at Medium integrity.
    # Recording the level makes a future 'no trace captured' self-explanatory.
    param()

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
        $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { $isAdmin = $null }

    $label = 'unknown'
    try {
        $groups = (whoami /groups) -join "`n"
        if ($groups -match 'Mandatory Label\\System') { $label = 'System' }
        elseif ($groups -match 'Mandatory Label\\High') { $label = 'High' }
        elseif ($groups -match 'Mandatory Label\\Medium') { $label = 'Medium' }
        elseif ($groups -match 'Mandatory Label\\Low') { $label = 'Low' }
    }
    catch { }

    return [pscustomobject][ordered]@{
        Label       = $label
        IsAdminRole = $isAdmin
        UserName    = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        SessionId   = (Get-Process -Id $PID).SessionId
        Pid         = $PID
    }
}

function New-P9HExitRecord {
    # Build the authoritative exit record. Pure: no IO.
    #
    # Outcome vocabulary is closed so a consumer can never see an invented
    # success:
    #   exited      - the tracked launcher was observed to exit; ExitCode is an int
    #   timeout     - the bounded wait elapsed; ExitCode is $null
    #   start-failed- the launcher never started; ExitCode is $null
    #   identity-unknown - the process handle was lost; ExitCode is $null
    param(
        [Parameter(Mandatory)][string]$TrialId,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Outcome,
        [AllowNull()]$ExitCode = $null,
        [AllowNull()]$LauncherPid = $null,
        [AllowNull()][string]$LauncherPath = $null,
        [AllowNull()][string]$LauncherSha256 = $null,
        [AllowNull()][string]$InvocationDisplay = $null,
        [AllowNull()][AllowEmptyCollection()][string[]]$Arguments = @(),
        [AllowNull()][string]$WorkingDirectory = $null,
        [AllowNull()]$InvokingProcess = $null,
        [AllowNull()][string]$LaunchedAtUtc = $null,
        [AllowNull()][string]$ExitedAtUtc = $null,
        [AllowNull()]$ElapsedMs = $null,
        [AllowNull()][string]$StdoutPath = $null,
        [AllowNull()][string]$StderrPath = $null,
        [AllowNull()][string]$Detail = $null
    )

    $valid = @('exited', 'timeout', 'start-failed', 'identity-unknown')
    if ($valid -notcontains $Outcome) {
        throw "P9-H: invalid exit outcome '$Outcome'."
    }

    # A numeric code is legal ONLY for a confirmed exit. Anything else must be
    # null so a downstream reader cannot mistake 0 for success.
    if ($Outcome -eq 'exited') {
        if ($null -eq $ExitCode) { throw 'P9-H: outcome=exited requires a numeric exit code.' }
        $asInt = 0
        if (-not [int]::TryParse([string]$ExitCode, [ref]$asInt)) {
            throw "P9-H: exit code must be a 32-bit integer (got '$ExitCode')."
        }
        $ExitCode = $asInt
    }
    else {
        $ExitCode = $null
    }

    return [ordered]@{
        trialId           = $TrialId
        schema            = 'p9h.exit-record.v1'
        sequence          = 1
        outcome           = $Outcome
        exitCode          = $ExitCode
        launcherPid       = $LauncherPid
        launcherPath      = $LauncherPath
        launcherSha256    = $LauncherSha256
        invocation        = $InvocationDisplay
        arguments         = @($Arguments)
        argumentCount     = @($Arguments).Count
        workingDirectory  = $WorkingDirectory
        invokingPid       = if ($null -ne $InvokingProcess) { $InvokingProcess.Pid } else { $null }
        invokingUser      = if ($null -ne $InvokingProcess) { $InvokingProcess.UserName } else { $null }
        invokingIntegrity = if ($null -ne $InvokingProcess) { $InvokingProcess.Label } else { $null }
        invokingSessionId = if ($null -ne $InvokingProcess) { $InvokingProcess.SessionId } else { $null }
        launchedAtUtc     = $LaunchedAtUtc
        exitedAtUtc       = $ExitedAtUtc
        elapsedMs         = $ElapsedMs
        stdoutPath        = $StdoutPath
        stderrPath        = $StderrPath
        detail            = $Detail
    }
}

function Write-P9HExitRecord {
    # Persist the exit record durably and immediately.
    #
    # Atomic temp-then-rename, then read back and validate. Returns a result
    # object; the caller must not proceed if Ok=$false.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Record
    )

    $json = $Record | ConvertTo-Json -Depth 8
    Write-P9HArtifact -Path $Path -Lines @($json)

    $readBack = Read-P9HJsonArtifact -Path $Path
    if (-not $readBack.Ok) {
        return [pscustomobject][ordered]@{
            Ok     = $false
            Reason = ('exit-record-not-readable:' + $readBack.Reason)
            Detail = $readBack.Error
            Data   = $null
        }
    }

    $data = $readBack.Data

    $required = @('trialId', 'outcome', 'exitCode')
    foreach ($field in $required) {
        if ($null -eq $data.PSObject.Properties[$field]) {
            return [pscustomobject][ordered]@{
                Ok     = $false
                Reason = ('exit-record-missing-field:' + $field)
                Detail = $null
                Data   = $data
            }
        }
    }

    if ([string]$data.outcome -eq 'exited') {
        if ($null -eq $data.exitCode) {
            return [pscustomobject][ordered]@{
                Ok     = $false
                Reason = 'exit-record-exited-without-code'
                Detail = $null
                Data   = $data
            }
        }
    }
    elseif ($null -ne $data.exitCode) {
        return [pscustomobject][ordered]@{
            Ok     = $false
            Reason = ('exit-record-non-exited-with-code:' + [string]$data.outcome)
            Detail = $null
            Data   = $data
        }
    }

    return [pscustomobject][ordered]@{ Ok = $true; Reason = 'ok'; Detail = $null; Data = $data }
}

function Test-P9HExitRecord {
    # Independent verifier, used by the verdict stage and by self-test T8/T9.
    #
    # Returns Valid=$false with a specific reason for missing, malformed, or
    # internally inconsistent records. It never defaults to a passing value.
    param([Parameter(Mandatory)][string]$Path)

    $read = Read-P9HJsonArtifact -Path $Path
    if (-not $read.Ok) {
        return [pscustomobject][ordered]@{ Valid = $false; Reason = $read.Reason; Data = $null; Error = $read.Error }
    }

    $d = $read.Data

    foreach ($field in @('trialId', 'schema', 'outcome', 'exitCode')) {
        if ($null -eq $d.PSObject.Properties[$field]) {
            return [pscustomobject][ordered]@{ Valid = $false; Reason = ('missing-field:' + $field); Data = $d; Error = $null }
        }
    }

    if ([string]$d.schema -ne 'p9h.exit-record.v1') {
        return [pscustomobject][ordered]@{ Valid = $false; Reason = ('unknown-schema:' + [string]$d.schema); Data = $d; Error = $null }
    }

    $validOutcomes = @('exited', 'timeout', 'start-failed', 'identity-unknown')
    if ($validOutcomes -notcontains [string]$d.outcome) {
        return [pscustomobject][ordered]@{ Valid = $false; Reason = ('unknown-outcome:' + [string]$d.outcome); Data = $d; Error = $null }
    }

    if ([string]$d.outcome -eq 'exited') {
        if ($null -eq $d.exitCode) {
            return [pscustomobject][ordered]@{ Valid = $false; Reason = 'exited-without-exit-code'; Data = $d; Error = $null }
        }
        $asInt = 0
        if (-not [int]::TryParse([string]$d.exitCode, [ref]$asInt)) {
            return [pscustomobject][ordered]@{ Valid = $false; Reason = 'exit-code-not-integer'; Data = $d; Error = $null }
        }
    }
    else {
        if ($null -ne $d.exitCode) {
            return [pscustomobject][ordered]@{ Valid = $false; Reason = ('non-exited-with-exit-code:' + [string]$d.outcome); Data = $d; Error = $null }
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$d.trialId)) {
        return [pscustomobject][ordered]@{ Valid = $false; Reason = 'missing-trial-id'; Data = $d; Error = $null }
    }

    return [pscustomobject][ordered]@{ Valid = $true; Reason = 'ok'; Data = $d; Error = $null }
}

function Invoke-P9HProcessRecorded {
    # Generic tracked-process recorder. Launches whatever command it is given and
    # persists the exit record FIRST.
    #
    # This carries no product authorization because it is the measurement
    # primitive, not a product action: the synthetic self-tests use it with
    # harmless test-owned processes. Product launches go through
    # Invoke-P9HProductLaunchRecorded below, which additionally requires the
    # real-execution token.
    #
    # The sequence is deliberately rigid:
    #   1. start the launcher with file-redirected streams (no pipe buffers);
    #   2. bounded process-specific wait on the LAUNCHER handle only;
    #   3. build + atomically persist + read back the exit record;
    #   4. only then return so the caller may begin inventories.
    #
    # A detached descendant cannot extend step 2, and stream files are never read
    # here, so an inherited output handle cannot block the recorder.
    param(
        [Parameter(Mandatory)][string]$TrialId,
        [Parameter(Mandatory)][string]$CommandPath,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$ArtifactDirectory,
        [int]$TimeoutMs = 180000,
        [scriptblock]$OnExitRecordPersisted = $null
    )

    $spec = Get-P9HLauncherSpec -CommandPath $CommandPath -Arguments $Arguments -WorkingDirectory $WorkingDirectory
    if (-not $spec.Ok) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = $spec.Reason; Detail = $spec.Detail; ExitRecord = $null }
    }

    $stdoutPath = Join-Path $ArtifactDirectory 'n2-launch-stdout.txt'
    $stderrPath = Join-Path $ArtifactDirectory 'n2-launch-stderr.txt'
    $exitPath = Join-Path $ArtifactDirectory 'n2-exit-record.json'

    $invoking = Get-P9HProcessIntegrity
    $launchedAt = Get-P9HUtcStamp
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $proc = Start-Process -FilePath $spec.Spec.InterpreterPath `
            -ArgumentList $spec.Spec.Argv `
            -WorkingDirectory $spec.Spec.WorkingDirectory `
            -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath
    }
    catch {
        $record = New-P9HExitRecord -TrialId $TrialId -Outcome 'start-failed' `
            -LauncherPath $spec.Spec.InterpreterPath -LauncherSha256 $spec.Spec.InterpreterSha `
            -InvocationDisplay $spec.Spec.ArgvDisplay -Arguments $Arguments `
            -WorkingDirectory $spec.Spec.WorkingDirectory -InvokingProcess $invoking `
            -LaunchedAtUtc $launchedAt -StdoutPath $stdoutPath -StderrPath $stderrPath `
            -Detail $_.Exception.Message
        $written = Write-P9HExitRecord -Path $exitPath -Record $record
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'start-failed'; Detail = $_.Exception.Message; ExitRecord = $written }
    }

    $exited = $false
    try { $exited = $proc.WaitForExit($TimeoutMs) }
    catch { $exited = $false }
    finally { $stopwatch.Stop() }

    $exitedAt = Get-P9HUtcStamp

    if (-not $exited) {
        $record = New-P9HExitRecord -TrialId $TrialId -Outcome 'timeout' `
            -LauncherPid $proc.Id -LauncherPath $spec.Spec.InterpreterPath -LauncherSha256 $spec.Spec.InterpreterSha `
            -InvocationDisplay $spec.Spec.ArgvDisplay -Arguments $Arguments `
            -WorkingDirectory $spec.Spec.WorkingDirectory -InvokingProcess $invoking `
            -LaunchedAtUtc $launchedAt -ExitedAtUtc $exitedAt -ElapsedMs $stopwatch.ElapsedMilliseconds `
            -StdoutPath $stdoutPath -StderrPath $stderrPath `
            -Detail ('launcher did not exit within {0} ms' -f $TimeoutMs)
        $written = Write-P9HExitRecord -Path $exitPath -Record $record
        return [pscustomobject][ordered]@{
            Ok         = $false
            Reason     = 'timeout'
            Detail     = ('launcher still running after {0} ms' -f $TimeoutMs)
            ExitRecord = $written
            Process    = $proc
        }
    }

    $code = $null
    try { $code = $proc.ExitCode }
    catch {
        $record = New-P9HExitRecord -TrialId $TrialId -Outcome 'identity-unknown' `
            -LauncherPid $proc.Id -LauncherPath $spec.Spec.InterpreterPath -LauncherSha256 $spec.Spec.InterpreterSha `
            -InvocationDisplay $spec.Spec.ArgvDisplay -Arguments $Arguments `
            -WorkingDirectory $spec.Spec.WorkingDirectory -InvokingProcess $invoking `
            -LaunchedAtUtc $launchedAt -ExitedAtUtc $exitedAt -ElapsedMs $stopwatch.ElapsedMilliseconds `
            -StdoutPath $stdoutPath -StderrPath $stderrPath -Detail $_.Exception.Message
        $written = Write-P9HExitRecord -Path $exitPath -Record $record
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'identity-unknown'; Detail = $_.Exception.Message; ExitRecord = $written }
    }

    $record = New-P9HExitRecord -TrialId $TrialId -Outcome 'exited' -ExitCode $code `
        -LauncherPid $proc.Id -LauncherPath $spec.Spec.InterpreterPath -LauncherSha256 $spec.Spec.InterpreterSha `
        -InvocationDisplay $spec.Spec.ArgvDisplay -Arguments $Arguments `
        -WorkingDirectory $spec.Spec.WorkingDirectory -InvokingProcess $invoking `
        -LaunchedAtUtc $launchedAt -ExitedAtUtc $exitedAt -ElapsedMs $stopwatch.ElapsedMilliseconds `
        -StdoutPath $stdoutPath -StderrPath $stderrPath

    $written = Write-P9HExitRecord -Path $exitPath -Record $record

    # Prerequisite for everything else: the record must exist and be valid.
    if (-not $written.Ok) {
        return [pscustomobject][ordered]@{
            Ok         = $false
            Reason     = 'exit-record-not-persisted'
            Detail     = $written.Reason
            ExitRecord = $written
            Process    = $proc
        }
    }

    if ($null -ne $OnExitRecordPersisted) {
        & $OnExitRecordPersisted $written.Data
    }

    return [pscustomobject][ordered]@{
        Ok         = $true
        Reason     = 'exit-record-persisted'
        Detail     = $null
        ExitRecord = $written
        Process    = $proc
    }
}

function Invoke-P9HProductLaunchRecorded {
    # The ONLY authorized path for a real installed-product launch.
    #
    # Adds the real-execution gate on top of the generic recorder. Stage 2 never
    # calls this: without the authorization token it throws before any process
    # is created, so accidentally invoking installed DevWS is structurally
    # impossible in this stage's tests.
    param(
        [Parameter(Mandatory)][string]$TrialId,
        [Parameter(Mandatory)][string]$CommandPath,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$ArtifactDirectory,
        [int]$TimeoutMs = 180000,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$AuthorizationToken
    )

    [void](Assert-P9HRealExecutionAuthorized -AuthorizationToken $AuthorizationToken -Action 'Invoke-P9HProductLaunchRecorded')

    return Invoke-P9HProcessRecorded -TrialId $TrialId -CommandPath $CommandPath `
        -Arguments $Arguments -WorkingDirectory $WorkingDirectory `
        -ArtifactDirectory $ArtifactDirectory -TimeoutMs $TimeoutMs
}
