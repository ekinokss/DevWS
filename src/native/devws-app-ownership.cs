// DevWS native app ownership primitives.
//
// Authoritative declaration of the user32 window-property surface used by
// src/lib/devws-app-ownership.ps1 (DevWSAppOwnershipNative).
//
// - Repository/development execution compiles this file together with the
//   other tracked native sources via src/lib/devws-native.ps1.
// - Installed execution loads the installer-generated
//   <InstallRoot>\app\native\DevWS.Native.dll from bytes; it never compiles.
//
// Do not duplicate this declaration as an embedded TypeDefinition string.

using System;
using System.Runtime.InteropServices;

public static class DevWSAppOwnershipNative
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetPropW(IntPtr hWnd, string lpString, IntPtr hData);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr GetPropW(IntPtr hWnd, string lpString);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr RemovePropW(IntPtr hWnd, string lpString);
}
