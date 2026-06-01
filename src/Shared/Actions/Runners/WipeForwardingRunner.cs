using System.Text.Json;
using Azure.Messaging.ServiceBus;
using IntuneDeviceActions.Services;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Actions.Runners;

/// <summary>
/// <see cref="IActionRunner"/> registered on the worker role for the
/// <c>wipe</c> action type. Instead of executing the wipe in-process, it
/// forwards the dispatch envelope to a dedicated per-capability Service Bus
/// queue (<c>wipe-action</c>) which is consumed by a separate Function App
/// (<see cref="IntuneDeviceActions.Functions.WipeActionConsumerFunction"/>).
/// </summary>
/// <remarks>
/// Architectural rationale:
/// <list type="bullet">
///   <item>Isolates the privileged Graph identity to the wipe app only.</item>
///   <item>Independent deploy/scaling/blast-radius for the wipe capability.</item>
///   <item>Keeps the dispatcher generic — adding a new capability still means
///   "new IActionRunner + new app + new queue", with no changes here.</item>
/// </list>
/// </remarks>
public sealed class WipeForwardingRunner : IActionRunner
{
    public string Type => "wipe";

    private readonly WipeActionSender _sender;
    private readonly AuditService _audit;
    private readonly ILogger<WipeForwardingRunner> _log;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public WipeForwardingRunner(WipeActionSender sender, AuditService audit,
        ILogger<WipeForwardingRunner> log)
    {
        _sender = sender;
        _audit = audit;
        _log = log;
    }

    public async Task RunAsync(ActionDispatchMessage envelope, CancellationToken ct)
    {
        var json = JsonSerializer.Serialize(envelope, JsonOptions);
        _log.LogDebug("WipeForwardingRunner sending envelope: corr={Corr} bytes={Bytes} queue={Queue}",
            envelope.CorrelationId, System.Text.Encoding.UTF8.GetByteCount(json), _sender.Sender.EntityPath);
        if (_log.IsEnabled(LogLevel.Trace))
            _log.LogTrace("WipeForwardingRunner payload (Trace only): {Payload}", json);

        var sbMessage = new ServiceBusMessage(json)
        {
            ContentType = "application/json",
            MessageId = envelope.CorrelationId,
            CorrelationId = envelope.CorrelationId,
        };
        sbMessage.ApplicationProperties["actionType"] = envelope.ActionType;
        sbMessage.ApplicationProperties["schemaVersion"] = envelope.SchemaVersion;
        await _sender.Sender.SendMessageAsync(sbMessage, ct);

        _audit.TrackEvent(AuditEvents.ActionForwarded, new Dictionary<string, string>
        {
            [AuditEvents.Prop.CorrelationId]  = envelope.CorrelationId,
            [AuditEvents.Prop.ActionType]     = envelope.ActionType,
            [AuditEvents.Prop.DeviceName]     = envelope.DeviceName,
            [AuditEvents.Prop.EntraDeviceId]  = envelope.EntraDeviceId,
            [AuditEvents.Prop.IntuneDeviceId] = envelope.IntuneDeviceId,
            ["targetQueue"]                   = _sender.Sender.EntityPath,
            ["targetApp"]                     = "wipe-runner",
        });

        _log.LogInformation(
            "Forwarded action '{ActionType}' for {Device} to dedicated wipe-runner queue '{Queue}' (corr={Corr})",
            envelope.ActionType, envelope.DeviceName, _sender.Sender.EntityPath, envelope.CorrelationId);
    }
}
