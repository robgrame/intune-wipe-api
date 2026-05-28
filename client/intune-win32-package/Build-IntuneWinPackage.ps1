#requires -Version 5.1
<#
.SYNOPSIS
    Builds the IntuneWipeClient.intunewin package.

.DESCRIPTION
    1. Copies the canonical wipe scripts from ..\Invoke-DeviceWipe.ps1 and
       ..\WipeConfirmationDialog.ps1 into .\source (single source of truth).
    2. Rewrites the $ExpectedVersion placeholder inside Detect.ps1 from
       source\version.txt so detection stays in lockstep with the payload.
    3. Downloads Microsoft's IntuneWinAppUtil.exe to .\tools if missing
       (https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool).
    4. Produces .\dist\IntuneWipeClient.intunewin.

.NOTES
    Idempotent. Safe to re-run.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$Root      = $PSScriptRoot
$SourceDir = Join-Path $Root 'source'
$ToolsDir  = Join-Path $Root 'tools'
$DistDir   = Join-Path $Root 'dist'
$ClientDir = Resolve-Path (Join-Path $Root '..')
$Util      = Join-Path $ToolsDir 'IntuneWinAppUtil.exe'

New-Item -ItemType Directory -Force -Path $SourceDir, $ToolsDir, $DistDir | Out-Null

Write-Host "==> Syncing canonical scripts into .\source ..." -ForegroundColor Cyan
foreach ($f in @('Invoke-DeviceWipe.ps1','WipeConfirmationDialog.ps1')) {
    $src = Join-Path $ClientDir $f
    if (-not (Test-Path $src)) { throw "Missing source script: $src" }
    Copy-Item -LiteralPath $src -Destination (Join-Path $SourceDir $f) -Force
}

# --- Stamp the detection script with the current version --------------------
$version = (Get-Content (Join-Path $SourceDir 'version.txt') -Raw).Trim()
if (-not $version) { throw "source\version.txt is empty." }
$detectPath = Join-Path $SourceDir 'Detect.ps1'
$detect = Get-Content -LiteralPath $detectPath -Raw
$detect = [regex]::Replace($detect,
    "(?m)^\s*\`$ExpectedVersion\s*=\s*'[^']*'\s*#\s*__VERSION_PLACEHOLDER__.*$",
    "`$ExpectedVersion = '$version'  # __VERSION_PLACEHOLDER__  (rewritten by Build-IntuneWinPackage.ps1)")
Set-Content -LiteralPath $detectPath -Value $detect -Encoding utf8
Write-Host "    Detect.ps1 stamped with version $version"

# --- Acquire IntuneWinAppUtil.exe if needed --------------------------------
if (-not (Test-Path $Util)) {
    $urls = @(
        'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe',
        'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/main/IntuneWinAppUtil.exe'
    )
    foreach ($u in $urls) {
        Write-Host "==> Downloading IntuneWinAppUtil.exe from $u ..." -ForegroundColor Cyan
        try {
            Invoke-WebRequest -Uri $u -OutFile $Util -UseBasicParsing -ErrorAction Stop
            break
        } catch {
            Write-Warning "    Failed: $($_.Exception.Message)"
            Remove-Item $Util -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-Path $Util)) { throw "Could not download IntuneWinAppUtil.exe." }
}

# --- Build .intunewin -------------------------------------------------------
$outName = 'IntuneWipeClient.intunewin'
$outPath = Join-Path $DistDir $outName
if (Test-Path $outPath) { Remove-Item $outPath -Force }

# IntuneWinAppUtil renames its output after the setup file's basename, so the
# resulting filename will be 'Install.intunewin'. Rename to canonical name.
Write-Host "==> Running IntuneWinAppUtil ..." -ForegroundColor Cyan
$utilArgs = @('-c', $SourceDir, '-s', 'Install.ps1', '-o', $DistDir, '-q')
& $Util @utilArgs
if ($LASTEXITCODE -ne 0) { throw "IntuneWinAppUtil failed with exit code $LASTEXITCODE." }

$generated = Join-Path $DistDir 'Install.intunewin'
if (-not (Test-Path $generated)) { throw "Expected output '$generated' was not produced." }
Move-Item -LiteralPath $generated -Destination $outPath -Force

Write-Host ""
Write-Host ("Done. Package: {0}" -f $outPath) -ForegroundColor Green
Write-Host ("Version     : {0}" -f $version)
