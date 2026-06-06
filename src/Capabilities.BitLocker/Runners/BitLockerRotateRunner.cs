using System.Text.Json;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Capabilities.BitLocker.Audit;
using IntuneDeviceActions.Capabilities.BitLocker.Services;
using IntuneDeviceActions.Models;
using IntuneDeviceActions.Services;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Capabilities.BitLocker.Runners;

/// <summary>
/// <see cref="IActionRunner"/> for the <c>bitlocker-rotate</c> action — the
/// privileged executor that calls Graph <c>rotateBitLockerKeys</c> for the
/// target managed device and escrows a fresh recovery key to Entra ID.
/// </summary>
/// <remarks>
/// Same fail-closed pre-issue safety pipeline as the wipe capability, minus the
/// destructive payload and the post-wipe nudges:
/// <list type="number">
///   <item>resolve Entra directory object id;</item>
///   <item>check membership of the allowed Entra group (<c>BitLocker:AllowedGroupId</c>);</item>
///   <item>validate Intune↔Entra mapping (ownership);</item>
///   <item>reserve an idempotency ledger entry — skip if already issued / rate-limited;</item>
///   <item>call Graph rotateBitLockerKeys; mark ledger Issued/Failed accordingly;</item>
///   <item>open the status-tracker row so <c>GET /api/actions/status</c> works.</item>
/// </list>
/// Permanent errors swallow (no queue retry); transient errors throw (the
/// per-capability consumer honours <see cref="ActionDispatchMessage.FailOnError"/>).
/// </remarks>
public sealed class BitLockerRotateRunner : IActionRunner
{
    public string Type => "bitlocker-rotate";

    private readonly GraphBitLockerService _graph;
    private readonly ActionIdempotencyService _ledger;
    private readonly AuditService _audit;
    private readonly ActionStatusTracker _statusTracker;
    private readonly ILogger<BitLockerRotateRunner> _log;

    public BitLockerRotateRunner(GraphBitLockerService graph, ActionIdempotencyService ledger,
        AuditService audit, ActionStatusTracker statusTracker, ILogger<BitLockerRotateRunner> log)
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
            ?? throw new InvalidOperationException("BitLocker payload missing/invalid in dispatch envelope.");

        if (string.IsNullOrEmpty(msg.CorrelationId))  msg.CorrelationId  = envelope.CorrelationId;
        if (string.IsNullOrEmpty(msg.DeviceName))     msg.DeviceName     = envelope.DeviceName;
        if (string.IsNullOrEmpty(msg.EntraDeviceId))  msg.EntraDeviceId  = envelope.EntraDeviceId;
        if (string.IsNullOrEmpty(msg.IntuneDeviceId)) msg.IntuneDeviceId = envelope.IntuneDeviceId;

        using var scope = _log.BeginScope(new Dictionary<string, object>
        {
            ["CorrelationId"]  = msg.CorrelationId,
            ["DeviceName"]     = msg.DeviceName,
            ["EntraDeviceId"]  = msg.EntraDeviceId,
            ["IntuneDeviceId"] = msg.IntuneDeviceId,
            ["ActionType"]     = Type,
        });

        _log.LogInformation("Running bitlocker-rotate action for {Device}", msg.DeviceName);

        // 1) Resolve Entra directory object id
        string? deviceObjId;
        try
        {
            deviceObjId = await _graph.GetDeviceObjectIdAsync(msg.EntraDeviceId, ct);
        }
        catch (Exception ex) when (GraphErrorClassifier.Classify(ex) == GraphErrorClassifier.GraphErrorKind.Transient)
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
        catch (Exception ex) when (GraphErrorClassifier.Classify(ex) == GraphErrorClassifier.GraphErrorKind.Transient)
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

        // 3) Ownership: resolve managedDevice via Graph (server-authoritative)
        string? managedId;
        try
        {
            managedId = await _graph.ResolveAndValidateAsync(msg.EntraDeviceId, ct);
        }
        catch (Exception ex) when (GraphErrorClassifier.Classify(ex) == GraphErrorClassifier.GraphErrorKind.Transient)
        {
            _log.LogWarning(ex, "Transient error on managed-device resolve — will retry");
            throw;
        }
        catch (Exception ex)
        {
            _audit.TrackEvent(AuditEvents.DeniedManagedDeviceResolveFailed, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
                [AuditEvents.Prop.EntraDeviceId]  = msg.EntraDeviceId,
                [AuditEvents.Prop.DeviceName]     = msg.DeviceName,
            });
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

        if (state == ActionIdempotencyService.State.RateLimited)
        {
            _audit.TrackEvent(AuditEvents.DeniedRateLimited, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]             = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]                = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId]            = msg.IntuneDeviceId,
                [AuditEvents.Prop.RecentActionsInWindow]     = reserve.RecentActionsInWindow.ToString(),
                [AuditEvents.Prop.MaxActionsPerDevicePerDay] = reserve.MaxActionsPerDevicePerDay.ToString(),
            }, LogLevel.Warning);
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:rate-limited", ct, managedId);
            return;
        }

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
            _audit.TrackEvent(rearmEvent, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]         = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]            = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId]        = msg.IntuneDeviceId,
                [AuditEvents.Prop.ActionSequence]        = entry.ActionSequence.ToString(),
                [AuditEvents.Prop.PreviousTerminalState] = entry.LastTerminalState ?? "(unknown)",
                [AuditEvents.Prop.RearmReason]           = reserve.Rearmed.ToString(),
            });
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

        // 5) Execute rotateBitLockerKeys
        try
        {
            await _graph.RotateBitLockerKeysAsync(managedId, ct);
            await _ledger.MarkIssuedAsync(msg.IntuneDeviceId, msg.CorrelationId, ct);
            _audit.TrackEvent(BitLockerAuditEvents.RotateIssued, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]   = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]      = msg.DeviceName,
                [AuditEvents.Prop.EntraDeviceId]   = msg.EntraDeviceId,
                [AuditEvents.Prop.IntuneDeviceId]  = msg.IntuneDeviceId,
                [AuditEvents.Prop.ManagedDeviceId] = managedId,
            });

            try { await _statusTracker.InitializeAsync(msg, Type, managedId, ct); }
            catch (Exception ex) { _log.LogWarning(ex, "Status tracker initialization failed for {Corr}", msg.CorrelationId); }
        }
        catch (Exception ex) when (GraphErrorClassifier.Classify(ex) == GraphErrorClassifier.GraphErrorKind.Permanent)
        {
            await _ledger.MarkFailedAsync(msg.IntuneDeviceId, msg.CorrelationId, ex.Message, ct);
            _audit.TrackEvent(BitLockerAuditEvents.RotateFailedPermanent, ex, new Dictionary<string, string>
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
            _audit.TrackEvent(BitLockerAuditEvents.RotateTransientError, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]   = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]      = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId]  = msg.IntuneDeviceId,
                [AuditEvents.Prop.ManagedDeviceId] = managedId,
            }, LogLevel.Warning);
            throw;
        }
    }
}
