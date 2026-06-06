using IntuneDeviceActions.Capabilities.Autopilot.Models;
using IntuneDeviceActions.Models;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Graph;
using Microsoft.Graph.Devices.Item.CheckMemberGroups;
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
/// Thin wrapper around <see cref="GraphServiceClient"/> exposing the
/// Autopilot-capability-specific Microsoft Graph operations:
/// <list type="bullet">
///   <item>Device resolution helpers (object id / group membership) used by
///         <c>AutopilotRegisterRunner</c> during the pre-issue safety checks —
///         same fail-closed semantics as wipe, minus the destructive ownership
///         verification;</item>
///   <item>The actual Autopilot <c>importedWindowsAutopilotDeviceIdentities</c>
///         create (the device registers itself into Windows Autopilot).</item>
/// </list>
/// <para>
/// Unlike wipe/bitlocker this capability does NOT act on an existing
/// <c>managedDevice</c> — it imports a hardware identity collected on the
/// client, so the privileged Graph permission is
/// <c>DeviceManagementServiceConfig.ReadWrite.All</c> (granted on the
/// app registration, isolated on the Autopilot UAMI).
/// </para>
/// </summary>
public sealed class GraphAutopilotService
{
    private readonly GraphServiceClient _graph;
    private readonly ILogger<GraphAutopilotService> _log;
    private readonly string _allowedGroupId;

    public GraphAutopilotService(GraphServiceClient graph, IConfiguration cfg, ILogger<GraphAutopilotService> log)
    {
        _graph = graph;
        _log = log;
        _allowedGroupId = cfg["Autopilot:AllowedGroupId"]
            ?? throw new InvalidOperationException("Autopilot:AllowedGroupId must be configured");
    }

    /// <summary>
    /// Resolves the directory object id of an Entra device by its deviceId (azureADDeviceId).
    /// </summary>
    public async Task<string?> GetDeviceObjectIdAsync(string entraDeviceId, CancellationToken ct)
    {
        if (!Guid.TryParse(entraDeviceId, out _))
            throw new ArgumentException("entraDeviceId must be a GUID", nameof(entraDeviceId));

        var page = await _graph.Devices.GetAsync(rc =>
        {
            rc.QueryParameters.Filter = $"deviceId eq '{entraDeviceId}'";
            rc.QueryParameters.Select = new[] { "id", "deviceId" };
            rc.QueryParameters.Top    = 2;
        }, ct);

        var matches = page?.Value ?? new List<Device>();
        if (matches.Count != 1) return null;
        return matches[0].Id;
    }

    /// <summary>Checks membership of the configured Autopilot allow-list group.</summary>
    public async Task<bool> IsDeviceInAllowedGroupAsync(string deviceObjectId, CancellationToken ct)
    {
        var body = new CheckMemberGroupsPostRequestBody { GroupIds = new List<string> { _allowedGroupId } };
        var result = await _graph.Devices[deviceObjectId]
            .CheckMemberGroups
            .PostAsCheckMemberGroupsPostResponseAsync(body, cancellationToken: ct);
        var matches = result?.Value ?? new List<string>();
        return matches.Contains(_allowedGroupId, StringComparer.OrdinalIgnoreCase);
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
