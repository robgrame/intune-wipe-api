using FluentAssertions;
using IntuneDeviceActions.Services;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace IntuneDeviceActions.Shared.Tests.Services;

public sealed class ActionStatusPollingSettingsTests
{
    [Fact]
    public void GetMinPollIntervalSeconds_UsesDefaultOfFiveSeconds()
    {
        var cfg = new ConfigurationBuilder().AddInMemoryCollection().Build();

        ActionStatusPollingSettings.GetMinPollIntervalSeconds(cfg).Should().Be(5);
    }

    [Fact]
    public void GetMinPollIntervalSeconds_ClampsInvalidValues()
    {
        var cfg = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { ["ActionStatus:MinPollIntervalSeconds"] = "0" })
            .Build();

        ActionStatusPollingSettings.GetMinPollIntervalSeconds(cfg).Should().Be(1);
    }

    [Fact]
    public void GetPollMaxAgeHours_UsesConfiguredValue()
    {
        var cfg = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { ["ActionStatus:PollMaxAgeHours"] = "12" })
            .Build();

        ActionStatusPollingSettings.GetPollMaxAgeHours(cfg).Should().Be(12);
    }
}
