#requires -Version 5.1
<#
.SYNOPSIS
    Uninstalls the Intune Wipe self-service client.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $ShortcutName = 'Reset aziendale del dispositivo'
)

$ErrorActionPreference = 'Continue'

$InstallDir = Join-Path $env:ProgramFiles 'IntuneWipeClient'
$RegPath    = 'HKLM:\SOFTWARE\Contoso\IntuneWipeClient'
$LogDir     = Join-Path $env:ProgramData  'IntuneWipeClient\Logs'

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("Uninstall_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile -Force | Out-Null

try {
    # --- Scheduled task -----------------------------------------------------
    & schtasks.exe /Delete /TN '\IntuneWipeClient\InvokeWipe' /F 2>$null | Out-Null
    # Also remove the (now-empty) folder.
    try {
        $svc = New-Object -ComObject 'Schedule.Service'; $svc.Connect()
        $root = $svc.GetFolder('\')
        $root.DeleteFolder('IntuneWipeClient', 0)
    } catch { }

    $allUsersStart = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $publicDesktop = Join-Path $env:PUBLIC      'Desktop'
    foreach ($folder in @($allUsersStart, $publicDesktop)) {
        $lnkPath = Join-Path $folder ("{0}.lnk" -f $ShortcutName)
        if (Test-Path -LiteralPath $lnkPath) {
            Remove-Item -LiteralPath $lnkPath -Force
            Write-Host "Removed shortcut: $lnkPath"
        }
    }

    if (Test-Path $InstallDir) {
        Remove-Item $InstallDir -Recurse -Force
        Write-Host "Removed: $InstallDir"
    }

    if (Test-Path $RegPath) {
        Remove-Item $RegPath -Recurse -Force
        Write-Host "Removed registry: $RegPath"
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
