namespace IntuneDeviceActions.Schedule;

/// <summary>
/// Generic JSON projection returned by <c>GET /api/schedule/me</c> to a
/// client device. Capability-agnostic by design: the discriminator is
/// <see cref="ActionType"/> ("wipe", "autopilot-register", "bitlocker-rotate",
/// ...) so the same DTO and same endpoint serve every capability that
/// implements <see cref="IScheduleProvider"/>.
/// </summary>
public sealed class DeviceScheduleSnapshot
{
    /// <summary>Wave id (GUID, lowercased dashed form).</summary>
    public string WaveId { get; init; } = string.Empty;

    /// <summary>Human-readable wave name.</summary>
    public string Name { get; init; } = string.Empty;

    /// <summary>
    /// Action discriminator (matches <see cref="IActionRunner.Type"/> on the
    /// capability that owns the schedule entry, e.g. <c>wipe</c>).
    /// </summary>
    public string ActionType { get; init; } = string.Empty;

    /// <summary>When the wave should fire (UTC, ISO 8601).</summary>
    public DateTimeOffset ScheduledAtUtc { get; init; }

    /// <summary>Wave status at the time of the query.</summary>
    public string Status { get; init; } = string.Empty;

    /// <summary>
    /// True when <see cref="ScheduledAtUtc"/> has already elapsed (the client
    /// should act immediately, subject to its own gating).
    /// </summary>
    public bool IsImmediate { get; init; }

    /// <summary>Optional wave description.</summary>
    public string? Description { get; init; }

    /// <summary>Server time at which the snapshot was produced.</summary>
    public DateTimeOffset GeneratedAtUtc { get; init; } = DateTimeOffset.UtcNow;
}
