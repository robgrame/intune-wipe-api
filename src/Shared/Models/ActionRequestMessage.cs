using System.Text.Json;
using System.Text.Json.Serialization;

namespace IntuneDeviceActions.Models;

/// <summary>
/// Service Bus message produced by the HTTP intake and consumed by the
/// dispatcher. Mirrors <see cref="ActionRequest"/> on the wire and shares the
/// same action-agnostic contract: the Shared core stamps only the routing and
/// audit fields; per-capability payloads travel opaquely in <see cref="Extras"/>
/// and are deserialized by the matching <c>IActionRunner</c>.
/// </summary>
public sealed class ActionRequestMessage
{
    /// <summary>
    /// Pluggable action discriminator (matches an <c>IActionRunner.Type</c>
    /// downstream). Stamped by <c>ActionRequestFunction</c> from the HTTP body
    /// and propagated end-to-end so the intake/dispatch pipeline can route any
    /// registered action without code changes. Nullable to stay compatible with
    /// in-flight messages produced before this field existed: consumers fall
    /// back to a configured default when missing.
    /// </summary>
    [JsonPropertyName("actionType")]       public string? ActionType { get; set; }
    [JsonPropertyName("deviceName")]       public string DeviceName { get; set; } = string.Empty;
    [JsonPropertyName("entraDeviceId")]    public string EntraDeviceId { get; set; } = string.Empty;
    [JsonPropertyName("intuneDeviceId")]   public string IntuneDeviceId { get; set; } = string.Empty;
    [JsonPropertyName("correlationId")]    public string CorrelationId { get; set; } = string.Empty;
    [JsonPropertyName("clientCertThumbprint")] public string? ClientCertThumbprint { get; set; }
    [JsonPropertyName("requestedAt")]      public DateTimeOffset RequestedAt { get; set; } = DateTimeOffset.UtcNow;

    /// <summary>
    /// If true AND the worker has <c>Idempotency:AllowForceRearm=true</c>, the
    /// idempotency ledger will be re-armed unconditionally for this request,
    /// bypassing the tracker-based completion check. Intended for DEV/testing
    /// scenarios where repeated wipes must be issued to the same device
    /// (especially with keepEnrollmentData=true). Set from the
    /// <c>X-Force-Rearm: true</c> request header at the HTTP boundary.
    /// </summary>
    [JsonPropertyName("forceRearm")]       public bool ForceRearm { get; set; }

    /// <summary>
    /// Opaque bag of any additional JSON properties carried alongside the
    /// routing fields. Mirrors <see cref="ActionRequest.Extras"/> and carries
    /// per-capability payloads end-to-end (e.g. <c>autopilot</c> for the
    /// autopilot-register action) without leaking capability-specific types
    /// into the Shared core. Populated by <c>ActionRequestFunction</c> from the
    /// HTTP body's extras and forwarded through the dispatch envelope until the
    /// matching <c>IActionRunner</c> reads its own named property.
    /// </summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extras { get; set; }
}
