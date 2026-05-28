using Microsoft.ApplicationInsights;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Services;

/// <summary>
/// Emits security/audit events for the wipe pipeline as Application Insights
/// <c>customEvents</c> (queryable as <c>customEvents | where name startswith "wipe."</c>).
///
/// Why not just <see cref="ILogger"/>? Logger traces ride on the same App Insights
/// pipeline as application traces and are subject to adaptive sampling; a destructive
/// operation requires audit evidence to NEVER be dropped. <c>TrackEvent</c> on the
/// telemetry client bypasses adaptive sampling when sampling is disabled on the
/// worker telemetry options (see Program.cs <c>SamplingRatio = 1.0f</c>), and the
/// events are stored in a dedicated table for retention/archival.
///
/// The method also writes an <see cref="ILogger"/> entry at an explicit severity
/// (<see cref="LogLevel.Warning"/> for denials, <see cref="LogLevel.Error"/> for
/// permanent failures, <see cref="LogLevel.Information"/> for acceptance) so that
/// support engineers tailing the live log stream still see security-relevant events
/// at a visible severity even without writing KQL.
/// </summary>
public sealed class AuditService
{
    // Max length retained for raw exception messages to limit risk of
    // accidentally storing oversized payloads (URLs, response bodies, etc.)
    // in App Insights customDimensions.
    private const int MaxExceptionMessageLength = 512;

    private const string AuditMarkerKey = "audit";
    private const string AuditMarkerValue = "true";

    private readonly TelemetryClient _telemetry;
    private readonly ILogger<AuditService> _log;
    private readonly AuditTableSink _tableSink;

    public AuditService(TelemetryClient telemetry, AuditTableSink tableSink, ILogger<AuditService> log)
    {
        _telemetry = telemetry;
        _tableSink = tableSink;
        _log = log;
    }

    public void TrackEvent(
        string eventName,
        IDictionary<string, string>? properties = null,
        LogLevel logLevel = LogLevel.Information)
    {
        var props = properties is null
            ? new Dictionary<string, string>(StringComparer.Ordinal)
            : new Dictionary<string, string>(properties, StringComparer.Ordinal);
        props[AuditMarkerKey] = AuditMarkerValue;

        _telemetry.TrackEvent(eventName, props);
        _tableSink.TrackEvent(eventName, props, logLevel);
        WriteLog(logLevel, eventName, props, exception: null);
    }

    /// <summary>
    /// Convenience overload for events tied to an exception (transient/permanent
    /// failure paths). Exception goes through <see cref="TelemetryClient.TrackException"/>
    /// so it shows up in the exceptions table with the same correlation id; the
    /// raw message is truncated before being stored as a customDimension to limit
    /// leakage of oversized error bodies into App Insights.
    /// </summary>
    public void TrackEvent(
        string eventName,
        Exception exception,
        IDictionary<string, string>? properties = null,
        LogLevel logLevel = LogLevel.Error)
    {
        var props = properties is null
            ? new Dictionary<string, string>(StringComparer.Ordinal)
            : new Dictionary<string, string>(properties, StringComparer.Ordinal);
        props[AuditEvents.Prop.ExceptionType] = exception.GetType().FullName ?? exception.GetType().Name;
        props[AuditEvents.Prop.ExceptionMessage] = Truncate(exception.Message, MaxExceptionMessageLength);
        props[AuditMarkerKey] = AuditMarkerValue;

        _telemetry.TrackEvent(eventName, props);
        _telemetry.TrackException(exception, props);
        _tableSink.TrackEvent(eventName, props, logLevel);
        WriteLog(logLevel, eventName, props, exception);
    }

    private void WriteLog(LogLevel level, string eventName, IDictionary<string, string> props, Exception? exception)
    {
        // Scalar placeholders (not {@Properties}) — default Microsoft.Extensions.Logging
        // does not support Serilog-style destructuring; using @ would emit a dictionary
        // ToString() and lose property names. Pull the commonly-queried fields out
        // explicitly so the rendered trace stays readable for ops.
        props.TryGetValue(AuditEvents.Prop.CorrelationId, out var corr);
        props.TryGetValue(AuditEvents.Prop.DeviceName, out var device);
        props.TryGetValue(AuditEvents.Prop.IntuneDeviceId, out var intune);
        props.TryGetValue(AuditEvents.Prop.Reason, out var reason);

        if (exception is null)
        {
            _log.Log(level, "AUDIT {EventName} corr={CorrelationId} device={DeviceName} intune={IntuneDeviceId} reason={Reason}",
                eventName, corr, device, intune, reason);
        }
        else
        {
            _log.Log(level, exception, "AUDIT {EventName} corr={CorrelationId} device={DeviceName} intune={IntuneDeviceId} reason={Reason}",
                eventName, corr, device, intune, reason);
        }
    }

    private static string Truncate(string? value, int max)
    {
        if (string.IsNullOrEmpty(value)) return string.Empty;
        return value.Length <= max ? value : value.Substring(0, max) + "…";
    }
}

