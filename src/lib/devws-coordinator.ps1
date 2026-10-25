# DevWS Stage 1 warm normal coordinator: constants, protocol validation,
# deployment-generation freshness and the launch command entry point.
#
# The coordinator process itself lives in src\coordinator\coordinator.ps1; this
# library keeps every policy/validation piece unit-testable without a live
# pipe. The wire protocol is deliberately tiny and strictly validated:
#
#   { "version": 1, "command": "ping" }
#   { "version": 1, "command": "launch" }
#   { "version": 1, "command": "launch", "setId": "main" }
#   { "version": 1, "command": "shutdown" }
#
# No arbitrary script execution, no active-workspace state, no polling.

function Get-DevWSCoordinatorPipeName {
    # Stable local named pipe; current-user-only at the server end.
    return "DevWS.Coordinator.v1"
}

function Get-DevWSCoordinatorMutexName {
    # Local-session singleton mutex (same convention as the lifecycle lock).
    return "Local\DevWS.Coordinator.v1.Instance"
}

function Get-DevWSCoordinatorProtocolVersion {
    return 1
}

function Get-DevWSCoordinatorMaxLineLength {
    # A launch request is ~45 bytes; 4 KiB is a generous strict ceiling.
    return 4096
}

function Get-DevWSRuntimeGeneration {
    # Cheap deterministic generation over every source-managed runtime area of
    # the install (app\*, helpers\*, workers\*, bin\*; never state). Recomputed
    # before each coordinator command: a changed generation means the deployed
    # code was updated under the running process and requires a restart.
    param(
        [Parameter(Mandatory)]
        [string]$InstallRoot
    )

    $parts = [System.Collections.Generic.List[string]]::new()

    foreach ($relative in @("app", "helpers", "workers", "bin")) {
        $root = Join-Path $InstallRoot $relative

        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName)) {
            $relativePath = $file.FullName.Substring($InstallRoot.Length).TrimStart('\')

            $parts.Add(("{0}|{1}|{2}" -f $relativePath.ToLowerInvariant(), $file.Length, $file.LastWriteTimeUtc.Ticks))
        }
    }

    $text = $parts -join "`n"
    $sha  = [System.Security.Cryptography.SHA256]::Create()

    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)))).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}

function Get-DevWSPrivilegedRuntimeGeneration {
    # Cheap deterministic generation over the administrator-protected
    # privileged runtime (relative path, length, mtime of every file). Used
    # for restart detection only: a changed privileged runtime means the High
    # hosts must restart. This is NOT an authenticity/security mechanism: the
    # value is derived state and is never treated as a trust signal.
    param(
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = Get-DevWSPrivilegedInstallRoot
    }

    $parts = [System.Collections.Generic.List[string]]::new()

    if (Test-Path -LiteralPath $Root -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName)) {
            $relativePath = $file.FullName.Substring($Root.Length).TrimStart('\')
            $parts.Add(("{0}|{1}|{2}" -f $relativePath.ToLowerInvariant(), $file.Length, $file.LastWriteTimeUtc.Ticks))
        }
    }

    $text = $parts -join "`n"
    $sha  = [System.Security.Cryptography.SHA256]::Create()

    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)))).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}

function Get-DevWSEffectiveRuntimeGeneration {
    # Combined restart-detection generation: the normal runtime under the
    # install root plus the administrator-protected privileged runtime. A
    # change in either area requires a restart of the hosts that consume it.
    # Restart detection only - never an authenticity signal.
    param(
        [Parameter(Mandatory)]
        [string]$InstallRoot,
        [string]$PrivilegedRoot
    )

    $normal     = Get-DevWSRuntimeGeneration -InstallRoot $InstallRoot
    $privileged = Get-DevWSPrivilegedRuntimeGeneration -Root $PrivilegedRoot
    $text       = "normal:$normal;privileged:$privileged"
    $sha        = [System.Security.Cryptography.SHA256]::Create()

    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)))).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}

function Test-DevWSCoordinatorRequest {
    # Strict validation of one JSON request line. Returns Ok/Error plus the
    # normalized request (command + optional setId). Unknown fields, wrong
    # versions, unknown commands, non-string/empty set ids and oversized lines
    # are all rejected before any policy code runs.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Line,
        [int]$MaxLength = (Get-DevWSCoordinatorMaxLineLength)
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
        if (@("version", "command", "setId") -notcontains [string]$property.Name) {
            return [pscustomobject]@{ Ok = $false; Error = "unsupported request field '$($property.Name)'"; Request = $null }
        }
    }

    $versionProperty = $parsed.PSObject.Properties["version"]

    if ($null -eq $versionProperty -or -not (Test-DevWSInteger $versionProperty.Value) -or
        [int]$versionProperty.Value -ne (Get-DevWSCoordinatorProtocolVersion)) {
        return [pscustomobject]@{ Ok = $false; Error = "unsupported protocol version (expected $(Get-DevWSCoordinatorProtocolVersion))"; Request = $null }
    }

    $commandProperty = $parsed.PSObject.Properties["command"]
    $command         = if ($null -ne $commandProperty) { [string]$commandProperty.Value } else { "" }

    if ($command -notin @("ping", "status", "launch", "shutdown")) {
        return [pscustomobject]@{ Ok = $false; Error = "unsupported command '$command'"; Request = $null }
    }

    $setId = $null
    $setIdProperty = $parsed.PSObject.Properties["setId"]

    if ($null -ne $setIdProperty -and $null -ne $setIdProperty.Value) {
        if ($setIdProperty.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$setIdProperty.Value) -or
            ([string]$setIdProperty.Value).Length -gt 200) {
            return [pscustomobject]@{ Ok = $false; Error = "setId must be a non-empty string"; Request = $null }
        }

        $setId = [string]$setIdProperty.Value
    }

    return [pscustomobject]@{
        Ok      = $true
        Error   = $null
        Request = [pscustomobject]@{ Command = $command; SetId = $setId }
    }
}

function Get-DevWSCoordinatorStatus {
    # Read-only observational status for the warm coordinator. Uses the
    # dedicated `status` command so a stale coordinator answers current=false
    # and STAYS RESIDENT. Bounded connect + bounded read; never starts,
    # recovers, or otherwise touches the coordinator.
    param(
        [string]$PipeName = (Get-DevWSCoordinatorPipeName),
        [int]$TimeoutMilliseconds = 1500
    )

    $client = $null

    try {
        $client = [System.IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $client.Connect($TimeoutMilliseconds)
    }
    catch {
        if ($null -ne $client) { $client.Dispose() }
        return [pscustomobject]@{
            State             = "unavailable"
            Pid               = $null
            Generation        = $null
            CurrentGeneration = $null
            GenerationCurrent = $false
            UptimeSeconds     = $null
            Error             = $_.Exception.Message
        }
    }

    try {
        $encoding = [System.Text.UTF8Encoding]::new($false)
        $writer = [System.IO.StreamWriter]::new($client, $encoding, 4096, $true)
        $writer.AutoFlush = $true
        $reader = [System.IO.StreamReader]::new($client, $encoding, $false, 4096, $true)

        $writer.WriteLine('{"version":1,"command":"status"}')
        $writer.Flush()

        $readTask = $reader.ReadLineAsync()

        if (-not $readTask.Wait($TimeoutMilliseconds)) {
            return [pscustomobject]@{
                State             = "error"
                Pid               = $null
                Generation        = $null
                CurrentGeneration = $null
                GenerationCurrent = $false
                UptimeSeconds     = $null
                Error             = "coordinator did not answer within $TimeoutMilliseconds ms"
            }
        }

        $line = [string]$readTask.Result

        if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -gt (Get-DevWSCoordinatorMaxLineLength)) {
            return [pscustomobject]@{
                State = "error"; Pid = $null; Generation = $null; CurrentGeneration = $null
                GenerationCurrent = $false; UptimeSeconds = $null; Error = "malformed coordinator status response"
            }
        }

        try {
            $parsed = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            return [pscustomobject]@{
                State = "error"; Pid = $null; Generation = $null; CurrentGeneration = $null
                GenerationCurrent = $false; UptimeSeconds = $null; Error = "malformed coordinator status response"
            }
        }

        if ($parsed -isnot [System.Management.Automation.PSCustomObject] -or
            -not (Test-DevWSInteger $parsed.version) -or [int]$parsed.version -ne (Get-DevWSCoordinatorProtocolVersion) -or
            $parsed.ok -ne $true -or [string]$parsed.command -ne "status" -or
            [string]::IsNullOrWhiteSpace([string]$parsed.generation) -or
            [string]::IsNullOrWhiteSpace([string]$parsed.currentGeneration)) {
            return [pscustomobject]@{
                State = "error"; Pid = $null; Generation = $null; CurrentGeneration = $null
                GenerationCurrent = $false; UptimeSeconds = $null; Error = "unexpected coordinator status response"
            }
        }

        $current = [bool]$parsed.current

        return [pscustomobject]@{
            State             = if ($current) { "ready" } else { "stale" }
            Pid               = [int]$parsed.pid
            Generation        = [string]$parsed.generation
            CurrentGeneration = [string]$parsed.currentGeneration
            GenerationCurrent = $current
            UptimeSeconds     = $parsed.uptimeSec
            Error             = $null
        }
    }
    catch {
        return [pscustomobject]@{
            State = "error"; Pid = $null; Generation = $null; CurrentGeneration = $null
            GenerationCurrent = $false; UptimeSeconds = $null; Error = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $client) { $client.Dispose() }
    }
}

function Get-DevWSCoordinatorProcessRecords {
    # Exact coordinator process inventory for the current user. A candidate is
    # a pwsh process whose actual executed script is the installed
    # app\coordinator.ps1; a coordinator path appearing only as an argument or
    # command text is not a candidate. The owner SID must match the invoking
    # user, and the record carries the exact kernel creation time used later for
    # handle-bound termination.
    param(
        [string]$InstallRoot = "",
        [string]$UserSid = ""
    )

    if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        $InstallRoot = Get-DevWSInstallRoot
    }

    if ($null -eq (Get-Command Get-DevWSExecutedScriptProcessRecords -ErrorAction SilentlyContinue)) {
        throw 'The executed-script process inventory is unavailable; load devws-install.ps1 before the coordinator lifecycle helpers.'
    }

    $coordinatorPath = Join-Path $InstallRoot "app\coordinator.ps1"

    return @(Get-DevWSExecutedScriptProcessRecords `
        -ImageNames @('pwsh.exe') `
        -Kind 'PowerShell' `
        -ExpectedScriptPath $coordinatorPath `
        -UserSid $UserSid)
}

function Get-DevWSCoordinatorPipeServerProcessId {
    # Kernel-reported server PID from the connected pipe handle. No request
    # bytes have been sent when this is called.
    param([Parameter(Mandatory)]$Client)

    Initialize-DevWSProcessIdentityNative

    try {
        $handle = $Client.SafePipeHandle

        if ($null -eq $handle -or $handle.IsInvalid) {
            return $null
        }

        [uint32]$serverPid = 0

        if ([DevWSProcessIdentityNative]::GetNamedPipeServerProcessId($handle.DangerousGetHandle(), [ref]$serverPid) -and $serverPid -ne 0) {
            return [int]$serverPid
        }
    }
    catch {
        # Treat an unreadable server identity as unverifiable; never send a
        # shutdown request to an unidentified server.
    }

    return $null
}

function Wait-DevWSCoordinatorProcessesGone {
    param(
        [string]$InstallRoot = "",
        [int]$TimeoutMilliseconds = 5000
    )

    $deadline = [datetime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)

    while ($true) {
        $records = @(Get-DevWSCoordinatorProcessRecords -InstallRoot $InstallRoot)

        if ($records.Count -eq 0) {
            return $true
        }

        if ([datetime]::UtcNow -ge $deadline) {
            return $false
        }

        Start-Sleep -Milliseconds 100
    }
}

function Invoke-DevWSCoordinatorShutdown {
    # Bounded graceful shutdown through the existing current-user-only pipe.
    # Returns a structured state; it never kills a process itself.
    param(
        [string]$PipeName = (Get-DevWSCoordinatorPipeName),
        [string]$InstallRoot = "",
        [int]$ConnectTimeoutMilliseconds = 1500,
        [int]$ResponseTimeoutMilliseconds = 3000,
        [int]$ExitTimeoutMilliseconds = 5000
    )

    if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        $InstallRoot = Get-DevWSInstallRoot
    }

    $known = @(Get-DevWSCoordinatorProcessRecords -InstallRoot $InstallRoot)
    $unverified = @($known | Where-Object { -not [bool]$_.Verified })
    $verified   = @($known | Where-Object { [bool]$_.Verified })
    $knownPids  = @($known | ForEach-Object { $_.Pid })

    if ($unverified.Count -gt 0) {
        return [pscustomobject]@{
            State  = "unverified"
            Pid    = $null
            Pids   = $knownPids
            Error  = "a coordinator process could not be ownership-verified"
            Detail = (@($unverified | ForEach-Object { "PID $($_.Pid): $($_.IdentityError)" }) -join "; ")
        }
    }

    if ($verified.Count -eq 0) {
        # No verified coordinator process: do not contact the pipe at all. A
        # same-user process merely owning the expected pipe name is unrelated.
        return [pscustomobject]@{
            State  = "absent"
            Pid    = $null
            Pids   = @()
            Error  = $null
            Detail = "no verified DevWS coordinator process is running"
        }
    }

    $client = $null

    try {
        $client = [System.IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        $client.Connect($ConnectTimeoutMilliseconds)
    }
    catch {
        $connectError = $_.Exception.Message
        if ($null -ne $client) { $client.Dispose() }

        $after = @(Get-DevWSCoordinatorProcessRecords -InstallRoot $InstallRoot)

        if ($after.Count -eq 0) {
            return [pscustomobject]@{
                State  = "stopped"
                Pid    = $null
                Pids   = $knownPids
                Error  = $null
                Detail = "verified coordinator exited before the pipe could be contacted"
            }
        }

        return [pscustomobject]@{
            State  = "unavailable"
            Pid    = $null
            Pids   = $knownPids
            Error  = $connectError
            Detail = "a verified coordinator process exists but the current-user pipe could not be contacted"
        }
    }

    $writer = $null
    $reader = $null

    try {
        # Bind the pipe server to a verified coordinator process BEFORE sending
        # any request. The kernel-reported server PID must be one of the
        # verified records and its handle identity must still match; otherwise
        # the connection is closed without writing a shutdown frame.
        $serverPid = Get-DevWSCoordinatorPipeServerProcessId -Client $client

        if ($null -eq $serverPid) {
            return [pscustomobject]@{
                State  = "unverified-pipe-server"
                Pid    = $null
                Pids   = $knownPids
                Error  = "the named-pipe server process id is unavailable"
                Detail = "no shutdown was sent"
            }
        }

        $serverRecord = @($verified | Where-Object { [int]$_.Pid -eq [int]$serverPid })[0]

        if ($null -eq $serverRecord) {
            return [pscustomobject]@{
                State  = "unverified-pipe-server"
                Pid    = [int]$serverPid
                Pids   = $knownPids
                Error  = "the named-pipe server is not a verified coordinator process"
                Detail = "no shutdown was sent"
            }
        }

        $serverCheck = Invoke-DevWSProcessIdentityAction `
            -Record $serverRecord `
            -ImageNames @('pwsh.exe') `
            -Kind 'PowerShell' `
            -ExpectedScriptPath (Join-Path $InstallRoot "app\coordinator.ps1") `
            -UserSid (Get-DevWSCurrentUserSid)

        if ($serverCheck.State -ne "verified") {
            return [pscustomobject]@{
                State  = "unverified-pipe-server"
                Pid    = [int]$serverPid
                Pids   = $knownPids
                Error  = "the named-pipe server identity is not current ($($serverCheck.State): $($serverCheck.Error))"
                Detail = "no shutdown was sent"
            }
        }

        $encoding = [System.Text.UTF8Encoding]::new($false)
        $writer = [System.IO.StreamWriter]::new($client, $encoding, 4096, $true)
        $writer.AutoFlush = $true
        $reader = [System.IO.StreamReader]::new($client, $encoding, $false, 4096, $true)

        $writer.WriteLine('{"version":1,"command":"shutdown"}')
        $writer.Flush()

        $readTask = $reader.ReadLineAsync()

        if (-not $readTask.Wait($ResponseTimeoutMilliseconds)) {
            return [pscustomobject]@{
                State  = "unresponsive"
                Pid    = $null
                Pids   = $knownPids
                Error  = "coordinator did not answer within $ResponseTimeoutMilliseconds ms"
                Detail = "shutdown request sent but no bounded response was received"
            }
        }

        $line = [string]$readTask.Result

        if ([string]::IsNullOrWhiteSpace($line)) {
            return [pscustomobject]@{
                State  = "unresponsive"
                Pid    = $null
                Pids   = $knownPids
                Error  = "coordinator returned an empty shutdown response"
                Detail = "shutdown response was empty"
            }
        }

        $parsed = $null

        try {
            $parsed = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            return [pscustomobject]@{
                State  = "unresponsive"
                Pid    = $null
                Pids   = $knownPids
                Error  = "coordinator returned a malformed shutdown response"
                Detail = $line
            }
        }

        $isAck = ($parsed -is [System.Management.Automation.PSCustomObject]) -and
            [int]$parsed.version -eq (Get-DevWSCoordinatorProtocolVersion) -and
            [bool]$parsed.ok -eq $true -and
            [string]$parsed.command -eq "shutdown"
        $isStaleExit = ($parsed -is [System.Management.Automation.PSCustomObject]) -and
            [int]$parsed.version -eq (Get-DevWSCoordinatorProtocolVersion) -and
            [bool]$parsed.ok -eq $false -and
            [string]$parsed.error -eq "restart-required"

        if (-not $isAck -and -not $isStaleExit) {
            return [pscustomobject]@{
                State  = "unresponsive"
                Pid    = $null
                Pids   = $knownPids
                Error  = "coordinator did not acknowledge shutdown"
                Detail = $line
            }
        }

        $responsePid = $null

        if ($null -ne $parsed.PSObject.Properties["pid"]) {
            try { $responsePid = [int]$parsed.pid } catch { $responsePid = $null }
        }

        if ($isAck -and ($null -eq $responsePid -or [int]$responsePid -ne [int]$serverPid)) {
            return [pscustomobject]@{
                State  = "unresponsive"
                Pid    = $responsePid
                Pids   = $knownPids
                Error  = "the shutdown acknowledgement is not bound to the verified pipe server PID"
                Detail = $line
            }
        }

        $gone = Wait-DevWSCoordinatorProcessesGone -InstallRoot $InstallRoot -TimeoutMilliseconds $ExitTimeoutMilliseconds

        if ($gone) {
            return [pscustomobject]@{
                State  = "stopped"
                Pid    = [int]$serverPid
                Pids   = $knownPids
                Error  = $null
                Detail = if ($isStaleExit) { "stale coordinator exited after restart-required" } else { "shutdown acknowledged by the verified pipe server and exact process exited" }
            }
        }

        return [pscustomobject]@{
            State  = "still-running"
            Pid    = [int]$serverPid
            Pids   = $knownPids
            Error  = "coordinator acknowledged shutdown but the exact process is still running"
            Detail = "bounded exit wait expired"
        }
    }
    catch {
        return [pscustomobject]@{
            State  = "unresponsive"
            Pid    = $null
            Pids   = $knownPids
            Error  = $_.Exception.Message
            Detail = "shutdown exchange failed"
        }
    }
    finally {
        try { if ($reader) { $reader.Dispose() } } catch { }
        try { if ($writer) { $writer.Dispose() } } catch { }
        try { if ($client) { $client.Dispose() } } catch { }
    }
}

function Stop-DevWSCoordinator {
    # Graceful shutdown first. A bounded fallback may terminate only processes
    # whose actual executed script is the installed coordinator, whose image
    # and owner SID match, and whose exact creation time still matches the
    # enumerated record. Termination uses the verified handle, never a bare PID.
    param(
        [string]$PipeName = (Get-DevWSCoordinatorPipeName),
        [string]$InstallRoot = "",
        [int]$ConnectTimeoutMilliseconds = 1500,
        [int]$ResponseTimeoutMilliseconds = 3000,
        [int]$ExitTimeoutMilliseconds = 5000
    )

    $graceful = Invoke-DevWSCoordinatorShutdown `
        -PipeName $PipeName `
        -InstallRoot $InstallRoot `
        -ConnectTimeoutMilliseconds $ConnectTimeoutMilliseconds `
        -ResponseTimeoutMilliseconds $ResponseTimeoutMilliseconds `
        -ExitTimeoutMilliseconds $ExitTimeoutMilliseconds

    if ($graceful.State -in @("stopped", "absent")) {
        return $graceful
    }

    $records = @(Get-DevWSCoordinatorProcessRecords -InstallRoot $InstallRoot)
    $unverified = @($records | Where-Object { -not [bool]$_.Verified })
    $verified   = @($records | Where-Object { [bool]$_.Verified })
    $pids       = @(
        (@($graceful.Pids) + @($records | ForEach-Object { $_.Pid })) | Sort-Object -Unique
    )

    if ($unverified.Count -gt 0) {
        return [pscustomobject]@{
            State  = "unverified"
            Pid    = $null
            Pids   = $pids
            Error  = (@($unverified | ForEach-Object { "PID $($_.Pid): $($_.IdentityError)" }) -join "; ")
            Detail = $graceful.Detail
        }
    }

    if ($verified.Count -eq 0) {
        return [pscustomobject]@{
            State  = "stopped"
            Pid    = $null
            Pids   = $pids
            Error  = $null
            Detail = "verified coordinator process exited before fallback"
        }
    }

    $userSid = Get-DevWSCurrentUserSid
    $target  = Join-Path $InstallRoot "app\coordinator.ps1"
    $stopErrors = [System.Collections.Generic.List[string]]::new()
    $stoppedPids = [System.Collections.Generic.List[int]]::new()

    foreach ($record in $verified) {
        $action = Invoke-DevWSProcessIdentityAction `
            -Record $record `
            -ImageNames @('pwsh.exe') `
            -Kind 'PowerShell' `
            -ExpectedScriptPath $target `
            -UserSid $userSid `
            -Terminate `
            -TimeoutMilliseconds $ExitTimeoutMilliseconds

        if ($action.State -eq "stopped") {
            $stoppedPids.Add([int]$record.Pid) | Out-Null
        }
        elseif ($action.State -ne "gone") {
            $stopErrors.Add("PID $($record.Pid): $($action.State) ($($action.Error))") | Out-Null
        }
    }

    $gone = Wait-DevWSCoordinatorProcessesGone -InstallRoot $InstallRoot -TimeoutMilliseconds $ExitTimeoutMilliseconds

    if ($gone) {
        $fallbackPid = if ($stoppedPids.Count -gt 0) { $stoppedPids[0] } else { [int]$verified[0].Pid }

        return [pscustomobject]@{
            State  = "stopped-fallback"
            Pid    = $fallbackPid
            Pids   = $pids
            Error  = if ($stopErrors.Count -gt 0) { ($stopErrors -join "; ") } else { $null }
            Detail = "handle-verified exact coordinator process stopped after graceful shutdown did not complete"
        }
    }

    return [pscustomobject]@{
        State  = "failed"
        Pid    = $null
        Pids   = $pids
        Error  = if ($stopErrors.Count -gt 0) { ($stopErrors -join "; ") } else { $graceful.Error }
        Detail = "a known DevWS coordinator remains running"
    }
}

function Invoke-DevWSCoordinatorLaunch {
    # Execute one validated launch request through the same canonical
    # transaction the cold CLI uses. -LayoutPlan is the frozen lifecycle
    # placement decision computed BEFORE the accepted ACK; the transaction
    # validates and consumes it without re-sampling topology. Errors are
    # returned as a structured failure, never thrown at the pipe loop.
    param(
        [Parameter(Mandatory)]
        $Config,
        [string]$SetId,
        [AllowNull()]
        $LayoutPlan = $null
    )

    try {
        $result = Invoke-DevWSLaunchTransaction -Config $Config -SetId $SetId -LayoutPlan $LayoutPlan

        return [ordered]@{
            ok             = $true
            command        = "launch"
            status         = "completed"
            setId          = $result.SetId
            noEnabledItems = [bool]$result.NoEnabledItems
            layoutSource   = [string]$result.LayoutSource
            profileId      = if ($null -ne $result.ProfileId) { [string]$result.ProfileId } else { $null }
            layoutWarnings = @($result.LayoutWarnings)
        }
    }
    catch {
        return [ordered]@{
            ok      = $false
            command = "launch"
            status  = "failed"
            message = $_.Exception.Message
        }
    }
}
