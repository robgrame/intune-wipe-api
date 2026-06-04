namespace IntuneDeviceActions.Services;

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
    // Inbound request audit (emitted BEFORE validation so denied attempts are
    // also visible — gives full coverage of every wipe attempt that reached us)
    public const string RequestReceived = "wipe.request.received";

    // Acceptance
    public const string RequestAccepted = "wipe.request.accepted";

    // Web-side denials (HTTP path)
    public const string DeniedReplay                 = "wipe.denied.replay";
    public const string DeniedCertValidation         = "wipe.denied.cert-validation";
    public const string DeniedCertBindingMissing     = "wipe.denied.cert-binding-missing";
    public const string DeniedCertDeviceMismatch     = "wipe.denied.cert-device-mismatch";
    public const string DeniedPayloadInvalid         = "wipe.denied.payload-invalid";
    // Action-type allowlist denial: caller hit /api/actions/{actionType} with
    // an actionType that is not enabled in Actions:AllowedTypes config.
    public const string DeniedActionTypeNotAllowed   = "action.denied.type-not-allowed";

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

    // Ledger lifecycle — re-arm decisions taken by IdempotencyService when a
    // previous wipe for the same device has already reached a terminal state
    // on the Intune side (as observed by ActionStatusTracker). These are the
    // signals operators look at to validate that "test wipe ×N" or
    // "re-wipe after legitimate failure" flows behave as designed.
    public const string LedgerRearmedAfterSuccess = "wipe.ledger.rearmed.after-success";
    public const string LedgerRearmedAfterFailure = "wipe.ledger.rearmed.after-failure";
    public const string LedgerRearmedAfterTimeout = "wipe.ledger.rearmed.after-timeout";
    public const string LedgerRearmedForced       = "wipe.ledger.rearmed.forced";
    public const string LedgerRearmConflict       = "wipe.ledger.rearm-conflict";
    public const string LedgerNoTracker           = "wipe.ledger.no-tracker";
    public const string LedgerWaitingGrace        = "wipe.ledger.waiting-grace-period";

    // Rate limiting (per-device daily cap on wipes)
    public const string DeniedRateLimited        = "wipe.denied.rate-limited";

    // Admin operations on the ledger (manual reset by SecOps).
    public const string LedgerResetManual        = "wipe.ledger.reset-manual";
    public const string LedgerResetDenied        = "wipe.ledger.reset-denied";

    // Graph outcomes
    public const string WipeIssued          = "wipe.graph.issued";
    public const string WipeFailedPermanent = "wipe.graph.failed-permanent";
    public const string WipeTransientError  = "wipe.graph.transient-error";

    // Post-wipe fallback nudges (best-effort: syncDevice + rebootNow to push the
    // managed-device to pick up the pending wipe even if it didn't kick in
    // immediately). Failures here do NOT reverse the successful wipe.
    public const string SyncFallbackIssued     = "wipe.graph.sync-fallback.issued";
    public const string SyncFallbackRetrying   = "wipe.graph.sync-fallback.retrying";
    public const string SyncFallbackFailed     = "wipe.graph.sync-fallback.failed";
    public const string SyncFallbackExhausted  = "wipe.graph.sync-fallback.exhausted";
    public const string RebootFallbackIssued   = "wipe.graph.reboot-fallback.issued";
    public const string RebootFallbackRetrying = "wipe.graph.reboot-fallback.retrying";
    public const string RebootFallbackFailed   = "wipe.graph.reboot-fallback.failed";
    public const string RebootFallbackExhausted= "wipe.graph.reboot-fallback.exhausted";

    // Post-issue wipe action tracking (polled by ActionStatusPollerFunction every
    // few minutes against Graph's managedDevices/{id}.deviceActionResults).
    public const string ActionStateObserved   = "wipe.action.state-observed";   // every poll, even if unchanged (low-noise via LogLevel.Debug)
    public const string ActionStateChanged    = "wipe.action.state-changed";    // emitted on transition
    public const string ActionCompleted       = "wipe.action.completed";        // terminal: done | removedFromIntune
    public const string ActionFailed          = "wipe.action.failed";           // terminal: failed | canceled | notSupported
    public const string ActionPollTimeout     = "wipe.action.poll-timeout";     // gave up polling after PollMaxAgeHours
    public const string ActionPollError       = "wipe.action.poll-error";       // Graph call failed (transient)

    // Plug-in dispatch pipeline (action-dispatch queue + ActionDispatchFunction).
    // The wipe processor enqueues an ActionDispatchMessage with ActionType="wipe";
    // the router resolves the matching IActionRunner and invokes it.
    public const string ActionDispatchEnqueued       = "action.dispatch.enqueued";        // producer side
    public const string ActionDispatchReceived       = "action.dispatch.received";        // router consumed envelope
    public const string ActionDispatchNoRunner       = "action.dispatch.no-runner";       // unknown ActionType
    public const string ActionDispatchInvalidEnvelope= "action.dispatch.invalid-envelope";// JSON malformed
    public const string ActionDispatchCompleted      = "action.dispatch.completed";       // runner returned OK
    public const string ActionDispatchRunnerFailed   = "action.dispatch.runner-failed";   // runner threw

    // Per-capability dedicated runner queue (out-of-process isolation).
    // Worker's WipeForwardingRunner enqueues here; WipeActionConsumerFunction on
    // the wipe-runner Function App consumes and invokes the real WipeActionRunner.
    public const string ActionForwarded              = "action.forwarded";                // worker → wipe-runner queue
    public const string WipeActionConsumed           = "wipe.action.consumed";            // wipe app received envelope
    public const string WipeActionInvalidEnvelope    = "wipe.action.invalid-envelope";    // JSON malformed on wipe app
    public const string WipeActionCompleted          = "wipe.action.completed";           // runner returned OK on wipe app
    public const string WipeActionRunnerFailed       = "wipe.action.runner-failed";       // runner threw on wipe app

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
        public const string BoundDeviceId    = "boundDeviceId";
        public const string OriginalCorrelationId = "originalCorrelationId";
        public const string ExceptionType    = "exceptionType";
        public const string ExceptionMessage = "exceptionMessage";
        // Inbound request envelope
        public const string CallerIp          = "callerIp";
        public const string UserAgent         = "userAgent";
        public const string RequestSize       = "requestSize";
        public const string ContentType       = "contentType";
        // Wipe execution context
        public const string KeepEnrollmentData = "keepEnrollmentData";
        public const string KeepUserData       = "keepUserData";
        // Wipe action status tracking
        public const string PreviousState    = "previousState";
        public const string CurrentState     = "currentState";
        public const string PollAttempts     = "pollAttempts";
        public const string IssuedAt         = "issuedAt";
        public const string LastChangedAt    = "lastChangedAt";
        // Enriched device snapshot from Graph (during polling)
        public const string GraphActionStartedAt    = "graphActionStartedAt";
        public const string GraphActionLastUpdated  = "graphActionLastUpdated";
        public const string DeviceLastSync          = "deviceLastSyncDateTime";
        public const string DeviceComplianceState   = "deviceComplianceState";
        public const string DeviceOsVersion         = "deviceOsVersion";
        public const string DeviceOperatingSystem   = "deviceOperatingSystem";
        public const string MinutesSinceLastSync    = "minutesSinceLastSync";
        // Plug-in dispatch
        public const string ActionType              = "actionType";
        public const string SchemaVersion           = "schemaVersion";
        // Ledger / rearm context
        public const string WipeSequence            = "wipeSequence";
        public const string PreviousTerminalState   = "previousTerminalState";
        public const string PreviousIssuedAt        = "previousIssuedAt";
        public const string RearmReason             = "rearmReason";
        public const string ForceRearm              = "forceRearm";
        public const string RecentWipesInWindow     = "recentWipesInWindow";
        public const string MaxWipesPerDevicePerDay = "maxWipesPerDevicePerDay";
        public const string GracePeriodHours        = "gracePeriodHours";
        public const string AgeSinceTerminalHours   = "ageSinceTerminalHours";
        // Admin context
        public const string AdminReason             = "adminReason";
        public const string Actor                   = "actor";
        public const string AdminCallerIp           = "adminCallerIp";
        public const string ArchiveBlobName         = "archiveBlobName";
        // Post-wipe nudge retry context
        public const string AttemptNumber           = "attemptNumber";
        public const string MaxAttempts             = "maxAttempts";
        public const string BackoffMs               = "backoffMs";
    }
}
