using IntuneWipeApi;
using IntuneWipeApi.Middleware;
using IntuneWipeApi.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var host = new HostBuilder()
    .ConfigureFunctionsWebApplication(b =>
    {
        b.UseDefaultWorkerMiddleware();
        b.UseMiddleware<AppConfigRefreshMiddleware>();
    })
    .ConfigureAppConfiguration((ctx, c) => c.AddIntuneWipeApiAppConfig(roleHint: "web"))
    .ConfigureServices((ctx, services) =>
    {
        services.AddIntuneWipeApiCore();
        // Web-only: cert mTLS + replay nonce + directory resolver (Graph lookup for non-GUID claim).
        services.AddSingleton<ClientCertValidator>();
        services.AddSingleton<ReplayProtector>();
        services.AddGraphWipe();                  // GraphServiceClient (DeviceDirectoryResolver only — NOT for status tracker)
        services.AddSingleton<DeviceDirectoryResolver>();
        services.AddIdempotency();                // admin reset endpoint
        services.AddWipeRequestQueueSender();     // enqueue to proc
        services.AddWipeStatusTracker();          // GET /api/wipe/status reads it (Graph not used on this code path)
    })
    .Build();

host.Run();
