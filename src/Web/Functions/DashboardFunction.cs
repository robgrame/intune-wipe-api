using System.Net;
using System.Text.Json;
using IntuneDeviceActions.Dashboard;
using IntuneDeviceActions.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Functions;

/// <summary>
/// HTTP API consumed by the external operator portal (separate repo
/// <c>intune-wipe-web</c> hosted on <c>idactions-portal</c>) to expose
/// real-time pipeline state and operator remediation actions. This file
/// owns the JSON contract only — there is no UI here. Routes share the
/// same defense-in-depth as the ledger admin endpoint: Function key,
/// <c>Dashboard:Enabled</c> kill switch, mTLS, operator thumbprint
/// allow-list (falls back to <c>Idempotency:AdminCertThumbprints</c> so
/// an operator already trusted for reset reaches the dashboard with no
/// duplicate config key).
/// Routes:
/// <list type="bullet">
///   <item><c>GET  /api/dashboard/data</c> — overview snapshot (queues, ledger, diagnostics).</item>
///   <item><c>GET  /api/dashboard/trace?corr={correlationId}</c> — full lifecycle of a request + recommendation.</item>
///   <item><c>GET  /api/dashboard/device?q={hostname-or-intune-id}</c> — recent requests for a device.</item>
///   <item><c>POST /api/dashboard/actions/reset-ledger</c> — operator-driven remediation (body: <c>{"intuneDeviceId","reason"}</c>).</item>
/// </list>
/// </summary>
public sealed class DashboardFunction
{
    private readonly DashboardTelemetryService _telemetry;
    private readonly ClientCertValidator _cert;
    private readonly AuditService _audit;
    private readonly IConfiguration _cfg;
    private readonly ILogger<DashboardFunction> _log;
    private readonly HashSet<string> _allowedThumbprints;

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public DashboardFunction(DashboardTelemetryService telemetry, ClientCertValidator cert,
        AuditService audit, IConfiguration cfg, ILogger<DashboardFunction> log)
    {
        _telemetry = telemetry;
        _cert = cert;
        _audit = audit;
        _cfg = cfg;
        _log = log;
        var primary = cfg["Dashboard:AllowedCertThumbprints"] ?? string.Empty;
        var fallback = cfg["Idempotency:AdminCertThumbprints"] ?? string.Empty;
        _allowedThumbprints = (primary + ";" + fallback)
            .Split(new[] { ',', ';', '|' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(t => t.Replace(":", "").Replace(" ", "").ToUpperInvariant())
            .Where(t => t.Length > 0)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
    }

    [Function("Dashboard_Data")]
    public async Task<IActionResult> GetData(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "dashboard/data")] HttpRequest req,
        CancellationToken ct)
    {
        if (!Allowed(req, out var deny, out _)) return deny!;
        try
        {
            var snapshot = await _telemetry.SnapshotAsync(ct);
            return Json(snapshot);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Dashboard snapshot failed");
            return new ObjectResult(new { message = "snapshot failed", error = ex.GetType().Name })
                { StatusCode = (int)HttpStatusCode.InternalServerError };
        }
    }

    [Function("Dashboard_Trace")]
    public async Task<IActionResult> Trace(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "dashboard/trace")] HttpRequest req,
        CancellationToken ct)
    {
        if (!Allowed(req, out var deny, out _)) return deny!;
        var corr = req.Query["corr"].ToString();
        if (string.IsNullOrWhiteSpace(corr))
            return new BadRequestObjectResult(new { message = "query parameter 'corr' is required" });
        try
        {
            var trace = await _telemetry.TraceByCorrelationAsync(corr, ct);
            return Json(trace);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Dashboard trace failed for {Corr}", corr);
            return new ObjectResult(new { message = "trace failed", error = ex.GetType().Name })
                { StatusCode = (int)HttpStatusCode.InternalServerError };
        }
    }

    [Function("Dashboard_Device")]
    public async Task<IActionResult> Device(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "dashboard/device")] HttpRequest req,
        CancellationToken ct)
    {
        if (!Allowed(req, out var deny, out _)) return deny!;
        var q = req.Query["q"].ToString();
        if (string.IsNullOrWhiteSpace(q))
            return new BadRequestObjectResult(new { message = "query parameter 'q' is required (hostname or intuneDeviceId)" });
        var take = int.TryParse(req.Query["take"].ToString(), out var t) ? t : 25;
        try
        {
            var rows = await _telemetry.RecentByDeviceAsync(q, take, ct);
            return Json(new { device = q, rows });
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Dashboard device lookup failed for {Q}", q);
            return new ObjectResult(new { message = "device lookup failed", error = ex.GetType().Name })
                { StatusCode = (int)HttpStatusCode.InternalServerError };
        }
    }

    [Function("Dashboard_ResetLedger")]
    public async Task<IActionResult> ResetLedger(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "dashboard/actions/reset-ledger")] HttpRequest req,
        CancellationToken ct)
    {
        if (!Allowed(req, out var deny, out var callerThumb)) return deny!;
        // Reuse the admin kill switch — the dashboard's reset button is the
        // same destructive action as the admin REST endpoint, so it must
        // honour the same operator opt-in.
        if (!bool.TryParse(_cfg["Idempotency:AdminApiEnabled"], out var admin) || !admin)
            return new ObjectResult(new { message = "ledger reset is disabled (Idempotency:AdminApiEnabled=false)" })
                { StatusCode = (int)HttpStatusCode.Forbidden };

        ResetBody? body;
        try
        {
            body = await JsonSerializer.DeserializeAsync<ResetBody>(req.Body,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true }, ct);
        }
        catch (JsonException)
        {
            return new BadRequestObjectResult(new { message = "invalid JSON body" });
        }
        if (body is null || string.IsNullOrWhiteSpace(body.IntuneDeviceId) || string.IsNullOrWhiteSpace(body.Reason))
            return new BadRequestObjectResult(new { message = "'intuneDeviceId' and 'reason' are required" });

        try
        {
            var (archive, prevCorr) = await _telemetry.ResetLedgerAsync(body.IntuneDeviceId!, callerThumb!, body.Reason!, ct);
            _audit.TrackEvent("ledger.reset.manual.dashboard", new Dictionary<string, string>
            {
                ["intuneDeviceId"] = body.IntuneDeviceId!,
                ["previousCorrelationId"] = prevCorr,
                ["adminReason"] = body.Reason!,
                ["actor"] = callerThumb!,
                ["archiveBlobName"] = archive,
                ["source"] = "cruscotto-ui",
            });
            return new OkObjectResult(new { status = "reset", archive, previousCorrelationId = prevCorr });
        }
        catch (InvalidOperationException ex)
        {
            return new NotFoundObjectResult(new { message = ex.Message });
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Dashboard ledger reset failed for {Id}", body.IntuneDeviceId);
            return new ObjectResult(new { message = "reset failed", error = ex.GetType().Name })
                { StatusCode = (int)HttpStatusCode.InternalServerError };
        }
    }

    private sealed record ResetBody(string? IntuneDeviceId, string? Reason);

    // ─── plumbing ────────────────────────────────────────────────────────────

    private static ContentResult Json(object value) => new()
    {
        Content = JsonSerializer.Serialize(value, JsonOpts),
        ContentType = "application/json; charset=utf-8",
        StatusCode = (int)HttpStatusCode.OK,
    };

    private bool Allowed(HttpRequest req, out IActionResult? deny, out string? callerThumbprint)
    {
        callerThumbprint = null;
        if (!bool.TryParse(_cfg["Dashboard:Enabled"], out var enabled) || !enabled)
        {
            deny = new ObjectResult(new { message = "dashboard disabled" })
                { StatusCode = (int)HttpStatusCode.Forbidden };
            return false;
        }
        var (certOk, cert, certReason) = _cert.Validate(req.HttpContext);
        if (!certOk || cert is null)
        {
            deny = new UnauthorizedObjectResult(new { message = "client certificate required", reason = certReason });
            return false;
        }
        if (_allowedThumbprints.Count == 0)
        {
            deny = new ObjectResult(new { message = "no operator certificates configured" })
                { StatusCode = (int)HttpStatusCode.Forbidden };
            return false;
        }
        var thumb = cert.Thumbprint?.ToUpperInvariant() ?? string.Empty;
        if (!_allowedThumbprints.Contains(thumb))
        {
            _log.LogWarning("Dashboard access denied: thumbprint {Thumb} not in allow-list", thumb);
            deny = new ObjectResult(new { message = "operator certificate not authorized" })
                { StatusCode = (int)HttpStatusCode.Forbidden };
            return false;
        }
        callerThumbprint = thumb;
        deny = null;
        return true;
    }
}
