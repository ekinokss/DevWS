using System.IO;
using System.Windows;

namespace DevWS.WpfSpike;

public sealed record SelfTestResult(string Name, bool Passed, string Details);

public static class GeometrySelfTest
{
    public static IReadOnlyList<SelfTestResult> Run()
    {
        var results = new List<SelfTestResult>();

        void Check(string name, Func<bool> test, string details)
        {
            bool passed;
            try
            {
                passed = test();
            }
            catch (Exception ex)
            {
                results.Add(new SelfTestResult(name, false, $"{details}; exception: {ex.Message}"));
                return;
            }

            results.Add(new SelfTestResult(name, passed, details));
        }

        var transform = new CanvasTransform();
        var virtualRect = new Rect(-1920, 0, 4480, 1440);
        var viewport = new Size(1200, 800);
        transform.Fit(virtualRect, viewport);

        Check("fit-negative-origin", () =>
        {
            var topLeft = transform.WorldToScreen(new Point(-1920, 0));
            var bottomRight = transform.WorldToScreen(new Point(2560, 1440));
            return topLeft.X >= 0 && topLeft.Y >= 0 &&
                   bottomRight.X <= viewport.Width && bottomRight.Y <= viewport.Height &&
                   bottomRight.X > topLeft.X && bottomRight.Y > topLeft.Y;
        }, "all virtual-screen corners fit inside the viewport");

        Check("world-screen-roundtrip", () =>
        {
            foreach (var point in new[]
                     {
                         new Point(-1920, 0),
                         new Point(0, 0),
                         new Point(2560, 1440),
                         new Point(-17, 933)
                     })
            {
                var roundTrip = transform.ScreenToWorld(transform.WorldToScreen(point));
                if (Math.Abs(roundTrip.X - point.X) > 1e-6 ||
                    Math.Abs(roundTrip.Y - point.Y) > 1e-6)
                {
                    return false;
                }
            }

            return true;
        }, "world -> screen -> world is stable within 1e-6");

        Check("zoom-anchor-roundtrip", () =>
        {
            var anchor = new Point(640, 400);
            var worldBefore = transform.ScreenToWorld(anchor);
            transform.ZoomAt(anchor, 1.75);
            var worldAfter = transform.ScreenToWorld(anchor);
            return Math.Abs(worldAfter.X - worldBefore.X) < 1e-6 &&
                   Math.Abs(worldAfter.Y - worldBefore.Y) < 1e-6;
        }, "zoom at a pointer anchor keeps the world point under the pointer");

        Check("pan-roundtrip", () =>
        {
            var before = transform.ScreenToWorld(new Point(100, 100));
            transform.PanBy(new Vector(37, -19));
            var after = transform.ScreenToWorld(new Point(137, 81));
            return Math.Abs(after.X - before.X) < 1e-6 &&
                   Math.Abs(after.Y - before.Y) < 1e-6;
        }, "pan shifts the screen origin without changing world geometry");

        Check("item-rect-roundtrip", () =>
        {
            var item = new Rect(-1900, 20, 800, 600);
            var screenTopLeft = transform.WorldToScreen(item.TopLeft);
            var screenBottomRight = transform.WorldToScreen(item.BottomRight);
            var worldTopLeft = transform.ScreenToWorld(screenTopLeft);
            var worldBottomRight = transform.ScreenToWorld(screenBottomRight);
            return Math.Abs(worldTopLeft.X - item.Left) < 1e-6 &&
                   Math.Abs(worldTopLeft.Y - item.Top) < 1e-6 &&
                   Math.Abs(worldBottomRight.X - item.Right) < 1e-6 &&
                   Math.Abs(worldBottomRight.Y - item.Bottom) < 1e-6;
        }, "configured item rectangles survive the canvas transform");

        Check("zoom-clamp", () =>
        {
            var clampTransform = new CanvasTransform();
            clampTransform.Fit(virtualRect, viewport);
            clampTransform.ZoomAt(new Point(600, 400), 1e6);
            var high = clampTransform.Zoom;
            clampTransform.ZoomAt(new Point(600, 400), 1e-9);
            var low = clampTransform.Zoom;
            return high <= clampTransform.MaxZoom && low >= clampTransform.MinZoom;
        }, "zoom remains inside configured bounds");

        foreach (var path in FixtureLoader.EnumerateFixturePaths())
        {
            var fixture = FixtureLoader.Load(path);
            var fixtureTransform = new CanvasTransform();
            fixtureTransform.Fit(fixture.GetVirtualScreenRect(), viewport);

            Check($"fixture-fit:{Path.GetFileName(path)}", () =>
            {
                var virtualScreen = fixture.GetVirtualScreenRect();
                var corners = new[]
                {
                    virtualScreen.TopLeft,
                    virtualScreen.TopRight,
                    virtualScreen.BottomLeft,
                    virtualScreen.BottomRight
                };

                foreach (var corner in corners)
                {
                    var screen = fixtureTransform.WorldToScreen(corner);
                    if (screen.X < -0.001 || screen.Y < -0.001 ||
                        screen.X > viewport.Width + 0.001 || screen.Y > viewport.Height + 0.001)
                    {
                        return false;
                    }
                }

                return fixture.Monitors.Count > 0;
            }, $"{fixture.Monitors.Count} monitors, {fixture.Items.Count} items");
        }

        return results;
    }
}
