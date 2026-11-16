using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace DevWS.Editor;

public enum GeometryScopeKind
{
    AbsoluteFallback,
    ProfileEntry,
    Relative
}

public sealed class GeometryScopeOption
{
    public GeometryScopeOption(GeometryScopeKind kind, string display, string storagePath, string? profileId = null)
    {
        Kind = kind;
        Display = display;
        StoragePath = storagePath;
        ProfileId = profileId;
    }

    public GeometryScopeKind Kind { get; }
    public string Display { get; }
    public string StoragePath { get; }
    public string? ProfileId { get; }

    public override string ToString() => Display;
}

public sealed record RelativeRectValues(double X, double Y, double W, double H);

public sealed record RelativeAnchorInfo(string Identity, string? Instance, string Basis);

public sealed class DraftDocument
{
    private JsonObject _root;
    private readonly JsonObject _baseline;
    private string _setId;

    private DraftDocument(
        JsonObject root,
        JsonObject baseline,
        string baseSha256,
        string? baseTopologyFingerprint,
        string setId)
    {
        _root = root;
        _baseline = baseline;
        BaseSha256 = baseSha256;
        BaseTopologyFingerprint = baseTopologyFingerprint;
        _setId = setId;
    }

    public string BaseSha256 { get; }
    public string? BaseTopologyFingerprint { get; }
    public string SetId => _setId;
    public bool IsDirty => !JsonEquals(_root, _baseline);
    public bool MatchesSnapshot(JsonObject snapshot) => JsonEquals(_root, snapshot);

    public static DraftDocument Create(
        JsonElement document,
        string baseSha256,
        string? baseTopologyFingerprint,
        string setId)
    {
        if (document.ValueKind != JsonValueKind.Object)
        {
            throw new EditorException(
                "protocol-error",
                "The editor backend did not return a complete configuration document.");
        }

        JsonObject root;

        try
        {
            root = JsonNode.Parse(document.GetRawText()) as JsonObject
                ?? throw new JsonException("The document root is not an object.");
        }
        catch (Exception ex)
        {
            throw new EditorException(
                "protocol-error",
                "The configuration document could not be loaded into the draft model.",
                inner: ex);
        }

        var baseline = (JsonObject)root.DeepClone();

        return new DraftDocument(root, baseline, baseSha256, baseTopologyFingerprint, setId);
    }

    public void RebindSet(string setId)
    {
        if (IsDirty)
        {
            throw new EditorException(
                "draft-dirty",
                "Discard the unsaved draft before changing the workspace set.");
        }

        EnsureSetExists(_baseline, setId);
        _setId = setId;
    }

    public JsonObject CreateDraftSnapshot() => (JsonObject)_root.DeepClone();

    public RectInfo GetAbsoluteLayout(string itemId)
    {
        var item = FindItem(_root, _setId, itemId);
        var layout = item["layout"] as JsonObject
            ?? throw new EditorException("draft-invalid", $"Item '{itemId}' has no absolute layout object.");

        return ReadRect(layout, $"Item '{itemId}' layout");
    }

    public string GetLayoutMode(string itemId)
    {
        var item = FindItem(_root, _setId, itemId);
        var mode = item["layoutMode"]?.GetValue<string>();
        return string.Equals(mode, "relative", StringComparison.Ordinal) ? "relative" : "absolute";
    }

    public RelativeAnchorInfo? GetRelativeAnchor(string itemId)
    {
        var item = FindItem(_root, _setId, itemId);
        var relative = item["layoutRelative"] as JsonObject;

        if (relative is null)
        {
            return null;
        }

        var monitor = relative["monitor"] as JsonObject;
        var identity = monitor?["identity"]?.GetValue<string>();
        var instance = monitor?["instance"]?.GetValue<string>();
        var basis = relative["basis"]?.GetValue<string>() ?? "workArea";

        if (string.IsNullOrWhiteSpace(identity))
        {
            return null;
        }

        return new RelativeAnchorInfo(identity!, instance, basis);
    }

    public RelativeRectValues? GetRelativeRect(string itemId)
    {
        var item = FindItem(_root, _setId, itemId);
        var rect = (item["layoutRelative"] as JsonObject)?["rect"] as JsonObject;

        if (rect is null)
        {
            return null;
        }

        return new RelativeRectValues(
            ReadDouble(rect["x"], "layoutRelative.rect.x"),
            ReadDouble(rect["y"], "layoutRelative.rect.y"),
            ReadDouble(rect["w"], "layoutRelative.rect.w"),
            ReadDouble(rect["h"], "layoutRelative.rect.h"));
    }

    public RectInfo? GetProfileEntry(string itemId, string profileId)
    {
        var set = FindSet(_root, _setId);
        var profile = FindProfile(set, profileId);

        if (profile is null)
        {
            return null;
        }

        var layouts = profile["layouts"] as JsonObject;

        if (layouts is null)
        {
            return null;
        }

        var key = FindPropertyKey(layouts, itemId);

        if (key is null || layouts[key] is not JsonObject entry)
        {
            return null;
        }

        return ReadRect(entry, $"Profile '{profileId}' entry '{itemId}'");
    }

    public void SetAbsoluteLayout(string itemId, RectInfo rect)
    {
        ValidateRect(rect);
        var item = FindItem(_root, _setId, itemId);
        var layout = item["layout"] as JsonObject
            ?? throw new EditorException("draft-invalid", $"Item '{itemId}' has no absolute layout object.");

        WriteRect(layout, rect);
    }

    public void SetProfileEntry(string itemId, string profileId, RectInfo rect)
    {
        ValidateRect(rect);
        var set = FindSet(_root, _setId);
        var profile = FindProfile(set, profileId)
            ?? throw new EditorException("profile-not-found", $"Profile '{profileId}' is not present in the draft.");

        var layouts = profile["layouts"] as JsonObject
            ?? throw new EditorException("unsupported-mutation", $"Profile '{profileId}' has no layout entries.");

        var key = FindPropertyKey(layouts, itemId);

        if (key is null || layouts[key] is not JsonObject entry)
        {
            throw new EditorException(
                "unsupported-mutation",
                $"Profile '{profileId}' does not already contain an entry for item '{itemId}'. P5 cannot create profile entries.");
        }

        WriteRect(entry, rect);
    }

    public void SetRelativeRect(string itemId, RelativeRectValues rect)
    {
        if (rect.W <= 0 || rect.H <= 0 ||
            !double.IsFinite(rect.X) || !double.IsFinite(rect.Y) ||
            !double.IsFinite(rect.W) || !double.IsFinite(rect.H))
        {
            throw new EditorException("invalid-rect", "The relative rectangle must be finite with positive width and height.");
        }

        var item = FindItem(_root, _setId, itemId);
        var relative = item["layoutRelative"] as JsonObject
            ?? throw new EditorException("draft-invalid", $"Item '{itemId}' has no relative layout object.");

        var target = relative["rect"] as JsonObject
            ?? throw new EditorException("draft-invalid", $"Item '{itemId}' has no relative rectangle.");

        target["x"] = JsonValue.Create(NormalizeFraction(rect.X));
        target["y"] = JsonValue.Create(NormalizeFraction(rect.Y));
        target["w"] = JsonValue.Create(NormalizeFraction(rect.W));
        target["h"] = JsonValue.Create(NormalizeFraction(rect.H));
    }

    public void SetRelativeMode(
        string itemId,
        string identity,
        string? instance,
        string basis,
        RelativeRectValues rect)
    {
        if (string.IsNullOrWhiteSpace(identity))
        {
            throw new EditorException("unsupported-mutation", "A relative mode requires a durable monitor identity.");
        }

        if (rect.W <= 0 || rect.H <= 0)
        {
            throw new EditorException("invalid-rect", "The relative rectangle must have positive width and height.");
        }

        var item = FindItem(_root, _setId, itemId);
        var monitor = new JsonObject { ["identity"] = identity };

        if (!string.IsNullOrWhiteSpace(instance))
        {
            monitor["instance"] = instance;
        }

        item["layoutMode"] = "relative";
        item["layoutRelative"] = new JsonObject
        {
            ["monitor"] = monitor,
            ["basis"] = basis,
            ["rect"] = new JsonObject
            {
                ["x"] = NormalizeFraction(rect.X),
                ["y"] = NormalizeFraction(rect.Y),
                ["w"] = NormalizeFraction(rect.W),
                ["h"] = NormalizeFraction(rect.H)
            }
        };
    }

    public void SetAbsoluteMode(string itemId, RectInfo layout)
    {
        ValidateRect(layout);
        var item = FindItem(_root, _setId, itemId);
        var target = item["layout"] as JsonObject
            ?? throw new EditorException("draft-invalid", $"Item '{itemId}' has no absolute layout object.");

        WriteRect(target, layout);
        item["layoutMode"] = "absolute";
        item.Remove("layoutRelative");
    }

    public void RevertItem(string itemId)
    {
        var item = FindItem(_root, _setId, itemId);
        var baselineSet = FindSet(_baseline, _setId);
        var baselineItem = FindItem(baselineSet, itemId);

        RestoreProperty(item, baselineItem, "layout");
        RestoreProperty(item, baselineItem, "layoutMode");
        RestoreProperty(item, baselineItem, "layoutRelative");

        var rootProfiles = FindSet(_root, _setId)["layoutProfiles"] as JsonArray;
        var baselineProfiles = baselineSet["layoutProfiles"] as JsonArray;

        if (rootProfiles is null || baselineProfiles is null)
        {
            return;
        }

        for (var profileIndex = 0; profileIndex < Math.Min(rootProfiles.Count, baselineProfiles.Count); profileIndex++)
        {
            if (rootProfiles[profileIndex] is not JsonObject rootProfile ||
                baselineProfiles[profileIndex] is not JsonObject baselineProfile)
            {
                continue;
            }

            var rootLayouts = rootProfile["layouts"] as JsonObject;
            var baselineLayouts = baselineProfile["layouts"] as JsonObject;

            if (rootLayouts is null || baselineLayouts is null)
            {
                continue;
            }

            var rootKey = FindPropertyKey(rootLayouts, itemId);
            var baselineKey = FindPropertyKey(baselineLayouts, itemId);

            if (rootKey is null || baselineKey is null)
            {
                continue;
            }

            if (rootLayouts[rootKey] is JsonObject rootEntry && baselineLayouts[baselineKey] is JsonObject baselineEntry)
            {
                foreach (var field in new[] { "x", "y", "w", "h" })
                {
                    RestoreProperty(rootEntry, baselineEntry, field);
                }
            }
        }
    }

    public void DiscardAll()
    {
        _root = (JsonObject)_baseline.DeepClone();
    }

    public IReadOnlyList<string> DirtyItemIds()
    {
        var result = new List<string>();
        var rootSet = FindSet(_root, _setId);

        if (rootSet["windows"] is not JsonArray windows)
        {
            return result;
        }

        foreach (var node in windows)
        {
            if (node is not JsonObject item)
            {
                continue;
            }

            var itemId = item["id"]?.GetValue<string>();

            if (string.IsNullOrWhiteSpace(itemId))
            {
                continue;
            }

            var baselineSet = FindSet(_baseline, _setId);
            var baselineItem = FindItem(baselineSet, itemId);

            if (!JsonEquals(item["layout"], baselineItem["layout"]) ||
                !JsonEquals(item["layoutMode"], baselineItem["layoutMode"]) ||
                !JsonEquals(item["layoutRelative"], baselineItem["layoutRelative"]))
            {
                result.Add(itemId!);
                continue;
            }

            if (ProfileGeometryDiffers(itemId!))
            {
                result.Add(itemId!);
            }
        }

        return result;
    }

    public IReadOnlyList<string> ValidateMutationScope()
    {
        return FindViolations(_baseline, _root, _setId);
    }

    public static IReadOnlyList<string> FindViolations(JsonObject baseline, JsonObject draft, string setId)
    {
        var targetIndex = FindSetIndex(baseline, setId);
        var violations = new List<string>();
        var allowed = new[]
        {
            new Regex($@"^/sets/{targetIndex}/windows/\d+/layout/(x|y|w|h)$", RegexOptions.CultureInvariant),
            new Regex($@"^/sets/{targetIndex}/windows/\d+/layoutMode( \(presence\))?$", RegexOptions.CultureInvariant),
            new Regex($@"^/sets/{targetIndex}/windows/\d+/layoutRelative( \(presence\))?$", RegexOptions.CultureInvariant),
            new Regex($@"^/sets/{targetIndex}/windows/\d+/layoutRelative/monitor/(identity|instance)$", RegexOptions.CultureInvariant),
            new Regex($@"^/sets/{targetIndex}/windows/\d+/layoutRelative/basis$", RegexOptions.CultureInvariant),
            new Regex($@"^/sets/{targetIndex}/windows/\d+/layoutRelative/rect/(x|y|w|h)$", RegexOptions.CultureInvariant),
            new Regex($@"^/sets/{targetIndex}/layoutProfiles/\d+/layouts/[^/]+/(x|y|w|h)$", RegexOptions.CultureInvariant)
        };

        CollectDifferences(baseline, draft, "", violations);

        var result = violations
            .Where(path => !allowed.Any(pattern => pattern.IsMatch(path)))
            .Distinct(StringComparer.Ordinal)
            .ToList();

        foreach (var violation in CheckModeCoherence(draft, setId))
        {
            if (!result.Contains(violation, StringComparer.Ordinal))
            {
                result.Add(violation);
            }
        }

        return result;
    }

    public void EnsureMutationScope()
    {
        var violations = ValidateMutationScope();

        if (violations.Count > 0)
        {
            throw new EditorException(
                "unsupported-mutation",
                "The draft changes a field that the v0.4 editor is not authorized to modify.",
                details: string.Join(Environment.NewLine, violations.Take(8)));
        }
    }

    private bool ProfileGeometryDiffers(string itemId)
    {
        var rootSet = FindSet(_root, _setId);
        var baselineSet = FindSet(_baseline, _setId);
        var rootProfiles = rootSet["layoutProfiles"] as JsonArray;
        var baselineProfiles = baselineSet["layoutProfiles"] as JsonArray;

        if (rootProfiles is null || baselineProfiles is null)
        {
            return false;
        }

        for (var index = 0; index < Math.Min(rootProfiles.Count, baselineProfiles.Count); index++)
        {
            if (rootProfiles[index] is not JsonObject rootProfile ||
                baselineProfiles[index] is not JsonObject baselineProfile)
            {
                continue;
            }

            var rootLayouts = rootProfile["layouts"] as JsonObject;
            var baselineLayouts = baselineProfile["layouts"] as JsonObject;

            if (rootLayouts is null || baselineLayouts is null)
            {
                continue;
            }

            var rootKey = FindPropertyKey(rootLayouts, itemId);
            var baselineKey = FindPropertyKey(baselineLayouts, itemId);

            if (rootKey is null || baselineKey is null)
            {
                continue;
            }

            if (!JsonEquals(rootLayouts[rootKey], baselineLayouts[baselineKey]))
            {
                return true;
            }
        }

        return false;
    }

    private static IEnumerable<string> CheckModeCoherence(JsonObject root, string setId)
    {
        var result = new List<string>();
        var set = FindSet(root, setId);

        if (set["windows"] is not JsonArray windows)
        {
            return result;
        }

        var index = 0;
        var setIndex = FindSetIndex(root, setId);

        foreach (var node in windows)
        {
            if (node is JsonObject item)
            {
                var itemId = item["id"]?.GetValue<string>() ?? index.ToString();
                var mode = item["layoutMode"]?.GetValue<string>() ?? "absolute";
                var relative = item["layoutRelative"] as JsonObject;

                if (string.Equals(mode, "relative", StringComparison.Ordinal) && relative is null)
                {
                    result.Add($"/sets/{setIndex}/windows/{index}/layoutRelative (absent for relative mode)");
                }
                else if (!string.Equals(mode, "relative", StringComparison.Ordinal) && relative is not null)
                {
                    result.Add($"/sets/{setIndex}/windows/{index}/layoutRelative (present for absolute mode of '{itemId}')");
                }
            }

            index++;
        }

        return result;
    }

    private static void RestoreProperty(JsonObject target, JsonObject baseline, string propertyName)
    {
        if (baseline.TryGetPropertyValue(propertyName, out var value))
        {
            target[propertyName] = value?.DeepClone();
        }
        else
        {
            target.Remove(propertyName);
        }
    }

    private static void CollectDifferences(JsonNode? baseline, JsonNode? draft, string path, List<string> violations)
    {
        if (JsonEquals(baseline, draft))
        {
            return;
        }

        if (baseline is JsonObject baselineObject && draft is JsonObject draftObject)
        {
            var keys = baselineObject.Select(pair => pair.Key)
                .Concat(draftObject.Select(pair => pair.Key))
                .Distinct(StringComparer.Ordinal)
                .OrderBy(key => key, StringComparer.Ordinal);

            foreach (var key in keys)
            {
                var hasBaseline = baselineObject.TryGetPropertyValue(key, out var baselineValue);
                var hasDraft = draftObject.TryGetPropertyValue(key, out var draftValue);

                if (hasBaseline != hasDraft)
                {
                    violations.Add($"{path}/{key} (presence)");
                    continue;
                }

                CollectDifferences(baselineValue, draftValue, $"{path}/{key}", violations);
            }

            return;
        }

        if (baseline is JsonArray baselineArray && draft is JsonArray draftArray)
        {
            if (baselineArray.Count != draftArray.Count)
            {
                violations.Add($"{path} (array length)");
                return;
            }

            for (var index = 0; index < baselineArray.Count; index++)
            {
                CollectDifferences(baselineArray[index], draftArray[index], $"{path}/{index}", violations);
            }

            return;
        }

        violations.Add(path);
    }

    private static bool JsonEquals(JsonNode? left, JsonNode? right)
    {
        if (left is null || right is null)
        {
            return left is null && right is null;
        }

        if (left is JsonObject leftObject && right is JsonObject rightObject)
        {
            if (leftObject.Count != rightObject.Count)
            {
                return false;
            }

            foreach (var pair in leftObject)
            {
                if (!rightObject.TryGetPropertyValue(pair.Key, out var value) ||
                    !JsonEquals(pair.Value, value))
                {
                    return false;
                }
            }

            return true;
        }

        if (left is JsonArray leftArray && right is JsonArray rightArray)
        {
            if (leftArray.Count != rightArray.Count)
            {
                return false;
            }

            for (var index = 0; index < leftArray.Count; index++)
            {
                if (!JsonEquals(leftArray[index], rightArray[index]))
                {
                    return false;
                }
            }

            return true;
        }

        if (left is JsonValue leftValue && right is JsonValue rightValue)
        {
            if (TryDecimal(leftValue, out var leftNumber) && TryDecimal(rightValue, out var rightNumber))
            {
                return leftNumber == rightNumber;
            }

            if (leftValue.TryGetValue<bool>(out var leftBoolean) && rightValue.TryGetValue<bool>(out var rightBoolean))
            {
                return leftBoolean == rightBoolean;
            }

            if (leftValue.TryGetValue<string>(out var leftString) && rightValue.TryGetValue<string>(out var rightString))
            {
                return string.Equals(leftString, rightString, StringComparison.Ordinal);
            }
        }

        return JsonNode.DeepEquals(left, right);
    }

    private static bool TryDecimal(JsonValue value, out decimal number)
    {
        try
        {
            return value.TryGetValue(out number);
        }
        catch
        {
            number = 0;
            return false;
        }
    }

    private static JsonObject FindSet(JsonObject root, string setId)
    {
        if (root["sets"] is not JsonArray sets)
        {
            throw new EditorException("draft-invalid", "The draft has no 'sets' array.");
        }

        foreach (var node in sets)
        {
            if (node is JsonObject set &&
                string.Equals(set["id"]?.GetValue<string>(), setId, StringComparison.OrdinalIgnoreCase))
            {
                return set;
            }
        }

        throw new EditorException("set-not-found", $"The draft does not contain set '{setId}'.");
    }

    private static void EnsureSetExists(JsonObject root, string setId)
    {
        if (root["sets"] is not JsonArray sets)
        {
            throw new EditorException("draft-invalid", "The draft has no 'sets' array.");
        }

        foreach (var node in sets)
        {
            if (node is JsonObject set &&
                string.Equals(set["id"]?.GetValue<string>(), setId, StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
        }

        throw new EditorException("set-not-found", $"The draft does not contain set '{setId}'.");
    }

    private static int FindSetIndex(JsonObject root, string setId)
    {
        if (root["sets"] is not JsonArray sets)
        {
            throw new EditorException("draft-invalid", "The draft has no 'sets' array.");
        }

        for (var index = 0; index < sets.Count; index++)
        {
            if (sets[index] is JsonObject set &&
                string.Equals(set["id"]?.GetValue<string>(), setId, StringComparison.OrdinalIgnoreCase))
            {
                return index;
            }
        }

        throw new EditorException("set-not-found", $"The draft does not contain set '{setId}'.");
    }

    private JsonObject FindItem(JsonObject root, string setId, string itemId)
    {
        var set = FindSet(root, setId);

        if (set["windows"] is not JsonArray windows)
        {
            throw new EditorException("draft-invalid", $"Set '{setId}' has no 'windows' array.");
        }

        foreach (var node in windows)
        {
            if (node is JsonObject item &&
                string.Equals(item["id"]?.GetValue<string>(), itemId, StringComparison.OrdinalIgnoreCase))
            {
                return item;
            }
        }

        if (root["sets"] is JsonArray sets)
        {
            foreach (var node in sets)
            {
                if (node is not JsonObject otherSet ||
                    string.Equals(otherSet["id"]?.GetValue<string>(), setId, StringComparison.OrdinalIgnoreCase) ||
                    otherSet["windows"] is not JsonArray otherWindows)
                {
                    continue;
                }

                foreach (var otherNode in otherWindows)
                {
                    if (otherNode is JsonObject otherItem &&
                        string.Equals(otherItem["id"]?.GetValue<string>(), itemId, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new EditorException(
                            "unsupported-mutation",
                            $"Item '{itemId}' belongs to another workspace set; P5 only edits the selected set.");
                    }
                }
            }
        }

        throw new EditorException("item-not-found", $"Set '{setId}' does not contain item '{itemId}'.");
    }

    private static JsonObject FindItem(JsonObject set, string itemId)
    {
        if (set["windows"] is JsonArray windows)
        {
            foreach (var node in windows)
            {
                if (node is JsonObject item &&
                    string.Equals(item["id"]?.GetValue<string>(), itemId, StringComparison.OrdinalIgnoreCase))
                {
                    return item;
                }
            }
        }

        throw new EditorException("item-not-found", $"The set does not contain item '{itemId}'.");
    }

    private static JsonObject? FindProfile(JsonObject set, string profileId)
    {
        if (set["layoutProfiles"] is not JsonArray profiles)
        {
            return null;
        }

        foreach (var node in profiles)
        {
            if (node is JsonObject profile &&
                string.Equals(profile["id"]?.GetValue<string>(), profileId, StringComparison.OrdinalIgnoreCase))
            {
                return profile;
            }
        }

        return null;
    }

    private static string? FindPropertyKey(JsonObject obj, string name)
    {
        foreach (var pair in obj)
        {
            if (string.Equals(pair.Key, name, StringComparison.OrdinalIgnoreCase))
            {
                return pair.Key;
            }
        }

        return null;
    }

    private static RectInfo ReadRect(JsonObject obj, string label)
    {
        var x = ReadInt(obj["x"], $"{label}.x");
        var y = ReadInt(obj["y"], $"{label}.y");
        var w = ReadInt(obj["w"], $"{label}.w");
        var h = ReadInt(obj["h"], $"{label}.h");

        if (w <= 0 || h <= 0)
        {
            throw new EditorException("draft-invalid", $"{label} must have positive width and height.");
        }

        return new RectInfo(x, y, w, h);
    }

    private static void WriteRect(JsonObject obj, RectInfo rect)
    {
        obj["x"] = rect.X;
        obj["y"] = rect.Y;
        obj["w"] = rect.W;
        obj["h"] = rect.H;
    }

    private static void ValidateRect(RectInfo rect)
    {
        if (rect.W <= 0 || rect.H <= 0)
        {
            throw new EditorException("invalid-rect", "Geometry width and height must be greater than 0.");
        }
    }

    private static int ReadInt(JsonNode? node, string label)
    {
        if (node is JsonValue value)
        {
            if (value.TryGetValue<int>(out var number))
            {
                return number;
            }

            if (value.TryGetValue<long>(out var longNumber) &&
                longNumber >= int.MinValue && longNumber <= int.MaxValue)
            {
                return (int)longNumber;
            }
        }

        throw new EditorException("draft-invalid", $"{label} must be a 32-bit integer.");
    }

    private static double ReadDouble(JsonNode? node, string label)
    {
        if (node is JsonValue value && value.TryGetValue<double>(out var number) && double.IsFinite(number))
        {
            return number;
        }

        throw new EditorException("draft-invalid", $"{label} must be a finite number.");
    }

    private static double NormalizeFraction(double value) =>
        Math.Round(value, 6, MidpointRounding.AwayFromZero);
}
