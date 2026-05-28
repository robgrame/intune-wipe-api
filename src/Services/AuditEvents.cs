namespace IntuneWipeApi.Services;

/// <summary>
/// Canonical event names emitted to Application Insights customEvents for the
/// security/audit trail of the wipe pipeline.
///
/// These events are emitted via <see cref="AuditService"/> with adaptive sampling
/// disabled on the worker telemetry pipeline (see Program.cs), so they are
/// guaranteed to land in App Insights and are queryable as:
///
///     customEvents | where name startswith "wipe."
///
/// Keep names stable — workbooks, alerts, and KQL queries depend on them.
/// </summary>
public static class AuditEvents
{
    // Acceptance
    public const string RequestAccepted = "wipe.request.accepted";

    // Web-side denials (HTTP path)
    public const string DeniedAppRoleMismatch        = "wipe.denied.app-role-mismatch";
    public const string DeniedReplay                 = "wipe.denied.replay";
    public const string DeniedCertValidation         = "wipe.denied.cert-validation";
    public const string DeniedCertBindingMissing     = "wipe.denied.cert-binding-missing";
    public const string DeniedCertDeviceMismatch     = "wipe.denied.cert-device-mismatch";
    public const string DeniedPayloadInvalid         = "wipe.denied.payload-invalid";

    // Worker-side denials (queue path)
    public const string DeniedDeviceResolveFailed        = "wipe.denied.device-resolve-failed";
    public const string DeniedDeviceNotInEntra           = "wipe.denied.device-not-in-entra";
    public const string DeniedGroupCheckFailed           = "wipe.denied.group-check-failed";
    public const string DeniedNotInAllowedGroup          = "wipe.denied.not-in-allowed-group";
    public const string DeniedManagedDeviceResolveFailed = "wipe.denied.managed-device-resolve-failed";
    public const string DeniedOwnershipMismatch          = "wipe.denied.ownership-mismatch";

    // Idempotency outcomes
    public const string WipeAlreadyIssued        = "wipe.already-issued";
    public const string WipeInProgressElsewhere  = "wipe.in-progress-elsewhere";

    // Graph outcomes
    public const string WipeIssued          = "wipe.graph.issued";
    public const string WipeFailedPermanent = "wipe.graph.failed-permanent";
    public const string WipeTransientError  = "wipe.graph.transient-error";

    // Post-wipe fallback nudges (best-effort: syncDevice + rebootNow to push the
    // managed-device to pick up the pending wipe even if it didn't kick in
    // immediately). Failures here do NOT reverse the successful wipe.
    public const string SyncFallbackIssued   = "wipe.graph.sync-fallback.issued";
    public const string SyncFallbackFailed   = "wipe.graph.sync-fallback.failed";
    public const string RebootFallbackIssued = "wipe.graph.reboot-fallback.issued";
    public const string RebootFallbackFailed = "wipe.graph.reboot-fallback.failed";

    // Shared property keys (use these consistently so KQL is uniform)
    public static class Prop
    {
        public const string CorrelationId    = "correlationId";
        public const string DeviceName       = "deviceName";
        public const string EntraDeviceId    = "entraDeviceId";
        public const string IntuneDeviceId   = "intuneDeviceId";
        public const string ManagedDeviceId  = "managedDeviceId";
        public const string CertThumbprint   = "certThumbprint";
        public const string Reason           = "reason";
        public const string ExpectedRole     = "expectedRole";
        public const string ActualRole       = "actualRole";
        public const string BoundDeviceId    = "boundDeviceId";
        public const string OriginalCorrelationId = "originalCorrelationId";
        public const string ExceptionType    = "exceptionType";
        public const string ExceptionMessage = "exceptionMessage";
    }
}
