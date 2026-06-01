using System.Text.Json;
using IntuneWipeApi.Actions;
using IntuneWipeApi.Middleware;
using IntuneWipeApi.Models;
using IntuneWipeApi.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Functions;

/// <summary>
/// Thin <b>dispatcher</b> over the <c>wipe-requests</c> storage queue.
/// </summary>
/// <remarks>
/// <para>
/// Historically this function executed the entire wipe pipeline inline. As of
/// the plug-in refactor it ONLY:
/// </para>
/// <list type="number">
///   <item>guards the app role (this must be the worker app);</item>
///   <item>parses the wipe-specific <see cref="WipeQueueMessage"/> intake payload;</item>
///   <item>wraps it inside an <see cref="ActionDispatchMessage"/> envelope with <c>ActionType="wipe"</c>;</item>
///   <item>enqueues the envelope on the <c>action-dispatch</c> queue.</item>
/// </list>
/// <para>
/// The actual Graph wipe + idempotency + nudges + status-tracker init live in
/// <see cref="Actions.Runners.WipeActionRunner"/> and are invoked by
/// <see cref="ActionDispatchFunction"/>. This keeps the intake/queue layer
/// stable while new capabilities are added behind <see cref="IActionRunner"/>.
/// </para>
/// </remarks>
public sealed class WipeProcessorFunction
{
    private const string DefaultWipeActionType = "wipe";

    private readonly ActionDispatchEnqueuer _enqueuer;
    private readonly AuditService _audit;
    private readonly ILogger<WipeProcessorFunction> _log;
    private readonly IConfiguration _cfg;

    public WipeProcessorFunction(ActionDispatchEnqueuer enqueuer, AuditService audit,
        IConfiguration cfg, ILogger<WipeProcessorFunction> log)
    {
        _enqueuer = enqueuer;
        _audit = audit;
        _log = log;
        _cfg = cfg;
    }

    // Read per-invocation so a hot-reloaded value from Azure App Configuration
    // (triggered by bumping the 'Sentinel' key) actually flips routing on the
    // next message without restarting the worker. We invoke TryRefreshAsync
    // here directly (rather than relying on a worker middleware) because
    // wiring middleware via b.UseMiddleware<T>() inside
    // ConfigureFunctionsWebApplication did not reliably fire for queue triggers
    // in dotnet-isolated 10.0. Calling on the captured refresher is cheap:
    // the provider polls the store at most once per SetRefreshInterval (30s).
    private async Task<string> CurrentActionTypeAsync(CancellationToken ct)
    {
        var refresher = AppConfigRefresherHolder.Instance;
        if (refresher is not null)
        {
            try { await refresher.TryRefreshAsync(ct); }
            catch (Exception ex) { _log.LogWarning(ex, "AppConfig refresh failed; using cached value."); }
        }
        return string.IsNullOrWhiteSpace(_cfg["Wipe:ActionType"])
            ? DefaultWipeActionType
            : _cfg["Wipe:ActionType"]!.Trim();
    }

    [Function("WipeProcessor")]
    public async Task Run(
        [QueueTrigger("%Queue:WipeQueueName%", Connection = "AzureWebJobsStorage")] string messageJson,
        CancellationToken ct)
    {
        // App role guard — throwing releases the message back so the correct
        // worker app can pick it up; after max attempts it poison-queues.
        if (!AppRoleGuard.IsAllowed(AppRoleGuard.Proc))
        {
            _audit.TrackEvent(AuditEvents.DeniedAppRoleMismatch, new Dictionary<string, string>
            {
                [AuditEvents.Prop.ExpectedRole] = AppRoleGuard.Proc,
                [AuditEvents.Prop.ActualRole]   = AppRoleGuard.CurrentRole ?? "",
                ["function"]                    = "WipeProcessor",
            }, LogLevel.Error);
            throw new InvalidOperationException(
                $"App role mismatch: this Function App is not the wipe processor (App__Role='{AppRoleGuard.CurrentRole}')");
        }

        var msg = JsonSerializer.Deserialize<WipeQueueMessage>(messageJson)
            ?? throw new InvalidOperationException("Empty/invalid queue payload");

        using var scope = _log.BeginScope(new Dictionary<string, object>
        {
            ["CorrelationId"]  = msg.CorrelationId,
            ["DeviceName"]     = msg.DeviceName,
            ["EntraDeviceId"]  = msg.EntraDeviceId,
            ["IntuneDeviceId"] = msg.IntuneDeviceId,
        });

        _log.LogInformation("Dispatching wipe request for {Device} to action runner", msg.DeviceName);

        var envelope = new ActionDispatchMessage
        {
            SchemaVersion   = "1",
            ActionType      = await CurrentActionTypeAsync(ct),
            CorrelationId   = msg.CorrelationId,
            DeviceName      = msg.DeviceName,
            EntraDeviceId   = msg.EntraDeviceId,
            IntuneDeviceId  = msg.IntuneDeviceId,
            RequestedAt     = msg.RequestedAt,
            FailOnError     = true, // wipe is security-critical → honour queue retries
            Payload         = JsonSerializer.SerializeToElement(msg, ActionDispatchEnqueuer.JsonOptions),
        };

        await _enqueuer.EnqueueAsync(envelope, ct);
    }
}
