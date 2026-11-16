using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace DevWS.WpfSpike;

public partial class App : Application
{
    private readonly Stopwatch _appStopwatch = Stopwatch.StartNew();
    private string? _fixturePath;
    private string? _logPath;
    private string? _snapshotPath;
    private int _exitAfterMs = 2000;
    private int _frames = 120;
    private bool _benchmark;
    private bool _interactionBenchmark;
    private DateTime _processStartUtc;
    private double _windowLoadedMs;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        ParseArguments(e.Args);
        _processStartUtc = GetProcessStartUtc();

        if (e.Args.Any(arg => arg.Equals("--self-test", StringComparison.OrdinalIgnoreCase)))
        {
            RunSelfTest();
            return;
        }

        var window = new MainWindow(_fixturePath);
        MainWindow = window;

        if (!_benchmark && !_interactionBenchmark && !string.IsNullOrWhiteSpace(_snapshotPath))
        {
            window.ContentRendered += (_, _) =>
            {
                Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() =>
                {
                    window.SaveSnapshot(_snapshotPath!);
                    Shutdown(0);
                }));
            };
            window.Show();
            return;
        }

        if (!_benchmark && !_interactionBenchmark)
        {
            ShutdownMode = System.Windows.ShutdownMode.OnMainWindowClose;
            window.Show();
            return;
        }

        window.Loaded += (_, _) => _windowLoadedMs = ElapsedMs();
        window.ContentRendered += (_, _) =>
        {
            Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => CompleteBenchmark(window)));
        };
        window.Show();
    }

    private void CompleteBenchmark(MainWindow window)
    {
        var canvasReadyMs = ElapsedMs();
        var processReadyMs = (DateTime.UtcNow - _processStartUtc).TotalMilliseconds;
        var dpi = VisualTreeHelper.GetDpi(window);
        var process = Process.GetCurrentProcess();
        process.Refresh();

        InteractionMetrics? interaction = null;
        if (_interactionBenchmark)
        {
            interaction = window.RunInteractionBenchmark(_frames);
        }

        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(_exitAfterMs) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            process.Refresh();

            var log = new
            {
                mode = _interactionBenchmark ? "interaction" : "startup",
                fixture = window.Fixture?.Name,
                fixturePath = _fixturePath,
                monitorCount = window.Fixture?.Monitors.Count ?? 0,
                itemCount = window.Fixture?.Items.Count ?? 0,
                processStartUtc = _processStartUtc,
                appStartupMs = Math.Round(_appStopwatch.Elapsed.TotalMilliseconds, 1),
                windowLoadedMs = Math.Round(_windowLoadedMs, 1),
                canvasReadyMs = Math.Round(canvasReadyMs, 1),
                processReadyMs = Math.Round(processReadyMs, 1),
                idleDelayMs = _exitAfterMs,
                workingSetBytes = process.WorkingSet64,
                workingSetMB = Math.Round(process.WorkingSet64 / 1024.0 / 1024.0, 2),
                cpuTotalMs = Math.Round(process.TotalProcessorTime.TotalMilliseconds, 1),
                dpiScaleX = dpi.DpiScaleX,
                dpiScaleY = dpi.DpiScaleY,
                primaryScreenWidth = SystemParameters.PrimaryScreenWidth,
                primaryScreenHeight = SystemParameters.PrimaryScreenHeight,
                virtualScreenRect = window.Fixture is null ? null : new
                {
                    x = window.Fixture.GetVirtualScreenRect().X,
                    y = window.Fixture.GetVirtualScreenRect().Y,
                    w = window.Fixture.GetVirtualScreenRect().Width,
                    h = window.Fixture.GetVirtualScreenRect().Height
                },
                monitors = window.Fixture?.Monitors.Select(monitor => new
                {
                    monitor.Id,
                    monitor.Name,
                    monitor.Primary,
                    monitor.ScalePercent,
                    monitorRect = new { x = monitor.MonitorRect.X, y = monitor.MonitorRect.Y, w = monitor.MonitorRect.W, h = monitor.MonitorRect.H },
                    workRect = new { x = monitor.WorkRect.X, y = monitor.WorkRect.Y, w = monitor.WorkRect.W, h = monitor.WorkRect.H }
                }).ToArray(),
                integrity = IntegrityProbe.GetIntegrityLevel(),
                processArchitecture = RuntimeInformation.ProcessArchitecture.ToString(),
                osDescription = RuntimeInformation.OSDescription,
                runtimeVersion = Environment.Version.ToString(),
                interaction
            };

            WriteJson(_logPath, log);
            Shutdown(0);
        };
        timer.Start();
    }

    private void RunSelfTest()
    {
        var results = GeometrySelfTest.Run();
        var passed = results.All(result => result.Passed);
        var log = new
        {
            mode = "self-test",
            passed,
            resultCount = results.Count,
            failedCount = results.Count(result => !result.Passed),
            integrity = IntegrityProbe.GetIntegrityLevel(),
            processArchitecture = RuntimeInformation.ProcessArchitecture.ToString(),
            osDescription = RuntimeInformation.OSDescription,
            runtimeVersion = Environment.Version.ToString(),
            results
        };

        WriteJson(_logPath, log);
        Shutdown(passed ? 0 : 1);
    }

    private double ElapsedMs() => _appStopwatch.Elapsed.TotalMilliseconds;

    private static DateTime GetProcessStartUtc()
    {
        try
        {
            return Process.GetCurrentProcess().StartTime.ToUniversalTime();
        }
        catch
        {
            return DateTime.UtcNow;
        }
    }

    private void ParseArguments(string[] args)
    {
        for (var index = 0; index < args.Length; index++)
        {
            var argument = args[index];
            switch (argument)
            {
                case "--fixture":
                    _fixturePath = NextValue(args, ref index);
                    break;
                case "--log":
                    _logPath = NextValue(args, ref index);
                    break;
                case "--snapshot":
                    _snapshotPath = NextValue(args, ref index);
                    break;
                case "--exit-after-ms":
                    if (int.TryParse(NextValue(args, ref index), out var exitAfter))
                    {
                        _exitAfterMs = Math.Max(100, exitAfter);
                    }
                    break;
                case "--frames":
                    if (int.TryParse(NextValue(args, ref index), out var frames))
                    {
                        _frames = Math.Max(1, frames);
                    }
                    break;
                case "--benchmark":
                    _benchmark = true;
                    break;
                case "--interaction-benchmark":
                    _interactionBenchmark = true;
                    break;
            }
        }

        if (!string.IsNullOrWhiteSpace(_fixturePath))
        {
            _fixturePath = Path.GetFullPath(_fixturePath);
        }

        if (!string.IsNullOrWhiteSpace(_logPath))
        {
            _logPath = Path.GetFullPath(_logPath);
        }
        else if (_benchmark || _interactionBenchmark)
        {
            _logPath = Path.Combine(Path.GetTempPath(), $"devws-wpf-spike-{Environment.ProcessId}.json");
        }

        if (!string.IsNullOrWhiteSpace(_snapshotPath))
        {
            _snapshotPath = Path.GetFullPath(_snapshotPath);
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

    private static void WriteJson(string? path, object value)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        var json = JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json);
    }
}
