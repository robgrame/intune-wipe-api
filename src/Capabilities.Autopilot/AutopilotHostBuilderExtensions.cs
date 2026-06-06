using Azure.Core;
using Azure.Messaging.ServiceBus;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Capabilities.Autopilot.Runners;
using IntuneDeviceActions.Capabilities.Autopilot.Senders;
using IntuneDeviceActions.Capabilities.Autopilot.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace IntuneDeviceActions.Capabilities.Autopilot;

/// <summary>
/// Autopilot-capability DI helpers, mirroring <c>WipeHostBuilderExtensions</c>
/// and <c>BitLockerHostBuilderExtensions</c>. Each host role calls the subset it
/// needs:
/// <list type="bullet">
///   <item><c>AddAutopilotProbe</c>     → Proc (poller probes the import state) +
///                                         Autopilot (tracker init reads).</item>
///   <item><c>AddAutopilotForwarding</c> → Proc (forwards envelopes to the
///                                         autopilot-action queue).</item>
///   <item><c>AddAutopilotExecutor</c>   → Autopilot (privileged executor:
///                                         GraphAutopilotService + register runner).</item>
/// </list>
/// </summary>
public static class AutopilotHostBuilderExtensions
{
    /// <summary>
    /// Registers the <see cref="AutopilotActionStatusProbe"/> so the action
    /// status poller knows how to ask Graph for the current import state on rows
    /// whose <c>ActionType=="autopilot-register"</c>.
    /// </summary>
    public static IServiceCollection AddAutopilotProbe(this IServiceCollection services)
    {
        services.AddSingleton<IActionStatusProbe, AutopilotActionStatusProbe>();
        return services;
    }

    /// <summary>
    /// Registers the proc-side forwarder (<see cref="AutopilotForwardingRunner"/>
    /// → Service Bus <c>autopilot-action</c> queue) plus the sender wrapper.
    /// </summary>
    public static IServiceCollection AddAutopilotForwarding(this IServiceCollection services)
    {
        services.EnsureServiceBusClient();
        services.AddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var client = sp.GetRequiredService<ServiceBusClient>();
            var queueName = cfg["ServiceBus:AutopilotActionQueue"] ?? "autopilot-action";
            return new AutopilotActionSender(client.CreateSender(queueName));
        });
        services.AddSingleton<IActionRunner, AutopilotForwardingRunner>();
        return services;
    }

    /// <summary>
    /// Registers the privileged autopilot executor (Autopilot role only):
    /// <see cref="GraphAutopilotService"/> + <see cref="AutopilotRegisterRunner"/>.
    /// The runner is registered as a concrete singleton (resolved directly by the
    /// consumer function) AND as <see cref="IActionRunner"/>. Also adds the probe
    /// so tracker init on this app can resolve it.
    /// </summary>
    public static IServiceCollection AddAutopilotExecutor(this IServiceCollection services)
    {
        services.AddSingleton<GraphAutopilotService>();
        services.AddSingleton<AutopilotRegisterRunner>();
        services.AddSingleton<IActionRunner>(sp => sp.GetRequiredService<AutopilotRegisterRunner>());
        services.AddAutopilotProbe();
        return services;
    }

    /// <summary>
    /// Idempotent <see cref="ServiceBusClient"/> registration (mirrors the
    /// internal helper in Shared / the wipe + bitlocker capabilities).
    /// </summary>
    internal static IServiceCollection EnsureServiceBusClient(this IServiceCollection services)
    {
        services.TryAddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var cred = sp.GetRequiredService<TokenCredential>();
            var ns = cfg["ServiceBus:FullyQualifiedNamespace"]
                ?? throw new InvalidOperationException(
                    "ServiceBus:FullyQualifiedNamespace must be configured (e.g. 'idactions-sb-xxx.servicebus.windows.net').");
            return new ServiceBusClient(ns, cred);
        });
        return services;
    }
}
