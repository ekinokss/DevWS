using System.ComponentModel;
using System.Diagnostics;
using System.Security.Principal;

namespace DevWS.Setup;

internal static class Elevation
{
    internal const string ElevatedArgument = "--elevated";
    internal const string OperationArgument = "--operation";
    internal const string CallerSidArgument = "--caller-sid";

    internal static bool IsElevated()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    internal static int RelaunchElevated(SetupOperation operation, string callerSid)
    {
        var executable = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(executable) || !Path.IsPathFullyQualified(executable))
        {
            throw new SetupException("Could not resolve the absolute path of DevWS-Setup.exe for elevation.");
        }

        if (!UserIdentity.TryParseSid(callerSid, out _))
        {
            throw new SetupException("The caller SID is malformed; refusing to request elevation.");
        }

        var operationText = operation == SetupOperation.Install ? "install" : "uninstall";
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = Path.GetDirectoryName(executable) ?? Environment.CurrentDirectory,
            UseShellExecute = true,
            Verb = "runas",
            Arguments = $"{ElevatedArgument} {OperationArgument} {operationText} {CallerSidArgument} {callerSid}"
        };

        try
        {
            using var child = Process.Start(startInfo)
                ?? throw new SetupException("Windows did not start the elevated DevWS-Setup.exe process.");
            child.WaitForExit();
            return child.ExitCode;
        }
        catch (Win32Exception error) when (error.NativeErrorCode == 1223)
        {
            Console.Error.WriteLine("Elevation was cancelled. Nothing was changed.");
            return 1;
        }
        catch (Win32Exception error)
        {
            throw new SetupException($"Windows could not start the elevated setup process: {error.Message}", error);
        }
    }
}
