using Azure.Messaging.ServiceBus;

namespace IntuneDeviceActions.Capabilities.BitLocker.Senders;

/// <summary>
/// Thin DI wrapper around a <see cref="ServiceBusSender"/> that targets the
/// per-capability <c>bitlocker-action</c> Service Bus queue. This is the
/// boundary between the generic action dispatcher (proc role) and the dedicated
/// bitlocker-runner Function App (bitlocker role), which consumes this queue
/// exclusively via <c>ServiceBusTrigger</c>.
/// </summary>
/// <remarks>
/// Using a wrapper type avoids ambiguity with the other ServiceBusSender
/// registrations (action-requests, action-dispatch, wipe-action, autopilot-action).
/// </remarks>
public sealed class BitLockerActionSender
{
    public ServiceBusSender Sender { get; }
    public BitLockerActionSender(ServiceBusSender sender) => Sender = sender;
}
