using System.Text.Json;

namespace DevWS.Editor;

public sealed class PreviewDiffEntry
{
    public string SetId { get; init; } = "";
    public string ItemId { get; init; } = "";
    public string Scope { get; init; } = "";
    public string Field { get; init; } = "";
    public JsonElement Before { get; init; }
    public JsonElement After { get; init; }

    public string BeforeDisplay => FormatValue(Before);
    public string AfterDisplay => FormatValue(After);

    public string Display => $"{ItemId}  ·  {Scope}  ·  {Field}:  {BeforeDisplay}  →  {AfterDisplay}";

    public override string ToString() => Display;

    public static PreviewDiffEntry Parse(JsonElement element)
    {
        return new PreviewDiffEntry
        {
            SetId = JsonText.String(element, "setId"),
            ItemId = JsonText.String(element, "itemId"),
            Scope = JsonText.String(element, "scope"),
            Field = JsonText.String(element, "field"),
            Before = element.TryGetProperty("before", out var before) ? before.Clone() : default,
            After = element.TryGetProperty("after", out var after) ? after.Clone() : default
        };
    }

    private static string FormatValue(JsonElement element)
    {
        if (element.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
        {
            return "—";
        }

        if (element.ValueKind == JsonValueKind.Object)
        {
            var rect = element.TryGetProperty("x", out _) &&
                       element.TryGetProperty("y", out _) &&
                       element.TryGetProperty("w", out _) &&
                       element.TryGetProperty("h", out _)
                ? new RectInfo(
                    JsonText.Int(element, "x"),
                    JsonText.Int(element, "y"),
                    JsonText.Int(element, "w"),
                    JsonText.Int(element, "h"))
                : null;

            if (rect is not null)
            {
                return rect.Display;
            }
        }

        return element.ValueKind switch
        {
            JsonValueKind.String => element.GetString() ?? "",
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            JsonValueKind.Number => element.GetRawText(),
            _ => element.GetRawText()
        };
    }
}

public sealed class ReviewInfo
{
    public string BaseSha256 { get; init; } = "";
    public string? TopologyFingerprint { get; init; }
    public IReadOnlyList<string> WarningIds { get; init; } = Array.Empty<string>();
    public string? WarningDigest { get; init; }
    public bool RequiresAcknowledgement { get; init; }
    public string? ReviewToken { get; init; }

    public static ReviewInfo Parse(JsonElement element)
    {
        return new ReviewInfo
        {
            BaseSha256 = JsonText.String(element, "baseSha256"),
            TopologyFingerprint = JsonText.NullableString(element, "topologyFingerprint"),
            WarningIds = JsonText.StringArray(element, "warningIds"),
            WarningDigest = JsonText.NullableString(element, "warningDigest"),
            RequiresAcknowledgement = JsonText.Bool(element, "requiresAcknowledgement"),
            ReviewToken = JsonText.NullableString(element, "reviewToken")
        };
    }
}

public sealed class PreviewResult
{
    public string BaseSha256 { get; init; } = "";
    public string CurrentSha256 { get; init; } = "";
    public bool BaseMatches { get; init; }
    public string SetId { get; init; } = "";
    public string? TopologyFingerprint { get; init; }
    public ProjectedSet SavedSet { get; init; } = new();
    public ProjectedSet DraftSet { get; init; } = new();
    public IReadOnlyList<PreviewDiffEntry> Diff { get; init; } = Array.Empty<PreviewDiffEntry>();
    public ReviewInfo Review { get; init; } = new();
    public IReadOnlyList<WarningInfo> Warnings { get; init; } = Array.Empty<WarningInfo>();

    public static PreviewResult Parse(JsonElement result, JsonElement warnings)
    {
        var diff = new List<PreviewDiffEntry>();

        if (result.ValueKind == JsonValueKind.Object &&
            result.TryGetProperty("diff", out var diffElement) &&
            diffElement.ValueKind == JsonValueKind.Array)
        {
            foreach (var entry in diffElement.EnumerateArray())
            {
                diff.Add(PreviewDiffEntry.Parse(entry));
            }
        }

        var warningList = new List<WarningInfo>();

        if (warnings.ValueKind == JsonValueKind.Array)
        {
            foreach (var warning in warnings.EnumerateArray())
            {
                warningList.Add(WarningInfo.Parse(warning));
            }
        }

        return new PreviewResult
        {
            BaseSha256 = JsonText.String(result, "baseSha256"),
            CurrentSha256 = JsonText.String(result, "currentSha256"),
            BaseMatches = JsonText.Bool(result, "baseMatches"),
            SetId = JsonText.String(result, "setId"),
            TopologyFingerprint = JsonText.NullableString(result, "topologyFingerprint"),
            SavedSet = ProjectedSet.Parse(JsonText.Object(result, "savedSet")),
            DraftSet = ProjectedSet.Parse(JsonText.Object(result, "draftSet")),
            Diff = diff,
            Review = ReviewInfo.Parse(JsonText.Object(result, "review")),
            Warnings = warningList
        };
    }
}

public sealed class PreviewDiffRow
{
    public PreviewDiffRow(PreviewDiffEntry entry)
    {
        Entry = entry;
    }

    public PreviewDiffEntry Entry { get; }
    public string Display => Entry.Display;
    public override string ToString() => Display;
}
