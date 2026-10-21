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

    private const FileSystemRights DangerousRights =
        FileSystemRights.WriteData |
        FileSystemRights.AppendData |
        FileSystemRights.WriteExtendedAttributes |
        FileSystemRights.WriteAttributes |
        FileSystemRights.Delete |
        FileSystemRights.DeleteSubdirectoriesAndFiles |
        FileSystemRights.ChangePermissions |
        FileSystemRights.TakeOwnership |
        FileSystemRights.Write;

    internal static StagingSession Create()
    {
        var commonData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        if (string.IsNullOrWhiteSpace(commonData) || !Path.IsPathFullyQualified(commonData))
        {
            throw new SetupException("The Windows ProgramData root could not be resolved as an absolute path.");
        }

        PathSafety.EnsureNoReparseChain(commonData, commonData);

        var created = new List<string>();
        try
        {
            var devwsRoot = Path.Combine(commonData, "DevWS");
            EnsureProtectedDirectory(devwsRoot, commonData, created);

            var stagingRoot = Path.Combine(devwsRoot, "setup-staging");
            EnsureProtectedDirectory(stagingRoot, commonData, created);

            var runRoot = Path.Combine(stagingRoot, Guid.NewGuid().ToString("N"));
            CreateDirectoryAtomic(runRoot, created);
            PathSafety.EnsureNoReparseChain(runRoot, commonData);

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

    private static void EnsureProtectedDirectory(string path, string commonData, List<string> created)
    {
        if (Directory.Exists(path))
        {
            ValidateExistingDirectory(path, commonData);
            return;
        }

        CreateDirectoryAtomic(path, created);
        ValidateExistingDirectory(path, commonData);
    }

    private static void CreateDirectoryAtomic(string path, List<string> created)
    {
        var security = BuildSecurity();
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
                    throw new SetupException($"Staging directory already exists and will not be reused: '{path}'.");
                }
                throw new SetupException($"Could not create protected staging directory '{path}' (Win32 error {error}).");
            }

            created.Add(path);
        }
        finally
        {
            descriptorHandle.Free();
        }
    }

    private static DirectorySecurity BuildSecurity()
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

        return security;
    }

    internal static void ValidateExistingDirectory(string path, string commonData)
    {
        if (!Directory.Exists(path))
        {
            throw new SetupException($"Expected protected staging directory is missing: '{path}'.");
        }

        PathSafety.EnsureNoReparseChain(path, commonData);

        var info = new DirectoryInfo(path);
        DirectorySecurity security;
        try
        {
            security = info.GetAccessControl(AccessControlSections.Access | AccessControlSections.Owner);
        }
        catch (Exception error)
        {
            throw new SetupException($"Could not read the staging directory security descriptor '{path}': {error.Message}", error);
        }

        var owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (!IsTrustedSid(owner))
        {
            throw new SetupException($"Staging directory '{path}' is not owned by Administrators or SYSTEM.");
        }

        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow ||
                rule.IdentityReference is not SecurityIdentifier sid ||
                IsTrustedSid(sid))
            {
                continue;
            }

            if ((rule.FileSystemRights & DangerousRights) != 0)
            {
                throw new SetupException(
                    $"Staging directory '{path}' grants write/delete authority to untrusted identity '{sid}'.");
            }
        }
    }

    private static bool IsTrustedSid(SecurityIdentifier? sid)
        => sid is not null && (sid.Equals(Administrators) || sid.Equals(LocalSystem));
}
