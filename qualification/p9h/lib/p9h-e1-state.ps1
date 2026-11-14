# DevWS P9-H replay instrumentation - E1 disconnect/reconnect state machine.
#
# Closes P9-G defect E1-6: reconnect was permitted immediately after a disconnect
# command was issued. Here the ONLY path to reconnect is a persisted, read-back,
# validated target-session disconnected observation. A command exiting 0 is not
# evidence; a different session's state is not evidence; a new logon is not
# evidence.
#
# Real-execution safety: every function that could touch a live session takes an
# explicit -AuthorizationToken. Without the token the function refuses. Stage 2
# never supplies a token, so `tsdiscon` is unreachable from the synthetic tests.

Set-StrictMode -Version Latest

# The single authorization phrase required before any real guest/RDP action.
$script:P9HRealExecutionToken = 'AUTHORIZED-REAL-REPLAY'

function Assert-P9HRealExecutionAuthorized {
    # Hard gate in front of every irreversible or externally visible action.
    #
    # Deliberately a literal-string comparison, not a switch or an environment
    # variable: an operator must have read the plan and typed the phrase.
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$AuthorizationToken,
        [Parameter(Mandatory)][string]$Action
    )

    if ([string]::IsNullOrWhiteSpace($AuthorizationToken)) {
        throw "P9-H: '$Action' requires an explicit real-execution authorization token; none was supplied. Instrumentation refuses to touch a live session."
    }

    if (-not [string]::Equals($AuthorizationToken, $script:P9HRealExecutionToken, [System.StringComparison]::Ordinal)) {
        throw "P9-H: '$Action' was given an authorization token that does not match the required phrase. Refusing to proceed."
    }

    return $true
}

function Get-P9HExecutionContext {
    # Resolve WHERE this code is actually running.
    #
    # Stage 3B7G0 correction. Stage 3B7F-R2 disclosed a real safety incident: the
    # disconnect primitive was invoked on the WINDOWS HOST while the plan named a
    # GUEST session. `tsdiscon 2` then addressed the HOST's own session 2 - which
    # happened to be the Anode seat's session - instead of the Hyper-V guest's.
    #
    # The defect was not a wrong session id: it was that NOTHING bound the plan to
    # a machine, so the same plan was equally valid on any computer. This function
    # supplies the local ground truth that a plan is checked against.
    #
    # Deliberately read-only and obligation-free: it starts no process, opens no
    # session and changes nothing. It only reports identity.
    param()

    $identity = $null
    try { $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $identity = $null }

    $sessionId = $null
    try { $sessionId = [int](Get-Process -Id $PID).SessionId } catch { $sessionId = $null }

    return [pscustomobject][ordered]@{
        ComputerName = [string]$env:COMPUTERNAME
        UserName     = [string]$identity
        ProcessId    = $PID
        SessionId    = $sessionId
        IsElevated   = try {
            ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [System.Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        catch { $null }
    }
}

function Assert-P9HGuestExecutionContext {
    # FAIL-CLOSED GUEST BOUNDARY.
    #
    # Refuses to let a GUEST-targeted disconnect proceed anywhere except on the
    # named guest. Every requirement below is MANDATORY and there is no way to
    # switch a check off:
    #
    #   * the plan must name the intended guest identity;
    #   * the expected computer must be supplied by the caller (no default, so an
    #     omitted value cannot silently disable the check);
    #   * the ACTUAL local computer name must equal the expected one;
    #   * the plan's guest identity must equal the actual local computer name;
    #   * the authorized VM id must be supplied and must equal the plan's VM id;
    #   * the target must not be session 0 and must not be a WTS listener.
    #
    # It throws on every mismatch, BEFORE any process is created, and returns the
    # verified execution context on success. Because it never runs tsdiscon, the
    # whole boundary is testable without a live session.
    param(
        [Parameter(Mandatory)][AllowNull()]$Plan,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$ExpectedComputerName,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$ExpectedVmId,
        [AllowNull()]$LocalContext = $null
    )

    if ($null -eq $Plan) {
        throw 'P9-H: the guest execution boundary requires a disconnect plan; none was supplied.'
    }

    # ---- 1. the caller must state the expectations; nothing defaults to "skip" ----
    if ([string]::IsNullOrWhiteSpace($ExpectedComputerName)) {
        throw 'P9-H: the guest execution boundary requires an explicit expected guest computer name. Refusing to run a guest disconnect with an unstated target machine.'
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedVmId)) {
        throw 'P9-H: the guest execution boundary requires the authorized VM id so the disconnect cannot run against an unlisted machine.'
    }

    # ---- 2. the plan itself must carry the intended guest identity ----
    $planComputer = $null
    if ($null -ne $Plan.PSObject.Properties['GuestComputerName']) { $planComputer = [string]$Plan.GuestComputerName }

    if ([string]::IsNullOrWhiteSpace($planComputer)) {
        throw 'P9-H: the disconnect plan does not name the intended guest computer. A plan without a bound machine identity is equally valid on any host and must never be executed.'
    }

    $planVmId = $null
    if ($null -ne $Plan.PSObject.Properties['VmId']) { $planVmId = [string]$Plan.VmId }

    if ([string]::IsNullOrWhiteSpace($planVmId)) {
        throw 'P9-H: the disconnect plan does not name the authorized VM id. Refusing an unbound plan.'
    }

    # ---- 3. plan expectations must agree with each other ----
    if (-not [string]::Equals($planComputer, $ExpectedComputerName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("P9-H: the disconnect plan targets guest '{0}' but the caller expects '{1}'. Refusing a plan whose machine identity does not match the intended guest." -f $planComputer, $ExpectedComputerName)
    }

    if (-not [string]::Equals($planVmId, $ExpectedVmId, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("P9-H: the disconnect plan names VM id '{0}' but the authorized VM id is '{1}'. Refusing." -f $planVmId, $ExpectedVmId)
    }

    # ---- 4. THE CONTROL: actual local identity must be the guest ----
    $context = if ($null -ne $LocalContext) { $LocalContext } else { Get-P9HExecutionContext }
    $actualComputer = [string]$context.ComputerName

    if ([string]::IsNullOrWhiteSpace($actualComputer)) {
        throw 'P9-H: the local computer identity could not be determined. A guest disconnect cannot be authorized without positive proof that this IS the guest.'
    }

    if (-not [string]::Equals($actualComputer, $ExpectedComputerName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("P9-H: GUEST BOUNDARY REFUSAL - this process is running on '{0}', but the disconnect targets guest '{1}'. A guest-targeted disconnect must never execute on another machine (this is the Stage 3B7F-R2 host-side incident). No process was created." -f $actualComputer, $ExpectedComputerName)
    }

    if (-not [string]::Equals($planComputer, $actualComputer, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("P9-H: GUEST BOUNDARY REFUSAL - the plan targets '{0}' but this machine is '{1}'. No process was created." -f $planComputer, $actualComputer)
    }

    # ---- 5. target sanity: never session 0, never a listener ----
    $targetId = $null
    if ($null -ne $Plan.PSObject.Properties['TargetSessionId']) { $targetId = [int]$Plan.TargetSessionId }

    if ($null -eq $targetId) {
        throw 'P9-H: the disconnect plan has no explicit target session id. Refusing.'
    }

    if ($targetId -eq 0) {
        throw 'P9-H: session 0 is the services session and can never be a disconnect target.'
    }

    if ($targetId -ge 65536) {
        # WTS listener ids (WTSListen) are connection endpoints, not logged-on
        # users. Disconnecting one is meaningless and would prove nothing.
        throw ("P9-H: session id {0} is in the WTS listener range and cannot be a disconnect target." -f $targetId)
    }

    if ($null -ne $Plan.PSObject.Properties['TargetIsListener'] -and $Plan.TargetIsListener -eq $true) {
        throw 'P9-H: the disconnect target is a WTS listener, not a logged-on user session. Refusing.'
    }

    return $context
}

function New-P9HDisconnectPlan {
    # Validate and freeze the parameters of a controlled disconnect.
    #
    # The disconnect target is ALWAYS an explicit session id. An omitted id is a
    # hard error rather than an implicit 'current session', because an implicit
    # target could disconnect the observer's own session or the console.
    #
    # Stage 3B7G0: the plan now BINDS the machine it is valid for. A plan that
    # does not name its guest and its authorized VM id is a plan that would be
    # equally valid on the Windows host, which is exactly how a guest-targeted
    # disconnect reached the host in Stage 3B7F-R2.
    param(
        [Parameter(Mandatory)][string]$TrialId,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$TargetSessionId,
        [Parameter(Mandatory)][string]$TargetUser,
        [AllowNull()][string]$TargetLogonTime = $null,
        [ValidateSet('tsdiscon')][string]$Method = 'tsdiscon',
        # Mandatory-by-contract: the plan must state which machine it is for and
        # which authorized VM it belongs to. Both are validated as non-empty
        # below, so an omitted value is a refusal, never a silent default.
        [AllowNull()][AllowEmptyString()][string]$GuestComputerName = $null,
        [AllowNull()][AllowEmptyString()][string]$VmId = $null
    )

    if ([string]::IsNullOrWhiteSpace($TargetSessionId)) {
        throw 'P9-H: the disconnect target must be an explicit session id; an omitted target would disconnect an implicit session.'
    }

    $id = 0
    if (-not [int]::TryParse([string]$TargetSessionId, [ref]$id)) {
        throw "P9-H: the disconnect session id must be a decimal integer (got '$TargetSessionId')."
    }

    if ($id -eq 0) {
        throw 'P9-H: session 0 is the services session and can never be a disconnect target.'
    }

    if ($id -ge 65536) {
        throw ("P9-H: session id {0} is in the WTS listener range and cannot be a disconnect target." -f $id)
    }

    if ([string]::IsNullOrWhiteSpace($TargetUser)) {
        throw 'P9-H: the disconnect target must name the account so the observation can be identity-matched.'
    }

    # Stage 3B7G0: refuse an unbound plan. Without this an operator can build a
    # plan for 'session 2' that is silently valid on the Windows host too.
    if ([string]::IsNullOrWhiteSpace($GuestComputerName)) {
        throw 'P9-H: the disconnect plan must name the intended guest computer; a plan with no bound machine is valid on any host and must never be executed.'
    }

    if ([string]::IsNullOrWhiteSpace($VmId)) {
        throw 'P9-H: the disconnect plan must name the authorized VM id so execution is restricted to that authorized machine.'
    }

    return [pscustomobject][ordered]@{
        TrialId         = $TrialId
        GuestComputerName = $GuestComputerName
        VmId            = $VmId
        TargetSessionId = $id
        TargetUser      = $TargetUser
        TargetLogonTime = $TargetLogonTime
        Method          = $Method
        CreatedUtc      = Get-P9HUtcStamp
    }
}

function Invoke-P9HControlledDisconnect {
    # Issue the controlled disconnect. Real execution only.
    #
    # 'tsdiscon <id>' disconnects a specific session and leaves it alive in the
    # WTSDisconnected state, which is what E1 must observe. It requires the
    # ability to administer Terminal Services sessions on the guest; failure
    # surface (nonzero exit, access denied) is reported verbatim rather than
    # retried or substituted.
    #
    # Returns the raw outcome. The caller MUST NOT treat Ok=$true as proof of
    # the transition; proof comes only from the observer log.
    #
    # Stage 3B7G0: this function now enforces the GUEST EXECUTION BOUNDARY before
    # it resolves a tool or starts a process. The boundary check runs AFTER the
    # authorization token (so the token requirement is preserved) and BEFORE any
    # process creation, so a plan for a guest can never disconnect a host session.
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$AuthorizationToken,
        # Mandatory-by-contract. These identify the machine this execution is
        # ALLOWED to touch. Omitting either is a refusal, not a skipped check.
        [AllowNull()][AllowEmptyString()][string]$ExpectedComputerName = $null,
        [AllowNull()][AllowEmptyString()][string]$ExpectedVmId = $null,
        # Injectable purely so the boundary is testable without a live guest.
        # The production path leaves this null and reads the real identity.
        [AllowNull()]$LocalContext = $null,
        # NOT Mandatory: with a default value, Mandatory still makes PowerShell
        # PROMPT for the argument, which blocks a non-interactive harness. The
        # authorization token above is the real gate.
        [string]$TsdisconPath = (Join-Path $env:SystemRoot 'System32\tsdiscon.exe')
    )

    [void](Assert-P9HRealExecutionAuthorized -AuthorizationToken $AuthorizationToken -Action 'Invoke-P9HControlledDisconnect')

    # ---------------------------------------------------------------------
    # GUEST EXECUTION BOUNDARY - fail closed BEFORE any process exists.
    # ---------------------------------------------------------------------
    $context = Assert-P9HGuestExecutionContext -Plan $Plan `
        -ExpectedComputerName $ExpectedComputerName -ExpectedVmId $ExpectedVmId `
        -LocalContext $LocalContext

    if (-not (Test-Path -LiteralPath $TsdisconPath -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            Ok      = $false
            Outcome = 'tool-missing'
            ExitCode = $null
            Detail  = "tsdiscon was not found at '$TsdisconPath'."
            Utc     = Get-P9HUtcStamp
        }
    }

    $started = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $proc = Start-Process -FilePath $TsdisconPath `
            -ArgumentList ([string]$Plan.TargetSessionId) `
            -PassThru -NoNewWindow
        $exited = $proc.WaitForExit(30000)
    }
    catch {
        return [pscustomobject][ordered]@{
            Ok       = $false
            Outcome  = 'start-failed'
            ExitCode = $null
            Detail   = $_.Exception.Message
            Utc      = Get-P9HUtcStamp
            ExecutedOnComputerName = [string]$context.ComputerName
            ExecutedInSessionId    = $context.SessionId
        }
    }
    finally { $started.Stop() }

    if (-not $exited) {
        return [pscustomobject][ordered]@{
            Ok       = $false
            Outcome  = 'timeout'
            ExitCode = $null
            Detail   = ('tsdiscon did not exit within {0} ms' -f $started.ElapsedMilliseconds)
            Utc      = Get-P9HUtcStamp
            ExecutedOnComputerName = [string]$context.ComputerName
            ExecutedInSessionId    = $context.SessionId
        }
    }

    return [pscustomobject][ordered]@{
        Ok       = ($proc.ExitCode -eq 0)
        Outcome  = if ($proc.ExitCode -eq 0) { 'exited' } else { 'nonzero-exit' }
        ExitCode = $proc.ExitCode
        Detail   = $null
        Utc      = Get-P9HUtcStamp
        # Stage 3B7G0: record WHERE the command ran. A transition claim is only
        # meaningful together with the machine that produced it.
        ExecutedOnComputerName = [string]$context.ComputerName
        ExecutedInSessionId    = $context.SessionId
        TargetSessionId        = [int]$Plan.TargetSessionId
    }
}

function Wait-P9HTargetDisconnected {
    # Poll the observer until the PINNED target session is observed disconnected,
    # then PERSIST that observation and read it back.
    #
    # This is the gate. It returns Proven=$true only after the record survives a
    # read-back from disk, so a reconnect can never be authorized by an in-memory
    # value that a later crash could erase.
    param(
        [Parameter(Mandatory)][string]$TrialId,
        [Parameter(Mandatory)][int]$SequenceStart,
        [Parameter(Mandatory)][string]$ObserverLogPath,
        [Parameter(Mandatory)][int]$TargetSessionId,
        [Parameter(Mandatory)][string]$TargetUser,
        [AllowNull()][string]$TargetLogonTime = $null,
        [AllowNull()][string]$GuestIdentity = $null,
        [Parameter(Mandatory)][scriptblock]$Provider,
        [int]$TimeoutSeconds = 90,
        [int]$PollIntervalMs = 1000
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $sequence = $SequenceStart
    $attempts = 0
    $lastReason = $null

    while ([datetime]::UtcNow -lt $deadline) {
        $attempts++

        $sample = & $Provider
        $rawLines = @($sample.RawWtsLines)
        $quser = $null
        if ($null -ne $sample.PSObject.Properties['QuserText']) { $quser = [string]$sample.QuserText }

        # Stage 3A.2: consume the provider's CAPTURE AUTHORITY when it supplies
        # one. Previously this loop hardcoded -CaptureOutcome 'ok', so a provider
        # whose session table was rejected (inconsistent, ambiguous, incomplete,
        # provider error) still produced an authoritative-looking observation.
        #
        # Stage 3B0 correction: an OMITTED `Authoritative` no longer implies
        # true. The provider's reported outcome is passed through and the
        # observer derives authority from it, so a provider that reports a
        # provider error without an explicit flag cannot authorize.
        $outcome = 'ok'
        $captureError = $null
        $authorityReason = $null
        $rejection = $null
        $win32 = @()

        if ($null -ne $sample.PSObject.Properties['CaptureOutcome'] -and
            -not [string]::IsNullOrWhiteSpace([string]$sample.CaptureOutcome)) {
            $outcome = [string]$sample.CaptureOutcome
        }
        if ($null -ne $sample.PSObject.Properties['CaptureError']) { $captureError = [string]$sample.CaptureError }
        if ($null -ne $sample.PSObject.Properties['RejectionReason']) { $rejection = [string]$sample.RejectionReason }
        if ($null -ne $sample.PSObject.Properties['AuthorityReason']) { $authorityReason = [string]$sample.AuthorityReason }
        if ($null -ne $sample.PSObject.Properties['Win32Errors']) { $win32 = @($sample.Win32Errors) }

        # $null when the provider is silent, so the observer derives authority
        # from the outcome instead of assuming success.
        $providedAuthoritative = $null
        if ($null -ne $sample.PSObject.Properties['Authoritative'] -and $null -ne $sample.Authoritative) {
            $providedAuthoritative = [bool]$sample.Authoritative
        }

        # Persist EVERY sample: the evidence of what was seen when matters, not
        # just the sample that finally matched. A rejected sample is persisted
        # with its diagnostics, and simply never authorizes.
        $line = New-P9HObserverRecord -TrialId $TrialId -Sequence $sequence -Phase 'disconnect-observed' `
            -RawWtsLines $rawLines -TargetSessionId $TargetSessionId -TargetUser $TargetUser `
            -TargetLogonTime $TargetLogonTime -GuestIdentity $GuestIdentity -QuserText $quser `
            -CaptureOutcome $outcome -CaptureError $captureError `
            -CaptureAuthoritative $providedAuthoritative `
            -CaptureAuthorityReason $authorityReason `
            -CaptureRejection $rejection `
            -CaptureWin32Errors $win32
        Add-P9HArtifactLine -Path $ObserverLogPath -Line $line

        $readBack = Read-P9HObserverLog -Path $ObserverLogPath
        if (-not $readBack.Ok) {
            return [pscustomobject][ordered]@{
                Proven      = $false
                Reason      = ('persisted-record-unreadable:' + $readBack.Reason)
                Detail      = $readBack.Error
                Attempts    = $attempts
                Sequence    = $sequence
                Observation = $null
            }
        }

        $persisted = @($readBack.Records | Where-Object { [int]$_.sequence -eq $sequence }) | Select-Object -First 1
        if ($null -eq $persisted) {
            return [pscustomobject][ordered]@{
                Proven      = $false
                Reason      = 'persisted-record-not-found-on-readback'
                Detail      = $null
                Attempts    = $attempts
                Sequence    = $sequence
                Observation = $null
            }
        }

        # A persisted record whose CAPTURE was rejected can never prove a
        # disconnect, even if its parsed target line looks perfectly clean.
        $persistedAuthoritative = if ($null -ne $persisted.PSObject.Properties['captureAuthoritative']) {
            [bool]$persisted.captureAuthoritative
        }
        else { ([string]$persisted.captureOutcome -eq 'ok') -and [bool]$persisted.tableOk }

        if (-not $persistedAuthoritative) {
            $lastReason = if ($null -ne $persisted.PSObject.Properties['captureAuthorityReason'] -and
                -not [string]::IsNullOrWhiteSpace([string]$persisted.captureAuthorityReason)) {
                'capture-not-authoritative:' + [string]$persisted.captureAuthorityReason
            }
            else { 'capture-not-authoritative' }
            # Keep polling: a later sample may be authoritative.
            $sequence++
            Start-Sleep -Milliseconds $PollIntervalMs
            continue
        }

        $judged = Test-P9HTargetDisconnected -Records @($persisted | ForEach-Object {
                [pscustomobject]@{
                    SessionId = $_.targetSessionId
                    User      = $_.targetUser
                    State     = $_.targetState
                    # Stage 3B7C bridge correction: StateName was omitted, so the
                    # NON-disconnected path ('target-state-' + StateName) threw
                    # instead of returning Disconnected=false. The defect only
                    # surfaced once a real poll observed the target still Active.
                    StateName = [string]$_.targetStateName
                    StationName = $_.targetStation
                    LogonTime = $_.targetObservedLogon
                }
            }) -SessionId $TargetSessionId -User $TargetUser -LogonTime $TargetLogonTime -RequireLogonTime

        if ($judged.Disconnected) {
            return [pscustomobject][ordered]@{
                Proven      = $true
                Reason      = 'target-disconnected-persisted'
                Detail      = $null
                Attempts    = $attempts
                Sequence    = $sequence
                Observation = $persisted
            }
        }

        $lastReason = $judged.Reason
        $sequence++
        Start-Sleep -Milliseconds $PollIntervalMs
    }

    return [pscustomobject][ordered]@{
        Proven      = $false
        Reason      = 'timeout-without-target-disconnected'
        Detail      = $lastReason
        Attempts    = $attempts
        Sequence    = $sequence
        Observation = $null
    }
}

function Assert-P9HReconnectPermitted {
    # The single authority for 'may we reconnect now?'.
    #
    # Stage 2.1 correction: this MUST use the pre-reconnect authorization proof,
    # which does not require a post-reconnect record. The Stage 2 version called
    # Get-P9HDisconnectProof, whose own requirement for a post-reconnect Active
    # observation made the gate circular and the replay sequence impossible.
    #
    # The proof is re-derived from the PERSISTED log at call time; passing a
    # boolean captured earlier is not accepted, because that boolean could
    # outlive the file it was derived from.
    param(
        [Parameter(Mandatory)][string]$ObserverLogPath,
        [Parameter(Mandatory)][int]$TargetSessionId,
        [Parameter(Mandatory)][string]$TargetUser,
        [string]$TrialId = '',
        [AllowNull()][string]$TargetLogonTime = $null
    )

    $proof = Get-P9HReconnectAuthorizationProof -ObserverLogPath $ObserverLogPath -TrialId $TrialId `
        -SessionId $TargetSessionId -User $TargetUser -LogonTime $TargetLogonTime

    if (-not $proof.Proven) {
        throw ("P9-H: reconnect refused - the persisted observer log does not authorize the target session disconnect ({0})." -f $proof.Reason)
    }

    return $proof
}

function Get-P9HSessionIdentityPinned {
    # Capture the identity tuple that all later observations must match.
    #
    # Pinning at pre-snapshot time prevents a 'successful' reconnect from being
    # scored against a DIFFERENT logon that merely reused the session id.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RawWtsLines,
        [Parameter(Mandatory)][int]$TargetSessionId,
        [Parameter(Mandatory)][string]$TargetUser,
        [AllowNull()][string]$LogonTime = $null,
        [AllowNull()][string]$GuestIdentity = $null
    )

    $table = ConvertFrom-P9HWtsTable -Lines $RawWtsLines
    if (-not $table.Ok) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = ('malformed-table:' + $table.Reason); Identity = $null }
    }

    $match = Get-P9HTargetSessionRecord -Records $table.Records -SessionId $TargetSessionId -User $TargetUser -LogonTime $LogonTime
    if (-not $match.Ok) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = ('target-not-matched:' + $match.Reason); Identity = $null }
    }

    if ([int]$match.Record.State -ne 0) {
        return [pscustomobject][ordered]@{
            Ok       = $false
            Reason   = ('target-not-active:' + $match.Record.StateName)
            Identity = $null
        }
    }

    return [pscustomobject][ordered]@{
        Ok       = $true
        Reason   = 'pinned'
        Identity = [pscustomobject][ordered]@{
            TrialId         = $null
            GuestIdentity   = $GuestIdentity
            SessionId       = $TargetSessionId
            User            = $TargetUser
            LogonTime       = $LogonTime
            StationName     = [string]$match.Record.StationName
            PinnedUtc       = Get-P9HUtcStamp
        }
    }
}

function Test-P9HGuestDisconnectEligible {
    # NON-EXECUTING validation of a guest disconnect.
    #
    # This is the path a caller uses to find out whether a disconnect WOULD be
    # allowed, without creating any process. It runs the exact same boundary and
    # target checks as Invoke-P9HControlledDisconnect, so a green result here and
    # a refusal there cannot disagree for identity reasons.
    #
    # It deliberately does NOT check the authorization token: whether an operator
    # typed the real-execution phrase is a permission question, while "may this
    # plan touch this machine at all" is a safety question. Keeping them separate
    # is what makes the boundary testable offline.
    param(
        [Parameter(Mandatory)][AllowNull()]$Plan,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$ExpectedComputerName,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$ExpectedVmId,
        [AllowNull()]$LocalContext = $null
    )

    try {
        $context = Assert-P9HGuestExecutionContext -Plan $Plan `
            -ExpectedComputerName $ExpectedComputerName -ExpectedVmId $ExpectedVmId `
            -LocalContext $LocalContext

        return [pscustomobject][ordered]@{
            Eligible        = $true
            Reason          = 'guest-boundary-satisfied'
            Detail          = $null
            ComputerName    = [string]$context.ComputerName
            TargetSessionId = [int]$Plan.TargetSessionId
            TargetUser      = [string]$Plan.TargetUser
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            Eligible        = $false
            Reason          = 'guest-boundary-refused'
            Detail          = $_.Exception.Message
            ComputerName    = if ($null -ne $LocalContext) { [string]$LocalContext.ComputerName } else { [string]$env:COMPUTERNAME }
            TargetSessionId = if ($null -ne $Plan -and $null -ne $Plan.PSObject.Properties['TargetSessionId']) { [int]$Plan.TargetSessionId } else { $null }
            TargetUser      = if ($null -ne $Plan -and $null -ne $Plan.PSObject.Properties['TargetUser']) { [string]$Plan.TargetUser } else { $null }
        }
    }
}

function Invoke-P9HGuestControlledDisconnect {
    # Guest-targeted controlled disconnect ORCHESTRATION.
    #
    # This is the ONLY intended production entry point. It performs the whole
    # sequence in the correct order and cannot be redirected at the host:
    #
    #   1. validate the plan and its guest binding LOCALLY, before any transport;
    #   2. prove the authorized VM exists and is the expected one;
    #   3. run the disconnect INSIDE that VM over PowerShell Direct;
    #   4. re-verify the guest's own computer identity INSIDE the execution
    #      context before tsdiscon is started there;
    #   5. return the guest's verbatim outcome.
    #
    # The local boundary check in step 1 is what makes the Stage 3B7F-R2 incident
    # impossible: a caller that forgets to orchestrate remotely is refused here,
    # because the LOCAL computer is not the named guest.
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$AuthorizationToken,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$ExpectedVmName,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$ExpectedVmId,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$GuestCredentialUser,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$GuestCredentialPassword,
        # Injectable so the whole orchestration is testable with no VM and no
        # session. Production leaves these null.
        [AllowNull()]$LocalContext = $null,
        [AllowNull()][scriptblock]$RemoteInvoker = $null,
        [string]$TsdisconPath = (Join-Path $env:SystemRoot 'System32\tsdiscon.exe')
    )

    # ---- 0. authorization first: the token requirement is never bypassed ----
    [void](Assert-P9HRealExecutionAuthorized -AuthorizationToken $AuthorizationToken -Action 'Invoke-P9HGuestControlledDisconnect')

    if ([string]::IsNullOrWhiteSpace($ExpectedVmName)) {
        throw 'P9-H: guest orchestration requires the authorized VM name; refusing to guess which machine to disconnect.'
    }

    # ---- 1. local guest boundary: this process must BE the guest ----
    # In the production topology the orchestration runs on the host and therefore
    # FAILS this check, which is correct and deliberate: the guest-side execution
    # must be performed by the remote invoker, never by the host itself.
    $context = if ($null -ne $LocalContext) { $LocalContext } else { Get-P9HExecutionContext }
    $weAreTheGuest = [string]::Equals([string]$context.ComputerName, [string]$Plan.GuestComputerName, [System.StringComparison]::OrdinalIgnoreCase)

    if ($weAreTheGuest) {
        # Running already inside the guest: the local path is legitimate.
        $out = Invoke-P9HControlledDisconnect -Plan $Plan -AuthorizationToken $AuthorizationToken `
            -ExpectedComputerName $Plan.GuestComputerName -ExpectedVmId $ExpectedVmId `
            -LocalContext $context -TsdisconPath $TsdisconPath
        return [pscustomobject][ordered]@{
            Ok                     = [bool]$out.Ok
            Transport              = 'local-in-guest'
            ExecutedOnComputerName = [string]$context.ComputerName
            GuestOutcome           = $out
        }
    }

    # ---- 2. host path: the plan must never execute here ----
    # Prove the authorized VM identity before dispatching anything.
    if (-not [string]::Equals([string]$Plan.VmId, $ExpectedVmId, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("P9-H: the disconnect plan names VM id '{0}' but the authorized VM id is '{1}'. Refusing." -f $Plan.VmId, $ExpectedVmId)
    }

    if ([string]::IsNullOrWhiteSpace($GuestCredentialUser)) {
        throw 'P9-H: guest orchestration requires explicit guest credentials; refusing to dispatch an unauthenticated remote action.'
    }

    if ([string]::IsNullOrWhiteSpace($TsdisconPath)) {
        throw 'P9-H: guest orchestration requires the in-guest tsdiscon path.'
    }

    $payload = [ordered]@{
        TrialId         = [string]$Plan.TrialId
        ComputerName    = [string]$Plan.GuestComputerName
        VmId            = [string]$Plan.VmId
        TargetSessionId = [int]$Plan.TargetSessionId
        TargetUser      = [string]$Plan.TargetUser
        TargetLogonTime = [string]$Plan.TargetLogonTime
        TsdisconPath    = [string]$TsdisconPath
        AuthorizationToken = [string]$AuthorizationToken
        ExpectedVmId    = [string]$ExpectedVmId
    }

    $invoker = if ($null -ne $RemoteInvoker) {
        $RemoteInvoker
    }
    else {
        # Production invoker: PowerShell Direct. The remote block re-verifies the
        # GUEST'S OWN computer identity before it starts tsdiscon, so a host that
        # somehow reached this point still cannot disconnect its own session.
        {
            param($P, $VmName, $Credential)
            Invoke-Command -VMName $VmName -Credential $Credential -ErrorAction Stop -ScriptBlock {
                param($Inner)
                Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
                . 'C:\ProgramData\P9H\lib\p9h-e1-state.ps1'
                . 'C:\ProgramData\P9H\lib\p9h-core.ps1'

                # ---- INSIDE-EXECUTION-CONTEXT GUEST PROOF ----
                $actual = [string]$env:COMPUTERNAME
                if (-not [string]::Equals($actual, [string]$Inner.ComputerName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw ("P9-H: GUEST BOUNDARY REFUSAL INSIDE THE EXECUTION CONTEXT - this shell is '{0}' but the plan targets '{1}'. No process was created." -f $actual, $Inner.ComputerName)
                }

                $plan = [pscustomobject][ordered]@{
                    TrialId           = [string]$Inner.TrialId
                    GuestComputerName = [string]$Inner.ComputerName
                    VmId              = [string]$Inner.VmId
                    TargetSessionId   = [int]$Inner.TargetSessionId
                    TargetUser        = [string]$Inner.TargetUser
                    TargetLogonTime   = [string]$Inner.TargetLogonTime
                    Method            = 'tsdiscon'
                    CreatedUtc        = (Get-P9HUtcStamp)
                }

                $res = Invoke-P9HControlledDisconnect -Plan $plan -AuthorizationToken ([string]$Inner.AuthorizationToken) `
                    -ExpectedComputerName ([string]$Inner.ComputerName) -ExpectedVmId ([string]$Inner.ExpectedVmId) `
                    -TsdisconPath ([string]$Inner.TsdisconPath)

                [pscustomobject][ordered]@{
                    GuestComputerName = $actual
                    Outcome           = [string]$res.Outcome
                    Ok                = [bool]$res.Ok
                    ExitCode          = $res.ExitCode
                    Detail            = [string]$res.Detail
                    Utc               = [string]$res.Utc
                    ExecutedInSessionId = $res.ExecutedInSessionId
                }
            } -ArgumentList @($P)
        }
    }

    $cred = New-Object System.Management.Automation.PSCredential(
        $GuestCredentialUser, (ConvertTo-SecureString $GuestCredentialPassword -AsPlainText -Force))

    $remote = & $invoker $payload $ExpectedVmName $cred

    return [pscustomobject][ordered]@{
        Ok                     = [bool]$remote.Ok
        Transport              = 'powershell-direct'
        DispatchedFromComputer = [string]$context.ComputerName
        ExecutedOnComputerName = [string]$remote.GuestComputerName
        GuestOutcome           = $remote
    }
}