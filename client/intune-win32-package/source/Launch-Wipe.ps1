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
$ResultUiPath = Join-Path $InstallDir     'WipeResultDialogs.ps1'
$ProgressUiPath = Join-Path $InstallDir   'Show-WipeProgressDialog.ps1'
$DataDir    = Join-Path $env:ProgramData  'IntuneWipeClient'
$ResultPath = Join-Path $DataDir          'last-result.json'
$TaskFull   = '\IntuneWipeClient\InvokeWipe'

$UserLogDir = Join-Path $env:LOCALAPPDATA 'IntuneWipeClient\Logs'
New-Item -ItemType Directory -Force -Path $UserLogDir | Out-Null
$LogFile = Join-Path $UserLogDir ("Launch_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile -Force | Out-Null

# Device identity helpers live in the canonical module so they can be
# unit-tested in isolation (see client\tests\DeviceIdentity.Tests.ps1).
# The module is deployed alongside this script by the Win32 installer.
Import-Module (Join-Path $InstallDir 'DeviceIdentity.psm1') -Force -DisableNameChecking

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
    if (-not (Test-Path $ResultUiPath)) {
        throw "Result dialog script not found at '$ResultUiPath'. Reinstall the client."
    }

    # Load confirmation dialog builder (defines Show-WipeConfirmation),
    # the rich result dialogs (Show-WipeSuccessDialog, Show-WipeErrorDialog,
    # Show-WipeUnknownDialog) and the live status progress dialog
    # (Show-WipeProgressDialog) used on the success path to tail the
    # SYSTEM-context StatusPoller's status file.
    . $DialogPath
    . $ResultUiPath
    if (Test-Path $ProgressUiPath) { . $ProgressUiPath }

    $deviceName = $env:COMPUTERNAME
    $entraId    = Get-EntraDeviceIdSafe
    $intuneId   = Get-IntuneManagedDeviceIdSafe

    $confirmed = Show-WipeConfirmation -DeviceName $deviceName -EntraDeviceId $entraId -IntuneDeviceId $intuneId
    if (-not $confirmed) {
        Write-Host 'Operazione annullata dall''utente.' -ForegroundColor Yellow
        exit 0
    }

    # Wipe previous result so we know the next one is fresh.
    if (Test-Path $ResultPath) { Remove-Item -LiteralPath $ResultPath -Force -ErrorAction SilentlyContinue }

    Write-Host "Triggering scheduled task: $TaskFull"
    $triggerError = $null
    try {
        Start-ScheduledTask -TaskPath '\IntuneWipeClient\' -TaskName 'InvokeWipe' -ErrorAction Stop
    } catch {
        # Fallback to schtasks.exe if Start-ScheduledTask is unavailable.
        $triggerError = $_.Exception.Message
        & schtasks.exe /Run /TN $TaskFull | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "schtasks /Run failed (exit $LASTEXITCODE). First error: $triggerError" }
        $triggerError = $null
    }

    # Wait up to 2 minutes for the task to finish (state returns to 'Ready').
    $deadline = (Get-Date).AddMinutes(2)
    $state = 'Unknown'
    $lastTaskResult = $null
    do {
        Start-Sleep -Seconds 2
        $info = $null
        try { $info = Get-ScheduledTask -TaskPath '\IntuneWipeClient\' -TaskName 'InvokeWipe' -ErrorAction Stop } catch { }
        $state = if ($info) { $info.State } else { 'Unknown' }
    } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)
    try { $lastTaskResult = (Get-ScheduledTaskInfo -TaskPath '\IntuneWipeClient\' -TaskName 'InvokeWipe').LastTaskResult } catch { }

    # Read result file (written by Invoke-WipeFromTask.ps1).
    $result = $null
    $resultParseError = $null
    if (Test-Path $ResultPath) {
        try { $result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json } catch { $resultParseError = $_.Exception.Message }
    }

    # User-mode breadcrumb: persist what THIS launcher observed about the
    # SYSTEM-task lifecycle in a location the SYSTEM script does not touch.
    # This gives ground truth even if the SYSTEM script never executed (e.g.
    # AppLocker/WDAC blocked powershell.exe, .ps1 file missing, etc.) — IT
    # helpdesk can read this file from the user's profile to see whether the
    # task was triggered, the final state and the LastTaskResult.
    try {
        $breadcrumb = [ordered]@{
            ts                 = (Get-Date).ToUniversalTime().ToString('o')
            userName           = "$env:USERDOMAIN\$env:USERNAME"
            deviceName         = $env:COMPUTERNAME
            taskFullName       = $TaskFull
            triggerError       = $triggerError
            finalTaskState     = $state
            lastTaskResult     = $lastTaskResult
            resultFileExists   = (Test-Path $ResultPath)
            resultFileParseError = $resultParseError
            resultPayload      = $result
        }
        $breadcrumbPath = Join-Path $UserLogDir 'launcher-observation.json'
        ([pscustomobject]$breadcrumb) | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath $breadcrumbPath -Encoding utf8
    } catch {
        Write-Host "WARN: could not write launcher observation breadcrumb: $($_.Exception.Message)"
    }

    # If the SYSTEM task is still running at deadline, prefer the in-progress
    # dialog over the generic "Stato non disponibile" dialog: the user gets
    # an actionable message explaining the wipe was accepted by Intune but the
    # local task hasn't finished its bookkeeping yet. The user can re-run the
    # launcher in a minute to pick up the final result.
    if ($state -eq 'Running') {
        Show-WipeUnknownDialog -ReasonHint 'StillRunning'
        exit 2
    }

    if ($result -and $result.status -eq 'ok') {
        $corr = if ($result.correlationId) { $result.correlationId } else { '' }
        # New UX (replaces the static success popup): live progress dialog
        # that tails %ProgramData%\IntuneWipeClient\status\<corr>.json
        # populated by the SYSTEM-context StatusPoller scheduled task. The
        # user gets the CorrelationId AND continuous feedback on the wipe
        # action state observed by Intune. We fall back to the static
        # success dialog if the progress UI script is missing (older
        # install).
        if (Get-Command Show-WipeProgressDialog -ErrorAction SilentlyContinue) {
            Show-WipeProgressDialog -CorrelationId $corr -DeviceName $deviceName
        } else {
            Show-WipeSuccessDialog -CorrelationId $corr -DeviceName $deviceName
        }
        exit 0
    }
    elseif ($result -and $result.status -eq 'error') {
        Show-WipeErrorDialog -Result $result
        exit 1
    }
    else {
        $hint = if ($resultParseError) { 'BadJson' } else { 'NoResultFile' }
        Show-WipeUnknownDialog -ReasonHint $hint
        exit 2
    }
}
catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    try {
        # Use the rich error dialog if it's already loaded; otherwise fall
        # back to a plain MessageBox so the user is never left without UI.
        if (Get-Command Show-WipeErrorDialog -ErrorAction SilentlyContinue) {
            $fallback = [pscustomobject]@{
                status        = 'error'
                kind          = 'launcher'
                message       = $_.Exception.Message
                clientMessage = $_.Exception.Message
                ts            = (Get-Date).ToUniversalTime().ToString('o')
            }
            Show-WipeErrorDialog -Result $fallback -Title 'Errore'
        } else {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            [System.Windows.Forms.MessageBox]::Show(
                "Errore nell'avvio della richiesta:`r`n`r`n$($_.Exception.Message)",
                'Errore',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    } catch { }
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
