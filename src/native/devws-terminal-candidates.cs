using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

// Fast class-scoped top-level window enumeration for managed Windows Terminal
// windows. One EnumWindows pass with the class filter performed in C#; the
// PowerShell side never loops over every top-level window itself (a
// PowerShell-callback enumeration costs ~0.3 ms per top-level window, which is
// tens of milliseconds on a busy desktop and is paid on every launch plan and
// every plan-freshness recheck).
public static class DevWSTerminalNative
{
    private const string WindowsTerminalTopLevelClass = "CASCADIA_HOSTING_WINDOW_CLASS";

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    // Returns every top-level HWND whose window class is the Windows Terminal
    // frame class, in EnumWindows order.
    public static long[] GetWindowsTerminalTopLevelHwnds()
    {
        var result = new List<long>();

        EnumWindows((h, l) =>
        {
            var className = new StringBuilder(256);

            if (GetClassName(h, className, className.Capacity) > 0 &&
                string.Equals(className.ToString(), WindowsTerminalTopLevelClass, StringComparison.Ordinal))
            {
                result.Add(h.ToInt64());
            }

            return true;
        }, IntPtr.Zero);

        return result.ToArray();
    }
}
