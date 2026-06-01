using Azure.Storage.Queues;

namespace IntuneWipeApi.Actions;

/// <summary>
/// Thin DI wrapper around the <see cref="QueueClient"/> that targets the
/// per-capability <c>wipe-action</c> queue. This is the boundary between the
/// generic action dispatcher (worker role) and the dedicated wipe-runner
/// Function App (wipe role), which consumes this queue exclusively.
/// </summary>
/// <remarks>
/// Using a wrapper type avoids ambiguity with the other <see cref="QueueClient"/>
/// registrations (wipe-requests, action-dispatch).
/// </remarks>
public sealed class WipeActionQueueClient
{
    public QueueClient Client { get; }
    public WipeActionQueueClient(QueueClient client) => Client = client;
}
