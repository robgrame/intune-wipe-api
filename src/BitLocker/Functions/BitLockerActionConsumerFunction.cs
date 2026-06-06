using System.Text.Json;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Capabilities.BitLocker.Audit;
using IntuneDeviceActions.Capabilities.BitLocker.Runners;
using IntuneDeviceActions.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Functions;

/// <summary>
/// Dedicated per-capability consumer for the <c>bitlocker-action</c> Service Bus
/// queue. Runs ONLY on the bitlocker-runner Function App (artifact isolation —
/// this Function class is deployed only to the BitLocker assembly), which holds
/// the privileged Graph identity for <c>rotateBitLockerKeys</c>. The Proc app's
/// <see cref="BitLockerForwardingRunner"/> is the only producer.
/// </summary>
/// <remarks>
/// Functionally equivalent to <c>WipeActionConsumerFunction</c>, bound to a
/// per-capability queue and app role, reusing the same
/// <see cref="ActionDispatchMessage"/> envelope.
/// </remarks>
public sealed class BitLockerActionConsumerFunction
{
    private readonly BitLockerRotateRunner _runner;
    private readonly AuditService _audit;
    private readonly ILogger<BitLockerActionConsumerFunction> _log;

    public BitLockerActionConsumerFunction(BitLockerRotateRunner runner, AuditService audit,
        ILogger<BitLockerActionConsumerFunction> log)
    {
        _runner = runner;
        _audit = audit;
        _log = log;
    }

    [Function("BitLockerAction")]
    public async Task Run(
        [ServiceBusTrigger("%ServiceBus:BitLockerActionQueue%", Connection = "ServiceBus")] string messageJson,
        CancellationToken ct)
    {
        ActionDispatchMessage env;
        try
        {
            env = JsonSerializer.Deserialize<ActionDispatchMessage>(messageJson, ActionDispatchEnqueuer.JsonOptions)
                  ?? throw new InvalidOperationException("Empty bitlocker-action envelope.");
        }
        catch (Exception ex)
        {
            _audit.TrackEvent(BitLockerAuditEvents.ActionInvalidEnvelope, ex, new Dictionary<string, string>
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

        _audit.TrackEvent(BitLockerAuditEvents.ActionConsumed, new Dictionary<string, string>
        {
            [AuditEvents.Prop.CorrelationId] = env.CorrelationId,
            [AuditEvents.Prop.ActionType]    = env.ActionType,
            [AuditEvents.Prop.DeviceName]    = env.DeviceName,
            [AuditEvents.Prop.SchemaVersion] = env.SchemaVersion,
        });

        var sw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            await _runner.RunAsync(env, ct);
            sw.Stop();
            _audit.TrackEvent(BitLockerAuditEvents.ActionCompleted, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId] = env.CorrelationId,
                ["durationMs"]                   = sw.ElapsedMilliseconds.ToString(),
            });
        }
        catch (Exception ex)
        {
            sw.Stop();
            _audit.TrackEvent(BitLockerAuditEvents.ActionRunnerFailed, ex, new Dictionary<string, string>
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
