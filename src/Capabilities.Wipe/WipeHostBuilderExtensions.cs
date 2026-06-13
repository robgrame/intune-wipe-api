using Azure.Core;
using Azure.Data.Tables;
using Azure.Messaging.ServiceBus;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Capabilities.Wipe.Runners;
using IntuneDeviceActions.Capabilities.Wipe.Schedule;
using IntuneDeviceActions.Capabilities.Wipe.Senders;
using IntuneDeviceActions.Capabilities.Wipe.Services;
using IntuneDeviceActions.Schedule;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Capabilities.Wipe;

/// <summary>
/// Wipe-capability DI helpers. Each host role calls the subset it needs:
/// <list type="bullet">
///   <item><c>AddWipeProbe</c>  → Proc (poller probes the wipe state) +
///                                Wipe (probe runs on the wipe app's tracker).</item>
///   <item><c>AddWipeForwarding</c> → Proc (forwards wipe envelopes to the
///                                    wipe-action queue + runbook variant).</item>
///   <item><c>AddWipeExecutor</c>   → Wipe (privileged executor: GraphWipeService
///                                    + WipeActionRunner).</item>
/// </list>
/// All three require <see cref="HostBuilderExtensions.AddGraphClient"/> (in
/// Shared) for the bare <see cref="Microsoft.Graph.GraphServiceClient"/>.
/// </summary>
public static class WipeHostBuilderExtensions
{
    /// <summary>
    /// Registers the <see cref="WipeActionStatusProbe"/> so the action status
    /// poller knows how to ask Graph for the current wipe state on rows whose
    /// <c>ActionType=="wipe"</c>. Call this on every role whose tracker may
    /// poll wipe rows (Proc for the poller; Wipe for tracker init reads).
    /// </summary>
    public static IServiceCollection AddWipeProbe(this IServiceCollection services)
    {
        services.AddSingleton<IActionStatusProbe, WipeActionStatusProbe>();
        return services;
    }

    /// <summary>
    /// Registers the proc-side forwarders: <see cref="WipeForwardingRunner"/>
    /// (wipe → Service Bus <c>wipe-action</c> queue) and
    /// <see cref="WipeRunbookForwardingRunner"/> (wipe-runbook → Azure
    /// Automation webhook). Includes the sender wrapper around the dedicated
    /// per-capability queue.
    /// </summary>
    public static IServiceCollection AddWipeForwarding(this IServiceCollection services)
    {
        services.EnsureServiceBusClient();
        services.AddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var client = sp.GetRequiredService<ServiceBusClient>();
            var queueName = cfg["ServiceBus:WipeActionQueue"] ?? "wipe-action";
            return new WipeActionSender(client.CreateSender(queueName));
        });
        services.AddSingleton<IActionRunner, WipeForwardingRunner>();
        services.AddSingleton<IActionRunner, WipeRunbookForwardingRunner>();
        return services;
    }

    /// <summary>
    /// Registers the privileged wipe executor (Wipe role only):
    /// <see cref="GraphWipeService"/> + <see cref="WipeActionRunner"/>. The
    /// runner is registered as a concrete singleton (resolved directly by
    /// <c>WipeActionConsumerFunction</c>) AND as <see cref="IActionRunner"/>
    /// (so any future generic dispatcher on the wipe app could resolve it).
    /// Also adds the probe so tracker init on the wipe app can resolve it.
    /// </summary>
    public static IServiceCollection AddWipeExecutor(this IServiceCollection services)
    {
        services.AddSingleton<GraphWipeService>();
        services.AddSingleton<WipeActionRunner>();
        services.AddSingleton<IActionRunner>(sp => sp.GetRequiredService<WipeActionRunner>());
        services.AddWipeProbe();
        return services;
    }

    /// <summary>
    /// Idempotent <see cref="ServiceBusClient"/> registration (mirrors the
    /// internal helper in Shared, public here so this capability project can
    /// own its own queue sender registration without leaking it).
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

    /// <summary>
    /// Registers the wipe-schedule storage facade (<see cref="WipeScheduleStore"/>).
    /// Called by:
    /// <list type="bullet">
    ///   <item>the <b>Wipe</b> executor host — so <see cref="WipeActionRunner"/>
    ///         can enforce capability-side temporal gating (defer wipes whose
    ///         wave hasn't fired yet);</item>
    ///   <item>the <b>Web</b> host — together with <see cref="AddWipeScheduleProvider"/>
    ///         so the generic <c>GET /api/schedule/me</c> endpoint can include
    ///         wipe schedules via the wipe provider.</item>
    /// </list>
    /// Reads <c>WipeSchedule:StorageAccount</c> (or falls back to
    /// <c>AzureWebJobsStorage__accountName</c>), <c>WipeSchedule:WavesTable</c>
    /// (default <c>wipeschedulewaves</c>) and <c>WipeSchedule:MembersTable</c>
    /// (default <c>wipeschedulemembers</c>).
    /// </summary>
    public static IServiceCollection AddWipeScheduleStore(this IServiceCollection services)
    {
        services.TryAddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var cred = sp.GetRequiredService<TokenCredential>();

            var account = cfg["WipeSchedule:StorageAccount"]
                ?? cfg["Audit:StorageAccount"]
                ?? cfg["AzureWebJobsStorage__accountName"];
            var wavesName = cfg["WipeSchedule:WavesTable"] ?? "wipeschedulewaves";
            var membersName = cfg["WipeSchedule:MembersTable"] ?? "wipeschedulemembers";

            TableClient waves, members;
            if (string.IsNullOrWhiteSpace(account))
            {
                var conn = cfg["AzureWebJobsStorage"] ?? "UseDevelopmentStorage=true";
                waves = new TableClient(conn, wavesName);
                members = new TableClient(conn, membersName);
            }
            else
            {
                var baseUri = new Uri($"https://{account}.table.core.windows.net");
                waves = new TableClient(baseUri, wavesName, cred);
                members = new TableClient(baseUri, membersName, cred);
            }
            return new WipeScheduleStore(waves, members,
                sp.GetRequiredService<ILogger<WipeScheduleStore>>());
        });
        return services;
    }

    /// <summary>
    /// Registers the wipe adapter onto the generic
    /// <see cref="IScheduleProvider"/> extension point so the core schedule
    /// aggregator (Web role) can return wipe waves to clients without taking
    /// a dependency on wipe-specific types. Implies
    /// <see cref="AddWipeScheduleStore"/>.
    /// </summary>
    public static IServiceCollection AddWipeScheduleProvider(this IServiceCollection services)
    {
        services.AddWipeScheduleStore();
        services.AddSingleton<IScheduleProvider, WipeScheduleProvider>();
        return services;
    }
}
