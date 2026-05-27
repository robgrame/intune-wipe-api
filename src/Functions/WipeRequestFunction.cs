using System.Net;
using System.Text.Json;
using Azure.Storage.Queues;
using IntuneWipeApi.Models;
using IntuneWipeApi.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Functions;

/// <summary>
/// Public HTTP endpoint: validates the client (cert + payload + replay headers + cert↔device binding)
/// and enqueues a wipe request. All heavy lifting (group membership, Graph wipe) happens
/// asynchronously in WipeProcessorFunction.
/// </summary>
public sealed class WipeRequestFunction
{
    private readonly ClientCertValidator _cert;
    private readonly ReplayProtector _replay;
    private readonly QueueClient _queue;
    private readonly ILogger<WipeRequestFunction> _log;

    public WipeRequestFunction(ClientCertValidator cert, ReplayProtector replay,
        QueueClient queue, ILogger<WipeRequestFunction> log)
    {
        _cert = cert;
        _replay = replay;
        _queue = queue;
        _log = log;
    }

    [Function("WipeRequest")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "wipe")] HttpRequest req,
        CancellationToken ct)
    {
        // 0) App role guard: this function may run ONLY on the public web app.
        //    The Functions runtime "Disabled" setting does not reliably block HTTP
        //    triggers on dotnet-isolated, so fail closed here to keep the worker
        //    app's HTTP surface inert even if reached.
        if (!AppRoleGuard.IsAllowed(AppRoleGuard.Web))
        {
            _log.LogWarning("AUDIT denied reason=app-role-mismatch expected={Expected} actual={Actual}",
                AppRoleGuard.Web, AppRoleGuard.CurrentRole);
            return new ObjectResult(new { status = "gone", message = "endpoint not available on this host" })
                { StatusCode = (int)HttpStatusCode.Gone };
        }

        var correlationId = Guid.NewGuid().ToString("N");
        using var scope = _log.BeginScope(new Dictionary<string, object> { ["CorrelationId"] = correlationId });

        // 1) Replay protection (timestamp + nonce)
        var ts = req.Headers["X-Request-Timestamp"].ToString();
        var nonce = req.Headers["X-Request-Nonce"].ToString();
        var (replayOk, replayReason) = _replay.Validate(ts, nonce);
        if (!replayOk)
        {
            _log.LogWarning("AUDIT denied reason=replay-check {Reason} corr={Corr}", replayReason, correlationId);
            return new ObjectResult(new { status = "denied", message = replayReason, correlationId })
                { StatusCode = (int)HttpStatusCode.BadRequest };
        }

        // 2) Client certificate (chain validation + EKU + optional revocation)
        var (ok, cert, reason) = _cert.Validate(req.HttpContext);
        if (!ok)
        {
            _log.LogWarning("AUDIT denied reason=cert-validation {Reason} corr={Corr}", reason, correlationId);
            return new ObjectResult(new { status = "denied", message = $"client cert: {reason}", correlationId })
                { StatusCode = (int)HttpStatusCode.Unauthorized };
        }

        // 3) Payload
        WipeRequest? body;
        try
        {
            body = await JsonSerializer.DeserializeAsync<WipeRequest>(req.Body,
                new JsonSerializerOptions(JsonSerializerDefaults.Web), ct);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Invalid JSON");
            return new BadRequestObjectResult(new { status = "error", message = "invalid JSON", correlationId });
        }

        if (body is null
            || string.IsNullOrWhiteSpace(body.EntraDeviceId)
            || string.IsNullOrWhiteSpace(body.IntuneDeviceId)
            || string.IsNullOrWhiteSpace(body.DeviceName))
        {
            return new BadRequestObjectResult(new
            {
                status = "error",
                message = "deviceName, entraDeviceId, intuneDeviceId are required",
                correlationId
            });
        }

        if (!Guid.TryParse(body.EntraDeviceId, out _) || !Guid.TryParse(body.IntuneDeviceId, out _))
        {
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
            var boundDeviceId = _cert.GetBoundDeviceId(cert!);
            if (string.IsNullOrEmpty(boundDeviceId))
            {
                _log.LogWarning("AUDIT denied reason=binding-claim-missing thumb={Thumb} corr={Corr}",
                    cert!.Thumbprint, correlationId);
                return new ObjectResult(new { status = "denied",
                    message = "client certificate is missing the configured device-id binding claim",
                    correlationId })
                    { StatusCode = (int)HttpStatusCode.Unauthorized };
            }

            if (!string.Equals(boundDeviceId, body.EntraDeviceId, StringComparison.OrdinalIgnoreCase))
            {
                _log.LogWarning(
                    "AUDIT denied reason=cert-device-mismatch certBound={Bound} reqEntra={Req} thumb={Thumb} corr={Corr}",
                    boundDeviceId, body.EntraDeviceId, cert!.Thumbprint, correlationId);
                return new ObjectResult(new { status = "denied",
                    message = "client certificate is not bound to the requested device",
                    correlationId })
                    { StatusCode = (int)HttpStatusCode.Forbidden };
            }
        }

        // 5) Enqueue
        var msg = new WipeQueueMessage
        {
            DeviceName = body.DeviceName!,
            EntraDeviceId = body.EntraDeviceId!,
            IntuneDeviceId = body.IntuneDeviceId!,
            CorrelationId = correlationId,
            ClientCertThumbprint = cert?.Thumbprint,
            RequestedAt = DateTimeOffset.UtcNow
        };

        var payload = JsonSerializer.Serialize(msg);
        await _queue.SendMessageAsync(Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(payload)), ct);

        _log.LogInformation(
            "AUDIT wipe-request enqueued device={DeviceName} entra={EntraId} intune={IntuneId} cert={Thumb} corr={Corr}",
            msg.DeviceName, msg.EntraDeviceId, msg.IntuneDeviceId, msg.ClientCertThumbprint, correlationId);

        return new AcceptedResult(string.Empty, new
        {
            status = "queued",
            message = "wipe request accepted and queued",
            correlationId
        });
    }
}
