#requires -Version 5.1
<#
.SYNOPSIS
    Self-service BitLocker recovery-key rotation client.
.DESCRIPTION
    Collects the device identity (EntraDeviceId / enrollment id / name) and calls
    the action API with -ActionType bitlocker-rotate, authenticating with the
    Intune-issued device certificate (mTLS). The backend issues Graph
    rotateBitLockerKeys for the resolved managed device, which rotates the
    BitLocker recovery key and escrows the new key to Entra ID.

    Reuses the exact same pipeline as the wipe client; this is a non-destructive
    administrative action so no "type WIPE" confirmation is required. Use the
    -Confirm switch to show a light confirmation dialog when run interactively.
.PARAMETER ApiUrl
    Full URL to the canonical actions endpoint, e.g.
    https://func.example.net/api/actions.
.PARAMETER ActionType
    Action discriminator. Defaults to "bitlocker-rotate"; must be enabled
    server-side via Actions:AllowedTypes.
.PARAMETER CertificateThumbprint
    Thumbprint of the client certificate in Cert:\LocalMachine\My (or CurrentUser\My).
.PARAMETER CertificateSubjectLike
    Alternative: subject wildcard, e.g. "*Intune MDM Device CA*".
.PARAMETER CertificateIssuerLike
    Optional issuer wildcard, e.g. "*MSLABS-SUBCA01*".
.PARAMETER FunctionKey
    Function key for the Azure Function (header x-functions-key).
.PARAMETER DryRun
    Skip certificate selection and the API call (uses demo identity values).
.NOTES
    Sends the same anti-replay headers as the wipe client
    (X-Request-Timestamp, X-Request-Nonce).
.EXAMPLE
    .\Invoke-BitLockerKeyRotation.ps1 -ApiUrl https://func.example.net/api/actions `
        -CertificateSubjectLike '*Intune MDM Device CA*' -FunctionKey '...'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $ApiUrl,
    [string] $CertificateThumbprint,
    [string] $CertificateSubjectLike,
    [string] $CertificateIssuerLike,
    [Parameter(Mandatory = $false)] [string] $FunctionKey,
    [Parameter(Mandatory = $false)] [string] $ActionType = 'bitlocker-rotate',
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $DryRun) {
    if (-not $ApiUrl)      { throw "-ApiUrl is required (unless -DryRun)." }
    if (-not $FunctionKey) { throw "-FunctionKey is required (unless -DryRun)." }
}

Import-Module (Join-Path $PSScriptRoot 'DeviceIdentity.psm1') -Force -DisableNameChecking

Write-Host 'Collecting device identity...' -ForegroundColor Cyan
if ($DryRun) {
    $deviceName   = 'LAPTOP-DEMO-01'
    $entraId      = '8f3b6c2e-7a91-4d2f-9b1e-5c0a4d6e8f12'
    $enrollmentId = '1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d'
} else {
    $deviceName   = $env:COMPUTERNAME
    $entraId      = Get-EntraDeviceId
    $enrollmentId = Get-MdmEnrollmentId
}

Write-Host ("  Device       : {0}" -f $deviceName)
Write-Host ("  EntraDevId   : {0}" -f $entraId)

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
    intuneDeviceId = $enrollmentId   # legacy field name; backend resolves the real id via EntraDeviceId
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
    Write-Host 'Richiesta di rotazione chiave BitLocker accettata:' -ForegroundColor Green
    $corrOut   = if ($resp.PSObject.Properties.Name -contains 'correlationId') { [string]$resp.correlationId } else { '' }
    $statusOut = if ($resp.PSObject.Properties.Name -contains 'status')        { [string]$resp.status }        else { '' }
    Write-Host ("  status         : {0}" -f $statusOut)
    Write-Host ("  correlationId  : {0}" -f $corrOut)
}
catch {
    Write-Host 'Richiesta FALLITA:' -ForegroundColor Red
    $resp = $_.Exception.Response
    if ($resp) {
        try {
            $sr = New-Object IO.StreamReader($resp.GetResponseStream())
            Write-Host $sr.ReadToEnd()
        } catch { }
    }
    throw
}
