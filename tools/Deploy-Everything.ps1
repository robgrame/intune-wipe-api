<#
.SYNOPSIS
End-to-end deployment of the IntuneDeviceActions stack: API (Web + Proc +
Wipe + Autopilot + BitLocker function apps + Azure Automation runbooks)
AND the Blazor portal in the sibling repo `intune-wipe-portal`.

.DESCRIPTION
Single entry point that orchestrates the two existing scripts:

  1. tools\Deploy-IntuneDeviceActions.ps1   (this repo)
        - provisions/updates infra/main(-public).bicep
        - publishes & zip-deploys all 5 function apps
        - publishes runbooks
        - optional smoke test

  2. ..\intune-wipe-portal\infra\deploy.ps1
        - ensures the portal Entra app registration
        - provisions/updates the portal infra (App Service + plan +
          KV + role assignments on the existing LAW)
        - publishes & zip-deploys the Blazor app

Both child scripts are idempotent — re-run any time. Phases can be
skipped independently via -SkipApi / -SkipPortal.

Defaults target the standard dev environment:
  RG              = RG-INTUNE-DEVICEACTIONS
  Location        = italynorth
  NamePrefix      = idactions
  NameSuffix      = dev (pinned to avoid uniqueString() regeneration)
  NetworkProfile  = public (default; pass 'hardened' for VNet+PE+NAT GW)
  LAW             = idactions-law-dev

.PARAMETER PortalRepoPath
Path to the sibling `intune-wipe-portal` clone. Default:
`..\intune-wipe-portal` relative to this repo.

.EXAMPLE
# Full deploy with defaults (dev environment):
.\tools\Deploy-Everything.ps1

.EXAMPLE
# Only redeploy code (skip infra) for both API and portal:
.\tools\Deploy-Everything.ps1 -SkipInfra

.EXAMPLE
# Only API, hardened network profile:
.\tools\Deploy-Everything.ps1 -SkipPortal -NetworkProfile hardened

.EXAMPLE
# Only portal:
.\tools\Deploy-Everything.ps1 -SkipApi
#>
[CmdletBinding()]
param(
    [string] $ResourceGroup            = 'RG-INTUNE-DEVICEACTIONS',
    [string] $Location                 = 'italynorth',
    [string] $SubscriptionId,
    [string] $NamePrefix               = 'idactions',
    [AllowNull()][AllowEmptyString()]
    [ValidatePattern('^[a-z0-9]*$')]
    [string] $NameSuffix               = 'dev',
    [ValidateSet('hardened','public')]
    [string] $NetworkProfile           = 'public',
    [hashtable] $Tags                  = @{},

    # --- Portal-only ------------------------------------------------------
    [string] $PortalRepoPath,
    [string] $LogAnalyticsWorkspaceName = 'idactions-law-dev',
    [ValidateSet('B1','B2','P0v3','P1v3')]
    [string] $PortalSku                = 'B1',
    [string] $AssignUserUpn,
    [ValidateSet('Actions.Observer','Actions.Auditor')]
    [string] $AssignRole               = 'Actions.Observer',
    [switch] $RotatePortalSecret,        # if absent we -SkipAppRegistration

    # --- Skip switches ----------------------------------------------------
    [switch] $SkipApi,
    [switch] $SkipPortal,
    [switch] $SkipInfra,                # forwarded to BOTH child scripts
    [switch] $SkipPublish,              # API only
    [switch] $SkipDeploy,               # API only
    [switch] $SkipGraphConsent,         # API only
    [switch] $SkipPrereqInstall,        # API only
    [switch] $NoSmokeTest               # API only
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Write-Phase($m) {
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor Magenta
    Write-Host "  $m" -ForegroundColor Magenta
    Write-Host ("=" * 78) -ForegroundColor Magenta
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $PortalRepoPath) {
    $PortalRepoPath = (Resolve-Path (Join-Path $RepoRoot '..\intune-wipe-portal') -ErrorAction SilentlyContinue)?.Path
}

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
Write-Phase "Pre-flight"
Write-Host "  API repo    : $RepoRoot"
Write-Host "  Portal repo : $PortalRepoPath"
Write-Host "  RG          : $ResourceGroup ($Location)"
Write-Host "  Name        : $NamePrefix-<role>-$NameSuffix  (network=$NetworkProfile)"

if (-not $SkipApi) {
    $apiScript = Join-Path $RepoRoot 'tools\Deploy-IntuneDeviceActions.ps1'
    if (-not (Test-Path $apiScript)) { throw "API deploy script not found: $apiScript" }
}
if (-not $SkipPortal) {
    if (-not $PortalRepoPath -or -not (Test-Path $PortalRepoPath)) {
        throw "Portal repo not found. Pass -PortalRepoPath, expected sibling folder 'intune-wipe-portal'."
    }
    $portalScript = Join-Path $PortalRepoPath 'infra\deploy.ps1'
    if (-not (Test-Path $portalScript)) { throw "Portal deploy script not found: $portalScript" }
}

if ($SubscriptionId) {
    Write-Host "  Setting subscription: $SubscriptionId"
    az account set --subscription $SubscriptionId | Out-Null
}

# ----------------------------------------------------------------------------
# Phase 1: API stack
# ----------------------------------------------------------------------------
if (-not $SkipApi) {
    Write-Phase "Phase 1 / 2 — API stack (Web, Proc, Wipe, Autopilot, BitLocker, runbooks)"
    $apiArgs = @{
        ResourceGroup  = $ResourceGroup
        Location       = $Location
        NamePrefix     = $NamePrefix
        NetworkProfile = $NetworkProfile
    }
    if ($PSBoundParameters.ContainsKey('NameSuffix'))     { $apiArgs.NameSuffix     = $NameSuffix }
    if ($PSBoundParameters.ContainsKey('SubscriptionId')) { $apiArgs.SubscriptionId = $SubscriptionId }
    if ($Tags.Count -gt 0)                                { $apiArgs.Tags           = $Tags }
    foreach ($sw in 'SkipPrereqInstall','SkipPublish','SkipInfra','SkipDeploy','SkipGraphConsent','NoSmokeTest') {
        if ($PSBoundParameters[$sw]) { $apiArgs[$sw] = $true }
    }
    & (Join-Path $RepoRoot 'tools\Deploy-IntuneDeviceActions.ps1') @apiArgs
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "API deploy failed with exit code $LASTEXITCODE" }
} else {
    Write-Phase "Phase 1 / 2 — API stack [SKIPPED]"
}

# ----------------------------------------------------------------------------
# Phase 2: portal
# ----------------------------------------------------------------------------
if (-not $SkipPortal) {
    Write-Phase "Phase 2 / 2 — Portal (Blazor Server idactions-portal)"
    $portalArgs = @{
        ResourceGroup              = $ResourceGroup
        Location                   = $Location
        NamePrefix                 = $NamePrefix
        AppServicePlanSku          = $PortalSku
        LogAnalyticsWorkspaceName  = $LogAnalyticsWorkspaceName
    }
    if ($PSBoundParameters.ContainsKey('NameSuffix')) { $portalArgs.NameSuffix = $NameSuffix }
    if ($AssignUserUpn)        { $portalArgs.AssignUserUpn = $AssignUserUpn; $portalArgs.AssignRole = $AssignRole }
    if (-not $RotatePortalSecret) { $portalArgs.SkipAppRegistration = $true }

    & (Join-Path $PortalRepoPath 'infra\deploy.ps1') @portalArgs
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Portal deploy failed with exit code $LASTEXITCODE" }
} else {
    Write-Phase "Phase 2 / 2 — Portal [SKIPPED]"
}

Write-Phase "Deployment complete"
Write-Host "  Portal : https://$NamePrefix-portal.azurewebsites.net/" -ForegroundColor Green
Write-Host "  Cruscotto : https://$NamePrefix-portal.azurewebsites.net/cruscotto" -ForegroundColor Green
