using IntuneDeviceActions.Actions;
using Microsoft.Extensions.Logging;
using Microsoft.Graph;
using Microsoft.Graph.Models.ODataErrors;

namespace IntuneDeviceActions.Capabilities.BitLocker.Services;

/// <summary>
/// <see cref="IActionStatusProbe"/> for the <c>bitlocker-rotate</c> action type.
/// Queries Graph <c>managedDevices/{id}</c> for the latest
/// <c>deviceActionResults[name=='rotateBitLockerKeys']</c> entry plus
/// surrounding device telemetry so operators can see whether the rotation has
/// been picked up by the device.
/// </summary>
public sealed class BitLockerActionStatusProbe : IActionStatusProbe
{
    public string ActionType => "bitlocker-rotate";

    private readonly GraphServiceClient _graph;
    private readonly ILogger<BitLockerActionStatusProbe> _log;

    public BitLockerActionStatusProbe(GraphServiceClient graph, ILogger<BitLockerActionStatusProbe> log)
    {
        _graph = graph;
        _log = log;
    }

    public async Task<ActionProbeSnapshot> ProbeAsync(string managedDeviceId, CancellationToken ct)
    {
        try
        {
            var dev = await _graph.DeviceManagement.ManagedDevices[managedDeviceId].GetAsync(rc =>
            {
                rc.QueryParameters.Select = new[]
                {
                    "id", "deviceName", "operatingSystem", "osVersion",
                    "complianceState", "lastSyncDateTime", "deviceActionResults"
                };
            }, cancellationToken: ct);

            DateTimeOffset? actionStart   = null;
            DateTimeOffset? actionUpdated = null;
            var state = "notReported";

            if (dev?.DeviceActionResults is { Count: > 0 } results)
            {
                var rotate = results
                    .Where(r => string.Equals(r.ActionName, "rotateBitLockerKeys", StringComparison.OrdinalIgnoreCase))
                    .OrderByDescending(r => r.LastUpdatedDateTime ?? r.StartDateTime ?? DateTimeOffset.MinValue)
                    .FirstOrDefault();

                if (rotate is not null)
                {
                    state         = rotate.ActionState?.ToString().ToLowerInvariant() ?? "unknown";
                    actionStart   = rotate.StartDateTime;
                    actionUpdated = rotate.LastUpdatedDateTime ?? rotate.StartDateTime;
                }
            }

            return new ActionProbeSnapshot(
                State:             state,
                ActionStartedAt:   actionStart,
                ActionLastUpdated: actionUpdated,
                DeviceLastSync:    dev?.LastSyncDateTime,
                ComplianceState:   dev?.ComplianceState?.ToString(),
                OsVersion:         dev?.OsVersion,
                OperatingSystem:   dev?.OperatingSystem);
        }
        catch (ODataError oe) when (oe.ResponseStatusCode == 404)
        {
            // Device no longer in Intune — nothing left to rotate; treat as terminal.
            _log.LogInformation("BitLocker probe: managedDevice {Id} returned 404 (removed from Intune)", managedDeviceId);
            return new ActionProbeSnapshot(
                State: "removedFromIntune",
                ActionStartedAt: null,
                ActionLastUpdated: DateTimeOffset.UtcNow,
                DeviceLastSync: null,
                ComplianceState: null,
                OsVersion: null,
                OperatingSystem: null);
        }
    }
}
