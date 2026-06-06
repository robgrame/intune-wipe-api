using IntuneDeviceActions;
using IntuneDeviceActions.Capabilities.Autopilot;
using IntuneDeviceActions.Middleware;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults(b =>
    {
        b.UseMiddleware<AppConfigRefreshMiddleware>();
        b.UseMiddleware<ServiceBusTraceContextMiddleware>();
    })
    .ConfigureAppConfiguration((ctx, c) => c.AddIntuneDeviceActionsAppConfig(roleHint: "autopilot"))
    .ConfigureServices((ctx, services) =>
    {
        services.AddIntuneDeviceActionsCore();
        services.AddIntuneDeviceActionsOpenTelemetry(role: "autopilot");
        services.AddGraphClient();                // bare GraphServiceClient (privileged identity granted on the app, not in code)
        services.AddActionIdempotency();          // reserve / mark issued / mark failed
        services.AddActionStatusTracker();        // init state on action issued (probe registered by AddAutopilotExecutor below)

        // Autopilot capability — autopilot role hosts the privileged executor:
        //   AddAutopilotExecutor: GraphAutopilotService + AutopilotRegisterRunner (+ probe).
        // The consumer function resolves AutopilotRegisterRunner directly (concrete type).
        services.AddAutopilotExecutor();
    })
    .Build();

host.Run();
