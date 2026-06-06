using System.Text.Json.Serialization;

namespace IntuneDeviceActions.Models;

public sealed class ActionRequestMessage
{
    /// <summary>
    /// Pluggable action discriminator (matches an <c>IActionRunner.Type</c>
    /// downstream). Stamped by <c>ActionRequestFunction</c> from the HTTP route
    /// template and propagated end-to-end so the intake/dispatch pipeline can
    /// route any registered action without code changes. Nullable to stay
    /// compatible with in-flight messages produced before this field existed:
    /// consumers fall back to a configured default when missing.
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
    /// Optional Autopilot device-identity bundle (hardware hash + serial +
    /// product key + group tag) carried end-to-end for the
    /// <c>autopilot-register</c> action. Null for every other action. Stamped by
    /// <c>ActionRequestFunction</c> from the HTTP body's <c>autopilot</c> object
    /// and forwarded opaquely inside the dispatch envelope until
    /// <c>AutopilotRegisterRunner</c> consumes it.
    /// </summary>
    [JsonPropertyName("autopilot")]        public AutopilotIdentityPayload? Autopilot { get; set; }
}
