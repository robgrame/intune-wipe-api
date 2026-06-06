using System.Net;
using System.Text;
using FluentAssertions;
using IntuneDeviceActions.Actions;
using IntuneDeviceActions.Services;
using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.Extensibility;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace IntuneDeviceActions.Shared.Tests.Actions;

/// <summary>
/// Verifies the plug-in attach mechanism for Azure Automation runbooks:
/// adding a new capability runbook is a config-only operation — one App
/// Configuration key under <c>RunbookBridge:Routes</c> is enough to make
/// the dispatcher route a new <c>actionType</c> to a webhook with zero new
/// code in any core or capability project.
/// </summary>
public sealed class RunbookBridgeTests
{
    // ── Helpers ─────────────────────────────────────────────────────────────

    private static IConfiguration BuildConfig(params (string Key, string? Value)[] entries)
        => new ConfigurationBuilder()
            .AddInMemoryCollection(entries.Select(e => new KeyValuePair<string, string?>(e.Key, e.Value)))
            .Build();

    private static AuditService BuildAudit()
    {
        var cfg = new TelemetryConfiguration
        {
            ConnectionString = "InstrumentationKey=00000000-0000-0000-0000-000000000000",
        };
        var telemetry = new TelemetryClient(cfg);
        var sink      = new AuditTableSink(table: null, log: NullLogger<AuditTableSink>.Instance);
        return new AuditService(telemetry, sink, NullLogger<AuditService>.Instance);
    }

    private sealed class CapturingHandler : HttpMessageHandler
    {
        public HttpRequestMessage? LastRequest { get; private set; }
        public string? LastBody { get; private set; }
        public HttpStatusCode StatusCode { get; init; } = HttpStatusCode.OK;
        public string ResponseBody { get; init; } = "{\"jobIds\":[\"00000000-0000-0000-0000-000000000000\"]}";
        public int CallCount { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            CallCount++;
            LastRequest = request;
            LastBody = request.Content is null ? null : await request.Content.ReadAsStringAsync(ct);
            return new HttpResponseMessage(StatusCode)
            {
                Content = new StringContent(ResponseBody, Encoding.UTF8, "application/json"),
            };
        }
    }

    private static ActionDispatchMessage BuildEnvelope(string actionType, string corr = "corr-1") =>
        new()
        {
            CorrelationId  = corr,
            ActionType     = actionType,
            DeviceName     = "PC-001",
            EntraDeviceId  = "abc",
            IntuneDeviceId = "def",
            SchemaVersion  = "1",
            Payload        = System.Text.Json.JsonDocument.Parse("{}").RootElement,
        };

    // ── RunbookWebhookRunner ────────────────────────────────────────────────

    [Fact]
    public async Task Runner_posts_envelope_to_configured_webhook_and_succeeds_on_2xx()
    {
        var handler = new CapturingHandler();
        var runner = new RunbookWebhookRunner(
            actionType: "lock-runbook",
            webhookUrl: "https://contoso-aa.webhook.we.azure-automation.net/webhooks?token=abc",
            audit: BuildAudit(),
            log:   NullLogger<RunbookWebhookRunner>.Instance,
            httpHandler: handler);

        await runner.RunAsync(BuildEnvelope("lock-runbook"), CancellationToken.None);

        handler.CallCount.Should().Be(1);
        handler.LastRequest!.Method.Should().Be(HttpMethod.Post);
        handler.LastRequest.RequestUri!.Host.Should().Be("contoso-aa.webhook.we.azure-automation.net");
        handler.LastBody.Should().Contain("\"corr-1\"").And.Contain("\"lock-runbook\"");
    }

    [Fact]
    public async Task Runner_throws_on_non_success_status_so_the_queue_retries()
    {
        var handler = new CapturingHandler
        {
            StatusCode   = HttpStatusCode.InternalServerError,
            ResponseBody = "boom",
        };
        var runner = new RunbookWebhookRunner(
            actionType: "wipe-runbook",
            webhookUrl: "https://x.webhook.azure-automation.net/?t=abc",
            audit: BuildAudit(),
            log:   NullLogger<RunbookWebhookRunner>.Instance,
            httpHandler: handler);

        var act = async () => await runner.RunAsync(BuildEnvelope("wipe-runbook", "c"), CancellationToken.None);
        await act.Should().ThrowAsync<InvalidOperationException>()
            .Where(e => e.Message.Contains("HTTP 500") && e.Message.Contains("wipe-runbook"));
    }

    [Theory]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData("http://insecure.example.com/hook")]  // non-https
    [InlineData("not-a-uri")]
    public void Runner_constructor_rejects_invalid_webhook_url(string url)
    {
        var act = () => new RunbookWebhookRunner(
            actionType: "x",
            webhookUrl: url,
            audit: BuildAudit(),
            log:   NullLogger<RunbookWebhookRunner>.Instance);
        act.Should().Throw<ArgumentException>().Which.ParamName.Should().Be("webhookUrl");
    }

    [Fact]
    public void Runner_constructor_rejects_empty_actionType()
    {
        var act = () => new RunbookWebhookRunner(
            actionType: "  ",
            webhookUrl: "https://x.example.com/hook",
            audit: BuildAudit(),
            log:   NullLogger<RunbookWebhookRunner>.Instance);
        act.Should().Throw<ArgumentException>().Which.ParamName.Should().Be("actionType");
    }

    // ── RunbookBridgeExtensions ─────────────────────────────────────────────

    [Fact]
    public void AddRunbookBridgeRunners_registers_one_runner_per_config_entry()
    {
        var cfg = BuildConfig(
            ("RunbookBridge:Routes:wipe-runbook",      "https://aa.example.com/hooks?token=1"),
            ("RunbookBridge:Routes:lock-runbook",      "https://aa.example.com/hooks?token=2"),
            ("RunbookBridge:Routes:bitlocker-runbook", "https://aa.example.com/hooks?token=3"));

        var services = new ServiceCollection();
        services.AddSingleton(BuildAudit());
        services.AddLogging();
        services.AddRunbookBridgeRunners(cfg);

        var sp = services.BuildServiceProvider();
        var runners = sp.GetServices<IActionRunner>().ToList();
        runners.Should().HaveCount(3);
        runners.Select(r => r.Type).Should().BeEquivalentTo(new[] { "wipe-runbook", "lock-runbook", "bitlocker-runbook" });
        runners.Should().AllBeOfType<RunbookWebhookRunner>();
    }

    [Fact]
    public void AddRunbookBridgeRunners_skips_invalid_or_empty_entries_without_throwing()
    {
        var cfg = BuildConfig(
            ("RunbookBridge:Routes:valid",       "https://aa.example.com/h"),
            ("RunbookBridge:Routes:empty-url",   ""),
            ("RunbookBridge:Routes:not-uri",     "not-a-uri"),
            ("RunbookBridge:Routes:plain-http",  "http://aa.example.com/h"));

        var services = new ServiceCollection();
        services.AddSingleton(BuildAudit());
        services.AddLogging();
        services.AddRunbookBridgeRunners(cfg);

        var summary = services.BuildServiceProvider().GetRequiredService<RunbookBridgeRegistrationSummary>();
        summary.Registered.Should().Be(1);
        summary.Skipped.Should().Be(3);
    }

    [Fact]
    public void AddRunbookBridgeRunners_is_noop_when_section_missing()
    {
        var cfg = BuildConfig(("UnrelatedSetting", "value"));

        var services = new ServiceCollection();
        services.AddSingleton(BuildAudit());
        services.AddLogging();
        services.AddRunbookBridgeRunners(cfg);

        var sp = services.BuildServiceProvider();
        sp.GetServices<IActionRunner>().Should().BeEmpty();
        sp.GetRequiredService<RunbookBridgeRegistrationSummary>()
          .Should().BeEquivalentTo(new RunbookBridgeRegistrationSummary(0, 0));
    }

    [Fact]
    public void Bridge_runners_integrate_with_ActionRunnerRegistry_for_dispatch_resolution()
    {
        // Proves the end-to-end plug-in flow: routes in App Config → bridge runners
        // → ActionRunnerRegistry → dispatcher Resolve(actionType) finds them.
        var cfg = BuildConfig(
            ("RunbookBridge:Routes:custom-capability", "https://aa.example.com/h?token=z"));

        var services = new ServiceCollection();
        services.AddSingleton(BuildAudit());
        services.AddLogging();
        services.AddRunbookBridgeRunners(cfg);
        services.AddSingleton<ActionRunnerRegistry>();

        var registry = services.BuildServiceProvider().GetRequiredService<ActionRunnerRegistry>();
        registry.KnownTypes.Should().BeEquivalentTo(new[] { "custom-capability" });
        registry.Resolve("custom-capability").Should().BeOfType<RunbookWebhookRunner>();
    }
}
