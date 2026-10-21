using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32;

namespace DevWS.Setup.Checks;

internal static class Program
{
    private static int _passed;
    private static readonly List<string> Failures = new();

    private static int Main()
    {
        Run("x64 Windows is the only supported architecture", () =>
        {
            Check(ArchitecturePolicy.IsSupported(true, Architecture.X64));
            Check(!ArchitecturePolicy.IsSupported(true, Architecture.X86));
            Check(!ArchitecturePolicy.IsSupported(true, Architecture.Arm64));
            Check(!ArchitecturePolicy.IsSupported(false, Architecture.X64));
        });

        Run("version policy is numeric and fail-closed", () =>
        {
            Check(PackageVersion.TryParse("0.2.0", out var v020));
            Check(PackageVersion.TryParse("0.2.1", out var v021));
            Check(!PackageVersion.TryParse("0.2", out _));
            Check(!PackageVersion.TryParse("0.2.x", out _));
            Check(!PackageVersion.TryParse("0.2.0-beta", out _));
            Check(v020.CompareTo(v021) < 0);
            Check(VersionPolicy.Decide(null, v020) == PackageVersionDecision.FreshInstall);
            Check(VersionPolicy.Decide(v020, v020) == PackageVersionDecision.Reinstall);
            Check(VersionPolicy.Decide(v020, v021) == PackageVersionDecision.Upgrade);
            Check(VersionPolicy.Decide(v021, v020) == PackageVersionDecision.Downgrade);
        });

        Run("production/fixture identity paths and SID rules are exact", () =>
        {
            var sid = UserIdentity.CurrentSid();
            Check(UserIdentity.TryParseSid(sid.Value, out var parsed));
            Check(parsed is not null && parsed.Equals(sid));
            Check(!UserIdentity.TryParseSid("not-a-sid", out _));

            var fixture = FixtureIdentity();
            Check(fixture.ArpKeyPath == @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + fixture.ProductId);
            Check(fixture.PersistedSetupPath(sid.Value).EndsWith(@"\setup\" + sid.Value + @"\DevWS-Setup.exe", StringComparison.OrdinalIgnoreCase));
            Check(fixture.InstallLocation.EndsWith(fixture.InstallRootLeaf, StringComparison.OrdinalIgnoreCase));

            var otherSid = new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null).Value;
            var rejected = false;
            try { UserIdentity.RequireSameElevatedSid(otherSid); }
            catch (SetupException) { rejected = true; }
            Check(rejected, "cross-user elevation SID mismatch was accepted");
        });

        Run("ARP registration fixture round-trips and is removable", () =>
        {
            var identity = FixtureIdentity();
            var sid = UserIdentity.CurrentSid().Value;
            try
            {
                Check(!PackageRegistration.Read(identity, sid).Exists);
                PackageRegistration.Write(identity, sid, "test-source", identity.ParsedVersion);
                var read = PackageRegistration.Read(identity, sid);
                Check(read.Exists);
                Check(read.Version == identity.ParsedVersion);
                PackageRegistration.ValidatePersistedRegistration(identity, sid, identity.ParsedVersion, "test-source");
            }
            finally
            {
                PackageRegistration.Remove(identity);
            }
            Check(!PackageRegistration.Read(identity, sid).Exists, "fixture ARP key remained after removal");
        });

        Run("malformed package registration is refused", () =>
        {
            var identity = FixtureIdentity();
            var sid = UserIdentity.CurrentSid().Value;
            try
            {
                PackageRegistration.Write(identity, sid, "test-source", identity.ParsedVersion);
                using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64))
                using (var key = baseKey.OpenSubKey(identity.ArpKeyPath, writable: true))
                {
                    Check(key is not null);
                    key!.SetValue("DisplayVersion", "not-a-version", RegistryValueKind.String);
                }

                var rejected = false;
                try { PackageRegistration.Read(identity, sid); }
                catch (SetupException) { rejected = true; }
                Check(rejected, "malformed ARP version was accepted");
            }
            finally
            {
                PackageRegistration.Remove(identity);
            }
        });

        Run("package ACL policy grants user read but no write/delete", () =>
        {
            var root = NewTempDirectory();
            var packageRoot = Path.Combine(root, "pkg");
            var sid = UserIdentity.CurrentSid();
            try
            {
                PackageSecurity.CreateDirectoryAtomic(packageRoot, null);
                var readOnlyDir = Path.Combine(packageRoot, "setup");
                PackageSecurity.CreateDirectoryAtomic(readOnlyDir, sid);
                PackageSecurity.ValidateDirectory(readOnlyDir, root, sid, requireReaderAccess: true);

                var file = Path.Combine(readOnlyDir, "install-marker.txt");
                File.WriteAllText(file, "fixture");
                PackageSecurity.ApplyFileSecurity(file, sid);
                PackageSecurity.ValidateFile(file, root, sid);
            }
            finally
            {
                TryDelete(root);
            }
        });

        Run("PowerShell trust root rejects user-writable and missing candidates", () =>
        {
            var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            Check(PowerShellResolver.MsixPackageFamilyName == "Microsoft.PowerShell_8wekyb3d8bbwe");

            var userCandidate = Path.Combine(Path.GetTempPath(), "pwsh.exe");
            var userProblem = PowerShellResolver.ValidateCandidatePath(userCandidate, programFiles);
            Check(userProblem is not null && userProblem.Contains("outside", StringComparison.OrdinalIgnoreCase));

            var missing = Path.Combine(programFiles, "DevWS-Setup-Checks-NoSuch", "pwsh.exe");
            var missingProblem = PowerShellResolver.ValidateCandidatePath(missing, programFiles);
            Check(missingProblem is not null);

            var wrongLeaf = Path.Combine(programFiles, "PowerShell", "7", "cmd.exe");
            var leafProblem = PowerShellResolver.ValidateCandidatePath(wrongLeaf, programFiles);
            Check(leafProblem is not null && leafProblem.Contains("pwsh.exe", StringComparison.OrdinalIgnoreCase));
        });

        Run("payload rejects traversal, duplicate targets, file conflicts, and symlinks", () =>
        {
            using var traversal = Zip("install.ps1", "Write-Output 'ok'", "../escape.ps1", "bad");
            ExpectPayloadError(traversal);

            using var duplicate = Zip("install.ps1", "a", "A.txt", "a", "a.txt", "b");
            ExpectPayloadError(duplicate);

            using var conflict = Zip("install.ps1", "a", "a", "file", "a/b", "child");
            ExpectPayloadError(conflict);

            using var symlink = Zip("install.ps1", "a", "link.ps1", "target");
            symlink.Entries.First(item => item.FullName == "link.ps1").ExternalAttributes = 0xA000 << 16;
            ExpectPayloadError(symlink);
        });

        Run("payload extraction accepts a normal installer payload", () =>
        {
            var root = NewTempDirectory();
            try
            {
                using var archive = Zip(
                    "install.ps1", "param([switch]$PackageMode)",
                    "src/ws.ps1", "Write-Output 'runtime'",
                    "config/workspace.default.json", "{}");
                PayloadArchive.Extract(archive, root);
                Check(File.Exists(Path.Combine(root, "install.ps1")));
                Check(File.Exists(Path.Combine(root, "src", "ws.ps1")));
                Check(File.Exists(Path.Combine(root, "config", "workspace.default.json")));
            }
            finally
            {
                TryDelete(root);
            }
        });

        Run("reparse staging paths are rejected", () =>
        {
            var root = NewTempDirectory();
            var target = Path.Combine(root, "target");
            var link = Path.Combine(root, "link");
            try
            {
                Directory.CreateDirectory(target);
                Directory.CreateSymbolicLink(link, target);
                var rejected = false;
                try
                {
                    PathSafety.EnsureNoReparseChain(link, root);
                }
                catch (SetupException)
                {
                    rejected = true;
                }
                Check(rejected, "symlink path was accepted");
            }
            finally
            {
                try { if (Directory.Exists(link)) Directory.Delete(link); } catch { }
                TryDelete(root);
            }
        });

        Run("stable self-image handle prevents replacement and copies exact bytes", () =>
        {
            var root = NewTempDirectory();
            var sourcePath = Path.Combine(root, "source.exe");
            var copyPath = Path.Combine(root, "copy.exe");
            var bytes = new byte[] { 1, 2, 3, 4, 5, 6, 7, 8 };
            File.WriteAllBytes(sourcePath, bytes);
            try
            {
                using var image = SelfImage.Open(sourcePath);
                Check(image.Length == bytes.Length);
                Check(image.Hash == Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)));

                var writeRejected = false;
                try
                {
                    using var writer = new FileStream(sourcePath, FileMode.Open, FileAccess.Write, FileShare.ReadWrite);
                    writer.WriteByte(0);
                }
                catch (IOException) { writeRejected = true; }
                catch (UnauthorizedAccessException) { writeRejected = true; }
                Check(writeRejected, "the held source could be replaced");

                image.CopyTo(copyPath);
                Check(File.ReadAllBytes(copyPath).SequenceEqual(bytes));
            }
            finally
            {
                TryDelete(root);
            }
        });

        Run("protected staging is created and cleaned under ProgramData", () =>
        {
            var stagingRoot = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "DevWS",
                "setup-staging");
            using var session = ProtectedStaging.Create();
            try
            {
                Check(Directory.Exists(session.Root));
                Check(session.Root.StartsWith(stagingRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase));
                Check(!session.Root.StartsWith(Path.GetTempPath(), StringComparison.OrdinalIgnoreCase));

                var security = new DirectoryInfo(session.Root)
                    .GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner);
                foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(System.Security.Principal.SecurityIdentifier)))
                {
                    if (rule.AccessControlType != AccessControlType.Allow) continue;
                    var sid = (System.Security.Principal.SecurityIdentifier)rule.IdentityReference;
                    var trusted = sid.IsWellKnown(System.Security.Principal.WellKnownSidType.BuiltinAdministratorsSid)
                        || sid.IsWellKnown(System.Security.Principal.WellKnownSidType.LocalSystemSid);
                    Check(trusted, $"unexpected staging ACL identity {sid}");
                }
            }
            finally
            {
                var root = session.Root;
                session.Dispose();
                Check(!Directory.Exists(root), "staging run directory was not removed");
            }
        });

        Console.WriteLine($"Checks passed: {_passed}");
        foreach (var failure in Failures)
        {
            Console.Error.WriteLine($"FAIL: {failure}");
        }
        return Failures.Count == 0 ? 0 : 1;
    }

    private static void Run(string name, Action body)
    {
        try
        {
            body();
            _passed++;
            Console.WriteLine($"PASS: {name}");
        }
        catch (Exception error)
        {
            Failures.Add($"{name}: {error.Message}");
        }
    }

    private static void Check(bool condition, string message = "assertion failed")
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void ExpectPayloadError(ZipArchive archive)
    {
        var root = NewTempDirectory();
        try
        {
            var rejected = false;
            try { PayloadArchive.PlanEntries(archive, root); }
            catch (SetupException) { rejected = true; }
            Check(rejected, "unsafe payload was accepted");
        }
        finally
        {
            TryDelete(root);
        }
    }

    private static ProductIdentity FixtureIdentity()
    {
        var suffix = Guid.NewGuid().ToString("N").Substring(0, 8);
        return new ProductIdentity(
            "ekinokss.DevWS.Fixture.Checks." + suffix,
            "DevWS Setup Fixture Checks " + suffix,
            "ekinokss",
            "0.2.0",
            "DevWS-Setup-Fixture-Checks-" + suffix,
            "DevWS-Setup-Fixture-Checks-" + suffix,
            "https://github.com/ekinokss/DevWS");
    }

    private static ZipArchive Zip(params string[] namesAndContents)
    {
        var stream = new MemoryStream();
        using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
        {
            for (var index = 0; index < namesAndContents.Length; index += 2)
            {
                var entry = archive.CreateEntry(namesAndContents[index]);
                using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
                writer.Write(namesAndContents[index + 1]);
            }
        }
        stream.Position = 0;
        return new ZipArchive(stream, ZipArchiveMode.Read);
    }

    private static string NewTempDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), "devws-setup-checks-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
        }
        catch
        {
            // Best-effort test cleanup.
        }
    }
}
