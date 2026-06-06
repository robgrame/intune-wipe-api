using System.Net.Http.Json;
using IntuneDeviceActions.Services;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Actions;

/// <summary>
/// Generic data-driven <see cref="IActionRunner"/> that forwards a dispatch
/// envelope to an Azure Automation Runbook webhook over HTTPS.
/// </summary>
/// <remarks>
/// <para>
/// One instance per <c>ActionType</c> is registered automatically by
/// <see cref="RunbookBridgeExtensions.AddRunbookBridgeRunners"/> from the
/// <c>RunbookBridge:Routes:&lt;actionType&gt; = &lt;webhookUrl&gt;</c>
/// configuration section (typically sourced from Azure App Configuration).
/// </para>
/// <para>
/// This is the preferred way to bridge a capability to a PowerShell runbook:
/// it requires zero new code per capability and zero changes to the core
/// (Shared / Web / Proc / existing capability projects). Adding a new
/// runbook-backed capability is reduced to:
/// </para>
/// <list type="number">
///   <item>publish the <c>.ps1</c> runbook and create a webhook on the Automation Account;</item>
///   <item>add a single App Configuration key:
///         <c>RunbookBridge:Routes:my-action = https://&lt;webhook-uri&gt;</c>;</item>
///   <item>restart the Proc app (Flex Consumption cold-start is sufficient) so the
///         new route is picked up at host build time.</item>
/// </list>
/// <para>
/// The webhook URL is treated as a secret — Key Vault references in App
/// Configuration are recommended for production.
/// </para>
/// </remarks>
public sealed class RunbookWebhookRunner : IActionRunner
{
    // One process-wide shared HttpClient is the documented best practice
    // (avoids socket exhaustion). Tests inject a custom HttpMessageHandler.
    private static readonly HttpClient SharedHttp = new();

    private readonly string _actionType;
    private readonly string _webhookUrl;
    private readonly AuditService _audit;
    private readonly ILogger<RunbookWebhookRunner> _log;
    private readonly HttpClient _http;

    /// <summary>Returns the <c>ActionType</c> this runner handles.</summary>
    public string Type => _actionType;

    /// <summary>Production constructor — uses the shared <see cref="HttpClient"/>.</summary>
    public RunbookWebhookRunner(
        string actionType,
        string webhookUrl,
        AuditService audit,
        ILogger<RunbookWebhookRunner> log)
        : this(actionType, webhookUrl, audit, log, httpHandler: null)
    {
    }

    /// <summary>Test-only overload that lets callers inject a custom <see cref="HttpMessageHandler"/>.</summary>
    public RunbookWebhookRunner(
        string actionType,
        string webhookUrl,
        AuditService audit,
        ILogger<RunbookWebhookRunner> log,
        HttpMessageHandler? httpHandler)
    {
        if (string.IsNullOrWhiteSpace(actionType))
            throw new ArgumentException("actionType is required", nameof(actionType));
        if (string.IsNullOrWhiteSpace(webhookUrl))
            throw new ArgumentException("webhookUrl is required", nameof(webhookUrl));
        if (!Uri.TryCreate(webhookUrl, UriKind.Absolute, out var parsed) || parsed.Scheme != Uri.UriSchemeHttps)
            throw new ArgumentException($"webhookUrl must be an absolute https:// URL (got '{webhookUrl}')", nameof(webhookUrl));

        _actionType = actionType;
        _webhookUrl = webhookUrl;
        _audit = audit;
        _log = log;
        _http = httpHandler is null ? SharedHttp : new HttpClient(httpHandler);
    }

    public async Task RunAsync(ActionDispatchMessage envelope, CancellationToken ct)
    {
        // Redact the webhook URL for logging — keep only host + first 32 chars
        // of the path so we don't leak the SAS token in the query string.
        string webhookHost = "(unknown)", pathHead = string.Empty;
        try
        {
            var u = new Uri(_webhookUrl);
            webhookHost = u.Host;
            pathHead = u.AbsolutePath.Length > 32 ? u.AbsolutePath[..32] + "…" : u.AbsolutePath;
        }
        catch
        {
            // Already validated in the constructor — ignore.
        }

        _log.LogDebug(
            "RunbookWebhookRunner POST: corr={Corr} type={Type} host={Host} path={Path}",
            envelope.CorrelationId, _actionType, webhookHost, pathHead);

        // Automation webhooks accept any POST body and expose it on
        // $WebhookData.RequestBody as a JSON string. We send the envelope
        // as-is so the runbook deserialises it back into the same shape
        // used by the Function App consumers — no wire-format change.
        HttpResponseMessage resp;
        try
        {
            resp = await _http.PostAsJsonAsync(_webhookUrl, envelope, ct);
        }
        catch (Exception ex)
        {
            _audit.TrackEvent(AuditEvents.ActionDispatchRunnerFailed, ex, new Dictionary<string, string>
            {
                [AuditEvents.Prop.CorrelationId]    = envelope.CorrelationId,
                [AuditEvents.Prop.ActionType]       = envelope.ActionType,
                [AuditEvents.Prop.ExceptionType]    = ex.GetType().FullName ?? "(unknown)",
                [AuditEvents.Prop.ExceptionMessage] = ex.Message ?? string.Empty,
                ["targetApp"]                       = "automation-runbook",
                ["webhookHost"]                     = webhookHost,
            }, LogLevel.Error);
            throw;
        }

        var status = (int)resp.StatusCode;
        _log.LogDebug(
            "RunbookWebhookRunner response: corr={Corr} httpStatus={Status} reason={Reason}",
            envelope.CorrelationId, status, resp.ReasonPhrase ?? "(none)");

        if (!resp.IsSuccessStatusCode)
        {
            var body = await resp.Content.ReadAsStringAsync(ct);
            throw new InvalidOperationException(
                $"Automation webhook POST failed for actionType='{_actionType}': HTTP {status} body={body}");
        }

        _audit.TrackEvent(AuditEvents.ActionForwarded, new Dictionary<string, string>
        {
            [AuditEvents.Prop.CorrelationId]  = envelope.CorrelationId,
            [AuditEvents.Prop.ActionType]     = envelope.ActionType,
            [AuditEvents.Prop.DeviceName]     = envelope.DeviceName,
            [AuditEvents.Prop.EntraDeviceId]  = envelope.EntraDeviceId,
            [AuditEvents.Prop.IntuneDeviceId] = envelope.IntuneDeviceId,
            ["targetApp"]                     = "automation-runbook",
            ["webhookHttpStatus"]             = status.ToString(),
            ["webhookHost"]                   = webhookHost,
        });

        _log.LogInformation(
            "Forwarded actionType='{Type}' for {Device} → Automation runbook webhook (HTTP {Status}, corr={Corr})",
            _actionType, envelope.DeviceName, status, envelope.CorrelationId);
    }
}
