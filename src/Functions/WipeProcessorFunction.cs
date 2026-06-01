using System.Text.Json;
using IntuneWipeApi.Actions;
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
    private readonly string _actionType;

    public WipeProcessorFunction(ActionDispatchEnqueuer enqueuer, AuditService audit,
        IConfiguration cfg, ILogger<WipeProcessorFunction> log)
    {
        _enqueuer = enqueuer;
        _audit = audit;
        _log = log;
        // Config-driven routing: setting Wipe:ActionType="wipe-runbook" flips
        // the entire wipe pipeline to the Automation runbook executor without
        // any code change. Default keeps the canonical Function-App path.
        _actionType = string.IsNullOrWhiteSpace(cfg["Wipe:ActionType"])
            ? DefaultWipeActionType
            : cfg["Wipe:ActionType"]!.Trim();
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
            ActionType      = _actionType,
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
