namespace IntuneWipeApi.Actions;

/// <summary>
/// Envelope queued on the <c>action-dispatch</c> storage queue. Decouples the
/// producers (e.g. <c>WipeProcessorFunction</c> after validating an HTTP wipe
/// request) from the concrete action implementation, which is selected at
/// runtime by <see cref="Functions.ActionDispatchFunction"/> via
/// <see cref="ActionRunnerRegistry"/>.
/// </summary>
/// <remarks>
/// <para>
/// The only thing the core dispatcher/router knows about an action is its
/// <see cref="ActionType"/> string and an opaque JSON <see cref="Payload"/>.
/// Adding a new capability (e.g. <c>lock</c>, <c>bitlocker-rotate</c>, …)
/// means dropping in a new <see cref="IActionRunner"/> implementation and a
/// matching producer; the dispatcher, router, queue and HTTP intake never
/// need to change.
/// </para>
/// <para>
/// <b>Versioning</b>: <see cref="SchemaVersion"/> is stamped by the producer
/// so runners can support multiple revisions of the payload contract without
/// a breaking change. Today the only version is <c>"1"</c>.
/// </para>
/// </remarks>
public sealed class ActionDispatchMessage
{
    /// <summary>Schema version of this envelope. Producers must set <c>"1"</c>.</summary>
    public string SchemaVersion { get; set; } = "1";

    /// <summary>The runner type to invoke (matches <see cref="IActionRunner.Type"/>). Required.</summary>
    public string ActionType { get; set; } = string.Empty;

    /// <summary>Cross-pipeline correlation id (mirrors the HTTP request id).</summary>
    public string CorrelationId { get; set; } = string.Empty;

    /// <summary>Display name of the target device (used in audit/logs).</summary>
    public string DeviceName { get; set; } = string.Empty;

    /// <summary>Entra device id of the target device.</summary>
    public string EntraDeviceId { get; set; } = string.Empty;

    /// <summary>Intune device id of the target device.</summary>
    public string IntuneDeviceId { get; set; } = string.Empty;

    /// <summary>When the original HTTP request was accepted.</summary>
    public DateTimeOffset RequestedAt { get; set; } = DateTimeOffset.UtcNow;

    /// <summary>When this dispatch envelope was produced by the dispatcher.</summary>
    public DateTimeOffset DispatchedAt { get; set; } = DateTimeOffset.UtcNow;

    /// <summary>
    /// If <c>true</c>, the router lets exceptions bubble so the storage queue
    /// retry policy kicks in (visibility timeout, dequeueCount, poison queue
    /// after max attempts). Default <c>true</c> for security-critical actions
    /// (wipe). Best-effort runners can opt out by setting this to <c>false</c>
    /// when they enqueue.
    /// </summary>
    public bool FailOnError { get; set; } = true;

    /// <summary>
    /// Per-action-type opaque payload. Producers serialize the concrete shape;
    /// runners deserialize it via <see cref="System.Text.Json.JsonElement"/>.
    /// For the wipe runner this is a <c>WipeQueueMessage</c>; future runners
    /// use whatever shape they need without polluting this envelope.
    /// </summary>
    public System.Text.Json.JsonElement Payload { get; set; }
}
