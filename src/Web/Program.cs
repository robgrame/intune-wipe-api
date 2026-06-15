using IntuneDeviceActions;
using IntuneDeviceActions.Capabilities.Wipe;
using IntuneDeviceActions.Dashboard;
using IntuneDeviceActions.Middleware;
using IntuneDeviceActions.Services;
using Azure.Core;
using Azure.Messaging.ServiceBus.Administration;
using Microsoft.Extensions.Configuration;
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

        // Operator cruscotto — GET /api/dashboard{,/data}. Reads SB queue
        // depths (admin client) and the idempotency ledger (BlobContainerClient
        // already registered by AddActionIdempotency). Gated by
        // Dashboard:Enabled + mTLS + operator thumbprint allow-list.
        services.AddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var cred = sp.GetRequiredService<TokenCredential>();
            var ns = cfg["ServiceBus:FullyQualifiedNamespace"]
                ?? throw new InvalidOperationException("ServiceBus:FullyQualifiedNamespace must be configured for the dashboard.");
            return new ServiceBusAdministrationClient(ns, cred);
        });
        services.AddSingleton<DashboardTelemetryService>();
    })
    .Build();

host.Run();
