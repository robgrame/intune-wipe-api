using Azure.Messaging.ServiceBus;

namespace IntuneDeviceActions.Capabilities.Autopilot.Senders;

/// <summary>
/// Thin DI wrapper around a <see cref="ServiceBusSender"/> that targets the
/// per-capability <c>autopilot-action</c> Service Bus queue. This is the
/// boundary between the generic action dispatcher (proc role) and the dedicated
/// autopilot-runner Function App (autopilot role), which consumes this queue
/// exclusively via <c>ServiceBusTrigger</c>.
/// </summary>
/// <remarks>
/// Using a wrapper type avoids ambiguity with the other ServiceBusSender
/// registrations (action-requests, action-dispatch, wipe-action, bitlocker-action).
/// </remarks>
public sealed class AutopilotActionSender
{
    public ServiceBusSender Sender { get; }
    public AutopilotActionSender(ServiceBusSender sender) => Sender = sender;
}
