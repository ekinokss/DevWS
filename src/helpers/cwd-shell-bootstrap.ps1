# DevWS Phase 9 / Pass 6B tracked shell bootstrap.
#
# This is a STATIC staged helper (never generated at runtime). It is launched
# as every configured tab of a tracked managed terminal:
#
#   pwsh -NoExit -File cwd-shell-bootstrap.ps1 -SetId ... -TerminalId ...
#     -WindowId ... [-TabIndex N] -SessionId ... -PublicationPath ...
#     -ChildSpecBase64 ...
#
# The user's normal PowerShell profile has already run (this bootstrap is never
# invoked with -NoProfile). The bootstrap:
#
#   1. captures the already-loaded user prompt;
#   2. installs a PROCESS-LOCAL prompt wrapper that publishes the shell cwd;
#   3. publishes the initial cwd/startup state BEFORE the configured child
#      takes over;
#   4. publishes startup-child-active, hands off to the decoded configured
#      tab child command/args (the exact decoded ARRAY, never a reparsed
#      shell string), then publishes startup-child-returned when that exact
#      child invocation returns;
#   5. leaves the shell interactive (-NoExit), publishing later prompt cwd
#      while preserving the lifecycle state.
#
# The startup lifecycle (idle | startup-child-active | startup-child-returned)
# is owned solely by this bootstrap across its own child invocation. It is
# never inferred from process trees, foreground processes, terminal contents,
# or shell history.
#
# It never modifies profile files, installs a module, or touches Startup.
# Publication failures are swallowed and logged; the prompt stays usable.
# The controller-owned expected session record path is intentionally NOT an
# input: the shell cannot read or write the expected generation.
#
# Public Security Phase 2-C: installed tracked shells (running from
# <privileged root>\helpers) derive their protected publication destination
# from the validated logical identity using the canonical path policy loaded
# ONLY from the protected privileged runtime next to this helper, and accept
# the supplied PublicationPath only when it equals that derived path exactly.
# A tracked shell never creates protected ancestors.
#
# Public Security Phase 2-E: installed tracked shells (High) create NO
# diagnostic filesystem output at all - no legacy user-owned log, no
# fallback path and no protected successor file. Diagnostics stay
# process-local; historical log files are never touched or deleted.
# Repository helpers keep the historical explicit-path logging behavior so
# fixture tests stay supported.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SetId,
    [Parameter(Mandatory)]
    [string]$TerminalId,
    [Parameter(Mandatory)]
    [string]$WindowId,
    [int]$TabIndex = 0,
    [Parameter(Mandatory)]
    [string]$SessionId,
    [Parameter(Mandatory)]
    [string]$PublicationPath,
    [Parameter(Mandatory)]
    [string]$ChildSpecBase64
)

# Installed tracked shells run from <privileged root>\helpers; repository
# helpers run from <repo>\src\helpers. The discriminator is this file's own
# location - never an environment variable or caller input.
$global:DevWSCwdBootstrapInstalled = ((Split-Path -Leaf (Split-Path -Parent $PSScriptRoot)) -ieq "privileged")
$global:DevWSCwdBootstrapBlocked = ""

if ($global:DevWSCwdBootstrapInstalled) {
    $global:DevWSCwdBootstrapLeafPath = Join-Path (Split-Path -Parent $PSScriptRoot) "lib\devws-cwd-paths.ps1"

    if (Test-Path -LiteralPath $global:DevWSCwdBootstrapLeafPath -PathType Leaf) {
        try {
            . $global:DevWSCwdBootstrapLeafPath

            if ($TabIndex -lt 0) {
                $global:DevWSCwdBootstrapBlocked = "publication disabled: tab-index-negative"
            }
            else {
                $decision = Test-DevWSCwdBootstrapPublicationTarget `
                    -SidRoot (Get-DevWSCwdProtectedSidRoot) `
                    -SetId $SetId `
                    -TerminalId $TerminalId `
                    -TabIndex $TabIndex `
                    -SuppliedPath $PublicationPath

                if ([bool]$decision.Ok) {
                    $PublicationPath = [string]$decision.DerivedPath
                }
                else {
                    $global:DevWSCwdBootstrapBlocked = "publication disabled: " + [string]$decision.Reason
                }
            }
        }
        catch {
            $global:DevWSCwdBootstrapBlocked = "publication disabled: " + $_.Exception.Message
        }
    }
    else {
        $global:DevWSCwdBootstrapBlocked = "publication disabled: protected cwd path library missing at '$($global:DevWSCwdBootstrapLeafPath)'"
    }
}

$global:DevWSCwdTrackingContext = @{
    SetId           = $SetId
    TerminalId      = $TerminalId
    WindowId        = $WindowId
    TabIndex        = [int]$TabIndex
    SessionId       = $SessionId
    PublicationPath = $PublicationPath
    ErrorLogPath    = $(if ($global:DevWSCwdBootstrapInstalled) {
        # Public Security Phase 2-E: an installed tracked shell never creates
        # or appends a diagnostic file. The legacy user-owned log and any
        # protected successor are both retired; diagnostics stay process-local
        # ($global:DevWSCwdBootstrapDiagnostics) and no filesystem artifact is
        # produced. Historical log files are never touched.
        $null
    } else {
        Join-Path (Split-Path -Parent $PublicationPath) "bootstrap-errors.log"
    })
    ShellPid        = $PID
    ShellStartUtc   = (Get-Date).ToUniversalTime().ToString("o")
    StartupState    = "idle"
}

try {
    # Recorded once; the resolver rejects the publication when this identity
    # does not match the live process start time (PID-reuse protection).
    $global:DevWSCwdTrackingContext.ShellStartUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o")
}
catch {
    # Leave the fallback start time in place: the resolver will treat the
    # publication as unavailable rather than guessing.
}

function global:Write-DevWSCwdBootstrapLog {
    # Best-effort diagnostic log. Interface and call sites are unchanged
    # (Public Security Phase 2-E keeps the function contract):
    #
    #   installed tracked shell (High) -> process-local list only; NO
    #     directory creation, NO file append, NO fallback path, NO protected
    #     successor file, and historical files are never deleted.
    #   repository helper -> the historical sibling-of-publication file.
    param([string]$Message)

    try {
        $line = "[{0}] [pid {1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $PID, $Message

        if ([bool]$global:DevWSCwdBootstrapInstalled) {
            if ($null -eq $global:DevWSCwdBootstrapDiagnostics) {
                $global:DevWSCwdBootstrapDiagnostics = [System.Collections.Generic.List[string]]::new()
            }

            # Bounded process-local retention; diagnostics are never authority.
            if ($global:DevWSCwdBootstrapDiagnostics.Count -lt 64) {
                $global:DevWSCwdBootstrapDiagnostics.Add($line) | Out-Null
            }

            return
        }

        $logPath   = [string]$global:DevWSCwdTrackingContext.ErrorLogPath
        $directory = Split-Path -Parent $logPath

        if (-not [string]::IsNullOrWhiteSpace($directory) -and -not [System.IO.Directory]::Exists($directory)) {
            [void][System.IO.Directory]::CreateDirectory($directory)
        }

        [System.IO.File]::AppendAllText($logPath, $line + "`r`n", [System.Text.UTF8Encoding]::new($false))
    }
    catch {
    }
}

function global:Write-DevWSCwdBootstrapAtomic {
    # Unique temp + validated JSON + bounded replace retry (a Windows reader
    # without delete-sharing can transiently block the replacement).
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        $Object
    )

    $directory = Split-Path -Parent $Path

    if (-not [System.IO.Directory]::Exists($directory)) {
        if ([bool]$global:DevWSCwdBootstrapInstalled) {
            # Protected ancestors are created ONLY by the High controller
            # through the exclusive secure-directory primitive; a tracked
            # shell never creates trusted protected directories.
            throw "the protected cwd publication directory '$directory' is missing; a tracked shell never creates protected ancestors."
        }

        [void][System.IO.Directory]::CreateDirectory($directory)
    }

    if ([System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path)) {
        $existingItem = Get-Item -LiteralPath $Path -Force

        if ($existingItem.PSIsContainer -or [bool]($existingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "refusing a cwd publication write through an unexpected filesystem object at '$Path'."
        }
    }

    $json = $Object | ConvertTo-Json -Compress -Depth 6
    $null = $json | ConvertFrom-Json -ErrorAction Stop

    $tempPath = Join-Path $directory (".cwd-" + [string]$PID + "-" + [guid]::NewGuid().ToString("N") + ".tmp")

    try {
        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))

        $attempt = 0

        while ($true) {
            $attempt++

            try {
                [System.IO.File]::Move($tempPath, $Path, $true)
                break
            }
            catch {
                # Sharing/access-denied on replace is transient; bounded retry.
                # [System.IO.File]::Move failures arrive wrapped in
                # MethodInvocationException, so unwrap first.
                $moveError = $_.Exception

                if ($moveError -is [System.Management.Automation.MethodInvocationException] -and $null -ne $moveError.InnerException) {
                    $moveError = $moveError.InnerException
                }

                $isTransient = ($moveError -is [System.IO.IOException]) -or ($moveError -is [System.UnauthorizedAccessException])

                if (-not $isTransient -or $attempt -ge 6) { throw }
                Start-Sleep -Milliseconds 40
            }
        }
    }
    finally {
        if ([System.IO.File]::Exists($tempPath)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function global:Write-DevWSCwdBootstrapPublication {
    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$global:DevWSCwdBootstrapBlocked)) {
            Write-DevWSCwdBootstrapLog ("cwd publication skipped (swallowed): " + [string]$global:DevWSCwdBootstrapBlocked)
            return
        }

        $context = $global:DevWSCwdTrackingContext

        $payload = [ordered]@{
            version     = 1
            setId       = $context.SetId
            terminalId  = $context.TerminalId
            windowId    = $context.WindowId
            sessionId   = $context.SessionId
            cwd         = (Get-Location).ProviderPath
            startupState = [string]$context.StartupState
            shellPid    = $context.ShellPid
            shellStartTimeUtc = $context.ShellStartUtc
            updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        }

        if ([int]$context.TabIndex -gt 0) {
            $payload.tabIndex = [int]$context.TabIndex
        }

        Write-DevWSCwdBootstrapAtomic -Path ([string]$context.PublicationPath) -Object $payload
    }
    catch {
        Write-DevWSCwdBootstrapLog ("cwd publication failed (swallowed): " + $_.Exception.Message)
    }
}

function global:Read-DevWSCwdBootstrapChildSpec {
    # One Base64(UTF-8 JSON) payload; the decoded argument ARRAY is invoked
    # directly, so switch-looking arguments, spaces, quotes, Unicode, empty
    # args, and argument order are preserved without shell-string reparsing.
    param([string]$Base64)

    $result = [ordered]@{
        Ok        = $false
        Reason    = "malformed"
        Command   = $null
        Arguments = @()
    }

    if ([string]::IsNullOrWhiteSpace($Base64)) {
        $result.Reason = "missing"
        return [pscustomobject]$result
    }

    try {
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
        $spec = $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return [pscustomobject]$result
    }

    if ($null -eq $spec -or
        $null -eq $spec.PSObject.Properties["command"] -or
        $null -eq $spec.PSObject.Properties["args"]) {
        $result.Reason = "schema"
        return [pscustomobject]$result
    }

    $command = $spec.command

    if ($null -ne $command -and $command -isnot [string]) {
        $result.Reason = "schema"
        return [pscustomobject]$result
    }

    $arguments = @()

    foreach ($argument in @($spec.args)) {
        if ($null -ne $argument -and $argument -isnot [string]) {
            $result.Reason = "schema"
            return [pscustomobject]$result
        }

        $arguments += [string]$argument
    }

    $result.Ok        = $true
    $result.Reason    = "ok"
    $result.Command   = $(if ($null -eq $command -or [string]::IsNullOrWhiteSpace([string]$command)) { $null } else { [string]$command })
    $result.Arguments = $arguments
    return [pscustomobject]$result
}

# Capture the prompt that the real profile installed (the profile has already
# run for this process). The wrapper delegates to it unchanged.
$global:DevWSCwdOriginalPrompt = $function:prompt

function global:prompt {
    $savedLastExitCode = $global:LASTEXITCODE

    try {
        Write-DevWSCwdBootstrapPublication
    }
    catch {
        Write-DevWSCwdBootstrapLog ("prompt publication wrapper failed (swallowed): " + $_.Exception.Message)
    }

    # Publication must never corrupt the shell's visible native exit code.
    $global:LASTEXITCODE = $savedLastExitCode

    if ($null -ne $global:DevWSCwdOriginalPrompt) {
        & $global:DevWSCwdOriginalPrompt
    }
    else {
        "PS $((Get-Location).ProviderPath)> "
    }
}

# Initial publication BEFORE the configured child command takes over the tab.
try {
    Write-DevWSCwdBootstrapPublication
}
catch {
    Write-DevWSCwdBootstrapLog ("initial publication failed (swallowed): " + $_.Exception.Message)
}

# Configured tab child handoff (if any). A malformed payload never executes
# an invented command; the shell stays alive either way. The startup lifecycle
# transitions are owned by this bootstrap across its own child invocation.
$childSpec = Read-DevWSCwdBootstrapChildSpec -Base64 $ChildSpecBase64

if (-not $childSpec.Ok) {
    Write-DevWSCwdBootstrapLog ("child spec rejected (" + $childSpec.Reason + "); no command was executed")
}
elseif ($null -ne $childSpec.Command) {
    $global:DevWSCwdTrackingContext.StartupState = "startup-child-active"
    Write-DevWSCwdBootstrapPublication

    # Splat the decoded argument ARRAY element-by-element. A PowerShell SCRIPT
    # child (for example an npm .ps1 shim) receives an array passed as a single
    # token as ONE object argument, so an EMPTY array would otherwise arrive as
    # one empty-string positional argument and a multi-element array would
    # collapse into one joined argument. Splatting keeps [] (zero arguments)
    # distinct from [""] (one empty-string argument) and preserves exact order,
    # spaces, quotes, switch-looking tokens and Unicode for every child kind.
    $childArguments = @($childSpec.Arguments)

    if ($childArguments.Count -eq 0) {
        & $childSpec.Command
    }
    else {
        & $childSpec.Command @childArguments
    }

    $global:DevWSCwdTrackingContext.StartupState = "startup-child-returned"
    Write-DevWSCwdBootstrapPublication
}
