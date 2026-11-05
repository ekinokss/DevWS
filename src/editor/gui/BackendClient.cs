using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using Microsoft.Win32;

namespace DevWS.Editor;

public sealed record BackendHello(
    string Protocol,
    string BackendVersion,
    IReadOnlyList<string> SupportedOps,
    bool ReadOnly,
    bool SaveSupported,
    long MaxRequestBytes,
    long MaxResponseBytes,
    int MaxJsonDepth);

public sealed class BackendResponse
{
    public BackendResponse(JsonElement result, JsonElement warnings, string raw)
    {
        Result = result;
        Warnings = warnings;
        Raw = raw;
    }

    public JsonElement Result { get; }
    public JsonElement Warnings { get; }
    public string Raw { get; }
}

public sealed class BackendException : Exception
{
    public BackendException(
        string code,
        string message,
        bool retryable = false,
        string? details = null,
        bool isTransportFailure = false,
        bool isProtocolError = false,
        Exception? inner = null)
        : base(message, inner)
    {
        Code = code;
        Retryable = retryable;
        DetailsText = details;
        IsTransportFailure = isTransportFailure;
        IsProtocolError = isProtocolError;
    }

    public string Code { get; }
    public bool Retryable { get; }
    public string? DetailsText { get; }
    public bool IsTransportFailure { get; }
    public bool IsProtocolError { get; }
}

public sealed class BackendLaunchOptions
{
    public BackendLaunchOptions(
        string pwshPath,
        string backendScriptPath,
        string? devConfigPath = null,
        TimeSpan? requestTimeout = null,
        IReadOnlyDictionary<string, string?>? additionalEnvironment = null)
    {
        PwshPath = FullExistingFile(pwshPath, "PowerShell executable");
        BackendScriptPath = FullExistingFile(backendScriptPath, "editor backend script");

        if (!string.IsNullOrWhiteSpace(devConfigPath))
        {
            DevConfigPath = FullExistingFile(devConfigPath, "development configuration");
        }

        RequestTimeout = requestTimeout ?? TimeSpan.FromSeconds(10);
        if (RequestTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(requestTimeout));
        }

        AdditionalEnvironment = additionalEnvironment ?? new Dictionary<string, string?>();
    }

    public string PwshPath { get; }
    public string BackendScriptPath { get; }
    public string? DevConfigPath { get; }
    public TimeSpan RequestTimeout { get; }
    public IReadOnlyDictionary<string, string?> AdditionalEnvironment { get; }

    private static string FullExistingFile(string path, string label)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new ArgumentException($"{label} path is required.", nameof(path));
        }

        var full = Path.GetFullPath(path);
        if (!File.Exists(full))
        {
            throw new FileNotFoundException($"{label} was not found.", full);
        }

        return full;
    }
}

public sealed class BackendClient : IDisposable
{
    private const string Protocol = "devws-editor/1";
    private const int MaxRetainedStderrChars = 64 * 1024;

    private readonly BackendLaunchOptions _options;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly StringBuilder _stderr = new();
    private readonly object _stderrLock = new();
    private Process? _process;
    private StreamWriter? _stdin;
    private StreamReader? _stdout;
    private StreamReader? _stderrReader;
    private Task? _stderrTask;
    private BackendHello? _hello;
    private long _nextId;
    private bool _disposed;
    private int? _lastExitCode;

    public BackendClient(BackendLaunchOptions options)
    {
        _options = options;
    }

    public BackendHello? Hello => _hello;
    public int? ProcessId => _process is { HasExited: false } process ? process.Id : null;
    public bool HasExited => _process is null || _process.HasExited;
    public int? ExitCode => _lastExitCode;
    public double LastConnectMs { get; private set; }
    public string LastStderr
    {
        get
        {
            lock (_stderrLock)
            {
                return _stderr.ToString();
            }
        }
    }

    public async Task<BackendHello> ConnectAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await EnsureConnectedCoreAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<BackendResponse> SendAsync(
        string op,
        object? parameters = null,
        CancellationToken cancellationToken = default)
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(BackendClient));
        }

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            await EnsureConnectedCoreAsync(cancellationToken).ConfigureAwait(false);

            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    return await SendOnceCoreAsync(op, parameters, cancellationToken).ConfigureAwait(false);
                }
                catch (BackendException ex) when (ex.IsTransportFailure && attempt == 0)
                {
                    await RestartCoreAsync(cancellationToken).ConfigureAwait(false);
                }
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<BackendHello> EnsureConnectedCoreAsync(CancellationToken cancellationToken)
    {
        if (_process is { HasExited: false } && _hello is not null)
        {
            return _hello;
        }

        StopProcessCore();
        var started = Stopwatch.StartNew();
        StartProcessCore();

        try
        {
            _hello = await SendHelloOnceAsync(cancellationToken).ConfigureAwait(false);
            LastConnectMs = started.Elapsed.TotalMilliseconds;
            return _hello;
        }
        catch
        {
            StopProcessCore();
            throw;
        }
    }

    private async Task RestartCoreAsync(CancellationToken cancellationToken)
    {
        StopProcessCore();
        await EnsureConnectedCoreAsync(cancellationToken).ConfigureAwait(false);
    }

    private void StartProcessCore()
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = _options.PwshPath,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(_options.BackendScriptPath) ?? AppContext.BaseDirectory
        };

        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(_options.BackendScriptPath);

        startInfo.StandardInputEncoding = new UTF8Encoding(false);
        startInfo.StandardOutputEncoding = new UTF8Encoding(false);
        startInfo.StandardErrorEncoding = new UTF8Encoding(false);

        startInfo.Environment.Remove("DEVWS_CONFIG");
        startInfo.Environment.Remove("DEVWS_STATE_ROOT");
        startInfo.Environment.Remove("DEVWS_INSTALL_ROOT");

        if (!string.IsNullOrWhiteSpace(_options.DevConfigPath))
        {
            startInfo.Environment["DEVWS_CONFIG"] = _options.DevConfigPath;
        }

        foreach (var pair in _options.AdditionalEnvironment)
        {
            if (pair.Value is null)
            {
                startInfo.Environment.Remove(pair.Key);
            }
            else
            {
                startInfo.Environment[pair.Key] = pair.Value;
            }
        }

        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = false };

        if (!process.Start())
        {
            process.Dispose();
            throw new BackendException("backend-start-failed", "The editor backend process could not be started.");
        }

        _process = process;
        _stdin = process.StandardInput;
        _stdin.AutoFlush = true;
        _stdin.NewLine = "\n";
        _stdout = process.StandardOutput;
        _stderrReader = process.StandardError;
        _stderrTask = Task.Run(ReadStderrAsync);
    }

    private async Task ReadStderrAsync()
    {
        var reader = _stderrReader;
        if (reader is null)
        {
            return;
        }

        try
        {
            while (true)
            {
                var line = await reader.ReadLineAsync().ConfigureAwait(false);
                if (line is null)
                {
                    break;
                }

                AppendStderr(line);
            }
        }
        catch
        {
            // Diagnostics are best-effort; protocol data is never read from stderr.
        }
    }

    private void AppendStderr(string line)
    {
        lock (_stderrLock)
        {
            if (_stderr.Length + line.Length + 2 > MaxRetainedStderrChars)
            {
                var remove = Math.Max(0, _stderr.Length - MaxRetainedStderrChars / 2);
                _stderr.Remove(0, remove);
            }

            _stderr.AppendLine(line);
        }
    }

    private async Task<BackendResponse> SendOnceCoreAsync(
        string op,
        object? parameters,
        CancellationToken cancellationToken)
    {
        if (_process is null || _process.HasExited || _stdin is null || _stdout is null)
        {
            throw new BackendException(
                "backend-exited",
                "The editor backend is not running.",
                retryable: true,
                isTransportFailure: true);
        }

        var id = $"gui-{Interlocked.Increment(ref _nextId)}";
        var request = new Dictionary<string, object?>
        {
            ["protocol"] = Protocol,
            ["id"] = id,
            ["op"] = op,
            ["params"] = parameters ?? new Dictionary<string, object?>()
        };

        var json = JsonSerializer.Serialize(request);

        try
        {
            _stdin.WriteLine(json);
            _stdin.Flush();
        }
        catch (Exception ex)
        {
            StopProcessCore();
            throw new BackendException(
                "backend-exited",
                "The editor backend exited before the request could be written.",
                retryable: true,
                isTransportFailure: true,
                inner: ex);
        }

        var line = await ReadLineWithTimeoutAsync(cancellationToken).ConfigureAwait(false);
        if (line is null)
        {
            StopProcessCore();
            throw new BackendException(
                "backend-exited",
                "The editor backend exited before responding.",
                retryable: true,
                isTransportFailure: true);
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(line);
        }
        catch (Exception ex)
        {
            StopProcessCore();
            throw new BackendException(
                "protocol-error",
                "The editor backend returned malformed JSON.",
                isProtocolError: true,
                inner: ex);
        }

        using (document)
        {
            var root = document.RootElement;
            var responseProtocol = JsonText.String(root, "protocol");
            var responseId = JsonText.String(root, "id");
            var responseOp = JsonText.String(root, "op");

            if (responseProtocol != Protocol || responseId != id || responseOp != op)
            {
                StopProcessCore();
                throw new BackendException(
                    "protocol-error",
                    "The editor backend response did not match the request.",
                    isProtocolError: true);
            }

            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("ok", out var okElement) ||
                okElement.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            {
                StopProcessCore();
                throw new BackendException(
                    "protocol-error",
                    "The editor backend response did not contain a boolean result state.",
                    isProtocolError: true);
            }

            if (!okElement.GetBoolean())
            {
                var error = JsonText.Object(root, "error");
                var code = JsonText.String(error, "code");
                var message = JsonText.String(error, "message");
                var retryable = JsonText.Bool(error, "retryable");
                var details = error.ValueKind == JsonValueKind.Object &&
                              error.TryGetProperty("details", out var detailElement)
                    ? detailElement.GetRawText()
                    : null;

                throw new BackendException(
                    string.IsNullOrWhiteSpace(code) ? "backend-error" : code,
                    string.IsNullOrWhiteSpace(message) ? "The editor backend refused the request." : message,
                    retryable,
                    details);
            }

            var result = root.TryGetProperty("result", out var resultElement)
                ? resultElement.Clone()
                : default;
            var warnings = root.TryGetProperty("warnings", out var warningsElement)
                ? warningsElement.Clone()
                : default;

            return new BackendResponse(result, warnings, line);
        }
    }

    private async Task<BackendHello> SendHelloOnceAsync(CancellationToken cancellationToken)
    {
        var response = await SendOnceCoreAsync(
            "hello",
            new Dictionary<string, object?>(),
            cancellationToken).ConfigureAwait(false);

        var result = response.Result;
        var protocol = JsonText.String(result, "protocol");
        if (protocol != Protocol)
        {
            throw new BackendException(
                "protocol-version-unsupported",
                $"The editor backend speaks unsupported protocol '{protocol}'.");
        }

        var supportedOps = JsonText.StringArray(result, "supportedOps");
        foreach (var required in new[] { "inspect", "read-config", "project" })
        {
            if (!supportedOps.Contains(required, StringComparer.Ordinal))
            {
                throw new BackendException(
                    "unsupported-operation",
                    $"The editor backend does not support required operation '{required}'.",
                    details: string.Join(", ", supportedOps));
            }
        }

        var capabilities = JsonText.Object(result, "capabilities");
        var readOnly = JsonText.Bool(capabilities, "readOnly");
        if (!readOnly)
        {
            throw new BackendException(
                "read-only-required",
                "The editor backend did not advertise read-only capabilities.");
        }

        return new BackendHello(
            protocol,
            JsonText.String(result, "backendVersion"),
            supportedOps,
            readOnly,
            JsonText.Bool(capabilities, "saveSupported"),
            JsonText.Long(JsonText.Object(result, "limits"), "maxRequestBytes"),
            JsonText.Long(JsonText.Object(result, "limits"), "maxResponseBytes"),
            JsonText.Int(JsonText.Object(result, "limits"), "maxJsonDepth"));
    }

    private async Task<string?> ReadLineWithTimeoutAsync(CancellationToken cancellationToken)
    {
        if (_stdout is null)
        {
            return null;
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_options.RequestTimeout);

        try
        {
            return await _stdout.ReadLineAsync(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            StopProcessCore();
            throw new BackendException(
                "timeout",
                $"The editor backend did not respond within {_options.RequestTimeout.TotalSeconds:0.#} seconds.",
                retryable: true,
                isTransportFailure: true);
        }
    }

    private void StopProcessCore()
    {
        _hello = null;
        var process = _process;
        _process = null;

        try
        {
            _stdin?.Close();
        }
        catch
        {
        }

        if (process is not null)
        {
            try
            {
                if (!process.HasExited && !process.WaitForExit(1500))
                {
                    process.Kill(entireProcessTree: true);
                    process.WaitForExit(2000);
                }

                if (process.HasExited)
                {
                    _lastExitCode = process.ExitCode;
                }
            }
            catch
            {
            }
        }

        if (_stderrTask is not null)
        {
            try
            {
                _stderrTask.Wait(1000);
            }
            catch
            {
            }

            _stderrTask = null;
        }

        _stdin?.Dispose();
        _stdout?.Dispose();
        _stderrReader?.Dispose();
        _stdin = null;
        _stdout = null;
        _stderrReader = null;

        process?.Dispose();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        var acquired = false;

        try
        {
            acquired = _gate.Wait(2000);
            StopProcessCore();
        }
        finally
        {
            if (acquired)
            {
                _gate.Release();
            }

            _gate.Dispose();
        }
    }
}

public static class PwshLocator
{
    public static string Resolve()
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var candidates = new List<string>
        {
            Path.Combine(programFiles, "PowerShell", "7", "pwsh.exe"),
            Path.Combine(programFiles, "PowerShell", "7-preview", "pwsh.exe")
        };

        var powershellRoot = Path.Combine(programFiles, "PowerShell");
        try
        {
            if (Directory.Exists(powershellRoot))
            {
                candidates.AddRange(
                    Directory.GetDirectories(powershellRoot)
                        .OrderByDescending(path => path, StringComparer.OrdinalIgnoreCase)
                        .Select(path => Path.Combine(path, "pwsh.exe")));
            }
        }
        catch
        {
        }

        // Store-installed PowerShell lives under Program Files\WindowsApps, which
        // a medium-integrity process may not enumerate. Derive candidate package
        // roots from PSModulePath and PATH, then accept only files that remain
        // under the protected WindowsApps root.
        var windowsApps = Path.GetFullPath(Path.Combine(programFiles, "WindowsApps")).TrimEnd('\\');
        foreach (var variableName in new[] { "PSModulePath", "Path" })
        {
            var value = Environment.GetEnvironmentVariable(variableName);
            if (string.IsNullOrWhiteSpace(value))
            {
                continue;
            }

            foreach (var rawEntry in value.Split(';'))
            {
                var entry = rawEntry.Trim().Trim('"');
                if (string.IsNullOrWhiteSpace(entry))
                {
                    continue;
                }

                string full;
                try
                {
                    full = Path.GetFullPath(entry).TrimEnd('\\');
                }
                catch
                {
                    continue;
                }

                if (!full.StartsWith(windowsApps + "\\", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var packageRoot = full.EndsWith("\\Modules", StringComparison.OrdinalIgnoreCase)
                    ? Path.GetDirectoryName(full)
                    : full;

                if (string.IsNullOrWhiteSpace(packageRoot))
                {
                    continue;
                }

                var candidate = Path.Combine(packageRoot, "pwsh.exe");
                if (File.Exists(candidate))
                {
                    candidates.Add(candidate);
                }
            }
        }

        // Store installs register the package path in per-user App Paths and in
        // the AppModel package repository. Those keys are user-writable, so the
        // candidate is accepted only when it is a pwsh.exe inside the protected
        // WindowsApps root and the package directory is the PowerShell package.
        try
        {
            using var appPath = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe");
            if (appPath?.GetValue(null) is string registered)
            {
                candidates.Add(registered);
            }
        }
        catch
        {
        }

        try
        {
            using var packages = Registry.CurrentUser.OpenSubKey(
                @"Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages");
            if (packages is not null)
            {
                foreach (var packageName in packages.GetSubKeyNames())
                {
                    if (!packageName.StartsWith("Microsoft.PowerShell_", StringComparison.OrdinalIgnoreCase) ||
                        !packageName.EndsWith("_x64__8wekyb3d8bbwe", StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    using var package = packages.OpenSubKey(packageName);
                    if (package?.GetValue("PackageRootFolder") is string packageRoot &&
                        !string.IsNullOrWhiteSpace(packageRoot))
                    {
                        candidates.Add(Path.Combine(packageRoot, "pwsh.exe"));
                    }
                }
            }
        }
        catch
        {
        }

        foreach (var candidate in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            string full;
            try
            {
                full = Path.GetFullPath(candidate);
            }
            catch
            {
                continue;
            }

            if (!File.Exists(full))
            {
                continue;
            }

            var directory = Path.GetDirectoryName(full) ?? "";
            var packageDirectory = Path.GetFileName(directory);
            var isWindowsAppsPowerShell =
                full.StartsWith(windowsApps + "\\", StringComparison.OrdinalIgnoreCase) &&
                packageDirectory.StartsWith("Microsoft.PowerShell_", StringComparison.OrdinalIgnoreCase) &&
                packageDirectory.EndsWith("_x64__8wekyb3d8bbwe", StringComparison.OrdinalIgnoreCase) &&
                string.Equals(Path.GetFileName(full), "pwsh.exe", StringComparison.OrdinalIgnoreCase);

            var isProgramFilesPowerShell =
                full.StartsWith(Path.GetFullPath(Path.Combine(programFiles, "PowerShell")) + "\\",
                    StringComparison.OrdinalIgnoreCase) &&
                string.Equals(Path.GetFileName(full), "pwsh.exe", StringComparison.OrdinalIgnoreCase);

            if (isWindowsAppsPowerShell || isProgramFilesPowerShell)
            {
                return full;
            }
        }

        throw new BackendException(
            "pwsh-missing",
            "PowerShell 7 was not found in a trusted Program Files location.");
    }
}

public static class BackendLocator
{
    public static string Resolve()
    {
        var installed = Path.Combine(AppContext.BaseDirectory, "ws-editor-backend.ps1");
        if (File.Exists(installed))
        {
            return Path.GetFullPath(installed);
        }

        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        for (var depth = 0; depth < 8 && directory is not null; depth++, directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, "src", "editor", "ws-editor-backend.ps1");
            if (File.Exists(candidate))
            {
                return Path.GetFullPath(candidate);
            }
        }

        throw new BackendException(
            "backend-missing",
            "The editor backend script (ws-editor-backend.ps1) was not found next to the editor or in the repository layout.");
    }
}
