#requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls the Intune Wipe self-service client.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $ShortcutName = 'Migrazione a MODERN',
    # Legacy shortcut names removed during uninstall (rename history).
    [Parameter(Mandatory = $false)] [string[]] $LegacyShortcutNames = @(
        'Reset aziendale del dispositivo'
    )
)

$ErrorActionPreference = 'Continue'

$ProgramFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$InstallDir = Join-Path $ProgramFiles64 'IntuneWipeClient'
$RegPath    = 'HKLM:\SOFTWARE\MSLABS\IntuneWipeClient'
$RegSubKey  = 'SOFTWARE\MSLABS\IntuneWipeClient'
$LogDir     = Join-Path $env:ProgramData  'IntuneWipeClient\Logs'

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("Uninstall_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile -Force | Out-Null

try {
    # --- Scheduled task -----------------------------------------------------
    & schtasks.exe /Delete /TN '\IntuneWipeClient\InvokeWipe'   /F 2>$null | Out-Null
    & schtasks.exe /Delete /TN '\IntuneWipeClient\StatusPoller' /F 2>$null | Out-Null
    # Also remove the (now-empty) folder.
    try {
        $svc = New-Object -ComObject 'Schedule.Service'; $svc.Connect()
        $root = $svc.GetFolder('\')
        $root.DeleteFolder('IntuneWipeClient', 0)
    } catch { }

    $allUsersStart = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $publicDesktop = Join-Path $env:PUBLIC      'Desktop'
    $allShortcutNames = @($ShortcutName) + ($LegacyShortcutNames | Where-Object { $_ -and $_ -ne $ShortcutName })
    foreach ($folder in @($allUsersStart, $publicDesktop)) {
        foreach ($name in $allShortcutNames) {
            $lnkPath = Join-Path $folder ("{0}.lnk" -f $name)
            if (Test-Path -LiteralPath $lnkPath) {
                Remove-Item -LiteralPath $lnkPath -Force
                Write-Host "Removed shortcut: $lnkPath"
            }
        }
    }

    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force
        Write-Host "Removed: $InstallDir"
    }
    # Best-effort cleanup of legacy install path under Program Files (x86)
    # left over by earlier 32-bit-redirected installs.
    $legacyX86 = Join-Path ${env:ProgramFiles(x86)} 'IntuneWipeClient'
    if ($legacyX86 -and (Test-Path $legacyX86) -and ($legacyX86 -ne $InstallDir)) {
        Remove-Item $legacyX86 -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Removed legacy: $legacyX86"
    }

    # Delete the detection key from the 64-bit hive (where Install.ps1 wrote it).
    try {
        $base64 = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            [Microsoft.Win32.RegistryView]::Registry64)
        $base64.DeleteSubKeyTree($RegSubKey, $false)
        $base64.Close()
        Write-Host "Removed registry (64-bit): $RegPath"
    } catch { }
    # Best-effort cleanup of any stale WOW6432Node copy from older installs.
    if (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\MSLABS\IntuneWipeClient') {
        Remove-Item 'HKLM:\SOFTWARE\WOW6432Node\MSLABS\IntuneWipeClient' -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Contoso\IntuneWipeClient') {
        Remove-Item 'HKLM:\SOFTWARE\WOW6432Node\Contoso\IntuneWipeClient' -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path 'HKLM:\SOFTWARE\Contoso\IntuneWipeClient') {
        Remove-Item 'HKLM:\SOFTWARE\Contoso\IntuneWipeClient' -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host "Uninstall completed."
    exit 0
}
catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
