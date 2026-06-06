#requires -Version 7.2
#requires -Modules @{ ModuleName='Az.Accounts'; ModuleVersion='2.13.0' }
#requires -Modules @{ ModuleName='Az.Storage';  ModuleVersion='6.0.0' }
#requires -Modules @{ ModuleName='AzTable';     ModuleVersion='2.1.0' }

<#
.SYNOPSIS
    PowerShell 7.2 runbook variant of the autopilot-register capability.

.DESCRIPTION
    Same envelope, audit table, and Graph endpoint as
    src/Capabilities.Autopilot/Runners/AutopilotRegisterRunner.cs. The
    idempotency ledger is intentionally NOT replicated — see the Function
    App pipeline for production semantics.

.PARAMETER EnvelopeJson
    ActionRequestMessage JSON. Required extras: serialNumber,
    hardwareIdentifier (base64), groupTag (optional but recommended),
    productKey/oemManufacturer/model when available.
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
    $p['source']        = 'runbook:autopilot-register'
    $p['correlationId'] = $Corr
    $p['issuedAtUtc']   = $now.ToString('o')
    Add-AzTableRow -Table $Table -PartitionKey $Pk -RowKey $rk -Property $p | Out-Null
}
function Get-VarOrDefault {
    param([string]$Name, $Default)
    try { return Get-AutomationVariable -Name $Name -ErrorAction Stop } catch { return $Default }
}
function Get-Extra {
    param($Env, [string]$Name)
    if ($Env.PSObject.Properties.Name -contains 'extras' -and $Env.extras) {
        $v = $Env.extras.PSObject.Properties[$Name]
        if ($v) { return [string]$v.Value }
    }
    if ($Env.PSObject.Properties.Name -contains $Name) {
        return [string]$Env.$Name
    }
    return $null
}

$env = $EnvelopeJson | ConvertFrom-Json -Depth 16
foreach ($p in @('correlationId','intuneDeviceId')) {
    if (-not ($env.PSObject.Properties.Name -contains $p)) { throw "Envelope missing '$p'" }
}
$corr        = [string]$env.correlationId
$intune      = [string]$env.intuneDeviceId
$serial      = Get-Extra $env 'serialNumber'
$hwHashB64   = Get-Extra $env 'hardwareIdentifier'
$groupTag    = Get-Extra $env 'groupTag'
$oem         = Get-Extra $env 'oemManufacturer'
$model       = Get-Extra $env 'model'
$productKey  = Get-Extra $env 'productKey'

if (-not $serial -or -not $hwHashB64) {
    throw "Envelope missing 'serialNumber' and/or 'hardwareIdentifier' (in extras or root)."
}

Write-Output "==> autopilot-register runbook starting (corr=$corr serial=$serial groupTag=$groupTag)"

Disable-AzContextAutosave -Scope Process | Out-Null
$null = Connect-AzAccount -Identity -ErrorAction Stop

$auditStorage    = Get-VarOrDefault 'AuditStorageAccount' $null
$auditTableName  = Get-VarOrDefault 'AuditTableName' 'AuditEvents'
if (-not $auditStorage) { throw 'AuditStorageAccount Automation Variable not set' }
$audit = Get-AuditTable -StorageAccountName $auditStorage -TableName $auditTableName

$token = Get-GraphToken

$body = @{
    '@odata.type'        = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
    serialNumber         = $serial
    hardwareIdentifier   = $hwHashB64
}
if ($groupTag)   { $body['groupTag']        = $groupTag }
if ($productKey) { $body['productKey']      = $productKey }
if ($oem -and $model) {
    $body['state'] = @{
        '@odata.type'             = 'microsoft.graph.importedWindowsAutopilotDeviceIdentityState'
        deviceImportStatus        = 'pending'
        deviceErrorCode           = 0
        deviceErrorName           = ''
    }
}

$importUri = 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities'

try {
    $resp = Invoke-GraphApi -Token $token -Method POST -Uri $importUri -Body $body
    $importedId = [string]$resp.id
    Write-AuditRow -Table $audit -Pk $intune -Corr $corr -EventType 'action.dispatch.completed' -Props @{
        actionType          = 'autopilot-register'
        importedId          = $importedId
        serialNumber        = $serial
        groupTag            = ($groupTag ?? '')
    }
    Write-Output (([ordered]@{
        correlationId = $corr
        state         = 'issued:autopilot-register'
        terminal      = $true
        importedId    = $importedId
        serialNumber  = $serial
        groupTag      = $groupTag
        source        = 'runbook'
    } | ConvertTo-Json -Compress))
} catch {
    Write-AuditRow -Table $audit -Pk $intune -Corr $corr -EventType 'action.dispatch.runner-failed' -Props @{
        actionType   = 'autopilot-register'
        serialNumber = $serial
        groupTag     = ($groupTag ?? '')
        error        = $_.Exception.Message
    }
    throw
}
