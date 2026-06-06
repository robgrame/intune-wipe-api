using System.Text.Json;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Capabilities.Autopilot.Audit;
using IntuneDeviceActions.Capabilities.Autopilot.Models;
using IntuneDeviceActions.Capabilities.Autopilot.Services;
using IntuneDeviceActions.Models;
using IntuneDeviceActions.Services;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Capabilities.Autopilot.Runners;

/// <summary>
/// <see cref="IActionRunner"/> for the <c>autopilot-register</c> action — the
/// privileged executor that imports the client-collected hardware identity into
/// Windows Autopilot via Graph
/// <c>importedWindowsAutopilotDeviceIdentities</c>.
/// </summary>
/// <remarks>
/// Reuses the wipe/bitlocker fail-closed pre-issue safety pipeline, but:
/// <list type="number">
///   <item>requires an Autopilot payload with a hardware hash (collected on the
///         client — not available server-side);</item>
///   <item>resolves the Entra directory object id;</item>
///   <item>checks membership of the allowed Entra group (<c>Autopilot:AllowedGroupId</c>);</item>
///   <item><b>skips</b> the destructive managedDevice ownership check — this
///         action does not act on an existing managed device, it registers a new
///         hardware identity;</item>
///   <item>reserves an idempotency ledger entry — one import per device;</item>
///   <item>calls Graph import; marks ledger Issued/Failed accordingly; stores
///         the returned import-identity id as the probe handle.</item>
/// </list>
/// Permanent errors swallow (no queue retry); transient errors throw.
/// </remarks>
public sealed class AutopilotRegisterRunner : IActionRunner
{
    public string Type => "autopilot-register";

    private readonly GraphAutopilotService _graph;
    private readonly ActionIdempotencyService _ledger;
    private readonly AuditService _audit;
    private readonly ActionStatusTracker _statusTracker;
    private readonly ILogger<AutopilotRegisterRunner> _log;

    public AutopilotRegisterRunner(GraphAutopilotService graph, ActionIdempotencyService ledger,
        AuditService audit, ActionStatusTracker statusTracker, ILogger<AutopilotRegisterRunner> log)
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
            ?? throw new InvalidOperationException("Autopilot payload missing/invalid in dispatch envelope.");

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

        _log.LogInformation("Running autopilot-register action for {Device}", msg.DeviceName);

        // 0) Payload validation — the hardware hash is collected on the client and
        //    is mandatory for the Graph import. Missing hash is a permanent denial.
        //    The autopilot payload travels opaquely in the action-agnostic Extras
        //    bag; we pull it out by its capability-owned key via the extractor
        //    helper (separately unit-tested).
        var autopilot = AutopilotPayloadExtractor.TryRead(msg);
        if (autopilot is null || string.IsNullOrWhiteSpace(autopilot.HardwareHash))
        {
            _audit.TrackEvent(AutopilotAuditEvents.DeniedMissingHardwareHash, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId] = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]    = msg.DeviceName,
                [AuditEvents.Prop.EntraDeviceId] = msg.EntraDeviceId,
            }, LogLevel.Warning);
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:missing-hardware-hash", ct);
            return;
        }

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

        // 3) Idempotency reservation (with auto-rearm + rate limiting). Keyed on
        //    the Intune device id — one Autopilot import per device.
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
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:rate-limited", ct);
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
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:already-issued", ct);
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
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:in-progress-elsewhere", ct);
            return;
        }

        // 4) Execute the Autopilot import
        try
        {
            var import = await _graph.ImportAsync(autopilot, ct);
            await _ledger.MarkIssuedAsync(msg.IntuneDeviceId, msg.CorrelationId, ct);
            _audit.TrackEvent(AutopilotAuditEvents.ImportIssued, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]   = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]      = msg.DeviceName,
                [AuditEvents.Prop.EntraDeviceId]   = msg.EntraDeviceId,
                [AuditEvents.Prop.IntuneDeviceId]  = msg.IntuneDeviceId,
                [AuditEvents.Prop.ManagedDeviceId] = import.ImportIdentityId ?? string.Empty,
                ["importStatus"]                   = import.ImportStatus,
            });

            // Store the import-identity id as the probe handle so the status
            // poller can reconcile pending → complete/error.
            try { await _statusTracker.InitializeAsync(msg, Type, import.ImportIdentityId ?? string.Empty, ct); }
            catch (Exception ex) { _log.LogWarning(ex, "Status tracker initialization failed for {Corr}", msg.CorrelationId); }
        }
        catch (Exception ex) when (GraphErrorClassifier.Classify(ex) == GraphErrorClassifier.GraphErrorKind.Permanent)
        {
            await _ledger.MarkFailedAsync(msg.IntuneDeviceId, msg.CorrelationId, ex.Message, ct);
            _audit.TrackEvent(AutopilotAuditEvents.ImportFailedPermanent, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]     = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
            });
            await _statusTracker.RecordTerminalAsync(msg, Type, "failed:permanent", ct);
            // Do not throw — no retry on permanent errors.
        }
        catch (Exception ex)
        {
            _audit.TrackEvent(AutopilotAuditEvents.ImportTransientError, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]     = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
            }, LogLevel.Warning);
            throw;
        }
    }
}
