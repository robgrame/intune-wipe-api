using Azure.Core;
using Azure.Data.Tables;
using Azure.Identity;
using Azure.Storage.Blobs;
using Azure.Storage.Queues;
using IntuneWipeApi.Actions;
using IntuneWipeApi.Actions.Runners;
using IntuneWipeApi.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Graph;

var host = new HostBuilder()
    .ConfigureFunctionsWebApplication(b => b.UseDefaultWorkerMiddleware())
    .ConfigureAppConfiguration(c => c.AddEnvironmentVariables())
    .ConfigureServices((ctx, services) =>
    {
        services.AddLogging();
        // Worker telemetry pipeline. Adaptive sampling is DISABLED so that
        // security/audit customEvents emitted via AuditService are NEVER dropped.
        // host.json additionally excludes Event/Exception from the host's own
        // sampling (which applies to Functions runtime telemetry).
        services.AddApplicationInsightsTelemetryWorkerService(options =>
        {
            // App Insights SDK v3 uses fixed-rate sampling (not adaptive).
            // 1.0 = sample 100% (no sampling). Audit customEvents emitted via
            // AuditService must NEVER be dropped on a security-critical pipeline.
            options.SamplingRatio = 1.0f;
            options.EnableTraceBasedLogsSampler = false;
        });
        // NOTE: services.ConfigureFunctionsApplicationInsights() — the Functions
        // worker-AI bridge — was tested here and triggered a host startup crash
        // (worker SIGABRT on .NET 10 + WorkerService 3.1.1 + isolated). Removed
        // for stability. Worker-emitted TrackEvent calls still flow to App
        // Insights via TelemetryClient; operation_Id propagation may be best-
        // effort instead of guaranteed. Revisit if/when the bridge package
        // supports this combination.
        services.AddMemoryCache(o => o.SizeLimit = 100_000);

        var cfg = ctx.Configuration;

        services.AddSingleton<AuditService>();
        services.AddSingleton<DeviceDirectoryResolver>();
        services.AddSingleton<ClientCertValidator>();
        services.AddSingleton<ReplayProtector>();

        services.AddSingleton<TokenCredential>(_ =>
        {
            var tenantId = cfg["Graph:TenantId"];
            var clientId = cfg["Graph:ManagedIdentityClientId"] ?? cfg["AZURE_CLIENT_ID"];
            var opts = new DefaultAzureCredentialOptions();
            if (!string.IsNullOrWhiteSpace(tenantId)) opts.TenantId = tenantId;
            if (!string.IsNullOrWhiteSpace(clientId)) opts.ManagedIdentityClientId = clientId;
            return new DefaultAzureCredential(opts);
        });

        services.AddSingleton(sp =>
        {
            var cred = sp.GetRequiredService<TokenCredential>();
            var queueName = cfg["Queue:WipeQueueName"] ?? "wipe-requests";
            // Prefer an explicit Queue:StorageAccount so the web app can target a
            // *different* storage account (proc's) than its own AzureWebJobsStorage.
            // This is the privilege-isolation boundary: the web identity only has
            // Queue Data Message Sender scoped to the wipe queue on that account.
            var account = cfg["Queue:StorageAccount"]
                ?? cfg["AzureWebJobsStorage__accountName"]
                ?? cfg["Idempotency:StorageAccount"];
            var options = new QueueClientOptions { MessageEncoding = QueueMessageEncoding.None };
            QueueClient client;
            if (string.IsNullOrWhiteSpace(account))
            {
                // Local dev fallback (Azurite): create on demand
                client = new QueueClient(cfg["AzureWebJobsStorage"] ?? "UseDevelopmentStorage=true", queueName, options);
                client.CreateIfNotExists();
            }
            else
            {
                // Azure: queue is provisioned by Bicep; identity has Send-only role
                client = new QueueClient(
                    new Uri($"https://{account}.queue.core.windows.net/{queueName}"),
                    cred, options);
            }
            return client;
        });

        services.AddSingleton(sp =>
        {
            var cred = sp.GetRequiredService<TokenCredential>();
            var account = cfg["Idempotency:StorageAccount"] ?? cfg["AzureWebJobsStorage__accountName"];
            var container = cfg["Idempotency:BlobContainer"] ?? "wipe-ledger";
            BlobContainerClient client;
            if (string.IsNullOrWhiteSpace(account))
            {
                // Local dev fallback (Azurite): create on demand
                client = new BlobContainerClient(cfg["AzureWebJobsStorage"] ?? "UseDevelopmentStorage=true", container);
                client.CreateIfNotExists();
            }
            else
            {
                // Azure: container is provisioned by Bicep
                client = new BlobContainerClient(
                    new Uri($"https://{account}.blob.core.windows.net/{container}"),
                    cred);
            }
            return client;
        });

        services.AddSingleton<IdempotencyService>();

        // Audit persistence sink (Table Storage). Best-effort, dual-write
        // alongside App Insights. Disabled gracefully if no storage account
        // is configured (provider returns a sink with no underlying client → no-ops).
        services.AddSingleton(sp =>
        {
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
                        tableName,
                        cred);
                }
                client.CreateIfNotExists();
                return new AuditTableSink(client, sp.GetRequiredService<ILogger<AuditTableSink>>());
            }
            catch
            {
                // Fall back to disabled sink — never fail host startup over audit persistence.
                return new AuditTableSink(null, sp.GetRequiredService<ILogger<AuditTableSink>>());
            }
        });

        services.AddSingleton(sp =>
        {
            var cred = sp.GetRequiredService<TokenCredential>();
            return new GraphServiceClient(cred, new[] { "https://graph.microsoft.com/.default" });
        });
        services.AddSingleton<GraphWipeService>();

        // --- Plug-in action dispatch pipeline -----------------------------
        // ActionDispatchEnqueuer wraps a dedicated QueueClient (action-dispatch
        // queue, same storage account as wipe-requests). Adding a new action
        // capability is a one-liner here: services.AddSingleton<IActionRunner, MyRunner>().
        services.AddSingleton(sp =>
        {
            var cred = sp.GetRequiredService<TokenCredential>();
            var queueName = cfg["Actions:DispatchQueueName"] ?? "action-dispatch";
            var account = cfg["Queue:StorageAccount"]
                ?? cfg["AzureWebJobsStorage__accountName"]
                ?? cfg["Idempotency:StorageAccount"];
            // Base64 encoding matches the Functions queue trigger default —
            // WipeRequestFunction base64-encodes manually for the SAME reason
            // (see comment there). Using QueueMessageEncoding.Base64 lets the
            // SDK do it transparently for any caller of this client.
            var options = new QueueClientOptions { MessageEncoding = QueueMessageEncoding.Base64 };
            QueueClient client;
            if (string.IsNullOrWhiteSpace(account))
            {
                client = new QueueClient(cfg["AzureWebJobsStorage"] ?? "UseDevelopmentStorage=true", queueName, options);
                client.CreateIfNotExists();
            }
            else
            {
                client = new QueueClient(
                    new Uri($"https://{account}.queue.core.windows.net/{queueName}"),
                    cred, options);
            }
            return new ActionDispatchQueueClient(client);
        });
        services.AddSingleton<ActionDispatchEnqueuer>();
        services.AddSingleton<ActionRunnerRegistry>();
        // Built-in runners — add new IActionRunner registrations below for new capabilities.
        services.AddSingleton<IActionRunner, WipeActionRunner>();
        // ------------------------------------------------------------------

        // Wipe action status tracker (separate table from auditevents because
        // it's upsert-per-correlationId, not append-only). Pollato dal
        // WipeStatusPollerFunction (timer trigger ogni 5 min).
        services.AddSingleton(sp =>
        {
            var cred = sp.GetRequiredService<TokenCredential>();
            var account = cfg["Audit:StorageAccount"]
                ?? cfg["Idempotency:StorageAccount"]
                ?? cfg["AzureWebJobsStorage__accountName"];
            var tableName = cfg["WipeStatus:TableName"] ?? "wipestatus";
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
                        tableName,
                        cred);
                }
                client.CreateIfNotExists();
                return new WipeStatusTracker(client,
                    sp.GetRequiredService<GraphWipeService>(),
                    sp.GetRequiredService<AuditService>(),
                    cfg,
                    sp.GetRequiredService<ILogger<WipeStatusTracker>>());
            }
            catch
            {
                return new WipeStatusTracker(null,
                    sp.GetRequiredService<GraphWipeService>(),
                    sp.GetRequiredService<AuditService>(),
                    cfg,
                    sp.GetRequiredService<ILogger<WipeStatusTracker>>());
            }
        });
    })
    .Build();

host.Run();
