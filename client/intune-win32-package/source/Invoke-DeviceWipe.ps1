#requires -Version 5.1
<#
.SYNOPSIS
    Self-service Intune wipe client with confirmation UI.
.DESCRIPTION
    Collects EntraDeviceId / IntuneDeviceId / device name, shows an elegant
    WinForms confirmation dialog (irreversibility + ~90 min downtime warning,
    typed "WIPE" confirmation + checkbox), then calls the wipe API
    authenticating with the Intune-issued device certificate.
.PARAMETER ApiUrl
    Full URL to the canonical actions endpoint, e.g.
    https://func.example.net/api/actions. The endpoint is action-agnostic:
    the action discriminator is sent in the request body via -ActionType
    below, so the same URL handles wipe, sync, and any future action types
    enabled server-side via the Actions:AllowedTypes allowlist.
.PARAMETER ActionType
    Action discriminator stamped into the request body so the backend can
    route to the right IActionRunner. Defaults to "wipe". To request a
    different action (once a corresponding runner is enabled server-side)
    pass e.g. -ActionType sync.
.PARAMETER CertificateThumbprint
    Thumbprint of the client certificate in Cert:\LocalMachine\My (or CurrentUser\My).
.PARAMETER CertificateSubjectLike
    Alternative: subject wildcard, e.g. "*Intune MDM Device CA*".
.PARAMETER CertificateIssuerLike
    Optional issuer wildcard, e.g. "*MSLABS-SUBCA01*". When set, only certs
    issued by a matching CA are considered. Combinable with SubjectLike
    (AND semantics).
.PARAMETER FunctionKey
    Function key for the Azure Function (header x-functions-key).
.PARAMETER Silent
    Skip the UI (use only for unattended testing).
.PARAMETER StatusPollIntervalSeconds
    Polling interval for GET /api/actions/status/{correlationId}. Default: 5.
.PARAMETER StatusPollMaxMinutes
    Maximum time to wait for a terminal status when monitoring is enabled.
.PARAMETER NoWaitForStatus
    Do not poll the status endpoint after the request is accepted.
.NOTES
    The client sends two anti-replay headers required by the API:
      X-Request-Timestamp : current UTC time in ISO-8601 (server tolerates ±5 min by default)
      X-Request-Nonce     : a fresh GUID per request
.EXAMPLE
    .\Invoke-DeviceWipe.ps1 -ApiUrl https://func.example.net/api/actions `
        -CertificateSubjectLike '*Intune MDM Device CA*' -FunctionKey '...'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $ApiUrl,
    [string] $CertificateThumbprint,
    [string] $CertificateSubjectLike,
    [string] $CertificateIssuerLike,
    [Parameter(Mandatory = $false)] [string] $FunctionKey,
    [Parameter(Mandatory = $false)] [string] $ActionType = 'wipe',
    [Parameter(Mandatory = $false)] [int] $StatusPollIntervalSeconds = 5,
    [Parameter(Mandatory = $false)] [int] $StatusPollMaxMinutes = 30,
    [switch] $NoWaitForStatus,
    [switch] $Silent,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $DryRun) {
    if (-not $ApiUrl)      { throw "-ApiUrl is required (unless -DryRun)." }
    if (-not $FunctionKey) { throw "-FunctionKey is required (unless -DryRun)." }
}

#region helpers

# Device identity + certificate helpers live in the canonical module so they
# can be unit-tested in isolation (see client\tests\DeviceIdentity.Tests.ps1).
# The module is copied next to this script by Build-IntuneWinPackage.ps1.
Import-Module (Join-Path $PSScriptRoot 'DeviceIdentity.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'ActionStatusClient.psm1') -Force -DisableNameChecking

function Show-WipeConfirmation {
    param([string]$DeviceName, [string]$EntraDeviceId, [string]$IntuneDeviceId)
    throw "Internal error: WipeConfirmationDialog.ps1 not loaded."
}

#endregion

# Load the shared dialog builder (overrides the placeholder above so the
# UI definition has a single source of truth, also reused by
# docs/Capture-DialogScreenshot.ps1).
. (Join-Path $PSScriptRoot 'WipeConfirmationDialog.ps1')

function Write-StatusTransition {
    param(
        [Parameter(Mandatory = $true)] [pscustomobject] $Update,
        [ref] $LastState
    )

    $state = $null
    if ($Update.Snapshot) {
        $state = [string]$Update.Snapshot.state
    }

    if ($state -and $state -ne $LastState.Value) {
        Write-Host ("  status         : {0}" -f $state) -ForegroundColor Cyan
        $LastState.Value = $state
    } elseif ($Update.LocalState -eq 'error') {
        Write-Host ("  polling warn   : {0}" -f $Update.Note) -ForegroundColor Yellow
    }
}

Write-Host 'Collecting device identity...' -ForegroundColor Cyan
if ($DryRun) {
    $deviceName  = 'LAPTOP-DEMO-01'
    $entraId     = '8f3b6c2e-7a91-4d2f-9b1e-5c0a4d6e8f12'
    $enrollmentId = '1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d'
    $intuneId    = 'a8fa102a-1e88-4e71-8df0-37a09d570a72'
} else {
    $deviceName   = $env:COMPUTERNAME
    $entraId      = Get-EntraDeviceId
    $enrollmentId = Get-MdmEnrollmentId
    $intuneId     = Get-IntuneManagedDeviceId   # may be $null on devices without IME
}
$intuneDisplay = if ($intuneId) { $intuneId } else { '(non disponibile localmente — risolto dal server)' }
Write-Host ("  Device       : {0}" -f $deviceName)
Write-Host ("  EntraDevId   : {0}" -f $entraId)
Write-Host ("  IntuneDevId  : {0}" -f $intuneDisplay)
Write-Host ("  EnrollmentId : {0}" -f $enrollmentId) -ForegroundColor DarkGray

if (-not $Silent) {
    $confirmed = Show-WipeConfirmation -DeviceName $deviceName -EntraDeviceId $entraId -IntuneDeviceId $intuneDisplay
    if (-not $confirmed) {
        Write-Host 'Operazione annullata dall''utente.' -ForegroundColor Yellow
        return
    }
}

if ($DryRun) {
    Write-Host 'DryRun: skipping certificate selection and API call.' -ForegroundColor Yellow
    return
}

$cert = Get-ClientCertificate -Thumb $CertificateThumbprint -SubjectLike $CertificateSubjectLike -IssuerLike $CertificateIssuerLike
Write-Host ("Using cert: {0} (thumb {1})" -f $cert.Subject, $cert.Thumbprint) -ForegroundColor Cyan

$body = @{
    actionType     = $ActionType
    deviceName     = $deviceName
    entraDeviceId  = $entraId
    intuneDeviceId = $enrollmentId   # legacy field name; backend uses it only for audit, resolves real id via EntraDeviceId
} | ConvertTo-Json -Compress

$headers = @{
    'x-functions-key'     = $FunctionKey
    'Content-Type'        = 'application/json'
    'X-Request-Timestamp' = (Get-Date).ToUniversalTime().ToString('o')
    'X-Request-Nonce'     = [Guid]::NewGuid().ToString()
}

try {
    $resp = Invoke-RestMethod -Method Post -Uri $ApiUrl -Body $body `
        -Headers $headers -Certificate $cert -TimeoutSec 60
    Write-Host 'Richiesta accettata:' -ForegroundColor Green
    # NOTE: NON usare `$resp | Format-List` qui — i directive di formattazione
    # (FormatStartData/GroupStartData/...) finiscono nello stream success e
    # durante `Start-Transcript` vengono serializzati come nomi di tipo,
    # mascherando i valori. Inoltre Invoke-WipeFromTask.ps1 fa regex match su
    # "correlationId : <guid>" nello stdout: Format-List dentro trascrizione
    # non produce quella riga in modo affidabile. Stampo esplicitamente.
    $corrOut   = if ($resp.PSObject.Properties.Name -contains 'correlationId') { [string]$resp.correlationId } else { '' }
    $statusOut = if ($resp.PSObject.Properties.Name -contains 'status')        { [string]$resp.status }        else { '' }
    $msgOut    = if ($resp.PSObject.Properties.Name -contains 'message')       { [string]$resp.message }       else { '' }
    Write-Host ("  status         : {0}" -f $statusOut)
    Write-Host ("  correlationId  : {0}" -f $corrOut)
    if ($msgOut) { Write-Host ("  message        : {0}" -f $msgOut) }
    $shouldMonitorStatus = (-not $Silent) -and (-not $NoWaitForStatus) -and (-not [string]::IsNullOrWhiteSpace($corrOut))
    $monitorResult = $null
    if ($shouldMonitorStatus) {
        Write-Host ("Polling GET /api/actions/status every {0}s (max {1} min)..." -f $StatusPollIntervalSeconds, $StatusPollMaxMinutes) -ForegroundColor Cyan
        $lastState = ''
        $monitorResult = Wait-ActionStatus `
            -ApiUrl $ApiUrl `
            -CorrelationId $corrOut `
            -Certificate $cert `
            -FunctionKey $FunctionKey `
            -IntervalSeconds $StatusPollIntervalSeconds `
            -MaxMinutes $StatusPollMaxMinutes `
            -OnUpdate {
                param($update)
                Write-StatusTransition -Update $update -LastState ([ref]$lastState)
            }

        if ($monitorResult.LocalState -eq 'terminal' -and $monitorResult.Snapshot) {
            Write-Host ("  terminal state : {0}" -f [string]$monitorResult.Snapshot.state) -ForegroundColor Green
        } elseif ($monitorResult.LocalState -eq 'timeout') {
            Write-Host ("  polling timed out after {0} minutes" -f $StatusPollMaxMinutes) -ForegroundColor Yellow
        }
    }
    if (-not $Silent) {
        $dialogMessage = "Richiesta di reset accettata.`r`n`r`nCorrelation Id: {0}" -f $resp.correlationId
        if ($monitorResult -and $monitorResult.Snapshot) {
            $dialogMessage += "`r`nStato finale: {0}" -f [string]$monitorResult.Snapshot.state
        } elseif ($shouldMonitorStatus) {
            $dialogMessage += "`r`nMonitoraggio: nessuno stato terminale entro {0} minuti." -f $StatusPollMaxMinutes
        }
        $dialogMessage += "`r`n`r`nIl dispositivo verra' reimpostato a breve e restera' inutilizzabile per circa 90 minuti."
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        [System.Windows.Forms.MessageBox]::Show(
            $dialogMessage,
            'Reset richiesto',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
}
catch {
    Write-Host 'Richiesta FALLITA:' -ForegroundColor Red

    # Build a rich error envelope so the SYSTEM task wrapper can surface
    # actionable diagnostics to the end user instead of just "401
    # Unauthorized". We extract HTTP status + the JSON response body
    # ({status,message,correlationId}) returned by the API's error handler.
    $errInfo = [ordered]@{
        kind               = 'http'
        apiUrl             = $ApiUrl
        deviceName         = $deviceName
        entraDeviceId      = $entraId
        intuneDeviceId     = $enrollmentId
        intuneManagedId    = $intuneId
        certSubject        = $cert.Subject
        certThumbprint     = $cert.Thumbprint
        clientMessage      = $_.Exception.Message
        httpStatusCode     = $null
        httpStatusReason   = $null
        serverStatus       = $null
        serverMessage      = $null
        serverCorrelationId = $null
        serverBodyRaw      = $null
        timestampUtc       = (Get-Date).ToUniversalTime().ToString('o')
    }

    $resp = $_.Exception.Response
    if ($resp) {
        try {
            $errInfo.httpStatusCode   = [int]$resp.StatusCode
            $errInfo.httpStatusReason = [string]$resp.StatusDescription
        } catch { }
        try {
            $sr = New-Object IO.StreamReader($resp.GetResponseStream())
            $bodyText = $sr.ReadToEnd()
            $errInfo.serverBodyRaw = $bodyText
            Write-Host $bodyText
            if ($bodyText) {
                try {
                    $parsed = $bodyText | ConvertFrom-Json -ErrorAction Stop
                    if ($parsed.PSObject.Properties.Name -contains 'status')        { $errInfo.serverStatus        = [string]$parsed.status }
                    if ($parsed.PSObject.Properties.Name -contains 'message')       { $errInfo.serverMessage       = [string]$parsed.message }
                    if ($parsed.PSObject.Properties.Name -contains 'correlationId') { $errInfo.serverCorrelationId = [string]$parsed.correlationId }
                } catch { }
            }
        } catch { }
    } else {
        $errInfo.kind = 'transport'
    }

    # Emit a single-line marker the task wrapper can parse out of stdout.
    $errJson = ($errInfo | ConvertTo-Json -Compress -Depth 4)
    Write-Host ("ERRJSON:{0}" -f $errJson)

    throw
}
