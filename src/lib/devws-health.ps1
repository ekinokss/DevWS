# DevWS health check.
#
# Non-destructive by design: it only reads files, PATH/task state, and runs
# the read-only `ws list` command against the installed app. It never launches
# the workspace, moves windows, resets terminals, or closes anything.
#
# All checks take an explicit context so automated tests can run the whole
# aggregation against temp fixtures without touching the live machine.

function New-DevWSHealthCheckResult {
    param(
        [Parameter(Mandatory)]
        [string]$Id,
        [Parameter(Mandatory)]
        [string]$Description,
        [Parameter(Mandatory)]
        [bool]$Ok,
        [string]$Message = ""
    )

    return [pscustomobject]@{
        Id          = $Id
        Description = $Description
        Ok          = $Ok
        Message     = $Message
    }
}

function Get-DevWSHealthSummary {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    $failed = @($Results | Where-Object { -not $_.Ok })
    $passed = @($Results | Where-Object { $_.Ok })

    return [pscustomobject]@{
        Ok        = ($failed.Count -eq 0)
        Passed    = $passed.Count
        Failed    = $failed.Count
        FailedIds = @($failed | ForEach-Object { $_.Id })
        Results   = @($Results)
    }
}

function Get-DevWSHealthRecordedPowerShellPath {
    # The absolute trusted PowerShell path recorded by the installer in the
    # additive Security Phase 1 metadata. Empty for legacy metadata or when
    # the installer library is not loaded in this host.
    try {
        if (Get-Command Read-DevWSInstallMetadata -ErrorAction SilentlyContinue) {
            $metadata = Read-DevWSInstallMetadata -Path (Get-DevWSInstallMetadataPath)
            return [string]$metadata.privileged.powerShellPath
        }
    }
    catch {
        return ""
    }

    return ""
}

function Get-DevWSHealthContext {
    # Windows Terminal: resolve the trusted launcher now. Installed hosts
    # require the genuine package executable; a failed resolution is carried
    # into the check as an explicit failure message while the display path
    # falls back to the user alias. Repository hosts keep the existence-only
    # semantics (no WindowsApps trust roots).
    $trustedWtPath  = $null
    $trustedWtError = $null

    try {
        $trustedWtPath = Resolve-DevWSTrustedWindowsTerminalPath
    }
    catch {
        $trustedWtError = $_.Exception.Message
    }

    return [pscustomobject]@{
        InstallRoot          = Get-DevWSInstallRoot
        StateRoot            = Get-DevWSStateRoot
        CanonicalPath        = Get-DevWSCanonicalConfigPath
        StartupPath          = Get-DevWSStartupPath
        LegacyShimPath       = Get-DevWSLegacyShimPath
        WindowsTerminalPath  = $(if ($null -ne $trustedWtPath) { $trustedWtPath } else { Get-DevWSWindowsTerminalPath })
        WindowsTerminalTrustRoots = $(if ((Get-DevWSPathsLayout) -eq "repository") { @() } else { @(Get-DevWSTrustedWindowsTerminalRoots) })
        WindowsTerminalTrustError = $trustedWtError
        AutoHotkeyPath       = Get-DevWSAutoHotkeyPath
        MetadataPath         = Get-DevWSInstallMetadataPath
        PrivilegedRoot       = Get-DevWSPrivilegedInstallRoot
        PrivilegedStateRoot  = $(if ((Get-DevWSPathsLayout) -eq "repository") { $null } else { (Get-DevWSPrivilegedStateRoot) })
        PrivilegedPowerShellPath = (Get-DevWSHealthRecordedPowerShellPath)
    }
}

function Get-DevWSHealthScheduledTaskIndex {
    # One unfiltered query per health run, shared by the three task checks.
    # Named Get-ScheduledTask lookups are pathologically slow on real machines
    # (measured ~0.9 s per call because the cmdlet filters a full enumeration
    # client-side), while the whole task set is returned in well under a second.
    $index = @{}

    foreach ($task in @(Get-ScheduledTask -ErrorAction Stop)) {
        $name = [string]$task.TaskName

        if (-not $index.ContainsKey($name) -or [string]$task.TaskPath -eq "\") {
            $index[$name] = $task
        }
    }

    return $index
}

function Write-DevWSHealthReport {
    param(
        [Parameter(Mandatory)]
        $Summary
    )

    foreach ($result in @($Summary.Results)) {
        $marker = "[ok]  "

        if (-not $result.Ok) {
            $marker = "[FAIL]"
        }

        Write-Host ("  {0} {1}: {2}" -f $marker, $result.Description, $result.Message)
    }

    Write-Host ""

    if ($Summary.Ok) {
        Write-Host "Health check PASSED ($($Summary.Passed) checks)." -ForegroundColor Green
    }
    else {
        Write-Host "Health check FAILED: $($Summary.Failed) of $($Summary.Passed + $Summary.Failed) checks failed ($($Summary.FailedIds -join ', '))." -ForegroundColor Red
    }
}

function Read-DevWSHealthChildStreamsToExit {
    # Public Security Phase 2-E: drains a redirected child's stdout/stderr
    # while waiting for it to exit within the caller's timeout, so no
    # temporary redirect files are ever created. Reads are interleaved
    # (a flooding child can never deadlock on a full pipe buffer) and every
    # byte is discarded - the check itself only needs the exit code.
    #
    # Outcome model (process-lifecycle contract gate): the DIRECT CHILD's
    # exit timing decides the wait outcome, never the post-exit drain.
    #   - child exits at or before the deadline (its actual ExitTime is
    #     compared against the deadline) -> $true; any remaining pipe writers
    #     (e.g. a descendant holding the inherited handles) are drained for a
    #     finite grace period that can never turn the timely exit into a
    #     timeout;
    #   - child still running at the deadline (or exiting only after it) ->
    #     $false; the caller terminates it within its own bound and a timeout
    #     is never reported as success.
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )

    $deadlineWall = [DateTime]::Now.AddMilliseconds($TimeoutMilliseconds)
    $deadlineTick = [Environment]::TickCount64 + $TimeoutMilliseconds
    $exitGraceMs  = 500

    $states = @(
        [pscustomobject]@{ Stream = $Process.StandardOutput.BaseStream; Task = $null; Buffer = [byte[]]::new(8192) },
        [pscustomobject]@{ Stream = $Process.StandardError.BaseStream;  Task = $null; Buffer = [byte[]]::new(8192) }
    )

    foreach ($state in $states) {
        $state.Task = $state.Stream.ReadAsync($state.Buffer, 0, $state.Buffer.Length)
    }

    $childExited = $false
    $exitedAt    = $null

    while ($null -ne $states[0].Task -or $null -ne $states[1].Task) {
        if (-not $childExited) {
            # Child-exit timing is the outcome authority: confirm the actual
            # exit time against the deadline before anything else, so the
            # drain can never misclassify a timely exit as a timeout.
            if ($Process.HasExited) {
                if ($Process.ExitTime -le $deadlineWall) {
                    $childExited = $true
                    $exitedAt = [Environment]::TickCount64
                }
                else {
                    return $false
                }
            }
            elseif ([Environment]::TickCount64 -ge $deadlineTick) {
                return $false
            }
        }

        if ($childExited) {
            $slice = 50
        }
        else {
            $slice = [Math]::Min(50, [Math]::Max(1, [int]($deadlineTick - [Environment]::TickCount64)))
        }

        foreach ($state in $states) {
            if ($null -eq $state.Task) {
                continue
            }

            $completed = $false

            try {
                $completed = $state.Task.Wait($slice)
            }
            catch {
                $completed = $true
            }

            if (-not $completed) {
                continue
            }

            $read = -1

            try {
                $read = $state.Task.Result
            }
            catch {
                $read = -1
            }

            if ($read -le 0) {
                $state.Task = $null
                continue
            }

            try {
                $state.Task = $state.Stream.ReadAsync($state.Buffer, 0, $state.Buffer.Length)
            }
            catch {
                $state.Task = $null
            }
        }

        if ($childExited -and ([Environment]::TickCount64 - $exitedAt) -gt $exitGraceMs) {
            # Finite post-exit drain grace: a descendant holding the
            # inherited pipe writers can never extend the wait.
            break
        }
    }

    if (-not $childExited) {
        # Streams closed; the child must still have exited within the
        # deadline. Re-confirm the actual exit time so a late exit can never
        # be reported as a timely completion.
        $remaining = [int]($deadlineTick - [Environment]::TickCount64)

        if (-not $Process.WaitForExit([Math]::Max(0, $remaining))) {
            return $false
        }

        $childExited = $Process.HasExited -and ($Process.ExitTime -le $deadlineWall)
    }

    return $childExited
}

function Invoke-DevWSHealthCheck {
    param(
        [Parameter(Mandatory)]
        $Context,
        [int]$ListTimeoutSeconds = 30
    )

    $results = [System.Collections.Generic.List[object]]::new()

    # The three task checks share one scheduled-task snapshot; a query failure
    # fails them with the underlying message instead of throwing out of the
    # aggregation.
    $taskIndex      = $null
    $taskIndexError = "Scheduled task state could not be read."

    try {
        $taskIndex = Get-DevWSHealthScheduledTaskIndex
    }
    catch {
        $taskIndexError = $_.Exception.Message
    }

    $checks = @(
        @{
            Id          = "os-windows"
            Description = "Windows"
            Test        = {
                return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
            }
        },
        @{
            Id          = "powershell-7"
            Description = "PowerShell 7+"
            Test        = {
                return ($PSVersionTable.PSVersion.Major -ge 7)
            }
        },
        @{
            Id          = "windows-terminal"
            Description = "Windows Terminal launcher is the trusted package executable"
            Test        = {
                $trustError = ""

                if ($null -ne $Context.PSObject.Properties["WindowsTerminalTrustError"] -and $null -ne $Context.WindowsTerminalTrustError) {
                    $trustError = [string]$Context.WindowsTerminalTrustError
                }

                if (-not [string]::IsNullOrWhiteSpace($trustError)) {
                    throw $trustError
                }

                $roots = @()

                if ($null -ne $Context.PSObject.Properties["WindowsTerminalTrustRoots"]) {
                    $roots = @($Context.WindowsTerminalTrustRoots)
                }

                if ($roots.Count -eq 0) {
                    # Repository/legacy contexts keep the existence-only check.
                    return (Test-Path -LiteralPath $Context.WindowsTerminalPath -PathType Leaf)
                }

                if (-not (Test-DevWSTrustedWindowsTerminalCandidate -Path $Context.WindowsTerminalPath -TrustedRoots $roots)) {
                    throw "the resolved Windows Terminal launcher is not the trusted Windows package executable: $($Context.WindowsTerminalPath)"
                }

                return $true
            }
        },
        @{
            Id          = "autohotkey"
            Description = "AutoHotkey v2 executable"
            Test        = {
                return (Test-Path -LiteralPath $Context.AutoHotkeyPath -PathType Leaf)
            }
        },
        @{
            Id          = "app-script"
            Description = "Installed app host scripts (ws.ps1, coordinator.ps1)"
            Test        = {
                if (-not (Test-Path -LiteralPath (Join-Path $Context.InstallRoot "app\ws.ps1") -PathType Leaf)) {
                    return $false
                }

                return (Test-Path -LiteralPath (Join-Path $Context.InstallRoot "app\coordinator.ps1") -PathType Leaf)
            }
        },
        @{
            Id          = "app-libs"
            Description = "Installed app libraries and native runtime"
            Test        = {
                $lib = Join-Path $Context.InstallRoot "app\lib"

                foreach ($name in @(Get-DevWSRequiredLibraryNames)) {
                    if (-not (Test-Path -LiteralPath (Join-Path $lib $name) -PathType Leaf)) {
                        return $false
                    }
                }

                $nativeDll = Get-DevWSInstalledNativeDllPath -InstallRoot $Context.InstallRoot

                if (-not (Test-Path -LiteralPath $nativeDll -PathType Leaf)) {
                    throw "the generated native runtime is missing: $nativeDll; run install.ps1"
                }

                $validation = Test-DevWSNativeAssemblyBytes -Bytes ([System.IO.File]::ReadAllBytes($nativeDll))

                if (-not $validation.Ok) {
                    throw "the generated native runtime is invalid ($($validation.Message)); run install.ps1"
                }

                return $true
            }
        },
        @{
            Id          = "helpers"
            Description = "Installed helpers (medium copy + privileged routes)"
            Test        = {
                $mediumHelper = Join-Path $Context.InstallRoot "helpers\window-helper.ahk"

                if (-not (Test-Path -LiteralPath $mediumHelper -PathType Leaf)) {
                    return $false
                }

                foreach ($name in @("window-helper.ahk", "reset-window.ahk", "cwd-shell-bootstrap.ps1")) {
                    if (-not (Test-Path -LiteralPath (Join-Path ([string]$Context.PrivilegedRoot) "helpers\$name") -PathType Leaf)) {
                        return $false
                    }
                }

                return $true
            }
        },
        @{
            Id          = "workers"
            Description = "Installed scheduled-task workers (privileged root)"
            Test        = {
                foreach ($spec in @(Get-DevWSScheduledTaskSpecs -InstallRoot $Context.InstallRoot -PrivilegedRoot $Context.PrivilegedRoot)) {
                    if (-not (Test-Path -LiteralPath $spec.Worker -PathType Leaf)) {
                        return $false
                    }
                }

                return $true
            }
        },
        @{
            Id             = "privileged-runtime"
            Description    = "Administrator-protected privileged runtime is complete"
            FailureMessage = "the protected privileged runtime is incomplete; run install.ps1"
            Test           = {
                Assert-DevWSPrivilegedRuntimeComplete -Root ([string]$Context.PrivilegedRoot)
                return $true
            }
        },
        @{
            Id             = "privileged-native"
            Description    = "Privileged native runtime validates"
            FailureMessage = "the privileged native runtime is missing or invalid; run install.ps1"
            Test           = {
                $dllPath = Join-Path ([string]$Context.PrivilegedRoot) "native\DevWS.Native.dll"

                if (-not (Test-Path -LiteralPath $dllPath -PathType Leaf)) {
                    throw "the privileged native runtime is missing: $dllPath; run install.ps1"
                }

                $validation = Test-DevWSNativeAssemblyBytes -Bytes ([System.IO.File]::ReadAllBytes($dllPath))

                if (-not $validation.Ok) {
                    throw "the privileged native runtime is invalid ($($validation.Message)); run install.ps1"
                }

                return $true
            }
        },
        @{
            Id             = "privileged-state"
            Description    = "Protected privileged-state foundation is administrator-controlled"
            FailureMessage = "the protected privileged-state foundation is missing or not administrator-controlled; run install.ps1"
            Test           = {
                # Public Security Phase 2-A: SID-derived ProgramData root,
                # owner Administrators, protected DACL, user read/list only,
                # no reparse components. Read-only: never creates or deletes.
                $protectedRoot = $null

                if ($null -ne $Context.PSObject.Properties["PrivilegedStateRoot"]) {
                    $protectedRoot = [string]$Context.PrivilegedStateRoot
                }

                if ([string]::IsNullOrWhiteSpace($protectedRoot)) {
                    # Repository/legacy contexts do not carry the installed
                    # protected-state root; the installed doctor and the
                    # installer enforce it explicitly.
                    return $true
                }

                $validation = Test-DevWSPrivilegedStateRoot -Root $protectedRoot

                if (-not $validation.Ok) {
                    throw ($validation.Errors -join " | ")
                }

                return $true
            }
        },
        @{
            Id          = "bin-shim"
            Description = "Installed bin\ws.cmd"
            Test        = {
                $shim = Join-Path $Context.InstallRoot "bin\ws.cmd"

                if (-not (Test-Path -LiteralPath $shim -PathType Leaf)) {
                    return $false
                }

                $content = Get-Content -LiteralPath $shim -Raw

                return (-not (Test-DevWSLegacyShimContent -Content $content))
            }
        },
        @{
            Id          = "state-directory"
            Description = "State directory"
            Test        = {
                return (Test-Path -LiteralPath $Context.StateRoot -PathType Container)
            }
        },
        @{
            Id          = "canonical-config"
            Description = "Canonical workspace config exists"
            Test        = {
                return (Test-Path -LiteralPath $Context.CanonicalPath -PathType Leaf)
            }
        },
        @{
            Id          = "canonical-config-valid"
            Description = "Canonical workspace config validates"
            Test        = {
                if (-not (Test-Path -LiteralPath $Context.CanonicalPath -PathType Leaf)) {
                    return $false
                }

                $config = Read-DevWSConfigFile -Path $Context.CanonicalPath
                Assert-DevWSConfig -Config $config -Source $Context.CanonicalPath

                return $true
            }
        },
        @{
            Id          = "user-path"
            Description = "DevWS bin on the user PATH"
            Test        = {
                return (Test-DevWSPathEntry -PathText (Get-DevWSUserPathText) -Entry (Join-Path $Context.InstallRoot "bin"))
            }
        },
        @{
            Id          = "scheduled-tasks"
            Description = "Five DevWorkspace scheduled tasks exist"
            Test        = {
                if ($null -eq $taskIndex) {
                    throw $taskIndexError
                }

                foreach ($spec in @(Get-DevWSScheduledTaskSpecs -InstallRoot $Context.InstallRoot -PrivilegedRoot $Context.PrivilegedRoot)) {
                    if (-not $taskIndex.ContainsKey([string]$spec.TaskName)) {
                        return $false
                    }
                }

                return $true
            }
        },
        @{
            Id          = "task-workers"
            Description = "Scheduled tasks point at installed workers and match managed settings"
            Test        = {
                if ($null -eq $taskIndex) {
                    throw $taskIndexError
                }

                foreach ($spec in @(Get-DevWSScheduledTaskSpecs -InstallRoot $Context.InstallRoot -PrivilegedRoot $Context.PrivilegedRoot)) {
                    if (-not $taskIndex.ContainsKey([string]$spec.TaskName)) {
                        return $false
                    }

                    $task = $taskIndex[[string]$spec.TaskName]
                    $arguments = @($task.Actions | ForEach-Object { [string]$_.Arguments }) -join " "

                    if ($arguments.IndexOf($spec.Worker, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                        return $false
                    }

                    if ([string]$task.Settings.MultipleInstances -ne "IgnoreNew") {
                        return $false
                    }

                    if ($spec.PSObject.Properties["ExecutionTimeLimitZero"] -and [bool]$spec.ExecutionTimeLimitZero) {
                        if ([string]$task.Settings.ExecutionTimeLimit -ne "PT0S") {
                            return $false
                        }
                    }

                    if ($spec.PSObject.Properties["AllowBattery"] -and [bool]$spec.AllowBattery) {
                        if ([bool]$task.Settings.DisallowStartIfOnBatteries -or [bool]$task.Settings.StopIfGoingOnBatteries) {
                            return $false
                        }
                    }

                    if ($spec.PSObject.Properties["RestartCount"] -and [int]$spec.RestartCount -gt 0) {
                        if ([int]$task.Settings.RestartCount -lt [int]$spec.RestartCount) {
                            return $false
                        }
                    }

                    if ($spec.PSObject.Properties["LogonTrigger"] -and [bool]$spec.LogonTrigger) {
                        $logonTriggers = @($task.Triggers | Where-Object { $null -ne $_.PSObject.Properties["UserId"] })
                        if ($logonTriggers.Count -lt 1) {
                            return $false
                        }
                    }
                }

                return $true
            }
        },
        @{
            Id          = "task-runlevel"
            Description = "Scheduled tasks run with Highest privileges"
            Test        = {
                if ($null -eq $taskIndex) {
                    throw $taskIndexError
                }

                foreach ($spec in @(Get-DevWSScheduledTaskSpecs -InstallRoot $Context.InstallRoot -PrivilegedRoot $Context.PrivilegedRoot)) {
                    if (-not $taskIndex.ContainsKey([string]$spec.TaskName)) {
                        return $false
                    }

                    if ([string]$taskIndex[[string]$spec.TaskName].Principal.RunLevel -ne "Highest") {
                        return $false
                    }
                }

                return $true
            }
        },
        @{
            Id          = "task-executable"
            Description = "Scheduled tasks use the absolute trusted PowerShell executable"
            Test        = {
                if ($null -eq $taskIndex) {
                    throw $taskIndexError
                }

                $expected = ""

                if ($null -ne $Context.PSObject.Properties["PrivilegedPowerShellPath"]) {
                    $expected = [string]$Context.PrivilegedPowerShellPath
                }

                $recorded = $expected

                if ([string]::IsNullOrWhiteSpace($expected)) {
                    # Legacy metadata (or a test context) without the recorded
                    # path: require the running trusted installation instead.
                    $expected = Resolve-DevWSTrustedPowerShellPath
                }

                if (-not (Test-DevWSTrustedExecutablePath -Path $expected)) {
                    if (-not [string]::IsNullOrWhiteSpace($recorded)) {
                        # The recorded interpreter itself is gone or no longer a
                        # trusted candidate. That is the package-update case.
                        throw ("the recorded trusted PowerShell executable '$recorded' is missing or is no longer a trusted candidate (typical after a PowerShell package update); repair the managed task bindings with: install.ps1 -RepairTasks  (from an elevated PowerShell 7 shell)")
                    }

                    return $false
                }

                foreach ($spec in @(Get-DevWSScheduledTaskSpecs -InstallRoot $Context.InstallRoot -PrivilegedRoot $Context.PrivilegedRoot -PowerShellPath $expected)) {
                    if (-not $taskIndex.ContainsKey([string]$spec.TaskName)) {
                        return $false
                    }

                    $task = $taskIndex[[string]$spec.TaskName]
                    $execute = ""

                    if (@($task.Actions).Count -gt 0) {
                        $execute = [string]$task.Actions[0].Execute
                    }

                    if ([string]::IsNullOrWhiteSpace($execute)) {
                        return $false
                    }

                    if ($execute.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
                        continue
                    }

                    # The executable does not match. Only a task that still has
                    # the complete DevWS-managed shape apart from that
                    # executable is the repairable package-update condition; any
                    # other drift stays a distinct installer problem and must
                    # not be presented as a routine PowerShell update.
                    $repairable = $false

                    if ([string]$task.TaskPath -eq "\") {
                        try {
                            $xml = Export-ScheduledTask -TaskName $spec.TaskName -ErrorAction Stop
                            $shape = Get-DevWSScheduledTaskShapeAssessment -Spec $spec -DefinitionXml $xml
                            $repairable = [bool]$shape.Ok
                        }
                        catch {
                            $repairable = $false
                        }
                    }

                    if ($repairable) {
                        throw ("the scheduled task '$($spec.TaskName)' still executes '$execute', not the recorded trusted PowerShell executable '$expected' (typical after a PowerShell package update); repair the managed task bindings with: install.ps1 -RepairTasks  (from an elevated PowerShell 7 shell)")
                    }

                    throw ("the scheduled task '$($spec.TaskName)' has an unexpected definition (execute '$execute', expected '$expected'); the DevWS-managed shape no longer matches, so run install.ps1 (normal mode) to repair the installation")
                }

                return $true
            }
        },
        @{
            Id          = "hotkey-file"
            Description = "TerminalShortcut.ahk exists"
            Test        = {
                return (Test-Path -LiteralPath (Join-Path $Context.StartupPath "TerminalShortcut.ahk") -PathType Leaf)
            }
        },
        @{
            Id             = "hotkey-target"
            Description    = "TerminalShortcut Alt+Shift+T targets installed DevWS"
            FailureMessage = "the managed hotkey script is missing or not current; run install.ps1"
            Test           = {
                $hotkeyPath = Join-Path $Context.StartupPath "TerminalShortcut.ahk"

                if (-not (Test-Path -LiteralPath $hotkeyPath -PathType Leaf)) {
                    return $false
                }

                $content = Get-Content -LiteralPath $hotkeyPath -Raw

                if (-not (Test-DevWSManagedHotkeyContent -Content $content -InstallRoot $Context.InstallRoot)) {
                    return $false
                }

                if (-not (Test-DevWSCoordinatorHotkeyContract -Content $content -InstallRoot $Context.InstallRoot)) {
                    return $false
                }

                $bindingsPath = Join-Path $Context.StateRoot "hotkeys\bindings.ahk"

                return (Test-DevWSManagedHotkeyIncludeContract -Content $content -BindingsPath $bindingsPath)
            }
        },
        @{
            Id          = "hotkey-legacy-external"
            Description = "TerminalShortcut has no retired external scheduled-task binding"
            Test        = {
                $hotkeyPath = Join-Path $Context.StartupPath "TerminalShortcut.ahk"

                if (-not (Test-Path -LiteralPath $hotkeyPath -PathType Leaf)) {
                    return $false
                }

                $content = Get-Content -LiteralPath $hotkeyPath -Raw

                if (-not (Test-DevWSManagedHotkeyContent -Content $content -InstallRoot $Context.InstallRoot)) {
                    return $false
                }

                # The current managed core must not carry the retired external
                # scheduled-task binding: Alt+T is ordinary binding space now.
                return (-not (Test-DevWSHistoricalManagedHotkeyContent -Content $content -InstallRoot $Context.InstallRoot))
            }
        },
        @{
            Id             = "hotkey-bindings"
            Description    = "Generated set launch bindings match canonical config"
            FailureMessage = "the generated bindings file is missing or out of date; run 'ws sync-hotkeys'"
            Test           = {
                if (-not (Test-Path -LiteralPath $Context.CanonicalPath -PathType Leaf)) {
                    return $false
                }

                $config = Read-DevWSConfigFile -Path $Context.CanonicalPath

                return (Test-DevWSBindingsInSync `
                    -Config $config `
                    -AppScriptPath (Join-Path $Context.InstallRoot "app\ws.ps1") `
                    -Path (Join-Path $Context.StateRoot "hotkeys\bindings.ahk"))
            }
        },
        @{
            Id          = "ws-list"
            Description = "Installed ws list runs read-only"
            Test        = {
                $scriptPath = Join-Path $Context.InstallRoot "app\ws.ps1"

                if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
                    return $false
                }

                $before = $null

                if (Test-Path -LiteralPath $Context.StateRoot -PathType Container) {
                    $before = @(Get-ChildItem -LiteralPath $Context.StateRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
                }

                $previousConfig = $env:DEVWS_CONFIG
                $exitCode = $null

                try {
                    $env:DEVWS_CONFIG = $Context.CanonicalPath

                    # Public Security Phase 2-E: the child's output is drained
                    # in memory (and discarded); no temporary redirect files
                    # are ever created.
                    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
                    $startInfo.FileName               = [string](Resolve-DevWSTrustedPowerShellPath)
                    $startInfo.Arguments              = "-NoLogo -NoProfile -File `"$scriptPath`" list"
                    $startInfo.UseShellExecute        = $false
                    $startInfo.CreateNoWindow         = $true
                    $startInfo.RedirectStandardOutput = $true
                    $startInfo.RedirectStandardError  = $true

                    $process = [System.Diagnostics.Process]::Start($startInfo)

                    if ($null -eq $process) {
                        return $false
                    }

                    try {
                        if (-not (Read-DevWSHealthChildStreamsToExit -Process $process -TimeoutMilliseconds ($ListTimeoutSeconds * 1000))) {
                            try { $process.Kill() } catch { }
                            [void]$process.WaitForExit(5000)
                            return $false
                        }

                        $exitCode = $process.ExitCode
                    }
                    finally {
                        $process.Dispose()
                    }
                }
                finally {
                    if ($null -eq $previousConfig) {
                        Remove-Item Env:\DEVWS_CONFIG -ErrorAction SilentlyContinue
                    }
                    else {
                        $env:DEVWS_CONFIG = $previousConfig
                    }
                }

                if ($exitCode -ne 0) {
                    return $false
                }

                if ($null -ne $before) {
                    $after = @(Get-ChildItem -LiteralPath $Context.StateRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
                    $newFiles = @($after | Where-Object { $_ -notin $before })

                    if ($newFiles.Count -gt 0) {
                        return $false
                    }
                }

                return $true
            }
        }
    )

    foreach ($check in $checks) {
        try {
            $ok = [bool](& $check.Test)

            if ($ok) {
                $results.Add((New-DevWSHealthCheckResult -Id $check.Id -Description $check.Description -Ok $true -Message "ok"))
            }
            else {
                $message = "check failed"

                if ($check.ContainsKey("FailureMessage")) {
                    $message = [string]$check.FailureMessage
                }

                $results.Add((New-DevWSHealthCheckResult -Id $check.Id -Description $check.Description -Ok $false -Message $message))
            }
        }
        catch {
            $results.Add((New-DevWSHealthCheckResult -Id $check.Id -Description $check.Description -Ok $false -Message $_.Exception.Message))
        }
    }

    return (Get-DevWSHealthSummary -Results $results.ToArray())
}
