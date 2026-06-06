using System.Text.Json;
using FluentAssertions;
using IntuneDeviceActions.Models;
using Xunit;

namespace IntuneDeviceActions.Shared.Tests.Models;

/// <summary>
/// Regression tests for the HTTP-boundary sanitiser that prevents an
/// authenticated client from spoofing server-stamped fields (forceRearm,
/// correlationId, requestedAt, clientCertThumbprint, ...) by smuggling
/// them into the opaque ActionRequest.Extras bag. Without
/// SanitizeExtras the round-trip would emit duplicate JSON keys and
/// last-value semantics on the consumer would let the client win.
/// </summary>
public sealed class ActionRequestMessageSanitizeExtrasTests
{
    [Fact]
    public void Returns_null_when_source_is_null()
    {
        ActionRequestMessage.SanitizeExtras(null).Should().BeNull();
    }

    [Fact]
    public void Returns_null_when_source_is_empty()
    {
        ActionRequestMessage.SanitizeExtras(new Dictionary<string, JsonElement>())
            .Should().BeNull();
    }

    [Fact]
    public void Returns_null_when_every_key_is_reserved_and_stripped()
    {
        var src = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(
            """{"forceRearm":true,"correlationId":"x"}""")!;
        var dropped = new List<string>();

        var result = ActionRequestMessage.SanitizeExtras(src, dropped);

        result.Should().BeNull();
        dropped.Should().BeEquivalentTo(new[] { "forceRearm", "correlationId" });
    }

    [Fact]
    public void Keeps_capability_payload_intact()
    {
        var src = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(
            """{"autopilot":{"hardwareHash":"AA"},"bitlocker":{"recoveryKey":"BB"}}""")!;

        var result = ActionRequestMessage.SanitizeExtras(src)!;

        result.Should().ContainKey("autopilot");
        result.Should().ContainKey("bitlocker");
        result["autopilot"].GetProperty("hardwareHash").GetString().Should().Be("AA");
    }

    [Theory]
    [InlineData("forceRearm")]
    [InlineData("ForceRearm")]
    [InlineData("FORCEREARM")]
    [InlineData("correlationId")]
    [InlineData("requestedAt")]
    [InlineData("clientCertThumbprint")]
    [InlineData("actionType")]
    [InlineData("deviceName")]
    [InlineData("entraDeviceId")]
    [InlineData("intuneDeviceId")]
    public void Strips_reserved_key_case_insensitively(string spoofKey)
    {
        var src = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(
            "{\"" + spoofKey + "\":true,\"autopilot\":{\"hardwareHash\":\"AA\"}}")!;
        var dropped = new List<string>();

        var result = ActionRequestMessage.SanitizeExtras(src, dropped)!;

        result.Should().NotContainKey(spoofKey);
        result.Should().ContainKey("autopilot");
        dropped.Should().ContainSingle().Which.Should().Be(spoofKey);
    }

    [Fact]
    public void Sanitized_message_does_not_emit_duplicate_keys_for_spoofed_forceRearm()
    {
        // Simulates the attack: client body declares both the safe top-level
        // shape and a spoofed "forceRearm":true buried in extras. The
        // unsanitised path would round-trip both, last-value wins, and the
        // consumer would observe ForceRearm=true.
        var hostileExtras = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(
            """{"forceRearm":true,"autopilot":{"hardwareHash":"AA"}}""")!;

        var msg = new ActionRequestMessage
        {
            ActionType     = "autopilot-register",
            DeviceName     = "PC-01",
            EntraDeviceId  = "e",
            IntuneDeviceId = "i",
            CorrelationId  = "c",
            RequestedAt    = DateTimeOffset.Parse("2026-06-06T00:00:00Z"),
            ForceRearm     = false, // server-stamped, must survive the round-trip
            Extras         = ActionRequestMessage.SanitizeExtras(hostileExtras),
        };

        var json = JsonSerializer.Serialize(msg);

        // Round-trip back: ForceRearm must remain false despite the hostile input.
        var rehydrated = JsonSerializer.Deserialize<ActionRequestMessage>(json)!;
        rehydrated.ForceRearm.Should().BeFalse("server-stamped value must win after sanitisation");

        // And the capability payload must survive intact.
        rehydrated.Extras.Should().NotBeNull();
        rehydrated.Extras!.Should().ContainKey("autopilot");

        // Defensive: there must be exactly one occurrence of "forceRearm" in
        // the serialised JSON (no duplicate key smuggled by extension data).
        var occurrences = 0;
        var idx = 0;
        while ((idx = json.IndexOf("\"forceRearm\"", idx, StringComparison.Ordinal)) >= 0)
        {
            occurrences++;
            idx += "\"forceRearm\"".Length;
        }
        occurrences.Should().Be(1);
    }

    [Fact]
    public void Round_trip_without_sanitisation_demonstrates_the_attack_works()
    {
        // Pinned regression: this is the BAD behaviour SanitizeExtras prevents.
        // If the production path ever drops the sanitiser, this test will
        // start "passing" with the wrong outcome, which the assertion below
        // catches by failing.
        var hostileExtras = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(
            """{"forceRearm":true}""")!;

        var msg = new ActionRequestMessage
        {
            ForceRearm = false,
            Extras = hostileExtras, // intentionally NOT sanitised — proves the threat is real
        };

        var json = JsonSerializer.Serialize(msg);
        var rehydrated = JsonSerializer.Deserialize<ActionRequestMessage>(json)!;

        // Document the vulnerability: without sanitisation, the client wins.
        rehydrated.ForceRearm.Should().BeTrue(
            "if this ever flips to false, System.Text.Json semantics changed " +
            "and the sanitiser may no longer be strictly required — re-evaluate");
    }
}
