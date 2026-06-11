#requires -Version 5.1
<#
.SYNOPSIS
    Grants Microsoft Graph application permissions (app roles) to the
    User-Assigned Managed Identities used by IntuneDeviceActions.

.DESCRIPTION
    Performs app-role assignments on the Microsoft Graph service principal for:
      - uamiWipe  (privileged): DeviceManagementManagedDevices.PrivilegedOperations.All,
                                DeviceManagementManagedDevices.Read.All,
                                Device.Read.All, GroupMember.Read.All
      - uamiAutopilot (privileged): DeviceManagementServiceConfig.ReadWrite.All,
                                DeviceManagementManagedDevices.Read.All,
                                Device.Read.All, GroupMember.Read.All
      - uamiBitLocker (privileged): DeviceManagementManagedDevices.PrivilegedOperations.All,
                                DeviceManagementManagedDevices.Read.All,
                                Device.Read.All, GroupMember.Read.All
      - uamiWeb   (public web)  : Device.Read.All
                                  (used by DeviceDirectoryResolver to resolve
                                   client-cert SAN DNS / Subject CN -> Entra
                                   deviceId via Microsoft Graph when the cert
                                   does not embed the GUID directly. Without
                                   this grant, mTLS clients with on-prem PKI
                                   certs are rejected with 401 "client
                                   certificate is missing the configured
                                   device-id binding claim".)
      - uami      (status poller): DeviceManagementManagedDevices.Read.All

    Idempotent: existing assignments are detected via 409/duplicate and skipped.

    REQUIRED PERMISSIONS for the caller (you):
      - One of: Global Administrator, Privileged Role Administrator, or Cloud Application Administrator
        (any of these can grant Graph application permissions).

.PARAMETER ResourceGroup
    RG where the UAMIs live.

.PARAMETER NamePrefix
    Name prefix used in the deployment (default: idactions).

.EXAMPLE
    .\tools\Grant-GraphPermissions.ps1 -ResourceGroup rg-idactions-dev
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$NamePrefix = 'idactions'
)

$ErrorActionPreference = 'Stop'

function Write-Ok($m)   { Write-Host "    [OK]   $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Write-Err2($m) { Write-Host "    [ERR]  $m" -ForegroundColor Red }
function Write-Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }

$graphAppId = '00000003-0000-0000-c000-000000000000'

# Roles to assign per UAMI logical name (matches Bicep)
$assignments = @{
    'uamiWipe' = @(
        'DeviceManagementManagedDevices.PrivilegedOperations.All',
        'DeviceManagementManagedDevices.Read.All',
        'Device.Read.All',
        'GroupMember.Read.All'
    )
    'uamiAutopilot' = @(
        'DeviceManagementServiceConfig.ReadWrite.All',
        'DeviceManagementManagedDevices.Read.All',
        'Device.Read.All',
        'GroupMember.Read.All'
    )
    'uamiBitLocker' = @(
        'DeviceManagementManagedDevices.PrivilegedOperations.All',
        'DeviceManagementManagedDevices.Read.All',
        'Device.Read.All',
        'GroupMember.Read.All'
    )
    'uamiRename' = @(
        # setDeviceName is a privileged Intune action (rename queued for next MDM sync)
        'DeviceManagementManagedDevices.PrivilegedOperations.All',
        # Read.All used to fetch managedDevice for diagnostics / status init
        'DeviceManagementManagedDevices.Read.All',
        # Entra displayName collision pre-check (devices?$filter=displayName eq ...)
        'Device.Read.All'
    )
    'uamiWeb'  = @(
        # DeviceDirectoryResolver resolves client-cert SAN DNS / Subject CN to
        # Entra deviceId for the cert<->device IDOR binding gate. Read-only.
        'Device.Read.All'
    )
    'uami'     = @(
        'DeviceManagementManagedDevices.Read.All'
    )
}

# Map logical name -> actual UAMI Azure resource name (matches main.bicep)
$uamiResourceNames = @{
    'uamiWipe'      = "$NamePrefix-uami-wipe-*"
    'uamiAutopilot' = "$NamePrefix-uami-autopilot-*"
    'uamiBitLocker' = "$NamePrefix-uami-bitlocker-*"
    'uamiRename'    = "$NamePrefix-uami-rename-*"
    'uamiWeb'       = "$NamePrefix-uami-web-*"
    'uami'          = "$NamePrefix-uami-*"   # filtered to exclude -wipe-/-web-/-autopilot-/-bitlocker-/-rename-
}

Write-Step "Resolving Microsoft Graph service principal"
$graphUrl = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$graphAppId'"
$graphResp = az rest --method GET --url $graphUrl -o json | ConvertFrom-Json
$graphSp = $graphResp.value | Select-Object -First 1
if (-not $graphSp -or -not $graphSp.id) { throw "Microsoft Graph SP not found" }
Write-Ok "Graph SP objectId: $($graphSp.id)"

# Build a role-name -> appRoleId map (only Application type roles)
$roleMap = @{}
foreach ($r in $graphSp.appRoles) {
    if ($r.allowedMemberTypes -contains 'Application') { $roleMap[$r.value] = $r.id }
}

Write-Step "Locating User-Assigned Managed Identities in $ResourceGroup"
$allUamis = az identity list -g $ResourceGroup -o json | ConvertFrom-Json
if (-not $allUamis) { throw "No UAMIs found in $ResourceGroup" }

$uamiByLogical = @{}
$uamiWipe = $allUamis | Where-Object { $_.name -like "$NamePrefix-uami-wipe-*" } | Select-Object -First 1
$uamiAutopilot = $allUamis | Where-Object { $_.name -like "$NamePrefix-uami-autopilot-*" } | Select-Object -First 1
$uamiBitLocker = $allUamis | Where-Object { $_.name -like "$NamePrefix-uami-bitlocker-*" } | Select-Object -First 1
$uamiRename    = $allUamis | Where-Object { $_.name -like "$NamePrefix-uami-rename-*" } | Select-Object -First 1
$uamiWeb       = $allUamis | Where-Object { $_.name -like "$NamePrefix-uami-web-*" } | Select-Object -First 1
$uamiPoll = $allUamis | Where-Object { $_.name -like "$NamePrefix-uami-*" -and $_.name -notlike "$NamePrefix-uami-wipe-*" -and $_.name -notlike "$NamePrefix-uami-web-*" -and $_.name -notlike "$NamePrefix-uami-autopilot-*" -and $_.name -notlike "$NamePrefix-uami-bitlocker-*" -and $_.name -notlike "$NamePrefix-uami-rename-*" } | Select-Object -First 1
if (-not $uamiWipe) { throw "uamiWipe not found (pattern $NamePrefix-uami-wipe-*)" }
if (-not $uamiAutopilot) { throw "uamiAutopilot not found (pattern $NamePrefix-uami-autopilot-*)" }
if (-not $uamiBitLocker) { throw "uamiBitLocker not found (pattern $NamePrefix-uami-bitlocker-*)" }
if (-not $uamiRename)    { Write-Warn2 "uamiRename not found (pattern $NamePrefix-uami-rename-*) - skipping rename role grants (deploy with current bicep to create it)" }
if (-not $uamiWeb)       { Write-Warn2 "uamiWeb not found (pattern $NamePrefix-uami-web-*) - skipping DeviceDirectoryResolver grant; mTLS cert<->device binding via SAN DNS lookup will fail-closed." }
if (-not $uamiPoll) { throw "uami (status poller) not found (pattern $NamePrefix-uami-* excluding -wipe-/-web-/-autopilot-/-bitlocker-/-rename-)" }
$uamiByLogical['uamiWipe'] = $uamiWipe
$uamiByLogical['uamiAutopilot'] = $uamiAutopilot
$uamiByLogical['uamiBitLocker'] = $uamiBitLocker
if ($uamiRename) { $uamiByLogical['uamiRename'] = $uamiRename }
if ($uamiWeb)    { $uamiByLogical['uamiWeb']    = $uamiWeb }
$uamiByLogical['uami']     = $uamiPoll
Write-Ok "uamiWipe      -> $($uamiWipe.name)  (principalId $($uamiWipe.principalId))"
Write-Ok "uamiAutopilot -> $($uamiAutopilot.name)  (principalId $($uamiAutopilot.principalId))"
Write-Ok "uamiBitLocker -> $($uamiBitLocker.name)  (principalId $($uamiBitLocker.principalId))"
if ($uamiRename) { Write-Ok "uamiRename    -> $($uamiRename.name)  (principalId $($uamiRename.principalId))" }
if ($uamiWeb)    { Write-Ok "uamiWeb       -> $($uamiWeb.name)  (principalId $($uamiWeb.principalId))" }
Write-Ok "uami          -> $($uamiPoll.name)  (principalId $($uamiPoll.principalId))"

$totalGranted = 0
$totalSkipped = 0
$totalFailed  = 0

foreach ($logical in $assignments.Keys) {
    if (-not $uamiByLogical.ContainsKey($logical)) {
        Write-Warn2 "Skipping '$logical' — UAMI not present in $ResourceGroup (deploy bicep first if you need this capability)."
        continue
    }
    $uami = $uamiByLogical[$logical]
    $principalId = $uami.principalId
    Write-Step "Granting roles to $logical ($($uami.name))"

    # Fetch existing assignments once for idempotency
    $existing = az rest --method GET `
        --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
        -o json | ConvertFrom-Json
    $existingRoleIds = @($existing.value | ForEach-Object { $_.appRoleId })

    foreach ($roleName in $assignments[$logical]) {
        $appRoleId = $roleMap[$roleName]
        if (-not $appRoleId) {
            Write-Err2 "Role not found on Graph SP: $roleName"
            $totalFailed++
            continue
        }
        if ($existingRoleIds -contains $appRoleId) {
            Write-Warn2 "Already assigned: $roleName"
            $totalSkipped++
            continue
        }
        $body = @{
            principalId = $principalId
            resourceId  = $graphSp.id
            appRoleId   = $appRoleId
        } | ConvertTo-Json -Compress

        $tmp = [IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $tmp -Value $body -Encoding ASCII -NoNewline
            $resp = az rest --method POST `
                --url "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
                --headers "Content-Type=application/json" `
                --body "@$tmp" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "Granted: $roleName"
                $totalGranted++
            } else {
                Write-Err2 "Failed: $roleName  ->  $resp"
                $totalFailed++
            }
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
Write-Host "============ Summary ============" -ForegroundColor Cyan
Write-Host "  Granted: $totalGranted" -ForegroundColor Green
Write-Host "  Skipped: $totalSkipped (already present)" -ForegroundColor Yellow
Write-Host "  Failed:  $totalFailed" -ForegroundColor $(if ($totalFailed) {'Red'} else {'DarkGray'})
Write-Host "================================="

# ── Optional: Automation Account SystemAssigned MI (runbook variant) ─────────
# The 3 runbooks (Invoke-DeviceWipe / Invoke-AutopilotRegister /
# Invoke-RotateBitLockerKey) authenticate as the Automation Account's
# system-assigned MI. We grant the union of the 3 capability role sets so a
# single MI can execute any of them.
Write-Step "Optional: Automation Account (runbook variant)"
$aaList = az automation account list -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
$aa = @($aaList) | Where-Object { $_.name -like "$NamePrefix-aa-*" } | Select-Object -First 1
if (-not $aa) {
    Write-Warn2 "No Automation Account ($NamePrefix-aa-*) found in $ResourceGroup -- skipping (enableRunbookVariant=false)."
} else {
    $aaPrincipalId = $aa.identity.principalId
    if (-not $aaPrincipalId) {
        Write-Warn2 "Automation Account $($aa.name) has no SystemAssigned identity -- skipping."
    } else {
        Write-Ok "Automation Account: $($aa.name)  (principalId $aaPrincipalId)"
        $aaRoles = @(
            'DeviceManagementManagedDevices.PrivilegedOperations.All',
            'DeviceManagementManagedDevices.Read.All',
            'DeviceManagementServiceConfig.ReadWrite.All',
            'Device.Read.All',
            'GroupMember.Read.All'
        )
        $aaExisting = az rest --method GET `
            --url "https://graph.microsoft.com/v1.0/servicePrincipals/$aaPrincipalId/appRoleAssignments" `
            -o json | ConvertFrom-Json
        $aaExistingRoleIds = @($aaExisting.value | ForEach-Object { $_.appRoleId })
        foreach ($roleName in $aaRoles) {
            $appRoleId = $roleMap[$roleName]
            if (-not $appRoleId) { Write-Err2 "Role not found: $roleName"; $totalFailed++; continue }
            if ($aaExistingRoleIds -contains $appRoleId) {
                Write-Warn2 "Already assigned: $roleName"; $totalSkipped++; continue
            }
            $body = @{ principalId=$aaPrincipalId; resourceId=$graphSp.id; appRoleId=$appRoleId } | ConvertTo-Json -Compress
            $tmp = [IO.Path]::GetTempFileName()
            try {
                Set-Content -Path $tmp -Value $body -Encoding ASCII -NoNewline
                $resp = az rest --method POST `
                    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$aaPrincipalId/appRoleAssignments" `
                    --headers "Content-Type=application/json" --body "@$tmp" 2>&1
                if ($LASTEXITCODE -eq 0) { Write-Ok "Granted: $roleName"; $totalGranted++ }
                else { Write-Err2 "Failed: $roleName  ->  $resp"; $totalFailed++ }
            } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
}

Write-Host ""
Write-Host "======= Final Summary (incl. AA if any) =======" -ForegroundColor Cyan
Write-Host "  Granted: $totalGranted" -ForegroundColor Green
Write-Host "  Skipped: $totalSkipped (already present)" -ForegroundColor Yellow
Write-Host "  Failed:  $totalFailed" -ForegroundColor $(if ($totalFailed) {'Red'} else {'DarkGray'})
Write-Host "==============================================="
if ($totalFailed) { exit 1 }
