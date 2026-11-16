using System.Runtime.InteropServices;
using System.Security.Principal;

namespace DevWS.Editor;

public static class IntegrityProbe
{
    private const uint TokenQuery = 0x0008;
    private const int TokenIntegrityLevel = 25;

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(
        IntPtr tokenHandle,
        int tokenInformationClass,
        IntPtr tokenInformation,
        int tokenInformationLength,
        out int returnLength);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "ConvertSidToStringSidW")]
    private static extern bool ConvertSidToStringSid(IntPtr sid, out IntPtr stringSid);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [StructLayout(LayoutKind.Sequential)]
    private struct SidAndAttributes
    {
        public IntPtr Sid;
        public uint Attributes;
    }

    public static string GetIntegrityLevel()
    {
        var token = IntPtr.Zero;
        var buffer = IntPtr.Zero;
        var stringSid = IntPtr.Zero;

        try
        {
            if (!OpenProcessToken(GetCurrentProcess(), TokenQuery, out token))
            {
                return Fallback();
            }

            GetTokenInformation(token, TokenIntegrityLevel, IntPtr.Zero, 0, out var length);
            if (length <= 0)
            {
                return Fallback();
            }

            buffer = Marshal.AllocHGlobal(length);

            if (!GetTokenInformation(token, TokenIntegrityLevel, buffer, length, out _))
            {
                return Fallback();
            }

            var label = Marshal.PtrToStructure<SidAndAttributes>(buffer);

            if (!ConvertSidToStringSid(label.Sid, out stringSid))
            {
                return Fallback();
            }

            var sid = Marshal.PtrToStringUni(stringSid) ?? "";
            return sid switch
            {
                "S-1-16-4096" => "Low",
                "S-1-16-8192" => "Medium",
                "S-1-16-12288" => "High",
                "S-1-16-16384" => "System",
                _ => "Unknown"
            };
        }
        catch
        {
            return Fallback();
        }
        finally
        {
            if (stringSid != IntPtr.Zero) LocalFree(stringSid);
            if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
            if (token != IntPtr.Zero) CloseHandle(token);
        }
    }

    private static string Fallback()
    {
        try
        {
            var identity = WindowsIdentity.GetCurrent();
            var integritySid = identity.Groups?
                .OfType<SecurityIdentifier>()
                .FirstOrDefault(sid => sid.Value.StartsWith("S-1-16-", StringComparison.Ordinal));

            return integritySid?.Value switch
            {
                "S-1-16-4096" => "Low",
                "S-1-16-8192" => "Medium",
                "S-1-16-12288" => "High",
                "S-1-16-16384" => "System",
                _ => "Unknown"
            };
        }
        catch
        {
            return "Unknown";
        }
    }
}
