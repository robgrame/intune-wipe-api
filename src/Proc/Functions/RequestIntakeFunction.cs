using System.Text.Json;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Middleware;
using IntuneDeviceActions.Models;
using IntuneDeviceActions.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Functions;

/// <summary>
/// Thin <b>dispatcher</b> over the <c>action-requests</c> Service Bus queue.
/// </summary>
/// <remarks>
/// <para>
/// Action-agnostic intake: takes an <see cref="ActionRequestMessage"/> (any
/// type), wraps it inside an <see cref="ActionDispatchMessage"/> envelope
/// stamping the <c>ActionType</c> propagated by the HTTP intake, and enqueues
/// it on the <c>action-dispatch</c> queue. The concrete behaviour is then
/// selected by <see cref="ActionDispatchFunction"/> against the
/// <see cref="ActionRunnerRegistry"/>.
/// </para>
/// <list type="number">
///   <item>guards the app role (this must be the worker app);</item>
///   <item>parses the intake payload;</item>
///   <item>resolves the ActionType (message → config fallback) so messages
///         produced by older Web instances without an ActionType field still
///         route to <c>"wipe"</c>;</item>
///   <item>wraps it into an <see cref="ActionDispatchMessage"/> envelope;</item>
///   <item>enqueues the envelope on the <c>action-dispatch</c> queue.</item>
/// </list>
/// <para>
/// To add a new capability: register a new <see cref="IActionRunner"/>; the
/// intake / queue / dispatcher don't change.
/// </para>
/// </remarks>
public sealed class RequestIntakeFunction
{
    private const string DefaultActionType = "wipe";

    private readonly ActionDispatchEnqueuer _enqueuer;
    private readonly AuditService _audit;
    private readonly ILogger<RequestIntakeFunction> _log;
    private readonly IConfiguration _cfg;

    public RequestIntakeFunction(ActionDispatchEnqueuer enqueuer, AuditService audit,
        IConfiguration cfg, ILogger<RequestIntakeFunction> log)
    {
        _enqueuer = enqueuer;
        _audit = audit;
        _log = log;
        _cfg = cfg;
    }

    // Refreshes App Configuration so a flipped Wipe:ActionType (legacy override
    // used when the message does not carry one) is picked up without a restart.
    // The actual resolution order is: 1) the message's own ActionType, 2) the
    // configured legacy default, 3) the hard-coded "wipe" constant.
    private async Task<string> ResolveActionTypeAsync(string? messageActionType, CancellationToken ct)
    {
        if (!string.IsNullOrWhiteSpace(messageActionType))
            return messageActionType.Trim();

        var refresher = AppConfigRefresherHolder.Instance;
        if (refresher is not null)
        {
            try
            {
                var refreshed = await refresher.TryRefreshAsync(ct);
                _log.LogDebug("AppConfig TryRefreshAsync returned {Refreshed}", refreshed);
            }
            catch (Exception ex) { _log.LogWarning(ex, "AppConfig refresh failed; using cached value."); }
        }
        else
        {
            _log.LogTrace("AppConfig refresher not captured — running with startup snapshot only.");
        }
        var actionType = string.IsNullOrWhiteSpace(_cfg["Wipe:ActionType"])
            ? DefaultActionType
            : _cfg["Wipe:ActionType"]!.Trim();
        _log.LogDebug("Resolved ActionType={ActionType} from config fallback (raw cfg value='{Raw}')",
            actionType, _cfg["Wipe:ActionType"] ?? "(null)");
        return actionType;
    }

    [Function("RequestIntake")]
    public async Task Run(
        [ServiceBusTrigger("%ServiceBus:ActionRequestsQueue%", Connection = "ServiceBus")] string messageJson,
        CancellationToken ct)
    {
        var msg = JsonSerializer.Deserialize<ActionRequestMessage>(messageJson)
            ?? throw new InvalidOperationException("Empty/invalid Service Bus payload");

        var actionType = await ResolveActionTypeAsync(msg.ActionType, ct);

        using var scope = _log.BeginScope(new Dictionary<string, object>
        {
            ["CorrelationId"]  = msg.CorrelationId,
            ["ActionType"]     = actionType,
            ["DeviceName"]     = msg.DeviceName,
            ["EntraDeviceId"]  = msg.EntraDeviceId,
            ["IntuneDeviceId"] = msg.IntuneDeviceId,
        });

        _log.LogInformation("Dispatching '{ActionType}' request for {Device} to action runner",
            actionType, msg.DeviceName);

        var envelope = new ActionDispatchMessage
        {
            SchemaVersion   = "1",
            ActionType      = actionType,
            CorrelationId   = msg.CorrelationId,
            DeviceName      = msg.DeviceName,
            EntraDeviceId   = msg.EntraDeviceId,
            IntuneDeviceId  = msg.IntuneDeviceId,
            RequestedAt     = msg.RequestedAt,
            // Default to "let the queue retry me" on failure. Security-critical
            // actions (wipe) should leave this on; opt-out best-effort actions
            // (e.g. a future "sync") can flip it from their producer.
            FailOnError     = true,
            Payload         = JsonSerializer.SerializeToElement(msg, ActionDispatchEnqueuer.JsonOptions),
        };

        await _enqueuer.EnqueueAsync(envelope, ct);
        _log.LogDebug("Dispatch envelope enqueued: corr={Corr} actionType={ActionType} device={Device}",
            envelope.CorrelationId, envelope.ActionType, envelope.DeviceName);
    }
}
