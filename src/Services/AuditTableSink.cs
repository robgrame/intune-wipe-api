using System.Text.Json;
using Azure;
using Azure.Data.Tables;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Services;

/// <summary>
/// Long-term persistent sink for audit events backed by Azure Table Storage.
/// </summary>
/// <remarks>
/// <para>
/// Why a second sink alongside App Insights:
/// </para>
/// <list type="bullet">
///   <item><description>
///     App Insights has a default 90-day retention; compliance/forensic audit
///     trails for destructive operations (remote wipe) often need to survive
///     multi-year retention windows. Table Storage is cheap and supports
///     indefinite retention with lifecycle policies.
///   </description></item>
///   <item><description>
///     Table queries are server-side filter expressions on PartitionKey/RowKey
///     plus property predicates — no KQL, no Log Analytics ingest delay (a few
///     minutes), data is queryable seconds after the write.
///   </description></item>
///   <item><description>
///     App Insights customEvents customDimensions are bag-of-strings without a
///     fixed schema; the table promotes the well-known property keys to typed
///     columns so the rows are scannable in Storage Explorer / Portal.
///   </description></item>
/// </list>
/// <para>
/// Writes are best-effort: a failure here MUST NOT break the audit pipeline.
/// The App Insights write is the primary path; the table is the durable copy.
/// All exceptions from the table SDK are caught and logged at Warning.
/// </para>
/// <para>
/// Row layout:
/// <list type="bullet">
///   <item><description><b>PartitionKey</b> = correlationId (so every event for one wipe request groups together — cheap partition-scoped query for the trail view).</description></item>
///   <item><description><b>RowKey</b> = <c>{TicksAscending:D19}_{Guid8}</c> — chronological-ascending within a partition; the Guid suffix de-duplicates simultaneous writes.</description></item>
///   <item><description>Promoted columns: <c>Name</c>, <c>Level</c>, <c>EventTimestamp</c>, <c>DeviceName</c>, <c>EntraDeviceId</c>, <c>IntuneDeviceId</c>, <c>ManagedDeviceId</c>, <c>Reason</c>, <c>ExceptionType</c>, <c>ExceptionMessage</c>.</description></item>
///   <item><description><c>PropertiesJson</c>: full property bag serialized for forensic completeness.</description></item>
/// </list>
/// </para>
/// </remarks>
public sealed class AuditTableSink
{
    private const int MaxStringPropertyLength = 30_000; // Table entity property hard limit is 64 KiB (UTF-16); stay well under.

    private readonly TableClient? _table;
    private readonly ILogger<AuditTableSink> _log;
    private readonly bool _enabled;

    public AuditTableSink(TableClient? table, ILogger<AuditTableSink> log)
    {
        _table = table;
        _log = log;
        _enabled = table is not null;
    }

    public void TrackEvent(string eventName, IDictionary<string, string> properties, LogLevel level)
    {
        if (!_enabled || _table is null) return;

        try
        {
            var entity = BuildEntity(eventName, properties, level);
            // Synchronous fire-and-forget on the thread-pool. We intentionally don't
            // await: audit-table latency must not bottleneck the wipe path. If
            // ordering across events matters for a trail view, the consumer can
            // sort by EventTimestamp (or RowKey, which is ticks-prefixed).
            _ = AddEntityFireAndForget(entity);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Audit table sink failed to enqueue event {EventName}", eventName);
        }
    }

    private async Task AddEntityFireAndForget(TableEntity entity)
    {
        try
        {
            await _table!.AddEntityAsync(entity).ConfigureAwait(false);
        }
        catch (RequestFailedException ex) when (ex.Status == 409)
        {
            // RowKey collision (extremely unlikely given ticks + guid suffix).
            // Re-issue with a new guid suffix so the event isn't lost.
            try
            {
                entity.RowKey = entity.RowKey + "_" + Guid.NewGuid().ToString("N").Substring(0, 4);
                await _table!.AddEntityAsync(entity).ConfigureAwait(false);
            }
            catch (Exception ex2)
            {
                _log.LogWarning(ex2, "Audit table sink failed twice for event {EventName}", entity.GetString("Name"));
            }
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Audit table sink failed for event {EventName}", entity.GetString("Name"));
        }
    }

    private static TableEntity BuildEntity(string eventName, IDictionary<string, string> properties, LogLevel level)
    {
        properties.TryGetValue(AuditEvents.Prop.CorrelationId, out var correlationId);
        if (string.IsNullOrWhiteSpace(correlationId))
        {
            correlationId = "no-correlation";
        }

        var now = DateTimeOffset.UtcNow;
        var rowKey = $"{now.UtcTicks:D19}_{Guid.NewGuid().ToString("N").Substring(0, 8)}";

        var entity = new TableEntity(SanitizeKey(correlationId), rowKey)
        {
            { "Name", eventName },
            { "Level", level.ToString() },
            { "EventTimestamp", now },
        };

        // Promote well-known property keys to typed columns for scannability.
        SetIfPresent(entity, "DeviceName",        properties, AuditEvents.Prop.DeviceName);
        SetIfPresent(entity, "EntraDeviceId",     properties, AuditEvents.Prop.EntraDeviceId);
        SetIfPresent(entity, "IntuneDeviceId",    properties, AuditEvents.Prop.IntuneDeviceId);
        SetIfPresent(entity, "ManagedDeviceId",   properties, AuditEvents.Prop.ManagedDeviceId);
        SetIfPresent(entity, "Reason",            properties, AuditEvents.Prop.Reason);
        SetIfPresent(entity, "ExceptionType",     properties, AuditEvents.Prop.ExceptionType);
        SetIfPresent(entity, "ExceptionMessage",  properties, AuditEvents.Prop.ExceptionMessage);

        // Full property bag for forensic completeness.
        var json = JsonSerializer.Serialize(properties);
        if (json.Length > MaxStringPropertyLength)
        {
            json = json.Substring(0, MaxStringPropertyLength) + "…(truncated)";
        }
        entity["PropertiesJson"] = json;

        return entity;
    }

    private static void SetIfPresent(TableEntity entity, string column, IDictionary<string, string> source, string sourceKey)
    {
        if (source.TryGetValue(sourceKey, out var value) && !string.IsNullOrEmpty(value))
        {
            entity[column] = value.Length > 1024 ? value.Substring(0, 1024) + "…" : value;
        }
    }

    /// <summary>
    /// PartitionKey/RowKey must not contain '/', '\\', '#', '?', control chars, or be > 1 KiB.
    /// Wipe correlation ids are guids — already safe — but guard anyway.
    /// </summary>
    private static string SanitizeKey(string key)
    {
        if (string.IsNullOrEmpty(key)) return "_";
        Span<char> buf = stackalloc char[Math.Min(key.Length, 256)];
        var len = Math.Min(key.Length, buf.Length);
        for (var i = 0; i < len; i++)
        {
            var c = key[i];
            buf[i] = c is '/' or '\\' or '#' or '?' || char.IsControl(c) ? '_' : c;
        }
        return new string(buf.Slice(0, len));
    }
}
