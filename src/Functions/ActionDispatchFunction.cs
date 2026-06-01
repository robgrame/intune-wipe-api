using System.Text.Json;
using IntuneWipeApi.Actions;
using IntuneWipeApi.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Functions;

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
        [QueueTrigger("%Actions:DispatchQueueName%", Connection = "AzureWebJobsStorage")] string messageJson,
        CancellationToken ct)
    {
        // App-role guard: this runs ONLY on the worker app (same as WipeProcessor).
        if (!AppRoleGuard.IsAllowed(AppRoleGuard.Proc))
        {
            _audit.TrackEvent(AuditEvents.DeniedAppRoleMismatch, new Dictionary<string, string>
            {
                [AuditEvents.Prop.ExpectedRole] = AppRoleGuard.Proc,
                [AuditEvents.Prop.ActualRole]   = AppRoleGuard.CurrentRole ?? "",
                ["function"]                    = "ActionDispatch",
            }, LogLevel.Error);
            throw new InvalidOperationException(
                $"App role mismatch: this Function App is not the worker (App__Role='{AppRoleGuard.CurrentRole}')");
        }

        ActionDispatchMessage env;
        try
        {
            env = JsonSerializer.Deserialize<ActionDispatchMessage>(messageJson, ActionDispatchEnqueuer.JsonOptions)
                  ?? throw new InvalidOperationException("Empty dispatch envelope.");
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
            await runner.RunAsync(env, ct);
            sw.Stop();
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
