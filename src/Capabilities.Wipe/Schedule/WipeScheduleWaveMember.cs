using Azure;
using Azure.Data.Tables;

namespace IntuneDeviceActions.Capabilities.Wipe.Schedule;

/// <summary>
/// One row per device-in-wave assignment. PartitionKey = wave id (so listing
/// members of a wave is a single partition scan); RowKey = entra device id
/// (lowercased) so a device cannot appear twice in the same wave.
/// </summary>
public sealed class WipeScheduleWaveMember : ITableEntity
{
    /// <summary>PartitionKey = wave id (GUID, lowercased dashed form).</summary>
    public string PartitionKey { get; set; } = string.Empty;

    /// <summary>RowKey = entra device id (GUID, lowercased dashed form).</summary>
    public string RowKey { get; set; } = string.Empty;

    public DateTimeOffset? Timestamp { get; set; }
    public ETag ETag { get; set; }

    public string DeviceName { get; set; } = string.Empty;
    public string? IntuneDeviceId { get; set; }

    public string? AddedBy { get; set; }
    public DateTimeOffset AddedAtUtc { get; set; }

    public Guid WaveId =>
        Guid.TryParse(PartitionKey, out var g) ? g : Guid.Empty;

    public Guid EntraDeviceId =>
        Guid.TryParse(RowKey, out var g) ? g : Guid.Empty;
}
