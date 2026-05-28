#requires -Version 5.1
<#
.SYNOPSIS
    Intune Win32 detection script for IntuneWipeClient.

.DESCRIPTION
    Returns exit code 0 + non-empty STDOUT when the expected version is
    installed (Intune interprets this as "Detected"). Any other combination
    is interpreted as "Not detected". Update $ExpectedVersion in lockstep
    with version.txt at packaging time (the Build script rewrites this for
    you).
#>

$ErrorActionPreference = 'SilentlyContinue'
$ExpectedVersion = '1.0.2'  # __VERSION_PLACEHOLDER__  (rewritten by Build-IntuneWinPackage.ps1)
$RegPath         = 'HKLM:\SOFTWARE\Contoso\IntuneWipeClient'
$InstallDir      = Join-Path $env:ProgramFiles 'IntuneWipeClient'
$Marker          = Join-Path $InstallDir 'Invoke-DeviceWipe.ps1'

$installed = (Get-ItemProperty -Path $RegPath -Name Version -ErrorAction SilentlyContinue).Version

if ($installed -eq $ExpectedVersion -and (Test-Path $Marker)) {
    Write-Output "IntuneWipeClient $ExpectedVersion detected."
    exit 0
}

exit 0  # exit 0 with NO output => Not detected (Intune contract)



