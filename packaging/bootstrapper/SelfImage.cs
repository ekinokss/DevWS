using System.Security.Cryptography;

namespace DevWS.Setup;

internal sealed class SelfImage : IDisposable
{
    private readonly FileStream _stream;

    private SelfImage(string path, FileStream stream, long length, string hash)
    {
        SourcePath = path;
        _stream = stream;
        Length = length;
        Hash = hash;
    }

    internal string SourcePath { get; }
    internal long Length { get; }
    internal string Hash { get; }

    internal static SelfImage Open() => Open(Environment.ProcessPath ?? string.Empty);

    internal static SelfImage Open(string path)
    {
        if (string.IsNullOrWhiteSpace(path) || !System.IO.Path.IsPathFullyQualified(path))
        {
            throw new SetupException("The running setup executable path could not be resolved absolutely.");
        }

        path = System.IO.Path.GetFullPath(path);
        if (!File.Exists(path) ||
            (File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
        {
            throw new SetupException("The running setup executable is not an ordinary file.");
        }

        FileStream stream;
        try
        {
            stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        }
        catch (Exception error)
        {
            throw new SetupException($"Could not hold a stable read handle on the running setup image: {error.Message}", error);
        }

        try
        {
            var length = stream.Length;
            using var sha = SHA256.Create();
            var digest = sha.ComputeHash(stream);
            stream.Position = 0;
            return new SelfImage(path, stream, length, Convert.ToHexString(digest));
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }

    internal void CopyTo(string destination)
    {
        _stream.Position = 0;
        using var output = new FileStream(
            destination,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            81_920,
            FileOptions.SequentialScan);
        _stream.CopyTo(output);
        output.Flush(flushToDisk: true);
    }

    public void Dispose() => _stream.Dispose();
}
