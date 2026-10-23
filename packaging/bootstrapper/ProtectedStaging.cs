using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;

namespace DevWS.Setup;

internal sealed class StagingSession : IDisposable
{
    private readonly List<string> _createdDirectories;
    private bool _disposed;
    private bool _handedOffToCleanup;

    internal StagingSession(string root, List<string> createdDirectories)
    {
        Root = root;
        _createdDirectories = createdDirectories;
    }

    internal string Root { get; }
    internal string InstallScript => Path.Combine(Root, "install.ps1");

    internal void HandoffToCleanup()
    {
        _handedOffToCleanup = true;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;

        if (_handedOffToCleanup)
        {
            return;
        }

        try
        {
            DeleteTreeNoReparse(Root);

            foreach (var directory in _createdDirectories.AsEnumerable().Reverse())
            {
                if (string.Equals(directory, Root, StringComparison.OrdinalIgnoreCase) ||
                    !Directory.Exists(directory))
                {
                    continue;
                }

                var attributes = File.GetAttributes(directory);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw new SetupException($"Cleanup refused a reparse-point staging path: '{directory}'.");
                }

                if (!Directory.EnumerateFileSystemEntries(directory).Any())
                {
                    Directory.Delete(directory);
                }
            }
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"[setup] cleanup warning: {error.Message}");
        }
    }

    private static void DeleteTreeNoReparse(string path)
    {
        if (!Directory.Exists(path))
        {
            return;
        }

        foreach (var child in Directory.EnumerateFileSystemEntries(path))
        {
            var attributes = File.GetAttributes(child);
            if ((attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new SetupException($"Cleanup refused a reparse point inside staging: '{child}'.");
            }

            if ((attributes & FileAttributes.Directory) != 0)
            {
                DeleteTreeNoReparse(child);
            }
            else
            {
                File.Delete(child);
            }
        }

        Directory.Delete(path);
    }
}

internal static class ProtectedStaging
{
    private static readonly SecurityIdentifier Administrators =
        new(WellKnownSidType.BuiltinAdministratorsSid, null);
    private static readonly SecurityIdentifier LocalSystem =
        new(WellKnownSidType.LocalSystemSid, null);
    private static readonly SecurityIdentifier Users =
        new(WellKnownSidType.BuiltinUsersSid, null);

    internal static StagingSession Create()
    {
        var commonData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        if (string.IsNullOrWhiteSpace(commonData) || !Path.IsPathFullyQualified(commonData))
        {
            throw new SetupException("The Windows ProgramData root could not be resolved as an absolute path.");
        }

        return CreateForRoot(commonData);
    }

    internal static StagingSession CreateForRoot(string commonData)
    {
        if (string.IsNullOrWhiteSpace(commonData) || !Path.IsPathFullyQualified(commonData))
        {
            throw new SetupException("The protected staging root is not an absolute path.");
        }

        PathSafety.EnsureNoReparseChain(commonData, commonData);

        var created = new List<string>();
        try
        {
            var devwsRoot = Path.Combine(commonData, "DevWS");
            EnsureBaseDirectory(devwsRoot, commonData, created);

            var stagingRoot = Path.Combine(devwsRoot, "setup-staging");
            EnsureStagingDirectory(stagingRoot, commonData, created);

            var runRoot = Path.Combine(stagingRoot, Guid.NewGuid().ToString("N"));
            CreateDirectoryAtomic(runRoot, BuildStagingSecurity(), created, "protected staging run");
            ValidateStagingDirectory(runRoot, commonData);

            return new StagingSession(runRoot, created);
        }
        catch
        {
            foreach (var directory in created.AsEnumerable().Reverse())
            {
                try
                {
                    if (Directory.Exists(directory) &&
                        !Directory.EnumerateFileSystemEntries(directory).Any())
                    {
                        Directory.Delete(directory);
                    }
                }
                catch
                {
                    // Preserve the primary setup failure. A later process can clean
                    // an empty bootstrapper-owned staging parent safely.
                }
            }
            throw;
        }
    }

    private static void EnsureBaseDirectory(string path, string commonData, List<string> created)
    {
        if (Directory.Exists(path))
        {
            ValidateBaseDirectory(path, commonData);
            return;
        }

        CreateDirectoryAtomic(path, BuildBaseSecurity(), created, "protected state base");
        ValidateBaseDirectory(path, commonData);
    }

    private static void EnsureStagingDirectory(string path, string commonData, List<string> created)
    {
        if (Directory.Exists(path))
        {
            ValidateStagingDirectory(path, commonData);
            return;
        }

        CreateDirectoryAtomic(path, BuildStagingSecurity(), created, "protected staging root");
        ValidateStagingDirectory(path, commonData);
    }

    private static void CreateDirectoryAtomic(
        string path,
        DirectorySecurity security,
        List<string> created,
        string description)
    {
        var descriptor = security.GetSecurityDescriptorBinaryForm();
        var descriptorHandle = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
        try
        {
            var attributes = new NativeMethods.SecurityAttributes
            {
                Length = Marshal.SizeOf<NativeMethods.SecurityAttributes>(),
                SecurityDescriptor = descriptorHandle.AddrOfPinnedObject(),
                InheritHandle = 0
            };

            if (!NativeMethods.CreateDirectoryW(path, ref attributes))
            {
                var error = Marshal.GetLastWin32Error();
                if (error == NativeMethods.ErrorAlreadyExists)
                {
                    throw new SetupException($"Protected directory already exists and will not be reused: '{path}'.");
                }
                throw new SetupException($"Could not create {description} directory '{path}' (Win32 error {error}).");
            }

            created.Add(path);
        }
        finally
        {
            descriptorHandle.Free();
        }
    }

    internal static DirectorySecurity BuildBaseSecurity()
        => BuildDirectorySecurity(Users);

    internal static DirectorySecurity BuildStagingSecurity()
        => BuildDirectorySecurity(null);

    private static DirectorySecurity BuildDirectorySecurity(SecurityIdentifier? reader)
    {
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetOwner(Administrators);

        const InheritanceFlags inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        security.AddAccessRule(new FileSystemAccessRule(
            Administrators,
            FileSystemRights.FullControl,
            inheritance,
            PropagationFlags.None,
            AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            LocalSystem,
            FileSystemRights.FullControl,
            inheritance,
            PropagationFlags.None,
            AccessControlType.Allow));

        if (reader is not null)
        {
            security.AddAccessRule(new FileSystemAccessRule(
                reader,
                FileSystemRights.ReadAndExecute,
                inheritance,
                PropagationFlags.None,
                AccessControlType.Allow));
        }

        return security;
    }

    internal static void ValidateBaseDirectory(string path, string commonData)
        => ValidateDirectory(path, commonData, DirectoryPolicy.Base);

    internal static void ValidateStagingDirectory(string path, string commonData)
        => ValidateDirectory(path, commonData, DirectoryPolicy.Staging);

    private static void ValidateDirectory(string path, string commonData, DirectoryPolicy policy)
    {
        if (!Directory.Exists(path))
        {
            throw new SetupException($"Expected protected directory is missing: '{path}'.");
        }

        PathSafety.EnsureNoReparseChain(path, commonData);

        DirectorySecurity security;
        try
        {
            security = new DirectoryInfo(path).GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner);
        }
        catch (Exception error)
        {
            throw new SetupException($"Could not read protected directory security '{path}': {error.Message}", error);
        }

        var errors = new List<string>();
        var owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;

        if (policy == DirectoryPolicy.Base)
        {
            if (owner is null || !owner.Equals(Administrators))
            {
                errors.Add($"owner is '{owner?.Value ?? "unresolved"}'; expected BUILTIN\\Administrators ({Administrators.Value})");
            }
        }
        else if (!IsTrustedSid(owner))
        {
            errors.Add($"owner is '{owner?.Value ?? "unresolved"}'; expected BUILTIN\\Administrators or SYSTEM");
        }

        if (!security.AreAccessRulesProtected)
        {
            errors.Add("the DACL is not protected: inherited ACEs are still present");
        }

        var expected = new Dictionary<string, FileSystemRights>(StringComparer.Ordinal)
        {
            [LocalSystem.Value] = FileSystemRights.FullControl,
            [Administrators.Value] = FileSystemRights.FullControl
        };
        if (policy == DirectoryPolicy.Base)
        {
            expected[Users.Value] = FileSystemRights.ReadAndExecute;
        }

        const InheritanceFlags requiredInheritance =
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        var rights = new Dictionary<string, FileSystemRights>(StringComparer.Ordinal);

        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow)
            {
                errors.Add($"unexpected DENY access rule for '{rule.IdentityReference}'");
                continue;
            }

            if (rule.IsInherited)
            {
                errors.Add($"an access rule for '{rule.IdentityReference}' is inherited; only explicit ACEs apply");
                continue;
            }

            if (rule.InheritanceFlags != requiredInheritance)
            {
                errors.Add($"an access rule for '{rule.IdentityReference}' must have exactly ContainerInherit|ObjectInherit inheritance (got '{rule.InheritanceFlags}')");
                continue;
            }

            if (rule.PropagationFlags != PropagationFlags.None)
            {
                errors.Add($"an access rule for '{rule.IdentityReference}' must not use propagation flags (got '{rule.PropagationFlags}')");
                continue;
            }

            if (rule.IdentityReference is not SecurityIdentifier sid)
            {
                errors.Add($"an access rule identity '{rule.IdentityReference}' could not be resolved to a SID");
                continue;
            }

            if (!expected.ContainsKey(sid.Value))
            {
                errors.Add($"unexpected access rule for '{sid.Value}' (rights '{rule.FileSystemRights}')");
                continue;
            }

            if (!rights.ContainsKey(sid.Value))
            {
                rights[sid.Value] = 0;
            }
            rights[sid.Value] |= rule.FileSystemRights;
        }

        foreach (var expectedRule in expected)
        {
            if (!rights.TryGetValue(expectedRule.Key, out var granted))
            {
                var expectedLabel = expectedRule.Key == Users.Value
                    ? "BUILTIN\\Users"
                    : expectedRule.Key == LocalSystem.Value
                        ? "SYSTEM"
                        : "BUILTIN\\Administrators";
                errors.Add($"missing access rule for {expectedLabel} ({expectedRule.Key})");
                continue;
            }

            if (expectedRule.Key == Users.Value && policy == DirectoryPolicy.Base)
            {
                var allowedReader = FileSystemRights.ReadAndExecute | FileSystemRights.Synchronize;
                if (((int)granted & ~(int)allowedReader) != 0)
                {
                    errors.Add($"BUILTIN\\Users grants unexpected write-capable rights: {granted}");
                }
                if ((granted & FileSystemRights.ReadAndExecute) != FileSystemRights.ReadAndExecute)
                {
                    errors.Add("BUILTIN\\Users is missing part of the required read+execute/list access");
                }
            }
            else if ((granted & FileSystemRights.FullControl) != FileSystemRights.FullControl)
            {
                errors.Add($"'{(expectedRule.Key == LocalSystem.Value ? "SYSTEM" : "BUILTIN\\Administrators")}' does not have FullControl");
            }
        }

        if (errors.Count > 0)
        {
            var label = policy == DirectoryPolicy.Base
                ? "Protected state base"
                : "Protected staging directory";
            throw new SetupException(
                $"{label} '{path}' has unexpected security. Refusing to repair it automatically; remove or repair it explicitly from an administrator shell and rerun setup." +
                Environment.NewLine + "  - " + string.Join(Environment.NewLine + "  - ", errors));
        }
    }

    private static bool IsTrustedSid(SecurityIdentifier? sid)
        => sid is not null && (sid.Equals(Administrators) || sid.Equals(LocalSystem));

    private enum DirectoryPolicy
    {
        Base,
        Staging
    }
}
