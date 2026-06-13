using IntuneDeviceActions.Schedule;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Capabilities.Wipe.Schedule;

/// <summary>
/// Adapter that exposes <see cref="WipeScheduleStore"/> through the
/// capability-agnostic <see cref="IScheduleProvider"/> contract so the core
/// <c>GET /api/schedule/me</c> endpoint can include wipe schedules in its
/// response without taking a dependency on wipe-specific types.
/// </summary>
public sealed class WipeScheduleProvider : IScheduleProvider
{
    private readonly WipeScheduleStore _store;
    private readonly ILogger<WipeScheduleProvider> _log;

    public WipeScheduleProvider(WipeScheduleStore store, ILogger<WipeScheduleProvider> log)
    {
        _store = store;
        _log = log;
    }

    public string ActionType => WipeScheduleWave.ActionTypeValue;

    public async Task<DeviceScheduleSnapshot?> GetScheduleAsync(Guid entraDeviceId, CancellationToken ct)
    {
        try
        {
            return await _store.GetScheduleForDeviceAsync(entraDeviceId, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            // Contract: providers swallow transient failures so the aggregator
            // does not 500 the whole endpoint when wipe storage is briefly
            // unavailable.
            _log.LogWarning(ex, "WipeScheduleProvider failed for {EntraDeviceId}; returning null.",
                entraDeviceId);
            return null;
        }
    }
}
