using Microsoft.Extensions.Configuration.AzureAppConfiguration;

namespace IntuneWipeApi.Middleware;

/// <summary>
/// Holds the <see cref="IConfigurationRefresher"/> captured at startup so the
/// Functions worker middleware can call <c>TryRefreshAsync</c> per invocation
/// without depending on the DI-scanning <c>IConfigurationRefresherProvider</c>,
/// which is unreliable when the AppConfig source is added via the host's
/// <c>ConfigureAppConfiguration</c> callback.
/// </summary>
internal static class AppConfigRefresherHolder
{
    public static IConfigurationRefresher? Instance { get; set; }
}
