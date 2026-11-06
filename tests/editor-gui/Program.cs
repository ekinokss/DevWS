using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using DevWS.Editor;

namespace DevWS.Editor.Tests;

internal static class Program
{
    private static int _passed;
    private static int _failed;
    private static string _fakeBackend = "";
    private static string _pwsh = "";
    private static string _realBackend = "";
    private static string _tempRoot = "";

    [STAThread]
    public static int Main()
    {
        try
        {
            var repoRoot = FindRepoRoot();
            _pwsh = PwshLocator.Resolve();
            _realBackend = Path.Combine(repoRoot, "src", "editor", "ws-editor-backend.ps1");
            _fakeBackend = ResolveFakeBackend(repoRoot);
            _tempRoot = Path.Combine(Path.GetTempPath(), "devws-editor-tests-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_tempRoot);

            var tests = new (string Name, Func<Task> Body)[]
            {
                ("fake handshake succeeds", FakeHandshake),
                ("fake unsupported protocol is refused", FakeUnsupportedProtocol),
                ("fake missing validate/convert is refused", FakeMissingDraftOps),
                ("fake sequential requests correlate", FakeSequentialRequests),
                ("fake timeout restarts once", FakeTimeoutRestart),
                ("fake backend exit restarts once", FakeExitRestart),
                ("fake malformed response is protocol-error and recovers", FakeMalformedResponse),
                ("fake save refusal is structured", FakeSaveRefusal),
                ("fake graceful shutdown exits child", FakeGracefulShutdown),
                ("real backend round trip and non-mutation", RealBackendRoundTrip),
                ("real backend validate and convert are read-only", RealBackendValidateConvert),
                ("view model loads sets, monitors, items, warnings", ViewModelLoadAndSelection),
                ("view model rejects revision mismatch", ViewModelRevisionMismatch),
                ("view model recovers from malformed config", ViewModelMalformedConfigRecovery),
                ("view model displays ambiguous and unreachable placement", ViewModelPlacementStates),
                ("draft creation binds revision, topology, and full document", DraftCreation),
                ("draft preserves unknown properties", DraftUnknownProperties),
                ("draft absolute and profile mutations stay scoped", DraftScopedMutations),
                ("draft mutation guard rejects structural changes", DraftRejectsUnsupported),
                ("draft negative coordinates and invalid dimensions", DraftGeometryValidation),
                ("draft revert and discard reset dirty state", DraftRevertDiscard),
                ("draft dirty state returns clean when values are restored", DraftDirtyRoundTrip),
                ("draft mode conversion is coherent", DraftModeConversion),
                ("view model converts absolute to relative and back", ViewModelModeConversion),
                ("rect edit math moves and resizes positively", RectEditMathTests),
                ("view model numeric edit updates draft and validates", ViewModelNumericEdit),
                ("view model relative edit uses backend convert", ViewModelRelativeEdit),
                ("view model convert refusal preserves draft", ViewModelConvertFailure),
                ("view model revision conflict preserves draft", ViewModelRevisionConflict),
                ("view model topology conflict blocks relative commit", ViewModelTopologyConflict),
                ("view model discard clears dirty state", ViewModelDiscard),
                ("view model handles 200 synthetic items", ViewModelLargeSet),
                ("canvas transform preserves negative origins", CanvasNegativeOrigin),
                ("canvas handles negative and empty draft data", CanvasDataHandling),
                ("production GUI source keeps draft-only boundaries", SourceBoundaries)
            };

            foreach (var test in tests)
            {
                try
                {
                    test.Body().GetAwaiter().GetResult();
                    _passed++;
                    Console.WriteLine($"PASS {test.Name}");
                }
                catch (Exception ex)
                {
                    _failed++;
                    Console.WriteLine($"FAIL {test.Name}: {ex}");
                }
            }
        }
        catch (Exception ex)
        {
            _failed++;
            Console.WriteLine($"FAIL harness setup: {ex}");
        }
        finally
        {
            try
            {
                if (Directory.Exists(_tempRoot))
                {
                    Directory.Delete(_tempRoot, recursive: true);
                }
            }
            catch
            {
            }
        }

        Console.WriteLine($"editor-gui tests: {_passed} passed, {_failed} failed");
        return _failed == 0 ? 0 : 1;
    }

    private static async Task FakeHandshake()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        var hello = await client.ConnectAsync();
        Equal("devws-editor/1", hello.Protocol, "protocol");
        True(hello.SupportedOps.Contains("inspect"), "inspect advertised");
        True(hello.SupportedOps.Contains("validate"), "validate advertised");
        True(hello.SupportedOps.Contains("convert"), "convert advertised");
        True(hello.ReadOnly, "read-only");
        True(client.ProcessId is > 0, "backend pid available");
        client.Dispose();
        True(client.HasExited, "backend exited after dispose");
    }

    private static async Task FakeMissingDraftOps()
    {
        var scenario = NormalScenario();
        scenario["hello"] = Hello(
            supportedOps: new[] { "hello", "inspect", "read-config", "project", "shutdown" });
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        var error = await CatchAsync(() => client.ConnectAsync());
        Equal("unsupported-operation", error.Code, "missing validate/convert refusal");
    }

    private static async Task FakeUnsupportedProtocol()
    {
        var scenario = NormalScenario();
        scenario["hello"] = Hello(protocol: "devws-editor/2");
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        var error = await CatchAsync(() => client.ConnectAsync());
        Equal("protocol-version-unsupported", error.Code, "protocol refusal");
    }

    private static async Task FakeSequentialRequests()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        await client.ConnectAsync();

        var inspect = await client.SendAsync("inspect");
        Equal("user", ReadNestedString(inspect.Result, "config", "source"), "inspect source");

        var read = await client.SendAsync(
            "read-config",
            new Dictionary<string, object?> { ["expectedSha256"] = Sha });
        Equal(Sha, ReadNestedString(read.Result, "", "sha256"), "read hash");

        var project = await client.SendAsync("project");
        Equal(Sha, JsonText.String(project.Result, "configRevision"), "project revision");
        Equal("main", JsonText.String(project.Result, "setId"), "project set");
    }

    private static async Task FakeTimeoutRestart()
    {
        var scenario = NormalScenario();
        scenario["mode"] = "timeout-once";
        scenario["marker"] = NewPath("timeout.marker");
        using var client = CreateFakeClient(scenario, TimeSpan.FromMilliseconds(900));
        await client.ConnectAsync();
        var response = await client.SendAsync("inspect");
        Equal("user", ReadNestedString(response.Result, "config", "source"), "restarted inspect result");
    }

    private static async Task FakeExitRestart()
    {
        var scenario = NormalScenario();
        scenario["mode"] = "exit-once";
        scenario["marker"] = NewPath("exit.marker");
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        await client.ConnectAsync();
        var response = await client.SendAsync("inspect");
        Equal("user", ReadNestedString(response.Result, "config", "source"), "restarted inspect result");
    }

    private static async Task FakeMalformedResponse()
    {
        var scenario = NormalScenario();
        scenario["mode"] = "malformed-once";
        scenario["marker"] = NewPath("malformed.marker");
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        await client.ConnectAsync();

        var first = await CatchAsync(() => client.SendAsync("inspect"));
        Equal("protocol-error", first.Code, "malformed response code");

        var second = await client.SendAsync("inspect");
        Equal("user", ReadNestedString(second.Result, "config", "source"), "recovered inspect");
    }

    private static async Task FakeSaveRefusal()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        await client.ConnectAsync();
        var error = await CatchAsync(() => client.SendAsync("save"));
        Equal("unsupported-operation", error.Code, "save refusal");
        var inspect = await client.SendAsync("inspect");
        True(inspect.Result.ValueKind == JsonValueKind.Object, "backend still usable");
    }

    private static async Task FakeGracefulShutdown()
    {
        var scenario = NormalScenario();
        var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        await client.ConnectAsync();
        var response = await client.SendAsync("shutdown");
        True(JsonText.Bool(response.Result, "stopped"), "shutdown result");
        client.Dispose();
        True(client.HasExited, "backend exited");
    }

    private static async Task RealBackendRoundTrip()
    {
        var configPath = NewPath("real-config.json");
        var config = RealConfig();
        File.WriteAllText(configPath, JsonSerializer.Serialize(config), new System.Text.UTF8Encoding(false));
        var before = Hash(configPath);
        var canonical = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "devws", "workspace.json")
        }.FirstOrDefault(File.Exists);
        var canonicalBefore = canonical is null ? null : Hash(canonical);
        var initialFiles = Directory.GetFiles(Path.GetDirectoryName(configPath)!).OrderBy(path => path).ToArray();

        var options = new BackendLaunchOptions(
            _pwsh,
            _realBackend,
            configPath,
            TimeSpan.FromSeconds(20));
        using var client = new BackendClient(options);
        await client.ConnectAsync();

        var inspect = await client.SendAsync("inspect");
        Equal("env", ReadNestedString(inspect.Result, "config", "source"), "inspect source");
        Equal(Path.GetFullPath(configPath), ReadNestedString(inspect.Result, "config", "effectivePath"), "inspect effective path");
        Equal(before, ReadNestedString(inspect.Result, "config", "sha256"), "inspect hash");
        Equal("main", ReadNestedString(inspect.Result, "config", "defaultSet"), "inspect default set");

        var read = await client.SendAsync(
            "read-config",
            new Dictionary<string, object?> { ["expectedSha256"] = before });
        Equal(before, JsonText.String(read.Result, "sha256"), "read hash");
        Equal(2, ReadArrayLength(JsonText.Object(read.Result, "document"), "sets"), "document set count");

        var project = await client.SendAsync("project");
        Equal(before, JsonText.String(project.Result, "configRevision"), "project revision");
        Equal("main", JsonText.String(project.Result, "setId"), "project set");
        var projectSet = JsonText.Object(project.Result, "set");
        Equal(2, ReadArrayLength(projectSet, "items"), "project item count");

        var saveError = await CatchAsync(() => client.SendAsync("save"));
        Equal("unsupported-operation", saveError.Code, "save refusal");

        client.Dispose();
        Equal(before, Hash(configPath), "real config unchanged");
        if (canonical is not null && canonicalBefore is not null)
        {
            Equal(canonicalBefore, Hash(canonical), "canonical config unchanged");
        }

        var afterFiles = Directory.GetFiles(Path.GetDirectoryName(configPath)!).OrderBy(path => path).ToArray();
        Equal(string.Join("|", initialFiles), string.Join("|", afterFiles), "no unexpected config files");
        True(client.HasExited, "real backend exited");
    }

    private static async Task DraftCreation()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        True(!vm.HasError, "draft load error");
        var draft = vm.Draft;
        True(draft is not null, "draft exists");
        Equal(Sha, draft!.BaseSha256, "draft base revision");
        Equal(Fingerprint, draft.BaseTopologyFingerprint, "draft base topology");
        Equal("main", draft.SetId, "draft selected set");
        Equal(new RectInfo(100, 100, 600, 500), draft.GetAbsoluteLayout("profile"), "draft absolute layout");
        Equal("relative", draft.GetLayoutMode("relative"), "draft relative mode");
        Equal(new RectInfo(100, 100, 600, 500), draft.GetProfileEntry("profile", "docked"), "draft profile entry");
        True(!draft.IsDirty, "new draft is clean");
        True(!vm.IsDraftDirty, "view model reports clean draft");
        Equal(0, draft.ValidateMutationScope().Count, "new draft passes mutation guard");
    }

    private static async Task DraftUnknownProperties()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        var draft = vm.Draft!;
        draft.SetAbsoluteLayout("profile", new RectInfo(-5, 7, 640, 480));
        var root = draft.CreateDraftSnapshot();
        Equal(true, root["x-unknown"]!["keep"]!.GetValue<bool>(), "top-level unknown preserved");
        Equal(3, ((JsonArray)root["x-unknown"]!["nested"]!).Count, "nested unknown preserved");
        var mainSet = (JsonObject)((JsonArray)root["sets"]!)[0]!;
        var windows = (JsonArray)mainSet["windows"]!;
        var profile = (JsonObject)windows[0]!;
        Equal("keep", profile["x-item-note"]!.GetValue<string>(), "item unknown preserved");
        Equal(@"C:\Windows", profile["path"]!.GetValue<string>(), "item path preserved");
        Equal(0, draft.ValidateMutationScope().Count, "geometry-only mutation authorized");
        True(draft.IsDirty, "geometry mutation marks dirty");
    }

    private static async Task DraftScopedMutations()
    {
        var scenario = NormalScenario();
        var readConfig = (Dictionary<string, object?>)scenario["readConfig"]!;
        var document = (Dictionary<string, object?>)readConfig["document"]!;
        var sets = (object?[])document["sets"]!;
        var secondary = (Dictionary<string, object?>)sets[1]!;
        secondary["windows"] = new object?[]
        {
            new Dictionary<string, object?>
            {
                ["id"] = "other-only",
                ["type"] = "terminal",
                ["layout"] = Rect(0, 0, 10, 10)
            }
        };

        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        var draft = vm.Draft!;
        var relativeBefore = draft.GetRelativeRect("relative");
        draft.SetAbsoluteLayout("fallback", new RectInfo(-3000, -120, 700, 500));
        Equal(new RectInfo(-3000, -120, 700, 500), draft.GetAbsoluteLayout("fallback"), "negative absolute mutation");
        Equal(relativeBefore, draft.GetRelativeRect("relative"), "other item relative geometry unchanged");
        Equal(0, draft.ValidateMutationScope().Count, "absolute mutation authorized");

        draft.SetProfileEntry("profile", "docked", new RectInfo(130, 140, 650, 550));
        Equal(new RectInfo(130, 140, 650, 550), draft.GetProfileEntry("profile", "docked"), "profile entry mutation");
        Equal(new RectInfo(100, 100, 600, 500), draft.GetAbsoluteLayout("profile"), "profile edit leaves fallback unchanged");
        Equal(0, draft.ValidateMutationScope().Count, "profile mutation authorized");

        var missingProfileEntry = CatchEditor(() => draft.SetProfileEntry("relative", "docked", new RectInfo(1, 2, 3, 4)));
        Equal("unsupported-mutation", missingProfileEntry.Code, "profile entry creation refused");

        var crossSet = CatchEditor(() => draft.SetAbsoluteLayout("other-only", new RectInfo(1, 2, 3, 4)));
        Equal("unsupported-mutation", crossSet.Code, "cross-set mutation refused");
        True(draft.DirtyItemIds().Contains("fallback"), "fallback dirty");
        True(draft.DirtyItemIds().Contains("profile"), "profile dirty");
        True(!draft.DirtyItemIds().Contains("other-only"), "other set stays clean");
    }

    private static async Task DraftRejectsUnsupported()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        var baseline = vm.Draft!.CreateDraftSnapshot();
        var allowed = (JsonObject)baseline.DeepClone();
        var allowedWindows = (JsonArray)((JsonObject)((JsonArray)allowed["sets"]!)[0]!)["windows"]!;
        ((JsonObject)allowedWindows[0]!)["layout"]!["x"] = 101;
        Equal(0, DraftDocument.FindViolations(baseline, allowed, "main").Count, "geometry change is authorized");

        var bindingChange = (JsonObject)baseline.DeepClone();
        bindingChange["bindings"] = JsonNode.Parse("[{\"hotkey\":\"ctrl+1\",\"setId\":\"main\"}]");
        True(DraftDocument.FindViolations(baseline, bindingChange, "main").Any(path => path.Contains("/bindings", StringComparison.Ordinal)), "binding change refused");

        var commandChange = (JsonObject)baseline.DeepClone();
        var commandWindows = (JsonArray)((JsonObject)((JsonArray)commandChange["sets"]!)[0]!)["windows"]!;
        ((JsonObject)commandWindows[0]!)["path"] = @"C:\Evil";
        True(DraftDocument.FindViolations(baseline, commandChange, "main").Any(path => path.Contains("/path", StringComparison.Ordinal)), "path change refused");

        var tabChange = (JsonObject)baseline.DeepClone();
        var tabWindows = (JsonArray)((JsonObject)((JsonArray)tabChange["sets"]!)[0]!)["windows"]!;
        ((JsonObject)((JsonObject)tabWindows[0]!)["tabs"]![0]!)["args"] = JsonNode.Parse("[\"/c\",\"calc\"]");
        True(DraftDocument.FindViolations(baseline, tabChange, "main").Any(path => path.Contains("/tabs", StringComparison.Ordinal)), "tab argument change refused");

        var idChange = (JsonObject)baseline.DeepClone();
        var idWindows = (JsonArray)((JsonObject)((JsonArray)idChange["sets"]!)[0]!)["windows"]!;
        ((JsonObject)idWindows[0]!)["id"] = "renamed";
        True(DraftDocument.FindViolations(baseline, idChange, "main").Any(path => path.Contains("/id", StringComparison.Ordinal)), "item identity change refused");

        var profileChange = (JsonObject)baseline.DeepClone();
        var profileSet = (JsonObject)((JsonArray)profileChange["sets"]!)[0]!;
        var profiles = (JsonArray)profileSet["layoutProfiles"]!;
        ((JsonObject)profiles[0]!)["layouts"]!.AsObject()["new-entry"] = JsonNode.Parse("{\"x\":1,\"y\":2,\"w\":3,\"h\":4}");
        True(DraftDocument.FindViolations(baseline, profileChange, "main").Any(path => path.Contains("/layoutProfiles/", StringComparison.Ordinal)), "profile entry creation refused");

        var crossSetChange = (JsonObject)baseline.DeepClone();
        var crossSet = (JsonObject)((JsonArray)crossSetChange["sets"]!)[1]!;
        crossSet["windows"] = JsonNode.Parse("[{\"id\":\"x\",\"type\":\"terminal\",\"layout\":{\"x\":0,\"y\":0,\"w\":1,\"h\":1}}]");
        True(DraftDocument.FindViolations(baseline, crossSetChange, "main").Count > 0, "cross-set structural change refused");

        var unknownChange = (JsonObject)baseline.DeepClone();
        unknownChange["x-new"] = true;
        True(DraftDocument.FindViolations(baseline, unknownChange, "main").Any(path => path.Contains("/x-new", StringComparison.Ordinal)), "new unknown property refused");

        var modeOnly = (JsonObject)baseline.DeepClone();
        var modeWindows = (JsonArray)((JsonObject)((JsonArray)modeOnly["sets"]!)[0]!)["windows"]!;
        ((JsonObject)modeWindows[0]!)["layoutMode"] = "relative";
        True(DraftDocument.FindViolations(baseline, modeOnly, "main").Any(path => path.Contains("mode", StringComparison.OrdinalIgnoreCase)), "mode-only change refused");
    }

    private static async Task DraftGeometryValidation()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        var draft = vm.Draft!;
        draft.SetAbsoluteLayout("fallback", new RectInfo(-2500, -1200, 400, 300));
        Equal(new RectInfo(-2500, -1200, 400, 300), draft.GetAbsoluteLayout("fallback"), "negative draft coordinates");
        var invalid = CatchEditor(() => draft.SetAbsoluteLayout("fallback", new RectInfo(0, 0, 0, 100)));
        Equal("invalid-rect", invalid.Code, "zero width refused");
        Equal(new RectInfo(-2500, -1200, 400, 300), draft.GetAbsoluteLayout("fallback"), "invalid mutation left draft unchanged");

        var invalidHeight = CatchEditor(() => draft.SetAbsoluteLayout("fallback", new RectInfo(0, 0, 100, -1)));
        Equal("invalid-rect", invalidHeight.Code, "negative height refused");
    }

    private static async Task DraftRevertDiscard()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        var draft = vm.Draft!;
        draft.SetAbsoluteLayout("fallback", new RectInfo(1, 2, 3, 4));
        draft.SetAbsoluteLayout("profile", new RectInfo(5, 6, 7, 8));
        Equal(2, draft.DirtyItemIds().Count, "two dirty items");
        draft.RevertItem("fallback");
        Equal(1, draft.DirtyItemIds().Count, "one dirty item after revert");
        Equal(new RectInfo(-1920, 0, 960, 1080), draft.GetAbsoluteLayout("fallback"), "reverted layout restored");
        draft.DiscardAll();
        True(!draft.IsDirty, "discard clears dirty state");
        Equal(0, draft.ValidateMutationScope().Count, "discard leaves an authorized document");
        Equal(new RectInfo(100, 100, 600, 500), draft.GetAbsoluteLayout("profile"), "discard restores all geometry");
    }

    private static async Task DraftDirtyRoundTrip()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        var draft = vm.Draft!;
        draft.SetAbsoluteLayout("fallback", new RectInfo(-1920, 0, 960, 1080));
        True(!draft.IsDirty, "writing the baseline value stays clean");
        draft.SetAbsoluteLayout("fallback", new RectInfo(1, 2, 3, 4));
        True(draft.IsDirty, "different value is dirty");
        draft.SetAbsoluteLayout("fallback", new RectInfo(-1920, 0, 960, 1080));
        True(!draft.IsDirty, "restoring the exact value clears dirty state");
    }

    private static async Task ViewModelModeConversion()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        var fallback = vm.Items.First(item => item.Item.ItemId == "fallback");
        vm.SelectItem(fallback);
        vm.SelectScope(vm.GeometryScopes.First(scope => scope.Kind == GeometryScopeKind.AbsoluteFallback));
        True(vm.CanConvertToRelative, "absolute item can convert to relative");
        True(!vm.CanConvertToAbsolute, "absolute item cannot convert to absolute");

        await vm.ConvertToRelativeAsync();
        Equal("relative", vm.Draft!.GetLayoutMode("fallback"), "view model relative conversion");
        Equal("path:TEST/RIGHT", vm.Draft.GetRelativeAnchor("fallback")?.Identity, "converted anchor");
        True(vm.IsDraftDirty, "mode conversion marks dirty");
        True(vm.CanConvertToAbsolute, "relative item can convert back");
        True(!vm.CanConvertToRelative, "relative item cannot convert to relative");
        Equal(GeometryScopeKind.Relative, vm.SelectedScope?.Kind, "relative scope selected after conversion");
        Equal(0, vm.Draft.ValidateMutationScope().Count, "view model relative conversion is authorized");

        await vm.ConvertToAbsoluteAsync();
        Equal("absolute", vm.Draft.GetLayoutMode("fallback"), "view model absolute conversion");
        True(vm.Draft.GetRelativeAnchor("fallback") is null, "absolute conversion removed relative");
        Equal(new RectInfo(0, 0, 1280, 1400), vm.Draft.GetAbsoluteLayout("fallback"), "absolute conversion used round-trip rect");
        Equal(GeometryScopeKind.AbsoluteFallback, vm.SelectedScope?.Kind, "absolute scope selected after conversion");
        Equal(0, vm.Draft.ValidateMutationScope().Count, "view model absolute conversion is authorized");
    }

    private static async Task DraftModeConversion()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        var draft = vm.Draft!;
        draft.SetRelativeMode("fallback", "path:TEST/LEFT", null, "monitor", new RelativeRectValues(0.1, 0.2, 0.3, 0.4));
        Equal("relative", draft.GetLayoutMode("fallback"), "relative mode written");
        Equal("path:TEST/LEFT", draft.GetRelativeAnchor("fallback")?.Identity, "relative anchor written");
        Equal(0, draft.ValidateMutationScope().Count, "coherent relative conversion authorized");

        draft.SetAbsoluteMode("fallback", new RectInfo(9, 8, 7, 6));
        Equal("absolute", draft.GetLayoutMode("fallback"), "absolute mode restored");
        True(draft.GetRelativeAnchor("fallback") is null, "relative object removed");
        Equal(new RectInfo(9, 8, 7, 6), draft.GetAbsoluteLayout("fallback"), "absolute layout written");
        Equal(0, draft.ValidateMutationScope().Count, "coherent absolute conversion authorized");
    }

    private static Task RectEditMathTests()
    {
        var moved = RectEditMath.Move(new RectInfo(-100, -50, 200, 100), 10, -20);
        Equal(new RectInfo(-90, -70, 200, 100), moved, "move preserves size and negative origins");

        var northwest = RectEditMath.Resize(new RectInfo(-100, -50, 200, 100), ResizeHandle.NorthWest, 500, 500);
        Equal(1, northwest.W, "northwest resize clamps width");
        Equal(1, northwest.H, "northwest resize clamps height");

        var southeast = RectEditMath.Resize(new RectInfo(-100, -50, 200, 100), ResizeHandle.SouthEast, -500, -500);
        Equal(1, southeast.W, "southeast resize clamps width");
        Equal(1, southeast.H, "southeast resize clamps height");

        var east = RectEditMath.Resize(new RectInfo(10, 20, 100, 80), ResizeHandle.East, 25, 0);
        Equal(new RectInfo(10, 20, 125, 80), east, "east resize changes width only");

        var screen = new Rect(0, 0, 200, 100);
        Equal(ResizeHandle.NorthWest, RectEditMath.HandleAt(screen, new Point(2, 3)), "northwest handle");
        Equal(ResizeHandle.SouthEast, RectEditMath.HandleAt(screen, new Point(198, 97)), "southeast handle");
        Equal(ResizeHandle.East, RectEditMath.HandleAt(screen, new Point(200, 50)), "east handle");
        Equal(ResizeHandle.None, RectEditMath.HandleAt(screen, new Point(120, 70)), "interior is not a handle");
        return Task.CompletedTask;
    }

    private static async Task ViewModelNumericEdit()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        var profile = vm.Items.First(item => item.Item.ItemId == "profile");
        vm.SelectItem(profile);
        var absoluteScope = vm.GeometryScopes.First(scope => scope.Kind == GeometryScopeKind.AbsoluteFallback);
        vm.SelectScope(absoluteScope);

        var applied = await vm.ApplyGeometryAsync("-40", "-25", "640", "480");
        True(applied, "numeric edit applied");
        Equal(new RectInfo(-40, -25, 640, 480), vm.Draft!.GetAbsoluteLayout("profile"), "draft absolute value");
        True(vm.IsDraftDirty, "dirty after numeric edit");
        True(vm.IsDraftValid, "valid after numeric edit");
        True(vm.DraftPreviewRects.ContainsKey("profile"), "preview rect recorded");
        True(vm.DetailRows.Any(row => row.Label == "Proposed draft" && row.Value.Contains("640x480", StringComparison.Ordinal)), "proposed draft detail");
        True(vm.LastValidateMs >= 0, "validate timing recorded");

        var invalid = await vm.ApplyGeometryAsync("abc", "0", "100", "100");
        True(!invalid, "malformed X refused");
        True(vm.EditErrorText.Contains("integer", StringComparison.OrdinalIgnoreCase), "malformed input explanation");
        Equal(new RectInfo(-40, -25, 640, 480), vm.Draft.GetAbsoluteLayout("profile"), "malformed input left draft unchanged");

        var zero = await vm.ApplyGeometryAsync("0", "0", "0", "100");
        True(!zero, "zero width refused");
        True(vm.EditErrorText.Contains("greater than 0", StringComparison.Ordinal), "zero width explanation");

        var profileScope = vm.GeometryScopes.First(scope => scope.Kind == GeometryScopeKind.ProfileEntry);
        vm.SelectScope(profileScope);
        var profileApplied = await vm.ApplyGeometryAsync("110", "120", "610", "510");
        True(profileApplied, "profile entry edit applied");
        Equal(new RectInfo(110, 120, 610, 510), vm.Draft.GetProfileEntry("profile", "docked"), "profile entry value");
        Equal(new RectInfo(-40, -25, 640, 480), vm.Draft.GetAbsoluteLayout("profile"), "profile edit did not touch fallback");
        Equal(0, vm.Draft.ValidateMutationScope().Count, "view-model edits stay authorized");
    }

    private static async Task ViewModelRelativeEdit()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        var relative = vm.Items.First(item => item.Item.ItemId == "relative");
        vm.SelectItem(relative);
        Equal(GeometryScopeKind.Relative, vm.SelectedScope?.Kind, "relative scope is default");

        var applied = await vm.ApplyGeometryAsync("25", "0", "900", "700");
        True(applied, "relative edit applied");
        Equal("relative", vm.Draft!.GetLayoutMode("relative"), "relative mode preserved");
        var relativeRect = vm.Draft.GetRelativeRect("relative");
        True(relativeRect is not null, "relative rect stored");
        Close(0.5, relativeRect!.W, 0.000001, "backend normalized width used");
        Equal(new RectInfo(20, 20, 500, 400), vm.Draft.GetAbsoluteLayout("relative"), "relative edit left fallback unchanged");
        Equal(new RectInfo(0, 0, 1280, 1400), vm.DraftPreviewRects["relative"], "convert round-trip preview used");
        True(vm.LastConvertMs >= 0, "convert timing recorded");
        True(vm.IsDraftValid, "relative edit validated");
    }

    private static async Task ViewModelConvertFailure()
    {
        var scenarioPath = NewPath("convert-failure-scenario.json");
        var scenario = NormalScenario();
        scenario["convertError"] = Error("topology-changed", "The monitor topology changed.");
        WriteScenario(scenarioPath, scenario);

        using var client = CreateFakeClient(scenarioPath, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        vm.SelectItem(vm.Items.First(item => item.Item.ItemId == "relative"));
        var applied = await vm.ApplyGeometryAsync("25", "0", "900", "700");
        True(!applied, "convert refusal reported");
        True(!vm.IsDraftDirty, "refused relative edit left draft clean");
        True(vm.HasDraftConflict, "convert refusal becomes a conflict");
        True(vm.EditErrorText.Contains("topology-changed", StringComparison.Ordinal), "structured convert error visible");
    }

    private static async Task ViewModelRevisionConflict()
    {
        var scenarioPath = NewPath("revision-conflict-scenario.json");
        WriteScenario(scenarioPath, NormalScenario());

        using var client = CreateFakeClient(scenarioPath, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        var fallback = vm.Items.First(item => item.Item.ItemId == "fallback");
        vm.SelectItem(fallback);
        vm.SelectScope(vm.GeometryScopes.First(scope => scope.Kind == GeometryScopeKind.AbsoluteFallback));
        True(await vm.ApplyGeometryAsync("-1900", "10", "900", 1000.ToString()), "baseline edit applied");
        True(vm.IsDraftDirty, "draft dirty before conflict");

        var scenario = NormalScenario();
        var inspect = (Dictionary<string, object?>)scenario["inspect"]!;
        var config = (Dictionary<string, object?>)inspect["config"]!;
        config["sha256"] = new string('c', 64);
        WriteScenario(scenarioPath, scenario);

        await vm.RefreshAsync();
        True(vm.HasDraftConflict, "revision conflict detected");
        True(vm.DraftConflictText.StartsWith("external-change", StringComparison.Ordinal), "conflict text names external-change");
        True(vm.IsDraftDirty, "draft preserved across conflict");
        Equal(3, vm.Items.Count, "view preserved across conflict");
        Equal(new RectInfo(-1900, 10, 900, 1000), vm.Draft!.GetAbsoluteLayout("fallback"), "draft geometry preserved");

        var setBefore = vm.SelectedSet?.Info.Id;
        await vm.SelectSetAsync(vm.Sets.First(set => set.Info.Id == "secondary"));
        Equal(setBefore, vm.SelectedSet?.Info.Id, "dirty draft blocks set switch");
    }

    private static async Task ViewModelTopologyConflict()
    {
        var scenarioPath = NewPath("topology-conflict-scenario.json");
        WriteScenario(scenarioPath, NormalScenario());

        using var client = CreateFakeClient(scenarioPath, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        var relative = vm.Items.First(item => item.Item.ItemId == "relative");
        vm.SelectItem(relative);
        True(await vm.ApplyGeometryAsync("10", "0", "900", "700"), "first relative edit");
        var rectAfterFirst = vm.Draft!.GetRelativeRect("relative");

        var scenario = NormalScenario();
        var inspect = (Dictionary<string, object?>)scenario["inspect"]!;
        var topology = (Dictionary<string, object?>)inspect["topology"]!;
        topology["fingerprint"] = new string('A', 64);
        WriteScenario(scenarioPath, scenario);

        var applied = await vm.ApplyGeometryAsync("20", "0", "900", "700");
        True(!applied, "topology drift blocks relative commit");
        True(vm.HasDraftConflict, "topology conflict detected");
        True(vm.DraftConflictText.Contains("topology-changed", StringComparison.Ordinal), "conflict text names topology-changed");
        Equal(rectAfterFirst, vm.Draft.GetRelativeRect("relative"), "relative draft unchanged after refusal");
        True(!vm.CanEditSelectedScope, "relative scope blocked after topology drift");
    }

    private static async Task ViewModelDiscard()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        vm.SelectItem(vm.Items.First(item => item.Item.ItemId == "fallback"));
        vm.SelectScope(vm.GeometryScopes.First(scope => scope.Kind == GeometryScopeKind.AbsoluteFallback));
        True(await vm.ApplyGeometryAsync("-1800", "0", "900", "1000"), "discard setup edit");
        True(vm.IsDraftDirty, "discard setup dirty");

        await vm.DiscardDraftAsync(reload: false);
        True(!vm.IsDraftDirty, "discard clears dirty flag");
        Equal(0, vm.DraftPreviewRects.Count, "discard clears previews");
        Equal(new RectInfo(-1920, 0, 960, 1080), vm.Draft!.GetAbsoluteLayout("fallback"), "discard restores baseline");
        True(vm.DraftValidationText.Contains("not run", StringComparison.Ordinal), "discard clears validation state");

        True(await vm.ApplyGeometryAsync("-1800", "0", "900", "1000"), "reload discard setup edit");
        await vm.DiscardDraftAndReloadAsync();
        True(!vm.IsDraftDirty, "discard and reload clean");
        Equal(3, vm.Items.Count, "discard and reload keeps items");
    }

    private static async Task RealBackendValidateConvert()
    {
        var configPath = NewPath("real-validate-config.json");
        File.WriteAllText(
            configPath,
            JsonSerializer.Serialize(RealConfig()),
            new System.Text.UTF8Encoding(false));
        var before = Hash(configPath);
        var canonical = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".config",
            "devws",
            "workspace.json");
        var canonicalBefore = File.Exists(canonical) ? Hash(canonical) : null;

        var options = new BackendLaunchOptions(
            _pwsh,
            _realBackend,
            configPath,
            TimeSpan.FromSeconds(20));
        using var client = new BackendClient(options);
        var hello = await client.ConnectAsync();
        True(hello.SupportedOps.Contains("validate"), "real backend advertises validate");
        True(hello.SupportedOps.Contains("convert"), "real backend advertises convert");
        True(!hello.SupportedOps.Contains("save"), "real backend does not advertise save");
        True(!hello.SupportedOps.Contains("preview"), "real backend does not advertise preview");

        var inspectResponse = await client.SendAsync("inspect");
        var inspect = InspectInfo.Parse(inspectResponse.Result);
        var read = await client.SendAsync(
            "read-config",
            new Dictionary<string, object?> { ["expectedSha256"] = before });
        var document = JsonText.Object(read.Result, "document");

        var validResponse = await client.SendAsync(
            "validate",
            new Dictionary<string, object?> { ["draft"] = document });
        var valid = DraftValidationResult.Parse(validResponse.Result);
        True(valid.Valid, "real backend accepts the canonical draft");
        Equal(0, valid.Errors.Count, "valid draft has no errors");

        var invalidRoot = JsonNode.Parse(document.GetRawText())!.AsObject();
        var invalidWindows = (JsonArray)((JsonObject)((JsonArray)invalidRoot["sets"]!)[0]!)["windows"]!;
        ((JsonObject)invalidWindows[0]!)["layout"]!["w"] = -5;
        var invalidResponse = await client.SendAsync(
            "validate",
            new Dictionary<string, object?> { ["draft"] = invalidRoot });
        var invalid = DraftValidationResult.Parse(invalidResponse.Result);
        True(!invalid.Valid, "real backend rejects negative width");
        True(invalid.Errors.Count >= 1, "real backend returns canonical error");
        True(invalid.Errors[0].Message.Contains("layout.w", StringComparison.Ordinal), "canonical layout.w message");
        Equal("main", invalid.Errors[0].SetId, "canonical set context");
        Equal("demo-terminal", invalid.Errors[0].ItemId, "canonical item context");

        if (inspect.Topology.Available && inspect.Topology.Monitors.Count > 0)
        {
        var monitor = inspect.Topology.Monitors.FirstOrDefault(item => item.Primary)
                      ?? inspect.Topology.Monitors[0];
        var anchor = new Dictionary<string, object?> { ["identity"] = monitor.Identity };
        var rect = monitor.WorkRect;
        var convertResponse = await client.SendAsync(
            "convert",
            new Dictionary<string, object?>
            {
                ["rect"] = new Dictionary<string, object?>
                {
                    ["x"] = rect.X,
                    ["y"] = rect.Y,
                    ["w"] = rect.W,
                    ["h"] = rect.H
                },
                ["anchor"] = anchor,
                ["basis"] = "workArea",
                ["topologyFingerprint"] = inspect.Topology.Fingerprint
            });
        var converted = RelativeConversionResult.Parse(convertResponse.Result);
        Equal(monitor.Identity, converted.Identity, "convert anchor identity");
        Close(0.0, converted.Normalized.X, 0.000001, "convert normalized x");
        Close(0.0, converted.Normalized.Y, 0.000001, "convert normalized y");
        Close(1.0, converted.Normalized.W, 0.000001, "convert normalized w");
        Close(1.0, converted.Normalized.H, 0.000001, "convert normalized h");
        Equal(rect, converted.RoundTripRect, "convert round-trip rect");
        True(converted.Reachable, "convert reachability");
        Equal(converted.Identity, monitor.Identity, "monitor identity matches");

        var selectedResponse = await client.SendAsync(
            "convert",
            new Dictionary<string, object?>
            {
                ["rect"] = new Dictionary<string, object?>
                {
                    ["x"] = rect.X,
                    ["y"] = rect.Y,
                    ["w"] = rect.W,
                    ["h"] = rect.H
                },
                ["selectAnchor"] = true,
                ["basis"] = "workArea",
                ["topologyFingerprint"] = inspect.Topology.Fingerprint
            });
        var selected = RelativeConversionResult.Parse(selectedResponse.Result);
        Equal(monitor.Identity, selected.Identity, "selectAnchor chooses the visible monitor");

        var invalidRectError = await CatchAsync(() => client.SendAsync(
            "convert",
            new Dictionary<string, object?>
            {
                ["rect"] = new Dictionary<string, object?> { ["x"] = 0, ["y"] = 0, ["w"] = 0, ["h"] = 10 },
                ["anchor"] = anchor,
                ["basis"] = "workArea"
            }));
        Equal("invalid-rect", invalidRectError.Code, "convert invalid-rect refusal");

        var missingAnchorError = await CatchAsync(() => client.SendAsync(
            "convert",
            new Dictionary<string, object?>
            {
                ["rect"] = new Dictionary<string, object?>
                {
                    ["x"] = rect.X,
                    ["y"] = rect.Y,
                    ["w"] = rect.W,
                    ["h"] = rect.H
                },
                ["anchor"] = new Dictionary<string, object?> { ["identity"] = "path:DEVWS-TEST/MISSING" },
                ["basis"] = "workArea"
            }));
        Equal("anchor-missing", missingAnchorError.Code, "convert missing anchor refusal");

        var fingerprintError = await CatchAsync(() => client.SendAsync(
            "convert",
            new Dictionary<string, object?>
            {
                ["rect"] = new Dictionary<string, object?>
                {
                    ["x"] = rect.X,
                    ["y"] = rect.Y,
                    ["w"] = rect.W,
                    ["h"] = rect.H
                },
                ["anchor"] = anchor,
                ["basis"] = "workArea",
                ["topologyFingerprint"] = new string('A', 64)
            }));
        Equal("topology-changed", fingerprintError.Code, "convert fingerprint refusal");
        }
        else
        {
            Console.WriteLine("INFO convert tests skipped: host topology unavailable");
        }

        var saveError = await CatchAsync(() => client.SendAsync("save"));
        Equal("unsupported-operation", saveError.Code, "save still refused");

        client.Dispose();
        Equal(before, Hash(configPath), "validate/convert left the real config unchanged");
        if (canonicalBefore is not null)
        {
            Equal(canonicalBefore, Hash(canonical), "validate/convert left the canonical config unchanged");
        }
        True(client.HasExited, "validate/convert backend exited");
    }


    private static async Task ViewModelLoadAndSelection()
    {
        var scenario = NormalScenario();
        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");

        await vm.LoadAsync();
        True(!vm.HasError, "no load error");
        Equal(2, vm.Sets.Count, "set count");
        Equal("main", vm.SelectedSet?.Info.Id, "default set");
        Equal(2, vm.Monitors.Count, "monitor count");
        Equal(3, vm.Items.Count, "item count");
        True(vm.Warnings.Count >= 1, "warning count");
        Equal<int?>(-1920, vm.VirtualScreenRect?.X, "negative virtual origin");
        Equal(-1920, vm.Items.First(item => item.Item.ItemId == "fallback").Item.Rect.X, "negative item origin");
        True(vm.DetailRows.Any(row => row.Label == "Placement source"), "details include source");
        True(vm.DetailRows.Any(row => row.Label == "Fallback used"), "details include fallback");
        Equal("profile", vm.DetailRows.First(row => row.Label == "Placement source").Value, "profile source detail");
        True(vm.DetailRows.First(row => row.Label == "Set profile").Value.Contains("matched", StringComparison.Ordinal), "set profile match detail");
        True(vm.DetailRows.First(row => row.Label == "Profile").Value.Contains("docked", StringComparison.Ordinal), "profile id detail");

        var relative = vm.Items.First(item => item.Item.ItemId == "relative");
        vm.SelectItem(relative);
        Equal("relative", vm.DetailRows.First(row => row.Label == "Placement source").Value, "relative source detail");
        True(vm.DetailRows.First(row => row.Label == "Relative anchor").Value.Contains("resolved", StringComparison.Ordinal), "relative status detail");
        True(vm.DetailRows.First(row => row.Label == "Relative rect").Value.Contains("1280x1400", StringComparison.Ordinal), "relative rect detail");

        var fallback = vm.Items.First(item => item.Item.ItemId == "fallback");
        vm.SelectItem(fallback);
        True(vm.ItemWarnings.Count >= 1, "selected item warning");

        var secondary = vm.Sets.First(set => set.Info.Id == "secondary");
        await vm.SelectSetAsync(secondary);
        Equal(0, vm.Items.Count, "empty set item count");
        True(vm.SelectedItem is null, "empty set selection");
        True(vm.DetailRows.Any(row => row.Value.Contains("No item selected", StringComparison.Ordinal)), "empty details");

        await vm.SelectSetAsync(vm.Sets.First(set => set.Info.Id == "main"));
        await vm.RefreshAsync();
        Equal(3, vm.Items.Count, "refresh item count");
        vm.Dispose();
        True(vm.BackendExited, "view model backend exited");
    }

    private static async Task ViewModelRevisionMismatch()
    {
        var scenario = NormalScenario();
        var projects = (Dictionary<string, object?>)scenario["projects"]!;
        var main = (Dictionary<string, object?>)projects["main"]!;
        main["configRevision"] = new string('b', 64);

        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        True(vm.HasError, "revision mismatch error");
        Equal("external-change", vm.ErrorCode, "revision mismatch code");
        Equal(0, vm.Items.Count, "no mixed items");
        True(vm.RequiresRefresh, "refresh required");
    }

    private static async Task ViewModelMalformedConfigRecovery()
    {
        var scenarioPath = NewPath("recover-scenario.json");
        var scenario = NormalScenario();
        scenario["inspectError"] = Error("config-invalid", "Invalid workspace config.");
        WriteScenario(scenarioPath, scenario);

        using var client = CreateFakeClient(scenarioPath, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();
        True(vm.HasError, "malformed config error");
        Equal("config-invalid", vm.ErrorCode, "malformed config code");
        Equal(0, vm.Items.Count, "no items after malformed config");

        WriteScenario(scenarioPath, NormalScenario());
        await vm.RefreshAsync();
        True(!vm.HasError, "recovered after refresh");
        Equal(3, vm.Items.Count, "recovered item count");
    }

    private static async Task ViewModelPlacementStates()
    {
        var scenario = NormalScenario();
        var projects = (Dictionary<string, object?>)scenario["projects"]!;
        var main = (Dictionary<string, object?>)projects["main"]!;
        var set = (Dictionary<string, object?>)main["set"]!;
        set["items"] = new object?[]
        {
            Item(
                "ambiguous",
                "terminal",
                "fallback",
                Rect(10, 10, 400, 300),
                "anchor-ambiguous",
                "relative",
                relativeStatus: "anchor-ambiguous",
                relativeReason: "duplicate-identity",
                relativeMessage: "Multiple monitors share the relative identity.",
                fallbackUsed: true,
                fallbackReachable: true,
                applyGeometry: false),
            Item(
                "unreachable",
                "terminal",
                "fallback",
                Rect(500, 10, 400, 300),
                "fallback-unreachable",
                "absolute",
                fallbackReachable: false,
                applyGeometry: false,
                reachable: false)
        };
        scenario["warnings"] = new object?[]
        {
            Warning(
                "anchor-ambiguous|main|ambiguous|path:TEST/DUP",
                "anchor-ambiguous",
                "Multiple monitors share the relative identity.",
                "main",
                "ambiguous",
                "path:TEST/DUP"),
            Warning(
                "fallback-unreachable|main|unreachable|",
                "fallback-unreachable",
                "The absolute fallback is not reachable.",
                "main",
                "unreachable",
                "")
        };

        var readConfig = (Dictionary<string, object?>)scenario["readConfig"]!;
        var document = (Dictionary<string, object?>)readConfig["document"]!;
        var documentSets = (object?[])document["sets"]!;
        var documentMain = (Dictionary<string, object?>)documentSets[0]!;
        documentMain["windows"] = new object?[]
        {
            new Dictionary<string, object?>
            {
                ["id"] = "ambiguous",
                ["type"] = "terminal",
                ["layout"] = Rect(10, 10, 400, 300),
                ["layoutMode"] = "relative",
                ["layoutRelative"] = new Dictionary<string, object?>
                {
                    ["monitor"] = new Dictionary<string, object?> { ["identity"] = "path:TEST/DUP" },
                    ["basis"] = "workArea",
                    ["rect"] = new Dictionary<string, object?>
                    {
                        ["x"] = 0.0,
                        ["y"] = 0.0,
                        ["w"] = 0.4,
                        ["h"] = 0.4
                    }
                }
            },
            new Dictionary<string, object?>
            {
                ["id"] = "unreachable",
                ["type"] = "terminal",
                ["layout"] = Rect(500, 10, 400, 300)
            }
        };
        documentMain.Remove("layoutProfiles");

        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(2));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        await vm.LoadAsync();

        vm.SelectItem(vm.Items.First(item => item.Item.ItemId == "ambiguous"));
        True(vm.DetailRows.First(row => row.Label == "Relative anchor").Value.Contains("duplicate-identity", StringComparison.Ordinal), "ambiguous reason detail");
        True(vm.DetailRows.First(row => row.Label == "Apply geometry").Value == "no", "ambiguous apply state");
        True(vm.ItemWarnings.Any(warning => warning.Info.Code == "anchor-ambiguous"), "ambiguous warning visible");

        vm.SelectItem(vm.Items.First(item => item.Item.ItemId == "unreachable"));
        Equal("fallback", vm.DetailRows.First(row => row.Label == "Placement source").Value, "unreachable source");
        Equal("no", vm.DetailRows.First(row => row.Label == "Apply geometry").Value, "unreachable apply state");
        Equal("no", vm.DetailRows.First(row => row.Label == "Reachable").Value, "unreachable reachability");
        True(vm.ItemWarnings.Any(warning => warning.Info.Code == "fallback-unreachable"), "unreachable warning visible");
    }

    private static Task SourceBoundaries()
    {
        var repoRoot = FindRepoRoot();
        var guiRoot = Path.Combine(repoRoot, "src", "editor", "gui");
        var source = string.Join(
            "\n",
            Directory.GetFiles(guiRoot, "*.cs", SearchOption.AllDirectories)
                .Concat(Directory.GetFiles(guiRoot, "*.xaml", SearchOption.AllDirectories))
                .Where(path => !path.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}", StringComparison.OrdinalIgnoreCase) &&
                               !path.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.OrdinalIgnoreCase))
                .Select(File.ReadAllText));

        foreach (var forbidden in new[]
        {
            "NamedPipeClientStream",
            "DevWorkspace-Elevated",
            "DevWS.Coordinator",
            "Invoke-DevWSWorkerRequest",
            "Start-Process",
            "SetWindowPos",
            "GetWindowRect",
            "Invoke-Expression",
            "System.Windows.Forms.Screen",
            "GetSystemMetrics",
            "GetDpiForMonitor",
            "-Command"
        })
        {
            True(!source.Contains(forbidden, StringComparison.Ordinal), $"forbidden source token: {forbidden}");
        }

        foreach (var forbiddenCall in new[]
        {
            "SendAsync(\"save\"",
            "SendAsync(\"preview\""
        })
        {
            True(!source.Contains(forbiddenCall, StringComparison.Ordinal), $"production GUI must not call {forbiddenCall}");
        }

        var canvasSource = File.ReadAllText(Path.Combine(guiRoot, "WorkspaceCanvas.cs"));
        True(!canvasSource.Contains("BackendClient", StringComparison.Ordinal), "canvas has no backend client");
        True(!canvasSource.Contains("SendAsync", StringComparison.Ordinal), "canvas never sends requests during drag/resize");
        True(source.Contains("\"validate\"", StringComparison.Ordinal), "session calls structural validate");
        True(source.Contains("\"convert\"", StringComparison.Ordinal), "session calls backend convert");

        True(source.Contains("ArgumentList.Add(\"-File\")", StringComparison.Ordinal), "backend uses -File");
        True(source.Contains("-NoProfile", StringComparison.Ordinal), "backend uses -NoProfile");
        True(source.Contains("-NonInteractive", StringComparison.Ordinal), "backend uses -NonInteractive");
        return Task.CompletedTask;
    }

    private static async Task ViewModelLargeSet()
    {
        var scenario = NormalScenario();
        var largeItems = Enumerable.Range(0, 200)
            .Select(index => Item(
                $"item-{index:000}",
                "terminal",
                "fallback",
                new Dictionary<string, object?> { ["x"] = index * 4, ["y"] = 0, ["w"] = 100, ["h"] = 80 },
                "fallback",
                "absolute"))
            .ToArray();
        var main = (Dictionary<string, object?>)((Dictionary<string, object?>)scenario["projects"]!)["main"]!;
        var set = (Dictionary<string, object?>)main["set"]!;
        set["items"] = largeItems;

        var readConfig = (Dictionary<string, object?>)scenario["readConfig"]!;
        var document = (Dictionary<string, object?>)readConfig["document"]!;
        var documentSets = (object?[])document["sets"]!;
        var documentMain = (Dictionary<string, object?>)documentSets[0]!;
        documentMain["windows"] = Enumerable.Range(0, 200)
            .Select(index => (object?)new Dictionary<string, object?>
            {
                ["id"] = $"item-{index:000}",
                ["type"] = "terminal",
                ["enabled"] = true,
                ["layout"] = new Dictionary<string, object?> { ["x"] = index * 4, ["y"] = 0, ["w"] = 100, ["h"] = 80 }
            })
            .ToArray();

        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(3));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        var watch = Stopwatch.StartNew();
        await vm.LoadAsync();
        watch.Stop();
        Equal(200, vm.Items.Count, "200 item count");
        vm.SelectItemAt(199);
        Equal<string?>("item-199", vm.SelectedItem?.Item.ItemId, "last item selection");
        True(vm.SelectedScope?.Kind == GeometryScopeKind.AbsoluteFallback, "large set defaults to absolute scope");
        True(await vm.ApplyGeometryAsync("900", "0", "100", "80"), "large set numeric edit");
        Equal(new RectInfo(900, 0, 100, 80), vm.Draft!.GetAbsoluteLayout("item-199"), "large set draft edit");
        Console.WriteLine($"INFO 200-item view-model load: {watch.Elapsed.TotalMilliseconds:0.0} ms, draft create: {vm.LastDraftCreateMs:0.0} ms, items update: {vm.LastItemsUpdateMs:0.0} ms, validate: {vm.LastValidateMs:0.0} ms");
    }

    private static Task CanvasNegativeOrigin()
    {
        var transform = new CanvasTransform();
        transform.Fit(new Rect(-1920, -1080, 4480, 2520), new Size(1000, 700), 20);
        Equal(-1920.0, transform.VirtualScreen.X, "negative X");
        Equal(-1080.0, transform.VirtualScreen.Y, "negative Y");
        True(transform.Zoom > 0, "positive zoom");

        var world = new Point(-1920, -1080);
        var screen = transform.WorldToScreen(world);
        var roundTrip = transform.ScreenToWorld(screen);
        Close(world.X, roundTrip.X, 0.0001, "X round trip");
        Close(world.Y, roundTrip.Y, 0.0001, "Y round trip");

        var before = transform.WorldToScreen(world);
        transform.ZoomAt(before, 1.5);
        var after = transform.WorldToScreen(world);
        Close(before.X, after.X, 0.0001, "zoom anchor X");
        Close(before.Y, after.Y, 0.0001, "zoom anchor Y");

        transform.PanBy(new Vector(10, -20));
        var panned = transform.WorldToScreen(world);
        Close(before.X + 10, panned.X, 0.0001, "pan X");
        Close(before.Y - 20, panned.Y, 0.0001, "pan Y");
        return Task.CompletedTask;
    }

    private static Task CanvasDataHandling()
    {
        var canvas = new WorkspaceCanvas();
        var monitors = new[]
        {
            new MonitorInfo
            {
                Identity = "path:TEST/LEFT",
                FriendlyName = "Left",
                MonitorRect = new RectInfo(-1920, 0, 1920, 1080),
                WorkRect = new RectInfo(-1920, 0, 1920, 1040)
            },
            new MonitorInfo
            {
                Identity = "path:TEST/RIGHT",
                FriendlyName = "Right",
                Primary = true,
                MonitorRect = new RectInfo(0, 0, 2560, 1440),
                WorkRect = new RectInfo(0, 0, 2560, 1400)
            }
        };
        var items = new[]
        {
            new ProjectedItem
            {
                ItemId = "negative",
                Type = "terminal",
                Enabled = true,
                LayoutMode = "absolute",
                Rect = new RectInfo(-100, 10, 800, 600),
                Source = "fallback",
                PlacementStatus = "fallback"
            },
            new ProjectedItem
            {
                ItemId = "relative",
                Type = "terminal",
                Enabled = true,
                LayoutMode = "relative",
                Rect = new RectInfo(100, 100, 500, 500),
                Source = "relative",
                PlacementStatus = "resolved"
            }
        };

        canvas.SetData(monitors, items, new RectInfo(-1920, 0, 4480, 1440), new HashSet<string> { "negative" });
        canvas.Measure(new Size(1000, 700));
        canvas.Arrange(new Rect(0, 0, 1000, 700));
        canvas.Fit();
        Equal(-1920.0, canvas.Transform.VirtualScreen.X, "canvas negative origin");
        canvas.SelectItem(1);
        Equal(1, canvas.SelectedItemIndex, "canvas item selection");
        canvas.SelectMonitor(0);
        Equal(0, canvas.SelectedMonitorIndex, "canvas monitor selection");

        canvas.SetData(Array.Empty<MonitorInfo>(), Array.Empty<ProjectedItem>(), null, null);
        canvas.Fit();
        Equal(-1, canvas.SelectedItemIndex, "empty canvas selection");
        return Task.CompletedTask;
    }

    private static BackendClient CreateFakeClient(Dictionary<string, object?> scenario, TimeSpan timeout)
    {
        var path = NewPath("scenario-" + Guid.NewGuid().ToString("N") + ".json");
        WriteScenario(path, scenario);
        return CreateFakeClient(path, timeout);
    }

    private static BackendClient CreateFakeClient(string scenarioPath, TimeSpan timeout)
    {
        var environment = new Dictionary<string, string?>
        {
            ["DEVWS_TEST_SCENARIO"] = scenarioPath
        };
        var options = new BackendLaunchOptions(_pwsh, _fakeBackend, null, timeout, environment);
        return new BackendClient(options);
    }

    private static void WriteScenario(string path, Dictionary<string, object?> scenario)
    {
        File.WriteAllText(path, JsonSerializer.Serialize(scenario), new System.Text.UTF8Encoding(false));
    }

    private static Dictionary<string, object?> NormalScenario()
    {
        var warnings = new object?[]
        {
            Warning(
                "anchor-missing|main|fallback|path:TEST/MISSING",
                "anchor-missing",
                "The relative monitor identity 'path:TEST/MISSING' is not present in the current topology.",
                "main",
                "fallback",
                "path:TEST/MISSING")
        };

        return new Dictionary<string, object?>
        {
            ["hello"] = Hello(),
            ["inspect"] = Inspect(),
            ["readConfig"] = ReadConfig(),
            ["validate"] = ValidateResult(),
            ["convert"] = ConvertResult(),
            ["defaultSet"] = "main",
            ["warnings"] = warnings,
            ["projects"] = new Dictionary<string, object?>
            {
                ["main"] = Projection("main", MainItems(), Sha, true),
                ["secondary"] = Projection("secondary", Array.Empty<object?>(), Sha, false)
            }
        };
    }

    private static Dictionary<string, object?> ValidateResult(bool valid = true)
    {
        return new Dictionary<string, object?>
        {
            ["valid"] = valid,
            ["saveEligible"] = false,
            ["errors"] = valid
                ? Array.Empty<object?>()
                : new object?[]
                {
                    new Dictionary<string, object?>
                    {
                        ["code"] = "config-schema-invalid",
                        ["message"] = "sets[0] ('main') windows[0] ('profile') layout.w must be greater than 0 (got 0).",
                        ["setId"] = "main",
                        ["itemId"] = "profile",
                        ["field"] = "layout.w"
                    }
                }
        };
    }

    private static Dictionary<string, object?> ConvertResult()
    {
        return new Dictionary<string, object?>
        {
            ["anchor"] = new Dictionary<string, object?>
            {
                ["identity"] = "path:TEST/RIGHT",
                ["instance"] = "TEST/RIGHT"
            },
            ["basis"] = "workArea",
            ["basisRect"] = Rect(0, 0, 2560, 1400),
            ["normalized"] = new Dictionary<string, object?>
            {
                ["x"] = 0.0,
                ["y"] = 0.0,
                ["w"] = 0.5,
                ["h"] = 1.0
            },
            ["roundTripRect"] = Rect(0, 0, 1280, 1400),
            ["reachable"] = true,
            ["visibleRatio"] = 1.0
        };
    }

    private static Dictionary<string, object?> Hello(
        string protocol = "devws-editor/1",
        string[]? supportedOps = null,
        bool readOnly = true)
    {
        return new Dictionary<string, object?>
        {
            ["backendVersion"] = "test-editor-1",
            ["protocol"] = protocol,
            ["supportedOps"] = supportedOps ?? new[] { "hello", "inspect", "read-config", "project", "validate", "convert", "shutdown" },
            ["limits"] = new Dictionary<string, object?>
            {
                ["maxRequestBytes"] = 4194304,
                ["maxResponseBytes"] = 16777216,
                ["maxJsonDepth"] = 32,
                ["maxConfigBytes"] = 4194304,
                ["maxInflight"] = 1,
                ["readTimeoutMs"] = 10000,
                ["saveTimeoutMs"] = null
            },
            ["capabilities"] = new Dictionary<string, object?>
            {
                ["configWritable"] = true,
                ["topologyReadable"] = true,
                ["readOnly"] = readOnly,
                ["saveSupported"] = false,
                ["validateSupported"] = true,
                ["previewSupported"] = false,
                ["convertSupported"] = true
            }
        };
    }

    private static Dictionary<string, object?> Inspect()
    {
        return new Dictionary<string, object?>
        {
            ["config"] = new Dictionary<string, object?>
            {
                ["canonicalPath"] = @"C:\DevWS-Fixture\.config\devws\workspace.json",
                ["effectivePath"] = @"C:\DevWS-Fixture\workspace.json",
                ["source"] = "user",
                ["canonicalExists"] = true,
                ["writable"] = true,
                ["sha256"] = Sha,
                ["sizeBytes"] = 1024,
                ["version"] = 3,
                ["defaultSet"] = "main",
                ["valid"] = true
            },
            ["sets"] = new object?[]
            {
                new Dictionary<string, object?>
                {
                    ["id"] = "main",
                    ["isDefault"] = true,
                    ["itemCount"] = 3,
                    ["profileIds"] = new[] { "docked" }
                },
                new Dictionary<string, object?>
                {
                    ["id"] = "secondary",
                    ["isDefault"] = false,
                    ["itemCount"] = 0,
                    ["profileIds"] = Array.Empty<string>()
                }
            },
            ["topology"] = Topology()
        };
    }

    private static Dictionary<string, object?> ReadConfig()
    {
        return new Dictionary<string, object?>
        {
            ["sha256"] = Sha,
            ["sizeBytes"] = 1024,
            ["document"] = new Dictionary<string, object?>
            {
                ["version"] = 3,
                ["defaultSet"] = "main",
                ["bindings"] = Array.Empty<object?>(),
                ["x-unknown"] = new Dictionary<string, object?>
                {
                    ["keep"] = true,
                    ["nested"] = new object?[] { 1, "two", false }
                },
                ["sets"] = new object?[]
                {
                    new Dictionary<string, object?>
                    {
                        ["id"] = "main",
                        ["windows"] = new object?[]
                        {
                            new Dictionary<string, object?>
                            {
                                ["id"] = "profile",
                                ["type"] = "terminal",
                                ["enabled"] = true,
                                ["windowId"] = "DEVWS-P5-PROFILE",
                                ["path"] = @"C:\Windows",
                                ["elevated"] = true,
                                ["tabs"] = new object?[]
                                {
                                    new Dictionary<string, object?> { ["command"] = null, ["args"] = Array.Empty<object?>() }
                                },
                                ["activeTab"] = 0,
                                ["x-item-note"] = "keep",
                                ["layout"] = Rect(100, 100, 600, 500)
                            },
                            new Dictionary<string, object?>
                            {
                                ["id"] = "relative",
                                ["type"] = "terminal",
                                ["enabled"] = true,
                                ["windowId"] = "DEVWS-P5-RELATIVE",
                                ["path"] = @"C:\Windows",
                                ["elevated"] = true,
                                ["tabs"] = new object?[]
                                {
                                    new Dictionary<string, object?> { ["command"] = null, ["args"] = Array.Empty<object?>() }
                                },
                                ["activeTab"] = 0,
                                ["layout"] = Rect(20, 20, 500, 400),
                                ["layoutMode"] = "relative",
                                ["layoutRelative"] = new Dictionary<string, object?>
                                {
                                    ["monitor"] = new Dictionary<string, object?> { ["identity"] = "path:TEST/RIGHT" },
                                    ["basis"] = "workArea",
                                    ["rect"] = new Dictionary<string, object?>
                                    {
                                        ["x"] = 0.0,
                                        ["y"] = 0.0,
                                        ["w"] = 0.5,
                                        ["h"] = 1.0
                                    }
                                }
                            },
                            new Dictionary<string, object?>
                            {
                                ["id"] = "fallback",
                                ["type"] = "terminal",
                                ["enabled"] = true,
                                ["windowId"] = "DEVWS-P5-FALLBACK",
                                ["path"] = @"C:\Windows",
                                ["elevated"] = true,
                                ["tabs"] = new object?[]
                                {
                                    new Dictionary<string, object?> { ["command"] = null, ["args"] = Array.Empty<object?>() }
                                },
                                ["activeTab"] = 0,
                                ["layout"] = Rect(-1920, 0, 960, 1080)
                            }
                        },
                        ["layoutProfiles"] = new object?[]
                        {
                            new Dictionary<string, object?>
                            {
                                ["id"] = "docked",
                                ["match"] = new Dictionary<string, object?>
                                {
                                    ["mode"] = "exact",
                                    ["monitors"] = new[]
                                    {
                                        "path:TEST/LEFT@-1920,0,1920x1080",
                                        "path:TEST/RIGHT@0,0,2560x1440"
                                    }
                                },
                                ["layouts"] = new Dictionary<string, object?>
                                {
                                    ["profile"] = Rect(100, 100, 600, 500)
                                }
                            }
                        }
                    },
                    new Dictionary<string, object?>
                    {
                        ["id"] = "secondary",
                        ["windows"] = Array.Empty<object?>()
                    }
                }
            }
        };
    }

    private static Dictionary<string, object?> Projection(
        string setId,
        object?[] items,
        string revision = Sha,
        bool isDefault = false)
    {
        return new Dictionary<string, object?>
        {
            ["configRevision"] = revision,
            ["setId"] = setId,
            ["set"] = new Dictionary<string, object?>
            {
                ["id"] = setId,
                ["isDefault"] = isDefault,
                ["profileAware"] = true,
                ["profileMatch"] = new Dictionary<string, object?>
                {
                    ["status"] = "matched",
                    ["profileId"] = "docked",
                    ["reason"] = "matched"
                },
                ["lifecycleRefusal"] = null,
                ["items"] = items
            },
            ["topology"] = Topology()
        };
    }

    private static object?[] MainItems()
    {
        return new object?[]
        {
            Item(
                "profile",
                "terminal",
                "profile",
                Rect(100, 100, 600, 500),
                "profile",
                "absolute",
                profileId: "docked",
                profileEntry: Rect(100, 100, 600, 500),
                profileOverridesRelative: true),
            Item(
                "relative",
                "terminal",
                "relative",
                Rect(0, 0, 1280, 1400),
                "resolved",
                "relative",
                relativeRect: Rect(0, 0, 1280, 1400),
                fallbackRect: Rect(20, 20, 500, 400)),
            Item(
                "fallback",
                "terminal",
                "fallback",
                Rect(-1920, 0, 960, 1080),
                "fallback",
                "absolute",
                fallbackUsed: true,
                fallbackReachable: true)
        };
    }

    private static Dictionary<string, object?> Item(
        string itemId,
        string type,
        string source,
        Dictionary<string, object?> rect,
        string placementStatus,
        string layoutMode,
        string? profileId = null,
        Dictionary<string, object?>? profileEntry = null,
        bool profileOverridesRelative = false,
        Dictionary<string, object?>? relativeRect = null,
        Dictionary<string, object?>? fallbackRect = null,
        bool fallbackUsed = false,
        bool? fallbackReachable = null,
        string? relativeStatus = null,
        string? relativeReason = null,
        string? relativeMessage = null,
        bool applyGeometry = true,
        bool? reachable = true)
    {
        var isRelative = string.Equals(layoutMode, "relative", StringComparison.Ordinal);
        return new Dictionary<string, object?>
        {
            ["itemId"] = itemId,
            ["type"] = type,
            ["enabled"] = true,
            ["layoutMode"] = layoutMode,
            ["rect"] = rect,
            ["source"] = source,
            ["profileId"] = profileId,
            ["profileMatched"] = profileId is not null,
            ["profileOverridesRelative"] = profileOverridesRelative,
            ["profileEntry"] = profileEntry,
            ["relativeLayout"] = isRelative
                ? new Dictionary<string, object?>
                {
                    ["monitor"] = new Dictionary<string, object?> { ["identity"] = "path:TEST/RIGHT" },
                    ["basis"] = "workArea",
                    ["rect"] = new Dictionary<string, object?> { ["x"] = 0.0, ["y"] = 0.0, ["w"] = 0.5, ["h"] = 1.0 }
                }
                : null,
            ["relativeStatus"] = relativeStatus ?? (isRelative ? "resolved" : "not-applicable"),
            ["relativeReason"] = relativeReason ?? (isRelative ? "identity" : null),
            ["relativeMessage"] = relativeMessage,
            ["relativeRect"] = relativeRect,
            ["relativeReachable"] = isRelative ? true : null,
            ["fallbackRect"] = fallbackRect ?? rect,
            ["fallbackReachable"] = fallbackReachable,
            ["fallbackUsed"] = fallbackUsed,
            ["applyGeometry"] = applyGeometry,
            ["placementStatus"] = placementStatus,
            ["placementReason"] = placementStatus,
            ["reachable"] = reachable,
            ["visibleRatio"] = 1.0,
            ["visibleWidth"] = 100,
            ["visibleHeight"] = 100
        };
    }

    private static Dictionary<string, object?> Topology(string? fingerprint = null)
    {
        return new Dictionary<string, object?>
        {
            ["available"] = true,
            ["identityComplete"] = true,
            ["correlationComplete"] = true,
            ["identityAmbiguous"] = false,
            ["signature"] = "path:TEST/LEFT@-1920,0,1920x1080;path:TEST/RIGHT@0,0,2560x1440",
            ["fingerprint"] = fingerprint ?? Fingerprint,
            ["virtualScreenRect"] = Rect(-1920, 0, 4480, 1440),
            ["monitors"] = new object?[]
            {
                new Dictionary<string, object?>
                {
                    ["identity"] = "path:TEST/LEFT",
                    ["instance"] = "TEST/LEFT",
                    ["friendlyName"] = "Left",
                    ["primary"] = false,
                    ["monitorRect"] = Rect(-1920, 0, 1920, 1080),
                    ["workRect"] = Rect(-1920, 0, 1920, 1040),
                    ["scalePercent"] = 100,
                    ["outputTechnology"] = "Synthetic"
                },
                new Dictionary<string, object?>
                {
                    ["identity"] = "path:TEST/RIGHT",
                    ["instance"] = "TEST/RIGHT",
                    ["friendlyName"] = "Right",
                    ["primary"] = true,
                    ["monitorRect"] = Rect(0, 0, 2560, 1440),
                    ["workRect"] = Rect(0, 0, 2560, 1400),
                    ["scalePercent"] = 100,
                    ["outputTechnology"] = "Synthetic"
                }
            },
            ["error"] = null
        };
    }

    private static Dictionary<string, object?> Warning(
        string id,
        string code,
        string message,
        string setId,
        string itemId,
        string identity)
    {
        return new Dictionary<string, object?>
        {
            ["id"] = id,
            ["code"] = code,
            ["message"] = message,
            ["requiresAcknowledgement"] = true,
            ["details"] = new Dictionary<string, object?>
            {
                ["setId"] = setId,
                ["itemId"] = itemId,
                ["identity"] = identity,
                ["relativeStatus"] = code,
                ["placementStatus"] = "fallback",
                ["placementReason"] = "anchor-missing"
            }
        };
    }

    private static Dictionary<string, object?> Error(string code, string message)
    {
        return new Dictionary<string, object?>
        {
            ["code"] = code,
            ["message"] = message,
            ["retryable"] = false,
            ["details"] = new Dictionary<string, object?> { ["source"] = "test" }
        };
    }

    private static Dictionary<string, object?> RealConfig()
    {
        return new Dictionary<string, object?>
        {
            ["version"] = 3,
            ["defaultSet"] = "main",
            ["bindings"] = Array.Empty<object?>(),
            ["sets"] = new object?[]
            {
                new Dictionary<string, object?>
                {
                    ["id"] = "main",
                    ["windows"] = new object?[]
                    {
                        new Dictionary<string, object?>
                        {
                            ["id"] = "demo-terminal",
                            ["type"] = "terminal",
                            ["enabled"] = true,
                            ["windowId"] = "DEVWS-P4-DEMO",
                            ["path"] = @"C:\Windows",
                            ["elevated"] = true,
                            ["tabs"] = new object?[]
                            {
                                new Dictionary<string, object?> { ["command"] = null, ["args"] = Array.Empty<object?>() }
                            },
                            ["activeTab"] = 0,
                            ["layout"] = new Dictionary<string, object?> { ["x"] = -100, ["y"] = 20, ["w"] = 800, ["h"] = 600 }
                        },
                        new Dictionary<string, object?>
                        {
                            ["id"] = "demo-app",
                            ["type"] = "app",
                            ["enabled"] = true,
                            ["match"] = new Dictionary<string, object?> { ["kind"] = "exe", ["value"] = "notepad.exe" },
                            ["launch"] = new Dictionary<string, object?> { ["kind"] = "exe", ["value"] = @"C:\Windows\System32\notepad.exe", ["args"] = Array.Empty<object?>() },
                            ["instanceMode"] = "dedicated",
                            ["layout"] = new Dictionary<string, object?> { ["x"] = 100, ["y"] = 100, ["w"] = 500, ["h"] = 400 }
                        }
                    }
                },
                new Dictionary<string, object?>
                {
                    ["id"] = "empty",
                    ["windows"] = Array.Empty<object?>()
                }
            }
        };
    }

    private static Dictionary<string, object?> Rect(int x, int y, int w, int h)
    {
        return new Dictionary<string, object?> { ["x"] = x, ["y"] = y, ["w"] = w, ["h"] = h };
    }

    private static string ReadNestedString(JsonElement element, string container, string property)
    {
        if (!string.IsNullOrWhiteSpace(container))
        {
            element = JsonText.Object(element, container);
        }

        return JsonText.String(element, property);
    }

    private static int ReadArrayLength(JsonElement element, string property)
    {
        if (element.ValueKind == JsonValueKind.Object &&
            element.TryGetProperty(property, out var value) &&
            value.ValueKind == JsonValueKind.Array)
        {
            return value.GetArrayLength();
        }

        return -1;
    }

    private static async Task<BackendException> CatchAsync(Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (BackendException ex)
        {
            return ex;
        }

        throw new InvalidOperationException("Expected a BackendException, but the call succeeded.");
    }

    private static EditorException CatchEditor(Action action)
    {
        try
        {
            action();
        }
        catch (EditorException ex)
        {
            return ex;
        }

        throw new InvalidOperationException("Expected an EditorException, but the call succeeded.");
    }

    private static string FindRepoRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "src", "editor", "ws-editor-backend.ps1")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        throw new DirectoryNotFoundException("Repository root was not found.");
    }

    private static string ResolveFakeBackend(string repoRoot)
    {
        var copied = Path.Combine(AppContext.BaseDirectory, "fixtures", "fake-editor-backend.ps1");
        if (File.Exists(copied))
        {
            return copied;
        }

        var repo = Path.Combine(repoRoot, "tests", "editor-gui", "fixtures", "fake-editor-backend.ps1");
        if (File.Exists(repo))
        {
            return repo;
        }

        throw new FileNotFoundException("Fake editor backend fixture was not found.");
    }

    private static string NewPath(string name)
    {
        return Path.Combine(_tempRoot, name);
    }

    private static string Hash(string path)
    {
        using var stream = File.OpenRead(path);
        var hash = System.Security.Cryptography.SHA256.HashData(stream);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private static void Equal<T>(T expected, T actual, string message)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"{message}: expected '{expected}', got '{actual}'");
        }
    }

    private static void True(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException($"{message}: condition was false");
        }
    }

    private static void Close(double expected, double actual, double tolerance, string message)
    {
        if (Math.Abs(expected - actual) > tolerance)
        {
            throw new InvalidOperationException($"{message}: expected {expected}, got {actual}");
        }
    }

    private const string Sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private static readonly string Fingerprint = new('F', 64);
}
