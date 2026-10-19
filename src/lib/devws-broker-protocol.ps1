# DevWS elevated broker protocol library (Stage 2).
#
# Owns the secure pipe boundary, the strictly validated JSON-line protocol and
# the client API for the persistent elevated broker. It contains NO terminal
# launch policy: plans, kickoff and completion live in
# devws-terminal-launch.ps1, and the transaction that drives them lives in
# devws-launch.ps1.
#
# Wire protocol (one JSON object per line, UTF-8, bounded strict ceiling -
# see Get-DevWSBrokerMaxLineLength; only prepare-launch carries the terminal
# placement array):
#
#   {"version":1,"command":"ping"}
#   {"version":1,"command":"prepare-launch","requestId":<int>,"setId":<string>,
#    "terminalPlacements":[{"id":"slot","move":true,"x":-7,"y":0,"w":654,"h":1407},{"id":"term2","move":false}]}
#   {"version":1,"command":"go-launch","requestId":<int>,"planId":<string>}
#   {"version":1,"command":"abort-launch","requestId":<int>}
#   {"version":1,"command":"focus-terminals","requestId":<int>,"setId":<string>}
#   {"version":1,"command":"capture-terminals","requestId":<int>,"setId":<string>}
#   {"version":1,"command":"shutdown"}
#
# terminalPlacements carries FINAL normal-side geometry decisions only (what
# to apply, never why it was chosen): elevated hosts must never interpret
# monitoring/profile policy.
#
# Responses are JSON lines with a "type" field:
#
#   pong | ready | prepare-failed | go-ack | replan-required | final |
#   operation-accepted | operation-final | operation-rejected |
#   aborted | bye | restart-required | error
#
# No arbitrary script execution, no active-workspace state, one pending plan.

function Get-DevWSElevatedBrokerTaskName {
    return "DevWorkspace-ElevatedBroker"
}

function Get-DevWSElevatedBrokerPipeName {
    # Stable local named pipe served by the elevated broker.
    return "DevWS.ElevatedBroker.v1"
}

function Get-DevWSElevatedBrokerMutexName {
    # Local-session singleton mutex (same convention as the coordinator).
    return "Local\DevWS.ElevatedBroker.v1.Instance"
}

function Get-DevWSBrokerProtocolVersion {
    return 1
}

function Get-DevWSBrokerMaxLineLength {
    # Strict bounded request ceiling. Historical requests are well under 200
    # bytes, but prepare-launch now carries terminal placement records, so the
    # ceiling is 64 KiB: generous for any real workspace while still a hard
    # bound. The coordinator protocol keeps its separate 4 KiB ceiling.
    return 65536
}

function Get-DevWSElevatedBrokerPipeSddl {
    # Current user + SYSTEM full access; Medium mandatory label so the
    # non-elevated coordinator can open the high-integrity broker pipe.
    # Deliberately no Everyone and no Authenticated Users grant.
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return "D:(A;;GA;;;$sid)(A;;GA;;;SY)S:(ML;;NW;;;ME)"
}

function New-DevWSElevatedBrokerPipeServer {
    # Raw CreateNamedPipeW with the explicit SDDL, wrapped in a
    # NamedPipeServerStream over the returned handle. NamedPipeServerStreamAcl
    # is NOT used: it requires SeSecurityPrivilege on this machine.
    param([string]$PipeName = (Get-DevWSElevatedBrokerPipeName))

    Initialize-DevWSNativeRuntime

    $handle = [System.IntPtr]::Zero
    $win32Error = 0

    if (-not [DevWSBrokerPipeNative]::TryCreateSecurePipe($PipeName, (Get-DevWSElevatedBrokerPipeSddl), [ref]$handle, [ref]$win32Error)) {
        $message = [System.ComponentModel.Win32Exception]::new($win32Error).Message
        throw "Could not create the DevWS elevated broker pipe '$PipeName' (Win32 ${win32Error}: $message)."
    }

    $safeHandle = [Microsoft.Win32.SafeHandles.SafePipeHandle]::new($handle, $true)

    return [System.IO.Pipes.NamedPipeServerStream]::new(
        [System.IO.Pipes.PipeDirection]::InOut,
        $false,
        $false,
        $safeHandle)
}

function Test-DevWSBrokerProtocolRequest {
    # Strict validation of one JSON request line. Unknown fields, wrong
    # versions, unsupported commands, malformed ids and oversized lines are
    # rejected before any policy code runs.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Line,
        [int]$MaxLength = (Get-DevWSBrokerMaxLineLength)
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return [pscustomobject]@{ Ok = $false; Error = "empty request"; Request = $null }
    }

    if ($Line.Length -gt $MaxLength) {
        return [pscustomobject]@{ Ok = $false; Error = "request exceeds the $MaxLength byte protocol limit"; Request = $null }
    }

    try {
        $parsed = ConvertFrom-Json -InputObject $Line -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Error = "malformed JSON request"; Request = $null }
    }

    if ($null -eq $parsed -or $parsed -isnot [System.Management.Automation.PSCustomObject]) {
        return [pscustomobject]@{ Ok = $false; Error = "malformed JSON request"; Request = $null }
    }

    foreach ($property in @($parsed.PSObject.Properties)) {
        if (@("version", "command", "requestId", "planId", "setId", "terminalPlacements") -notcontains [string]$property.Name) {
            return [pscustomobject]@{ Ok = $false; Error = "unsupported request field '$($property.Name)'"; Request = $null }
        }
    }

    $versionProperty = $parsed.PSObject.Properties["version"]

    if ($null -eq $versionProperty -or -not (Test-DevWSInteger $versionProperty.Value) -or
        [int]$versionProperty.Value -ne (Get-DevWSBrokerProtocolVersion)) {
        return [pscustomobject]@{ Ok = $false; Error = "unsupported protocol version (expected $(Get-DevWSBrokerProtocolVersion))"; Request = $null }
    }

    $commandProperty = $parsed.PSObject.Properties["command"]
    $command = if ($null -ne $commandProperty) { [string]$commandProperty.Value } else { "" }

    if ($command -notin @("ping", "status", "prepare-launch", "go-launch", "abort-launch", "focus-terminals", "capture-terminals", "shutdown")) {
        return [pscustomobject]@{ Ok = $false; Error = "unsupported command '$command'"; Request = $null }
    }

    $requestId = $null
    $planId = $null
    $setId = $null

    if ($command -in @("prepare-launch", "go-launch", "abort-launch", "focus-terminals", "capture-terminals")) {
        $requestIdProperty = $parsed.PSObject.Properties["requestId"]

        if ($null -eq $requestIdProperty -or -not (Test-DevWSInteger $requestIdProperty.Value) -or [long]$requestIdProperty.Value -lt 1) {
            return [pscustomobject]@{ Ok = $false; Error = "requestId must be a positive integer"; Request = $null }
        }

        $requestId = [long]$requestIdProperty.Value
    }
    elseif ($null -ne $parsed.PSObject.Properties["requestId"]) {
        return [pscustomobject]@{ Ok = $false; Error = "command '$command' does not accept requestId"; Request = $null }
    }

    if ($command -eq "go-launch") {
        $planIdProperty = $parsed.PSObject.Properties["planId"]

        if ($null -eq $planIdProperty -or $planIdProperty.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$planIdProperty.Value) -or ([string]$planIdProperty.Value).Length -gt 200) {
            return [pscustomobject]@{ Ok = $false; Error = "planId must be a non-empty string"; Request = $null }
        }

        $planId = [string]$planIdProperty.Value
    }
    elseif ($null -ne $parsed.PSObject.Properties["planId"]) {
        return [pscustomobject]@{ Ok = $false; Error = "command '$command' does not accept planId"; Request = $null }
    }

    if ($command -in @("prepare-launch", "focus-terminals", "capture-terminals")) {
        $setIdProperty = $parsed.PSObject.Properties["setId"]

        if ($null -eq $setIdProperty -or $setIdProperty.Value -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$setIdProperty.Value) -or ([string]$setIdProperty.Value).Length -gt 200) {
            return [pscustomobject]@{ Ok = $false; Error = "setId must be a non-empty string"; Request = $null }
        }

        $setId = [string]$setIdProperty.Value
    }
    elseif ($null -ne $parsed.PSObject.Properties["setId"]) {
        return [pscustomobject]@{ Ok = $false; Error = "command '$command' does not accept setId"; Request = $null }
    }

    # terminalPlacements is a prepare-launch-only payload: final geometry and
    # move decisions computed by the NORMAL side. Shape validation reuses the
    # one shared placement parser (devws-terminal-launch.ps1); correlation
    # against configured terminals happens in the prepare handler.
    $terminalPlacements = $null
    $terminalPlacementsProperty = $parsed.PSObject.Properties["terminalPlacements"]

    if ($null -ne $terminalPlacementsProperty) {
        if ($command -ne "prepare-launch") {
            return [pscustomobject]@{ Ok = $false; Error = "command '$command' does not accept terminalPlacements"; Request = $null }
        }

        $placementValidation = Test-DevWSTerminalPlacementRecords -Records $terminalPlacementsProperty.Value

        if (-not $placementValidation.Ok) {
            return [pscustomobject]@{ Ok = $false; Error = $placementValidation.Error; Request = $null }
        }

        $terminalPlacements = @($terminalPlacementsProperty.Value)
    }

    return [pscustomobject]@{
        Ok      = $true
        Error   = $null
        Request = [pscustomobject]@{
            Command            = $command
            RequestId          = $requestId
            PlanId             = $planId
            SetId              = $setId
            TerminalPlacements = $terminalPlacements
        }
    }
}

# ---------------------------------------------------------------------------
# Client side
# ---------------------------------------------------------------------------

function Read-DevWSBrokerResponseLine {
    # Bounded single-line read: a hung broker can never wedge the caller.
    param(
        [Parameter(Mandatory)]$Reader,
        [int]$TimeoutMilliseconds = 10000
    )

    $cts = [System.Threading.CancellationTokenSource]::new($TimeoutMilliseconds)

    try {
        $line = $Reader.ReadLineAsync($cts.Token).GetAwaiter().GetResult()
    }
    catch [System.OperationCanceledException] {
        throw "The DevWS elevated broker did not answer within $TimeoutMilliseconds ms."
    }
    finally {
        $cts.Dispose()
    }

    if ($null -eq $line) {
        throw "The DevWS elevated broker closed the connection unexpectedly."
    }

    try {
        $parsed = $line | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "The DevWS elevated broker sent a malformed response: $line"
    }

    return $parsed
}

function Connect-DevWSElevatedBroker {
    param(
        [string]$PipeName = (Get-DevWSElevatedBrokerPipeName),
        [int]$TimeoutMilliseconds = 3000
    )

    $client = [System.IO.Pipes.NamedPipeClientStream]::new(
        ".",
        $PipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        [System.IO.Pipes.PipeOptions]::None)

    try {
        $client.Connect($TimeoutMilliseconds)
    }
    catch {
        $client.Dispose()
        throw "The DevWS elevated broker pipe '$PipeName' is unavailable: $($_.Exception.Message)"
    }

    return $client
}

function New-DevWSElevatedBrokerConnection {
    # One connection per launch request; the caller sends prepare, later go,
    # and reads ready/go-ack/final on the same stream.
    param(
        [string]$PipeName = (Get-DevWSElevatedBrokerPipeName),
        [int]$TimeoutMilliseconds = 3000
    )

    $client = Connect-DevWSElevatedBroker -PipeName $PipeName -TimeoutMilliseconds $TimeoutMilliseconds
    $encoding = [System.Text.UTF8Encoding]::new($false)

    return [pscustomobject]@{
        Client = $client
        Reader = [System.IO.StreamReader]::new($client, $encoding, $false, 4096, $true)
        Writer = [System.IO.StreamWriter]::new($client, $encoding, 4096, $true)
    }
}

function Send-DevWSBrokerRequestLine {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)]$Request
    )

    $Connection.Writer.WriteLine(($Request | ConvertTo-Json -Compress -Depth 4))
    $Connection.Writer.Flush()
}

function New-DevWSElevatedBrokerPrepare {
    # Sends prepare-launch and returns the open connection WITHOUT waiting for
    # READY, so the caller can run the app prepare concurrently with the
    # broker's terminal plan.
    #
    # -TerminalPlacements carries the frozen normal-side placement records
    # (id + move + exact geometry). When supplied, the broker plan uses them
    # verbatim; when omitted (legacy/test callers) the broker keeps the
    # historical per-terminal default.
    param(
        [Parameter(Mandatory)][long]$RequestId,
        [Parameter(Mandatory)][string]$SetId,
        [AllowNull()][object[]]$TerminalPlacements = $null,
        [string]$PipeName = (Get-DevWSElevatedBrokerPipeName),
        [int]$TimeoutMilliseconds = 3000
    )

    $request = [ordered]@{
        version   = (Get-DevWSBrokerProtocolVersion)
        command   = "prepare-launch"
        requestId = [long]$RequestId
        setId     = $SetId
    }

    if ($PSBoundParameters.ContainsKey("TerminalPlacements") -and $null -ne $TerminalPlacements) {
        $request.terminalPlacements = @($TerminalPlacements)
    }

    $connection = New-DevWSElevatedBrokerConnection -PipeName $PipeName -TimeoutMilliseconds $TimeoutMilliseconds

    try {
        Send-DevWSBrokerRequestLine -Connection $connection -Request $request
    }
    catch {
        Close-DevWSElevatedBrokerConnection -Connection $connection
        throw
    }

    return $connection
}

function Wait-DevWSElevatedBrokerPrepare {
    param(
        [Parameter(Mandatory)]$Connection,
        [int]$TimeoutMilliseconds = 30000
    )

    return Read-DevWSBrokerResponseLine -Reader $Connection.Reader -TimeoutMilliseconds $TimeoutMilliseconds
}

function Send-DevWSElevatedBrokerGo {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][long]$RequestId,
        [Parameter(Mandatory)][string]$PlanId,
        [int]$TimeoutMilliseconds = 10000
    )

    Send-DevWSBrokerRequestLine -Connection $Connection -Request ([ordered]@{
        version   = (Get-DevWSBrokerProtocolVersion)
        command   = "go-launch"
        requestId = [long]$RequestId
        planId    = $PlanId
    })

    return Read-DevWSBrokerResponseLine -Reader $Connection.Reader -TimeoutMilliseconds $TimeoutMilliseconds
}

function Read-DevWSElevatedBrokerFinal {
    # Bounded wait for the FINAL line after a GO-ACK. Returns $null when the
    # connection is lost or the broker does not finish in time: the caller must
    # then report an uncertain completion and NEVER fall back.
    param(
        [Parameter(Mandatory)]$Connection,
        [int]$TimeoutMilliseconds = 120000
    )

    try {
        return Read-DevWSBrokerResponseLine -Reader $Connection.Reader -TimeoutMilliseconds $TimeoutMilliseconds
    }
    catch {
        return $null
    }
}

function Send-DevWSElevatedBrokerAbort {
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][long]$RequestId,
        [int]$TimeoutMilliseconds = 5000
    )

    Send-DevWSBrokerRequestLine -Connection $Connection -Request ([ordered]@{
        version   = (Get-DevWSBrokerProtocolVersion)
        command   = "abort-launch"
        requestId = [long]$RequestId
    })

    return Read-DevWSBrokerResponseLine -Reader $Connection.Reader -TimeoutMilliseconds $TimeoutMilliseconds
}

function Close-DevWSElevatedBrokerConnection {
    param($Connection)

    if ($null -eq $Connection) {
        return
    }

    foreach ($disposable in @($Connection.Reader, $Connection.Writer, $Connection.Client)) {
        if ($null -ne $disposable) {
            try { $disposable.Dispose() } catch { }
        }
    }
}

function Test-DevWSElevatedBrokerPipeExists {
    # Fast, bounded check whether the broker pipe is currently being served.
    #
    # The broker re-arms its single pipe instance between connections
    # (Disconnect -> WaitForConnection), so the name can be momentarily absent
    # for a few milliseconds right after a client disconnects. A single sample
    # would therefore misclassify a live broker as dead; sample briefly within
    # a small confirmation window instead. Only a consistently absent name
    # counts as "broker not running", which keeps the dead-broker fallback
    # prompt (no full connect timeout) without flapping under normal churn.
    param(
        [string]$PipeName = (Get-DevWSElevatedBrokerPipeName),
        [int]$ConfirmMilliseconds = 250,
        [int]$SampleMilliseconds = 25
    )

    $target = "\\.\pipe\" + $PipeName
    $deadline = [DateTime]::UtcNow.AddMilliseconds($ConfirmMilliseconds)

    while ($true) {
        try {
            foreach ($candidate in [System.IO.Directory]::GetFiles("\\.\pipe\")) {
                if ($candidate -ieq $target) {
                    return $true
                }
            }
        }
        catch {
            # Fail open: an enumeration failure must not disable the broker path.
            return $true
        }

        if ([DateTime]::UtcNow -ge $deadline) {
            return $false
        }

        Start-Sleep -Milliseconds $SampleMilliseconds
    }
}

function Start-DevWSElevatedBrokerTerminalOperation {
    # Sends focus-terminals / capture-terminals and returns the open connection
    # WITHOUT waiting for ACCEPTED, so callers can apply their own bounded
    # acceptance deadline and distinguish the pre/post-acceptance boundary.
    param(
        [Parameter(Mandatory)]
        [ValidateSet("focus-terminals", "capture-terminals")]
        [string]$Command,
        [Parameter(Mandatory)]
        [long]$RequestId,
        [Parameter(Mandatory)]
        [string]$SetId,
        [string]$PipeName = (Get-DevWSElevatedBrokerPipeName),
        [int]$TimeoutMilliseconds = 3000
    )

    $connection = New-DevWSElevatedBrokerConnection -PipeName $PipeName -TimeoutMilliseconds $TimeoutMilliseconds

    try {
        Send-DevWSBrokerRequestLine -Connection $connection -Request ([ordered]@{
            version   = (Get-DevWSBrokerProtocolVersion)
            command   = $Command
            requestId = [long]$RequestId
            setId     = $SetId
        })
    }
    catch {
        Close-DevWSElevatedBrokerConnection -Connection $connection
        throw
    }

    return $connection
}

function Wait-DevWSElevatedBrokerOperationAccepted {
    # Bounded wait for the operation-accepted / operation-rejected response.
    param(
        [Parameter(Mandatory)]
        $Connection,
        [int]$TimeoutMilliseconds = 30000
    )

    return Read-DevWSBrokerResponseLine -Reader $Connection.Reader -TimeoutMilliseconds $TimeoutMilliseconds
}

function Read-DevWSElevatedBrokerOperationFinal {
    # Bounded wait for the FINAL line after ACCEPTED. Returns $null when the
    # connection is lost or the broker does not finish in time: the caller must
    # then report an uncertain completion and NEVER fall back.
    param(
        [Parameter(Mandatory)]
        $Connection,
        [int]$TimeoutMilliseconds = 120000
    )

    try {
        return Read-DevWSBrokerResponseLine -Reader $Connection.Reader -TimeoutMilliseconds $TimeoutMilliseconds
    }
    catch {
        return $null
    }
}

function Request-DevWSElevatedBrokerRestartBestEffort {
    # Fire-and-forget recovery used by non-launch operations: it never waits,
    # and failures simply leave the broker unavailable (the caller falls back
    # to the scheduled worker). Safe against duplicate execution because it is
    # only invoked BEFORE any operation is accepted.
    try { Start-DevWSElevatedBrokerTask } catch { }
}

function Invoke-DevWSElevatedBrokerTerminalOperation {
    # One focus-terminals / capture-terminals round trip with an explicit
    # three-state outcome so callers can enforce the safety boundary:
    #
    #   NotAccepted          - no side effect may have happened; the scheduled
    #                          worker fallback remains permissible.
    #   AcceptedAndCompleted - the broker reported FINAL; inspect Ok/Message.
    #   AcceptedButUncertain - ACCEPTED was received but FINAL was lost; side
    #                          effects may have happened; NEVER fall back and
    #                          never repeat the operation automatically.
    param(
        [Parameter(Mandatory)]
        [ValidateSet("focus-terminals", "capture-terminals")]
        [string]$Command,
        [Parameter(Mandatory)]
        [long]$RequestId,
        [Parameter(Mandatory)]
        [string]$SetId,
        [string]$PipeName = (Get-DevWSElevatedBrokerPipeName),
        [int]$ConnectTimeoutMilliseconds = 1500,
        [int]$AcceptTimeoutMilliseconds = 30000,
        [int]$FinalTimeoutMilliseconds = 120000
    )

    $connection = $null

    if (-not (Test-DevWSElevatedBrokerPipeExists -PipeName $PipeName)) {
        # No broker at all: no side effects are possible. Kick the managed task
        # best-effort for FUTURE calls and let the caller fall back immediately.
        Request-DevWSElevatedBrokerRestartBestEffort

        return [pscustomobject]@{
            Status  = "NotAccepted"
            Ok      = $false
            Message = ""
            Error   = "the elevated broker is not running"
        }
    }

    try {
        $connection = Start-DevWSElevatedBrokerTerminalOperation `
            -Command $Command `
            -RequestId $RequestId `
            -SetId $SetId `
            -PipeName $PipeName `
            -TimeoutMilliseconds $ConnectTimeoutMilliseconds
    }
    catch {
        # Unavailable/connect failure: no side effects. Kick the managed task
        # best-effort for FUTURE calls, then let the caller fall back.
        Request-DevWSElevatedBrokerRestartBestEffort

        return [pscustomobject]@{
            Status  = "NotAccepted"
            Ok      = $false
            Message = ""
            Error   = $_.Exception.Message
        }
    }

    $accepted = $null

    try {
        $accepted = Wait-DevWSElevatedBrokerOperationAccepted -Connection $connection -TimeoutMilliseconds $AcceptTimeoutMilliseconds
    }
    catch {
        Close-DevWSElevatedBrokerConnection -Connection $connection

        return [pscustomobject]@{
            Status  = "NotAccepted"
            Ok      = $false
            Message = ""
            Error   = $_.Exception.Message
        }
    }

    if ($null -eq $accepted -or [string]$accepted.type -ne "operation-accepted" -or
        -not ([string]$accepted.requestId -match '^\d+$') -or [long]$accepted.requestId -ne [long]$RequestId) {
        $reason = "the elevated broker did not accept the operation"

        if ($null -ne $accepted) {
            $detail = ""

            if ($null -ne $accepted.error -and -not [string]::IsNullOrWhiteSpace([string]$accepted.error)) {
                $detail = [string]$accepted.error
            }
            elseif ($null -ne $accepted.reason -and -not [string]::IsNullOrWhiteSpace([string]$accepted.reason)) {
                $detail = [string]$accepted.reason
            }

            $reason = ("$([string]$accepted.type)" + $(if ($detail) { ": $detail" } else { "" }))
        }

        Close-DevWSElevatedBrokerConnection -Connection $connection

        return [pscustomobject]@{
            Status  = "NotAccepted"
            Ok      = $false
            Message = ""
            Error   = $reason
        }
    }

    $final = Read-DevWSElevatedBrokerOperationFinal -Connection $connection -TimeoutMilliseconds $FinalTimeoutMilliseconds
    Close-DevWSElevatedBrokerConnection -Connection $connection

    if ($null -eq $final -or [string]$final.type -ne "operation-final") {
        return [pscustomobject]@{
            Status  = "AcceptedButUncertain"
            Ok      = $false
            Message = ""
            Error   = "the elevated broker did not report FINAL after acceptance"
        }
    }

    if (-not ([string]$final.requestId -match '^\d+$') -or [long]$final.requestId -ne [long]$RequestId) {
        return [pscustomobject]@{
            Status  = "AcceptedButUncertain"
            Ok      = $false
            Message = ""
            Error   = "the elevated broker FINAL did not match the request id"
        }
    }

    if ([bool]$final.ok) {
        return [pscustomobject]@{
            Status      = "AcceptedAndCompleted"
            Ok          = $true
            Message     = [string]$final.message
            Error       = ""
            Publication = [string]$final.publication
        }
    }

    $finalError = ""

    if ($null -ne $final.error) { $finalError = [string]$final.error }
    elseif ($null -ne $final.message) { $finalError = [string]$final.message }

    return [pscustomobject]@{
        Status      = "AcceptedAndCompleted"
        Ok          = $false
        Message     = $finalError
        Error       = ""
        Publication = [string]$final.publication
    }
}

function Test-DevWSElevatedBrokerAvailable {
    # One bounded ping. Transport failure means "not available"; it never
    # throws at the caller.
    param(
        [string]$PipeName = (Get-DevWSElevatedBrokerPipeName),
        [int]$TimeoutMilliseconds = 1500
    )

    $connection = $null

    try {
        $connection = New-DevWSElevatedBrokerConnection -PipeName $PipeName -TimeoutMilliseconds $TimeoutMilliseconds

        Send-DevWSBrokerRequestLine -Connection $connection -Request ([ordered]@{
            version = (Get-DevWSBrokerProtocolVersion)
            command = "ping"
        })

        $response = Read-DevWSBrokerResponseLine -Reader $connection.Reader -TimeoutMilliseconds $TimeoutMilliseconds

        return ([string]$response.type -eq "pong")
    }
    catch {
        return $false
    }
    finally {
        Close-DevWSElevatedBrokerConnection -Connection $connection
    }
}

function Get-DevWSElevatedBrokerStatus {
    # Read-only observational status. Unlike the launch-path ping, this uses
    # the dedicated `status` command so a stale host answers current=false and
    # STAYS RESIDENT. It never requests recovery and never starts a task.
    param(
        [string]$PipeName = (Get-DevWSElevatedBrokerPipeName),
        [int]$TimeoutMilliseconds = 1500
    )

    $connection = $null

    try {
        $connection = New-DevWSElevatedBrokerConnection -PipeName $PipeName -TimeoutMilliseconds $TimeoutMilliseconds
    }
    catch {
        return [pscustomobject]@{
            State             = "unavailable"
            Pid               = $null
            Generation        = $null
            CurrentGeneration = $null
            GenerationCurrent = $false
            Error             = $_.Exception.Message
        }
    }

    try {
        Send-DevWSBrokerRequestLine -Connection $connection -Request ([ordered]@{
            version = (Get-DevWSBrokerProtocolVersion)
            command = "status"
        })

        $response = Read-DevWSBrokerResponseLine -Reader $connection.Reader -TimeoutMilliseconds $TimeoutMilliseconds

        if ([int]$response.version -ne (Get-DevWSBrokerProtocolVersion) -or
            [string]$response.type -ne "status" -or
            [string]::IsNullOrWhiteSpace([string]$response.generation) -or
            [string]::IsNullOrWhiteSpace([string]$response.currentGeneration)) {
            return [pscustomobject]@{
                State             = "error"
                Pid               = $null
                Generation        = $null
                CurrentGeneration = $null
                GenerationCurrent = $false
                Error             = "unexpected broker status response"
            }
        }

        $current = [bool]$response.current

        return [pscustomobject]@{
            State             = if ($current) { "ready" } else { "stale" }
            Pid               = [int]$response.pid
            Generation        = [string]$response.generation
            CurrentGeneration = [string]$response.currentGeneration
            GenerationCurrent = $current
            Error             = $null
        }
    }
    catch {
        return [pscustomobject]@{
            State             = "error"
            Pid               = $null
            Generation        = $null
            CurrentGeneration = $null
            GenerationCurrent = $false
            Error             = $_.Exception.Message
        }
    }
    finally {
        Close-DevWSElevatedBrokerConnection -Connection $connection
    }
}

function Start-DevWSElevatedBrokerTask {
    # On-demand start through the managed task. Best effort: failures are
    # reported by the caller's subsequent bounded ping. The trusted system
    # executable is resolved under %SystemRoot%\System32 (never PATH); this
    # library is copied into the privileged runtime.
    $taskName = Get-DevWSElevatedBrokerTaskName

    try {
        $process = Start-Process -FilePath (Get-DevWSTrustedSystemExecutable -Name "schtasks.exe") -ArgumentList @("/run", "/tn", $taskName) -PassThru -WindowStyle Hidden
        $process.WaitForExit(15000) | Out-Null
    }
    catch { }
}

function Request-DevWSElevatedBrokerRecovery {
    # Bounded recovery used at coordinator startup and by the launch
    # transaction: ping, start the managed task once, then ping until the
    # timeout. Never blocks indefinitely.
    param(
        [int]$TimeoutSeconds = 20,
        [int]$PingTimeoutMilliseconds = 1500
    )

    if (Test-DevWSElevatedBrokerAvailable -TimeoutMilliseconds $PingTimeoutMilliseconds) {
        return $true
    }

    Start-DevWSElevatedBrokerTask

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500

        if (Test-DevWSElevatedBrokerAvailable -TimeoutMilliseconds $PingTimeoutMilliseconds) {
            return $true
        }
    }

    return $false
}
