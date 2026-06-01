using Azure.Messaging.ServiceBus;

namespace IntuneDeviceActions.Actions;

/// <summary>
/// Thin DI wrapper around a <see cref="ServiceBusSender"/> that targets the
/// <c>action-dispatch</c> Service Bus queue. Wrapping in a dedicated type
/// avoids ambiguity with the other ServiceBusSender registrations
/// (action-requests, wipe-action) without resorting to keyed services.
/// </summary>
public sealed class ActionDispatchSender
{
    public ServiceBusSender Sender { get; }
    public ActionDispatchSender(ServiceBusSender sender) => Sender = sender;
}
