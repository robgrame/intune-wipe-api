using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Actions;

/// <summary>
/// Resolves an <see cref="IActionRunner"/> by its <see cref="IActionRunner.Type"/>.
/// Built from all <c>IActionRunner</c> implementations registered in DI.
/// Duplicate types log a warning (last-write-wins is intentional so a custom
/// override can replace a stock runner in test environments).
/// </summary>
public sealed class ActionRunnerRegistry
{
    private readonly Dictionary<string, IActionRunner> _byType;
    private readonly ILogger<ActionRunnerRegistry> _log;

    public ActionRunnerRegistry(IEnumerable<IActionRunner> runners, ILogger<ActionRunnerRegistry> log)
    {
        _log = log;
        _byType = new Dictionary<string, IActionRunner>(StringComparer.OrdinalIgnoreCase);
        foreach (var r in runners)
        {
            if (string.IsNullOrWhiteSpace(r.Type))
            {
                _log.LogWarning("Action runner {Impl} has empty Type; ignored", r.GetType().FullName);
                continue;
            }
            if (_byType.TryGetValue(r.Type, out var existing))
            {
                _log.LogWarning("Action runner type '{Type}' already registered by {Existing}; replacing with {New}",
                    r.Type, existing.GetType().FullName, r.GetType().FullName);
            }
            _byType[r.Type] = r;
        }
        _log.LogInformation("ActionRunnerRegistry initialised with {Count} runner(s): {Types}",
            _byType.Count, string.Join(", ", _byType.Keys));
    }

    /// <summary>Returns the runner for <paramref name="type"/>, or <c>null</c> if none is registered.</summary>
    public IActionRunner? Resolve(string? type)
    {
        if (string.IsNullOrWhiteSpace(type)) return null;
        return _byType.TryGetValue(type, out var r) ? r : null;
    }

    /// <summary>Snapshot of registered runner types (for diagnostics).</summary>
    public IReadOnlyCollection<string> KnownTypes => _byType.Keys;
}
