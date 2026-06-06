using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Graph;
using Microsoft.Graph.Devices.Item.CheckMemberGroups;
using Microsoft.Graph.Models.ODataErrors;
using Microsoft.Kiota.Abstractions;
using Microsoft.Kiota.Abstractions.Serialization;

namespace IntuneDeviceActions.Capabilities.BitLocker.Services;

/// <summary>
/// Thin wrapper around <see cref="GraphServiceClient"/> exposing the
/// BitLocker-capability-specific Microsoft Graph operations:
/// <list type="bullet">
///   <item>Device resolution helpers (object id / group membership /
///         managed-device id) used by <c>BitLockerRotateRunner</c> during the
///         pre-issue safety checks — same fail-closed semantics as wipe;</item>
///   <item>The actual <c>rotateBitLockerKeys</c> managed-device action.</item>
/// </list>
/// <para>
/// <c>rotateBitLockerKeys</c> is not surfaced as a strongly-typed request
/// builder in the Microsoft.Graph v1.0 SDK (only the result type
/// <c>RotateBitLockerKeysDeviceActionResult</c> exists), so the call is issued
/// as a raw POST through the SDK's <see cref="IRequestAdapter"/>. This reuses
/// the same managed-identity credential, retry handlers, and base address as
/// every other Graph call — only the URL is hand-built. The endpoint is
/// configurable via <c>BitLocker:RotateEndpoint</c> so it can be pointed at the
/// beta surface if a tenant requires it.
/// </para>
/// </summary>
public sealed class GraphBitLockerService
{
    private readonly GraphServiceClient _graph;
    private readonly ILogger<GraphBitLockerService> _log;
    private readonly string _allowedGroupId;
    private readonly string _rotateEndpoint;

    public GraphBitLockerService(GraphServiceClient graph, IConfiguration cfg, ILogger<GraphBitLockerService> log)
    {
        _graph = graph;
        _log = log;
        _allowedGroupId = cfg["BitLocker:AllowedGroupId"]
            ?? throw new InvalidOperationException("BitLocker:AllowedGroupId must be configured");

        // {0} is the (URL-escaped) managedDevice id. Default targets the v1.0
        // action surface; override to beta if the tenant requires it.
        _rotateEndpoint = string.IsNullOrWhiteSpace(cfg["BitLocker:RotateEndpoint"])
            ? "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/{0}/rotateBitLockerKeys"
            : cfg["BitLocker:RotateEndpoint"]!;
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

        var matches = page?.Value ?? new List<Microsoft.Graph.Models.Device>();
        if (matches.Count != 1) return null;
        return matches[0].Id;
    }

    /// <summary>Checks membership of the configured BitLocker allow-list group.</summary>
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
    /// Resolves the Intune managedDevice.id by querying managedDevices filtered
    /// by azureADDeviceId. The cert-bound entraDeviceId is the authoritative
    /// server-side input. Returns null when there is no match or an ambiguous
    /// (>1) match — fail-closed, mirroring the wipe capability.
    /// </summary>
    public async Task<string?> ResolveAndValidateAsync(string entraDeviceId, CancellationToken ct)
    {
        if (!Guid.TryParse(entraDeviceId, out _))
            throw new ArgumentException("entraDeviceId must be a GUID", nameof(entraDeviceId));

        var page = await _graph.DeviceManagement.ManagedDevices.GetAsync(rc =>
        {
            rc.QueryParameters.Filter = $"azureADDeviceId eq '{entraDeviceId}'";
            rc.QueryParameters.Select = new[] { "id", "deviceName", "azureADDeviceId", "managementState" };
            rc.QueryParameters.Top    = 2;
        }, ct);

        var matches = page?.Value ?? new List<Microsoft.Graph.Models.ManagedDevice>();
        if (matches.Count == 0)
        {
            _log.LogWarning("No managedDevice found for azureADDeviceId={Aad} (device not Intune-enrolled or replication lag)", entraDeviceId);
            return null;
        }
        if (matches.Count > 1)
        {
            _log.LogWarning("Ambiguous managedDevice resolution for azureADDeviceId={Aad}: {Count} matches — fail-closed", entraDeviceId, matches.Count);
            return null;
        }
        return matches[0].Id;
    }

    /// <summary>
    /// Issues <c>rotateBitLockerKeys</c> for the given managed device. The
    /// service rotates the BitLocker recovery key on the device and escrows the
    /// new key to Entra ID. No request body is required.
    /// </summary>
    public async Task RotateBitLockerKeysAsync(string managedDeviceId, CancellationToken ct)
    {
        var url = string.Format(_rotateEndpoint, Uri.EscapeDataString(managedDeviceId));
        var requestInfo = new RequestInformation
        {
            HttpMethod = Method.POST,
            URI        = new Uri(url),
        };
        requestInfo.Headers.Add("Accept", "application/json");

        // Map any 4xx/5xx into a typed ODataError so the shared classifier can
        // tell transient from permanent (the runner relies on this). "XXX" is the
        // Kiota catch-all; 4XX/5XX are listed explicitly so the mapping is robust
        // regardless of Kiota's wildcard-resolution order across versions.
        var errorMapping = new Dictionary<string, ParsableFactory<IParsable>>
        {
            { "4XX", ODataError.CreateFromDiscriminatorValue },
            { "5XX", ODataError.CreateFromDiscriminatorValue },
            { "XXX", ODataError.CreateFromDiscriminatorValue },
        };

        _log.LogDebug("Graph rotateBitLockerKeys request: managedDevice={Id} endpoint={Url}", managedDeviceId, url);
        await _graph.RequestAdapter.SendNoContentAsync(requestInfo, errorMapping, cancellationToken: ct);
        _log.LogInformation("rotateBitLockerKeys issued for managedDevice {Id}", managedDeviceId);
    }
}
