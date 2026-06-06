using FluentAssertions;
using IntuneDeviceActions.Actions;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace IntuneDeviceActions.Shared.Tests.Actions;

/// <summary>
/// Guards the registry contract that lets new capabilities plug in without
/// core changes: case-insensitive lookup by string type, unknown types
/// resolve to null, duplicates last-write-wins.
/// </summary>
public sealed class ActionRunnerRegistryTests
{
    private sealed class StubRunner : IActionRunner
    {
        public StubRunner(string type) => Type = type;
        public string Type { get; }
        public Task RunAsync(ActionDispatchMessage message, CancellationToken ct) => Task.CompletedTask;
    }

    [Fact]
    public void Resolve_returns_runner_matching_type_exact()
    {
        var registry = new ActionRunnerRegistry(
            new IActionRunner[] { new StubRunner("wipe"), new StubRunner("autopilot-register") },
            NullLogger<ActionRunnerRegistry>.Instance);

        registry.Resolve("autopilot-register").Should().NotBeNull().And.BeOfType<StubRunner>();
    }

    [Theory]
    [InlineData("WIPE")]
    [InlineData("Wipe")]
    [InlineData("wipe")]
    public void Resolve_is_case_insensitive(string requested)
    {
        var registry = new ActionRunnerRegistry(
            new IActionRunner[] { new StubRunner("wipe") },
            NullLogger<ActionRunnerRegistry>.Instance);

        registry.Resolve(requested).Should().NotBeNull();
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("does-not-exist")]
    public void Resolve_returns_null_for_missing_or_unknown_type(string? requested)
    {
        var registry = new ActionRunnerRegistry(
            new IActionRunner[] { new StubRunner("wipe") },
            NullLogger<ActionRunnerRegistry>.Instance);

        registry.Resolve(requested).Should().BeNull();
    }

    [Fact]
    public void Duplicate_type_registration_replaces_existing_last_write_wins()
    {
        var first  = new StubRunner("wipe");
        var second = new StubRunner("wipe");

        var registry = new ActionRunnerRegistry(
            new IActionRunner[] { first, second },
            NullLogger<ActionRunnerRegistry>.Instance);

        registry.Resolve("wipe").Should().BeSameAs(second);
        registry.KnownTypes.Should().HaveCount(1);
    }

    [Fact]
    public void Empty_type_runner_is_silently_ignored()
    {
        var registry = new ActionRunnerRegistry(
            new IActionRunner[] { new StubRunner(""), new StubRunner("wipe") },
            NullLogger<ActionRunnerRegistry>.Instance);

        registry.KnownTypes.Should().BeEquivalentTo(new[] { "wipe" });
    }

    [Fact]
    public void KnownTypes_reflects_all_registered_runners()
    {
        var registry = new ActionRunnerRegistry(
            new IActionRunner[]
            {
                new StubRunner("wipe"),
                new StubRunner("autopilot-register"),
                new StubRunner("bitlocker-rotate"),
            },
            NullLogger<ActionRunnerRegistry>.Instance);

        registry.KnownTypes.Should().BeEquivalentTo(new[]
        {
            "wipe", "autopilot-register", "bitlocker-rotate",
        });
    }
}
