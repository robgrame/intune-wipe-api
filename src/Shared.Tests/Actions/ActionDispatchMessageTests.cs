using System.Text.Json;
using FluentAssertions;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Models;
using Xunit;

namespace IntuneDeviceActions.Shared.Tests.Actions;

public sealed class ActionDispatchMessageTests
{
    [Fact]
    public void Defaults_are_safe_for_security_critical_actions()
    {
        var env = new ActionDispatchMessage();

        env.SchemaVersion.Should().Be("1");
        env.FailOnError.Should().BeTrue("default opts security-critical actions into queue retry");
        env.ActionType.Should().BeEmpty();
        env.CorrelationId.Should().BeEmpty();
    }

    [Fact]
    public void Payload_remains_opaque_JsonElement_so_core_never_binds_to_capability_types()
    {
        var inner = new ActionRequestMessage
        {
            ActionType     = "autopilot-register",
            DeviceName     = "PC-01",
            EntraDeviceId  = "11111111-1111-1111-1111-111111111111",
            IntuneDeviceId = "22222222-2222-2222-2222-222222222222",
            CorrelationId  = "c-1",
            Extras = new Dictionary<string, JsonElement>
            {
                ["autopilot"] = JsonDocument.Parse("""{"hardwareHash":"H"}""").RootElement,
            },
        };

        var env = new ActionDispatchMessage
        {
            ActionType    = inner.ActionType!,
            CorrelationId = inner.CorrelationId,
            Payload       = JsonSerializer.SerializeToElement(inner),
        };

        var json = JsonSerializer.Serialize(env);
        var env2 = JsonSerializer.Deserialize<ActionDispatchMessage>(json)!;
        var inner2 = env2.Payload.Deserialize<ActionRequestMessage>()!;

        inner2.ActionType.Should().Be("autopilot-register");
        inner2.Extras.Should().ContainKey("autopilot");
        inner2.Extras!["autopilot"].GetProperty("hardwareHash").GetString().Should().Be("H");
    }
}
