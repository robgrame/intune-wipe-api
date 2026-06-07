using System.Text.Json.Serialization;

namespace IntuneDeviceActions.Capabilities.Rename.Models;

/// <summary>
/// Capability-specific payload carried inside the opaque <c>Extras</c> bag of
/// <c>ActionRequest</c>/<c>ActionRequestMessage</c>. The Shared HTTP intake
/// passes this through unchanged; the rename runner deserializes the named
/// <c>rename</c> property of <c>Extras</c> into this shape.
///
/// JSON shape on the wire (inside <c>ActionRequest.Extras</c>):
/// <code>
/// {
///   "actionType": "device-rename",
///   "deviceName": "WS-CONTOSO-001",
///   "entraDeviceId": "...",
///   "intuneDeviceId": "...",
///   "rename": {
///     "serialNumber": "PF3X9ABC"
///   }
/// }
/// </code>
/// <para>
/// The new device name is NOT supplied by the caller — the rename runner queries
/// the customer-internal REST endpoint with the serial number and the customer
/// system returns the authoritative new name. This keeps the naming convention
/// in the customer's CMDB/asset-management system rather than scattered across
/// client scripts.
/// </para>
/// <para>
/// Only <see cref="SerialNumber"/> is required — the runner emits
/// <c>rename.denied.missing-serial</c> and records a terminal status if absent.
/// </para>
/// </summary>
public sealed class RenameRequestExtras
{
    /// <summary>Hardware serial number passed to the customer REST endpoint as the lookup key.</summary>
    [JsonPropertyName("serialNumber")]
    public string? SerialNumber { get; set; }
}
