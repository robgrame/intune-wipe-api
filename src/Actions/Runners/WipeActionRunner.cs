using System.Text.Json;
using IntuneWipeApi.Models;
using IntuneWipeApi.Services;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Actions.Runners;

/// <summary>
/// <see cref="IActionRunner"/> for the <c>wipe</c> action — the original
/// business logic that previously lived inline inside
/// <c>WipeProcessorFunction</c>. Moving it here behind the
/// <see cref="IActionRunner"/> contract turns it into one plug-in among
/// many that the router can dispatch to.
/// </summary>
/// <remarks>
/// Steps:
/// <list type="number">
///   <item>resolve Entra directory object id;</item>
///   <item>check membership of the allowed Entra group;</item>
///   <item>validate Intune↔Entra mapping (ownership);</item>
///   <item>reserve an idempotency ledger entry — skip if a wipe was already issued;</item>
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
    private readonly IdempotencyService _ledger;
    private readonly AuditService _audit;
    private readonly WipeStatusTracker _statusTracker;
    private readonly ILogger<WipeActionRunner> _log;

    public WipeActionRunner(GraphWipeService graph, IdempotencyService ledger,
        AuditService audit, WipeStatusTracker statusTracker, ILogger<WipeActionRunner> log)
    {
        _graph = graph;
        _ledger = ledger;
        _audit = audit;
        _statusTracker = statusTracker;
        _log = log;
    }

    public async Task RunAsync(ActionDispatchMessage envelope, CancellationToken ct)
    {
        var msg = envelope.Payload.Deserialize<WipeQueueMessage>()
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
            return;
        }

        // 4) Idempotency reservation
        var (state, entry) = await _ledger.ReserveAsync(msg.IntuneDeviceId, msg.CorrelationId, ct);
        if (state == IdempotencyService.State.Issued)
        {
            _audit.TrackEvent(AuditEvents.WipeAlreadyIssued, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]         = msg.CorrelationId,
                [AuditEvents.Prop.OriginalCorrelationId] = entry.CorrelationId,
                [AuditEvents.Prop.DeviceName]            = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId]        = msg.IntuneDeviceId,
            });
            return;
        }
        if (state == IdempotencyService.State.Reserved && entry.CorrelationId != msg.CorrelationId)
        {
            _audit.TrackEvent(AuditEvents.WipeInProgressElsewhere, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]         = msg.CorrelationId,
                [AuditEvents.Prop.OriginalCorrelationId] = entry.CorrelationId,
                [AuditEvents.Prop.DeviceName]            = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId]        = msg.IntuneDeviceId,
            }, LogLevel.Warning);
            return;
        }

        // 5) Execute wipe
        bool wipeSucceeded = false;
        try
        {
            await _graph.WipeAsync(managedId, ct);
            await _ledger.MarkIssuedAsync(msg.IntuneDeviceId, msg.CorrelationId, ct);
            _audit.TrackEvent(AuditEvents.WipeIssued, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]      = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]         = msg.DeviceName,
                [AuditEvents.Prop.EntraDeviceId]      = msg.EntraDeviceId,
                [AuditEvents.Prop.IntuneDeviceId]     = msg.IntuneDeviceId,
                [AuditEvents.Prop.ManagedDeviceId]    = managedId,
                [AuditEvents.Prop.KeepEnrollmentData] = _graph.KeepEnrollmentData.ToString(),
                [AuditEvents.Prop.KeepUserData]       = _graph.KeepUserData.ToString(),
            });
            wipeSucceeded = true;

            try { await _statusTracker.InitializeAsync(msg, managedId, ct); }
            catch (Exception ex) { _log.LogWarning(ex, "Status tracker initialization failed for {Corr}", msg.CorrelationId); }
        }
        catch (Exception ex) when (GraphWipeService.Classify(ex) == GraphWipeService.GraphErrorKind.Permanent)
        {
            await _ledger.MarkFailedAsync(msg.IntuneDeviceId, msg.CorrelationId, ex.Message, ct);
            _audit.TrackEvent(AuditEvents.WipeFailedPermanent, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]   = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]      = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId]  = msg.IntuneDeviceId,
                [AuditEvents.Prop.ManagedDeviceId] = managedId,
            });
            // Do not throw — no retry on permanent errors.
        }
        catch (Exception ex)
        {
            _audit.TrackEvent(AuditEvents.WipeTransientError, ex, new Dictionary<string, string>
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

    private async Task TryNudgeAfterWipeAsync(WipeQueueMessage msg, string managedId, CancellationToken ct)
    {
        var syncDelay   = _graph.SyncFallbackDelaySeconds;
        var rebootDelay = _graph.RebootFallbackDelaySeconds;

        if (syncDelay > 0)
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(syncDelay), ct);
                await _graph.SyncDeviceAsync(managedId, ct);
                _audit.TrackEvent(AuditEvents.SyncFallbackIssued, new Dictionary<string, string>
                {
                    [AuditEvents.Prop.CorrelationId]   = msg.CorrelationId,
                    [AuditEvents.Prop.DeviceName]      = msg.DeviceName,
                    [AuditEvents.Prop.ManagedDeviceId] = managedId,
                    ["delaySeconds"]                   = syncDelay.ToString(),
                });
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                _audit.TrackEvent(AuditEvents.SyncFallbackFailed, ex, BuildGraphErrProps(msg, managedId, ex), LogLevel.Warning);
            }
        }

        if (rebootDelay > 0)
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(rebootDelay), ct);
                await _graph.RebootAsync(managedId, ct);
                _audit.TrackEvent(AuditEvents.RebootFallbackIssued, new Dictionary<string, string>
                {
                    [AuditEvents.Prop.CorrelationId]   = msg.CorrelationId,
                    [AuditEvents.Prop.DeviceName]      = msg.DeviceName,
                    [AuditEvents.Prop.ManagedDeviceId] = managedId,
                    ["delaySeconds"]                   = rebootDelay.ToString(),
                });
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                _audit.TrackEvent(AuditEvents.RebootFallbackFailed, ex, BuildGraphErrProps(msg, managedId, ex), LogLevel.Warning);
            }
        }
    }

    private static Dictionary<string, string> BuildGraphErrProps(WipeQueueMessage msg, string managedId, Exception ex)
    {
        var props = new Dictionary<string, string>
        {
            [AuditEvents.Prop.CorrelationId]    = msg.CorrelationId,
            [AuditEvents.Prop.DeviceName]       = msg.DeviceName,
            [AuditEvents.Prop.ManagedDeviceId]  = managedId,
            [AuditEvents.Prop.ExceptionType]    = ex.GetType().FullName ?? "(unknown)",
            [AuditEvents.Prop.ExceptionMessage] = ex.Message ?? string.Empty,
        };
        if (ex is Microsoft.Graph.Models.ODataErrors.ODataError oe)
        {
            props["graphStatusCode"] = oe.ResponseStatusCode.ToString();
            props["graphErrorCode"]  = oe.Error?.Code ?? string.Empty;
            props["graphErrorMsg"]   = oe.Error?.Message ?? string.Empty;
        }
        return props;
    }
}
