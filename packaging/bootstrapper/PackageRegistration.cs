using System.Globalization;
using Microsoft.Win32;

namespace DevWS.Setup;

internal sealed record RegistryValueSnapshot(RegistryValueKind Kind, object? Data);

internal sealed class PackageRegistrationSnapshot
{
    internal PackageRegistrationSnapshot(
        bool exists,
        PackageVersion? version,
        IReadOnlyDictionary<string, RegistryValueSnapshot> values)
    {
        Exists = exists;
        Version = version;
        Values = values;
    }

    internal bool Exists { get; }
    internal PackageVersion? Version { get; }
    internal IReadOnlyDictionary<string, RegistryValueSnapshot> Values { get; }
}

internal static class PackageRegistration
{
    internal static PackageRegistrationSnapshot Read(ProductIdentity identity, string sid)
    {
        try
        {
            using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
            using var key = baseKey.OpenSubKey(identity.ArpKeyPath, writable: false);
            if (key is null)
            {
                return new PackageRegistrationSnapshot(false, null, new Dictionary<string, RegistryValueSnapshot>());
            }

            var values = SnapshotValues(key);
            var displayName = RequiredString(key, "DisplayName");
            var publisher = RequiredString(key, "Publisher");
            var versionText = RequiredString(key, "DisplayVersion");
            var uninstall = RequiredString(key, "UninstallString");
            var quietUninstall = RequiredString(key, "QuietUninstallString");
            var displayIcon = RequiredString(key, "DisplayIcon");
            var installLocation = RequiredString(key, "InstallLocation");
            var url = RequiredString(key, "URLInfoAbout");

            if (!string.Equals(displayName, identity.DisplayName, StringComparison.Ordinal))
            {
                throw new SetupException(
                    $"The existing DevWS package identity has DisplayName '{displayName}', expected '{identity.DisplayName}'.");
            }
            if (!string.Equals(publisher, identity.Publisher, StringComparison.Ordinal))
            {
                throw new SetupException(
                    $"The existing DevWS package identity has Publisher '{publisher}', expected '{identity.Publisher}'.");
            }
            if (!PackageVersion.TryParse(versionText, out var version))
            {
                throw new SetupException(
                    $"The existing DevWS package identity has malformed DisplayVersion '{versionText}'.");
            }

            var expectedPath = identity.PersistedSetupPath(sid);
            var expectedUninstall = identity.UninstallCommand(sid);
            if (!string.Equals(uninstall, expectedUninstall, StringComparison.Ordinal) ||
                !string.Equals(quietUninstall, expectedUninstall, StringComparison.Ordinal))
            {
                throw new SetupException(
                    "The existing DevWS package identity has contradictory uninstall paths; refusing to guess.");
            }
            if (!string.Equals(displayIcon, expectedPath, StringComparison.Ordinal))
            {
                throw new SetupException("The existing DevWS package identity has a contradictory DisplayIcon.");
            }
            if (!string.Equals(installLocation, identity.InstallLocation, StringComparison.Ordinal))
            {
                throw new SetupException("The existing DevWS package identity has a contradictory InstallLocation.");
            }
            if (!string.Equals(url, identity.UrlInfoAbout, StringComparison.Ordinal))
            {
                throw new SetupException("The existing DevWS package identity has a contradictory URLInfoAbout.");
            }
            if (!IsDwordOne(key, "NoModify") || !IsDwordOne(key, "NoRepair"))
            {
                throw new SetupException("The existing DevWS package identity has malformed NoModify/NoRepair values.");
            }

            return new PackageRegistrationSnapshot(true, version, values);
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new SetupException($"Could not read the DevWS ARP registration: {error.Message}", error);
        }
    }

    internal static void Write(
        ProductIdentity identity,
        string sid,
        string sourceSha,
        PackageVersion version)
    {
        try
        {
            using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
            using var key = baseKey.CreateSubKey(identity.ArpKeyPath, writable: true)
                ?? throw new SetupException($"Could not create HKCU ARP key '{identity.ArpKeyPath}'.");

            var path = identity.PersistedSetupPath(sid);
            key.SetValue("DisplayName", identity.DisplayName, RegistryValueKind.String);
            key.SetValue("DisplayVersion", version.ToString(), RegistryValueKind.String);
            key.SetValue("Publisher", identity.Publisher, RegistryValueKind.String);
            key.SetValue("InstallLocation", identity.InstallLocation, RegistryValueKind.String);
            key.SetValue("UninstallString", identity.UninstallCommand(sid), RegistryValueKind.String);
            key.SetValue("QuietUninstallString", identity.UninstallCommand(sid), RegistryValueKind.String);
            key.SetValue("DisplayIcon", path, RegistryValueKind.String);
            key.SetValue("URLInfoAbout", identity.UrlInfoAbout, RegistryValueKind.String);
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            key.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd", CultureInfo.InvariantCulture), RegistryValueKind.String);
            key.SetValue("DevWSSourceSha", sourceSha, RegistryValueKind.String);
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new SetupException($"Could not write the DevWS ARP registration: {error.Message}", error);
        }
    }

    internal static void Remove(ProductIdentity identity)
    {
        try
        {
            using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
            baseKey.DeleteSubKeyTree(identity.ArpKeyPath, throwOnMissingSubKey: false);
        }
        catch (Exception error)
        {
            throw new SetupException($"Could not remove the DevWS ARP registration: {error.Message}", error);
        }
    }

    internal static void Restore(ProductIdentity identity, PackageRegistrationSnapshot snapshot)
    {
        Remove(identity);
        if (!snapshot.Exists)
        {
            return;
        }

        try
        {
            using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
            using var key = baseKey.CreateSubKey(identity.ArpKeyPath, writable: true)
                ?? throw new SetupException($"Could not restore HKCU ARP key '{identity.ArpKeyPath}'.");

            foreach (var item in snapshot.Values)
            {
                if (item.Value.Data is null)
                {
                    continue;
                }

                if (item.Value.Kind == RegistryValueKind.Unknown)
                {
                    key.SetValue(item.Key, item.Value.Data);
                }
                else
                {
                    key.SetValue(item.Key, item.Value.Data, item.Value.Kind);
                }
            }
        }
        catch (Exception error)
        {
            throw new SetupException($"Could not restore the previous DevWS ARP registration: {error.Message}", error);
        }
    }

    internal static void ValidatePersistedRegistration(
        ProductIdentity identity,
        string sid,
        PackageVersion version,
        string sourceSha)
    {
        var snapshot = Read(identity, sid);
        if (!snapshot.Exists || snapshot.Version is null)
        {
            throw new SetupException("The DevWS ARP registration was not created.");
        }
        if (snapshot.Version.Value.CompareTo(version) != 0)
        {
            throw new SetupException(
                $"The DevWS ARP registration reports {snapshot.Version.Value}, expected {version}.");
        }

        using var baseKey = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64);
        using var key = baseKey.OpenSubKey(identity.ArpKeyPath, writable: false)
            ?? throw new SetupException("The DevWS ARP registration disappeared during validation.");
        var recordedSource = key.GetValue("DevWSSourceSha", null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
        if (!string.Equals(recordedSource, sourceSha, StringComparison.Ordinal))
        {
            throw new SetupException("The DevWS ARP registration has a contradictory DevWSSourceSha.");
        }
    }

    internal static IReadOnlyDictionary<string, RegistryValueSnapshot> SnapshotValues(RegistryKey key)
    {
        var values = new Dictionary<string, RegistryValueSnapshot>(StringComparer.OrdinalIgnoreCase);
        foreach (var name in key.GetValueNames())
        {
            if (string.IsNullOrEmpty(name))
            {
                continue;
            }

            var kind = key.GetValueKind(name);
            var data = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
            values[name] = new RegistryValueSnapshot(kind, data);
        }
        return values;
    }

    private static string RequiredString(RegistryKey key, string name)
    {
        var value = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new SetupException($"The existing DevWS package identity is missing required value '{name}'.");
        }
        return value;
    }

    private static bool IsDwordOne(RegistryKey key, string name)
    {
        var value = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
        return value is int integer && integer == 1;
    }
}
