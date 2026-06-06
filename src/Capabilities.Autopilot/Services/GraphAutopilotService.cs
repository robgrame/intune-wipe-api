using IntuneDeviceActions.Capabilities.Autopilot.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Graph;
using Microsoft.Graph.Models;

namespace IntuneDeviceActions.Capabilities.Autopilot.Services;

/// <summary>
/// Outcome of an Autopilot import: the id of the created
/// <c>importedWindowsAutopilotDeviceIdentity</c> (the per-capability probe
/// handle stored on the status row) and the import status reported synchronously
/// by Graph.
/// </summary>
public sealed record AutopilotImportResult(string? ImportIdentityId, string ImportStatus);

/// <summary>
/// Thin wrapper around <see cref="GraphServiceClient"/> exposing the only
/// Autopilot-capability Microsoft Graph operation we need: the
/// <c>importedWindowsAutopilotDeviceIdentities</c> create that registers a
/// hardware identity into Windows Autopilot.
/// <para>
/// Unlike wipe/bitlocker this capability does NOT act on an existing
/// <c>managedDevice</c> and does NOT pre-check Entra membership: Autopilot
/// registration is intentionally usable on hardware that has never been
/// hybrid-joined and therefore has no Entra device object at all (let alone
/// a security-group membership). The privileged Graph permission is
/// <c>DeviceManagementServiceConfig.ReadWrite.All</c>, granted on the app
/// registration and isolated on the Autopilot UAMI.
/// </para>
/// </summary>
public sealed class GraphAutopilotService
{
    private readonly GraphServiceClient _graph;
    private readonly ILogger<GraphAutopilotService> _log;

    public GraphAutopilotService(GraphServiceClient graph, ILogger<GraphAutopilotService> log)
    {
        _graph = graph;
        _log = log;
    }

    /// <summary>
    /// Imports a Windows Autopilot device identity from the client-collected
    /// hardware hash. Idempotent on Graph's side per (hardware hash, serial) —
    /// a re-import of the same identity returns the existing record. Returns the
    /// created identity id (probe handle) plus the synchronous import status.
    /// </summary>
    public async Task<AutopilotImportResult> ImportAsync(AutopilotIdentityPayload payload, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(payload.HardwareHash))
            throw new ArgumentException("HardwareHash is required for Autopilot import", nameof(payload));

        byte[] hardwareId;
        try
        {
            hardwareId = Convert.FromBase64String(payload.HardwareHash);
        }
        catch (FormatException ex)
        {
            // Malformed hash is a permanent client error — surface as ArgumentException
            // so the runner classifies it (via Graph classifier default) appropriately.
            throw new ArgumentException("HardwareHash must be valid base64", nameof(payload), ex);
        }

        var body = new ImportedWindowsAutopilotDeviceIdentity
        {
            HardwareIdentifier        = hardwareId,
            SerialNumber              = string.IsNullOrWhiteSpace(payload.SerialNumber) ? null : payload.SerialNumber,
            ProductKey                = string.IsNullOrWhiteSpace(payload.ProductKey) ? null : payload.ProductKey,
            GroupTag                  = string.IsNullOrWhiteSpace(payload.GroupTag) ? null : payload.GroupTag,
            AssignedUserPrincipalName = string.IsNullOrWhiteSpace(payload.AssignedUserPrincipalName) ? null : payload.AssignedUserPrincipalName,
        };

        _log.LogDebug("Graph autopilot import: serial={Serial} groupTag={GroupTag} hashBytes={Bytes}",
            payload.SerialNumber, payload.GroupTag, hardwareId.Length);

        var created = await _graph.DeviceManagement.ImportedWindowsAutopilotDeviceIdentities.PostAsync(body, cancellationToken: ct);

        var importId = created?.Id;
        var status   = created?.State?.DeviceImportStatus?.ToString() ?? "pending";
        _log.LogInformation("autopilot import created: id={ImportId} status={Status} serial={Serial}",
            importId, status, payload.SerialNumber);
        return new AutopilotImportResult(importId, status);
    }
}
