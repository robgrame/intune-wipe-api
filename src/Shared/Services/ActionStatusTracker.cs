using Azure;
using Azure.Data.Tables;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Models;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Services;

/// <summary>
/// Persists per-action status rows in a dedicated Azure Table (one row per
/// correlationId) and drives the polling loop via per-capability
/// <see cref="IActionStatusProbe"/> implementations.
/// </summary>
/// <remarks>
/// <para>
/// Actions are asynchronous on the back-end (Intune): the moment the runner
/// issues the back-end call we only know the request was *enqueued*; whether
/// the device picked it up, executed it, failed, or wandered offline takes
/// minutes to hours to observe. This tracker closes that loop:
/// </para>
/// <list type="number">
///   <item><description>
///     <see cref="InitializeAsync"/> is called right after a successful action
///     issue → writes a row <c>{Terminal=false, LastState=pending, IssuedAt=now,
///     ActionType=actionType}</c>.
///   </description></item>
///   <item><description>
///     A timer trigger (<c>ActionStatusPollerFunction</c>) enumerates all
///     non-terminal rows whose age is &lt; <see cref="PollMaxAgeHours"/> and
///     calls <see cref="PollOneAsync"/> for each. The tracker selects the
///     matching <see cref="IActionStatusProbe"/> by row's <c>ActionType</c>
///     column, gets the current state, and records transitions to App
///     Insights + audit table.
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
/// Schema: PartitionKey = correlationId (each row is independent and the table
/// scales horizontally), RowKey = "status" (single canonical row per action —
/// upsert semantics).
/// </para>
/// </remarks>
public sealed class ActionStatusTracker
{
    public const string RowKeyStatus = "status";

    // Sentinel "never" timestamp. Azure Table rejects DateTimeOffset.MinValue
    // (0001-01-01) because the service min is 1601-01-01; using Unix epoch
    // (1970-01-01) is safely above the floor and unambiguous as "never set".
    private static readonly DateTimeOffset NeverTimestamp = DateTimeOffset.FromUnixTimeSeconds(0);

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
    private readonly Dictionary<string, IActionStatusProbe> _probes;
    private readonly AuditService _audit;
    private readonly ILogger<ActionStatusTracker> _log;
    private readonly int _pollMaxAgeHours;
    // Lazy table provisioning: instead of calling CreateIfNotExists() at DI
    // resolution time (which permanently disables the tracker on a single
    // transient cold-start failure — e.g. DNS for a freshly-created private
    // endpoint hasn't propagated), we attempt it on the first WRITE call and
    // retry on every subsequent write until it succeeds. Reads don't require
    // it (the table service returns 404 for both "table missing" and "entity
    // missing", which we already collapse to "no row").
    private readonly SemaphoreSlim _ensureLock = new(1, 1);
    private volatile bool _tableEnsured;

    public ActionStatusTracker(TableClient? table, IEnumerable<IActionStatusProbe> probes,
        AuditService audit, IConfiguration cfg, ILogger<ActionStatusTracker> log)
    {
        _table = table;
        _probes = (probes ?? Array.Empty<IActionStatusProbe>())
            .ToDictionary(p => p.ActionType, p => p, StringComparer.OrdinalIgnoreCase);
        _audit = audit;
        _log = log;
        _pollMaxAgeHours = int.TryParse(cfg["ActionStatus:PollMaxAgeHours"], out var h) ? Math.Max(1, h) : 24;
    }

    public bool IsEnabled => _table is not null;
    public int PollMaxAgeHours => _pollMaxAgeHours;

    /// <summary>
    /// Single-flight, retry-on-failure provisioning of the underlying table.
    /// Returns true once we know the table exists. If the call fails (RBAC,
    /// network, transient throttling) we log a warning and return false; the
    /// next write attempt will try again — we never permanently disable the
    /// tracker for a recoverable failure.
    /// </summary>
    private async Task<bool> EnsureTableExistsAsync(CancellationToken ct)
    {
        if (_table is null) return false;
        if (_tableEnsured) return true;

        await _ensureLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_tableEnsured) return true;
            await _table.CreateIfNotExistsAsync(ct).ConfigureAwait(false);
            _tableEnsured = true;
            return true;
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex,
                "ActionStatusTracker.EnsureTableExistsAsync failed for table '{Table}'; " +
                "will retry on the next write. Cause is usually RBAC or network ACLs.",
                _table.Name);
            return false;
        }
        finally
        {
            _ensureLock.Release();
        }
    }

    /// <summary>
    /// Read the current status row for a correlationId. Returns null if no
    /// tracking row exists (either the action was never issued, the row was
    /// purged, or the storage backend is disabled).
    /// </summary>
    public async Task<ActionStatusSnapshot?> GetStatusAsync(string correlationId, CancellationToken ct)
    {
        if (_table is null || string.IsNullOrWhiteSpace(correlationId)) return null;
        try
        {
            var resp = await _table.GetEntityAsync<TableEntity>(SanitizeKey(correlationId), RowKeyStatus, cancellationToken: ct).ConfigureAwait(false);
            var row = resp.Value;
            return new ActionStatusSnapshot(
                CorrelationId:    correlationId,
                DeviceName:       row.GetString("DeviceName") ?? string.Empty,
                EntraDeviceId:    row.GetString("EntraDeviceId") ?? string.Empty,
                IntuneDeviceId:   row.GetString("IntuneDeviceId") ?? string.Empty,
                ManagedDeviceId:  row.GetString("ManagedDeviceId") ?? string.Empty,
                LastState:        row.GetString("LastState") ?? "unknown",
                PreviousState:    row.GetString("PreviousState") ?? string.Empty,
                Terminal:         row.GetBoolean("Terminal") ?? false,
                IssuedAt:         row.GetDateTimeOffset("IssuedAt") ?? NeverTimestamp,
                LastPolledAt:     row.GetDateTimeOffset("LastPolledAt") ?? NeverTimestamp,
                LastChangedAt:    row.GetDateTimeOffset("LastChangedAt") ?? NeverTimestamp,
                PollAttempts:     row.GetInt32("PollAttempts") ?? 0);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }

    /// <summary>
    /// Creates the initial status row right after an action was successfully
    /// issued. Idempotent (uses upsert) — re-issuing for the same
    /// correlationId resets the tracking row without throwing.
    /// </summary>
    public async Task InitializeAsync(ActionRequestMessage msg, string actionType,
        string managedDeviceId, CancellationToken ct)
    {
        if (_table is null) return;
        if (!await EnsureTableExistsAsync(ct).ConfigureAwait(false)) return;

        var now = DateTimeOffset.UtcNow;
        var entity = new TableEntity(SanitizeKey(msg.CorrelationId), RowKeyStatus)
        {
            { "ActionType",      string.IsNullOrWhiteSpace(actionType) ? "wipe" : actionType.ToLowerInvariant() },
            { "ManagedDeviceId", managedDeviceId },
            { "DeviceName",      msg.DeviceName ?? string.Empty },
            { "EntraDeviceId",   msg.EntraDeviceId ?? string.Empty },
            { "IntuneDeviceId",  msg.IntuneDeviceId ?? string.Empty },
            { "IssuedAt",        now },
            { "LastPolledAt",    NeverTimestamp },
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
            // Initialization failure is logged but not fatal — the action is
            // already issued, only the tracking is degraded.
            _log.LogWarning(ex, "ActionStatusTracker: failed to initialize row for {Corr}", msg.CorrelationId);
        }
    }

    /// <summary>
    /// Writes a terminal status row for a request that never reached
    /// <see cref="InitializeAsync"/> (denial paths, permanent backend failure,
    /// idempotency collisions). Operators querying /api/actions/status get a
    /// definitive answer (the row's <c>LastState</c> carries the reason
    /// prefix, e.g. <c>denied:device-not-in-entra</c>) instead of an
    /// ambiguous 404. Terminal=true keeps the poller from picking these rows
    /// up. Best-effort: failures are logged, never thrown — the original
    /// audit event remains the source of truth.
    /// </summary>
    public async Task RecordTerminalAsync(ActionRequestMessage msg, string actionType,
        string state, CancellationToken ct, string managedDeviceId = "")
    {
        if (_table is null) return;
        if (string.IsNullOrWhiteSpace(msg?.CorrelationId)) return;
        if (!await EnsureTableExistsAsync(ct).ConfigureAwait(false)) return;

        var now = DateTimeOffset.UtcNow;
        var entity = new TableEntity(SanitizeKey(msg.CorrelationId), RowKeyStatus)
        {
            { "ActionType",      string.IsNullOrWhiteSpace(actionType) ? "unknown" : actionType.ToLowerInvariant() },
            { "ManagedDeviceId", managedDeviceId ?? string.Empty },
            { "DeviceName",      msg.DeviceName ?? string.Empty },
            { "EntraDeviceId",   msg.EntraDeviceId ?? string.Empty },
            { "IntuneDeviceId",  msg.IntuneDeviceId ?? string.Empty },
            { "IssuedAt",        now },
            { "LastPolledAt",    NeverTimestamp },
            { "LastChangedAt",   now },
            { "LastState",       string.IsNullOrWhiteSpace(state) ? "denied:unknown" : state },
            { "PreviousState",   string.Empty },
            { "PollAttempts",    0 },
            { "Terminal",        true },
        };

        try
        {
            await _table.UpsertEntityAsync(entity, TableUpdateMode.Replace, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex,
                "ActionStatusTracker.RecordTerminalAsync failed for {Corr} state={State}",
                msg.CorrelationId, state);
        }
    }

    /// <summary>
    /// Enumerates all non-terminal status rows for the poller. Includes a cap
    /// on PollMaxAgeHours so we don't poll forever — rows older than that get
    /// flipped to Terminal=true with LastState=pollTimeout on the next pass.
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
    /// Polls the back-end for one tracking row, updates state, and audits
    /// transitions. Dispatches to the registered <see cref="IActionStatusProbe"/>
    /// matching the row's <c>ActionType</c> column.
    /// </summary>
    public async Task PollOneAsync(TableEntity row, CancellationToken ct)
    {
        if (_table is null) return;

        var correlationId    = row.PartitionKey;
        var actionType       = (row.GetString("ActionType") ?? "wipe").ToLowerInvariant();
        var managedDeviceId  = row.GetString("ManagedDeviceId") ?? string.Empty;
        var deviceName       = row.GetString("DeviceName") ?? string.Empty;
        var issuedAt         = row.GetDateTimeOffset("IssuedAt") ?? DateTimeOffset.UtcNow;
        var previousState    = row.GetString("LastState") ?? "pending";
        var attempts         = row.GetInt32("PollAttempts") ?? 0;

        if (!_probes.TryGetValue(actionType, out var probe))
        {
            // Capability is not registered on this host (e.g. status poller
            // running on a role that doesn't have the wipe probe loaded).
            // Bump attempts and skip — operator-visible via the audit event.
            _audit.TrackEvent(AuditEvents.ActionPollError, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]   = correlationId,
                [AuditEvents.Prop.ActionType]      = actionType,
                [AuditEvents.Prop.DeviceName]      = deviceName,
                [AuditEvents.Prop.ManagedDeviceId] = managedDeviceId,
                [AuditEvents.Prop.Reason]          = "no-probe-registered",
            }, Microsoft.Extensions.Logging.LogLevel.Warning);
            return;
        }

        // Time-based give-up: don't poll forever on a device that never reports.
        if (DateTimeOffset.UtcNow - issuedAt > TimeSpan.FromHours(_pollMaxAgeHours))
        {
            await MarkTerminalAsync(row, "pollTimeout", previousState, ct).ConfigureAwait(false);
            _audit.TrackEvent(AuditEvents.ActionPollTimeout, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]   = correlationId,
                [AuditEvents.Prop.ActionType]      = actionType,
                [AuditEvents.Prop.DeviceName]      = deviceName,
                [AuditEvents.Prop.ManagedDeviceId] = managedDeviceId,
                [AuditEvents.Prop.PreviousState]   = previousState,
                [AuditEvents.Prop.IssuedAt]        = issuedAt.ToString("o"),
                [AuditEvents.Prop.PollAttempts]    = attempts.ToString(),
            }, Microsoft.Extensions.Logging.LogLevel.Warning);
            return;
        }

        ActionProbeSnapshot snap;
        try
        {
            snap = await probe.ProbeAsync(managedDeviceId, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            // Transient back-end error — bump attempts and try again next tick.
            row["PollAttempts"] = attempts + 1;
            row["LastPolledAt"] = DateTimeOffset.UtcNow;
            try { await _table.UpdateEntityAsync(row, row.ETag, TableUpdateMode.Replace, ct).ConfigureAwait(false); }
            catch (RequestFailedException) { /* ETag mismatch — another poller won, skip */ }

            _audit.TrackEvent(AuditEvents.ActionPollError, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]   = correlationId,
                [AuditEvents.Prop.ActionType]      = actionType,
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
            [AuditEvents.Prop.ActionType]       = actionType,
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
