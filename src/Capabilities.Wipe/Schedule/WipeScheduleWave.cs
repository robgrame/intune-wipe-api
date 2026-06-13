using Azure;
using Azure.Data.Tables;

namespace IntuneDeviceActions.Capabilities.Wipe.Schedule;

/// <summary>
/// One row per scheduled wipe wave (Azure Table entity). All wave rows share
/// a single partition (<see cref="DefaultPartition"/>) because the expected
/// cardinality is small (dozens of active waves per tenant); per-wave member
/// lookups live in a separate table partitioned by wave id.
/// </summary>
/// <remarks>
/// Wipe-specific by intent: it lives inside the wipe capability project so
/// the core (Shared/Web/Proc) stays unaware of wipe's storage layout. Future
/// capabilities that need schedule waves should ship their own analogous
/// entity (<c>AutopilotScheduleWave</c>, etc.) inside their capability
/// project and expose a sibling <see cref="Schedule.IScheduleProvider"/>.
/// </remarks>
public sealed class WipeScheduleWave : ITableEntity
{
    /// <summary>Constant partition for all wipe waves.</summary>
    public const string DefaultPartition = "WipeScheduleWave";

    /// <summary>Action discriminator carried for cross-capability tooling parity.</summary>
    public const string ActionTypeValue = "wipe";

    public string PartitionKey { get; set; } = DefaultPartition;

    /// <summary>RowKey = wave id (GUID, lowercased dashed form).</summary>
    public string RowKey { get; set; } = string.Empty;

    public DateTimeOffset? Timestamp { get; set; }
    public ETag ETag { get; set; }

    /// <summary>Human-readable name (required).</summary>
    public string Name { get; set; } = string.Empty;

    public string? Description { get; set; }

    /// <summary>When the wave should fire (UTC, ISO 8601).</summary>
    public DateTimeOffset ScheduledAtUtc { get; set; }

    /// <summary>One of <see cref="IntuneDeviceActions.Schedule.WaveStatus"/>.</summary>
    public string Status { get; set; } = IntuneDeviceActions.Schedule.WaveStatus.Draft;

    public string? CreatedBy { get; set; }
    public DateTimeOffset CreatedAtUtc { get; set; }
    public string? UpdatedBy { get; set; }
    public DateTimeOffset UpdatedAtUtc { get; set; }

    /// <summary>Convenience accessor for the wave id (parsed from RowKey).</summary>
    public Guid WaveId =>
        Guid.TryParse(RowKey, out var g) ? g : Guid.Empty;
}
