using System;
using System.Runtime.InteropServices;

// Secure named-pipe server creation for the elevated broker.
//
// The .NET NamedPipeServerStream ACL path (NamedPipeServerStreamAcl.Create)
// requires SeSecurityPrivilege on this machine and fails with "a required
// privilege is not held". Raw CreateNamedPipeW with an explicit SDDL string is
// the proven mechanism for the cross-integrity case:
//
//   medium coordinator -> high broker
//
// The caller supplies the SDDL (current user + SYSTEM full access, medium
// mandatory label) and wraps the returned handle in a Managed
// NamedPipeServerStream.
public static class DevWSBrokerPipeNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct SECURITY_ATTRIBUTES
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        public bool bInheritHandle;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateNamedPipeW(string lpName, uint dwOpenMode, uint dwPipeMode,
        uint nMaxInstances, uint nOutBufferSize, uint nInBufferSize, uint nDefaultTimeOut,
        ref SECURITY_ATTRIBUTES lpSecurityAttributes);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string stringSecurityDescriptor,
        uint stringSDRevision, out IntPtr securityDescriptor, out uint securityDescriptorSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr hMem);

    public static bool TryCreateSecurePipe(string pipeName, string sddl, out IntPtr pipeHandle, out int win32Error)
    {
        pipeHandle = IntPtr.Zero;
        win32Error = 0;

        IntPtr descriptor;
        uint descriptorSize;

        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, out descriptor, out descriptorSize))
        {
            win32Error = Marshal.GetLastWin32Error();
            return false;
        }

        try
        {
            var attributes = new SECURITY_ATTRIBUTES();
            attributes.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            attributes.lpSecurityDescriptor = descriptor;
            attributes.bInheritHandle = false;

            // PIPE_ACCESS_DUPLEX = 0x3;
            // PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT = 0x0.
            IntPtr handle = CreateNamedPipeW(
                @"\\.\pipe\" + pipeName,
                0x3,
                0x0,
                1,
                65536,
                65536,
                0,
                ref attributes);

            if (handle == IntPtr.Zero || handle == new IntPtr(-1))
            {
                win32Error = Marshal.GetLastWin32Error();
                return false;
            }

            pipeHandle = handle;
            return true;
        }
        finally
        {
            LocalFree(descriptor);
        }
    }
}
