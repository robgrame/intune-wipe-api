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
.PARAMETER StatusPollIntervalSeconds
    Default polling interval baked into the installed client.
.PARAMETER StatusPollMaxMinutes
    Default maximum live-monitoring duration baked into the installed client.
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
    [Parameter(Mandatory = $false)] [int] $StatusPollIntervalSeconds = 5,
    [Parameter(Mandatory = $false)] [int] $StatusPollMaxMinutes = 30,
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

# Quick PS5.1 vs PS7 detection — needed because System.Net.HttpListener
# behaves identically on both, but `Start-Process` URL handling differs.
$IsPwsh7 = ($PSVersionTable.PSVersion.Major -ge 7)

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

# ---------------------------------------------------------------------------
# Token acquisition. Two flows are supported:
#   * Default: Interactive Authorization Code w/ PKCE — opens the system
#     browser, captures the redirect on http://localhost:<port>/, and
#     exchanges the code for an access token. Zero copy-paste UX.
#   * Fallback: Device code (-DeviceCode switch) — useful on headless boxes,
#     RDP without browser, or CI runners.
# Both flows require the app registration to have
#   * "Allow public client flows" = Yes
#   * redirect URI 'http://localhost' (public client / mobile-desktop)
# IntuneUp-Deploy (70586042-...) already satisfies both.
# ---------------------------------------------------------------------------
$scopeStr = 'https://graph.microsoft.com/DeviceManagementApps.ReadWrite.All offline_access openid profile'

function Get-TokenInteractive {
    param(
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$Scope
    )

    # PKCE code verifier + challenge (RFC 7636).
    $bytes = New-Object byte[] 64
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $codeVerifier = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($codeVerifier))
    $codeChallenge = [Convert]::ToBase64String($hash).TrimEnd('=').Replace('+','-').Replace('/','_')
    $state = [Guid]::NewGuid().Guid

    # Bind a free localhost port. HttpListener requires the prefix to end with /.
    $listener = New-Object System.Net.HttpListener
    $port = $null
    foreach ($candidate in 49152..49200) {
        try {
            $listener.Prefixes.Clear()
            $listener.Prefixes.Add("http://localhost:$candidate/")
            $listener.Start()
            $port = $candidate
            break
        } catch {
            try { $listener.Close() } catch { }
            $listener = New-Object System.Net.HttpListener
        }
    }
    if (-not $port) { throw "Could not bind any port in 49152-49200 for the local redirect listener." }
    $redirectUri = "http://localhost:$port/"

    $authUri = $null
    $qs = [System.Web.HttpUtility]::ParseQueryString('')
    $qs.Add('client_id',             $ClientId)
    $qs.Add('response_type',         'code')
    $qs.Add('redirect_uri',          $redirectUri)
    $qs.Add('response_mode',         'query')
    $qs.Add('scope',                 $Scope)
    $qs.Add('state',                 $state)
    $qs.Add('code_challenge',        $codeChallenge)
    $qs.Add('code_challenge_method', 'S256')
    $qs.Add('prompt',                'select_account')
    $authUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize?" + $qs.ToString()

    # Sanity check: redirect_uri must round-trip as absolute http://localhost
    # URI or Entra rejects with AADSTS90102. Catch this client-side rather
    # than after a browser round-trip.
    $parsed = $null
    if (-not [Uri]::TryCreate($redirectUri, [UriKind]::Absolute, [ref]$parsed)) {
        throw "Internal: redirect URI '$redirectUri' is not a valid absolute URI."
    }
    if ($parsed.Scheme -ne 'http' -or $parsed.Host -ne 'localhost') {
        throw "Internal: redirect URI '$redirectUri' must be http://localhost:<port>/."
    }

    Write-Host "==> Opening browser for sign-in ..." -ForegroundColor Cyan
    Write-Host ("    redirect_uri = {0}" -f $redirectUri) -ForegroundColor DarkGray
    Write-Host ("    authorize    = {0}" -f $authUri)     -ForegroundColor DarkGray
    Start-Process $authUri | Out-Null

    # Block up to 5 minutes waiting for the redirect callback.
    $ctxTask = $listener.GetContextAsync()
    if (-not $ctxTask.Wait([TimeSpan]::FromMinutes(5))) {
        try { $listener.Stop() } catch { }
        throw "Timed out waiting for the browser to complete sign-in."
    }
    $ctx = $ctxTask.Result
    $query = [System.Web.HttpUtility]::ParseQueryString($ctx.Request.Url.Query)
    $code      = $query['code']
    $gotState  = $query['state']
    $err       = $query['error']
    $errDesc   = $query['error_description']

    $html = if ($err) {
        "<html><body style='font-family:Segoe UI,sans-serif;padding:2rem'><h2 style='color:#b00'>Sign-in failed</h2><p>$err</p><pre>$errDesc</pre><p>You can close this tab.</p></body></html>"
    } else {
        "<html><body style='font-family:Segoe UI,sans-serif;padding:2rem'><h2 style='color:#080'>Sign-in completed</h2><p>You can close this tab and return to PowerShell.</p></body></html>"
    }
    $buf = [System.Text.Encoding]::UTF8.GetBytes($html)
    $ctx.Response.ContentType   = 'text/html; charset=utf-8'
    $ctx.Response.ContentLength64 = $buf.Length
    $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
    $ctx.Response.OutputStream.Close()
    try { $listener.Stop() } catch { }

    if ($err) { throw "Authorization endpoint returned error '$err': $errDesc" }
    if ($gotState -ne $state) { throw "State mismatch in OAuth callback (CSRF guard tripped)." }
    if (-not $code) { throw "Authorization code missing in callback." }

    Write-Host "    Code received, exchanging for access token ..." -ForegroundColor DarkCyan
    $resp = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -Body @{
            client_id     = $ClientId
            grant_type    = 'authorization_code'
            code          = $code
            redirect_uri  = $redirectUri
            code_verifier = $codeVerifier
            scope         = $Scope
        }
    [pscustomobject]@{
        AccessToken = $resp.access_token
        ExpiresOn   = (Get-Date).ToUniversalTime().AddSeconds([int]$resp.expires_in)
    }
}

function Get-TokenDeviceCode {
    param(
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$Scope
    )
    $dc = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $ClientId; scope = $Scope }
    Write-Host ""
    Write-Host "  >>> Open in browser : $($dc.verification_uri)" -ForegroundColor Yellow
    Write-Host "  >>> Enter the code  : $($dc.user_code)"           -ForegroundColor Yellow
    Write-Host ""
    [Console]::Out.Flush()

    $start    = Get-Date
    $interval = [int]$dc.interval
    if ($interval -lt 5) { $interval = 5 }
    $rawToken = $null
    $expiresOnUtc = $null
    while (-not $rawToken) {
        if (((Get-Date) - $start).TotalSeconds -ge $dc.expires_in) {
            throw "Device code expired before sign-in completed."
        }
        Start-Sleep -Seconds $interval
        try {
            $resp = Invoke-RestMethod -Method Post `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -Body @{
                    client_id   = $ClientId
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                    device_code = $dc.device_code
                } -ErrorAction Stop
            $rawToken = $resp.access_token
            $expiresOnUtc = (Get-Date).ToUniversalTime().AddSeconds([int]$resp.expires_in)
        } catch {
            $errBody = $null
            try { $errBody = $_.ErrorDetails.Message | ConvertFrom-Json } catch {
                try { $errBody = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() | ConvertFrom-Json } catch { }
            }
            switch ($errBody.error) {
                'authorization_pending'  { continue }
                'slow_down'              { $interval += 5; continue }
                'authorization_declined' { throw "User declined the sign-in." }
                'expired_token'          { throw "Device code expired." }
                default                  { throw "Token error: $($errBody.error) - $($errBody.error_description)" }
            }
        }
    }
    [pscustomobject]@{
        AccessToken = $rawToken
        ExpiresOn   = $expiresOnUtc
    }
}

# System.Web is needed for HttpUtility.ParseQueryString on PS5.1 and PS7.
Add-Type -AssemblyName System.Web | Out-Null

if ($DeviceCode) {
    Write-Host "==> Acquiring Graph access token (device code flow) ..." -ForegroundColor Cyan
    $tok = Get-TokenDeviceCode -TenantId $TenantId -ClientId $ClientId -Scope $scopeStr
} else {
    Write-Host "==> Acquiring Graph access token (interactive auth code flow) ..." -ForegroundColor Cyan
    try {
        $tok = Get-TokenInteractive -TenantId $TenantId -ClientId $ClientId -Scope $scopeStr
    } catch {
        Write-Host ("    Interactive flow failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host "    Falling back to device code flow (use -DeviceCode to skip this on next run)." -ForegroundColor Yellow
        $tok = Get-TokenDeviceCode -TenantId $TenantId -ClientId $ClientId -Scope $scopeStr
    }
}
$rawToken     = $tok.AccessToken
$expiresOnUtc = $tok.ExpiresOn

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
    "-StatusPollIntervalSeconds $StatusPollIntervalSeconds"
    "-StatusPollMaxMinutes $StatusPollMaxMinutes"
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
