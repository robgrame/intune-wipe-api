using FluentAssertions;
using IntuneDeviceActions.Services;
using Microsoft.Graph.Models.ODataErrors;
using Xunit;

namespace IntuneDeviceActions.Shared.Tests.Services;

/// <summary>
/// Guards the Graph error retry policy shared by every capability runner.
/// 408/429/5xx + network/cancellation → Transient (queue retries);
/// other 4xx → Permanent (no retry); unknown → Transient (fail-safe).
/// </summary>
public sealed class GraphErrorClassifierTests
{
    [Theory]
    [InlineData(400)] [InlineData(401)] [InlineData(403)]
    [InlineData(404)] [InlineData(405)] [InlineData(409)]
    public void Permanent_for_non_retryable_4xx(int status)
    {
        var ex = new ODataError { ResponseStatusCode = status };
        GraphErrorClassifier.Classify(ex).Should().Be(GraphErrorClassifier.GraphErrorKind.Permanent);
    }

    [Theory]
    [InlineData(408)] [InlineData(429)]
    [InlineData(500)] [InlineData(502)] [InlineData(503)] [InlineData(504)]
    public void Transient_for_retryable_status_codes(int status)
    {
        var ex = new ODataError { ResponseStatusCode = status };
        GraphErrorClassifier.Classify(ex).Should().Be(GraphErrorClassifier.GraphErrorKind.Transient);
    }

    [Fact]
    public void Transient_for_OperationCanceled()
    {
        GraphErrorClassifier.Classify(new OperationCanceledException())
            .Should().Be(GraphErrorClassifier.GraphErrorKind.Transient);
    }

    [Fact]
    public void Transient_for_HttpRequestException_and_TimeoutException()
    {
        GraphErrorClassifier.Classify(new HttpRequestException("network down"))
            .Should().Be(GraphErrorClassifier.GraphErrorKind.Transient);
        GraphErrorClassifier.Classify(new TimeoutException())
            .Should().Be(GraphErrorClassifier.GraphErrorKind.Transient);
    }

    [Fact]
    public void Default_is_Transient_for_unknown_exception()
    {
        // Fail-safe: a stuck message dead-letters eventually, which beats
        // silently dropping a privileged action on a fluke exception.
        GraphErrorClassifier.Classify(new InvalidOperationException("?"))
            .Should().Be(GraphErrorClassifier.GraphErrorKind.Transient);
    }
}
