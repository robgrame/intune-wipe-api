using System.Net;
using System.Text.Json;
using IntuneDeviceActions.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Functions;

/// <summary>
/// Operator-facing endpoints to inspect and manually reset the per-device
/// idempotency ledger. Used by SecOps in the rare case the automatic re-arm
/// logic in <see cref="ActionIdempotencyService"/> intentionally blocks a re-issue
/// (e.g. <c>keepEnrollmentData=true</c> with the previous wipe never observed
/// terminal by the tracker) and the device must be unblocked immediately.
/// <para>
/// Routes:
/// <list type="bullet">
///   <item><c>GET  /api/actions/ledger/{intuneDeviceId}</c></item>
///   <item><c>POST /api/actions/ledger/{intuneDeviceId}/reset</c></item>
/// </list>
/// </para>
/// <para>
/// Authorization (banking-grade — defense in depth):
/// <list type="number">
///   <item>Function-level key on the HTTP route;</item>
///   <item><c>Idempotency:AdminApiEnabled=true</c> kill switch (off by default);</item>
///   <item><b>mTLS</b> — the App Service plan is configured with
///         <c>clientCertMode: Required</c> and <b>no</b>
///         <c>clientCertExclusionPaths</c>, so the admin surface receives the
///         same client-certificate handshake as device traffic;</item>
///   <item><b>Operator allow-list</b> — the caller's leaf certificate thumbprint
///         must appear in <c>Idempotency:AdminCertThumbprints</c> (CSV). This
///         is the *operator* trust list (distinct from
///         <c>ClientCert:AllowedLeafThumbprints</c> used for device-cert
///         pinning), so SecOps can be issued dedicated client certs (smartcard /
///         HSM-backed) without granting every device cert admin power.</item>
/// </list>
/// The audit <c>actor</c> field is bound to the <b>verified</b> cert thumbprint
/// (not to the self-reported body field) — the body's <c>actor</c> is retained
/// only as free-text operator context alongside the cryptographically anchored
/// identity, so a leaked function key cannot impersonate an admin in the
/// non-repudiable ledger reset audit trail.
/// </para>
/// <para>
/// These endpoints are only deployed to the Web Function App (artifact isolation —
/// the Proc and capability assemblies do not contain this Function class).
/// </para>
/// </summary>
public sealed class ActionLedgerAdminFunction
{
    private readonly ActionIdempotencyService _ledger;
    private readonly ActionStatusTracker _tracker;
    private readonly AuditService _audit;
    private readonly ClientCertValidator _cert;
    private readonly IConfiguration _cfg;
    private readonly ILogger<ActionLedgerAdminFunction> _log;
    private readonly HashSet<string> _adminThumbprints;

    public ActionLedgerAdminFunction(ActionIdempotencyService ledger, ActionStatusTracker tracker,
        AuditService audit, ClientCertValidator cert, IConfiguration cfg, ILogger<ActionLedgerAdminFunction> log)
    {
        _ledger = ledger;
        _tracker = tracker;
        _audit = audit;
        _cert = cert;
        _cfg = cfg;
        _log = log;
        _adminThumbprints = (cfg["Idempotency:AdminCertThumbprints"] ?? string.Empty)
            .Split(new[] { ',', ';', '|' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(NormalizeThumbprint)
            .Where(t => t.Length > 0)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>
    /// GET /api/actions/ledger/{intuneDeviceId} — returns the current ledger
    /// entry joined with the most recent tracker snapshot (so operators see one
    /// page with everything needed to decide whether a manual reset is warranted).
    /// </summary>
    [Function("ActionLedger_Get")]
    public async Task<IActionResult> Get(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "actions/ledger/{intuneDeviceId}")]
        HttpRequest req, string intuneDeviceId, CancellationToken ct)
    {
        if (!Allowed(req, out var deny, out _)) return deny!;

        var entry = await _ledger.GetEntryAsync(intuneDeviceId, ct);
        if (entry is null)
            return new NotFoundObjectResult(new { intuneDeviceId, ledger = (object?)null });

        ActionStatusSnapshot? snap = null;
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
                maxActionsPerDevicePerDay = _ledger.MaxActionsPerDevicePerDay,
                rearmGracePeriodHours   = _ledger.RearmGracePeriodHours,
                allowForceRearm         = _ledger.AllowForceRearm,
            }
        });
    }

    /// <summary>
    /// POST /api/actions/ledger/{intuneDeviceId}/reset — archives the current
    /// blob under <c>_archive/</c> and removes the live entry. Body must be
    /// JSON: <c>{ "reason": "..." }</c> (mandatory) plus optional
    /// <c>{ "actor": "alice@contoso.com" }</c> free-text operator context. The
    /// authoritative audited <c>actor</c> is the SHA-1 thumbprint of the
    /// verified mTLS client certificate.
    /// </summary>
    [Function("ActionLedger_Reset")]
    public async Task<IActionResult> Reset(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "actions/ledger/{intuneDeviceId}/reset")]
        HttpRequest req, string intuneDeviceId, CancellationToken ct)
    {
        if (!Allowed(req, out var deny, out var callerThumb)) return deny!;

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
        if (body is null || string.IsNullOrWhiteSpace(body.Reason))
        {
            return new BadRequestObjectResult(new { message = "'reason' is required in the JSON body" });
        }

        try
        {
            // Pass the verified cert thumbprint (not the body claim) as the
            // ledger-side actor so the archived blob's metadata also carries the
            // cryptographically anchored identity.
            var (previous, archivePath) = await _ledger.ResetAsync(intuneDeviceId, callerThumb!, body.Reason!, ct);
            _audit.TrackEvent(AuditEvents.LedgerResetManual, new Dictionary<string, string>
            {
                [AuditEvents.Prop.IntuneDeviceId]     = intuneDeviceId,
                [AuditEvents.Prop.CorrelationId]      = previous.CorrelationId,
                [AuditEvents.Prop.ActionSequence]     = previous.ActionSequence.ToString(),
                [AuditEvents.Prop.AdminReason]        = body.Reason!,
                [AuditEvents.Prop.Actor]              = callerThumb!,
                ["actorClaimed"]                      = body.Actor ?? string.Empty,
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
    /// Defense in depth: (1) kill switch <c>Idempotency:AdminApiEnabled</c>,
    /// (2) mTLS client cert validation, (3) operator thumbprint allow-list.
    /// On success returns the verified caller thumbprint so the handler can
    /// bind it to the audit trail.
    /// </summary>
    private bool Allowed(HttpRequest req, out IActionResult? deny, out string? callerThumbprint)
    {
        callerThumbprint = null;

        if (!bool.TryParse(_cfg["Idempotency:AdminApiEnabled"], out var enabled) || !enabled)
        {
            _audit.TrackEvent(AuditEvents.LedgerResetDenied,
                new Dictionary<string, string> { ["reason"] = "admin-api-disabled" }, LogLevel.Warning);
            deny = new ObjectResult(new { message = "admin API disabled" }) { StatusCode = (int)HttpStatusCode.Forbidden };
            return false;
        }

        // mTLS — fail-closed if the caller didn't present a valid client cert.
        var (certOk, cert, certReason) = _cert.Validate(req.HttpContext);
        if (!certOk || cert is null)
        {
            _audit.TrackEvent(AuditEvents.LedgerResetDenied,
                new Dictionary<string, string> { ["reason"] = $"cert:{certReason ?? "missing"}" }, LogLevel.Warning);
            deny = new UnauthorizedObjectResult(new { message = "client certificate required", reason = certReason });
            return false;
        }

        var thumb = NormalizeThumbprint(cert.Thumbprint ?? string.Empty);
        if (_adminThumbprints.Count == 0)
        {
            // Fail-closed: no operator allow-list configured means no operator
            // is currently authorized. Refuse rather than silently fall back
            // to "any valid mTLS cert can reset" — that would let every
            // managed device reset every other device's ledger.
            _audit.TrackEvent(AuditEvents.LedgerResetDenied,
                new Dictionary<string, string> { ["reason"] = "admin-allowlist-empty", [AuditEvents.Prop.CertThumbprint] = thumb }, LogLevel.Warning);
            deny = new ObjectResult(new { message = "admin operator allow-list not configured" }) { StatusCode = (int)HttpStatusCode.Forbidden };
            return false;
        }
        if (!_adminThumbprints.Contains(thumb))
        {
            _audit.TrackEvent(AuditEvents.LedgerResetDenied,
                new Dictionary<string, string> { ["reason"] = "cert-not-in-admin-allowlist", [AuditEvents.Prop.CertThumbprint] = thumb }, LogLevel.Warning);
            deny = new ObjectResult(new { message = "caller certificate not authorized for admin operations" }) { StatusCode = (int)HttpStatusCode.Forbidden };
            return false;
        }

        callerThumbprint = thumb;
        deny = null;
        return true;
    }

    private static string NormalizeThumbprint(string t)
        => new string((t ?? string.Empty).Where(char.IsLetterOrDigit).ToArray()).ToUpperInvariant();

    private sealed class ResetBody
    {
        public string? Reason { get; set; }
        public string? Actor { get; set; }
    }
}
