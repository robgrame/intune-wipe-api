#requires -Version 5.1
<#
.SYNOPSIS
    Intune Proactive Remediation — DETECTION script for the wipe schedule
    manifest.

.DESCRIPTION
    Exits 0 (COMPLIANT — Intune does NOT run Remediate.ps1) when the local
    schedule manifest:
      - exists at  %ProgramData%\IntuneWipeClient\schedule.json,
      - is well-formed JSON,
      - was refreshed in the last $MaxAgeHours hours
        (default 6 — overridable via config.json key
        "ScheduleManifestMaxAgeHours"),
      - was produced by the same API base URL recorded in the local
        config.json (so an upgrade that changes the endpoint
        invalidates the cache).

    Exits 1 (NEEDS REMEDIATION — Intune runs Remediate.ps1) otherwise,
    including when the manifest file is missing entirely, malformed, or
    when the local IntuneWipeClient config itself is missing (in which
    case Remediate.ps1 will log + no-op and the next install cycle will
    fix the config).

    Must run in the SYSTEM context (same as the wipe scheduled task);
    detection writes only to stdout and never modifies state, so it is
    safe to schedule on every Intune evaluation tick (default 24h, can
    be tightened by the admin in the portal).

    Stdout: a single concise line (Intune Endpoint Analytics surfaces
    the FIRST line in its UI). Never throws — any unhandled exception
    is caught and reported as "Detection error: <msg>" exit 1, so the
    remediation gets a chance to recover.

.NOTES
    Pair with .\Remediate.ps1. Upload both to:
      Endpoint Manager > Reports > Endpoint analytics >
      Proactive remediations > "+ Create script package".
      Run as SYSTEM, 64-bit PowerShell, Signature check OFF (Microsoft
      does not sign these scripts; sign yourself if your AppLocker / WDAC
      policy requires it).
    Recommended schedule: every 4 hours (Intune minimum is 1h).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$DataDir        = Join-Path $env:ProgramData 'IntuneWipeClient'
$ManifestPath   = Join-Path $DataDir         'schedule.json'
$ProgramFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$ConfigPath     = Join-Path $ProgramFiles64 'IntuneWipeClient\config.json'

$DefaultMaxAgeHours = 6

function Write-OneLine([string]$msg) {
    # Intune Endpoint Analytics displays the first line of stdout. Strip
    # any embedded CR/LF defensively.
    [Console]::Out.WriteLine(($msg -replace "[`r`n]+", ' '))
}

try {
    # 1) Config file present? — otherwise the remediation will not be able
    #    to call the API anyway. Surface a clear message and force a
    #    remediation cycle so the no-op remediation logs the gap (which
    #    Intune reporting will then surface as a recurring failure).
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Write-OneLine "REMEDIATE: IntuneWipeClient config.json missing at $ConfigPath; cannot refresh schedule."
        exit 1
    }

    $cfg = $null
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-OneLine "REMEDIATE: config.json unreadable ($($_.Exception.Message))."
        exit 1
    }

    if (-not $cfg.ApiUrl) {
        Write-OneLine "REMEDIATE: config.json has no ApiUrl property."
        exit 1
    }

    $maxAgeHours = $DefaultMaxAgeHours
    if ($cfg.PSObject.Properties.Name -contains 'ScheduleManifestMaxAgeHours') {
        $candidate = [double]$cfg.ScheduleManifestMaxAgeHours
        if ($candidate -gt 0 -and $candidate -le 168) { $maxAgeHours = $candidate }
    }

    # 2) Manifest file present?
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        Write-OneLine "REMEDIATE: schedule.json missing — first run or remediation never succeeded."
        exit 1
    }

    # 3) Manifest fresh enough?
    $age = (Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $ManifestPath).LastWriteTimeUtc
    if ($age.TotalHours -gt $maxAgeHours) {
        Write-OneLine ("REMEDIATE: schedule.json is {0:N1}h old (max allowed {1}h)." -f $age.TotalHours, $maxAgeHours)
        exit 1
    }

    # 4) Manifest well-formed?
    $manifest = $null
    try {
        $raw = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-OneLine "REMEDIATE: schedule.json is empty (likely a previous remediation failure)."
            exit 1
        }
        $manifest = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-OneLine "REMEDIATE: schedule.json malformed ($($_.Exception.Message))."
        exit 1
    }

    # 5) Endpoint pinning — invalidate the cache if the configured API base
    #    URL no longer matches the one used when the manifest was produced.
    #    (Stamped by Remediate.ps1 into a sidecar marker file because the
    #    server-side DeviceScheduleSnapshot does not include the endpoint.)
    $stampPath = Join-Path $DataDir 'schedule.endpoint'
    if (Test-Path -LiteralPath $stampPath) {
        try {
            $stamped = (Get-Content -LiteralPath $stampPath -Raw -ErrorAction Stop).Trim()
            $expected = ([uri]$cfg.ApiUrl).GetLeftPart([System.UriPartial]::Authority).TrimEnd('/')
            if ($stamped -and $stamped -ne $expected) {
                Write-OneLine ("REMEDIATE: schedule.json was produced by '{0}' but config now points to '{1}'." -f $stamped, $expected)
                exit 1
            }
        } catch {
            # Stamp unreadable — force refresh, harmless.
            Write-OneLine "REMEDIATE: schedule.endpoint sidecar unreadable; refreshing."
            exit 1
        }
    }

    # 6) Healthy — report a useful one-liner so admins can see, at a
    #    glance, whether the device has a future wave scheduled or none.
    $summary = "OK: schedule.json fresh ({0:N1}h old; cap {1}h)" -f $age.TotalHours, $maxAgeHours
    if ($manifest.scheduledAtUtc) {
        $when = [DateTimeOffset]::Parse($manifest.scheduledAtUtc).ToUniversalTime()
        $delta = $when - [DateTimeOffset]::UtcNow
        if ($delta.TotalSeconds -gt 0) {
            $summary += (" — next wave '{0}' in {1:N1}h ({2})." -f $manifest.name, $delta.TotalHours, $manifest.status)
        } else {
            $summary += (" — wave '{0}' was due {1:N1}h ago ({2})." -f $manifest.name, ([Math]::Abs($delta.TotalHours)), $manifest.status)
        }
    } else {
        $summary += " — no wave currently assigned to this device."
    }
    Write-OneLine $summary
    exit 0
}
catch {
    # Belt-and-suspenders: any unhandled error → request remediation so the
    # remediation script can log diagnostics and try a fresh fetch.
    Write-OneLine ("REMEDIATE: detection error — {0}" -f ($_.Exception.Message))
    exit 1
}
