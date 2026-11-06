using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace DevWS.Editor;

public partial class MainWindow : Window
{
    private readonly EditorViewModel _viewModel;
    private readonly Stopwatch _appStopwatch;
    private Task? _loadTask;
    private bool _syncingSelection;

    public MainWindow(EditorViewModel viewModel, Stopwatch appStopwatch)
    {
        InitializeComponent();
        _viewModel = viewModel;
        _appStopwatch = appStopwatch;
        DataContext = viewModel;

        Canvas.SelectionChanged += Canvas_SelectionChanged;
        Canvas.PointerWorldChanged += Canvas_PointerWorldChanged;
        Loaded += Window_Loaded;
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        await EnsureLoadedAsync();
    }

    private Task EnsureLoadedAsync()
    {
        return _loadTask ??= LoadInitialAsync();
    }

    private async Task LoadInitialAsync()
    {
        await _viewModel.LoadAsync();
        UpdateCanvasFromViewModel(resetView: true);
        SyncSelectionFromViewModel();
        UpdateStatus();
    }

    private async void SetList_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_syncingSelection || SetList.SelectedItem is not SetOption set)
        {
            return;
        }

        await _viewModel.SelectSetAsync(set);
        UpdateCanvasFromViewModel(resetView: true);
        SyncSelectionFromViewModel();
        UpdateStatus();
    }

    private void MonitorList_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_syncingSelection)
        {
            return;
        }

        _viewModel.SelectMonitorAt(MonitorList.SelectedIndex);
        Canvas.SelectMonitor(MonitorList.SelectedIndex);
        UpdateStatus();
    }

    private void ItemList_SelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_syncingSelection)
        {
            return;
        }

        _viewModel.SelectItemAt(ItemList.SelectedIndex);
        Canvas.SelectItem(ItemList.SelectedIndex);
        UpdateStatus();
    }

    private void Canvas_SelectionChanged(object? sender, EventArgs e)
    {
        if (_syncingSelection)
        {
            return;
        }

        _syncingSelection = true;

        try
        {
            MonitorList.SelectedIndex = Canvas.SelectedMonitorIndex;
            ItemList.SelectedIndex = Canvas.SelectedItemIndex;
        }
        finally
        {
            _syncingSelection = false;
        }

        _viewModel.SelectMonitorAt(Canvas.SelectedMonitorIndex);
        _viewModel.SelectItemAt(Canvas.SelectedItemIndex);
        UpdateStatus();
    }

    private void Canvas_PointerWorldChanged(object? sender, Point point)
    {
        PointerText.Text = $"Pointer: {point.X:0} , {point.Y:0}";
    }

    private async void RefreshButton_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.RefreshAsync();
        UpdateCanvasFromViewModel(resetView: true);
        SyncSelectionFromViewModel();
        UpdateStatus();
    }

    private void FitButton_Click(object sender, RoutedEventArgs e)
    {
        Canvas.Fit();
        UpdateStatus();
    }

    private void ZoomInButton_Click(object sender, RoutedEventArgs e)
    {
        Canvas.ZoomBy(1.15);
        UpdateStatus();
    }

    private void ZoomOutButton_Click(object sender, RoutedEventArgs e)
    {
        Canvas.ZoomBy(1 / 1.15);
        UpdateStatus();
    }

    private void ResetViewButton_Click(object sender, RoutedEventArgs e)
    {
        Canvas.ResetView();
        UpdateStatus();
    }

    private void UpdateCanvasFromViewModel(bool resetView)
    {
        _syncingSelection = true;

        try
        {
            Canvas.SetData(
                _viewModel.Monitors.Select(monitor => monitor.Info).ToList(),
                _viewModel.Items.Select(item => item.Item).ToList(),
                _viewModel.VirtualScreenRect,
                _viewModel.WarningItemIds);

            if (resetView)
            {
                Canvas.Fit();
            }

            Canvas.SelectItem(_viewModel.SelectedItem is null ? -1 : _viewModel.Items.IndexOf(_viewModel.SelectedItem));
            Canvas.SelectMonitor(_viewModel.SelectedMonitor is null ? -1 : _viewModel.Monitors.IndexOf(_viewModel.SelectedMonitor));
        }
        finally
        {
            _syncingSelection = false;
        }

        UpdateStatus();
    }

    private void SyncSelectionFromViewModel()
    {
        _syncingSelection = true;

        try
        {
            SetList.SelectedItem = _viewModel.SelectedSet;
            MonitorList.SelectedItem = _viewModel.SelectedMonitor;
            ItemList.SelectedItem = _viewModel.SelectedItem;
            Canvas.SelectItem(_viewModel.SelectedItem is null ? -1 : _viewModel.Items.IndexOf(_viewModel.SelectedItem));
            Canvas.SelectMonitor(_viewModel.SelectedMonitor is null ? -1 : _viewModel.Monitors.IndexOf(_viewModel.SelectedMonitor));
        }
        finally
        {
            _syncingSelection = false;
        }
    }

    private void UpdateStatus()
    {
        StatusText.Text = _viewModel.StatusMessage;
        ZoomText.Text = $"Zoom {Canvas.Transform.Zoom * 100:0}%";
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        _viewModel.Dispose();
        base.OnClosing(e);
    }

    public async Task<bool> RunSmokeAsync(string? snapshotPath, string? logPath)
    {
        try
        {
            await EnsureLoadedAsync();

            if (_viewModel.HasError)
            {
                WriteSmokeLog(logPath, new
                {
                    success = false,
                    error = _viewModel.ErrorText,
                    integrity = _viewModel.IntegrityText,
                    timestampUtc = DateTime.UtcNow
                });
                _viewModel.Dispose();
                Close();
                return false;
            }

            var initialHandshakeMs = _viewModel.HandshakeMs;
            var initialLoadMs = _viewModel.LoadMs;

            if (_viewModel.Sets.Count > 1)
            {
                await _viewModel.SelectSetAsync(_viewModel.Sets[1]);
                await _viewModel.SelectSetAsync(_viewModel.Sets[0]);
                UpdateCanvasFromViewModel(resetView: true);
                SyncSelectionFromViewModel();
            }

            _viewModel.SelectItemAt(0);
            _viewModel.SelectMonitorAt(0);
            SyncSelectionFromViewModel();
            Canvas.Fit();
            Canvas.ZoomBy(1.1);
            Canvas.PanBy(new Vector(30, 20));
            Canvas.ResetView();

            var refreshWatch = Stopwatch.StartNew();
            await _viewModel.RefreshAsync();
            refreshWatch.Stop();
            UpdateCanvasFromViewModel(resetView: true);
            SyncSelectionFromViewModel();

            _viewModel.SelectItemAt(0);
            _viewModel.SelectMonitorAt(0);
            SyncSelectionFromViewModel();
            Canvas.Fit();
            UpdateLayout();

            if (!string.IsNullOrWhiteSpace(snapshotPath))
            {
                SaveWindowSnapshot(snapshotPath);
            }

            var selected = _viewModel.SelectedItem?.Item;
            var evidence = new
            {
                success = true,
                integrity = _viewModel.IntegrityText,
                processId = Environment.ProcessId,
                backendPid = _viewModel.BackendPid,
                backendVersion = _viewModel.BackendText,
                protocol = "devws-editor/1",
                isDevelopmentConfig = _viewModel.IsDevelopmentConfig,
                configSource = _viewModel.ConfigSource,
                configRevision = _viewModel.ConfigRevision,
                configEffectivePath = _viewModel.ConfigEffectivePath,
                canonicalPath = _viewModel.CanonicalPath,
                canonicalExists = _viewModel.CanonicalExists,
                configWritable = _viewModel.Writable,
                setCount = _viewModel.Sets.Count,
                selectedSetId = _viewModel.SelectedSet?.Info.Id,
                monitorCount = _viewModel.Monitors.Count,
                itemCount = _viewModel.Items.Count,
                warningCount = _viewModel.Warnings.Count,
                selectedItemId = selected?.ItemId,
                selectedItemSource = selected?.Source,
                selectedItemPlacement = selected?.PlacementStatus,
                selectedItemRect = selected?.Rect.Display,
                handshakeMs = Math.Round(initialHandshakeMs, 1),
                loadMs = Math.Round(initialLoadMs, 1),
                refreshMs = Math.Round(refreshWatch.Elapsed.TotalMilliseconds, 1),
                appStartupMs = Math.Round(_appStopwatch.Elapsed.TotalMilliseconds, 1),
                workingSetMB = _viewModel.WorkingSetMb,
                cpuTotalMs = _viewModel.CpuTotalMs,
                zoom = Canvas.Transform.Zoom,
                virtualScreen = _viewModel.VirtualScreenRect,
                monitors = _viewModel.Monitors.Select(monitor => new
                {
                    identity = monitor.Info.Identity,
                    friendlyName = monitor.Info.FriendlyName,
                    primary = monitor.Info.Primary,
                    monitorRect = monitor.Info.MonitorRect,
                    workRect = monitor.Info.WorkRect,
                    scalePercent = monitor.Info.ScalePercent
                }).ToArray(),
                warnings = _viewModel.Warnings.Select(warning => new
                {
                    code = warning.Info.Code,
                    message = warning.Info.Message,
                    itemId = warning.Info.Details.ItemId
                }).ToArray(),
                snapshotPath = snapshotPath,
                timestampUtc = DateTime.UtcNow
            };

            var backendPid = _viewModel.BackendPid;
            _viewModel.Dispose();
            var exitCode = _viewModel.BackendExitCode;
            var backendExited = _viewModel.BackendExited;

            WriteSmokeLog(logPath, new
            {
                evidence.success,
                evidence.integrity,
                evidence.processId,
                backendPid,
                backendExited,
                backendExitCode = exitCode,
                backendStderr = _viewModel.BackendStderr,
                evidence.backendVersion,
                evidence.protocol,
                evidence.isDevelopmentConfig,
                evidence.configSource,
                evidence.configRevision,
                evidence.configEffectivePath,
                evidence.canonicalPath,
                evidence.canonicalExists,
                evidence.configWritable,
                evidence.setCount,
                evidence.selectedSetId,
                evidence.monitorCount,
                evidence.itemCount,
                evidence.warningCount,
                evidence.selectedItemId,
                evidence.selectedItemSource,
                evidence.selectedItemPlacement,
                evidence.selectedItemRect,
                evidence.handshakeMs,
                evidence.loadMs,
                evidence.refreshMs,
                evidence.appStartupMs,
                evidence.workingSetMB,
                evidence.cpuTotalMs,
                evidence.zoom,
                evidence.virtualScreen,
                evidence.monitors,
                evidence.warnings,
                evidence.snapshotPath,
                evidence.timestampUtc
            });

            Close();
            return true;
        }
        catch (Exception ex)
        {
            WriteSmokeLog(logPath, new
            {
                success = false,
                error = ex.Message,
                errorType = ex.GetType().Name,
                integrity = _viewModel.IntegrityText,
                timestampUtc = DateTime.UtcNow
            });
            _viewModel.Dispose();
            Close();
            return false;
        }
    }

    public void SaveWindowSnapshot(string path)
    {
        if (Content is not FrameworkElement root)
        {
            return;
        }

        var width = Math.Max(1, (int)Math.Ceiling(root.ActualWidth));
        var height = Math.Max(1, (int)Math.Ceiling(root.ActualHeight));
        root.Measure(new Size(width, height));
        root.Arrange(new Rect(0, 0, width, height));
        root.UpdateLayout();

        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(root);

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));

        var directory = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        using var stream = File.Create(path);
        encoder.Save(stream);
    }

    private static void WriteSmokeLog(string? path, object value)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        var directory = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var json = JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json);
    }
}
