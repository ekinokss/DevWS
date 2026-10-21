namespace DevWS.Setup;

internal sealed record ProductIdentity(
    string ProductId,
    string DisplayName,
    string Publisher,
    string ProductVersion,
    string ProgramFilesRootLeaf,
    string InstallRootLeaf,
    string UrlInfoAbout)
{
    internal static ProductIdentity Load()
    {
        var identity = new ProductIdentity(
            Required("DevWSProductId"),
            Required("DevWSDisplayName"),
            Required("DevWSPublisher"),
            Required("DevWSProductVersion"),
            Required("DevWSProgramFilesRootLeaf"),
            Required("DevWSInstallRootLeaf"),
            Required("DevWSURLInfoAbout"));

        ValidateIdentifier(identity.ProductId, "product id");
        ValidateLeaf(identity.ProgramFilesRootLeaf, "Program Files root leaf");
        ValidateLeaf(identity.InstallRootLeaf, "install root leaf");

        if (string.IsNullOrWhiteSpace(identity.DisplayName) || string.IsNullOrWhiteSpace(identity.Publisher))
        {
            throw new SetupException("The build identity has a blank display name or publisher.");
        }

        if (!Uri.TryCreate(identity.UrlInfoAbout, UriKind.Absolute, out var uri) ||
            !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
        {
            throw new SetupException("The build identity URLInfoAbout is not an absolute HTTPS URL.");
        }

        _ = identity.ParsedVersion;
        return identity;
    }

    internal PackageVersion ParsedVersion =>
        PackageVersion.TryParse(ProductVersion, out var version)
            ? version
            : throw new SetupException($"The build product version '{ProductVersion}' is not major.minor.patch.");

    internal string ArpKeyPath =>
        @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + ProductId;

    internal string ProgramFilesRoot =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            ProgramFilesRootLeaf);

    internal string InstallLocation =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            InstallRootLeaf);

    internal string SetupRoot => Path.Combine(ProgramFilesRoot, "setup");

    internal string PersistedSetupDirectory(string sid) => Path.Combine(SetupRoot, sid);

    internal string PersistedSetupPath(string sid) =>
        Path.Combine(PersistedSetupDirectory(sid), "DevWS-Setup.exe");

    internal string UninstallCommand(string sid) =>
        "\"" + PersistedSetupPath(sid) + "\" --uninstall";

    private static string Required(string key) =>
        BuildInfo.ReadMetadata(key)
        ?? throw new SetupException($"The build is missing required product metadata '{key}'.");

    private static void ValidateIdentifier(string value, string label)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value.Any(character => !(char.IsLetterOrDigit(character) || character is '.' or '_' or '-')))
        {
            throw new SetupException($"The build {label} '{value}' contains unsupported characters.");
        }
    }

    private static void ValidateLeaf(string value, string label)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            value is "." or ".." ||
            value.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
            value.Contains(Path.DirectorySeparatorChar) ||
            value.Contains(Path.AltDirectorySeparatorChar))
        {
            throw new SetupException($"The build {label} '{value}' is not a single safe path leaf.");
        }
    }
}
