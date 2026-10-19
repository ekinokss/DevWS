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
