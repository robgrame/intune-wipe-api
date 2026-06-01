using System.Net.Http.Headers;
using System.Net.Http.Json;
using IntuneWipeApi.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Actions.Runners;

/// <summary>
/// <see cref="IActionRunner"/> registered on the worker role for the
/// <c>wipe-runbook</c> action type. Instead of forwarding to a Function App
/// queue (like <see cref="WipeForwardingRunner"/>), it POSTs the dispatch
/// envelope to an Azure Automation Runbook webhook — the runbook
/// <c>Invoke-DeviceWipe</c> (PowerShell 7.2) becomes the executor.
/// </summary>
/// <remarks>
/// <para>
/// This proves the plug-in model: the SAME core (HTTP front-end, dispatcher,
/// queues, audit) drives two completely different runtimes (dotnet-isolated
/// on Functions vs. PowerShell on Automation) for the SAME conceptual
/// capability, selected at producer time via <c>ActionType</c> on the
/// envelope.
/// </para>
/// <para>
/// Configuration key: <c>WipeRunbook:WebhookUrl</c> — the webhook URI
/// generated for the runbook. Treat as a secret (Key Vault reference
/// recommended in production).
/// </para>
/// </remarks>
public sealed class WipeRunbookForwardingRunner : IActionRunner
{
    public string Type => "wipe-runbook";

    private static readonly HttpClient Http = new();

    private readonly string _webhookUrl;
    private readonly AuditService _audit;
    private readonly ILogger<WipeRunbookForwardingRunner> _log;

    public WipeRunbookForwardingRunner(IConfiguration cfg, AuditService audit,
        ILogger<WipeRunbookForwardingRunner> log)
    {
        _webhookUrl = cfg["WipeRunbook:WebhookUrl"] ?? string.Empty;
        _audit = audit;
        _log = log;
    }

    public async Task RunAsync(ActionDispatchMessage envelope, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(_webhookUrl))
        {
            // Permanent config error — surface as failure so envelope.FailOnError
            // can route to poison instead of looping.
            throw new InvalidOperationException(
                "WipeRunbook:WebhookUrl is not configured on this app. Cannot forward to runbook.");
        }

        // Automation webhooks accept ANY POST body and expose it on
        // $WebhookData.RequestBody as a JSON string. The runbook deserialises
        // it back into the same ActionDispatchMessage shape used by the
        // Function App path — no wire-format change.
        var resp = await Http.PostAsJsonAsync(_webhookUrl, envelope, ct);
        var status = (int)resp.StatusCode;

        if (!resp.IsSuccessStatusCode)
        {
            var body = await resp.Content.ReadAsStringAsync(ct);
            throw new InvalidOperationException(
                $"Automation webhook POST failed: HTTP {status} body={body}");
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
        });

        _log.LogInformation(
            "Forwarded action '{ActionType}' for {Device} to Automation runbook webhook (HTTP {Status}, corr={Corr})",
            envelope.ActionType, envelope.DeviceName, status, envelope.CorrelationId);
    }
}
