# HWND-based window operations.
#
# High-frequency operations (existence, process name, restore+move, rectangle
# capture, exact-title lookup) are implemented in-process with user32 P/Invoke,
# so no AutoHotkey helper process is spawned for them. The two retained
# helper-backed operations are focus (window-helper.ahk `focus-hwnd`) and
# close/reset (reset-window.ahk `close-hwnd`). Every operation targets a
# validated top-level HWND directly, so no visible top-level title transition
# is needed.
#
# The user32 declaration is tracked once in src\native\devws-window-ops.cs.
# Repository execution compiles every tracked native source once per process
# through src\lib\devws-native.ps1; installed execution byte-loads the
# installer-generated app\native\DevWS.Native.dll and never compiles.

function Initialize-DevWSWindowOpsNative {
    # Guarded subsystem access to the shared native runtime. Window operations
    # are deliberately independent of the app libraries; the shared loader
    # still brings up every native type in one assembly.
    if ($null -ne ([System.Management.Automation.PSTypeName]'DevWSWindowOpsNative').Type) {
        return
    }

    Initialize-DevWSNativeRuntime
}

function Get-DevWSWindowProcessId {
    # Exact single-HWND lookup; never a global process snapshot.
    param([Parameter(Mandatory)][long]$Hwnd)

    if ($Hwnd -le 0) {
        return 0
    }

    Initialize-DevWSWindowOpsNative
    $procId = [uint32]0
    [void][DevWSWindowOpsNative]::GetWindowThreadProcessId([IntPtr]$Hwnd, [ref]$procId)
    return [int]$procId
}

function Get-DevWSProcessNameById {
    # Single-process .NET lookup; returns $null when the process is gone or
    # cannot be inspected. Never uses CIM or a global process snapshot.
    param([Parameter(Mandatory)][int]$ProcessId)

    if ($ProcessId -le 0) {
        return $null
    }

    $process = $null

    try {
        $process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
        return [string]$process.ProcessName
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Test-DevWSWindowHwnd {
    param([Parameter(Mandatory)][long]$Hwnd)

    if ($Hwnd -le 0) {
        return $false
    }

    Initialize-DevWSWindowOpsNative
    return [bool][DevWSWindowOpsNative]::IsWindow([IntPtr]$Hwnd)
}

function Get-DevWSWindowHwndProcessName {
    param([Parameter(Mandatory)][long]$Hwnd)

    if (-not (Test-DevWSWindowHwnd -Hwnd $Hwnd)) {
        return $null
    }

    $procId = Get-DevWSWindowProcessId -Hwnd $Hwnd

    if ($procId -le 0) {
        return $null
    }

    return Get-DevWSProcessNameById -ProcessId $procId
}

function Restore-DevWSWindowHwnd {
    # WinRestore-equivalent for the move path: only minimized or maximized
    # targets are restored; normal windows are never touched and restoring
    # does not change the z-order.
    param([Parameter(Mandatory)][long]$Hwnd)

    Initialize-DevWSWindowOpsNative
    $ptr = [IntPtr]$Hwnd

    if ([DevWSWindowOpsNative]::IsIconic($ptr) -or [DevWSWindowOpsNative]::IsZoomed($ptr)) {
        [void][DevWSWindowOpsNative]::ShowWindow($ptr, [DevWSWindowOpsNative]::SW_RESTORE)
    }
}

function Set-DevWSWindowHwndPos {
    # Exact-HWND outer-rectangle placement: no z-order change, no activation.
    param(
        [Parameter(Mandatory)][long]$Hwnd,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height
    )

    Initialize-DevWSWindowOpsNative
    $flags = [uint32]([DevWSWindowOpsNative]::SWP_NOZORDER -bor [DevWSWindowOpsNative]::SWP_NOACTIVATE)
    $moved = [DevWSWindowOpsNative]::SetWindowPos([IntPtr]$Hwnd, [IntPtr]::Zero, $X, $Y, $Width, $Height, $flags)

    if (-not $moved) {
        $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SetWindowPos failed for HWND $Hwnd (Win32 error $code)."
    }
}

function Move-DevWSWindowHwnd {
    param(
        [Parameter(Mandatory)][long]$Hwnd,
        [Parameter(Mandatory)]$Layout,
        [string]$Context = "window"
    )

    if (-not (Test-DevWSWindowHwnd -Hwnd $Hwnd)) {
        throw "Could not position $Context by HWND $Hwnd (window does not exist)."
    }

    $x = [int]$Layout.x
    $y = [int]$Layout.y
    $w = [int]$Layout.w
    $h = [int]$Layout.h

    if ($w -le 0 -or $h -le 0) {
        throw "Could not position $Context by HWND $Hwnd (invalid geometry)."
    }

    Restore-DevWSWindowHwnd -Hwnd $Hwnd

    try {
        Set-DevWSWindowHwndPos -Hwnd $Hwnd -X $x -Y $y -Width $w -Height $h
    }
    catch {
        throw "Could not position $Context by HWND $Hwnd ($($_.Exception.Message))."
    }
}

function Find-DevWSVisibleWindowHwndByExactTitle {
    # Native exact-title top-level lookup used by the temporary locator tab.
    # Returns 0 when the title does not resolve to a visible window. The
    # visibility check preserves the former AHK WinExist semantics: hidden
    # helper windows are not valid locator targets. Locator titles are
    # GUID-unique, so a single exact match is expected.
    param([Parameter(Mandatory)][string]$Title)

    Initialize-DevWSWindowOpsNative

    $hwnd = [DevWSWindowOpsNative]::FindWindowByExactTitle($Title)

    if ($hwnd -eq [IntPtr]::Zero) {
        return 0
    }

    if (-not [DevWSWindowOpsNative]::IsWindowVisible($hwnd)) {
        return 0
    }

    return [long]$hwnd
}

function Get-DevWSWindowHwndRect {
    # Native rectangle capture. Mirrors the former AHK rectangle-capture
    # semantics: a missing, hidden, minimized, or invalid-geometry window
    # returns $null.
    param([Parameter(Mandatory)][long]$Hwnd)

    if (-not (Test-DevWSWindowHwnd -Hwnd $Hwnd)) {
        return $null
    }

    Initialize-DevWSWindowOpsNative

    $handle = [IntPtr]$Hwnd

    if (-not [DevWSWindowOpsNative]::IsWindowVisible($handle)) {
        return $null
    }

    if ([DevWSWindowOpsNative]::IsIconic($handle)) {
        return $null
    }

    $rect = New-Object 'DevWSWindowOpsNative+RECT'

    if (-not [DevWSWindowOpsNative]::GetWindowRect($handle, [ref]$rect)) {
        return $null
    }

    $x = $rect.Left
    $y = $rect.Top
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top

    if ($x -le -30000 -or $y -le -30000 -or $w -le 0 -or $h -le 0) {
        return $null
    }

    return [pscustomobject]@{
        Valid = $true
        x     = $x
        y     = $y
        w     = $w
        h     = $h
    }
}

function Focus-DevWSWindowHwnd {
    param(
        [Parameter(Mandatory)][long]$Hwnd,
        [string]$Context = "window"
    )

    $result = Invoke-DevWSWindowHelper -Arguments @("focus-hwnd", [string]$Hwnd)

    if ($result.ExitCode -ne 0) {
        throw "Could not focus $Context by HWND $Hwnd (exit code $($result.ExitCode))."
    }
}

function Close-DevWSWindowHwnd {
    param(
        [Parameter(Mandatory)][long]$Hwnd,
        [string]$Context = "window"
    )

    $result = Invoke-DevWSResetWindowHelper -Arguments @("close-hwnd", [string]$Hwnd)

    if ($result.ExitCode -ne 0) {
        throw "Could not close $Context (HWND $Hwnd); exit code $($result.ExitCode)."
    }
}

function Wait-DevWSWindowHwndGone {
    param(
        [Parameter(Mandatory)][long]$Hwnd,
        [int]$TimeoutSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        if (-not (Test-DevWSWindowHwnd -Hwnd $Hwnd)) {
            return $true
        }

        Start-Sleep -Milliseconds 200
    }

    return $false
}
