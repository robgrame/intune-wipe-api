using System.Text.Json;
using FluentAssertions;
using IntuneDeviceActions.Models;
using Xunit;

namespace IntuneDeviceActions.Shared.Tests.Models;

/// <summary>
/// Guards the action-agnostic contract: any top-level JSON property on the
/// request body that is NOT one of the four core fields must be captured into
/// <see cref="ActionRequest.Extras"/> and survive end-to-end through
/// <see cref="ActionRequestMessage"/> without the Shared core knowing its
/// shape. These tests are the regression net for the immutable-core rule
/// documented in .github/copilot-instructions.md.
/// </summary>
public sealed class ActionRequestExtrasTests
{
    private static readonly JsonSerializerOptions WebOptions = new(JsonSerializerDefaults.Web);

    [Fact]
    public void Deserialize_captures_unknown_top_level_property_into_Extras()
    {
        const string body = """
        {
          "actionType":"autopilot-register",
          "deviceName":"PC-01",
          "entraDeviceId":"11111111-1111-1111-1111-111111111111",
          "intuneDeviceId":"22222222-2222-2222-2222-222222222222",
          "autopilot":{"hardwareHash":"BASE64HASH","serialNumber":"SN-01"}
        }
        """;

        var req = JsonSerializer.Deserialize<ActionRequest>(body, WebOptions);

        req.Should().NotBeNull();
        req!.ActionType.Should().Be("autopilot-register");
        req.Extras.Should().NotBeNull().And.ContainKey("autopilot");
        req.Extras!["autopilot"].GetProperty("hardwareHash").GetString().Should().Be("BASE64HASH");
    }

    [Fact]
    public void Deserialize_captures_multiple_unknown_properties_independently()
    {
        const string body = """
        {
          "actionType":"foo",
          "deviceName":"PC-01",
          "entraDeviceId":"11111111-1111-1111-1111-111111111111",
          "intuneDeviceId":"22222222-2222-2222-2222-222222222222",
          "foo":{"x":1},
          "bar":"hello"
        }
        """;

        var req = JsonSerializer.Deserialize<ActionRequest>(body, WebOptions)!;

        req.Extras.Should().ContainKeys("foo", "bar");
        req.Extras!["foo"].GetProperty("x").GetInt32().Should().Be(1);
        req.Extras["bar"].GetString().Should().Be("hello");
    }

    [Fact]
    public void Deserialize_with_no_extras_leaves_Extras_null()
    {
        const string body = """
        {
          "actionType":"wipe",
          "deviceName":"PC-01",
          "entraDeviceId":"11111111-1111-1111-1111-111111111111",
          "intuneDeviceId":"22222222-2222-2222-2222-222222222222"
        }
        """;

        var req = JsonSerializer.Deserialize<ActionRequest>(body, WebOptions)!;

        req.Extras.Should().BeNull();
    }

    [Fact]
    public void Extras_survives_round_trip_through_ActionRequestMessage()
    {
        const string clientBody = """
        {
          "actionType":"autopilot-register",
          "deviceName":"PC-01",
          "entraDeviceId":"11111111-1111-1111-1111-111111111111",
          "intuneDeviceId":"22222222-2222-2222-2222-222222222222",
          "autopilot":{"hardwareHash":"H","serialNumber":"S","groupTag":"G"}
        }
        """;

        var req = JsonSerializer.Deserialize<ActionRequest>(clientBody, WebOptions)!;
        var msg = new ActionRequestMessage
        {
            ActionType     = req.ActionType,
            DeviceName     = req.DeviceName!,
            EntraDeviceId  = req.EntraDeviceId!,
            IntuneDeviceId = req.IntuneDeviceId!,
            CorrelationId  = "corr-1",
            Extras         = req.Extras,
        };

        var sbJson = JsonSerializer.Serialize(msg);
        var msg2   = JsonSerializer.Deserialize<ActionRequestMessage>(sbJson)!;

        msg2.Extras.Should().NotBeNull().And.ContainKey("autopilot");
        var autopilot = msg2.Extras!["autopilot"];
        autopilot.GetProperty("hardwareHash").GetString().Should().Be("H");
        autopilot.GetProperty("serialNumber").GetString().Should().Be("S");
        autopilot.GetProperty("groupTag").GetString().Should().Be("G");
    }

    [Fact]
    public void Serialize_emits_extras_as_top_level_properties_not_under_an_Extras_key()
    {
        // Regression guard: if someone removes [JsonExtensionData] the field
        // would emit as "Extras": { ... } and silently break every existing
        // client. This test fails fast in that scenario.
        var req = new ActionRequest
        {
            ActionType     = "autopilot-register",
            DeviceName     = "PC-01",
            EntraDeviceId  = "11111111-1111-1111-1111-111111111111",
            IntuneDeviceId = "22222222-2222-2222-2222-222222222222",
            Extras = new Dictionary<string, JsonElement>
            {
                ["autopilot"] = JsonDocument.Parse("""{"hardwareHash":"H"}""").RootElement,
            },
        };

        var json = JsonSerializer.Serialize(req, WebOptions);

        json.Should().Contain("\"autopilot\":{\"hardwareHash\":\"H\"}");
        json.Should().NotContain("\"extras\":");
        json.Should().NotContain("\"Extras\":");
    }
}
