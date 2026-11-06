using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json.Nodes;

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
    public string Display => Info.Display + (Info.RequiresAcknowledgement ? "  [acknowledgement required]" : "");
    public override string ToString() => Display;
}

public sealed record DetailRow(string Label, string Value);

public sealed class EditorViewModel : ObservableObject, IDisposable
{
    private static readonly IReadOnlyDictionary<string, RectInfo> EmptyRectDictionary =
        new Dictionary<string, RectInfo>(StringComparer.Ordinal);
    private readonly EditorSession _session;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Dictionary<string, RectInfo> _draftPreviewRects = new(StringComparer.Ordinal);
    private bool _disposed;
    private bool _isBusy;
    private bool _hasError;
    private bool _initialLoadCompleted;
    private bool _requiresRefresh;
    private SetOption? _selectedSet;
    private MonitorOption? _selectedMonitor;
    private ItemOption? _selectedItem;
    private DraftDocument? _draft;
    private PreviewResult? _preview;
    private JsonObject? _previewDraftSnapshot;
    private int? _previewBackendPid;
    private bool _previewStale = true;
    private bool _previewAcknowledged;
    private string? _acknowledgedReviewToken;
    private string _previewError = "";
    private GeometryScopeOption? _selectedScope;
    private DraftValidationResult? _draftValidation;
    private bool _hasDraftConflict;
    private bool _relativeCommitBlocked;
    private string _draftConflictCode = "";
    private string _draftConflictMessage = "";
    private string _editError = "";
    private string _editX = "";
    private string _editY = "";
    private string _editW = "";
    private string _editH = "";
    private string _selectedBasis = "workArea";
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
    private double _lastProjectionApplyMs;
    private double _lastItemsUpdateMs;
    private double _lastDraftCreateMs;
    private double _lastValidateMs;
    private double _lastConvertMs;
    private double _lastEditCommitMs;
    private double _lastPreviewMs;
    private double _lastPreviewTransportMs;
    private double _lastPreviewParseMs;
    private double _lastPreviewModelMs;

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
    public ObservableCollection<GeometryScopeOption> GeometryScopes { get; } = new();
    public ObservableCollection<DraftErrorInfo> DraftErrors { get; } = new();
    public ObservableCollection<PreviewDiffRow> PreviewDiffs { get; } = new();
    public ObservableCollection<PreviewDiffRow> ItemPreviewDiffs { get; } = new();
    public ObservableCollection<WarningRow> PreviewWarnings { get; } = new();
    public ObservableCollection<WarningRow> ItemPreviewWarnings { get; } = new();
    public HashSet<string> WarningItemIds { get; private set; } = new(StringComparer.Ordinal);

    public bool IsDevelopmentConfig { get; }
    public bool InitialLoadCompleted => _initialLoadCompleted;
    public bool RequiresRefresh => _requiresRefresh;
    public bool IsBundledDefault => string.Equals(ConfigSource, "default", StringComparison.OrdinalIgnoreCase);
    public bool IsBusy => _isBusy;
    public bool IsNotBusy => !_isBusy;
    public bool HasError => _hasError;
    public string ReadOnlyBadge => "DRAFT-ONLY";
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
    public string BusyText => _isBusy ? "Working…" : "";
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
    public EditorLoadMetrics? LoadMetrics => _session.LastLoadMetrics;
    public double LastProjectionApplyMs => _lastProjectionApplyMs;
    public double LastItemsUpdateMs => _lastItemsUpdateMs;
    public double LastDraftCreateMs => _lastDraftCreateMs;
    public double LastValidateMs => _lastValidateMs;
    public double LastConvertMs => _lastConvertMs;
    public double LastEditCommitMs => _lastEditCommitMs;
    public DraftDocument? Draft => _draft;
    public IReadOnlyDictionary<string, RectInfo> DraftPreviewRects => _draftPreviewRects;
    public bool HasDraft => _draft is not null;
    public bool IsDraftDirty => _draft?.IsDirty == true;
    public string DraftBadgeText => IsDraftDirty
        ? $"UNSAVED DRAFT — {_draft!.DirtyItemIds().Count} item(s)"
        : "";
    public string SaveUnavailableText => "Save is not available in P6 (preview/review only).";
    public bool CanSave => false;
    public bool HasDraftConflict => _hasDraftConflict;
    public string DraftConflictText => _hasDraftConflict
        ? $"{_draftConflictCode}: {_draftConflictMessage}"
        : "";
    public bool CanDiscardDraft => HasDraft && (IsDraftDirty || HasDraftConflict);
    public bool CanEditGeometry => HasDraft && !HasDraftConflict && !_isBusy && _selectedItem is not null;
    public bool CanEditSelectedScope => CanEditGeometry &&
        (_selectedScope?.Kind != GeometryScopeKind.Relative || !_relativeCommitBlocked) &&
        (_selectedScope?.Kind != GeometryScopeKind.ProfileEntry || !_relativeCommitBlocked);
    public bool CanPreview => HasDraft && !HasDraftConflict && !_isBusy;
    public bool HasPreview => _preview is not null;
    public PreviewResult? Preview => _preview;
    public bool IsPreviewCurrent =>
        _preview is not null &&
        !_previewStale &&
        _draft is not null &&
        _previewDraftSnapshot is not null &&
        _previewBackendPid is not null &&
        _session.Client.ProcessId == _previewBackendPid &&
        _draft.MatchesSnapshot(_previewDraftSnapshot);
    public bool HasPreviewError => !string.IsNullOrWhiteSpace(_previewError);
    public string PreviewErrorText => _previewError;
    public string PreviewSummaryText
    {
        get
        {
            if (_preview is null)
            {
                return HasPreviewError ? "Preview failed" : "Preview: not run";
            }

            if (!IsPreviewCurrent)
            {
                return "Preview: stale — run Preview again";
            }

            return _preview.Diff.Count == 0
                ? "Preview: no proposed changes"
                : $"Preview: {_preview.Diff.Count} stored change(s)";
        }
    }
    public int PreviewDiffCount => IsPreviewCurrent && _preview is not null ? _preview.Diff.Count : 0;
    public int PreviewWarningCount => IsPreviewCurrent && _preview is not null ? _preview.Warnings.Count : 0;
    public bool PreviewNoChanges => IsPreviewCurrent && _preview is not null && _preview.Diff.Count == 0;
    public bool IsPreviewAcknowledged =>
        _previewAcknowledged &&
        IsPreviewCurrent &&
        _preview is not null &&
        string.Equals(_acknowledgedReviewToken, _preview.Review.ReviewToken, StringComparison.Ordinal);
    public bool CanAcknowledgePreview =>
        IsPreviewCurrent &&
        _preview is not null &&
        _preview.Review.RequiresAcknowledgement &&
        !IsPreviewAcknowledged;
    public string ReviewStatusText
    {
        get
        {
            if (_preview is null)
            {
                return "Run Preview to review warnings.";
            }

            if (!IsPreviewCurrent)
            {
                return "Preview is stale; run Preview again before reviewing warnings.";
            }

            if (!_preview.Review.RequiresAcknowledgement)
            {
                return "No acknowledgement required.";
            }

            return IsPreviewAcknowledged
                ? "Warnings reviewed — save remains unavailable in P6."
                : "Explicit review required for the displayed warnings.";
        }
    }
    public double LastPreviewMs => _lastPreviewMs;
    public double LastPreviewTransportMs => _lastPreviewTransportMs;
    public double LastPreviewParseMs => _lastPreviewParseMs;
    public double LastPreviewModelMs => _lastPreviewModelMs;
    public string? PreviewWarningDigest => IsPreviewCurrent ? _preview?.Review.WarningDigest : null;
    public string? PreviewReviewToken => IsPreviewCurrent ? _preview?.Review.ReviewToken : null;
    public IReadOnlyDictionary<string, RectInfo> CanvasDraftRects =>
        IsPreviewCurrent ? EmptyRectDictionary : _draftPreviewRects;
    public IReadOnlyDictionary<string, RectInfo> CanvasPreviewRects
    {
        get
        {
            if (!IsPreviewCurrent || _preview is null)
            {
                return EmptyRectDictionary;
            }

            var saved = _preview.SavedSet.Items.ToDictionary(item => item.ItemId, item => item.Rect, StringComparer.Ordinal);
            var proposed = new Dictionary<string, RectInfo>(StringComparer.Ordinal);

            foreach (var item in _preview.DraftSet.Items)
            {
                if (!saved.TryGetValue(item.ItemId, out var savedRect) || !Equals(savedRect, item.Rect))
                {
                    proposed[item.ItemId] = item.Rect;
                }
            }

            return proposed;
        }
    }
    public string ScopeDescription => _selectedScope is null
        ? "Select an item to edit its geometry."
        : _selectedScope.Kind switch
        {
            GeometryScopeKind.AbsoluteFallback => $"Stored scope: item.layout (absolute fallback) for '{SelectedItem?.Item.ItemId}'",
            GeometryScopeKind.ProfileEntry => $"Stored scope: layoutProfiles['{_selectedScope.ProfileId}'].layouts['{SelectedItem?.Item.ItemId}']",
            GeometryScopeKind.Relative => $"Stored scope: layoutRelative for '{SelectedItem?.Item.ItemId}' • anchor {RelativeAnchorSummary()}",
            _ => ""
        };
    public string DraftValidationText => _draft is null
        ? "Draft: not loaded"
        : _draftValidation is null
            ? "Draft validation: not run"
            : _draftValidation.Valid
                ? "Draft validation: structurally valid (not a semantic preview or save authorization)"
                : $"Draft validation: INVALID — {_draftValidation.Errors.Count} error(s)";
    public bool IsDraftValid => _draftValidation?.Valid == true;
    public string EditErrorText => _editError;
    public bool HasEditError => !string.IsNullOrWhiteSpace(_editError);
    public string EditX
    {
        get => _editX;
        set => Set(ref _editX, value);
    }
    public string EditY
    {
        get => _editY;
        set => Set(ref _editY, value);
    }
    public string EditW
    {
        get => _editW;
        set => Set(ref _editW, value);
    }
    public string EditH
    {
        get => _editH;
        set => Set(ref _editH, value);
    }
    public IReadOnlyList<string> BasisOptions { get; } = new[] { "workArea", "monitor" };
    public string SelectedBasis
    {
        get => _selectedBasis;
        set => Set(ref _selectedBasis, value);
    }
    public bool CanConvertToRelative => CanEditGeometry &&
        SelectedItem is not null &&
        _draft?.GetLayoutMode(SelectedItem.Item.ItemId) == "absolute";
    public bool CanConvertToAbsolute => CanEditGeometry &&
        SelectedItem is not null &&
        _draft?.GetLayoutMode(SelectedItem.Item.ItemId) == "relative";
    public string BaseRevisionText => _draft is null
        ? "—"
        : _draft.BaseSha256[..Math.Min(12, _draft.BaseSha256.Length)] + "…";
    public string BaseTopologyText => string.IsNullOrWhiteSpace(_draft?.BaseTopologyFingerprint)
        ? "unavailable"
        : _draft!.BaseTopologyFingerprint![..Math.Min(12, _draft.BaseTopologyFingerprint.Length)] + "…";

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

    public GeometryScopeOption? SelectedScope
    {
        get => _selectedScope;
        private set
        {
            if (Set(ref _selectedScope, value))
            {
                OnPropertyChanged(nameof(SelectedScope));
                OnPropertyChanged(nameof(ScopeDescription));
                OnPropertyChanged(nameof(CanConvertToRelative));
                OnPropertyChanged(nameof(CanConvertToAbsolute));
                OnPropertyChanged(nameof(CanEditSelectedScope));
            }
        }
    }

    public async Task LoadAsync(string? preferredSetId = null)
    {
        if (_isBusy || _disposed)
        {
            return;
        }

        if (IsDraftDirty)
        {
            SetDraftConflict(
                "draft-dirty",
                "Discard the unsaved draft before reloading the canonical configuration.");
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

        if (IsDraftDirty)
        {
            SetEditError("Discard the unsaved draft before switching workspace sets.");
            _statusMessage = "Set switch blocked: the current draft is dirty.";
            OnPropertyChanged(nameof(StatusMessage));
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
            ClearPreview();
            _draft?.RebindSet(set.Info.Id);
            _draftPreviewRects.Clear();
            _draftValidation = null;
            DraftErrors.Clear();
            ApplyProjection(projection, null);
            SelectedSet = set;
            _statusMessage = $"Projected set '{set.Info.Id}': {Items.Count} items.";
            RefreshDraftUi();
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
        InvalidatePreview();

        if (!IsDraftDirty)
        {
            await LoadAsync(SelectedSet?.Info.Id);
            return;
        }

        if (_isBusy)
        {
            return;
        }

        SetBusy(true);
        ClearError();

        try
        {
            var inspect = await _session.InspectAsync(_lifetime.Token);

            if (!string.Equals(inspect.Config.Sha256, _draft!.BaseSha256, StringComparison.Ordinal))
            {
                SetDraftConflict(
                    "external-change",
                    "The canonical configuration changed while the draft is dirty. The draft was preserved; discard it to reload, or keep working without refreshing.");
                _statusMessage = "Refresh stopped: the canonical configuration changed.";
                return;
            }

            if (!string.Equals(
                    inspect.Topology.Fingerprint ?? "",
                    _draft.BaseTopologyFingerprint ?? "",
                    StringComparison.Ordinal))
            {
                SetDraftConflict(
                    "topology-changed",
                    "The monitor topology changed while the draft is dirty. Relative/profile commits are blocked; discard the draft to reload.");
                _statusMessage = "Refresh stopped: the monitor topology changed.";
                return;
            }

            var projection = await _session.ProjectAsync(
                SelectedSet?.Info.Id ?? _draft.SetId,
                _draft.BaseSha256,
                _draft.BaseTopologyFingerprint,
                _lifetime.Token);

            ApplyProjection(projection, inspect.Topology);
            _statusMessage = $"Refreshed saved projection; draft preserved ({_draft.DirtyItemIds().Count} dirty item(s)).";
            RefreshDraftUi();
        }
        catch (Exception ex)
        {
            SetError(ex);
            if (ex is BackendException backend &&
                backend.Code is "external-change" or "topology-changed")
            {
                SetDraftConflict(backend.Code, backend.Message);
            }
        }
        finally
        {
            SetBusy(false);
            OnPropertyChanged(nameof(RefreshMs));
        }
    }

    public void SelectItem(ItemOption? item)
    {
        SelectedItem = item;
        RebuildScopes(preserveSelection: false);
        RebuildItemPreview();
        RebuildDetails();
        RefreshEditFields();
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

    public void SelectScope(GeometryScopeOption? scope)
    {
        if (scope is null)
        {
            return;
        }

        SelectedScope = scope;
        RefreshEditFields();
        RebuildDetails();
    }

    public void RefreshEditFields()
    {
        var rect = GetScopeEditableRect();

        if (rect is null)
        {
            EditX = "";
            EditY = "";
            EditW = "";
            EditH = "";
        }
        else
        {
            EditX = rect.X.ToString(CultureInfo.InvariantCulture);
            EditY = rect.Y.ToString(CultureInfo.InvariantCulture);
            EditW = rect.W.ToString(CultureInfo.InvariantCulture);
            EditH = rect.H.ToString(CultureInfo.InvariantCulture);
        }

        OnPropertyChanged(nameof(CanEditGeometry));
        OnPropertyChanged(nameof(CanEditSelectedScope));
        OnPropertyChanged(nameof(CanConvertToRelative));
        OnPropertyChanged(nameof(CanConvertToAbsolute));
        OnPropertyChanged(nameof(ScopeDescription));
    }

    public RectInfo? GetScopeEditableRect()
    {
        if (_draft is null || SelectedItem is null || SelectedScope is null)
        {
            return null;
        }

        var itemId = SelectedItem.Item.ItemId;

        return SelectedScope.Kind switch
        {
            GeometryScopeKind.AbsoluteFallback => _draft.GetAbsoluteLayout(itemId),
            GeometryScopeKind.ProfileEntry when !string.IsNullOrWhiteSpace(SelectedScope.ProfileId) =>
                _draft.GetProfileEntry(itemId, SelectedScope.ProfileId!) ?? SelectedItem.Item.ProfileEntry,
            GeometryScopeKind.Relative =>
                _draftPreviewRects.TryGetValue(itemId, out var preview)
                    ? preview
                    : SelectedItem.Item.RelativeRect ?? SelectedItem.Item.FallbackRect ?? _draft.GetAbsoluteLayout(itemId),
            _ => null
        };
    }

    public async Task<bool> ApplyGeometryAsync(string xText, string yText, string wText, string hText)
    {
        ClearEditError();

        if (!CanEditSelectedScope)
        {
            SetEditError(HasDraftConflict
                ? "Editing is blocked until the draft conflict is resolved."
                : "The selected geometry scope cannot be committed in the current state.");
            return false;
        }

        if (!TryParseInteger(xText, "X", out var x) ||
            !TryParseInteger(yText, "Y", out var y) ||
            !TryParseInteger(wText, "Width", out var w) ||
            !TryParseInteger(hText, "Height", out var h))
        {
            return false;
        }

        if (w <= 0 || h <= 0)
        {
            SetEditError("Width and height must be greater than 0.");
            return false;
        }

        return await CommitRectAsync(new RectInfo(x, y, w, h));
    }

    public async Task<bool> CommitCanvasRectAsync(RectInfo rect)
    {
        ClearEditError();

        if (!CanEditSelectedScope)
        {
            SetEditError("The selected geometry scope cannot be committed in the current state.");
            return false;
        }

        if (rect.W <= 0 || rect.H <= 0)
        {
            SetEditError("Width and height must be greater than 0.");
            return false;
        }

        return await CommitRectAsync(rect);
    }

    private async Task<bool> CommitRectAsync(RectInfo rect)
    {
        if (_draft is null || SelectedItem is null || SelectedScope is null)
        {
            SetEditError("No editable geometry scope is selected.");
            return false;
        }

        var itemId = SelectedItem.Item.ItemId;
        var scope = SelectedScope;
        var commitWatch = Stopwatch.StartNew();

        SetBusy(true);
        ClearEditError();

        try
        {
            await EnsureCommitContextAsync(scope.Kind is GeometryScopeKind.ProfileEntry or GeometryScopeKind.Relative);

            RectInfo preview;

            if (scope.Kind == GeometryScopeKind.Relative)
            {
                var anchor = _draft.GetRelativeAnchor(itemId);

                if (anchor is null)
                {
                    SetEditError("This relative item has no usable anchor or basis; the relative edit was refused.");
                    return false;
                }

                var convertWatch = Stopwatch.StartNew();
                var converted = await _session.ConvertAsync(
                    rect,
                    anchor,
                    anchor.Basis,
                    _draft.BaseTopologyFingerprint,
                    _lifetime.Token);
                convertWatch.Stop();
                _lastConvertMs = convertWatch.Elapsed.TotalMilliseconds;

                _draft.SetRelativeRect(itemId, converted.Normalized);
                preview = converted.RoundTripRect;
            }
            else if (scope.Kind == GeometryScopeKind.ProfileEntry)
            {
                if (string.IsNullOrWhiteSpace(scope.ProfileId))
                {
                    SetEditError("The profile entry scope has no profile id.");
                    return false;
                }

                _draft.SetProfileEntry(itemId, scope.ProfileId!, rect);
                preview = rect;
            }
            else
            {
                _draft.SetAbsoluteLayout(itemId, rect);
                preview = rect;
            }

            _draft.EnsureMutationScope();
            InvalidatePreview();
            _draftPreviewRects[itemId] = preview;
            commitWatch.Stop();
            _lastEditCommitMs = commitWatch.Elapsed.TotalMilliseconds;

            await ValidateDraftCoreAsync();
            RebuildScopes(preserveSelection: true);
            RebuildDetails();
            RefreshEditFields();
            RefreshDraftUi();

            _statusMessage = scope.Kind == GeometryScopeKind.Relative
                ? $"Relative geometry committed in memory for '{itemId}'; normalized fractions stored in the draft."
                : $"Draft geometry updated for '{itemId}' ({scope.Display}).";
            OnPropertyChanged(nameof(StatusMessage));
            return true;
        }
        catch (BackendException ex)
        {
            HandleDraftBackendError(ex);
            return false;
        }
        catch (EditorException ex)
        {
            if (ex.Code is "unsupported-mutation" or "invalid-rect" or "draft-invalid")
            {
                _draft?.RevertItem(itemId);
                _draftPreviewRects.Remove(itemId);
            }

            SetEditError(ex.Message);
            _statusMessage = "Draft edit refused.";
            OnPropertyChanged(nameof(StatusMessage));
            return false;
        }
        finally
        {
            SetBusy(false);
        }
    }

    public async Task RevertSelectedAsync()
    {
        if (_draft is null || SelectedItem is null || !IsDraftDirty)
        {
            return;
        }

        var itemId = SelectedItem.Item.ItemId;
        _draft.RevertItem(itemId);
        InvalidatePreview();
        _draftPreviewRects.Remove(itemId);
        ClearEditError();
        await ValidateDraftCoreAsync();
        RebuildScopes(preserveSelection: true);
        RebuildDetails();
        RefreshEditFields();
        RefreshDraftUi();
        _statusMessage = $"Reverted the draft geometry for '{itemId}'.";
        OnPropertyChanged(nameof(StatusMessage));
    }

    public async Task DiscardDraftAsync(bool reload)
    {
        if (_draft is null)
        {
            return;
        }

        _draft.DiscardAll();
        ClearPreview();
        _draftPreviewRects.Clear();
        _draftValidation = null;
        DraftErrors.Clear();
        _hasDraftConflict = false;
        _relativeCommitBlocked = false;
        _draftConflictCode = "";
        _draftConflictMessage = "";
        ClearEditError();
        RebuildScopes(preserveSelection: true);
        RebuildDetails();
        RefreshEditFields();
        RefreshDraftUi();

        if (reload)
        {
            await LoadAsync(SelectedSet?.Info.Id);
        }
        else
        {
            _statusMessage = "All in-memory draft changes were discarded.";
            OnPropertyChanged(nameof(StatusMessage));
        }
    }

    public async Task DiscardDraftAndReloadAsync()
    {
        await DiscardDraftAsync(reload: true);
    }

    public async Task<bool> PreviewAsync()
    {
        ClearPreviewError();

        if (!CanPreview || _draft is null)
        {
            SetPreviewError(HasDraftConflict
                ? "Preview is blocked by the current draft conflict."
                : "Preview is unavailable while the editor is busy or has no draft.");
            return false;
        }

        SetBusy(true);

        try
        {
            await ValidateDraftCoreAsync();

            if (_draftValidation is null || !_draftValidation.Valid)
            {
                SetPreviewError("Draft validation failed; preview was not requested.");
                return false;
            }

            var watch = Stopwatch.StartNew();
            var result = await _session.PreviewAsync(
                _draft,
                _draft.BaseSha256,
                _draft.SetId,
                _draft.BaseTopologyFingerprint,
                _lifetime.Token);
            watch.Stop();
            _lastPreviewMs = watch.Elapsed.TotalMilliseconds;
            var metrics = _session.LastPreviewMetrics;
            _lastPreviewTransportMs = metrics?.TransportMs ?? 0;
            _lastPreviewParseMs = metrics?.ParseMs ?? 0;
            _lastPreviewModelMs = metrics?.ModelMs ?? 0;
            ApplyPreviewResult(result);
            return true;
        }
        catch (BackendException ex)
        {
            HandlePreviewBackendError(ex);
            return false;
        }
        catch (EditorException ex)
        {
            SetPreviewError($"{ex.Code}: {ex.Message}");
            return false;
        }
        finally
        {
            SetBusy(false);
        }
    }

    public bool AcknowledgePreviewWarnings()
    {
        if (!CanAcknowledgePreview || _preview is null)
        {
            return false;
        }

        _previewAcknowledged = true;
        _acknowledgedReviewToken = _preview.Review.ReviewToken;
        _statusMessage = "Warnings reviewed explicitly; save remains unavailable in P6.";
        OnPropertyChanged(nameof(StatusMessage));
        NotifyPreviewState();
        return true;
    }

    public ProjectedItem? GetPreviewSavedItem()
    {
        var itemId = SelectedItem?.Item.ItemId;

        return itemId is null
            ? null
            : _preview?.SavedSet.Items.FirstOrDefault(item => string.Equals(item.ItemId, itemId, StringComparison.Ordinal));
    }

    public ProjectedItem? GetPreviewDraftItem()
    {
        var itemId = SelectedItem?.Item.ItemId;

        return itemId is null
            ? null
            : _preview?.DraftSet.Items.FirstOrDefault(item => string.Equals(item.ItemId, itemId, StringComparison.Ordinal));
    }

    private void ApplyPreviewResult(PreviewResult result)
    {
        _preview = result;
        _previewDraftSnapshot = _draft?.CreateDraftSnapshot();
        _previewBackendPid = _session.Client.ProcessId;
        _previewStale = false;
        _previewAcknowledged = false;
        _acknowledgedReviewToken = null;
        _previewError = "";

        PreviewDiffs.Clear();
        foreach (var entry in result.Diff)
        {
            PreviewDiffs.Add(new PreviewDiffRow(entry));
        }

        PreviewWarnings.Clear();
        foreach (var warning in result.Warnings)
        {
            PreviewWarnings.Add(new WarningRow(warning));
        }

        RebuildItemPreview();
        RebuildDetails();
        RefreshDraftUi();
        _statusMessage = result.Diff.Count == 0
            ? "Preview current: no proposed changes."
            : $"Preview current: {result.Diff.Count} stored change(s).";
        OnPropertyChanged(nameof(StatusMessage));
    }

    private void InvalidatePreview(bool clearError = true)
    {
        _previewStale = true;
        _previewAcknowledged = false;
        _acknowledgedReviewToken = null;

        if (clearError)
        {
            _previewError = "";
        }

        NotifyPreviewState();
    }

    private void ClearPreview()
    {
        _preview = null;
        _previewDraftSnapshot = null;
        _previewBackendPid = null;
        _previewStale = true;
        _previewAcknowledged = false;
        _acknowledgedReviewToken = null;
        _previewError = "";
        PreviewDiffs.Clear();
        ItemPreviewDiffs.Clear();
        PreviewWarnings.Clear();
        ItemPreviewWarnings.Clear();
        NotifyPreviewState();
    }

    private void SetPreviewError(string message)
    {
        _previewError = message;
        _previewStale = true;
        _previewAcknowledged = false;
        _acknowledgedReviewToken = null;
        NotifyPreviewState();
    }

    private void ClearPreviewError()
    {
        if (string.IsNullOrEmpty(_previewError))
        {
            return;
        }

        _previewError = "";
        NotifyPreviewState();
    }

    private void HandlePreviewBackendError(BackendException exception)
    {
        if (exception.Code is "external-change" or "topology-changed")
        {
            SetDraftConflict(exception.Code, exception.Message);
        }

        SetPreviewError($"{exception.Code}: {exception.Message}");
        _statusMessage = $"Preview refused: {exception.Code}.";
        OnPropertyChanged(nameof(StatusMessage));
    }

    private void RebuildItemPreview()
    {
        ItemPreviewDiffs.Clear();
        ItemPreviewWarnings.Clear();

        var itemId = SelectedItem?.Item.ItemId;

        if (itemId is null || _preview is null)
        {
            return;
        }

        foreach (var row in PreviewDiffs.Where(row => string.Equals(row.Entry.ItemId, itemId, StringComparison.Ordinal)))
        {
            ItemPreviewDiffs.Add(row);
        }

        foreach (var warning in _preview.Warnings.Where(warning => IsPreviewWarningRelevant(warning, itemId)))
        {
            ItemPreviewWarnings.Add(new WarningRow(warning));
        }
    }

    private bool IsPreviewWarningRelevant(WarningInfo warning, string itemId)
    {
        if (string.Equals(warning.Details.ItemId, itemId, StringComparison.Ordinal))
        {
            return true;
        }

        return string.IsNullOrWhiteSpace(warning.Details.ItemId) &&
               (string.IsNullOrWhiteSpace(warning.Details.SetId) ||
                string.Equals(warning.Details.SetId, _draft?.SetId, StringComparison.Ordinal));
    }

    private void NotifyPreviewState()
    {
        OnPropertyChanged(nameof(HasPreview));
        OnPropertyChanged(nameof(Preview));
        OnPropertyChanged(nameof(IsPreviewCurrent));
        OnPropertyChanged(nameof(HasPreviewError));
        OnPropertyChanged(nameof(PreviewErrorText));
        OnPropertyChanged(nameof(PreviewSummaryText));
        OnPropertyChanged(nameof(PreviewDiffCount));
        OnPropertyChanged(nameof(PreviewWarningCount));
        OnPropertyChanged(nameof(PreviewNoChanges));
        OnPropertyChanged(nameof(IsPreviewAcknowledged));
        OnPropertyChanged(nameof(CanAcknowledgePreview));
        OnPropertyChanged(nameof(ReviewStatusText));
        OnPropertyChanged(nameof(PreviewWarningDigest));
        OnPropertyChanged(nameof(PreviewReviewToken));
        OnPropertyChanged(nameof(CanvasPreviewRects));
        OnPropertyChanged(nameof(CanvasDraftRects));
    }

    public async Task ConvertToRelativeAsync()
    {
        ClearEditError();

        if (!CanConvertToRelative || _draft is null || SelectedItem is null)
        {
            SetEditError("The selected item is not an absolute item that can be converted to relative mode.");
            return;
        }

        var itemId = SelectedItem.Item.ItemId;
        var rect = _draft.GetAbsoluteLayout(itemId);

        SetBusy(true);

        try
        {
            await EnsureCommitContextAsync(requiresTopology: true);
            var convertWatch = Stopwatch.StartNew();
            var converted = await _session.SelectAnchorAndConvertAsync(
                rect,
                SelectedBasis,
                _draft.BaseTopologyFingerprint,
                _lifetime.Token);
            convertWatch.Stop();
            _lastConvertMs = convertWatch.Elapsed.TotalMilliseconds;

            _draft.SetRelativeMode(
                itemId,
                converted.Identity,
                converted.Instance,
                converted.Basis,
                converted.Normalized);
            _draft.EnsureMutationScope();
            InvalidatePreview();
            _draftPreviewRects[itemId] = converted.RoundTripRect;

            await ValidateDraftCoreAsync();
            RebuildScopes(preserveSelection: true);
            SelectedScope = GeometryScopes.FirstOrDefault(scope => scope.Kind == GeometryScopeKind.Relative) ?? SelectedScope;
            RebuildDetails();
            RefreshEditFields();
            RefreshDraftUi();
            _statusMessage = $"Converted '{itemId}' to relative mode using backend anchor selection ({converted.Identity}).";
            OnPropertyChanged(nameof(StatusMessage));
        }
        catch (BackendException ex)
        {
            HandleDraftBackendError(ex);
        }
        catch (EditorException ex)
        {
            if (ex.Code is "unsupported-mutation" or "invalid-rect" or "draft-invalid")
            {
                _draft.RevertItem(itemId);
                _draftPreviewRects.Remove(itemId);
            }

            SetEditError(ex.Message);
        }
        finally
        {
            SetBusy(false);
        }
    }

    public async Task ConvertToAbsoluteAsync()
    {
        ClearEditError();

        if (!CanConvertToAbsolute || _draft is null || SelectedItem is null)
        {
            SetEditError("The selected item is not a relative item that can be converted to absolute mode.");
            return;
        }

        var itemId = SelectedItem.Item.ItemId;
        var anchor = _draft.GetRelativeAnchor(itemId);
        var rect = _draftPreviewRects.TryGetValue(itemId, out var preview)
            ? preview
            : SelectedItem.Item.RelativeRect;

        if (anchor is null || rect is null)
        {
            SetEditError("The relative item has no resolved anchor/rectangle; conversion to absolute was refused.");
            return;
        }

        SetBusy(true);

        try
        {
            await EnsureCommitContextAsync(requiresTopology: true);
            var convertWatch = Stopwatch.StartNew();
            var converted = await _session.ConvertAsync(
                rect,
                anchor,
                anchor.Basis,
                _draft.BaseTopologyFingerprint,
                _lifetime.Token);
            convertWatch.Stop();
            _lastConvertMs = convertWatch.Elapsed.TotalMilliseconds;

            _draft.SetAbsoluteMode(itemId, converted.RoundTripRect);
            _draft.EnsureMutationScope();
            InvalidatePreview();
            _draftPreviewRects[itemId] = converted.RoundTripRect;

            await ValidateDraftCoreAsync();
            RebuildScopes(preserveSelection: true);
            SelectedScope = GeometryScopes.FirstOrDefault(scope => scope.Kind == GeometryScopeKind.AbsoluteFallback) ?? SelectedScope;
            RebuildDetails();
            RefreshEditFields();
            RefreshDraftUi();
            _statusMessage = $"Converted '{itemId}' to absolute mode at {converted.RoundTripRect.Display}.";
            OnPropertyChanged(nameof(StatusMessage));
        }
        catch (BackendException ex)
        {
            HandleDraftBackendError(ex);
        }
        catch (EditorException ex)
        {
            if (ex.Code is "unsupported-mutation" or "invalid-rect" or "draft-invalid")
            {
                _draft.RevertItem(itemId);
                _draftPreviewRects.Remove(itemId);
            }

            SetEditError(ex.Message);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async Task EnsureCommitContextAsync(bool requiresTopology)
    {
        if (_draft is null)
        {
            throw new EditorException("draft-missing", "No draft is loaded.");
        }

        var inspect = await _session.InspectAsync(_lifetime.Token);

        if (!string.Equals(inspect.Config.Sha256, _draft.BaseSha256, StringComparison.Ordinal))
        {
            SetDraftConflict(
                "external-change",
                "The canonical configuration changed while the draft is dirty. The edit was refused and the draft was preserved.");
            throw new EditorException(
                "external-change",
                "The canonical configuration changed; the draft edit was refused.",
                requiresRefresh: true);
        }

        if (requiresTopology &&
            !string.Equals(
                inspect.Topology.Fingerprint ?? "",
                _draft.BaseTopologyFingerprint ?? "",
                StringComparison.Ordinal))
        {
            _relativeCommitBlocked = true;
            SetDraftConflict(
                "topology-changed",
                "The monitor topology changed. Relative/profile commits are blocked until the draft is discarded and reloaded.");
            throw new EditorException(
                "topology-changed",
                "The monitor topology changed; the relative/profile edit was refused.",
                requiresRefresh: true);
        }
    }

    private async Task ValidateDraftCoreAsync()
    {
        if (_draft is null)
        {
            return;
        }

        var watch = Stopwatch.StartNew();
        var result = await _session.ValidateAsync(_draft, _lifetime.Token);
        watch.Stop();
        _lastValidateMs = watch.Elapsed.TotalMilliseconds;
        _draftValidation = result;

        DraftErrors.Clear();
        foreach (var error in result.Errors)
        {
            DraftErrors.Add(error);
        }

        OnPropertyChanged(nameof(DraftValidationText));
        OnPropertyChanged(nameof(IsDraftValid));
    }

    private void ApplySnapshot(EditorSnapshot snapshot, string? preferredSetId)
    {
        ClearPreview();
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
        _hasDraftConflict = false;
        _relativeCommitBlocked = false;
        _draftConflictCode = "";
        _draftConflictMessage = "";
        _draftPreviewRects.Clear();
        _draftValidation = null;
        _draft = null;
        DraftErrors.Clear();
        ClearEditError();

        Monitors.Clear();
        foreach (var monitor in snapshot.Inspect.Topology.Monitors)
        {
            Monitors.Add(new MonitorOption(monitor));
        }

        SelectedMonitor = null;
        ApplyProjection(snapshot.Projection, snapshot.Inspect.Topology);
        SelectedMonitor ??= Monitors.FirstOrDefault();

        var draftWatch = Stopwatch.StartNew();
        _draft = DraftDocument.Create(
            snapshot.Document,
            snapshot.Inspect.Config.Sha256,
            snapshot.Inspect.Topology.Fingerprint,
            SelectedSet?.Info.Id ?? "");
        draftWatch.Stop();
        _lastDraftCreateMs = draftWatch.Elapsed.TotalMilliseconds;

        RebuildScopes(preserveSelection: false);
        RebuildDetails();
        RefreshEditFields();
        RefreshDraftUi();

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
        var applyWatch = Stopwatch.StartNew();
        var selectedItemId = SelectedItem?.Item.ItemId;
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

        var itemsWatch = Stopwatch.StartNew();
        Items.Clear();
        foreach (var item in projection.Set.Items)
        {
            Items.Add(new ItemOption(item));
        }
        itemsWatch.Stop();
        _lastItemsUpdateMs = itemsWatch.Elapsed.TotalMilliseconds;

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

        SelectedItem = !string.IsNullOrWhiteSpace(selectedItemId)
            ? Items.FirstOrDefault(item => string.Equals(item.Item.ItemId, selectedItemId, StringComparison.Ordinal))
            : null;
        SelectedItem ??= Items.FirstOrDefault();
        SelectedMonitor = SelectedMonitor is null ? Monitors.FirstOrDefault() : SelectedMonitor;
        RebuildScopes(preserveSelection: true);
        RebuildDetails();
        applyWatch.Stop();
        _lastProjectionApplyMs = applyWatch.Elapsed.TotalMilliseconds;

        OnPropertyChanged(nameof(VirtualScreenRect));
        OnPropertyChanged(nameof(ConfigRevision));
        OnPropertyChanged(nameof(RevisionText));
        OnPropertyChanged(nameof(TopologyText));
        OnPropertyChanged(nameof(CountsText));
        OnPropertyChanged(nameof(WarningItemIds));
    }

    private void RebuildScopes(bool preserveSelection)
    {
        var priorKind = preserveSelection ? SelectedScope?.Kind : null;
        var priorProfile = preserveSelection ? SelectedScope?.ProfileId : null;
        var item = SelectedItem?.Item;
        GeometryScopes.Clear();

        if (item is null || _draft is null)
        {
            SelectedScope = null;
            OnPropertyChanged(nameof(GeometryScopes));
            return;
        }

        var absoluteRect = _draft.GetAbsoluteLayout(item.ItemId);
        GeometryScopes.Add(new GeometryScopeOption(
            GeometryScopeKind.AbsoluteFallback,
            $"Absolute fallback — {absoluteRect.Display}",
            $"item.layout ({item.ItemId})"));

        if (item.ProfileEntry is not null && !string.IsNullOrWhiteSpace(item.ProfileId))
        {
            var entry = _draft.GetProfileEntry(item.ItemId, item.ProfileId!) ?? item.ProfileEntry;
            GeometryScopes.Add(new GeometryScopeOption(
                GeometryScopeKind.ProfileEntry,
                $"Profile entry '{item.ProfileId}' — {entry.Display}",
                $"layoutProfiles['{item.ProfileId}'].layouts['{item.ItemId}']",
                item.ProfileId));
        }

        if (string.Equals(_draft.GetLayoutMode(item.ItemId), "relative", StringComparison.Ordinal) &&
            _draft.GetRelativeAnchor(item.ItemId) is not null)
        {
            var relativeRect = _draft.GetRelativeRect(item.ItemId);
            var rectText = relativeRect is null
                ? "unresolved"
                : $"{relativeRect.X:0.######},{relativeRect.Y:0.######} {relativeRect.W:0.######}x{relativeRect.H:0.######}";
            GeometryScopes.Add(new GeometryScopeOption(
                GeometryScopeKind.Relative,
                $"Relative placement — {rectText}",
                $"item.layoutRelative ({item.ItemId})"));
        }

        GeometryScopeOption? target = null;

        if (priorKind is not null)
        {
            target = GeometryScopes.FirstOrDefault(scope =>
                scope.Kind == priorKind &&
                string.Equals(scope.ProfileId, priorProfile, StringComparison.Ordinal));
        }

        if (target is null)
        {
            target = item.Source switch
            {
                "profile" => GeometryScopes.FirstOrDefault(scope => scope.Kind == GeometryScopeKind.ProfileEntry),
                "relative" or "relative-fallback" => GeometryScopes.FirstOrDefault(scope => scope.Kind == GeometryScopeKind.Relative),
                _ => null
            };
        }

        SelectedScope = target
            ?? GeometryScopes.FirstOrDefault(scope => scope.Kind == GeometryScopeKind.AbsoluteFallback)
            ?? GeometryScopes.FirstOrDefault();

        OnPropertyChanged(nameof(GeometryScopes));
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
        DetailRows.Add(new DetailRow("Draft mode", _draft?.GetLayoutMode(item.ItemId) ?? item.LayoutMode));
        DetailRows.Add(new DetailRow("Saved effective rect", item.Rect.Display));
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

        DetailRows.Add(new DetailRow("Draft state", IsDraftDirty ? "UNSAVED — in memory only" : "clean"));
        DetailRows.Add(new DetailRow("Edit scope", SelectedScope?.Display ?? "—"));
        DetailRows.Add(new DetailRow("Stored geometry", GetScopeEditableRect()?.Display ?? "—"));
        DetailRows.Add(new DetailRow(
            "Local draft",
            _draftPreviewRects.TryGetValue(item.ItemId, out var preview) ? preview.Display : "—"));
        DetailRows.Add(new DetailRow("Draft validation", DraftValidationText));
        DetailRows.Add(new DetailRow("Base revision", BaseRevisionText));
        DetailRows.Add(new DetailRow("Base topology", BaseTopologyText));
        DetailRows.Add(new DetailRow("Save", "unavailable in P6"));
        DetailRows.Add(new DetailRow("Preview", PreviewSummaryText));

        var previewSaved = GetPreviewSavedItem();
        var previewDraft = GetPreviewDraftItem();

        if (_preview is not null)
        {
            DetailRows.Add(new DetailRow("Preview saved effective", previewSaved?.Rect.Display ?? "—"));
            DetailRows.Add(new DetailRow("Preview proposed effective", previewDraft?.Rect.Display ?? "—"));
            DetailRows.Add(new DetailRow(
                "Effective placement changed",
                previewSaved is null || previewDraft is null
                    ? "—"
                    : Equals(previewSaved.Rect, previewDraft.Rect) ? "no" : "yes"));
            DetailRows.Add(new DetailRow("Preview active source", previewDraft?.Source ?? "—"));
            DetailRows.Add(new DetailRow("Preview warnings", _preview.Warnings.Count.ToString()));

            foreach (var row in ItemPreviewDiffs.Take(6))
            {
                DetailRows.Add(new DetailRow("Stored change", row.Display));
            }

            foreach (var warning in ItemPreviewWarnings.Take(4))
            {
                DetailRows.Add(new DetailRow("Preview warning", warning.Display));
            }

            DetailRows.Add(new DetailRow("Review", ReviewStatusText));
        }

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

    private string RelativeAnchorSummary()
    {
        if (_draft is null || SelectedItem is null)
        {
            return "—";
        }

        var anchor = _draft.GetRelativeAnchor(SelectedItem.Item.ItemId);
        return anchor is null
            ? "unresolved"
            : $"{anchor.Identity} · {anchor.Basis}";
    }

    private static string YesNo(bool value) => value ? "yes" : "no";
    private static string YesNo(bool? value) => value is null ? "—" : value.Value ? "yes" : "no";

    private bool TryParseInteger(string text, string label, out int value)
    {
        if (int.TryParse(text?.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out value))
        {
            return true;
        }

        SetEditError($"{label} must be a 32-bit integer. Negative X/Y values are allowed.");
        value = 0;
        return false;
    }

    private void SetEditError(string message)
    {
        _editError = message;
        OnPropertyChanged(nameof(EditErrorText));
        OnPropertyChanged(nameof(HasEditError));
    }

    private void ClearEditError()
    {
        if (string.IsNullOrEmpty(_editError))
        {
            return;
        }

        _editError = "";
        OnPropertyChanged(nameof(EditErrorText));
        OnPropertyChanged(nameof(HasEditError));
    }

    private void SetDraftConflict(string code, string message)
    {
        _hasDraftConflict = true;
        _draftConflictCode = code;
        _draftConflictMessage = message;
        InvalidatePreview(clearError: false);
        OnPropertyChanged(nameof(HasDraftConflict));
        OnPropertyChanged(nameof(DraftConflictText));
        OnPropertyChanged(nameof(CanEditGeometry));
        OnPropertyChanged(nameof(CanEditSelectedScope));
        OnPropertyChanged(nameof(CanDiscardDraft));
        OnPropertyChanged(nameof(CanPreview));
    }

    private void HandleDraftBackendError(BackendException exception)
    {
        SetEditError($"{exception.Code}: {exception.Message}");

        if (exception.Code is "external-change" or "topology-changed")
        {
            SetDraftConflict(exception.Code, exception.Message);
            _relativeCommitBlocked = true;
        }

        _statusMessage = $"Draft edit refused: {exception.Code}.";
        OnPropertyChanged(nameof(StatusMessage));
    }

    private void RefreshDraftUi()
    {
        OnPropertyChanged(nameof(HasDraft));
        OnPropertyChanged(nameof(IsDraftDirty));
        OnPropertyChanged(nameof(DraftBadgeText));
        OnPropertyChanged(nameof(CanDiscardDraft));
        OnPropertyChanged(nameof(CanEditGeometry));
        OnPropertyChanged(nameof(CanEditSelectedScope));
        OnPropertyChanged(nameof(CanConvertToRelative));
        OnPropertyChanged(nameof(CanConvertToAbsolute));
        OnPropertyChanged(nameof(DraftValidationText));
        OnPropertyChanged(nameof(IsDraftValid));
        OnPropertyChanged(nameof(ScopeDescription));
        OnPropertyChanged(nameof(BaseRevisionText));
        OnPropertyChanged(nameof(BaseTopologyText));
        OnPropertyChanged(nameof(EditErrorText));
        OnPropertyChanged(nameof(HasEditError));
        OnPropertyChanged(nameof(CountsText));
        NotifyPreviewState();
    }

    private void SetBusy(bool busy)
    {
        if (Set(ref _isBusy, busy, nameof(IsBusy)))
        {
            OnPropertyChanged(nameof(IsNotBusy));
            OnPropertyChanged(nameof(BusyText));
            OnPropertyChanged(nameof(CanEditGeometry));
            OnPropertyChanged(nameof(CanEditSelectedScope));
            OnPropertyChanged(nameof(CanConvertToRelative));
            OnPropertyChanged(nameof(CanConvertToAbsolute));
            OnPropertyChanged(nameof(CanPreview));
            OnPropertyChanged(nameof(CanAcknowledgePreview));
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

        _statusMessage = "Load failed. Review the error and refresh.";
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
        GeometryScopes.Clear();
        DraftErrors.Clear();
        WarningItemIds = new HashSet<string>(StringComparer.Ordinal);
        SelectedItem = null;
        SelectedMonitor = null;
        SelectedScope = null;
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
