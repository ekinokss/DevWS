using System.Windows;

namespace DevWS.Editor;

public enum ResizeHandle
{
    None,
    NorthWest,
    North,
    NorthEast,
    East,
    SouthEast,
    South,
    SouthWest,
    West
}

public static class RectEditMath
{
    public const int MinimumSize = 1;

    public static RectInfo Move(RectInfo rect, int dx, int dy)
    {
        return new RectInfo(
            checked(rect.X + dx),
            checked(rect.Y + dy),
            rect.W,
            rect.H);
    }

    public static RectInfo Resize(RectInfo rect, ResizeHandle handle, int dx, int dy)
    {
        if (handle == ResizeHandle.None)
        {
            return rect;
        }

        long left = rect.X;
        long top = rect.Y;
        long right = (long)rect.X + rect.W;
        long bottom = (long)rect.Y + rect.H;

        switch (handle)
        {
            case ResizeHandle.NorthWest:
                left += dx;
                top += dy;
                break;
            case ResizeHandle.North:
                top += dy;
                break;
            case ResizeHandle.NorthEast:
                right += dx;
                top += dy;
                break;
            case ResizeHandle.East:
                right += dx;
                break;
            case ResizeHandle.SouthEast:
                right += dx;
                bottom += dy;
                break;
            case ResizeHandle.South:
                bottom += dy;
                break;
            case ResizeHandle.SouthWest:
                left += dx;
                bottom += dy;
                break;
            case ResizeHandle.West:
                left += dx;
                break;
        }

        var movesLeft = handle is ResizeHandle.NorthWest or ResizeHandle.West or ResizeHandle.SouthWest;
        var movesTop = handle is ResizeHandle.NorthWest or ResizeHandle.North or ResizeHandle.NorthEast;
        var movesRight = handle is ResizeHandle.NorthEast or ResizeHandle.East or ResizeHandle.SouthEast;
        var movesBottom = handle is ResizeHandle.SouthWest or ResizeHandle.South or ResizeHandle.SouthEast;

        if (right - left < MinimumSize)
        {
            if (movesLeft)
            {
                left = right - MinimumSize;
            }
            else if (movesRight)
            {
                right = left + MinimumSize;
            }
        }

        if (bottom - top < MinimumSize)
        {
            if (movesTop)
            {
                top = bottom - MinimumSize;
            }
            else if (movesBottom)
            {
                bottom = top + MinimumSize;
            }
        }

        if (right - left < MinimumSize)
        {
            right = left + MinimumSize;
        }

        if (bottom - top < MinimumSize)
        {
            bottom = top + MinimumSize;
        }

        return new RectInfo(
            checked((int)left),
            checked((int)top),
            checked((int)(right - left)),
            checked((int)(bottom - top)));
    }

    public static ResizeHandle HandleAt(Rect screenRect, Point point, double radius = 7.0)
    {
        var handles = new (ResizeHandle Handle, Point Point)[]
        {
            (ResizeHandle.NorthWest, screenRect.TopLeft),
            (ResizeHandle.NorthEast, screenRect.TopRight),
            (ResizeHandle.SouthEast, screenRect.BottomRight),
            (ResizeHandle.SouthWest, screenRect.BottomLeft),
            (ResizeHandle.North, new Point(screenRect.Left + screenRect.Width / 2, screenRect.Top)),
            (ResizeHandle.East, new Point(screenRect.Right, screenRect.Top + screenRect.Height / 2)),
            (ResizeHandle.South, new Point(screenRect.Left + screenRect.Width / 2, screenRect.Bottom)),
            (ResizeHandle.West, new Point(screenRect.Left, screenRect.Top + screenRect.Height / 2))
        };

        foreach (var candidate in handles)
        {
            if (Math.Abs(point.X - candidate.Point.X) <= radius &&
                Math.Abs(point.Y - candidate.Point.Y) <= radius)
            {
                return candidate.Handle;
            }
        }

        return ResizeHandle.None;
    }
}
