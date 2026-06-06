using IntuneDeviceActions.Services;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Actions;

/// <summary>
/// Data-driven registration of <see cref="RunbookWebhookRunner"/> instances
/// based on the <see cref="RoutesSection"/> configuration section.
/// </summary>
/// <remarks>
/// <para>
/// This is the "plug-in attach mechanism" for Azure Automation runbooks: a
/// new runbook-backed capability is attached to the Service Bus by adding a
/// single key to App Configuration, with no new code and no changes to the
/// core (Shared / Web / Proc / existing capability projects).
/// </para>
/// <para>
/// Convention (App Configuration keys):
/// <code>
/// RunbookBridge:Routes:&lt;actionType&gt; = &lt;https-webhook-uri&gt;
/// </code>
/// Example:
/// <code>
/// RunbookBridge:Routes:wipe-runbook        = https://&lt;automation-uri&gt;
/// RunbookBridge:Routes:lock-runbook        = https://&lt;automation-uri&gt;
/// RunbookBridge:Routes:bitlocker-runbook   = https://&lt;automation-uri&gt;
/// </code>
/// </para>
/// <para>
/// At host build time (typically inside <c>AddIntuneDeviceActionsCore</c>),
/// this extension enumerates the section, validates each entry and registers
/// one <see cref="IActionRunner"/> per route. The dispatcher
/// <c>ActionDispatchFunction</c> then resolves them by <c>actionType</c> just
/// like any other plug-in runner — the dispatcher does not know runbooks
/// exist.
/// </para>
/// </remarks>
public static class RunbookBridgeExtensions
{
    /// <summary>Configuration section enumerating the runbook routes.</summary>
    public const string RoutesSection = "RunbookBridge:Routes";

    /// <summary>
    /// Reads the <see cref="RoutesSection"/> from <paramref name="cfg"/> and
    /// registers a <see cref="RunbookWebhookRunner"/> for each non-empty entry.
    /// Invalid entries (missing URL, non-HTTPS, malformed URI) are skipped with
    /// a warning instead of failing host build — so a typo in one route never
    /// takes the whole app down.
    /// </summary>
    public static IServiceCollection AddRunbookBridgeRunners(this IServiceCollection services, IConfiguration cfg)
    {
        var section = cfg.GetSection(RoutesSection);
        var registered = 0;
        var skipped    = 0;

        foreach (var child in section.GetChildren())
        {
            var actionType = child.Key?.Trim();
            var webhookUrl = child.Value?.Trim();

            if (string.IsNullOrWhiteSpace(actionType) || string.IsNullOrWhiteSpace(webhookUrl))
            {
                skipped++;
                continue;
            }
            if (!Uri.TryCreate(webhookUrl, UriKind.Absolute, out var parsed)
                || parsed.Scheme != Uri.UriSchemeHttps)
            {
                skipped++;
                continue;
            }

            // Capture by value for the factory closure.
            var capturedType = actionType;
            var capturedUrl  = webhookUrl;
            services.AddSingleton<IActionRunner>(sp =>
                new RunbookWebhookRunner(
                    capturedType,
                    capturedUrl,
                    sp.GetRequiredService<AuditService>(),
                    sp.GetRequiredService<ILogger<RunbookWebhookRunner>>()));
            registered++;
        }

        // Emit a one-shot informational log on first resolution of the
        // ActionRunnerRegistry. We piggy-back on a marker singleton so the
        // counts surface even when no runner is invoked.
        services.AddSingleton(new RunbookBridgeRegistrationSummary(registered, skipped));
        return services;
    }
}

/// <summary>
/// Internal marker captured at host build time so logs / diagnostics can
/// report how many runbook routes were registered. Resolved by
/// <see cref="ActionRunnerRegistry"/> via constructor injection is not
/// necessary — this is purely a diagnostic record.
/// </summary>
public sealed record RunbookBridgeRegistrationSummary(int Registered, int Skipped);
