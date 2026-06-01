using Azure.Core;
using Azure.Data.Tables;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Azure.Storage.Blobs;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Middleware;
using IntuneDeviceActions.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;
using Microsoft.Graph;

namespace IntuneDeviceActions;

/// <summary>
/// Cross-cutting DI registrations shared by all three Function App hosts
/// (Web, Proc, Wipe). The split is enforced at the deployment-artifact
/// level: each host project only contains its own Function classes.
/// Per-role runner registrations live in the role-specific Program.cs.
/// </summary>
public static class HostBuilderExtensions
{
    /// <summary>
    /// Adds Azure App Configuration as a layered configuration source when
    /// <c>AppConfig:Endpoint</c> is set. Sentinel-driven refresh polls every
    /// 30s; <see cref="AppConfigRefresherHolder"/> exposes the refresher so
    /// individual functions can opt-in to a per-invocation TryRefreshAsync.
    /// </summary>
    public static IConfigurationBuilder AddIntuneDeviceActionsAppConfig(this IConfigurationBuilder c, string roleHint)
    {
        c.AddEnvironmentVariables();
        var preliminary = c.Build();
        var endpoint = preliminary["AppConfig:Endpoint"];
        if (string.IsNullOrWhiteSpace(endpoint)) return c;

        var role = preliminary["App:Role"] ?? roleHint;
        var clientId = preliminary["Graph:ManagedIdentityClientId"]
            ?? preliminary["AZURE_CLIENT_ID"];
        Console.WriteLine($"[startup] AppConfig source enabled: endpoint={endpoint} role={role} miClientId={(string.IsNullOrEmpty(clientId) ? "(none)" : clientId)}");

        var credOpts = new DefaultAzureCredentialOptions();
        if (!string.IsNullOrWhiteSpace(clientId)) credOpts.ManagedIdentityClientId = clientId;
        var cred = new DefaultAzureCredential(credOpts);

        c.AddAzureAppConfiguration(opt =>
        {
            opt.Connect(new Uri(endpoint), cred)
               .Select(keyFilter: "*")
               .Select(keyFilter: "*", labelFilter: role)
               .ConfigureRefresh(r => r
                    .Register("Sentinel", refreshAll: true)
                    .SetRefreshInterval(TimeSpan.FromSeconds(30)));
            AppConfigRefresherHolder.Instance = opt.GetRefresher();
        });
        return c;
    }

    /// <summary>
    /// Cross-cutting services required by all hosts: telemetry, memory cache,
    /// audit pipeline, AppConfig refresh middleware. Per-role hosts call this
    /// first, then opt into the storage/Graph helpers + runners they need via
    /// the dedicated methods below.
    /// </summary>
    public static IServiceCollection AddIntuneDeviceActionsCore(this IServiceCollection services)
    {
        services.AddSingleton<AppConfigRefreshMiddleware>();
        services.AddLogging();
        services.AddApplicationInsightsTelemetryWorkerService(options =>
        {
            // Sampling DISABLED so security audit customEvents are never dropped.
            options.SamplingRatio = 1.0f;
            options.EnableTraceBasedLogsSampler = false;
        });
        services.AddMemoryCache(o => o.SizeLimit = 100_000);

        services.AddSingleton<AuditService>();

        services.AddSingleton<TokenCredential>(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var tenantId = cfg["Graph:TenantId"];
            var clientId = cfg["Graph:ManagedIdentityClientId"] ?? cfg["AZURE_CLIENT_ID"];
            var opts = new DefaultAzureCredentialOptions();
            if (!string.IsNullOrWhiteSpace(tenantId)) opts.TenantId = tenantId;
            if (!string.IsNullOrWhiteSpace(clientId)) opts.ManagedIdentityClientId = clientId;
            return new DefaultAzureCredential(opts);
        });

        // Audit Table sink — best-effort dual-write alongside App Insights.
        services.AddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var cred = sp.GetRequiredService<TokenCredential>();
            var account = cfg["Audit:StorageAccount"]
                ?? cfg["Idempotency:StorageAccount"]
                ?? cfg["AzureWebJobsStorage__accountName"];
            var tableName = cfg["Audit:TableName"] ?? "auditevents";
            try
            {
                TableClient client;
                if (string.IsNullOrWhiteSpace(account))
                {
                    var conn = cfg["AzureWebJobsStorage"] ?? "UseDevelopmentStorage=true";
                    client = new TableClient(conn, tableName);
                }
                else
                {
                    client = new TableClient(
                        new Uri($"https://{account}.table.core.windows.net"),
                        tableName, cred);
                }
                client.CreateIfNotExists();
                return new AuditTableSink(client, sp.GetRequiredService<ILogger<AuditTableSink>>());
            }
            catch
            {
                return new AuditTableSink(null, sp.GetRequiredService<ILogger<AuditTableSink>>());
            }
        });

        return services;
    }

    /// <summary>
    /// Registers the Graph client + GraphWipeService. Only the Wipe and Proc
    /// roles need this (web role does not call Graph for wipe execution; it
    /// uses DeviceDirectoryResolver which is registered separately).
    /// </summary>
    public static IServiceCollection AddGraphWipe(this IServiceCollection services)
    {
        services.AddSingleton(sp =>
        {
            var cred = sp.GetRequiredService<TokenCredential>();
            return new GraphServiceClient(cred, new[] { "https://graph.microsoft.com/.default" });
        });
        services.AddSingleton<GraphWipeService>();
        return services;
    }

    /// <summary>
    /// Registers the idempotency-ledger blob container client and service.
    /// Used by Web (admin reset), Proc (read-only inspection rarely), Wipe (reserve).
    /// </summary>
    public static IServiceCollection AddIdempotency(this IServiceCollection services)
    {
        services.AddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var cred = sp.GetRequiredService<TokenCredential>();
            var account = cfg["Idempotency:StorageAccount"] ?? cfg["AzureWebJobsStorage__accountName"];
            var container = cfg["Idempotency:BlobContainer"] ?? "action-ledger";
            BlobContainerClient client;
            if (string.IsNullOrWhiteSpace(account))
            {
                client = new BlobContainerClient(cfg["AzureWebJobsStorage"] ?? "UseDevelopmentStorage=true", container);
                client.CreateIfNotExists();
            }
            else
            {
                client = new BlobContainerClient(
                    new Uri($"https://{account}.blob.core.windows.net/{container}"),
                    cred);
            }
            return client;
        });
        services.AddSingleton<IdempotencyService>();
        return services;
    }

    /// <summary>
    /// Wipe status tracker (separate table from auditevents).
    /// Required by Wipe (init state on issue) and Proc (poller updates).
    /// </summary>
    public static IServiceCollection AddActionStatusTracker(this IServiceCollection services)
    {
        services.AddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var cred = sp.GetRequiredService<TokenCredential>();
            var account = cfg["Audit:StorageAccount"]
                ?? cfg["Idempotency:StorageAccount"]
                ?? cfg["AzureWebJobsStorage__accountName"];
            var tableName = cfg["ActionStatus:TableName"] ?? "actionstatus";
            try
            {
                TableClient client;
                if (string.IsNullOrWhiteSpace(account))
                {
                    var conn = cfg["AzureWebJobsStorage"] ?? "UseDevelopmentStorage=true";
                    client = new TableClient(conn, tableName);
                }
                else
                {
                    client = new TableClient(
                        new Uri($"https://{account}.table.core.windows.net"),
                        tableName, cred);
                }
                client.CreateIfNotExists();
                return new ActionStatusTracker(client,
                    sp.GetService<GraphWipeService>(),
                    sp.GetRequiredService<AuditService>(),
                    cfg,
                    sp.GetRequiredService<ILogger<ActionStatusTracker>>());
            }
            catch
            {
                return new ActionStatusTracker(null,
                    sp.GetService<GraphWipeService>(),
                    sp.GetRequiredService<AuditService>(),
                    cfg,
                    sp.GetRequiredService<ILogger<ActionStatusTracker>>());
            }
        });
        return services;
    }

    /// <summary>
    /// Registers a shared <see cref="ServiceBusClient"/> singleton, authenticated
    /// via the host's <see cref="TokenCredential"/> against the namespace given
    /// by <c>ServiceBus:FullyQualifiedNamespace</c> (e.g.
    /// <c>idactions-sb-xxx.servicebus.windows.net</c>). Idempotent — safe to
    /// call from multiple <c>AddXxxSender</c> helpers; only the first wins.
    /// </summary>
    private static IServiceCollection EnsureServiceBusClient(this IServiceCollection services)
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
    /// Sender-side <c>action-requests</c> Service Bus queue client. Web app uses
    /// it to enqueue the initial request; Proc app consumes it via
    /// <c>ServiceBusTrigger</c> (RequestIntakeFunction) — no DI sender needed there.
    /// </summary>
    public static IServiceCollection AddActionRequestSender(this IServiceCollection services)
    {
        services.EnsureServiceBusClient();
        services.AddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var client = sp.GetRequiredService<ServiceBusClient>();
            var queueName = cfg["ServiceBus:ActionRequestsQueue"] ?? "action-requests";
            return new ActionRequestSender(client.CreateSender(queueName));
        });
        return services;
    }

    /// <summary>
    /// Sender-side <c>action-dispatch</c> Service Bus queue client +
    /// <see cref="ActionDispatchEnqueuer"/>. Used by Proc (RequestIntake →
    /// ActionDispatch). Wipe is NOT a producer of this queue.
    /// </summary>
    public static IServiceCollection AddActionDispatchSender(this IServiceCollection services)
    {
        services.EnsureServiceBusClient();
        services.AddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var client = sp.GetRequiredService<ServiceBusClient>();
            var queueName = cfg["ServiceBus:ActionDispatchQueue"] ?? "action-dispatch";
            return new ActionDispatchSender(client.CreateSender(queueName));
        });
        services.AddSingleton<ActionDispatchEnqueuer>();
        return services;
    }

    /// <summary>
    /// Sender-side <c>wipe-action</c> Service Bus queue client (envelope to the
    /// dedicated wipe-runner). Used by Proc (<c>WipeForwardingRunner</c>). The
    /// Wipe app consumes via <c>ServiceBusTrigger</c> — no DI sender needed there.
    /// </summary>
    public static IServiceCollection AddWipeActionSender(this IServiceCollection services)
    {
        services.EnsureServiceBusClient();
        services.AddSingleton(sp =>
        {
            var cfg = sp.GetRequiredService<IConfiguration>();
            var client = sp.GetRequiredService<ServiceBusClient>();
            var queueName = cfg["ServiceBus:WipeActionQueue"] ?? "wipe-action";
            return new WipeActionSender(client.CreateSender(queueName));
        });
        return services;
    }
}
