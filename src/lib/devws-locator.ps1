# Temporary locator-tab lifecycle.
#
# Solved problem: while a command tab is active the top-level Win32 title is
# dynamic, so a managed terminal cannot be found by its configured title
# alone. A locator tab is a temporary, uniquely titled, title-stable tab that
# attaches to the named window (or creates it) and exposes the owning
# top-level HWND through the in-process exact-title lookup immediately after
# creation.
#
# Verified on the installed Windows Terminal:
# - `wt -w <windowId> new-tab ... --title <unique> --suppressApplicationTitle
#   pwsh` attaches to the existing named window or creates it, and activates
#   the new tab.
# - `wt close-pane` is NOT supported (it opens a tab running `close-pane`),
#   so removal invokes the tab's UI Automation "Close Tab" button instead
#   (verified working).

function New-DevWSLocatorTitle {
    param([Parameter(Mandatory)][string]$WindowId)

    $suffix = [guid]::NewGuid().ToString("N").Substring(0, 8)

    return "DevWS-LOCATOR-$WindowId-$suffix"
}

function Test-DevWSLocatorOwnsWindow {
    param(
        [Parameter(Mandatory)]
        $TabNames,
        [Parameter(Mandatory)]
        [string]$LocatorTitle
    )

    $names = @()

    foreach ($name in $TabNames) {
        $names += [string]$name
    }

    if ($names.Count -ne 1) {
        return $false
    }

    return ($names[0] -ieq $LocatorTitle)
}

function Start-DevWSLocator {
    param(
        [Parameter(Mandatory)]
        [string]$WindowId,
        [int]$TimeoutSeconds = 10
    )

    $title = New-DevWSLocatorTitle -WindowId $WindowId

    # Trusted launcher + trusted shell token: the locator can run from High
    # contexts, so it never relies on the per-user alias pathname or a bare
    # `pwsh` resolved through PATH.
    & (Resolve-DevWSTrustedWindowsTerminalPath) `
        -w $WindowId `
        new-tab `
            -p "PowerShell" `
            --title $title `
            --suppressApplicationTitle `
            (Get-DevWSPowerShellLaunchToken) -NoLogo -NoProfile | Out-Null

    # The locator tab is active right after creation, so its exact title
    # exposes the owning top-level HWND through the in-process native lookup.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $hwnd = 0

    while ((Get-Date) -lt $deadline -and -not $hwnd) {
        $hwnd = Find-DevWSVisibleWindowHwndByExactTitle -Title $title

        if (-not $hwnd) {
            Start-Sleep -Milliseconds 150
        }
    }

    if (-not $hwnd) {
        throw "Locator tab '$title' did not appear in window '$WindowId'."
    }

    $tabNames  = Get-DevWSPresentTabNamesFromHwnd -Hwnd $hwnd
    $ownsWindow = Test-DevWSLocatorOwnsWindow -TabNames $tabNames -LocatorTitle $title

    return [pscustomobject]@{
        WindowId   = $WindowId
        Title      = $title
        Hwnd       = [long]$hwnd
        OwnsWindow = $ownsWindow
    }
}

function Remove-DevWSLocator {
    param(
        [Parameter(Mandatory)]
        $Locator
    )

    try {
        [void](Remove-DevWSTabByName -Name $Locator.Title)

        if (-not (Wait-DevWSTabGone -Name $Locator.Title -TimeoutSeconds 5)) {
            return [pscustomobject]@{
                Removed = $false
                Message = "Locator tab '$($Locator.Title)' did not disappear after closing it."
            }
        }

        return [pscustomobject]@{
            Removed = $true
            Message = "OK"
        }
    }
    catch {
        return [pscustomobject]@{
            Removed = $false
            Message = $_.Exception.Message
        }
    }
}
