using System.ComponentModel;
using System.Diagnostics;

namespace DevWS.Setup;

internal static class ProcessRunner
{
    internal static int RunInstaller(string powerShellPath, string installScriptPath, string workingDirectory)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = powerShellPath,
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = false,
            RedirectStandardError = false,
            CreateNoWindow = false
        };

        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(installScriptPath);
        startInfo.ArgumentList.Add("-PackageMode");

        try
        {
            using var child = Process.Start(startInfo)
                ?? throw new SetupException("PowerShell did not start the DevWS installer.");
            child.WaitForExit();
            return child.ExitCode;
        }
        catch (Win32Exception error)
        {
            throw new SetupException($"Could not start the DevWS installer: {error.Message}", error);
        }
    }
}
