using IntuneDeviceActions.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Functions;

/// <summary>
/// Timer-triggered poller that drives the wipe-action status tracking loop.
/// Runs every 5 seconds by default (configurable via <c>ActionStatusPoller:CronExpression</c>).
/// </summary>
/// <remarks>
/// <para>
/// Reads all non-terminal rows from the <c>wipestatus</c> table and asks Graph
/// for the current <c>deviceActionResults[wipe].actionState</c>. State changes
/// are recorded to the audit pipeline (App Insights + auditevents table).
/// </para>
/// <para>
/// Singleton: Functions runtime guarantees only one instance of a timer
/// trigger runs across all worker instances, so we don't need to coordinate
/// poll passes across scaled-out workers.
/// </para>
/// </remarks>
public sealed class ActionStatusPollerFunction
{
    private readonly ActionStatusTracker _tracker;
    private readonly ILogger<ActionStatusPollerFunction> _log;

    public ActionStatusPollerFunction(ActionStatusTracker tracker, ILogger<ActionStatusPollerFunction> log)
    {
        _tracker = tracker;
        _log = log;
    }

    // NCRONTAB: every 5 seconds (sec min hour day month dayOfWeek). Override
    // with %ActionStatusPoller:CronExpression% app setting if needed.
    [Function("ActionStatusPoller")]
    public async Task Run(
        [TimerTrigger("%ActionStatusPoller:CronExpression%")] TimerInfo timer,
        CancellationToken ct)
    {
        if (!_tracker.IsEnabled)
        {
            _log.LogDebug("ActionStatusPoller skipped: tracker not configured");
            return;
        }

        var processed = 0;
        var transitions = 0;
        await foreach (var row in _tracker.EnumeratePendingAsync(ct))
        {
            ct.ThrowIfCancellationRequested();
            var beforeState = row.GetString("LastState");
            try
            {
                await _tracker.PollOneAsync(row, ct);
                processed++;
                // The row object is updated in-place by PollOneAsync for the
                // audit emit; cheap state-change detection.
                var afterState = row.GetString("LastState");
                if (!string.Equals(beforeState, afterState, StringComparison.OrdinalIgnoreCase))
                {
                    transitions++;
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "ActionStatusPoller: unhandled error on {PK}", row.PartitionKey);
            }
        }

        _log.LogInformation("ActionStatusPoller tick: polled={Polled} transitions={Transitions}", processed, transitions);
    }
}
