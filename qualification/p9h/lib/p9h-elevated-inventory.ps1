# ============================================================================
# DevWS P9-H Stage 3B7G2 - Elevated (High-integrity) process inventory collector.
#
# WHY THIS EXISTS
# ---------------
# Stage 3B7G1 measured a real limitation: a MEDIUM-integrity inventory in the
# interactive session recovered command lines for 41/56 processes but returned an
# EMPTY command line for the product's own elevated processes (WindowsTerminal.exe,
# OpenConsole.exe and the broker's pwsh.exe). N2 process attribution requires argv
# identity (-SetId / -TerminalId / -WindowId), so attribution refused.
#
# This collector runs at HIGH integrity and recovers the metadata the Medium path
# cannot. It is STRICTLY READ-ONLY:
#   * it launches no product and no window;
#   * it moves, closes and re-parents nothing;
#   * it modifies no product configuration;
#   * it changes no process ownership or elevation.
#
# DIVISION OF RESPONSIBILITIES (deliberately preserved)
#   Medium    : launches the installed product and collects its lifecycle trace
#   High      : reads the process metadata needed for attribution   <-- this file
#   Interactive: collects real top-level HWNDs and window rectangles
#   Host      : orchestration and byte-preserving evidence retention
#
# PROVENANCE: every row records which account and integrity level produced it, so
# a High-sourced argv can never be confused with a Medium-sourced one.
# ============================================================================

function Get-P9HElevatedProcessInventory {
    # Read one process inventory WITH full provenance.
    #
    # Returns the SAME correlation fields the Medium inventory produces (pid, ppid,
    # name, sessionId, startUtc, commandLine) plus explicit provenance, so the two
    # inventories can be compared field-by-field and a missing value stays visible
    # as a missing value rather than being inferred.
    param(
        [int]$SessionId = -1,
        [switch]$All,
        # Limit the retained raw command line to processes of interest. Untrusted
        # command lines of unrelated processes are NOT retained: only the process
        # name/pid/session correlation is kept for them.
        [AllowEmptyCollection()][string[]]$RetainCommandLineForNames = @(),
        [switch]$RetainAllCommandLines
    )

    $identity = $null
    $integrity = $null
    try { $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { }
    try { $integrity = Get-P9HProcessIntegrity } catch { }

    $collectorSession = $null
    try { $collectorSession = [int](Get-Process -Id $PID).SessionId } catch { $collectorSession = $null }

    $rows = [System.Collections.Generic.List[object]]::new()
    $queryFailures = [System.Collections.Generic.List[string]]::new()
    $startOk = 0
    $startBad = 0
    $cmdOk = 0
    $cmdMissing = 0

    $procs = @()
    try {
        $procs = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    }
    catch {
        $queryFailures.Add('GetCimInstanceWin32Process:' + $_.Exception.Message) | Out-Null
    }

    foreach ($p in $procs) {
        $procSession = -1
        try { $procSession = [int]$p.SessionId } catch { $procSession = -1 }

        if (-not $All -and $SessionId -ge 0 -and $procSession -ne $SessionId) { continue }

        $converted = ConvertTo-P9HProcessStartUtc -Value $p.CreationDate
        if ($converted.Ok) { $startOk++ } else { $startBad++ }

        $rawCmd = ''
        try { $rawCmd = [string]$p.CommandLine } catch { $rawCmd = '' }
        if ([string]::IsNullOrWhiteSpace($rawCmd)) { $cmdMissing++ } else { $cmdOk++ }

        $name = [string]$p.Name
        $retain = ($RetainAllCommandLines -or ($RetainCommandLineForNames -contains $name))
        if (-not $retain -and -not [string]::IsNullOrWhiteSpace($rawCmd)) {
            # Keep the LENGTH (proves a value existed) but redact the payload.
            $rawCmd = '<redacted:not-retained>'
        }

        $rows.Add([pscustomobject][ordered]@{
                # ---- correlation fields, identical in shape to the Medium path ----
                pid            = [int]$p.ProcessId
                ppid           = [int]$p.ParentProcessId
                name           = $name
                sessionId      = $procSession
                startUtc       = if ($converted.Ok) { $converted.Utc.ToString('o') } else { $null }
                startSource    = [string]$converted.Reason
                commandLine    = $rawCmd
                commandLength  = ([string]$p.CommandLine).Length
                commandRetained = $retain
                # ---- provenance: WHO and FROM WHERE ----
                collectedByUser      = [string]$identity
                collectedByIntegrity = if ($null -ne $integrity) { [string]$integrity.Label } else { 'unknown' }
                collectedByPid       = $PID
                collectedBySession   = $collectorSession
                querySucceeded       = $true
                querySource          = 'Get-CimInstance Win32_Process'
            }) | Out-Null
    }

    $outcome = 'ok'
    $reason = $null
    if ($rows.Count -eq 0) { $outcome = 'empty'; $reason = 'no-processes-matched' }
    elseif ($startOk -eq 0) { $outcome = 'degraded'; $reason = 'no-process-start-times-recovered' }
    elseif ($startBad -gt 0) { $outcome = 'partial'; $reason = 'some-process-start-times-unrecoverable' }

    return [pscustomobject][ordered]@{
        schema            = 'p9h.elevated-process-inventory.v1'
        capturedUtc       = Get-P9HUtcStamp
        Ok                = ($outcome -eq 'ok' -or $outcome -eq 'partial')
        Outcome           = $outcome
        Reason            = $reason
        RequestedSessionId = $SessionId
        AllSessions       = [bool]$All
        # ---- provenance of the COLLECTOR itself ----
        CollectorUser     = [string]$identity
        CollectorIntegrity = if ($null -ne $integrity) { [string]$integrity.Label } else { 'unknown' }
        CollectorPid      = $PID
        CollectorSession  = $collectorSession
        CollectorComputer = [string]$env:COMPUTERNAME
        QueryFailures     = @($queryFailures)
        Count             = $rows.Count
        StartOk           = $startOk
        StartBad          = $startBad
        CommandLinePresent = $cmdOk
        CommandLineMissing = $cmdMissing
        RetainedCommandLineNames = @($RetainCommandLineForNames)
        Processes         = @($rows)
    }
}

function ConvertTo-P9HAttributionInventory {
    # Project a High-integrity inventory into the EXACT row shape
    # Get-P9HLaunchAttribution consumes, WITHOUT inventing any value.
    #
    # This is the transparent derivation the N2 evidence package records: the
    # authoritative new-processes artifact is built from REAL measurements by
    # selecting rows that (a) exist only in the post inventory, (b) belong to the
    # intended session, and (c) carry a retained raw command line.
    #
    # A row whose command line was not retained is NOT silently dropped from the
    # accounting - it is reported in SkippedNoCommandLine so the caller can see
    # exactly how many candidates were excluded and why.
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After,
        [int]$SessionId = -1
    )

    $beforeIndex = @{}
    foreach ($p in @($Before.Processes)) { $beforeIndex[[int]$p.pid] = $p }

    $added = [System.Collections.Generic.List[object]]::new()
    $skippedNoCmd = [System.Collections.Generic.List[int]]::new()
    $skippedSession = [System.Collections.Generic.List[int]]::new()

    foreach ($p in @($After.Processes)) {
        $id = [int]$p.pid
        if ($beforeIndex.ContainsKey($id)) { continue }

        if ($SessionId -ge 0 -and [int]$p.sessionId -ne $SessionId) {
            $skippedSession.Add($id) | Out-Null
            continue
        }

        if ([string]::IsNullOrWhiteSpace([string]$p.commandLine) -or
            [string]$p.commandLine -eq '<redacted:not-retained>') {
            $skippedNoCmd.Add($id) | Out-Null
            continue
        }

        $added.Add([pscustomobject][ordered]@{
                pid            = [int]$p.pid
                ppid           = [int]$p.ppid
                name           = [string]$p.name
                sessionId      = [int]$p.sessionId
                startUtc       = [string]$p.startUtc
                startSource    = [string]$p.startSource
                commandLine    = [string]$p.commandLine
                commandLength  = [int]$p.commandLength
                # Provenance travels with the row so the verdict's input is auditable.
                # Read defensively: a row produced by a non-elevated collector has
                # no such field and must not throw during derivation.
                collectedByIntegrity = if ($null -ne $p.PSObject.Properties['collectedByIntegrity']) { [string]$p.collectedByIntegrity } else { $null }
                collectedByUser      = if ($null -ne $p.PSObject.Properties['collectedByUser']) { [string]$p.collectedByUser } else { $null }
            }) | Out-Null
    }

    return [pscustomobject][ordered]@{
        schema           = 'p9h.n2.new-processes.v1'
        capturedUtc      = Get-P9HUtcStamp
        derivation       = 'high-integrity post-minus-pre inventory, session-filtered, command-line-retained rows only'
        beforeCount      = @($Before.Processes).Count
        afterCount       = @($After.Processes).Count
        beforeIntegrity  = [string]$Before.CollectorIntegrity
        afterIntegrity   = [string]$After.CollectorIntegrity
        sessionId        = $SessionId
        AddedCount       = $added.Count
        RemovedCount     = 0
        Added            = @($added.ToArray())
        Removed          = @()
        AddedWithStart   = @($added | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.startUtc) }).Count
        SkippedNoCommandLine = @($skippedNoCmd.ToArray())
        SkippedOtherSession  = @($skippedSession.ToArray())
    }
}
