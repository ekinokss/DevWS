using System.Security.Cryptography;
using System.Security.Principal;

namespace DevWS.Setup;

internal static class InstalledSetup
{
    internal static void Commit(
        ProductIdentity identity,
        string sid,
        SecurityIdentifier userSid,
        SelfImage source,
        PackageRegistrationSnapshot priorRegistration)
    {
        var programFilesRoot = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        if (string.IsNullOrWhiteSpace(programFilesRoot) || !Path.IsPathFullyQualified(programFilesRoot))
        {
            throw new SetupException("The Windows Program Files root could not be resolved absolutely.");
        }

        PathSafety.EnsureNoReparseChain(programFilesRoot, programFilesRoot);

        var createdDirectories = new List<string>();
        var targetPath = identity.PersistedSetupPath(sid);
        var candidatePath = Path.Combine(identity.PersistedSetupDirectory(sid), "DevWS-Setup.new." + Guid.NewGuid().ToString("N"));
        var backupPath = Path.Combine(identity.PersistedSetupDirectory(sid), "DevWS-Setup.old." + Guid.NewGuid().ToString("N"));
        var targetReplaced = false;
        var targetCreated = false;
        var targetExisted = false;

        try
        {
            EnsureDirectory(identity.ProgramFilesRoot, programFilesRoot, userSid, requireReaderAccess: false, includeInheritedRules: false, createdDirectories);
            EnsureDirectory(identity.SetupRoot, programFilesRoot, userSid, requireReaderAccess: true, includeInheritedRules: true, createdDirectories);
            EnsureDirectory(identity.PersistedSetupDirectory(sid), programFilesRoot, userSid, requireReaderAccess: true, includeInheritedRules: true, createdDirectories);

            targetExisted = File.Exists(targetPath);
            if (targetExisted)
            {
                PackageSecurity.ValidateFile(targetPath, programFilesRoot, userSid);
            }

            if (targetExisted && string.Equals(HashFile(targetPath), source.Hash, StringComparison.OrdinalIgnoreCase))
            {
                PackageSecurity.ValidateFile(targetPath, programFilesRoot, userSid);
            }
            else
            {
                if (targetExisted &&
                    string.Equals(
                        Path.GetFullPath(source.SourcePath),
                        Path.GetFullPath(targetPath),
                        StringComparison.OrdinalIgnoreCase))
                {
                    throw new SetupException(
                        "The running persisted setup cannot replace itself with different bytes while it is executing.");
                }

                source.CopyTo(candidatePath);
                PackageSecurity.ApplyFileSecurity(candidatePath, userSid);
                ValidateCandidate(candidatePath, source, programFilesRoot, userSid);

                if (targetExisted)
                {
                    try
                    {
                        File.Replace(candidatePath, targetPath, backupPath, ignoreMetadataErrors: false);
                        targetReplaced = true;
                    }
                    catch (Exception error)
                    {
                        throw new SetupException($"Could not atomically replace the persisted setup executable: {error.Message}", error);
                    }
                }
                else
                {
                    File.Move(candidatePath, targetPath);
                    targetCreated = true;
                }
            }

            PackageSecurity.ValidateFile(targetPath, programFilesRoot, userSid);
            if (!string.Equals(HashFile(targetPath), source.Hash, StringComparison.OrdinalIgnoreCase))
            {
                throw new SetupException("The persisted setup executable does not hash to the held source image.");
            }

            PackageRegistration.Write(identity, sid, BuildInfo.SourceSha, identity.ParsedVersion);
            PackageRegistration.ValidatePersistedRegistration(identity, sid, identity.ParsedVersion, BuildInfo.SourceSha);
            PackageSecurity.ValidateFile(targetPath, programFilesRoot, userSid);

            if (File.Exists(backupPath))
            {
                File.Delete(backupPath);
            }
            if (File.Exists(candidatePath))
            {
                File.Delete(candidatePath);
            }
        }
        catch (Exception error)
        {
            var rollbackErrors = new List<string>();
            try
            {
                PackageRegistration.Restore(identity, priorRegistration);
            }
            catch (Exception rollbackError)
            {
                rollbackErrors.Add(rollbackError.Message);
            }

            try
            {
                if (targetReplaced && File.Exists(backupPath))
                {
                    File.Replace(backupPath, targetPath, null, ignoreMetadataErrors: true);
                }
                else if (targetCreated && File.Exists(targetPath))
                {
                    File.Delete(targetPath);
                }
            }
            catch (Exception rollbackError)
            {
                rollbackErrors.Add(rollbackError.Message);
            }

            TryDeleteFile(candidatePath);
            TryDeleteFile(backupPath);
            TryDeleteEmptyDirectories(createdDirectories);

            var suffix = rollbackErrors.Count > 0
                ? " Rollback also failed: " + string.Join("; ", rollbackErrors)
                : string.Empty;
            throw new SetupException($"DevWS package identity commit failed: {error.Message}.{suffix}", error);
        }
    }

    internal static void ValidatePersisted(
        ProductIdentity identity,
        string sid,
        SecurityIdentifier userSid,
        SelfImage source)
    {
        var programFilesRoot = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        PathSafety.EnsureNoReparseChain(identity.PersistedSetupPath(sid), programFilesRoot);
        PackageSecurity.ValidateFile(identity.PersistedSetupPath(sid), programFilesRoot, userSid);
        if (!string.Equals(HashFile(identity.PersistedSetupPath(sid)), source.Hash, StringComparison.OrdinalIgnoreCase))
        {
            throw new SetupException("Persisted setup validation failed after package registration.");
        }
        PackageRegistration.ValidatePersistedRegistration(identity, sid, identity.ParsedVersion, BuildInfo.SourceSha);
    }

    private static void EnsureDirectory(
        string path,
        string stopAt,
        SecurityIdentifier reader,
        bool requireReaderAccess,
        bool includeInheritedRules,
        List<string> createdDirectories)
    {
        if (Directory.Exists(path))
        {
            PackageSecurity.ValidateDirectory(path, stopAt, reader, requireReaderAccess, includeInheritedRules);
            return;
        }

        PackageSecurity.CreateDirectoryAtomic(path, requireReaderAccess ? reader : null);
        createdDirectories.Add(path);
        PackageSecurity.ValidateDirectory(path, stopAt, reader, requireReaderAccess, includeInheritedRules);
    }

    private static void ValidateCandidate(
        string path,
        SelfImage source,
        string programFilesRoot,
        SecurityIdentifier userSid)
    {
        var info = new FileInfo(path);
        if (!info.Exists || info.Length != source.Length)
        {
            throw new SetupException("The persisted setup candidate has an unexpected length.");
        }

        PackageSecurity.ValidateFile(path, programFilesRoot, userSid);
        if (!string.Equals(HashFile(path), source.Hash, StringComparison.OrdinalIgnoreCase))
        {
            throw new SetupException("The persisted setup candidate does not hash to the held source image.");
        }
    }

    private static string HashFile(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var sha = SHA256.Create();
        return Convert.ToHexString(sha.ComputeHash(stream));
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // Best-effort rollback artifact cleanup.
        }
    }

    private static void TryDeleteEmptyDirectories(IEnumerable<string> directories)
    {
        foreach (var directory in directories.Reverse())
        {
            try
            {
                if (Directory.Exists(directory) &&
                    (File.GetAttributes(directory) & FileAttributes.ReparsePoint) == 0 &&
                    !Directory.EnumerateFileSystemEntries(directory).Any())
                {
                    Directory.Delete(directory);
                }
            }
            catch
            {
                // Preserve the primary registration failure.
            }
        }
    }
}
