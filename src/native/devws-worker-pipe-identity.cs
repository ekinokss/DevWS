using System;
using System.Text;
using System.Runtime.InteropServices;

// Worker pipe peer identity interop for the one-shot worker transport
// (Public Security Phase 2-D).
//
// The Medium caller authenticates the connected High worker from the connected
// pipe handle itself: the kernel-reported server PID, a retained
// minimal-rights process handle, the token integrity/user/session facts, the
// canonical image path, the stable creation time and the token-aware command
// line. PeekNamedPipe provides deadline-driven bounded pipe reads so a stalled
// peer can never block a reader forever.
//
// Token reads reuse the shared DevWSPrivilegeNative members (OpenProcessToken,
// GetTokenInformation, ConvertSidToStringSid, GetCurrentProcess) from the same
// generated assembly.
public static class DevWSWorkerPipeIdentityNative
{
    // PROCESS_QUERY_LIMITED_INFORMATION: the minimal query right that still
    // allows image-path, command-line and token queries for same-user targets.
    public const uint ProcessQueryLimitedInformation = 0x1000;

    // TOKEN_INFORMATION_CLASS values used by the shared identity policy.
    public const int TokenUserClass = 1;
    public const int TokenSessionIdClass = 12;
    public const int TokenIntegrityLevelClass = 25;

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeServerProcessId(IntPtr hPipe, out uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeClientProcessId(IntPtr hPipe, out uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool QueryFullProcessImageNameW(IntPtr h, uint flags, StringBuilder buffer, ref uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessTimes(IntPtr h, out long creation, out long exit, out long kernel, out long user);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool PeekNamedPipe(IntPtr hPipe, IntPtr buffer, uint bufferSize, out uint bytesRead, out uint totalAvail, out uint bytesLeftThisMessage);

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr h, int infoClass, IntPtr info, uint infoLength, out uint returnLength);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int argumentCount);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr h);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FlushFileBuffers(IntPtr hFile);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DuplicateHandle(IntPtr sourceProcess, IntPtr sourceHandle, IntPtr targetProcess, out IntPtr targetHandle, uint desiredAccess, bool inheritHandle, uint options);

    private const uint DuplicateSameAccess = 0x00000002;

    private const int ProcessCommandLineInformationClass = 60;

    public static bool TryGetCommandLine(IntPtr processHandle, out string commandLine)
    {
        commandLine = null;

        uint needed;
        int status = NtQueryInformationProcess(processHandle, ProcessCommandLineInformationClass, IntPtr.Zero, 0, out needed);

        if (needed == 0)
        {
            return false;
        }

        IntPtr buffer = Marshal.AllocHGlobal((int)needed);

        try
        {
            status = NtQueryInformationProcess(processHandle, ProcessCommandLineInformationClass, buffer, needed, out needed);

            if (status != 0)
            {
                return false;
            }

            // UNICODE_STRING { USHORT Length; USHORT MaximumLength; PWSTR Buffer; }
            int length = Marshal.ReadInt16(buffer);
            IntPtr stringPointer = Marshal.ReadIntPtr(buffer, 8);

            if (length <= 0 || stringPointer == IntPtr.Zero)
            {
                return false;
            }

            commandLine = Marshal.PtrToStringUni(stringPointer, length / 2);
            return true;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public static string[] SplitCommandLine(string commandLine)
    {
        if (string.IsNullOrEmpty(commandLine))
        {
            return null;
        }

        int argumentCount;
        IntPtr argv = CommandLineToArgvW(commandLine, out argumentCount);

        if (argv == IntPtr.Zero || argumentCount <= 0)
        {
            return null;
        }

        try
        {
            string[] result = new string[argumentCount];

            for (int index = 0; index < argumentCount; index++)
            {
                IntPtr item = Marshal.ReadIntPtr(argv, index * IntPtr.Size);
                result[index] = Marshal.PtrToStringUni(item) ?? "";
            }

            return result;
        }
        finally
        {
            LocalFree(argv);
        }
    }

    public static bool TryFlushFileBuffers(IntPtr handle, int timeoutMilliseconds)
    {
        // Bounded pipe drain. On a pipe, FlushFileBuffers blocks until the peer
        // has consumed everything the writer sent. It runs on a background
        // thread with a finite Join, and it operates on a DUPLICATE of the
        // handle: the duplicate is owned by the flush operation and is closed
        // when the native call returns, so a timeout can never leave the
        // worker's own handle (or a pooled-and-reused OS handle value) in an
        // ambiguous state. The blocked thread is kept alive by the duplicate
        // handle and simply dies with the process, which exits immediately
        // after this call returns.
        if (handle == IntPtr.Zero)
        {
            return true;
        }

        IntPtr duplicate;

        if (!DuplicateHandle(GetCurrentProcess(), handle, GetCurrentProcess(), out duplicate, 0, false, DuplicateSameAccess))
        {
            return false;
        }

        bool completed = false;

        System.Threading.Thread thread = new System.Threading.Thread(() =>
        {
            try { FlushFileBuffers(duplicate); }
            catch { }

            try { CloseHandle(duplicate); } catch { }
        });

        thread.IsBackground = true;
        thread.Start();

        completed = thread.Join(timeoutMilliseconds);

        return completed;
    }
}

// Uninstall-only process identity interop. The class is part of the tracked
// native assembly so no C# declaration lives in a PowerShell library. It is
// loaded lazily by the uninstaller; normal CLI startup never invokes it.
//
// The read surface returns the image path, token user SID, command line and
// exact kernel creation time. TerminateProcess is exposed only so the caller
// can terminate through the same handle whose identity was just verified; the
// PowerShell policy decides when that is allowed.
public sealed class DevWSProcessIdentityResult
{
    public bool Ok;
    public string Error;
    public long CreationTime;
    public string ImagePath;
    public string CommandLine;
    public string UserSid;
}

public static class DevWSProcessIdentityNative
{
    public const uint ProcessTerminate = 0x0001;
    public const uint ProcessQueryLimitedInformation = 0x1000;
    public const uint Synchronize = 0x00100000;
    public const uint WaitObject0 = 0x00000000;
    public const uint WaitTimeout = 0x00000102;

    private const uint TokenQuery = 0x0008;
    private const int TokenUser = 1;
    private const int ProcessCommandLineInformation = 60;

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetProcessTimes(IntPtr handle, out long creation, out long exit, out long kernel, out long user);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateProcess(IntPtr handle, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool QueryFullProcessImageNameW(IntPtr handle, uint flags, StringBuilder buffer, ref uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint pid);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int argumentCount);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr handle);

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr processHandle, int informationClass, IntPtr information, uint informationLength, out uint returnLength);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr tokenHandle, int informationClass, IntPtr information, uint informationLength, out uint returnLength);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr stringSid);

    public static string[] SplitCommandLine(string commandLine)
    {
        if (string.IsNullOrEmpty(commandLine))
        {
            return null;
        }

        int argumentCount;
        IntPtr argv = CommandLineToArgvW(commandLine, out argumentCount);

        if (argv == IntPtr.Zero || argumentCount <= 0)
        {
            return null;
        }

        try
        {
            string[] result = new string[argumentCount];

            for (int index = 0; index < argumentCount; index++)
            {
                IntPtr item = Marshal.ReadIntPtr(argv, index * IntPtr.Size);
                result[index] = Marshal.PtrToStringUni(item) ?? "";
            }

            return result;
        }
        finally
        {
            LocalFree(argv);
        }
    }

    public static DevWSProcessIdentityResult ReadIdentity(IntPtr processHandle)
    {
        DevWSProcessIdentityResult result = new DevWSProcessIdentityResult();

        long creation;
        long exit;
        long kernel;
        long user;

        if (!GetProcessTimes(processHandle, out creation, out exit, out kernel, out user))
        {
            result.Error = "creation-time-unavailable (win32=" + Marshal.GetLastWin32Error() + ")";
            return result;
        }

        result.CreationTime = creation;

        StringBuilder image = new StringBuilder(32768);
        uint size = (uint)image.Capacity;

        if (!QueryFullProcessImageNameW(processHandle, 0, image, ref size))
        {
            result.Error = "image-path-unavailable (win32=" + Marshal.GetLastWin32Error() + ")";
            return result;
        }

        result.ImagePath = image.ToString(0, (int)size);
        result.CommandLine = TryReadCommandLine(processHandle);
        result.UserSid = TryReadUserSid(processHandle);
        result.Ok = true;
        return result;
    }

    private static string TryReadCommandLine(IntPtr processHandle)
    {
        uint needed;
        int status = NtQueryInformationProcess(processHandle, ProcessCommandLineInformation, IntPtr.Zero, 0, out needed);

        if (needed == 0)
        {
            return null;
        }

        IntPtr buffer = Marshal.AllocHGlobal((int)needed);

        try
        {
            status = NtQueryInformationProcess(processHandle, ProcessCommandLineInformation, buffer, needed, out needed);

            if (status != 0)
            {
                return null;
            }

            int length = Marshal.ReadInt16(buffer);
            int pointerOffset = IntPtr.Size == 8 ? 8 : 4;
            IntPtr stringPointer = Marshal.ReadIntPtr(buffer, pointerOffset);

            if (length <= 0 || stringPointer == IntPtr.Zero)
            {
                return null;
            }

            return Marshal.PtrToStringUni(stringPointer, length / 2);
        }
        catch
        {
            return null;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static string TryReadUserSid(IntPtr processHandle)
    {
        IntPtr token = IntPtr.Zero;

        if (!OpenProcessToken(processHandle, TokenQuery, out token) || token == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            uint needed;
            GetTokenInformation(token, TokenUser, IntPtr.Zero, 0, out needed);

            if (needed == 0)
            {
                return null;
            }

            IntPtr buffer = Marshal.AllocHGlobal((int)needed);

            try
            {
                uint returned;

                if (!GetTokenInformation(token, TokenUser, buffer, needed, out returned))
                {
                    return null;
                }

                IntPtr sid = Marshal.ReadIntPtr(buffer);
                IntPtr stringSid;

                if (sid == IntPtr.Zero || !ConvertSidToStringSidW(sid, out stringSid) || stringSid == IntPtr.Zero)
                {
                    return null;
                }

                try
                {
                    return Marshal.PtrToStringUni(stringSid);
                }
                finally
                {
                    LocalFree(stringSid);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
        catch
        {
            return null;
        }
        finally
        {
            CloseHandle(token);
        }
    }
}
