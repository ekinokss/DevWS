// DevWS native app-window interop.
//
// Authoritative declaration of the user32 surface used by
// src/lib/devws-app-window.ps1 (DevWSAppWindowNative).
//
// - Repository/development execution compiles this file together with the
//   other tracked native sources via src/lib/devws-native.ps1.
// - Installed execution loads the installer-generated
//   <InstallRoot>\app\native\DevWS.Native.dll from bytes; it never compiles.
//
// Do not duplicate this declaration as an embedded TypeDefinition string.

using System;
using System.Runtime.InteropServices;
using System.Text;

public static class DevWSAppWindowNative
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
}
