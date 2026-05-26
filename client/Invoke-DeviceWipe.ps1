#requires -Version 5.1
<#
.SYNOPSIS
    Self-service Intune wipe client with confirmation UI.
.DESCRIPTION
    Collects EntraDeviceId / IntuneDeviceId / device name, shows an elegant
    WinForms confirmation dialog (irreversibility + ~90 min downtime warning,
    typed "WIPE" confirmation + checkbox), then calls the wipe API
    authenticating with the Intune-issued device certificate.
.PARAMETER ApiUrl
    Full URL to the wipe endpoint, e.g. https://func.example.net/api/wipe
.PARAMETER CertificateThumbprint
    Thumbprint of the client certificate in Cert:\LocalMachine\My (or CurrentUser\My).
.PARAMETER CertificateSubjectLike
    Alternative: subject wildcard, e.g. "*Intune MDM Device CA*".
.PARAMETER FunctionKey
    Function key for the Azure Function (header x-functions-key).
.PARAMETER Silent
    Skip the UI (use only for unattended testing).
.NOTES
    The client sends two anti-replay headers required by the API:
      X-Request-Timestamp : current UTC time in ISO-8601 (server tolerates ±5 min by default)
      X-Request-Nonce     : a fresh GUID per request
.EXAMPLE
    .\Invoke-DeviceWipe.ps1 -ApiUrl https://func.example.net/api/wipe `
        -CertificateSubjectLike '*Intune MDM Device CA*' -FunctionKey '...'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $ApiUrl,
    [string] $CertificateThumbprint,
    [string] $CertificateSubjectLike,
    [Parameter(Mandatory = $false)] [string] $FunctionKey,
    [switch] $Silent,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not $DryRun) {
    if (-not $ApiUrl)      { throw "-ApiUrl is required (unless -DryRun)." }
    if (-not $FunctionKey) { throw "-FunctionKey is required (unless -DryRun)." }
}

#region helpers

function Get-EntraDeviceId {
    $out = & dsregcmd /status 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { throw "dsregcmd failed" }
    $line = $out | Where-Object { $_ -match '^\s*DeviceId\s*:\s*([0-9a-fA-F-]{36})' } | Select-Object -First 1
    if ($line -match '([0-9a-fA-F-]{36})') { return $Matches[1] }
    throw "EntraDeviceId not found (device not Entra joined/registered?)"
}

function Get-IntuneDeviceId {
    $root = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (-not (Test-Path $root)) { throw "Enrollments key not found" }
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
    throw "Intune enrollment not found (device not enrolled in Intune?)"
}

function Get-ClientCertificate {
    param([string]$Thumb, [string]$SubjectLike)
    # Prefer LocalMachine\My (Intune SCEP/PKCS device certs typically land there in machine context).
    foreach ($s in @('Cert:\LocalMachine\My','Cert:\CurrentUser\My')) {
        $certs = Get-ChildItem $s -ErrorAction SilentlyContinue |
                 Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) -and $_.NotBefore -le (Get-Date) }
        # Keep only certs that have Client Authentication EKU (1.3.6.1.5.5.7.3.2)
        $certs = $certs | Where-Object {
            $ekus = $_.EnhancedKeyUsageList
            (-not $ekus) -or ($ekus | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.2' })
        }
        if ($Thumb) {
            $c = $certs | Where-Object Thumbprint -eq $Thumb.ToUpper() | Select-Object -First 1
        } elseif ($SubjectLike) {
            $c = $certs | Where-Object { $_.Subject -like $SubjectLike -or $_.Issuer -like $SubjectLike } |
                 Sort-Object NotAfter -Descending | Select-Object -First 1
        }
        if ($c) { return $c }
    }
    throw "Client certificate not found (with Client Authentication EKU and private key)"
}

function Show-WipeConfirmation {
    param([string]$DeviceName, [string]$EntraDeviceId, [string]$IntuneDeviceId)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form               = New-Object System.Windows.Forms.Form
    $form.Text          = 'Conferma reset del dispositivo'
    $form.Size          = New-Object System.Drawing.Size(640, 520)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox   = $false
    $form.MinimizeBox   = $false
    $form.BackColor     = [System.Drawing.Color]::White
    $form.TopMost       = $true
    $form.Font          = New-Object System.Drawing.Font('Segoe UI', 10)

    # Header bar
    $header = New-Object System.Windows.Forms.Panel
    $header.Dock      = 'Top'
    $header.Height    = 64
    $header.BackColor = [System.Drawing.Color]::FromArgb(196, 30, 58)
    $form.Controls.Add($header)

    $hLbl = New-Object System.Windows.Forms.Label
    $hLbl.Text      = '⚠  Reset di fabbrica del dispositivo'
    $hLbl.ForeColor = [System.Drawing.Color]::White
    $hLbl.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 16, [System.Drawing.FontStyle]::Bold)
    $hLbl.AutoSize  = $true
    $hLbl.Location  = New-Object System.Drawing.Point(20, 16)
    $header.Controls.Add($hLbl)

    # Warning body
    $warn = New-Object System.Windows.Forms.Label
    $warn.Location = New-Object System.Drawing.Point(24, 80)
    $warn.Size     = New-Object System.Drawing.Size(580, 130)
    $warn.Text     = @"
Stai per richiedere il RESET DI FABBRICA di questo dispositivo via Microsoft Intune.

• L'operazione è IRREVERSIBILE: tutti i dati locali, le app, gli account e le impostazioni verranno cancellati.
• Il dispositivo resterà INUTILIZZABILE per circa 90 minuti durante il reset e la successiva re-provisioning.
• Assicurati di aver salvato tutto il lavoro in corso e di essere collegato all'alimentazione e a Internet.
"@
    $form.Controls.Add($warn)

    # Device info box
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

    # Checkbox
    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Location = New-Object System.Drawing.Point(24, 325)
    $chk.Size     = New-Object System.Drawing.Size(580, 24)
    $chk.Text     = 'Ho compreso che l''operazione è irreversibile.'
    $form.Controls.Add($chk)

    # Typed confirmation
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

    # Buttons
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text      = 'Esegui reset'
    $btnOk.Location  = New-Object System.Drawing.Point(360, 430)
    $btnOk.Size      = New-Object System.Drawing.Size(120, 36)
    $btnOk.BackColor = [System.Drawing.Color]::FromArgb(196, 30, 58)
    $btnOk.ForeColor = [System.Drawing.Color]::White
    $btnOk.FlatStyle = 'Flat'
    $btnOk.Enabled   = $false
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = 'Annulla'
    $btnCancel.Location = New-Object System.Drawing.Point(490, 430)
    $btnCancel.Size     = New-Object System.Drawing.Size(120, 36)
    $btnCancel.FlatStyle = 'Flat'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $null
    $form.CancelButton = $btnCancel

    $updateState = {
        $btnOk.Enabled = ($chk.Checked -and $tb.Text -ceq 'WIPE')
    }
    $chk.Add_CheckedChanged($updateState)
    $tb.Add_TextChanged($updateState)

    $result = $form.ShowDialog()
    $form.Dispose()
    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

#endregion

Write-Host 'Collecting device identity...' -ForegroundColor Cyan
if ($DryRun) {
    $deviceName = 'LAPTOP-DEMO-01'
    $entraId    = '8f3b6c2e-7a91-4d2f-9b1e-5c0a4d6e8f12'
    $intuneId   = '1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d'
} else {
    $deviceName = $env:COMPUTERNAME
    $entraId    = Get-EntraDeviceId
    $intuneId   = Get-IntuneDeviceId
}
Write-Host ("  Device      : {0}" -f $deviceName)
Write-Host ("  EntraDevId  : {0}" -f $entraId)
Write-Host ("  IntuneDevId : {0}" -f $intuneId)

if (-not $Silent) {
    $confirmed = Show-WipeConfirmation -DeviceName $deviceName -EntraDeviceId $entraId -IntuneDeviceId $intuneId
    if (-not $confirmed) {
        Write-Host 'Operazione annullata dall''utente.' -ForegroundColor Yellow
        return
    }
}

if ($DryRun) {
    Write-Host 'DryRun: skipping certificate selection and API call.' -ForegroundColor Yellow
    return
}

$cert = Get-ClientCertificate -Thumb $CertificateThumbprint -SubjectLike $CertificateSubjectLike
Write-Host ("Using cert: {0} (thumb {1})" -f $cert.Subject, $cert.Thumbprint) -ForegroundColor Cyan

$body = @{
    deviceName     = $deviceName
    entraDeviceId  = $entraId
    intuneDeviceId = $intuneId
} | ConvertTo-Json -Compress

$headers = @{
    'x-functions-key'     = $FunctionKey
    'Content-Type'        = 'application/json'
    'X-Request-Timestamp' = (Get-Date).ToUniversalTime().ToString('o')
    'X-Request-Nonce'     = [Guid]::NewGuid().ToString()
}

try {
    $resp = Invoke-RestMethod -Method Post -Uri $ApiUrl -Body $body `
        -Headers $headers -Certificate $cert -TimeoutSec 60
    Write-Host 'Richiesta accettata:' -ForegroundColor Green
    $resp | Format-List
    if (-not $Silent) {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        [System.Windows.Forms.MessageBox]::Show(
            ("Richiesta di reset accettata.`r`n`r`nCorrelation Id: {0}`r`n`r`nIl dispositivo verra' reimpostato a breve e restera' inutilizzabile per circa 90 minuti." -f $resp.correlationId),
            'Reset richiesto',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
}
catch {
    Write-Host 'Richiesta FALLITA:' -ForegroundColor Red
    if ($_.Exception.Response) {
        try {
            $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())
            Write-Host $sr.ReadToEnd()
        } catch { }
    }
    throw
}
