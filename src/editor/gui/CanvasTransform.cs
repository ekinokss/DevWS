using System.Windows;

namespace DevWS.Editor;

/// <summary>
/// Maps DevWS virtual-screen coordinates to WPF canvas coordinates.
/// The transform is deliberately independent of WPF DPI: all geometry math uses
/// backend virtual-screen units, and WPF DIPs are only the drawing surface.
/// </summary>
public sealed class CanvasTransform
{
    public Rect VirtualScreen { get; private set; } = Rect.Empty;
    public double Zoom { get; private set; } = 1.0;
    public Vector Pan { get; private set; }
    public double MinZoom { get; init; } = 0.02;
    public double MaxZoom { get; init; } = 20.0;

    public Point WorldToScreen(Point world)
    {
        return new Point(
            (world.X - VirtualScreen.X) * Zoom + Pan.X,
            (world.Y - VirtualScreen.Y) * Zoom + Pan.Y);
    }

    public Point ScreenToWorld(Point screen)
    {
        return new Point(
            (screen.X - Pan.X) / Zoom + VirtualScreen.X,
            (screen.Y - Pan.Y) / Zoom + VirtualScreen.Y);
    }

    public void Fit(Rect virtualScreen, Size viewport, double padding = 32)
    {
        VirtualScreen = virtualScreen;
        Zoom = 1.0;
        Pan = default;

        if (viewport.Width <= 1 || viewport.Height <= 1 ||
            virtualScreen.Width <= 0 || virtualScreen.Height <= 0)
        {
            return;
        }

        var availableWidth = Math.Max(1, viewport.Width - padding * 2);
        var availableHeight = Math.Max(1, viewport.Height - padding * 2);
        var zoomX = availableWidth / virtualScreen.Width;
        var zoomY = availableHeight / virtualScreen.Height;
        Zoom = Math.Clamp(Math.Min(zoomX, zoomY), MinZoom, MaxZoom);

        Pan = new Vector(
            (viewport.Width - virtualScreen.Width * Zoom) / 2,
            (viewport.Height - virtualScreen.Height * Zoom) / 2);
    }

    public void PanBy(Vector delta) => Pan += delta;

    public void ZoomAt(Point screenAnchor, double factor)
    {
        var world = ScreenToWorld(screenAnchor);
        var newZoom = Math.Clamp(Zoom * factor, MinZoom, MaxZoom);

        if (Math.Abs(newZoom - Zoom) < double.Epsilon)
        {
            return;
        }

        Zoom = newZoom;
        Pan = new Vector(
            screenAnchor.X - (world.X - VirtualScreen.X) * Zoom,
            screenAnchor.Y - (world.Y - VirtualScreen.Y) * Zoom);
    }

    public void ResetZoom(Size viewport, double padding = 32)
    {
        Fit(VirtualScreen, viewport, padding);
    }

    public string Describe()
    {
        return $"zoom={Zoom:0.###} pan=({Pan.X:0.##},{Pan.Y:0.##}) " +
               $"virtual=({VirtualScreen.X},{VirtualScreen.Y},{VirtualScreen.Width}x{VirtualScreen.Height})";
    }
}
