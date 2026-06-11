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

    # ---------- Client-side schedule gate -----------------------------------
    # Read %ProgramData%\IntuneWipeClient\schedule.json (refreshed by the
    # Intune Proactive Remediation in client/intune-remediation-schedule/).
    # If a future wave is assigned to this device, surface a friendly
    # "scheduled for X" dialog and abort BEFORE prompting the user for a
    # destructive confirmation that wouldn't fire anyway (the capability-side
    # gate in WipeActionRunner Step 0 would defer it server-side).
    #
    # Fail-open semantics: missing / empty / malformed manifest → proceed
    # normally. The server-side gate is the authoritative safety net; this
    # client gate is purely UX defense-in-depth.
    $scheduleManifestPath = Join-Path $DataDir 'schedule.json'
    if (Test-Path -LiteralPath $scheduleManifestPath) {
        try {
            $rawManifest = Get-Content -LiteralPath $scheduleManifestPath -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($rawManifest)) {
                $manifest = $rawManifest | ConvertFrom-Json -ErrorAction Stop
                if (-not $manifest.empty -and $manifest.scheduledAtUtc) {
                    $whenUtc = [DateTimeOffset]::Parse($manifest.scheduledAtUtc).ToUniversalTime()
                    $deltaSec = ($whenUtc - [DateTimeOffset]::UtcNow).TotalSeconds
                    if ($deltaSec -gt 0) {
                        $whenLocal = $whenUtc.LocalDateTime
                        $waveName  = if ($manifest.name) { $manifest.name } else { 'pianificata' }
                        $body = "Il wipe di questo dispositivo è pianificato per:`r`n`r`n   $($whenLocal.ToString('dddd dd MMMM yyyy HH:mm')) (ora locale)`r`n`r`nWave: $waveName"
                        if ($manifest.description) {
                            $body += "`r`nDettagli: $($manifest.description)"
                        }
                        $body += "`r`n`r`nPer questo motivo l'azione di wipe non può essere avviata adesso. L'esecuzione partirà automaticamente all'orario indicato."
                        Add-Type -AssemblyName System.Windows.Forms | Out-Null
                        [System.Windows.Forms.MessageBox]::Show(
                            $body, 'Wipe pianificato',
                            [System.Windows.Forms.MessageBoxButtons]::OK,
                            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                        Write-Host ("Wipe gated by client-side schedule: wave '{0}' fires at {1:o} ({2:N0}s)" -f `
                            $waveName, $whenUtc, $deltaSec) -ForegroundColor Yellow
                        exit 0
                    }
                }
            }
        } catch {
            # Fail-open: log + proceed. The server-side gate still applies.
            Write-Host "WARN: could not parse schedule.json ($($_.Exception.Message)); proceeding without client-side gate."
        }
    }
    # ------------------------------------------------------------------------

    # ---- New live-progress confirmation flow ------------------------------
    # Single dialog that:
    #   1) collects the typed "WIPE" confirmation (phase 1)
    #   2) on confirm, transitions to a progress panel and walks the user
    #      through trigger-task -> wait -> read-result -> outcome IN-PLACE
    #      so there's no ~2-minute UX gap between "click Esegui" and the
    #      live status dialog opening.
    # Falls back to the legacy modal+poll flow if the new helper isn't
    # present (older client build still on disk after a partial upgrade).
    if (Get-Command Show-WipeConfirmationLive -ErrorAction SilentlyContinue) {
        $script:exitCode = 1

        $onExecute = {
            param($form)

            Add-WipeFormLog -Form $form -Message ("Dispositivo : {0}" -f $deviceName)        -Kind muted
            Add-WipeFormLog -Form $form -Message ("EntraDevId  : {0}" -f $entraId)           -Kind muted
            if ($intuneId) { Add-WipeFormLog -Form $form -Message ("IntuneDevId : {0}" -f $intuneId) -Kind muted }

            # Wipe previous result so we know the next one is fresh.
            if (Test-Path $ResultPath) { Remove-Item -LiteralPath $ResultPath -Force -ErrorAction SilentlyContinue }

            Set-WipeFormStatus -Form $form -Text 'Avvio task amministrativo (SYSTEM)...'
            Add-WipeFormLog -Form $form -Message ("Triggering scheduled task: {0}" -f $TaskFull)
            $triggerError = $null
            try {
                Start-ScheduledTask -TaskPath '\IntuneWipeClient\' -TaskName 'InvokeWipe' -ErrorAction Stop
                Add-WipeFormLog -Form $form -Message 'Task avviato.' -Kind success
            } catch {
                $triggerError = $_.Exception.Message
                Add-WipeFormLog -Form $form -Message ("Start-ScheduledTask fallito ({0}); fallback su schtasks.exe..." -f $triggerError) -Kind warning
                & schtasks.exe /Run /TN $TaskFull | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Add-WipeFormLog -Form $form -Message ("schtasks /Run uscito con codice {0}" -f $LASTEXITCODE) -Kind error
                    Complete-WipeForm -Form $form -Success $false -FinalStatus 'Impossibile avviare il task amministrativo.'
                    $script:exitCode = 1
                    return
                }
                Add-WipeFormLog -Form $form -Message 'Task avviato via schtasks.exe.' -Kind success
                $triggerError = $null
            }

            Set-WipeFormStatus -Form $form -Text 'Esecuzione comando di reset (chiamata API)...'
            Add-WipeFormLog -Form $form -Message 'Attendo il completamento del task (max 2 minuti)...'
            $deadline = (Get-Date).AddMinutes(2)
            $state = 'Unknown'
            $lastReported = 'Unknown'
            do {
                Start-Sleep -Seconds 2
                [System.Windows.Forms.Application]::DoEvents()
                $info = $null
                try { $info = Get-ScheduledTask -TaskPath '\IntuneWipeClient\' -TaskName 'InvokeWipe' -ErrorAction Stop } catch { }
                $state = if ($info) { $info.State } else { 'Unknown' }
                if ($state -ne $lastReported) {
                    Add-WipeFormLog -Form $form -Message ("Stato task: {0}" -f $state) -Kind muted
                    $lastReported = $state
                }
            } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)
            $lastTaskResult = $null
            try { $lastTaskResult = (Get-ScheduledTaskInfo -TaskPath '\IntuneWipeClient\' -TaskName 'InvokeWipe').LastTaskResult } catch { }
            Add-WipeFormLog -Form $form -Message ("Task terminato (LastTaskResult = {0})" -f $lastTaskResult) -Kind muted

            # Read result file (written by Invoke-WipeFromTask.ps1).
            Set-WipeFormStatus -Form $form -Text 'Lettura risultato...'
            $result = $null
            $resultParseError = $null
            if (Test-Path $ResultPath) {
                try { $result = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json } catch { $resultParseError = $_.Exception.Message }
            }

            # Persist launcher observation breadcrumb (same as before).
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
                Add-WipeFormLog -Form $form -Message ("WARN: impossibile scrivere il breadcrumb: {0}" -f $_.Exception.Message) -Kind warning
            }

            if ($state -eq 'Running') {
                Add-WipeFormLog -Form $form -Message 'Il task amministrativo è ancora in esecuzione oltre il timeout UI (2 min).' -Kind warning
                Add-WipeFormLog -Form $form -Message 'Riapri il launcher tra qualche minuto per leggere il risultato finale.' -Kind muted
                Complete-WipeForm -Form $form -Success $false -FinalStatus 'Esito non disponibile entro 2 minuti.'
                $script:exitCode = 2
                return
            }

            if ($result -and $result.status -eq 'ok') {
                $corr = if ($result.correlationId) { [string]$result.correlationId } else { '' }
                $msg  = if ($result.message)       { [string]$result.message }       else { '' }
                Add-WipeFormLog -Form $form -Message 'Richiesta accettata dal server.' -Kind success
                if ($corr) {
                    Set-WipeFormCorrelationId -Form $form -CorrelationId $corr
                    Add-WipeFormLog -Form $form -Message ("CorrelationId : {0}" -f $corr) -Kind success
                }
                if ($msg) { Add-WipeFormLog -Form $form -Message ("Server message : {0}" -f $msg) -Kind muted }
                Add-WipeFormLog -Form $form -Message 'Intune prenderà in carico il comando entro pochi minuti.' -Kind muted
                Add-WipeFormLog -Form $form -Message 'Usa "Monitora avanzamento live" per seguire gli stati riportati da Intune.' -Kind muted

                $openLive = $null
                if (Get-Command Show-WipeProgressDialog -ErrorAction SilentlyContinue) {
                    $openLive = { param($c) Show-WipeProgressDialog -CorrelationId $c -DeviceName $deviceName }.GetNewClosure()
                }
                Complete-WipeForm -Form $form -Success $true `
                    -FinalStatus 'Reset richiesto. In attesa di presa in carico da Intune.' `
                    -OnOpenLiveProgress $openLive
                $script:exitCode = 0
                return
            }

            if ($result -and $result.status -eq 'error') {
                $corr  = if ($result.correlationId) { [string]$result.correlationId } else { '' }
                $msg   = if ($result.message)       { [string]$result.message }       else { 'Errore non specificato dal server.' }
                $kind  = if ($result.kind)          { [string]$result.kind }          else { '' }
                $http  = if ($result.httpStatusCode){ [string]$result.httpStatusCode } else { '' }
                Add-WipeFormLog -Form $form -Message 'Richiesta FALLITA.' -Kind error
                if ($http) { Add-WipeFormLog -Form $form -Message ("HTTP : {0}" -f $http) -Kind error }
                if ($kind) { Add-WipeFormLog -Form $form -Message ("Kind : {0}" -f $kind) -Kind muted }
                Add-WipeFormLog -Form $form -Message ("Message : {0}" -f $msg) -Kind error
                if ($corr) {
                    Set-WipeFormCorrelationId -Form $form -CorrelationId $corr
                    Add-WipeFormLog -Form $form -Message ("CorrelationId : {0}" -f $corr) -Kind muted
                }
                Complete-WipeForm -Form $form -Success $false -FinalStatus 'Richiesta di reset rifiutata dal server.'
                $script:exitCode = 1
                return
            }

            # No result / unparseable result.
            $hint = if ($resultParseError) { ("Risultato non leggibile: {0}" -f $resultParseError) } else { 'Nessun file di risultato prodotto dal task SYSTEM.' }
            Add-WipeFormLog -Form $form -Message $hint -Kind error
            Add-WipeFormLog -Form $form -Message 'Controlla i log in %ProgramData%\IntuneWipeClient\Logs.' -Kind muted
            Complete-WipeForm -Form $form -Success $false -FinalStatus 'Esito sconosciuto.'
            $script:exitCode = 2
        }.GetNewClosure()

        $openLiveFromConfirm = $null
        if (Get-Command Show-WipeProgressDialog -ErrorAction SilentlyContinue) {
            $openLiveFromConfirm = { param($c) Show-WipeProgressDialog -CorrelationId $c -DeviceName $deviceName }.GetNewClosure()
        }

        $confirmed = Show-WipeConfirmationLive `
            -DeviceName $deviceName -EntraDeviceId $entraId -IntuneDeviceId $intuneId `
            -OnExecute $onExecute -OnOpenLiveProgress $openLiveFromConfirm

        if (-not $confirmed) {
            Write-Host 'Operazione annullata dall''utente.' -ForegroundColor Yellow
            exit 0
        }
        exit $script:exitCode
    }

    # ---- Legacy flow (fallback when Show-WipeConfirmationLive is missing) ---
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
    # AppLocker/WDAC blocked powershell.exe, .ps1 file missing, etc.) - IT
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
