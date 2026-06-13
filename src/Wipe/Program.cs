using IntuneDeviceActions;
using IntuneDeviceActions.Capabilities.Wipe;
using IntuneDeviceActions.Middleware;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults(b =>
    {
        b.UseMiddleware<AppConfigRefreshMiddleware>();
        b.UseMiddleware<ServiceBusTraceContextMiddleware>();
    })
    .ConfigureAppConfiguration((ctx, c) => c.AddIntuneDeviceActionsAppConfig(roleHint: "wipe"))
    .ConfigureServices((ctx, services) =>
    {
        services.AddIntuneDeviceActionsCore();
        services.AddIntuneDeviceActionsOpenTelemetry(role: "wipe");
        services.AddGraphClient();                // bare GraphServiceClient (privileged identity is granted on the app, not in code)
        services.AddActionIdempotency();          // reserve / mark issued / mark failed
        services.AddActionStatusTracker();        // init state on action issued (probe registered by AddWipeExecutor below)

        // Wipe capability — wipe role hosts the privileged executor:
        //   AddWipeExecutor: GraphWipeService + WipeActionRunner (+ probe).
        //   AddWipeScheduleStore: gives WipeActionRunner access to the
        //     schedule tables so it can enforce capability-side temporal
        //     gating (defense-in-depth alongside client-side gating).
        // The consumer function resolves WipeActionRunner directly (concrete type).
        services.AddWipeScheduleStore();
        services.AddWipeExecutor();
    })
    .Build();

host.Run();
