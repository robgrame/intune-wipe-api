namespace IntuneDeviceActions.Capabilities.BitLocker.Audit;

/// <summary>
/// BitLocker-specific event names and property keys emitted to Application
/// Insights customEvents. Lives alongside the bitlocker capability so it keeps
/// its own namespace and the Shared <c>AuditEvents</c> doesn't accumulate
/// per-capability bloat (mirrors <c>WipeAuditEvents</c>).
///
/// KQL convention: <c>customEvents | where name startswith "bitlocker."</c>
/// covers every bitlocker-specific row; combine with
/// <c>name startswith "action."</c> for the full pipeline picture.
/// </summary>
public static class BitLockerAuditEvents
{
    // Graph rotateBitLockerKeys call outcomes
    public const string RotateIssued          = "bitlocker.graph.rotate.issued";
    public const string RotateFailedPermanent = "bitlocker.graph.rotate.failed-permanent";
    public const string RotateTransientError  = "bitlocker.graph.rotate.transient-error";

    // BitLocker-runner Function App (consumer of the per-capability bitlocker-action queue)
    public const string ActionConsumed        = "bitlocker.action.consumed";
    public const string ActionInvalidEnvelope = "bitlocker.action.invalid-envelope";
    public const string ActionCompleted       = "bitlocker.action.completed";
    public const string ActionRunnerFailed    = "bitlocker.action.runner-failed";
}
