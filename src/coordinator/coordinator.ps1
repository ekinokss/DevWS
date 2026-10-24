# DevWS Stage 1 warm normal-privilege coordinator (user-session process).
#
# Started once at login by the managed TerminalShortcut.ahk, hidden and
# non-elevated. Holds the DevWS PowerShell/native code warm and serves a
# deliberately tiny, strictly validated local named-pipe protocol:
#
#   ping | launch [setId] | shutdown
#
# Guarantees:
#   - single instance per session (named mutex; a second process exits 0);
#   - current-user-only named pipe (PipeOptions.CurrentUserOnly);
#   - no active workspace state and no polling: it blocks on WaitForConnection;
#   - canonical config is reloaded and validated for every command;
#   - deployed-code generation is rechecked per command: a changed install
#     returns "restart-required" and the process exits, so the bounded AHK
#     recovery path restarts fresh code;
#   - all launch policy comes from the canonical shared transaction.
#
# Optional parameters exist only for tests/benchmarks; production starts it
# with no arguments.
param(
    [string]$PipeName = "",
    [string]$MutexName = "",
    [switch]$NoWarmup,
    [string]$InstallRootOverride = ""
)

$ErrorActionPreference = "Stop"

# Resolve the runtime libraries for both supported layouts (same rule as the
# scheduled workers):
#   repository: <repo>\src\coordinator -> <repo>\src\lib
#   installed:  <installRoot>\app      -> <installRoot>\app\lib
$LibDir = $null

foreach ($candidate in @(
    (Join-Path $PSScriptRoot "..\lib"),
    (Join-Path $PSScriptRoot "..\app\lib")
)) {
    if (Test-Path -LiteralPath (Join-Path $candidate "devws-paths.ps1") -PathType Leaf) {
        $LibDir = (Resolve-Path -LiteralPath $candidate).Path
        break
    }
}

if (-not $LibDir) {
    throw "DevWS runtime libraries were not found next to '$PSScriptRoot'."
}

# Minimal pre-load so the singleton check can run before any heavy work.
. (Join-Path $LibDir "devws-paths.ps1")
. (Join-Path $LibDir "devws-config.ps1")
. (Join-Path $LibDir "devws-coordinator.ps1")

if ([string]::IsNullOrWhiteSpace($PipeName)) {
    $PipeName = Get-DevWSCoordinatorPipeName
}

if ([string]::IsNullOrWhiteSpace($MutexName)) {
    $MutexName = Get-DevWSCoordinatorMutexName
}

# ---- single instance ----
$mutex    = [System.Threading.Mutex]::new($false, $MutexName)
$acquired = $false

try {
    try {
        $acquired = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        # The previous owner died without releasing; ownership transferred.
        $acquired = $true
    }
}
catch {
    # A malformed mutex name is a deployment error; fail loudly.
    throw
}

if (-not $acquired) {
    # Another coordinator already owns this session instance.
    $mutex.Dispose()
    exit 0
}

$server = $null

try {
    # ---- full runtime load + warmup ----
    foreach ($name in @(
        "devws-native.ps1", "devws-app-ownership.ps1", "devws-app-window.ps1",
        "devws-lifecycle.ps1", "devws-terminal.ps1", "devws-app.ps1",
        "devws-window-ops.ps1", "devws-worker-protocol.ps1",
        "devws-terminal-launch.ps1", "devws-broker-protocol.ps1", "devws-launch.ps1",
        "devws-monitor.ps1", "devws-layout-profile.ps1", "devws-lifecycle-layout.ps1"
    )) {
        . (Join-Path $LibDir $name)
    }

    # Repo layout: <repo>\src\lib -> <repo>\src -> <repo>
    # Installed:   <root>\app\lib -> <root>\app -> <root>
    $appRoot     = Split-Path -Parent $LibDir
    $installRoot = if ([string]::IsNullOrWhiteSpace($InstallRootOverride)) { Split-Path -Parent $appRoot } else { $InstallRootOverride.Trim() }

    Write-DevWSLaunchTrace -Event "coordinator-start" -Data ([ordered]@{
        pipe       = $PipeName
        installRoot = $installRoot
        pid        = $PID
    })

    if (-not $NoWarmup) {
        # Best-effort warmup: heavy code paths and native types are brought in
        # once at login; failures are surfaced per command instead of killing
        # the resident process here.
        try {
            $warmLocation = Resolve-DevWSConfigLocation -StartPath $appRoot
            $warmConfig   = Get-DevWSConfig -Location $warmLocation
        }
        catch {
            $warmConfig = $null
        }

        try {
            [void](Initialize-DevWSNativeRuntime)
        }
        catch { }

        if ($null -ne $warmConfig) {
            try {
                [void](@(Get-DevWSAppWindowProbe -Config $warmConfig))
            }
            catch { }
        }
    }

    $generation = Get-DevWSRuntimeGeneration -InstallRoot $installRoot

    Write-DevWSLaunchTrace -Event "coordinator-ready" -Data ([ordered]@{
        pipe       = $PipeName
        generation = $generation
    })

    # Best-effort elevated-broker recovery (Stage 2). The broker normally
    # already exists from its logon task; this is bounded recovery, never a
    # blocking startup gate.
    try {
        if (-not (Test-DevWSElevatedBrokerAvailable -TimeoutMilliseconds 1000)) {
            Start-DevWSElevatedBrokerTask

            Write-DevWSLaunchTrace -Event "broker-recovery-requested" -Data ([ordered]@{
                pipe = $PipeName
            })
        }
    }
    catch { }

    # ---- server loop ----
    $server = [System.IO.Pipes.NamedPipeServerStream]::new(
        $PipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::CurrentUserOnly
    )

    $enc       = [System.Text.UTF8Encoding]::new($false)
    $quit      = $false
    $startedAt = Get-Date

    while (-not $quit) {
        $server.WaitForConnection()

        $reader = $null
        $writer = $null

        try {
            $reader = [System.IO.StreamReader]::new($server, $enc, $false, 4096, $true)
            $writer = [System.IO.StreamWriter]::new($server, $enc, 4096, $true)

            # Bounded read: a connected client that never sends a line can
            # never wedge the loop (10 s ceiling, single local user).
            $line = $null
            $cts  = [System.Threading.CancellationTokenSource]::new(10000)

            try {
                $line = $reader.ReadLineAsync($cts.Token).GetAwaiter().GetResult()
            }
            catch [System.OperationCanceledException] {
                $line = $null
            }
            finally {
                $cts.Dispose()
            }

            if ($null -eq $line) {
                continue
            }

            Write-DevWSLaunchTrace -Event "request-received" -Data ([ordered]@{ pipe = $PipeName })

            $parsed = Test-DevWSCoordinatorRequest -Line $line

            if (-not $parsed.Ok) {
                $writer.WriteLine(([ordered]@{
                    version = 1
                    ok      = $false
                    error   = $parsed.Error
                } | ConvertTo-Json -Compress))
                $writer.Flush()
                continue
            }

            $request = $parsed.Request

            # Stale deployed code: reject and exit; the AHK recovery path
            # starts fresh code on the next interaction.
            $currentGeneration = Get-DevWSRuntimeGeneration -InstallRoot $installRoot

            # Observational status: reports staleness WITHOUT the
            # restart-required exit; the host stays resident.
            if ($request.Command -eq "status") {
                $writer.WriteLine(([ordered]@{
                    version           = 1
                    ok                = $true
                    command           = "status"
                    pid               = $PID
                    generation        = $generation
                    currentGeneration = $currentGeneration
                    current           = ($currentGeneration -eq $generation)
                    uptimeSec         = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
                } | ConvertTo-Json -Compress))
                $writer.Flush()
                continue
            }

            if ($currentGeneration -ne $generation) {
                Write-DevWSLaunchTrace -Event "restart-required" -Data ([ordered]@{ pipe = $PipeName })

                $writer.WriteLine(([ordered]@{
                    version = 1
                    ok      = $false
                    command = $request.Command
                    error   = "restart-required"
                } | ConvertTo-Json -Compress))
                $writer.Flush()
                $quit = $true
                continue
            }

            if ($request.Command -eq "ping") {
                $writer.WriteLine(([ordered]@{
                    version    = 1
                    ok         = $true
                    command    = "ping"
                    pid        = $PID
                    generation = $generation
                    uptimeSec  = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
                } | ConvertTo-Json -Compress))
                $writer.Flush()
                continue
            }

            if ($request.Command -eq "shutdown") {
                $writer.WriteLine(([ordered]@{
                    version = 1
                    ok      = $true
                    command = "shutdown"
                    pid     = $PID
                } | ConvertTo-Json -Compress))
                $writer.Flush()
                $quit = $true
                continue
            }

            # launch: fresh canonical config for every command.
            $configFresh   = $null
            $configFailure = $null

            try {
                $locationFresh = Resolve-DevWSConfigLocation -StartPath $appRoot
                $configFresh   = Get-DevWSConfig -Location $locationFresh
            }
            catch {
                $configFailure = $_.Exception.Message
            }

            if ($null -ne $configFailure) {
                $writer.WriteLine(([ordered]@{
                    version = 1
                    ok      = $false
                    command = "launch"
                    error   = $configFailure
                } | ConvertTo-Json -Compress))
                $writer.Flush()
                continue
            }

            # Pure pre-ack validation and the frozen lifecycle placement
            # preflight: a resolvable target AND a safely resolvable placement
            # decision must exist before the request is accepted. Read-only;
            # no side effects. The plan is computed exactly ONCE here and the
            # canonical transaction consumes it without re-sampling topology,
            # so the hotkey sender can never receive "accepted" for a launch
            # that immediately fails preflight.
            $layoutPlan = $null
            $preflightFailure = $null

            try {
                [void](Resolve-DevWSLifecycleTarget -Config $configFresh -SetId $request.SetId)
                $layoutPlan = New-DevWSLaunchLayoutPlan -Config $configFresh -SetId $request.SetId
            }
            catch {
                $preflightFailure = $_.Exception.Message
            }

            if ($null -ne $preflightFailure) {
                Write-DevWSLaunchTrace -Event "launch-preflight-refused" -Data ([ordered]@{
                    pipe = $PipeName
                })

                $writer.WriteLine(([ordered]@{
                    version = 1
                    ok      = $false
                    command = "launch"
                    error   = $preflightFailure
                } | ConvertTo-Json -Compress))
                $writer.Flush()
                continue
            }

            Write-DevWSLaunchTrace -Event "launch-preflight-ready" -Data ([ordered]@{
                pipe         = $PipeName
                source       = [string]$layoutPlan.Source
                profileId    = [string]$layoutPlan.ProfileId
                profileAware = [bool]$layoutPlan.ProfileAware
            })

            # Immediate acceptance ack: the hotkey sender never blocks on
            # finalization; the completion line follows for real clients.
            $writer.WriteLine(([ordered]@{
                version = 1
                ok      = $true
                command = "launch"
                status  = "accepted"
            } | ConvertTo-Json -Compress))
            $writer.Flush()

            Write-DevWSLaunchTrace -Event "ack-sent" -Data ([ordered]@{ pipe = $PipeName })

            $response = Invoke-DevWSCoordinatorLaunch -Config $configFresh -SetId $request.SetId -LayoutPlan $layoutPlan

            try {
                $writer.WriteLine(($response | ConvertTo-Json -Compress))
                $writer.Flush()

                Write-DevWSLaunchTrace -Event "command-done" -Data ([ordered]@{
                    pipe = $PipeName
                    ok   = [bool]$response.ok
                })
            }
            catch {
                # The sender (hotkey) may have closed after the ack; the launch
                # itself already ran and must not be reported as failed.
            }
        }
        catch {
            try {
                if ($writer) {
                    $writer.WriteLine(([ordered]@{
                        version = 1
                        ok      = $false
                        error   = $_.Exception.Message
                    } | ConvertTo-Json -Compress))
                    $writer.Flush()
                }
            }
            catch { }
        }
        finally {
            try { if ($reader) { $reader.Dispose() } } catch { }
            try { if ($writer) { $writer.Dispose() } } catch { }
            try { $server.Disconnect() } catch { }
        }
    }
}
finally {
    if ($server) {
        try { $server.Dispose() } catch { }
    }

    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
}
