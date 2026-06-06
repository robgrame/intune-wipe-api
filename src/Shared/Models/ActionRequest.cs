using System.Text.Json;
using System.Text.Json.Serialization;

namespace IntuneDeviceActions.Models;

/// <summary>
/// Action-agnostic HTTP request envelope accepted by <c>POST /api/actions</c>.
/// The core knows ONLY the four fields needed to route + audit the request —
/// any capability-specific data travels opaquely in <see cref="Extras"/> and is
/// deserialized by the matching <c>IActionRunner</c>.
/// </summary>
public sealed class ActionRequest
{
    /// <summary>
    /// Action discriminator (matches an <c>IActionRunner.Type</c> downstream).
    /// Required: requests without an <c>actionType</c> are rejected by the
    /// allowlist (<c>Actions:AllowedTypes</c>).
    /// </summary>
    [JsonPropertyName("actionType")]
    public string? ActionType { get; set; }

    [JsonPropertyName("deviceName")]
    public string? DeviceName { get; set; }

    [JsonPropertyName("entraDeviceId")]
    public string? EntraDeviceId { get; set; }

    [JsonPropertyName("intuneDeviceId")]
    public string? IntuneDeviceId { get; set; }

    /// <summary>
    /// Opaque bag of any additional top-level JSON properties on the request
    /// body. Captures per-capability payloads (e.g. <c>autopilot</c> for the
    /// autopilot-register action) without leaking capability-specific types
    /// into the Shared core. Each capability runner pulls its own named
    /// property out of this dictionary and deserializes it into the shape it
    /// expects. Null when the body has no extra properties beyond the four
    /// core fields above.
    /// </summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extras { get; set; }
}

public sealed class ActionResponse
{
    public string Status { get; set; } = "accepted";
    public string? Message { get; set; }
    public string? CorrelationId { get; set; }
}
