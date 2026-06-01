namespace IntuneWipeApi.Services;

/// <summary>
/// Defense-in-depth guard that hard-fails functions invoked on the wrong app role.
///
/// The deployment splits a single code base across two Function Apps:
///   - "web"  → only WipeRequest (HTTP, mTLS, no Graph identity)
///   - "proc" → only WipeProcessor (queue trigger, Graph identity)
///
/// The Functions runtime setting <c>AzureWebJobs.&lt;FunctionName&gt;.Disabled</c>
/// does NOT reliably block HTTP triggers in the dotnet-isolated worker model:
/// the HTTP endpoint stays routable and the function-key check happens before
/// the disabled check. Without this guard, an attacker who reaches the worker
/// app's /api/wipe with a valid function key would bypass mTLS *and* execute
/// against the Graph-enabled identity.
///
/// Each function calls <see cref="EnsureRole"/> as its first action.
/// </summary>
public static class AppRoleGuard
{
    public const string Web  = "web";
    public const string Proc = "proc";
    public const string Wipe = "wipe";

    /// <summary>Reads the App__Role environment variable (set by Bicep per Function App).</summary>
    public static string CurrentRole =>
        Environment.GetEnvironmentVariable("App__Role")?.Trim().ToLowerInvariant() ?? string.Empty;

    /// <summary>Returns true if the caller is running on an app whose role matches the expected one.</summary>
    public static bool IsAllowed(string expectedRole) =>
        string.Equals(CurrentRole, expectedRole, StringComparison.OrdinalIgnoreCase);
}
