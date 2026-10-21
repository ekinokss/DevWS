namespace DevWS.Setup;

internal readonly record struct PackageVersion(int Major, int Minor, int Patch) : IComparable<PackageVersion>
{
    internal static bool TryParse(string? value, out PackageVersion version)
    {
        version = default;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var parts = value.Split('.');
        if (parts.Length != 3 ||
            !int.TryParse(parts[0], out var major) || major < 0 ||
            !int.TryParse(parts[1], out var minor) || minor < 0 ||
            !int.TryParse(parts[2], out var patch) || patch < 0)
        {
            return false;
        }

        version = new PackageVersion(major, minor, patch);
        return true;
    }

    public int CompareTo(PackageVersion other)
    {
        var result = Major.CompareTo(other.Major);
        if (result != 0) return result;
        result = Minor.CompareTo(other.Minor);
        return result != 0 ? result : Patch.CompareTo(other.Patch);
    }

    public override string ToString() => $"{Major}.{Minor}.{Patch}";
}

internal enum PackageVersionDecision
{
    FreshInstall,
    Reinstall,
    Upgrade,
    Downgrade
}

internal static class VersionPolicy
{
    internal static PackageVersionDecision Decide(PackageVersion? installed, PackageVersion setup)
    {
        if (installed is null)
        {
            return PackageVersionDecision.FreshInstall;
        }

        var comparison = installed.Value.CompareTo(setup);
        if (comparison < 0) return PackageVersionDecision.Upgrade;
        if (comparison > 0) return PackageVersionDecision.Downgrade;
        return PackageVersionDecision.Reinstall;
    }
}
