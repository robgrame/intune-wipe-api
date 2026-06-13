using System.Net;
using IntuneDeviceActions.Schedule;
using IntuneDeviceActions.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Functions;

/// <summary>
/// Public HTTP endpoint <c>GET /api/schedule/me</c> that returns the most
/// imminent scheduled action (if any) for the device whose mTLS client
/// certificate is bound to a directory device id. Capability-agnostic — the
/// concrete shape is owned by registered <see cref="IScheduleProvider"/>
/// instances (wipe today; autopilot / bitlocker tomorrow) and merged by
/// <see cref="ScheduleAggregator"/>.
/// </summary>
/// <remarks>
/// HTTP contract:
/// <list type="bullet">
///   <item><description><c>200 OK</c> + <see cref="DeviceScheduleSnapshot"/> JSON when a wave applies.</description></item>
///   <item><description><c>204 No Content</c> when no provider has work for the device.</description></item>
///   <item><description><c>401 Unauthorized</c> on cert/binding failure.</description></item>
///   <item><description><c>503 Service Unavailable</c> if no schedule providers are registered.</description></item>
/// </list>
/// </remarks>
public sealed class ScheduleManifestFunction
{
    private readonly ClientCertValidator _cert;
    private readonly ScheduleAggregator _aggregator;
    private readonly AuditService _audit;
    private readonly ILogger<ScheduleManifestFunction> _log;

    public ScheduleManifestFunction(ClientCertValidator cert, ScheduleAggregator aggregator,
        AuditService audit, ILogger<ScheduleManifestFunction> log)
    {
        _cert = cert;
        _aggregator = aggregator;
        _audit = audit;
        _log = log;
    }

    [Function("ScheduleManifest")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "schedule/me")] HttpRequest req,
        CancellationToken ct)
    {
        // 1) mTLS
        var (ok, cert, reason) = _cert.Validate(req.HttpContext);
        if (!ok)
        {
            _audit.TrackEvent(AuditEvents.DeniedCertValidation, new Dictionary<string, string>
            {
                [AuditEvents.Prop.Reason]         = reason ?? "",
                [AuditEvents.Prop.CertThumbprint] = cert?.Thumbprint ?? "",
            }, LogLevel.Warning);
            return new ObjectResult(new { status = "denied", message = $"client cert: {reason}" })
                { StatusCode = (int)HttpStatusCode.Unauthorized };
        }

        // 2) Device-id binding required — the schedule endpoint is inherently
        //    per-device, so without a binding the caller cannot identify
        //    itself.
        if (!_cert.BindingEnabled)
        {
            return new ObjectResult(new
            {
                status = "unavailable",
                message = "schedule endpoint requires the device-id certificate binding to be enabled on this deployment.",
            }) { StatusCode = (int)HttpStatusCode.ServiceUnavailable };
        }

        var boundDeviceId = await _cert.GetBoundDeviceId(cert!, ct);
        if (string.IsNullOrWhiteSpace(boundDeviceId))
        {
            _audit.TrackEvent(AuditEvents.DeniedCertBindingMissing, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CertThumbprint] = cert!.Thumbprint ?? "",
            }, LogLevel.Warning);
            return new ObjectResult(new
            {
                status = "denied",
                message = "client certificate is missing the configured device-id binding claim",
            }) { StatusCode = (int)HttpStatusCode.Unauthorized };
        }

        if (!Guid.TryParse(boundDeviceId, out var entraDeviceId))
        {
            return new ObjectResult(new
            {
                status = "denied",
                message = "client certificate device binding is not a valid GUID",
            }) { StatusCode = (int)HttpStatusCode.Unauthorized };
        }

        // 3) Capability check
        if (!_aggregator.HasProviders)
        {
            return new ObjectResult(new
            {
                status = "unavailable",
                message = "no schedule providers are registered on this deployment.",
            }) { StatusCode = (int)HttpStatusCode.ServiceUnavailable };
        }

        // 4) Optional capability filter (?actionType=wipe). Default = merge all.
        string? actionTypeFilter = req.Query.TryGetValue("actionType", out var atv)
            ? atv.ToString()
            : null;

        var snap = await _aggregator.GetScheduleAsync(entraDeviceId, actionTypeFilter, ct);

        var auditProps = new Dictionary<string, string>
        {
            [AuditEvents.Prop.EntraDeviceId] = entraDeviceId.ToString(),
        };
        if (!string.IsNullOrEmpty(actionTypeFilter))
            auditProps[AuditEvents.Prop.ActionType] = actionTypeFilter!;
        _audit.TrackEvent(AuditEvents.ScheduleQueried, auditProps, LogLevel.Information);

        if (snap is null)
        {
            _audit.TrackEvent(AuditEvents.ScheduleEmpty, auditProps, LogLevel.Information);
            return new NoContentResult();
        }

        var returnedProps = new Dictionary<string, string>(auditProps)
        {
            [AuditEvents.Prop.ScheduleWaveId]         = snap.WaveId,
            [AuditEvents.Prop.ScheduleWaveName]       = snap.Name,
            [AuditEvents.Prop.ScheduleWaveStatus]     = snap.Status,
            [AuditEvents.Prop.ActionType]             = snap.ActionType,
            [AuditEvents.Prop.ScheduleScheduledAtUtc] = snap.ScheduledAtUtc.ToString("O"),
        };
        _audit.TrackEvent(AuditEvents.ScheduleReturned, returnedProps, LogLevel.Information);

        return new OkObjectResult(snap);
    }
}
