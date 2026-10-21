using System.Runtime.InteropServices;

namespace DevWS.Setup;

internal static class NativeMethods
{
    internal const int ErrorSuccess = 0;
    internal const int ErrorInsufficientBuffer = 122;
    internal const int ErrorAlreadyExists = 183;

    [StructLayout(LayoutKind.Sequential)]
    internal struct SecurityAttributes
    {
        internal int Length;
        internal IntPtr SecurityDescriptor;
        internal int InheritHandle;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool CreateDirectoryW(string path, ref SecurityAttributes securityAttributes);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    internal static extern int GetPackagesByPackageFamily(
        string packageFamilyName,
        out uint count,
        IntPtr packageFullNames,
        ref uint bufferLength,
        IntPtr buffer);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    internal static extern int GetPackagePathByFullName(
        string packageFullName,
        ref uint pathLength,
        IntPtr path);
}
