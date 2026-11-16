using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace DevWS.WpfSpike;

public sealed class MonitorRow
{
    public MonitorRow(MonitorDto monitor)
    {
        Monitor = monitor;
    }

    public MonitorDto Monitor { get; }
    public string Display => $"{Monitor.Name}  {Monitor.MonitorRect.W}x{Monitor.MonitorRect.H} @ {Monitor.ScalePercent}%  ({Monitor.MonitorRect.X},{Monitor.MonitorRect.Y})";

    public override string ToString() => Display;
}

public sealed class ItemRow
{
    public ItemRow(int index, ItemDto item)
    {
        Index = index;
        Item = item;
    }

    public int Index { get; }
    public ItemDto Item { get; }
    public string Display => $"{Item.Id}  [{Item.Kind}]  {Item.Rect.X},{Item.Rect.Y} {Item.Rect.W}x{Item.Rect.H}";

    public override string ToString() => Display;
}

public sealed class FixtureChoice
{
    public FixtureChoice(string path)
    {
        Path = path;
        Display = System.IO.Path.GetFileNameWithoutExtension(path);
    }

    public string Path { get; }
    public string Display { get; }
}

public partial class MainWindow : Window
{
    private WorkspaceFixture? _fixture;
    private List<ItemRow> _itemRows = new();
    private bool _syncingSelection;

    public MainWindow(string? fixturePath = null)
    {
        InitializeComponent();
        Canvas.SelectionChanged += Canvas_SelectionChanged;
        Canvas.PointerWorldChanged += Canvas_PointerWorldChanged;
        Canvas.ItemGeometryChanged += Canvas_ItemGeometryChanged;
        DpiChanged += (_, _) => UpdateEnvironmentLabels();
        Loaded += (_, _) => UpdateEnvironmentLabels();

        PopulateFixtures();

        var initialPath = fixturePath;
        if (string.IsNullOrWhiteSpace(initialPath))
        {
            initialPath = (FixtureCombo.SelectedItem as FixtureChoice)?.Path;
        }

        if (!string.IsNullOrWhiteSpace(initialPath))
        {
            LoadFixture(initialPath);
        }
    }

    public WorkspaceFixture? Fixture => _fixture;

    public InteractionMetrics RunInteractionBenchmark(int frames) => Canvas.RunInteractionBenchmark(frames);

    public void SaveSnapshot(string path)
    {
        var width = Math.Max(1, (int)Math.Ceiling(Canvas.ActualWidth));
        var height = Math.Max(1, (int)Math.Ceiling(Canvas.ActualHeight));
        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(Canvas);

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

    public void UpdateEnvironmentLabels()
    {
        var dpi = VisualTreeHelper.GetDpi(this);
        IntegrityText.Text = $"Integrity: {IntegrityProbe.GetIntegrityLevel()}";
        DpiText.Text = $"WPF DPI: {dpi.DpiScaleX * 100:0}% / {dpi.DpiScaleY * 100:0}%";
    }

    private void PopulateFixtures()
    {
        var choices = FixtureLoader.EnumerateFixturePaths()
            .Select(path => new FixtureChoice(path))
            .ToList();

        FixtureCombo.ItemsSource = choices;
        FixtureCombo.DisplayMemberPath = nameof(FixtureChoice.Display);
        if (choices.Count > 0)
        {
            var defaultIndex = choices.FindIndex(choice =>
                string.Equals(Path.GetFileName(choice.Path), "two-monitors-10-items.json", StringComparison.OrdinalIgnoreCase));
            FixtureCombo.SelectedIndex = defaultIndex >= 0 ? defaultIndex : 0;
        }
    }

    private void LoadFixture(string path)
    {
        try
        {
            _fixture = FixtureLoader.Load(path);
            Canvas.Fixture = _fixture;
            Canvas.Fit();

            _itemRows = _fixture.Items
                .Select((item, index) => new ItemRow(index, item))
                .ToList();

            MonitorList.ItemsSource = _fixture.Monitors.Select(monitor => new MonitorRow(monitor)).ToList();
            ItemList.ItemsSource = _itemRows;

            if (_itemRows.Count > 0)
            {
                ItemList.SelectedIndex = 0;
                Canvas.SelectItem(0);
            }
            else
            {
                Canvas.SelectItem(-1);
            }

            if (_fixture.Monitors.Count > 0)
            {
                MonitorList.SelectedIndex = 0;
                Canvas.SelectMonitor(0);
            }

            UpdateEditorFromSelection();
            StatusText.Text = $"Loaded {_fixture.Name}: {_fixture.Monitors.Count} monitors, {_fixture.Items.Count} items.";
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Fixture load failed: {ex.Message}";
            MessageBox.Show(this, ex.Message, "Fixture load failed", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void LoadButton_Click(object sender, RoutedEventArgs e)
    {
        if (FixtureCombo.SelectedItem is FixtureChoice choice)
        {
            LoadFixture(choice.Path);
        }
    }

    private void FitButton_Click(object sender, RoutedEventArgs e) => Canvas.Fit();

    private void ZoomInButton_Click(object sender, RoutedEventArgs e) => Canvas.ZoomBy(1.2);

    private void ZoomOutButton_Click(object sender, RoutedEventArgs e) => Canvas.ZoomBy(1 / 1.2);

    private void ResetButton_Click(object sender, RoutedEventArgs e) => Canvas.ResetView();

    private void MonitorList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingSelection)
        {
            return;
        }

        Canvas.SelectMonitor(MonitorList.SelectedIndex);
        UpdateStatus();
    }

    private void ItemList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingSelection)
        {
            return;
        }

        Canvas.SelectItem(ItemList.SelectedIndex);
        UpdateEditorFromSelection();
        UpdateStatus();
    }

    private void Canvas_SelectionChanged(object? sender, EventArgs e)
    {
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

        UpdateEditorFromSelection();
        UpdateStatus();
    }

    private void Canvas_PointerWorldChanged(object? sender, Point point)
    {
        PointerText.Text = $"Pointer: {point.X:0} , {point.Y:0}";
    }

    private void Canvas_ItemGeometryChanged(object? sender, EventArgs e)
    {
        UpdateEditorFromSelection();
        ItemList.Items.Refresh();
        UpdateStatus();
    }

    private void ApplyButton_Click(object sender, RoutedEventArgs e)
    {
        if (_fixture is null || Canvas.SelectedItemIndex < 0 ||
            Canvas.SelectedItemIndex >= _fixture.Items.Count)
        {
            return;
        }

        if (!int.TryParse(XBox.Text, out var x) ||
            !int.TryParse(YBox.Text, out var y) ||
            !int.TryParse(WBox.Text, out var width) ||
            !int.TryParse(HBox.Text, out var height) ||
            width <= 0 || height <= 0)
        {
            StatusText.Text = "Geometry must be integer X/Y and positive integer W/H.";
            return;
        }

        var item = _fixture.Items[Canvas.SelectedItemIndex];
        item.Rect.X = x;
        item.Rect.Y = y;
        item.Rect.W = width;
        item.Rect.H = height;
        ItemList.Items.Refresh();
        Canvas.InvalidateVisual();
        StatusText.Text = $"Updated {item.Id}: {x},{y} {width}x{height}.";
    }

    private void UpdateEditorFromSelection()
    {
        var hasSelection = _fixture is not null &&
                           Canvas.SelectedItemIndex >= 0 &&
                           Canvas.SelectedItemIndex < _fixture.Items.Count;

        ApplyButton.IsEnabled = hasSelection;
        XBox.IsEnabled = hasSelection;
        YBox.IsEnabled = hasSelection;
        WBox.IsEnabled = hasSelection;
        HBox.IsEnabled = hasSelection;

        if (!hasSelection)
        {
            XBox.Text = "";
            YBox.Text = "";
            WBox.Text = "";
            HBox.Text = "";
            return;
        }

        var item = _fixture!.Items[Canvas.SelectedItemIndex];
        XBox.Text = item.Rect.X.ToString();
        YBox.Text = item.Rect.Y.ToString();
        WBox.Text = item.Rect.W.ToString();
        HBox.Text = item.Rect.H.ToString();
    }

    private void UpdateStatus()
    {
        if (_fixture is null)
        {
            StatusText.Text = "No fixture.";
            return;
        }

        var monitor = Canvas.SelectedMonitorIndex >= 0 && Canvas.SelectedMonitorIndex < _fixture.Monitors.Count
            ? _fixture.Monitors[Canvas.SelectedMonitorIndex]
            : null;
        var item = Canvas.SelectedItemIndex >= 0 && Canvas.SelectedItemIndex < _fixture.Items.Count
            ? _fixture.Items[Canvas.SelectedItemIndex]
            : null;

        var monitorText = monitor is null ? "no monitor" : $"monitor {monitor.Name}";
        var itemText = item is null ? "no item" : $"item {item.Id}";
        StatusText.Text = $"{_fixture.Name}: {monitorText}, {itemText}. Zoom {Canvas.Transform.Zoom * 100:0}%.";
    }
}
