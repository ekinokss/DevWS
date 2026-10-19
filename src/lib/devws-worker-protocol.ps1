# Scheduled-worker one-shot transport (Public Security Phase 2-D).
#
# Replaces the historical Medium-writable JSON request/result file exchange
# with a secure, bounded, authenticated, one-shot named-pipe transport:
#
#   Medium Start      kicks the fixed scheduled task, connects to the worker's
#                     single-instance pipe with a bounded retry, authenticates
#                     the connected server from the pipe handle itself
#                     (retained process handle: High integrity, current user,
#                     caller session, canonical trusted PowerShell image, fixed
#                     scheduled-task action identity, argv-token worker script
#                     binding), transmits one bounded request frame and returns
#                     after observing ACCEPTED.
#   High worker       creates the one-instance pipe, serves exactly ONE
#                     connection, fully validates the request, emits ACCEPTED
#                     before its first side effect, executes, emits FINAL and
#                     disposes.
#   Medium Complete   waits for the correlated FINAL within the remaining
#                     operation budget, classifies the outcome and disposes
#                     every owned resource.
#
# Caller-observable outcomes (never server-internal inference):
#   NotTransmitted       no request bytes could have reached the worker
#   Rejected             explicit correlated pre-execution rejection
#   UncertainNoAck       transmission may have begun; ACCEPTED not observed
#   UncertainAfterAccept ACCEPTED observed; FINAL missing
#   Completed            correlated FINAL observed (success or failure)
#
# Retry policy: only NotTransmitted (and, at a caller site that permits it,
# Rejected) may be retried; UncertainNoAck / UncertainAfterAccept / Completed
# never automatically repeat. There is no durable idempotency ledger and no
# exactly-once claim: the guarantee is NO AUTOMATIC DUPLICATE EXECUTION AFTER
# UNCERTAINTY.
#
# Wire protocol DevWS.Worker.v1 (one UTF-8 JSON object per LF-terminated
# frame, hard 65,536-byte encoded ceiling):
#   request   {version:1, operation, requestId, payload}
#   responses {version:1, type:"accepted"|"final"|"error", operation,
#              requestId, ok?, message?, error?, data?}
#
# Pipe namespace: DevWS.Worker.<operation>.<current-user-SID> - an identifier,
# never a secret. The pipe SDDL admits the current user and SYSTEM only with a
# Medium mandatory label (Low/other-user clients are rejected by the OS); the
# same-user Medium delegation boundary itself belongs to Trusted Elevation
# (Phases 3-4) and is intentionally unchanged.

$script:DevWSWorkerFrameMaxBytes = 65536
$script:DevWSWorkerFrameMaxDepth = 16
$script:DevWSWorkerFixedArgumentPrefix = @("-NoProfile", "-WindowStyle", "Hidden", "-File")

function Get-DevWSWorkerFrameMaxBytes {
    return $script:DevWSWorkerFrameMaxBytes
}

function Get-DevWSWorkerFixedArgumentPrefix {
    return @($script:DevWSWorkerFixedArgumentPrefix)
}

function Get-DevWSWorkerKindTaskName {
    # Fixed Kind -> scheduled-task binding. Caller-supplied task names can
    # never widen this association.
    param(
        [Parameter(Mandatory)]
        [ValidateSet("launch", "capture", "focus", "reset")]
        [string]$Kind
    )

    switch ($Kind) {
        "launch"  { return "DevWorkspace-ElevatedHelper" }
        "capture" { return "DevWorkspace-ElevatedCapture" }
        "focus"   { return "DevWorkspace-ElevatedFocus" }
        "reset"   { return "DevWorkspace-ElevatedReset" }
    }
}

function Get-DevWSWorkerKindScriptName {
    # Fixed Kind -> protected worker script (resolved under the privileged
    # workers root by the Kind expectation).
    param(
        [Parameter(Mandatory)]
        [ValidateSet("launch", "capture", "focus", "reset")]
        [string]$Kind
    )

    switch ($Kind) {
        "launch"  { return "elevated.ps1" }
        "capture" { return "elevated-capture.ps1" }
        "focus"   { return "elevated-focus.ps1" }
        "reset"   { return "elevated-reset.ps1" }
    }
}

function Get-DevWSWorkerOperationPipeName {
    # Operation-scoped identifier in the local pipe namespace: not a secret.
    param(
        [Parameter(Mandatory)]
        [ValidateSet("launch", "capture", "focus", "reset")]
        [string]$Kind
    )

    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return "DevWS.Worker.$Kind.$sid"
}

function Get-DevWSWorkerPipeSddl {
    # Current user + SYSTEM full access; Medium mandatory label so the
    # non-elevated caller can connect. Deliberately no Everyone and no
    # Authenticated Users grant; lower-integrity clients are refused by the
    # mandatory no-write-up policy. Same shape as the elevated broker pipe.
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return "D:(A;;GA;;;$sid)(A;;GA;;;SY)S:(ML;;NW;;;ME)"
}

$script:DevWSWorkerPendingConnections = @{}

function New-DevWSWorkerPipeServer {
    # Worker-side (High) single-instance secure pipe server, reusing the
    # proven elevated-broker creation primitive (raw CreateNamedPipeW with an
    # explicit SDDL wrapped in a NamedPipeServerStream).
    #
    # The accept wait is armed HERE, immediately after instance creation: a
    # caller that connects and disconnects within the gap before the worker
    # reached its wait (caller death right after transmission) must not have
    # its connection discarded.
    param(
        [Parameter(Mandatory)]
        [ValidateSet("launch", "capture", "focus", "reset")]
        [string]$Kind,
        [string]$PipeName = (Get-DevWSWorkerOperationPipeName -Kind $Kind)
    )

    Initialize-DevWSNativeRuntime

    $handle = [System.IntPtr]::Zero
    $win32Error = 0

    if (-not [DevWSBrokerPipeNative]::TryCreateSecurePipe($PipeName, (Get-DevWSWorkerPipeSddl), [ref]$handle, [ref]$win32Error)) {
        $message = [System.ComponentModel.Win32Exception]::new($win32Error).Message
        throw "Could not create the DevWS $Kind worker pipe '$PipeName' (Win32 ${win32Error}: $message)."
    }

    $safeHandle = [Microsoft.Win32.SafeHandles.SafePipeHandle]::new($handle, $true)

    $server = [System.IO.Pipes.NamedPipeServerStream]::new(
        [System.IO.Pipes.PipeDirection]::InOut,
        $false,
        $false,
        $safeHandle)

    $script:DevWSWorkerPendingConnections[$server] = $server.WaitForConnectionAsync()
    return $server
}

# ---------------------------------------------------------------------------
# Frame codec (byte-ceilinged, strict UTF-8, newline-delimited)
# ---------------------------------------------------------------------------

function ConvertTo-DevWSWorkerFrameBytes {
    # Encodes one frame's JSON bytes (without the LF terminator) and enforces
    # the hard byte ceiling.
    param(
        [Parameter(Mandatory)]
        $Object,
        [int]$MaxBytes = (Get-DevWSWorkerFrameMaxBytes)
    )

    $json = ConvertTo-Json -InputObject $Object -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    if ($bytes.Length -gt $MaxBytes) {
        throw "DevWS worker frame exceeds the $MaxBytes-byte protocol ceiling ($($bytes.Length) bytes)."
    }

    return $bytes
}

function Write-DevWSWorkerFrame {
    param(
        [Parameter(Mandatory)] $Stream,
        [Parameter(Mandatory)] $Object
    )

    $bytes = ConvertTo-DevWSWorkerFrameBytes -Object $Object
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.WriteByte(10)
    $Stream.Flush()
}

function Get-DevWSWorkerFrameDepthError {
    # Structural bound: maximum nesting depth over the encoded text, computed
    # before JSON parsing so deeply nested adversarial frames are refused
    # deterministically.
    param(
        [Parameter(Mandatory)][string]$Text,
        [int]$MaxDepth = $script:DevWSWorkerFrameMaxDepth
    )

    $depth = 0
    $inString = $false
    $escaped = $false

    foreach ($character in $Text.ToCharArray()) {
        if ($inString) {
            if ($escaped) { $escaped = $false; continue }
            if ($character -eq '\') { $escaped = $true; continue }
            if ($character -eq '"') { $inString = $false }
            continue
        }

        switch ($character) {
            '"' { $inString = $true }
            '{' { $depth++; if ($depth -gt $MaxDepth) { return "frame nesting exceeds $MaxDepth levels" } }
            '[' { $depth++; if ($depth -gt $MaxDepth) { return "frame nesting exceeds $MaxDepth levels" } }
            '}' { $depth--; if ($depth -lt 0) { return 'frame structure is unbalanced' } }
            ']' { $depth--; if ($depth -lt 0) { return 'frame structure is unbalanced' } }
        }
    }

    if ($inString) { return 'frame structure is unbalanced' }
    if ($depth -ne 0) { return 'frame structure is unbalanced' }

    return $null
}

function Test-DevWSWorkerFrameBytes {
    # Pure frame validation: newline terminator, encoded byte ceiling (LF
    # excluded), strict UTF-8 decoding, bounded nesting and a JSON object root.
    param(
        [AllowNull()][byte[]]$Bytes,
        [int]$MaxBytes = (Get-DevWSWorkerFrameMaxBytes)
    )

    $result = [ordered]@{ Ok = $false; Text = $null; Value = $null; Error = $null }

    if ($null -eq $Bytes -or $Bytes.Length -lt 2) {
        $result.Error = 'frame is not newline-terminated'
        return [pscustomobject]$result
    }

    if ($Bytes[$Bytes.Length - 1] -ne 10) {
        $result.Error = 'frame is not newline-terminated'
        return [pscustomobject]$result
    }

    $payloadLength = $Bytes.Length - 1

    if ($payloadLength -gt $MaxBytes) {
        $result.Error = "frame exceeds the $MaxBytes-byte protocol ceiling"
        return [pscustomobject]$result
    }

    $payload = New-Object byte[] $payloadLength
    [Array]::Copy($Bytes, 0, $payload, 0, $payloadLength)

    # A single trailing CR is tolerated as line-ending hygiene; anything else
    # is content and must decode as strict UTF-8.
    if ($payloadLength -gt 0 -and $payload[$payloadLength - 1] -eq 13) {
        $payloadLength--
        $payload = $payload[0..($payloadLength - 1)]
    }

    if ($payloadLength -le 0) {
        $result.Error = 'empty frame'
        return [pscustomobject]$result
    }

    try {
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($payload)
    }
    catch {
        $result.Error = 'frame is not valid UTF-8'
        return [pscustomobject]$result
    }

    $depthError = Get-DevWSWorkerFrameDepthError -Text $text

    if ($null -ne $depthError) {
        $result.Error = $depthError
        return [pscustomobject]$result
    }

    try {
        $parsed = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    }
    catch {
        $result.Error = 'malformed JSON frame'
        return [pscustomobject]$result
    }

    if ($null -eq $parsed -or $parsed -isnot [System.Management.Automation.PSCustomObject]) {
        $result.Error = 'frame root must be a JSON object'
        return [pscustomobject]$result
    }

    $result.Ok = $true
    $result.Text = $text
    $result.Value = $parsed
    return [pscustomobject]$result
}

function Read-DevWSWorkerFrame {
    # Deadline-driven bounded frame read. Pipe-backed streams are polled with
    # PeekNamedPipe so a stalled or silent peer can never block the reader; a
    # plain in-memory stream (tests) reads until LF/EOF/deadline.
    param(
        [Parameter(Mandatory)] $Stream,
        [int]$TimeoutSeconds = 20,
        [int]$MaxBytes = (Get-DevWSWorkerFrameMaxBytes)
    )

    $result = [ordered]@{ Ok = $false; Bytes = $null; Text = $null; Value = $null; Error = $null; Eof = $false; TimedOut = $false }
    $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))

    $pipeHandle = [IntPtr]::Zero
    $isPipe = $false

    if ($null -ne $Stream.PSObject.Properties["SafePipeHandle"] -and $null -ne $Stream.SafePipeHandle) {
        $isPipe = $true
        $pipeHandle = $Stream.SafePipeHandle.DangerousGetHandle()
        Initialize-DevWSNativeRuntime
    }

    $collected = [System.Collections.Generic.List[byte]]::new()
    $buffer = New-Object byte[] 8192

    while ([datetime]::UtcNow -lt $deadline) {
        if ($isPipe) {
            $bytesRead = [uint32]0
            $available = [uint32]0
            $left = [uint32]0

            if (-not [DevWSWorkerPipeIdentityNative]::PeekNamedPipe($pipeHandle, [IntPtr]::Zero, 0, [ref]$bytesRead, [ref]$available, [ref]$left)) {
                # A broken pipe can still hold buffered bytes: drain them with
                # a direct read before treating the connection as ended, so a
                # caller that transmits its request and dies immediately is
                # still served (its response write failure is the uncertainty
                # marker). Only a read that yields nothing means real EOF.
                $value = -1

                try { $value = $Stream.ReadByte() } catch { $value = -1 }

                if ($value -lt 0) {
                    if ($collected.Count -eq 0) {
                        $result.Eof = $true
                        $result.Error = 'the peer closed the connection before a frame was received'
                        return [pscustomobject]$result
                    }

                    $result.Error = 'the peer closed the connection mid-frame'
                    return [pscustomobject]$result
                }

                $collected.Add([byte]$value)

                if ($value -eq 10) {
                    $bytes = $collected.ToArray()
                    $validation = Test-DevWSWorkerFrameBytes -Bytes $bytes -MaxBytes $MaxBytes
                    $result.Bytes = $bytes
                    $result.Text = $validation.Text
                    $result.Value = $validation.Value
                    $result.Ok = [bool]$validation.Ok
                    $result.Error = $validation.Error
                    return [pscustomobject]$result
                }

                if ($collected.Count -gt $MaxBytes) {
                    $result.Error = "frame exceeds the $MaxBytes-byte protocol ceiling"
                    return [pscustomobject]$result
                }

                continue
            }

            if ($available -eq 0) {
                Start-Sleep -Milliseconds 25
                continue
            }

            # EXACT consumption: one byte at a time, stopping immediately at
            # the LF terminator. Reading a whole chunk would discard the bytes
            # of a following frame when a fast worker writes ACCEPTED and FINAL
            # back to back before the caller's next read (which would surface
            # as a lost FINAL for a completed operation).
            $value = $Stream.ReadByte()

            if ($value -lt 0) {
                if ($collected.Count -eq 0) {
                    $result.Eof = $true
                    $result.Error = 'the peer closed the connection before a frame was received'
                    return [pscustomobject]$result
                }

                $result.Error = 'the peer closed the connection mid-frame'
                return [pscustomobject]$result
            }

            $collected.Add([byte]$value)

            if ($value -eq 10) {
                $bytes = $collected.ToArray()
                $validation = Test-DevWSWorkerFrameBytes -Bytes $bytes -MaxBytes $MaxBytes
                $result.Bytes = $bytes
                $result.Text = $validation.Text
                $result.Value = $validation.Value
                $result.Ok = [bool]$validation.Ok
                $result.Error = $validation.Error
                return [pscustomobject]$result
            }

            if ($collected.Count -gt $MaxBytes) {
                $result.Error = "frame exceeds the $MaxBytes-byte protocol ceiling"
                return [pscustomobject]$result
            }

            continue
        }

        # Plain streams (tests): read up to the LF within the chunk; residual
        # bytes of a following frame would require a buffered reader, so this
        # path is reserved for single-frame fixtures.
        $read = $Stream.Read($buffer, 0, $buffer.Length)

        if ($read -le 0) {
            if ($collected.Count -eq 0) {
                $result.Eof = $true
                $result.Error = 'the peer closed the connection before a frame was received'
                return [pscustomobject]$result
            }

            $result.Error = 'the peer closed the connection mid-frame'
            return [pscustomobject]$result
        }

        for ($index = 0; $index -lt $read; $index++) {
            $collected.Add($buffer[$index])

            if ($buffer[$index] -eq 10) {
                $bytes = $collected.ToArray()
                $validation = Test-DevWSWorkerFrameBytes -Bytes $bytes -MaxBytes $MaxBytes
                $result.Bytes = $bytes
                $result.Text = $validation.Text
                $result.Value = $validation.Value
                $result.Ok = [bool]$validation.Ok
                $result.Error = $validation.Error
                return [pscustomobject]$result
            }

            # LF-excluded encoded ceiling: once the collected bytes exceed the
            # ceiling a complete frame could only be oversized.
            if ($collected.Count -gt $MaxBytes) {
                $result.Error = "frame exceeds the $MaxBytes-byte protocol ceiling"
                return [pscustomobject]$result
            }
        }
    }

    $result.TimedOut = $true
    $result.Error = if ($collected.Count -gt 0) { 'the frame was not completed before the read deadline' } else { 'no frame was received before the read deadline' }
    return [pscustomobject]$result
}

# ---------------------------------------------------------------------------
# One-shot wire contract validation
# ---------------------------------------------------------------------------

function Test-DevWSWorkerRequestId {
    # Canonical lowercase GUID; the scheduled capture fallback keeps its exact
    # existing operation-id domain.
    param([AllowNull()][string]$RequestId)

    if ([string]::IsNullOrEmpty($RequestId)) { return $false }
    return ($RequestId -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
}

function Test-DevWSWorkerRequestFrame {
    # Strict `DevWS.Worker.v1` request validation: exact property set, exact
    # protocol version, exact operation, canonical requestId and the
    # per-operation permitted payload fields.
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][ValidateSet("launch", "capture", "focus", "reset")][string]$Kind
    )

    $result = [ordered]@{ Ok = $false; Error = $null; RequestId = $null; Payload = $null }

    if ($null -eq $Value -or $Value -isnot [System.Management.Automation.PSCustomObject]) {
        $result.Error = 'request frame must be a JSON object'
        return [pscustomobject]$result
    }

    foreach ($property in @($Value.PSObject.Properties)) {
        if (@('version', 'operation', 'requestId', 'payload') -notcontains [string]$property.Name) {
            $result.Error = "unsupported request field '$($property.Name)'"
            return [pscustomobject]$result
        }
    }

    $versionProperty = $Value.PSObject.Properties['version']
    if ($null -eq $versionProperty -or -not (Test-DevWSInteger $versionProperty.Value) -or [int]$versionProperty.Value -ne 1) {
        $result.Error = 'unsupported protocol version (expected 1)'
        return [pscustomobject]$result
    }

    $operationProperty = $Value.PSObject.Properties['operation']
    $operation = if ($null -ne $operationProperty) { [string]$operationProperty.Value } else { '' }
    if ($operation -cne $Kind) {
        $result.Error = "unsupported operation '$operation' for the '$Kind' worker pipe"
        return [pscustomobject]$result
    }

    $requestIdProperty = $Value.PSObject.Properties['requestId']
    $requestId = if ($null -ne $requestIdProperty) { [string]$requestIdProperty.Value } else { '' }
    if (-not (Test-DevWSWorkerRequestId -RequestId $requestId)) {
        $result.Error = 'requestId must be a canonical lowercase GUID'
        return [pscustomobject]$result
    }

    # From here on the requestId parsed and validated: every later rejection
    # carries it so the worker's error frame stays correlated.
    $result.RequestId = $requestId

    $payloadProperty = $Value.PSObject.Properties['payload']
    if ($null -eq $payloadProperty -or $payloadProperty.Value -isnot [System.Management.Automation.PSCustomObject]) {
        $result.Error = 'request payload must be a JSON object'
        return [pscustomobject]$result
    }

    $payload = $payloadProperty.Value
    $permitted = switch ($Kind) {
        'launch'  { @('setId', 'terminalPlacements') }
        'capture' { @('setId') }
        'focus'   { @('setId') }
        'reset'   { @('setId', 'terminalPlacements') }
    }

    foreach ($property in @($payload.PSObject.Properties)) {
        if ($permitted -notcontains [string]$property.Name) {
            $result.Error = "unsupported $Kind payload field '$($property.Name)'"
            return [pscustomobject]$result
        }
    }

    $setIdProperty = $payload.PSObject.Properties['setId']

    if ($null -eq $setIdProperty -or $setIdProperty.Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$setIdProperty.Value) -or
        ([string]$setIdProperty.Value).Length -gt 200) {
        $result.Error = 'payload.setId must be a non-empty string'
        return [pscustomobject]$result
    }

    $placementsProperty = $payload.PSObject.Properties['terminalPlacements']

    if ($Kind -eq 'reset' -and $null -eq $placementsProperty) {
        $result.Error = 'payload.terminalPlacements is required for reset'
        return [pscustomobject]$result
    }

    if ($null -ne $placementsProperty -and $null -ne $placementsProperty.Value -and
        $placementsProperty.Value -isnot [System.Collections.IList] -and $placementsProperty.Value -isnot [object[]]) {
        $result.Error = 'payload.terminalPlacements must be an array'
        return [pscustomobject]$result
    }

    $result.Ok = $true
    $result.RequestId = $requestId
    $result.Payload = $payload
    return [pscustomobject]$result
}

function Test-DevWSWorkerResponseFrame {
    # Strict response validation with complete correlation (operation +
    # requestId) and type-conditional fields.
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][ValidateSet("launch", "capture", "focus", "reset")][string]$ExpectedOperation,
        [Parameter(Mandatory)][string]$ExpectedRequestId,
        [string[]]$AllowedTypes = @('accepted', 'final', 'error')
    )

    $result = [ordered]@{ Ok = $false; Error = $null; Type = $null }

    if ($null -eq $Value -or $Value -isnot [System.Management.Automation.PSCustomObject]) {
        $result.Error = 'response frame must be a JSON object'
        return [pscustomobject]$result
    }

    foreach ($property in @($Value.PSObject.Properties)) {
        if (@('version', 'type', 'operation', 'requestId', 'ok', 'message', 'error', 'data') -notcontains [string]$property.Name) {
            $result.Error = "unsupported response field '$($property.Name)'"
            return [pscustomobject]$result
        }
    }

    $versionProperty = $Value.PSObject.Properties['version']
    if ($null -eq $versionProperty -or -not (Test-DevWSInteger $versionProperty.Value) -or [int]$versionProperty.Value -ne 1) {
        $result.Error = 'unsupported protocol version (expected 1)'
        return [pscustomobject]$result
    }

    $typeProperty = $Value.PSObject.Properties['type']
    $type = if ($null -ne $typeProperty) { [string]$typeProperty.Value } else { '' }

    if ($type -notin $AllowedTypes) {
        $result.Error = "unsupported response type '$type'"
        return [pscustomobject]$result
    }

    $result.Type = $type

    $operationProperty = $Value.PSObject.Properties['operation']
    if ($null -eq $operationProperty -or [string]$operationProperty.Value -cne $ExpectedOperation) {
        $result.Error = "cross-kind response: operation '$([string]$operationProperty.Value)'"
        return [pscustomobject]$result
    }

    $requestIdProperty = $Value.PSObject.Properties['requestId']
    if ($null -eq $requestIdProperty) {
        $result.Error = 'response without requestId'
        return [pscustomobject]$result
    }

    if ([string]$requestIdProperty.Value -cne $ExpectedRequestId) {
        $result.Error = "stale response: requestId '$([string]$requestIdProperty.Value)'"
        return [pscustomobject]$result
    }

    if ($type -eq 'accepted') {
        foreach ($field in @('ok', 'message', 'error', 'data')) {
            if ($null -ne $Value.PSObject.Properties[$field]) {
                $result.Error = "accepted response must not carry '$field'"
                return [pscustomobject]$result
            }
        }
    }

    if ($type -eq 'final') {
        $okProperty = $Value.PSObject.Properties['ok']
        $messageProperty = $Value.PSObject.Properties['message']

        if ($null -eq $okProperty -or $okProperty.Value -isnot [bool]) {
            $result.Error = 'final response requires a boolean ok'
            return [pscustomobject]$result
        }

        if ($null -eq $messageProperty -or $messageProperty.Value -isnot [string]) {
            $result.Error = 'final response requires a string message'
            return [pscustomobject]$result
        }

        if ($null -ne $Value.PSObject.Properties['error']) {
            $result.Error = 'final response must not carry an error field'
            return [pscustomobject]$result
        }
    }

    if ($type -eq 'error') {
        $errorProperty = $Value.PSObject.Properties['error']

        if ($null -eq $errorProperty -or $errorProperty.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$errorProperty.Value)) {
            $result.Error = 'error response requires a non-empty error string'
            return [pscustomobject]$result
        }

        foreach ($field in @('ok', 'message', 'data')) {
            if ($null -ne $Value.PSObject.Properties[$field]) {
                $result.Error = "error response must not carry '$field'"
                return [pscustomobject]$result
            }
        }
    }

    $result.Ok = $true
    return [pscustomobject]$result
}

# ---------------------------------------------------------------------------
# Caller-observable state model
# ---------------------------------------------------------------------------

function Resolve-DevWSWorkerCallerState {
    # Pure classification used by Start/Complete. Order: a correlated FINAL is
    # Completed; an observed ACCEPTED without FINAL is UncertainAfterAccept; an
    # explicit correlated pre-execution rejection is Rejected; any request
    # transmission without an acknowledgment is UncertainNoAck; everything else
    # (including any authentication refusal before the first byte) is
    # NotTransmitted.
    param(
        [bool]$Connected = $false,
        [bool]$BytesSent = $false,
        [bool]$AcceptedObserved = $false,
        [bool]$FinalObserved = $false,
        [bool]$CorrelatedRejection = $false
    )

    if ($FinalObserved) { return 'Completed' }
    if ($AcceptedObserved) { return 'UncertainAfterAccept' }
    if ($CorrelatedRejection) { return 'Rejected' }
    if ($BytesSent) { return 'UncertainNoAck' }
    return 'NotTransmitted'
}

function New-DevWSWorkerStateException {
    # State-tagged exception: callers classify through Get-DevWSWorkerErrorState
    # instead of message sniffing.
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Message
    )

    $exception = [System.Exception]::new($Message)
    $exception.Data['DevWSWorkerState'] = $State
    return $exception
}

function Get-DevWSWorkerErrorState {
    # Returns the DevWS worker state carried by a thrown error, or $null.
    param([AllowNull()]$ErrorRecord)

    if ($null -eq $ErrorRecord) { return $null }

    $exception = $ErrorRecord.Exception

    while ($null -ne $exception) {
        if ($null -ne $exception.Data -and $exception.Data.Contains('DevWSWorkerState')) {
            return [string]$exception.Data['DevWSWorkerState']
        }

        $exception = $exception.InnerException
    }

    return $null
}

function Get-DevWSWorkerRemainingSeconds {
    # Remaining operation budget from an absolute UTC deadline; never negative.
    param([Parameter(Mandatory)][datetime]$Deadline)

    $remaining = ($Deadline.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds

    if ($remaining -le 0) { return 0 }

    return [int][Math]::Ceiling($remaining)
}

# ---------------------------------------------------------------------------
# Scheduled task declaration + authenticated server identity
# ---------------------------------------------------------------------------

function ConvertFrom-DevWSScheduledTaskDeclarationXml {
    # Pure parser for one scheduled-task definition XML: the fixed action
    # executable and its token-aware argument list.
    param(
        [Parameter(Mandatory)][string]$Xml
    )

    try {
        $document = [System.Xml.XmlDocument]::new()
        $document.LoadXml($Xml)
    }
    catch {
        throw "The scheduled task declaration is not valid XML: $($_.Exception.Message)"
    }

    $namespaces = [System.Xml.XmlNamespaceManager]::new($document.NameTable)
    [void]$namespaces.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')

    $commandNode = $document.SelectSingleNode('//t:Actions/t:Exec/t:Command', $namespaces)

    if ($null -eq $commandNode -or [string]::IsNullOrWhiteSpace($commandNode.InnerText)) {
        throw 'The scheduled task declaration has no Exec command.'
    }

    $argumentsNode = $document.SelectSingleNode('//t:Actions/t:Exec/t:Arguments', $namespaces)
    $arguments = if ($null -ne $argumentsNode) { [string]$argumentsNode.InnerText } else { '' }

    Initialize-DevWSNativeRuntime
    $argv = if ([string]::IsNullOrWhiteSpace($arguments)) { $null } else { [DevWSWorkerPipeIdentityNative]::SplitCommandLine($arguments) }

    return [pscustomobject]@{
        Exec      = [string]$commandNode.InnerText
        Arguments = $arguments
        Argv      = $argv
    }
}

function Get-DevWSScheduledTaskDeclaration {
    # Read-only scheduled-task definition read through the Task Scheduler COM
    # service (the task XML is administrator-controlled; a Medium process can
    # read but not modify it).
    param(
        [Parameter(Mandatory)][string]$TaskName
    )

    $service = $null
    $folder = $null
    $task = $null

    try {
        $service = New-Object -ComObject "Schedule.Service"
        $service.Connect()
        $folder = $service.GetFolder("\")
        $task = $folder.GetTask($TaskName)

        if ($null -eq $task) {
            throw "Scheduled task '$TaskName' was not found in the root Task Scheduler folder."
        }

        return ConvertFrom-DevWSScheduledTaskDeclarationXml -Xml ([string]$task.Xml)
    }
    catch {
        if ($_.Exception -is [System.IO.FileNotFoundException] -or $_.Exception.HResult -eq -2147024894) {
            throw "Scheduled task '$TaskName' was not found in the root Task Scheduler folder; run install.ps1 to register the DevWS scheduled tasks."
        }

        throw
    }
    finally {
        if ($null -ne $task)    { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($task) }
        if ($null -ne $folder)  { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($folder) }
        if ($null -ne $service) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($service) }
    }
}

function Test-DevWSWorkerPathIdentityEqual {
    # Complete canonical path identity: full-path normalization plus
    # case-insensitive comparison. Never substring matching.
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }

    try {
        $leftCanonical = ([System.IO.Path]::GetFullPath($Left.Trim())).TrimEnd('\')
        $rightCanonical = ([System.IO.Path]::GetFullPath($Right.Trim())).TrimEnd('\')
    }
    catch {
        return $false
    }

    return ($leftCanonical -ieq $rightCanonical)
}

function Get-DevWSWorkerKindExpectedScriptPath {
    # The protected worker script bound to the Kind under the privileged
    # workers root.
    param(
        [Parameter(Mandatory)]
        [ValidateSet("launch", "capture", "focus", "reset")]
        [string]$Kind
    )

    $workersRoot = Join-Path (Get-DevWSPrivilegedInstallRoot) "workers"
    return (Join-Path $workersRoot (Get-DevWSWorkerKindScriptName -Kind $Kind))
}

function Get-DevWSWorkerKindExpectation {
    # The authenticated-server expectation for one Kind: fixed task name, the
    # task-declared executable, the task-declared token-aware argument list and
    # the protected worker script bound to the Kind. Fails closed when the
    # installed task declaration does not match the fixed shape.
    param(
        [Parameter(Mandatory)]
        [ValidateSet("launch", "capture", "focus", "reset")]
        [string]$Kind
    )

    $taskName = Get-DevWSWorkerKindTaskName -Kind $Kind
    $scriptPath = Get-DevWSWorkerKindExpectedScriptPath -Kind $Kind
    $declaration = Get-DevWSScheduledTaskDeclaration -TaskName $taskName
    $prefix = Get-DevWSWorkerFixedArgumentPrefix

    if ($null -eq $declaration.Argv -or $declaration.Argv.Count -ne ($prefix.Count + 1)) {
        throw "The '$taskName' scheduled task declaration does not match the fixed worker action shape (expected '$(($prefix -join ' ')) <script>')."
    }

    for ($index = 0; $index -lt $prefix.Count; $index++) {
        if ($declaration.Argv[$index] -cne $prefix[$index]) {
            throw "The '$taskName' scheduled task declaration has an unexpected argument '$($declaration.Argv[$index])'."
        }
    }

    if (-not (Test-DevWSWorkerPathIdentityEqual -Left $declaration.Argv[$prefix.Count] -Right $scriptPath)) {
        throw "The '$taskName' scheduled task declaration does not point at the expected protected worker script."
    }

    return [pscustomobject]@{
        TaskName = $taskName
        Kind     = $Kind
        Exec     = $declaration.Exec
        Argv     = @($declaration.Argv)
        Script   = $scriptPath
    }
}

function Get-DevWSCurrentTokenSessionId {
    # The caller's own token session id (compared against the worker token).
    Initialize-DevWSNativeRuntime

    $token = [IntPtr]::Zero

    if (-not [DevWSPrivilegeNative]::OpenProcessToken([DevWSPrivilegeNative]::GetCurrentProcess(), [uint32]0x0008, [ref]$token)) {
        throw "Could not open the current process token (win32=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }

    try {
        $needed = [uint32]0
        [void][DevWSPrivilegeNative]::GetTokenInformation($token, 12, [IntPtr]::Zero, 0, [ref]$needed)

        if ($needed -le 0) {
            throw 'The current token session id could not be read.'
        }

        $buffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([int]$needed)

        try {
            if (-not [DevWSPrivilegeNative]::GetTokenInformation($token, 12, $buffer, $needed, [ref]$needed)) {
                throw 'The current token session id could not be read.'
            }

            return [int][System.Runtime.InteropServices.Marshal]::ReadInt32($buffer)
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
        }
    }
    finally {
        [void][DevWSPrivilegeNative]::CloseHandle($token)
    }
}

function Get-DevWSTokenStringSid {
    # Token SID (user/integrity) as a canonical string.
    param(
        [Parameter(Mandatory)][IntPtr]$Token,
        [Parameter(Mandatory)][int]$InformationClass
    )

    $needed = [uint32]0
    [void][DevWSPrivilegeNative]::GetTokenInformation($Token, $InformationClass, [IntPtr]::Zero, 0, [ref]$needed)

    if ($needed -le 0) { return $null }

    $buffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([int]$needed)

    try {
        if (-not [DevWSPrivilegeNative]::GetTokenInformation($Token, $InformationClass, $buffer, $needed, [ref]$needed)) {
            return $null
        }

        # TOKEN_USER/TOKEN_MANDATORY_LABEL both begin with SID_AND_ATTRIBUTES.
        $sidPointer = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buffer)
        $stringPointer = [IntPtr]::Zero

        if (-not [DevWSPrivilegeNative]::ConvertSidToStringSid($sidPointer, [ref]$stringPointer)) {
            return $null
        }

        try { return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($stringPointer) }
        finally { [void][DevWSPrivilegeNative]::LocalFree($stringPointer) }
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
    }
}

function Get-DevWSWorkerProcessImagePath {
    # Isolated acquisition so the caller-identity policy stays testable by
    # injection at exactly this boundary.
    param([Parameter(Mandatory)][IntPtr]$Handle)

    Initialize-DevWSNativeRuntime

    $buffer = [System.Text.StringBuilder]::new(4096)
    $size = [uint32]$buffer.Capacity

    if ([DevWSWorkerPipeIdentityNative]::QueryFullProcessImageNameW($Handle, 0, $buffer, [ref]$size)) {
        return $buffer.ToString()
    }

    return $null
}

function Get-DevWSWorkerProcessCreationTime {
    param([Parameter(Mandatory)][IntPtr]$Handle)

    Initialize-DevWSNativeRuntime

    $creation = [long]0
    $exit = [long]0
    $kernel = [long]0
    $user = [long]0

    if ([DevWSWorkerPipeIdentityNative]::GetProcessTimes($Handle, [ref]$creation, [ref]$exit, [ref]$kernel, [ref]$user)) {
        return $creation
    }

    return $null
}

function Get-DevWSWorkerProcessCommandLine {
    param([Parameter(Mandatory)][IntPtr]$Handle)

    Initialize-DevWSNativeRuntime

    $commandLine = $null

    if ([DevWSWorkerPipeIdentityNative]::TryGetCommandLine($Handle, [ref]$commandLine)) {
        return $commandLine
    }

    return $null
}

function Read-DevWSWorkerProcessIdentityFromHandle {
    # Reads the identity facts from an EXISTING process handle (the retained
    # handle). No ownership transfer: the caller keeps owning the handle.
    param(
        [Parameter(Mandatory)][IntPtr]$Handle
    )

    $identity = [ordered]@{
        Integrity    = $null
        UserSid      = $null
        SessionId    = $null
        ImagePath    = $null
        CommandLine  = $null
        CreationTime = $null
    }

    $token = [IntPtr]::Zero

    if ([DevWSPrivilegeNative]::OpenProcessToken($Handle, [uint32]0x0008, [ref]$token)) {
        try {
            $identity.Integrity = Get-DevWSTokenStringSid -Token $token -InformationClass 25
            $identity.UserSid   = Get-DevWSTokenStringSid -Token $token -InformationClass 1

            $needed = [uint32]0
            [void][DevWSPrivilegeNative]::GetTokenInformation($token, 12, [IntPtr]::Zero, 0, [ref]$needed)

            if ($needed -gt 0) {
                $buffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([int]$needed)

                try {
                    if ([DevWSPrivilegeNative]::GetTokenInformation($token, 12, $buffer, $needed, [ref]$needed)) {
                        $identity.SessionId = [int][System.Runtime.InteropServices.Marshal]::ReadInt32($buffer)
                    }
                }
                finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer) }
            }
        }
        finally {
            [void][DevWSPrivilegeNative]::CloseHandle($token)
        }
    }

    $identity.ImagePath = Get-DevWSWorkerProcessImagePath -Handle $Handle
    $identity.CreationTime = Get-DevWSWorkerProcessCreationTime -Handle $Handle
    $identity.CommandLine = Get-DevWSWorkerProcessCommandLine -Handle $Handle

    return [pscustomobject]$identity
}

function Test-DevWSWorkerArgumentIdentity {
    # Token-aware argv identity: argv[0] and every absolute-path token use
    # complete canonical path equality; non-path tokens must match exactly.
    param(
        [AllowNull()][string[]]$ProcessArgv,
        [Parameter(Mandatory)][string]$ExpectedExec,
        [Parameter(Mandatory)][string[]]$ExpectedArgv
    )

    if ($null -eq $ProcessArgv -or $ProcessArgv.Count -lt 1) {
        return [pscustomobject]@{ Ok = $false; Error = 'process command line has no argument tokens' }
    }

    if ($ProcessArgv.Count -ne ($ExpectedArgv.Count + 1)) {
        return [pscustomobject]@{ Ok = $false; Error = "process argument count $($ProcessArgv.Count) does not match the expected $($ExpectedArgv.Count + 1)" }
    }

    if (-not (Test-DevWSWorkerPathIdentityEqual -Left $ProcessArgv[0] -Right $ExpectedExec)) {
        return [pscustomobject]@{ Ok = $false; Error = "process image argument '$($ProcessArgv[0])' does not match the expected executable" }
    }

    for ($index = 0; $index -lt $ExpectedArgv.Count; $index++) {
        $expectedToken = [string]$ExpectedArgv[$index]
        $actualToken = [string]$ProcessArgv[$index + 1]

        $isPathToken = ($expectedToken -match '^[A-Za-z]:\\' -or $expectedToken -match '^\\\\')

        $matches = if ($isPathToken) {
            Test-DevWSWorkerPathIdentityEqual -Left $actualToken -Right $expectedToken
        }
        else {
            ($actualToken -ceq $expectedToken)
        }

        if (-not $matches) {
            return [pscustomobject]@{ Ok = $false; Error = "process argument token $($index + 1) ('$actualToken') does not match the expected fixed worker action" }
        }
    }

    return [pscustomobject]@{ Ok = $true; Error = $null }
}

function Test-DevWSWorkerServerIdentityRecord {
    # Pure identity policy over a process-identity record: exact High
    # integrity, current user, caller session, canonical trusted PowerShell
    # image, stable creation time and the token-aware fixed worker action.
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$ExpectedExec,
        [Parameter(Mandatory)][string[]]$ExpectedArgv,
        [Parameter(Mandatory)][string]$ExpectedUserSid,
        [Parameter(Mandatory)][int]$ExpectedSessionId
    )

    Initialize-DevWSNativeRuntime

    if ([string]$Record.Integrity -cne 'S-1-16-12288') {
        return [pscustomobject]@{ Ok = $false; Reason = "integrity-not-high ($([string]$Record.Integrity))" }
    }

    if ([string]$Record.UserSid -cne $ExpectedUserSid) {
        return [pscustomobject]@{ Ok = $false; Reason = "token-user-mismatch ($([string]$Record.UserSid))" }
    }

    if ([int]$Record.SessionId -ne $ExpectedSessionId) {
        return [pscustomobject]@{ Ok = $false; Reason = "session-mismatch ($([string]$Record.SessionId))" }
    }

    if (-not (Test-DevWSWorkerPathIdentityEqual -Left ([string]$Record.ImagePath) -Right $ExpectedExec)) {
        return [pscustomobject]@{ Ok = $false; Reason = "image-path-mismatch ($([string]$Record.ImagePath))" }
    }

    if ($null -eq $Record.CreationTime -or [long]$Record.CreationTime -eq 0) {
        return [pscustomobject]@{ Ok = $false; Reason = 'creation-time-unavailable' }
    }

    if ([string]::IsNullOrWhiteSpace([string]$Record.CommandLine)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'command-line-unavailable' }
    }

    $processArgv = $null

    try { $processArgv = [DevWSWorkerPipeIdentityNative]::SplitCommandLine([string]$Record.CommandLine) }
    catch { }

    if ($null -eq $processArgv -or $processArgv.Count -lt 1) {
        return [pscustomobject]@{ Ok = $false; Reason = 'command-line-unparsable' }
    }

    $argvCheck = Test-DevWSWorkerArgumentIdentity -ProcessArgv $processArgv -ExpectedExec $ExpectedExec -ExpectedArgv $ExpectedArgv

    if (-not $argvCheck.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = $argvCheck.Error }
    }

    return [pscustomobject]@{ Ok = $true; Reason = $null }
}

function Get-DevWSWorkerServerIdentityRecord {
    # Reads the connected server's identity from the pipe handle only:
    # kernel-reported PID, retained minimal-rights process handle, token
    # facts, canonical image path, creation time and command line. The
    # returned Handle is owned by the caller and must be retained until final
    # disposal (stable process identity; PID-reuse immune).
    param(
        [Parameter(Mandatory)] $Connection
    )

    Initialize-DevWSNativeRuntime

    $record = [ordered]@{
        Ok           = $false
        Error        = $null
        Pid          = $null
        Handle       = [IntPtr]::Zero
        Integrity    = $null
        UserSid      = $null
        SessionId    = $null
        ImagePath    = $null
        CommandLine  = $null
        CreationTime = $null
    }

    $rawHandle = $Connection.SafePipeHandle.DangerousGetHandle()
    $serverPid = [uint32]0

    if (-not [DevWSWorkerPipeIdentityNative]::GetNamedPipeServerProcessId($rawHandle, [ref]$serverPid) -or $serverPid -eq 0) {
        $record.Error = 'server-pid-unavailable'
        return [pscustomobject]$record
    }

    $record.Pid = [int]$serverPid

    $processHandle = [DevWSWorkerPipeIdentityNative]::OpenProcess([DevWSWorkerPipeIdentityNative]::ProcessQueryLimitedInformation, $false, $serverPid)

    if ($processHandle -eq [IntPtr]::Zero) {
        $record.Error = "open-process-failed (win32=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        return [pscustomobject]$record
    }

    # Exception-safe ownership: any failure while reading the identity facts
    # closes the just-opened handle before propagating, so a throwing token,
    # image, creation-time or command-line acquisition can never leak it.
    try {
        $identity = Read-DevWSWorkerProcessIdentityFromHandle -Handle $processHandle

        $record.Integrity = $identity.Integrity
        $record.UserSid = $identity.UserSid
        $record.SessionId = $identity.SessionId
        $record.ImagePath = $identity.ImagePath
        $record.CommandLine = $identity.CommandLine
        $record.CreationTime = $identity.CreationTime
        $record.Handle = $processHandle
        $record.Ok = $true
    }
    catch {
        [void][DevWSWorkerPipeIdentityNative]::CloseHandle($processHandle)
        $record.Handle = [IntPtr]::Zero
        $record.Error = "identity-read-failed ($($_.Exception.Message))"
        return [pscustomobject]$record
    }

    return [pscustomobject]$record
}

function Initialize-DevWSWorkerClientAuthentication {
    # The complete pre-transmission authentication of the connected worker:
    # Kind expectation (fixed task declaration + protected script binding),
    # identity record from the pipe handle, the pure identity policy and the
    # retained handle. Throws on any failure; the caller must then send ZERO
    # request bytes.
    param(
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)][ValidateSet("launch", "capture", "focus", "reset")][string]$Kind
    )

    $expected = Get-DevWSWorkerKindExpectation -Kind $Kind
    $record = Get-DevWSWorkerServerIdentityRecord -Connection $Connection

    if (-not $record.Ok) {
        # The record never owns a live handle on a failure path, but close any
        # unexpected non-zero value defensively before throwing so a throwing
        # acquisition can never leak the process handle.
        if ([IntPtr]$record.Handle -ne [IntPtr]::Zero) {
            [void][DevWSWorkerPipeIdentityNative]::CloseHandle([IntPtr]$record.Handle)
        }

        throw "the connected worker identity is unavailable ($($record.Error))"
    }

    try {
        $validation = Test-DevWSWorkerServerIdentityRecord `
            -Record $record `
            -ExpectedExec $expected.Exec `
            -ExpectedArgv @($expected.Argv) `
            -ExpectedUserSid (Get-DevWSCurrentUserSid) `
            -ExpectedSessionId (Get-DevWSCurrentTokenSessionId)

        if (-not $validation.Ok) {
            throw $validation.Reason
        }
    }
    catch {
        if ($record.Handle -ne [IntPtr]::Zero) {
            [void][DevWSWorkerPipeIdentityNative]::CloseHandle($record.Handle)
        }

        throw
    }

    return [pscustomobject]@{
        Handle   = $record.Handle
        Record   = $record
        Expected = $expected
    }
}

function Test-DevWSWorkerRetainedIdentityStable {
    # Re-verifies the retained-handle process identity immediately before the
    # first request byte: the handle pins the process object, so a reused PID
    # can never satisfy this check.
    param(
        [Parameter(Mandatory)]$Authentication
    )

    $identity = Read-DevWSWorkerProcessIdentityFromHandle -Handle ([IntPtr]$Authentication.Handle)
    $record = $Authentication.Record

    if ($identity.CreationTime -ne $record.CreationTime) { return $false }
    if ($identity.Integrity -cne $record.Integrity) { return $false }
    if ($identity.UserSid -cne $record.UserSid) { return $false }
    if ($identity.SessionId -ne $record.SessionId) { return $false }
    if (-not (Test-DevWSWorkerPathIdentityEqual -Left $identity.ImagePath -Right $record.ImagePath)) { return $false }

    return $true
}

function Connect-DevWSWorkerPipe {
    # Bounded connect retry against the operation-scoped pipe name. A connect
    # can succeed against an endpoint that is already closing (a dying worker
    # instance from an earlier attempt), so each candidate connection is
    # verified with a retained server-process handle before it is accepted.
    param(
        [Parameter(Mandatory)][ValidateSet("launch", "capture", "focus", "reset")][string]$Kind,
        [int]$TimeoutSeconds = 25
    )

    $pipeName = Get-DevWSWorkerOperationPipeName -Kind $Kind
    $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))

    while ([datetime]::UtcNow -lt $deadline) {
        $client = [System.IO.Pipes.NamedPipeClientStream]::new(
            ".",
            $pipeName,
            [System.IO.Pipes.PipeDirection]::InOut,
            [System.IO.Pipes.PipeOptions]::None)

        $connected = $false

        try {
            $client.Connect(250)
            $connected = $true
        }
        catch {
            $client.Dispose()
        }

        if ($connected) {
            # Verify that the connected server process is still alive; a
            # closing endpoint reports a dead PID and the attempt restarts.
            $serverPid = $null

            try { $serverPid = Get-DevWSWorkerPipeServerProcessId -Connection $client } catch { $serverPid = $null }

            if ($null -ne $serverPid) {
                $processHandle = [DevWSWorkerPipeIdentityNative]::OpenProcess([DevWSWorkerPipeIdentityNative]::ProcessQueryLimitedInformation, $false, [uint32]$serverPid)

                if ($processHandle -ne [IntPtr]::Zero) {
                    [void][DevWSWorkerPipeIdentityNative]::CloseHandle($processHandle)
                    return $client
                }
            }

            $client.Dispose()
        }

        Start-Sleep -Milliseconds 100
    }

    return $null
}

function Get-DevWSWorkerPipeServerProcessId {
    # Kernel-reported server PID for a connected client stream.
    param([Parameter(Mandatory)] $Connection)

    Initialize-DevWSNativeRuntime

    $rawHandle = $Connection.SafePipeHandle.DangerousGetHandle()
    $serverPid = [uint32]0

    if (-not [DevWSWorkerPipeIdentityNative]::GetNamedPipeServerProcessId($rawHandle, [ref]$serverPid) -or $serverPid -eq 0) {
        return $null
    }

    return [int]$serverPid
}

# ---------------------------------------------------------------------------
# Worker-serving helpers (used by the four short-lived elevated workers)
# ---------------------------------------------------------------------------

function Wait-DevWSWorkerPipeConnection {
    # Accepts exactly one caller within the bounded no-client window. The
    # accept task is armed at server creation (see New-DevWSWorkerPipeServer),
    # so a caller that connects - or connects and disconnects - before this
    # function runs is never missed. Rechecks IsConnected and the armed task.
    param(
        [Parameter(Mandatory)] $Server,
        [int]$TimeoutSeconds = 60
    )

    $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))

    while ([datetime]::UtcNow -lt $deadline) {
        if ($Server.IsConnected) { return $true }

        $pending = $null

        if ($script:DevWSWorkerPendingConnections.ContainsKey($Server)) {
            $pending = $script:DevWSWorkerPendingConnections[$Server]
        }

        if ($null -eq $pending -or $pending.IsCompleted) {
            # Completed successfully => connected (checked above); completed
            # otherwise (faulted/cancelled) => re-arm one attempt.
            if ($null -ne $pending -and $pending.IsFaulted) {
                $script:DevWSWorkerPendingConnections[$Server] = $Server.WaitForConnectionAsync()
                $pending = $script:DevWSWorkerPendingConnections[$Server]
            }
            elseif ($null -eq $pending) {
                $script:DevWSWorkerPendingConnections[$Server] = $Server.WaitForConnectionAsync()
                $pending = $script:DevWSWorkerPendingConnections[$Server]
            }
        }

        $remaining = ($deadline - [datetime]::UtcNow).TotalSeconds

        if ($remaining -le 0) { break }

        $slice = [Math]::Min(2.0, $remaining)

        try {
            if ($pending.Wait([TimeSpan]::FromSeconds($slice)) -and $pending.Status -eq 'RanToCompletion') {
                return $true
            }
        }
        catch { }

        if ($Server.IsConnected) { return $true }
    }

    return $false
}

function Read-DevWSWorkerPipeRequest {
    # One request frame from a connected caller: bounded read, strict frame
    # decoding, strict per-Kind schema. Never blocks beyond the deadline.
    param(
        [Parameter(Mandatory)] $Server,
        [Parameter(Mandatory)][ValidateSet("launch", "capture", "focus", "reset")][string]$Kind,
        [int]$TimeoutSeconds = 20
    )

    $frame = Read-DevWSWorkerFrame -Stream $Server -TimeoutSeconds $TimeoutSeconds

    if (-not $frame.Ok) {
        return [pscustomobject]@{ Ok = $false; Error = [string]$frame.Error; RequestId = ''; Payload = $null }
    }

    $check = Test-DevWSWorkerRequestFrame -Value $frame.Value -Kind $Kind

    if (-not $check.Ok) {
        return [pscustomobject]@{ Ok = $false; Error = [string]$check.Error; RequestId = [string]$check.RequestId; Payload = $null }
    }

    return [pscustomobject]@{ Ok = $true; Error = $null; RequestId = [string]$check.RequestId; Payload = $check.Payload }
}

function Send-DevWSWorkerAccepted {
    param(
        [Parameter(Mandatory)] $Server,
        [Parameter(Mandatory)][ValidateSet("launch", "capture", "focus", "reset")][string]$Kind,
        [Parameter(Mandatory)][string]$RequestId
    )

    try {
        Write-DevWSWorkerFrame -Stream $Server -Object ([ordered]@{
            version   = 1
            type      = 'accepted'
            operation = $Kind
            requestId = $RequestId
        })
        return $true
    }
    catch { return $false }
}

function Send-DevWSWorkerFinal {
    param(
        [Parameter(Mandatory)] $Server,
        [Parameter(Mandatory)][ValidateSet("launch", "capture", "focus", "reset")][string]$Kind,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][bool]$Ok,
        [AllowEmptyString()][string]$Message,
        $Data
    )

    try {
        $frame = [ordered]@{
            version   = 1
            type      = 'final'
            operation = $Kind
            requestId = $RequestId
            ok        = $Ok
            message   = [string]$Message
        }

        if ($null -ne $Data) { $frame['data'] = $Data }

        Write-DevWSWorkerFrame -Stream $Server -Object $frame
        return $true
    }
    catch { return $false }
}

function Send-DevWSWorkerError {
    param(
        [Parameter(Mandatory)] $Server,
        [Parameter(Mandatory)][ValidateSet("launch", "capture", "focus", "reset")][string]$Kind,
        [AllowEmptyString()][string]$RequestId,
        [Parameter(Mandatory)][string]$Error
    )

    try {
        Write-DevWSWorkerFrame -Stream $Server -Object ([ordered]@{
            version   = 1
            type      = 'error'
            operation = $Kind
            requestId = $RequestId
            error     = $Error
        })
        return $true
    }
    catch { return $false }
}

function Wait-DevWSWorkerFrameDelivery {
    # Server-side delivery barrier with a HARD finite bound: waits up to the
    # delivery budget for a cooperating client to consume the buffered response
    # bytes, then returns regardless. Without the barrier, a worker that exited
    # immediately after writing ACCEPTED / FINAL could - on some Windows builds
    # - destroy the pipe instance before the caller reads the buffered frame
    # (lost acknowledgment / lost FINAL for a completed operation). With an
    # UNBOUNDED barrier, a client that keeps the pipe open without reading
    # could block the single-instance worker forever.
    #
    # The bounded native flush (FlushFileBuffers on a worker thread with a Join
    # timeout) gives both properties: reliable delivery for cooperating clients
    # and a guaranteed worker exit for stalled or hostile readers. The process
    # exits immediately after this returns, which is itself resource cleanup:
    # on timeout the blocked native call keeps its OS handle until process
    # exit, so no abandoned thread ever touches freed memory.
    param(
        [Parameter(Mandatory)] $Server,
        [int]$TimeoutMilliseconds = 5000
    )

    if ($null -eq $Server) { return }

    try {
        Initialize-DevWSNativeRuntime

        $handle = [IntPtr]::Zero

        if ($null -ne $Server.PSObject.Properties['SafePipeHandle'] -and $null -ne $Server.SafePipeHandle) {
            $handle = $Server.SafePipeHandle.DangerousGetHandle()
        }

        [void][DevWSWorkerPipeIdentityNative]::TryFlushFileBuffers($handle, [Math]::Max(0, $TimeoutMilliseconds))
    }
    catch { }
}

# ---------------------------------------------------------------------------
# Scheduled task invocation and shared JSON writer (unchanged helpers)
# ---------------------------------------------------------------------------

function New-DevWSRequestId {
    return [guid]::NewGuid().ToString()
}

function Write-DevWSJsonFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        $Object
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)

    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = $Object | ConvertTo-Json -Depth 10
    $tempPath = "$Path.tmp"

    try {
        [System.IO.File]::WriteAllText(
            $tempPath,
            $json + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )

        [System.IO.File]::Move($tempPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-DevWSRootScheduledTaskState {
    # Exact root-folder scheduled-task state via the documented Task Scheduler
    # COM service. Named PowerShell scheduled-task cmdlet lookups filter a full
    # client-side enumeration (measured ~1.1 s per call); this reads the single
    # registered root task directly (~0.1 s) without mutating anything.
    # TASK_STATE_RUNNING is 4; root GetTask cannot match a same-name task in
    # another folder.
    param(
        [Parameter(Mandatory)]
        [string]$TaskName
    )

    $service = $null
    $folder  = $null
    $task    = $null

    try {
        $service = New-Object -ComObject "Schedule.Service"
        $service.Connect()
        $folder = $service.GetFolder("\")
        $task   = $folder.GetTask($TaskName)

        return [int]$task.State
    }
    catch {
        # A missing root task surfaces as FileNotFoundException (HRESULT
        # 0x80070002); map only that to an actionable DevWS error and preserve
        # every other COM failure unchanged.
        if ($_.Exception -is [System.IO.FileNotFoundException] -or $_.Exception.HResult -eq -2147024894) {
            throw "Scheduled task '$TaskName' was not found in the root Task Scheduler folder; run install.ps1 to register the DevWS scheduled tasks."
        }

        throw
    }
    finally {
        if ($null -ne $task)    { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($task) }
        if ($null -ne $folder)  { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($folder) }
        if ($null -ne $service) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($service) }
    }
}

function New-DevWSBoundedProcessInstance {
    # Single construction point for the bounded runner's process object. Kept
    # as a tiny function so tests can deterministically substitute a process
    # double (for example to exercise the unconfirmed-termination path) without
    # touching production behavior.
    param(
        [Parameter(Mandatory)][System.Diagnostics.ProcessStartInfo]$StartInfo
    )

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $StartInfo
    return $process
}

function Invoke-DevWSBoundedProcess {
    # Runs ONE absolute executable with an explicit separate argument list and
    # a hard wall-clock budget. No shell, no PATH lookup, no quoting by string
    # concatenation: ProcessStartInfo.ArgumentList passes each token verbatim.
    #
    # Output collection is deadline-driven and bounded: redirected stdout/stderr
    # are pumped in capped chunks on the caller thread, so a child (or a
    # descendant that inherits the redirected writers) can never make the caller
    # wait for EOF indefinitely, and retained diagnostics never exceed
    # OutputRetentionChars per stream. A child that exits while a descendant
    # still holds an inherited writer ends the collection after a short bounded
    # flush grace instead of waiting for that writer.
    #
    # On timeout the direct child is terminated with its permitted descendant
    # tree (Kill(true), then a direct-only retry); termination is only REPORTED
    # after the exit is actually confirmed by a finite wait, and the bounded
    # termination cleanup (TerminationGraceMilliseconds) is separate from the
    # normal execution budget.
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutMilliseconds = 10000,
        [int]$TerminationGraceMilliseconds = 5000,
        [int]$OutputRetentionChars = 4096,
        [string]$Label = "process"
    )

    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not [System.IO.Path]::IsPathRooted($FilePath)) {
        throw "The $Label executable must be an absolute path (got '$FilePath')."
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    foreach ($argument in @($Arguments)) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }

    $process = New-DevWSBoundedProcessInstance -StartInfo $startInfo

    $retention = [Math]::Max(0, $OutputRetentionChars)
    $flushGraceMilliseconds = 500

    $sides = @(
        [pscustomobject]@{ Reader = $null; Pending = $null; Eof = $false; Chars = [char[]]::new(1024); Builder = [System.Text.StringBuilder]::new() },
        [pscustomobject]@{ Reader = $null; Pending = $null; Eof = $false; Chars = [char[]]::new(1024); Builder = [System.Text.StringBuilder]::new() }
    )

    try {
        # The Boolean success signal is deliberately suppressed: the runner's
        # public contract is exactly one structured result object (or a thrown
        # error). Process-creation failures still throw from Start().
        [void]$process.Start()
        $childPid = $null

        try { $childPid = [int]$process.Id } catch { $childPid = $null }

        $pidNote = if ($null -ne $childPid) { "pid=$childPid" } else { 'pid=unknown' }

        $sides[0].Reader = $process.StandardOutput
        $sides[1].Reader = $process.StandardError

        $deadline = [datetime]::UtcNow.AddMilliseconds([Math]::Max(1, $TimeoutMilliseconds))
        $exitConfirmed = $false
        $flushUntil = $null

        while ($true) {
            foreach ($side in $sides) {
                if ($side.Eof) { continue }

                if ($null -eq $side.Pending) {
                    try { $side.Pending = $side.Reader.ReadAsync($side.Chars, 0, $side.Chars.Length) } catch { $side.Eof = $true; continue }
                }

                if ($side.Pending.IsCompleted) {
                    $read = 0

                    try { $read = [int]$side.Pending.Result } catch { $read = 0 }

                    $side.Pending = $null

                    if ($read -le 0) {
                        $side.Eof = $true
                    }
                    elseif ($side.Builder.Length -lt $retention) {
                        $take = [Math]::Min($read, $retention - $side.Builder.Length)
                        [void]$side.Builder.Append($side.Chars, 0, $take)
                    }
                }
            }

            if (-not $exitConfirmed) {
                if ($process.HasExited) {
                    $exitConfirmed = $true
                    $flushUntil = [datetime]::UtcNow.AddMilliseconds($flushGraceMilliseconds)
                }
                elseif ([datetime]::UtcNow -ge $deadline) {
                    break
                }

                Start-Sleep -Milliseconds 10
                continue
            }

            # Exit confirmed: drain what the pipes already hold, but never wait
            # for EOF beyond the short flush grace - a descendant that still
            # holds an inherited writer must not delay the caller.
            $openSides = @($sides | Where-Object { -not $_.Eof }).Count

            if ($openSides -eq 0) { break }
            if ([datetime]::UtcNow -ge $flushUntil) { break }

            Start-Sleep -Milliseconds 10
        }

        if (-not $exitConfirmed) {
            # Termination path: bounded, confirmed, and separate from the
            # normal execution budget. From here on the runner never claims
            # termination unless the exit was actually observed.
            $treeKillAttempted = $false

            try { $process.Kill($true); $treeKillAttempted = $true } catch { }

            $terminationConfirmed = $false

            try { $terminationConfirmed = $process.WaitForExit([Math]::Max(1, $TerminationGraceMilliseconds)) } catch { $terminationConfirmed = $false }

            if (-not $terminationConfirmed) {
                # Direct-child retry, still finitely bounded.
                try { $process.Kill() } catch { }
                try { $terminationConfirmed = $process.WaitForExit(1000) } catch { $terminationConfirmed = $false }
            }

            if ($terminationConfirmed) {
                throw "The $Label invocation did not finish within $TimeoutMilliseconds ms and was terminated (exit confirmed; $pidNote; tree kill attempted=$treeKillAttempted)."
            }

            throw "The $Label invocation did not finish within $TimeoutMilliseconds ms and its termination could not be confirmed ($pidNote); the caller must not assume the invocation target has stopped."
        }

        $detail = ''

        try {
            $stderrText = $sides[1].Builder.ToString().Trim()
            $stdoutText = $sides[0].Builder.ToString().Trim()
            $detail = if ($stderrText) { $stderrText } elseif ($stdoutText) { $stdoutText } else { '' }
        }
        catch { }

        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Detail   = $detail
        }
    }
    finally {
        # Observe any still-pending read tasks (a faulted task must never
        # surface later as an unobserved exception) before disposal releases
        # the streams.
        foreach ($side in $sides) {
            if ($null -ne $side.Pending) {
                try { [void]$side.Pending.Wait(0) } catch { }
            }
        }

        try { $process.Dispose() } catch { }
    }
}

function Start-DevWSScheduledTask {
    # The single controlled scheduled-task invocation. Kept as a tiny helper so
    # the split request protocol is deterministically testable; task
    # registration, task definitions and single-instance policy are unchanged.
    # The trusted system executable is resolved under %SystemRoot%\System32
    # (never PATH); this library is copied into the privileged runtime, so no
    # bare executable may appear here.
    #
    # The kickoff is narrowly bounded: schtasks.exe gets a hard 10-second
    # budget, a timeout terminates ONLY schtasks.exe (never the scheduled
    # worker it may already have started), and a nonzero exit code is refused
    # explicitly. Every failure here is a NotTransmitted caller outcome,
    # because no request byte can have been sent yet.
    param(
        [Parameter(Mandatory)]
        [string]$TaskName,
        [int]$TimeoutMilliseconds = 10000
    )

    $schtasks = Get-DevWSTrustedSystemExecutable -Name "schtasks.exe"

    $result = Invoke-DevWSBoundedProcess `
        -FilePath $schtasks `
        -Arguments @('/run', '/tn', $TaskName) `
        -TimeoutMilliseconds ([Math]::Max(1, $TimeoutMilliseconds)) `
        -Label "scheduled task '$TaskName' kickoff"

    if ([int]$result.ExitCode -ne 0) {
        $detail = if (-not [string]::IsNullOrWhiteSpace([string]$result.Detail)) { ": $($result.Detail)" } else { "" }
        throw "schtasks /run for '$TaskName' failed with exit code $($result.ExitCode)$detail."
    }
}

# ---------------------------------------------------------------------------
# Public split caller API
# ---------------------------------------------------------------------------

function Start-DevWSWorkerRequest {
    # Model A: kick the fixed scheduled task, connect with a bounded retry,
    # authenticate the connected server from the pipe handle, transmit one
    # bounded request frame and return the live connection handle after
    # observing ACCEPTED. The High worker then executes while the Medium caller
    # continues its own work; Complete settles the outcome.
    #
    # Failure states are propagated through state-tagged exceptions:
    # NotTransmitted (no request bytes; retryable), Rejected (explicit
    # correlated pre-execution rejection; retryable at a caller site that
    # permits it) and UncertainNoAck (transmission may have begun; never
    # automatically retried or replaced by a fallback).
    param(
        [Parameter(Mandatory)]
        [ValidateSet("launch", "capture", "focus", "reset")]
        [string]$Kind,
        [Parameter(Mandatory)]
        [string]$TaskName,
        $Payload,
        [int]$TimeoutSeconds = 60
    )

    $boundTask = Get-DevWSWorkerKindTaskName -Kind $Kind

    if (-not [string]::IsNullOrWhiteSpace($TaskName) -and $TaskName -cne $boundTask) {
        throw (New-DevWSWorkerStateException -State 'NotTransmitted' -Message "The '$Kind' worker request names task '$TaskName', which does not match the fixed binding '$boundTask'.")
    }

    $requestId = New-DevWSRequestId
    $deadline = [datetime]::UtcNow.AddSeconds([Math]::Max(1, $TimeoutSeconds))

    # ---- kick (no request bytes can exist yet) -----------------------------
    try {
        Start-DevWSScheduledTask -TaskName $boundTask
    }
    catch {
        throw (New-DevWSWorkerStateException -State 'NotTransmitted' -Message "The '$boundTask' scheduled task could not be started: $($_.Exception.Message)")
    }

    # ---- connect (bounded retry; no request bytes) -------------------------
    $connectBudget = [Math]::Min(25, (Get-DevWSWorkerRemainingSeconds -Deadline $deadline))
    $connection = $null

    if ($connectBudget -gt 0) {
        $connection = Connect-DevWSWorkerPipe -Kind $Kind -TimeoutSeconds $connectBudget
    }

    if ($null -eq $connection) {
        throw (New-DevWSWorkerStateException -State 'NotTransmitted' -Message "The elevated '$Kind' worker did not accept a connection within the connect deadline; no request bytes were sent.")
    }

    # ---- authenticate the connected server (no request bytes) --------------
    $authentication = $null

    try {
        $authentication = Initialize-DevWSWorkerClientAuthentication -Connection $connection -Kind $Kind

        if (-not (Test-DevWSWorkerRetainedIdentityStable -Authentication $authentication)) {
            throw 'the retained server process identity changed before request transmission'
        }
    }
    catch {
        if ($null -ne $authentication -and [IntPtr]$authentication.Handle -ne [IntPtr]::Zero) {
            [void][DevWSWorkerPipeIdentityNative]::CloseHandle([IntPtr]$authentication.Handle)
        }

        $connection.Dispose()
        throw (New-DevWSWorkerStateException -State 'NotTransmitted' -Message "The '$Kind' worker server identity verification failed before any request byte was sent: $($_.Exception.Message)")
    }

    # ---- transmit one bounded request frame --------------------------------
    $frame = [ordered]@{
        version   = 1
        operation = $Kind
        requestId = $requestId
        payload   = if ($null -ne $Payload) { $Payload } else { [pscustomobject]@{} }
    }

    try {
        Write-DevWSWorkerFrame -Stream $connection -Object $frame
    }
    catch {
        $connection.Dispose()
        [void][DevWSWorkerPipeIdentityNative]::CloseHandle([IntPtr]$authentication.Handle)
        throw (New-DevWSWorkerStateException -State 'UncertainNoAck' -Message "The '$Kind' request transmission failed ($($_.Exception.Message)); the operation may have started and must not be repeated automatically.")
    }

    # ---- await ACCEPTED (bounded; further bounded by the budget) -----------
    # After the first request byte may have been transmitted the whole region
    # is exception-safe: an unexpected read exception, a malformed frame or an
    # uncorrelated response all classify as UncertainNoAck (never
    # NotTransmitted), and every unsuccessful exit disposes the connection and
    # the retained process handle exactly once.
    $acceptedObserved = $false
    $rejection = $null
    $ackBudget = [Math]::Min(30, (Get-DevWSWorkerRemainingSeconds -Deadline $deadline))
    $response = $null

    try {
        if ($ackBudget -gt 0) {
            $response = Read-DevWSWorkerFrame -Stream $connection -TimeoutSeconds $ackBudget
        }

        if ($null -ne $response -and $response.Ok) {
            $typeProperty = $response.Value.PSObject.Properties['type']
            $responseType = if ($null -ne $typeProperty) { [string]$typeProperty.Value } else { '' }

            if ($responseType -eq 'accepted') {
                $check = Test-DevWSWorkerResponseFrame -Value $response.Value -ExpectedOperation $Kind -ExpectedRequestId $requestId -AllowedTypes @('accepted')

                if ($check.Ok) {
                    $acceptedObserved = $true
                }
            }
            elseif ($responseType -eq 'error') {
                $check = Test-DevWSWorkerResponseFrame -Value $response.Value -ExpectedOperation $Kind -ExpectedRequestId $requestId -AllowedTypes @('error')

                if ($check.Ok) {
                    $rejection = [string]$response.Value.error
                }
            }
        }
    }
    catch { }

    # Start-stage classification: an observed ACCEPTED is the success path
    # (the worker executes while the caller continues); only an explicit
    # correlated rejection is retryable, and anything else after transmission
    # is uncertain.
    if (-not $acceptedObserved) {
        $connection.Dispose()
        [void][DevWSWorkerPipeIdentityNative]::CloseHandle([IntPtr]$authentication.Handle)

        if ($null -ne $rejection) {
            throw (New-DevWSWorkerStateException -State 'Rejected' -Message "The elevated '$Kind' worker rejected the request before execution: $rejection")
        }

        throw (New-DevWSWorkerStateException -State 'UncertainNoAck' -Message "No ACCEPTED was observed for the '$Kind' worker request after transmission; the operation may have started and must not be repeated automatically (no fallback).")
    }

    return [pscustomobject]@{
        Kind        = $Kind
        TaskName    = $boundTask
        RequestId   = $requestId
        PipeName    = (Get-DevWSWorkerOperationPipeName -Kind $Kind)
        Connection  = $connection
        ServerPid   = [int]$authentication.Record.Pid
        ServerHandle = [IntPtr]$authentication.Handle
        AcceptedAt  = [datetime]::UtcNow
        Deadline    = $deadline
        TimeoutSeconds = $TimeoutSeconds
    }
}

function Complete-DevWSWorkerRequest {
    # Waits for the correlated FINAL within the remaining operation budget,
    # classifies the caller-observable outcome, and disposes every owned
    # resource on every path. UncertainAfterAccept is never automatically
    # retried; an unsuccessful FINAL preserves the historical caller-facing
    # failure form ("Scheduled worker '<kind>' failed: <message>").
    param(
        [Parameter(Mandatory)]
        $Request
    )

    foreach ($field in @('Kind', 'TaskName', 'RequestId', 'Connection', 'Deadline', 'TimeoutSeconds')) {
        if ($null -eq $Request.$field) {
            throw "Complete-DevWSWorkerRequest requires the request handle returned by Start-DevWSWorkerRequest (missing '$field')."
        }
    }

    $kind = [string]$Request.Kind
    $connection = $Request.Connection
    $serverHandle = [IntPtr]$Request.ServerHandle

    try {
        $remaining = Get-DevWSWorkerRemainingSeconds -Deadline ([datetime]$Request.Deadline)

        if ($remaining -le 0) {
            throw (New-DevWSWorkerStateException -State 'UncertainAfterAccept' -Message "The '$kind' worker operation budget expired before FINAL was observed; the operation may have completed and must not be repeated automatically.")
        }

        $response = Read-DevWSWorkerFrame -Stream $connection -TimeoutSeconds $remaining

        if (-not $response.Ok) {
            throw (New-DevWSWorkerStateException -State 'UncertainAfterAccept' -Message "The '$kind' worker finished without a readable FINAL ($($response.Error)); the operation may have completed and must not be repeated automatically.")
        }

        $check = Test-DevWSWorkerResponseFrame -Value $response.Value -ExpectedOperation $kind -ExpectedRequestId ([string]$Request.RequestId) -AllowedTypes @('final')

        $finalObserved = [bool]$check.Ok
        $state = Resolve-DevWSWorkerCallerState -Connected $true -BytesSent $true -AcceptedObserved $true -FinalObserved $finalObserved

        if ($state -ne 'Completed') {
            throw (New-DevWSWorkerStateException -State 'UncertainAfterAccept' -Message "The '$kind' worker FINAL is not correlated to this request ($($check.Error)); the operation may have completed and must not be repeated automatically.")
        }

        $value = $response.Value
        $result = [pscustomobject]@{
            requestId = [string]$Request.RequestId
            ok        = [bool]$value.ok
            message   = [string]$value.message
        }

        if ($null -ne $value.PSObject.Properties['data'] -and $null -ne $value.data) {
            $result | Add-Member -NotePropertyName data -NotePropertyValue $value.data
        }

        if (-not [bool]$value.ok) {
            throw (New-DevWSWorkerStateException -State 'Completed' -Message "Scheduled worker '$kind' failed: $($result.message)")
        }

        return $result
    }
    finally {
        try { $connection.Dispose() } catch { }

        if ($serverHandle -ne [IntPtr]::Zero) {
            [void][DevWSWorkerPipeIdentityNative]::CloseHandle($serverHandle)
        }
    }
}

function Invoke-DevWSWorkerRequest {
    # Compatibility wrapper for non-overlapped callers (capture, focus, reset):
    # start immediately followed by completion, exactly the historical
    # observable behavior. Start-level failures (NotTransmitted / Rejected /
    # UncertainNoAck) and completion failures (UncertainAfterAccept /
    # unsuccessful FINAL) propagate unchanged; there is no automatic retry.
    param(
        [Parameter(Mandatory)]
        [ValidateSet("launch", "capture", "focus", "reset")]
        [string]$Kind,
        [Parameter(Mandatory)]
        [string]$TaskName,
        $Payload,
        [int]$TimeoutSeconds = 60
    )

    $request = Start-DevWSWorkerRequest `
        -Kind $Kind `
        -TaskName $TaskName `
        -Payload $Payload `
        -TimeoutSeconds $TimeoutSeconds

    return (Complete-DevWSWorkerRequest -Request $request)
}
