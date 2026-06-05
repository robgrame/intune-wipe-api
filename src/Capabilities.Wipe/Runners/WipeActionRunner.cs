using System.Text.Json;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Capabilities.Wipe.Audit;
using IntuneDeviceActions.Capabilities.Wipe.Services;
using IntuneDeviceActions.Models;
using IntuneDeviceActions.Services;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Capabilities.Wipe.Runners;

/// <summary>
/// <see cref="IActionRunner"/> for the <c>wipe</c> action — the privileged
/// executor that actually calls Graph and issues the wipe + post-wipe nudges.
/// </summary>
/// <remarks>
/// Steps:
/// <list type="number">
///   <item>resolve Entra directory object id;</item>
///   <item>check membership of the allowed Entra group;</item>
///   <item>validate Intune↔Entra mapping (ownership);</item>
///   <item>reserve an idempotency ledger entry — skip if an action was already issued;</item>
///   <item>call Graph wipe; mark ledger Issued/Failed accordingly;</item>
///   <item>open the status-tracker row and best-effort sync/reboot nudges.</item>
/// </list>
/// Permanent errors swallow (no queue retry); transient errors throw
/// (the router honours <see cref="ActionDispatchMessage.FailOnError"/>).
/// </remarks>
public sealed class WipeActionRunner : IActionRunner
{
    public string Type => "wipe";

    private readonly GraphWipeService _graph;
    private readonly ActionIdempotencyService _ledger;
    private readonly AuditService _audit;
    private readonly ActionStatusTracker _statusTracker;
    private readonly ILogger<WipeActionRunner> _log;

    public WipeActionRunner(GraphWipeService graph, ActionIdempotencyService ledger,
        AuditService audit, ActionStatusTracker statusTracker, ILogger<WipeActionRunner> log)
    {
        _graph = graph;
        _ledger = ledger;
        _audit = audit;
        _statusTracker = statusTracker;
        _log = log;
    }

    public async Task RunAsync(ActionDispatchMessage envelope, CancellationToken ct)
    {
        var msg = envelope.Payload.Deserialize<ActionRequestMessage>()
            ?? throw new InvalidOperationException("Wipe payload missing/invalid in dispatch envelope.");

        // Defensive fill-in if the producer didn't repeat fields at envelope level.
        if (string.IsNullOrEmpty(msg.CorrelationId)) msg.CorrelationId = envelope.CorrelationId;
        if (string.IsNullOrEmpty(msg.DeviceName))    msg.DeviceName    = envelope.DeviceName;
        if (string.IsNullOrEmpty(msg.EntraDeviceId)) msg.EntraDeviceId = envelope.EntraDeviceId;
        if (string.IsNullOrEmpty(msg.IntuneDeviceId))msg.IntuneDeviceId= envelope.IntuneDeviceId;

        using var scope = _log.BeginScope(new Dictionary<string, object>
        {
            ["CorrelationId"]  = msg.CorrelationId,
            ["DeviceName"]     = msg.DeviceName,
            ["EntraDeviceId"]  = msg.EntraDeviceId,
            ["IntuneDeviceId"] = msg.IntuneDeviceId,
            ["ActionType"]     = Type,
        });

        _log.LogInformation("Running wipe action for {Device}", msg.DeviceName);

        // 1) Resolve Entra directory object id
        string? deviceObjId;
        try
        {
            deviceObjId = await _graph.GetDeviceObjectIdAsync(msg.EntraDeviceId, ct);
        }
        catch (Exception ex) when (GraphWipeService.Classify(ex) == GraphWipeService.GraphErrorKind.Transient)
        {
            _log.LogWarning(ex, "Transient error resolving device — will retry");
            throw;
        }
        catch (Exception ex)
        {
            _audit.TrackEvent(AuditEvents.DeniedDeviceResolveFailed, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId] = msg.CorrelationId,
                [AuditEvents.Prop.EntraDeviceId] = msg.EntraDeviceId,
                [AuditEvents.Prop.DeviceName]    = msg.DeviceName,
            });
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:device-resolve-failed", ct);
            return;
        }

        if (deviceObjId is null)
        {
            _audit.TrackEvent(AuditEvents.DeniedDeviceNotInEntra, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId] = msg.CorrelationId,
                [AuditEvents.Prop.EntraDeviceId] = msg.EntraDeviceId,
                [AuditEvents.Prop.DeviceName]    = msg.DeviceName,
            }, LogLevel.Warning);
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:device-not-in-entra", ct);
            return;
        }

        // 2) Group membership check
        bool inGroup;
        try
        {
            inGroup = await _graph.IsDeviceInAllowedGroupAsync(deviceObjId, ct);
        }
        catch (Exception ex) when (GraphWipeService.Classify(ex) == GraphWipeService.GraphErrorKind.Transient)
        {
            _log.LogWarning(ex, "Transient error on group check — will retry");
            throw;
        }
        catch (Exception ex)
        {
            _audit.TrackEvent(AuditEvents.DeniedGroupCheckFailed, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId] = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]    = msg.DeviceName,
            });
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:group-check-failed", ct);
            return;
        }

        if (!inGroup)
        {
            _audit.TrackEvent(AuditEvents.DeniedNotInAllowedGroup, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId] = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]    = msg.DeviceName,
                [AuditEvents.Prop.EntraDeviceId] = msg.EntraDeviceId,
            }, LogLevel.Warning);
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:not-in-allowed-group", ct);
            return;
        }

        // 3) Ownership: resolve managedDevice via Graph filter by azureADDeviceId (server-authoritative)
        string? managedId;
        try
        {
            managedId = await _graph.ResolveAndValidateAsync(msg.EntraDeviceId, ct);
        }
        catch (Exception ex) when (GraphWipeService.Classify(ex) == GraphWipeService.GraphErrorKind.Transient)
        {
            _log.LogWarning(ex, "Transient error on managed-device resolve — will retry");
            throw;
        }
        catch (Exception ex)
        {
            var props = new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
                [AuditEvents.Prop.EntraDeviceId]  = msg.EntraDeviceId,
                [AuditEvents.Prop.DeviceName]     = msg.DeviceName,
                ["exceptionType"]                 = ex.GetType().FullName ?? "(unknown)",
                ["exceptionMessage"]              = ex.Message ?? string.Empty,
            };
            if (ex is Microsoft.Graph.Models.ODataErrors.ODataError oe)
            {
                props["graphStatusCode"] = oe.ResponseStatusCode.ToString();
                props["graphErrorCode"]  = oe.Error?.Code ?? string.Empty;
                props["graphErrorMsg"]   = oe.Error?.Message ?? string.Empty;
            }
            _audit.TrackEvent(AuditEvents.DeniedManagedDeviceResolveFailed, ex, props);
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:managed-device-resolve-failed", ct);
            return;
        }

        if (managedId is null)
        {
            _audit.TrackEvent(AuditEvents.DeniedOwnershipMismatch, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]     = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
                [AuditEvents.Prop.EntraDeviceId]  = msg.EntraDeviceId,
            }, LogLevel.Warning);
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:ownership-mismatch", ct);
            return;
        }

        // 4) Idempotency reservation (with auto-rearm + rate limiting)
        var reserve = await _ledger.ReserveAsync(msg.IntuneDeviceId, msg.CorrelationId, msg.ForceRearm, ct);
        var state = reserve.State;
        var entry = reserve.Entry;

        // Rate limiter trip: too many actions for this device in the rolling 24h window.
        if (state == ActionIdempotencyService.State.RateLimited)
        {
            _audit.TrackEvent(AuditEvents.DeniedRateLimited, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]               = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]                  = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId]              = msg.IntuneDeviceId,
                [AuditEvents.Prop.RecentActionsInWindow]       = reserve.RecentActionsInWindow.ToString(),
                [AuditEvents.Prop.MaxActionsPerDevicePerDay]   = reserve.MaxActionsPerDevicePerDay.ToString(),
            }, LogLevel.Warning);
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:rate-limited", ct, managedId);
            return;
        }

        // Auto-rearm happened: a previous action had reached terminal state
        // (success / failure / timed-out past grace). Emit a dedicated audit
        // so operators can see *why* the ledger was reset implicitly.
        if (reserve.Rearmed != ActionIdempotencyService.RearmReason.None)
        {
            var rearmEvent = reserve.Rearmed switch
            {
                ActionIdempotencyService.RearmReason.AfterSuccess     => AuditEvents.LedgerRearmedAfterSuccess,
                ActionIdempotencyService.RearmReason.AfterFailure     => AuditEvents.LedgerRearmedAfterFailure,
                ActionIdempotencyService.RearmReason.AfterPollTimeout => AuditEvents.LedgerRearmedAfterTimeout,
                ActionIdempotencyService.RearmReason.Forced           => AuditEvents.LedgerRearmedForced,
                _                                                     => AuditEvents.LedgerRearmedAfterSuccess,
            };
            var props = new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]          = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]             = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId]         = msg.IntuneDeviceId,
                [AuditEvents.Prop.ActionSequence]         = entry.ActionSequence.ToString(),
                [AuditEvents.Prop.PreviousTerminalState]  = entry.LastTerminalState ?? "(unknown)",
                [AuditEvents.Prop.RearmReason]            = reserve.Rearmed.ToString(),
            };
            if (reserve.AgeSinceTerminalHours.HasValue)
                props[AuditEvents.Prop.AgeSinceTerminalHours] = reserve.AgeSinceTerminalHours.Value.ToString("F2");
            if (reserve.Rearmed == ActionIdempotencyService.RearmReason.Forced)
                props[AuditEvents.Prop.ForceRearm] = "true";
            _audit.TrackEvent(rearmEvent, props);
        }

        if (state == ActionIdempotencyService.State.Issued)
        {
            _audit.TrackEvent(AuditEvents.ActionAlreadyIssued, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]         = msg.CorrelationId,
                [AuditEvents.Prop.OriginalCorrelationId] = entry.CorrelationId,
                [AuditEvents.Prop.DeviceName]            = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId]        = msg.IntuneDeviceId,
                [AuditEvents.Prop.ActionSequence]        = entry.ActionSequence.ToString(),
            });
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:already-issued", ct, managedId);
            return;
        }
        if (state == ActionIdempotencyService.State.Reserved && entry.CorrelationId != msg.CorrelationId)
        {
            _audit.TrackEvent(AuditEvents.ActionInProgressElsewhere, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]         = msg.CorrelationId,
                [AuditEvents.Prop.OriginalCorrelationId] = entry.CorrelationId,
                [AuditEvents.Prop.DeviceName]            = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId]        = msg.IntuneDeviceId,
            }, LogLevel.Warning);
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:in-progress-elsewhere", ct, managedId);
            return;
        }

        // 5) Execute wipe
        bool wipeSucceeded = false;
        try
        {
            await _graph.WipeAsync(managedId, ct);
            await _ledger.MarkIssuedAsync(msg.IntuneDeviceId, msg.CorrelationId, ct);
            _audit.TrackEvent(WipeAuditEvents.WipeIssued, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]               = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]                  = msg.DeviceName,
                [AuditEvents.Prop.EntraDeviceId]               = msg.EntraDeviceId,
                [AuditEvents.Prop.IntuneDeviceId]              = msg.IntuneDeviceId,
                [AuditEvents.Prop.ManagedDeviceId]             = managedId,
                [WipeAuditEvents.Prop.KeepEnrollmentData]      = _graph.KeepEnrollmentData.ToString(),
                [WipeAuditEvents.Prop.KeepUserData]            = _graph.KeepUserData.ToString(),
            });
            wipeSucceeded = true;

            try { await _statusTracker.InitializeAsync(msg, Type, managedId, ct); }
            catch (Exception ex) { _log.LogWarning(ex, "Status tracker initialization failed for {Corr}", msg.CorrelationId); }
        }
        catch (Exception ex) when (GraphWipeService.Classify(ex) == GraphWipeService.GraphErrorKind.Permanent)
        {
            await _ledger.MarkFailedAsync(msg.IntuneDeviceId, msg.CorrelationId, ex.Message, ct);
            _audit.TrackEvent(WipeAuditEvents.WipeFailedPermanent, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]   = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]      = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId]  = msg.IntuneDeviceId,
                [AuditEvents.Prop.ManagedDeviceId] = managedId,
            });
            await _statusTracker.RecordTerminalAsync(msg, Type, "failed:permanent", ct, managedId);
            // Do not throw — no retry on permanent errors.
        }
        catch (Exception ex)
        {
            _audit.TrackEvent(WipeAuditEvents.WipeTransientError, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]   = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]      = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId]  = msg.IntuneDeviceId,
                [AuditEvents.Prop.ManagedDeviceId] = managedId,
            }, LogLevel.Warning);
            throw;
        }

        // 6) Post-wipe nudges (best-effort, never reverse a successful wipe).
        if (wipeSucceeded)
        {
            await TryNudgeAfterWipeAsync(msg, managedId, ct);
        }
    }

    private async Task TryNudgeAfterWipeAsync(ActionRequestMessage msg, string managedId, CancellationToken ct)
    {
        var syncDelay   = _graph.SyncFallbackDelaySeconds;
        var rebootDelay = _graph.RebootFallbackDelaySeconds;

        if (syncDelay > 0)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(syncDelay), ct); }
            catch (OperationCanceledException) { throw; }
            await RunNudgeWithRetryAsync(
                action:           ct2 => _graph.SyncDeviceAsync(managedId, ct2),
                maxAttempts:      _graph.SyncFallbackMaxAttempts,
                issuedEvent:      WipeAuditEvents.SyncFallbackIssued,
                retryingEvent:    WipeAuditEvents.SyncFallbackRetrying,
                failedEvent:      WipeAuditEvents.SyncFallbackFailed,
                exhaustedEvent:   WipeAuditEvents.SyncFallbackExhausted,
                extraIssuedProps: new() { ["delaySeconds"] = syncDelay.ToString() },
                msg:              msg,
                managedId:        managedId,
                ct:               ct);
        }

        if (rebootDelay > 0)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(rebootDelay), ct); }
            catch (OperationCanceledException) { throw; }
            await RunNudgeWithRetryAsync(
                action:           ct2 => _graph.RebootAsync(managedId, ct2),
                maxAttempts:      _graph.RebootFallbackMaxAttempts,
                issuedEvent:      WipeAuditEvents.RebootFallbackIssued,
                retryingEvent:    WipeAuditEvents.RebootFallbackRetrying,
                failedEvent:      WipeAuditEvents.RebootFallbackFailed,
                exhaustedEvent:   WipeAuditEvents.RebootFallbackExhausted,
                extraIssuedProps: new() { ["delaySeconds"] = rebootDelay.ToString() },
                msg:              msg,
                managedId:        managedId,
                ct:               ct);
        }
    }

    /// <summary>
    /// Runs a post-wipe nudge (syncDevice or rebootNow) with bounded retries on
    /// transient Graph errors. Never throws (the wipe itself already succeeded);
    /// failures end up as audit events that operators can alert on.
    /// </summary>
    /// <remarks>
    /// Backoff sequence (ms): 1000, 3000, 10000, 30000, 60000 — capped at
    /// <paramref name="maxAttempts"/> entries. Total worst-case latency for
    /// the default 3 attempts is ~14s.
    /// </remarks>
    private async Task RunNudgeWithRetryAsync(
        Func<CancellationToken, Task> action,
        int maxAttempts,
        string issuedEvent,
        string retryingEvent,
        string failedEvent,
        string exhaustedEvent,
        Dictionary<string, string> extraIssuedProps,
        ActionRequestMessage msg,
        string managedId,
        CancellationToken ct)
    {
        // Fixed backoff schedule. Keep it short — the runner is on a Service Bus
        // lock and we have *two* nudges back-to-back. Total upper bound at
        // maxAttempts=5 is ~104s, well within the 10-minute auto-renew window.
        int[] backoffMs = { 1000, 3000, 10000, 30000, 60000 };

        Exception? lastException = null;
        for (int attempt = 1; attempt <= maxAttempts; attempt++)
        {
            try
            {
                await action(ct);
                var props = new Dictionary<string, string>(extraIssuedProps)
                {
                    [AuditEvents.Prop.CorrelationId]   = msg.CorrelationId,
                    [AuditEvents.Prop.DeviceName]      = msg.DeviceName,
                    [AuditEvents.Prop.ManagedDeviceId] = managedId,
                    [AuditEvents.Prop.AttemptNumber]   = attempt.ToString(),
                    [AuditEvents.Prop.MaxAttempts]     = maxAttempts.ToString(),
                };
                _audit.TrackEvent(issuedEvent, props);
                return;
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                lastException = ex;
                var kind = GraphWipeService.Classify(ex);

                // Permanent errors (4xx other than 408/429): don't waste retries.
                // E.g., 404 here is expected when the device is already gone from
                // Intune because the wipe is being applied.
                if (kind == GraphWipeService.GraphErrorKind.Permanent)
                {
                    _audit.TrackEvent(failedEvent, ex,
                        BuildNudgeErrProps(msg, managedId, ex, attempt, maxAttempts),
                        LogLevel.Warning);
                    return;
                }

                // Transient. If we have budget left, sleep and try again.
                if (attempt < maxAttempts)
                {
                    var sleep = backoffMs[Math.Min(attempt - 1, backoffMs.Length - 1)];
                    var props = BuildNudgeErrProps(msg, managedId, ex, attempt, maxAttempts);
                    props[AuditEvents.Prop.BackoffMs] = sleep.ToString();
                    _audit.TrackEvent(retryingEvent, ex, props, LogLevel.Information);
                    try { await Task.Delay(sleep, ct); }
                    catch (OperationCanceledException) { throw; }
                    continue;
                }
            }
        }

        // Exhausted: all attempts threw transient errors.
        var exhaustedProps = BuildNudgeErrProps(msg, managedId, lastException, maxAttempts, maxAttempts);
        if (lastException is not null)
        {
            _audit.TrackEvent(exhaustedEvent, lastException, exhaustedProps, LogLevel.Warning);
        }
        else
        {
            _audit.TrackEvent(exhaustedEvent, exhaustedProps, LogLevel.Warning);
        }
    }

    private static Dictionary<string, string> BuildNudgeErrProps(
        ActionRequestMessage msg, string managedId, Exception? ex,
        int attempt, int maxAttempts)
    {
        var props = new Dictionary<string, string>
        {
            [AuditEvents.Prop.CorrelationId]   = msg.CorrelationId,
            [AuditEvents.Prop.DeviceName]      = msg.DeviceName,
            [AuditEvents.Prop.ManagedDeviceId] = managedId,
            [AuditEvents.Prop.AttemptNumber]   = attempt.ToString(),
            [AuditEvents.Prop.MaxAttempts]     = maxAttempts.ToString(),
        };
        if (ex is not null)
        {
            props[AuditEvents.Prop.ExceptionType]    = ex.GetType().FullName ?? "(unknown)";
            props[AuditEvents.Prop.ExceptionMessage] = ex.Message ?? string.Empty;
            if (ex is Microsoft.Graph.Models.ODataErrors.ODataError oe)
            {
                props["graphStatusCode"] = oe.ResponseStatusCode.ToString();
                props["graphErrorCode"]  = oe.Error?.Code ?? string.Empty;
                props["graphErrorMsg"]   = oe.Error?.Message ?? string.Empty;
            }
        }
        return props;
    }
}
