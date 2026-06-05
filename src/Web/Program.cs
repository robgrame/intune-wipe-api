using IntuneDeviceActions;
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
        services.AddGraphWipe();                  // GraphServiceClient (DeviceDirectoryResolver only — NOT for status tracker)
        services.AddSingleton<DeviceDirectoryResolver>();
        services.AddIdempotency();                // admin reset endpoint
        services.AddActionRequestSender();     // enqueue to proc
        services.AddActionStatusTracker();          // GET /api/actions/status reads it (Graph not used on this code path)
    })
    .Build();

host.Run();
