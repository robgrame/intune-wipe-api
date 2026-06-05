using System.Net;
using IntuneDeviceActions.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Functions;

/// <summary>
/// Public HTTP endpoint <c>GET /api/actions/status/{correlationId}</c> that
/// surfaces the outcome of a previously-issued action. Action-agnostic: the
/// <c>correlationId</c> uniquely identifies the request and the concrete
/// <c>actionType</c> is opaque to this function — it is carried verbatim in
/// the snapshot returned to the caller.
///
/// Reads the row tracked by <see cref="ActionStatusTracker"/> in the
/// <c>actionstatus</c> table and returns a small JSON projection.
/// </summary>
/// <remarks>
/// <para>
/// Authentication mirrors <see cref="ActionRequestFunction"/>: mTLS is required
/// and the caller's certificate-bound device id must match the EntraDeviceId
/// of the row being read. This prevents one enrolled device from snooping the
/// action outcome of another (basic IDOR defense).
/// </para>
/// <para>
/// HTTP contract:
/// <list type="bullet">
///   <item><description><c>200 OK</c> with snapshot if the row exists and the caller is authorized.</description></item>
///   <item><description><c>400 Bad Request</c> if the correlationId is missing or malformed.</description></item>
///   <item><description><c>401 Unauthorized</c> on cert/binding failure.</description></item>
///   <item><description><c>403 Forbidden</c> if the bound device id doesn't match the row owner.</description></item>
///   <item><description><c>404 Not Found</c> if no row exists for the correlationId.</description></item>
///   <item><description><c>503 Service Unavailable</c> if status tracking isn't configured on this deployment.</description></item>
/// </list>
/// </para>
/// </remarks>
public sealed class ActionStatusFunction
{
    private readonly ClientCertValidator _cert;
    private readonly ActionStatusTracker _tracker;
    private readonly AuditService _audit;
    private readonly ILogger<ActionStatusFunction> _log;

    public ActionStatusFunction(ClientCertValidator cert, ActionStatusTracker tracker,
        AuditService audit, ILogger<ActionStatusFunction> log)
    {
        _cert = cert;
        _tracker = tracker;
        _audit = audit;
        _log = log;
    }

    [Function("ActionStatus")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "actions/status/{correlationId}")] HttpRequest req,
        string correlationId,
        CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(correlationId) || correlationId.Length > 64)
        {
            return new BadRequestObjectResult(new { status = "error", message = "invalid correlationId" });
        }

        // mTLS
        var (ok, cert, reason) = _cert.Validate(req.HttpContext);
        if (!ok)
        {
            _audit.TrackEvent(AuditEvents.DeniedCertValidation, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]  = correlationId,
                [AuditEvents.Prop.Reason]         = reason ?? "",
                [AuditEvents.Prop.CertThumbprint] = cert?.Thumbprint ?? "",
            }, LogLevel.Warning);
            return new ObjectResult(new { status = "denied", message = $"client cert: {reason}", correlationId })
                { StatusCode = (int)HttpStatusCode.Unauthorized };
        }

        if (!_tracker.IsEnabled)
        {
            return new ObjectResult(new
            {
                status = "unavailable",
                message = "status tracking is not configured on this deployment",
                correlationId
            }) { StatusCode = (int)HttpStatusCode.ServiceUnavailable };
        }

        var snapshot = await _tracker.GetStatusAsync(correlationId, ct);
        if (snapshot is null)
        {
            return new NotFoundObjectResult(new
            {
                status = "not-found",
                message = "no action status recorded for the supplied correlationId",
                correlationId
            });
        }

        // IDOR defense: caller must own the row (when cert<->device binding is enabled).
        if (_cert.BindingEnabled)
        {
            var boundDeviceId = await _cert.GetBoundDeviceId(cert!, ct);
            if (string.IsNullOrEmpty(boundDeviceId))
            {
                _audit.TrackEvent(AuditEvents.DeniedCertBindingMissing, new Dictionary<string, string>
                {
                    [AuditEvents.Prop.CorrelationId]  = correlationId,
                    [AuditEvents.Prop.CertThumbprint] = cert!.Thumbprint ?? "",
                }, LogLevel.Warning);
                return new ObjectResult(new { status = "denied",
                    message = "client certificate is missing the configured device-id binding claim",
                    correlationId })
                    { StatusCode = (int)HttpStatusCode.Unauthorized };
            }

            if (!string.Equals(boundDeviceId, snapshot.EntraDeviceId, StringComparison.OrdinalIgnoreCase))
            {
                _audit.TrackEvent(AuditEvents.DeniedCertDeviceMismatch, new Dictionary<string, string>
                {
                    [AuditEvents.Prop.CorrelationId]  = correlationId,
                    [AuditEvents.Prop.BoundDeviceId]  = boundDeviceId,
                    [AuditEvents.Prop.EntraDeviceId]  = snapshot.EntraDeviceId,
                }, LogLevel.Warning);
                return new ObjectResult(new { status = "forbidden",
                    message = "this client cert is not bound to the device that issued the action",
                    correlationId })
                    { StatusCode = (int)HttpStatusCode.Forbidden };
            }
        }

        // Project to the public response shape — never leak ManagedDeviceId
        // (not useful to the device and clutters the response).
        return new OkObjectResult(new
        {
            status         = "ok",
            correlationId  = snapshot.CorrelationId,
            deviceName     = snapshot.DeviceName,
            entraDeviceId  = snapshot.EntraDeviceId,
            intuneDeviceId = snapshot.IntuneDeviceId,
            state          = snapshot.LastState,
            previousState  = snapshot.PreviousState,
            terminal       = snapshot.Terminal,
            issuedAt       = snapshot.IssuedAt,
            lastChangedAt  = snapshot.LastChangedAt,
            lastPolledAt   = snapshot.LastPolledAt,
            pollAttempts   = snapshot.PollAttempts,
        });
    }
}
