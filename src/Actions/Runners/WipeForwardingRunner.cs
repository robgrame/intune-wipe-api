using System.Text.Json;
using IntuneWipeApi.Services;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Actions.Runners;

/// <summary>
/// <see cref="IActionRunner"/> registered on the worker role for the
/// <c>wipe</c> action type. Instead of executing the wipe in-process, it
/// forwards the dispatch envelope to a dedicated per-capability Storage Queue
/// (<c>wipe-action</c>) which is consumed by a separate Function App
/// (<see cref="IntuneWipeApi.Functions.WipeActionConsumerFunction"/>).
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

    private readonly WipeActionQueueClient _queue;
    private readonly AuditService _audit;
    private readonly ILogger<WipeForwardingRunner> _log;

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    public WipeForwardingRunner(WipeActionQueueClient queue, AuditService audit,
        ILogger<WipeForwardingRunner> log)
    {
        _queue = queue;
        _audit = audit;
        _log = log;
    }

    public async Task RunAsync(ActionDispatchMessage envelope, CancellationToken ct)
    {
        var json = JsonSerializer.Serialize(envelope, JsonOptions);
        await _queue.Client.SendMessageAsync(json, cancellationToken: ct);

        _audit.TrackEvent(AuditEvents.ActionForwarded, new Dictionary<string, string>
        {
            [AuditEvents.Prop.CorrelationId]  = envelope.CorrelationId,
            [AuditEvents.Prop.ActionType]     = envelope.ActionType,
            [AuditEvents.Prop.DeviceName]     = envelope.DeviceName,
            [AuditEvents.Prop.EntraDeviceId]  = envelope.EntraDeviceId,
            [AuditEvents.Prop.IntuneDeviceId] = envelope.IntuneDeviceId,
            ["targetQueue"]                   = _queue.Client.Name,
            ["targetApp"]                     = "wipe-runner",
        });

        _log.LogInformation(
            "Forwarded action '{ActionType}' for {Device} to dedicated wipe-runner queue '{Queue}' (corr={Corr})",
            envelope.ActionType, envelope.DeviceName, _queue.Client.Name, envelope.CorrelationId);
    }
}
