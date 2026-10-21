using System.Runtime.InteropServices;

namespace DevWS.Setup;

internal sealed class SetupException : Exception
{
    internal SetupException(string message) : base(message) { }
    internal SetupException(string message, Exception inner) : base(message, inner) { }
}

internal static class ArchitecturePolicy
{
    internal static bool IsSupported(bool isWindows, Architecture architecture)
        => isWindows && architecture == Architecture.X64;

    internal static void EnsureSupported()
    {
        if (!IsSupported(RuntimeInformation.IsOSPlatform(OSPlatform.Windows), RuntimeInformation.ProcessArchitecture))
        {
            throw new SetupException(
                "DevWS-Setup.exe is supported only on Windows x64. " +
                "This build does not support x86, ARM64, or other operating systems.");
        }
    }
}
