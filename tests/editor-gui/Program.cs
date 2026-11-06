using System.Diagnostics;
using System.IO;
using System.Text.Json;
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
                ("fake sequential requests correlate", FakeSequentialRequests),
                ("fake timeout restarts once", FakeTimeoutRestart),
                ("fake backend exit restarts once", FakeExitRestart),
                ("fake malformed response is protocol-error and recovers", FakeMalformedResponse),
                ("fake save refusal is structured", FakeSaveRefusal),
                ("fake graceful shutdown exits child", FakeGracefulShutdown),
                ("real backend round trip and non-mutation", RealBackendRoundTrip),
                ("view model loads sets, monitors, items, warnings", ViewModelLoadAndSelection),
                ("view model rejects revision mismatch", ViewModelRevisionMismatch),
                ("view model recovers from malformed config", ViewModelMalformedConfigRecovery),
                ("view model displays ambiguous and unreachable placement", ViewModelPlacementStates),
                ("view model handles 200 synthetic items", ViewModelLargeSet),
                ("canvas transform preserves negative origins", CanvasNegativeOrigin),
                ("canvas handles negative and empty data", CanvasDataHandling),
                ("production GUI source keeps read-only boundaries", SourceBoundaries)
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
        True(hello.ReadOnly, "read-only");
        True(client.ProcessId is > 0, "backend pid available");
        client.Dispose();
        True(client.HasExited, "backend exited after dispose");
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
            "SendAsync(\"validate\"",
            "SendAsync(\"preview\"",
            "SendAsync(\"convert\""
        })
        {
            True(!source.Contains(forbiddenCall, StringComparison.Ordinal), $"production GUI must not call {forbiddenCall}");
        }

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

        using var client = CreateFakeClient(scenario, TimeSpan.FromSeconds(3));
        using var session = new EditorSession(client);
        using var vm = new EditorViewModel(session, false, "Medium");
        var watch = Stopwatch.StartNew();
        await vm.LoadAsync();
        watch.Stop();
        Equal(200, vm.Items.Count, "200 item count");
        vm.SelectItemAt(199);
        Equal<string?>("item-199", vm.SelectedItem?.Item.ItemId, "last item selection");
        Console.WriteLine($"INFO 200-item view-model load: {watch.Elapsed.TotalMilliseconds:0.0} ms");
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
            ["defaultSet"] = "main",
            ["warnings"] = warnings,
            ["projects"] = new Dictionary<string, object?>
            {
                ["main"] = Projection("main", MainItems(), Sha, true),
                ["secondary"] = Projection("secondary", Array.Empty<object?>(), Sha, false)
            }
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
            ["supportedOps"] = supportedOps ?? new[] { "hello", "inspect", "read-config", "project", "shutdown" },
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
                ["saveSupported"] = false
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
                ["sets"] = new object?[]
                {
                    new Dictionary<string, object?>
                    {
                        ["id"] = "main",
                        ["windows"] = new object?[]
                        {
                            new Dictionary<string, object?> { ["id"] = "profile", ["type"] = "terminal" },
                            new Dictionary<string, object?> { ["id"] = "relative", ["type"] = "terminal" },
                            new Dictionary<string, object?> { ["id"] = "fallback", ["type"] = "terminal" }
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
