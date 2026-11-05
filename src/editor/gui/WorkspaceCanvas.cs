using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Input;
using System.Windows.Media;

namespace DevWS.Editor;

public sealed class WorkspaceCanvas : FrameworkElement
{
    private static readonly Brush BackgroundBrush = Freeze(new SolidColorBrush(Color.FromRgb(24, 24, 28)));
    private static readonly Brush MonitorBrush = Freeze(new SolidColorBrush(Color.FromRgb(42, 44, 50)));
    private static readonly Brush MonitorPrimaryBrush = Freeze(new SolidColorBrush(Color.FromRgb(38, 52, 62)));
    private static readonly Brush ItemProfileBrush = Freeze(new SolidColorBrush(Color.FromRgb(42, 100, 72)));
    private static readonly Brush ItemRelativeBrush = Freeze(new SolidColorBrush(Color.FromRgb(44, 86, 128)));
    private static readonly Brush ItemFallbackBrush = Freeze(new SolidColorBrush(Color.FromRgb(116, 84, 28)));
    private static readonly Brush ItemUnavailableBrush = Freeze(new SolidColorBrush(Color.FromRgb(58, 58, 62)));
    private static readonly Brush ItemSelectedBrush = Freeze(new SolidColorBrush(Color.FromRgb(120, 90, 30)));
    private static readonly Brush TextBrush = Freeze(new SolidColorBrush(Color.FromRgb(235, 235, 240)));
    private static readonly Brush MutedTextBrush = Freeze(new SolidColorBrush(Color.FromRgb(165, 170, 180)));
    private static readonly Brush WarningBrush = Freeze(new SolidColorBrush(Color.FromRgb(255, 196, 87)));
    private static readonly Pen MonitorBorderPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(90, 170, 210)), 1.5));
    private static readonly Pen MonitorPrimaryPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(110, 210, 250)), 2.0));
    private static readonly Pen MonitorSelectedPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(255, 213, 79)), 3.0));
    private static readonly Pen WorkAreaPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(230, 170, 70)), 1.2)
    {
        DashStyle = new DashStyle(new double[] { 5, 4 }, 0)
    });
    private static readonly Pen ItemBorderPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(180, 200, 220)), 1.0));
    private static readonly Pen ItemSelectedPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(255, 213, 79)), 2.5));
    private static readonly Typeface Typeface = new("Segoe UI");

    private IReadOnlyList<MonitorInfo> _monitors = Array.Empty<MonitorInfo>();
    private IReadOnlyList<ProjectedItem> _items = Array.Empty<ProjectedItem>();
    private HashSet<string> _warningItemIds = new(StringComparer.Ordinal);
    private Rect _virtualScreen = new(0, 0, 1, 1);
    private bool _needsInitialFit;
    private bool _panning;
    private Point _lastPanPoint;

    public WorkspaceCanvas()
    {
        Focusable = true;
        ClipToBounds = true;
        SnapsToDevicePixels = true;
        AutomationProperties.SetName(this, "Workspace monitor canvas. Use the set, monitor, and item lists for keyboard navigation.");
        AutomationProperties.SetHelpText(this, "Shows monitor bounds, work areas, and effective item rectangles in DevWS virtual-screen coordinates. Read-only.");
    }

    public CanvasTransform Transform { get; } = new();
    public int SelectedItemIndex { get; private set; } = -1;
    public int SelectedMonitorIndex { get; private set; } = -1;

    public event EventHandler? SelectionChanged;
    public event EventHandler<Point>? PointerWorldChanged;

    public void SetData(
        IReadOnlyList<MonitorInfo> monitors,
        IReadOnlyList<ProjectedItem> items,
        RectInfo? virtualScreen,
        ISet<string>? warningItemIds)
    {
        _monitors = monitors;
        _items = items;
        _warningItemIds = warningItemIds is null
            ? new HashSet<string>(StringComparer.Ordinal)
            : new HashSet<string>(warningItemIds, StringComparer.Ordinal);
        _virtualScreen = ComputeVirtualScreen(virtualScreen);
        SelectedItemIndex = -1;
        SelectedMonitorIndex = -1;
        _needsInitialFit = true;
        InvalidateVisual();
    }

    public void Fit()
    {
        if (ActualWidth <= 1 || ActualHeight <= 1)
        {
            return;
        }

        Transform.Fit(_virtualScreen, RenderSize);
        _needsInitialFit = false;
        InvalidateVisual();
    }

    public void ResetView() => Fit();

    public void ZoomBy(double factor)
    {
        Transform.ZoomAt(new Point(ActualWidth / 2, ActualHeight / 2), factor);
        InvalidateVisual();
    }

    public void PanBy(Vector delta)
    {
        Transform.PanBy(delta);
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

        if (_monitors.Count == 0 && _items.Count == 0)
        {
            DrawText(drawingContext, "No monitors or configured items reported.", new Point(16, 16), 14, MutedTextBrush);
            return;
        }

        DrawGrid(drawingContext);

        for (var index = 0; index < _monitors.Count; index++)
        {
            DrawMonitor(drawingContext, _monitors[index], index);
        }

        for (var index = 0; index < _items.Count; index++)
        {
            DrawItem(drawingContext, _items[index], index);
        }

        DrawText(
            drawingContext,
            $"{_monitors.Count} monitors  |  {_items.Count} items  |  {Transform.Describe()}",
            new Point(12, 8),
            12,
            MutedTextBrush);
    }

    private void DrawGrid(DrawingContext drawingContext)
    {
        const int step = 200;
        var pen = new Pen(new SolidColorBrush(Color.FromArgb(28, 255, 255, 255)), 1);
        pen.Freeze();

        var startX = (int)Math.Floor(_virtualScreen.Left / step) * step;
        var endX = (int)Math.Ceiling(_virtualScreen.Right / step) * step;
        var startY = (int)Math.Floor(_virtualScreen.Top / step) * step;
        var endY = (int)Math.Ceiling(_virtualScreen.Bottom / step) * step;

        for (var x = startX; x <= endX; x += step)
        {
            var top = Transform.WorldToScreen(new Point(x, _virtualScreen.Top));
            var bottom = Transform.WorldToScreen(new Point(x, _virtualScreen.Bottom));
            drawingContext.DrawLine(pen, top, bottom);
        }

        for (var y = startY; y <= endY; y += step)
        {
            var left = Transform.WorldToScreen(new Point(_virtualScreen.Left, y));
            var right = Transform.WorldToScreen(new Point(_virtualScreen.Right, y));
            drawingContext.DrawLine(pen, left, right);
        }
    }

    private void DrawMonitor(DrawingContext drawingContext, MonitorInfo monitor, int index)
    {
        var monitorRect = WorldRectToScreen(monitor.MonitorRect.ToRect());
        var workRect = WorldRectToScreen(monitor.WorkRect.ToRect());
        var selected = index == SelectedMonitorIndex;
        var brush = monitor.Primary ? MonitorPrimaryBrush : MonitorBrush;
        var pen = selected ? MonitorSelectedPen : monitor.Primary ? MonitorPrimaryPen : MonitorBorderPen;

        drawingContext.DrawRectangle(brush, pen, monitorRect);
        drawingContext.DrawRectangle(null, WorkAreaPen, workRect);

        var name = string.IsNullOrWhiteSpace(monitor.FriendlyName) ? monitor.Identity : monitor.FriendlyName;
        var label = $"{name}  {monitor.MonitorRect.W}x{monitor.MonitorRect.H}" + (monitor.Primary ? "  [primary]" : "");
        DrawText(drawingContext, label, new Point(monitorRect.Left + 8, monitorRect.Top + 6), 12, TextBrush);

        var origin = $"{monitor.MonitorRect.X},{monitor.MonitorRect.Y}  work {monitor.WorkRect.W}x{monitor.WorkRect.H}";
        DrawText(drawingContext, origin, new Point(monitorRect.Left + 8, monitorRect.Top + 24), 10, MutedTextBrush);

        if (selected)
        {
            DrawText(drawingContext, "selected monitor", new Point(monitorRect.Left + 8, monitorRect.Bottom - 20), 10, TextBrush);
        }
    }

    private void DrawItem(DrawingContext drawingContext, ProjectedItem item, int index)
    {
        var rect = WorldRectToScreen(item.Rect.ToRect());
        var selected = index == SelectedItemIndex;
        var brush = selected ? ItemSelectedBrush : BrushForSource(item.Source, item.Enabled);
        var pen = selected ? ItemSelectedPen : ItemBorderPen;

        drawingContext.DrawRectangle(brush, pen, rect);
        DrawText(drawingContext, item.ItemId, new Point(rect.Left + 5, rect.Top + 4), 11, TextBrush);

        if (rect.Width > 100 && rect.Height > 36)
        {
            var detail = $"{item.Source}  {item.Rect.W}x{item.Rect.H}";
            DrawText(drawingContext, detail, new Point(rect.Left + 5, rect.Top + 20), 9, MutedTextBrush);
        }

        if (_warningItemIds.Contains(item.ItemId))
        {
            var marker = new Point(rect.Right - 12, rect.Top + 4);
            drawingContext.DrawEllipse(WarningBrush, null, marker, 5, 5);
            DrawText(drawingContext, "!", new Point(marker.X - 2.5, marker.Y - 6), 9, BackgroundBrush);
        }
    }

    private static Brush BrushForSource(string source, bool enabled)
    {
        if (!enabled)
        {
            return ItemUnavailableBrush;
        }

        return source switch
        {
            "profile" => ItemProfileBrush,
            "relative" => ItemRelativeBrush,
            "relative-fallback" => ItemFallbackBrush,
            "fallback" => ItemFallbackBrush,
            "relative-unavailable" => ItemUnavailableBrush,
            _ => ItemRelativeBrush
        };
    }

    private Rect WorldRectToScreen(Rect rect)
    {
        var topLeft = Transform.WorldToScreen(rect.TopLeft);
        var bottomRight = Transform.WorldToScreen(rect.BottomRight);
        return new Rect(topLeft, bottomRight);
    }

    private void DrawText(DrawingContext drawingContext, string text, Point origin, double size, Brush brush)
    {
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

        var step = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? 120 : 40;
        var pan = e.Key switch
        {
            Key.Left => new Vector(step, 0),
            Key.Right => new Vector(-step, 0),
            Key.Up => new Vector(0, step),
            Key.Down => new Vector(0, -step),
            _ => default
        };

        if (pan != default)
        {
            Transform.PanBy(pan);
            InvalidateVisual();
            e.Handled = true;
        }
    }

    private int HitTestItem(Point screen)
    {
        var world = Transform.ScreenToWorld(screen);

        for (var index = _items.Count - 1; index >= 0; index--)
        {
            if (_items[index].Rect.ToRect().Contains(world))
            {
                return index;
            }
        }

        return -1;
    }

    private int HitTestMonitor(Point screen)
    {
        var world = Transform.ScreenToWorld(screen);

        for (var index = 0; index < _monitors.Count; index++)
        {
            if (_monitors[index].MonitorRect.ToRect().Contains(world))
            {
                return index;
            }
        }

        return -1;
    }

    private Rect ComputeVirtualScreen(RectInfo? virtualScreen)
    {
        if (virtualScreen is { W: > 0, H: > 0 })
        {
            return virtualScreen.ToRect();
        }

        var rects = _monitors.Select(monitor => monitor.MonitorRect)
            .Concat(_items.Select(item => item.Rect))
            .ToList();

        if (rects.Count == 0)
        {
            return new Rect(0, 0, 1, 1);
        }

        var left = rects.Min(rect => rect.X);
        var top = rects.Min(rect => rect.Y);
        var right = rects.Max(rect => rect.X + rect.W);
        var bottom = rects.Max(rect => rect.Y + rect.H);
        return new Rect(left, top, Math.Max(1, right - left), Math.Max(1, bottom - top));
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
