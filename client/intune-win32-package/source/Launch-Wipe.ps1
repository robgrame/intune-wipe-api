#requires -Version 5.1
<#
.SYNOPSIS
    User-context launcher. Shows the wipe-confirmation UI; on accept,
    triggers the SYSTEM-context scheduled task that performs the actual API
    call with the device certificate's private key.
.DESCRIPTION
    Why this split: the device SCEP/PKCS certificate lives in
    Cert:\LocalMachine\My and its private key is ACL'd to SYSTEM and
    BUILTIN\Administrators. A non-admin user-context script cannot use the
    cert for TLS client auth. The confirmation dialog, however, must run
    in the user's interactive session (Session 0 isolation prevents SYSTEM
    from showing UI). So:
      - This script (user context): show dialog, on accept trigger the task.
      - Invoke-WipeFromTask.ps1 (SYSTEM via scheduled task): API call.
    The task writes its result to %ProgramData%\IntuneWipeClient\last-result.json
    which this launcher reads to show success/failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ProgramFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
$InstallDir = Join-Path $ProgramFiles64 'IntuneWipeClient'
$DialogPath = Join-Path $InstallDir       'WipeConfirmationDialog.ps1'
$DataDir    = Join-Path $env:ProgramData  'IntuneWipeClient'
$ResultPath = Join-Path $DataDir          'last-result.json'
$TaskFull   = '\IntuneWipeClient\InvokeWipe'

$UserLogDir = Join-Path $env:LOCALAPPDATA 'IntuneWipeClient\Logs'
New-Item -ItemType Directory -Force -Path $UserLogDir | Out-Null
$LogFile = Join-Path $UserLogDir ("Launch_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile -Force | Out-Null

function Get-EntraDeviceIdSafe {
    try {
        $out = & dsregcmd /status 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return 'n/a' }
        $line = $out | Where-Object { $_ -match '^\s*DeviceId\s*:\s*([0-9a-fA-F-]{36})' } | Select-Object -First 1
        if ($line -match '([0-9a-fA-F-]{36})') { return $Matches[1] }
        return 'n/a'
    } catch { return 'n/a' }
}

function Get-IntuneDeviceIdSafe {
    try {
        $root = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
        if (-not (Test-Path $root)) { return 'n/a' }
        foreach ($e in (Get-ChildItem $root -ErrorAction SilentlyContinue |
                        Where-Object { $_.PSChildName -match '^[0-9A-Fa-f-]{36}$' })) {
            $p = Get-ItemProperty $e.PSPath -ErrorAction SilentlyContinue
            if ($p.ProviderID -eq 'MS DM Server' -and $p.UPN) {
                if ($p.PSObject.Properties.Name -contains 'DeviceClientId' -and $p.DeviceClientId) {
                    return $p.DeviceClientId
                }
                return $e.PSChildName
            }
        }
    } catch { }
    return 'n/a'
}

function Show-Message {
    param([string]$Text, [string]$Title, [System.Windows.Forms.MessageBoxIcon]$Icon = 'Information')
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show($Text, $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK, $Icon) | Out-Null
}

try {
    if (-not (Test-Path $DialogPath)) {
        throw "Dialog script not found at '$DialogPath'. Reinstall the client."
    }

    # Load confirmation dialog builder (defines Show-WipeConfirmation).
    . $DialogPath

    $deviceName = $env:COMPUTERNAME
    $entraId    = Get-EntraDeviceIdSafe
    $intuneId   = Get-IntuneDeviceIdSafe

    $confirmed = Show-WipeConfirmation -DeviceName $deviceName -EntraDeviceId $entraId -IntuneDeviceId $intuneId
    if (-not $confirmed) {
        Write-Host 'Operazione annullata dall''utente.' -ForegroundColor Yellow
        exit 0
    }

    # Wipe previous result so we know the next one is fresh.
    if (Test-Path $ResultPath) { Remove-Item -LiteralPath $ResultPath -Force -ErrorAction SilentlyContinue }

    Write-Host "Triggering scheduled task: $TaskFull"
    try {
        Start-ScheduledTask -TaskPath '\IntuneWipeClient\' -TaskName 'InvokeWipe' -ErrorAction Stop
    } catch {
        # Fallback to schtasks.exe if Start-ScheduledTask is unavailable.
        & schtasks.exe /Run /TN $TaskFull | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "schtasks /Run failed (exit $LASTEXITCODE)" }
    }

    # Wait up to 2 minutes for the task to finish (state returns to 'Ready').
    $deadline = (Get-Date).AddMinutes(2)
    do {
        Start-Sleep -Seconds 2
        $info = $null
        try { $info = Get-ScheduledTask -TaskPath '\IntuneWipeClient\' -TaskName 'InvokeWipe' -ErrorAction Stop } catch { }
        $state = if ($info) { $info.State } else { 'Unknown' }
    } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)

    # Read result file (written by Invoke-WipeFromTask.ps1).
    $result = $null
    if (Test-Path $ResultPath) {
        try { $result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json } catch { }
    }

    if ($result -and $result.status -eq 'ok') {
        $corr = if ($result.correlationId) { $result.correlationId } else { '(n/d)' }
        Show-Message -Title 'Reset richiesto' -Icon Information -Text (
            "Richiesta di reset accettata.`r`n`r`n" +
            "Correlation Id: $corr`r`n`r`n" +
            "Il dispositivo verra' reimpostato a breve e restera' inutilizzabile per circa 90 minuti."
        )
        exit 0
    }
    elseif ($result -and $result.status -eq 'error') {
        Show-Message -Title 'Errore' -Icon Error -Text (
            "Impossibile completare la richiesta di reset.`r`n`r`n" +
            "Dettagli tecnici:`r`n$($result.message)`r`n`r`n" +
            "Contatta l'IT helpdesk."
        )
        exit 1
    }
    else {
        Show-Message -Title 'Stato sconosciuto' -Icon Warning -Text (
            "L'operazione e' stata avviata ma il risultato non e' ancora disponibile.`r`n`r`n" +
            "Controlla %ProgramData%\IntuneWipeClient\Logs per i dettagli."
        )
        exit 2
    }
}
catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    try {
        Show-Message -Title 'Errore' -Icon Error -Text (
            "Errore nell'avvio della richiesta:`r`n`r`n$($_.Exception.Message)"
        )
    } catch { }
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
