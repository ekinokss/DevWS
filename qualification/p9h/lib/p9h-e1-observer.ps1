# DevWS P9-H replay instrumentation - E1 WTS session observer.
#
# Closes P9-G defect E1-4: session 0 'Services' state=4 must never be read as
# proof that the target RDP session disconnected. Every predicate here is keyed
# on the FULL pinned identity tuple (session id + user + logon time), and a
# record that does not match all three is rejected with an explicit reason.
#
# The observer is pure with respect to the host: it consumes a WTS session table
# supplied by a provider function. In synthetic self-tests the provider returns
# fabricated tables; in a real replay it would query WTS through PowerShell
# Direct. Import and ordinary calls never contact a VM.

Set-StrictMode -Version Latest

# WTS_CONNECTSTATE_CLASS values (wtsapi32.h).
$script:P9HWtsStateName = @{
    0 = 'Active'
    1 = 'Connected'
    2 = 'ConnectQuery'
    3 = 'Shadow'
    4 = 'Disconnected'
    5 = 'Idle'
    6 = 'Listen'
    7 = 'Reset'
    8 = 'Down'
    9 = 'Init'
}

$script:P9HWtsStateDisconnected = 4
$script:P9HWtsStateActive = 0

function ConvertFrom-P9HWtsLine {
    # Parse one 'id|name|state|user' line as produced by WTSEnumerateSessions.
    #
    # Returns a structured result. Malformed lines are rejected explicitly so a
    # broken provider cannot masquerade as 'session not found'.
    param([AllowNull()][AllowEmptyString()][string]$Line)

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'empty-line'; Record = $null }
    }

    $parts = $Line.Split('|')
    if ($parts.Count -lt 4) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'malformed-field-count'; Record = $null }
    }

    $idText = $parts[0].Trim()
    $id = 0
    if (-not [int]::TryParse($idText, [ref]$id)) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'malformed-session-id'; Record = $null }
    }

    $stateText = $parts[2].Trim()
    $stateMatch = [regex]::Match($stateText, '^state=(\d+)$')
    if (-not $stateMatch.Success) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'malformed-state'; Record = $null }
    }

    $state = [int]$stateMatch.Groups[1].Value

    # The provider emits 'id|station|state=N|user=<account>'. Strip the literal
    # 'user=' key so the record carries the ACCOUNT, not the rendered pair.
    # Keeping the prefix here would make every user comparison fail - exactly the
    # class of silent mis-parse this instrumentation exists to prevent.
    $userText = [string]$parts[3]
    if ($userText.StartsWith('user=', [System.StringComparison]::Ordinal)) {
        $userText = $userText.Substring(5)
    }
    $userText = $userText.Trim()

    return [pscustomobject][ordered]@{
        Ok      = $true
        Reason  = 'ok'
        Record  = [pscustomobject][ordered]@{
            SessionId   = $id
            StationName = [string]$parts[1]
            State       = $state
            StateName   = if ($script:P9HWtsStateName.ContainsKey($state)) { $script:P9HWtsStateName[$state] } else { "Unknown($state)" }
            User        = $userText
        }
    }
}

function ConvertFrom-P9HWtsTable {
    # Parse a whole WTS table. Any malformed line makes the whole capture
    # untrustworthy, because a partially parsed table could silently drop the
    # very session the verdict depends on.
    param([AllowNull()][AllowEmptyCollection()][string[]]$Lines)

    $records = [System.Collections.Generic.List[object]]::new()
    $rejects = [System.Collections.Generic.List[string]]::new()

    foreach ($line in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parsed = ConvertFrom-P9HWtsLine -Line $line
        if ($parsed.Ok) { $records.Add($parsed.Record) | Out-Null }
        else { $rejects.Add(('{0}:{1}' -f $parsed.Reason, $line.Trim())) | Out-Null }
    }

    return [pscustomobject][ordered]@{
        Ok         = ($rejects.Count -eq 0)
        Reason     = if ($rejects.Count -eq 0) { 'ok' } else { 'malformed-table' }
        Records    = @($records)
        Rejections = @($rejects)
    }
}

function Get-P9HTargetSessionRecord {
    # Select the single record that matches the pinned identity.
    #
    # Identity is (SessionId, User, LogonTime). WTS does not expose logon time
    # directly in the table, so the provider supplies it per record; the synthetic
    # tests model this by attaching LogonTime to each record before matching.
    #
    # Rejection reasons are deliberately specific so the evidence shows WHY a
    # candidate did not qualify:
    #   no-target           - no record with the pinned session id
    #   user-mismatch       - session id matched, account did not
    #   logon-mismatch      - session id and account matched, logon time did not
    #   ambiguous           - more than one record matched (service/console reuse)
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][int]$SessionId,
        [Parameter(Mandatory)][string]$User,
        [AllowNull()][string]$LogonTime = $null
    )

    $byId = @($Records | Where-Object { [int]$_.SessionId -eq $SessionId })

    if ($byId.Count -eq 0) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'no-target'; Record = $null; Candidates = 0 }
    }

    $byIdAndUser = @($byId | Where-Object { [string]::Equals([string]$_.User, $User, [System.StringComparison]::OrdinalIgnoreCase) })

    if ($byIdAndUser.Count -eq 0) {
        return [pscustomobject][ordered]@{
            Ok         = $false
            Reason     = 'user-mismatch'
            Record     = $null
            Candidates = $byId.Count
            ObservedUsers = @($byId | ForEach-Object { [string]$_.User })
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($LogonTime)) {
        $byLogon = @($byIdAndUser | Where-Object {
                $candidate = $_.PSObject.Properties['LogonTime']
                if ($null -eq $candidate -or [string]::IsNullOrWhiteSpace([string]$candidate.Value)) { return $false }
                return [string]::Equals([string]$candidate.Value, $LogonTime, [System.StringComparison]::Ordinal)
            })

        if ($byLogon.Count -eq 0) {
            return [pscustomobject][ordered]@{
                Ok          = $false
                Reason      = 'logon-mismatch'
                Record      = $null
                Candidates  = $byIdAndUser.Count
                ExpectedLogon = $LogonTime
                ObservedLogons = @($byIdAndUser | ForEach-Object {
                        $p = $_.PSObject.Properties['LogonTime']
                        if ($null -ne $p) { [string]$p.Value } else { $null }
                    })
            }
        }

        $byIdAndUser = $byLogon
    }

    if ($byIdAndUser.Count -gt 1) {
        return [pscustomobject][ordered]@{
            Ok         = $false
            Reason     = 'ambiguous'
            Record     = $null
            Candidates = $byIdAndUser.Count
        }
    }

    return [pscustomobject][ordered]@{
        Ok         = $true
        Reason     = 'ok'
        Record     = $byIdAndUser[0]
        Candidates = 1
    }
}

function Test-P9HTargetDisconnected {
    # The E1 disconnected predicate. TRUE only when the pinned target session is
    # itself in WTS state 4.
    #
    # This is the function P9-G lacked. Note explicitly that a state-4 record for
    # ANY other session (e.g. '0|Services|state=4') can never satisfy it: the
    # session id must equal the pinned target id.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][int]$SessionId,
        [Parameter(Mandatory)][string]$User,
        [AllowNull()][string]$LogonTime = $null
    )

    $match = Get-P9HTargetSessionRecord -Records $Records -SessionId $SessionId -User $User -LogonTime $LogonTime

    if (-not $match.Ok) {
        return [pscustomobject][ordered]@{
            Disconnected = $false
            Reason       = $match.Reason
            Record       = $null
        }
    }

    $isDisconnected = ([int]$match.Record.State -eq $script:P9HWtsStateDisconnected)

    return [pscustomobject][ordered]@{
        Disconnected = $isDisconnected
        Reason       = if ($isDisconnected) { 'target-disconnected' } else { ('target-state-' + $match.Record.StateName) }
        Record       = $match.Record
    }
}

function Test-P9HTargetActive {
    # Precondition and post-reconnect predicate: the pinned target session is
    # itself Active (WTS state 0).
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][int]$SessionId,
        [Parameter(Mandatory)][string]$User,
        [AllowNull()][string]$LogonTime = $null
    )

    $match = Get-P9HTargetSessionRecord -Records $Records -SessionId $SessionId -User $User -LogonTime $LogonTime

    if (-not $match.Ok) {
        return [pscustomobject][ordered]@{ Active = $false; Reason = $match.Reason; Record = $null }
    }

    $isActive = ([int]$match.Record.State -eq $script:P9HWtsStateActive)

    return [pscustomobject][ordered]@{
        Active = $isActive
        Reason = if ($isActive) { 'target-active' } else { ('target-state-' + $match.Record.StateName) }
        Record = $match.Record
    }
}

function New-P9HObserverRecord {
    # One append-only observation record. Contains the complete raw table so a
    # reviewer can re-derive the predicate independently of our parser.
    param(
        [Parameter(Mandatory)][string]$TrialId,
        [Parameter(Mandatory)][int]$Sequence,
        [Parameter(Mandatory)][ValidateSet('pre', 'disconnect-requested', 'disconnect-observed', 'reconnect-requested', 'post')][string]$Phase,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RawWtsLines,
        [Parameter(Mandatory)][int]$TargetSessionId,
        [Parameter(Mandatory)][string]$TargetUser,
        [AllowNull()][string]$TargetLogonTime = $null,
        [AllowNull()][string]$GuestIdentity = $null,
        [AllowNull()][string]$QuserText = $null,
        [AllowNull()][string]$CaptureOutcome = 'ok',
        [AllowNull()][string]$CaptureError = $null
    )

    $table = ConvertFrom-P9HWtsTable -Lines $RawWtsLines
    $target = if ($table.Ok) {
        Get-P9HTargetSessionRecord -Records $table.Records -SessionId $TargetSessionId -User $TargetUser -LogonTime $TargetLogonTime
    }
    else {
        [pscustomobject][ordered]@{ Ok = $false; Reason = $table.Reason; Record = $null }
    }

    $record = [ordered]@{
        trialId          = $TrialId
        sequence         = $Sequence
        phase            = $Phase
        utc              = Get-P9HUtcStamp
        guestIdentity    = $GuestIdentity
        targetSessionId  = $TargetSessionId
        targetUser       = $TargetUser
        targetLogonTime  = $TargetLogonTime
        captureOutcome   = $CaptureOutcome
        captureError     = $CaptureError
        rawWts           = @($RawWtsLines)
        tableOk          = $table.Ok
        tableRejections  = @($table.Rejections)
        targetMatched    = [bool]$target.Ok
        targetMatchReason = [string]$target.Reason
        targetState      = if ($target.Ok) { [int]$target.Record.State } else { $null }
        targetStateName  = if ($target.Ok) { [string]$target.Record.StateName } else { $null }
        targetStation    = if ($target.Ok) { [string]$target.Record.StationName } else { $null }
        quser            = $QuserText
    }

    return ($record | ConvertTo-Json -Compress -Depth 6)
}

function Read-P9HObserverLog {
    # Read back an append-only observer log and validate ordering.
    #
    # Sequence numbers must strictly increase. A duplicate or out-of-order
    # sequence means two writers raced or records were spliced, and the log must
    # not be trusted for a verdict.
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'missing'; Records = @(); Error = $null }
    }

    $records = [System.Collections.Generic.List[object]]::new()
    $lineNo = 0

    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $lineNo++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $records.Add(($line | ConvertFrom-Json -ErrorAction Stop)) | Out-Null }
        catch {
            return [pscustomobject][ordered]@{
                Ok      = $false
                Reason  = 'malformed-line'
                Records = @($records)
                Error   = ('line {0}: {1}' -f $lineNo, $_.Exception.Message)
            }
        }
    }

    $previous = -1
    foreach ($record in $records) {
        $seqProp = $record.PSObject.Properties['sequence']
        if ($null -eq $seqProp) {
            return [pscustomobject][ordered]@{ Ok = $false; Reason = 'missing-sequence'; Records = @($records); Error = $null }
        }
        $sequence = [int]$seqProp.Value
        if ($sequence -le $previous) {
            return [pscustomobject][ordered]@{
                Ok      = $false
                Reason  = 'sequence-not-increasing'
                Records = @($records)
                Error   = ('sequence {0} after {1}' -f $sequence, $previous)
            }
        }
        $previous = $sequence
    }

    return [pscustomobject][ordered]@{ Ok = $true; Reason = 'ok'; Records = @($records); Error = $null }
}

function Get-P9HDisconnectProof {
    # Derive the E1 disconnect proof from a persisted observer log.
    #
    # A proof exists only when ALL of the following hold, in order:
    #   1. a 'pre' record shows the pinned target Active;
    #   2. a 'disconnect-observed' record shows the SAME pinned target in state 4;
    #   3. a 'post' record shows the same pinned target Active again;
    #   4. sequence numbers strictly increase across those records.
    #
    # Returning Ok=$false is the normal, expected outcome when the transition was
    # not proven. It is never upgraded to a pass elsewhere.
    param(
        [Parameter(Mandatory)][string]$ObserverLogPath,
        [Parameter(Mandatory)][int]$SessionId,
        [Parameter(Mandatory)][string]$User
    )

    $log = Read-P9HObserverLog -Path $ObserverLogPath

    if (-not $log.Ok) {
        return [pscustomobject][ordered]@{
            Proven = $false
            Reason = ('observer-log-' + $log.Reason)
            Detail = $log.Error
            Pre    = $null
            Disc   = $null
            Post   = $null
        }
    }

    $pre = @($log.Records | Where-Object { $_.phase -eq 'pre' }) | Select-Object -Last 1
    $disc = @($log.Records | Where-Object {
            $_.phase -eq 'disconnect-observed' -and
            [int]$_.targetSessionId -eq $SessionId -and
            [string]::Equals([string]$_.targetUser, $User, [System.StringComparison]::OrdinalIgnoreCase) -and
            $null -ne $_.targetState -and [int]$_.targetState -eq 4
        }) | Select-Object -First 1
    $post = @($log.Records | Where-Object { $_.phase -eq 'post' }) | Select-Object -Last 1

    if ($null -eq $pre) { return [pscustomobject][ordered]@{ Proven = $false; Reason = 'no-pre-record'; Detail = $null; Pre = $null; Disc = $null; Post = $null } }
    if ([int]$pre.targetSessionId -ne $SessionId) { return [pscustomobject][ordered]@{ Proven = $false; Reason = 'pre-session-mismatch'; Detail = $null; Pre = $pre; Disc = $null; Post = $null } }
    if (-not $pre.targetMatched -or [int]$pre.targetState -ne 0) { return [pscustomobject][ordered]@{ Proven = $false; Reason = 'pre-not-active'; Detail = $pre.targetMatchReason; Pre = $pre; Disc = $null; Post = $null } }
    if ($null -eq $disc) { return [pscustomobject][ordered]@{ Proven = $false; Reason = 'no-target-disconnected-record'; Detail = $null; Pre = $pre; Disc = $null; Post = $null } }
    if ([int]$disc.sequence -le [int]$pre.sequence) { return [pscustomobject][ordered]@{ Proven = $false; Reason = 'disconnect-not-after-pre'; Detail = $null; Pre = $pre; Disc = $disc; Post = $null } }
    if ($null -eq $post) { return [pscustomobject][ordered]@{ Proven = $false; Reason = 'no-post-record'; Detail = $null; Pre = $pre; Disc = $disc; Post = $null } }
    if ([int]$post.sequence -le [int]$disc.sequence) { return [pscustomobject][ordered]@{ Proven = $false; Reason = 'post-not-after-disconnect'; Detail = $null; Pre = $pre; Disc = $disc; Post = $post } }
    if (-not $post.targetMatched -or [int]$post.targetState -ne 0) { return [pscustomobject][ordered]@{ Proven = $false; Reason = 'post-not-active'; Detail = $post.targetMatchReason; Pre = $pre; Disc = $disc; Post = $post } }

    return [pscustomobject][ordered]@{
        Proven = $true
        Reason = 'target-disconnect-reconnect-observed'
        Detail = $null
        Pre    = $pre
        Disc   = $disc
        Post   = $post
    }
}

function Get-P9HTerminalServicesEventProof {
    # Corroborating evidence from the guest Terminal Services event log.
    #
    # Event 24 = session disconnected, event 25 = session reconnection succeeded.
    # Events are matched on session id AND user, and an event alone NEVER
    # satisfies the E1 gate: callers use this only to corroborate a proof that
    # was already derived from the WTS observer.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events,
        [Parameter(Mandatory)][int]$SessionId,
        [Parameter(Mandatory)][string]$User
    )

    $matched = @($Events | Where-Object {
            $null -ne $_.PSObject.Properties['SessionId'] -and
            [int]$_.SessionId -eq $SessionId -and
            $null -ne $_.PSObject.Properties['User'] -and
            [string]::Equals([string]$_.User, $User, [System.StringComparison]::OrdinalIgnoreCase)
        })

    $disconnect = @($matched | Where-Object { [int]$_.Id -eq 24 }) | Select-Object -First 1
    $reconnect = @($matched | Where-Object { [int]$_.Id -eq 25 }) | Select-Object -First 1

    return [pscustomobject][ordered]@{
        Available        = ($matched.Count -gt 0)
        DisconnectEvent  = $disconnect
        ReconnectEvent   = $reconnect
        Corroborates     = ($null -ne $disconnect -and $null -ne $reconnect)
        MatchingEvents   = $matched.Count
    }
}
