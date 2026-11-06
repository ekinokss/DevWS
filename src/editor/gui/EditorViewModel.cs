using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;

namespace DevWS.Editor;

public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }

    protected void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}

public sealed class SetOption
{
    public SetOption(SetInfo info)
    {
        Info = info;
    }

    public SetInfo Info { get; }
    public string Display => Info.Id + (Info.IsDefault ? "  (default)" : "") + $"  —  {Info.ItemCount} items";
    public override string ToString() => Display;
}

public sealed class MonitorOption
{
    public MonitorOption(MonitorInfo info)
    {
        Info = info;
    }

    public MonitorInfo Info { get; }
    public string Display => Info.Display;
    public override string ToString() => Display;
}

public sealed class ItemOption
{
    public ItemOption(ProjectedItem item)
    {
        Item = item;
    }

    public ProjectedItem Item { get; }
    public string Display => $"{Item.ItemId}  [{Item.Type}]  {Item.Source}";
    public override string ToString() => Display;
}

public sealed class WarningRow
{
    public WarningRow(WarningInfo info)
    {
        Info = info;
    }

    public WarningInfo Info { get; }
    public string Display => Info.Display;
    public override string ToString() => Display;
}

public sealed record DetailRow(string Label, string Value);

public sealed class EditorViewModel : ObservableObject, IDisposable
{
    private readonly EditorSession _session;
    private readonly CancellationTokenSource _lifetime = new();
    private bool _disposed;
    private bool _isBusy;
    private bool _hasError;
    private bool _initialLoadCompleted;
    private bool _requiresRefresh;
    private SetOption? _selectedSet;
    private MonitorOption? _selectedMonitor;
    private ItemOption? _selectedItem;
    private string _configSource = "";
    private string _configRevision = "";
    private string _topologyFingerprint = "";
    private string _backendVersion = "";
    private string _protocol = "";
    private string _configEffectivePath = "";
    private string _canonicalPath = "";
    private bool _canonicalExists;
    private bool _writable;
    private string _statusMessage = "Starting…";
    private string _errorCode = "";
    private string _errorMessage = "";
    private string _errorDetails = "";
    private string _integrityLevel = "Unknown";
    private RectInfo? _virtualScreenRect;
    private ProjectedSet? _projectedSet;
    private double _handshakeMs;
    private double _loadMs;
    private double _refreshMs;
    private double _workingSetMb;
    private double _cpuTotalMs;
    private int? _backendPid;
    private int _warningCount;

    public EditorViewModel(EditorSession session, bool isDevelopmentConfig, string integrityLevel)
    {
        _session = session;
        IsDevelopmentConfig = isDevelopmentConfig;
        _integrityLevel = integrityLevel;
    }

    public ObservableCollection<SetOption> Sets { get; } = new();
    public ObservableCollection<MonitorOption> Monitors { get; } = new();
    public ObservableCollection<ItemOption> Items { get; } = new();
    public ObservableCollection<WarningRow> Warnings { get; } = new();
    public ObservableCollection<WarningRow> ItemWarnings { get; } = new();
    public ObservableCollection<DetailRow> DetailRows { get; } = new();
    public HashSet<string> WarningItemIds { get; private set; } = new(StringComparer.Ordinal);

    public bool IsDevelopmentConfig { get; }
    public bool InitialLoadCompleted => _initialLoadCompleted;
    public bool RequiresRefresh => _requiresRefresh;
    public bool IsBundledDefault => string.Equals(ConfigSource, "default", StringComparison.OrdinalIgnoreCase);
    public bool IsBusy => _isBusy;
    public bool IsNotBusy => !_isBusy;
    public bool HasError => _hasError;
    public string ReadOnlyBadge => "READ-ONLY";
    public string DevelopmentBadge => "DEVELOPMENT CONFIG";
    public string IntegrityText => $"Integrity: {_integrityLevel}";
    public string BackendText => _backendPid is null
        ? "Backend: not connected"
        : $"Backend: pid {_backendPid}  •  {_protocol}  •  {_backendVersion}";
    public string RevisionText => string.IsNullOrWhiteSpace(_configRevision)
        ? "Revision: —"
        : $"Revision: {_configRevision[..Math.Min(12, _configRevision.Length)]}…";
    public string ConfigText => string.IsNullOrWhiteSpace(_configSource)
        ? "Config: —"
        : IsBundledDefault
            ? "Config: bundled default (read-only)"
            : $"Config: {_configSource}";
    public string TopologyText => string.IsNullOrWhiteSpace(_topologyFingerprint)
        ? "Topology: unavailable"
        : $"Topology: {_topologyFingerprint[..Math.Min(12, _topologyFingerprint.Length)]}…";
    public string CountsText => $"{Sets.Count} sets  •  {Monitors.Count} monitors  •  {Items.Count} items  •  {_warningCount} warnings";
    public string BusyText => _isBusy ? "Loading read-only projection…" : "";
    public string StatusMessage => _statusMessage;
    public string ErrorCode => _errorCode;
    public string ErrorMessage => _errorMessage;
    public string ErrorDetails => _errorDetails;
    public string ErrorText => string.IsNullOrWhiteSpace(_errorDetails)
        ? $"{_errorCode}: {_errorMessage}"
        : $"{_errorCode}: {_errorMessage}{Environment.NewLine}{_errorDetails}";
    public double HandshakeMs => _handshakeMs;
    public double LoadMs => _loadMs;
    public double RefreshMs => _refreshMs;
    public double WorkingSetMb => _workingSetMb;
    public double CpuTotalMs => _cpuTotalMs;
    public int? BackendPid => _backendPid;
    public RectInfo? VirtualScreenRect => _virtualScreenRect;
    public ProjectedSet? ProjectedSet => _projectedSet;
    public string ConfigRevision => _configRevision;
    public string? TopologyFingerprint => _topologyFingerprint;
    public string ConfigSource => _configSource;
    public string ConfigEffectivePath => _configEffectivePath;
    public string CanonicalPath => _canonicalPath;
    public bool CanonicalExists => _canonicalExists;
    public bool Writable => _writable;
    public bool BackendExited => _session.Client.HasExited;
    public int? BackendExitCode => _session.Client.ExitCode;
    public string BackendStderr => _session.Client.LastStderr;

    public SetOption? SelectedSet
    {
        get => _selectedSet;
        private set
        {
            if (Set(ref _selectedSet, value))
            {
                OnPropertyChanged(nameof(SelectedSet));
            }
        }
    }

    public MonitorOption? SelectedMonitor
    {
        get => _selectedMonitor;
        private set
        {
            if (Set(ref _selectedMonitor, value))
            {
                OnPropertyChanged(nameof(SelectedMonitor));
            }
        }
    }

    public ItemOption? SelectedItem
    {
        get => _selectedItem;
        private set
        {
            if (Set(ref _selectedItem, value))
            {
                OnPropertyChanged(nameof(SelectedItem));
            }
        }
    }

    public async Task LoadAsync(string? preferredSetId = null)
    {
        if (_isBusy || _disposed)
        {
            return;
        }

        SetBusy(true);
        ClearError();

        try
        {
            var watch = Stopwatch.StartNew();
            var snapshot = await _session.LoadAsync(preferredSetId, _lifetime.Token);
            watch.Stop();
            ApplySnapshot(snapshot, preferredSetId);
            _loadMs = watch.Elapsed.TotalMilliseconds;
            _refreshMs = preferredSetId is null ? 0 : _loadMs;
            UpdateRuntimeMetrics();
            _statusMessage = $"Loaded {Sets.Count} sets, {Monitors.Count} monitors, {Items.Count} items.";
            OnPropertyChanged(nameof(LoadMs));
            OnPropertyChanged(nameof(RefreshMs));
            OnPropertyChanged(nameof(StatusMessage));
            OnPropertyChanged(nameof(CountsText));
        }
        catch (OperationCanceledException)
        {
            _statusMessage = "Loading cancelled.";
            OnPropertyChanged(nameof(StatusMessage));
        }
        catch (Exception ex)
        {
            SetError(ex);
            if (preferredSetId is not null && IsSetNotFound(ex))
            {
                SetBusy(false);
                await LoadAsync(null);
                return;
            }
        }
        finally
        {
            SetBusy(false);
        }
    }

    public async Task SelectSetAsync(SetOption? set)
    {
        if (set is null || _isBusy || _disposed)
        {
            return;
        }

        if (SelectedSet?.Info.Id == set.Info.Id && Items.Count > 0)
        {
            return;
        }

        SetBusy(true);
        ClearError();

        try
        {
            var projection = await _session.ProjectAsync(
                set.Info.Id,
                _configRevision,
                _topologyFingerprint,
                _lifetime.Token);
            ApplyProjection(projection, null);
            SelectedSet = set;
            _statusMessage = $"Projected set '{set.Info.Id}': {Items.Count} items.";
            OnPropertyChanged(nameof(StatusMessage));
            OnPropertyChanged(nameof(CountsText));
        }
        catch (Exception ex)
        {
            SetError(ex);
            if (ex is EditorException editor && editor.RequiresRefresh)
            {
                DiscardInconsistentView();
            }
        }
        finally
        {
            SetBusy(false);
        }
    }

    public async Task RefreshAsync()
    {
        _refreshMs = 0;
        await LoadAsync(SelectedSet?.Info.Id);
    }

    public void SelectItem(ItemOption? item)
    {
        SelectedItem = item;
        RebuildDetails();
    }

    public void SelectItemAt(int index)
    {
        if (index >= 0 && index < Items.Count)
        {
            SelectItem(Items[index]);
        }
        else
        {
            SelectItem(null);
        }
    }

    public void SelectMonitor(MonitorOption? monitor)
    {
        SelectedMonitor = monitor;
    }

    public void SelectMonitorAt(int index)
    {
        if (index >= 0 && index < Monitors.Count)
        {
            SelectMonitor(Monitors[index]);
        }
        else
        {
            SelectMonitor(null);
        }
    }

    private void ApplySnapshot(EditorSnapshot snapshot, string? preferredSetId)
    {
        Sets.Clear();
        foreach (var set in snapshot.Inspect.Sets)
        {
            Sets.Add(new SetOption(set));
        }

        var preferred = !string.IsNullOrWhiteSpace(preferredSetId)
            ? Sets.FirstOrDefault(set => set.Info.Id == preferredSetId)
            : null;
        SelectedSet = preferred
            ?? Sets.FirstOrDefault(set => set.Info.IsDefault)
            ?? Sets.FirstOrDefault();

        _configSource = snapshot.Inspect.Config.Source;
        _configEffectivePath = snapshot.Inspect.Config.EffectivePath;
        _canonicalPath = snapshot.Inspect.Config.CanonicalPath;
        _canonicalExists = snapshot.Inspect.Config.CanonicalExists;
        _writable = snapshot.Inspect.Config.Writable;
        _configRevision = snapshot.Inspect.Config.Sha256;
        _topologyFingerprint = snapshot.Inspect.Topology.Fingerprint ?? "";
        _backendVersion = snapshot.Hello.BackendVersion;
        _protocol = snapshot.Hello.Protocol;
        _backendPid = _session.Client.ProcessId;
        _handshakeMs = snapshot.Hello is null ? 0 : _session.Client.LastConnectMs;
        _initialLoadCompleted = true;
        _requiresRefresh = false;

        Monitors.Clear();
        foreach (var monitor in snapshot.Inspect.Topology.Monitors)
        {
            Monitors.Add(new MonitorOption(monitor));
        }

        SelectedMonitor = null;
        ApplyProjection(snapshot.Projection, snapshot.Inspect.Topology);
        SelectedMonitor ??= Monitors.FirstOrDefault();

        OnPropertyChanged(nameof(ConfigSource));
        OnPropertyChanged(nameof(ConfigText));
        OnPropertyChanged(nameof(IsBundledDefault));
        OnPropertyChanged(nameof(ConfigEffectivePath));
        OnPropertyChanged(nameof(CanonicalPath));
        OnPropertyChanged(nameof(CanonicalExists));
        OnPropertyChanged(nameof(Writable));
        OnPropertyChanged(nameof(ConfigRevision));
        OnPropertyChanged(nameof(RevisionText));
        OnPropertyChanged(nameof(TopologyFingerprint));
        OnPropertyChanged(nameof(TopologyText));
        OnPropertyChanged(nameof(BackendText));
        OnPropertyChanged(nameof(BackendPid));
        OnPropertyChanged(nameof(CountsText));
        OnPropertyChanged(nameof(HandshakeMs));
    }

    private void ApplyProjection(WorkspaceProjection projection, TopologyInfo? fallbackTopology)
    {
        _projectedSet = projection.Set;
        _configRevision = string.IsNullOrWhiteSpace(projection.ConfigRevision)
            ? _configRevision
            : projection.ConfigRevision;
        _topologyFingerprint = projection.Topology.Fingerprint
            ?? fallbackTopology?.Fingerprint
            ?? "";
        _virtualScreenRect = projection.Topology.VirtualScreenRect
            ?? fallbackTopology?.VirtualScreenRect;
        _warningCount = projection.Warnings.Count;

        Items.Clear();
        foreach (var item in projection.Set.Items)
        {
            Items.Add(new ItemOption(item));
        }

        Warnings.Clear();
        foreach (var warning in projection.Warnings)
        {
            Warnings.Add(new WarningRow(warning));
        }

        WarningItemIds = new HashSet<string>(
            projection.Warnings
                .Select(warning => warning.Details.ItemId)
                .Where(id => !string.IsNullOrWhiteSpace(id))
                .Select(id => id!),
            StringComparer.Ordinal);

        SelectedItem = Items.FirstOrDefault();
        SelectedMonitor = SelectedMonitor is null ? Monitors.FirstOrDefault() : SelectedMonitor;
        RebuildDetails();

        OnPropertyChanged(nameof(VirtualScreenRect));
        OnPropertyChanged(nameof(ConfigRevision));
        OnPropertyChanged(nameof(RevisionText));
        OnPropertyChanged(nameof(TopologyText));
        OnPropertyChanged(nameof(CountsText));
        OnPropertyChanged(nameof(WarningItemIds));
    }

    private void RebuildDetails()
    {
        DetailRows.Clear();
        ItemWarnings.Clear();

        if (SelectedItem is null)
        {
            DetailRows.Add(new DetailRow("Item", "No item selected"));
            return;
        }

        var item = SelectedItem.Item;
        var set = SelectedSet;

        DetailRows.Add(new DetailRow("Item", item.ItemId));
        DetailRows.Add(new DetailRow("Type", item.Type));
        DetailRows.Add(new DetailRow("Enabled", YesNo(item.Enabled)));
        DetailRows.Add(new DetailRow("Layout mode", item.LayoutMode));
        DetailRows.Add(new DetailRow("Effective rect", item.Rect.Display));
        DetailRows.Add(new DetailRow("Placement source", item.Source));
        DetailRows.Add(new DetailRow("Placement status", $"{item.PlacementStatus} ({item.PlacementReason})"));
        var setProfile = _projectedSet?.ProfileMatch;
        DetailRows.Add(new DetailRow(
            "Set profile",
            setProfile is null
                ? "—"
                : $"{setProfile.Status}  {setProfile.ProfileId ?? "—"}  ({setProfile.Reason})"));
        DetailRows.Add(new DetailRow("Profile", ProfileText(item, set)));
        DetailRows.Add(new DetailRow("Profile entry", item.ProfileEntry?.Display ?? "—"));
        DetailRows.Add(new DetailRow("Relative anchor", RelativeText(item)));
        DetailRows.Add(new DetailRow("Relative rect", item.RelativeRect?.Display ?? "—"));
        DetailRows.Add(new DetailRow("Relative reachability", YesNo(item.RelativeReachable)));
        DetailRows.Add(new DetailRow("Fallback rect", item.FallbackRect?.Display ?? "—"));
        DetailRows.Add(new DetailRow("Fallback used", YesNo(item.FallbackUsed)));
        DetailRows.Add(new DetailRow("Fallback reachable", YesNo(item.FallbackReachable)));
        DetailRows.Add(new DetailRow("Reachable", YesNo(item.Reachable)));
        DetailRows.Add(new DetailRow("Visible ratio", item.VisibleRatio is null ? "—" : $"{item.VisibleRatio:0.###}"));
        DetailRows.Add(new DetailRow("Apply geometry", YesNo(item.ApplyGeometry)));

        foreach (var warning in Warnings.Where(warning => IsWarningRelevant(warning.Info, item.ItemId, set?.Info.Id)))
        {
            ItemWarnings.Add(warning);
        }

        DetailRows.Add(new DetailRow("Warnings", ItemWarnings.Count == 0 ? "none" : ItemWarnings.Count.ToString()));
    }

    private static bool IsWarningRelevant(WarningInfo warning, string itemId, string? setId)
    {
        if (string.Equals(warning.Details.ItemId, itemId, StringComparison.Ordinal))
        {
            return true;
        }

        return string.IsNullOrWhiteSpace(warning.Details.ItemId) &&
               (string.IsNullOrWhiteSpace(warning.Details.SetId) ||
                string.Equals(warning.Details.SetId, setId, StringComparison.Ordinal));
    }

    private static string ProfileText(ProjectedItem item, SetOption? set)
    {
        var profileId = item.ProfileId ?? set?.Info.ProfileIds.FirstOrDefault();
        if (string.IsNullOrWhiteSpace(profileId))
        {
            return "not matched";
        }

        return $"{profileId}  (overrides relative: {YesNo(item.ProfileOverridesRelative)})";
    }

    private static string RelativeText(ProjectedItem item)
    {
        if (item.RelativeLayout is null && string.Equals(item.RelativeStatus, "not-applicable", StringComparison.Ordinal))
        {
            return "not applicable";
        }

        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(item.RelativeStatus)) parts.Add(item.RelativeStatus!);
        if (!string.IsNullOrWhiteSpace(item.RelativeReason)) parts.Add(item.RelativeReason!);
        if (!string.IsNullOrWhiteSpace(item.RelativeMessage)) parts.Add(item.RelativeMessage!);
        if (item.RelativeLayout is not null) parts.Add(item.RelativeLayout.Display);
        return parts.Count == 0 ? "—" : string.Join("  •  ", parts);
    }

    private static string YesNo(bool value) => value ? "yes" : "no";
    private static string YesNo(bool? value) => value is null ? "—" : value.Value ? "yes" : "no";

    private void SetBusy(bool busy)
    {
        if (Set(ref _isBusy, busy, nameof(IsBusy)))
        {
            OnPropertyChanged(nameof(IsNotBusy));
            OnPropertyChanged(nameof(BusyText));
        }
    }

    private void ClearError()
    {
        _hasError = false;
        _requiresRefresh = false;
        _errorCode = "";
        _errorMessage = "";
        _errorDetails = "";
        OnPropertyChanged(nameof(HasError));
        OnPropertyChanged(nameof(RequiresRefresh));
        OnPropertyChanged(nameof(ErrorCode));
        OnPropertyChanged(nameof(ErrorMessage));
        OnPropertyChanged(nameof(ErrorDetails));
        OnPropertyChanged(nameof(ErrorText));
    }

    private void SetError(Exception exception)
    {
        _hasError = true;
        _errorCode = exception switch
        {
            BackendException backend => backend.Code,
            EditorException editor => editor.Code,
            _ => "unexpected-error"
        };
        _errorMessage = exception.Message;
        _errorDetails = exception switch
        {
            BackendException backend => backend.DetailsText ?? "",
            EditorException editor => editor.DetailsText ?? "",
            _ => ""
        };
        _requiresRefresh = exception switch
        {
            EditorException editor => editor.RequiresRefresh,
            BackendException backend => backend.IsTransportFailure ||
                                        backend.Code is "external-change" or "topology-changed" or
                                            "config-invalid" or "config-unavailable" or "protocol-error",
            _ => true
        };

        _statusMessage = "Read-only load failed. Review the error and refresh.";
        OnPropertyChanged(nameof(HasError));
        OnPropertyChanged(nameof(RequiresRefresh));
        OnPropertyChanged(nameof(ErrorCode));
        OnPropertyChanged(nameof(ErrorMessage));
        OnPropertyChanged(nameof(ErrorDetails));
        OnPropertyChanged(nameof(ErrorText));
        OnPropertyChanged(nameof(StatusMessage));
    }

    private static bool IsSetNotFound(Exception exception)
    {
        return exception is BackendException backend &&
               string.Equals(backend.Code, "set-not-found", StringComparison.Ordinal);
    }

    private void DiscardInconsistentView()
    {
        Items.Clear();
        Monitors.Clear();
        Warnings.Clear();
        ItemWarnings.Clear();
        DetailRows.Clear();
        WarningItemIds = new HashSet<string>(StringComparer.Ordinal);
        SelectedItem = null;
        SelectedMonitor = null;
        _projectedSet = null;
        _virtualScreenRect = null;
        _warningCount = 0;
        _statusMessage = "The projection is stale. Refresh to load a consistent revision and topology.";
        OnPropertyChanged(nameof(VirtualScreenRect));
        OnPropertyChanged(nameof(CountsText));
        OnPropertyChanged(nameof(WarningItemIds));
        OnPropertyChanged(nameof(StatusMessage));
    }

    private void UpdateRuntimeMetrics()
    {
        try
        {
            using var process = Process.GetCurrentProcess();
            process.Refresh();
            _workingSetMb = Math.Round(process.WorkingSet64 / 1024.0 / 1024.0, 2);
            _cpuTotalMs = Math.Round(process.TotalProcessorTime.TotalMilliseconds, 1);
            OnPropertyChanged(nameof(WorkingSetMb));
            OnPropertyChanged(nameof(CpuTotalMs));
        }
        catch
        {
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _lifetime.Cancel();
        _lifetime.Dispose();
        _session.Dispose();
        OnPropertyChanged(nameof(BackendExited));
        OnPropertyChanged(nameof(BackendExitCode));
    }
}
