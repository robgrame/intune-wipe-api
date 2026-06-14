#requires -Version 5.1
<#
.SYNOPSIS
    Captures PNG screenshots of the wipe-client dialogs for documentation.
.DESCRIPTION
    Loads the shared dialog builders from ..\client\WipeConfirmationDialog.ps1
    and ..\client\WipeResultDialogs.ps1 (single source of truth, same UI
    used by the production client) and captures up to four frames:

      dialog-screenshot.png      Phase 1 — confirmation (checkbox + "WIPE")
      dialog-progress.png        Phase 2 — live execution progress
      dialog-result-success.png  Result dialog — wipe accepted by Intune
      dialog-result-error.png    Result dialog — API / certificate error

    Each PNG is written to $OutDir (defaults to the script's own folder).

    Run with -STA when invoking from powershell.exe:
        powershell.exe -STA -File docs\Capture-DialogScreenshot.ps1

    To regenerate only a specific frame pass -Frame:
        powershell.exe -STA -File docs\Capture-DialogScreenshot.ps1 -Frame phase1
#>
[CmdletBinding()]
param(
    [string] $OutDir      = $PSScriptRoot,
    [ValidateSet('all','phase1','phase2','success','error')]
    [string] $Frame       = 'all',
    [string] $DeviceName     = 'LAPTOP-DEMO-01',
    [string] $EntraDeviceId  = '8f3b6c2e-7a91-4d2f-9b1e-5c0a4d6e8f12',
    [string] $IntuneDeviceId = '1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d',
    [string] $CorrelationId  = 'a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d'
)

$ErrorActionPreference = 'Stop'

$clientDir = Join-Path $PSScriptRoot '..\client'
. (Join-Path $clientDir 'WipeConfirmationDialog.ps1')
. (Join-Path $clientDir 'WipeResultDialogs.ps1')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Save-FormBitmap {
    param(
        [System.Windows.Forms.Form] $Form,
        [string] $OutFile
    )
    $Form.Show()
    $Form.Activate()
    $Form.BringToFront()
    for ($i = 0; $i -lt 8; $i++) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 150
    }
    $cs  = $Form.ClientSize
    $bmp = New-Object System.Drawing.Bitmap ([int]$cs.Width), ([int]$cs.Height)
    $Form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, ([int]$cs.Width), ([int]$cs.Height)))
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $Form.Close(); $Form.Dispose()
    Write-Host "Saved: $OutFile" -ForegroundColor Green
}

# ---- Phase 1 — confirmation ------------------------------------------------
if ($Frame -in 'all','phase1') {
    $f = Build-WipeConfirmationForm -DeviceName $DeviceName `
        -EntraDeviceId $EntraDeviceId -IntuneDeviceId $IntuneDeviceId
    $f.AcceptCheckBox.Checked = $true
    $f.ConfirmTextBox.Text    = 'WIPE'
    $f.ConfirmButton.Enabled  = $true
    Save-FormBitmap -Form $f -OutFile (Join-Path $OutDir 'dialog-screenshot.png')
}

# ---- Phase 2 — live execution progress -------------------------------------
if ($Frame -in 'all','phase2') {
    $f = Build-WipeConfirmationForm -DeviceName $DeviceName `
        -EntraDeviceId $EntraDeviceId -IntuneDeviceId $IntuneDeviceId
    # Switch to progress panel (mimics Switch-WipeFormToProgress)
    $f.Phase1Panel.Visible = $false
    $f.Phase2Panel.Visible = $true
    $f.Text = 'Esecuzione richiesta di reset'
    $f.ProgressStatus.Text      = 'Comando wipe inoltrato a Intune'
    $f.ProgressStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
    $f.ProgressCorrLabel.Text   = "CorrelationId : $CorrelationId"

    # Populate the log (uses direct RichTextBox manipulation — no DoEvents required)
    $rt = $f.ProgressLog
    $stamp = '10:32:15'
    foreach ($entry in @(
        @{ t = '10:32:14'; msg = 'Avvio della richiesta di reset...';               color = [System.Drawing.Color]::FromArgb(20,20,20) }
        @{ t = '10:32:14'; msg = 'Identita dispositivo raccolta.';                  color = [System.Drawing.Color]::FromArgb(0,120,50)  }
        @{ t = '10:32:14'; msg = "Certificato selezionato: CN=$DeviceName";         color = [System.Drawing.Color]::FromArgb(80,80,80)  }
        @{ t = '10:32:15'; msg = 'Invio richiesta POST /api/actions...';            color = [System.Drawing.Color]::FromArgb(20,20,20)  }
        @{ t = '10:32:15'; msg = "202 Accepted — correlationId=$CorrelationId";    color = [System.Drawing.Color]::FromArgb(0,120,50)  }
        @{ t = '10:32:15'; msg = 'Monitoraggio stato wipe in corso (ogni 5s)...';  color = [System.Drawing.Color]::FromArgb(80,80,80)  }
    )) {
        $rt.SelectionStart  = $rt.TextLength
        $rt.SelectionLength = 0
        $rt.SelectionColor  = $entry.color
        $rt.AppendText(("[{0}] {1}{2}" -f $entry.t, $entry.msg, [Environment]::NewLine))
    }
    $rt.SelectionColor = [System.Drawing.Color]::FromArgb(20,20,20)
    $rt.SelectionStart = $rt.TextLength

    Save-FormBitmap -Form $f -OutFile (Join-Path $OutDir 'dialog-progress.png')
}

# ---- Result — success -------------------------------------------------------
if ($Frame -in 'all','success') {
    $mockResult = [pscustomobject]@{
        ok            = $true
        status        = 'pending'
        statusMessage = 'Wipe command accepted by Intune — waiting for device response.'
        correlationId = $CorrelationId
        certThumbprint = 'A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2'
        ts            = (Get-Date).ToUniversalTime().ToString('o')
        deviceName    = $DeviceName
        entraDeviceId = $EntraDeviceId
        intuneDeviceId = $IntuneDeviceId
    }
    $f = Show-WipeSuccessDialog -Result $mockResult -NoModal
    if ($f) { Save-FormBitmap -Form $f -OutFile (Join-Path $OutDir 'dialog-result-success.png') }
    else    { Write-Warning 'Show-WipeSuccessDialog does not support -NoModal; skipping success frame.' }
}

# ---- Result — error ---------------------------------------------------------
if ($Frame -in 'all','error') {
    $mockResult = [pscustomobject]@{
        ok            = $false
        httpStatus    = 403
        error         = 'Device non appartenente al gruppo di sicurezza autorizzato.'
        correlationId = ''
        certThumbprint = 'A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2'
        ts            = (Get-Date).ToUniversalTime().ToString('o')
        deviceName    = $DeviceName
        entraDeviceId = $EntraDeviceId
        intuneDeviceId = $IntuneDeviceId
    }
    $f = Show-WipeErrorDialog -Result $mockResult -NoModal
    if ($f) { Save-FormBitmap -Form $f -OutFile (Join-Path $OutDir 'dialog-result-error.png') }
    else    { Write-Warning 'Show-WipeErrorDialog does not support -NoModal; skipping error frame.' }
}
