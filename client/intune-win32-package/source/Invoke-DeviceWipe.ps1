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
    Full URL to the wipe endpoint, e.g. https://func.example.net/api/wipe
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
.NOTES
    The client sends two anti-replay headers required by the API:
      X-Request-Timestamp : current UTC time in ISO-8601 (server tolerates ±5 min by default)
      X-Request-Nonce     : a fresh GUID per request
.EXAMPLE
    .\Invoke-DeviceWipe.ps1 -ApiUrl https://func.example.net/api/wipe `
        -CertificateSubjectLike '*Intune MDM Device CA*' -FunctionKey '...'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $ApiUrl,
    [string] $CertificateThumbprint,
    [string] $CertificateSubjectLike,
    [string] $CertificateIssuerLike,
    [Parameter(Mandatory = $false)] [string] $FunctionKey,
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

function Show-WipeConfirmation {
    param([string]$DeviceName, [string]$EntraDeviceId, [string]$IntuneDeviceId)
    throw "Internal error: WipeConfirmationDialog.ps1 not loaded."
}

#endregion

# Load the shared dialog builder (overrides the placeholder above so the
# UI definition has a single source of truth, also reused by
# docs/Capture-DialogScreenshot.ps1).
. (Join-Path $PSScriptRoot 'WipeConfirmationDialog.ps1')

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
    $resp | Format-List
    if (-not $Silent) {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        [System.Windows.Forms.MessageBox]::Show(
            ("Richiesta di reset accettata.`r`n`r`nCorrelation Id: {0}`r`n`r`nIl dispositivo verra' reimpostato a breve e restera' inutilizzabile per circa 90 minuti." -f $resp.correlationId),
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
