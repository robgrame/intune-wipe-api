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
           Blob Data Contributor on container 'action-ledger' (storageProc)
           Table Data Contributor on storageProc (audit + actionstatus tables)
      4) Import this runbook (RunbookType: PowerShell72), publish.
      5) Create a webhook bound to this runbook (1-year expiry).
      6) Set on idactions-proc app:  WipeRunbookWebhook__Url = <webhook-uri>
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
    [Parameter(Mandatory = $false)]
    [object]$WebhookData,

    # Direct-invocation parameters (used when started from portal / az CLI
    # without a webhook). If provided, take precedence over WebhookData.
    [Parameter(Mandatory = $false)] [string]$IntuneDeviceId,
    [Parameter(Mandatory = $false)] [string]$EntraDeviceId,
    [Parameter(Mandatory = $false)] [string]$DeviceName,
    [Parameter(Mandatory = $false)] [string]$CorrelationId,

    # Test mode: skip the Graph wipe call (still authenticates + logs the
    # full pipeline so the job is visible in the portal).
    [Parameter(Mandatory = $false)] [bool]$TestMode = $false
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─── Configuration (override via Automation variables if needed) ────────────
$GraphApi              = 'https://graph.microsoft.com/v1.0'
$LedgerStorageAccount  = Get-AutomationVariable -Name 'LedgerStorageAccount'     # e.g. idactionsstpqupxwx6egkr3e
$LedgerContainer       = Get-AutomationVariable -Name 'LedgerContainer'          # 'action-ledger'
$AuditStorageAccount   = Get-AutomationVariable -Name 'AuditStorageAccount'      # same as ledger
$AuditTableName        = Get-AutomationVariable -Name 'AuditTableName'           # 'auditevents'
$KeepEnrollmentData    = [bool](Get-AutomationVariable -Name 'KeepEnrollmentData')
$KeepUserData          = [bool](Get-AutomationVariable -Name 'KeepUserData')

# ─── Envelope resolution ────────────────────────────────────────────────────
if ($IntuneDeviceId) {
    $correlationId  = if ($CorrelationId) { $CorrelationId } else { [guid]::NewGuid().ToString() }
    $intuneDeviceId = $IntuneDeviceId
    $entraDeviceId  = $EntraDeviceId
    $deviceName     = $DeviceName
    Write-Output "runbook-wipe source=direct mode=$(if($TestMode){'TEST'}else{'LIVE'})"
}
elseif ($WebhookData -and $WebhookData.RequestBody) {
    $envelope        = $WebhookData.RequestBody | ConvertFrom-Json
    $correlationId   = $envelope.correlationId
    $intuneDeviceId  = $envelope.payload.intuneDeviceId
    $entraDeviceId   = $envelope.payload.entraDeviceId
    $deviceName      = $envelope.payload.deviceName
    Write-Output "runbook-wipe source=webhook"
}
else {
    throw 'Runbook requires either -WebhookData (from webhook) or -IntuneDeviceId (direct invocation).'
}

Write-Output "runbook-wipe start corr=$correlationId intune=$intuneDeviceId name=$deviceName"
Write-Output "config: ledger=$LedgerStorageAccount/$LedgerContainer audit=$AuditStorageAccount/$AuditTableName keepEnrollment=$KeepEnrollmentData keepUser=$KeepUserData"

# ─── Connect to Azure via system-assigned MI ────────────────────────────────
Connect-AzAccount -Identity | Out-Null
Write-Output "az auth: connected as $((Get-AzContext).Account.Id)"

# ─── Acquire Graph token via the MI ─────────────────────────────────────────
$tokenObj = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com'
Write-Output "graph token: acquired (expires $($tokenObj.ExpiresOn))"

if ($TestMode) {
    Write-Output "TEST MODE: skipping Graph wipe POST. Pipeline OK."
    Write-Output "runbook-wipe done corr=$correlationId (test)"
    return
}

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
