using System.Text.Json;
using Azure;
using Azure.Messaging.ServiceBus.Administration;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Dashboard;

/// <summary>
/// Aggregates real-time signals from the moving parts of the pipeline so the
/// operator "cruscotto" can render a single-page flow-of-energy view. Each
/// snapshot fans out to ServiceBus admin + ledger blob enumeration with a
/// short timeout and stitches the result. No background timers, no caching —
/// the HTTP endpoint polls every few seconds and the cost of one admin call
/// per queue is negligible.
/// </summary>
/// <remarks>
/// Sources used (deliberately limited to what's already available in the Web
/// composition root to keep the MVP dependency-free):
/// <list type="bullet">
///   <item><c>ServiceBusAdministrationClient</c> for queue active/dead-letter counts (real-time, no AI lag).</item>
///   <item><c>BlobContainerClient</c> on the <c>action-ledger</c> container to count entries and detect
///         "stuck Issued" rows — the exact silent-failure mode that blocked the FC1DSK005 wipe for 4 days.</item>
/// </list>
/// Deferred to v2: AI KQL for throughput (would need Azure.Monitor.Query),
/// ARM for FunctionApp states, Automation runbook job listings.
/// </remarks>
public sealed class DashboardTelemetryService
{
    private readonly ServiceBusAdministrationClient _sbAdmin;
    private readonly BlobContainerClient _ledger;
    private readonly IConfiguration _cfg;
    private readonly ILogger<DashboardTelemetryService> _log;

    // Listed in flow order so the dashboard can render them top-to-bottom
    // without extra layout metadata.
    private static readonly string[] FlowQueues =
    {
        "action-requests",
        "action-dispatch",
        "wipe-action",
        "autopilot-action",
        "bitlocker-action",
        "rename-action",
    };

    public DashboardTelemetryService(
        ServiceBusAdministrationClient sbAdmin,
        BlobContainerClient ledger,
        IConfiguration cfg,
        ILogger<DashboardTelemetryService> log)
    {
        _sbAdmin = sbAdmin;
        _ledger = ledger;
        _cfg = cfg;
        _log = log;
    }

    public async Task<DashboardSnapshot> SnapshotAsync(CancellationToken ct)
    {
        var queuesTask = LoadQueuesAsync(ct);
        var ledgerTask = LoadLedgerAsync(ct);
        await Task.WhenAll(queuesTask, ledgerTask);

        var queues = await queuesTask;
        var ledger = await ledgerTask;

        var warnings = new List<string>();
        foreach (var q in queues)
        {
            if (q.DeadLetter > 0)
                warnings.Add($"Queue '{q.Name}' has {q.DeadLetter} dead-lettered message(s).");
            else if (q.Active >= 50)
                warnings.Add($"Queue '{q.Name}' has {q.Active} active messages — backlog forming.");
            if (q.Error is not null && q.Status == NodeHealth.Unknown)
                _log.LogDebug("Queue {Queue} lookup soft-failed: {Reason}", q.Name, q.Error);
        }
        if (ledger.StuckEntries > 0)
            warnings.Add($"{ledger.StuckEntries} ledger entry(ies) Issued past grace ({ledger.GraceHours}h) " +
                         "with no terminal observation. Future requests for those devices are blocked.");
        if (ledger.Error is not null)
            warnings.Add($"Ledger inspection failed: {ledger.Error}.");

        return new DashboardSnapshot(
            GeneratedAt: DateTimeOffset.UtcNow,
            Queues: queues,
            Ledger: ledger,
            Warnings: warnings.ToArray());
    }

    private async Task<IReadOnlyList<QueueStatus>> LoadQueuesAsync(CancellationToken ct)
    {
        var results = new List<QueueStatus>(FlowQueues.Length);
        foreach (var name in FlowQueues)
        {
            try
            {
                var props = await _sbAdmin.GetQueueRuntimePropertiesAsync(name, ct);
                var active = props.Value.ActiveMessageCount;
                var dlq = props.Value.DeadLetterMessageCount;
                var scheduled = props.Value.ScheduledMessageCount;
                results.Add(new QueueStatus(
                    Name: name,
                    Active: active,
                    DeadLetter: dlq,
                    Scheduled: scheduled,
                    AccessedAt: props.Value.AccessedAt,
                    Status: dlq > 0          ? NodeHealth.Red
                          : active >= 50     ? NodeHealth.Red
                          : active >= 10     ? NodeHealth.Yellow
                          :                    NodeHealth.Green,
                    Error: null));
            }
            catch (RequestFailedException ex) when (ex.Status == 404)
            {
                // Not provisioned in this environment (e.g. rename queue on the
                // old SB namespace) — N/A rather than failure.
                results.Add(new QueueStatus(name, 0, 0, 0, null, NodeHealth.Unknown, "queue not provisioned"));
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "Dashboard: queue {Queue} runtime lookup failed", name);
                results.Add(new QueueStatus(name, 0, 0, 0, null, NodeHealth.Unknown, ex.GetType().Name));
            }
        }
        return results;
    }

    private async Task<LedgerStatus> LoadLedgerAsync(CancellationToken ct)
    {
        if (!double.TryParse(_cfg["Idempotency:RearmGracePeriodHours"], out var graceHours) || graceHours <= 0)
            graceHours = 48;
        var stuckBefore = DateTimeOffset.UtcNow.AddHours(-graceHours);

        var total = 0;
        var stuck = 0;
        DateTimeOffset? oldestStuckIssuedAt = null;
        string? oldestStuckId = null;

        try
        {
            await foreach (BlobItem item in _ledger.GetBlobsAsync(BlobTraits.None, BlobStates.None, prefix: null, ct))
            {
                // Reset endpoint archives entries under "_archive/" — skip them.
                if (item.Name.StartsWith("_archive/", StringComparison.OrdinalIgnoreCase)) continue;
                total++;

                LedgerEntry? entry = null;
                try
                {
                    var resp = await _ledger.GetBlobClient(item.Name).DownloadContentAsync(ct);
                    entry = JsonSerializer.Deserialize<LedgerEntry>(resp.Value.Content.ToMemory().Span);
                }
                catch (Exception ex)
                {
                    _log.LogDebug(ex, "Dashboard: ledger blob {Name} read failed", item.Name);
                    continue;
                }
                if (entry is null) continue;

                // "Stuck" = Issued past the rearm grace period AND tracker never
                // observed terminal. This is the exact failure mode that
                // silently blocked the FC1DSK005 wipe for 4 days — surfacing it
                // on the cruscotto is the whole reason this dashboard exists.
                var isIssued   = string.Equals(entry.State, "Issued", StringComparison.OrdinalIgnoreCase);
                var noTerminal = string.IsNullOrEmpty(entry.LastTerminalState);
                if (isIssued && noTerminal && entry.IssuedAt is { } issued && issued < stuckBefore)
                {
                    stuck++;
                    if (oldestStuckIssuedAt is null || issued < oldestStuckIssuedAt)
                    {
                        oldestStuckIssuedAt = issued;
                        oldestStuckId = entry.IntuneDeviceId;
                    }
                }
            }
            var status = stuck > 0          ? NodeHealth.Red
                       : total >= 100       ? NodeHealth.Yellow
                       :                      NodeHealth.Green;
            return new LedgerStatus(total, stuck, oldestStuckIssuedAt, oldestStuckId, graceHours, status, null);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Dashboard: ledger enumeration failed");
            return new LedgerStatus(0, 0, null, null, graceHours, NodeHealth.Unknown, ex.GetType().Name);
        }
    }

    // Subset of the ActionIdempotencyService.Entry shape — only the fields the
    // dashboard consumes. Extra fields in the blob are ignored by the
    // serializer, so we don't have to track changes to the full entry shape.
    private sealed record LedgerEntry
    {
        public string? IntuneDeviceId { get; init; }
        public string? State { get; init; }
        public DateTimeOffset? IssuedAt { get; init; }
        public string? LastTerminalState { get; init; }
    }
}

public enum NodeHealth { Green, Yellow, Red, Unknown }

public sealed record DashboardSnapshot(
    DateTimeOffset GeneratedAt,
    IReadOnlyList<QueueStatus> Queues,
    LedgerStatus Ledger,
    string[] Warnings);

public sealed record QueueStatus(
    string Name,
    long Active,
    long DeadLetter,
    long Scheduled,
    DateTimeOffset? AccessedAt,
    NodeHealth Status,
    string? Error);

public sealed record LedgerStatus(
    int TotalEntries,
    int StuckEntries,
    DateTimeOffset? OldestStuckIssuedAt,
    string? OldestStuckIntuneDeviceId,
    double GraceHours,
    NodeHealth Status,
    string? Error);
