#requires -Version 5.1
<#
.SYNOPSIS
    Shared builder for the wipe-confirmation WinForms dialog.
.DESCRIPTION
    Single source of truth for the confirmation UI shown to the end user
    before issuing a self-wipe. Used both by the production client
    (Invoke-DeviceWipe.ps1) and by the documentation screenshot script
    (docs/Capture-DialogScreenshot.ps1).

    - Build-WipeConfirmationForm: returns the populated [Form] without
      showing it. Caller decides ShowDialog() (modal) vs Show() (non-modal
      for screenshot capture).
    - Show-WipeConfirmation: convenience wrapper that ShowDialog()s the
      form and returns $true only if the user accepted.

    PowerShell 5.1 reads .ps1 files as Windows-1252 unless the file has a
    UTF-8 BOM. Non-ASCII glyphs are produced via [char] codes so the
    visible UI text stays correct regardless of how the file is saved.
#>

function Build-WipeConfirmationForm {
    param(
        [Parameter(Mandatory)] [string] $DeviceName,
        [Parameter(Mandatory)] [string] $EntraDeviceId,
        [Parameter(Mandatory)] [string] $IntuneDeviceId
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $e_grave = [char]0x00E8
    $a_grave = [char]0x00E0
    $bul     = [char]0x2022
    $warnSym = [char]0x26A0

    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = 'Conferma reset del dispositivo'
    $form.Size            = New-Object System.Drawing.Size(640, 560)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.BackColor       = [System.Drawing.Color]::White
    $form.TopMost         = $true
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 10)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock      = 'Top'
    $header.Height    = 64
    $header.BackColor = [System.Drawing.Color]::FromArgb(196, 30, 58)
    $form.Controls.Add($header)

    $hLbl = New-Object System.Windows.Forms.Label
    $hLbl.Text      = "$warnSym  Reset di fabbrica del dispositivo"
    $hLbl.ForeColor = [System.Drawing.Color]::White
    $hLbl.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 16, [System.Drawing.FontStyle]::Bold)
    $hLbl.AutoSize  = $true
    $hLbl.Location  = New-Object System.Drawing.Point(20, 16)
    $header.Controls.Add($hLbl)

    # -------- Phase 1 controls (confirmation) ------------------------------
    # Grouped into a Panel so the caller can hide them in one shot when the
    # form transitions into "execution / progress" mode after the user
    # confirms.
    $phase1 = New-Object System.Windows.Forms.Panel
    $phase1.Location = New-Object System.Drawing.Point(0, 64)
    $phase1.Size     = New-Object System.Drawing.Size(624, 460)
    $phase1.BackColor = [System.Drawing.Color]::White
    $form.Controls.Add($phase1)

    $warn = New-Object System.Windows.Forms.Label
    $warn.Location = New-Object System.Drawing.Point(24, 16)
    $warn.Size     = New-Object System.Drawing.Size(580, 130)
    $warn.Text     = @"
Stai per richiedere il RESET DI FABBRICA di questo dispositivo via Microsoft Intune.

$bul L'operazione $e_grave IRREVERSIBILE: tutti i dati locali, le app, gli account e le impostazioni verranno cancellati.
$bul Il dispositivo rester$a_grave INUTILIZZABILE per circa 90 minuti durante il reset e la successiva re-provisioning.
$bul Assicurati di aver salvato tutto il lavoro in corso e di essere collegato all'alimentazione e a Internet.
"@
    $phase1.Controls.Add($warn)

    $info = New-Object System.Windows.Forms.GroupBox
    $info.Text     = 'Dispositivo'
    $info.Location = New-Object System.Drawing.Point(24, 151)
    $info.Size     = New-Object System.Drawing.Size(580, 100)
    $info.Font     = New-Object System.Drawing.Font('Segoe UI', 9)
    $phase1.Controls.Add($info)

    $infoLbl = New-Object System.Windows.Forms.Label
    $infoLbl.Location = New-Object System.Drawing.Point(14, 22)
    $infoLbl.Size     = New-Object System.Drawing.Size(556, 70)
    $infoLbl.Font     = New-Object System.Drawing.Font('Consolas', 9)
    $infoLbl.Text     = "Nome           : $DeviceName`r`nEntra Device   : $EntraDeviceId`r`nIntune Device  : $IntuneDeviceId"
    $info.Controls.Add($infoLbl)

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Location = New-Object System.Drawing.Point(24, 261)
    $chk.Size     = New-Object System.Drawing.Size(580, 24)
    $chk.Text     = "Ho compreso che l'operazione $e_grave irreversibile."
    $phase1.Controls.Add($chk)

    $typeLbl = New-Object System.Windows.Forms.Label
    $typeLbl.Location = New-Object System.Drawing.Point(24, 291)
    $typeLbl.Size     = New-Object System.Drawing.Size(580, 20)
    $typeLbl.Text     = 'Per confermare, digita la parola WIPE in maiuscolo:'
    $phase1.Controls.Add($typeLbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(24, 314)
    $tb.Size     = New-Object System.Drawing.Size(200, 28)
    $tb.Font     = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold)
    $tb.CharacterCasing = 'Upper'
    $phase1.Controls.Add($tb)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text      = 'Esegui reset'
    $btnOk.Location  = New-Object System.Drawing.Point(360, 406)
    $btnOk.Size      = New-Object System.Drawing.Size(120, 36)
    $btnOk.BackColor = [System.Drawing.Color]::FromArgb(196, 30, 58)
    $btnOk.ForeColor = [System.Drawing.Color]::White
    $btnOk.FlatStyle = 'Flat'
    $btnOk.Enabled   = $false
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $phase1.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = 'Annulla'
    $btnCancel.Location = New-Object System.Drawing.Point(490, 406)
    $btnCancel.Size     = New-Object System.Drawing.Size(120, 36)
    $btnCancel.FlatStyle = 'Flat'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $phase1.Controls.Add($btnCancel)

    $form.AcceptButton = $null
    $form.CancelButton = $btnCancel

    $updateState = {
        $btnOk.Enabled = ($chk.Checked -and $tb.Text -ceq 'WIPE')
    }.GetNewClosure()
    $chk.Add_CheckedChanged($updateState)
    $tb.Add_TextChanged($updateState)

    # -------- Phase 2 controls (execution / progress) ---------------------
    # Initially hidden. Show-WipeConfirmationLive switches the form into this
    # mode after the user has confirmed: the phase-1 panel is hidden and the
    # caller drives the form forward via the LogMessage / SetStatus /
    # MarkComplete helpers attached below.
    $phase2 = New-Object System.Windows.Forms.Panel
    $phase2.Location = New-Object System.Drawing.Point(0, 64)
    $phase2.Size     = New-Object System.Drawing.Size(624, 460)
    $phase2.BackColor = [System.Drawing.Color]::White
    $phase2.Visible  = $false
    $form.Controls.Add($phase2)

    $p2Intro = New-Object System.Windows.Forms.Label
    $p2Intro.Location = New-Object System.Drawing.Point(24, 12)
    $p2Intro.Size     = New-Object System.Drawing.Size(580, 36)
    $p2Intro.Text     = "Esecuzione della richiesta di reset in corso. Questa finestra si aggiorna automaticamente."
    $p2Intro.Font     = New-Object System.Drawing.Font('Segoe UI', 9)
    $p2Intro.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $phase2.Controls.Add($p2Intro)

    $p2Status = New-Object System.Windows.Forms.Label
    $p2Status.Location = New-Object System.Drawing.Point(24, 52)
    $p2Status.Size     = New-Object System.Drawing.Size(580, 24)
    $p2Status.Font     = New-Object System.Drawing.Font('Segoe UI Semibold', 11, [System.Drawing.FontStyle]::Bold)
    $p2Status.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
    $p2Status.Text     = 'Avvio...'
    $phase2.Controls.Add($p2Status)

    $p2Progress = New-Object System.Windows.Forms.ProgressBar
    $p2Progress.Location = New-Object System.Drawing.Point(24, 80)
    $p2Progress.Size     = New-Object System.Drawing.Size(580, 14)
    $p2Progress.Style    = 'Marquee'
    $p2Progress.MarqueeAnimationSpeed = 40
    $phase2.Controls.Add($p2Progress)

    $p2CorrLbl = New-Object System.Windows.Forms.Label
    $p2CorrLbl.Location = New-Object System.Drawing.Point(24, 102)
    $p2CorrLbl.Size     = New-Object System.Drawing.Size(580, 20)
    $p2CorrLbl.Font     = New-Object System.Drawing.Font('Consolas', 9)
    $p2CorrLbl.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $p2CorrLbl.Text     = ''
    $phase2.Controls.Add($p2CorrLbl)

    $p2LogLbl = New-Object System.Windows.Forms.Label
    $p2LogLbl.Location = New-Object System.Drawing.Point(24, 128)
    $p2LogLbl.Size     = New-Object System.Drawing.Size(580, 20)
    $p2LogLbl.Text     = 'Avanzamento:'
    $p2LogLbl.Font     = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $phase2.Controls.Add($p2LogLbl)

    $p2Log = New-Object System.Windows.Forms.RichTextBox
    $p2Log.Location   = New-Object System.Drawing.Point(24, 150)
    $p2Log.Size       = New-Object System.Drawing.Size(580, 210)
    $p2Log.ReadOnly   = $true
    $p2Log.BackColor  = [System.Drawing.Color]::FromArgb(248, 248, 248)
    $p2Log.Font       = New-Object System.Drawing.Font('Consolas', 9)
    $p2Log.WordWrap   = $true
    $p2Log.DetectUrls = $false
    $phase2.Controls.Add($p2Log)

    $p2OpenProgress = New-Object System.Windows.Forms.Button
    $p2OpenProgress.Text     = 'Monitora avanzamento live...'
    $p2OpenProgress.Location = New-Object System.Drawing.Point(24, 406)
    $p2OpenProgress.Size     = New-Object System.Drawing.Size(240, 36)
    $p2OpenProgress.FlatStyle = 'Flat'
    $p2OpenProgress.Visible  = $false
    $phase2.Controls.Add($p2OpenProgress)

    $p2Close = New-Object System.Windows.Forms.Button
    $p2Close.Text         = 'Chiudi'
    $p2Close.Location     = New-Object System.Drawing.Point(490, 406)
    $p2Close.Size         = New-Object System.Drawing.Size(120, 36)
    $p2Close.FlatStyle    = 'Flat'
    $p2Close.Enabled      = $false   # enabled by MarkComplete
    $p2Close.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $phase2.Controls.Add($p2Close)

    # Expose key controls for callers (e.g. screenshot script that
    # needs to pre-fill the dialog into the "ready" state).
    $form | Add-Member -NotePropertyName 'AcceptCheckBox'     -NotePropertyValue $chk            -Force
    $form | Add-Member -NotePropertyName 'ConfirmTextBox'     -NotePropertyValue $tb             -Force
    $form | Add-Member -NotePropertyName 'ConfirmButton'      -NotePropertyValue $btnOk          -Force
    $form | Add-Member -NotePropertyName 'Phase1Panel'        -NotePropertyValue $phase1         -Force
    $form | Add-Member -NotePropertyName 'Phase2Panel'        -NotePropertyValue $phase2         -Force
    $form | Add-Member -NotePropertyName 'ProgressStatus'     -NotePropertyValue $p2Status       -Force
    $form | Add-Member -NotePropertyName 'ProgressBarCtl'     -NotePropertyValue $p2Progress     -Force
    $form | Add-Member -NotePropertyName 'ProgressCorrLabel'  -NotePropertyValue $p2CorrLbl      -Force
    $form | Add-Member -NotePropertyName 'ProgressLog'        -NotePropertyValue $p2Log          -Force
    $form | Add-Member -NotePropertyName 'ProgressCloseBtn'   -NotePropertyValue $p2Close        -Force
    $form | Add-Member -NotePropertyName 'OpenLiveProgressBtn' -NotePropertyValue $p2OpenProgress -Force

    return $form
}

function Show-WipeConfirmation {
    param(
        [Parameter(Mandatory)] [string] $DeviceName,
        [Parameter(Mandatory)] [string] $EntraDeviceId,
        [Parameter(Mandatory)] [string] $IntuneDeviceId
    )
    $form   = Build-WipeConfirmationForm -DeviceName $DeviceName -EntraDeviceId $EntraDeviceId -IntuneDeviceId $IntuneDeviceId
    $result = $form.ShowDialog()
    $form.Dispose()
    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

# ----- Phase-2 helpers (live execution UX) ----------------------------------
# Pure UI primitives invoked by the caller's -OnExecute scriptblock to keep
# the user informed about what is happening BETWEEN the moment they confirm
# the wipe and the moment Intune accepts the command. Every helper pumps the
# WinForms message loop (DoEvents) so the form repaints even though the
# caller's PowerShell flow is synchronous and CPU-bound.

function Switch-WipeFormToProgress {
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.Form] $Form,
        [string] $InitialStatus = 'Esecuzione in corso...'
    )
    $Form.Phase1Panel.Visible = $false
    $Form.Phase2Panel.Visible = $true
    $Form.AcceptButton = $null
    $Form.CancelButton = $null
    $Form.Text = 'Esecuzione richiesta di reset'
    $Form.ProgressStatus.Text = $InitialStatus
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-WipeFormStatus {
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.Form] $Form,
        [Parameter(Mandatory)] [string] $Text
    )
    $Form.ProgressStatus.Text = $Text
    [System.Windows.Forms.Application]::DoEvents()
}

function Add-WipeFormLog {
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.Form] $Form,
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('info','success','warning','error','muted')]
        [string] $Kind = 'info'
    )
    $colors = @{
        info    = [System.Drawing.Color]::FromArgb(20, 20, 20)
        success = [System.Drawing.Color]::FromArgb(0, 120, 50)
        warning = [System.Drawing.Color]::FromArgb(176, 122, 0)
        error   = [System.Drawing.Color]::FromArgb(168, 0, 0)
        muted   = [System.Drawing.Color]::FromArgb(110, 110, 110)
    }
    $rt = $Form.ProgressLog
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $line = ("[{0}] {1}{2}" -f $stamp, $Message, [Environment]::NewLine)

    $rt.SelectionStart = $rt.TextLength
    $rt.SelectionLength = 0
    $rt.SelectionColor = $colors[$Kind]
    $rt.AppendText($line)
    $rt.SelectionColor = $colors['info']
    $rt.SelectionStart = $rt.TextLength
    $rt.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-WipeFormCorrelationId {
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.Form] $Form,
        [Parameter(Mandatory)] [string] $CorrelationId
    )
    if ([string]::IsNullOrWhiteSpace($CorrelationId)) { return }
    $Form.ProgressCorrLabel.Text = ("CorrelationId : {0}" -f $CorrelationId)
    $Form | Add-Member -NotePropertyName 'CorrelationId' -NotePropertyValue $CorrelationId -Force
    [System.Windows.Forms.Application]::DoEvents()
}

function Complete-WipeForm {
    param(
        [Parameter(Mandatory)] [System.Windows.Forms.Form] $Form,
        [Parameter(Mandatory)] [bool] $Success,
        [Parameter(Mandatory)] [string] $FinalStatus,
        [scriptblock] $OnOpenLiveProgress
    )
    $Form.ProgressBarCtl.Style = 'Continuous'
    $Form.ProgressBarCtl.Value = 100
    $Form.ProgressStatus.Text = $FinalStatus
    $Form.ProgressStatus.ForeColor =
        if ($Success) { [System.Drawing.Color]::FromArgb(0, 120, 50) }
        else          { [System.Drawing.Color]::FromArgb(168, 0, 0) }

    if ($Success -and $OnOpenLiveProgress -and $Form.CorrelationId) {
        $Form.OpenLiveProgressBtn.Visible = $true
        $captured = $OnOpenLiveProgress
        $Form.OpenLiveProgressBtn.Add_Click({
            try { & $captured $Form.CorrelationId } catch { }
        }.GetNewClosure())

        # Auto-open the live progress dialog so the operator sees in-flight
        # state without having to click the button first. Scheduled via
        # BeginInvoke so it fires after Complete-WipeForm returns and the
        # final paint of the parent form has settled.
        $btn = $Form.OpenLiveProgressBtn
        [void]$Form.BeginInvoke([Action]{
            try { $btn.PerformClick() } catch { }
        })
    }

    $Form.ProgressCloseBtn.Enabled = $true
    $Form.AcceptButton = $Form.ProgressCloseBtn
    $Form.CancelButton = $Form.ProgressCloseBtn
    [System.Windows.Forms.Application]::DoEvents()
}

<#
.SYNOPSIS
    Confirmation dialog that stays open and reports live execution status.
.DESCRIPTION
    Shows the same phase-1 confirmation UI as Show-WipeConfirmation, but on
    accept the form transitions into phase 2 (progress panel with status,
    log, optional live-monitor button) and invokes the caller-provided
    -OnExecute scriptblock SYNCHRONOUSLY. The scriptblock drives the form
    forward via Add-WipeFormLog / Set-WipeFormStatus / Set-WipeFormCorrelationId
    and terminates with Complete-WipeForm. The dialog blocks until the user
    clicks Chiudi after completion (or Annulla / X in phase 1).

    Returns $true if the user confirmed (and OnExecute ran),
    $false if the user cancelled the confirmation phase.
.PARAMETER OnExecute
    Scriptblock invoked with a single argument: the form instance. Must use
    the helper cmdlets above to surface progress; should call
    Complete-WipeForm at the end (success or failure).
.PARAMETER OnOpenLiveProgress
    Optional scriptblock invoked when the user clicks the "Monitora
    avanzamento live..." button after a successful completion. Receives the
    correlationId. Typical body: { param($corr) Show-WipeProgressDialog -CorrelationId $corr }.
#>
function Show-WipeConfirmationLive {
    param(
        [Parameter(Mandatory)] [string] $DeviceName,
        [Parameter(Mandatory)] [string] $EntraDeviceId,
        [Parameter(Mandatory)] [string] $IntuneDeviceId,
        [Parameter(Mandatory)] [scriptblock] $OnExecute,
        [scriptblock] $OnOpenLiveProgress
    )

    $form = Build-WipeConfirmationForm -DeviceName $DeviceName -EntraDeviceId $EntraDeviceId -IntuneDeviceId $IntuneDeviceId

    # Intercept the Esegui reset click so the form transitions to phase 2
    # INSTEAD of closing. The default DialogResult=OK on the button would
    # otherwise close the dialog before we can show progress. We clear the
    # DialogResult on click and run the caller's work synchronously.
    $form.ConfirmButton.DialogResult = [System.Windows.Forms.DialogResult]::None

    $script:wipeConfirmed = $false
    $form.ConfirmButton.Add_Click({
        $script:wipeConfirmed = $true
        Switch-WipeFormToProgress -Form $form -InitialStatus 'Avvio della richiesta di reset...'
        try {
            & $OnExecute $form
        }
        catch {
            Add-WipeFormLog -Form $form -Message ("Errore inatteso: {0}" -f $_.Exception.Message) -Kind error
            Complete-WipeForm -Form $form -Success $false -FinalStatus 'Esecuzione fallita.' -OnOpenLiveProgress $null
        }
        finally {
            # Safety net: if the caller forgot to call Complete-WipeForm,
            # at least re-enable Chiudi so the user is not stuck.
            if (-not $form.ProgressCloseBtn.Enabled) {
                Complete-WipeForm -Form $form -Success $false -FinalStatus 'Esecuzione terminata (stato sconosciuto).' -OnOpenLiveProgress $null
            }
        }
    }.GetNewClosure())

    # Stash OnOpenLiveProgress on the form so Complete-WipeForm can wire it
    # up later — keeps the caller surface area minimal.
    if ($OnOpenLiveProgress) {
        $form | Add-Member -NotePropertyName 'OnOpenLiveProgress' -NotePropertyValue $OnOpenLiveProgress -Force
    }

    $result = $form.ShowDialog()
    $form.Dispose()
    return $script:wipeConfirmed
}
