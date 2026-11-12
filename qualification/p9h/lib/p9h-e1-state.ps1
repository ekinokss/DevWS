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

function New-P9HDisconnectPlan {
    # Validate and freeze the parameters of a controlled disconnect.
    #
    # The disconnect target is ALWAYS an explicit session id. An omitted id is a
    # hard error rather than an implicit 'current session', because an implicit
    # target could disconnect the observer's own session or the console.
    param(
        [Parameter(Mandatory)][string]$TrialId,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$TargetSessionId,
        [Parameter(Mandatory)][string]$TargetUser,
        [AllowNull()][string]$TargetLogonTime = $null,
        [ValidateSet('tsdiscon')][string]$Method = 'tsdiscon'
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

    if ([string]::IsNullOrWhiteSpace($TargetUser)) {
        throw 'P9-H: the disconnect target must name the account so the observation can be identity-matched.'
    }

    return [pscustomobject][ordered]@{
        TrialId         = $TrialId
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
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$AuthorizationToken,
        # NOT Mandatory: with a default value, Mandatory still makes PowerShell
        # PROMPT for the argument, which blocks a non-interactive harness. The
        # authorization token above is the real gate.
        [string]$TsdisconPath = (Join-Path $env:SystemRoot 'System32\tsdiscon.exe')
    )

    [void](Assert-P9HRealExecutionAuthorized -AuthorizationToken $AuthorizationToken -Action 'Invoke-P9HControlledDisconnect')

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
        }
    }

    return [pscustomobject][ordered]@{
        Ok       = ($proc.ExitCode -eq 0)
        Outcome  = if ($proc.ExitCode -eq 0) { 'exited' } else { 'nonzero-exit' }
        ExitCode = $proc.ExitCode
        Detail   = $null
        Utc      = Get-P9HUtcStamp
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
        # `Authoritative` defaults to TRUE only for a provider that says nothing
        # about capture status, which preserves the simple-caller contract; a
        # provider that reports a rejection is propagated verbatim and can never
        # be upgraded here.
        $providedAuthoritative = $true
        $authorityReason = $null
        $rejection = $null
        $win32 = @()
        $outcome = 'ok'
        $captureError = $null

        if ($null -ne $sample.PSObject.Properties['Authoritative']) {
            $providedAuthoritative = [bool]$sample.Authoritative
        }
        if ($null -ne $sample.PSObject.Properties['RejectionReason']) { $rejection = [string]$sample.RejectionReason }
        if ($null -ne $sample.PSObject.Properties['AuthorityReason']) { $authorityReason = [string]$sample.AuthorityReason }
        if ($null -ne $sample.PSObject.Properties['Win32Errors']) { $win32 = @($sample.Win32Errors) }
        if ($null -ne $sample.PSObject.Properties['CaptureOutcome']) { $outcome = [string]$sample.CaptureOutcome }
        if ($null -ne $sample.PSObject.Properties['CaptureError']) { $captureError = [string]$sample.CaptureError }

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
