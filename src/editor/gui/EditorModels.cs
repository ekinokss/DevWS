using System.Text.Json;
using System.Windows;

namespace DevWS.Editor;

public sealed record RectInfo(int X, int Y, int W, int H)
{
    public Rect ToRect() => new(X, Y, W, H);
    public string Display => $"{X},{Y}  {W}x{H}";
}

public sealed class ConfigInfo
{
    public string CanonicalPath { get; init; } = "";
    public string EffectivePath { get; init; } = "";
    public string Source { get; init; } = "";
    public bool CanonicalExists { get; init; }
    public bool Writable { get; init; }
    public string Sha256 { get; init; } = "";
    public long SizeBytes { get; init; }
    public int Version { get; init; }
    public string DefaultSet { get; init; } = "";
    public bool Valid { get; init; }

    public static ConfigInfo Parse(JsonElement element)
    {
        return new ConfigInfo
        {
            CanonicalPath = JsonText.String(element, "canonicalPath"),
            EffectivePath = JsonText.String(element, "effectivePath"),
            Source = JsonText.String(element, "source"),
            CanonicalExists = JsonText.Bool(element, "canonicalExists"),
            Writable = JsonText.Bool(element, "writable"),
            Sha256 = JsonText.String(element, "sha256"),
            SizeBytes = JsonText.Long(element, "sizeBytes"),
            Version = JsonText.Int(element, "version"),
            DefaultSet = JsonText.String(element, "defaultSet"),
            Valid = JsonText.Bool(element, "valid")
        };
    }
}

public sealed class SetInfo
{
    public string Id { get; init; } = "";
    public bool IsDefault { get; init; }
    public int ItemCount { get; init; }
    public IReadOnlyList<string> ProfileIds { get; init; } = Array.Empty<string>();

    public static SetInfo Parse(JsonElement element)
    {
        return new SetInfo
        {
            Id = JsonText.String(element, "id"),
            IsDefault = JsonText.Bool(element, "isDefault"),
            ItemCount = JsonText.Int(element, "itemCount"),
            ProfileIds = JsonText.StringArray(element, "profileIds")
        };
    }
}

public sealed class ProfileMatchInfo
{
    public string Status { get; init; } = "";
    public string? ProfileId { get; init; }
    public string Reason { get; init; } = "";

    public static ProfileMatchInfo Parse(JsonElement element)
    {
        return new ProfileMatchInfo
        {
            Status = JsonText.String(element, "status"),
            ProfileId = JsonText.NullableString(element, "profileId"),
            Reason = JsonText.String(element, "reason")
        };
    }
}

public sealed class MonitorInfo
{
    public string Identity { get; init; } = "";
    public string Instance { get; init; } = "";
    public string FriendlyName { get; init; } = "";
    public bool Primary { get; init; }
    public RectInfo MonitorRect { get; init; } = new(0, 0, 1, 1);
    public RectInfo WorkRect { get; init; } = new(0, 0, 1, 1);
    public int ScalePercent { get; init; } = 100;
    public string OutputTechnology { get; init; } = "";

    public string Display =>
        $"{(string.IsNullOrWhiteSpace(FriendlyName) ? Identity : FriendlyName)}  " +
        $"{MonitorRect.W}x{MonitorRect.H} @ {MonitorRect.X},{MonitorRect.Y}  work {WorkRect.W}x{WorkRect.H} @ {WorkRect.X},{WorkRect.Y}" +
        (Primary ? "  [primary]" : "");

    public override string ToString() => Display;

    public static MonitorInfo Parse(JsonElement element)
    {
        return new MonitorInfo
        {
            Identity = JsonText.String(element, "identity"),
            Instance = JsonText.String(element, "instance"),
            FriendlyName = JsonText.String(element, "friendlyName"),
            Primary = JsonText.Bool(element, "primary"),
            MonitorRect = JsonText.Rect(element, "monitorRect") ?? new RectInfo(0, 0, 1, 1),
            WorkRect = JsonText.Rect(element, "workRect") ?? new RectInfo(0, 0, 1, 1),
            ScalePercent = JsonText.Int(element, "scalePercent"),
            OutputTechnology = JsonText.String(element, "outputTechnology")
        };
    }
}

public sealed class TopologyInfo
{
    public bool Available { get; init; }
    public bool IdentityComplete { get; init; }
    public bool CorrelationComplete { get; init; }
    public bool IdentityAmbiguous { get; init; }
    public string? Signature { get; init; }
    public string? Fingerprint { get; init; }
    public RectInfo? VirtualScreenRect { get; init; }
    public IReadOnlyList<MonitorInfo> Monitors { get; init; } = Array.Empty<MonitorInfo>();
    public string? Error { get; init; }

    public static TopologyInfo Parse(JsonElement element)
    {
        var monitors = new List<MonitorInfo>();
        if (element.ValueKind == JsonValueKind.Object &&
            element.TryGetProperty("monitors", out var monitorsElement) &&
            monitorsElement.ValueKind == JsonValueKind.Array)
        {
            foreach (var monitor in monitorsElement.EnumerateArray())
            {
                monitors.Add(MonitorInfo.Parse(monitor));
            }
        }

        return new TopologyInfo
        {
            Available = JsonText.Bool(element, "available"),
            IdentityComplete = JsonText.Bool(element, "identityComplete"),
            CorrelationComplete = JsonText.Bool(element, "correlationComplete"),
            IdentityAmbiguous = JsonText.Bool(element, "identityAmbiguous"),
            Signature = JsonText.NullableString(element, "signature"),
            Fingerprint = JsonText.NullableString(element, "fingerprint"),
            VirtualScreenRect = JsonText.Rect(element, "virtualScreenRect"),
            Monitors = monitors,
            Error = JsonText.NullableString(element, "error")
        };
    }
}

public sealed class RelativeLayoutInfo
{
    public string Identity { get; init; } = "";
    public string? Instance { get; init; }
    public string Basis { get; init; } = "";
    public double X { get; init; }
    public double Y { get; init; }
    public double W { get; init; }
    public double H { get; init; }

    public string Display => $"{Basis} {X:0.######},{Y:0.######}  {W:0.######}x{H:0.######} on {Identity}";

    public static RelativeLayoutInfo? Parse(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        var monitor = JsonText.Object(element, "monitor");
        var rect = JsonText.Object(element, "rect");

        return new RelativeLayoutInfo
        {
            Identity = JsonText.String(monitor, "identity"),
            Instance = JsonText.NullableString(monitor, "instance"),
            Basis = JsonText.String(element, "basis"),
            X = JsonText.Double(rect, "x"),
            Y = JsonText.Double(rect, "y"),
            W = JsonText.Double(rect, "w"),
            H = JsonText.Double(rect, "h")
        };
    }
}

public sealed class ProjectedItem
{
    public string ItemId { get; init; } = "";
    public string Type { get; init; } = "";
    public bool Enabled { get; init; }
    public string LayoutMode { get; init; } = "";
    public RectInfo Rect { get; init; } = new(0, 0, 1, 1);
    public string Source { get; init; } = "";
    public string? ProfileId { get; init; }
    public bool ProfileMatched { get; init; }
    public bool ProfileOverridesRelative { get; init; }
    public RectInfo? ProfileEntry { get; init; }
    public RelativeLayoutInfo? RelativeLayout { get; init; }
    public string RelativeStatus { get; init; } = "";
    public string? RelativeReason { get; init; }
    public string? RelativeMessage { get; init; }
    public RectInfo? RelativeRect { get; init; }
    public bool? RelativeReachable { get; init; }
    public RectInfo? FallbackRect { get; init; }
    public bool? FallbackReachable { get; init; }
    public bool FallbackUsed { get; init; }
    public bool ApplyGeometry { get; init; }
    public string PlacementStatus { get; init; } = "";
    public string PlacementReason { get; init; } = "";
    public bool? Reachable { get; init; }
    public double? VisibleRatio { get; init; }
    public int? VisibleWidth { get; init; }
    public int? VisibleHeight { get; init; }

    public string Display => $"{ItemId}  [{Type}]  {Source}  {Rect.Display}";
    public override string ToString() => Display;

    public static ProjectedItem Parse(JsonElement element)
    {
        return new ProjectedItem
        {
            ItemId = JsonText.String(element, "itemId"),
            Type = JsonText.String(element, "type"),
            Enabled = JsonText.Bool(element, "enabled"),
            LayoutMode = JsonText.String(element, "layoutMode"),
            Rect = JsonText.Rect(element, "rect") ?? new RectInfo(0, 0, 1, 1),
            Source = JsonText.String(element, "source"),
            ProfileId = JsonText.NullableString(element, "profileId"),
            ProfileMatched = JsonText.Bool(element, "profileMatched"),
            ProfileOverridesRelative = JsonText.Bool(element, "profileOverridesRelative"),
            ProfileEntry = JsonText.Rect(element, "profileEntry"),
            RelativeLayout = RelativeLayoutInfo.Parse(JsonText.Object(element, "relativeLayout")),
            RelativeStatus = JsonText.String(element, "relativeStatus"),
            RelativeReason = JsonText.NullableString(element, "relativeReason"),
            RelativeMessage = JsonText.NullableString(element, "relativeMessage"),
            RelativeRect = JsonText.Rect(element, "relativeRect"),
            RelativeReachable = JsonText.NullableBool(element, "relativeReachable"),
            FallbackRect = JsonText.Rect(element, "fallbackRect"),
            FallbackReachable = JsonText.NullableBool(element, "fallbackReachable"),
            FallbackUsed = JsonText.Bool(element, "fallbackUsed"),
            ApplyGeometry = JsonText.Bool(element, "applyGeometry"),
            PlacementStatus = JsonText.String(element, "placementStatus"),
            PlacementReason = JsonText.String(element, "placementReason"),
            Reachable = JsonText.NullableBool(element, "reachable"),
            VisibleRatio = JsonText.NullableDouble(element, "visibleRatio"),
            VisibleWidth = JsonText.NullableInt(element, "visibleWidth"),
            VisibleHeight = JsonText.NullableInt(element, "visibleHeight")
        };
    }
}

public sealed class ProjectedSet
{
    public string Id { get; init; } = "";
    public bool IsDefault { get; init; }
    public bool ProfileAware { get; init; }
    public ProfileMatchInfo ProfileMatch { get; init; } = new();
    public string? LifecycleRefusal { get; init; }
    public IReadOnlyList<ProjectedItem> Items { get; init; } = Array.Empty<ProjectedItem>();

    public static ProjectedSet Parse(JsonElement element)
    {
        var items = new List<ProjectedItem>();
        if (element.ValueKind == JsonValueKind.Object &&
            element.TryGetProperty("items", out var itemsElement) &&
            itemsElement.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in itemsElement.EnumerateArray())
            {
                items.Add(ProjectedItem.Parse(item));
            }
        }

        return new ProjectedSet
        {
            Id = JsonText.String(element, "id"),
            IsDefault = JsonText.Bool(element, "isDefault"),
            ProfileAware = JsonText.Bool(element, "profileAware"),
            ProfileMatch = ProfileMatchInfo.Parse(JsonText.Object(element, "profileMatch")),
            LifecycleRefusal = JsonText.NullableString(element, "lifecycleRefusal"),
            Items = items
        };
    }
}

public sealed class WarningDetails
{
    public string? SetId { get; init; }
    public string? ItemId { get; init; }
    public string? Identity { get; init; }
    public string? RelativeStatus { get; init; }
    public string? PlacementStatus { get; init; }
    public string? PlacementReason { get; init; }

    public string Summary
    {
        get
        {
            var parts = new List<string>();
            if (!string.IsNullOrWhiteSpace(ItemId)) parts.Add($"item {ItemId}");
            if (!string.IsNullOrWhiteSpace(Identity)) parts.Add($"identity {Identity}");
            if (!string.IsNullOrWhiteSpace(RelativeStatus)) parts.Add($"relative {RelativeStatus}");
            if (!string.IsNullOrWhiteSpace(PlacementStatus)) parts.Add($"placement {PlacementStatus}");
            return string.Join("; ", parts);
        }
    }

    public static WarningDetails Parse(JsonElement element)
    {
        return new WarningDetails
        {
            SetId = JsonText.NullableString(element, "setId"),
            ItemId = JsonText.NullableString(element, "itemId"),
            Identity = JsonText.NullableString(element, "identity"),
            RelativeStatus = JsonText.NullableString(element, "relativeStatus"),
            PlacementStatus = JsonText.NullableString(element, "placementStatus"),
            PlacementReason = JsonText.NullableString(element, "placementReason")
        };
    }
}

public sealed class WarningInfo
{
    public string Id { get; init; } = "";
    public string Code { get; init; } = "";
    public string Message { get; init; } = "";
    public bool RequiresAcknowledgement { get; init; }
    public WarningDetails Details { get; init; } = new();

    public string Display =>
        $"[{Code}] {Message}" +
        (string.IsNullOrWhiteSpace(Details.Summary) ? "" : $"  ({Details.Summary})");

    public override string ToString() => Display;

    public static WarningInfo Parse(JsonElement element)
    {
        return new WarningInfo
        {
            Id = JsonText.String(element, "id"),
            Code = JsonText.String(element, "code"),
            Message = JsonText.String(element, "message"),
            RequiresAcknowledgement = JsonText.Bool(element, "requiresAcknowledgement"),
            Details = WarningDetails.Parse(JsonText.Object(element, "details"))
        };
    }
}

public sealed class WorkspaceProjection
{
    public string ConfigRevision { get; init; } = "";
    public string SetId { get; init; } = "";
    public ProjectedSet Set { get; init; } = new();
    public TopologyInfo Topology { get; init; } = new();
    public IReadOnlyList<WarningInfo> Warnings { get; init; } = Array.Empty<WarningInfo>();

    public static WorkspaceProjection Parse(JsonElement result, JsonElement warnings)
    {
        var warningList = new List<WarningInfo>();
        if (warnings.ValueKind == JsonValueKind.Array)
        {
            foreach (var warning in warnings.EnumerateArray())
            {
                warningList.Add(WarningInfo.Parse(warning));
            }
        }

        return new WorkspaceProjection
        {
            ConfigRevision = JsonText.String(result, "configRevision"),
            SetId = JsonText.String(result, "setId"),
            Set = ProjectedSet.Parse(JsonText.Object(result, "set")),
            Topology = TopologyInfo.Parse(JsonText.Object(result, "topology")),
            Warnings = warningList
        };
    }
}

public sealed class InspectInfo
{
    public ConfigInfo Config { get; init; } = new();
    public IReadOnlyList<SetInfo> Sets { get; init; } = Array.Empty<SetInfo>();
    public TopologyInfo Topology { get; init; } = new();

    public static InspectInfo Parse(JsonElement result)
    {
        var sets = new List<SetInfo>();
        if (result.ValueKind == JsonValueKind.Object &&
            result.TryGetProperty("sets", out var setsElement) &&
            setsElement.ValueKind == JsonValueKind.Array)
        {
            foreach (var set in setsElement.EnumerateArray())
            {
                sets.Add(SetInfo.Parse(set));
            }
        }

        return new InspectInfo
        {
            Config = ConfigInfo.Parse(JsonText.Object(result, "config")),
            Sets = sets,
            Topology = TopologyInfo.Parse(JsonText.Object(result, "topology"))
        };
    }
}

public sealed record EditorSnapshot(
    BackendHello Hello,
    InspectInfo Inspect,
    WorkspaceProjection Projection,
    string ReadConfigSha256,
    JsonElement Document);

public sealed class EditorException : Exception
{
    public EditorException(
        string code,
        string message,
        bool requiresRefresh = false,
        string? details = null,
        Exception? inner = null)
        : base(message, inner)
    {
        Code = code;
        RequiresRefresh = requiresRefresh;
        DetailsText = details;
    }

    public string Code { get; }
    public bool RequiresRefresh { get; }
    public string? DetailsText { get; }
}

public static class JsonText
{
    public static string String(JsonElement element, string name)
    {
        return element.ValueKind == JsonValueKind.Object &&
               element.TryGetProperty(name, out var value) &&
               value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? ""
            : "";
    }

    public static string? NullableString(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(name, out var value))
        {
            return null;
        }

        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Null => null,
            _ => null
        };
    }

    public static bool Bool(JsonElement element, string name)
    {
        return element.ValueKind == JsonValueKind.Object &&
               element.TryGetProperty(name, out var value) &&
               value.ValueKind is JsonValueKind.True or JsonValueKind.False &&
               value.GetBoolean();
    }

    public static bool? NullableBool(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(name, out var value))
        {
            return null;
        }

        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null
        };
    }

    public static int Int(JsonElement element, string name)
    {
        return element.ValueKind == JsonValueKind.Object &&
               element.TryGetProperty(name, out var value) &&
               value.ValueKind == JsonValueKind.Number &&
               value.TryGetInt32(out var number)
            ? number
            : 0;
    }

    public static int? NullableInt(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(name, out var value))
        {
            return null;
        }

        return value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number)
            ? number
            : null;
    }

    public static long Long(JsonElement element, string name)
    {
        return element.ValueKind == JsonValueKind.Object &&
               element.TryGetProperty(name, out var value) &&
               value.ValueKind == JsonValueKind.Number &&
               value.TryGetInt64(out var number)
            ? number
            : 0;
    }

    public static double Double(JsonElement element, string name)
    {
        return element.ValueKind == JsonValueKind.Object &&
               element.TryGetProperty(name, out var value) &&
               value.ValueKind == JsonValueKind.Number &&
               value.TryGetDouble(out var number)
            ? number
            : 0;
    }

    public static double? NullableDouble(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(name, out var value))
        {
            return null;
        }

        return value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number)
            ? number
            : null;
    }

    public static JsonElement Object(JsonElement element, string name)
    {
        return element.ValueKind == JsonValueKind.Object &&
               element.TryGetProperty(name, out var value) &&
               value.ValueKind == JsonValueKind.Object
            ? value
            : default;
    }

    public static RectInfo? Rect(JsonElement element, string name)
    {
        var rect = Object(element, name);
        return rect.ValueKind == JsonValueKind.Object
            ? new RectInfo(Int(rect, "x"), Int(rect, "y"), Int(rect, "w"), Int(rect, "h"))
            : null;
    }

    public static IReadOnlyList<string> StringArray(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object ||
            !element.TryGetProperty(name, out var value) ||
            value.ValueKind != JsonValueKind.Array)
        {
            return Array.Empty<string>();
        }

        var result = new List<string>();
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String)
            {
                result.Add(item.GetString() ?? "");
            }
        }

        return result;
    }
}
