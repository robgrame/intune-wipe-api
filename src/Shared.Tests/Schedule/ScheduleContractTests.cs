using FluentAssertions;
using IntuneDeviceActions.Schedule;
using IntuneDeviceActions.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace IntuneDeviceActions.Shared.Tests.Schedule;

/// <summary>
/// Locks down the public surface of the generic schedule contract — the
/// status set semantics that capability providers and the aggregator both
/// depend on, and the aggregator's merge behaviour across providers.
/// </summary>
public sealed class ScheduleContractTests
{
    [Theory]
    [InlineData("scheduled", true)]
    [InlineData("executing", true)]
    [InlineData("SCHEDULED", true)]  // case-insensitive
    [InlineData("draft", false)]
    [InlineData("completed", false)]
    [InlineData("canceled", false)]
    [InlineData("", false)]
    public void WaveStatus_ClientVisible_only_contains_active_states(string status, bool expected)
    {
        WaveStatus.ClientVisible.Contains(status).Should().Be(expected);
    }

    [Theory]
    [InlineData("draft", true)]
    [InlineData("scheduled", true)]
    [InlineData("executing", false)] // operators can't change membership once firing
    [InlineData("completed", false)]
    [InlineData("canceled", false)]
    public void WaveStatus_Mutable_only_contains_pre_execution_states(string status, bool expected)
    {
        WaveStatus.Mutable.Contains(status).Should().Be(expected);
    }

    [Fact]
    public void WaveStatus_IsKnown_accepts_all_constants_and_rejects_unknowns()
    {
        WaveStatus.IsKnown(WaveStatus.Draft).Should().BeTrue();
        WaveStatus.IsKnown(WaveStatus.Scheduled).Should().BeTrue();
        WaveStatus.IsKnown(WaveStatus.Executing).Should().BeTrue();
        WaveStatus.IsKnown(WaveStatus.Completed).Should().BeTrue();
        WaveStatus.IsKnown(WaveStatus.Canceled).Should().BeTrue();
        WaveStatus.IsKnown(null).Should().BeFalse();
        WaveStatus.IsKnown("").Should().BeFalse();
        WaveStatus.IsKnown("bogus").Should().BeFalse();
    }

    [Fact]
    public async Task ScheduleAggregator_returns_null_with_no_providers()
    {
        var agg = new ScheduleAggregator(Array.Empty<IScheduleProvider>(),
            NullLogger<ScheduleAggregator>.Instance);

        agg.HasProviders.Should().BeFalse();
        var r = await agg.GetScheduleAsync(Guid.NewGuid(), null, CancellationToken.None);
        r.Should().BeNull();
    }

    [Fact]
    public async Task ScheduleAggregator_returns_null_for_empty_device_id()
    {
        var agg = new ScheduleAggregator(new[] { new StubProvider("wipe", _ => StubSnapshot(DateTimeOffset.UtcNow.AddHours(1))) },
            NullLogger<ScheduleAggregator>.Instance);

        var r = await agg.GetScheduleAsync(Guid.Empty, null, CancellationToken.None);
        r.Should().BeNull();
    }

    [Fact]
    public async Task ScheduleAggregator_picks_earliest_across_providers()
    {
        var earlier = StubSnapshot(DateTimeOffset.UtcNow.AddHours(1));
        var later = StubSnapshot(DateTimeOffset.UtcNow.AddHours(3));
        var agg = new ScheduleAggregator(new[]
        {
            new StubProvider("autopilot", _ => later),
            new StubProvider("wipe", _ => earlier),
        }, NullLogger<ScheduleAggregator>.Instance);

        var r = await agg.GetScheduleAsync(Guid.NewGuid(), null, CancellationToken.None);
        r.Should().BeSameAs(earlier);
    }

    [Fact]
    public async Task ScheduleAggregator_actionType_filter_picks_matching_provider_only()
    {
        var earlierWipe = StubSnapshot(DateTimeOffset.UtcNow.AddHours(1));
        var laterAutopilot = StubSnapshot(DateTimeOffset.UtcNow.AddHours(3));
        var agg = new ScheduleAggregator(new[]
        {
            new StubProvider("wipe", _ => earlierWipe),
            new StubProvider("autopilot", _ => laterAutopilot),
        }, NullLogger<ScheduleAggregator>.Instance);

        var r = await agg.GetScheduleAsync(Guid.NewGuid(), "autopilot", CancellationToken.None);
        r.Should().BeSameAs(laterAutopilot);
    }

    [Fact]
    public async Task ScheduleAggregator_skips_provider_that_throws_and_returns_others()
    {
        var ok = StubSnapshot(DateTimeOffset.UtcNow.AddHours(2));
        var agg = new ScheduleAggregator(new[]
        {
            new StubProvider("broken", _ => throw new InvalidOperationException("boom")),
            new StubProvider("wipe", _ => ok),
        }, NullLogger<ScheduleAggregator>.Instance);

        var r = await agg.GetScheduleAsync(Guid.NewGuid(), null, CancellationToken.None);
        r.Should().BeSameAs(ok);
    }

    private static DeviceScheduleSnapshot StubSnapshot(DateTimeOffset at) => new()
    {
        WaveId = Guid.NewGuid().ToString("D"),
        Name = "test",
        ActionType = "wipe",
        ScheduledAtUtc = at,
        Status = WaveStatus.Scheduled,
        IsImmediate = at <= DateTimeOffset.UtcNow,
    };

    private sealed class StubProvider : IScheduleProvider
    {
        private readonly Func<Guid, DeviceScheduleSnapshot?> _fn;
        public StubProvider(string actionType, Func<Guid, DeviceScheduleSnapshot?> fn)
        {
            ActionType = actionType;
            _fn = fn;
        }
        public string ActionType { get; }
        public Task<DeviceScheduleSnapshot?> GetScheduleAsync(Guid entraDeviceId, CancellationToken ct)
            => Task.FromResult(_fn(entraDeviceId));
    }
}
