using System.Diagnostics;
using System.Runtime.InteropServices;

namespace DevWS.Setup;

internal sealed record TrustedPowerShell(string Path);

internal static class PowerShellResolver
{
    internal const string MsixPackageFamilyName = "Microsoft.PowerShell_8wekyb3d8bbwe";

    internal static TrustedPowerShell ResolveAndVerify()
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        if (string.IsNullOrWhiteSpace(programFiles) || !Path.IsPathFullyQualified(programFiles))
        {
            throw new SetupException("The Windows Program Files root could not be resolved as an absolute path.");
        }

        var candidates = new List<(string Path, string AllowedRoot)>
        {
            (Path.Combine(programFiles, "PowerShell", "7", "pwsh.exe"), programFiles)
        };

        try
        {
            var windowsApps = Path.Combine(programFiles, "WindowsApps");
            foreach (var candidate in FindMsixCandidates())
            {
                candidates.Add((candidate, windowsApps));
            }
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new SetupException($"Could not enumerate the official Microsoft PowerShell MSIX package: {error.Message}", error);
        }

        var failures = new List<string>();
        foreach (var candidate in candidates)
        {
            var shapeProblem = ValidateCandidatePath(candidate.Path, candidate.AllowedRoot);
            if (shapeProblem is not null)
            {
                failures.Add(shapeProblem);
                continue;
            }

            if (!HasSupportedMajorVersion(candidate.Path))
            {
                failures.Add($"'{candidate.Path}' does not report a PowerShell major version >= 7.");
                continue;
            }

            var verification = VerifyRuntime(candidate.Path);
            if (!verification.Ok)
            {
                failures.Add(verification.Detail);
                continue;
            }

            return new TrustedPowerShell(candidate.Path);
        }

        throw new SetupException(
            "No trusted PowerShell 7 executable was found. " +
            "Expected the machine-wide Program Files installation or the official Microsoft PowerShell MSIX package. " +
            string.Join(" ", failures));
    }

    internal static string? ValidateCandidatePath(string candidate, string allowedRoot)
    {
        if (!Path.IsPathFullyQualified(candidate) || !Path.IsPathFullyQualified(allowedRoot))
        {
            return $"PowerShell candidate is not an absolute path: '{candidate}'.";
        }

        var fullCandidate = Path.GetFullPath(candidate);
        var fullRoot = Path.GetFullPath(allowedRoot);

        if (!string.Equals(Path.GetFileName(fullCandidate), "pwsh.exe", StringComparison.OrdinalIgnoreCase))
        {
            return $"PowerShell candidate must have the exact leaf 'pwsh.exe': '{fullCandidate}'.";
        }

        if (!PathSafety.IsSameOrDescendant(fullCandidate, fullRoot))
        {
            return $"PowerShell candidate is outside the trusted root '{fullRoot}': '{fullCandidate}'.";
        }

        if (!File.Exists(fullCandidate))
        {
            return $"PowerShell candidate does not exist as a normal file: '{fullCandidate}'.";
        }

        try
        {
            PathSafety.EnsureNoReparseChain(fullCandidate, fullRoot);
        }
        catch (Exception error)
        {
            return $"PowerShell candidate failed the reparse-point check: {error.Message}";
        }

        if ((File.GetAttributes(fullCandidate) & FileAttributes.Directory) != 0)
        {
            return $"PowerShell candidate is a directory, not pwsh.exe: '{fullCandidate}'.";
        }

        return null;
    }

    internal static bool HasSupportedMajorVersion(string path)
    {
        try
        {
            var version = FileVersionInfo.GetVersionInfo(path);
            return version.FileMajorPart >= 7 || version.ProductMajorPart >= 7;
        }
        catch
        {
            return false;
        }
    }

    internal static (bool Ok, string Detail) VerifyRuntime(string path)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = path,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-Command");
        startInfo.ArgumentList.Add("$PSVersionTable.PSVersion.Major");

        try
        {
            using var process = Process.Start(startInfo);
            if (process is null)
            {
                return (false, $"'{path}' could not be started for runtime verification.");
            }

            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(15_000))
            {
                try { process.Kill(entireProcessTree: true); } catch { }
                return (false, $"'{path}' timed out during runtime verification.");
            }

            var output = stdout.GetAwaiter().GetResult().Trim();
            var error = stderr.GetAwaiter().GetResult().Trim();
            if (process.ExitCode != 0)
            {
                return (false, $"'{path}' runtime verification exited {process.ExitCode}: {error}");
            }

            if (int.TryParse(output, out var major) && major >= 7)
            {
                return (true, string.Empty);
            }

            return (false, $"'{path}' reported PowerShell major '{output}', not >= 7.");
        }
        catch (Exception error)
        {
            return (false, $"'{path}' runtime verification failed: {error.Message}");
        }
    }

    internal static IReadOnlyList<string> FindMsixCandidates()
    {
        var fullNames = GetRegisteredPackageFullNames();
        var candidates = new List<string>();

        foreach (var fullName in fullNames)
        {
            var packagePath = GetPackagePath(fullName);
            if (string.IsNullOrWhiteSpace(packagePath))
            {
                continue;
            }

            candidates.Add(Path.Combine(packagePath, "pwsh.exe"));
        }

        candidates.Sort(StringComparer.Ordinal);
        return candidates;
    }

    private static IReadOnlyList<string> GetRegisteredPackageFullNames()
    {
        uint count = 0;
        uint bufferLength = 0;
        var status = NativeMethods.GetPackagesByPackageFamily(
            MsixPackageFamilyName,
            out count,
            IntPtr.Zero,
            ref bufferLength,
            IntPtr.Zero);

        if (status == NativeMethods.ErrorSuccess && count == 0)
        {
            return Array.Empty<string>();
        }

        if (status != NativeMethods.ErrorInsufficientBuffer || count == 0 || bufferLength == 0)
        {
            return Array.Empty<string>();
        }

        var namesPointer = Marshal.AllocHGlobal(checked((int)count * IntPtr.Size));
        var stringsPointer = Marshal.AllocHGlobal(checked((int)bufferLength * sizeof(char)));

        try
        {
            status = NativeMethods.GetPackagesByPackageFamily(
                MsixPackageFamilyName,
                out count,
                namesPointer,
                ref bufferLength,
                stringsPointer);

            if (status != NativeMethods.ErrorSuccess)
            {
                return Array.Empty<string>();
            }

            var names = new List<string>(checked((int)count));
            for (var index = 0; index < count; index++)
            {
                var itemPointer = Marshal.ReadIntPtr(namesPointer, checked((int)index) * IntPtr.Size);
                var name = Marshal.PtrToStringUni(itemPointer);
                if (!string.IsNullOrWhiteSpace(name))
                {
                    names.Add(name);
                }
            }

            return names;
        }
        finally
        {
            Marshal.FreeHGlobal(namesPointer);
            Marshal.FreeHGlobal(stringsPointer);
        }
    }

    private static string? GetPackagePath(string packageFullName)
    {
        uint pathLength = 0;
        var status = NativeMethods.GetPackagePathByFullName(packageFullName, ref pathLength, IntPtr.Zero);
        if (status != NativeMethods.ErrorInsufficientBuffer || pathLength == 0)
        {
            return null;
        }

        var pathPointer = Marshal.AllocHGlobal(checked((int)pathLength * sizeof(char)));
        try
        {
            status = NativeMethods.GetPackagePathByFullName(packageFullName, ref pathLength, pathPointer);
            return status == NativeMethods.ErrorSuccess
                ? Marshal.PtrToStringUni(pathPointer)
                : null;
        }
        finally
        {
            Marshal.FreeHGlobal(pathPointer);
        }
    }
}
