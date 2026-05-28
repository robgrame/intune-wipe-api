#requires -Version 5.1
<#
.SYNOPSIS
    Scheduled-task wrapper that runs as SYSTEM and performs the actual API
    call using the machine certificate.
.DESCRIPTION
    The end-user shortcut (Launch-Wipe.ps1) collects the confirmation in
    the user's interactive session, then triggers the scheduled task
    '\IntuneWipeClient\InvokeWipe' which executes this script as SYSTEM.
    Running as SYSTEM is required to access the private key of the SCEP /
    PKCS device certificate in Cert:\LocalMachine\My.

    This script:
      1. Reads C:\Program Files\IntuneWipeClient\config.json (ACL'd to
         SYSTEM + Administrators).
      2. Invokes Invoke-DeviceWipe.ps1 -Silent.
      3. Persists the outcome to %ProgramData%\IntuneWipeClient\last-result.json
         so the user-context launcher can show success/failure.
    Logs to %ProgramData%\IntuneWipeClient\Logs.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ProgramFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$InstallDir   = Join-Path $ProgramFiles64 'IntuneWipeClient'
$ConfigPath   = Join-Path $InstallDir       'config.json'
$WipeScript   = Join-Path $InstallDir       'Invoke-DeviceWipe.ps1'
$DataDir      = Join-Path $env:ProgramData  'IntuneWipeClient'
$LogDir       = Join-Path $DataDir          'Logs'
$ResultPath   = Join-Path $DataDir          'last-result.json'

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("Task_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile -Force | Out-Null

function Write-Result {
    param(
        [string]$Status,
        [string]$Message,
        [string]$CorrelationId,
        [hashtable]$Extra
    )
    $obj = [ordered]@{
        status        = $Status
        message       = $Message
        correlationId = $CorrelationId
        ts            = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($Extra) {
        foreach ($k in $Extra.Keys) { $obj[$k] = $Extra[$k] }
    }
    ([pscustomobject]$obj) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding utf8
}

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

function Send-UserNotification {
    param([string]$Title, [string]$Body)
    # msg.exe sends a Terminal Services message to all interactive sessions.
    # Works out-of-the-box from SYSTEM context on Windows 10/11 and shows a
    # native popup even when Launch-Wipe.ps1 isn't running. Best-effort: we
    # never want this to break the task itself.
    # NOTE: msg.exe truncates messages > ~255 chars, so we keep it short.
    try {
        $text = "{0}`r`n`r`n{1}" -f $Title, $Body
        if ($text.Length -gt 250) { $text = $text.Substring(0, 247) + '...' }
        & "$env:WINDIR\System32\msg.exe" '*' '/TIME:60' $text 2>$null | Out-Null
    } catch {
        Write-Host ("WARN: msg.exe notification failed: {0}" -f $_.Exception.Message)
    }
}

function Get-ErrJsonFromOutput {
    param($Lines)
    foreach ($line in $Lines) {
        $s = [string]$line
        $idx = $s.IndexOf('ERRJSON:')
        if ($idx -ge 0) {
            $payload = $s.Substring($idx + 'ERRJSON:'.Length).Trim()
            try { return ($payload | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
        }
    }
    return $null
}

try {
    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
    if (-not (Test-Path $WipeScript)) { throw "Wipe script not found: $WipeScript" }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    $params = @{
        ApiUrl      = $cfg.ApiUrl
        FunctionKey = $cfg.FunctionKey
        Silent      = $true
    }
    if ($cfg.CertificateThumbprint)  { $params['CertificateThumbprint']  = $cfg.CertificateThumbprint  }
    if ($cfg.CertificateIssuerLike)  { $params['CertificateIssuerLike']  = $cfg.CertificateIssuerLike  }
    if ($cfg.CertificateSubjectLike) { $params['CertificateSubjectLike'] = $cfg.CertificateSubjectLike }

    # Capture stdout to extract the correlation id (and rich error details
    # on failure) from the wipe script output.
    $wipeFailed = $false
    $out = $null
    try {
        $out = & $WipeScript @params 2>&1
    } catch {
        $wipeFailed = $true
        $thrown = $_
    }
    if ($out) { $out | ForEach-Object { Write-Host $_ } }

    if ($wipeFailed) {
        $err = Get-ErrJsonFromOutput -Lines $out
        if ($err) {
            $extra = @{
                kind                = [string]$err.kind
                apiUrl              = [string]$err.apiUrl
                httpStatusCode      = $err.httpStatusCode
                httpStatusReason    = [string]$err.httpStatusReason
                serverStatus        = [string]$err.serverStatus
                serverMessage       = [string]$err.serverMessage
                serverCorrelationId = [string]$err.serverCorrelationId
                serverBodyRaw       = [string]$err.serverBodyRaw
                certSubject         = [string]$err.certSubject
                certThumbprint      = [string]$err.certThumbprint
                deviceName          = [string]$err.deviceName
                entraDeviceId       = [string]$err.entraDeviceId
                intuneDeviceId      = [string]$err.intuneDeviceId
                clientMessage       = [string]$err.clientMessage
            }
            $displayMsg = if ($err.serverMessage) { [string]$err.serverMessage } else { [string]$err.clientMessage }
            Write-Result -Status 'error' -Message $displayMsg -CorrelationId ([string]$err.serverCorrelationId) -Extra $extra

            $evtMsg = "Wipe request FAILED.`r`nHTTP {0} {1}`r`nServer: {2}`r`nCorrelationId: {3}`r`nDevice: {4} (Entra={5}, Intune={6})`r`nCert: {7} ({8})" -f `
                $err.httpStatusCode, $err.httpStatusReason, $displayMsg, $err.serverCorrelationId, `
                $err.deviceName, $err.entraDeviceId, $err.intuneDeviceId, $err.certSubject, $err.certThumbprint
            Write-WipeEventLog -EntryType Error -EventId 2001 -Message $evtMsg
            Send-UserNotification -Title 'Reset aziendale: richiesta NON inviata' `
                -Body ("Errore: {0} (correlationId: {1}). Vedi Event Viewer/Application/IntuneWipeClient per dettagli." -f $displayMsg, $err.serverCorrelationId)
        } else {
            $msg = if ($thrown) { $thrown.Exception.Message } else { 'Wipe script terminated with an error.' }
            Write-Result -Status 'error' -Message $msg -CorrelationId $null -Extra @{ kind = 'unknown' }
            Write-WipeEventLog -EntryType Error -EventId 2002 -Message ("Wipe script terminated unexpectedly: {0}" -f $msg)
            Send-UserNotification -Title 'Reset aziendale: errore imprevisto' -Body $msg
        }
        exit 1
    }

    # Success path: pull correlationId out of the captured stdout.
    $corr = $null
    foreach ($line in $out) {
        if ($line -match 'correlationId\s*:\s*([0-9a-fA-F-]{36})') {
            $corr = $Matches[1]; break
        }
    }

    Write-Result -Status 'ok' -Message 'Wipe request accepted by the API.' -CorrelationId $corr
    Write-WipeEventLog -EntryType Information -EventId 1001 -Message ("Wipe request accepted by the API. CorrelationId={0}, Device={1}" -f $corr, $env:COMPUTERNAME)
    Send-UserNotification -Title 'Reset aziendale: richiesta inviata' `
        -Body ("La richiesta e' stata accettata. Il dispositivo verra' resettato a breve. CorrelationId: {0}" -f $corr)
    exit 0
}
catch {
    $msg = $_.Exception.Message
    Write-Host ("ERROR: {0}" -f $msg) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    Write-Result -Status 'error' -Message $msg -CorrelationId $null -Extra @{ kind = 'task-wrapper' }
    Write-WipeEventLog -EntryType Error -EventId 2003 -Message ("Task wrapper failure: {0}`r`n{1}" -f $msg, $_.ScriptStackTrace)
    Send-UserNotification -Title 'Reset aziendale: errore configurazione' -Body $msg
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
