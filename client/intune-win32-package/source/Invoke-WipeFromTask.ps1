#requires -Version 5.1
<#
.SYNOPSIS
    Scheduled-task wrapper that runs as SYSTEM and performs the actual API
    call using the machine certificate.
.DESCRIPTION
    The end-user shortcut (Launch-Wipe.ps1) collects the confirmation in
    the user's interactive session, then triggers the scheduled task
    '\IntuneWipeClient\InvokeWipe' which executes this script as SYSTEM.
    Running as SYSTEM is required to access the private key of the SCEP /
    PKCS device certificate in Cert:\LocalMachine\My.

    This script:
      1. Reads C:\Program Files\IntuneWipeClient\config.json (ACL'd to
         SYSTEM + Administrators).
      2. Invokes Invoke-DeviceWipe.ps1 -Silent.
      3. Persists the outcome to %ProgramData%\IntuneWipeClient\last-result.json
         so the user-context launcher can show success/failure.
    Logs to %ProgramData%\IntuneWipeClient\Logs.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$InstallDir   = Join-Path $env:ProgramFiles 'IntuneWipeClient'
$ConfigPath   = Join-Path $InstallDir       'config.json'
$WipeScript   = Join-Path $InstallDir       'Invoke-DeviceWipe.ps1'
$DataDir      = Join-Path $env:ProgramData  'IntuneWipeClient'
$LogDir       = Join-Path $DataDir          'Logs'
$ResultPath   = Join-Path $DataDir          'last-result.json'

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("Task_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile -Force | Out-Null

function Write-Result {
    param([string]$Status, [string]$Message, [string]$CorrelationId)
    $payload = [pscustomobject]@{
        status        = $Status
        message       = $Message
        correlationId = $CorrelationId
        ts            = (Get-Date).ToUniversalTime().ToString('o')
    }
    $payload | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding utf8
}

try {
    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
    if (-not (Test-Path $WipeScript)) { throw "Wipe script not found: $WipeScript" }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

    $params = @{
        ApiUrl      = $cfg.ApiUrl
        FunctionKey = $cfg.FunctionKey
        Silent      = $true
    }
    if ($cfg.CertificateThumbprint)  { $params['CertificateThumbprint']  = $cfg.CertificateThumbprint  }
    if ($cfg.CertificateIssuerLike)  { $params['CertificateIssuerLike']  = $cfg.CertificateIssuerLike  }
    if ($cfg.CertificateSubjectLike) { $params['CertificateSubjectLike'] = $cfg.CertificateSubjectLike }

    # Capture stdout to extract the correlation id from the wipe response.
    $out = & $WipeScript @params 2>&1
    $out | ForEach-Object { Write-Host $_ }

    # Try to extract a correlationId from the captured output (the wipe
    # script writes the response object with Format-List).
    $corr = $null
    foreach ($line in $out) {
        if ($line -match 'correlationId\s*:\s*([0-9a-fA-F-]{36})') {
            $corr = $Matches[1]; break
        }
    }

    Write-Result -Status 'ok' -Message 'Wipe request accepted by the API.' -CorrelationId $corr
    exit 0
}
catch {
    $msg = $_.Exception.Message
    Write-Host ("ERROR: {0}" -f $msg) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    Write-Result -Status 'error' -Message $msg -CorrelationId $null
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
