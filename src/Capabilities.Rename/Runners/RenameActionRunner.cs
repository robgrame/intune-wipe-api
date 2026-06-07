using System.Text.Json;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Capabilities.Rename.Audit;
using IntuneDeviceActions.Capabilities.Rename.Services;
using IntuneDeviceActions.Models;
using IntuneDeviceActions.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Capabilities.Rename.Runners;

/// <summary>
/// <see cref="IActionRunner"/> for the <c>device-rename</c> action. Lives on
/// the dedicated Rename Function App (the proc role only forwards via
/// <see cref="RenameForwardingRunner"/>).
/// </summary>
/// <remarks>
/// Pipeline (LOOKUP + Graph):
/// <list type="number">
///   <item>extract + validate <c>rename</c> payload (serial required);</item>
///   <item>reserve idempotency ledger entry — skip if already issued / rate-limited;</item>
///   <item>LOOKUP the canonical new name from the customer CMDB via
///         <see cref="ICustomerRenameClient"/> (GET serial → newName);</item>
///   <item>collision check — query Entra for existing devices with the same
///         <c>displayName</c> (Entra does not enforce uniqueness on device
///         displayName, unlike on-prem AD). Behaviour controlled by
///         <c>Rename:OnCollision</c> (<c>block</c> | <c>warn</c>);</item>
///   <item>call Microsoft Graph
///         <c>POST /deviceManagement/managedDevices/{id}/setDeviceName</c>;</item>
///   <item>mark ledger Issued/Failed based on classified outcome;</item>
///   <item>open the status-tracker row so <c>GET /api/actions/status</c> works.</item>
/// </list>
/// Permanent errors (lookup NotFound/permanent, Graph 4xx other than 408/429,
/// collision blocked) are swallowed (no queue retry); transient errors throw
/// so the per-capability Service Bus consumer retries via its built-in policy.
/// </remarks>
public sealed class RenameActionRunner : IActionRunner
{
    public string Type => "device-rename";

    private readonly ICustomerRenameClient _customer;
    private readonly GraphRenameService _graph;
    private readonly ActionIdempotencyService _ledger;
    private readonly AuditService _audit;
    private readonly ActionStatusTracker _statusTracker;
    private readonly IConfiguration _cfg;
    private readonly ILogger<RenameActionRunner> _log;

    public RenameActionRunner(ICustomerRenameClient customer, GraphRenameService graph,
        ActionIdempotencyService ledger, AuditService audit, ActionStatusTracker statusTracker,
        IConfiguration cfg, ILogger<RenameActionRunner> log)
    {
        _customer = customer;
        _graph = graph;
        _ledger = ledger;
        _audit = audit;
        _statusTracker = statusTracker;
        _cfg = cfg;
        _log = log;
    }

    public async Task RunAsync(ActionDispatchMessage envelope, CancellationToken ct)
    {
        var msg = envelope.Payload.Deserialize<ActionRequestMessage>()
            ?? throw new InvalidOperationException("Rename payload missing/invalid in dispatch envelope.");

        if (string.IsNullOrEmpty(msg.CorrelationId))  msg.CorrelationId  = envelope.CorrelationId;
        if (string.IsNullOrEmpty(msg.DeviceName))     msg.DeviceName     = envelope.DeviceName;
        if (string.IsNullOrEmpty(msg.EntraDeviceId))  msg.EntraDeviceId  = envelope.EntraDeviceId;
        if (string.IsNullOrEmpty(msg.IntuneDeviceId)) msg.IntuneDeviceId = envelope.IntuneDeviceId;

        using var scope = _log.BeginScope(new Dictionary<string, object>
        {
            ["CorrelationId"]  = msg.CorrelationId,
            ["DeviceName"]     = msg.DeviceName,
            ["IntuneDeviceId"] = msg.IntuneDeviceId,
            ["ActionType"]     = Type,
        });

        _log.LogInformation("Running device-rename action for {Device}", msg.DeviceName);

        // 0) Payload validation — serial mandatory; intuneDeviceId mandatory for Graph call.
        var extras = RenamePayloadExtractor.TryRead(msg);
        if (extras is null || string.IsNullOrWhiteSpace(extras.SerialNumber))
        {
            _audit.TrackEvent(RenameAuditEvents.MissingSerial, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]     = msg.DeviceName,
                [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
            }, LogLevel.Warning);
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:missing-serial", ct);
            return;
        }
        if (string.IsNullOrWhiteSpace(msg.IntuneDeviceId))
        {
            _audit.TrackEvent(RenameAuditEvents.MissingIntuneDeviceId, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]     = msg.DeviceName,
                ["serial"]                        = extras.SerialNumber,
            }, LogLevel.Warning);
            await _statusTracker.RecordTerminalAsync(msg, Type, "denied:missing-intune-device-id", ct);
            return;
        }

        var serial = extras.SerialNumber.Trim();

        // 1) Idempotency reservation — same contract as bitlocker/wipe.
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

        // 2) LOOKUP — ask the customer CMDB for the canonical new name.
        RenameLookupOutcome lookup;
        try
        {
            lookup = await _customer.ResolveNewNameAsync(serial, msg.CorrelationId, ct);
        }
        catch (Exception ex)
        {
            _audit.TrackEvent(RenameAuditEvents.LookupTransientError, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
                ["serial"]                        = serial,
            }, LogLevel.Warning);
            throw;
        }

        if (lookup.OutcomeKind == RenameLookupOutcome.Kind.NotFound)
        {
            await _ledger.MarkFailedAsync(msg.IntuneDeviceId, msg.CorrelationId, lookup.Reason, ct);
            _audit.TrackEvent(RenameAuditEvents.LookupNotFound, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
                ["serial"]                        = serial,
                ["httpStatus"]                    = lookup.StatusCode.ToString(),
            }, LogLevel.Warning);
            await _statusTracker.RecordTerminalAsync(msg, Type, "failed:lookup-not-found", ct, serial);
            return;
        }
        if (lookup.OutcomeKind == RenameLookupOutcome.Kind.Permanent)
        {
            await _ledger.MarkFailedAsync(msg.IntuneDeviceId, msg.CorrelationId, lookup.Reason, ct);
            _audit.TrackEvent(RenameAuditEvents.LookupFailedPermanent, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
                ["serial"]                        = serial,
                ["httpStatus"]                    = lookup.StatusCode.ToString(),
                ["reason"]                        = lookup.Reason,
            }, LogLevel.Error);
            await _statusTracker.RecordTerminalAsync(msg, Type, "failed:lookup-permanent", ct, serial);
            return;
        }
        if (lookup.OutcomeKind == RenameLookupOutcome.Kind.Transient)
        {
            _audit.TrackEvent(RenameAuditEvents.LookupTransientError, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
                ["serial"]                        = serial,
                ["httpStatus"]                    = lookup.StatusCode.ToString(),
                ["reason"]                        = lookup.Reason,
            }, LogLevel.Warning);
            throw new HttpRequestException(
                $"Customer rename lookup returned transient outcome (status={lookup.StatusCode}, reason={lookup.Reason}).");
        }

        var newName = lookup.NewName!;
        _audit.TrackEvent(RenameAuditEvents.LookupIssued, new Dictionary<string, string>
        {
            [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
            [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
            ["serial"]                        = serial,
            ["newName"]                       = newName,
        });

        // 3) Collision check — Entra does NOT enforce uniqueness on device
        //    displayName (unlike on-prem AD). Skip when the resolved name
        //    matches the device's current name (renaming to self is a no-op).
        var sameAsCurrent = !string.IsNullOrEmpty(msg.DeviceName)
            && string.Equals(msg.DeviceName, newName, StringComparison.OrdinalIgnoreCase);
        if (!sameAsCurrent)
        {
            IReadOnlyList<DeviceCollision>? collisions = null;
            try
            {
                collisions = await _graph.FindDisplayNameCollisionsAsync(newName, msg.EntraDeviceId, ct);
            }
            catch (Exception ex)
            {
                // Don't fail closed on Graph hiccups during the pre-check —
                // log + transient-throw so the SB queue retries the whole
                // message (idempotency ledger will short-circuit if we got
                // through to setDeviceName on a previous try).
                _audit.TrackEvent(RenameAuditEvents.CollisionCheckFailed, ex, new Dictionary<string, string>
                {
                    [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                    [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
                    ["newName"]                       = newName,
                }, LogLevel.Warning);
                if (GraphRenameService.Classify(ex) == GraphErrorClassifier.GraphErrorKind.Transient) throw;
                // Permanent — surface as a permanent failure rather than silently
                // skipping the check (collision detection is a safety guardrail).
                await _ledger.MarkFailedAsync(msg.IntuneDeviceId, msg.CorrelationId, $"collision-check-failed:{ex.Message}", ct);
                await _statusTracker.RecordTerminalAsync(msg, Type, "failed:collision-check", ct, newName);
                return;
            }

            if (collisions.Count > 0)
            {
                var onCollision = (_cfg["Rename:OnCollision"] ?? "block").Trim().ToLowerInvariant();
                var detail = string.Join(",",
                    collisions.Select(c => $"{c.DisplayName}@{c.EntraDeviceId}{(c.AccountEnabled == false ? "(disabled)" : string.Empty)}"));

                _audit.TrackEvent(RenameAuditEvents.CollisionDetected, new Dictionary<string, string>
                {
                    [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                    [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
                    ["newName"]                       = newName,
                    ["collisions"]                    = detail,
                    ["collisionCount"]                = collisions.Count.ToString(),
                    ["policy"]                        = onCollision,
                }, LogLevel.Warning);

                if (onCollision == "block")
                {
                    await _ledger.MarkFailedAsync(msg.IntuneDeviceId, msg.CorrelationId, $"name-collision:{collisions.Count}", ct);
                    _audit.TrackEvent(RenameAuditEvents.CollisionBlocked, new Dictionary<string, string>
                    {
                        [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                        [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
                        ["newName"]                       = newName,
                        ["collisions"]                    = detail,
                    }, LogLevel.Error);
                    await _statusTracker.RecordTerminalAsync(msg, Type, "denied:name-collision", ct, newName);
                    return;
                }
                // policy=warn → proceed; the warning is already in customEvents.
            }
        }

        // 4) Graph setDeviceName — Intune queues the rename for the next MDM sync.
        try
        {
            await _graph.SetDeviceNameAsync(msg.IntuneDeviceId, newName, ct);
            await _ledger.MarkIssuedAsync(msg.IntuneDeviceId, msg.CorrelationId, ct);
            _audit.TrackEvent(RenameAuditEvents.GraphSetNameIssued, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                [AuditEvents.Prop.DeviceName]     = msg.DeviceName,
                [AuditEvents.Prop.EntraDeviceId]  = msg.EntraDeviceId,
                [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
                ["serial"]                        = serial,
                ["newName"]                       = newName,
                ["sameAsCurrent"]                 = sameAsCurrent.ToString(),
            });

            try { await _statusTracker.InitializeAsync(msg, Type, newName, ct); }
            catch (Exception ex) { _log.LogWarning(ex, "Status tracker initialization failed for {Corr}", msg.CorrelationId); }
        }
        catch (Exception ex)
        {
            if (GraphRenameService.Classify(ex) == GraphErrorClassifier.GraphErrorKind.Permanent)
            {
                await _ledger.MarkFailedAsync(msg.IntuneDeviceId, msg.CorrelationId, ex.Message, ct);
                _audit.TrackEvent(RenameAuditEvents.GraphSetNameFailedPermanent, ex, new Dictionary<string, string>
                {
                    [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                    [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
                    ["serial"]                        = serial,
                    ["newName"]                       = newName,
                }, LogLevel.Error);
                await _statusTracker.RecordTerminalAsync(msg, Type, "failed:permanent", ct, newName);
                return;
            }
            _audit.TrackEvent(RenameAuditEvents.GraphSetNameTransientError, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]  = msg.CorrelationId,
                [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
                ["serial"]                        = serial,
                ["newName"]                       = newName,
            }, LogLevel.Warning);
            throw;
        }
    }
}
