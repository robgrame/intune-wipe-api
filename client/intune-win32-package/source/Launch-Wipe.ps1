#requires -Version 5.1
<#
.SYNOPSIS
    Start Menu launcher. Reads the per-machine config and invokes the
    real Invoke-DeviceWipe.ps1 with the proper parameters.

.DESCRIPTION
    Designed to run in the *user's* interactive session (the shortcut is
    not elevated) so the WinForms confirmation dialog renders correctly.
    Reading config.json requires Administrators / SYSTEM; if the user is
    not elevated and the ACL on config.json is restrictive, we fall back
    to having the user re-run elevated. In typical Intune deployments the
    end user is a local admin on their device, which keeps the UX simple.

    Logs end up under %LOCALAPPDATA%\IntuneWipeClient\Logs.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:ProgramFiles 'IntuneWipeClient'
$ConfigPath = Join-Path $InstallDir       'config.json'
$WipeScript = Join-Path $InstallDir       'Invoke-DeviceWipe.ps1'

$UserLogDir = Join-Path $env:LOCALAPPDATA 'IntuneWipeClient\Logs'
New-Item -ItemType Directory -Force -Path $UserLogDir | Out-Null
$LogFile = Join-Path $UserLogDir ("Launch_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile -Force | Out-Null

try {
    if (-not (Test-Path $ConfigPath)) {
        throw "Configuration file not found at '$ConfigPath'. Reinstall the client from Company Portal."
    }
    if (-not (Test-Path $WipeScript)) {
        throw "Wipe script not found at '$WipeScript'. Reinstall the client from Company Portal."
    }

    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        [System.Windows.Forms.MessageBox]::Show(
            "Impossibile leggere la configurazione del client di wipe.`r`n`r`n" +
            "Esegui questa scorciatoia come amministratore (clic destro -> Esegui come amministratore).",
            'IntuneWipeClient',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        throw
    }

    $params = @{
        ApiUrl                 = $cfg.ApiUrl
        FunctionKey            = $cfg.FunctionKey
        CertificateSubjectLike = $cfg.CertificateSubjectLike
    }
    if ($cfg.CertificateThumbprint) { $params['CertificateThumbprint'] = $cfg.CertificateThumbprint }

    & $WipeScript @params
    exit $LASTEXITCODE
}
catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
