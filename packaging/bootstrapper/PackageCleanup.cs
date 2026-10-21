using System.Diagnostics;
using System.Reflection;

namespace DevWS.Setup;

internal static class PackageCleanup
{
    private const string ResourceName = "DevWS.Setup.Cleanup.ps1";

    internal static void Schedule(
        TrustedPowerShell powerShell,
        StagingSession staging,
        ProductIdentity identity,
        string sid)
    {
        var scriptPath = Path.Combine(staging.Root, "package-cleanup.ps1");
        using (var source = typeof(PackageCleanup).Assembly.GetManifestResourceStream(ResourceName)
            ?? throw new SetupException("The embedded package-cleanup script is missing."))
        using (var destination = new FileStream(
            scriptPath,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            81_920,
            FileOptions.SequentialScan))
        {
            source.CopyTo(destination);
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = powerShell.Path,
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = false,
            RedirectStandardError = false
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(scriptPath);
        startInfo.ArgumentList.Add("-ParentPid");
        startInfo.ArgumentList.Add(Environment.ProcessId.ToString());
        startInfo.ArgumentList.Add("-SetupDirectory");
        startInfo.ArgumentList.Add(identity.PersistedSetupDirectory(sid));
        startInfo.ArgumentList.Add("-ProgramFilesRoot");
        startInfo.ArgumentList.Add(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles));
        startInfo.ArgumentList.Add("-RootLeaf");
        startInfo.ArgumentList.Add(identity.ProgramFilesRootLeaf);
        startInfo.ArgumentList.Add("-Sid");
        startInfo.ArgumentList.Add(sid);
        startInfo.ArgumentList.Add("-StagingRoot");
        startInfo.ArgumentList.Add(staging.Root);

        try
        {
            using var process = Process.Start(startInfo)
                ?? throw new SetupException("Could not start the package cleanup helper.");
            staging.HandoffToCleanup();
        }
        catch (Exception error)
        {
            throw new SetupException($"Could not schedule protected package cleanup: {error.Message}", error);
        }
    }
}
