using IntuneDeviceActions;
using IntuneDeviceActions.Capabilities.Autopilot;
using IntuneDeviceActions.Capabilities.BitLocker;
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
    .ConfigureAppConfiguration((ctx, c) => c.AddIntuneDeviceActionsAppConfig(roleHint: "proc"))
    .ConfigureServices((ctx, services) =>
    {
        services.AddIntuneDeviceActionsCore(ctx.Configuration);
        services.AddIntuneDeviceActionsOpenTelemetry(role: "proc");
        services.AddGraphClient();                // bare GraphServiceClient for the wipe probe (no privileged execution surface here)
        services.AddActionIdempotency();          // processor may inspect ledger entry on prep
        services.AddActionDispatchSender();       // processor → ActionDispatch queue
        services.AddSingleton<IntuneDeviceActions.Actions.ActionRunnerRegistry>();
        services.AddActionStatusTracker();        // poller updates actionstatus table

        // Wipe capability — proc role only forwards (does NOT execute).
        //   AddWipeForwarding: WipeActionSender + WipeForwardingRunner (wipe-action queue)
        //                      + WipeRunbookForwardingRunner (Automation webhook)
        //   AddWipeProbe:      WipeActionStatusProbe so the poller can probe "wipe" rows.
        services.AddWipeForwarding();
        services.AddWipeProbe();

        // BitLocker capability — proc role only forwards (does NOT execute).
        //   AddBitLockerForwarding: BitLockerActionSender + BitLockerForwardingRunner (bitlocker-action queue)
        //   AddBitLockerProbe:      BitLockerActionStatusProbe so the poller can probe "bitlocker-rotate" rows.
        services.AddBitLockerForwarding();
        services.AddBitLockerProbe();

        // Autopilot capability — proc role only forwards (does NOT execute).
        //   AddAutopilotForwarding: AutopilotActionSender + AutopilotForwardingRunner (autopilot-action queue)
        //   AddAutopilotProbe:      AutopilotActionStatusProbe so the poller can probe "autopilot-register" rows.
        services.AddAutopilotForwarding();
        services.AddAutopilotProbe();
    })
    .Build();

host.Run();
