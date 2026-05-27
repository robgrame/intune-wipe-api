using System.Text.Json;
using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.Extensions.Logging;

namespace IntuneWipeApi.Services;

/// <summary>
/// Conditional write-based idempotency ledger. One blob per Intune device id.
/// Blob lifecycle:
///   - reserve: create blob with If-None-Match="*" → returns Reserved
///                if 409 → read existing, return current state (Reserved, Issued, Failed)
///   - markIssued / markFailed: overwrite blob content with the new state
/// </summary>
public sealed class IdempotencyService
{
    public enum State { New, Reserved, Issued, Failed }

    private readonly BlobContainerClient _container;
    private readonly ILogger<IdempotencyService> _log;

    public IdempotencyService(BlobContainerClient container, ILogger<IdempotencyService> log)
    {
        _container = container;
        _log = log;
    }

    public sealed class Entry
    {
        public string IntuneDeviceId { get; set; } = string.Empty;
        public string CorrelationId { get; set; } = string.Empty;
        public string State { get; set; } = nameof(IdempotencyService.State.Reserved);
        public DateTimeOffset ReservedAt { get; set; } = DateTimeOffset.UtcNow;
        public DateTimeOffset? IssuedAt { get; set; }
        public DateTimeOffset? FailedAt { get; set; }
        public string? FailureReason { get; set; }
        public int Attempts { get; set; } = 1;
    }

    public async Task<(State currentState, Entry entry)> ReserveAsync(
        string intuneDeviceId, string correlationId, CancellationToken ct)
    {
        // Container is provisioned by Bicep (Azure) or by Program.cs registration (local dev).
        var blob = _container.GetBlobClient(BlobName(intuneDeviceId));

        var entry = new Entry
        {
            IntuneDeviceId = intuneDeviceId,
            CorrelationId = correlationId,
            State = nameof(State.Reserved)
        };
        var bytes = JsonSerializer.SerializeToUtf8Bytes(entry);

        try
        {
            await blob.UploadAsync(
                new BinaryData(bytes),
                new BlobUploadOptions { Conditions = new BlobRequestConditions { IfNoneMatch = ETag.All } },
                cancellationToken: ct);
            return (State.New, entry);
        }
        catch (RequestFailedException ex) when (ex.Status == 409 || ex.Status == 412)
        {
            // Already exists — read current state.
            var existing = await ReadAsync(blob, ct);
            return (ParseState(existing.State), existing);
        }
    }

    public Task MarkIssuedAsync(string intuneDeviceId, string correlationId, CancellationToken ct)
        => UpdateAsync(intuneDeviceId, correlationId, e =>
        {
            e.State = nameof(State.Issued);
            e.IssuedAt = DateTimeOffset.UtcNow;
        }, ct);

    public Task MarkFailedAsync(string intuneDeviceId, string correlationId, string reason, CancellationToken ct)
        => UpdateAsync(intuneDeviceId, correlationId, e =>
        {
            e.State = nameof(State.Failed);
            e.FailedAt = DateTimeOffset.UtcNow;
            e.FailureReason = reason;
        }, ct);

    private async Task UpdateAsync(string intuneDeviceId, string correlationId,
        Action<Entry> mutate, CancellationToken ct)
    {
        var blob = _container.GetBlobClient(BlobName(intuneDeviceId));
        Entry current;
        try
        {
            current = await ReadAsync(blob, ct);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            current = new Entry { IntuneDeviceId = intuneDeviceId, CorrelationId = correlationId };
        }
        current.Attempts++;
        mutate(current);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(current);
        await blob.UploadAsync(new BinaryData(bytes), overwrite: true, cancellationToken: ct);
    }

    private static async Task<Entry> ReadAsync(BlobClient blob, CancellationToken ct)
    {
        var resp = await blob.DownloadContentAsync(ct);
        return JsonSerializer.Deserialize<Entry>(resp.Value.Content.ToStream())
               ?? new Entry();
    }

    private static string BlobName(string intuneDeviceId)
        => $"{intuneDeviceId.ToLowerInvariant()}.json";

    private static State ParseState(string s)
        => Enum.TryParse<State>(s, true, out var v) ? v : State.New;
}
