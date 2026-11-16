using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace DevWS.Editor;

public partial class MainWindow : Window
{
    private readonly EditorViewModel _viewModel;
    private readonly Stopwatch _appStopwatch;
    private Task? _loadTask;
    private bool _syncingSelection;
    private bool _allowClose;

    public MainWindow(EditorViewModel viewModel, Stopwatch appStopwatch)
    {
        InitializeComponent();
        _viewModel = viewModel;
        _appStopwatch = appStopwatch;
        DataContext = viewModel;

        Canvas.SelectionChanged += Canvas_SelectionChanged;
        Canvas.PointerWorldChanged += Canvas_PointerWorldChanged;
        Canvas.DraftRectChanging += Canvas_DraftRectChanging;
        Canvas.DraftRectCommitted += Canvas_DraftRectCommitted;
        Canvas.DraftRectCancelled += Canvas_DraftRectCancelled;
        BasisCombo.SelectedItem = _viewModel.SelectedBasis;
        Loaded += Window_Loaded;
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        await EnsureLoadedAsync();
    }

    private Task EnsureLoadedAsync()
    {
        return _loadTask ??= LoadInitialAsync();
    }

    private async Task LoadInitialAsync()
    {
        await _viewModel.LoadAsync();
        UpdateCanvasFromViewModel(resetView: true);
        SyncSelectionFromViewModel();
        SyncScopeSelection();
        _viewModel.RefreshEditFields();
        UpdateStatus();
    }

    private async void SetList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingSelection || SetList.SelectedItem is not SetOption set)
        {
            return;
        }

        await _viewModel.SelectSetAsync(set);
        UpdateCanvasFromViewModel(resetView: true);
        SyncSelectionFromViewModel();
        SyncScopeSelection();
        _viewModel.RefreshEditFields();
        UpdateStatus();
    }

    private void MonitorList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingSelection)
        {
            return;
        }

        _viewModel.SelectMonitorAt(MonitorList.SelectedIndex);
        Canvas.SelectMonitor(MonitorList.SelectedIndex);
        UpdateStatus();
    }

    private void ItemList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingSelection)
        {
            return;
        }

        _viewModel.SelectItemAt(ItemList.SelectedIndex);
        Canvas.SelectItem(ItemList.SelectedIndex);
        SyncScopeSelection();
        _viewModel.RefreshEditFields();
        UpdateStatus();
    }

    private void ScopeCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingSelection || ScopeCombo.SelectedItem is not GeometryScopeOption scope)
        {
            return;
        }

        _viewModel.SelectScope(scope);
        _viewModel.RefreshEditFields();
        UpdateStatus();
    }

    private void Canvas_SelectionChanged(object? sender, EventArgs e)
    {
        if (_syncingSelection)
        {
            return;
        }

        _syncingSelection = true;

        try
        {
            MonitorList.SelectedIndex = Canvas.SelectedMonitorIndex;
            ItemList.SelectedIndex = Canvas.SelectedItemIndex;
        }
        finally
        {
            _syncingSelection = false;
        }

        _viewModel.SelectMonitorAt(Canvas.SelectedMonitorIndex);
        _viewModel.SelectItemAt(Canvas.SelectedItemIndex);
        SyncScopeSelection();
        _viewModel.RefreshEditFields();
        UpdateStatus();
    }

    private void Canvas_PointerWorldChanged(object? sender, Point point)
    {
        PointerText.Text = $"Pointer: {point.X:0} , {point.Y:0}";
    }

    private void Canvas_DraftRectChanging(object? sender, RectInfo rect)
    {
        _viewModel.EditX = rect.X.ToString(CultureInfo.InvariantCulture);
        _viewModel.EditY = rect.Y.ToString(CultureInfo.InvariantCulture);
        _viewModel.EditW = rect.W.ToString(CultureInfo.InvariantCulture);
        _viewModel.EditH = rect.H.ToString(CultureInfo.InvariantCulture);
    }

    private async void Canvas_DraftRectCommitted(object? sender, RectInfo rect)
    {
        var committed = await _viewModel.CommitCanvasRectAsync(rect);
        UpdateDraftOverlay();
        SyncScopeSelection();
        _viewModel.RefreshEditFields();
        UpdateStatus();

        if (!committed)
        {
            _viewModel.RefreshEditFields();
        }
    }

    private void Canvas_DraftRectCancelled(object? sender, EventArgs e)
    {
        UpdateDraftOverlay();
        _viewModel.RefreshEditFields();
        UpdateStatus();
    }

    private async void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        if (!_viewModel.CanSave || _viewModel.Draft is null)
        {
            MessageBox.Show(
                this,
                _viewModel.SaveAvailabilityText,
                "Save unavailable",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }

        var setId = _viewModel.Draft.SetId;
        var path = string.IsNullOrWhiteSpace(_viewModel.ConfigEffectivePath)
            ? _viewModel.CanonicalPath
            : _viewModel.ConfigEffectivePath;
        var confirmation = MessageBox.Show(
            this,
            $"Save set '{setId}' to the configuration file?\n\n{path}\n\n" +
            "The configuration file will be replaced. Live windows will not be moved, focused, or relaunched.",
            "Confirm configuration save",
            MessageBoxButton.YesNo,
            MessageBoxImage.Warning,
            MessageBoxResult.No);

        if (confirmation != MessageBoxResult.Yes)
        {
            return;
        }

        var saved = await _viewModel.SaveAsync();
        UpdateDraftOverlay();
        SyncSelectionFromViewModel();
        SyncScopeSelection();
        _viewModel.RefreshEditFields();
        Canvas.Fit();
        UpdateStatus();

        if (!saved && _viewModel.SaveOutcomeUncertain)
        {
            MessageBox.Show(
                this,
                "The save outcome is uncertain. The editor did not retry. Inspect the observed revision before editing or saving again.\n\n" +
                _viewModel.SaveObservedRevisionText,
                "Save outcome uncertain",
                MessageBoxButton.OK,
                MessageBoxImage.Warning);
        }
    }

    private async void PreviewButton_Click(object sender, RoutedEventArgs e)
    {
        var ok = await _viewModel.PreviewAsync();
        UpdateDraftOverlay();
        SyncScopeSelection();
        _viewModel.RefreshEditFields();

        if (!ok)
        {
            PreviewTabControl.SelectedIndex = 2;
        }
        else if (_viewModel.PreviewNoChanges)
        {
            PreviewTabControl.SelectedIndex = 1;
        }
        else
        {
            PreviewTabControl.SelectedIndex = _viewModel.PreviewWarningCount > 0 ? 2 : 1;
        }

        UpdateStatus();
    }

    private void ReviewWarningsButton_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.AcknowledgePreviewWarnings();
        UpdateStatus();
    }

    private async void RefreshButton_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.RefreshAsync();
        UpdateCanvasAfterRefresh();
        UpdateStatus();
    }

    private async void ApplyGeometryButton_Click(object sender, RoutedEventArgs e)
    {
        var applied = await _viewModel.ApplyGeometryAsync(
            _viewModel.EditX,
            _viewModel.EditY,
            _viewModel.EditW,
            _viewModel.EditH);

        if (applied)
        {
            UpdateDraftOverlay();
            SyncScopeSelection();
            _viewModel.RefreshEditFields();
        }

        UpdateStatus();
    }

    private async void RevertItemButton_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.RevertSelectedAsync();
        UpdateDraftOverlay();
        SyncScopeSelection();
        _viewModel.RefreshEditFields();
        UpdateStatus();
    }

    private async void DiscardDraftButton_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.DiscardDraftAsync(reload: _viewModel.HasDraftConflict);
        UpdateCanvasAfterRefresh();
        UpdateStatus();
    }

    private async void DiscardAndReloadButton_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.DiscardDraftAndReloadAsync();
        UpdateCanvasFromViewModel(resetView: true);
        SyncSelectionFromViewModel();
        SyncScopeSelection();
        _viewModel.RefreshEditFields();
        UpdateStatus();
    }

    private async void ConvertToRelativeButton_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.ConvertToRelativeAsync();
        UpdateDraftOverlay();
        SyncScopeSelection();
        _viewModel.RefreshEditFields();
        UpdateStatus();
    }

    private async void ConvertToAbsoluteButton_Click(object sender, RoutedEventArgs e)
    {
        await _viewModel.ConvertToAbsoluteAsync();
        UpdateDraftOverlay();
        SyncScopeSelection();
        _viewModel.RefreshEditFields();
        UpdateStatus();
    }

    private void GeometryField_PreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key == System.Windows.Input.Key.Enter)
        {
            ApplyGeometryButton_Click(sender, new RoutedEventArgs());
            e.Handled = true;
        }
    }

    private void FitButton_Click(object sender, RoutedEventArgs e)
    {
        Canvas.Fit();
        UpdateStatus();
    }

    private void ZoomInButton_Click(object sender, RoutedEventArgs e)
    {
        Canvas.ZoomBy(1.15);
        UpdateStatus();
    }

    private void ZoomOutButton_Click(object sender, RoutedEventArgs e)
    {
        Canvas.ZoomBy(1 / 1.15);
        UpdateStatus();
    }

    private void ResetViewButton_Click(object sender, RoutedEventArgs e)
    {
        Canvas.ResetView();
        UpdateStatus();
    }

    private void UpdateCanvasAfterRefresh()
    {
        if (_viewModel.HasDraftConflict)
        {
            UpdateDraftOverlay();
            UpdateStatus();
            return;
        }

        UpdateCanvasFromViewModel(resetView: false);
        SyncSelectionFromViewModel();
        SyncScopeSelection();
        _viewModel.RefreshEditFields();
    }

    private void UpdateCanvasFromViewModel(bool resetView)
    {
        _syncingSelection = true;

        try
        {
            Canvas.SetData(
                _viewModel.Monitors.Select(monitor => monitor.Info).ToList(),
                _viewModel.Items.Select(item => item.Item).ToList(),
                _viewModel.VirtualScreenRect,
                _viewModel.WarningItemIds,
                _viewModel.CanvasDraftRects,
                _viewModel.CanvasPreviewRects);

            if (resetView)
            {
                Canvas.Fit();
            }

            Canvas.SelectItem(_viewModel.SelectedItem is null ? -1 : _viewModel.Items.IndexOf(_viewModel.SelectedItem));
            Canvas.SelectMonitor(_viewModel.SelectedMonitor is null ? -1 : _viewModel.Monitors.IndexOf(_viewModel.SelectedMonitor));
        }
        finally
        {
            _syncingSelection = false;
        }

        UpdateStatus();
    }

    private void UpdateDraftOverlay()
    {
        _syncingSelection = true;

        try
        {
            Canvas.SetDraftRects(_viewModel.CanvasDraftRects);
            Canvas.SetPreviewRects(_viewModel.CanvasPreviewRects);
            Canvas.SelectItem(_viewModel.SelectedItem is null ? -1 : _viewModel.Items.IndexOf(_viewModel.SelectedItem));
            Canvas.SelectMonitor(_viewModel.SelectedMonitor is null ? -1 : _viewModel.Monitors.IndexOf(_viewModel.SelectedMonitor));
        }
        finally
        {
            _syncingSelection = false;
        }
    }

    private void SyncSelectionFromViewModel()
    {
        _syncingSelection = true;

        try
        {
            SetList.SelectedItem = _viewModel.SelectedSet;
            MonitorList.SelectedItem = _viewModel.SelectedMonitor;
            ItemList.SelectedItem = _viewModel.SelectedItem;
            Canvas.SelectItem(_viewModel.SelectedItem is null ? -1 : _viewModel.Items.IndexOf(_viewModel.SelectedItem));
            Canvas.SelectMonitor(_viewModel.SelectedMonitor is null ? -1 : _viewModel.Monitors.IndexOf(_viewModel.SelectedMonitor));
        }
        finally
        {
            _syncingSelection = false;
        }
    }

    private void SyncScopeSelection()
    {
        _syncingSelection = true;

        try
        {
            ScopeCombo.SelectedIndex = _viewModel.SelectedScope is null
                ? -1
                : _viewModel.GeometryScopes.IndexOf(_viewModel.SelectedScope);
        }
        finally
        {
            _syncingSelection = false;
        }
    }

    private void UpdateStatus()
    {
        StatusText.Text = _viewModel.StatusMessage;
        ZoomText.Text = $"Zoom {Canvas.Transform.Zoom * 100:0}%";
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_allowClose && _viewModel.IsDraftDirty)
        {
            var answer = MessageBox.Show(
                "This window has unsaved in-memory draft changes.\n\nDiscard the draft and close the editor?",
                "DevWS Editor — unsaved draft",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (answer != MessageBoxResult.Yes)
            {
                e.Cancel = true;
                return;
            }
        }

        _viewModel.Dispose();
        base.OnClosing(e);
    }

    public async Task<bool> RunSmokeAsync(string? snapshotPath, string? logPath, bool saveSmoke = false)
    {
        try
        {
            await EnsureLoadedAsync();

            if (_viewModel.HasError || _viewModel.SelectedItem is null)
            {
                WriteSmokeLog(logPath, new
                {
                    success = false,
                    error = _viewModel.ErrorText,
                    integrity = _viewModel.IntegrityText,
                    timestampUtc = DateTime.UtcNow
                });
                _allowClose = true;
                _viewModel.Dispose();
                Close();
                return false;
            }

            var initialHandshakeMs = _viewModel.HandshakeMs;
            var initialLoadMs = _viewModel.LoadMs;
            var initialMetrics = _viewModel.LoadMetrics;

            if (_viewModel.Sets.Count > 1)
            {
                await _viewModel.SelectSetAsync(_viewModel.Sets[1]);
                await _viewModel.SelectSetAsync(_viewModel.Sets[0]);
                UpdateCanvasFromViewModel(resetView: true);
                SyncSelectionFromViewModel();
                SyncScopeSelection();
            }

            var refreshWatch = Stopwatch.StartNew();
            await _viewModel.RefreshAsync();
            refreshWatch.Stop();
            UpdateCanvasAfterRefresh();
            SyncSelectionFromViewModel();
            SyncScopeSelection();

            var editItem = _viewModel.Items.FirstOrDefault(item =>
                               string.Equals(item.Item.LayoutMode, "absolute", StringComparison.Ordinal))
                           ?? _viewModel.Items.FirstOrDefault();
            _viewModel.SelectItem(editItem);
            UpdateDraftOverlay();
            SyncSelectionFromViewModel();
            SyncScopeSelection();
            _viewModel.RefreshEditFields();

            var editScope = _viewModel.SelectedScope?.Display;
            var editBeforeRect = _viewModel.GetScopeEditableRect();
            var editBefore = editBeforeRect?.Display;
            var applyWatch = Stopwatch.StartNew();
            var applied = editBeforeRect is not null &&
                await _viewModel.ApplyGeometryAsync(
                    (editBeforeRect.X + 40).ToString(CultureInfo.InvariantCulture),
                    (editBeforeRect.Y + 20).ToString(CultureInfo.InvariantCulture),
                    editBeforeRect.W.ToString(CultureInfo.InvariantCulture),
                    editBeforeRect.H.ToString(CultureInfo.InvariantCulture));
            applyWatch.Stop();
            var editAfter = _viewModel.GetScopeEditableRect()?.Display;
            var draftDirtyAfterApply = _viewModel.IsDraftDirty;
            var draftValidation = _viewModel.DraftValidationText;
            var draftErrorCount = _viewModel.DraftErrors.Count;
            UpdateDraftOverlay();
            SyncScopeSelection();
            _viewModel.RefreshEditFields();

            var canvasCommit = false;
            string? canvasBefore = null;
            string? canvasAfter = null;

            if (applied && _viewModel.GetScopeEditableRect() is { } current)
            {
                canvasBefore = current.Display;
                var canvasTarget = new RectInfo(current.X + 10, current.Y + 5, current.W, current.H);
                canvasCommit = await _viewModel.CommitCanvasRectAsync(canvasTarget);
                canvasAfter = _viewModel.GetScopeEditableRect()?.Display;
                UpdateDraftOverlay();
                SyncScopeSelection();
                _viewModel.RefreshEditFields();
            }

            await _viewModel.RevertSelectedAsync();
            var revertedDirty = _viewModel.IsDraftDirty;
            UpdateDraftOverlay();
            SyncScopeSelection();
            _viewModel.RefreshEditFields();

            var relativeEditOk = false;
            string? relativeBefore = null;
            string? relativeAfter = null;
            string? relativeNormalized = null;
            var relativeError = "";

            var relativeItem = _viewModel.Items.FirstOrDefault(item =>
                string.Equals(item.Item.LayoutMode, "relative", StringComparison.Ordinal));
            GeometryScopeOption? relativeOption = null;

            if (relativeItem is not null)
            {
                _viewModel.SelectItem(relativeItem);
                UpdateDraftOverlay();
                SyncSelectionFromViewModel();
                SyncScopeSelection();
                relativeOption = _viewModel.GeometryScopes.FirstOrDefault(scope => scope.Kind == GeometryScopeKind.Relative);
            }

            if (relativeOption is not null)
            {
                _viewModel.SelectScope(relativeOption);
                SyncScopeSelection();
                _viewModel.RefreshEditFields();
                var relativeRect = _viewModel.GetScopeEditableRect();
                relativeBefore = relativeRect?.Display;

                if (relativeRect is not null)
                {
                    relativeEditOk = await _viewModel.ApplyGeometryAsync(
                        (relativeRect.X + 25).ToString(CultureInfo.InvariantCulture),
                        relativeRect.Y.ToString(CultureInfo.InvariantCulture),
                        relativeRect.W.ToString(CultureInfo.InvariantCulture),
                        relativeRect.H.ToString(CultureInfo.InvariantCulture));
                    relativeAfter = _viewModel.GetScopeEditableRect()?.Display;
                    relativeNormalized = System.Text.Json.JsonSerializer.Serialize(
                        relativeItem is null ? null : _viewModel.Draft?.GetRelativeRect(relativeItem.Item.ItemId));
                    relativeError = _viewModel.EditErrorText;
                    UpdateDraftOverlay();
                    SyncScopeSelection();
                    _viewModel.RefreshEditFields();
                }
            }

            // Keep a visible draft edit for the screenshot and dirty-close test.
            _viewModel.SelectItem(editItem ?? _viewModel.Items.FirstOrDefault());
            UpdateDraftOverlay();
            SyncSelectionFromViewModel();
            SyncScopeSelection();
            _viewModel.RefreshEditFields();
            var finalRect = _viewModel.GetScopeEditableRect();

            if (finalRect is not null)
            {
                await _viewModel.ApplyGeometryAsync(
                    (finalRect.X + 15).ToString(CultureInfo.InvariantCulture),
                    (finalRect.Y + 10).ToString(CultureInfo.InvariantCulture),
                    finalRect.W.ToString(CultureInfo.InvariantCulture),
                    finalRect.H.ToString(CultureInfo.InvariantCulture));
            }

            UpdateDraftOverlay();
            SyncSelectionFromViewModel();
            SyncScopeSelection();
            _viewModel.RefreshEditFields();

            var previewOk = await _viewModel.PreviewAsync();
            var previewReviewRequired = _viewModel.Preview?.Review.RequiresAcknowledgement == true;
            var previewAcknowledged = previewReviewRequired && _viewModel.AcknowledgePreviewWarnings();
            var previewAckOk = !previewReviewRequired || previewAcknowledged;
            var previewDiffCount = _viewModel.PreviewDiffCount;
            var previewNoChanges = _viewModel.PreviewNoChanges;
            var previewWarningCount = _viewModel.PreviewWarningCount;
            var previewWarningDigest = _viewModel.PreviewWarningDigest;
            var previewReviewToken = _viewModel.PreviewReviewToken;
            var previewSavedRect = _viewModel.GetPreviewSavedItem()?.Rect.Display;
            var previewProposedRect = _viewModel.GetPreviewDraftItem()?.Rect.Display;
            var previewEffectiveChanged = previewSavedRect is null || previewProposedRect is null
                ? (bool?)null
                : !string.Equals(previewSavedRect, previewProposedRect, StringComparison.Ordinal);
            PreviewTabControl.SelectedIndex = previewReviewRequired ? 2 : 1;

            var saveOk = true;
            var saveDraftClean = true;
            var saveChanged = false;
            string? saveError = null;
            string? saveNewSha256 = null;
            string? savePersistedSelectedRect = null;

            if (saveSmoke)
            {
                saveOk = await _viewModel.SaveAsync();
                saveDraftClean = !_viewModel.IsDraftDirty;
                saveChanged = _viewModel.SaveResult?.Changed == true;
                saveError = _viewModel.SaveErrorText;
                saveNewSha256 = _viewModel.SaveResult?.NewSha256;
                savePersistedSelectedRect = _viewModel.SelectedItem?.Item.Rect.Display;
            }

            UpdateDraftOverlay();
            SyncSelectionFromViewModel();
            SyncScopeSelection();
            _viewModel.RefreshEditFields();
            Canvas.Fit();
            UpdateLayout();

            var finalDraftDirty = _viewModel.IsDraftDirty;
            var finalDraftItemCount = _viewModel.Draft?.DirtyItemIds().Count ?? 0;
            var finalProposed = _viewModel.SelectedItem is null
                ? null
                : _viewModel.DraftPreviewRects.TryGetValue(_viewModel.SelectedItem.Item.ItemId, out var proposed)
                    ? proposed.Display
                    : null;
            if (!string.IsNullOrWhiteSpace(snapshotPath))
            {
                SaveWindowSnapshot(snapshotPath);
            }

            string? previewDiffSnapshotPath = null;

            if (!string.IsNullOrWhiteSpace(snapshotPath))
            {
                var snapshotDirectory = Path.GetDirectoryName(Path.GetFullPath(snapshotPath));
                previewDiffSnapshotPath = Path.Combine(
                    snapshotDirectory ?? ".",
                    Path.GetFileNameWithoutExtension(snapshotPath) + "-diff" + Path.GetExtension(snapshotPath));
                PreviewTabControl.SelectedIndex = 1;
                UpdateLayout();
                SaveWindowSnapshot(previewDiffSnapshotPath);
                PreviewTabControl.SelectedIndex = previewReviewRequired ? 2 : 1;
                UpdateLayout();
            }

            var selected = _viewModel.SelectedItem?.Item;
            var evidence = new
            {
                success = applied && canvasCommit &&
                    (saveSmoke ? (saveOk && saveDraftClean) : finalDraftDirty) &&
                    previewOk && previewAckOk,
                integrity = _viewModel.IntegrityText,
                processId = Environment.ProcessId,
                backendPid = _viewModel.BackendPid,
                backendVersion = _viewModel.BackendText,
                protocol = "devws-editor/1",
                isDevelopmentConfig = _viewModel.IsDevelopmentConfig,
                configSource = _viewModel.ConfigSource,
                configRevision = _viewModel.ConfigRevision,
                configEffectivePath = _viewModel.ConfigEffectivePath,
                canonicalPath = _viewModel.CanonicalPath,
                canonicalExists = _viewModel.CanonicalExists,
                configWritable = _viewModel.Writable,
                setCount = _viewModel.Sets.Count,
                selectedSetId = _viewModel.SelectedSet?.Info.Id,
                monitorCount = _viewModel.Monitors.Count,
                itemCount = _viewModel.Items.Count,
                warningCount = _viewModel.Warnings.Count,
                selectedItemId = selected?.ItemId,
                selectedItemSource = selected?.Source,
                selectedItemPlacement = selected?.PlacementStatus,
                selectedItemRect = selected?.Rect.Display,
                editScope,
                editBefore,
                editAfter,
                applied,
                draftDirtyAfterApply,
                draftValidation,
                draftErrorCount,
                canvasCommit,
                canvasBefore,
                canvasAfter,
                revertedDirty,
                relativeEditOk,
                relativeBefore,
                relativeAfter,
                relativeNormalized,
                relativeError,
                finalDraftDirty,
                finalDraftItemCount,
                finalProposed,
                previewOk,
                previewReviewRequired,
                previewAcknowledged,
                previewAckOk,
                previewDiffCount,
                previewNoChanges,
                previewSavedRect,
                previewProposedRect,
                previewEffectiveChanged,
                previewWarningCount,
                previewWarningDigest,
                previewReviewToken,
                previewMs = Math.Round(_viewModel.LastPreviewMs, 1),
                saveSmoke,
                saveOk,
                saveDraftClean,
                saveChanged,
                saveError,
                saveNewSha256,
                savePersistedSelectedRect,
                saveMs = Math.Round(_viewModel.LastSaveMs, 1),
                saveTransportMs = Math.Round(_viewModel.LastSaveTransportMs, 1),
                saveParseMs = Math.Round(_viewModel.LastSaveParseMs, 1),
                saveModelMs = Math.Round(_viewModel.LastSaveModelMs, 1),
                previewTransportMs = Math.Round(_viewModel.LastPreviewTransportMs, 1),
                previewParseMs = Math.Round(_viewModel.LastPreviewParseMs, 1),
                previewModelMs = Math.Round(_viewModel.LastPreviewModelMs, 1),
                previewDiffSnapshotPath,
                editApplyMs = Math.Round(applyWatch.Elapsed.TotalMilliseconds, 1),
                editCommitMs = Math.Round(_viewModel.LastEditCommitMs, 1),
                validateMs = Math.Round(_viewModel.LastValidateMs, 1),
                convertMs = Math.Round(_viewModel.LastConvertMs, 1),
                draftCreateMs = Math.Round(_viewModel.LastDraftCreateMs, 1),
                projectionApplyMs = Math.Round(_viewModel.LastProjectionApplyMs, 1),
                itemsUpdateMs = Math.Round(_viewModel.LastItemsUpdateMs, 1),
                handshakeMs = Math.Round(initialHandshakeMs, 1),
                loadMs = Math.Round(initialLoadMs, 1),
                refreshMs = Math.Round(refreshWatch.Elapsed.TotalMilliseconds, 1),
                smokeElapsedMs = Math.Round(_appStopwatch.Elapsed.TotalMilliseconds, 1),
                workingSetMB = _viewModel.WorkingSetMb,
                cpuTotalMs = _viewModel.CpuTotalMs,
                projectResponseBytes = initialMetrics?.ProjectResponseBytes,
                projectParseMs = initialMetrics is null ? (double?)null : Math.Round(initialMetrics.ProjectParseMs, 1),
                projectModelMs = initialMetrics is null ? (double?)null : Math.Round(initialMetrics.ProjectModelMs, 1),
                projectRequestMs = initialMetrics is null ? (double?)null : Math.Round(initialMetrics.ProjectMs, 1),
                canvasRenderMs = Math.Round(Canvas.LastRenderMs, 2),
                canvasRenderCount = Canvas.RenderCount,
                cachedTextCount = Canvas.CachedTextCount,
                zoom = Canvas.Transform.Zoom,
                virtualScreen = _viewModel.VirtualScreenRect,
                monitors = _viewModel.Monitors.Select(monitor => new
                {
                    identity = monitor.Info.Identity,
                    friendlyName = monitor.Info.FriendlyName,
                    primary = monitor.Info.Primary,
                    monitorRect = monitor.Info.MonitorRect,
                    workRect = monitor.Info.WorkRect,
                    scalePercent = monitor.Info.ScalePercent
                }).ToArray(),
                warnings = _viewModel.Warnings.Select(warning => new
                {
                    code = warning.Info.Code,
                    message = warning.Info.Message,
                    itemId = warning.Info.Details.ItemId
                }).ToArray(),
                snapshotPath = snapshotPath,
                timestampUtc = DateTime.UtcNow
            };

            var backendPid = _viewModel.BackendPid;
            _allowClose = true;
            _viewModel.Dispose();
            var exitCode = _viewModel.BackendExitCode;
            var backendExited = _viewModel.BackendExited;

            WriteSmokeLog(logPath, new
            {
                evidence.success,
                evidence.integrity,
                evidence.processId,
                backendPid,
                backendExited,
                backendExitCode = exitCode,
                backendStderr = _viewModel.BackendStderr,
                evidence.backendVersion,
                evidence.protocol,
                evidence.isDevelopmentConfig,
                evidence.configSource,
                evidence.configRevision,
                evidence.configEffectivePath,
                evidence.canonicalPath,
                evidence.canonicalExists,
                evidence.configWritable,
                evidence.setCount,
                evidence.selectedSetId,
                evidence.monitorCount,
                evidence.itemCount,
                evidence.warningCount,
                evidence.selectedItemId,
                evidence.selectedItemSource,
                evidence.selectedItemPlacement,
                evidence.selectedItemRect,
                evidence.editScope,
                evidence.editBefore,
                evidence.editAfter,
                evidence.applied,
                evidence.draftDirtyAfterApply,
                evidence.draftValidation,
                evidence.draftErrorCount,
                evidence.canvasCommit,
                evidence.canvasBefore,
                evidence.canvasAfter,
                evidence.revertedDirty,
                evidence.relativeEditOk,
                evidence.relativeBefore,
                evidence.relativeAfter,
                evidence.relativeNormalized,
                evidence.relativeError,
                evidence.finalDraftDirty,
                evidence.finalDraftItemCount,
                evidence.finalProposed,
                evidence.previewOk,
                evidence.previewReviewRequired,
                evidence.previewAcknowledged,
                evidence.previewAckOk,
                evidence.previewDiffCount,
                evidence.previewNoChanges,
                evidence.previewSavedRect,
                evidence.previewProposedRect,
                evidence.previewEffectiveChanged,
                evidence.previewWarningCount,
                evidence.previewWarningDigest,
                evidence.previewReviewToken,
                evidence.previewMs,
                evidence.saveSmoke,
                evidence.saveOk,
                evidence.saveDraftClean,
                evidence.saveChanged,
                evidence.saveError,
                evidence.saveNewSha256,
                evidence.savePersistedSelectedRect,
                evidence.saveMs,
                evidence.saveTransportMs,
                evidence.saveParseMs,
                evidence.saveModelMs,
                evidence.previewTransportMs,
                evidence.previewParseMs,
                evidence.previewModelMs,
                evidence.previewDiffSnapshotPath,
                evidence.editApplyMs,
                evidence.editCommitMs,
                evidence.validateMs,
                evidence.convertMs,
                evidence.draftCreateMs,
                evidence.projectionApplyMs,
                evidence.itemsUpdateMs,
                evidence.handshakeMs,
                evidence.loadMs,
                evidence.refreshMs,
                evidence.smokeElapsedMs,
                evidence.workingSetMB,
                evidence.cpuTotalMs,
                evidence.projectResponseBytes,
                evidence.projectParseMs,
                evidence.projectModelMs,
                evidence.projectRequestMs,
                evidence.canvasRenderMs,
                evidence.canvasRenderCount,
                evidence.cachedTextCount,
                evidence.zoom,
                evidence.virtualScreen,
                evidence.monitors,
                evidence.warnings,
                evidence.snapshotPath,
                evidence.timestampUtc
            });

            Close();
            return true;
        }
        catch (Exception ex)
        {
            WriteSmokeLog(logPath, new
            {
                success = false,
                error = ex.Message,
                errorType = ex.GetType().Name,
                integrity = _viewModel.IntegrityText,
                timestampUtc = DateTime.UtcNow
            });
            _allowClose = true;
            _viewModel.Dispose();
            Close();
            return false;
        }
    }

    public void SaveWindowSnapshot(string path)
    {
        if (Content is not FrameworkElement root)
        {
            return;
        }

        var width = Math.Max(1, (int)Math.Ceiling(root.ActualWidth));
        var height = Math.Max(1, (int)Math.Ceiling(root.ActualHeight));
        root.Measure(new Size(width, height));
        root.Arrange(new Rect(0, 0, width, height));
        root.UpdateLayout();

        var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(root);

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));

        var directory = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        using var stream = File.Create(path);
        encoder.Save(stream);
    }

    private static void WriteSmokeLog(string? path, object value)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return;
        }

        var directory = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var json = JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json);
    }
}
