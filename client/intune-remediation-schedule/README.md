# Intune Proactive Remediation — schedule manifest sync

This 2-script package is the **client-side half of the double temporal
gate** for the wipe schedule feature. It polls
`GET /api/schedule/me` from the Web Function App every few hours and
persists the JSON snapshot to
`%ProgramData%\IntuneWipeClient\schedule.json`, where the user-context
`Launch-Wipe.ps1` reads it to refuse early wipe attempts.

The capability-side gate inside `WipeActionRunner` Step 0 remains the
authoritative safety net — this remediation is **defense in depth** and
also drives the UX (the user sees a friendly "scheduled for X" message
instead of the wipe silently being deferred server-side).

## Files

| File | Purpose |
|------|---------|
| `Detect.ps1`    | Flags the device as needing remediation when `schedule.json` is missing, older than 6h, malformed, or stamped with a different API endpoint. Single one-line stdout for Endpoint Analytics. |
| `Remediate.ps1` | Calls the schedule endpoint with the device SCEP certificate, writes `schedule.json` + `schedule.endpoint` sidecar, hardens the ACL. Fail-closed: never overwrites the cached manifest if no certificate matches. |

## Prerequisites

1. **`IntuneWipeClient` Win32 package already installed** (the
   remediation reads `C:\Program Files\IntuneWipeClient\config.json`
   for `ApiUrl`, `FunctionKey`, and the cert selectors). The remediation
   exits 1 with a clear message if the package is missing — admins
   should not be surprised; deploy the Win32 app first.
2. **Device SCEP / PKCS certificate present** in
   `Cert:\LocalMachine\My`. Same cert used by the wipe client itself.
3. The Web Function App must expose `/api/schedule/me` and have at
   least one `IScheduleProvider` registered (today: `WipeScheduleProvider`).

## Upload to Intune

1. Open the Intune portal → **Reports** → **Endpoint analytics** →
   **Proactive remediations** → **Create script package**.
2. Name: `IntuneWipeClient — schedule manifest sync`.
3. Detection script file: upload `Detect.ps1`.
4. Remediation script file: upload `Remediate.ps1`.
5. **Run as**: `System`.
6. **Run script in 64-bit PowerShell**: `Yes`.
7. **Enforce script signature check**: `No` (unless you have signed the
   scripts with a cert trusted by your AppLocker / WDAC policy).
8. **Assignments**: target the same device group(s) that receive the
   `IntuneWipeClient` Win32 app.
9. **Schedule**: every **4 hours** is a good default (Intune minimum is
   1h; the maximum is daily). Detect respects a per-device override via
   the `ScheduleManifestMaxAgeHours` key in `config.json` if you want
   to tune the freshness threshold independently of the Intune cadence.

## Verification on a target device

After Intune evaluates the remediation, check on a device:

```powershell
Get-ChildItem $env:ProgramData\IntuneWipeClient\
# Expect: schedule.json + schedule.endpoint + Logs\Remediation_*.log

Get-Content $env:ProgramData\IntuneWipeClient\schedule.json | ConvertFrom-Json
# Either { "empty": true, "generatedAtUtc": "..." }  (204 NoContent)
# or     { "waveId":"...", "name":"...", "scheduledAtUtc":"...", ... } (200)

Get-Content (Get-ChildItem $env:ProgramData\IntuneWipeClient\Logs\Remediation_*.log |
  Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).FullName
```

The Intune Endpoint Analytics report shows the one-line stdout per
device — a concise diagnostic (`OK: refreshed — next wave 'Wave A' in 2.3h (scheduled).`
or `FAIL: no matching device certificate ...`).

## Optional config keys (host-side `config.json`)

| Key | Type | Default | Meaning |
|-----|------|---------|---------|
| `ScheduleManifestMaxAgeHours` | number | `6` | Max age tolerated by `Detect.ps1` before forcing a remediation. Must be `> 0` and `<= 168` (1 week). |

These are read by `Detect.ps1` only; absence is fine and uses the
hard-coded default. No restart of the wipe client is required after
changing them — the next remediation tick picks them up.

## Future work

When additional capabilities (autopilot, bitlocker) start exposing
their own `IScheduleProvider`, the same `/api/schedule/me` endpoint
will merge them — this remediation already strips the response to a
single capability via `?actionType=wipe`. To gate other capabilities
locally, clone this package, swap the `actionType` query and the
manifest file name, and upload as a separate Proactive Remediation.
