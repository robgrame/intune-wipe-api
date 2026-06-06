namespace IntuneDeviceActions.Capabilities.Autopilot.Audit;

/// <summary>
/// Autopilot-specific event names emitted to Application Insights customEvents.
/// Keeps its own namespace so the Shared <c>AuditEvents</c> doesn't accumulate
/// per-capability bloat (mirrors <c>WipeAuditEvents</c>/<c>BitLockerAuditEvents</c>).
///
/// KQL convention: <c>customEvents | where name startswith "autopilot."</c>
/// covers every autopilot-specific row; combine with
/// <c>name startswith "action."</c> for the full pipeline picture.
/// </summary>
public static class AutopilotAuditEvents
{
    // Graph importedWindowsAutopilotDeviceIdentities call outcomes
    public const string ImportIssued          = "autopilot.graph.import.issued";
    public const string ImportFailedPermanent = "autopilot.graph.import.failed-permanent";
    public const string ImportTransientError  = "autopilot.graph.import.transient-error";

    // Payload validation
    public const string DeniedMissingHardwareHash = "autopilot.denied.missing-hardware-hash";

    // Autopilot-runner Function App (consumer of the per-capability autopilot-action queue)
    public const string ActionConsumed        = "autopilot.action.consumed";
    public const string ActionInvalidEnvelope = "autopilot.action.invalid-envelope";
    public const string ActionCompleted       = "autopilot.action.completed";
    public const string ActionRunnerFailed    = "autopilot.action.runner-failed";
}
