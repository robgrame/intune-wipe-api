namespace IntuneDeviceActions.Schedule;

/// <summary>
/// Capability-agnostic extension point that lets the core <c>schedule/me</c>
/// HTTP endpoint discover what scheduled actions apply to a given device,
/// without knowing about any capability's storage layout.
/// <para>
/// Each capability that wants to expose a downloadable schedule (currently
/// wipe; future: autopilot, bitlocker) registers ONE
/// <see cref="IScheduleProvider"/> singleton in its host DI helper. The
/// provider is responsible for consulting its own backing store (a Table,
/// a DB, Entra groups, ...) and returning <c>null</c> when the device has no
/// imminent scheduled work.
/// </para>
/// <para>
/// The provider returns at most one snapshot — its own most-imminent entry.
/// The aggregator (in core) merges across providers and picks the earliest.
/// </para>
/// </summary>
public interface IScheduleProvider
{
    /// <summary>
    /// Discriminator matching <c>IActionRunner.Type</c>. Used for logging and
    /// for capability-scoped queries (<c>actionTypeFilter</c> on the endpoint).
    /// </summary>
    string ActionType { get; }

    /// <summary>
    /// Returns the most-imminent client-visible schedule entry for
    /// <paramref name="entraDeviceId"/>, or <c>null</c> if none.
    /// MUST NOT throw — providers swallow their own transient errors and
    /// return null on failure (so one broken provider does not poison the
    /// whole aggregated response).
    /// </summary>
    Task<DeviceScheduleSnapshot?> GetScheduleAsync(Guid entraDeviceId, CancellationToken ct);
}
