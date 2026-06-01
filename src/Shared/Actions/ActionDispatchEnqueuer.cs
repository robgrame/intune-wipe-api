using System.Text.Json;
using Azure.Messaging.ServiceBus;
using IntuneDeviceActions.Services;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Actions;

/// <summary>
/// Producer-side helper that publishes an <see cref="ActionDispatchMessage"/>
/// to the <c>action-dispatch</c> Service Bus queue consumed by
/// <c>ActionDispatchFunction</c>.
/// </summary>
/// <remarks>
/// Emits the <c>action.dispatch.enqueued</c> audit event so the full
/// lifecycle can be reconstructed end-to-end via correlationId.
/// </remarks>
public sealed class ActionDispatchEnqueuer
{
    private readonly ActionDispatchSender _sender;
    private readonly AuditService _audit;
    private readonly ILogger<ActionDispatchEnqueuer> _log;

    internal static readonly JsonSerializerOptions JsonOptionsInternal = new(JsonSerializerDefaults.Web);
    public static readonly JsonSerializerOptions JsonOptions = JsonOptionsInternal;

    public ActionDispatchEnqueuer(
        ActionDispatchSender sender,
        AuditService audit,
        ILogger<ActionDispatchEnqueuer> log)
    {
        _sender = sender;
        _audit = audit;
        _log = log;
    }

    public async Task EnqueueAsync(ActionDispatchMessage message, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(message.ActionType))
            throw new ArgumentException("ActionType is required.", nameof(message));
        if (string.IsNullOrWhiteSpace(message.CorrelationId))
            throw new ArgumentException("CorrelationId is required.", nameof(message));

        message.DispatchedAt = DateTimeOffset.UtcNow;
        var json = JsonSerializer.Serialize(message, JsonOptions);
        var sbMessage = new ServiceBusMessage(json)
        {
            ContentType = "application/json",
            MessageId = message.CorrelationId,
            CorrelationId = message.CorrelationId,
        };
        sbMessage.ApplicationProperties["actionType"] = message.ActionType;
        sbMessage.ApplicationProperties["schemaVersion"] = message.SchemaVersion;
        await _sender.Sender.SendMessageAsync(sbMessage, ct);

        _audit.TrackEvent(AuditEvents.ActionDispatchEnqueued, new Dictionary<string, string>
        {
            [AuditEvents.Prop.CorrelationId]  = message.CorrelationId,
            [AuditEvents.Prop.ActionType]     = message.ActionType,
            [AuditEvents.Prop.DeviceName]     = message.DeviceName,
            [AuditEvents.Prop.EntraDeviceId]  = message.EntraDeviceId,
            [AuditEvents.Prop.IntuneDeviceId] = message.IntuneDeviceId,
            [AuditEvents.Prop.SchemaVersion]  = message.SchemaVersion,
        });

        _log.LogInformation(
            "Enqueued action '{ActionType}' for {Device} (corr={Corr})",
            message.ActionType, message.DeviceName, message.CorrelationId);
    }
}
