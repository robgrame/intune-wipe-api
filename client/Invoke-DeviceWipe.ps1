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
    throw "Internal error: WipeConfirmationDialog.ps1 not loaded."
}

#endregion

# Load the shared dialog builder (overrides the placeholder above so the
# UI definition has a single source of truth, also reused by
# docs/Capture-DialogScreenshot.ps1).
. (Join-Path $PSScriptRoot 'WipeConfirmationDialog.ps1')

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
