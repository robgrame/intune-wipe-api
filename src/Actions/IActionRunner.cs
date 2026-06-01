namespace IntuneWipeApi.Actions;

/// <summary>
/// Plug-in contract for a single action handler.
/// </summary>
/// <remarks>
/// <para>
/// Concrete runners are registered in DI as <c>IActionRunner</c>; the
/// <see cref="ActionRunnerRegistry"/> indexes them by <see cref="Type"/> at
/// startup and the <see cref="Functions.ActionDispatchFunction"/> resolves
/// the right one for each <see cref="ActionDispatchMessage.ActionType"/>.
/// </para>
/// <para>
/// To add a new capability:
/// </para>
/// <list type="number">
///   <item>Create a new class implementing this interface with a unique <see cref="Type"/>.</item>
///   <item>Register it in <c>Program.cs</c>: <c>services.AddSingleton&lt;IActionRunner, MyRunner&gt;()</c>.</item>
///   <item>Add a producer that enqueues <see cref="ActionDispatchMessage"/> with the matching <c>ActionType</c>.</item>
/// </list>
/// <para>
/// The HTTP intake function, the queue infrastructure, the dispatcher and the
/// router never need to be touched.
/// </para>
/// </remarks>
public interface IActionRunner
{
    /// <summary>
    /// Stable string that identifies this action across the wire. Compared
    /// case-insensitively against <see cref="ActionDispatchMessage.ActionType"/>.
    /// </summary>
    string Type { get; }

    /// <summary>
    /// Execute the action for the given envelope.
    /// </summary>
    /// <remarks>
    /// Throwing a transient exception is the contract for "let the queue retry
    /// me". Throwing for a permanent error is fine only if
    /// <see cref="ActionDispatchMessage.FailOnError"/> is true on the
    /// envelope; otherwise the router swallows and logs.
    /// </remarks>
    Task RunAsync(ActionDispatchMessage message, CancellationToken ct);
}
