namespace DevWS.Setup;

internal static class PathSafety
{
    /// <summary>
    /// Rejects any reparse-point component from <paramref name="path"/> up to and including
    /// <paramref name="stopAt"/>. The caller supplies an absolute, OS-known authority root.
    /// </summary>
    internal static void EnsureNoReparseChain(string path, string stopAt)
    {
        if (!Path.IsPathFullyQualified(path) || !Path.IsPathFullyQualified(stopAt))
        {
            throw new SetupException($"A trusted path is not absolute: '{path}' or '{stopAt}'.");
        }

        var current = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var root = Path.GetFullPath(stopAt).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

        if (!IsSameOrDescendant(current, root))
        {
            throw new SetupException($"Path '{current}' is not under the expected root '{root}'.");
        }

        while (true)
        {
            if (File.Exists(current) || Directory.Exists(current))
            {
                var attributes = File.GetAttributes(current);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw new SetupException($"Refusing a reparse-point path component: '{current}'.");
                }
            }

            if (string.Equals(current, root, StringComparison.OrdinalIgnoreCase))
            {
                break;
            }

            var parent = Path.GetDirectoryName(current);
            if (string.IsNullOrEmpty(parent) || string.Equals(parent, current, StringComparison.OrdinalIgnoreCase))
            {
                throw new SetupException($"Could not validate the path chain for '{path}'.");
            }
            current = parent;
        }
    }

    internal static bool IsSameOrDescendant(string path, string root)
    {
        var fullPath = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return string.Equals(fullPath, fullRoot, StringComparison.OrdinalIgnoreCase)
            || fullPath.StartsWith(fullRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }
}
