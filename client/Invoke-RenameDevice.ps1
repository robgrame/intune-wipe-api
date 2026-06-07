<#
.SYNOPSIS
    Issues a device-rename request against the intune-device-actions API.

.DESCRIPTION
    Posts a `device-rename` action to the mTLS-protected `/api/v2/actions`
    endpoint. The API forwards to a dedicated Rename Function App (or to an
    Azure Automation runbook when the action type is suffixed with
    `-runbook`) which:
        1. queries the customer-internal CMDB / asset-management REST endpoint
           with the device serial number to RETRIEVE the canonical new name;
        2. checks Entra for displayName collisions (Entra does not enforce
           uniqueness on device displayName, unlike on-prem AD); behaviour is
           controlled by Rename:OnCollision (block | warn);
        3. invokes Microsoft Graph setDeviceName against the Intune managed
           device — Intune applies the rename on the next MDM sync (a reboot
           is required for the change to take effect on Windows).

    The client does NOT pass the new name — it lives in the customer CMDB by
    design, so the naming convention stays centralised. The serial number can
    be sourced from local hardware (default) or passed explicitly via -SerialNumber.

.PARAMETER ApiBaseUrl
    Full URL of the actions endpoint, e.g. https://idactions-web.azurewebsites.net/api/v2/actions

.PARAMETER ClientCertThumbprint
    SHA1 thumbprint of the client certificate enrolled in the API's allow-list
    (matches one of the `trustedCaThumbprints` configured in bicep).

.PARAMETER SerialNumber
    Hardware serial number to send. When omitted, the script reads the local
    BIOS serial via WMI (Win32_BIOS).

.PARAMETER IntuneDeviceId
    Intune managed-device id. Optional — when omitted, the API derives it from
    the client certificate / device claims.

.PARAMETER EntraDeviceId
    Entra (Azure AD) device id. Optional — same fallback as IntuneDeviceId.

.PARAMETER UseRunbook
    When set, posts the action with type `device-rename-runbook` (Automation
    runbook variant) instead of `device-rename` (Function App variant).

.EXAMPLE
    .\Invoke-RenameDevice.ps1 `
        -ApiBaseUrl 'https://idactions-web.azurewebsites.net/api/v2/actions' `
        -ClientCertThumbprint 'AB12CD34EF56...'

    Renames the local machine; serial is read from BIOS and the new name is
    fetched from the customer CMDB.

.EXAMPLE
    .\Invoke-RenameDevice.ps1 -ApiBaseUrl ... -ClientCertThumbprint ... `
        -SerialNumber 'PF3X9ABC' -UseRunbook
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ApiBaseUrl,
    [Parameter(Mandatory)] [string] $ClientCertThumbprint,
    [string] $SerialNumber,
    [string] $IntuneDeviceId,
    [string] $EntraDeviceId,
    [switch] $UseRunbook
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $SerialNumber) {
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
    $SerialNumber = ($bios.SerialNumber ?? '').Trim()
    if (-not $SerialNumber) {
        throw "Could not read BIOS serial number; pass -SerialNumber explicitly."
    }
    Write-Verbose "Resolved local serial: $SerialNumber"
}

$cert = Get-Item -Path "Cert:\LocalMachine\My\$ClientCertThumbprint" -ErrorAction SilentlyContinue
if (-not $cert) {
    $cert = Get-Item -Path "Cert:\CurrentUser\My\$ClientCertThumbprint" -ErrorAction SilentlyContinue
}
if (-not $cert) {
    throw "Client certificate $ClientCertThumbprint not found in LocalMachine\My or CurrentUser\My."
}

$actionType = if ($UseRunbook) { 'device-rename-runbook' } else { 'device-rename' }
$deviceName = $env:COMPUTERNAME
$body = [ordered]@{
    actionType = $actionType
    deviceName = $deviceName
    rename     = [ordered]@{
        serialNumber = $SerialNumber
    }
}
if ($IntuneDeviceId) { $body.intuneDeviceId = $IntuneDeviceId }
if ($EntraDeviceId)  { $body.entraDeviceId  = $EntraDeviceId }

$json = $body | ConvertTo-Json -Depth 6 -Compress
Write-Verbose "POST $ApiBaseUrl"
Write-Verbose "Body: $json"

$resp = Invoke-RestMethod -Method Post -Uri $ApiBaseUrl `
    -Body $json -ContentType 'application/json' `
    -Certificate $cert -ErrorAction Stop

$resp | ConvertTo-Json -Depth 6
