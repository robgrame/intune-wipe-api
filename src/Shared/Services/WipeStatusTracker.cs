using Azure;
using Azure.Data.Tables;
using IntuneWipeApi.Models;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Services;

/// <summary>
/// Persists per-wipe status rows in a dedicated Azure Table (one row per
/// correlationId) and runs the Graph poll that drives state transitions.
/// </summary>
/// <remarks>
/// <para>
/// The wipe is asynchronous on Intune's side: the moment <see cref="GraphWipeService.WipeAsync"/>
/// returns we only know the action was *enqueued*; whether the device picked
/// it up, executed it, failed, or wandered offline takes minutes to hours to
/// observe. This tracker closes that loop:
/// </para>
/// <list type="number">
///   <item><description>
///     <see cref="InitializeAsync"/> is called right after a successful wipe
///     issue → writes a row <c>{Terminal=false, LastState=pending, IssuedAt=now}</c>.
///   </description></item>
///   <item><description>
///     A timer trigger (<c>WipeStatusPollerFunction</c>) enumerates all
///     non-terminal rows whose age is &lt; <see cref="PollMaxAgeHours"/> and
///     calls <see cref="PollOneAsync"/> for each. Graph returns the current
///     <c>deviceActionResults[wipe].actionState</c>, transitions are recorded
///     to App Insights + audit table.
///   </description></item>
///   <item><description>
///     On a terminal state (<c>done</c>, <c>failed</c>, <c>canceled</c>,
///     <c>notSupported</c>, <c>removedFromIntune</c>) the row is marked
///     <c>Terminal=true</c> and stops being polled. Older non-terminal rows
///     exceeding <see cref="PollMaxAgeHours"/> are flipped to
///     <c>Terminal=true, LastState=pollTimeout</c>.
///   </description></item>
/// </list>
/// <para>
/// Schema: PartitionKey = correlationId (so each row is independent and the
/// table scales horizontally), RowKey = "status" (single canonical row per
/// wipe — upsert semantics).
/// </para>
/// </remarks>
public sealed class WipeStatusTracker
{
    public const string RowKeyStatus = "status";

    // Terminal states. Once a row hits one of these we stop polling.
    private static readonly HashSet<string> TerminalStates = new(StringComparer.OrdinalIgnoreCase)
    {
        "done", "failed", "canceled", "notsupported", "removedfromintune", "polltimeout"
    };

    // States that indicate success vs failure for the audit completion event.
    private static readonly HashSet<string> SuccessStates = new(StringComparer.OrdinalIgnoreCase)
    {
        "done", "removedfromintune"
    };

    private readonly TableClient? _table;
    private readonly GraphWipeService? _graph;
    private readonly AuditService _audit;
    private readonly ILogger<WipeStatusTracker> _log;
    private readonly int _pollMaxAgeHours;

    public WipeStatusTracker(TableClient? table, GraphWipeService? graph, AuditService audit,
        IConfiguration cfg, ILogger<WipeStatusTracker> log)
    {
        _table = table;
        _graph = graph;
        _audit = audit;
        _log = log;
        _pollMaxAgeHours = int.TryParse(cfg["Wipe:StatusPollMaxAgeHours"], out var h) ? Math.Max(1, h) : 24;
    }

    public bool IsEnabled => _table is not null;
    public int PollMaxAgeHours => _pollMaxAgeHours;

    /// <summary>
    /// Read the current status row for a correlationId. Returns null if no
    /// tracking row exists (either the wipe was never issued, the row was
    /// purged, or the storage backend is disabled).
    /// </summary>
    public async Task<WipeStatusSnapshot?> GetStatusAsync(string correlationId, CancellationToken ct)
    {
        if (_table is null || string.IsNullOrWhiteSpace(correlationId)) return null;
        try
        {
            var resp = await _table.GetEntityAsync<TableEntity>(SanitizeKey(correlationId), RowKeyStatus, cancellationToken: ct).ConfigureAwait(false);
            var row = resp.Value;
            return new WipeStatusSnapshot(
                CorrelationId:    correlationId,
                DeviceName:       row.GetString("DeviceName") ?? string.Empty,
                EntraDeviceId:    row.GetString("EntraDeviceId") ?? string.Empty,
                IntuneDeviceId:   row.GetString("IntuneDeviceId") ?? string.Empty,
                ManagedDeviceId:  row.GetString("ManagedDeviceId") ?? string.Empty,
                LastState:        row.GetString("LastState") ?? "unknown",
                PreviousState:    row.GetString("PreviousState") ?? string.Empty,
                Terminal:         row.GetBoolean("Terminal") ?? false,
                IssuedAt:         row.GetDateTimeOffset("IssuedAt") ?? DateTimeOffset.MinValue,
                LastPolledAt:     row.GetDateTimeOffset("LastPolledAt") ?? DateTimeOffset.MinValue,
                LastChangedAt:    row.GetDateTimeOffset("LastChangedAt") ?? DateTimeOffset.MinValue,
                PollAttempts:     row.GetInt32("PollAttempts") ?? 0);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }

    /// <summary>
    /// Creates the initial status row right after a wipe was successfully issued.
    /// Idempotent (uses upsert) — re-issuing for the same correlationId resets
    /// the tracking row without throwing.
    /// </summary>
    public async Task InitializeAsync(WipeQueueMessage msg, string managedDeviceId, CancellationToken ct)
    {
        if (_table is null) return;

        var now = DateTimeOffset.UtcNow;
        var entity = new TableEntity(SanitizeKey(msg.CorrelationId), RowKeyStatus)
        {
            { "ManagedDeviceId", managedDeviceId },
            { "DeviceName",      msg.DeviceName ?? string.Empty },
            { "EntraDeviceId",   msg.EntraDeviceId ?? string.Empty },
            { "IntuneDeviceId",  msg.IntuneDeviceId ?? string.Empty },
            { "IssuedAt",        now },
            { "LastPolledAt",    DateTimeOffset.MinValue },
            { "LastChangedAt",   now },
            { "LastState",       "pending" },
            { "PreviousState",   string.Empty },
            { "PollAttempts",    0 },
            { "Terminal",        false },
        };

        try
        {
            await _table.UpsertEntityAsync(entity, TableUpdateMode.Replace, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            // Initialization failure is logged but not fatal — the wipe is
            // already issued, only the tracking is degraded.
            _log.LogWarning(ex, "WipeStatusTracker: failed to initialize row for {Corr}", msg.CorrelationId);
        }
    }

    /// <summary>
    /// Enumerates all non-terminal status rows for the poller. Includes a
    /// cap on PollMaxAgeHours so we don't poll forever — rows older than that
    /// get flipped to Terminal=true with LastState=pollTimeout on the next pass.
    /// </summary>
    public IAsyncEnumerable<TableEntity> EnumeratePendingAsync(CancellationToken ct)
    {
        if (_table is null) return AsyncEmpty();

        // OData filter — Table service evaluates this server-side.
        return _table.QueryAsync<TableEntity>(filter: "Terminal eq false", cancellationToken: ct);

        static async IAsyncEnumerable<TableEntity> AsyncEmpty()
        {
            await Task.CompletedTask;
            yield break;
        }
    }

    /// <summary>
    /// Polls Graph for one tracking row, updates state, and audits transitions.
    /// </summary>
    public async Task PollOneAsync(TableEntity row, CancellationToken ct)
    {
        if (_table is null) return;
        if (_graph is null)
        {
            // Defensive guard: PollOneAsync is only called by the Proc poller,
            // which must register GraphWipeService. Web never calls this method
            // (it only reads via GetStatusAsync) and therefore doesn't need Graph.
            throw new InvalidOperationException(
                "WipeStatusTracker.PollOneAsync requires GraphWipeService. " +
                "Register it in the host via services.AddGraphWipe().");
        }

        var correlationId    = row.PartitionKey;
        var managedDeviceId  = row.GetString("ManagedDeviceId") ?? string.Empty;
        var deviceName       = row.GetString("DeviceName") ?? string.Empty;
        var issuedAt         = row.GetDateTimeOffset("IssuedAt") ?? DateTimeOffset.UtcNow;
        var previousState    = row.GetString("LastState") ?? "pending";
        var attempts         = row.GetInt32("PollAttempts") ?? 0;

        // Time-based give-up: don't poll forever on a device that never reports.
        if (DateTimeOffset.UtcNow - issuedAt > TimeSpan.FromHours(_pollMaxAgeHours))
        {
            await MarkTerminalAsync(row, "pollTimeout", previousState, ct).ConfigureAwait(false);
            _audit.TrackEvent(AuditEvents.ActionPollTimeout, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]   = correlationId,
                [AuditEvents.Prop.DeviceName]      = deviceName,
                [AuditEvents.Prop.ManagedDeviceId] = managedDeviceId,
                [AuditEvents.Prop.PreviousState]   = previousState,
                [AuditEvents.Prop.IssuedAt]        = issuedAt.ToString("o"),
                [AuditEvents.Prop.PollAttempts]    = attempts.ToString(),
            }, Microsoft.Extensions.Logging.LogLevel.Warning);
            return;
        }

        WipeStatusTracker.WipeActionSnapshotShim snap;
        try
        {
            var s = await _graph.GetWipeActionStatusAsync(managedDeviceId, ct).ConfigureAwait(false);
            snap = new WipeStatusTracker.WipeActionSnapshotShim(
                s.State, s.ActionStartedAt, s.ActionLastUpdated,
                s.DeviceLastSync, s.ComplianceState, s.OsVersion, s.OperatingSystem);
        }
        catch (Exception ex)
        {
            // Transient Graph error — bump attempts and try again next tick.
            row["PollAttempts"] = attempts + 1;
            row["LastPolledAt"] = DateTimeOffset.UtcNow;
            try { await _table.UpdateEntityAsync(row, row.ETag, TableUpdateMode.Replace, ct).ConfigureAwait(false); }
            catch (RequestFailedException) { /* ETag mismatch — another poller won, skip */ }

            _audit.TrackEvent(AuditEvents.ActionPollError, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]   = correlationId,
                [AuditEvents.Prop.DeviceName]      = deviceName,
                [AuditEvents.Prop.ManagedDeviceId] = managedDeviceId,
                [AuditEvents.Prop.PollAttempts]    = (attempts + 1).ToString(),
            }, Microsoft.Extensions.Logging.LogLevel.Warning);
            return;
        }

        var currentState     = snap.State;
        var graphLastUpdated = snap.ActionLastUpdated;
        var now = DateTimeOffset.UtcNow;
        var stateChanged = !string.Equals(previousState, currentState, StringComparison.OrdinalIgnoreCase);
        var isTerminal   = TerminalStates.Contains(currentState);

        row["LastPolledAt"] = now;
        row["PollAttempts"] = attempts + 1;
        row["LastState"]    = currentState;
        if (stateChanged)
        {
            row["PreviousState"] = previousState;
            row["LastChangedAt"] = now;
        }
        if (graphLastUpdated.HasValue)
        {
            row["GraphLastUpdated"] = graphLastUpdated.Value;
        }
        if (snap.ActionStartedAt.HasValue)   row["GraphActionStartedAt"] = snap.ActionStartedAt.Value;
        if (snap.DeviceLastSync.HasValue)    row["DeviceLastSync"]       = snap.DeviceLastSync.Value;
        if (!string.IsNullOrEmpty(snap.ComplianceState)) row["ComplianceState"] = snap.ComplianceState;
        if (!string.IsNullOrEmpty(snap.OsVersion))       row["OsVersion"]       = snap.OsVersion;
        if (!string.IsNullOrEmpty(snap.OperatingSystem)) row["OperatingSystem"] = snap.OperatingSystem;
        row["Terminal"] = isTerminal;

        try
        {
            await _table.UpdateEntityAsync(row, row.ETag, TableUpdateMode.Replace, ct).ConfigureAwait(false);
        }
        catch (RequestFailedException ex) when (ex.Status == 412)
        {
            // Concurrent update by another poller instance — drop this attempt; the other one wins.
            return;
        }

        // Build the rich context that every action-tracking event will carry.
        // Computed once, used by the heartbeat + transition + terminal events.
        var ctxBase = new Dictionary<string, string>
        {
            [AuditEvents.Prop.CorrelationId]    = correlationId,
            [AuditEvents.Prop.DeviceName]       = deviceName,
            [AuditEvents.Prop.ManagedDeviceId]  = managedDeviceId,
            [AuditEvents.Prop.PreviousState]    = previousState,
            [AuditEvents.Prop.CurrentState]     = currentState,
            [AuditEvents.Prop.PollAttempts]     = (attempts + 1).ToString(),
            [AuditEvents.Prop.IssuedAt]         = issuedAt.ToString("o"),
        };
        if (graphLastUpdated.HasValue)
            ctxBase[AuditEvents.Prop.GraphActionLastUpdated] = graphLastUpdated.Value.ToString("o");
        if (snap.ActionStartedAt.HasValue)
            ctxBase[AuditEvents.Prop.GraphActionStartedAt]   = snap.ActionStartedAt.Value.ToString("o");
        if (snap.DeviceLastSync.HasValue)
        {
            ctxBase[AuditEvents.Prop.DeviceLastSync]      = snap.DeviceLastSync.Value.ToString("o");
            ctxBase[AuditEvents.Prop.MinutesSinceLastSync] = ((int)(now - snap.DeviceLastSync.Value).TotalMinutes).ToString();
        }
        if (!string.IsNullOrEmpty(snap.ComplianceState)) ctxBase[AuditEvents.Prop.DeviceComplianceState] = snap.ComplianceState;
        if (!string.IsNullOrEmpty(snap.OsVersion))       ctxBase[AuditEvents.Prop.DeviceOsVersion]       = snap.OsVersion;
        if (!string.IsNullOrEmpty(snap.OperatingSystem)) ctxBase[AuditEvents.Prop.DeviceOperatingSystem] = snap.OperatingSystem;

        // Heartbeat: emit on every poll so operators can confirm the poller
        // actually ran for this correlationId, even when state is unchanged.
        // Information level — sampling may drop in high-volume tenants but the
        // table row in wipestatus always has the authoritative LastPolledAt.
        _audit.TrackEvent(AuditEvents.ActionStateObserved, new Dictionary<string, string>(ctxBase),
            Microsoft.Extensions.Logging.LogLevel.Information);

        // Audit transitions; on terminal also emit completed/failed.
        if (stateChanged)
        {
            _audit.TrackEvent(AuditEvents.ActionStateChanged, new Dictionary<string, string>(ctxBase));
        }

        if (isTerminal)
        {
            var name  = SuccessStates.Contains(currentState) ? AuditEvents.ActionCompleted : AuditEvents.ActionFailed;
            var level = SuccessStates.Contains(currentState)
                ? Microsoft.Extensions.Logging.LogLevel.Information
                : Microsoft.Extensions.Logging.LogLevel.Warning;
            var ctxTerminal = new Dictionary<string, string>(ctxBase)
            {
                [AuditEvents.Prop.LastChangedAt] = now.ToString("o"),
            };
            _audit.TrackEvent(name, ctxTerminal, level);
        }
    }

    /// <summary>
    /// Internal shim so PollOneAsync can pass the Graph snapshot around without
    /// taking a hard dependency on the GraphWipeService nested type at every
    /// call site (also makes future test mocks easier).
    /// </summary>
    internal sealed record WipeActionSnapshotShim(
        string State,
        DateTimeOffset? ActionStartedAt,
        DateTimeOffset? ActionLastUpdated,
        DateTimeOffset? DeviceLastSync,
        string? ComplianceState,
        string? OsVersion,
        string? OperatingSystem);

    private async Task MarkTerminalAsync(TableEntity row, string state, string previousState, CancellationToken ct)
    {
        if (_table is null) return;
        var now = DateTimeOffset.UtcNow;
        row["LastState"]     = state;
        row["PreviousState"] = previousState;
        row["LastChangedAt"] = now;
        row["LastPolledAt"]  = now;
        row["Terminal"]      = true;
        try { await _table.UpdateEntityAsync(row, row.ETag, TableUpdateMode.Replace, ct).ConfigureAwait(false); }
        catch (RequestFailedException) { /* concurrent write — drop */ }
    }

    private static string SanitizeKey(string key)
    {
        if (string.IsNullOrEmpty(key)) return "_";
        var sb = new System.Text.StringBuilder(key.Length);
        foreach (var c in key)
        {
            sb.Append(c is '/' or '\\' or '#' or '?' || char.IsControl(c) ? '_' : c);
            if (sb.Length >= 256) break;
        }
        return sb.ToString();
    }
}
