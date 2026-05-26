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

    $warn = New-Object System.Windows.Forms.Label
    $warn.Location = New-Object System.Drawing.Point(24, 80)
    $warn.Size     = New-Object System.Drawing.Size(580, 130)
    $warn.Text     = @"
Stai per richiedere il RESET DI FABBRICA di questo dispositivo via Microsoft Intune.

$bul L'operazione $e_grave IRREVERSIBILE: tutti i dati locali, le app, gli account e le impostazioni verranno cancellati.
$bul Il dispositivo rester$a_grave INUTILIZZABILE per circa 90 minuti durante il reset e la successiva re-provisioning.
$bul Assicurati di aver salvato tutto il lavoro in corso e di essere collegato all'alimentazione e a Internet.
"@
    $form.Controls.Add($warn)

    $info = New-Object System.Windows.Forms.GroupBox
    $info.Text     = 'Dispositivo'
    $info.Location = New-Object System.Drawing.Point(24, 215)
    $info.Size     = New-Object System.Drawing.Size(580, 100)
    $info.Font     = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.Controls.Add($info)

    $infoLbl = New-Object System.Windows.Forms.Label
    $infoLbl.Location = New-Object System.Drawing.Point(14, 22)
    $infoLbl.Size     = New-Object System.Drawing.Size(556, 70)
    $infoLbl.Font     = New-Object System.Drawing.Font('Consolas', 9)
    $infoLbl.Text     = "Nome           : $DeviceName`r`nEntra Device   : $EntraDeviceId`r`nIntune Device  : $IntuneDeviceId"
    $info.Controls.Add($infoLbl)

    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Location = New-Object System.Drawing.Point(24, 325)
    $chk.Size     = New-Object System.Drawing.Size(580, 24)
    $chk.Text     = "Ho compreso che l'operazione $e_grave irreversibile."
    $form.Controls.Add($chk)

    $typeLbl = New-Object System.Windows.Forms.Label
    $typeLbl.Location = New-Object System.Drawing.Point(24, 355)
    $typeLbl.Size     = New-Object System.Drawing.Size(580, 20)
    $typeLbl.Text     = 'Per confermare, digita la parola WIPE in maiuscolo:'
    $form.Controls.Add($typeLbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(24, 378)
    $tb.Size     = New-Object System.Drawing.Size(200, 28)
    $tb.Font     = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold)
    $tb.CharacterCasing = 'Upper'
    $form.Controls.Add($tb)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text      = 'Esegui reset'
    $btnOk.Location  = New-Object System.Drawing.Point(360, 470)
    $btnOk.Size      = New-Object System.Drawing.Size(120, 36)
    $btnOk.BackColor = [System.Drawing.Color]::FromArgb(196, 30, 58)
    $btnOk.ForeColor = [System.Drawing.Color]::White
    $btnOk.FlatStyle = 'Flat'
    $btnOk.Enabled   = $false
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = 'Annulla'
    $btnCancel.Location = New-Object System.Drawing.Point(490, 470)
    $btnCancel.Size     = New-Object System.Drawing.Size(120, 36)
    $btnCancel.FlatStyle = 'Flat'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $null
    $form.CancelButton = $btnCancel

    $updateState = {
        $btnOk.Enabled = ($chk.Checked -and $tb.Text -ceq 'WIPE')
    }.GetNewClosure()
    $chk.Add_CheckedChanged($updateState)
    $tb.Add_TextChanged($updateState)

    # Expose key controls for callers (e.g. screenshot script that
    # needs to pre-fill the dialog into the "ready" state).
    $form | Add-Member -NotePropertyName 'AcceptCheckBox'  -NotePropertyValue $chk    -Force
    $form | Add-Member -NotePropertyName 'ConfirmTextBox'  -NotePropertyValue $tb     -Force
    $form | Add-Member -NotePropertyName 'ConfirmButton'   -NotePropertyValue $btnOk  -Force

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
