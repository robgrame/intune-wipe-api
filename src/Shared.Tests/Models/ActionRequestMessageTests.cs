using System.Text.Json;
using FluentAssertions;
using IntuneDeviceActions.Models;
using Xunit;

namespace IntuneDeviceActions.Shared.Tests.Models;

public sealed class ActionRequestMessageTests
{
    [Fact]
    public void Defaults_are_safe_for_security_critical_actions()
    {
        var msg = new ActionRequestMessage();

        msg.DeviceName.Should().Be(string.Empty);
        msg.EntraDeviceId.Should().Be(string.Empty);
        msg.IntuneDeviceId.Should().Be(string.Empty);
        msg.CorrelationId.Should().Be(string.Empty);
        msg.ForceRearm.Should().BeFalse("force-rearm must opt-in explicitly");
        msg.RequestedAt.Should().BeAfter(DateTimeOffset.UtcNow.AddMinutes(-1));
    }

    [Fact]
    public void Json_property_names_use_camelCase_and_match_wire_contract()
    {
        var msg = new ActionRequestMessage
        {
            ActionType           = "wipe",
            DeviceName           = "PC-01",
            EntraDeviceId        = "e-1",
            IntuneDeviceId       = "i-1",
            CorrelationId        = "c-1",
            ClientCertThumbprint = "AABB",
            ForceRearm           = true,
        };

        var json = JsonSerializer.Serialize(msg);

        json.Should().Contain("\"actionType\":\"wipe\"");
        json.Should().Contain("\"deviceName\":\"PC-01\"");
        json.Should().Contain("\"entraDeviceId\":\"e-1\"");
        json.Should().Contain("\"intuneDeviceId\":\"i-1\"");
        json.Should().Contain("\"correlationId\":\"c-1\"");
        json.Should().Contain("\"clientCertThumbprint\":\"AABB\"");
        json.Should().Contain("\"forceRearm\":true");
    }

    [Fact]
    public void Backward_compat_pre_refactor_message_without_actionType_round_trips()
    {
        // Legacy in-flight messages produced before ActionType existed: must
        // deserialize cleanly into ActionType=null so the dispatcher's
        // configured default kicks in (preserved by RequestIntakeFunction).
        const string legacy = """
        {
          "deviceName":"PC-01",
          "entraDeviceId":"e",
          "intuneDeviceId":"i",
          "correlationId":"c",
          "requestedAt":"2026-01-01T00:00:00+00:00"
        }
        """;

        var msg = JsonSerializer.Deserialize<ActionRequestMessage>(legacy)!;

        msg.ActionType.Should().BeNull();
        msg.DeviceName.Should().Be("PC-01");
        msg.Extras.Should().BeNull();
    }
}
