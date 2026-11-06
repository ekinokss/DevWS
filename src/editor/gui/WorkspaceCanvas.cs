using System.Diagnostics;
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
    private static readonly Brush DraftOverlayBrush = Freeze(new SolidColorBrush(Color.FromArgb(70, 255, 196, 87)));
    private static readonly Brush PreviewOverlayBrush = Freeze(new SolidColorBrush(Color.FromArgb(60, 80, 210, 210)));
    private static readonly Brush TextBrush = Freeze(new SolidColorBrush(Color.FromRgb(235, 235, 240)));
    private static readonly Brush MutedTextBrush = Freeze(new SolidColorBrush(Color.FromRgb(165, 170, 180)));
    private static readonly Brush WarningBrush = Freeze(new SolidColorBrush(Color.FromRgb(255, 196, 87)));
    private static readonly Brush HandleBrush = Freeze(new SolidColorBrush(Color.FromRgb(255, 213, 79)));
    private static readonly Pen MonitorBorderPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(90, 170, 210)), 1.5));
    private static readonly Pen MonitorPrimaryPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(110, 210, 250)), 2.0));
    private static readonly Pen MonitorSelectedPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(255, 213, 79)), 3.0));
    private static readonly Pen WorkAreaPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(230, 170, 70)), 1.2)
    {
        DashStyle = new DashStyle(new double[] { 5, 4 }, 0)
    });
    private static readonly Pen ItemBorderPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(180, 200, 220)), 1.0));
    private static readonly Pen ItemSelectedPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(255, 213, 79)), 2.5));
    private static readonly Pen LocalDraftPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(255, 190, 70)), 2.0)
    {
        DashStyle = new DashStyle(new double[] { 6, 3 }, 0)
    });
    private static readonly Pen SavedOutlinePen = Freeze(new Pen(new SolidColorBrush(Color.FromArgb(190, 170, 175, 190)), 1.5));
    private static readonly Pen PreviewPen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(80, 220, 215)), 2.0)
    {
        DashStyle = new DashStyle(new double[] { 5, 3 }, 0)
    });
    private static readonly Pen HandlePen = Freeze(new Pen(new SolidColorBrush(Color.FromRgb(40, 36, 20)), 1.0));
    private static readonly Pen GridPen = Freeze(new Pen(new SolidColorBrush(Color.FromArgb(28, 255, 255, 255)), 1.0));
    private static readonly Typeface Typeface = new("Segoe UI");
    private const double HandleRadius = 7.0;
    private const double HandleSize = 7.0;

    private IReadOnlyList<MonitorInfo> _monitors = Array.Empty<MonitorInfo>();
    private IReadOnlyList<ProjectedItem> _items = Array.Empty<ProjectedItem>();
    private HashSet<string> _warningItemIds = new(StringComparer.Ordinal);
    private Dictionary<string, RectInfo> _draftRects = new(StringComparer.Ordinal);
    private Dictionary<string, RectInfo> _previewRects = new(StringComparer.Ordinal);
    private readonly Dictionary<string, FormattedText> _textCache = new(StringComparer.Ordinal);
    private Rect _virtualScreen = new(0, 0, 1, 1);
    private RectInfo? _virtualScreenSource;
    private bool _needsInitialFit;
    private bool _panning;
    private Point _lastPanPoint;

    private DragMode _dragMode;
    private ResizeHandle _resizeHandle;
    private int _dragItemIndex = -1;
    private string? _dragItemId;
    private Point _dragStartScreen;
    private Rect _dragStartWorldRect;
    private RectInfo? _interactiveRect;
    private bool _dragMoved;
    private double _cachedPixelsPerDip;

    public WorkspaceCanvas()
    {
        Focusable = true;
        ClipToBounds = true;
        SnapsToDevicePixels = true;
        AutomationProperties.SetName(this, "Workspace monitor canvas. Drag or resize the selected item; use the lists for keyboard navigation.");
        AutomationProperties.SetHelpText(this, "Shows monitor bounds, work areas, saved item rectangles, and local draft rectangles in DevWS virtual-screen coordinates.");
    }

    public CanvasTransform Transform { get; } = new();
    public int SelectedItemIndex { get; private set; } = -1;
    public int SelectedMonitorIndex { get; private set; } = -1;
    public RectInfo? InteractiveDraftRect => _interactiveRect;
    public double LastRenderMs { get; private set; }
    public long RenderCount { get; private set; }
    public int CachedTextCount => _textCache.Count;

    public event EventHandler? SelectionChanged;
    public event EventHandler<Point>? PointerWorldChanged;
    public event EventHandler<RectInfo>? DraftRectChanging;
    public event EventHandler<RectInfo>? DraftRectCommitted;
    public event EventHandler? DraftRectCancelled;

    public void SetData(
        IReadOnlyList<MonitorInfo> monitors,
        IReadOnlyList<ProjectedItem> items,
        RectInfo? virtualScreen,
        ISet<string>? warningItemIds,
        IReadOnlyDictionary<string, RectInfo>? draftRects = null,
        IReadOnlyDictionary<string, RectInfo>? previewRects = null)
    {
        _monitors = monitors;
        _items = items;
        _warningItemIds = warningItemIds is null
            ? new HashSet<string>(StringComparer.Ordinal)
            : new HashSet<string>(warningItemIds, StringComparer.Ordinal);
        _draftRects = draftRects is null
            ? new Dictionary<string, RectInfo>(StringComparer.Ordinal)
            : new Dictionary<string, RectInfo>(draftRects, StringComparer.Ordinal);
        _previewRects = previewRects is null
            ? new Dictionary<string, RectInfo>(StringComparer.Ordinal)
            : new Dictionary<string, RectInfo>(previewRects, StringComparer.Ordinal);
        _virtualScreenSource = virtualScreen;
        _virtualScreen = ComputeVirtualScreen(virtualScreen);
        _interactiveRect = null;
        _dragMode = DragMode.None;
        SelectedItemIndex = -1;
        SelectedMonitorIndex = -1;
        _needsInitialFit = true;
        _textCache.Clear();
        InvalidateVisual();
    }

    public void SetDraftRects(IReadOnlyDictionary<string, RectInfo>? draftRects)
    {
        _draftRects = draftRects is null
            ? new Dictionary<string, RectInfo>(StringComparer.Ordinal)
            : new Dictionary<string, RectInfo>(draftRects, StringComparer.Ordinal);
        _interactiveRect = null;
        _virtualScreen = ComputeVirtualScreen(_virtualScreenSource);
        InvalidateVisual();
    }

    public void SetPreviewRects(IReadOnlyDictionary<string, RectInfo>? previewRects)
    {
        _previewRects = previewRects is null
            ? new Dictionary<string, RectInfo>(StringComparer.Ordinal)
            : new Dictionary<string, RectInfo>(previewRects, StringComparer.Ordinal);
        _interactiveRect = null;
        _virtualScreen = ComputeVirtualScreen(_virtualScreenSource);
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
        CancelInteractiveEdit();
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

    public RectInfo? GetSelectedDisplayRect()
    {
        if (SelectedItemIndex < 0 || SelectedItemIndex >= _items.Count)
        {
            return null;
        }

        var item = _items[SelectedItemIndex];

        if (_interactiveRect is not null)
        {
            return _interactiveRect;
        }

        if (_draftRects.TryGetValue(item.ItemId, out var draft))
        {
            return draft;
        }

        return _previewRects.TryGetValue(item.ItemId, out var preview) ? preview : item.Rect;
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
        var renderWatch = Stopwatch.StartNew();
        base.OnRender(drawingContext);
        drawingContext.DrawRectangle(BackgroundBrush, null, new Rect(RenderSize));

        if (_monitors.Count == 0 && _items.Count == 0)
        {
            DrawText(drawingContext, "No monitors or configured items reported.", new Point(16, 16), 14, MutedTextBrush);
            renderWatch.Stop();
            RecordRender(renderWatch);
            return;
        }

        DrawGrid(drawingContext);

        for (var index = 0; index < _monitors.Count; index++)
        {
            DrawMonitor(drawingContext, _monitors[index], index);
        }

        for (var index = 0; index < _items.Count; index++)
        {
            if (index != SelectedItemIndex)
            {
                DrawItem(drawingContext, _items[index], index);
            }
        }

        if (SelectedItemIndex >= 0 && SelectedItemIndex < _items.Count)
        {
            DrawItem(drawingContext, _items[SelectedItemIndex], SelectedItemIndex);
        }

        var draftCount = _draftRects.Count;
        var previewCount = _previewRects.Count;
        var header = $"{_monitors.Count} monitors  |  {_items.Count} items  |  {Transform.Describe()}" +
                     (draftCount > 0 ? $"  |  {draftCount} local draft" : "") +
                     (previewCount > 0 ? $"  |  {previewCount} preview change(s)" : "");
        DrawText(drawingContext, header, new Point(12, 8), 12, MutedTextBrush);
        DrawText(
            drawingContext,
            previewCount > 0
                ? "solid = saved effective  ·  teal dashed = authoritative preview  ·  amber dashed = local unpreviewed  ·  handles = drag/resize"
                : "solid = saved effective  ·  amber dashed = local draft (not backend-validated)  ·  handles = drag/resize",
            new Point(12, Math.Max(12, RenderSize.Height - 22)),
            11,
            MutedTextBrush);

        var selectedRect = GetSelectedDisplayRect();
        AutomationProperties.SetHelpText(
            this,
            $"Workspace canvas. {Transform.Describe()}. " +
            (selectedRect is null
                ? "No item selected."
                : $"Selected {_items[SelectedItemIndex].ItemId} at {selectedRect.Display}."));

        renderWatch.Stop();
        RecordRender(renderWatch);
    }

    private void RecordRender(Stopwatch watch)
    {
        LastRenderMs = watch.Elapsed.TotalMilliseconds;
        RenderCount++;
    }

    private void DrawGrid(DrawingContext drawingContext)
    {
        const int step = 200;
        var startX = (int)Math.Floor(_virtualScreen.Left / step) * step;
        var endX = (int)Math.Ceiling(_virtualScreen.Right / step) * step;
        var startY = (int)Math.Floor(_virtualScreen.Top / step) * step;
        var endY = (int)Math.Ceiling(_virtualScreen.Bottom / step) * step;

        for (var x = startX; x <= endX; x += step)
        {
            var top = Transform.WorldToScreen(new Point(x, _virtualScreen.Top));
            var bottom = Transform.WorldToScreen(new Point(x, _virtualScreen.Bottom));
            drawingContext.DrawLine(GridPen, top, bottom);
        }

        for (var y = startY; y <= endY; y += step)
        {
            var left = Transform.WorldToScreen(new Point(_virtualScreen.Left, y));
            var right = Transform.WorldToScreen(new Point(_virtualScreen.Right, y));
            drawingContext.DrawLine(GridPen, left, right);
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
        var savedRect = WorldRectToScreen(item.Rect.ToRect());
        var selected = index == SelectedItemIndex;
        _draftRects.TryGetValue(item.ItemId, out var draftRect);
        _previewRects.TryGetValue(item.ItemId, out var previewRect);
        var displayWorld = selected && _interactiveRect is not null
            ? _interactiveRect
            : draftRect ?? previewRect ?? item.Rect;
        var rect = WorldRectToScreen(displayWorld.ToRect());
        var brush = selected ? ItemSelectedBrush : BrushForSource(item.Source, item.Enabled);
        var pen = selected ? ItemSelectedPen : ItemBorderPen;

        if (draftRect is not null || previewRect is not null || (selected && _interactiveRect is not null))
        {
            drawingContext.DrawRectangle(null, SavedOutlinePen, savedRect);
        }

        if (previewRect is not null)
        {
            drawingContext.DrawRectangle(PreviewOverlayBrush, null, rect);
            pen = PreviewPen;
        }

        if (draftRect is not null)
        {
            drawingContext.DrawRectangle(DraftOverlayBrush, null, rect);
            pen = LocalDraftPen;
        }

        drawingContext.DrawRectangle(brush, pen, rect);
        DrawText(drawingContext, item.ItemId, new Point(rect.Left + 5, rect.Top + 4), 11, TextBrush);

        if (rect.Width > 100 && rect.Height > 36)
        {
            var detail = $"{item.Source}  {item.Rect.W}x{item.Rect.H}";
            DrawText(drawingContext, detail, new Point(rect.Left + 5, rect.Top + 20), 9, MutedTextBrush);
        }

        if (selected && draftRect is not null)
        {
            DrawText(drawingContext, "LOCAL", new Point(rect.Left + 5, Math.Max(rect.Top + 4, rect.Bottom - 18)), 9, WarningBrush);
        }
        else if (selected && previewRect is not null)
        {
            DrawText(drawingContext, "PREVIEW", new Point(rect.Left + 5, Math.Max(rect.Top + 4, rect.Bottom - 18)), 9, PreviewPen.Brush);
        }

        if (_warningItemIds.Contains(item.ItemId))
        {
            var marker = new Point(rect.Right - 12, rect.Top + 4);
            drawingContext.DrawEllipse(WarningBrush, null, marker, 5, 5);
            DrawText(drawingContext, "!", new Point(marker.X - 2.5, marker.Y - 6), 9, BackgroundBrush);
        }

        if (selected)
        {
            DrawHandles(drawingContext, rect);
        }
    }

    private void DrawHandles(DrawingContext drawingContext, Rect rect)
    {
        foreach (var point in HandlePoints(rect))
        {
            drawingContext.DrawRectangle(
                HandleBrush,
                HandlePen,
                new Rect(point.X - HandleSize / 2, point.Y - HandleSize / 2, HandleSize, HandleSize));
        }
    }

    private static IEnumerable<Point> HandlePoints(Rect rect)
    {
        yield return rect.TopLeft;
        yield return rect.TopRight;
        yield return rect.BottomRight;
        yield return rect.BottomLeft;
        yield return new Point(rect.Left + rect.Width / 2, rect.Top);
        yield return new Point(rect.Right, rect.Top + rect.Height / 2);
        yield return new Point(rect.Left + rect.Width / 2, rect.Bottom);
        yield return new Point(rect.Left, rect.Top + rect.Height / 2);
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
        drawingContext.DrawText(GetText(text, size, brush), origin);
    }

    private FormattedText GetText(string text, double size, Brush brush)
    {
        var dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;

        if (Math.Abs(dpi - _cachedPixelsPerDip) > 0.0001)
        {
            _textCache.Clear();
            _cachedPixelsPerDip = dpi;
        }

        var key = $"{size:0.###}|{brush.GetHashCode()}|{text}";

        if (_textCache.TryGetValue(key, out var cached))
        {
            return cached;
        }

        if (_textCache.Count > 4096)
        {
            _textCache.Clear();
        }

        var formatted = new FormattedText(
            text,
            CultureInfo.InvariantCulture,
            FlowDirection.LeftToRight,
            Typeface,
            size,
            brush,
            dpi);
        _textCache[key] = formatted;
        return formatted;
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
        var selected = GetSelectedDisplayRect();

        if (selected is not null && SelectedItemIndex >= 0)
        {
            var selectedScreen = WorldRectToScreen(selected.ToRect());
            var handle = RectEditMath.HandleAt(selectedScreen, screen, HandleRadius);

            if (handle != ResizeHandle.None)
            {
                BeginDrag(SelectedItemIndex, DragMode.Resize, handle, screen, selected);
                e.Handled = true;
                return;
            }

            if (selectedScreen.Contains(screen))
            {
                BeginDrag(SelectedItemIndex, DragMode.Move, ResizeHandle.None, screen, selected);
                e.Handled = true;
                return;
            }
        }

        var itemIndex = HitTestItem(screen);

        if (itemIndex >= 0)
        {
            SelectItem(itemIndex);

            if (SelectedItemIndex >= 0 && _items[SelectedItemIndex].ItemId == _items[itemIndex].ItemId)
            {
                var rect = GetSelectedDisplayRect();

                if (rect is not null)
                {
                    BeginDrag(SelectedItemIndex, DragMode.Move, ResizeHandle.None, screen, rect);
                }
            }

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
            return;
        }

        if (_dragMode != DragMode.None)
        {
            UpdateDrag(position);
        }
        else
        {
            UpdateCursor(position);
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
            return;
        }

        if (_dragMode != DragMode.None && e.ChangedButton == MouseButton.Left)
        {
            var committed = _interactiveRect;
            var moved = _dragMoved;
            EndDrag();

            if (moved && committed is not null)
            {
                DraftRectCommitted?.Invoke(this, committed);
            }
            else
            {
                DraftRectCancelled?.Invoke(this, EventArgs.Empty);
            }

            e.Handled = true;
        }
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);

        if (e.Key == Key.Escape)
        {
            if (_dragMode != DragMode.None)
            {
                CancelInteractiveEdit();
                DraftRectCancelled?.Invoke(this, EventArgs.Empty);
            }
            else
            {
                SelectedItemIndex = -1;
                SelectedMonitorIndex = -1;
                SelectionChanged?.Invoke(this, EventArgs.Empty);
                InvalidateVisual();
            }

            e.Handled = true;
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

    private void BeginDrag(int itemIndex, DragMode mode, ResizeHandle handle, Point screen, RectInfo startRect)
    {
        _dragMode = mode;
        _resizeHandle = handle;
        _dragItemIndex = itemIndex;
        _dragItemId = _items[itemIndex].ItemId;
        _dragStartScreen = screen;
        _dragStartWorldRect = startRect.ToRect();
        _interactiveRect = startRect;
        _dragMoved = false;
        CaptureMouse();
    }

    private void UpdateDrag(Point position)
    {
        if (!_dragMoved)
        {
            var distance = position - _dragStartScreen;

            if (Math.Abs(distance.X) < 3 && Math.Abs(distance.Y) < 3)
            {
                return;
            }

            _dragMoved = true;
        }

        if (_dragItemIndex < 0 || _dragItemIndex >= _items.Count)
        {
            return;
        }

        var delta = (position - _dragStartScreen) / Math.Max(Transform.Zoom, 0.000001);
        var dx = (int)Math.Round(delta.X, MidpointRounding.AwayFromZero);
        var dy = (int)Math.Round(delta.Y, MidpointRounding.AwayFromZero);
        var start = new RectInfo(
            (int)Math.Round(_dragStartWorldRect.X),
            (int)Math.Round(_dragStartWorldRect.Y),
            Math.Max(1, (int)Math.Round(_dragStartWorldRect.Width)),
            Math.Max(1, (int)Math.Round(_dragStartWorldRect.Height)));

        RectInfo updated;

        try
        {
            updated = _dragMode == DragMode.Move
                ? RectEditMath.Move(start, dx, dy)
                : RectEditMath.Resize(start, _resizeHandle, dx, dy);
        }
        catch (OverflowException)
        {
            return;
        }

        if (updated.W <= 0 || updated.H <= 0)
        {
            return;
        }

        _interactiveRect = updated;
        DraftRectChanging?.Invoke(this, updated);
        InvalidateVisual();
    }

    private void EndDrag()
    {
        _dragMode = DragMode.None;
        _dragItemIndex = -1;
        _dragItemId = null;
        _dragMoved = false;
        _interactiveRect = null;
        ReleaseMouseCapture();
        InvalidateVisual();
    }

    public void CancelInteractiveEdit()
    {
        if (_dragMode != DragMode.None)
        {
            EndDrag();
        }
    }

    private void UpdateCursor(Point position)
    {
        var selected = GetSelectedDisplayRect();

        if (selected is null || SelectedItemIndex < 0)
        {
            Cursor = Cursors.Arrow;
            return;
        }

        var screen = WorldRectToScreen(selected.ToRect());
        var handle = RectEditMath.HandleAt(screen, position, HandleRadius);

        Cursor = handle switch
        {
            ResizeHandle.NorthWest or ResizeHandle.SouthEast => Cursors.SizeNWSE,
            ResizeHandle.NorthEast or ResizeHandle.SouthWest => Cursors.SizeNESW,
            ResizeHandle.North or ResizeHandle.South => Cursors.SizeNS,
            ResizeHandle.East or ResizeHandle.West => Cursors.SizeWE,
            _ => screen.Contains(position) ? Cursors.SizeAll : Cursors.Arrow
        };
    }

    private int HitTestItem(Point screen)
    {
        var world = Transform.ScreenToWorld(screen);

        for (var index = _items.Count - 1; index >= 0; index--)
        {
            var item = _items[index];
            var rect = _draftRects.TryGetValue(item.ItemId, out var draft)
                ? draft
                : _previewRects.TryGetValue(item.ItemId, out var preview)
                    ? preview
                    : item.Rect;

            if (rect.ToRect().Contains(world))
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
            .Concat(_draftRects.Values)
            .Concat(_previewRects.Values)
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

    private enum DragMode
    {
        None,
        Move,
        Resize
    }
}
