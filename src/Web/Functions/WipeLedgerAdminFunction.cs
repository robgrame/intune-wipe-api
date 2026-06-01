using System.Net;
using System.Text.Json;
using IntuneWipeApi.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Functions;

/// <summary>
/// Operator-facing endpoints to inspect and manually reset the per-device
/// idempotency ledger. Used by SecOps in the rare case the automatic re-arm
/// logic in <see cref="IdempotencyService"/> intentionally blocks a re-wipe
/// (e.g. <c>keepEnrollmentData=true</c> with the previous wipe never observed
/// terminal by the tracker) and the device must be unblocked immediately.
/// <para>
/// Routes (note: <c>/api/admin/*</c> is reserved by the Functions runtime, so
/// these live under <c>/api/wipe-ledger/*</c>):
/// <list type="bullet">
///   <item><c>GET  /api/wipe-ledger/{intuneDeviceId}</c></item>
///   <item><c>POST /api/wipe-ledger/{intuneDeviceId}/reset</c></item>
/// </list>
/// </para>
/// <para>
/// Authorization: function-level key (per the rest of the API). On top of
/// the function-key barrier, the endpoints are gated by
/// <c>Idempotency:AdminApiEnabled=true</c> in app settings — set false in
/// production to keep them off by default. These endpoints are only deployed
/// to the Web Function App (artifact isolation — the Proc and Wipe assemblies
/// do not contain this Function class).
/// </para>
/// </summary>
public sealed class WipeLedgerAdminFunction
{
    private readonly IdempotencyService _ledger;
    private readonly WipeStatusTracker _tracker;
    private readonly AuditService _audit;
    private readonly IConfiguration _cfg;
    private readonly ILogger<WipeLedgerAdminFunction> _log;

    public WipeLedgerAdminFunction(IdempotencyService ledger, WipeStatusTracker tracker,
        AuditService audit, IConfiguration cfg, ILogger<WipeLedgerAdminFunction> log)
    {
        _ledger = ledger;
        _tracker = tracker;
        _audit = audit;
        _cfg = cfg;
        _log = log;
    }

    /// <summary>
    /// GET /api/wipe-ledger/{intuneDeviceId} — returns the current ledger
    /// entry joined with the most recent tracker snapshot (so operators see one
    /// page with everything needed to decide whether a manual reset is warranted).
    /// </summary>
    [Function("WipeLedger_Get")]
    public async Task<IActionResult> Get(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "wipe-ledger/{intuneDeviceId}")]
        HttpRequest req, string intuneDeviceId, CancellationToken ct)
    {
        if (!Allowed(req, out var deny)) return deny!;

        var entry = await _ledger.GetEntryAsync(intuneDeviceId, ct);
        if (entry is null)
            return new NotFoundObjectResult(new { intuneDeviceId, ledger = (object?)null });

        WipeStatusSnapshot? snap = null;
        try
        {
            if (_tracker.IsEnabled && !string.IsNullOrEmpty(entry.CorrelationId))
                snap = await _tracker.GetStatusAsync(entry.CorrelationId, ct);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Tracker lookup failed for {Corr}", entry.CorrelationId);
        }

        return new OkObjectResult(new
        {
            intuneDeviceId,
            ledger = entry,
            tracker = snap,
            config = new
            {
                maxWipesPerDevicePerDay = _ledger.MaxWipesPerDay,
                rearmGracePeriodHours   = _ledger.RearmGracePeriodHours,
                allowForceRearm         = _ledger.AllowForceRearm,
            }
        });
    }

    /// <summary>
    /// POST /api/wipe-ledger/{intuneDeviceId}/reset — archives the current
    /// blob under <c>_archive/</c> and removes the live entry. Body must be
    /// JSON: <c>{ "reason": "...", "actor": "alice@contoso.com" }</c>. Both fields
    /// are mandatory so the audit trail is meaningful.
    /// </summary>
    [Function("WipeLedger_Reset")]
    public async Task<IActionResult> Reset(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "wipe-ledger/{intuneDeviceId}/reset")]
        HttpRequest req, string intuneDeviceId, CancellationToken ct)
    {
        if (!Allowed(req, out var deny)) return deny!;

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
        if (body is null || string.IsNullOrWhiteSpace(body.Reason) || string.IsNullOrWhiteSpace(body.Actor))
        {
            return new BadRequestObjectResult(new { message = "'actor' and 'reason' are required in the JSON body" });
        }

        try
        {
            var (previous, archivePath) = await _ledger.ResetAsync(intuneDeviceId, body.Actor!, body.Reason!, ct);
            _audit.TrackEvent(AuditEvents.LedgerResetManual, new Dictionary<string, string>
            {
                [AuditEvents.Prop.IntuneDeviceId]     = intuneDeviceId,
                [AuditEvents.Prop.CorrelationId]      = previous.CorrelationId,
                [AuditEvents.Prop.WipeSequence]       = previous.WipeSequence.ToString(),
                [AuditEvents.Prop.AdminReason]        = body.Reason!,
                [AuditEvents.Prop.Actor]              = body.Actor!,
                [AuditEvents.Prop.AdminCallerIp]      = req.HttpContext.Connection.RemoteIpAddress?.ToString() ?? "",
                [AuditEvents.Prop.ArchiveBlobName]    = archivePath,
            });
            return new OkObjectResult(new { status = "reset", archive = archivePath, previousCorrelationId = previous.CorrelationId });
        }
        catch (InvalidOperationException ex)
        {
            return new NotFoundObjectResult(new { message = ex.Message });
        }
    }

    /// <summary>
    /// Per-environment kill switch (<c>Idempotency:AdminApiEnabled</c>). Failures are audited.
    /// </summary>
    private bool Allowed(HttpRequest req, out IActionResult? deny)
    {
        if (!bool.TryParse(_cfg["Idempotency:AdminApiEnabled"], out var enabled) || !enabled)
        {
            _audit.TrackEvent(AuditEvents.LedgerResetDenied,
                new Dictionary<string, string> { ["reason"] = "admin-api-disabled" }, LogLevel.Warning);
            deny = new ObjectResult(new { message = "admin API disabled" }) { StatusCode = (int)HttpStatusCode.Forbidden };
            return false;
        }
        deny = null;
        return true;
    }

    private sealed class ResetBody
    {
        public string? Reason { get; set; }
        public string? Actor { get; set; }
    }
}
