using IntuneDeviceActions.Actions;
using Microsoft.Extensions.Logging;
using Microsoft.Graph;
using Microsoft.Graph.Models.ODataErrors;

namespace IntuneDeviceActions.Capabilities.Autopilot.Services;

/// <summary>
/// <see cref="IActionStatusProbe"/> for the <c>autopilot-register</c> action
/// type. Unlike wipe/bitlocker there is no <c>managedDevice</c> action result to
/// poll — instead the probe handle stored on the status row is the id of the
/// created <c>importedWindowsAutopilotDeviceIdentity</c>, and this probe reads
/// its <c>state.deviceImportStatus</c> to drive the terminal decision.
/// </summary>
/// <remarks>
/// Status mapping onto the shared tracker's terminal/success sets:
/// <list type="bullet">
///   <item><c>complete</c> → <c>done</c> (terminal success);</item>
///   <item><c>error</c> → <c>failed</c> (terminal failure);</item>
///   <item><c>pending</c>/<c>partial</c>/<c>unknown</c> → reported verbatim
///         (non-terminal — keep polling);</item>
///   <item>Graph 404 → <c>done</c> — the import record is removed once the
///         identity is promoted to a real Autopilot device, i.e. success.</item>
/// </list>
/// </remarks>
public sealed class AutopilotActionStatusProbe : IActionStatusProbe
{
    public string ActionType => "autopilot-register";

    private readonly GraphServiceClient _graph;
    private readonly ILogger<AutopilotActionStatusProbe> _log;

    public AutopilotActionStatusProbe(GraphServiceClient graph, ILogger<AutopilotActionStatusProbe> log)
    {
        _graph = graph;
        _log = log;
    }

    public async Task<ActionProbeSnapshot> ProbeAsync(string importIdentityId, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(importIdentityId))
        {
            // No probe handle was stored (import never returned an id) — nothing
            // to poll; treat as terminal so the poller stops churning the row.
            return new ActionProbeSnapshot("done", null, DateTimeOffset.UtcNow, null, null, null, null);
        }

        try
        {
            var identity = await _graph.DeviceManagement
                .ImportedWindowsAutopilotDeviceIdentities[importIdentityId]
                .GetAsync(rc =>
                {
                    rc.QueryParameters.Select = new[] { "id", "serialNumber", "state" };
                }, cancellationToken: ct);

            var raw = identity?.State?.DeviceImportStatus?.ToString().ToLowerInvariant() ?? "unknown";
            var state = raw switch
            {
                "complete" => "done",
                "error"    => "failed",
                _          => raw,   // pending / partial / unknown — non-terminal
            };

            return new ActionProbeSnapshot(
                State:             state,
                ActionStartedAt:   null,
                ActionLastUpdated: DateTimeOffset.UtcNow,
                DeviceLastSync:    null,
                ComplianceState:   null,
                OsVersion:         null,
                OperatingSystem:   null);
        }
        catch (ODataError oe) when (oe.ResponseStatusCode == 404)
        {
            // The import record is consumed/removed once the identity is promoted
            // to a real Autopilot device — that's the success end-state.
            _log.LogInformation("Autopilot probe: import identity {Id} returned 404 (promoted/removed) — treating as done", importIdentityId);
            return new ActionProbeSnapshot(
                State: "done",
                ActionStartedAt: null,
                ActionLastUpdated: DateTimeOffset.UtcNow,
                DeviceLastSync: null,
                ComplianceState: null,
                OsVersion: null,
                OperatingSystem: null);
        }
    }
}
