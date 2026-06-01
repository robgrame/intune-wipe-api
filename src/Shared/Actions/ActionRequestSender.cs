using Azure.Messaging.ServiceBus;

namespace IntuneDeviceActions.Actions;

/// <summary>
/// Thin DI wrapper around a <see cref="ServiceBusSender"/> that targets the
/// <c>action-requests</c> Service Bus queue. Web app uses it to enqueue the
/// initial action request; Proc app consumes it via <c>ServiceBusTrigger</c>
/// (RequestIntakeFunction). Wrapping in a dedicated type avoids ambiguity with
/// the other ServiceBusSender registrations (action-dispatch, wipe-action).
/// </summary>
public sealed class ActionRequestSender
{
    public ServiceBusSender Sender { get; }
    public ActionRequestSender(ServiceBusSender sender) => Sender = sender;
}
