using System.Net;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Capabilities.Rename.Services;

/// <summary>
/// <see cref="ICustomerRenameClient"/> over <see cref="HttpClient"/>. Reads
/// the endpoint URL and an optional auth header from configuration:
/// <list type="bullet">
///   <item><c>Rename:Endpoint</c> — absolute URL (required). May contain the
///         <c>{serial}</c> placeholder; when absent the serial is URL-encoded
///         and appended as a path segment.</item>
///   <item><c>Rename:AuthHeaderName</c> — header name. Default <c>X-Api-Key</c>. Empty disables.</item>
///   <item><c>Rename:AuthHeaderValue</c> — header value. Recommended: Key Vault reference.</item>
///   <item><c>Rename:NewNameJsonPath</c> — name of the response property holding
///         the resolved hostname. Default <c>newName</c>.</item>
///   <item><c>Rename:TimeoutSeconds</c> — request timeout. Default <c>30</c>.</item>
/// </list>
///
/// Response contract on 2xx (default <c>NewNameJsonPath</c>):
/// <code>{ "newName": "WS-CONTOSO-101" }</code>
/// </summary>
public sealed class HttpCustomerRenameClient : ICustomerRenameClient
{
    private readonly HttpClient _http;
    private readonly IConfiguration _cfg;
    private readonly ILogger<HttpCustomerRenameClient> _log;

    public HttpCustomerRenameClient(HttpClient http, IConfiguration cfg, ILogger<HttpCustomerRenameClient> log)
    {
        _http = http;
        _cfg = cfg;
        _log = log;

        // Only set the timeout once — HttpClient.Timeout is per-instance and
        // throws if mutated after a request. IHttpClientFactory hands us a
        // fresh typed-client per scope so this branch is safe.
        if (_http.Timeout == TimeSpan.FromSeconds(100)) // default
        {
            var seconds = int.TryParse(_cfg["Rename:TimeoutSeconds"], out var t) && t > 0 ? t : 30;
            _http.Timeout = TimeSpan.FromSeconds(seconds);
        }
    }

    public async Task<RenameLookupOutcome> ResolveNewNameAsync(string serialNumber, string correlationId, CancellationToken ct)
    {
        var template = _cfg["Rename:Endpoint"]
            ?? throw new InvalidOperationException(
                "Rename:Endpoint is not configured (must be the customer-internal CMDB lookup URL).");

        var url = BuildUrl(template, serialNumber);
        using var req = new HttpRequestMessage(HttpMethod.Get, url);

        var headerName  = _cfg["Rename:AuthHeaderName"]  ?? "X-Api-Key";
        var headerValue = _cfg["Rename:AuthHeaderValue"];
        if (!string.IsNullOrWhiteSpace(headerName) && !string.IsNullOrWhiteSpace(headerValue))
        {
            req.Headers.TryAddWithoutValidation(headerName, headerValue);
        }
        if (!string.IsNullOrWhiteSpace(correlationId))
        {
            req.Headers.TryAddWithoutValidation("X-Correlation-Id", correlationId);
        }
        req.Headers.Accept.ParseAdd("application/json");

        HttpResponseMessage resp;
        try
        {
            resp = await _http.SendAsync(req, HttpCompletionOption.ResponseContentRead, ct);
        }
        catch (TaskCanceledException tcex) when (!ct.IsCancellationRequested)
        {
            _log.LogWarning(tcex, "Customer rename lookup timed out (corr={Corr}, serial={Serial})", correlationId, serialNumber);
            return new RenameLookupOutcome(RenameLookupOutcome.Kind.Transient, 0, "timeout");
        }
        catch (HttpRequestException hrex)
        {
            _log.LogWarning(hrex, "Customer rename lookup unreachable (corr={Corr}, serial={Serial})", correlationId, serialNumber);
            return new RenameLookupOutcome(RenameLookupOutcome.Kind.Transient, 0, $"network:{hrex.Message}");
        }

        var status = (int)resp.StatusCode;
        if (resp.IsSuccessStatusCode)
        {
            string body;
            try { body = await resp.Content.ReadAsStringAsync(ct); }
            catch { body = string.Empty; }
            finally { resp.Dispose(); }

            var nameProp = _cfg["Rename:NewNameJsonPath"] ?? "newName";
            var newName = ExtractName(body, nameProp);
            if (string.IsNullOrWhiteSpace(newName))
            {
                return new RenameLookupOutcome(RenameLookupOutcome.Kind.Permanent, status,
                    $"missing-or-empty-property:{nameProp}");
            }
            return new RenameLookupOutcome(RenameLookupOutcome.Kind.Resolved, status, "resolved", newName.Trim());
        }

        string err;
        try
        {
            err = await resp.Content.ReadAsStringAsync(ct);
            if (err.Length > 200) err = err[..200] + "…";
        }
        catch { err = "(unavailable)"; }
        resp.Dispose();

        var kind = status switch
        {
            (int)HttpStatusCode.NotFound        => RenameLookupOutcome.Kind.NotFound,    // 404
            (int)HttpStatusCode.RequestTimeout  => RenameLookupOutcome.Kind.Transient,   // 408
            (int)HttpStatusCode.TooManyRequests => RenameLookupOutcome.Kind.Transient,   // 429
            >= 400 and < 500                    => RenameLookupOutcome.Kind.Permanent,
            >= 500                              => RenameLookupOutcome.Kind.Transient,
            _                                   => RenameLookupOutcome.Kind.Transient,
        };
        return new RenameLookupOutcome(kind, status, $"http-{status}:{err}");
    }

    internal static string BuildUrl(string template, string serial)
    {
        var encoded = Uri.EscapeDataString(serial);
        if (template.Contains("{serial}", StringComparison.OrdinalIgnoreCase))
        {
            return template.Replace("{serial}", encoded, StringComparison.OrdinalIgnoreCase);
        }
        return template.EndsWith('/') ? template + encoded : template + "/" + encoded;
    }

    private static string? ExtractName(string body, string propName)
    {
        if (string.IsNullOrWhiteSpace(body)) return null;
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            foreach (var prop in doc.RootElement.EnumerateObject())
            {
                if (string.Equals(prop.Name, propName, StringComparison.OrdinalIgnoreCase))
                {
                    return prop.Value.ValueKind == JsonValueKind.String ? prop.Value.GetString() : null;
                }
            }
        }
        catch (JsonException) { /* not JSON or malformed */ }
        return null;
    }
}
