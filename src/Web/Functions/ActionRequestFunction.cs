using System.Net;
using System.Text.Json;
using Azure.Messaging.ServiceBus;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Models;
using IntuneDeviceActions.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Functions;

/// <summary>
/// Public HTTP endpoint: validates the client (cert + payload + replay headers + cert↔device binding)
/// and publishes an action request on the <c>action-requests</c> Service Bus
/// queue. All heavy lifting (group membership, Graph wipe) happens
/// asynchronously downstream (RequestIntakeFunction → ActionDispatch → WipeAction).
/// </summary>
public sealed class ActionRequestFunction
{
    private readonly ClientCertValidator _cert;
    private readonly ReplayProtector _replay;
    private readonly ActionRequestSender _sender;
    private readonly AuditService _audit;
    private readonly IConfiguration _cfg;
    private readonly ILogger<ActionRequestFunction> _log;

    public ActionRequestFunction(ClientCertValidator cert, ReplayProtector replay,
        ActionRequestSender sender, AuditService audit, IConfiguration cfg, ILogger<ActionRequestFunction> log)
    {
        _cert = cert;
        _replay = replay;
        _sender = sender;
        _audit = audit;
        _cfg = cfg;
        _log = log;
    }

    [Function("ActionRequest")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "actions/wipe")] HttpRequest req,
        CancellationToken ct)
    {
        var correlationId = Guid.NewGuid().ToString("N");
        using var scope = _log.BeginScope(new Dictionary<string, object> { ["CorrelationId"] = correlationId });

        _log.LogDebug("ActionRequest received: corr={Corr} method={Method} path={Path} contentLength={Len}",
            correlationId, req.Method, req.Path.Value, req.ContentLength ?? -1);
        if (_log.IsEnabled(LogLevel.Trace))
        {
            // VERBOSE: dump headers (excluding Authorization / Cookie). Only emitted
            // when LogLevel for IntuneDeviceActions.* is Trace — never enabled in prod.
            var headerDump = string.Join(", ", req.Headers
                .Where(h => !string.Equals(h.Key, "Authorization", StringComparison.OrdinalIgnoreCase)
                         && !string.Equals(h.Key, "Cookie", StringComparison.OrdinalIgnoreCase))
                .Select(h => $"{h.Key}={h.Value}"));
            _log.LogTrace("ActionRequest headers: {Headers}", headerDump);
        }

        // 0.1) Inbound audit — emitted BEFORE any validation so even rejected/
        // malformed attempts leave a forensic trace. Captures the request
        // envelope (caller IP, UA, content type, size) without touching the body.
        var callerIp = req.HttpContext.Connection.RemoteIpAddress?.ToString()
            ?? req.Headers["X-Forwarded-For"].ToString();
        var userAgent = req.Headers.UserAgent.ToString();
        _audit.TrackEvent(AuditEvents.RequestReceived, new Dictionary<string, string>
        {
            [AuditEvents.Prop.CorrelationId] = correlationId,
            [AuditEvents.Prop.CallerIp]      = callerIp ?? "",
            [AuditEvents.Prop.UserAgent]     = userAgent ?? "",
            [AuditEvents.Prop.ContentType]   = req.ContentType ?? "",
            [AuditEvents.Prop.RequestSize]   = (req.ContentLength ?? -1).ToString(),
            [AuditEvents.Prop.CertThumbprint] = req.HttpContext.Connection.ClientCertificate?.Thumbprint ?? "",
        });

        // 1) Replay protection (timestamp + nonce)
        var ts = req.Headers["X-Request-Timestamp"].ToString();
        var nonce = req.Headers["X-Request-Nonce"].ToString();
        var (replayOk, replayReason) = _replay.Validate(ts, nonce);
        _log.LogDebug("Replay check: ok={Ok} reason={Reason} ts={Ts} nonceLen={NonceLen}",
            replayOk, replayReason ?? "(none)", ts ?? "(empty)", nonce?.Length ?? 0);
        if (!replayOk)
        {
            _audit.TrackEvent(AuditEvents.DeniedReplay, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId] = correlationId,
                [AuditEvents.Prop.Reason]        = replayReason ?? "",
            }, LogLevel.Warning);
            return new ObjectResult(new { status = "denied", message = replayReason, correlationId })
                { StatusCode = (int)HttpStatusCode.BadRequest };
        }

        // 2) Client certificate (chain validation + EKU + optional revocation)
        var (ok, cert, reason) = _cert.Validate(req.HttpContext);
        _log.LogDebug("Cert validation: ok={Ok} thumb={Thumb} reason={Reason}",
            ok, cert?.Thumbprint ?? "(none)", reason ?? "(none)");
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

        // 3) Payload
        ActionRequest? body;
        try
        {
            body = await JsonSerializer.DeserializeAsync<ActionRequest>(req.Body,
                new JsonSerializerOptions(JsonSerializerDefaults.Web), ct);
        }
        catch (Exception ex)
        {
            _audit.TrackEvent(AuditEvents.DeniedPayloadInvalid, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId] = correlationId,
                [AuditEvents.Prop.Reason]        = "invalid-json",
            }, LogLevel.Warning);
            return new BadRequestObjectResult(new { status = "error", message = "invalid JSON", correlationId });
        }

        if (body is null
            || string.IsNullOrWhiteSpace(body.EntraDeviceId)
            || string.IsNullOrWhiteSpace(body.IntuneDeviceId)
            || string.IsNullOrWhiteSpace(body.DeviceName))
        {
            _audit.TrackEvent(AuditEvents.DeniedPayloadInvalid, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId] = correlationId,
                [AuditEvents.Prop.Reason]        = "missing-required-fields",
            }, LogLevel.Warning);
            return new BadRequestObjectResult(new
            {
                status = "error",
                message = "deviceName, entraDeviceId, intuneDeviceId are required",
                correlationId
            });
        }

        if (!Guid.TryParse(body.EntraDeviceId, out _) || !Guid.TryParse(body.IntuneDeviceId, out _))
        {
            _audit.TrackEvent(AuditEvents.DeniedPayloadInvalid, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId] = correlationId,
                [AuditEvents.Prop.Reason]        = "invalid-guid",
            }, LogLevel.Warning);
            return new BadRequestObjectResult(new
            {
                status = "error",
                message = "entraDeviceId and intuneDeviceId must be GUIDs",
                correlationId
            });
        }

        // 4) Certificate <-> device binding (defends against IDOR)
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

            if (!string.Equals(boundDeviceId, body.EntraDeviceId, StringComparison.OrdinalIgnoreCase))
            {
                _audit.TrackEvent(AuditEvents.DeniedCertDeviceMismatch, new Dictionary<string, string>
                {
                    [AuditEvents.Prop.CorrelationId]  = correlationId,
                    [AuditEvents.Prop.BoundDeviceId]  = boundDeviceId,
                    [AuditEvents.Prop.EntraDeviceId]  = body.EntraDeviceId!,
                    [AuditEvents.Prop.CertThumbprint] = cert!.Thumbprint ?? "",
                }, LogLevel.Warning);
                return new ObjectResult(new { status = "denied",
                    message = "client certificate is not bound to the requested device",
                    correlationId })
                    { StatusCode = (int)HttpStatusCode.Forbidden };
            }
        }

        // 5) Enqueue. Allow operator-issued re-arm if BOTH the request asks for it
        //    AND the worker is configured to honour it (Idempotency:AllowForceRearm).
        //    This is a dev/testing escape hatch: in prod the header is silently ignored.
        var headerSaysForce = req.Headers.TryGetValue("X-Force-Rearm", out var fhv)
            && bool.TryParse(fhv.ToString(), out var fhb) && fhb;
        var allowForceRearm = bool.TryParse(_cfg["Idempotency:AllowForceRearm"], out var afr) && afr;
        var forceRearm      = headerSaysForce && allowForceRearm;

        var msg = new ActionRequestMessage
        {
            DeviceName = body.DeviceName!,
            EntraDeviceId = body.EntraDeviceId!,
            IntuneDeviceId = body.IntuneDeviceId!,
            CorrelationId = correlationId,
            ClientCertThumbprint = cert?.Thumbprint,
            RequestedAt = DateTimeOffset.UtcNow,
            ForceRearm = forceRearm,
        };

        var payload = JsonSerializer.Serialize(msg);
        var sbMessage = new ServiceBusMessage(payload)
        {
            ContentType = "application/json",
            MessageId = correlationId,
            CorrelationId = correlationId,
        };
        sbMessage.ApplicationProperties["actionType"] = "wipe";
        sbMessage.ApplicationProperties["entraDeviceId"] = msg.EntraDeviceId;
        sbMessage.ApplicationProperties["intuneDeviceId"] = msg.IntuneDeviceId;
        if (forceRearm) sbMessage.ApplicationProperties["forceRearm"] = true;
        await _sender.Sender.SendMessageAsync(sbMessage, ct);
        _log.LogDebug("Action request published: corr={Corr} device={Device} entra={Entra} intune={Intune} forceRearm={Force} queue={Queue}",
            correlationId, msg.DeviceName, msg.EntraDeviceId, msg.IntuneDeviceId, forceRearm, _sender.Sender.EntityPath);

        var acceptProps = new Dictionary<string, string>
        {
            [AuditEvents.Prop.CorrelationId]  = correlationId,
            [AuditEvents.Prop.DeviceName]     = msg.DeviceName,
            [AuditEvents.Prop.EntraDeviceId]  = msg.EntraDeviceId,
            [AuditEvents.Prop.IntuneDeviceId] = msg.IntuneDeviceId,
            [AuditEvents.Prop.CertThumbprint] = msg.ClientCertThumbprint ?? "",
        };
        if (forceRearm) acceptProps[AuditEvents.Prop.ForceRearm] = "true";
        // If the header was set but not allowed by config, leave a breadcrumb so
        // operators can see attempted bypasses.
        if (headerSaysForce && !allowForceRearm)
            acceptProps["forceRearmRequestedButDisabled"] = "true";
        _audit.TrackEvent(AuditEvents.RequestAccepted, acceptProps);

        return new AcceptedResult(string.Empty, new
        {
            status = "queued",
            message = "wipe request accepted and queued",
            correlationId
        });
    }
}
