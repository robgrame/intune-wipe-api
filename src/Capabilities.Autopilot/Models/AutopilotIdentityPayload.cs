using System.Text.Json.Serialization;

namespace IntuneDeviceActions.Capabilities.Autopilot.Models;

/// <summary>
/// Windows Autopilot device-identity bundle collected on the client (e.g. via
/// <c>Get-WindowsAutopilotInfo</c> / the <c>MDM_DevDetail_Ext01</c> WMI class)
/// and POSTed alongside an <c>autopilot-register</c> action request. Only the
/// hardware hash is strictly required by Graph's import endpoint; the rest aid
/// matching, error reporting, and group-tag assignment.
/// </summary>
/// <remarks>
/// Lives in the capability project — the Shared core does NOT know about
/// capability-specific payload shapes. On the wire this is carried as the
/// top-level <c>autopilot</c> JSON property, captured into
/// <c>ActionRequest.Extras</c> / <c>ActionRequestMessage.Extras</c> via
/// <see cref="JsonExtensionDataAttribute"/> in Shared, and deserialized into
/// this type by the <c>AutopilotRegisterRunner</c>.
/// </remarks>
public sealed class AutopilotIdentityPayload
{
    /// <summary>The JSON property name under which this payload travels in the action request body.</summary>
    public const string ExtrasKey = "autopilot";

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
