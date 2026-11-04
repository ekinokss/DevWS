using System.IO;
using System.Text.Json;
using System.Windows;

namespace DevWS.WpfSpike;

public sealed class RectDto
{
    public int X { get; set; }
    public int Y { get; set; }
    public int W { get; set; }
    public int H { get; set; }

    public Rect ToRect() => new(X, Y, W, H);

    public static RectDto FromRect(Rect rect) => new()
    {
        X = (int)Math.Round(rect.X),
        Y = (int)Math.Round(rect.Y),
        W = (int)Math.Round(rect.Width),
        H = (int)Math.Round(rect.Height)
    };

    public RectDto Clone() => new() { X = X, Y = Y, W = W, H = H };
}

public sealed class MonitorDto
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public bool Primary { get; set; }
    public RectDto MonitorRect { get; set; } = new();
    public RectDto WorkRect { get; set; } = new();
    public int ScalePercent { get; set; } = 100;
}

public sealed class ItemDto
{
    public string Id { get; set; } = "";
    public string Kind { get; set; } = "terminal";
    public string MonitorId { get; set; } = "";
    public bool Enabled { get; set; } = true;
    public RectDto Rect { get; set; } = new();
}

public sealed class WorkspaceFixture
{
    public string Name { get; set; } = "synthetic";
    public RectDto? VirtualScreenRect { get; set; }
    public List<MonitorDto> Monitors { get; set; } = new();
    public List<ItemDto> Items { get; set; } = new();

    public Rect GetVirtualScreenRect()
    {
        if (VirtualScreenRect is { W: > 0, H: > 0 })
        {
            return VirtualScreenRect.ToRect();
        }

        if (Monitors.Count == 0)
        {
            return Rect.Empty;
        }

        var left = Monitors.Min(m => m.MonitorRect.X);
        var top = Monitors.Min(m => m.MonitorRect.Y);
        var right = Monitors.Max(m => m.MonitorRect.X + m.MonitorRect.W);
        var bottom = Monitors.Max(m => m.MonitorRect.Y + m.MonitorRect.H);
        return new Rect(left, top, right - left, bottom - top);
    }

    public void Validate()
    {
        if (Monitors.Count == 0)
        {
            throw new InvalidDataException("Fixture must contain at least one monitor.");
        }

        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var monitor in Monitors)
        {
            if (string.IsNullOrWhiteSpace(monitor.Id) || !ids.Add(monitor.Id))
            {
                throw new InvalidDataException("Monitor ids must be non-empty and unique.");
            }

            if (monitor.MonitorRect.W <= 0 || monitor.MonitorRect.H <= 0)
            {
                throw new InvalidDataException($"Monitor '{monitor.Id}' has a non-positive rectangle.");
            }

            if (monitor.WorkRect.W <= 0 || monitor.WorkRect.H <= 0)
            {
                throw new InvalidDataException($"Monitor '{monitor.Id}' has a non-positive work area.");
            }
        }

        var itemIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var item in Items)
        {
            if (string.IsNullOrWhiteSpace(item.Id) || !itemIds.Add(item.Id))
            {
                throw new InvalidDataException("Item ids must be non-empty and unique.");
            }

            if (item.Rect.W <= 0 || item.Rect.H <= 0)
            {
                throw new InvalidDataException($"Item '{item.Id}' has a non-positive rectangle.");
            }

            if (!ids.Contains(item.MonitorId))
            {
                throw new InvalidDataException($"Item '{item.Id}' references unknown monitor '{item.MonitorId}'.");
            }
        }

        var virtualRect = GetVirtualScreenRect();

        if (virtualRect.Width <= 0 || virtualRect.Height <= 0)
        {
            throw new InvalidDataException("Virtual screen rectangle must be positive.");
        }
    }
}

public static class FixtureLoader
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true
    };

    public static WorkspaceFixture Load(string path)
    {
        var fullPath = Path.GetFullPath(path);
        var json = File.ReadAllText(fullPath);
        var fixture = JsonSerializer.Deserialize<WorkspaceFixture>(json, Options)
            ?? throw new InvalidDataException($"Fixture '{fullPath}' is empty or invalid.");
        fixture.Validate();
        return fixture;
    }

    public static IReadOnlyList<string> EnumerateFixturePaths()
    {
        var root = Path.Combine(AppContext.BaseDirectory, "Fixtures");
        if (!Directory.Exists(root))
        {
            return Array.Empty<string>();
        }

        return Directory.GetFiles(root, "*.json")
            .OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase)
            .ToArray();
    }
}
