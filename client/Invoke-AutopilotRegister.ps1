#requires -Version 5.1
<#
.SYNOPSIS
    Self-service Windows Autopilot registration client.
.DESCRIPTION
    Collects the device identity (EntraDeviceId / enrollment id / name) plus the
    Autopilot hardware identity (4K hash + serial + product key), then calls the
    action API with -ActionType autopilot-register, authenticating with the
    Intune-issued device certificate (mTLS).

    This reuses the exact same pipeline as the wipe client — the only difference
    is the action discriminator and the additional `autopilot` payload that
    carries the hardware hash (which is not available server-side). Designed to
    run silently in SYSTEM context (no destructive confirmation needed).
.PARAMETER ApiUrl
    Full URL to the canonical actions endpoint, e.g.
    https://func.example.net/api/actions.
.PARAMETER ActionType
    Action discriminator. Defaults to "autopilot-register"; must be enabled
    server-side via Actions:AllowedTypes.
.PARAMETER GroupTag
    Optional Autopilot group tag to stamp on the imported identity.
.PARAMETER AssignedUserPrincipalName
    Optional UPN to pre-assign to the imported device.
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
    .\Invoke-AutopilotRegister.ps1 -ApiUrl https://func.example.net/api/actions `
        -CertificateSubjectLike '*Intune MDM Device CA*' -FunctionKey '...' -GroupTag 'Corp-Standard'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $ApiUrl,
    [string] $CertificateThumbprint,
    [string] $CertificateSubjectLike,
    [string] $CertificateIssuerLike,
    [Parameter(Mandatory = $false)] [string] $FunctionKey,
    [Parameter(Mandatory = $false)] [string] $ActionType = 'autopilot-register',
    [string] $GroupTag,
    [string] $AssignedUserPrincipalName,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $DryRun) {
    if (-not $ApiUrl)      { throw "-ApiUrl is required (unless -DryRun)." }
    if (-not $FunctionKey) { throw "-FunctionKey is required (unless -DryRun)." }
}

Import-Module (Join-Path $PSScriptRoot 'DeviceIdentity.psm1')   -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'AutopilotIdentity.psm1') -Force -DisableNameChecking

Write-Host 'Collecting device + Autopilot identity...' -ForegroundColor Cyan
if ($DryRun) {
    $deviceName   = 'LAPTOP-DEMO-01'
    $entraId      = '8f3b6c2e-7a91-4d2f-9b1e-5c0a4d6e8f12'
    $enrollmentId = '1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d'
    $autopilot    = @{ hardwareHash = 'REVNTy1IQVJEV0FSRS1IQVNI'; serialNumber = 'DEMO-SERIAL-01' }
} else {
    $deviceName   = $env:COMPUTERNAME
    $entraId      = Get-EntraDeviceId
    $enrollmentId = Get-MdmEnrollmentId
    $autopilot    = Get-AutopilotIdentityPayload -GroupTag $GroupTag -AssignedUserPrincipalName $AssignedUserPrincipalName
}

Write-Host ("  Device       : {0}" -f $deviceName)
Write-Host ("  EntraDevId   : {0}" -f $entraId)
Write-Host ("  Serial       : {0}" -f $(if ($autopilot.ContainsKey('serialNumber')) { $autopilot.serialNumber } else { '(n/a)' }))
Write-Host ("  HashBytes    : {0}" -f $autopilot.hardwareHash.Length) -ForegroundColor DarkGray

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
    autopilot      = $autopilot
} | ConvertTo-Json -Compress -Depth 4

$headers = @{
    'x-functions-key'     = $FunctionKey
    'Content-Type'        = 'application/json'
    'X-Request-Timestamp' = (Get-Date).ToUniversalTime().ToString('o')
    'X-Request-Nonce'     = [Guid]::NewGuid().ToString()
}

try {
    $resp = Invoke-RestMethod -Method Post -Uri $ApiUrl -Body $body `
        -Headers $headers -Certificate $cert -TimeoutSec 60
    Write-Host 'Richiesta di registrazione Autopilot accettata:' -ForegroundColor Green
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
