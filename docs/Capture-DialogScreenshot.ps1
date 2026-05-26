#requires -Version 5.1
<#
.SYNOPSIS
    Captures a PNG screenshot of the wipe-confirmation dialog for documentation.
.DESCRIPTION
    Loads the shared dialog builder from ..\client\WipeConfirmationDialog.ps1
    (single source of truth, same UI used by the production client), opens
    the form with sample data already in the "ready to confirm" state
    (checkbox ticked + "WIPE" typed), captures the form's client area via
    DrawToBitmap (immune to overlapping windows) and saves it as PNG.

    Run with -STA when invoking from powershell.exe.
#>
[CmdletBinding()]
param(
    [string] $OutFile = (Join-Path $PSScriptRoot 'dialog-screenshot.png'),
    [string] $DeviceName     = 'LAPTOP-DEMO-01',
    [string] $EntraDeviceId  = '8f3b6c2e-7a91-4d2f-9b1e-5c0a4d6e8f12',
    [string] $IntuneDeviceId = '1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\client\WipeConfirmationDialog.ps1')

$form = Build-WipeConfirmationForm `
    -DeviceName $DeviceName -EntraDeviceId $EntraDeviceId -IntuneDeviceId $IntuneDeviceId

# Pre-fill into the "ready to confirm" state so the screenshot shows the
# enabled red "Esegui reset" button.
$form.AcceptCheckBox.Checked = $true
$form.ConfirmTextBox.Text    = 'WIPE'
$form.ConfirmButton.Enabled  = $true

$form.Show()
$form.Activate()
$form.BringToFront()
for ($i=0; $i -lt 8; $i++) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 150
}

$cs  = $form.ClientSize
$cw  = [int]$cs.Width
$ch  = [int]$cs.Height
$bmp = New-Object System.Drawing.Bitmap $cw, $ch
$form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $cw, $ch))

$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
$form.Close(); $form.Dispose()

Write-Host "Saved: $OutFile" -ForegroundColor Green
