namespace IntuneDeviceActions.Services;

/// <summary>
/// Canonical, capability-agnostic event names emitted to Application Insights
/// customEvents by the action pipeline (Web → Service Bus → Proc → … → runner).
///
/// All values are namespaced under <c>action.*</c> on purpose so the KQL query
/// <c>customEvents | where name startswith "action."</c> covers every
/// generic step of the pipeline — request intake, denial, dispatch, polling,
/// ledger lifecycle — regardless of which concrete capability (wipe, lock,
/// retire, …) was being executed.
///
/// Capability-specific events live alongside their capability (e.g.
/// <c>IntuneDeviceActions.Capabilities.Wipe.Audit.WipeAuditEvents</c> with
/// <c>wipe.*</c> values for Graph wipe + nudges + wipe-runner consumer).
///
/// Keep names stable — workbooks, alerts, and KQL queries depend on them.
/// </summary>
public static class AuditEvents
{
    // ---- Web (HTTP intake) ------------------------------------------------
    public const string RequestReceived = "action.request.received";
    public const string RequestAccepted = "action.request.accepted";

    public const string DeniedReplay                 = "action.denied.replay";
    public const string DeniedCertValidation         = "action.denied.cert-validation";
    public const string DeniedCertBindingMissing     = "action.denied.cert-binding-missing";
    public const string DeniedCertDeviceMismatch     = "action.denied.cert-device-mismatch";
    public const string DeniedPayloadInvalid         = "action.denied.payload-invalid";
    public const string DeniedActionTypeNotAllowed   = "action.denied.type-not-allowed";
    public const string ExtrasReservedKeyStripped    = "action.request.extras-reserved-key-stripped";

    // ---- Proc (queue path, generic preflight / dispatch) ------------------
    public const string DeniedDeviceResolveFailed        = "action.denied.device-resolve-failed";
    public const string DeniedDeviceNotInEntra           = "action.denied.device-not-in-entra";
    public const string DeniedGroupCheckFailed           = "action.denied.group-check-failed";
    public const string DeniedNotInAllowedGroup          = "action.denied.not-in-allowed-group";
    public const string DeniedManagedDeviceResolveFailed = "action.denied.managed-device-resolve-failed";
    public const string DeniedOwnershipMismatch          = "action.denied.ownership-mismatch";
    public const string DeniedRateLimited                = "action.denied.rate-limited";

    // Idempotency outcomes (action-agnostic — emitted by any runner that
    // reserves the ledger before issuing).
    public const string ActionAlreadyIssued        = "action.already-issued";
    public const string ActionInProgressElsewhere  = "action.in-progress-elsewhere";

    // Ledger rearm decisions taken by ActionIdempotencyService when a previous
    // action for the same device has already reached a terminal state. These
    // are the signals operators look at to validate that "test wipe ×N" or
    // "re-action after legitimate failure" flows behave as designed.
    public const string LedgerRearmedAfterSuccess = "action.ledger.rearmed.after-success";
    public const string LedgerRearmedAfterFailure = "action.ledger.rearmed.after-failure";
    public const string LedgerRearmedAfterTimeout = "action.ledger.rearmed.after-timeout";
    public const string LedgerRearmedForced       = "action.ledger.rearmed.forced";
    public const string LedgerRearmConflict       = "action.ledger.rearm-conflict";
    public const string LedgerNoTracker           = "action.ledger.no-tracker";
    public const string LedgerWaitingGrace        = "action.ledger.waiting-grace-period";

    // Admin operations on the ledger (manual reset by SecOps via the Web app).
    public const string LedgerResetManual        = "action.ledger.reset-manual";
    public const string LedgerResetDenied        = "action.ledger.reset-denied";

    // ---- Post-issue action status tracking --------------------------------
    // Polled by ActionStatusPollerFunction every few minutes via the per-
    // capability IActionStatusProbe (e.g. wipe → Graph deviceActionResults).
    public const string ActionStateObserved   = "action.state-observed";   // emitted on every poll, even unchanged
    public const string ActionStateChanged    = "action.state-changed";    // emitted on transition
    public const string ActionCompleted       = "action.completed";        // terminal: done | removedFromIntune
    public const string ActionFailed          = "action.failed";           // terminal: failed | canceled | notSupported
    public const string ActionPollTimeout     = "action.poll-timeout";     // gave up polling after PollMaxAgeHours
    public const string ActionPollError       = "action.poll-error";       // probe call failed (transient)

    // ---- Plug-in dispatch pipeline (action-dispatch queue) ----------------
    // The Web app enqueues an ActionRequestMessage with ActionType="wipe";
    // RequestIntakeFunction (Proc) wraps it in an ActionDispatchMessage that
    // ActionDispatchFunction (Proc) consumes, resolving the matching
    // IActionRunner and invoking it.
    public const string ActionDispatchEnqueued       = "action.dispatch.enqueued";        // producer side
    public const string ActionDispatchReceived       = "action.dispatch.received";        // router consumed envelope
    public const string ActionDispatchNoRunner       = "action.dispatch.no-runner";       // unknown ActionType
    public const string ActionDispatchInvalidEnvelope= "action.dispatch.invalid-envelope";// JSON malformed
    public const string ActionDispatchCompleted      = "action.dispatch.completed";       // runner returned OK
    public const string ActionDispatchRunnerFailed   = "action.dispatch.runner-failed";   // runner threw

    // Per-capability dedicated runner queue (forwarded by a per-capability
    // IActionRunner implementation, e.g. WipeForwardingRunner → wipe-action
    // queue → WipeActionConsumerFunction on the wipe app).
    public const string ActionForwarded              = "action.forwarded";                // proc → per-capability queue

    /// <summary>
    /// Shared property keys (use these consistently so KQL is uniform).
    /// Capability-specific properties live in their own Prop type
    /// (e.g. <c>WipeAuditEvents.Prop</c> for <c>keepEnrollmentData</c>).
    /// </summary>
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

        // Action status tracking
        public const string PreviousState    = "previousState";
        public const string CurrentState     = "currentState";
        public const string PollAttempts     = "pollAttempts";
        public const string IssuedAt         = "issuedAt";
        public const string LastChangedAt    = "lastChangedAt";

        // Enriched device snapshot from the probe (during polling)
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

        // Ledger / rearm context (action-agnostic — any runner that uses
        // ActionIdempotencyService emits these on rearm).
        public const string ActionSequence             = "actionSequence";
        public const string PreviousTerminalState      = "previousTerminalState";
        public const string PreviousIssuedAt           = "previousIssuedAt";
        public const string RearmReason                = "rearmReason";
        public const string ForceRearm                 = "forceRearm";
        public const string RecentActionsInWindow      = "recentActionsInWindow";
        public const string MaxActionsPerDevicePerDay  = "maxActionsPerDevicePerDay";
        public const string GracePeriodHours           = "gracePeriodHours";
        public const string AgeSinceTerminalHours      = "ageSinceTerminalHours";

        // Admin context
        public const string AdminReason             = "adminReason";
        public const string Actor                   = "actor";
        public const string AdminCallerIp           = "adminCallerIp";
        public const string ArchiveBlobName         = "archiveBlobName";

        // Generic retry context (used by any best-effort retry loop, e.g.
        // wipe nudges).
        public const string AttemptNumber           = "attemptNumber";
        public const string MaxAttempts             = "maxAttempts";
        public const string BackoffMs               = "backoffMs";
    }
}
