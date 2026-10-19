// DevWS native monitor interop (Pass 5B).
//
// Read-only declaration of the display-topology surface used by
// src/lib/devws-monitor.ps1 (DevWSMonitorNative). This layer returns raw
// facts only; identity normalization, signature/fingerprint construction and
// reachability policy all live in the PowerShell layer.
//
// Surface:
//   - EnumDisplayMonitors + GetMonitorInfoW
//       -> GDI monitor rectangles, work areas, primary role, effective DPI
//   - QueryDisplayConfig (QDC_ONLY_ACTIVE_PATHS) + DisplayConfigGetDeviceInfo
//       -> active source/target facts: GDI device name, target name,
//          monitor device path, EDID manufacturer/product ids
//
// This file deliberately contains no display-configuration mutation API: no
// display mode/shape changes, no window operation and no process operation of
// any kind. The native layer can observe, never alter.
//
// - Repository/development execution compiles this file lazily with
//   Add-Type -Path through src/lib/devws-native.ps1.
// - Installed execution loads the installer-generated
//   <InstallRoot>\app\native\DevWS.Native.dll from bytes; it never compiles.
//
// Do not duplicate this declaration as an embedded TypeDefinition string.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;

public static class DevWSMonitorNative
{
    // Bounded coherence retry for QueryDisplayConfig. The documented contract
    // requires re-reading the buffer sizes and retrying when the topology
    // changed between GetDisplayConfigBufferSizes and QueryDisplayConfig
    // (ERROR_INSUFFICIENT_BUFFER). Three attempts total; never unbounded.
    public const int MaxSnapshotAttempts = 3;
    public const int ErrorInsufficientBuffer = 122;
    public const uint QdcOnlyActivePaths = 2;

    private const int MdtEffectiveDpi = 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "GetMonitorInfoW")]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_RATIONAL
    {
        public uint Numerator;
        public uint Denominator;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_PATH_SOURCE_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_PATH_TARGET_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint outputTechnology;
        public uint rotation;
        public uint scaling;
        public DISPLAYCONFIG_RATIONAL refreshRate;
        public uint scanLineOrdering;
        [MarshalAs(UnmanagedType.Bool)]
        public bool targetAvailable;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_PATH_INFO
    {
        public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
        public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
        public uint flags;
    }

    // Explicit layout: the native union is read both as a source mode
    // (position/size) and as a target mode (video signal / active size).
    [StructLayout(LayoutKind.Explicit, Size = 64)]
    private struct DISPLAYCONFIG_MODE_INFO
    {
        [FieldOffset(0)] public uint infoType;
        [FieldOffset(4)] public uint id;
        [FieldOffset(8)] public uint luidLow;
        [FieldOffset(12)] public int luidHigh;
        [FieldOffset(16)] public uint srcWidth;
        [FieldOffset(20)] public uint srcHeight;
        [FieldOffset(24)] public uint srcPixelFormat;
        [FieldOffset(28)] public int srcPosX;
        [FieldOffset(32)] public int srcPosY;
        [FieldOffset(16)] public ulong tgtPixelRate;
        [FieldOffset(24)] public uint tgtHSyncNumerator;
        [FieldOffset(28)] public uint tgtHSyncDenominator;
        [FieldOffset(32)] public uint tgtVSyncNumerator;
        [FieldOffset(36)] public uint tgtVSyncDenominator;
        [FieldOffset(40)] public uint tgtActiveWidth;
        [FieldOffset(44)] public uint tgtActiveHeight;
        [FieldOffset(48)] public uint tgtTotalWidth;
        [FieldOffset(52)] public uint tgtTotalHeight;
        [FieldOffset(56)] public uint tgtVideoStandard;
    }

    [DllImport("user32.dll")]
    private static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);

    [DllImport("user32.dll")]
    private static extern int QueryDisplayConfig(
        uint flags,
        ref uint numPathArrayElements,
        [In, Out] DISPLAYCONFIG_PATH_INFO[] pathInfoArray,
        ref uint numModeInfoArrayElements,
        [In, Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray,
        IntPtr currentTopologyId);

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_DEVICE_INFO_HEADER
    {
        public uint type;
        public uint size;
        public LUID adapterId;
        public uint id;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DISPLAYCONFIG_SOURCE_DEVICE_NAME
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string viewGdiDeviceName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DISPLAYCONFIG_TARGET_DEVICE_NAME
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public uint flags;
        public uint outputTechnology;
        public ushort edidManufactureId;
        public ushort edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string monitorDevicePath;
    }

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DEVICE_NAME requestPacket);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_TARGET_DEVICE_NAME requestPacket);

    public static DevWSMonitorGdiRow[] GetGdiMonitorRows()
    {
        var rows = new List<DevWSMonitorGdiRow>();

        MonitorEnumProc callback = delegate (IntPtr hMonitor, IntPtr hdc, IntPtr lprcMonitor, IntPtr dwData)
        {
            var info = new MONITORINFOEX();
            info.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));

            if (!GetMonitorInfo(hMonitor, ref info))
            {
                return true;
            }

            var row = new DevWSMonitorGdiRow();
            row.HMonitor = hMonitor.ToInt64();
            row.GdiDeviceName = info.szDevice;
            row.Primary = (info.dwFlags & 1u) != 0;
            row.MonitorLeft = info.rcMonitor.Left;
            row.MonitorTop = info.rcMonitor.Top;
            row.MonitorRight = info.rcMonitor.Right;
            row.MonitorBottom = info.rcMonitor.Bottom;
            row.WorkLeft = info.rcWork.Left;
            row.WorkTop = info.rcWork.Top;
            row.WorkRight = info.rcWork.Right;
            row.WorkBottom = info.rcWork.Bottom;

            try
            {
                uint dpiX;
                uint dpiY;
                int hr = GetDpiForMonitor(hMonitor, MdtEffectiveDpi, out dpiX, out dpiY);

                if (hr == 0)
                {
                    row.DpiOk = true;
                    row.DpiEffectiveX = dpiX;
                    row.DpiEffectiveY = dpiY;
                }
            }
            catch
            {
                // DPI is diagnostic only; a missing shcore surface never fails
                // the topology snapshot.
            }

            rows.Add(row);
            return true;
        };

        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
        return rows.ToArray();
    }

    public static DevWSMonitorPathSnapshot GetActivePathSnapshot()
    {
        int lastError = 0;

        for (int attempt = 1; attempt <= MaxSnapshotAttempts; attempt++)
        {
            uint pathCount = 0;
            uint modeCount = 0;

            int error = GetDisplayConfigBufferSizes(QdcOnlyActivePaths, out pathCount, out modeCount);

            if (error != 0)
            {
                lastError = error;
                continue;
            }

            if (pathCount == 0)
            {
                pathCount = 1;
            }

            if (modeCount == 0)
            {
                modeCount = 1;
            }

            var paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
            var modes = new DISPLAYCONFIG_MODE_INFO[modeCount];

            uint returnedPaths = pathCount;
            uint returnedModes = modeCount;

            error = QueryDisplayConfig(QdcOnlyActivePaths, ref returnedPaths, paths, ref returnedModes, modes, IntPtr.Zero);

            if (error == ErrorInsufficientBuffer)
            {
                // Topology changed between the size query and the data query;
                // re-read the sizes and retry within the bounded attempt count.
                lastError = error;
                continue;
            }

            if (error != 0)
            {
                return new DevWSMonitorPathSnapshot
                {
                    Paths = new DevWSMonitorPathRow[0],
                    Attempts = attempt,
                    ErrorCode = error
                };
            }

            var rows = new List<DevWSMonitorPathRow>();

            for (int index = 0; index < returnedPaths; index++)
            {
                var path = paths[index];
                var row = new DevWSMonitorPathRow();

                row.SourceAdapterLuid = FormatLuid(path.sourceInfo.adapterId);
                row.SourceId = path.sourceInfo.id;
                row.TargetAdapterLuid = FormatLuid(path.targetInfo.adapterId);
                row.TargetId = path.targetInfo.id;
                row.OutputTechnology = path.targetInfo.outputTechnology;
                row.TargetAvailable = path.targetInfo.targetAvailable;

                var sourceName = new DISPLAYCONFIG_SOURCE_DEVICE_NAME();
                sourceName.header.type = 1;
                sourceName.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DEVICE_NAME));
                sourceName.header.adapterId = path.sourceInfo.adapterId;
                sourceName.header.id = path.sourceInfo.id;

                int sourceHr = DisplayConfigGetDeviceInfo(ref sourceName);
                row.GdiDeviceName = sourceHr == 0 ? sourceName.viewGdiDeviceName : null;

                var targetName = new DISPLAYCONFIG_TARGET_DEVICE_NAME();
                targetName.header.type = 2;
                targetName.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_TARGET_DEVICE_NAME));
                targetName.header.adapterId = path.targetInfo.adapterId;
                targetName.header.id = path.targetInfo.id;

                int targetHr = DisplayConfigGetDeviceInfo(ref targetName);

                if (targetHr == 0)
                {
                    row.OutputTechnology = targetName.outputTechnology;
                    row.FriendlyName = targetName.monitorFriendlyDeviceName;
                    row.MonitorDevicePath = targetName.monitorDevicePath;
                    row.EdidManufactureId = targetName.edidManufactureId;
                    row.EdidProductCodeId = targetName.edidProductCodeId;
                    row.ConnectorInstance = targetName.connectorInstance;
                }

                uint rawSourceIndex = path.sourceInfo.modeInfoIdx;
                uint rawTargetIndex = path.targetInfo.modeInfoIdx;
                int sourceIndex = rawSourceIndex == 0xFFFFFFFFu ? -1 : (int)(rawSourceIndex & 0xFFFF);
                int targetIndex = rawTargetIndex == 0xFFFFFFFFu ? -1 : (int)rawTargetIndex;

                if (sourceIndex >= returnedModes)
                {
                    sourceIndex = -1;
                }

                if (targetIndex >= returnedModes)
                {
                    targetIndex = -1;
                }

                if (sourceIndex >= 0 && modes[sourceIndex].infoType == 1)
                {
                    row.SourceModePositionX = modes[sourceIndex].srcPosX;
                    row.SourceModePositionY = modes[sourceIndex].srcPosY;
                    row.SourceModeWidth = (int)modes[sourceIndex].srcWidth;
                    row.SourceModeHeight = (int)modes[sourceIndex].srcHeight;
                }

                if (targetIndex >= 0 && modes[targetIndex].infoType == 2)
                {
                    row.TargetActiveWidth = (int)modes[targetIndex].tgtActiveWidth;
                    row.TargetActiveHeight = (int)modes[targetIndex].tgtActiveHeight;
                }

                rows.Add(row);
            }

            return new DevWSMonitorPathSnapshot
            {
                Paths = rows.ToArray(),
                Attempts = attempt,
                ErrorCode = 0
            };
        }

        return new DevWSMonitorPathSnapshot
        {
            Paths = new DevWSMonitorPathRow[0],
            Attempts = MaxSnapshotAttempts,
            ErrorCode = lastError
        };
    }

    private static string FormatLuid(LUID luid)
    {
        return luid.HighPart.ToString("X8", CultureInfo.InvariantCulture) + ":" +
               luid.LowPart.ToString("X8", CultureInfo.InvariantCulture);
    }
}

// Raw fact records (top-level so both PowerShell type resolution and the
// installer assembly validation address them by their plain names).

public sealed class DevWSMonitorGdiRow
{
    public long HMonitor { get; internal set; }
    public string GdiDeviceName { get; internal set; }
    public bool Primary { get; internal set; }
    public int MonitorLeft { get; internal set; }
    public int MonitorTop { get; internal set; }
    public int MonitorRight { get; internal set; }
    public int MonitorBottom { get; internal set; }
    public int WorkLeft { get; internal set; }
    public int WorkTop { get; internal set; }
    public int WorkRight { get; internal set; }
    public int WorkBottom { get; internal set; }
    public bool DpiOk { get; internal set; }
    public uint DpiEffectiveX { get; internal set; }
    public uint DpiEffectiveY { get; internal set; }
}

public sealed class DevWSMonitorPathRow
{
    public string GdiDeviceName { get; internal set; }
    public string SourceAdapterLuid { get; internal set; }
    public uint SourceId { get; internal set; }
    public string TargetAdapterLuid { get; internal set; }
    public uint TargetId { get; internal set; }
    public uint OutputTechnology { get; internal set; }
    public bool TargetAvailable { get; internal set; }
    public string FriendlyName { get; internal set; }
    public string MonitorDevicePath { get; internal set; }
    public ushort EdidManufactureId { get; internal set; }
    public ushort EdidProductCodeId { get; internal set; }
    public uint ConnectorInstance { get; internal set; }
    public int SourceModePositionX { get; internal set; }
    public int SourceModePositionY { get; internal set; }
    public int SourceModeWidth { get; internal set; }
    public int SourceModeHeight { get; internal set; }
    public int TargetActiveWidth { get; internal set; }
    public int TargetActiveHeight { get; internal set; }
}

public sealed class DevWSMonitorPathSnapshot
{
    public DevWSMonitorPathRow[] Paths { get; internal set; }
    public int Attempts { get; internal set; }
    public int ErrorCode { get; internal set; }
}
