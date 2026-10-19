# Shared AutoHotkey invocation helpers.
#
# AutoHotkey64.exe is a GUI-subsystem executable. `&` neither populates
# $LASTEXITCODE nor captures its stdout, so every call goes through an
# explicit System.Diagnostics.Process with in-memory redirected streams.
#
# Public Security Phase 2-E: no per-call temporary output files are ever
# created. AHK's text encoding for `*`/`**` follows the script's own
# FileAppend options: explicit UTF-8 output is captured byte-faithfully, and
# the default (system-ANSI-style) output decodes exactly the way the legacy
# redirect-file + Get-Content path decoded it.
#
# Helper-script routing lives in devws-paths.ps1 (Get-DevWSWindowHelperPath /
# Get-DevWSResetWindowHelperPath): installed High contexts load the
# administrator-protected privileged copies, installed Medium contexts load
# the user-owned copies, and repository execution uses src\helpers.

function Read-DevWSAhkProcessStreams {
    # Concurrent bounded capture of a redirected child's stdout/stderr.
    # Reads are interleaved so a child flooding either pipe can never
    # deadlock on a full buffer, and draining continues after the retained
    # bound is reached. At most $Limit bytes per stream are retained,
    # INCLUDING a fixed truncation marker appended inside the bound when
    # bytes were dropped. Bytes are decoded as UTF-8 without a BOM.
    #
    # After the child exits, draining stops once no new bytes have arrived
    # for a short grace period, so a hypothetical grandchild that inherited
    # the pipe handles can never extend the wait beyond the direct child.
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [int]$Limit = 262144
    )

    $markerBytes = [System.Text.Encoding]::UTF8.GetBytes("[DevWS output truncated]")
    $dataLimit   = [Math]::Max(0, $Limit - $markerBytes.Length)
    $exitGraceMs = 500

    $states = @(
        [pscustomobject]@{ Stream = $Process.StandardOutput.BaseStream; Task = $null; Buffer = [byte[]]::new(8192); Retained = [System.IO.MemoryStream]::new(); Truncated = $false },
        [pscustomobject]@{ Stream = $Process.StandardError.BaseStream;  Task = $null; Buffer = [byte[]]::new(8192); Retained = [System.IO.MemoryStream]::new(); Truncated = $false }
    )

    try {
        foreach ($state in $states) {
            $state.Task = $state.Stream.ReadAsync($state.Buffer, 0, $state.Buffer.Length)
        }

        $exitedAt = $null

        while ($null -ne $states[0].Task -or $null -ne $states[1].Task) {
            if ($null -eq $exitedAt -and $Process.HasExited) {
                $exitedAt = [Environment]::TickCount64
            }

            foreach ($state in $states) {
                if ($null -eq $state.Task) {
                    continue
                }

                $completed = $false

                try {
                    $completed = $state.Task.Wait(15)
                }
                catch {
                    # A faulted stream read is treated as end-of-stream; the
                    # process exit code still reports the helper outcome.
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

                $room = $dataLimit - [int]$state.Retained.Length
                $take = [Math]::Min($read, [Math]::Max(0, $room))

                if ($take -gt 0) {
                    $state.Retained.Write($state.Buffer, 0, $take)
                }

                if ($take -lt $read) {
                    $state.Truncated = $true
                }

                try {
                    $state.Task = $state.Stream.ReadAsync($state.Buffer, 0, $state.Buffer.Length)
                }
                catch {
                    $state.Task = $null
                }
            }

            if ($null -ne $exitedAt -and ([Environment]::TickCount64 - $exitedAt) -gt $exitGraceMs) {
                break
            }
        }

        foreach ($state in $states) {
            if ($state.Truncated) {
                $state.Retained.Write($markerBytes, 0, $markerBytes.Length)
            }
        }

        $encoding = [System.Text.UTF8Encoding]::new($false)

        return [pscustomobject]@{
            Output = $encoding.GetString($states[0].Retained.ToArray())
            Error  = $encoding.GetString($states[1].Retained.ToArray())
        }
    }
    finally {
        foreach ($state in $states) {
            $state.Retained.Dispose()
        }
    }
}

function Invoke-DevWSAhk {
    param(
        [Parameter(Mandatory)]
        [string]$Script,
        [AllowEmptyCollection()]
        [string[]]$Arguments = @()
    )

    # Historical quoted-array semantics are preserved exactly: the script
    # path and every argument are quoted, so paths and arguments containing
    # spaces survive unchanged.
    $argumentList = @("`"$Script`"")

    foreach ($argument in $Arguments) {
        $argumentList += "`"$argument`""
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName               = [string](Get-DevWSAutoHotkeyPath)
    $startInfo.Arguments              = ($argumentList -join ' ')
    $startInfo.UseShellExecute        = $false
    $startInfo.CreateNoWindow         = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError  = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)

    $process = $null

    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)

        if ($null -eq $process) {
            throw "The AutoHotkey helper process could not be started for '$Script'."
        }

        $streams = Read-DevWSAhkProcessStreams -Process $process

        # Direct-child wait. The P2-E process-lifecycle POC measured
        # Start-Process -Wait (PowerShell 7.6.7, the runtime of every DevWS
        # AHK caller) to return at the DIRECT child's exit while a
        # distinguishable 30 s descendant was still running: it does not wait
        # for descendants despite the documented language, so this preserves
        # the historical observable wait contract. Both shipped helpers
        # (window-helper.ahk, reset-window.ahk) are strictly descendant-free
        # (no Run/RunWait/ProcessClose; static and runtime verified), so the
        # distinction is unobservable for every production call either way. A
        # future helper that spawns descendants whose completion must gate
        # the caller requires an explicit contract review; descendants that
        # merely inherit the pipe writers are already bounded by the pump's
        # finite post-exit drain grace.
        [void]$process.WaitForExit()

        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Output   = [string]$streams.Output
            Error    = [string]$streams.Error
        }
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Invoke-DevWSWindowHelper {
    param([AllowEmptyCollection()][string[]]$Arguments = @())

    return Invoke-DevWSAhk -Script (Get-DevWSWindowHelperPath) -Arguments $Arguments
}

function Invoke-DevWSResetWindowHelper {
    param([AllowEmptyCollection()][string[]]$Arguments = @())

    return Invoke-DevWSAhk -Script (Get-DevWSResetWindowHelperPath) -Arguments $Arguments
}
