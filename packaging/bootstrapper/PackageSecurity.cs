using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;

namespace DevWS.Setup;

internal static class PackageSecurity
{
    internal static readonly SecurityIdentifier Administrators =
        new(WellKnownSidType.BuiltinAdministratorsSid, null);
    internal static readonly SecurityIdentifier LocalSystem =
        new(WellKnownSidType.LocalSystemSid, null);
    internal static readonly SecurityIdentifier TrustedInstaller =
        new("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464");

    internal const FileSystemRights DangerousRights =
        FileSystemRights.WriteData |
        FileSystemRights.AppendData |
        FileSystemRights.WriteExtendedAttributes |
        FileSystemRights.WriteAttributes |
        FileSystemRights.Delete |
        FileSystemRights.DeleteSubdirectoriesAndFiles |
        FileSystemRights.ChangePermissions |
        FileSystemRights.TakeOwnership |
        FileSystemRights.Write |
        (FileSystemRights)0x10000000 | // GenericAll
        (FileSystemRights)0x40000000;  // GenericWrite

    internal static DirectorySecurity BuildDirectorySecurity(SecurityIdentifier? reader)
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

    internal static void CreateDirectoryAtomic(string path, SecurityIdentifier? reader)
    {
        var security = BuildDirectorySecurity(reader);
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
                throw new SetupException($"Could not create protected package directory '{path}' (Win32 error {error}).");
            }
        }
        finally
        {
            descriptorHandle.Free();
        }
    }

    internal static void ValidateDirectory(
        string path,
        string stopAt,
        SecurityIdentifier? reader,
        bool requireReaderAccess)
    {
        if (!Directory.Exists(path))
        {
            throw new SetupException($"Expected protected package directory is missing: '{path}'.");
        }

        PathSafety.EnsureNoReparseChain(path, stopAt);

        DirectorySecurity security;
        try
        {
            security = new DirectoryInfo(path).GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner);
        }
        catch (Exception error)
        {
            throw new SetupException($"Could not read package directory security '{path}': {error.Message}", error);
        }

        ValidateSecurity(security, path, reader, requireReaderAccess);
    }

    internal static void ApplyFileSecurity(string path, SecurityIdentifier reader)
    {
        try
        {
            var security = new FileSecurity();
            security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
            security.SetOwner(Administrators);
            security.AddAccessRule(new FileSystemAccessRule(
                Administrators,
                FileSystemRights.FullControl,
                AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(
                LocalSystem,
                FileSystemRights.FullControl,
                AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(
                reader,
                FileSystemRights.ReadAndExecute,
                AccessControlType.Allow));

            new FileInfo(path).SetAccessControl(security);
        }
        catch (Exception error)
        {
            throw new SetupException($"Could not secure persisted setup file '{path}': {error.Message}", error);
        }
    }

    internal static void ValidateFile(string path, string stopAt, SecurityIdentifier reader)
    {
        if (!File.Exists(path))
        {
            throw new SetupException($"Persisted setup executable is missing: '{path}'.");
        }

        PathSafety.EnsureNoReparseChain(path, stopAt);
        if ((File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
        {
            throw new SetupException($"Persisted setup path is not an ordinary file: '{path}'.");
        }

        FileSecurity security;
        try
        {
            security = new FileInfo(path).GetAccessControl(
                AccessControlSections.Access | AccessControlSections.Owner);
        }
        catch (Exception error)
        {
            throw new SetupException($"Could not read persisted setup security '{path}': {error.Message}", error);
        }

        ValidateSecurity(security, path, reader, requireReaderAccess: true);
    }

    private static void ValidateSecurity(
        FileSystemSecurity security,
        string path,
        SecurityIdentifier? reader,
        bool requireReaderAccess)
    {
        var owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
        if (!IsTrustedSid(owner))
        {
            throw new SetupException($"Package path '{path}' is not owned by Administrators or SYSTEM.");
        }

        var readerHasReadExecute = false;
        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow ||
                rule.IdentityReference is not SecurityIdentifier sid ||
                (rule.PropagationFlags & PropagationFlags.InheritOnly) != 0)
            {
                // InheritOnly ACEs do not apply to the current object; they only
                // constrain descendants. Do not treat them as current-object
                // authority (and do not treat inherited status by itself as a
                // reason to ignore an ACE that does apply here).
                continue;
            }

            if (reader is not null && sid.Equals(reader) &&
                (rule.FileSystemRights & FileSystemRights.ReadData) != 0 &&
                (rule.FileSystemRights & FileSystemRights.ExecuteFile) != 0)
            {
                readerHasReadExecute = true;
            }

            if (IsTrustedSid(sid))
            {
                continue;
            }

            if ((rule.FileSystemRights & DangerousRights) != 0)
            {
                throw new SetupException(
                    $"Package path '{path}' grants write/delete authority to untrusted identity '{sid}'.");
            }
        }

        if (requireReaderAccess && (reader is null || !readerHasReadExecute))
        {
            throw new SetupException($"Package path '{path}' does not grant read/execute access to the target user.");
        }
    }

    internal static bool IsTrustedSid(SecurityIdentifier? sid) =>
        sid is not null &&
        (sid.Equals(Administrators) || sid.Equals(LocalSystem) || sid.Equals(TrustedInstaller));
}
