namespace IntuneDeviceActions.Capabilities.Rename.Services;

/// <summary>
/// Abstraction over the customer-internal CMDB / asset-management REST endpoint
/// that holds the authoritative naming convention. The contract is a LOOKUP:
/// given a hardware serial number, return the canonical device name the
/// customer wants applied via Intune.
///
/// Lives behind an interface so the runner can be unit-tested without an HTTP
/// dependency and so customer-specific transports (mTLS, API gateway, Service
/// Bus relay, …) can be swapped in without touching the runner.
/// </summary>
public interface ICustomerRenameClient
{
    /// <summary>
    /// GETs <c>{Rename:Endpoint}</c> with the serial substituted (either via the
    /// <c>{serial}</c> placeholder, or by URL-encoding and appending it as a
    /// path segment when no placeholder is present) and reads the response body.
    ///
    /// <para>
    /// The implementation classifies the HTTP outcome into a
    /// <see cref="RenameLookupOutcome"/> the runner uses to drive
    /// ledger/audit/status:
    /// <list type="bullet">
    ///   <item>2xx with non-empty <c>newName</c> → <see cref="RenameLookupOutcome.Kind.Resolved"/>;</item>
    ///   <item>404 → <see cref="RenameLookupOutcome.Kind.NotFound"/> (permanent — the
    ///         CMDB doesn't know this serial, no point in retrying);</item>
    ///   <item>4xx other than 404/408/429 → <see cref="RenameLookupOutcome.Kind.Permanent"/>;</item>
    ///   <item>5xx, 408, 429, timeout, network errors → <see cref="RenameLookupOutcome.Kind.Transient"/>
    ///         (the per-capability Service Bus consumer retries).</item>
    /// </list>
    /// </para>
    /// </summary>
    Task<RenameLookupOutcome> ResolveNewNameAsync(string serialNumber, string correlationId, CancellationToken ct);
}

/// <summary>
/// Classified result of the customer LOOKUP call. The runner uses
/// <see cref="OutcomeKind"/> to decide between proceeding-to-graph (resolved),
/// mark-failed-permanent (NotFound / 4xx), or throw-for-retry (transient).
/// </summary>
public sealed record RenameLookupOutcome(
    RenameLookupOutcome.Kind OutcomeKind,
    int StatusCode,
    string Reason,
    string? NewName = null)
{
    public enum Kind
    {
        /// <summary>2xx with a non-empty <c>newName</c> in the body.</summary>
        Resolved,
        /// <summary>HTTP 404 — the CMDB doesn't recognise this serial. Permanent.</summary>
        NotFound,
        /// <summary>Other 4xx (not 404/408/429) — permanent client error.</summary>
        Permanent,
        /// <summary>5xx, 408, 429, timeout, network. Throw so the SB consumer retries.</summary>
        Transient,
    }
}
