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
$ExpectedVersion = '1.0.17'  # __VERSION_PLACEHOLDER__  (rewritten by Build-IntuneWinPackage.ps1)
$RegPath         = 'HKLM:\SOFTWARE\MSLABS\IntuneWipeClient'
$RegSubKey       = 'SOFTWARE\MSLABS\IntuneWipeClient'
$ProgramFiles64  = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$InstallDir      = Join-Path $ProgramFiles64 'IntuneWipeClient'
$Marker          = Join-Path $InstallDir 'Invoke-DeviceWipe.ps1'

# Read from the 64-bit hive explicitly so detection works regardless of
# whether the script is running under 32-bit or 64-bit PowerShell.
$installed = $null
try {
    $base64 = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    $k = $base64.OpenSubKey($RegSubKey)
    if ($k) { $installed = [string]$k.GetValue('Version'); $k.Close() }
    $base64.Close()
} catch { }

if ($installed -eq $ExpectedVersion -and (Test-Path $Marker)) {
    Write-Output "IntuneWipeClient $ExpectedVersion detected."
    exit 0
}

exit 0  # exit 0 with NO output => Not detected (Intune contract)

















