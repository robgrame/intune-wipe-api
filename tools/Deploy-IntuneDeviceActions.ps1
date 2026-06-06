#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end deploy of IntuneDeviceActions (Web + Proc + Wipe + Autopilot + BitLocker Function Apps).

.DESCRIPTION
    Idempotent helper that:
      1. Verifies / auto-installs prerequisites: .NET 10 SDK, Azure CLI, Bicep.
      2. Logs in to Azure (interactive) and selects subscription.
      3. Prompts only for parameters not supplied on the command line.
      4. Builds + publishes Web/Proc/Wipe/Autopilot/BitLocker and creates 5 deployment zips.
      5. Deploys infra via Bicep (creates the RG if missing).
      6. Restarts the 3 Function Apps (RBAC propagation) and deploys the zips.
      7. Runs a smoke test and prints remaining manual steps
         (Graph admin consent, optional AppConfig seed).

    Safe to re-run. Each phase can be skipped with -Skip* switches.

.PARAMETER ResourceGroup
    Target resource group (created if missing).

.PARAMETER Location
    Azure region (default westeurope).

.PARAMETER SubscriptionId
    Subscription to deploy into. If omitted, current az context is used.

.PARAMETER NamePrefix
    Used only to (a) build the default RG name when ResourceGroup is omitted,
    and (b) look up the 3 deployed Function Apps by prefix. The actual naming
    is controlled by main.parameters.json (namePrefix parameter).

.PARAMETER ParametersFile
    Bicep parameters file. Default: infra\main.parameters.json (hardened)
    or infra\main-public.parameters.json when -NetworkProfile public.

.PARAMETER NetworkProfile
    Selects the Bicep variant to deploy:
      hardened (default) — infra\main.bicep with VNet, NAT Gateway, Private
                            Endpoints, Private DNS zones, NSGs.
      public             — infra\main-public.bicep without any network
                            isolation (storage / Service Bus reachable on
                            the public Internet, still RBAC-protected). Use
                            for low-cost / quick-start deployments.

.PARAMETER NameSuffix
    Overrides the disambiguation suffix appended to globally-unique resource
    names (Storage Account, App Configuration, Service Bus namespace, Function
    App FQDN, Key Vault). When not specified the bicep default applies:
    uniqueString(resourceGroup().id) — a 13-char deterministic hash per RG.

    Pass an empty string '' to omit the suffix entirely (cleanest names like
    'idactions-web', 'idactionsstw'). Pass a short label ('prod', 'lab') to
    customize. WARNING: empty or generic suffixes risk collision with other
    tenants on globally-unique names — only safe if your namePrefix is itself
    sufficiently unique.

.PARAMETER Tags
    Hashtable of tags applied to every taggable Azure resource (Storage,
    Function App, Service Bus, App Configuration, Key Vault, Managed Identity,
    Log Analytics, App Insights, VNet, NSG, Private Endpoint, Private DNS
    Zone, Automation Account). Sub-resources (queues, containers, role
    assignments, DNS A records, Automation runbooks/variables) are skipped
    because the platform doesn't support tags on them.

    Example:
      -Tags @{ env = 'prod'; owner = 'ITOps'; costCenter = 'CC123' }

.PARAMETER SkipPrereqInstall
    Don't try to install missing prereqs - error out instead.

.PARAMETER SkipPublish
    Skip dotnet publish + zip step (reuse existing publish\*.zip).

.PARAMETER SkipInfra
    Skip the Bicep deploy step.

.PARAMETER SkipDeploy
    Skip the function-zip deploy step.

.PARAMETER SkipGraphConsent
    Skip the automatic Microsoft Graph app-role assignment step.
    Requires the caller to be Global Admin / Privileged Role Admin /
    Cloud Application Admin in the tenant.

.PARAMETER NoSmokeTest
    Skip the final HTTP smoke test.

.EXAMPLE
    .\tools\Deploy-IntuneDeviceActions.ps1

.EXAMPLE
    .\tools\Deploy-IntuneDeviceActions.ps1 -ResourceGroup rg-idactions-dev -Location westeurope -SubscriptionId xxxx

.EXAMPLE
    # Rebuild + redeploy only the function code, leaving the infra alone:
    .\tools\Deploy-IntuneDeviceActions.ps1 -ResourceGroup rg-idactions-dev -SkipInfra
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup,
    [string]$Location        = 'westeurope',
    [string]$SubscriptionId,
    [string]$NamePrefix      = 'idactions',
    # Override the disambiguation suffix on globally-unique resource names.
    # $null (default) -> let bicep use uniqueString(resourceGroup().id).
    # ''               -> omit the suffix entirely (names like idactions-web).
    # 'prod' / 'lab'   -> custom short suffix.
    # WARNING: empty or short suffixes risk collision on globally-unique
    # names (Storage Account, App Configuration, Service Bus, FQDN, KV).
    [AllowNull()][AllowEmptyString()]
    [string]$NameSuffix      = $null,
    # Hashtable of tags applied to every taggable Azure resource.
    # Example: -Tags @{ env='prod'; owner='ITOps'; costCenter='CC123' }
    # Forwarded to bicep as the 'tags' object parameter when non-empty.
    [hashtable]$Tags         = @{},
    [string]$ParametersFile,
    [ValidateSet('hardened','public')]
    [string]$NetworkProfile = 'hardened',
    [switch]$SkipPrereqInstall,
    [switch]$SkipPublish,
    [switch]$SkipInfra,
    [switch]$SkipDeploy,
    [switch]$SkipGraphConsent,
    [switch]$NoSmokeTest
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# Capture NameSuffix override decision at script scope (function scopes
# don't see the script-level $PSBoundParameters).
$script:NameSuffixOverridden = $PSBoundParameters.ContainsKey('NameSuffix')

# -- Paths -------------------------------------------------------------------
$RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$InfraDir   = Join-Path $RepoRoot 'infra'
if ($NetworkProfile -eq 'public') {
    $BicepFile  = Join-Path $InfraDir 'main-public.bicep'
    $DefaultPF  = Join-Path $InfraDir 'main-public.parameters.json'
} else {
    $BicepFile  = Join-Path $InfraDir 'main.bicep'
    $DefaultPF  = Join-Path $InfraDir 'main.parameters.json'
}
$PublishDir = Join-Path $RepoRoot 'publish'

if (-not $ParametersFile) { $ParametersFile = $DefaultPF }

# -- Pretty printers --------------------------------------------------------
function Write-Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    [OK]   $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "    [ERR]  $m" -ForegroundColor Red }
function Test-Cmd($n)   { [bool](Get-Command $n -ErrorAction SilentlyContinue) }

# -- Prereqs ----------------------------------------------------------------
function Test-Winget { Test-Cmd winget }

function Install-DotNet10 {
    if (Test-Winget) {
        Write-Host "    installing .NET 10 SDK via winget..."
        & winget install -e --id Microsoft.DotNet.SDK.10 `
            --accept-package-agreements --accept-source-agreements --silent | Out-Null
        # Reload PATH from registry
        $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path','User')
    }
    else {
        Write-Host "    downloading dotnet-install.ps1..."
        $script = Join-Path $env:TEMP 'dotnet-install.ps1'
        Invoke-WebRequest 'https://dot.net/v1/dotnet-install.ps1' -OutFile $script -UseBasicParsing
        $installDir = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'
        & $script -Channel 10.0 -InstallDir $installDir
        if (-not ($env:Path -split ';' | Where-Object { $_ -eq $installDir })) {
            $env:Path = "$installDir;$env:Path"
        }
    }
}

function Confirm-DotNet10 {
    Write-Step '.NET 10 SDK'
    if (Test-Cmd dotnet) {
        $sdks = & dotnet --list-sdks 2>$null
        $v10  = $sdks | Where-Object { $_ -match '^10\.' } | Select-Object -First 1
        if ($v10) { Write-Ok ".NET SDK $($v10 -replace ' .*','') present"; return }
    }
    if ($SkipPrereqInstall) { throw '.NET 10 SDK missing; re-run without -SkipPrereqInstall.' }
    Install-DotNet10
    $sdks = & dotnet --list-sdks 2>$null
    if (-not ($sdks | Where-Object { $_ -match '^10\.' })) {
        throw '.NET 10 install did not complete - restart shell and retry.'
    }
    Write-Ok '.NET 10 SDK installed'
}

function Install-AzCli {
    if (Test-Winget) {
        Write-Host "    installing Azure CLI via winget..."
        & winget install -e --id Microsoft.AzureCLI `
            --accept-package-agreements --accept-source-agreements --silent | Out-Null
    }
    else {
        Write-Host "    downloading Azure CLI MSI (requires admin)..."
        $msi = Join-Path $env:TEMP 'AzureCLI.msi'
        Invoke-WebRequest 'https://aka.ms/installazurecliwindows' -OutFile $msi -UseBasicParsing
        Start-Process msiexec.exe -Wait -ArgumentList "/I `"$msi`" /quiet"
    }
    $azBin = Join-Path ${env:ProgramFiles} 'Microsoft SDKs\Azure\CLI2\wbin'
    if ((Test-Path $azBin) -and ($env:Path -notlike "*$azBin*")) { $env:Path = "$azBin;$env:Path" }
}

function Confirm-AzCli {
    Write-Step 'Azure CLI'
    if (Test-Cmd az) {
        $j = & az version --only-show-errors 2>$null | ConvertFrom-Json
        if ($j.'azure-cli') { Write-Ok "Azure CLI $($j.'azure-cli') present"; return }
    }
    if ($SkipPrereqInstall) { throw 'Azure CLI missing; re-run without -SkipPrereqInstall.' }
    Install-AzCli
    if (-not (Test-Cmd az)) { throw 'Azure CLI install failed - restart shell and retry.' }
    Write-Ok 'Azure CLI installed'
}

function Confirm-Bicep {
    Write-Step 'Bicep'
    $v = & az bicep version --only-show-errors 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Ok ($v -join ' '); return }
    if ($SkipPrereqInstall) { throw 'Bicep missing; re-run without -SkipPrereqInstall.' }
    & az bicep install --only-show-errors 2>&1 | Out-Null
    if ((& az bicep version --only-show-errors 2>&1) -and $LASTEXITCODE -eq 0) { Write-Ok 'Bicep installed' }
    else { throw 'Bicep install failed.' }
}

# -- Azure auth -------------------------------------------------------------
function Confirm-AzLogin {
    Write-Step 'Azure authentication'
    $acc = & az account show --only-show-errors 2>$null | ConvertFrom-Json
    if (-not $acc) {
        Write-Host "    no active session - launching az login..."
        & az login --only-show-errors | Out-Null
        $acc = & az account show --only-show-errors | ConvertFrom-Json
    }
    if ($script:SubscriptionId -and $acc.id -ne $script:SubscriptionId) {
        & az account set -s $script:SubscriptionId --only-show-errors
        $acc = & az account show --only-show-errors | ConvertFrom-Json
    }
    Write-Ok "Subscription: $($acc.name)  ($($acc.id))"
    Write-Ok "Tenant:       $($acc.tenantId)"
    Write-Ok "Signed-in as: $($acc.user.name)"
}

# -- Resource providers ----------------------------------------------------
# Tutti i namespace usati (esplicitamente nei Bicep o implicitamente da
# servizi derivati come App Insights → AlertsManagement). Vanno registrati
# UNA TANTUM a livello subscription; se non sono "Registered" il deploy
# Bicep fallisce con messaggi tipo:
#   "The subscription is not registered to use namespace 'Microsoft.X'"
$Script:RequiredResourceProviders = @(
    'Microsoft.Resources',
    'Microsoft.Authorization',
    'Microsoft.ManagedIdentity',
    'Microsoft.Storage',
    'Microsoft.Network',
    'Microsoft.Web',              # Function Apps + serverfarms (incl. Flex Consumption FC1)
    'Microsoft.App',              # Richiesto da Flex Consumption per VNet integration
    'Microsoft.ServiceBus',
    'Microsoft.OperationalInsights',
    'Microsoft.Insights',         # Application Insights (component v2 + classic)
    'Microsoft.AlertsManagement', # Smart Detector alert rules creati implicitamente da App Insights
    'Microsoft.AppConfiguration',
    'Microsoft.Automation'        # Runbook variant (enableRunbookVariant=true)
)

function Register-ResourceProviders {
    Write-Step "Registering required Azure resource providers ($($Script:RequiredResourceProviders.Count) namespaces)"
    $pending = @()
    foreach ($ns in $Script:RequiredResourceProviders) {
        $state = (& az provider show --namespace $ns --query registrationState -o tsv 2>$null)
        if ($state -eq 'Registered') {
            Write-Ok "$ns  (already Registered)"
        } else {
            Write-Host "    -> registering $ns (current state: $state)" -ForegroundColor Gray
            & az provider register --namespace $ns --only-show-errors | Out-Null
            $pending += $ns
        }
    }
    if ($pending.Count -gt 0) {
        Write-Host "    waiting for $($pending.Count) provider(s) to reach 'Registered' (up to 5 min)..." -ForegroundColor Gray
        $deadline = (Get-Date).AddMinutes(5)
        while ((Get-Date) -lt $deadline -and $pending.Count -gt 0) {
            Start-Sleep -Seconds 10
            $pending = @($pending | Where-Object {
                (& az provider show --namespace $_ --query registrationState -o tsv 2>$null) -ne 'Registered'
            })
        }
        if ($pending.Count -gt 0) {
            throw "Timed out waiting for resource providers: $($pending -join ', '). Re-run after they finish registering."
        }
        Write-Ok 'All required providers Registered.'
    }
}


# -- Interactive inputs -----------------------------------------------------
function Resolve-Inputs {
    Write-Step 'Resolving deployment parameters'
    if (-not $script:ResourceGroup) {
        $def  = "rg-$NamePrefix-dev"
        $ans  = Read-Host "Resource group name [$def]"
        $script:ResourceGroup = if ($ans) { $ans } else { $def }
    }
    if (-not $script:Location -or $script:Location -eq 'westeurope') {
        $ans = Read-Host "Location [$($script:Location)]"
        if ($ans) { $script:Location = $ans }
    }
    if (-not (Test-Path $ParametersFile)) {
        throw "Parameters file not found: $ParametersFile"
    }
    Write-Ok "Resource group:  $ResourceGroup"
    Write-Ok "Location:        $Location"
    Write-Ok "Bicep file:      $BicepFile"
    Write-Ok "Parameters file: $ParametersFile"
}

# -- Build + publish --------------------------------------------------------
function Invoke-Publish {
    if ($SkipPublish) { Write-Warn2 'Skipping publish (-SkipPublish).'; return }
    Write-Step 'Publishing 5 projects (Release) + zipping'
    if (Test-Path $PublishDir) { Remove-Item $PublishDir -Recurse -Force }
    New-Item -ItemType Directory -Path $PublishDir | Out-Null
    $projects = @(
        @{ Name='web';  Csproj='src\Web\IntuneDeviceActions.Web.csproj'   }
        @{ Name='proc'; Csproj='src\Proc\IntuneDeviceActions.Proc.csproj' }
        @{ Name='wipe'; Csproj='src\Wipe\IntuneDeviceActions.Wipe.csproj' }
        @{ Name='autopilot'; Csproj='src\Autopilot\IntuneDeviceActions.Autopilot.csproj' }
        @{ Name='bitlocker'; Csproj='src\BitLocker\IntuneDeviceActions.BitLocker.csproj' }
    )
    foreach ($p in $projects) {
        $csproj = Join-Path $RepoRoot $p.Csproj
        $outDir = Join-Path $PublishDir $p.Name
        Write-Host "    -> dotnet publish $($p.Name)"
        & dotnet publish $csproj -c Release -o $outDir --nologo -v minimal | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Publish failed for $($p.Csproj)" }
        $zip = Join-Path $PublishDir "$($p.Name).zip"
        if (Test-Path $zip) { Remove-Item $zip -Force }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Add-Type -AssemblyName System.IO.Compression
        # ZipFile.CreateFromDirectory on .NET Framework (Windows PowerShell 5.1)
        # writes entries with backslash separators, which Kudu / Flex Consumption
        # rejects ("Cannot find required .azurefunctions directory at root level").
        # Build the archive manually, normalizing every entry name to forward slashes.
        # writes entries with backslash separators, which Kudu / Flex Consumption
        # rejects ("Cannot find required .azurefunctions directory at root level").
        # Build the archive manually, normalizing every entry name to forward slashes.
        $fs = [IO.File]::Open($zip, [IO.FileMode]::Create)
        try {
            $archive = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
            try {
                $rootLen = (Resolve-Path $outDir).Path.TrimEnd('\').Length + 1
                Get-ChildItem -LiteralPath $outDir -Recurse -File -Force | ForEach-Object {
                    $entryName = $_.FullName.Substring($rootLen).Replace('\','/')
                    $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
                    $es = $entry.Open()
                    try {
                        $src = [IO.File]::OpenRead($_.FullName)
                        try { $src.CopyTo($es) } finally { $src.Dispose() }
                    } finally { $es.Dispose() }
                }
            } finally { $archive.Dispose() }
        } finally { $fs.Dispose() }
        Write-Ok "$($p.Name).zip ($([math]::Round((Get-Item $zip).Length / 1MB, 2)) MB)"
    }
}

# -- Infra deploy -----------------------------------------------------------
function Invoke-InfraDeploy {
    if ($SkipInfra) { Write-Warn2 'Skipping infra deploy (-SkipInfra).'; return }
    Write-Step "Bicep deploy -> $ResourceGroup ($Location)"
    & az group create -n $ResourceGroup -l $Location --only-show-errors -o none
    $deployName = "$NamePrefix-deploy-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
    Write-Host "    deployment name: $deployName"
    $azArgs = @(
        'deployment','group','create',
        '-g', $ResourceGroup, '-n', $deployName,
        '-f', $BicepFile, '-p', "@$ParametersFile",
        '--query', 'properties.provisioningState', '-o', 'tsv',
        '--only-show-errors'
    )
    # Bound (incl. empty string) -> forward to bicep as named param override.
    if ($script:NameSuffixOverridden) {
        Write-Host "    nameSuffix override: '$NameSuffix'"
        $azArgs += @('-p', "nameSuffix=$NameSuffix")
    }
    if ($Tags -and $Tags.Count -gt 0) {
        # Forward as JSON object literal: -p tags={"env":"prod","owner":"ITOps"}
        $tagsJson = $Tags | ConvertTo-Json -Compress
        Write-Host "    tags override: $tagsJson"
        $azArgs += @('-p', "tags=$tagsJson")
    }
    $state = & az @azArgs
    if ($LASTEXITCODE -ne 0 -or $state -ne 'Succeeded') {
        throw "Bicep deployment failed (state: $state). Run: az deployment group show -g $ResourceGroup -n $deployName"
    }
    Write-Ok "Infra deployed (state: $state)"
}

# -- Function-app lookup ---------------------------------------------------
function Get-FunctionAppByRole($role) {
    # Match both '<prefix>-<role>' (no suffix) and '<prefix>-<role>-<anything>' (suffix).
    # Using `starts_with` + an explicit '==' fallback covers both shapes.
    $needleDash = "$NamePrefix-$role-"
    $needleBare = "$NamePrefix-$role"
    $name = & az functionapp list -g $ResourceGroup `
        --query "[?starts_with(name, '$needleDash') || name == '$needleBare'].name | [0]" `
        -o tsv --only-show-errors
    if (-not $name) { return $null }
    return $name.Trim()
}

# -- Zip deploy -------------------------------------------------------------
function Invoke-ZipDeploy {
    if ($SkipDeploy) { Write-Warn2 'Skipping zip deploy (-SkipDeploy).'; return }
    $apps = @{}
    foreach ($role in 'web','proc','wipe','autopilot','bitlocker') {
        $a = Get-FunctionAppByRole $role
        if (-not $a) { throw "No Function App found with prefix '$NamePrefix-$role-' in $ResourceGroup." }
        $apps[$role] = $a
    }
    Write-Step 'Restarting Function Apps (RBAC propagation buffer)'
    foreach ($role in 'web','proc','wipe','autopilot','bitlocker') {
        & az functionapp restart -g $ResourceGroup -n $apps[$role] --only-show-errors -o none
        Write-Ok "restarted $($apps[$role])"
    }
    Write-Host "    waiting 60s for restart + RBAC settle..."
    Start-Sleep 60

    Write-Step 'Deploying function zips'
    foreach ($role in 'web','proc','wipe','autopilot','bitlocker') {
        $app = $apps[$role]
        $zip = Join-Path $PublishDir "$role.zip"
        if (-not (Test-Path $zip)) { throw "Missing zip: $zip (did you skip -SkipPublish?)" }
        Write-Host "    -> $app  ($role.zip)"
        & az functionapp deployment source config-zip `
            -g $ResourceGroup -n $app --src $zip `
            --only-show-errors -o none
        if ($LASTEXITCODE -ne 0) { throw "Zip deploy failed for $app" }
        Write-Ok "$app  deployed"
    }
}

# -- Smoke test ------------------------------------------------------------
function Invoke-SmokeTest {
    if ($NoSmokeTest) { return }
    Write-Step 'Smoke test'
    $webApp  = Get-FunctionAppByRole 'web'
    $webHost = (& az functionapp show -g $ResourceGroup -n $webApp `
        --query defaultHostName -o tsv --only-show-errors).Trim()
    $url = "https://$webHost/api/actions"
    Write-Host "    POST $url  (no client cert - expecting 401/403)"
    try {
        Invoke-WebRequest -Uri $url -Method POST -Body '{}' `
            -ContentType 'application/json' -UseBasicParsing -TimeoutSec 30 | Out-Null
        Write-Warn2 'Endpoint returned 2xx without a client cert - mTLS may NOT be enforced.'
    } catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($code -in 401, 403) { Write-Ok "mTLS enforced (HTTP $code without client cert)" }
        else { Write-Warn2 "Unexpected response: HTTP $code - verify manually." }
    }
    foreach ($role in 'proc','wipe','autopilot','bitlocker') {
        $app = Get-FunctionAppByRole $role
        try {
            $r = Invoke-WebRequest "https://$app.azurewebsites.net/" `
                -UseBasicParsing -TimeoutSec 30
            Write-Ok "$app warmup HTTP $($r.StatusCode)"
        } catch {
            $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            Write-Warn2 "$app warmup HTTP $code - may still be cold-starting."
        }
    }
}

# -- Runbook content publish (optional, when enableRunbookVariant=true) ------
function Invoke-RunbookPublish {
    $aaName = (& az automation account list -g $ResourceGroup `
        --query "[?starts_with(name, '$NamePrefix-aa-') || name == '$NamePrefix-aa'].name | [0]" `
        -o tsv --only-show-errors)
    if (-not $aaName) {
        Write-Warn2 "No Automation Account in $ResourceGroup; skipping runbook publish (enableRunbookVariant=false)."
        return
    }
    Write-Step "Publishing runbook content -> $aaName"
    $runbookDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'runbooks'
    if (-not (Test-Path $runbookDir)) {
        Write-Warn2 "runbooks/ folder not found; skipping."
        return
    }
    # Load the shared toolkit. Each runbook contains a `# >>> RBC-LIB-INSERTION-POINT <<<`
    # marker placed immediately after its `param()` block; we substitute the
    # marker with the full toolkit content so the script uploaded to Azure
    # Automation is self-contained (AA has no module-import mechanism for
    # runbook-local libraries).
    $libPath = Join-Path $runbookDir '_lib\RunbookCore.ps1'
    if (-not (Test-Path $libPath)) {
        Write-Err "Shared toolkit not found: $libPath"; return
    }
    $libContent = Get-Content -LiteralPath $libPath -Raw
    $marker     = '# >>> RBC-LIB-INSERTION-POINT <<<'
    $tmpDir     = Join-Path $env:TEMP "idactions-runbook-merge-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    # Map: runbook name in AA  ->  source script path
    $map = @(
        @{ Name = 'Invoke-DeviceWipe';          File = 'Invoke-DeviceWipe.runbook.ps1' }
        @{ Name = 'Invoke-AutopilotRegister';   File = 'Invoke-AutopilotRegister.runbook.ps1' }
        @{ Name = 'Invoke-RotateBitLockerKey';  File = 'Invoke-RotateBitLockerKey.runbook.ps1' }
    )
    try {
        foreach ($m in $map) {
            $src = Join-Path $runbookDir $m.File
            if (-not (Test-Path $src)) { Write-Warn2 "Source missing: $($m.File); skipping $($m.Name)."; continue }
            $body = Get-Content -LiteralPath $src -Raw
            if ($body -notmatch [regex]::Escape($marker)) {
                Write-Err "Runbook $($m.File) is missing the lib insertion marker; skipping."
                continue
            }
            $merged = $body.Replace($marker, $libContent)
            $mergedPath = Join-Path $tmpDir ($m.File)
            Set-Content -LiteralPath $mergedPath -Value $merged -Encoding UTF8
            Write-Host "    -> $($m.Name)  (merged $($m.File) + _lib/RunbookCore.ps1 = $($merged.Length) chars)" -ForegroundColor Gray
            $up = & az automation runbook replace-content -g $ResourceGroup `
                --automation-account-name $aaName --name $m.Name `
                --content "@$mergedPath" --only-show-errors 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Err "replace-content failed for $($m.Name): $up"; continue }
            $pub = & az automation runbook publish -g $ResourceGroup `
                --automation-account-name $aaName --name $m.Name --only-show-errors 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Err "publish failed for $($m.Name): $pub"; continue }
            Write-Ok "$($m.Name) published"
        }
    }
    finally {
        if (Test-Path $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# -- Graph admin consent ---------------------------------------------------
function Invoke-GraphConsent {
    Write-Step "Granting Microsoft Graph app roles to UAMIs"
    $script = Join-Path $PSScriptRoot 'Grant-GraphPermissions.ps1'
    if (-not (Test-Path $script)) {
        Write-Warn2 "Grant-GraphPermissions.ps1 not found; skipping."
        return
    }
    & $script -ResourceGroup $ResourceGroup -NamePrefix $NamePrefix
    if ($LASTEXITCODE -ne 0) {
        Write-Warn2 "Graph consent step reported failures (exit $LASTEXITCODE). Review output above."
    }
}

# -- Post-deploy reminders -------------------------------------------------
function Show-PostDeployNotes {
    $appcfg = & az appconfig list -g $ResourceGroup `
        --query "[?starts_with(name, '$NamePrefix-appcfg')].name | [0]" `
        -o tsv --only-show-errors
    Write-Host ''
    Write-Host '============ Manual post-deploy actions ============' -ForegroundColor Magenta
    Write-Host ''
    Write-Host '1) Microsoft Graph app roles for the UAMIs:' -ForegroundColor White
    Write-Host '     Handled automatically by Grant-GraphPermissions.ps1 unless -SkipGraphConsent was used.' -ForegroundColor Gray
    Write-Host '     If skipped, run:  .\tools\Grant-GraphPermissions.ps1 -ResourceGroup ' $ResourceGroup -ForegroundColor Gray
    Write-Host ''
    if ($appcfg) {
        Write-Host "2) (optional) Seed App Configuration ($appcfg) overrides:" -ForegroundColor White
        Write-Host "     az appconfig kv set --auth-mode login -n $appcfg --key Sentinel --value (Get-Date -f s)"
    }
    Write-Host ''
    Write-Host '3) Verify the client certificate / CA chain in main.parameters.json is still valid.' -ForegroundColor White
    Write-Host '   (clientCertCaChainBase64, clientCertThumbprintToDeviceMap)'
    Write-Host ''
    Write-Host '4) End-to-end test:' -ForegroundColor White
    $webApp  = Get-FunctionAppByRole 'web'
    if ($webApp) {
        $webHost = (& az functionapp show -g $ResourceGroup -n $webApp `
            --query defaultHostName -o tsv --only-show-errors).Trim()
        Write-Host "     client\Invoke-DeviceWipe.ps1 -ApiUrl https://$webHost/api/actions ..." -ForegroundColor Gray
    }
    Write-Host ''
    Write-Host '====================================================' -ForegroundColor Magenta
}

# -- Main ------------------------------------------------------------------
try {
    Write-Host ''
    Write-Host '+----------------------------------------------+' -ForegroundColor White
    Write-Host '|  IntuneDeviceActions  -  end-to-end deploy   |' -ForegroundColor White
    Write-Host '+----------------------------------------------+' -ForegroundColor White

    if ($SkipPrereqInstall) {
        Write-Warn2 '-SkipPrereqInstall set; assuming dotnet/az/bicep are present.'
    } else {
        Confirm-DotNet10
        Confirm-AzCli
        Confirm-Bicep
    }
    Confirm-AzLogin
    Register-ResourceProviders
    Resolve-Inputs
    Invoke-Publish
    Invoke-InfraDeploy
    Invoke-ZipDeploy
    Invoke-RunbookPublish
    if ($SkipGraphConsent) {
        Write-Warn2 'Skipping Graph consent (-SkipGraphConsent).'
    } else {
        Invoke-GraphConsent
    }
    Invoke-SmokeTest
    Show-PostDeployNotes

    Write-Host ''
    Write-Host '*  Deploy completed.' -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    exit 1
}
