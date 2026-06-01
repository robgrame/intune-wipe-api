using System.Text.Json;
using IntuneWipeApi.Services;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Actions;

/// <summary>
/// Producer-side helper that enqueues an <see cref="ActionDispatchMessage"/>
/// on the storage queue consumed by <c>ActionDispatchFunction</c>.
/// </summary>
/// <remarks>
/// Emits the <c>action.dispatch.enqueued</c> audit event so the full
/// lifecycle can be reconstructed end-to-end via correlationId.
/// </remarks>
public sealed class ActionDispatchEnqueuer
{
    private readonly ActionDispatchQueueClient _queue;
    private readonly AuditService _audit;
    private readonly ILogger<ActionDispatchEnqueuer> _log;

    internal static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public ActionDispatchEnqueuer(
        ActionDispatchQueueClient queue,
        AuditService audit,
        ILogger<ActionDispatchEnqueuer> log)
    {
        _queue = queue;
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
        await _queue.Client.SendMessageAsync(json, cancellationToken: ct);

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
