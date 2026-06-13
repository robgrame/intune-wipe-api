using IntuneDeviceActions;
using IntuneDeviceActions.Capabilities.Wipe;
using IntuneDeviceActions.Middleware;
using IntuneDeviceActions.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var host = new HostBuilder()
    .ConfigureFunctionsWebApplication(b =>
    {
        b.UseDefaultWorkerMiddleware();
        b.UseMiddleware<AppConfigRefreshMiddleware>();
        b.UseMiddleware<ServiceBusTraceContextMiddleware>();
    })
    .ConfigureAppConfiguration((ctx, c) => c.AddIntuneDeviceActionsAppConfig(roleHint: "web"))
    .ConfigureServices((ctx, services) =>
    {
        services.AddIntuneDeviceActionsCore();
        services.AddIntuneDeviceActionsOpenTelemetry(role: "web");
        // Web-only: cert mTLS + replay nonce + directory resolver (Graph lookup for non-GUID claim).
        services.AddSingleton<ClientCertValidator>();
        services.AddSingleton<ReplayProtector>();
        services.AddGraphClient();                // bare GraphServiceClient — DeviceDirectoryResolver only (NO wipe capability here)
        services.AddSingleton<DeviceDirectoryResolver>();
        services.AddActionIdempotency();          // admin reset endpoint
        services.AddActionRequestSender();        // enqueue to proc
        services.AddActionStatusTracker();        // GET /api/actions/status reads it (no probes registered → tracker won't poll from web)

        // Schedule manifest endpoint (GET /api/schedule/me). Core stays
        // capability-agnostic via IScheduleProvider; the wipe provider is
        // registered as a composition-root opt-in (this is the ONLY place
        // the Web role knows wipe scheduling exists).
        services.AddScheduleAggregator();
        services.AddWipeScheduleProvider();
    })
    .Build();

host.Run();
