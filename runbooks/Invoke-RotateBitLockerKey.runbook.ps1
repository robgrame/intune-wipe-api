#requires -Version 7.2
#requires -Modules @{ ModuleName='Az.Accounts'; ModuleVersion='2.13.0' }
#requires -Modules @{ ModuleName='Az.Storage';  ModuleVersion='6.0.0' }
#requires -Modules @{ ModuleName='AzTable';     ModuleVersion='2.1.0' }

<#
.SYNOPSIS
    PowerShell 7.2 runbook variant of the bitlocker (rotate recovery key)
    capability.

.DESCRIPTION
    Same envelope, audit table, and Graph endpoint as
    src/Capabilities.BitLocker/Runners/BitLockerRotateRunner.cs.

.PARAMETER EnvelopeJson
    ActionRequestMessage JSON. Must carry actionType="bitlocker-rotate",
    correlationId, intuneDeviceId, entraDeviceId, deviceName.
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $EnvelopeJson)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Get-GraphToken {
    $t = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -AsSecureString:$false -ErrorAction Stop
    return $t.Token
}
function Invoke-GraphApi {
    param([string]$Token, [string]$Method, [string]$Uri, [object]$Body)
    $h = @{ Authorization = "Bearer $Token"; 'Content-Type' = 'application/json' }
    $p = @{ Method=$Method; Uri=$Uri; Headers=$h; ErrorAction='Stop' }
    if ($null -ne $Body) { $p['Body'] = ($Body | ConvertTo-Json -Depth 16 -Compress) }
    try { return Invoke-RestMethod @p }
    catch {
        $st = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $msg = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        throw "Graph $Method $Uri failed (HTTP $st): $msg"
    }
}
function Get-AuditTable {
    param([string]$StorageAccountName, [string]$TableName)
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -ErrorAction Stop
    $t = Get-AzStorageTable -Name $TableName -Context $ctx -ErrorAction SilentlyContinue
    if (-not $t) { $t = New-AzStorageTable -Name $TableName -Context $ctx -ErrorAction Stop }
    return $t.CloudTable
}
function Write-AuditRow {
    param($Table, [string]$Pk, [string]$Corr, [string]$EventType, [hashtable]$Props)
    $now = [DateTimeOffset]::UtcNow
    $desc = ([DateTime]::MaxValue.Ticks - $now.UtcTicks).ToString('D19')
    $rk = "$desc-$([Guid]::NewGuid().ToString('N'))"
    $p = @{}
    foreach ($k in $Props.Keys) { $p[$k] = [string]$Props[$k] }
    $p['eventType']     = $EventType
    $p['source']        = 'runbook:bitlocker-rotate'
    $p['correlationId'] = $Corr
    $p['issuedAtUtc']   = $now.ToString('o')
    Add-AzTableRow -Table $Table -PartitionKey $Pk -RowKey $rk -Property $p | Out-Null
}
function Get-VarOrDefault {
    param([string]$Name, $Default)
    try { return Get-AutomationVariable -Name $Name -ErrorAction Stop } catch { return $Default }
}

$env = $EnvelopeJson | ConvertFrom-Json -Depth 16
foreach ($p in @('correlationId','intuneDeviceId','entraDeviceId')) {
    if (-not ($env.PSObject.Properties.Name -contains $p)) { throw "Envelope missing '$p'" }
}
$corr   = [string]$env.correlationId
$intune = [string]$env.intuneDeviceId
$entra  = [string]$env.entraDeviceId

Write-Output "==> bitlocker-rotate runbook starting (corr=$corr entra=$entra)"

Disable-AzContextAutosave -Scope Process | Out-Null
$null = Connect-AzAccount -Identity -ErrorAction Stop

$auditStorage   = Get-VarOrDefault 'AuditStorageAccount' $null
$auditTableName = Get-VarOrDefault 'AuditTableName' 'AuditEvents'
if (-not $auditStorage) { throw 'AuditStorageAccount Automation Variable not set' }
$audit = Get-AuditTable -StorageAccountName $auditStorage -TableName $auditTableName

$token = Get-GraphToken

# Resolve managedDevice id by Entra device id
$filter  = "azureADDeviceId eq '$entra'"
$enc     = [uri]::EscapeDataString($filter)
$listUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=$enc&`$select=id,deviceName,operatingSystem"
$list    = Invoke-GraphApi -Token $token -Method GET -Uri $listUri
$mdList  = @($list.value)
if ($mdList.Count -eq 0) {
    Write-AuditRow -Table $audit -Pk $intune -Corr $corr -EventType 'action.dispatch.runner-failed' -Props @{
        reason = 'device-not-in-intune'; entraDeviceId = $entra; actionType = 'bitlocker-rotate'
    }
    Write-Output (([ordered]@{correlationId=$corr; state='denied:device-not-in-intune'; terminal=$true; source='runbook'} | ConvertTo-Json -Compress))
    return
}
$managedId = $mdList[0].id
$os        = [string]$mdList[0].operatingSystem
if ($os -and $os -notmatch 'Windows') {
    Write-AuditRow -Table $audit -Pk $intune -Corr $corr -EventType 'action.dispatch.runner-failed' -Props @{
        reason='non-windows-device'; managedDeviceId=$managedId; os=$os; actionType='bitlocker-rotate'
    }
    Write-Output (([ordered]@{correlationId=$corr; state='denied:non-windows-device'; terminal=$true; source='runbook'} | ConvertTo-Json -Compress))
    return
}

$rotateUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$managedId/rotateBitLockerKeys"
try {
    Invoke-GraphApi -Token $token -Method POST -Uri $rotateUri | Out-Null
    Write-AuditRow -Table $audit -Pk $intune -Corr $corr -EventType 'action.dispatch.completed' -Props @{
        actionType='bitlocker-rotate'; managedDeviceId=$managedId
    }
    Write-Output (([ordered]@{correlationId=$corr; state='issued:bitlocker-rotate'; terminal=$true; managedDeviceId=$managedId; source='runbook'} | ConvertTo-Json -Compress))
} catch {
    Write-AuditRow -Table $audit -Pk $intune -Corr $corr -EventType 'action.dispatch.runner-failed' -Props @{
        actionType='bitlocker-rotate'; managedDeviceId=$managedId; error=$_.Exception.Message
    }
    throw
}
