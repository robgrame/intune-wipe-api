<#
.SYNOPSIS
    Azure Automation Runbook (PowerShell 7.2) — alternative wipe executor.

.DESCRIPTION
    Demo-variant of the wipe capability: invoked via Automation webhook with
    the same envelope shape produced by WipeForwardingRunner. Hooks into the
    same core infrastructure (audit table on storageProc, idempotency ledger
    blob on storageProc) used by the WipeActionConsumerFunction.

    This is a SECONDARY implementation that proves the plug-in model: the same
    "wipe" capability can be executed by:
      - the dotnet-isolated WipeActionRunner on the wipe-runner Function App, OR
      - this PowerShell 7.2 runbook on Azure Automation,
    without touching the HTTP front-end, the dispatcher, or any queue.

    Wire-up (not enabled by default):
      1) Create Automation Account with system-assigned MI.
      2) Grant the Automation MI the same Graph app roles as uamiWipe:
           DeviceManagementManagedDevices.PrivilegedOperations.All
           DeviceManagementManagedDevices.Read.All
           GroupMember.Read.All
      3) Grant the Automation MI:
           Blob Data Contributor on container 'wipe-ledger' (storageProc)
           Table Data Contributor on storageProc (audit + wipestatus tables)
      4) Import this runbook (RunbookType: PowerShell72), publish.
      5) Create a webhook bound to this runbook (1-year expiry).
      6) Set on intwipe-proc app:  WipeRunbookWebhook__Url = <webhook-uri>
         (Implementation note: a parallel WipeForwardingRunner variant could
         POST to that webhook instead of enqueuing to wipe-action; left as a
         documented hook to keep the default deploy lean.)

.NOTES
    Requires modules in the Automation Account:
      Az.Accounts >= 2.13
      AzTable    >= 2.1
      (Optional) Az.Storage for blob ledger ops

    Auth: Connect-AzAccount -Identity (system-assigned MI of the Automation
    Account). The MI's object id is what you grant Graph perms to.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [object]$WebhookData
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── Configuration (override via Automation variables if needed) ────────────
$GraphApi              = 'https://graph.microsoft.com/v1.0'
$LedgerStorageAccount  = Get-AutomationVariable -Name 'LedgerStorageAccount'     # e.g. intwipestpqupxwx6egkr3e
$LedgerContainer       = Get-AutomationVariable -Name 'LedgerContainer'          # 'wipe-ledger'
$AuditStorageAccount   = Get-AutomationVariable -Name 'AuditStorageAccount'      # same as ledger
$AuditTableName        = Get-AutomationVariable -Name 'AuditTableName'           # 'auditevents'
$KeepEnrollmentData    = [bool](Get-AutomationVariable -Name 'KeepEnrollmentData')
$KeepUserData          = [bool](Get-AutomationVariable -Name 'KeepUserData')

# ─── Envelope parse ─────────────────────────────────────────────────────────
if (-not $WebhookData -or -not $WebhookData.RequestBody) {
    throw 'Runbook must be triggered via webhook with envelope body.'
}
$envelope = $WebhookData.RequestBody | ConvertFrom-Json
$correlationId   = $envelope.correlationId
$intuneDeviceId  = $envelope.payload.intuneDeviceId
$entraDeviceId   = $envelope.payload.entraDeviceId
$deviceName      = $envelope.payload.deviceName

Write-Output "runbook-wipe start corr=$correlationId intune=$intuneDeviceId name=$deviceName"

# ─── Connect to Azure via system-assigned MI ────────────────────────────────
Connect-AzAccount -Identity | Out-Null

# ─── Acquire Graph token via the MI ─────────────────────────────────────────
$tokenObj = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com'
$headers  = @{
    Authorization  = "Bearer $($tokenObj.Token)"
    'Content-Type' = 'application/json'
}

# ─── Issue the wipe ─────────────────────────────────────────────────────────
$wipeBody = @{
    keepEnrollmentData = $KeepEnrollmentData
    keepUserData       = $KeepUserData
    macOsUnlockCode    = $null
} | ConvertTo-Json

$uri = "$GraphApi/deviceManagement/managedDevices/$intuneDeviceId/wipe"
try {
    Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -Body $wipeBody | Out-Null
    Write-Output "runbook-wipe issued corr=$correlationId intune=$intuneDeviceId"
}
catch {
    Write-Error "runbook-wipe failed corr=$correlationId intune=$intuneDeviceId err=$($_.Exception.Message)"
    throw
}

# Audit/ledger writes intentionally minimal in this demo — production wiring
# would use AzTable / Az.Storage to mirror the WipeActionRunner.MarkIssued
# semantics so the portal sees runbook-issued wipes in the same trail.
Write-Output "runbook-wipe done corr=$correlationId"
