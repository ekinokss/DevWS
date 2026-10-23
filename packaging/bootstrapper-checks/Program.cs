using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace DevWS.Setup.Checks;

internal static class Program
{
    private static int _passed;
    private static readonly List<string> Failures = new();

    private static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--emit-acl-json")
        {
            return EmitAclJson(args[1]);
        }

        if (args.Length != 0)
        {
            Console.Error.WriteLine("Usage: DevWS.Setup.Checks [--emit-acl-json <common-data-root>]");
            return 2;
        }

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

        Run("inherited dangerous ACL is rejected on child", () =>
        {
            var fixture = CreateAclFixture(dangerous: true, inheritOnly: false);
            try
            {
                var childAcl = new DirectoryInfo(fixture.Child).GetAccessControl(
                    AccessControlSections.Access);
                var inheritedDangerous = childAcl.GetAccessRules(true, true, typeof(SecurityIdentifier))
                    .Cast<FileSystemAccessRule>()
                    .First(rule => rule.IdentityReference.Equals(UserIdentity.CurrentSid()) &&
                        (rule.FileSystemRights & FileSystemRights.DeleteSubdirectoriesAndFiles) != 0);
                Check(inheritedDangerous.IsInherited, "dangerous child ACE was not inherited");
                Check(!inheritedDangerous.PropagationFlags.HasFlag(PropagationFlags.InheritOnly));

                var rejected = false;
                try { PackageSecurity.ValidateDirectory(fixture.Child, fixture.Root, UserIdentity.CurrentSid(), requireReaderAccess: true); }
                catch (SetupException) { rejected = true; }
                Check(rejected, "inherited dangerous authority was accepted");
            }
            finally
            {
                TryDelete(fixture.Root);
            }
        });

        Run("safe inherited read/execute is accepted", () =>
        {
            var fixture = CreateAclFixture(dangerous: false, inheritOnly: false);
            try
            {
                PackageSecurity.ValidateDirectory(fixture.Child, fixture.Root, UserIdentity.CurrentSid(), requireReaderAccess: true);
            }
            finally
            {
                TryDelete(fixture.Root);
            }
        });

        Run("inherit-only dangerous ACE is not current-object authority", () =>
        {
            var fixture = CreateAclFixture(dangerous: true, inheritOnly: true);
            try
            {
                PackageSecurity.ValidateDirectory(fixture.Parent, fixture.Root, UserIdentity.CurrentSid(), requireReaderAccess: true);
            }
            finally
            {
                TryDelete(fixture.Root);
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

        Run("fresh staging uses a canonical base and restricted staging subtree", () =>
        {
            var commonData = NewTempDirectory();
            try
            {
                var basePath = Path.Combine(commonData, "DevWS");
                var stagingPath = Path.Combine(basePath, "setup-staging");

                using (var session = ProtectedStaging.CreateForRoot(commonData))
                {
                    Check(Directory.Exists(session.Root));
                    Check(session.Root.StartsWith(stagingPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase));

                    ProtectedStaging.ValidateBaseDirectory(basePath, commonData);
                    ProtectedStaging.ValidateStagingDirectory(stagingPath, commonData);
                    ProtectedStaging.ValidateStagingDirectory(session.Root, commonData);

                    var baseSecurity = GetDirectorySecurity(basePath);
                    var usersRule = baseSecurity.GetAccessRules(true, true, typeof(SecurityIdentifier))
                        .Cast<FileSystemAccessRule>()
                        .FirstOrDefault(rule => rule.AccessControlType == AccessControlType.Allow &&
                            rule.IdentityReference is SecurityIdentifier sid &&
                            sid.IsWellKnown(WellKnownSidType.BuiltinUsersSid));
                    Check(usersRule is not null, "fresh base directory does not grant BUILTIN\\Users read access");
                    Check((usersRule!.FileSystemRights & FileSystemRights.ReadAndExecute) == FileSystemRights.ReadAndExecute,
                        "fresh base directory does not grant BUILTIN\\Users read+execute");

                    AssertRestrictedAcl(stagingPath);
                    AssertRestrictedAcl(session.Root);
                }

                Check(!Directory.Exists(stagingPath), "staging root was not removed after disposal");
            }
            finally
            {
                TryDelete(commonData);
            }
        });

        Run("legacy staging-only base ACL is rejected by the canonical base validator", () =>
        {
            var commonData = NewTempDirectory();
            try
            {
                var basePath = Path.Combine(commonData, "DevWS");
                PackageSecurity.CreateDirectoryAtomic(basePath, null);

                var rejected = false;
                try { ProtectedStaging.ValidateBaseDirectory(basePath, commonData); }
                catch (SetupException error) { rejected = error.Message.Contains("BUILTIN\\Users", StringComparison.Ordinal); }
                Check(rejected, "an Administrators/SYSTEM-only base ACL was accepted");
            }
            finally
            {
                TryDelete(commonData);
            }
        });

        Run("pre-existing canonical base directory is accepted without ACL modification", () =>
        {
            var commonData = NewTempDirectory();
            try
            {
                var basePath = Path.Combine(commonData, "DevWS");
                PackageSecurity.CreateDirectoryAtomic(
                    basePath,
                    new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null));
                var before = GetDirectorySddl(basePath);

                using (var session = ProtectedStaging.CreateForRoot(commonData))
                {
                    Check(Directory.Exists(session.Root));
                    Check(GetDirectorySddl(basePath) == before, "the pre-existing base ACL was modified");
                    ProtectedStaging.ValidateBaseDirectory(basePath, commonData);
                }
            }
            finally
            {
                TryDelete(commonData);
            }
        });

        Run("pre-existing dangerous base ACL is rejected and left unchanged", () =>
        {
            var commonData = NewTempDirectory();
            try
            {
                var basePath = Path.Combine(commonData, "DevWS");
                PackageSecurity.CreateDirectoryAtomic(
                    basePath,
                    new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null));
                var security = GetDirectorySecurity(basePath);
                security.AddAccessRule(new FileSystemAccessRule(
                    new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
                    FileSystemRights.DeleteSubdirectoriesAndFiles,
                    InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                    PropagationFlags.None,
                    AccessControlType.Allow));
                new DirectoryInfo(basePath).SetAccessControl(security);

                var before = GetDirectorySddl(basePath);
                var rejected = false;
                try { using var session = ProtectedStaging.CreateForRoot(commonData); }
                catch (SetupException) { rejected = true; }

                Check(rejected, "dangerous pre-existing base authority was accepted");
                Check(GetDirectorySddl(basePath) == before, "a rejected base ACL was modified");
                Check(!Directory.Exists(Path.Combine(basePath, "setup-staging")),
                    "staging was created before the unsafe base was rejected");
            }
            finally
            {
                TryDelete(commonData);
            }
        });

        Run("staging subtree with an untrusted reader ACE is rejected", () =>
        {
            var commonData = NewTempDirectory();
            try
            {
                var basePath = Path.Combine(commonData, "DevWS");
                var stagingPath = Path.Combine(basePath, "setup-staging");
                PackageSecurity.CreateDirectoryAtomic(
                    basePath,
                    new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null));
                PackageSecurity.CreateDirectoryAtomic(
                    stagingPath,
                    new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null));

                var rejected = false;
                try { using var session = ProtectedStaging.CreateForRoot(commonData); }
                catch (SetupException) { rejected = true; }
                Check(rejected, "an untrusted reader ACE on setup-staging was accepted");
                Check(!Directory.EnumerateDirectories(stagingPath).Any(),
                    "a staging run directory was created despite the untrusted reader ACE");
            }
            finally
            {
                TryDelete(commonData);
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

    private static (string Root, string Parent, string Child) CreateAclFixture(
        bool dangerous,
        bool inheritOnly)
    {
        var root = NewTempDirectory();
        var parent = Path.Combine(root, "parent");
        Directory.CreateDirectory(parent);

        var user = UserIdentity.CurrentSid();
        const InheritanceFlags inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetOwner(PackageSecurity.Administrators);
        security.AddAccessRule(new FileSystemAccessRule(
            PackageSecurity.Administrators,
            FileSystemRights.FullControl,
            inheritance,
            PropagationFlags.None,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            PackageSecurity.LocalSystem,
            FileSystemRights.FullControl,
            inheritance,
            PropagationFlags.None,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            user,
            FileSystemRights.ReadAndExecute,
            inheritance,
            PropagationFlags.None,
            AccessControlType.Allow));
        if (dangerous)
        {
            security.AddAccessRule(new FileSystemAccessRule(
                user,
                FileSystemRights.DeleteSubdirectoriesAndFiles,
                inheritance,
                inheritOnly ? PropagationFlags.InheritOnly : PropagationFlags.None,
                AccessControlType.Allow));
        }
        new DirectoryInfo(parent).SetAccessControl(security);

        var child = Path.Combine(parent, "child");
        Directory.CreateDirectory(child);
        var childSecurity = new DirectoryInfo(child).GetAccessControl(
            AccessControlSections.Access | AccessControlSections.Owner);
        childSecurity.SetOwner(PackageSecurity.Administrators);
        new DirectoryInfo(child).SetAccessControl(childSecurity);

        return (root, parent, child);
    }

    private static DirectorySecurity GetDirectorySecurity(string path)
        => new DirectoryInfo(path).GetAccessControl(
            AccessControlSections.Access | AccessControlSections.Owner);

    private static string GetDirectorySddl(string path)
        => GetDirectorySecurity(path).GetSecurityDescriptorSddlForm(
            AccessControlSections.Access | AccessControlSections.Owner);

    private static void AssertRestrictedAcl(string path)
    {
        var security = GetDirectorySecurity(path);
        Check(security.AreAccessRulesProtected, $"staging ACL is not protected: {path}");

        var owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        Check(owner is not null &&
            (owner.Equals(PackageSecurity.Administrators) || owner.Equals(PackageSecurity.LocalSystem)),
            $"staging owner is not Administrators or SYSTEM: {owner?.Value ?? "unresolved"}");

        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow)
            {
                continue;
            }

            var sid = rule.IdentityReference as SecurityIdentifier;
            Check(sid is not null &&
                (sid.Equals(PackageSecurity.Administrators) || sid.Equals(PackageSecurity.LocalSystem)),
                $"unexpected staging ACL identity: {rule.IdentityReference}");
        }
    }

    private static int EmitAclJson(string commonData)
    {
        Directory.CreateDirectory(commonData);
        using var session = ProtectedStaging.CreateForRoot(commonData);
        var basePath = Path.Combine(commonData, "DevWS");
        var stagingPath = Path.Combine(basePath, "setup-staging");
        var payload = new
        {
            baseSddl = GetDirectorySddl(basePath),
            stagingSddl = GetDirectorySddl(stagingPath),
            runSddl = GetDirectorySddl(session.Root)
        };
        Console.WriteLine("DEVWS_ACL_CONTRACT_JSON:" + JsonSerializer.Serialize(payload));
        return 0;
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
