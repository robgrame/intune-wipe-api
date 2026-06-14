using Microsoft.Extensions.Configuration;

namespace IntuneDeviceActions.Services;

/// <summary>
/// Centralized defaults/parsing for action-status polling settings shared by
/// server and client-side composition roots.
/// </summary>
public static class ActionStatusPollingSettings
{
    public const int DefaultPollMaxAgeHours = 24;
    public const int DefaultMinPollIntervalSeconds = 5;

    public static int GetPollMaxAgeHours(IConfiguration cfg)
        => TryReadPositiveInt(cfg, "ActionStatus:PollMaxAgeHours", DefaultPollMaxAgeHours);

    public static int GetMinPollIntervalSeconds(IConfiguration cfg)
        => TryReadPositiveInt(cfg, "ActionStatus:MinPollIntervalSeconds", DefaultMinPollIntervalSeconds);

    private static int TryReadPositiveInt(IConfiguration cfg, string key, int fallback)
        => int.TryParse(cfg[key], out var value) ? Math.Max(1, value) : fallback;
}
