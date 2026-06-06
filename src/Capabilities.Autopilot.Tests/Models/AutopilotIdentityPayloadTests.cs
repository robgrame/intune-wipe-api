using System.Text.Json;
using FluentAssertions;
using IntuneDeviceActions.Capabilities.Autopilot.Models;
using Xunit;

namespace IntuneDeviceActions.Capabilities.Autopilot.Tests.Models;

public sealed class AutopilotIdentityPayloadTests
{
    [Fact]
    public void ExtrasKey_matches_wire_property_name_used_by_client()
    {
        // The client (Invoke-AutopilotRegister.ps1) sends the payload under the
        // top-level "autopilot" key; the runner reads it via this constant.
        // A drift here silently breaks every device. Pin it.
        AutopilotIdentityPayload.ExtrasKey.Should().Be("autopilot");
    }

    [Fact]
    public void Json_uses_camelCase_property_names_matching_client_wire_format()
    {
        var payload = new AutopilotIdentityPayload
        {
            HardwareHash              = "H",
            SerialNumber              = "S",
            ProductKey                = "PK",
            GroupTag                  = "Corp",
            AssignedUserPrincipalName = "u@example.com",
        };

        var json = JsonSerializer.Serialize(payload);

        json.Should().Contain("\"hardwareHash\":\"H\"");
        json.Should().Contain("\"serialNumber\":\"S\"");
        json.Should().Contain("\"productKey\":\"PK\"");
        json.Should().Contain("\"groupTag\":\"Corp\"");
        json.Should().Contain("\"assignedUserPrincipalName\":\"u@example.com\"");
    }

    [Fact]
    public void Deserializes_minimal_payload_with_only_hardware_hash()
    {
        var p = JsonSerializer.Deserialize<AutopilotIdentityPayload>("""{"hardwareHash":"H"}""")!;

        p.HardwareHash.Should().Be("H");
        p.SerialNumber.Should().BeNull();
        p.ProductKey.Should().BeNull();
        p.GroupTag.Should().BeNull();
        p.AssignedUserPrincipalName.Should().BeNull();
    }
}
