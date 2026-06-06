using System.Text.Json;
using IntuneDeviceActions.Capabilities.Autopilot.Models;
using IntuneDeviceActions.Models;

namespace IntuneDeviceActions.Capabilities.Autopilot.Runners;

/// <summary>
/// Pulls the capability-owned <c>autopilot</c> JSON element out of the
/// action-agnostic <see cref="ActionRequestMessage.Extras"/> bag and binds
/// it to <see cref="AutopilotIdentityPayload"/>. Returns <c>null</c> when
/// the key is absent, JSON-null, or fails to bind — callers (the runner)
/// treat all three as "missing hardware hash" (a permanent denial).
/// Extracted from <c>AutopilotRegisterRunner</c> as a standalone helper so
/// its small but contract-critical behaviour can be unit-tested in isolation,
/// without spinning up the full runner + DI graph.
/// </summary>
internal static class AutopilotPayloadExtractor
{
    public static AutopilotIdentityPayload? TryRead(ActionRequestMessage msg)
    {
        if (msg.Extras is null) return null;
        if (!msg.Extras.TryGetValue(AutopilotIdentityPayload.ExtrasKey, out var element)) return null;
        if (element.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return null;
        try
        {
            return element.Deserialize<AutopilotIdentityPayload>();
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
