using IntuneDeviceActions.Schedule;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Services;

/// <summary>
/// Capability-agnostic aggregator: asks every registered
/// <see cref="IScheduleProvider"/> for the calling device's most-imminent
/// schedule entry and returns the earliest one across all providers.
/// <para>
/// This is the read-side counterpart of <see cref="IScheduleProvider"/>:
/// the HTTP endpoint <c>GET /api/schedule/me</c> in the Web role calls this
/// service, which knows nothing about wipe / autopilot / bitlocker — it just
/// merges whatever providers were registered at composition time.
/// </para>
/// </summary>
public sealed class ScheduleAggregator
{
    private readonly IEnumerable<IScheduleProvider> _providers;
    private readonly ILogger<ScheduleAggregator> _log;

    public ScheduleAggregator(IEnumerable<IScheduleProvider> providers,
        ILogger<ScheduleAggregator> log)
    {
        _providers = providers;
        _log = log;
    }

    /// <summary>True when at least one provider is registered.</summary>
    public bool HasProviders => _providers.Any();

    /// <summary>
    /// Returns the earliest schedule entry across all providers for
    /// <paramref name="entraDeviceId"/>, or <c>null</c> if none.
    /// Optionally restrict to a single <paramref name="actionTypeFilter"/>.
    /// </summary>
    public async Task<DeviceScheduleSnapshot?> GetScheduleAsync(
        Guid entraDeviceId, string? actionTypeFilter = null,
        CancellationToken ct = default)
    {
        if (entraDeviceId == Guid.Empty) return null;

        var providers = _providers;
        if (!string.IsNullOrWhiteSpace(actionTypeFilter))
        {
            providers = _providers.Where(p =>
                string.Equals(p.ActionType, actionTypeFilter, StringComparison.OrdinalIgnoreCase));
        }

        DeviceScheduleSnapshot? best = null;
        foreach (var provider in providers)
        {
            DeviceScheduleSnapshot? snap;
            try
            {
                snap = await provider.GetScheduleAsync(entraDeviceId, ct).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                // Per IScheduleProvider contract this should never happen;
                // belt-and-suspenders to ensure one broken provider doesn't
                // 500 the whole endpoint.
                _log.LogWarning(ex, "Schedule provider {ActionType} threw; skipping.",
                    provider.ActionType);
                continue;
            }
            if (snap is null) continue;
            if (best is null || snap.ScheduledAtUtc < best.ScheduledAtUtc)
            {
                best = snap;
            }
        }
        return best;
    }
}
