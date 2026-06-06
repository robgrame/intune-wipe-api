#requires -Version 7.2
<#
.SYNOPSIS
    Azure Automation Runbook (PowerShell 7.2) — autopilot-register capability
    executor with functional parity to
    IntuneDeviceActions.Capabilities.Autopilot.AutopilotRegisterRunner.

.DESCRIPTION
    Pipeline (mirrors AutopilotRegisterRunner.RunAsync):
        0. Payload validation — hardwareIdentifier mandatory (from extras)
        1. Idempotency reservation (auto-rearm + 24h rolling rate limit)
        2. Issue Graph importedWindowsAutopilotDeviceIdentities → mark ledger,
           audit, init status tracker with importIdentity id as the probe handle

    NO Entra resolve / NO group check / NO ownership step — Autopilot
    registration is intentionally usable on hardware that has never been
    Entra-joined (mirrors the .NET runner's documented behaviour). Safety
    relies on the mTLS edge + Actions:AllowedTypes allowlist + idempotency.

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
foreach ($req in @('correlationId','intuneDeviceId')) {
    $value = $env[(($req.Substring(0,1).ToUpperInvariant()) + $req.Substring(1))]
    if ([string]::IsNullOrWhiteSpace([string]$value)) { throw "Envelope missing required field '$req'." }
}

$ctx = New-RbcContext `
    -ActionType     'autopilot-register' `
    -CorrelationId  $env.CorrelationId `
    -IntuneDeviceId $env.IntuneDeviceId `
    -EntraDeviceId  $env.EntraDeviceId `
    -DeviceName     $env.DeviceName `
    -ForceRearm     $env.ForceRearm

Write-RbcInfo "autopilot-register runbook starting" @{
    corr = $ctx.CorrelationId; intune = $ctx.IntuneDeviceId; device = $ctx.DeviceName
}

Disable-AzContextAutosave -Scope Process | Out-Null
$null = Connect-AzAccount -Identity -ErrorAction Stop

# ─── 0) Payload validation: hardwareIdentifier required ────────────────────
$serial     = Get-RbcExtra -Extras $env.Extras -Name 'serialNumber'
$hwHashB64  = Get-RbcExtra -Extras $env.Extras -Name 'hardwareIdentifier'
$groupTag   = Get-RbcExtra -Extras $env.Extras -Name 'groupTag'
$productKey = Get-RbcExtra -Extras $env.Extras -Name 'productKey'

if (-not $hwHashB64) {
    Write-RbcAudit -EventName $script:RbcAudit.ApDeniedMissingHardwareHash -Context $ctx -Level 'Warning' -Props @{
        serialNumber = ($serial ?? '')
    }
    Write-RbcTerminalStatus -Context $ctx -State 'denied:missing-hardware-hash'
    return
}

# ─── 1) Idempotency reservation ────────────────────────────────────────────
$reserve = Reserve-RbcLedger -Context $ctx -IntuneDeviceId $ctx.IntuneDeviceId `
                              -CorrelationId $ctx.CorrelationId -ForceRearm $ctx.ForceRearm
$state = [string]$reserve.State
$entry = $reserve.Entry

if ($state -eq 'RateLimited') {
    Write-RbcAudit -EventName $script:RbcAudit.DeniedRateLimited -Context $ctx -Level 'Warning' -Props @{
        recentActionsInWindow     = $reserve.RecentActionsInWindow
        maxActionsPerDevicePerDay = $reserve.MaxActionsPerDevicePerDay
    }
    Write-RbcTerminalStatus -Context $ctx -State 'denied:rate-limited'
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
    Write-RbcTerminalStatus -Context $ctx -State 'denied:already-issued'
    return
}
if ($state -eq 'Reserved' -and [string]$entry.CorrelationId -ne $ctx.CorrelationId) {
    Write-RbcAudit -EventName $script:RbcAudit.ActionInProgressElsewhere -Context $ctx -Level 'Warning' -Props @{
        originalCorrelationId = [string]$entry.CorrelationId
    }
    Write-RbcTerminalStatus -Context $ctx -State 'denied:in-progress-elsewhere'
    return
}

# ─── 2) Execute Autopilot import ───────────────────────────────────────────
$importUri = 'https://graph.microsoft.com/v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities'
$importBody = @{
    '@odata.type'      = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
    serialNumber       = ($serial ?? '')
    hardwareIdentifier = $hwHashB64
}
if ($groupTag)   { $importBody['groupTag']   = $groupTag }
if ($productKey) { $importBody['productKey'] = $productKey }

try {
    $resp = Invoke-RbcGraphApi -Method POST -Uri $importUri -Body $importBody
    $importIdentityId = [string]$resp.id
    [void](Set-RbcLedgerOutcome -Context $ctx -IntuneDeviceId $ctx.IntuneDeviceId -CorrelationId $ctx.CorrelationId -Outcome 'Issued')
    Write-RbcAudit -EventName $script:RbcAudit.ApImportIssued -Context $ctx -Props @{
        managedDeviceId = $importIdentityId
        importStatus    = [string]$resp.state.deviceImportStatus
        serialNumber    = ($serial ?? '')
        groupTag        = ($groupTag ?? '')
    }
    Initialize-RbcActionStatus -Context $ctx -ManagedDeviceId $importIdentityId

    Write-Output (([ordered]@{
        correlationId    = $ctx.CorrelationId
        actionType       = 'autopilot-register'
        state            = 'issued'
        terminal         = $false
        importIdentityId = $importIdentityId
        serialNumber     = $serial
        groupTag         = $groupTag
        source           = 'runbook'
    } | ConvertTo-Json -Compress))
}
catch [RbcGraphError] {
    $err = $_.Exception
    if ($err.Kind -eq 'Permanent') {
        [void](Set-RbcLedgerOutcome -Context $ctx -IntuneDeviceId $ctx.IntuneDeviceId -CorrelationId $ctx.CorrelationId -Outcome 'Failed' -FailureReason $err.Message)
        Write-RbcAudit -EventName $script:RbcAudit.ApImportFailedPermanent -Context $ctx -Level 'Error' -Exception $err -Props @{
            serialNumber = ($serial ?? '')
            groupTag     = ($groupTag ?? '')
        }
        Write-RbcTerminalStatus -Context $ctx -State 'failed:permanent'
        return
    }
    Write-RbcAudit -EventName $script:RbcAudit.ApImportTransientError -Context $ctx -Level 'Warning' -Exception $err
    throw
}
