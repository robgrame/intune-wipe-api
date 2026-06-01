using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Middleware;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Middleware;

/// <summary>
/// Calls <c>TryRefreshAsync</c> on the captured Azure App Configuration
/// refresher at the start of each Functions invocation, so the sentinel-based
/// refresh actually fires. Without this, <c>ConfigureRefresh</c> only sets up
/// cache-invalidation rules; nothing polls the store. The provider polls at
/// most once per configured interval (30s by default), so per-invocation calls
/// are cheap.
/// </summary>
internal sealed class AppConfigRefreshMiddleware : IFunctionsWorkerMiddleware
{
    private readonly ILogger<AppConfigRefreshMiddleware> _log;

    public AppConfigRefreshMiddleware(ILogger<AppConfigRefreshMiddleware> log)
    {
        _log = log;
    }

    public async Task Invoke(FunctionContext context, FunctionExecutionDelegate next)
    {
        var refresher = AppConfigRefresherHolder.Instance;
        if (refresher is null)
        {
            _log.LogWarning("AppConfigRefreshMiddleware: no refresher captured (AppConfig source not active?).");
        }
        else
        {
            try
            {
                var refreshed = await refresher.TryRefreshAsync(context.CancellationToken);
                _log.LogInformation("AppConfigRefreshMiddleware: TryRefreshAsync returned {Refreshed}.", refreshed);
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "AppConfig TryRefreshAsync failed; continuing with cached config.");
            }
        }
        await next(context);
    }
}

