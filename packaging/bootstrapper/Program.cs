namespace DevWS.Setup;

internal static class Program
{
    private sealed record Invocation(SetupOperation Operation, bool IsElevatedChild, string? CallerSid);

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && (args[0] == "--help" || args[0] == "-h"))
            {
                PrintUsage();
                return 0;
            }

            if (args.Length == 1 && args[0] == "--version")
            {
                var versionIdentity = ProductIdentity.Load();
                Console.WriteLine($"{versionIdentity.DisplayName} {versionIdentity.ProductVersion} (source {BuildInfo.SourceSha})");
                return 0;
            }

            var invocation = ParseInvocation(args);
            ArchitecturePolicy.EnsureSupported();

            var identity = ProductIdentity.Load();
            var sid = UserIdentity.CurrentSid();
            var elevated = Elevation.IsElevated();

            if (invocation.IsElevatedChild)
            {
                if (!elevated)
                {
                    Console.Error.WriteLine("The internal elevation marker requires an already-elevated process.");
                    return 2;
                }
                UserIdentity.RequireSameElevatedSid(invocation.CallerSid!);
            }

            if (!elevated)
            {
                if (invocation.Operation == SetupOperation.Uninstall)
                {
                    RequirePersistedExecutable(identity, sid, validateFile: false);
                }

                Console.WriteLine($"[setup] Requesting administrator elevation for {invocation.Operation.ToString().ToLowerInvariant()}...");
                Console.WriteLine("[setup] Nothing is staged or changed before Windows grants elevation.");
                return Elevation.RelaunchElevated(invocation.Operation, sid.Value);
            }

            if (invocation.Operation == SetupOperation.Uninstall)
            {
                RequirePersistedExecutable(identity, sid, validateFile: true);
                return RunUninstall(identity, sid);
            }

            return RunInstall(identity, sid);
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

    private static int RunInstall(ProductIdentity identity, System.Security.Principal.SecurityIdentifier sid)
    {
        Console.WriteLine($"[setup] {identity.DisplayName} Setup (Windows x64)");
        Console.WriteLine($"[setup] product version: {identity.ProductVersion}");
        Console.WriteLine($"[setup] source commit: {BuildInfo.SourceSha}");

        var prior = PackageRegistration.Read(identity, sid.Value);
        var decision = VersionPolicy.Decide(prior.Version, identity.ParsedVersion);
        if (decision == PackageVersionDecision.Downgrade)
        {
            throw new SetupException(
                $"a newer DevWS package version ({prior.Version}) is already installed; downgrade to {identity.ProductVersion} is refused.");
        }

        var action = decision switch
        {
            PackageVersionDecision.FreshInstall => "fresh package install",
            PackageVersionDecision.Reinstall => "same-version reinstall/repair",
            PackageVersionDecision.Upgrade => $"upgrade from {prior.Version}",
            _ => "install"
        };
        Console.WriteLine($"[setup] package action: {action}");

        using var self = SelfImage.Open();
        var powerShell = PowerShellResolver.ResolveAndVerify();
        Console.WriteLine($"[setup] trusted PowerShell: {powerShell.Path}");

        using var staging = ProtectedStaging.Create();
        Console.WriteLine($"[setup] protected staging: {staging.Root}");

        PayloadArchive.ExtractEmbedded(staging.Root);
        Console.WriteLine("[setup] embedded payload extracted");

        var exitCode = ProcessRunner.RunInstaller(powerShell.Path, staging.InstallScript, staging.Root);
        Console.WriteLine($"[setup] installer exited with code {exitCode}");
        if (exitCode != 0)
        {
            Console.Error.WriteLine("[setup] DevWS package-mode installation did not complete successfully.");
            return exitCode;
        }

        InstalledSetup.Commit(identity, sid.Value, sid, self, prior);
        InstalledSetup.ValidatePersisted(identity, sid.Value, sid, self);

        Console.WriteLine($"[setup] persisted setup: {identity.PersistedSetupPath(sid.Value)}");
        Console.WriteLine($"[setup] installed package version: {identity.ProductVersion}");
        return 0;
    }

    private static int RunUninstall(ProductIdentity identity, System.Security.Principal.SecurityIdentifier sid)
    {
        Console.WriteLine($"[setup] {identity.DisplayName} Setup uninstall (Windows x64)");
        Console.WriteLine($"[setup] product version: {identity.ProductVersion}");

        var powerShell = PowerShellResolver.ResolveAndVerify();
        Console.WriteLine($"[setup] trusted PowerShell: {powerShell.Path}");

        using var staging = ProtectedStaging.Create();
        Console.WriteLine($"[setup] protected staging: {staging.Root}");

        PayloadArchive.ExtractEmbedded(staging.Root);
        Console.WriteLine("[setup] embedded payload extracted");

        var exitCode = ProcessRunner.RunUninstaller(powerShell.Path, Path.Combine(staging.Root, "uninstall.ps1"), staging.Root);
        Console.WriteLine($"[setup] uninstaller exited with code {exitCode}");
        if (exitCode != 0)
        {
            Console.Error.WriteLine("[setup] DevWS package-mode uninstall did not complete successfully; package registration is preserved.");
            return exitCode;
        }

        PackageRegistration.Remove(identity);
        PackageCleanup.Schedule(powerShell, staging, identity, sid.Value);

        Console.WriteLine("[setup] package registration removed");
        Console.WriteLine("[setup] protected setup cleanup scheduled after this process exits");
        return 0;
    }

    private static Invocation ParseInvocation(string[] args)
    {
        if (args.Length == 0)
        {
            return new Invocation(SetupOperation.Install, false, null);
        }

        if (args.Length == 1 && args[0] == "--uninstall")
        {
            return new Invocation(SetupOperation.Uninstall, false, null);
        }

        if (args.Length == 5 &&
            args[0] == Elevation.ElevatedArgument &&
            args[1] == Elevation.OperationArgument &&
            args[3] == Elevation.CallerSidArgument)
        {
            var operation = args[2] switch
            {
                "install" => SetupOperation.Install,
                "uninstall" => SetupOperation.Uninstall,
                _ => throw new SetupException("The internal elevated operation is malformed.")
            };
            if (!UserIdentity.TryParseSid(args[4], out _))
            {
                throw new SetupException("The internal elevated caller SID is malformed.");
            }
            return new Invocation(operation, true, args[4]);
        }

        throw new SetupException("Malformed DevWS-Setup invocation. Use --help, --version, or --uninstall.");
    }

    private static void RequirePersistedExecutable(
        ProductIdentity identity,
        System.Security.Principal.SecurityIdentifier sid,
        bool validateFile)
    {
        var expected = Path.GetFullPath(identity.PersistedSetupPath(sid.Value));
        var current = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(current) ||
            !string.Equals(Path.GetFullPath(current), expected, StringComparison.OrdinalIgnoreCase))
        {
            throw new SetupException(
                "Uninstall must run from the protected per-user installed DevWS-Setup.exe; a user-writable copy is not accepted elevated.");
        }

        var programFilesRoot = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        PathSafety.EnsureNoReparseChain(expected, programFilesRoot);
        if (!File.Exists(expected))
        {
            throw new SetupException("The protected persisted DevWS-Setup.exe is missing; package uninstall cannot proceed.");
        }

        if (validateFile)
        {
            PackageSecurity.ValidateFile(expected, programFilesRoot, sid);
        }
    }

    private static void PrintUsage()
    {
        Console.WriteLine("DevWS-Setup.exe - Windows x64 setup lifecycle");
        Console.WriteLine();
        Console.WriteLine("  DevWS-Setup.exe              install, upgrade, or reinstall/repair DevWS");
        Console.WriteLine("  DevWS-Setup.exe --uninstall  uninstall DevWS and preserve user data");
        Console.WriteLine("  DevWS-Setup.exe --version    show the setup version");
        Console.WriteLine("  DevWS-Setup.exe --help       show this help");
        Console.WriteLine();
        Console.WriteLine("No purge, reset-config, or arbitrary script arguments are exposed.");
        Console.WriteLine("The setup does not download prerequisites and no WinGet package exists yet.");
    }
}
