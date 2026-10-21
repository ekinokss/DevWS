using System.Reflection;

namespace DevWS.Setup;

internal static class BuildInfo
{
    internal static string SourceSha => ReadMetadata("DevWSSourceSha") ?? "unknown";

    internal static string? ReadMetadata(string key)
    {
        var metadata = typeof(BuildInfo).Assembly
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(item => string.Equals(item.Key, key, StringComparison.Ordinal));
        return string.IsNullOrWhiteSpace(metadata?.Value) ? null : metadata.Value;
    }
}
