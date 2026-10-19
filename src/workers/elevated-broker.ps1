# DevWS Stage 2 persistent elevated broker (high-integrity worker host).
#
# One instance per user session, started at logon by the managed
# DevWorkspace-ElevatedBroker scheduled task and lazily recovered on demand.
# It owns the terminal half of the canonical launch transaction:
#
#   prepare-launch -> side-effect-free terminal plan (state-first, fast native
#                     WT enumeration, candidate-only managed UIA, explicit
#                     duplicate-windowId ambiguity, cwd tracking context,
#                     exact WT create arguments) stored as at most ONE pending
#                     transactional plan (bounded expiry);
#   go-launch      -> cheap WT-generation + deployment-generation revalidation,
#                     GO-ACK, then immediate back-to-back WT kickoff and one
#                     shared completion loop;
#   abort-launch   -> discard the pending plan, no side effects;
#   shutdown       -> clean exit.
#
# Guarantees:
#   - no active workspace state, no polling, no automatic side effects;
#   - canonical config is reloaded for every prepare request;
#   - deployed-code generation is rechecked per command: a changed install
#     returns restart-required and exits cleanly (the caller restarts it);
#   - the pipe is local-only with the proven explicit SDDL
#     (current user + SYSTEM, Medium mandatory label);
#   - all terminal launch policy comes from devws-terminal-launch.ps1.
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

# Public Security hardening: installed workers resolve libraries ONLY from the
# administrator-protected privileged root next to them
# (<privileged root>\workers -> <privileged root>\lib). Repository execution
# resolves <repo>\src\lib. There is no fallback to user-writable install
# copies.
$LibDir = Join-Path (Split-Path -Parent $PSScriptRoot) "lib"

if (-not (Test-Path -LiteralPath (Join-Path $LibDir "devws-paths.ps1") -PathType Leaf)) {
    throw "DevWS runtime libraries were not found at '$LibDir'. Installed workers require the administrator-protected privileged root next to them; run install.ps1."
}

. (Join-Path $LibDir "devws-paths.ps1")
Assert-DevWSWorkerLibraryRoot -LibDir $LibDir
. (Join-Path $LibDir "devws-config.ps1")

if ([string]::IsNullOrWhiteSpace($PipeName)) {
    . (Join-Path $LibDir "devws-broker-protocol.ps1")
    $PipeName = Get-DevWSElevatedBrokerPipeName
}

if ([string]::IsNullOrWhiteSpace($MutexName)) {
    if (-not (Get-Command Get-DevWSElevatedBrokerMutexName -ErrorAction SilentlyContinue)) {
        . (Join-Path $LibDir "devws-broker-protocol.ps1")
    }

    $MutexName = Get-DevWSElevatedBrokerMutexName
}

# ---- single instance -------------------------------------------------------
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
    # Another broker already owns this session instance.
    $mutex.Dispose()
    exit 0
}

$server = $null

try {
    # ---- full runtime load + warmup ----------------------------------------
    foreach ($name in @(
        "devws-native.ps1", "devws-window-ops.ps1", "devws-uia.ps1",
        "devws-state.ps1", "devws-identity.ps1", "devws-terminal.ps1",
        "devws-cwd-paths.ps1", "devws-cwd.ps1", "devws-terminal-launch.ps1", "devws-broker-protocol.ps1",
        "devws-coordinator.ps1", "devws-ahk.ps1", "devws-locator.ps1",
        "devws-terminal-operations.ps1"
    )) {
        . (Join-Path $LibDir $name)
    }

    # Repo layout: <repo>\src\lib -> <repo>\src -> <repo>
    # Installed:   <root>\app\lib -> <root>\app -> <root>  (user root)
    $appRoot     = Split-Path -Parent $LibDir
    # The user-owned runtime root (app/bin/state). Installed privileged hosts
    # resolve it through the shared path abstraction; repository/test hosts
    # keep the explicit -InstallRootOverride.
    $installRoot = if ([string]::IsNullOrWhiteSpace($InstallRootOverride)) { Get-DevWSInstallRoot } else { $InstallRootOverride.Trim() }
    $location    = Resolve-DevWSConfigLocation -StartPath $appRoot

    Write-DevWSLaunchTrace -Event "broker-start" -Data ([ordered]@{
        pipe        = $PipeName
        installRoot = $installRoot
        pid         = $PID
    })

    if (-not $NoWarmup) {
        # Best-effort warmup: heavy code paths, native types and UIAutomation
        # are brought in once at logon; failures are surfaced per command
        # instead of killing the resident process here. No launch/move/select.
        try { [void](Initialize-DevWSNativeRuntime) } catch { }
        try { Add-Type -AssemblyName UIAutomationClient } catch { }
        try { [void](Get-DevWSTerminalTopLevelHwnds) } catch { }
        try { [void](Get-DevWSConfig -Location $location) } catch { }
    }

    $generation = Get-DevWSEffectiveRuntimeGeneration -InstallRoot $installRoot

    Write-DevWSLaunchTrace -Event "broker-ready" -Data ([ordered]@{
        pipe       = $PipeName
        generation = $generation
    })

    # At most ONE pending transactional plan. Never active workspace state.
    $pending = $null
    $shutdown = $false
    $enc = [System.Text.UTF8Encoding]::new($false)

    $server = New-DevWSElevatedBrokerPipeServer -PipeName $PipeName

    while (-not $shutdown) {
        $server.WaitForConnection()

        $reader = $null
        $writer = $null

        try {
            $reader = [System.IO.StreamReader]::new($server, $enc, $false, 4096, $true)
            $writer = [System.IO.StreamWriter]::new($server, $enc, 4096, $true)

            while (-not $shutdown) {
                # Bounded read: a connected client that never sends a line can
                # never wedge the broker (10 s ceiling, single local user).
                $line = $null
                $cts = [System.Threading.CancellationTokenSource]::new(10000)

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
                    break
                }

                $parsed = Test-DevWSBrokerProtocolRequest -Line $line

                if (-not $parsed.Ok) {
                    $writer.WriteLine(([ordered]@{
                        version = 1
                        type    = "error"
                        error   = $parsed.Error
                    } | ConvertTo-Json -Compress))
                    $writer.Flush()
                    continue
                }

                $request = $parsed.Request

                # Stale deployed code: answer restart-required and exit so the
                # caller restarts fresh code. No side effects.
                $currentGeneration = Get-DevWSEffectiveRuntimeGeneration -InstallRoot $installRoot

                # Observational status: reports staleness WITHOUT the
                # restart-required exit. Never touches the pending plan.
                if ($request.Command -eq "status") {
                    $writer.WriteLine(([ordered]@{
                        version           = 1
                        type              = "status"
                        pid               = $PID
                        generation        = $generation
                        currentGeneration = $currentGeneration
                        current           = ($currentGeneration -eq $generation)
                    } | ConvertTo-Json -Compress))
                    $writer.Flush()
                    continue
                }

                if ($currentGeneration -ne $generation) {
                    $pending = $null
                    Write-DevWSLaunchTrace -Event "broker-restart-required" -Data ([ordered]@{ pipe = $PipeName })

                    $writer.WriteLine(([ordered]@{
                        version = 1
                        type    = "restart-required"
                        error   = "restart-required"
                    } | ConvertTo-Json -Compress))
                    $writer.Flush()
                    $shutdown = $true
                    break
                }

                if ($request.Command -eq "ping") {
                    $writer.WriteLine(([ordered]@{
                        version    = 1
                        type       = "pong"
                        pid        = $PID
                        generation = $generation
                    } | ConvertTo-Json -Compress))
                    $writer.Flush()
                    continue
                }

                if ($request.Command -eq "shutdown") {
                    $pending = $null
                    $writer.WriteLine(([ordered]@{
                        version = 1
                        type    = "bye"
                    } | ConvertTo-Json -Compress))
                    $writer.Flush()
                    $shutdown = $true
                    break
                }

                if ($request.Command -eq "abort-launch") {
                    $pending = $null
                    $writer.WriteLine(([ordered]@{
                        version   = 1
                        type      = "aborted"
                        requestId = [long]$request.RequestId
                    } | ConvertTo-Json -Compress))
                    $writer.Flush()
                    continue
                }

                if ($request.Command -eq "prepare-launch") {
                    $prepareStart = [Environment]::TickCount64
                    $response = $null

                    try {
                        $config = Get-DevWSConfig -Location $location
                        $target = Resolve-DevWSLifecycleTarget -Config $config -SetId ([string]$request.SetId)

                        Assert-DevWSTerminalPaths -Config $config -Set $target.Set -Source "elevated broker"

                        $launchTerminals = @(Get-DevWSWindows -Config $config -Type "terminal" -EnabledOnly -Set $target.Set)
                        Assert-DevWSElevatedTerminals -Terminals $launchTerminals

                        # Frozen normal-side placements: correlate the request
                        # records against the CURRENT canonical membership. A
                        # membership change since the normal-side preflight
                        # fails safely instead of guessing geometry. The broker
                        # never resolves topology or profiles.
                        $payload = Resolve-DevWSTerminalPlacementPayload `
                            -Placements $request.TerminalPlacements `
                            -Terminals $launchTerminals `
                            -RequireExactMembership

                        $state = Read-DevWSRuntimeState
                        $plan  = Get-DevWSTerminalLaunchPlan -Config $config -SetId $target.SetId -State $state -Terminals $payload.Terminals -Placements $payload.Placements

                        # One pending plan maximum: a new prepare replaces any
                        # previous unconsumed plan.
                        $pending = [pscustomobject]@{
                            RequestId  = [long]$request.RequestId
                            Plan       = $plan
                            ExpiresUtc = [DateTimeOffset]::UtcNow.AddSeconds(2)
                        }

                        $response = [ordered]@{
                            version   = 1
                            type      = "ready"
                            requestId = [long]$request.RequestId
                            planId    = [string]$plan.PlanId
                            plan      = (Get-DevWSTerminalLaunchPlanSummary -Plan $plan)
                            elapsedMs = [Environment]::TickCount64 - $prepareStart
                        }

                        Write-DevWSLaunchTrace -Event "broker-prepared" -Data ([ordered]@{
                            requestId = [long]$request.RequestId
                            planId    = [string]$plan.PlanId
                            present   = [int]$plan.Counts.Present
                            missing   = [int]$plan.Counts.Missing
                            ambiguous = [int]$plan.Counts.Ambiguous
                            failed    = [int]$plan.Counts.Failed
                            elapsedMs = [long]$response.elapsedMs
                        })
                    }
                    catch {
                        $pending = $null
                        $response = [ordered]@{
                            version   = 1
                            type      = "prepare-failed"
                            requestId = [long]$request.RequestId
                            error     = $_.Exception.Message
                        }
                    }

                    $writer.WriteLine(($response | ConvertTo-Json -Compress -Depth 8))
                    $writer.Flush()
                    continue
                }

                if ($request.Command -in @("focus-terminals", "capture-terminals")) {
                    # Side-effect-free pre-acceptance preparation: canonical
                    # config, exact target set, enabled terminals, the elevated
                    # requirement and the runtime state are all resolved BEFORE
                    # ACCEPTED is sent. The shared terminal-operations core
                    # provides the same policy as the scheduled workers.
                    $accepted  = $false
                    $target    = $null
                    $terminals = @()
                    $state     = $null

                    try {
                        $config    = Get-DevWSConfig -Location $location
                        $target    = Resolve-DevWSLifecycleTarget -Config $config -SetId ([string]$request.SetId)
                        $terminals = @(Get-DevWSWindows -Config $config -Type terminal -EnabledOnly -Set $target.Set)
                        Assert-DevWSElevatedTerminals -Terminals $terminals
                        $state     = Read-DevWSRuntimeState
                        $accepted  = $true
                    }
                    catch {
                        $writer.WriteLine(([ordered]@{
                            version   = 1
                            type      = "operation-rejected"
                            operation = [string]$request.Command
                            requestId = [long]$request.RequestId
                            error     = $_.Exception.Message
                        } | ConvertTo-Json -Compress))
                        $writer.Flush()
                    }

                    if ($accepted) {
                        $writer.WriteLine(([ordered]@{
                            version   = 1
                            type      = "operation-accepted"
                            operation = [string]$request.Command
                            requestId = [long]$request.RequestId
                            setId     = [string]$target.SetId
                        } | ConvertTo-Json -Compress))
                        $writer.Flush()

                        $finalPayload = [ordered]@{
                            version   = 1
                            type      = "operation-final"
                            operation = [string]$request.Command
                            requestId = [long]$request.RequestId
                            ok        = $true
                            message   = "OK"
                            error     = $null
                        }

                        $operationStart = [Environment]::TickCount64

                        try {
                            if ($request.Command -eq "focus-terminals") {
                                $finalPayload.message = Invoke-DevWSTerminalFocusOperation -SetId $target.SetId -Terminals $terminals -State $state
                            }
                            else {
                                # Phase 2-B protected publication: exclusive claim,
                                # High-generated identity and the complete artifact
                                # write all happen while the claim lifetime scope
                                # is held; the identity travels on the FINAL.
                                $claim = New-DevWSProtectedCaptureClaim -OperationId ([string]([long]$request.RequestId))

                                try {
                                    $publication = [guid]::NewGuid().ToString()
                                    Set-DevWSProtectedPublicationIdentity -ClaimPath $claim.ClaimPath -Publication $publication
                                    $finalPayload["publication"] = $publication
                                    $finalPayload.message = Invoke-DevWSTerminalCaptureOperation -SetId $target.SetId -Terminals $terminals -State $state -ClaimPath $claim.ClaimPath
                                }
                                finally {
                                    $claim.Scope.Dispose()
                                }
                            }

                            Write-DevWSLaunchTrace -Event "broker-operation-final" -Data ([ordered]@{
                                operation = [string]$request.Command
                                setId     = [string]$target.SetId
                                ok        = $true
                                elapsedMs = [Environment]::TickCount64 - $operationStart
                            })
                        }
                        catch {
                            $finalPayload.ok      = $false
                            $finalPayload.message = $null
                            $finalPayload.error   = $_.Exception.Message

                            Write-DevWSLaunchTrace -Event "broker-operation-final" -Data ([ordered]@{
                                operation = [string]$request.Command
                                setId     = [string]$target.SetId
                                ok        = $false
                                error     = $_.Exception.Message
                            })
                        }

                        try {
                            $writer.WriteLine(($finalPayload | ConvertTo-Json -Compress))
                            $writer.Flush()
                        }
                        catch {
                            # The caller may have vanished after ACCEPTED; the
                            # operation side effects already happened and must
                            # not be repeated.
                        }
                    }

                    continue
                }

                if ($request.Command -eq "go-launch") {
                    $goStart = [Environment]::TickCount64
                    $plan = $null
                    $reason = $null

                    if ($null -eq $pending) {
                        $reason = "no-pending-plan"
                    }
                    elseif ([long]$pending.RequestId -ne [long]$request.RequestId) {
                        $reason = "request-mismatch"
                    }
                    elseif ([string]$pending.Plan.PlanId -cne [string]$request.PlanId) {
                        $reason = "plan-mismatch"
                    }
                    elseif ([DateTimeOffset]::UtcNow -gt $pending.ExpiresUtc) {
                        $reason = "expired"
                    }
                    else {
                        $plan = $pending.Plan
                    }

                    if ($null -eq $reason) {
                        $recheckStart = [Environment]::TickCount64
                        $fresh = Test-DevWSTerminalLaunchPlanFresh -Plan $plan
                        $recheckMs = [Environment]::TickCount64 - $recheckStart

                        if (-not $fresh) {
                            $reason = "wt-generation-changed"
                        }
                    }

                    if ($null -ne $reason) {
                        $pending = $null
                        Write-DevWSLaunchTrace -Event "broker-replan-required" -Data ([ordered]@{
                            requestId = [long]$request.RequestId
                            reason    = $reason
                        })

                        $writer.WriteLine(([ordered]@{
                            version   = 1
                            type      = "replan-required"
                            requestId = [long]$request.RequestId
                            reason    = $reason
                        } | ConvertTo-Json -Compress))
                        $writer.Flush()
                        continue
                    }

                    # Valid: GO-ACK first, then the terminal burst immediately.
                    $writer.WriteLine(([ordered]@{
                        version   = 1
                        type      = "go-ack"
                        requestId = [long]$request.RequestId
                        planId    = [string]$plan.PlanId
                        recheckMs = [long]$recheckMs
                        ackAt     = [Environment]::TickCount64
                    } | ConvertTo-Json -Compress))
                    $writer.Flush()

                    Write-DevWSLaunchTrace -Event "broker-go-ack" -Data ([ordered]@{
                        requestId = [long]$request.RequestId
                        planId    = [string]$plan.PlanId
                        recheckMs = [long]$recheckMs
                    })

                    $kickResult = Start-DevWSTerminalLaunchPlan -Plan $plan
                    $kicked = @($kickResult.Kicks)

                    $finalPayload = [ordered]@{
                        version   = 1
                        type      = "final"
                        requestId = [long]$request.RequestId
                        planId    = [string]$plan.PlanId
                        firstKick = $null
                        lastKick  = $null
                        kicked    = @()
                        summary   = $null
                    }

                    if ($kicked.Count -gt 0) {
                        $finalPayload.firstKick = [long]$kicked[0].StartedAtUtc.ToUnixTimeMilliseconds()
                        $finalPayload.lastKick  = [long]$kicked[$kicked.Count - 1].StartedAtUtc.ToUnixTimeMilliseconds()
                        $finalPayload.kicked    = @($kicked | ForEach-Object {
                            [ordered]@{
                                terminalId = [string]$_.TerminalId
                                windowId   = [string]$_.WindowId
                                startedAt  = [long]$_.StartedAtUtc.ToUnixTimeMilliseconds()
                            }
                        })
                    }

                    $completion = Complete-DevWSTerminalLaunchPlan -Plan $plan -KickResult $kickResult

                    $finalPayload.summary = [ordered]@{
                        finalized = @($completion.Finalized)
                        failures  = @($completion.Failures)
                    }
                    $finalPayload.elapsedMs = [Environment]::TickCount64 - $goStart

                    $pending = $null

                    Write-DevWSLaunchTrace -Event "broker-final" -Data ([ordered]@{
                        requestId = [long]$request.RequestId
                        finalized = @($completion.Finalized).Count
                        failures  = @($completion.Failures).Count
                        elapsedMs = [long]$finalPayload.elapsedMs
                    })

                    try {
                        $writer.WriteLine(($finalPayload | ConvertTo-Json -Compress -Depth 8))
                        $writer.Flush()
                    }
                    catch {
                        # The caller may have vanished after GO-ACK; terminal
                        # side effects already happened and must not be retried.
                    }

                    continue
                }

                $writer.WriteLine(([ordered]@{
                    version = 1
                    type    = "error"
                    error   = "unsupported command '$($request.Command)'"
                } | ConvertTo-Json -Compress))
                $writer.Flush()
            }
        }
        catch {
            # A broken connection never kills the broker; any pending plan is
            # abandoned with no side effects.
            $pending = $null
        }
        finally {
            try { if ($reader) { $reader.Dispose() } } catch { }
            try { if ($writer) { $writer.Dispose() } } catch { }
            try { $server.Dispose() } catch { }
        }

        if (-not $shutdown) {
            $pending = $null
            Start-Sleep -Milliseconds 50
            $server = New-DevWSElevatedBrokerPipeServer -PipeName $PipeName
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
