// DevWS native window interop.
//
// Single authoritative declaration of the user32 surface used by
// src/lib/devws-window-ops.ps1 (DevWSWindowOpsNative).
//
// - Repository/development execution compiles this file lazily with
//   Add-Type -Path.
// - Installed execution loads the installer-generated
//   <InstallRoot>\app\native\DevWS.Native.dll from bytes; it never compiles.
//
// Do not duplicate this declaration as an embedded TypeDefinition string.

using System;
using System.Runtime.InteropServices;

public static class DevWSWindowOpsNative
{
    public const int SW_RESTORE = 9;

    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool IsZoomed(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);

    public static IntPtr FindWindowByExactTitle(string title)
    {
        // PowerShell coerces $null to an empty class-name string for this
        // P/Invoke, so the NULL class name is supplied inside the native layer.
        return FindWindowW(null, title);
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
}
