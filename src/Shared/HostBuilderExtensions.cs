using Azure.Core;
using Azure.Data.Tables;
using Azure.Identity;
using Azure.Messaging.ServiceBus;
using Azure.Monitor.OpenTelemetry.Exporter;
using Azure.Storage.Blobs;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Middleware;
using IntuneDeviceActions.Services;
using IntuneDeviceActions.Telemetry;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging;
using Microsoft.Graph;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

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
    /// <para>
    /// When <paramref name="cfg"/> is supplied, also auto-registers any
    /// configured runbook-bridge runners
    /// (<see cref="RunbookBridgeExtensions.AddRunbookBridgeRunners"/>) so a
    /// dispatcher role can attach Azure Automation runbooks to Service Bus
    /// queues purely via App Configuration, with no per-capability code.
    /// </para>
    /// </summary>
    public static IServiceCollection AddIntuneDeviceActionsCore(this IServiceCollection services, IConfiguration? cfg = null)
    {
        services.AddSingleton<AppConfigRefreshMiddleware>();
        services.AddSingleton<ServiceBusTraceContextMiddleware>();
        services.AddLogging();
        services.AddApplicationInsightsTelemetryWorkerService(options =>
        {
            // Sampling DISABLED so security audit customEvents are never dropped.
            options.SamplingRatio = 1.0f;
            options.EnableTraceBasedLogsSampler = false;
            // Dependency tracking is now owned by the OpenTelemetry pipeline
            // (AddIntuneDeviceActionsOpenTelemetry → Azure Monitor exporter).
            // Disabling the classic AI dependency module avoids duplicate
            // dependency rows in App Insights for Service Bus / HTTP / Azure
            // SDK calls that OTel also covers.
            options.EnableDependencyTrackingTelemetryModule = false;
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

        // Auto-register runbook-bridge runners from App Configuration
        // (RunbookBridge:Routes:<actionType>=<webhookUrl>). When cfg is null
        // (e.g. unit tests calling the parameterless overload), this is a no-op.
        if (cfg is not null)
        {
            services.AddRunbookBridgeRunners(cfg);
        }

        return services;
    }

    /// <summary>
    /// Registers a bare <see cref="GraphServiceClient"/> singleton authenticated
    /// via the host's <see cref="TokenCredential"/>. This is the action-agnostic
    /// half of the previous <c>AddGraphWipe()</c> — capability-specific Graph
    /// services (e.g. <c>GraphWipeService</c>) live in their own capability
    /// project and call this from their own DI helper.
    /// <para>
    /// All roles that need Graph (Web for DeviceDirectoryResolver, Proc for the
    /// wipe-status probe and any future generic Graph reads, Wipe for the
    /// privileged executor) call this helper. The Graph identity granted to
    /// each role is what restricts what those calls can actually do.
    /// </para>
    /// </summary>
    public static IServiceCollection AddGraphClient(this IServiceCollection services)
    {
        services.TryAddSingleton(sp =>
        {
            var cred = sp.GetRequiredService<TokenCredential>();
            return new GraphServiceClient(cred, new[] { "https://graph.microsoft.com/.default" });
        });
        return services;
    }

    /// <summary>
    /// Registers the action-agnostic idempotency-ledger blob container client
    /// and service. Used by Web (admin reset), Proc (read-only inspection
    /// rarely), Wipe (reserve before issuing).
    /// </summary>
    public static IServiceCollection AddActionIdempotency(this IServiceCollection services)
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
        services.AddSingleton<ActionIdempotencyService>();
        return services;
    }

    /// <summary>
    /// Action-status tracker (separate table from auditevents). Required by
    /// Wipe (init state on issue) and Proc (poller updates). The tracker is
    /// capability-agnostic: per-capability <see cref="IActionStatusProbe"/>
    /// implementations are resolved via DI and dispatched by the row's
    /// <c>ActionType</c> column.
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
            var probes = sp.GetServices<IActionStatusProbe>();
            // The TableClient constructor performs NO I/O — it just binds a
            // URI and a credential — so it is safe to build at DI time.
            // CreateIfNotExists() (which DOES hit the network and used to be
            // called here) is now deferred to the first write inside
            // ActionStatusTracker.EnsureTableExistsAsync, with single-flight
            // semantics and retry on failure. Previously a transient cold-
            // start failure (e.g. DNS for a freshly-provisioned private
            // endpoint not yet propagated, or RBAC still propagating)
            // permanently disabled the tracker for the lifetime of the host
            // and forced every GET /api/actions/status to return 503 until
            // the Function App recycled.
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
            return new ActionStatusTracker(client, probes,
                sp.GetRequiredService<AuditService>(),
                cfg,
                sp.GetRequiredService<ILogger<ActionStatusTracker>>());
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
    /// Registers an OpenTelemetry <c>TracerProvider</c> wired to the Azure
    /// Monitor exporter. This is the layer that gives App Insights a single
    /// end-to-end trace across Web → Service Bus → Proc → Service Bus → Wipe.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Instrumentations enabled:
    /// </para>
    /// <list type="bullet">
    ///   <item><b>HttpClient</b> — replaces the classic AI dependency module
    ///         (disabled in <see cref="AddIntuneDeviceActionsCore"/>) and
    ///         covers Microsoft Graph calls made by <c>GraphServiceClient</c>.</item>
    ///   <item><b>Azure SDK sources</b> (Service Bus, Storage, Tables, Core HTTP)
    ///         — gives us send/receive spans with W3C trace propagation built in.</item>
    ///   <item><b>Custom source <see cref="InstrumentationActivity.ServiceName"/></b>
    ///         — used by <see cref="Middleware.ServiceBusTraceContextMiddleware"/>
    ///         to root the consumer-side function activity under the producer's
    ///         trace context (the link that stitches the pipeline together).</item>
    /// </list>
    /// <para>
    /// We deliberately do NOT add ASP.NET Core or Functions-worker auto-
    /// instrumentation: the classic Functions App Insights bridge still owns
    /// the <c>requests</c> table, and adding either would produce duplicate
    /// invocation rows.
    /// </para>
    /// <para>
    /// The exporter reads <c>APPLICATIONINSIGHTS_CONNECTION_STRING</c> from
    /// the environment automatically; we still pass it through explicitly
    /// when configured to keep the wiring obvious in code review.
    /// </para>
    /// <para>
    /// Sampling is set to <c>AlwaysOnSampler</c> for parity with the AI
    /// worker telemetry options (<c>SamplingRatio = 1.0f</c>): audit-relevant
    /// spans must never be dropped.
    /// </para>
    /// </remarks>
    /// <param name="services">Service collection to attach to.</param>
    /// <param name="role">Logical role of this host (e.g. <c>"web"</c>,
    /// <c>"proc"</c>, <c>"wipe"</c>). Used as the
    /// <c>service.name</c> resource attribute so the three apps show up as
    /// distinct nodes in the App Insights application map.</param>
    public static IServiceCollection AddIntuneDeviceActionsOpenTelemetry(
        this IServiceCollection services,
        string role)
    {
        var serviceName = $"idactions-{role}";
        var instanceId = Environment.MachineName;

        // The Functions worker ASP.NET Core integration (used by the Web host
        // via ConfigureFunctionsWebApplication) auto-wires the *cross-cutting*
        // Azure Monitor exporter (services.UseAzureMonitorExporter) at startup
        // when APPLICATIONINSIGHTS_CONNECTION_STRING is set. The Azure Monitor
        // SDK throws NotSupportedException if we then also register the
        // signal-specific .AddAzureMonitorTraceExporter on the TracerProvider:
        // "Signal-specific AddAzureMonitorExporter / UseAzureMonitor methods
        //  and the cross-cutting UseAzureMonitorExporter method being invoked
        //  on the same IServiceCollection is not supported."
        // Probe IServiceCollection BEFORE we call AddOpenTelemetry — any
        // pre-existing Azure.Monitor.OpenTelemetry.* registration means the
        // cross-cutting exporter is already in place and our shared
        // TracerProvider sources will be exported through it.
        var crossCuttingExporterAlreadyWired = services.Any(d =>
            (d.ServiceType.FullName?.StartsWith("Azure.Monitor.OpenTelemetry.", StringComparison.Ordinal) ?? false)
            || (d.ImplementationType?.FullName?.StartsWith("Azure.Monitor.OpenTelemetry.", StringComparison.Ordinal) ?? false));

        services.AddOpenTelemetry()
            .WithTracing(tracing =>
            {
                tracing
                .SetResourceBuilder(ResourceBuilder.CreateDefault()
                    .AddService(
                        serviceName: serviceName,
                        serviceNamespace: "IntuneDeviceActions",
                        serviceVersion: typeof(HostBuilderExtensions).Assembly.GetName().Version?.ToString() ?? "1.0.0",
                        serviceInstanceId: instanceId)
                    .AddAttributes(new[]
                    {
                        new KeyValuePair<string, object>("deployment.environment",
                            Environment.GetEnvironmentVariable("AZURE_ENV_NAME")
                                ?? Environment.GetEnvironmentVariable("ASPNETCORE_ENVIRONMENT")
                                ?? "production"),
                        new KeyValuePair<string, object>("idactions.role", role),
                    }))
                .SetSampler(new AlwaysOnSampler())
                // Custom spans (e.g. the ServiceBusTraceContextMiddleware consumer span).
                .AddSource(InstrumentationActivity.ServiceName)
                // Azure SDK activity sources — names must be exact, wildcards are
                // not supported by AddSource. List the SDKs we actually use.
                .AddSource("Azure.Messaging.ServiceBus")
                .AddSource("Azure.Messaging.ServiceBus.Sender")
                .AddSource("Azure.Messaging.ServiceBus.Receiver")
                .AddSource("Azure.Messaging.ServiceBus.Processor")
                .AddSource("Azure.Storage.Blobs")
                .AddSource("Azure.Data.Tables")
                .AddSource("Azure.Core.Http")
                // HttpClient — covers Microsoft Graph calls. We disabled the
                // classic AI DependencyTrackingTelemetryModule to prevent
                // double-counting; OTel is now the single source of truth for
                // outbound HTTP dependencies.
                .AddHttpClientInstrumentation(o =>
                {
                    // Skip the Functions worker's internal gRPC channel — it
                    // would otherwise show up as a noisy "POST localhost:..."
                    // dependency on every invocation.
                    o.FilterHttpRequestMessage = req =>
                        req?.RequestUri is not null
                        && !string.Equals(req.RequestUri.Host, "localhost", StringComparison.OrdinalIgnoreCase)
                        && !string.Equals(req.RequestUri.Host, "127.0.0.1", StringComparison.Ordinal);
                });

                if (!crossCuttingExporterAlreadyWired)
                {
                    tracing.AddAzureMonitorTraceExporter(o =>
                    {
                        var conn = Environment.GetEnvironmentVariable("APPLICATIONINSIGHTS_CONNECTION_STRING");
                        if (!string.IsNullOrWhiteSpace(conn))
                        {
                            o.ConnectionString = conn;
                        }
                    });
                }
            });

        return services;
    }
}
