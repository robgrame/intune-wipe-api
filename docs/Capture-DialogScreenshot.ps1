#requires -Version 5.1
<#
.SYNOPSIS
    Captures a PNG screenshot of the wipe-confirmation dialog for documentation.
.DESCRIPTION
    Builds the same WinForms dialog used by client/Invoke-DeviceWipe.ps1 with
    sample data already in the "ready to confirm" state (checkbox ticked +
    "WIPE" typed), captures the form bitmap and saves it as PNG.
.EXAMPLE
    .\Capture-DialogScreenshot.ps1 -OutFile docs\dialog-screenshot.png
#>
[CmdletBinding()]
param(
    [string] $OutFile = (Join-Path $PSScriptRoot 'dialog-screenshot.png'),
    [string] $DeviceName     = 'LAPTOP-DEMO-01',
    [string] $EntraDeviceId  = '8f3b6c2e-7a91-4d2f-9b1e-5c0a4d6e8f12',
    [string] $IntuneDeviceId = '1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form               = New-Object System.Windows.Forms.Form
$form.Text          = 'Conferma reset del dispositivo'
$form.Size          = New-Object System.Drawing.Size(640, 560)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox   = $false
$form.MinimizeBox   = $false
$form.BackColor     = [System.Drawing.Color]::White
$form.TopMost       = $true
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 10)

$header = New-Object System.Windows.Forms.Panel
$header.Dock      = 'Top'
$header.Height    = 64
$header.BackColor = [System.Drawing.Color]::FromArgb(196, 30, 58)
$form.Controls.Add($header)

$hLbl = New-Object System.Windows.Forms.Label
$hLbl.Text      = [char]0x26A0 + '  Reset di fabbrica del dispositivo'
$hLbl.ForeColor = [System.Drawing.Color]::White
$hLbl.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 16, [System.Drawing.FontStyle]::Bold)
$hLbl.AutoSize  = $true
$hLbl.Location  = New-Object System.Drawing.Point(20, 16)
$header.Controls.Add($hLbl)

$warn = New-Object System.Windows.Forms.Label
$warn.Location = New-Object System.Drawing.Point(24, 80)
$warn.Size     = New-Object System.Drawing.Size(580, 130)
$e_grave = [char]0x00E8
$a_grave = [char]0x00E0
$bul     = [char]0x2022
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
$chk.Text     = 'Ho compreso che l''operazione ' + [char]0x00E8 + ' irreversibile.'
$chk.Checked  = $true
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
$tb.Text     = 'WIPE'
$form.Controls.Add($tb)

$btnOk = New-Object System.Windows.Forms.Button
$btnOk.Text      = 'Esegui reset'
$btnOk.Location  = New-Object System.Drawing.Point(360, 430)
$btnOk.Size      = New-Object System.Drawing.Size(120, 36)
$btnOk.BackColor = [System.Drawing.Color]::FromArgb(196, 30, 58)
$btnOk.ForeColor = [System.Drawing.Color]::White
$btnOk.FlatStyle = 'Flat'
$btnOk.Enabled   = $true
$form.Controls.Add($btnOk)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text     = 'Annulla'
$btnCancel.Location = New-Object System.Drawing.Point(490, 430)
$btnCancel.Size     = New-Object System.Drawing.Size(120, 36)
$btnCancel.FlatStyle = 'Flat'
$form.Controls.Add($btnCancel)

$form.Show()
$form.Activate()
$form.BringToFront()
for ($i=0; $i -lt 8; $i++) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 150
}

# Use DrawToBitmap so overlapping windows don't pollute the screenshot.
# Note: DrawToBitmap renders the client area only.
$cs    = $form.ClientSize
$cw    = [int]$cs.Width
$ch    = [int]$cs.Height
$bmp   = New-Object System.Drawing.Bitmap $cw, $ch
$form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $cw, $ch))

$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
$form.Close(); $form.Dispose()

Write-Host "Saved: $OutFile" -ForegroundColor Green
