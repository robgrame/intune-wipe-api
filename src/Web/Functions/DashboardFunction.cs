using System.Net;
using System.Reflection;
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
/// Operator "cruscotto" — a single-page flow-of-energy view of the pipeline.
/// Two routes (both behind the same mTLS plan + Function key + operator
/// thumbprint allow-list as the ledger admin endpoint):
/// <list type="bullet">
///   <item><c>GET /api/dashboard</c> — returns the static HTML page embedded
///         as an assembly resource. The page polls the data endpoint every
///         few seconds and re-renders the SVG topology with health colors
///         and animated message-flow particles.</item>
///   <item><c>GET /api/dashboard/data</c> — returns the JSON snapshot
///         produced by <see cref="DashboardTelemetryService"/>.</item>
/// </list>
/// <para>
/// Auth (same defense-in-depth as ActionLedgerAdminFunction):
/// <list type="number">
///   <item>Function key on the route;</item>
///   <item><c>Dashboard:Enabled=true</c> kill switch (off by default);</item>
///   <item>mTLS — the Web plan is <c>clientCertMode: Required</c> with no
///         exclusion paths, so the dashboard inherits the same client-cert
///         requirement as device traffic;</item>
///   <item>Operator allow-list — caller cert thumbprint must appear in
///         <c>Dashboard:AllowedCertThumbprints</c> OR (fallback)
///         <c>Idempotency:AdminCertThumbprints</c>. This lets operators
///         already trusted for ledger reset reach the dashboard without a
///         duplicate config key, while leaving room to scope dashboard-only
///         viewers separately if desired.</item>
/// </list>
/// </para>
/// </summary>
public sealed class DashboardFunction
{
    private readonly DashboardTelemetryService _telemetry;
    private readonly ClientCertValidator _cert;
    private readonly IConfiguration _cfg;
    private readonly ILogger<DashboardFunction> _log;
    private readonly HashSet<string> _allowedThumbprints;

    private static readonly Lazy<string> CachedHtml = new(LoadEmbeddedHtml);
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public DashboardFunction(DashboardTelemetryService telemetry, ClientCertValidator cert,
        IConfiguration cfg, ILogger<DashboardFunction> log)
    {
        _telemetry = telemetry;
        _cert = cert;
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

    [Function("Dashboard_Page")]
    public IActionResult GetPage(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "dashboard")] HttpRequest req)
    {
        if (!Allowed(req, out var deny)) return deny!;
        return new ContentResult
        {
            Content = CachedHtml.Value,
            ContentType = "text/html; charset=utf-8",
            StatusCode = (int)HttpStatusCode.OK,
        };
    }

    [Function("Dashboard_Data")]
    public async Task<IActionResult> GetData(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "dashboard/data")] HttpRequest req,
        CancellationToken ct)
    {
        if (!Allowed(req, out var deny)) return deny!;
        try
        {
            var snapshot = await _telemetry.SnapshotAsync(ct);
            // Serialize manually to honour camelCase + skip-null without
            // requiring callers to tweak the function host's defaults.
            var json = JsonSerializer.Serialize(snapshot, JsonOpts);
            return new ContentResult
            {
                Content = json,
                ContentType = "application/json; charset=utf-8",
                StatusCode = (int)HttpStatusCode.OK,
            };
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Dashboard snapshot failed");
            return new ObjectResult(new { message = "snapshot failed", error = ex.GetType().Name })
            {
                StatusCode = (int)HttpStatusCode.InternalServerError,
            };
        }
    }

    private bool Allowed(HttpRequest req, out IActionResult? deny)
    {
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

        // Operator allow-list (covers both dashboard-only and ledger-admin
        // thumbprints — see constructor).
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

        deny = null;
        return true;
    }

    private static string LoadEmbeddedHtml()
    {
        var asm = typeof(DashboardFunction).Assembly;
        // Embedded resource name follows <RootNamespace>.<Path>.<File> with
        // path separators replaced by '.'. RootNamespace is IntuneDeviceActions
        // (see Web .csproj), folder is Dashboard, file is dashboard.html.
        var resourceName = asm.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith(".dashboard.html", StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException(
                "dashboard.html not found among embedded resources. " +
                "Did you add <EmbeddedResource Include=\"Dashboard\\dashboard.html\" /> to the Web .csproj?");
        using var stream = asm.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"Cannot open embedded resource {resourceName}");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}
