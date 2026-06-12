#requires -Version 5.1
<#
.SYNOPSIS
    Publishes IntuneWipeClient.intunewin to Microsoft Intune as a Win32
    LOB app, using the IntuneWin32App PowerShell module.

.DESCRIPTION
    Wraps Connect-MSIntuneGraph + Add-IntuneWin32App with sensible
    defaults: registry-based detection, system-context install, returns
    code 0 = success / 3010 = soft reboot.

    On first run installs the IntuneWin32App module to CurrentUser scope
    if it isn't present. Authentication is interactive via the well-known
    Microsoft Intune PowerShell first-party client (no app reg needed).

.PARAMETER ApiUrl
    Wipe API endpoint, baked into the install command line.
.PARAMETER FunctionKey
    Function key for the API, baked into the install command line.
.PARAMETER TenantId
    Entra tenant id (defaults to current az context).
.PARAMETER AssignToGroupId
    Optional Entra group object id to assign the app to as Required.
.PARAMETER Publisher
    Vendor name shown in Company Portal.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]  [string] $ApiUrl,
    [Parameter(Mandatory = $true)]  [string] $FunctionKey,
    [Parameter(Mandatory = $false)] [string] $TenantId,
    [Parameter(Mandatory = $false)] [string] $AssignToGroupId,
    [Parameter(Mandatory = $false)] [string] $Publisher = 'MSLABS IT',
    [Parameter(Mandatory = $false)] [string] $DisplayName = 'Intune Wipe Self-Service Client',
    [Parameter(Mandatory = $false)] [string] $CertificateIssuerLike = '*MSLABS-SUBCA01*',
    [Parameter(Mandatory = $false)] [string] $CertificateSubjectLike,
    # Well-known Microsoft Intune PowerShell first-party app (has Intune scopes
    # pre-consented in most tenants). Override with your own app reg if you have
    # one bound to DeviceManagementApps.ReadWrite.All.
    [Parameter(Mandatory = $false)] [string] $ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e',
    [Parameter(Mandatory = $false)] [switch] $DeviceCode
)

$ErrorActionPreference = 'Stop'

$Root        = $PSScriptRoot
$DistDir     = Join-Path $Root 'dist'
$SourceDir   = Join-Path $Root 'source'
$Package     = Join-Path $DistDir 'IntuneWipeClient.intunewin'
$Description = @'
Self-service Intune device wipe client. Adds a Start Menu / Desktop
shortcut ("Migrazione a MODERN") that, after explicit user confirmation,
calls the corporate wipe API to factory-reset this device. The device will
be unusable for approximately 90 minutes after confirmation.
'@

if (-not (Test-Path $Package)) {
    throw "Package not found: $Package`nRun .\Build-IntuneWinPackage.ps1 first."
}

$version = (Get-Content (Join-Path $SourceDir 'version.txt') -Raw).Trim()
if (-not $version) { throw "source\version.txt is empty." }

# --- Ensure module ----------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name IntuneWin32App)) {
    Write-Host "==> Installing IntuneWin32App module (CurrentUser) ..." -ForegroundColor Cyan
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
    }
    Install-Module IntuneWin32App -Scope CurrentUser -Force -AllowClobber
}
Import-Module IntuneWin32App -Force

# --- Resolve tenant ---------------------------------------------------------
if (-not $TenantId) {
    try {
        $TenantId = (az account show --query tenantId -o tsv 2>$null)
    } catch { }
    if (-not $TenantId) { throw "TenantId not provided and could not be inferred from az context." }
}
Write-Host "==> Tenant: $TenantId"
Write-Host "==> Acquiring Graph access token (device code flow) ..." -ForegroundColor Cyan
# We do the device code flow ourselves so the user-facing URL+code is printed
# immediately to STDOUT (Connect-MgGraph buffers its prompt under PS7).
$clientId = $ClientId
$dcUri    = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode"
$tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
$scopeStr = 'https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All offline_access'

$dc = Invoke-RestMethod -Method Post -Uri $dcUri -Body @{
    client_id = $clientId
    scope     = $scopeStr
}
Write-Host ""
Write-Host "  >>> Open in browser : $($dc.verification_uri)" -ForegroundColor Yellow
Write-Host "  >>> Enter the code  : $($dc.user_code)"           -ForegroundColor Yellow
Write-Host ""
[Console]::Out.Flush()

$start    = Get-Date
$interval = [int]$dc.interval
if ($interval -lt 5) { $interval = 5 }
$rawToken = $null
while (-not $rawToken) {
    if (((Get-Date) - $start).TotalSeconds -ge $dc.expires_in) {
        throw "Device code expired before sign-in completed."
    }
    Start-Sleep -Seconds $interval
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $tokenUri -Body @{
            client_id  = $clientId
            grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
            device_code = $dc.device_code
        } -ErrorAction Stop
        $rawToken = $resp.access_token
        $expiresOnUtc = (Get-Date).ToUniversalTime().AddSeconds([int]$resp.expires_in)
    }
    catch {
        $errBody = $null
        try { $errBody = $_.ErrorDetails.Message | ConvertFrom-Json } catch {
            try { $errBody = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() | ConvertFrom-Json } catch { }
        }
        switch ($errBody.error) {
            'authorization_pending' { continue }
            'slow_down'             { $interval += 5; continue }
            'authorization_declined'{ throw "User declined the sign-in." }
            'expired_token'         { throw "Device code expired." }
            default                 { throw "Token error: $($errBody.error) - $($errBody.error_description)" }
        }
    }
}

$Global:AccessToken = [pscustomobject]@{
    access_token = $rawToken
    ExpiresOn    = $expiresOnUtc
    Scopes       = @('DeviceManagementApps.ReadWrite.All')
    AccessToken  = $rawToken
}
$Global:AccessTokenTenantID  = $TenantId
$Global:AuthenticationHeader = @{
    'Content-Type'  = 'application/json'
    'Authorization' = "Bearer $rawToken"
    'ExpiresOn'     = $expiresOnUtc
}
Write-Host ("    Token OK (expires {0:HH:mm:ss}Z)" -f $expiresOnUtc) -ForegroundColor Green

# --- Build install / uninstall / detection ---------------------------------
$installParts = @(
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ".\Install.ps1"'
    "-ApiUrl `"$ApiUrl`""
    "-FunctionKey `"$FunctionKey`""
    "-CertificateIssuerLike `"$CertificateIssuerLike`""
)
if ($CertificateSubjectLike) {
    $installParts += "-CertificateSubjectLike `"$CertificateSubjectLike`""
}
$installCmd = $installParts -join ' '

$uninstallCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ".\Uninstall.ps1"'

$detection = New-IntuneWin32AppDetectionRuleRegistry `
    -StringComparison `
    -KeyPath 'HKEY_LOCAL_MACHINE\SOFTWARE\MSLABS\IntuneWipeClient' `
    -ValueName 'Version' `
    -StringComparisonOperator 'equal' `
    -StringComparisonValue $version

$requirement = New-IntuneWin32AppRequirementRule `
    -Architecture 'AllWithARM64' `
    -MinimumSupportedWindowsRelease 'W10_1809'

# --- Look up existing app by display name (idempotent) ----------------------
Write-Host "==> Checking for existing app '$DisplayName' ..."
$existing = Get-IntuneWin32App -DisplayName $DisplayName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host ("    Found existing app id {0} (version {1}); removing before re-publishing." -f $existing.id, $existing.displayVersion)
    Remove-IntuneWin32App -ID $existing.id -Confirm:$false | Out-Null
    Start-Sleep -Seconds 5
}

Write-Host "==> Uploading $Package ($([Math]::Round((Get-Item $Package).Length / 1KB,1)) KB) ..." -ForegroundColor Cyan
$app = Add-IntuneWin32App `
    -FilePath $Package `
    -DisplayName $DisplayName `
    -Description $Description `
    -Publisher $Publisher `
    -AppVersion $version `
    -InstallExperience 'system' `
    -RestartBehavior 'suppress' `
    -DetectionRule $detection `
    -RequirementRule $requirement `
    -InstallCommandLine $installCmd `
    -UninstallCommandLine $uninstallCmd `
    -Verbose

Write-Host ""
Write-Host ("Published: {0}  (id: {1})" -f $app.displayName, $app.id) -ForegroundColor Green

if ($AssignToGroupId) {
    Write-Host "==> Assigning to group $AssignToGroupId (Required) ..." -ForegroundColor Cyan
    Add-IntuneWin32AppAssignmentGroup -Include `
        -ID $app.id `
        -GroupID $AssignToGroupId `
        -Intent 'required' `
        -Notification 'showAll'
    Write-Host "    Assignment created."
} else {
    Write-Host "(No -AssignToGroupId provided; assign the app manually in Intune.)"
}
