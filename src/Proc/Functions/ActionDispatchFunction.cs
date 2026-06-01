using System.Text.Json;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Functions;

/// <summary>
/// Generic plug-in router. Consumes the <c>action-dispatch</c> storage queue,
/// resolves the matching <see cref="IActionRunner"/> via the
/// <see cref="ActionRunnerRegistry"/> and runs it.
/// </summary>
/// <remarks>
/// <para>
/// This is the only function that needs to know the contract for an action.
/// Adding a new capability never modifies this file — only DI registration
/// (<c>services.AddSingleton&lt;IActionRunner, MyRunner&gt;()</c>) and the
/// runner class itself.
/// </para>
/// <para>
/// Retry policy is driven by <see cref="ActionDispatchMessage.FailOnError"/>:
/// when <c>true</c>, exceptions bubble so the storage queue retries via
/// visibility timeout (poison queue after the host-configured max attempts).
/// </para>
/// </remarks>
public sealed class ActionDispatchFunction
{
    private readonly ActionRunnerRegistry _registry;
    private readonly AuditService _audit;
    private readonly ILogger<ActionDispatchFunction> _log;

    public ActionDispatchFunction(ActionRunnerRegistry registry, AuditService audit, ILogger<ActionDispatchFunction> log)
    {
        _registry = registry;
        _audit = audit;
        _log = log;
    }

    [Function("ActionDispatch")]
    public async Task Run(
        [ServiceBusTrigger("%ServiceBus:ActionDispatchQueue%", Connection = "ServiceBus")] string messageJson,
        CancellationToken ct)
    {
        ActionDispatchMessage env;
        try
        {
            _log.LogDebug("ActionDispatch raw message received: length={Length}", messageJson?.Length ?? 0);
            env = JsonSerializer.Deserialize<ActionDispatchMessage>(messageJson ?? "{}", ActionDispatchEnqueuer.JsonOptions)
                  ?? throw new InvalidOperationException("Empty dispatch envelope.");
            _log.LogDebug("ActionDispatch envelope parsed: corr={Corr} actionType={ActionType} schema={Schema} device={Device}",
                env.CorrelationId, env.ActionType, env.SchemaVersion, env.DeviceName);
        }
        catch (Exception ex)
        {
            _audit.TrackEvent(AuditEvents.ActionDispatchInvalidEnvelope, ex, new Dictionary<string, string>
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

        _audit.TrackEvent(AuditEvents.ActionDispatchReceived, new Dictionary<string, string>
        {
            [AuditEvents.Prop.CorrelationId]  = env.CorrelationId,
            [AuditEvents.Prop.ActionType]     = env.ActionType,
            [AuditEvents.Prop.DeviceName]     = env.DeviceName,
            [AuditEvents.Prop.SchemaVersion]  = env.SchemaVersion,
        });

        var runner = _registry.Resolve(env.ActionType);
        _log.LogDebug("ActionDispatch runner resolution: type={ActionType} runner={Runner} knownTypes=[{Known}]",
            env.ActionType, runner?.GetType().Name ?? "(none)", string.Join(",", _registry.KnownTypes));
        if (runner is null)
        {
            _audit.TrackEvent(AuditEvents.ActionDispatchNoRunner, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId] = env.CorrelationId,
                [AuditEvents.Prop.ActionType]    = env.ActionType,
                ["knownTypes"]                   = string.Join(",", _registry.KnownTypes),
            }, LogLevel.Error);
            // Unknown action type: nothing to retry → swallow so it doesn't loop.
            return;
        }

        var sw = System.Diagnostics.Stopwatch.StartNew();
        try
        {
            _log.LogDebug("ActionDispatch invoking runner {Runner} for corr={Corr}", runner.GetType().Name, env.CorrelationId);
            await runner.RunAsync(env, ct);
            sw.Stop();
            _log.LogDebug("ActionDispatch runner {Runner} completed in {Ms} ms corr={Corr}",
                runner.GetType().Name, sw.ElapsedMilliseconds, env.CorrelationId);
            _audit.TrackEvent(AuditEvents.ActionDispatchCompleted, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId] = env.CorrelationId,
                [AuditEvents.Prop.ActionType]    = env.ActionType,
                ["durationMs"]                   = sw.ElapsedMilliseconds.ToString(),
            });
        }
        catch (Exception ex)
        {
            sw.Stop();
            _audit.TrackEvent(AuditEvents.ActionDispatchRunnerFailed, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]    = env.CorrelationId,
                [AuditEvents.Prop.ActionType]       = env.ActionType,
                [AuditEvents.Prop.ExceptionType]    = ex.GetType().FullName ?? "(unknown)",
                [AuditEvents.Prop.ExceptionMessage] = ex.Message ?? string.Empty,
                ["failOnError"]                     = env.FailOnError.ToString(),
                ["durationMs"]                      = sw.ElapsedMilliseconds.ToString(),
            }, env.FailOnError ? LogLevel.Error : LogLevel.Warning);

            if (env.FailOnError)
            {
                throw; // queue retries via visibility timeout → poison queue after max attempts
            }
            // else: best-effort runner; swallow so we don't poison the queue
        }
    }
}
