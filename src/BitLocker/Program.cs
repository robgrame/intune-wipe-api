using IntuneDeviceActions;
using IntuneDeviceActions.Capabilities.BitLocker;
using IntuneDeviceActions.Middleware;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var host = new HostBuilder()
    .ConfigureFunctionsWorkerDefaults(b =>
    {
        b.UseMiddleware<AppConfigRefreshMiddleware>();
        b.UseMiddleware<ServiceBusTraceContextMiddleware>();
    })
    .ConfigureAppConfiguration((ctx, c) => c.AddIntuneDeviceActionsAppConfig(roleHint: "bitlocker"))
    .ConfigureServices((ctx, services) =>
    {
        services.AddIntuneDeviceActionsCore();
        services.AddIntuneDeviceActionsOpenTelemetry(role: "bitlocker");
        services.AddGraphClient();                // bare GraphServiceClient (privileged identity granted on the app, not in code)
        services.AddActionIdempotency();          // reserve / mark issued / mark failed
        services.AddActionStatusTracker();        // init state on action issued (probe registered by AddBitLockerExecutor below)

        // BitLocker capability — bitlocker role hosts the privileged executor:
        //   AddBitLockerExecutor: GraphBitLockerService + BitLockerRotateRunner (+ probe).
        // The consumer function resolves BitLockerRotateRunner directly (concrete type).
        services.AddBitLockerExecutor();
    })
    .Build();

host.Run();
