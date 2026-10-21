namespace DevWS.Setup;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && (args[0] == "--help" || args[0] == "-h"))
            {
                PrintUsage();
                return 0;
            }

            if (args.Length > 1 ||
                (args.Length == 1 && !string.Equals(args[0], Elevation.ElevatedArgument, StringComparison.Ordinal)))
            {
                Console.Error.WriteLine("Malformed DevWS-Setup invocation. This bootstrapper accepts no user arguments.");
                PrintUsage();
                return 2;
            }

            ArchitecturePolicy.EnsureSupported();

            var elevated = Elevation.IsElevated();
            if (!elevated)
            {
                if (args.Length == 1)
                {
                    Console.Error.WriteLine("The internal elevation marker requires an already-elevated process.");
                    return 2;
                }

                Console.WriteLine("[setup] Requesting administrator elevation...");
                Console.WriteLine("[setup] Nothing is staged or installed before Windows grants elevation.");
                return Elevation.RelaunchElevated();
            }

            return RunPackageInstall();
        }
        catch (SetupException error)
        {
            Console.Error.WriteLine($"[setup] error: {error.Message}");
            return 1;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"[setup] unexpected error: {error.Message}");
            return 1;
        }
    }

    private static int RunPackageInstall()
    {
        Console.WriteLine("[setup] DevWS Setup (Windows x64)");
        Console.WriteLine($"[setup] source commit: {BuildInfo.SourceSha}");

        var powerShell = PowerShellResolver.ResolveAndVerify();
        Console.WriteLine($"[setup] trusted PowerShell: {powerShell.Path}");

        using var staging = ProtectedStaging.Create();
        Console.WriteLine($"[setup] protected staging: {staging.Root}");

        PayloadArchive.ExtractEmbedded(staging.Root);
        Console.WriteLine("[setup] embedded payload extracted");

        var exitCode = ProcessRunner.RunInstaller(
            powerShell.Path,
            staging.InstallScript,
            staging.Root);

        Console.WriteLine($"[setup] installer exited with code {exitCode}");
        if (exitCode != 0)
        {
            Console.Error.WriteLine("[setup] DevWS package-mode installation did not complete successfully.");
        }
        return exitCode;
    }

    private static void PrintUsage()
    {
        Console.WriteLine("DevWS-Setup.exe - Windows x64 thin setup bootstrapper");
        Console.WriteLine();
        Console.WriteLine("Run without arguments to install or idempotently update DevWS.");
        Console.WriteLine("The bootstrapper requests elevation, stages the embedded source payload");
        Console.WriteLine("under ProgramData, and invokes install.ps1 -PackageMode.");
        Console.WriteLine();
        Console.WriteLine("This Phase-2 executable does not provide uninstall, repair, upgrade,");
        Console.WriteLine("Add/Remove Programs registration, or a WinGet package.");
        Console.WriteLine("It does not download or install prerequisites.");
    }
}
