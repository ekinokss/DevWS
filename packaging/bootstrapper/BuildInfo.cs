using System.Reflection;

namespace DevWS.Setup;

internal static class BuildInfo
{
    internal static string SourceSha
    {
        get
        {
            var metadata = typeof(BuildInfo).Assembly
                .GetCustomAttributes<AssemblyMetadataAttribute>()
                .FirstOrDefault(item => string.Equals(item.Key, "DevWSSourceSha", StringComparison.Ordinal));
            return string.IsNullOrWhiteSpace(metadata?.Value) ? "unknown" : metadata.Value;
        }
    }
}
