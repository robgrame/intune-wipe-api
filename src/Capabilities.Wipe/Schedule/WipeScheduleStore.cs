using Azure;
using Azure.Data.Tables;
using IntuneDeviceActions.Schedule;
using Microsoft.Extensions.Logging;

namespace IntuneDeviceActions.Capabilities.Wipe.Schedule;

/// <summary>
/// CRUD facade over two Azure Tables that together model "wipe schedule
/// waves":
/// <list type="bullet">
///   <item><description><b>waves table</b> — one row per wave (constant PK,
///   RowKey = wave id).</description></item>
///   <item><description><b>members table</b> — one row per device-in-wave
///   assignment (PK = wave id, RowKey = entra device id).</description></item>
/// </list>
/// <para>
/// Tables are auto-created on first use (lazy, single-flight) so a fresh
/// deployment needs no extra provisioning step.
/// </para>
/// <para>
/// This store lives entirely inside the wipe capability project and is the
/// single source of truth for wipe scheduling. The portal writes to it
/// directly via <c>TableClient</c> (cross-process contract documented on
/// table/column names). The wipe runner reads from it to enforce
/// capability-level temporal gating. The core (Web) never touches it — it
/// only sees <see cref="DeviceScheduleSnapshot"/> via the generic
/// <see cref="IScheduleProvider"/> contract.
/// </para>
/// </summary>
public sealed class WipeScheduleStore
{
    private readonly TableClient _waves;
    private readonly TableClient _members;
    private readonly ILogger<WipeScheduleStore> _log;

    private readonly SemaphoreSlim _ensureGate = new(1, 1);
    private bool _tablesEnsured;

    public WipeScheduleStore(TableClient wavesTable, TableClient membersTable,
        ILogger<WipeScheduleStore> log)
    {
        _waves = wavesTable;
        _members = membersTable;
        _log = log;
    }

    // ----- waves -----------------------------------------------------------

    /// <summary>
    /// Inserts a new wave or replaces an existing one by id. <paramref name="wave"/>
    /// MUST have a non-empty <see cref="WipeScheduleWave.RowKey"/>.
    /// </summary>
    public async Task<WipeScheduleWave> UpsertWaveAsync(
        WipeScheduleWave wave, CancellationToken ct = default)
    {
        if (wave is null) throw new ArgumentNullException(nameof(wave));
        if (string.IsNullOrWhiteSpace(wave.RowKey))
            throw new ArgumentException("RowKey (wave id) must be set.", nameof(wave));
        wave.PartitionKey = WipeScheduleWave.DefaultPartition;
        wave.RowKey = wave.RowKey.ToLowerInvariant();
        if (wave.CreatedAtUtc == default) wave.CreatedAtUtc = DateTimeOffset.UtcNow;
        wave.UpdatedAtUtc = DateTimeOffset.UtcNow;

        await EnsureTablesAsync(ct).ConfigureAwait(false);
        await _waves.UpsertEntityAsync(wave, TableUpdateMode.Replace, ct)
            .ConfigureAwait(false);
        return wave;
    }

    /// <summary>Returns the wave or <c>null</c> if missing.</summary>
    public async Task<WipeScheduleWave?> GetWaveAsync(Guid waveId, CancellationToken ct = default)
    {
        await EnsureTablesAsync(ct).ConfigureAwait(false);
        try
        {
            var resp = await _waves.GetEntityAsync<WipeScheduleWave>(
                WipeScheduleWave.DefaultPartition,
                waveId.ToString("D").ToLowerInvariant(), cancellationToken: ct)
                .ConfigureAwait(false);
            return resp.Value;
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }

    /// <summary>Enumerates all waves ordered by ScheduledAtUtc ascending.</summary>
    public async Task<IReadOnlyList<WipeScheduleWave>> ListWavesAsync(CancellationToken ct = default)
    {
        await EnsureTablesAsync(ct).ConfigureAwait(false);
        var list = new List<WipeScheduleWave>();
        await foreach (var w in _waves.QueryAsync<WipeScheduleWave>(
            $"PartitionKey eq '{WipeScheduleWave.DefaultPartition}'",
            cancellationToken: ct))
        {
            list.Add(w);
        }
        list.Sort((a, b) => a.ScheduledAtUtc.CompareTo(b.ScheduledAtUtc));
        return list;
    }

    /// <summary>
    /// Deletes the wave row AND all its member rows. Best-effort: a partial
    /// failure leaves orphan members in the members table; they are
    /// harmlessly skipped by <see cref="GetScheduleForDeviceAsync"/> (which
    /// re-resolves the wave row and silently drops members pointing at a
    /// missing wave). <see cref="ListMembersAsync"/> does NOT filter
    /// orphans — but it's only called by the portal with a wave id that
    /// must exist, so orphans cannot reach the UI.
    /// </summary>
    public async Task DeleteWaveAsync(Guid waveId, CancellationToken ct = default)
    {
        await EnsureTablesAsync(ct).ConfigureAwait(false);
        var pk = waveId.ToString("D").ToLowerInvariant();

        await foreach (var m in _members.QueryAsync<WipeScheduleWaveMember>(
            $"PartitionKey eq '{pk}'", cancellationToken: ct))
        {
            try
            {
                await _members.DeleteEntityAsync(m.PartitionKey, m.RowKey,
                    cancellationToken: ct).ConfigureAwait(false);
            }
            catch (RequestFailedException ex) when (ex.Status == 404) { /* ok */ }
        }

        try
        {
            await _waves.DeleteEntityAsync(WipeScheduleWave.DefaultPartition, pk,
                cancellationToken: ct).ConfigureAwait(false);
        }
        catch (RequestFailedException ex) when (ex.Status == 404) { /* ok */ }
    }

    // ----- members ---------------------------------------------------------

    /// <summary>
    /// Adds a device to a wave (or refreshes its metadata if already present).
    /// </summary>
    public async Task<WipeScheduleWaveMember> AddMemberAsync(
        Guid waveId, Guid entraDeviceId, string deviceName,
        string? intuneDeviceId = null, string? addedBy = null,
        CancellationToken ct = default)
    {
        if (waveId == Guid.Empty) throw new ArgumentException("Empty wave id.", nameof(waveId));
        if (entraDeviceId == Guid.Empty) throw new ArgumentException("Empty entra device id.", nameof(entraDeviceId));
        if (string.IsNullOrWhiteSpace(deviceName))
            throw new ArgumentException("Device name required.", nameof(deviceName));

        var member = new WipeScheduleWaveMember
        {
            PartitionKey = waveId.ToString("D").ToLowerInvariant(),
            RowKey = entraDeviceId.ToString("D").ToLowerInvariant(),
            DeviceName = deviceName,
            IntuneDeviceId = string.IsNullOrWhiteSpace(intuneDeviceId) ? null : intuneDeviceId,
            AddedBy = addedBy,
            AddedAtUtc = DateTimeOffset.UtcNow,
        };

        await EnsureTablesAsync(ct).ConfigureAwait(false);
        await _members.UpsertEntityAsync(member, TableUpdateMode.Replace, ct)
            .ConfigureAwait(false);
        return member;
    }

    /// <summary>Removes a device from a wave. 404 is success (idempotent).</summary>
    public async Task RemoveMemberAsync(Guid waveId, Guid entraDeviceId, CancellationToken ct = default)
    {
        await EnsureTablesAsync(ct).ConfigureAwait(false);
        try
        {
            await _members.DeleteEntityAsync(
                waveId.ToString("D").ToLowerInvariant(),
                entraDeviceId.ToString("D").ToLowerInvariant(),
                cancellationToken: ct).ConfigureAwait(false);
        }
        catch (RequestFailedException ex) when (ex.Status == 404) { /* ok */ }
    }

    /// <summary>Lists all members of a wave (single partition scan).</summary>
    public async Task<IReadOnlyList<WipeScheduleWaveMember>> ListMembersAsync(
        Guid waveId, CancellationToken ct = default)
    {
        await EnsureTablesAsync(ct).ConfigureAwait(false);
        var list = new List<WipeScheduleWaveMember>();
        var pk = waveId.ToString("D").ToLowerInvariant();
        await foreach (var m in _members.QueryAsync<WipeScheduleWaveMember>(
            $"PartitionKey eq '{pk}'", cancellationToken: ct))
        {
            list.Add(m);
        }
        return list;
    }

    // ----- device → schedule lookup ---------------------------------------

    /// <summary>
    /// Returns the next imminent schedule entry for <paramref name="entraDeviceId"/>,
    /// or null if the device is not enrolled in any client-visible wave.
    /// Implemented as a cross-partition scan on the members table filtered by
    /// RowKey, then per-membership wave resolution. Acceptable for &lt;1000
    /// waves; for larger volumes introduce a reverse-index table.
    /// </summary>
    public async Task<DeviceScheduleSnapshot?> GetScheduleForDeviceAsync(
        Guid entraDeviceId, CancellationToken ct = default)
    {
        if (entraDeviceId == Guid.Empty) return null;
        await EnsureTablesAsync(ct).ConfigureAwait(false);

        var rk = entraDeviceId.ToString("D").ToLowerInvariant();
        var memberships = new List<WipeScheduleWaveMember>();
        await foreach (var m in _members.QueryAsync<WipeScheduleWaveMember>(
            $"RowKey eq '{rk}'", cancellationToken: ct))
        {
            memberships.Add(m);
        }
        if (memberships.Count == 0) return null;

        var candidates = new List<WipeScheduleWave>();
        foreach (var m in memberships)
        {
            if (!Guid.TryParse(m.PartitionKey, out var waveId)) continue;
            var wave = await GetWaveAsync(waveId, ct).ConfigureAwait(false);
            if (wave is null) continue;
            if (!WaveStatus.ClientVisible.Contains(wave.Status)) continue;
            candidates.Add(wave);
        }
        if (candidates.Count == 0) return null;

        // Prioritise the next IMMINENT FUTURE wave over any past wave (a past
        // wave with status still 'scheduled'/'executing' is almost always a
        // stale row the operator forgot to mark completed/canceled — if a
        // newer future wave exists for the same device, that's the operator's
        // current intent and must take precedence). Only when no future wave
        // exists do we fall back to the most-recent past wave (which the
        // runner won't gate on, so the wipe proceeds anyway).
        var now = DateTimeOffset.UtcNow;
        var future = candidates.Where(c => c.ScheduledAtUtc > now).ToList();
        WipeScheduleWave next;
        if (future.Count > 0)
        {
            future.Sort((a, b) => a.ScheduledAtUtc.CompareTo(b.ScheduledAtUtc));
            next = future[0];
        }
        else
        {
            // All candidates are in the past — pick the most recent so the
            // client at least sees a snapshot, but isImmediate=true and the
            // runner gate won't defer.
            candidates.Sort((a, b) => b.ScheduledAtUtc.CompareTo(a.ScheduledAtUtc));
            next = candidates[0];
        }

        return new DeviceScheduleSnapshot
        {
            WaveId = next.RowKey,
            Name = next.Name,
            ActionType = WipeScheduleWave.ActionTypeValue,
            ScheduledAtUtc = next.ScheduledAtUtc,
            Status = next.Status,
            IsImmediate = next.ScheduledAtUtc <= now,
            Description = next.Description,
            GeneratedAtUtc = now,
        };
    }

    /// <summary>
    /// Tells the wipe runner whether a wipe for <paramref name="entraDeviceId"/>
    /// should be DEFERRED because the device is enrolled in a future wave.
    /// Returns <c>(false, null)</c> when no wave exists OR the wave has
    /// already fired. Returns <c>(true, scheduledAtUtc)</c> when the wipe
    /// must be deferred. Defense-in-depth companion to client-side gating.
    /// </summary>
    public async Task<(bool Defer, DateTimeOffset? ScheduledAtUtc)> ShouldDeferWipeAsync(
        Guid entraDeviceId, CancellationToken ct = default)
    {
        var snap = await GetScheduleForDeviceAsync(entraDeviceId, ct).ConfigureAwait(false);
        if (snap is null) return (false, null);
        if (snap.IsImmediate) return (false, snap.ScheduledAtUtc);
        return (true, snap.ScheduledAtUtc);
    }

    // ----- bootstrap -------------------------------------------------------

    private async Task EnsureTablesAsync(CancellationToken ct)
    {
        if (_tablesEnsured) return;
        await _ensureGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_tablesEnsured) return;
            await _waves.CreateIfNotExistsAsync(ct).ConfigureAwait(false);
            await _members.CreateIfNotExistsAsync(ct).ConfigureAwait(false);
            _tablesEnsured = true;
            _log.LogDebug("WipeScheduleStore tables ensured ({Waves}, {Members}).",
                _waves.Name, _members.Name);
        }
        finally
        {
            _ensureGate.Release();
        }
    }
}
