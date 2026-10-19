# DevWS terminal identity: HWND validation and discovery.
#
# Discovery is either
#   A. non-creating: validated runtime state, then UI Automation tab names; or
#   B. locator-assisted (see devws-locator.ps1), used by destructive reset and
#      as a fallback where a present window must still be attached to.
#
# A stored HWND is valid only when it still exists, belongs to
# WindowsTerminal, and is associated with the configured windowId tab.
# The pure validators below are unit-testable without any GUI state.

function Test-DevWSProcessNameIsWindowsTerminal {
    param([string]$ProcessName)

    if ([string]::IsNullOrWhiteSpace($ProcessName)) {
        return $false
    }

    $name = $ProcessName.Trim()

    if ($name.EndsWith(".exe", [StringComparison]::OrdinalIgnoreCase)) {
        $name = $name.Substring(0, $name.Length - 4)
    }

    return ($name -ieq "WindowsTerminal")
}

function Test-DevWSHwndAssociation {
    param(
        [Parameter(Mandatory)]
        [string]$WindowId,
        [string]$ExpectedWindowId,
        [string]$ProcessName,
        $TabNames,
        [switch]$RequireProcess
    )

    # A state entry recorded for another managed terminal never validates.
    if (-not [string]::IsNullOrWhiteSpace($ExpectedWindowId) -and -not ($ExpectedWindowId -ieq $WindowId)) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($ProcessName)) {
        if (-not (Test-DevWSProcessNameIsWindowsTerminal -ProcessName $ProcessName)) {
            return $false
        }
    }
    elseif ($RequireProcess) {
        return $false
    }

    # Pass 6C: association accepts the FULL managed tab-title family for the
    # windowId (exact base title or any canonical <windowId>#DevWS:<N> member),
    # so a stored or recovered HWND stays valid when tab 0 is gone. Lookalike
    # names that do not parse canonically still fail.
    if (-not (Test-DevWSTerminalTitleFamily -WindowId $WindowId -TabNames $TabNames)) {
        return $false
    }

    return $true
}

function Select-DevWSTerminalHwndCandidate {
    param(
        [AllowEmptyCollection()]
        $Candidates = @(),
        [Parameter(Mandatory)]
        [string]$WindowId,
        [switch]$RequireProcess
    )

    foreach ($candidate in @($Candidates)) {
        if ($null -eq $candidate) {
            continue
        }

        if (Test-DevWSHwndAssociation `
            -WindowId $WindowId `
            -ExpectedWindowId $candidate.ExpectedWindowId `
            -ProcessName $candidate.ProcessName `
            -TabNames $candidate.TabNames `
            -RequireProcess:$RequireProcess) {
            return [pscustomobject]@{
                Hwnd        = [long]$candidate.Hwnd
                ProcessName = $candidate.ProcessName
            }
        }
    }

    return $null
}

function Test-DevWSCreatedTabCount {
    param(
        [Parameter(Mandatory)]
        [int]$ActualCount,
        [Parameter(Mandatory)]
        [int]$ConfiguredCount
    )

    # A freshly created managed window must not hold more tabs than were
    # configured; more means `wt -w` attached to an already-existing window.
    #
    # The count is always a raw TabItem count (duplicates preserved), never a
    # deduplicated name set: every configured tab shares the windowId title.
    #
    # A temporarily lower count is tolerated because UI Automation
    # materialization can lag; callers wait briefly via
    # Wait-DevWSTabCountFromHwnd before applying this guard.
    return ($ActualCount -le $ConfiguredCount)
}

function Get-DevWSHwndCandidate {
    param(
        [Parameter(Mandatory)]
        [long]$Hwnd,
        [string]$ExpectedWindowId
    )

    if (-not (Test-DevWSWindowHwnd -Hwnd $Hwnd)) {
        return $null
    }

    return [pscustomobject]@{
        Hwnd             = $Hwnd
        ExpectedWindowId = $ExpectedWindowId
        ProcessName      = (Get-DevWSWindowHwndProcessName -Hwnd $Hwnd)
        TabNames         = (Get-DevWSPresentTabNamesFromHwnd -Hwnd $Hwnd)
    }
}

function Get-DevWSTerminalHwnd {
    param(
        [Parameter(Mandatory)]
        [string]$WindowId
    )

    $hwnd = Find-DevWSTerminalTopLevelHwnd -WindowId $WindowId

    if (-not $hwnd) {
        return 0
    }

    # Reuse the shared association validator: a UIA-recovered HWND must pass
    # the same identity requirements as a stored HWND (HWND exists, process is
    # WindowsTerminal, scoped tab association matches windowId). A foreign
    # application exposing a same-named tab must never be accepted.
    $candidate = Get-DevWSHwndCandidate -Hwnd $hwnd
    $selected  = Select-DevWSTerminalHwndCandidate `
        -Candidates @($candidate) `
        -WindowId $WindowId `
        -RequireProcess

    if ($null -eq $selected) {
        return 0
    }

    return [long]$selected.Hwnd
}

function Wait-DevWSTerminalHwnd {
    param(
        [Parameter(Mandatory)]
        [string]$WindowId,
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $hwnd = Get-DevWSTerminalHwnd -WindowId $WindowId

        if ($hwnd) {
            return $hwnd
        }

        Start-Sleep -Milliseconds 250
    }

    return 0
}

function Resolve-DevWSTerminalHwnd {
    param(
        [Parameter(Mandatory)]
        [string]$WindowId,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SetId,
        $State,
        [string]$TerminalId
    )

    # 1. Validated runtime state, scoped by set + terminal id so duplicate item
    #    ids in different sets can never share a cached HWND.
    if ($null -ne $State -and -not [string]::IsNullOrWhiteSpace($TerminalId)) {
        $entry = Get-DevWSRuntimeTerminal -State $State -SetId $SetId -Id $TerminalId

        if ($null -ne $entry -and $entry.hwnd) {
            $candidate = Get-DevWSHwndCandidate -Hwnd ([long]$entry.hwnd) -ExpectedWindowId $entry.windowId
            $selected  = Select-DevWSTerminalHwndCandidate `
                -Candidates @($candidate) `
                -WindowId $WindowId `
                -RequireProcess

            if ($null -ne $selected) {
                return [pscustomobject]@{
                    Status = "present"
                    Hwnd   = [long]$selected.Hwnd
                    Source = "state"
                }
            }
        }
    }

    # 2. Non-creating UI Automation discovery by the durable windowId.
    $hwnd = Get-DevWSTerminalHwnd -WindowId $WindowId

    if ($hwnd) {
        return [pscustomobject]@{
            Status = "present"
            Hwnd   = [long]$hwnd
            Source = "uia"
        }
    }

    return [pscustomobject]@{
        Status = "missing"
        Hwnd   = $null
        Source = $null
    }
}
