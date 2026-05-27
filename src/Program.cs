using Azure.Core;
using Azure.Identity;
using Azure.Storage.Blobs;
using Azure.Storage.Queues;
using IntuneWipeApi.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Graph;

var host = new HostBuilder()
    .ConfigureFunctionsWebApplication(b => b.UseDefaultWorkerMiddleware())
    .ConfigureAppConfiguration(c => c.AddEnvironmentVariables())
    .ConfigureServices((ctx, services) =>
    {
        services.AddLogging();
        services.AddApplicationInsightsTelemetryWorkerService();
        services.AddMemoryCache(o => o.SizeLimit = 100_000);

        var cfg = ctx.Configuration;

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
            var account = cfg["AzureWebJobsStorage__accountName"] ?? cfg["Idempotency:StorageAccount"];
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

        services.AddSingleton(sp =>
        {
            var cred = sp.GetRequiredService<TokenCredential>();
            return new GraphServiceClient(cred, new[] { "https://graph.microsoft.com/.default" });
        });
        services.AddSingleton<GraphWipeService>();
    })
    .Build();

host.Run();
