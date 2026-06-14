#requires -Version 5.1
<#
.SYNOPSIS
    SYSTEM-context status poller for an in-flight wipe request.
.DESCRIPTION
    Triggered on-demand by Invoke-WipeFromTask.ps1 right after a wipe is
    accepted by the API. Polls GET {ApiBase}/status/{correlationId} with
    the device client certificate (mTLS) every -IntervalSeconds (default
    5) for up to -MaxMinutes (default 30) or until the server reports a
    terminal state. Persists a fresh snapshot to:

        %ProgramData%\IntuneWipeClient\status\latest.json
        %ProgramData%\IntuneWipeClient\status\<corrId>.json

    so the user-side progress dialog (Show-WipeProgressDialog) can tail it
    without ever touching the cert / API directly. Writes Application Event
    Log entries on every state transition so admins/IT have a record even if
    nobody opened the UI.

    Why a self-contained loop (not a repetition trigger): scheduled-task
    repetition has a 1-minute minimum granularity but, more importantly, we
    want a single owning process that can self-deregister on terminal state
    and on its own MaxMinutes timeout. The Win32 install registers the task
    once with no trigger; Invoke-WipeFromTask.ps1 runs `schtasks /Run` and
    passes the live correlationId.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $CorrelationId,
    [Parameter(Mandatory = $false)] [int]    $IntervalSeconds = 5,
    [Parameter(Mandatory = $false)] [int]    $MaxMinutes      = 30
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ProgramFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$InstallDir   = Join-Path $ProgramFiles64 'IntuneWipeClient'
$ConfigPath   = Join-Path $InstallDir       'config.json'
$DataDir      = Join-Path $env:ProgramData  'IntuneWipeClient'
$StatusDir    = Join-Path $DataDir          'status'
$LogDir       = Join-Path $DataDir          'Logs'
$ResultPath   = Join-Path $DataDir          'last-result.json'

Import-Module (Join-Path $InstallDir 'ActionStatusClient.psm1') -Force -DisableNameChecking

# Argument-less invocation path: scheduled-task /Run cannot pass arguments,
# so the task manifest invokes us with no -CorrelationId and we recover it
# from the freshest last-result.json written by Invoke-WipeFromTask.ps1.
if (-not $CorrelationId) {
    if (Test-Path -LiteralPath $ResultPath) {
        try {
            $r = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
            if ($r -and $r.correlationId) { $CorrelationId = [string]$r.correlationId }
        } catch { }
    }
    if (-not $CorrelationId) {
        throw "No -CorrelationId supplied and last-result.json has no correlationId to fall back to."
    }
}

New-Item -ItemType Directory -Force -Path $StatusDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir    | Out-Null

$LogFile = Join-Path $LogDir ("Watch_{0:yyyyMMdd_HHmmss}_{1}.log" -f (Get-Date), $CorrelationId.Substring(0, [Math]::Min(8, $CorrelationId.Length)))
Start-Transcript -Path $LogFile -Force | Out-Null

function Write-WipeEventLog {
    param(
        [ValidateSet('Information','Warning','Error')] [string]$EntryType,
        [int]$EventId,
        [string]$Message
    )
    try {
        $src = 'IntuneWipeClient'
        if (-not [System.Diagnostics.EventLog]::SourceExists($src)) {
            [System.Diagnostics.EventLog]::CreateEventSource($src, 'Application')
        }
        Write-EventLog -LogName 'Application' -Source $src -EntryType $EntryType -EventId $EventId -Message $Message -ErrorAction Stop
    } catch {
        Write-Host ("WARN: Write-EventLog failed: {0}" -f $_.Exception.Message)
    }
}

function Get-ClientCertificate {
    param($Cfg)
    $certs = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.HasPrivateKey }
    if ($Cfg.CertificateThumbprint) {
        $c = $certs | Where-Object Thumbprint -eq $Cfg.CertificateThumbprint | Select-Object -First 1
        if ($c) { return $c }
    }
    if ($Cfg.CertificateIssuerLike) {
        $patterns = $Cfg.CertificateIssuerLike -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $certs = $certs | Where-Object {
            $issuer = $_.Issuer
            foreach ($p in $patterns) { if ($issuer -like $p) { return $true } }
            $false
        }
    }
    if ($Cfg.CertificateSubjectLike) {
        $certs = $certs | Where-Object { $_.Subject -like $Cfg.CertificateSubjectLike }
    }
    return ($certs | Sort-Object NotAfter -Descending | Select-Object -First 1)
}

function Write-StatusFile {
    param([string]$CorrelationId, [pscustomobject]$Snapshot, [string]$LocalState, [string]$Note)
    $obj = [ordered]@{
        correlationId   = $CorrelationId
        clientUpdatedAt = (Get-Date).ToUniversalTime().ToString('o')
        localState      = $LocalState        # 'polling','terminal','timeout','error'
        note            = $Note
        server          = $Snapshot
    }
    $json = ([pscustomobject]$obj) | ConvertTo-Json -Depth 8
    $perCorr = Join-Path $StatusDir ("{0}.json" -f $CorrelationId)
    $latest  = Join-Path $StatusDir 'latest.json'
    Set-Content -LiteralPath $perCorr -Value $json -Encoding utf8
    Set-Content -LiteralPath $latest  -Value $json -Encoding utf8
}

try {
    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    $cert = Get-ClientCertificate -Cfg $cfg
    if (-not $cert) { throw "No client certificate found in LocalMachine\My matching the configured selectors." }

    $settings = Resolve-ActionStatusMonitoringOptions -Config $cfg -IntervalSeconds $IntervalSeconds -MaxMinutes $MaxMinutes
    $statusUrl = Get-ActionStatusUrl -ApiUrl $cfg.ApiUrl -CorrelationId $CorrelationId
    Write-Host ("Polling: {0}  (cert={1})" -f $statusUrl, $cert.Thumbprint)
    Write-WipeEventLog -EntryType Information -EventId 3001 -Message ("StatusPoller started. CorrelationId={0}, IntervalSeconds={1}, MaxMinutes={2}" -f $CorrelationId, $settings.IntervalSeconds, $settings.MaxMinutes)

    Write-StatusFile -CorrelationId $CorrelationId -Snapshot $null -LocalState 'polling' -Note 'poller started'

    $lastState = ''
    $result = Wait-ActionStatus `
        -ApiUrl $cfg.ApiUrl `
        -CorrelationId $CorrelationId `
        -Certificate $cert `
        -FunctionKey $cfg.FunctionKey `
        -IntervalSeconds $settings.IntervalSeconds `
        -MaxMinutes $settings.MaxMinutes `
        -OnUpdate {
            param($update)
            $snapshot = $update.Snapshot
            $state = $null
            $terminal = $false
            if ($snapshot) {
                $state = [string]$snapshot.state
                $terminal = [bool]$snapshot.terminal
            }
            if ($update.LocalState -eq 'error') {
                Write-Host ("WARN attempt {0}: {1}" -f $update.Attempt, $update.Note)
            }
            Write-StatusFile -CorrelationId $CorrelationId -Snapshot $snapshot -LocalState $update.LocalState -Note $update.Note
            if ($state -and $state -ne $lastState) {
                $delta = "state '{0}' -> '{1}' (terminal={2}, attempt={3}, correlationId={4})" -f $lastState, $state, $terminal, $update.Attempt, $CorrelationId
                Write-WipeEventLog -EntryType Information -EventId 3002 -Message $delta
                Write-Host $delta
                $lastState = $state
            }
        }

    if ($result.LocalState -eq 'terminal' -and $result.Snapshot) {
        Write-WipeEventLog -EntryType Information -EventId 3003 -Message ("StatusPoller reached terminal state '{0}' after {1} attempts. CorrelationId={2}" -f [string]$result.Snapshot.state, $result.Attempt, $CorrelationId)
    }
    elseif ($result.LocalState -eq 'timeout') {
        Write-StatusFile -CorrelationId $CorrelationId -Snapshot $result.Snapshot -LocalState 'timeout' `
            -Note ("no terminal state after {0} minutes" -f $settings.MaxMinutes)
        Write-WipeEventLog -EntryType Warning -EventId 3004 -Message ("StatusPoller timed out after {0} minutes. LastState='{1}'. CorrelationId={2}" -f $settings.MaxMinutes, $lastState, $CorrelationId)
    }

    exit 0
}
catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    Write-WipeEventLog -EntryType Error -EventId 3005 -Message ("StatusPoller failure: {0}`r`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace)
    try {
        Write-StatusFile -CorrelationId $CorrelationId -Snapshot $null -LocalState 'error' -Note $_.Exception.Message
    } catch { }
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
