#requires -Version 7.2
<#
.SYNOPSIS
    Ops runbook (PowerShell 7.2) — re-enables publicNetworkAccess on
    storage accounts in this resource group.

.DESCRIPTION
    Microsoft Defender for Cloud (SP 7355f99c-0211-455d-aa02-4a559687ae60)
    periodically remediates the MCAPS initiative `MCAPSGovDeployPolicies`
    (policy `StorageAccount_New_Deploy`, deployIfNotExists at MG root
    46b06a5e-8f7a-467b-bc9a-e776011fbb57) and flips
    `publicNetworkAccess` to `Disabled` on storage accounts in
    `RG-INTUNE-DEVICEACTIONS`. The wipe schedule storage account
    (`idactionsstwdev`) MUST stay `Enabled` because the `idactions-portal`
    Web App accesses it over the public endpoint via Managed Identity +
    RBAC (no VNet integration is provisioned for the portal).

    A proper Policy Exemption requires
    `Microsoft.Authorization/policyAssignments/exempt/action` at the MG
    root scope, which the project team does not hold. Until MCAPS
    Governance grants that permission (or creates the exemption itself),
    this runbook restores the desired state on demand.

    This runbook is intentionally NOT scheduled. Operators run it
    manually (or from the `idactions-portal` Schedule page failure
    banner) when the Schedule page returns a 403 from the Table API.

.PARAMETER ResourceGroupName
    Resource group to scan. Defaults to `RG-INTUNE-DEVICEACTIONS`.

.PARAMETER StorageAccountNames
    Optional. Limits the scope to the named storage accounts. When
    omitted, every storage account in the resource group is processed.

.PARAMETER WhatIf
    Standard PowerShell `-WhatIf` switch. When supplied the runbook
    reports the accounts it WOULD update without calling
    `Set-AzStorageAccount`.

.NOTES
    Requires `Az.Accounts` and `Az.Storage` (shipped with the
    PowerShell-7.2 runtime environment in Azure Automation).

    The Automation Account's system-assigned managed identity needs
    `Storage Account Contributor` on the target resource group (granted
    out-of-band — see deployment notes).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = 'RG-INTUNE-DEVICEACTIONS',

    [Parameter(Mandatory = $false)]
    [string[]]$StorageAccountNames
)

$ErrorActionPreference = 'Stop'

Write-Output "[$(Get-Date -Format o)] Connecting with system-assigned managed identity..."
Disable-AzContextAutosave -Scope Process | Out-Null
$null = Connect-AzAccount -Identity

$ctx = Get-AzContext
Write-Output "[$(Get-Date -Format o)] Connected. Subscription = $($ctx.Subscription.Name) ($($ctx.Subscription.Id))"
Write-Output "[$(Get-Date -Format o)] Scanning storage accounts in resource group '$ResourceGroupName'..."

$accounts = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName

if ($StorageAccountNames) {
    $accounts = $accounts | Where-Object { $StorageAccountNames -contains $_.StorageAccountName }
}

if (-not $accounts) {
    Write-Output "[$(Get-Date -Format o)] No matching storage accounts found. Nothing to do."
    return
}

$updated  = 0
$alreadyOk = 0
$failed   = 0

foreach ($sa in $accounts) {
    $name    = $sa.StorageAccountName
    $current = $sa.PublicNetworkAccess

    if ($current -eq 'Enabled') {
        Write-Output "[$(Get-Date -Format o)] [$name] publicNetworkAccess already 'Enabled' — skipping."
        $alreadyOk++
        continue
    }

    Write-Output "[$(Get-Date -Format o)] [$name] publicNetworkAccess = '$current' — restoring to 'Enabled'."

    if ($PSCmdlet.ShouldProcess($name, "Set publicNetworkAccess = Enabled")) {
        try {
            $null = Set-AzStorageAccount `
                -ResourceGroupName $ResourceGroupName `
                -Name $name `
                -PublicNetworkAccess 'Enabled'
            Write-Output "[$(Get-Date -Format o)] [$name] updated."
            $updated++
        }
        catch {
            Write-Error "[$(Get-Date -Format o)] [$name] FAILED: $($_.Exception.Message)"
            $failed++
        }
    }
}

Write-Output ""
Write-Output "[$(Get-Date -Format o)] Summary: updated=$updated, alreadyEnabled=$alreadyOk, failed=$failed, scanned=$($accounts.Count)"

if ($failed -gt 0) {
    throw "Runbook completed with $failed failure(s)."
}
