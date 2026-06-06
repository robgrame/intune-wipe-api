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
    /// HTTP body's extras (after passing through <see cref="SanitizeExtras"/>
    /// to scrub any server-stamped key) and forwarded through the dispatch
    /// envelope until the matching <c>IActionRunner</c> reads its own named
    /// property.
    /// </summary>
    [JsonExtensionData]
    public Dictionary<string, JsonElement>? Extras { get; set; }

    /// <summary>
    /// Names of the declared JSON properties on this type. Used by
    /// <see cref="SanitizeExtras"/> to scrub any colliding key out of the
    /// extension-data bag at the trust boundary. The set is case-insensitive
    /// because some consumers configure <c>PropertyNameCaseInsensitive=true</c>
    /// and we don't want a case-flipped key (e.g. <c>ForceRearm</c>) to
    /// survive sanitisation and then bind on the consumer side.
    /// </summary>
    public static readonly IReadOnlySet<string> ReservedExtrasKeys =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "actionType",
            "deviceName",
            "entraDeviceId",
            "intuneDeviceId",
            "correlationId",
            "clientCertThumbprint",
            "requestedAt",
            "forceRearm",
        };

    /// <summary>
    /// Returns a copy of <paramref name="source"/> with any key matching a
    /// declared <see cref="ActionRequestMessage"/> property removed. Used at
    /// the HTTP boundary to prevent an authenticated client from spoofing
    /// server-stamped fields (e.g. <c>forceRearm</c>, <c>correlationId</c>,
    /// <c>clientCertThumbprint</c>) through the opaque
    /// <see cref="ActionRequest.Extras"/> bag. Returns <c>null</c> if
    /// <paramref name="source"/> is <c>null</c> or every key was reserved.
    /// </summary>
    /// <param name="source">Raw extras dictionary from the HTTP request body.</param>
    /// <param name="droppedKeys">
    /// When non-null, populated with the names of reserved keys that were
    /// stripped. Empty when no collisions were found. Useful for audit /
    /// forensic logging at the call site.
    /// </param>
    public static Dictionary<string, JsonElement>? SanitizeExtras(
        Dictionary<string, JsonElement>? source,
        IList<string>? droppedKeys = null)
    {
        if (source is null || source.Count == 0) return null;

        Dictionary<string, JsonElement>? clean = null;
        foreach (var kv in source)
        {
            if (ReservedExtrasKeys.Contains(kv.Key))
            {
                droppedKeys?.Add(kv.Key);
                continue;
            }
            clean ??= new Dictionary<string, JsonElement>(source.Count, StringComparer.Ordinal);
            clean[kv.Key] = kv.Value;
        }
        return clean;
    }
}
