using Azure.Messaging.ServiceBus;

namespace IntuneDeviceActions.Actions;

/// <summary>
/// Thin DI wrapper around a <see cref="ServiceBusSender"/> that targets the
/// per-capability <c>wipe-action</c> Service Bus queue. This is the boundary
/// between the generic action dispatcher (worker role) and the dedicated
/// wipe-runner Function App (wipe role), which consumes this queue
/// exclusively via <c>ServiceBusTrigger</c>.
/// </summary>
/// <remarks>
/// Using a wrapper type avoids ambiguity with the other ServiceBusSender
/// registrations (action-requests, action-dispatch).
/// </remarks>
public sealed class WipeActionSender
{
    public ServiceBusSender Sender { get; }
    public WipeActionSender(ServiceBusSender sender) => Sender = sender;
}
