# DevWS shared terminal operations (Focus / Capture).
#
# ONE implementation of the terminal-side Focus and Capture policy, shared by:
#   - the short-lived scheduled workers (fallback path):
#       workers\elevated-focus.ps1, workers\elevated-capture.ps1
#   - the persistent elevated broker (normal path):
#       workers\elevated-broker.ps1 (focus-terminals / capture-terminals)
#
# Callers resolve the target set, the enabled terminal definitions (configured
# order) and the runtime state BEFORE invoking these functions, so a host can
# perform all side-effect-free request validation before it accepts an
# operation. The functions below contain no request/result IPC and no config
# reloading: they are pure policy over the supplied inputs.
#
# Focus policy (unchanged from the historic scheduled worker):
#   reverse configured order; exact set-scoped HWND identity; strictly
#   non-creating (missing terminals are skipped); AHK focus; configured
#   activeTab selection; UIA-discovered HWNDs refresh the runtime cache;
#   per-terminal errors aggregate into one actionable failure.
#
# Capture policy (unchanged from the historic scheduled worker):
#   exact identity first; locator-assisted attach when the tab is known but the
#   HWND was not recovered; a locator-only race window is marked MISSING and
#   closed again, never treated as managed; minimized/invalid geometry fails
#   capture; runtime cache refresh when the source is not state; MISSING
#   terminals fail the operation without ever creating anything; geometry is
#   written with a temp file + atomic replace.

function Invoke-DevWSTerminalFocusOperation {
    param(
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Terminals,
        $State
    )

    $errors  = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()

    # Reverse order intentionally: the first configured terminal becomes the
    # final active window. Strictly non-creating: this validates existing
    # terminals through HWND state and UI Automation only. It never invokes
    # `wt`, so a window that disappears mid-operation can never be recreated
    # by focus. No directory validation is performed either.
    $terminalList = @($Terminals)

    for ($i = $terminalList.Count - 1; $i -ge 0; $i--) {
        $terminal = $terminalList[$i]

        try {
            $terminalId = [string]$terminal.id
            $windowId   = [string]$terminal.windowId

            $identity = Resolve-DevWSTerminalHwnd -WindowId $windowId -SetId $SetId -State $State -TerminalId $terminalId

            if ($identity.Status -ne "present") {
                $skipped.Add("terminal '$terminalId' ($windowId)")
                continue
            }

            Focus-DevWSWindowHwnd -Hwnd $identity.Hwnd -Context "terminal '$terminalId' ($windowId)"

            # HWND-scoped UI Automation selection: no `wt`, no creation risk.
            [void](Select-DevWSTabByIndexFromHwnd `
                -Hwnd $identity.Hwnd `
                -Index ([int]$terminal.activeTab) `
                -Context "terminal '$terminalId' ($windowId)")

            if ($identity.Source -eq "uia") {
                Update-DevWSRuntimeTerminal -SetId $SetId -Id $terminalId -WindowId $windowId -Hwnd $identity.Hwnd
            }
        }
        catch {
            $errors.Add("Terminal '$($terminal.id)' in set '$SetId': $($_.Exception.Message)")
        }
    }

    if ($errors.Count -gt 0) {
        throw ($errors -join " | ")
    }

    if ($skipped.Count -gt 0) {
        return "OK; skipped missing: $($skipped -join ', ')"
    }

    return "OK"
}

function Invoke-DevWSTerminalCaptureOperation {
    param(
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Terminals,
        $State,
        [string]$OutputPath,
        [string]$SnapshotOutputPath,
        [string]$ClaimPath = ""
    )

    $lines   = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()

    $useClaim = -not [string]::IsNullOrWhiteSpace($ClaimPath)

    if ($useClaim) {
        # Phase 2-B protected publication: the caller owns the claim scope; the
        # artifacts live inside the claimed operation directory. A fresh claim
        # can never contain a stale observation, so no pre-delete is needed.
        if (-not [string]::IsNullOrWhiteSpace($OutputPath) -and (Test-Path -LiteralPath $OutputPath)) {
            throw "A protected capture claim cannot be combined with a caller-supplied output path."
        }

        $OutputPath = Join-Path $ClaimPath "capture-elevated.txt"
        $snapshotPath = Join-Path $ClaimPath "capture-elevated.snapshots.json"
    }
    else {
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            throw "A capture operation requires either -ClaimPath or -OutputPath."
        }

        # Pass 6D legacy path: the optional active-tab snapshot sidecar is a
        # deterministic sibling of the geometry artifact. Stale state is
        # removed before the operation runs so a failed new write can never
        # leak an old observation.
        $snapshotPath = $SnapshotOutputPath

        if ([string]::IsNullOrWhiteSpace($snapshotPath)) {
            $snapshotParent = Split-Path -Parent $OutputPath

            if ([string]::IsNullOrWhiteSpace($snapshotParent)) { $snapshotParent = (Get-Location).Path }

            $snapshotPath = Join-Path $snapshotParent "capture-elevated.snapshots.json"
        }

        Remove-Item -LiteralPath $snapshotPath -Force -ErrorAction SilentlyContinue
    }

    $snapshots = [System.Collections.Generic.List[object]]::new()

    foreach ($terminal in @($Terminals)) {
        $terminalId = [string]$terminal.id
        $windowId   = [string]$terminal.windowId
        $activeTab  = [int]$terminal.activeTab

        $identity = Resolve-DevWSTerminalHwnd -WindowId $windowId -SetId $SetId -State $State -TerminalId $terminalId
        $locator  = $null

        # Pass 6D: read-only active-tab snapshot for an already-resolved exact
        # identity. This observation happens BEFORE any locator-assisted
        # recovery so a temporary locator-selected tab can never become the
        # canonical activeTab. Terminals without a non-creatively recovered
        # HWND are recorded fail-closed as locator-active and are never
        # snapshotted through a locator.
        $snapshotEntry = [ordered]@{
            id                         = $terminalId
            windowId                   = $windowId
            status                     = "locator-active"
            selectedConfiguredTabIndex = $null
        }

        if ($identity.Status -eq "present") {
            try {
                $snapshot = Get-DevWSTerminalTabSnapshotFromHwnd `
                    -Hwnd $identity.Hwnd `
                    -WindowId $windowId `
                    -ConfiguredTabCount (@($terminal.tabs).Count)

                $snapshotEntry.status = [string]$snapshot.Status

                if ($null -ne $snapshot.SelectedConfiguredTabIndex) {
                    $snapshotEntry.selectedConfiguredTabIndex = [int]$snapshot.SelectedConfiguredTabIndex
                }
            }
            catch {
                $snapshotEntry.status = "hwnd-unavailable"
            }
        }

        $snapshots.Add([pscustomobject]$snapshotEntry) | Out-Null

        try {
            if ($identity.Status -ne "present" -and (Find-DevWSTerminalTopLevelHwnd -WindowId $windowId) -gt 0) {
                # Presence is established (a tab exposing a managed title for
                # this windowId exists) but the HWND could not be recovered
                # non-creatively. Attach a temporary locator to the existing
                # window; never create a missing terminal.
                $locator = Start-DevWSLocator -WindowId $windowId

                if ($locator.OwnsWindow) {
                    # The terminal disappeared between the presence check and
                    # the attach, so the locator created a new, locator-only
                    # window. Never capture geometry or runtime state for it;
                    # the finally block closes the locator-only window.
                    $lines.Add("$terminalId|MISSING")
                    $missing.Add("terminal '$terminalId' ($windowId)")
                    continue
                }

                $identity = [pscustomobject]@{
                    Status = "present"
                    Hwnd   = [long]$locator.Hwnd
                    Source = "locator"
                }
            }

            if ($identity.Status -ne "present") {
                $lines.Add("$terminalId|MISSING")
                $missing.Add("terminal '$terminalId' ($windowId)")
                continue
            }

            $rect = Get-DevWSWindowHwndRect -Hwnd $identity.Hwnd

            if ($null -eq $rect -or -not $rect.Valid) {
                throw "Terminal '$terminalId' ($windowId) is minimized or has invalid geometry."
            }

            $lines.Add("$terminalId|$($rect.x)|$($rect.y)|$($rect.w)|$($rect.h)")

            if ($identity.Source -ne "state") {
                Update-DevWSRuntimeTerminal -SetId $SetId -Id $terminalId -WindowId $windowId -Hwnd $identity.Hwnd
            }
        }
        finally {
            if ($null -ne $locator) {
                if ($locator.OwnsWindow) {
                    # Locator-only window created by the race: close it entirely.
                    # Nothing was captured or persisted for this terminal.
                    if (Test-DevWSWindowHwnd -Hwnd $locator.Hwnd) {
                        Close-DevWSWindowHwnd `
                            -Hwnd $locator.Hwnd `
                            -Context "locator-only window for terminal '$terminalId' ($windowId)"

                        [void](Wait-DevWSWindowHwndGone -Hwnd $locator.Hwnd -TimeoutSeconds 10)
                    }
                }
                else {
                    $cleanup = Remove-DevWSLocator -Locator $locator

                    if (-not $cleanup.Removed) {
                        throw "Locator cleanup failed: $($cleanup.Message)"
                    }

                    # Creating the locator changed the active tab. Restore the
                    # configured activeTab without invoking `wt`; if the window
                    # disappeared, this fails instead of creating anything.
                    [void](Select-DevWSTabByIndexFromHwnd `
                        -Hwnd $locator.Hwnd `
                        -Index $activeTab `
                        -Context "terminal '$terminalId' ($windowId)")
                }
            }
        }
    }

    # Write geometry atomically; report MISSING terminals as a failure without
    # ever creating them. The caller keeps canonical config untouched.
    $tempPath = "$OutputPath.tmp"
    [System.IO.File]::WriteAllLines($tempPath, $lines, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($tempPath, $OutputPath, $true)

    # Pass 6D optional active-tab snapshot sidecar, written with the same
    # temp + atomic replace discipline. Observation, serialization, and write
    # failures are OPTIONAL-state failures: they must never turn a valid
    # geometry capture into a capture failure.
    $snapshotTemp = "$snapshotPath.tmp"

    try {
        $payload = [ordered]@{
            version   = 1
            terminals = $snapshots.ToArray()
        }

        $json = $payload | ConvertTo-Json -Compress -Depth 6

        [System.IO.File]::WriteAllText($snapshotTemp, $json, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($snapshotTemp, $snapshotPath, $true)
    }
    catch {
        Remove-Item -LiteralPath $snapshotTemp -Force -ErrorAction SilentlyContinue
    }

    if ($missing.Count -gt 0) {
        throw "Geometry was not captured for: $($missing -join ', ')."
    }

    return "OK"
}
