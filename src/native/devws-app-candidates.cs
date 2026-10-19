// DevWS native app-window candidate fact acquisition.
//
// Authoritative declaration of DevWSAppWindowCandidate (immutable fact record)
// and DevWSAppWindowCandidateCollector (one EnumWindows pass plus process
// metadata) used by src/lib/devws-app-window.ps1.
//
// C# acquires facts only. Match evaluation, ownership classification and all
// lifecycle policy stay in PowerShell.
//
// - Repository/development execution compiles this file together with the
//   other tracked native sources via src/lib/devws-native.ps1.
// - Installed execution loads the installer-generated
//   <InstallRoot>\app\native\DevWS.Native.dll from bytes; it never compiles.
//
// Semantics preserved from the former PowerShell collector:
//   - one EnumWindows pass, EnumWindows order preserved;
//   - hidden records keep empty title/class and null process metadata;
//   - title/class only for visible HWNDs;
//   - visible PIDs deduplicated and sorted, ProcessName normalized to
//     '<name>.exe';
//   - an inaccessible MainModule degrades the path to empty, never aborts;
//   - disappearing processes are skipped;
//   - includeInvisible=false filters hidden records out (order preserved).

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public sealed class DevWSAppWindowCandidate
{
    public long Hwnd { get; private set; }
    public uint Pid { get; private set; }
    public string ProcessName { get; private set; }
    public string ProcessPath { get; private set; }
    public bool PathUnavailable { get; private set; }
    public bool Visible { get; private set; }
    public string Class { get; private set; }
    public string Title { get; private set; }

    public DevWSAppWindowCandidate(long hwnd, uint pid, string processName, string processPath, bool pathUnavailable, bool visible, string cls, string title)
    {
        Hwnd = hwnd;
        Pid = pid;
        ProcessName = processName;
        ProcessPath = processPath;
        PathUnavailable = pathUnavailable;
        Visible = visible;
        Class = cls;
        Title = title;
    }
}

public static class DevWSAppWindowCandidateCollector
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    private sealed class RawWindow
    {
        public long Hwnd;
        public uint Pid;
        public bool Visible;
        public string Title;
        public string Class;
    }

    public static DevWSAppWindowCandidate[] CollectAppWindowCandidates(bool includeInvisible)
    {
        List<RawWindow> raw = new List<RawWindow>();

        EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
        {
            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);

            bool visible = IsWindowVisible(hWnd);
            string title = "";
            string cls = "";

            if (visible)
            {
                StringBuilder titleBuffer = new StringBuilder(600);
                GetWindowTextW(hWnd, titleBuffer, titleBuffer.Capacity);
                title = titleBuffer.ToString();

                StringBuilder classBuffer = new StringBuilder(300);
                GetClassNameW(hWnd, classBuffer, classBuffer.Capacity);
                cls = classBuffer.ToString();
            }

            raw.Add(new RawWindow { Hwnd = hWnd.ToInt64(), Pid = pid, Visible = visible, Title = title, Class = cls });
            return true;
        }, IntPtr.Zero);

        SortedSet<uint> visiblePids = new SortedSet<uint>();
        foreach (RawWindow window in raw)
        {
            if (window.Visible)
            {
                visiblePids.Add(window.Pid);
            }
        }

        // pid -> [name, path]; an entry exists only when name or path is non-blank.
        Dictionary<uint, string[]> metadata = new Dictionary<uint, string[]>();

        foreach (uint processId in visiblePids)
        {
            Process process = null;

            try
            {
                process = Process.GetProcessById((int)processId);
            }
            catch
            {
                continue;
            }

            try
            {
                string name = "";
                string path = "";

                try { name = process.ProcessName; } catch { name = ""; }
                if (name == null) { name = ""; }

                if (!string.IsNullOrWhiteSpace(name) && !name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                {
                    name = name + ".exe";
                }

                try { path = process.MainModule.FileName; } catch { path = ""; }
                if (path == null) { path = ""; }

                if (string.IsNullOrWhiteSpace(name) && string.IsNullOrWhiteSpace(path))
                {
                    continue;
                }

                metadata[processId] = new string[] { name, path };
            }
            finally
            {
                process.Dispose();
            }
        }

        List<DevWSAppWindowCandidate> candidates = new List<DevWSAppWindowCandidate>();

        foreach (RawWindow window in raw)
        {
            if (!window.Visible)
            {
                if (!includeInvisible)
                {
                    continue;
                }

                candidates.Add(new DevWSAppWindowCandidate(window.Hwnd, window.Pid, null, null, true, false, "", ""));
                continue;
            }

            string processName = null;
            string processPath = null;
            string[] values;

            if (metadata.TryGetValue(window.Pid, out values))
            {
                processName = values[0];
                processPath = values[1];
            }

            candidates.Add(new DevWSAppWindowCandidate(window.Hwnd, window.Pid, processName, processPath, string.IsNullOrWhiteSpace(processPath), true, window.Class, window.Title));
        }

        return candidates.ToArray();
    }
}
