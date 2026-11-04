using System.Diagnostics;
using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Input;
using System.Windows.Media;

namespace DevWS.WpfSpike;

public sealed record InteractionMetrics(
    int Frames,
    long WorkingSetBeforeBytes,
    long WorkingSetAfterBytes,
    double CpuBeforeMs,
    double CpuAfterMs,
    double ElapsedMs);

public sealed class WorkspaceCanvas : FrameworkElement
{
    private static readonly Brush BackgroundBrush = Freeze(new SolidColorBrush(Color.FromRgb(24, 24, 28)));
    private static readonly Brush MonitorBrush = Freeze(new SolidColorBrush(Color.FromRgb(42, 44, 50)));
    private static readonly Brush MonitorPrimaryBrush = Freeze(new SolidColorBrush(Color.FromRgb(38, 52, 62)));
    private static readonly Brush ItemBrush = Freeze(new SolidColorBrush(Color.FromRgb(44, 86, 128)));
    private static readonly Brush ItemDisabledBrush = Freeze(new SolidColorBrush(Color.FromRgb(58, 58, 62)));
    private static readonly Brush ItemSelectedBrush = Freeze(new SolidColorBrush(Color.FromRgb(120, 90, 30)));
    private static readonly Brush TextBrush = Freeze(new SolidColorBrush(Color.FromRgb(235, 235, 240)));
    private static readonly Brush MutedTextBrush = Freeze(new SolidColorBrush(Color.FromRgb(165, 170, 180)));
    private static readonly Pen MonitorBorderPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(90, 170, 210)), 1.5));
    private static readonly Pen MonitorPrimaryPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(110, 210, 250)), 2.0));
    private static readonly Pen MonitorSelectedPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(255, 213, 79)), 3.0));
    private static readonly Pen WorkAreaPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(230, 170, 70)), 1.2)
    {
        DashStyle = new DashStyle(new double[] { 5, 4 }, 0)
    });
    private static readonly Pen ItemBorderPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(130, 190, 235)), 1.0));
    private static readonly Pen ItemSelectedPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(255, 213, 79)), 2.5));
    private static readonly Typeface Typeface = new("Segoe UI");

    private WorkspaceFixture? _fixture;
    private bool _needsInitialFit;
    private bool _panning;
    private Point _lastPanPoint;

    public WorkspaceCanvas()
    {
        Focusable = true;
        ClipToBounds = true;
        SnapsToDevicePixels = true;
        AutomationProperties.SetName(this, "Workspace monitor canvas. Use the monitor and item lists for keyboard selection.");
        AutomationProperties.SetHelpText(this, "Shows monitor rectangles, work areas, and configured item rectangles in DevWS virtual-screen coordinates.");
    }

    public CanvasTransform Transform { get; } = new();

    public WorkspaceFixture? Fixture
    {
        get => _fixture;
        set
        {
            _fixture = value;
            _needsInitialFit = true;
            SelectedItemIndex = -1;
            SelectedMonitorIndex = -1;
            InvalidateVisual();
        }
    }

    public int SelectedItemIndex { get; set; } = -1;
    public int SelectedMonitorIndex { get; set; } = -1;

    public event EventHandler? SelectionChanged;
    public event EventHandler<Point>? PointerWorldChanged;
    public event EventHandler? ItemGeometryChanged;

    public void Fit()
    {
        if (_fixture is null || ActualWidth <= 1 || ActualHeight <= 1)
        {
            return;
        }

        Transform.Fit(_fixture.GetVirtualScreenRect(), RenderSize);
        _needsInitialFit = false;
        InvalidateVisual();
    }

    public void ResetView() => Fit();

    public void ZoomBy(double factor)
    {
        Transform.ZoomAt(new Point(ActualWidth / 2, ActualHeight / 2), factor);
        InvalidateVisual();
    }

    public void SelectItem(int index)
    {
        if (SelectedItemIndex == index)
        {
            return;
        }

        SelectedItemIndex = index;
        SelectionChanged?.Invoke(this, EventArgs.Empty);
        InvalidateVisual();
    }

    public void SelectMonitor(int index)
    {
        if (SelectedMonitorIndex == index)
        {
            return;
        }

        SelectedMonitorIndex = index;
        SelectionChanged?.Invoke(this, EventArgs.Empty);
        InvalidateVisual();
    }

    public InteractionMetrics RunInteractionBenchmark(int frames)
    {
        var process = Process.GetCurrentProcess();
        var beforeWorkingSet = process.WorkingSet64;
        var beforeCpu = process.TotalProcessorTime.TotalMilliseconds;
        var stopwatch = Stopwatch.StartNew();
        var center = new Point(ActualWidth / 2, ActualHeight / 2);

        for (var index = 0; index < frames; index++)
        {
            Transform.ZoomAt(center, index % 2 == 0 ? 1.04 : 1 / 1.04);
            Transform.PanBy(new Vector(index % 3 == 0 ? 1 : -1, index % 5 == 0 ? 1 : -1));
            InvalidateVisual();
            UpdateLayout();
        }

        stopwatch.Stop();
        process.Refresh();
        return new InteractionMetrics(
            frames,
            beforeWorkingSet,
            process.WorkingSet64,
            beforeCpu,
            process.TotalProcessorTime.TotalMilliseconds,
            stopwatch.Elapsed.TotalMilliseconds);
    }

    protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo)
    {
        base.OnRenderSizeChanged(sizeInfo);

        if (_needsInitialFit && ActualWidth > 1 && ActualHeight > 1)
        {
            Fit();
        }
    }

    protected override void OnRender(DrawingContext drawingContext)
    {
        base.OnRender(drawingContext);
        drawingContext.DrawRectangle(BackgroundBrush, null, new Rect(RenderSize));

        if (_fixture is null)
        {
            DrawText(drawingContext, "No fixture loaded.", new Point(16, 16), 14, MutedTextBrush);
            return;
        }

        DrawGrid(drawingContext);

        for (var index = 0; index < _fixture.Monitors.Count; index++)
        {
            DrawMonitor(drawingContext, _fixture.Monitors[index], index);
        }

        for (var index = 0; index < _fixture.Items.Count; index++)
        {
            DrawItem(drawingContext, _fixture.Items[index], index);
        }

        DrawText(
            drawingContext,
            $"{_fixture.Name}  |  {_fixture.Monitors.Count} monitors  |  {_fixture.Items.Count} items  |  {Transform.Describe()}",
            new Point(12, 8),
            12,
            MutedTextBrush);
    }

    private void DrawGrid(DrawingContext drawingContext)
    {
        var virtualScreen = _fixture!.GetVirtualScreenRect();
        const int step = 200;
        var pen = new Pen(new SolidColorBrush(Color.FromArgb(28, 255, 255, 255)), 1);
        pen.Freeze();

        var startX = (int)Math.Floor(virtualScreen.Left / step) * step;
        var endX = (int)Math.Ceiling(virtualScreen.Right / step) * step;
        var startY = (int)Math.Floor(virtualScreen.Top / step) * step;
        var endY = (int)Math.Ceiling(virtualScreen.Bottom / step) * step;

        for (var x = startX; x <= endX; x += step)
        {
            var top = Transform.WorldToScreen(new Point(x, virtualScreen.Top));
            var bottom = Transform.WorldToScreen(new Point(x, virtualScreen.Bottom));
            drawingContext.DrawLine(pen, top, bottom);
        }

        for (var y = startY; y <= endY; y += step)
        {
            var left = Transform.WorldToScreen(new Point(virtualScreen.Left, y));
            var right = Transform.WorldToScreen(new Point(virtualScreen.Right, y));
            drawingContext.DrawLine(pen, left, right);
        }
    }

    private void DrawMonitor(DrawingContext drawingContext, MonitorDto monitor, int index)
    {
        var monitorRect = WorldRectToScreen(monitor.MonitorRect.ToRect());
        var workRect = WorldRectToScreen(monitor.WorkRect.ToRect());
        var selected = index == SelectedMonitorIndex;
        var brush = monitor.Primary ? MonitorPrimaryBrush : MonitorBrush;
        var pen = selected ? MonitorSelectedPen : monitor.Primary ? MonitorPrimaryPen : MonitorBorderPen;

        drawingContext.DrawRectangle(brush, pen, monitorRect);
        drawingContext.DrawRectangle(null, WorkAreaPen, workRect);

        var label = $"{monitor.Name}  {monitor.MonitorRect.W}x{monitor.MonitorRect.H} @ {monitor.ScalePercent}%";
        DrawText(drawingContext, label, new Point(monitorRect.Left + 8, monitorRect.Top + 6), 12, TextBrush);

        var origin = $"{monitor.MonitorRect.X},{monitor.MonitorRect.Y}";
        DrawText(drawingContext, origin, new Point(monitorRect.Left + 8, monitorRect.Top + 24), 10, MutedTextBrush);

        if (selected)
        {
            DrawText(drawingContext, "selected monitor", new Point(monitorRect.Left + 8, monitorRect.Bottom - 20), 10, TextBrush);
        }
    }

    private void DrawItem(DrawingContext drawingContext, ItemDto item, int index)
    {
        var rect = WorldRectToScreen(item.Rect.ToRect());
        var selected = index == SelectedItemIndex;
        var brush = selected ? ItemSelectedBrush : item.Enabled ? ItemBrush : ItemDisabledBrush;
        var pen = selected ? ItemSelectedPen : ItemBorderPen;

        drawingContext.DrawRectangle(brush, pen, rect);
        DrawText(drawingContext, item.Id, new Point(rect.Left + 5, rect.Top + 4), 11, TextBrush);

        if (rect.Width > 90 && rect.Height > 36)
        {
            var detail = $"{item.Kind}  {item.Rect.W}x{item.Rect.H}";
            DrawText(drawingContext, detail, new Point(rect.Left + 5, rect.Top + 20), 9, MutedTextBrush);
        }
    }

    private Rect WorldRectToScreen(Rect rect)
    {
        var topLeft = Transform.WorldToScreen(rect.TopLeft);
        var bottomRight = Transform.WorldToScreen(rect.BottomRight);
        return new Rect(topLeft, bottomRight);
    }

    private void DrawText(DrawingContext drawingContext, string text, Point origin, double size, Brush brush)    {
        var dpi = VisualTreeHelper.GetDpi(this);
        var formatted = new FormattedText(
            text,
            CultureInfo.InvariantCulture,
            FlowDirection.LeftToRight,
            Typeface,
            size,
            brush,
            dpi.PixelsPerDip);
        drawingContext.DrawText(formatted, origin);
    }

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        base.OnMouseWheel(e);
        Transform.ZoomAt(e.GetPosition(this), e.Delta > 0 ? 1.15 : 1 / 1.15);
        InvalidateVisual();
        e.Handled = true;
    }

    protected override void OnMouseDown(MouseButtonEventArgs e)
    {
        base.OnMouseDown(e);
        Focus();

        if (e.ChangedButton is MouseButton.Middle or MouseButton.Right)
        {
            _panning = true;
            _lastPanPoint = e.GetPosition(this);
            CaptureMouse();
            e.Handled = true;
            return;
        }

        if (e.ChangedButton != MouseButton.Left)
        {
            return;
        }

        var screen = e.GetPosition(this);
        var itemIndex = HitTestItem(screen);

        if (itemIndex >= 0)
        {
            SelectItem(itemIndex);
            e.Handled = true;
            return;
        }

        var monitorIndex = HitTestMonitor(screen);
        SelectMonitor(monitorIndex);
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        var position = e.GetPosition(this);

        if (_panning)
        {
            Transform.PanBy(position - _lastPanPoint);
            _lastPanPoint = position;
            InvalidateVisual();
        }

        PointerWorldChanged?.Invoke(this, Transform.ScreenToWorld(position));
    }

    protected override void OnMouseUp(MouseButtonEventArgs e)
    {
        base.OnMouseUp(e);

        if (_panning && (e.ChangedButton is MouseButton.Middle or MouseButton.Right))
        {
            _panning = false;
            ReleaseMouseCapture();
            e.Handled = true;
        }
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);

        if (_fixture is null)
        {
            return;
        }

        if (e.Key == Key.F)
        {
            Fit();
            e.Handled = true;
            return;
        }

        if (e.Key is Key.Add or Key.OemPlus)
        {
            ZoomBy(1.15);
            e.Handled = true;
            return;
        }

        if (e.Key is Key.Subtract or Key.OemMinus)
        {
            ZoomBy(1 / 1.15);
            e.Handled = true;
            return;
        }

        if (e.Key == Key.Escape)
        {
            SelectedItemIndex = -1;
            SelectedMonitorIndex = -1;
            SelectionChanged?.Invoke(this, EventArgs.Empty);
            InvalidateVisual();
            e.Handled = true;
            return;
        }

        if (SelectedItemIndex < 0 || SelectedItemIndex >= _fixture.Items.Count)
        {
            return;
        }

        var step = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? 10 : 1;
        var item = _fixture.Items[SelectedItemIndex];
        var dx = 0;
        var dy = 0;

        switch (e.Key)
        {
            case Key.Left: dx = -step; break;
            case Key.Right: dx = step; break;
            case Key.Up: dy = -step; break;
            case Key.Down: dy = step; break;
            default: return;
        }

        item.Rect.X += dx;
        item.Rect.Y += dy;
        ItemGeometryChanged?.Invoke(this, EventArgs.Empty);
        InvalidateVisual();
        e.Handled = true;
    }

    private int HitTestItem(Point screen)
    {
        if (_fixture is null)
        {
            return -1;
        }

        var world = Transform.ScreenToWorld(screen);

        for (var index = _fixture.Items.Count - 1; index >= 0; index--)
        {
            if (_fixture.Items[index].Rect.ToRect().Contains(world))
            {
                return index;
            }
        }

        return -1;
    }

    private int HitTestMonitor(Point screen)
    {
        if (_fixture is null)
        {
            return -1;
        }

        var world = Transform.ScreenToWorld(screen);

        for (var index = 0; index < _fixture.Monitors.Count; index++)
        {
            if (_fixture.Monitors[index].MonitorRect.ToRect().Contains(world))
            {
                return index;
            }
        }

        return -1;
    }

    protected override AutomationPeer OnCreateAutomationPeer()
    {
        return new FrameworkElementAutomationPeer(this);
    }

    private static T Freeze<T>(T freezable) where T : Freezable
    {
        freezable.Freeze();
        return freezable;
    }
}
