using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace DevWS.Editor;

public partial class App : Application
{
    private readonly Stopwatch _appStopwatch = Stopwatch.StartNew();
    private string? _devConfigPath;
    private string? _snapshotPath;
    private string? _logPath;
    private bool _smoke;
    private bool _smokeStarted;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ParseArguments(e.Args);

        var integrity = IntegrityProbe.GetIntegrityLevel();
        if (!string.Equals(integrity, "Medium", StringComparison.OrdinalIgnoreCase))
        {
            MessageBox.Show(
                $"DevWS Editor must run at normal (Medium) integrity. The current process is {integrity}.\n\n" +
                "Close this elevated instance and launch the editor normally. Configuration editing is a " +
                "normal-integrity operation.",
                "DevWS Editor — integrity refusal",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
            Shutdown(2);
            return;
        }

        string pwshPath;
        string backendPath;

        try
        {
            pwshPath = PwshLocator.Resolve();
            backendPath = BackendLocator.Resolve();

            if (!string.IsNullOrWhiteSpace(_devConfigPath))
            {
                _devConfigPath = Path.GetFullPath(_devConfigPath);
                if (!File.Exists(_devConfigPath))
                {
                    throw new FileNotFoundException("The development configuration was not found.", _devConfigPath);
                }
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                ex.Message,
                "DevWS Editor — startup failure",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(2);
            return;
        }

        var options = new BackendLaunchOptions(
            pwshPath,
            backendPath,
            _devConfigPath,
            TimeSpan.FromSeconds(10));
        var client = new BackendClient(options);
        var session = new EditorSession(client);
        var viewModel = new EditorViewModel(session, _devConfigPath is not null, integrity);
        var window = new MainWindow(viewModel, _appStopwatch);
        MainWindow = window;

        if (!_smoke)
        {
            ShutdownMode = ShutdownMode.OnMainWindowClose;
            window.Show();
            return;
        }

        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        window.Show();
        window.ContentRendered += async (_, _) =>
        {
            if (_smokeStarted)
            {
                return;
            }

            _smokeStarted = true;
            var ok = await window.RunSmokeAsync(_snapshotPath, _logPath);
            Shutdown(ok ? 0 : 1);
        };
    }

    private void ParseArguments(string[] args)
    {
        for (var index = 0; index < args.Length; index++)
        {
            switch (args[index])
            {
                case "--dev-config":
                    _devConfigPath = NextValue(args, ref index);
                    break;
                case "--snapshot":
                    _snapshotPath = NextValue(args, ref index);
                    break;
                case "--log":
                    _logPath = NextValue(args, ref index);
                    break;
                case "--smoke":
                    _smoke = true;
                    break;
            }
        }

        if (_smoke && string.IsNullOrWhiteSpace(_logPath))
        {
            _logPath = Path.Combine(Path.GetTempPath(), $"devws-editor-smoke-{Environment.ProcessId}.json");
        }

        if (!string.IsNullOrWhiteSpace(_snapshotPath))
        {
            _snapshotPath = Path.GetFullPath(_snapshotPath);
        }

        if (!string.IsNullOrWhiteSpace(_logPath))
        {
            _logPath = Path.GetFullPath(_logPath);
        }
    }

    private static string? NextValue(string[] args, ref int index)
    {
        if (index + 1 >= args.Length)
        {
            return null;
        }

        index++;
        return args[index];
    }
}
