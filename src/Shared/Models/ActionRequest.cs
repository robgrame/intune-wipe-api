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

    /// <summary>
    /// Optional, action-specific data the client cannot have the server derive
    /// on its own. Today this carries the Windows Autopilot hardware identity
    /// (4K hardware hash + serial + product key + group tag) for the
    /// <c>autopilot-register</c> action, since the hardware hash only exists on
    /// the device. Null/absent for every other action (e.g. wipe, bitlocker-rotate)
    /// so the change is fully backward compatible: the field is opaque to the
    /// HTTP intake and flows through the dispatch envelope untouched until the
    /// matching <c>IActionRunner</c> deserializes it.
    /// </summary>
    [JsonPropertyName("autopilot")]
    public AutopilotIdentityPayload? Autopilot { get; set; }
}

/// <summary>
/// Windows Autopilot device-identity bundle collected on the client (e.g. via
/// <c>Get-WindowsAutopilotInfo</c> / the <c>MDM_DevDetail_Ext01</c> WMI class)
/// and POSTed alongside an <c>autopilot-register</c> action request. Only the
/// hardware hash is strictly required by Graph's import endpoint; the rest aid
/// matching, error reporting, and group-tag assignment.
/// </summary>
public sealed class AutopilotIdentityPayload
{
    /// <summary>Base64-encoded 4K hardware hash (<c>DeviceHardwareData</c>). Required.</summary>
    [JsonPropertyName("hardwareHash")]
    public string? HardwareHash { get; set; }

    /// <summary>Device serial number (used by Graph to dedupe imports).</summary>
    [JsonPropertyName("serialNumber")]
    public string? SerialNumber { get; set; }

    /// <summary>OEM Windows product key, when available.</summary>
    [JsonPropertyName("productKey")]
    public string? ProductKey { get; set; }

    /// <summary>Optional Autopilot group tag to stamp on the imported identity.</summary>
    [JsonPropertyName("groupTag")]
    public string? GroupTag { get; set; }

    /// <summary>Optional UPN to pre-assign to the imported device.</summary>
    [JsonPropertyName("assignedUserPrincipalName")]
    public string? AssignedUserPrincipalName { get; set; }
}

public sealed class ActionResponse
{
    public string Status { get; set; } = "accepted";
    public string? Message { get; set; }
    public string? CorrelationId { get; set; }
}
