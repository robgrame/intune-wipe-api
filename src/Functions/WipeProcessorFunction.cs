using System.Text.Json;
using IntuneWipeApi.Models;
using IntuneWipeApi.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Functions;

/// <summary>
/// Internal queue-triggered processor. Steps:
///   1) resolve Entra directory object id
///   2) check membership of the allowed Entra group
///   3) validate Intune↔Entra mapping (ownership)
///   4) reserve an idempotency ledger entry — skip if a wipe was already issued
///   5) call Graph wipe; mark ledger Issued/Failed accordingly
/// Permanent errors do not throw (no retry); transient errors throw (queue retries → poison after 5 attempts).
/// </summary>
public sealed class WipeProcessorFunction
{
    private readonly GraphWipeService _graph;
    private readonly IdempotencyService _ledger;
    private readonly ILogger<WipeProcessorFunction> _log;

    public WipeProcessorFunction(GraphWipeService graph, IdempotencyService ledger, ILogger<WipeProcessorFunction> log)
    {
        _graph = graph;
        _ledger = ledger;
        _log = log;
    }

    [Function("WipeProcessor")]
    public async Task Run(
        [QueueTrigger("%Queue:WipeQueueName%", Connection = "AzureWebJobsStorage")] string messageJson,
        CancellationToken ct)
    {
        // 0) App role guard: this function may run ONLY on the worker app.
        //    Throwing without ack releases the message back to the queue so the
        //    correctly-configured worker app can pick it up; after 5 retries it
        //    moves to the poison queue and stops bouncing.
        if (!AppRoleGuard.IsAllowed(AppRoleGuard.Proc))
        {
            _log.LogError("AUDIT denied reason=app-role-mismatch expected={Expected} actual={Actual}",
                AppRoleGuard.Proc, AppRoleGuard.CurrentRole);
            throw new InvalidOperationException(
                $"App role mismatch: this Function App is not the wipe processor (App__Role='{AppRoleGuard.CurrentRole}')");
        }

        var msg = JsonSerializer.Deserialize<WipeQueueMessage>(messageJson)
            ?? throw new InvalidOperationException("Empty/invalid queue payload");

        using var scope = _log.BeginScope(new Dictionary<string, object>
        {
            ["CorrelationId"] = msg.CorrelationId,
            ["DeviceName"]    = msg.DeviceName,
            ["EntraDeviceId"] = msg.EntraDeviceId,
            ["IntuneDeviceId"]= msg.IntuneDeviceId
        });

        _log.LogInformation("Processing wipe request for {Device}", msg.DeviceName);

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
            _log.LogWarning(ex, "AUDIT denied reason=device-resolve-failed-permanent corr={Corr}", msg.CorrelationId);
            return;
        }

        if (deviceObjId is null)
        {
            _log.LogWarning("AUDIT denied reason=device-not-found-in-entra corr={Corr}", msg.CorrelationId);
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
            _log.LogWarning(ex, "AUDIT denied reason=group-check-failed-permanent corr={Corr}", msg.CorrelationId);
            return;
        }

        if (!inGroup)
        {
            _log.LogWarning("AUDIT denied reason=device-not-in-allowed-group device={Device} corr={Corr}",
                msg.DeviceName, msg.CorrelationId);
            return;
        }

        // 3) Ownership: managedDevice.azureADDeviceId must match
        string? managedId;
        try
        {
            managedId = await _graph.ResolveAndValidateAsync(msg.IntuneDeviceId, msg.EntraDeviceId, ct);
        }
        catch (Exception ex) when (GraphWipeService.Classify(ex) == GraphWipeService.GraphErrorKind.Transient)
        {
            _log.LogWarning(ex, "Transient error on managed-device resolve — will retry");
            throw;
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "AUDIT denied reason=managed-device-resolve-failed-permanent corr={Corr}", msg.CorrelationId);
            return;
        }

        if (managedId is null)
        {
            _log.LogWarning("AUDIT denied reason=ownership-mismatch device={Device} corr={Corr}",
                msg.DeviceName, msg.CorrelationId);
            return;
        }

        // 4) Idempotency reservation
        var (state, entry) = await _ledger.ReserveAsync(msg.IntuneDeviceId, msg.CorrelationId, ct);
        if (state == IdempotencyService.State.Issued)
        {
            _log.LogInformation(
                "AUDIT wipe-already-issued device={Device} intune={Intune} originalCorr={Orig} corr={Corr}",
                msg.DeviceName, msg.IntuneDeviceId, entry.CorrelationId, msg.CorrelationId);
            return;
        }
        if (state == IdempotencyService.State.Reserved && entry.CorrelationId != msg.CorrelationId)
        {
            _log.LogWarning(
                "AUDIT wipe-in-progress-elsewhere device={Device} intune={Intune} originalCorr={Orig} corr={Corr}",
                msg.DeviceName, msg.IntuneDeviceId, entry.CorrelationId, msg.CorrelationId);
            // Another worker reserved it; skip to avoid double-wipe.
            return;
        }

        // 5) Execute wipe
        try
        {
            await _graph.WipeAsync(managedId, ct);
            await _ledger.MarkIssuedAsync(msg.IntuneDeviceId, msg.CorrelationId, ct);
            _log.LogInformation(
                "AUDIT wipe-issued device={Device} entra={Entra} intune={Intune} managed={Managed} corr={Corr}",
                msg.DeviceName, msg.EntraDeviceId, msg.IntuneDeviceId, managedId, msg.CorrelationId);
        }
        catch (Exception ex) when (GraphWipeService.Classify(ex) == GraphWipeService.GraphErrorKind.Permanent)
        {
            await _ledger.MarkFailedAsync(msg.IntuneDeviceId, msg.CorrelationId, ex.Message, ct);
            _log.LogError(ex,
                "AUDIT wipe-failed-permanent device={Device} intune={Intune} corr={Corr}",
                msg.DeviceName, msg.IntuneDeviceId, msg.CorrelationId);
            // Do not throw — no retry on permanent errors.
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex,
                "AUDIT wipe-transient-error device={Device} intune={Intune} corr={Corr} — will retry",
                msg.DeviceName, msg.IntuneDeviceId, msg.CorrelationId);
            // Throw → queue retries (visibility timeout). After 5 attempts → poison queue.
            throw;
        }
    }
}
