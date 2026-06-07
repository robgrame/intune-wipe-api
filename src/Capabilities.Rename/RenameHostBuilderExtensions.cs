using Azure.Core;
using Azure.Messaging.ServiceBus;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Capabilities.Rename.Runners;
using IntuneDeviceActions.Capabilities.Rename.Senders;
using IntuneDeviceActions.Capabilities.Rename.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

namespace IntuneDeviceActions.Capabilities.Rename;

/// <summary>
/// Rename-capability DI helpers, mirroring <c>BitLockerHostBuilderExtensions</c>.
/// Each host role calls the subset it needs:
/// <list type="bullet">
///   <item><c>AddRenameForwarding</c> → Proc (dispatcher forwards
///                                      <c>device-rename</c> envelopes to the
///                                      rename-action queue).</item>
///   <item><c>AddRenameExecutor</c>   → Rename (privileged executor:
///                                      ICustomerRenameClient + GraphRenameService +
///                                      RenameActionRunner).</item>
/// </list>
/// </summary>
public static class RenameHostBuilderExtensions
{
    /// <summary>
    /// Registers the proc-side forwarder (<see cref="RenameForwardingRunner"/>
    /// → Service Bus <c>rename-action</c> queue) plus the sender wrapper.
    /// </summary>
    public static IServiceCollection AddRenameForwarding(this IServiceCollection services)
    {
        services.EnsureServiceBusClient();
        services.AddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var client = sp.GetRequiredService<ServiceBusClient>();
            var queueName = cfg["ServiceBus:RenameActionQueue"] ?? "rename-action";
            return new RenameActionSender(client.CreateSender(queueName));
        });
        services.AddSingleton<IActionRunner, RenameForwardingRunner>();
        return services;
    }

    /// <summary>
    /// Registers the rename executor (Rename role only):
    /// <see cref="HttpCustomerRenameClient"/> (typed HttpClient for the CMDB
    /// lookup), <see cref="GraphRenameService"/> (Entra collision check +
    /// Intune setDeviceName) and <see cref="RenameActionRunner"/>.
    /// The runner is registered as a concrete singleton (resolved directly by
    /// the consumer function) AND as <see cref="IActionRunner"/>.
    /// Requires <c>AddGraphClient()</c> from Shared.
    /// </summary>
    public static IServiceCollection AddRenameExecutor(this IServiceCollection services)
    {
        // Typed HttpClient — IHttpClientFactory manages handler lifetime.
        services.AddHttpClient<ICustomerRenameClient, HttpCustomerRenameClient>();
        services.AddSingleton<GraphRenameService>();

        services.AddSingleton<RenameActionRunner>();
        services.AddSingleton<IActionRunner>(sp => sp.GetRequiredService<RenameActionRunner>());
        return services;
    }

    /// <summary>
    /// Idempotent <see cref="ServiceBusClient"/> registration (mirrors the
    /// internal helper in Shared / the other capabilities).
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
