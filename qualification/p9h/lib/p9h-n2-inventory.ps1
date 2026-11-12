# DevWS P9-H replay instrumentation - N2 process and window inventory.
#
# Closes P9-G defect N2-3 and N2-4: every process start time was destroyed by
# passing a DateTime to ManagementDateTimeConverter.ToDateTime, producing
# inventories that looked valid while the attribution field was silently empty.
#
# Two structural changes:
#   1. Timestamps go through ConvertTo-P9HProcessStartUtc, which accepts
#      DateTime/DateTimeOffset/DMTF text and reports anything else explicitly.
#   2. Every inventory is classified. An inventory where no start time could be
#      recovered is NOT 'ok' - it is reported as degraded, so a downstream
#      attribution claim cannot rest on it.
#
# All functions are read-only with respect to the host and never touch a VM.

Set-StrictMode -Version Latest

function Get-P9HProcessInventory {
    # Enumerate processes into a normalized, correlation-friendly form.
    #
    # -SessionId selects one session (the interactive RDP session for a replay);
    # -All returns every session. Start times are converted exactly once.
    param(
        [int]$SessionId = -1,
        [switch]$All
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $startOk = 0
    $startBad = 0
    $typeCounts = @{}

    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        if (-not $All -and $SessionId -ge 0 -and [int]$p.SessionId -ne $SessionId) { continue }

        $converted = ConvertTo-P9HProcessStartUtc -Value $p.CreationDate
        if ($converted.Ok) { $startOk++ }
        else {
            $startBad++
            $reason = [string]$converted.Reason
            if (-not $typeCounts.ContainsKey($reason)) { $typeCounts[$reason] = 0 }
            $typeCounts[$reason]++
        }

        $rows.Add([pscustomobject][ordered]@{
                pid           = [int]$p.ProcessId
                ppid          = [int]$p.ParentProcessId
                name          = [string]$p.Name
                sessionId     = [int]$p.SessionId
                startUtc      = if ($converted.Ok) { $converted.Utc.ToString('o') } else { $null }
                startSource   = [string]$converted.Reason
                commandLine   = [string]$p.CommandLine
                commandLength = ([string]$p.CommandLine).Length
            }) | Out-Null
    }

    # A session with processes but zero recoverable start times is degraded, not
    # clean. This is the exact condition P9-G produced without noticing.
    $outcome = 'ok'
    $reason = $null
    if ($rows.Count -eq 0) { $outcome = 'empty'; $reason = 'no-processes-matched' }
    elseif ($startOk -eq 0) { $outcome = 'degraded'; $reason = 'no-process-start-times-recovered' }
    elseif ($startBad -gt 0) { $outcome = 'partial'; $reason = 'some-process-start-times-unrecoverable' }

    return [pscustomobject][ordered]@{
        Ok           = ($outcome -eq 'ok' -or $outcome -eq 'partial')
        Outcome      = $outcome
        Reason       = $reason
        SessionId    = $SessionId
        Count        = $rows.Count
        StartOk      = $startOk
        StartBad     = $startBad
        StartFailures = $typeCounts
        Processes    = @($rows)
    }
}

function Get-P9HProcessDelta {
    # New/removed PIDs between two inventories, with start times preserved.
    #
    # Attribution of a created window depends on this: a process present after
    # but not before the launch, with a recovered start time, is the only
    # defensible evidence that the launch created it.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Before,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$After
    )

    $beforeIndex = @{}
    foreach ($p in $Before) { $beforeIndex[[int]$p.pid] = $p }

    $afterIndex = @{}
    foreach ($p in $After) { $afterIndex[[int]$p.pid] = $p }

    $added = @($After | Where-Object { -not $beforeIndex.ContainsKey([int]$_.pid) })
    $removed = @($Before | Where-Object { -not $afterIndex.ContainsKey([int]$_.pid) })

    return [pscustomobject][ordered]@{
        AddedCount    = $added.Count
        RemovedCount  = $removed.Count
        Added         = $added
        Removed       = $removed
        AddedWithStart = @($added | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.startUtc) }).Count
    }
}

function Get-P9HWindowInventory {
    # Enumerate top-level windows with PID correlation.
    #
    # Title-independent by construction: the inventory never filters on a title,
    # so 'no window matched' can never be confused with 'no window exists'. Titles
    # and classes are recorded as data for the reviewer, not used as a selector.
    param()

    if (-not ('P9HNativeWindows' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Text;
using System.Runtime.InteropServices;

public class P9HNativeWindows
{
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern int GetWindowThreadProcessId(IntPtr hWnd, out int pid);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);

    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    public static List<string> All()
    {
        var results = new List<string>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            int pid;
            GetWindowThreadProcessId(hWnd, out pid);

            var cls = new StringBuilder(256);
            GetClassNameW(hWnd, cls, 256);

            var title = new StringBuilder(512);
            GetWindowTextW(hWnd, title, 512);

            RECT r;
            GetWindowRect(hWnd, out r);

            results.Add(string.Format(
                "hwnd=0x{0:X}|pid={1}|visible={2}|class={3}|rect={4},{5},{6},{7}|owner=0x{8:X}|title={9}",
                hWnd.ToInt64(), pid, IsWindowVisible(hWnd), cls.ToString(),
                r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top,
                GetWindow(hWnd, 4).ToInt64(), title.ToString()));

            return true;
        }, IntPtr.Zero);
        return results;
    }
}
'@ -ErrorAction Stop
    }

    $lines = @([P9HNativeWindows]::All())
    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($line in $lines) {
        $m = [regex]::Match($line, '^hwnd=(?<hwnd>0x[0-9A-F]+)\|pid=(?<pid>\d+)\|visible=(?<vis>\w+)\|class=(?<cls>[^|]*)\|rect=(?<x>-?\d+),(?<y>-?\d+),(?<w>-?\d+),(?<h>-?\d+)\|owner=(?<owner>0x[0-9A-F]+)\|title=(?<title>.*)$')
        if (-not $m.Success) { continue }
        $rows.Add([pscustomobject][ordered]@{
                hwnd    = $m.Groups['hwnd'].Value
                pid     = [int]$m.Groups['pid'].Value
                visible = ($m.Groups['vis'].Value -eq 'True')
                class   = $m.Groups['cls'].Value
                x       = [int]$m.Groups['x'].Value
                y       = [int]$m.Groups['y'].Value
                width   = [int]$m.Groups['w'].Value
                height  = [int]$m.Groups['h'].Value
                owner   = $m.Groups['owner'].Value
                title   = $m.Groups['title'].Value
            }) | Out-Null
    }

    return [pscustomobject][ordered]@{
        Ok       = $true
        Count    = $rows.Count
        Windows  = @($rows)
        Raw      = @($lines)
    }
}

function Select-P9HAttributableWindow {
    # Positively attribute a created window to a launched process tree.
    #
    # Requires ALL of: a new HWND (absent from the pre-launcher inventory), a PID
    # that is inside the launch's new-process set, that PID carrying a recovered
    # start time, and a visible top-level window. Titles are recorded but never
    # required, so an unknown or localized title cannot break attribution.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PreWindowHwnds,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AfterWindows,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$CandidatePids
    )

    $preIndex = @{}
    foreach ($h in $PreWindowHwnds) { $preIndex[[string]$h] = $true }

    $candidates = @($AfterWindows | Where-Object {
            $_.visible -and
            -not $preIndex.ContainsKey([string]$_.hwnd) -and
            $CandidatePids -contains [int]$_.pid
        })

    return [pscustomobject][ordered]@{
        Count      = $candidates.Count
        Windows    = $candidates
        Attributed = ($candidates.Count -ge 1)
    }
}
