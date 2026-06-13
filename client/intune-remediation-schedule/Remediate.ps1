#requires -Version 5.1
<#
.SYNOPSIS
    Intune Proactive Remediation — REMEDIATE script for the wipe schedule
    manifest.

.DESCRIPTION
    Reads the IntuneWipeClient config (ApiUrl, FunctionKey, certificate
    selectors), calls GET <ApiBase>/api/schedule/me using the device's
    Intune-issued SCEP / PKCS certificate for mTLS, and persists the
    response JSON to %ProgramData%\IntuneWipeClient\schedule.json so the
    user-context launcher (Launch-Wipe.ps1) can read it and gate the
    wipe locally on a scheduled wave.

    Endpoint pinning: a sidecar file schedule.endpoint records the
    Authority of ApiUrl at refresh time; Detect.ps1 invalidates the
    manifest if the configured endpoint changes (e.g. after a
    redeploy under a new hostname).

    HTTP status handling:
      200 OK         -> persist body verbatim, exit 0.
      204 NoContent  -> persist a {"empty":true,"generatedAtUtc":"..."}
                        placeholder so Detect.ps1 sees a fresh manifest
                        and does NOT loop the remediation every cycle.
      401            -> log + exit 1 (cert binding misconfigured server-side).
      503            -> log + exit 1 (no providers registered / binding off).
      *              -> log + exit 1.

    Fail-closed semantics:
      - If config.json is missing: do nothing, exit 1 (Detect will keep
        flagging until the wipe client is installed properly).
      - If no matching certificate is found in Cert:\LocalMachine\My:
        do NOT overwrite schedule.json — operator may have a stale-but-
        valid manifest that is still usable by the launcher.

    Must run in the SYSTEM context — the device certificate's private
    key is ACL'd to SYSTEM + Administrators.

.NOTES
    Pair with .\Detect.ps1. Intune executes this script ONLY when
    Detect.ps1 exits 1. Single one-line summary on stdout for the
    Endpoint Analytics report.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$DataDir        = Join-Path $env:ProgramData 'IntuneWipeClient'
$ManifestPath   = Join-Path $DataDir         'schedule.json'
$StampPath      = Join-Path $DataDir         'schedule.endpoint'
$LogDir         = Join-Path $DataDir         'Logs'
$LogPath        = Join-Path $LogDir          ("Remediation_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$ProgramFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$ConfigPath     = Join-Path $ProgramFiles64 'IntuneWipeClient\config.json'

function Write-OneLine([string]$msg) {
    [Console]::Out.WriteLine(($msg -replace "[`r`n]+", ' '))
}

function Write-Log([string]$msg) {
    try {
        if (-not [System.IO.Directory]::Exists($LogDir)) {
            [void][System.IO.Directory]::CreateDirectory($LogDir)
        }
        $line = ("{0} {1}" -f (Get-Date).ToUniversalTime().ToString('o'), $msg)
        [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine)
    } catch { }
}

function Get-DeviceCertificate {
    param(
        [string]$Thumbprint,
        [string]$SubjectLike,
        [string]$IssuerLike
    )
    $candidates = Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) }

    if ($Thumbprint) {
        $candidates = $candidates | Where-Object { $_.Thumbprint -eq $Thumbprint.Trim().ToUpper() }
    }
    if ($SubjectLike) {
        $candidates = $candidates | Where-Object { $_.Subject -like $SubjectLike }
    }
    if ($IssuerLike) {
        $candidates = $candidates | Where-Object { $_.Issuer -like $IssuerLike }
    }
    # If multiple match, prefer the one that expires latest.
    return $candidates | Sort-Object NotAfter -Descending | Select-Object -First 1
}

try {
    # Always ensure data dir + log dir exist early so we can capture errors.
    if (-not [System.IO.Directory]::Exists($DataDir)) {
        [void][System.IO.Directory]::CreateDirectory($DataDir)
    }
    Write-Log "Remediation start — user=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) pid=$PID psver=$($PSVersionTable.PSVersion)"

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        Write-Log "config.json missing at $ConfigPath — no-op."
        Write-OneLine "FAIL: IntuneWipeClient not installed (config.json missing)."
        exit 1
    }

    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    if (-not $cfg.ApiUrl) {
        Write-Log "config.json has no ApiUrl."
        Write-OneLine "FAIL: config.json missing ApiUrl."
        exit 1
    }

    # Build the schedule URL from ApiUrl's authority + fixed path. The
    # canonical actions endpoint is e.g. https://func.example.net/api/actions,
    # so the schedule endpoint sits at https://func.example.net/api/schedule/me
    # on the SAME Function App (Web role). The client should only filter
    # for its own capability (wipe) — additional capabilities can be added
    # later without changing the script.
    $apiUri    = [uri]$cfg.ApiUrl
    $authority = $apiUri.GetLeftPart([System.UriPartial]::Authority).TrimEnd('/')
    $scheduleUrl = "$authority/api/schedule/me?actionType=wipe"
    Write-Log "Resolved schedule endpoint: $scheduleUrl"

    $cert = Get-DeviceCertificate `
        -Thumbprint  $cfg.CertificateThumbprint `
        -SubjectLike $cfg.CertificateSubjectLike `
        -IssuerLike  $cfg.CertificateIssuerLike
    if (-not $cert) {
        Write-Log "No matching certificate found in Cert:\LocalMachine\My — leaving existing manifest (if any) untouched."
        Write-OneLine "FAIL: no matching device certificate in LocalMachine\My — preserving previous schedule.json."
        exit 1
    }
    Write-Log "Using certificate: subject='$($cert.Subject)' thumbprint=$($cert.Thumbprint) notAfter=$($cert.NotAfter.ToUniversalTime().ToString('o'))"

    $headers = @{
        'X-Request-Timestamp' = (Get-Date).ToUniversalTime().ToString('o')
        'X-Request-Nonce'     = [Guid]::NewGuid().ToString()
    }
    if ($cfg.FunctionKey) { $headers['x-functions-key'] = $cfg.FunctionKey }

    $resp = $null
    try {
        $resp = Invoke-WebRequest -Uri $scheduleUrl -Method GET `
            -Certificate $cert -Headers $headers `
            -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    } catch [System.Net.WebException] {
        $we   = $_.Exception
        $code = if ($we.Response) { [int]$we.Response.StatusCode } else { 0 }
        $body = ''
        try {
            if ($we.Response) {
                $sr = New-Object System.IO.StreamReader($we.Response.GetResponseStream())
                $body = $sr.ReadToEnd()
            }
        } catch { }
        Write-Log "HTTP $code from $scheduleUrl — body: $body"
        Write-OneLine ("FAIL: schedule endpoint returned HTTP {0}." -f $code)
        exit 1
    } catch {
        Write-Log "Unexpected exception: $($_.Exception.GetType().FullName) — $($_.Exception.Message)"
        Write-OneLine ("FAIL: schedule fetch failed — {0}" -f $_.Exception.Message)
        exit 1
    }

    $status = [int]$resp.StatusCode
    Write-Log "HTTP $status received (length=$($resp.RawContentLength))."

    $bodyToWrite = $null
    if ($status -eq 204) {
        # No wave for this device — stamp a placeholder so Detect doesn't
        # loop forever; Launch-Wipe must treat {"empty":true} as "no gate
        # active, proceed".
        $bodyToWrite = @{
            empty          = $true
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Compress
    } elseif ($status -eq 200) {
        $bodyToWrite = $resp.Content
    } else {
        # Unexpected 2xx (e.g. 202) — log and bail; don't overwrite the
        # cached manifest with an unknown shape.
        Write-Log "Unexpected HTTP $status — not overwriting manifest."
        Write-OneLine ("FAIL: unexpected HTTP {0} from schedule endpoint." -f $status)
        exit 1
    }

    # Atomic-ish write: write to a sibling tmp file then rename.
    $tmpPath = "$ManifestPath.tmp"
    [System.IO.File]::WriteAllText($tmpPath, $bodyToWrite)
    Move-Item -LiteralPath $tmpPath -Destination $ManifestPath -Force

    # Stamp the endpoint so Detect can invalidate the cache on hostname change.
    [System.IO.File]::WriteAllText($StampPath, $authority)

    # Restrict ACL: SYSTEM + Administrators FullControl, Users READ (so the
    # user-context Launch-Wipe.ps1 can read it without elevation).
    try {
        $acl = Get-Acl -LiteralPath $ManifestPath
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
        $entries = @(
            @{ Sid='S-1-5-18';     Right='FullControl' },  # SYSTEM
            @{ Sid='S-1-5-32-544'; Right='FullControl' },  # BUILTIN\Administrators
            @{ Sid='S-1-5-32-545'; Right='Read'         }  # BUILTIN\Users
        )
        foreach ($e in $entries) {
            $idRef = (New-Object Security.Principal.SecurityIdentifier $e.Sid).Translate([Security.Principal.NTAccount])
            $rule  = New-Object System.Security.AccessControl.FileSystemAccessRule($idRef, $e.Right, 'Allow')
            $acl.AddAccessRule($rule)
        }
        $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([Security.Principal.NTAccount]))
        Set-Acl -LiteralPath $ManifestPath -AclObject $acl
    } catch {
        Write-Log "ACL hardening failed (manifest still written): $($_.Exception.Message)"
    }

    if ($status -eq 204) {
        Write-Log "Manifest written (204 placeholder)."
        Write-OneLine "OK: refreshed (no wave assigned)."
    } else {
        # Try to surface a useful one-liner.
        try {
            $j = $bodyToWrite | ConvertFrom-Json
            if ($j.scheduledAtUtc) {
                $when = [DateTimeOffset]::Parse($j.scheduledAtUtc).ToUniversalTime()
                $delta = $when - [DateTimeOffset]::UtcNow
                if ($delta.TotalSeconds -gt 0) {
                    Write-OneLine ("OK: refreshed — next wave '{0}' in {1:N1}h ({2})." -f $j.name, $delta.TotalHours, $j.status)
                } else {
                    Write-OneLine ("OK: refreshed — wave '{0}' was due {1:N1}h ago ({2})." -f $j.name, ([Math]::Abs($delta.TotalHours)), $j.status)
                }
            } else {
                Write-OneLine "OK: refreshed (no wave assigned)."
            }
        } catch {
            Write-OneLine "OK: refreshed."
        }
        Write-Log "Manifest written ($($resp.RawContentLength) bytes)."
    }
    exit 0
}
catch {
    Write-Log "Unhandled: $($_.Exception.GetType().FullName) — $($_.Exception.Message) at $($_.ScriptStackTrace)"
    Write-OneLine ("FAIL: remediation aborted — {0}" -f $_.Exception.Message)
    exit 1
}
