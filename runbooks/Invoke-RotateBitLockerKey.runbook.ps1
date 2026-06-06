#requires -Version 7.2
<#
.SYNOPSIS
    Azure Automation Runbook (PowerShell 7.2) — bitlocker-rotate capability
    executor with functional parity to
    IntuneDeviceActions.Capabilities.BitLocker.BitLockerRotateRunner.

.DESCRIPTION
    Pipeline (mirrors BitLockerRotateRunner.RunAsync — same fail-closed
    pre-issue safety as the wipe runner, minus the destructive payload):
        1. Resolve Entra directory object id
        2. Allowed-group membership check
        3. Ownership: resolve managedDevice via azureADDeviceId
        4. Idempotency reservation (auto-rearm + 24h rolling rate limit)
        5. Issue Graph rotateBitLockerKeys → mark ledger Issued/Failed, audit,
           init status tracker

    All helpers live in _lib/RunbookCore.ps1 which is concatenated in front
    of this file by tools/Deploy-IntuneDeviceActions.ps1 at publish time.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [object]$WebhookData,
    [Parameter(Mandatory = $false)] [string]$EnvelopeJson
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# >>> RBC-LIB-INSERTION-POINT <<<

$rawJson = if ($EnvelopeJson) { $EnvelopeJson }
           elseif ($WebhookData) { [string]$WebhookData.RequestBody }
           else { throw 'Runbook requires either -WebhookData or -EnvelopeJson.' }

$env = ConvertFrom-RbcEnvelope -Json $rawJson
foreach ($req in @('correlationId','intuneDeviceId','entraDeviceId')) {
    $value = $env[(($req.Substring(0,1).ToUpperInvariant()) + $req.Substring(1))]
    if ([string]::IsNullOrWhiteSpace([string]$value)) { throw "Envelope missing required field '$req'." }
}

$ctx = New-RbcContext `
    -ActionType     'bitlocker-rotate' `
    -CorrelationId  $env.CorrelationId `
    -IntuneDeviceId $env.IntuneDeviceId `
    -EntraDeviceId  $env.EntraDeviceId `
    -DeviceName     $env.DeviceName `
    -ForceRearm     $env.ForceRearm

Write-RbcInfo "bitlocker-rotate runbook starting" @{
    corr = $ctx.CorrelationId; entra = $ctx.EntraDeviceId; device = $ctx.DeviceName
}

Disable-AzContextAutosave -Scope Process | Out-Null
$null = Connect-AzAccount -Identity -ErrorAction Stop

# ─── 1) Resolve Entra device object id ─────────────────────────────────────
try {
    $deviceObjId = Resolve-RbcDeviceObjectId -EntraDeviceId $ctx.EntraDeviceId
} catch [RbcGraphError] {
    if ($_.Exception.Kind -eq 'Transient') { throw }
    Write-RbcAudit -EventName $script:RbcAudit.DeniedDeviceResolveFailed -Context $ctx -Level 'Error' -Exception $_.Exception
    Write-RbcTerminalStatus -Context $ctx -State 'denied:device-resolve-failed'
    return
}
if (-not $deviceObjId) {
    Write-RbcAudit -EventName $script:RbcAudit.DeniedDeviceNotInEntra -Context $ctx -Level 'Warning'
    Write-RbcTerminalStatus -Context $ctx -State 'denied:device-not-in-entra'
    return
}

# ─── 2) Group membership check ─────────────────────────────────────────────
if (-not $ctx.AllowedGroupId) {
    Write-RbcAudit -EventName $script:RbcAudit.DeniedGroupCheckFailed -Context $ctx -Level 'Error' -Props @{
        reason = "AllowedGroupId Automation Variable not set"
    }
    Write-RbcTerminalStatus -Context $ctx -State 'denied:group-check-failed'
    return
}
try {
    $inGroup = Test-RbcDeviceInAllowedGroup -DeviceObjectId $deviceObjId -AllowedGroupId $ctx.AllowedGroupId
} catch [RbcGraphError] {
    if ($_.Exception.Kind -eq 'Transient') { throw }
    Write-RbcAudit -EventName $script:RbcAudit.DeniedGroupCheckFailed -Context $ctx -Level 'Error' -Exception $_.Exception
    Write-RbcTerminalStatus -Context $ctx -State 'denied:group-check-failed'
    return
}
if (-not $inGroup) {
    Write-RbcAudit -EventName $script:RbcAudit.DeniedNotInAllowedGroup -Context $ctx -Level 'Warning'
    Write-RbcTerminalStatus -Context $ctx -State 'denied:not-in-allowed-group'
    return
}

# ─── 3) Ownership ──────────────────────────────────────────────────────────
try {
    $managedId = Resolve-RbcManagedDeviceId -EntraDeviceId $ctx.EntraDeviceId
} catch [RbcGraphError] {
    if ($_.Exception.Kind -eq 'Transient') { throw }
    Write-RbcAudit -EventName $script:RbcAudit.DeniedManagedDeviceResolveFailed -Context $ctx -Level 'Error' -Exception $_.Exception
    Write-RbcTerminalStatus -Context $ctx -State 'denied:managed-device-resolve-failed'
    return
}
if (-not $managedId) {
    Write-RbcAudit -EventName $script:RbcAudit.DeniedOwnershipMismatch -Context $ctx -Level 'Warning'
    Write-RbcTerminalStatus -Context $ctx -State 'denied:ownership-mismatch'
    return
}

# ─── 4) Idempotency ────────────────────────────────────────────────────────
$reserve = Reserve-RbcLedger -Context $ctx -IntuneDeviceId $ctx.IntuneDeviceId `
                              -CorrelationId $ctx.CorrelationId -ForceRearm $ctx.ForceRearm
$state = [string]$reserve.State
$entry = $reserve.Entry

if ($state -eq 'RateLimited') {
    Write-RbcAudit -EventName $script:RbcAudit.DeniedRateLimited -Context $ctx -Level 'Warning' -Props @{
        recentActionsInWindow     = $reserve.RecentActionsInWindow
        maxActionsPerDevicePerDay = $reserve.MaxActionsPerDevicePerDay
    }
    Write-RbcTerminalStatus -Context $ctx -State 'denied:rate-limited' -ManagedDeviceId $managedId
    return
}

if ([string]$reserve.Rearmed -ne 'None') {
    $rearmEvent = switch ([string]$reserve.Rearmed) {
        'AfterSuccess'     { $script:RbcAudit.LedgerRearmedAfterSuccess }
        'AfterFailure'     { $script:RbcAudit.LedgerRearmedAfterFailure }
        'AfterPollTimeout' { $script:RbcAudit.LedgerRearmedAfterTimeout }
        'Forced'           { $script:RbcAudit.LedgerRearmedForced }
        default            { $script:RbcAudit.LedgerRearmedAfterSuccess }
    }
    Write-RbcAudit -EventName $rearmEvent -Context $ctx -Props @{
        actionSequence        = [int]$entry.ActionSequence
        previousTerminalState = ([string]$entry.LastTerminalState ?? '(unknown)')
        rearmReason           = [string]$reserve.Rearmed
    }
}

if ($state -eq 'Issued') {
    Write-RbcAudit -EventName $script:RbcAudit.ActionAlreadyIssued -Context $ctx -Props @{
        originalCorrelationId = [string]$entry.CorrelationId
        actionSequence        = [int]$entry.ActionSequence
    }
    Write-RbcTerminalStatus -Context $ctx -State 'denied:already-issued' -ManagedDeviceId $managedId
    return
}
if ($state -eq 'Reserved' -and [string]$entry.CorrelationId -ne $ctx.CorrelationId) {
    Write-RbcAudit -EventName $script:RbcAudit.ActionInProgressElsewhere -Context $ctx -Level 'Warning' -Props @{
        originalCorrelationId = [string]$entry.CorrelationId
    }
    Write-RbcTerminalStatus -Context $ctx -State 'denied:in-progress-elsewhere' -ManagedDeviceId $managedId
    return
}

# ─── 5) Execute rotateBitLockerKeys ────────────────────────────────────────
$rotateUri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$managedId/rotateBitLockerKeys"
try {
    Invoke-RbcGraphApi -Method POST -Uri $rotateUri | Out-Null
    [void](Set-RbcLedgerOutcome -Context $ctx -IntuneDeviceId $ctx.IntuneDeviceId -CorrelationId $ctx.CorrelationId -Outcome 'Issued')
    Write-RbcAudit -EventName $script:RbcAudit.BlRotateIssued -Context $ctx -Props @{
        managedDeviceId = $managedId
    }
    Initialize-RbcActionStatus -Context $ctx -ManagedDeviceId $managedId

    Write-Output (([ordered]@{
        correlationId   = $ctx.CorrelationId
        actionType      = 'bitlocker-rotate'
        state           = 'issued'
        terminal        = $false
        managedDeviceId = $managedId
        source          = 'runbook'
    } | ConvertTo-Json -Compress))
}
catch [RbcGraphError] {
    $err = $_.Exception
    if ($err.Kind -eq 'Permanent') {
        [void](Set-RbcLedgerOutcome -Context $ctx -IntuneDeviceId $ctx.IntuneDeviceId -CorrelationId $ctx.CorrelationId -Outcome 'Failed' -FailureReason $err.Message)
        Write-RbcAudit -EventName $script:RbcAudit.BlRotateFailedPermanent -Context $ctx -Level 'Error' -Exception $err -Props @{
            managedDeviceId = $managedId
        }
        Write-RbcTerminalStatus -Context $ctx -State 'failed:permanent' -ManagedDeviceId $managedId
        return
    }
    Write-RbcAudit -EventName $script:RbcAudit.BlRotateTransientError -Context $ctx -Level 'Warning' -Exception $err -Props @{
        managedDeviceId = $managedId
    }
    throw
}
