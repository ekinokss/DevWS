using System.IO.Compression;

namespace DevWS.Setup;

internal sealed class PlannedPayloadEntry
{
    internal PlannedPayloadEntry(string relativePath, bool isDirectory, ZipArchiveEntry entry)
    {
        RelativePath = relativePath;
        IsDirectory = isDirectory;
        Entry = entry;
    }

    internal string RelativePath { get; }
    internal bool IsDirectory { get; }
    internal ZipArchiveEntry Entry { get; }
}

internal static class PayloadArchive
{
    internal const string ResourceName = "DevWS.Setup.Payload.zip";
    private const int MaxEntries = 10_000;
    private const long MaxUncompressedBytes = 256L * 1024 * 1024;

    internal static void ExtractEmbedded(string stagingRoot)
    {
        using var stream = typeof(PayloadArchive).Assembly.GetManifestResourceStream(ResourceName)
            ?? throw new SetupException("The embedded DevWS payload resource is missing from DevWS-Setup.exe.");
        using var archive = new ZipArchive(stream, ZipArchiveMode.Read, leaveOpen: false);
        Extract(archive, stagingRoot);
    }

    internal static void Extract(ZipArchive archive, string stagingRoot)
    {
        var planned = PlanEntries(archive, stagingRoot);
        Directory.CreateDirectory(stagingRoot);

        foreach (var item in planned)
        {
            var destination = Path.Combine(
                Path.GetFullPath(stagingRoot),
                item.RelativePath.Replace('/', Path.DirectorySeparatorChar));

            if (item.IsDirectory)
            {
                Directory.CreateDirectory(destination);
                continue;
            }

            var parent = Path.GetDirectoryName(destination);
            if (!string.IsNullOrEmpty(parent))
            {
                Directory.CreateDirectory(parent);
            }

            using var input = item.Entry.Open();
            using var output = new FileStream(
                destination,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                81_920,
                FileOptions.SequentialScan);
            input.CopyTo(output);
        }

        var installer = Path.Combine(Path.GetFullPath(stagingRoot), "install.ps1");
        if (!File.Exists(installer) ||
            (File.GetAttributes(installer) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
        {
            throw new SetupException("The payload did not produce a normal install.ps1 in protected staging.");
        }

        PathSafety.EnsureNoReparseChain(installer, Path.GetFullPath(stagingRoot));
    }

    internal static IReadOnlyList<PlannedPayloadEntry> PlanEntries(ZipArchive archive, string stagingRoot)
    {
        if (!Path.IsPathFullyQualified(stagingRoot))
        {
            throw new SetupException("The payload staging root is not absolute.");
        }

        var root = Path.GetFullPath(stagingRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var rootWithSeparator = root + Path.DirectorySeparatorChar;
        var destinations = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        var planned = new List<PlannedPayloadEntry>();
        long totalBytes = 0;

        foreach (var entry in archive.Entries)
        {
            if (planned.Count >= MaxEntries)
            {
                throw new SetupException($"The payload has more than {MaxEntries} entries.");
            }

            var raw = entry.FullName;
            if (string.IsNullOrWhiteSpace(raw))
            {
                throw new SetupException("The payload contains an entry with an empty name.");
            }

            var normalized = raw.Replace('\\', '/');
            var isDirectory = normalized.EndsWith("/", StringComparison.Ordinal);
            if (isDirectory)
            {
                normalized = normalized.TrimEnd('/');
            }

            if (normalized.Length == 0 ||
                normalized.StartsWith("/", StringComparison.Ordinal) ||
                normalized.Contains(':') ||
                normalized.Contains('\0'))
            {
                throw new SetupException($"The payload contains an unsafe absolute or drive-qualified entry: '{raw}'.");
            }

            if ((entry.ExternalAttributes & (int)FileAttributes.ReparsePoint) != 0 ||
                ((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000)
            {
                throw new SetupException($"The payload contains a reparse/symlink entry: '{raw}'.");
            }

            if (isDirectory && entry.Length != 0)
            {
                throw new SetupException($"The payload contains a non-empty directory entry: '{raw}'.");
            }

            if (entry.Length < 0 || totalBytes > MaxUncompressedBytes - entry.Length)
            {
                throw new SetupException($"The payload exceeds the {MaxUncompressedBytes / (1024 * 1024)} MiB uncompressed limit.");
            }
            totalBytes += entry.Length;

            var segments = normalized.Split('/');
            foreach (var segment in segments)
            {
                if (segment.Length == 0 ||
                    segment == "." ||
                    segment == ".." ||
                    segment.EndsWith(" ", StringComparison.Ordinal) ||
                    segment.EndsWith(".", StringComparison.Ordinal))
                {
                    throw new SetupException($"The payload contains an unsafe path segment in '{raw}'.");
                }
            }

            var relative = string.Join("/", segments);
            var destination = Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));
            if (!destination.StartsWith(rootWithSeparator, StringComparison.OrdinalIgnoreCase))
            {
                throw new SetupException($"The payload entry escapes the staging root: '{raw}'.");
            }

            if (!destinations.TryAdd(relative, isDirectory))
            {
                throw new SetupException($"The payload contains duplicate normalized targets: '{relative}'.");
            }

            planned.Add(new PlannedPayloadEntry(relative, isDirectory, entry));
        }

        foreach (var relative in destinations.Keys)
        {
            var parts = relative.Split('/');
            for (var index = 1; index < parts.Length; index++)
            {
                var parent = string.Join("/", parts.Take(index));
                if (destinations.TryGetValue(parent, out var parentIsDirectory) && !parentIsDirectory)
                {
                    throw new SetupException($"The payload has a file/directory conflict at '{parent}'.");
                }
            }
        }

        return planned;
    }
}
