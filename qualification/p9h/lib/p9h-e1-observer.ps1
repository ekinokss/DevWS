# DevWS P9-H replay instrumentation - E1 WTS session observer.
#
# Closes P9-G defect E1-4: session 0 'Services' state=4 must never be read as
# proof that the target RDP session disconnected.
#
# Stage 2.1 corrections (independent review):
#   * The reconnect gate was CIRCULAR: it used a proof that required the post
#     reconnect record, which cannot exist before reconnect is authorized. The
#     proof is now split into a pre-reconnect authorization proof and a final
#     transition proof (see p9h-e1-state.ps1).
#   * Session identity is now enforced end to end. The raw WTS line carries an
#     optional per-record logon time field, the observer record persists it with
#     an explicit source, and matching consumes the same pinned identity. When a
#     logon time is REQUIRED, a missing or unverifiable value FAILS CLOSED
#     instead of silently degrading to (sessionId, user).
#
# The observer is pure with respect to the host: it consumes a WTS session table
# supplied by a provider function. Importing or calling it never contacts a VM.

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
# WTSListen: a connection listener that accepts sessions but has no logged-on
# user, so it has no WTSINFO identity to return. Stage 3B7B-C1.
$script:P9HWtsStateListen = 6

# Identity strength. 'full' requires a verified logon time; 'degraded' is
# usable ONLY for non-authoritative observations and can never satisfy a PASS.
$script:P9HIdentityStrengthFull = 'full'
$script:P9HIdentityStrengthDegraded = 'degraded'

function Test-P9HLogonEqual {
    # Compare two logon-time values for authoritative identity equality.
    #
    # Both arguments may be a string (as supplied by the provider) or a DateTime
    # (as reconstructed by ConvertFrom-Json, which auto-converts ISO-8601 text in
    # PowerShell 7). Comparing raw strings across that boundary produces a false
    # mismatch, so both sides are normalized to UTC ISO-8601 before comparison.
    #
    # A value that cannot be normalized compares as NOT equal: identity matching
    # must fail closed.
    param([AllowNull()]$Left, [AllowNull()]$Right)

    $norm = {
        param($v)
        if ($null -eq $v) { return $null }
        if ($v -is [datetime]) { return $v.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
        if ($v -is [datetimeoffset]) { return $v.UtcDateTime.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture) }
        $text = [string]$v
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
            return $parsed.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        return $null
    }

    $l = & $norm $Left
    $r = & $norm $Right
    if ($null -eq $l -or $null -eq $r) { return $false }
    return [string]::Equals($l, $r, [System.StringComparison]::Ordinal)
}

function ConvertFrom-P9HLogonTimeField {
    # Parse the optional per-record logon field from a raw WTS line.
    #
    # Provider line format (authoritative form):
    #   id|station|state=N|user=<account>|logon=<ISO-8601 UTC>
    # Older/simpler providers may omit the trailing '|logon=' segment. That is
    # reported explicitly as absent, never guessed, so a caller can decide
    # whether the identity is strong enough for its purpose.
    param([AllowNull()][AllowEmptyString()][string]$Segment)

    if ([string]::IsNullOrWhiteSpace($Segment)) {
        return [pscustomobject][ordered]@{ Present = $false; Ok = $false; Value = $null; Reason = 'absent'; Raw = $Segment }
    }

    $text = [string]$Segment
    if (-not $text.StartsWith('logon=', [System.StringComparison]::Ordinal)) {
        return [pscustomobject][ordered]@{ Present = $true; Ok = $false; Value = $null; Reason = 'malformed-prefix'; Raw = $Segment }
    }

    $value = $text.Substring(6).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return [pscustomobject][ordered]@{ Present = $true; Ok = $false; Value = $null; Reason = 'empty-value'; Raw = $Segment }
    }

    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
    if (-not [datetime]::TryParse($value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return [pscustomobject][ordered]@{ Present = $true; Ok = $false; Value = $null; Reason = 'unparseable'; Raw = $Segment }
    }

    if ($parsed.Kind -ne [System.DateTimeKind]::Utc) {
        return [pscustomobject][ordered]@{ Present = $true; Ok = $false; Value = $null; Reason = 'not-utc'; Raw = $Segment }
    }

    return [pscustomobject][ordered]@{
        Present = $true
        Ok      = $true
        Value   = $parsed.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        Reason  = 'ok'
        Raw     = $Segment
    }
}

function ConvertFrom-P9HWtsLine {
    # Parse one provider line into a normalized session record.
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

    # The provider emits 'user=<account>'. Strip the literal key so the record
    # carries the ACCOUNT, not the rendered pair.
    $userText = [string]$parts[3]
    if ($userText.StartsWith('user=', [System.StringComparison]::Ordinal)) {
        $userText = $userText.Substring(5)
    }
    $userText = $userText.Trim()

    # Optional trailing 'logon=' segment (index 4..n, joined back in case an
    # ISO timestamp ever contains a pipe - it does not, but joining is safe).
    $logonSegment = if ($parts.Count -gt 4) { ($parts[4..($parts.Count - 1)]) -join '|' } else { $null }
    $logon = ConvertFrom-P9HLogonTimeField -Segment $logonSegment

    return [pscustomobject][ordered]@{
        Ok      = $true
        Reason  = 'ok'
        Record  = [pscustomobject][ordered]@{
            SessionId     = $id
            StationName   = [string]$parts[1]
            State         = $state
            StateName     = if ($script:P9HWtsStateName.ContainsKey($state)) { $script:P9HWtsStateName[$state] } else { "Unknown($state)" }
            User          = $userText
            LogonTime     = if ($logon.Ok) { $logon.Value } else { $null }
            LogonSource   = if ($logon.Ok) { 'wts-line' } elseif ($logon.Present) { ('wts-line-' + $logon.Reason) } else { 'absent' }
            LogonRaw      = $logon.Raw
        }
    }
}

function ConvertFrom-P9HWtsTable {
    # Parse a whole WTS table. Any malformed line makes the capture
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
    # Identity is (SessionId, User, LogonTime). -RequireLogonTime makes a missing
    # or unverifiable logon time a HARD FAILURE ('logon-unavailable') rather than
    # silently degrading the identity to (sessionId, user). Authoritative callers
    # (reconnect authorization, final verdict) always require it.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][int]$SessionId,
        [Parameter(Mandatory)][string]$User,
        [AllowNull()][string]$LogonTime = $null,
        [switch]$RequireLogonTime
    )

    if ($RequireLogonTime -and [string]::IsNullOrWhiteSpace($LogonTime)) {
        return [pscustomobject][ordered]@{
            Ok     = $false
            Reason = 'pinned-logon-missing'
            Record = $null
            Candidates = 0
        }
    }

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
                return (Test-P9HLogonEqual -Left $candidate.Value -Right $LogonTime)
            })

        if ($byLogon.Count -eq 0) {
            # Distinguish 'the provider gave us no logon at all' (a capability
            # gap that must fail closed) from 'it gave a different logon' (a real
            # identity mismatch).
            $observed = @($byIdAndUser | ForEach-Object {
                    $p = $_.PSObject.Properties['LogonTime']
                    if ($null -ne $p -and -not [string]::IsNullOrWhiteSpace([string]$p.Value)) { [string]$p.Value } else { $null }
                })
            $anyObserved = @($observed | Where-Object { $null -ne $_ }).Count -gt 0

            return [pscustomobject][ordered]@{
                Ok             = $false
                Reason         = if ($anyObserved) { 'logon-mismatch' } else { 'logon-unavailable' }
                Record         = $null
                Candidates     = $byIdAndUser.Count
                ExpectedLogon  = $LogonTime
                ObservedLogons = $observed
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
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][int]$SessionId,
        [Parameter(Mandatory)][string]$User,
        [AllowNull()][string]$LogonTime = $null,
        [switch]$RequireLogonTime
    )

    $matchArgs = @{ Records = $Records; SessionId = $SessionId; User = $User; LogonTime = $LogonTime }
    if ($RequireLogonTime) { $matchArgs['RequireLogonTime'] = $true }

    $match = Get-P9HTargetSessionRecord @matchArgs

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
        [AllowNull()][string]$LogonTime = $null,
        [switch]$RequireLogonTime
    )

    $matchArgs = @{ Records = $Records; SessionId = $SessionId; User = $User; LogonTime = $LogonTime }
    if ($RequireLogonTime) { $matchArgs['RequireLogonTime'] = $true }

    $match = Get-P9HTargetSessionRecord @matchArgs

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
    # One append-only observation record.
    #
    # Schema p9h.wts-observation.v2 carries the pinned identity AND the observed
    # per-record logon time with its provenance, so every downstream consumer
    # (authorization, readback, final verdict) evaluates the SAME identity
    # without re-deriving it from a different source.
    #
    # Stage 3A.2 adds the CAPTURE AUTHORITY fields. A syntactically perfect set
    # of lines is not evidence if the capture pipeline rejected the table:
    #   captureAuthoritative  - may this observation be authoritative evidence?
    #   captureAuthorityReason - why not, when it may not
    #   captureRejection      - the resolver/capture rejection, preserved
    #   captureWin32Errors    - preserved native diagnostics
    # `captureOutcome` stays the raw diagnostic outcome ('ok' / 'provider-error'),
    # so a rejected-but-successful read is never rewritten into an error, and an
    # error is never rewritten into 'ok'.
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
        [AllowNull()][string]$CaptureError = $null,
        [AllowNull()][string]$Corroboration = $null,
        # Capture authority (Stage 3A.2).
        #
        # Stage 3B0 correction: this was `[bool]$CaptureAuthoritative = $true`,
        # so a record that declared captureOutcome='provider-error' still
        # defaulted to authoritative=True and could satisfy Proof A/B. The value
        # is now NULLABLE:
        #   * $null  (omitted) -> DERIVED from CaptureOutcome;
        #   * $true / $false   -> the caller's assertion, which is then ANDed with
        #     the outcome so an explicit true can never override a failed capture.
        [AllowNull()][object]$CaptureAuthoritative = $null,
        [AllowNull()][string]$CaptureAuthorityReason = $null,
        [AllowNull()][string]$CaptureRejection = $null,
        [AllowNull()][AllowEmptyCollection()][int[]]$CaptureWin32Errors = $null,
        # Stage 3B7B-C1 listener inventory (optional, bounded extension).
        #
        # A complete ENUMERATION may legitimately contain WTSListen entries that
        # have no WTSINFO identity. Recording them separates two claims that must
        # never be conflated:
        #   * enumeratedCount      - how many sessions the enumeration reported;
        #   * identityCoveredCount - how many of those produced a WTSINFO identity.
        # The difference is exactly the listeners, and it is disclosed here rather
        # than hidden. These fields are METADATA ONLY: they are not consulted by
        # the authority predicate below, so no acceptance rule is weakened.
        [AllowNull()][object]$ListenerCount = $null,
        [AllowNull()][object]$EnumeratedCount = $null,
        [AllowNull()][object]$IdentityCoveredCount = $null,
        [AllowNull()][AllowEmptyCollection()][object[]]$ListenerDiagnostics = $null
    )

    $table = ConvertFrom-P9HWtsTable -Lines $RawWtsLines
    $matchArgs = @{ Records = $table.Records; SessionId = $TargetSessionId; User = $TargetUser; LogonTime = $TargetLogonTime }
    if (-not [string]::IsNullOrWhiteSpace($TargetLogonTime)) { $matchArgs['RequireLogonTime'] = $true }

    $target = if ($table.Ok) {
        Get-P9HTargetSessionRecord @matchArgs
    }
    else {
        [pscustomobject][ordered]@{ Ok = $false; Reason = $table.Reason; Record = $null }
    }

    # An observation may only be authoritative when the capture itself succeeded
    # AND the table parsed cleanly.
    #
    # Stage 3B0 correction: the caller's assertion is ANDed with the observed
    # outcome rather than trusted on its own, so an omitted flag can never
    # silently default to authoritative and an explicit `$true` can never
    # override a failed capture. A provider error is never authoritative.
    #
    # Deliberately EXCLUDES target matching: "was this capture accepted?" and
    # "does this describe the pinned target?" are separate questions, and the
    # target checks downstream already fail closed with precise reasons
    # (pre-not-active, logon-unavailable, user-mismatch, ...).
    $captureSucceeded = ([string]::IsNullOrWhiteSpace($CaptureOutcome) -or $CaptureOutcome -eq 'ok')

    $assertedAuthority = if ($null -eq $CaptureAuthoritative) {
        # Omitted: derive from the observed outcome. This is the conservative
        # reading and the fix for the omission defect.
        $captureSucceeded
    }
    else {
        [bool]$CaptureAuthoritative
    }

    $authoritative = ($assertedAuthority -and $captureSucceeded -and $table.Ok)

    $authorityReason = if ($authoritative) { $null }
    elseif (-not $captureSucceeded) {
        if ([string]::IsNullOrWhiteSpace($CaptureAuthorityReason)) { 'capture-outcome-' + [string]$CaptureOutcome } else { $CaptureAuthorityReason }
    }
    elseif (-not $assertedAuthority) {
        if ([string]::IsNullOrWhiteSpace($CaptureAuthorityReason)) { 'capture-not-authoritative' } else { $CaptureAuthorityReason }
    }
    else { 'table-not-ok:' + [string]$table.Reason }

    $record = [ordered]@{
        schema           = 'p9h.wts-observation.v2'
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
        captureAuthoritative = $authoritative
        captureAuthorityReason = $authorityReason
        captureRejection = $CaptureRejection
        captureWin32Errors = @($CaptureWin32Errors)
        rawWts           = @($RawWtsLines)
        tableOk          = $table.Ok
        tableRejections  = @($table.Rejections)
        targetMatched    = [bool]$target.Ok
        targetMatchReason = [string]$target.Reason
        targetState      = if ($target.Ok) { [int]$target.Record.State } else { $null }
        targetStateName  = if ($target.Ok) { [string]$target.Record.StateName } else { $null }
        targetStation    = if ($target.Ok) { [string]$target.Record.StationName } else { $null }
        targetObservedLogon = if ($target.Ok) { $target.Record.LogonTime } else { $null }
        targetObservedLogonSource = if ($target.Ok) { $target.Record.LogonSource } else { $null }
        identityStrength = if ($target.Ok -and -not [string]::IsNullOrWhiteSpace([string]$target.Record.LogonTime)) { 'full' } else { 'degraded' }
        quser            = $QuserText
        corroboration    = $Corroboration
    }

    # Stage 3B7B-C1: record the listener inventory when the caller supplied it.
    # Bounded extension - the fields are additive, carry enumeration provenance,
    # and do not participate in the authority predicate above.
    if ($null -ne $ListenerCount -or $null -ne $EnumeratedCount -or $null -ne $IdentityCoveredCount) {
        $record['listenerCount'] = if ($null -ne $ListenerCount) { [int]$ListenerCount } else { $null }
        $record['enumeratedCount'] = if ($null -ne $EnumeratedCount) { [int]$EnumeratedCount } else { $null }
        $record['identityCoveredCount'] = if ($null -ne $IdentityCoveredCount) { [int]$IdentityCoveredCount } else { $null }
        $record['enumeratedCountExceedsIdentity'] = if ($null -ne $EnumeratedCount -and $null -ne $IdentityCoveredCount) {
            ([int]$EnumeratedCount -gt [int]$IdentityCoveredCount)
        }
        else { $null }
    }
    if ($null -ne $ListenerDiagnostics) {
        $record['listenerDiagnostics'] = @($ListenerDiagnostics | ForEach-Object {
                [ordered]@{
                    sessionId   = [int]$_.SessionId
                    stationName = [string]$_.StationName
                    state       = [int]$_.State
                    stateName   = [string]$_.StateName
                    queryReason = [string]$_.QueryReason
                    win32Error  = $_.Win32Error
                    querySource = [string]$_.QuerySource
                }
            })
        $record['listenerMetadataSource'] = 'WTSEnumerateSessionsW (state=6 WTSListen); not WTSINFO'
    }

    return ($record | ConvertTo-Json -Compress -Depth 6)
}

function Read-P9HObserverLog {
    # Read back an append-only observer log and validate ordering + schema.
    #
    # A duplicate or out-of-order sequence means two writers raced or records were
    # spliced, and the log must not be trusted for a verdict.
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

function Select-P9HRecordsForTrial {
    # Reject any record that does not belong to the pinned trial.
    #
    # This closes cross-trial substitution: a log containing records from two
    # trials must never satisfy a single-trial proof.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][string]$TrialId
    )

    $matching = @($Records | Where-Object {
            $p = $_.PSObject.Properties['trialId']
            return ($null -ne $p -and [string]::Equals([string]$p.Value, $TrialId, [System.StringComparison]::Ordinal))
        })

    $foreign = @($Records | Where-Object {
            $p = $_.PSObject.Properties['trialId']
            return ($null -eq $p -or -not [string]::Equals([string]$p.Value, $TrialId, [System.StringComparison]::Ordinal))
        })

    return [pscustomobject][ordered]@{
        Ok       = ($foreign.Count -eq 0)
        Reason   = if ($foreign.Count -eq 0) { 'ok' } else { 'foreign-trial-records' }
        Records  = $matching
        Foreign  = $foreign.Count
    }
}

function Get-P9HReconnectAuthorizationProof {
    # PROOF A - required BEFORE the reconnect may be issued.
    #
    # Establishes only what can exist at that moment:
    #   1. every record belongs to the pinned trial;
    #   2. the pinned target was initially Active;
    #   3. a LATER record shows the SAME pinned target in WTS state 4;
    #   4. the log read back and parsed cleanly with increasing sequence;
    #   5. identity (session id, user, logon time) is consistent across both;
    #   6. a verified logon time is REQUIRED (fails closed when unavailable).
    #
    # It deliberately does NOT require a post-reconnect record: requiring one
    # here is what made the Stage 2 gate circular and unimplementable.
    param(
        [Parameter(Mandatory)][string]$ObserverLogPath,
        [Parameter(Mandatory)][string]$TrialId,
        [Parameter(Mandatory)][int]$SessionId,
        [Parameter(Mandatory)][string]$User,
        [AllowNull()][string]$LogonTime = $null
    )

    if ([string]::IsNullOrWhiteSpace($LogonTime)) {
        return [pscustomobject][ordered]@{
            Proven = $false; Reason = 'pinned-logon-missing'
            Detail = 'authoritative reconnect authorization requires a verified logon time'
            Pre = $null; Disc = $null
        }
    }

    $log = Read-P9HObserverLog -Path $ObserverLogPath
    if (-not $log.Ok) {
        return [pscustomobject][ordered]@{ Proven = $false; Reason = ('observer-log-' + $log.Reason); Detail = $log.Error; Pre = $null; Disc = $null }
    }

    $scoped = Select-P9HRecordsForTrial -Records $log.Records -TrialId $TrialId
    if (-not $scoped.Ok) {
        return [pscustomobject][ordered]@{ Proven = $false; Reason = $scoped.Reason; Detail = $null; Pre = $null; Disc = $null }
    }

    $records = $scoped.Records
    $pre = @($records | Where-Object { $_.phase -eq 'pre' }) | Select-Object -Last 1
    if ($null -eq $pre) {
        return [pscustomobject][ordered]@{ Proven = $false; Reason = 'no-pre-record'; Detail = $null; Pre = $null; Disc = $null }
    }

    # Stage 3A.2: an observation whose CAPTURE was not authoritative can never
    # be evidence of a transition, however clean its parsed target line looks.
    if ($null -ne $pre.PSObject.Properties['captureAuthoritative'] -and -not [bool]$pre.captureAuthoritative) {
        return [pscustomobject][ordered]@{
            Proven = $false
            Reason = 'pre-capture-not-authoritative'
            Detail = if ($null -ne $pre.PSObject.Properties['captureAuthorityReason']) { [string]$pre.captureAuthorityReason } else { $null }
            Pre    = $pre; Disc = $null
        }
    }

    if ([int]$pre.targetSessionId -ne $SessionId) {
        return [pscustomobject][ordered]@{ Proven = $false; Reason = 'pre-session-mismatch'; Detail = $null; Pre = $pre; Disc = $null }
    }

    if (-not $pre.targetMatched -or [int]$pre.targetState -ne 0) {
        return [pscustomobject][ordered]@{ Proven = $false; Reason = 'pre-not-active'; Detail = $pre.targetMatchReason; Pre = $pre; Disc = $null }
    }

    if (-not [string]::Equals([string]$pre.targetUser, $User, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject][ordered]@{ Proven = $false; Reason = 'pre-user-mismatch'; Detail = $null; Pre = $pre; Disc = $null }
    }

    if (-not (Test-P9HLogonEqual -Left $pre.targetObservedLogon -Right $LogonTime)) {
        return [pscustomobject][ordered]@{ Proven = $false; Reason = 'pre-logon-mismatch'; Detail = $pre.targetObservedLogon; Pre = $pre; Disc = $null }
    }

    # The disconnected observation must be the same trial, same session, same
    # user, same logon, state 4, and sequenced after the pre record.
    #
    # Stage 3A.2: it must ALSO be authoritative. A record whose capture was
    # rejected (inconsistent table, failed per-session query, ambiguous
    # enumeration, provider error) is a raw diagnostic, not transition evidence.
    # `captureAuthoritative` absent means a pre-3A.2 record, which is accepted
    # only when its raw capture actually succeeded.
    $discCandidates = @($records | Where-Object {
            $isAuthoritative = if ($null -ne $_.PSObject.Properties['captureAuthoritative']) {
                [bool]$_.captureAuthoritative
            }
            else {
                ([string]$_.captureOutcome -eq 'ok') -and [bool]$_.tableOk
            }
            $_.phase -eq 'disconnect-observed' -and
            $isAuthoritative -and
            [int]$_.targetSessionId -eq $SessionId -and
            [string]::Equals([string]$_.targetUser, $User, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-P9HLogonEqual -Left $_.targetObservedLogon -Right $LogonTime) -and
            $null -ne $_.targetState -and [int]$_.targetState -eq 4
        })

    if ($discCandidates.Count -eq 0) {
        # Explain WHY nothing qualified, using the most informative observation.
        # A non-authoritative capture is reported as such rather than as a plain
        # "no target record", so an operator can tell a rejected capture from an
        # observation that simply disagreed.
        $anyDiscPhase = @($records | Where-Object { $_.phase -eq 'disconnect-observed' })
        $reason = 'no-target-disconnected-record'
        if ($anyDiscPhase.Count -gt 0) {
            $last = $anyDiscPhase | Select-Object -Last 1
            $lastAuthoritative = if ($null -ne $last.PSObject.Properties['captureAuthoritative']) {
                [bool]$last.captureAuthoritative
            }
            else { ([string]$last.captureOutcome -eq 'ok') -and [bool]$last.tableOk }

            $searchText = @($anyDiscPhase | ForEach-Object {
                    [string]$_.captureAuthorityReason + ' ' + [string]$_.captureOutcome + ' ' + [string]$_.captureRejection
                }) -join ' '

            if ($searchText -match 'state-changed|state-changed-during-collection') { $reason = 'disconnect-capture-state-changed' }
            elseif ($searchText -match 'ambiguous') { $reason = 'disconnect-capture-ambiguous' }
            elseif ($searchText -match 'target-not-resolved|no-target') { $reason = 'disconnect-capture-target-missing' }
            elseif ($searchText -match 'incomplete|native-query-failed|Win32') { $reason = 'disconnect-capture-incomplete' }
            elseif (-not $lastAuthoritative) { $reason = 'disconnect-capture-not-authoritative' }
            elseif (-not $last.targetMatched) { $reason = 'disconnect-unmatched:' + [string]$last.targetMatchReason }
            elseif ([int]$last.targetState -ne 4) { $reason = 'disconnect-target-active:' + [string]$last.targetStateName }
        }
        return [pscustomobject][ordered]@{ Proven = $false; Reason = $reason; Detail = $null; Pre = $pre; Disc = $null }
    }

    $disc = $discCandidates | Select-Object -First 1
    if ([int]$disc.sequence -le [int]$pre.sequence) {
        return [pscustomobject][ordered]@{ Proven = $false; Reason = 'disconnect-not-after-pre'; Detail = $null; Pre = $pre; Disc = $disc }
    }

    if (-not (Test-P9HStrictUtcStamp -Text $disc.utc)) {
        return [pscustomobject][ordered]@{ Proven = $false; Reason = 'disconnect-timestamp-invalid'; Detail = [string]$disc.utc; Pre = $pre; Disc = $disc }
    }

    return [pscustomobject][ordered]@{
        Proven = $true
        Reason = 'target-disconnect-persisted'
        Detail = $null
        Pre    = $pre
        Disc   = $disc
    }
}

function Get-P9HDisconnectProof {
    # PROOF B - the FINAL E1 transition proof, used only for the verdict.
    #
    # Adds what proof A deliberately omits:
    #   * a post-reconnect Active observation of the same pinned identity;
    #   * monotonic ordering pre -> disconnect -> post;
    #   * same trial, same identity throughout.
    #
    # A reconnect authorization must NOT use this function (that would be
    # circular). It is retained for the verdict path only.
    param(
        [Parameter(Mandatory)][string]$ObserverLogPath,
        [Parameter(Mandatory)][int]$SessionId,
        [Parameter(Mandatory)][string]$User,
        [string]$TrialId = '',
        [AllowNull()][string]$LogonTime = $null
    )

    $auth = Get-P9HReconnectAuthorizationProof -ObserverLogPath $ObserverLogPath -TrialId $TrialId `
        -SessionId $SessionId -User $User -LogonTime $LogonTime

    if (-not $auth.Proven) {
        return [pscustomobject][ordered]@{
            Proven = $false
            Reason = $auth.Reason
            Detail = $auth.Detail
            Pre    = $auth.Pre
            Disc   = $auth.Disc
            Post   = $null
        }
    }

    $log = Read-P9HObserverLog -Path $ObserverLogPath
    $scoped = Select-P9HRecordsForTrial -Records $log.Records -TrialId $TrialId
    $records = $scoped.Records

    $post = @($records | Where-Object { $_.phase -eq 'post' }) | Select-Object -Last 1

    if ($null -eq $post) {
        return [pscustomobject][ordered]@{ Proven = $false; Reason = 'no-post-record'; Detail = $null; Pre = $auth.Pre; Disc = $auth.Disc; Post = $null }
    }

    if ([int]$post.sequence -le [int]$auth.Disc.sequence) {
        return [pscustomobject][ordered]@{ Proven = $false; Reason = 'post-not-after-disconnect'; Detail = $null; Pre = $auth.Pre; Disc = $auth.Disc; Post = $post }
    }

    if (-not $post.targetMatched -or [int]$post.targetState -ne 0) {
        return [pscustomobject][ordered]@{ Proven = $false; Reason = 'post-not-active'; Detail = $post.targetMatchReason; Pre = $auth.Pre; Disc = $auth.Disc; Post = $post }
    }

    # Stage 3A.2: the FINAL transition proof likewise requires the post-reconnect
    # observation itself to be authoritative. A provider error or a rejected
    # capture during the post observation is not evidence the session came back.
    $postAuthoritative = if ($null -ne $post.PSObject.Properties['captureAuthoritative']) {
        [bool]$post.captureAuthoritative
    }
    else { ([string]$post.captureOutcome -eq 'ok') -and [bool]$post.tableOk }

    if (-not $postAuthoritative) {
        return [pscustomobject][ordered]@{
            Proven = $false
            Reason = 'post-capture-not-authoritative'
            Detail = if ($null -ne $post.PSObject.Properties['captureAuthorityReason']) { [string]$post.captureAuthorityReason } else { [string]$post.captureOutcome }
            Pre    = $auth.Pre; Disc = $auth.Disc; Post = $post
        }
    }

    if ([int]$post.targetSessionId -ne $SessionId) {
        return [pscustomobject][ordered]@{ Proven = $false; Reason = 'post-session-mismatch'; Detail = $null; Pre = $auth.Pre; Disc = $auth.Disc; Post = $post }
    }

    if (-not (Test-P9HLogonEqual -Left $post.targetObservedLogon -Right $auth.Pre.targetObservedLogon)) {
        return [pscustomobject][ordered]@{ Proven = $false; Reason = 'post-logon-mismatch'; Detail = $post.targetObservedLogon; Pre = $auth.Pre; Disc = $auth.Disc; Post = $post }
    }

    return [pscustomobject][ordered]@{
        Proven = $true
        Reason = 'target-disconnect-reconnect-observed'
        Detail = $null
        Pre    = $auth.Pre
        Disc   = $auth.Disc
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
