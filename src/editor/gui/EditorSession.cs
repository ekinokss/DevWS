using System.Diagnostics;
using System.Text.Json;

namespace DevWS.Editor;

public sealed record EditorLoadMetrics(
    double HandshakeMs,
    double InspectMs,
    double ReadConfigMs,
    double ProjectMs,
    double TotalMs);

public sealed class EditorSession : IDisposable
{
    private static readonly Dictionary<string, object?> EmptyParameters = new();
    private readonly BackendClient _client;
    private bool _disposed;

    public EditorSession(BackendClient client)
    {
        _client = client;
    }

    public BackendClient Client => _client;
    public EditorLoadMetrics? LastLoadMetrics { get; private set; }

    public async Task<EditorSnapshot> LoadAsync(
        string? setId,
        CancellationToken cancellationToken = default)
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(EditorSession));
        }

        var total = Stopwatch.StartNew();
        var hello = await _client.ConnectAsync(cancellationToken).ConfigureAwait(false);
        var handshakeMs = _client.LastConnectMs;

        var inspectWatch = Stopwatch.StartNew();
        var inspectResponse = await _client
            .SendAsync("inspect", EmptyParameters, cancellationToken)
            .ConfigureAwait(false);
        inspectWatch.Stop();
        var inspect = InspectInfo.Parse(inspectResponse.Result);

        if (string.IsNullOrWhiteSpace(inspect.Config.Sha256))
        {
            throw new EditorException(
                "protocol-error",
                "The editor backend did not return a configuration revision.");
        }

        var readWatch = Stopwatch.StartNew();
        var readResponse = await _client
            .SendAsync(
                "read-config",
                new Dictionary<string, object?> { ["expectedSha256"] = inspect.Config.Sha256 },
                cancellationToken)
            .ConfigureAwait(false);
        readWatch.Stop();

        var readHash = JsonText.String(readResponse.Result, "sha256");
        if (!string.Equals(readHash, inspect.Config.Sha256, StringComparison.Ordinal))
        {
            throw new EditorException(
                "external-change",
                "The configuration changed while the editor was loading. Refresh to load a consistent revision.",
                requiresRefresh: true,
                details: $"inspect={inspect.Config.Sha256}; read-config={readHash}");
        }

        var document = default(JsonElement);
        if (readResponse.Result.ValueKind == JsonValueKind.Object &&
            readResponse.Result.TryGetProperty("document", out var documentElement))
        {
            document = documentElement.Clone();
        }

        var projectWatch = Stopwatch.StartNew();
        var projectResponse = await ProjectCoreAsync(setId, cancellationToken).ConfigureAwait(false);
        projectWatch.Stop();
        var projection = WorkspaceProjection.Parse(projectResponse.Result, projectResponse.Warnings);

        EnsureConsistent(inspect, projection);

        total.Stop();
        LastLoadMetrics = new EditorLoadMetrics(
            handshakeMs,
            inspectWatch.Elapsed.TotalMilliseconds,
            readWatch.Elapsed.TotalMilliseconds,
            projectWatch.Elapsed.TotalMilliseconds,
            total.Elapsed.TotalMilliseconds);

        return new EditorSnapshot(hello, inspect, projection, readHash, document);
    }

    public async Task<WorkspaceProjection> ProjectAsync(
        string setId,
        string expectedRevision,
        string? expectedFingerprint,
        CancellationToken cancellationToken = default)
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(EditorSession));
        }

        if (string.IsNullOrWhiteSpace(setId))
        {
            throw new EditorException("set-not-found", "A workspace set id is required.");
        }

        var response = await _client
            .SendAsync(
                "project",
                new Dictionary<string, object?> { ["setId"] = setId },
                cancellationToken)
            .ConfigureAwait(false);
        var projection = WorkspaceProjection.Parse(response.Result, response.Warnings);

        if (!string.Equals(projection.ConfigRevision, expectedRevision, StringComparison.Ordinal))
        {
            throw new EditorException(
                "external-change",
                "The configuration changed before the selected set could be projected. Refresh to load a consistent revision.",
                requiresRefresh: true,
                details: $"expected={expectedRevision}; actual={projection.ConfigRevision}");
        }

        if (!string.Equals(
                projection.Topology.Fingerprint ?? "",
                expectedFingerprint ?? "",
                StringComparison.Ordinal))
        {
            throw new EditorException(
                "topology-changed",
                "The monitor topology changed before the selected set could be projected. Refresh to load a consistent topology.",
                requiresRefresh: true,
                details: $"expected={expectedFingerprint ?? "<none>"}; actual={projection.Topology.Fingerprint ?? "<none>"}");
        }

        return projection;
    }

    private Task<BackendResponse> ProjectCoreAsync(string? setId, CancellationToken cancellationToken)
    {
        var parameters = string.IsNullOrWhiteSpace(setId)
            ? EmptyParameters
            : new Dictionary<string, object?> { ["setId"] = setId };
        return _client.SendAsync("project", parameters, cancellationToken);
    }

    private static void EnsureConsistent(InspectInfo inspect, WorkspaceProjection projection)
    {
        if (!string.Equals(projection.ConfigRevision, inspect.Config.Sha256, StringComparison.Ordinal))
        {
            throw new EditorException(
                "external-change",
                "The configuration changed between inspect and project. Refresh to load a consistent revision.",
                requiresRefresh: true,
                details: $"inspect={inspect.Config.Sha256}; project={projection.ConfigRevision}");
        }

        if (!string.Equals(
                inspect.Topology.Fingerprint,
                projection.Topology.Fingerprint,
                StringComparison.Ordinal))
        {
            throw new EditorException(
                "topology-changed",
                "The monitor topology changed between inspect and project. Refresh to load a consistent topology.",
                requiresRefresh: true,
                details: $"inspect={inspect.Topology.Fingerprint ?? "<none>"}; project={projection.Topology.Fingerprint ?? "<none>"}");
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _client.Dispose();
    }
}
