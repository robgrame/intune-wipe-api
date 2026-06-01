using System.Text.Json;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Actions.Runners;
using IntuneDeviceActions.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Functions;

/// <summary>
/// Dedicated per-capability consumer for the <c>wipe-action</c> Storage Queue.
/// Runs ONLY on the wipe-runner Function App (artifact isolation — this
/// Function class is deployed only to the Wipe assembly), which holds the
/// privileged Graph identity. The Proc app's
/// <see cref="WipeForwardingRunner"/> is the only producer.
/// </summary>
/// <remarks>
/// <para>
/// This is functionally equivalent to <see cref="ActionDispatchFunction"/>,
/// but bound to a per-capability queue and a per-capability app role. It
/// re-uses the same <see cref="ActionDispatchMessage"/> envelope so producers
/// don't see any wire-format change.
/// </para>
/// <para>
/// The wipe app also has <see cref="WipeActionRunner"/> registered in DI;
/// this function resolves it directly (bypassing the generic registry) to
/// make the privilege/responsibility boundary obvious.
/// </para>
/// </remarks>
public sealed class WipeActionConsumerFunction
{
    private readonly WipeActionRunner _runner;
    private readonly AuditService _audit;
    private readonly ILogger<WipeActionConsumerFunction> _log;

    public WipeActionConsumerFunction(WipeActionRunner runner, AuditService audit,
        ILogger<WipeActionConsumerFunction> log)
    {
        _runner = runner;
        _audit = audit;
        _log = log;
    }

    [Function("WipeAction")]
    public async Task Run(
        [ServiceBusTrigger("%ServiceBus:WipeActionQueue%", Connection = "ServiceBus")] string messageJson,
        CancellationToken ct)
    {
        ActionDispatchMessage env;
        try
        {
            env = JsonSerializer.Deserialize<ActionDispatchMessage>(messageJson, ActionDispatchEnqueuer.JsonOptions)
                  ?? throw new InvalidOperationException("Empty wipe-action envelope.");
        }
        catch (Exception ex)
        {
            _audit.TrackEvent(AuditEvents.WipeActionInvalidEnvelope, ex, new Dictionary<string, string>
            {
                ["payloadLength"] = (messageJson?.Length ?? 0).ToString(),
            });
            // Invalid envelopes are NEVER retryable — let them poison-out fast.
            return;
        }

        using var scope = _log.BeginScope(new Dictionary<string, object>
        {
            ["CorrelationId"] = env.CorrelationId,
            ["ActionType"]    = env.ActionType,
            ["DeviceName"]    = env.DeviceName,
        });

        _audit.TrackEvent(AuditEvents.WipeActionConsumed, new Dictionary<string, string>
        {
            [AuditEvents.Prop.CorrelationId]  = env.CorrelationId,
            [AuditEvents.Prop.ActionType]     = env.ActionType,
            [AuditEvents.Prop.DeviceName]     = env.DeviceName,
            [AuditEvents.Prop.SchemaVersion]  = env.SchemaVersion,
        });

        var sw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            await _runner.RunAsync(env, ct);
            sw.Stop();
            _audit.TrackEvent(AuditEvents.WipeActionCompleted, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId] = env.CorrelationId,
                ["durationMs"]                   = sw.ElapsedMilliseconds.ToString(),
            });
        }
        catch (Exception ex)
        {
            sw.Stop();
            _audit.TrackEvent(AuditEvents.WipeActionRunnerFailed, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]    = env.CorrelationId,
                [AuditEvents.Prop.ExceptionType]    = ex.GetType().FullName ?? "(unknown)",
                [AuditEvents.Prop.ExceptionMessage] = ex.Message ?? string.Empty,
                ["failOnError"]                     = env.FailOnError.ToString(),
                ["durationMs"]                      = sw.ElapsedMilliseconds.ToString(),
            }, env.FailOnError ? LogLevel.Error : LogLevel.Warning);

            if (env.FailOnError) throw;
        }
    }
}
