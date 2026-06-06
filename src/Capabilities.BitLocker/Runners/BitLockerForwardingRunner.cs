using System.Text.Json;
using Azure.Messaging.ServiceBus;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Capabilities.BitLocker.Senders;
using IntuneDeviceActions.Services;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Capabilities.BitLocker.Runners;

/// <summary>
/// <see cref="IActionRunner"/> registered on the proc role for the
/// <c>bitlocker-rotate</c> action type. Instead of executing the rotation
/// in-process (the proc app has no privileged Graph identity), it forwards the
/// dispatch envelope to a dedicated per-capability Service Bus queue
/// (<c>bitlocker-action</c>) consumed by the dedicated bitlocker Function App.
/// Structurally identical to <c>WipeForwardingRunner</c>.
/// </summary>
public sealed class BitLockerForwardingRunner : IActionRunner
{
    public string Type => "bitlocker-rotate";

    private readonly BitLockerActionSender _sender;
    private readonly AuditService _audit;
    private readonly ILogger<BitLockerForwardingRunner> _log;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public BitLockerForwardingRunner(BitLockerActionSender sender, AuditService audit,
        ILogger<BitLockerForwardingRunner> log)
    {
        _sender = sender;
        _audit = audit;
        _log = log;
    }

    public async Task RunAsync(ActionDispatchMessage envelope, CancellationToken ct)
    {
        var json = JsonSerializer.Serialize(envelope, JsonOptions);
        _log.LogDebug("BitLockerForwardingRunner sending envelope: corr={Corr} bytes={Bytes} queue={Queue}",
            envelope.CorrelationId, System.Text.Encoding.UTF8.GetByteCount(json), _sender.Sender.EntityPath);

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
            ["targetApp"]                     = "bitlocker-runner",
        });

        _log.LogInformation(
            "Forwarded action '{ActionType}' for {Device} to dedicated bitlocker-runner queue '{Queue}' (corr={Corr})",
            envelope.ActionType, envelope.DeviceName, _sender.Sender.EntityPath, envelope.CorrelationId);
    }
}
