using Azure.Core;
using Azure.Messaging.ServiceBus;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Capabilities.BitLocker.Runners;
using IntuneDeviceActions.Capabilities.BitLocker.Senders;
using IntuneDeviceActions.Capabilities.BitLocker.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace IntuneDeviceActions.Capabilities.BitLocker;

/// <summary>
/// BitLocker-capability DI helpers, mirroring <c>WipeHostBuilderExtensions</c>.
/// Each host role calls the subset it needs:
/// <list type="bullet">
///   <item><c>AddBitLockerProbe</c>     → Proc (poller probes the rotate state) +
///                                         BitLocker (tracker init reads).</item>
///   <item><c>AddBitLockerForwarding</c> → Proc (forwards envelopes to the
///                                         bitlocker-action queue).</item>
///   <item><c>AddBitLockerExecutor</c>   → BitLocker (privileged executor:
///                                         GraphBitLockerService + rotate runner).</item>
/// </list>
/// </summary>
public static class BitLockerHostBuilderExtensions
{
    /// <summary>
    /// Registers the <see cref="BitLockerActionStatusProbe"/> so the action
    /// status poller knows how to ask Graph for the current rotate state on
    /// rows whose <c>ActionType=="bitlocker-rotate"</c>.
    /// </summary>
    public static IServiceCollection AddBitLockerProbe(this IServiceCollection services)
    {
        services.AddSingleton<IActionStatusProbe, BitLockerActionStatusProbe>();
        return services;
    }

    /// <summary>
    /// Registers the proc-side forwarder (<see cref="BitLockerForwardingRunner"/>
    /// → Service Bus <c>bitlocker-action</c> queue) plus the sender wrapper.
    /// </summary>
    public static IServiceCollection AddBitLockerForwarding(this IServiceCollection services)
    {
        services.EnsureServiceBusClient();
        services.AddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var client = sp.GetRequiredService<ServiceBusClient>();
            var queueName = cfg["ServiceBus:BitLockerActionQueue"] ?? "bitlocker-action";
            return new BitLockerActionSender(client.CreateSender(queueName));
        });
        services.AddSingleton<IActionRunner, BitLockerForwardingRunner>();
        return services;
    }

    /// <summary>
    /// Registers the privileged bitlocker executor (BitLocker role only):
    /// <see cref="GraphBitLockerService"/> + <see cref="BitLockerRotateRunner"/>.
    /// The runner is registered as a concrete singleton (resolved directly by
    /// the consumer function) AND as <see cref="IActionRunner"/>. Also adds the
    /// probe so tracker init on this app can resolve it.
    /// </summary>
    public static IServiceCollection AddBitLockerExecutor(this IServiceCollection services)
    {
        services.AddSingleton<GraphBitLockerService>();
        services.AddSingleton<BitLockerRotateRunner>();
        services.AddSingleton<IActionRunner>(sp => sp.GetRequiredService<BitLockerRotateRunner>());
        services.AddBitLockerProbe();
        return services;
    }

    /// <summary>
    /// Idempotent <see cref="ServiceBusClient"/> registration (mirrors the
    /// internal helper in Shared / the wipe capability).
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
