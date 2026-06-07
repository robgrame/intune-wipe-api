namespace IntuneDeviceActions.Capabilities.Rename.Audit;

/// <summary>
/// Rename-specific event names emitted to Application Insights customEvents.
/// Mirrors the convention used by other capabilities (Wipe / Autopilot /
/// BitLocker) but with TWO verb segments because the rename pipeline spans
/// two trust boundaries:
/// <list type="bullet">
///   <item><c>rename.lookup.*</c> — the customer-internal CMDB call
///         (GET serial → newName);</item>
///   <item><c>rename.collision.*</c> — Entra displayName uniqueness check;</item>
///   <item><c>rename.graph.setname.*</c> — the Microsoft Graph
///         <c>setDeviceName</c> action against the managed device.</item>
/// </list>
///
/// KQL convention: <c>customEvents | where name startswith "rename."</c>
/// covers every rename-specific row; combine with
/// <c>name startswith "action."</c> for the full pipeline picture.
/// </summary>
public static class RenameAuditEvents
{
    // Customer lookup (GET serial -> newName)
    public const string LookupIssued          = "rename.lookup.issued";
    public const string LookupNotFound        = "rename.lookup.not-found";
    public const string LookupFailedPermanent = "rename.lookup.failed-permanent";
    public const string LookupTransientError  = "rename.lookup.transient-error";

    // Entra displayName collision check
    public const string CollisionDetected     = "rename.collision.detected";
    public const string CollisionBlocked      = "rename.collision.blocked";
    public const string CollisionCheckFailed  = "rename.collision.check-failed";

    // Microsoft Graph setDeviceName action against the managed device
    public const string GraphSetNameIssued          = "rename.graph.setname.issued";
    public const string GraphSetNameFailedPermanent = "rename.graph.setname.failed-permanent";
    public const string GraphSetNameTransientError  = "rename.graph.setname.transient-error";

    // Rename Function App (consumer of the per-capability rename-action queue)
    public const string ActionConsumed        = "rename.action.consumed";
    public const string ActionInvalidEnvelope = "rename.action.invalid-envelope";
    public const string ActionCompleted       = "rename.action.completed";
    public const string ActionRunnerFailed    = "rename.action.runner-failed";

    // Validation
    public const string MissingSerial         = "rename.denied.missing-serial";
    public const string MissingIntuneDeviceId = "rename.denied.missing-intune-device-id";
}
