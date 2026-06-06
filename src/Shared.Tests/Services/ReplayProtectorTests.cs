using FluentAssertions;
using IntuneDeviceActions.Services;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace IntuneDeviceActions.Shared.Tests.Services;

public sealed class ReplayProtectorTests
{
    private static ReplayProtector NewProtector(int? skewSeconds = null)
    {
        var dict = new Dictionary<string, string?>();
        if (skewSeconds is not null) dict["Replay:MaxTimestampSkewSeconds"] = skewSeconds.Value.ToString();
        var cfg = new ConfigurationBuilder().AddInMemoryCollection(dict).Build();
        var cache = new MemoryCache(new MemoryCacheOptions { SizeLimit = 1024 });
        return new ReplayProtector(cache, cfg, NullLogger<ReplayProtector>.Instance);
    }

    private static string NowIso(int offsetSeconds = 0)
        => DateTimeOffset.UtcNow.AddSeconds(offsetSeconds).ToString("o");

    [Theory]
    [InlineData(null, "missing X-Request-Timestamp")]
    [InlineData("",   "missing X-Request-Timestamp")]
    [InlineData("   ","missing X-Request-Timestamp")]
    public void Rejects_missing_timestamp(string? ts, string expectedReasonFragment)
    {
        var p = NewProtector();
        var (ok, reason) = p.Validate(ts, Guid.NewGuid().ToString());
        ok.Should().BeFalse();
        reason.Should().Contain(expectedReasonFragment);
    }

    [Theory]
    [InlineData(null)] [InlineData("")] [InlineData("   ")]
    public void Rejects_missing_nonce(string? nonce)
    {
        var p = NewProtector();
        var (ok, reason) = p.Validate(NowIso(), nonce);
        ok.Should().BeFalse();
        reason.Should().Contain("X-Request-Nonce");
    }

    [Fact]
    public void Rejects_unparseable_timestamp()
    {
        var p = NewProtector();
        var (ok, reason) = p.Validate("not-a-date", Guid.NewGuid().ToString());
        ok.Should().BeFalse();
        reason.Should().Contain("ISO-8601");
    }

    [Fact]
    public void Rejects_non_guid_nonce()
    {
        var p = NewProtector();
        var (ok, reason) = p.Validate(NowIso(), "not-a-guid");
        ok.Should().BeFalse();
        reason.Should().Contain("GUID");
    }

    [Fact]
    public void Rejects_timestamp_beyond_skew_window()
    {
        var p = NewProtector(skewSeconds: 60);
        var (ok, reason) = p.Validate(NowIso(offsetSeconds: -300), Guid.NewGuid().ToString());
        ok.Should().BeFalse();
        reason.Should().Contain("skew");
    }

    [Fact]
    public void Accepts_fresh_request_with_unique_nonce()
    {
        var p = NewProtector();
        var (ok, reason) = p.Validate(NowIso(), Guid.NewGuid().ToString());
        ok.Should().BeTrue();
        reason.Should().BeNull();
    }

    [Fact]
    public void Rejects_replay_of_same_nonce_within_window()
    {
        var p = NewProtector();
        var nonce = Guid.NewGuid().ToString();

        p.Validate(NowIso(), nonce).Ok.Should().BeTrue();
        var (ok, reason) = p.Validate(NowIso(), nonce);

        ok.Should().BeFalse();
        reason.Should().Contain("replay");
    }

    [Fact]
    public void Skew_clamp_floor_30s_enforced()
    {
        // Below the clamp the protector still works — config 1s is clamped to 30s,
        // so a 25s-old request still validates.
        var p = NewProtector(skewSeconds: 1);
        p.Validate(NowIso(offsetSeconds: -25), Guid.NewGuid().ToString()).Ok.Should().BeTrue();
    }
}
