namespace IntuneDeviceActions.Schedule;

/// <summary>
/// Lifecycle states for a scheduled wave. Generic across capabilities
/// (wipe, autopilot, bitlocker, ...). Each capability stores its own waves
/// in its own backing store; the strings below are the contract between
/// providers (write-side, in the capability project) and the
/// <see cref="ScheduleAggregator"/> (read-side, in Shared).
/// </summary>
public static class WaveStatus
{
    /// <summary>Work-in-progress: not yet visible to clients.</summary>
    public const string Draft = "draft";

    /// <summary>Active. Returned by <c>/api/schedule/me</c>.</summary>
    public const string Scheduled = "scheduled";

    /// <summary>Currently firing (reserved for future scheduler).</summary>
    public const string Executing = "executing";

    /// <summary>All members handled.</summary>
    public const string Completed = "completed";

    /// <summary>Manually canceled. Excluded from <c>/api/schedule/me</c>.</summary>
    public const string Canceled = "canceled";

    /// <summary>States visible to clients (downloadable schedule).</summary>
    public static readonly HashSet<string> ClientVisible =
        new(StringComparer.OrdinalIgnoreCase) { Scheduled, Executing };

    /// <summary>States in which an operator may still edit membership.</summary>
    public static readonly HashSet<string> Mutable =
        new(StringComparer.OrdinalIgnoreCase) { Draft, Scheduled };

    public static bool IsKnown(string? s) =>
        !string.IsNullOrWhiteSpace(s) &&
        (s == Draft || s == Scheduled || s == Executing || s == Completed || s == Canceled);
}
