using System.Text.Json.Serialization;

namespace IntuneDeviceActions.Models;

public sealed class ActionRequest
{
    /// <summary>
    /// Action discriminator (matches an <c>IActionRunner.Type</c> downstream
    /// once it crosses the dispatch queue). Required on the canonical
    /// <c>POST /api/actions</c> endpoint; for the legacy
    /// <c>POST /api/actions/{actionType}</c> endpoint this property MAY be
    /// omitted and the route value is used as a fallback. When both are
    /// present the body value takes precedence so a client can always
    /// override.
    /// </summary>
    [JsonPropertyName("actionType")]
    public string? ActionType { get; set; }

    [JsonPropertyName("deviceName")]
    public string? DeviceName { get; set; }

    [JsonPropertyName("entraDeviceId")]
    public string? EntraDeviceId { get; set; }

    [JsonPropertyName("intuneDeviceId")]
    public string? IntuneDeviceId { get; set; }
}

public sealed class ActionResponse
{
    public string Status { get; set; } = "accepted";
    public string? Message { get; set; }
    public string? CorrelationId { get; set; }
}
