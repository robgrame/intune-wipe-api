using Microsoft.Graph.Models.ODataErrors;

namespace IntuneDeviceActions.Services;

/// <summary>
/// Capability-agnostic Microsoft Graph error classifier shared by every action
/// runner that talks to Graph. Mirrors the original classifier baked into the
/// wipe capability's <c>GraphWipeService.Classify</c>, lifted into Shared so
/// new capabilities (autopilot, bitlocker, …) don't each re-implement (or, worse,
/// take a cross-capability dependency on) the same retry policy.
/// </summary>
/// <remarks>
/// Contract used by the runners: <see cref="GraphErrorKind.Transient"/> means
/// "throw so the Service Bus queue retries me" (408/429/5xx, network/TLS/DNS,
/// cancellation); <see cref="GraphErrorKind.Permanent"/> means "do not retry"
/// (other 4xx). The default for an unknown exception is Transient — a stuck
/// message will eventually dead-letter, which is safer than silently dropping
/// a privileged action on a fluke exception.
/// </remarks>
public static class GraphErrorClassifier
{
    public enum GraphErrorKind { Transient, Permanent }

    /// <summary>
    /// Classifies a Microsoft Graph exception as Transient (retry) or Permanent
    /// (do not retry).
    /// </summary>
    public static GraphErrorKind Classify(Exception ex)
    {
        if (ex is OperationCanceledException) return GraphErrorKind.Transient;

        if (ex is ODataError oe)
        {
            var status = oe.ResponseStatusCode;
            if (status == 408 || status == 429 || status >= 500) return GraphErrorKind.Transient;
            if (status >= 400 && status < 500) return GraphErrorKind.Permanent;
        }

        // Network / DNS / TLS — let it retry.
        if (ex is HttpRequestException or TimeoutException) return GraphErrorKind.Transient;
        return GraphErrorKind.Transient;
    }
}
