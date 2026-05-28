#requires -Version 5.1
<#
.SYNOPSIS
    Installs the Intune Wipe self-service client on the local machine.
.DESCRIPTION
    Copies the wipe client scripts to %ProgramFiles%\IntuneWipeClient,
    persists the API endpoint + function key in a per-machine config file
    (ACL'd so only SYSTEM / Administrators can read it), creates a Start
    Menu shortcut for the end user, and writes a detection registry key
    Intune Win32 detection can probe.

    Intended to be invoked by the Intune Win32 install command, e.g.:

      powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 `
          -ApiUrl "https://func.example.net/api/wipe" `
          -FunctionKey "abcd...==" `
          -CertificateIssuerLike "*MSLABS-SUBCA01*"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ApiUrl,
    [Parameter(Mandatory = $true)] [string] $FunctionKey,
    [Parameter(Mandatory = $false)] [string] $CertificateSubjectLike,
    [Parameter(Mandatory = $false)] [string] $CertificateIssuerLike = '*MSLABS-SUBCA01*',
    [Parameter(Mandatory = $false)] [string] $CertificateThumbprint,
    [Parameter(Mandatory = $false)] [string] $ShortcutName = 'Reset aziendale del dispositivo'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$InstallDir   = Join-Path $env:ProgramFiles 'IntuneWipeClient'
$LogDir       = Join-Path $env:ProgramData  'IntuneWipeClient\Logs'
$ConfigPath   = Join-Path $InstallDir       'config.json'
$RegPath      = 'HKLM:\SOFTWARE\Contoso\IntuneWipeClient'
$ProductCode  = '{2C0D7E3A-7A19-4B0B-8F7E-9E0F2A4D1B22}'  # stable GUID for detection
$Version      = (Get-Content (Join-Path $PSScriptRoot 'version.txt') -ErrorAction SilentlyContinue) -as [string]
if (-not $Version) { $Version = '1.0.0' }
$Version = $Version.Trim()

# --- Logging ----------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("Install_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $LogFile -Force | Out-Null
Write-Host ("=== IntuneWipeClient {0} install ===" -f $Version)

try {
    # --- Pre-flight ---------------------------------------------------------
    if (-not [Uri]::IsWellFormedUriString($ApiUrl, [UriKind]::Absolute)) {
        throw "ApiUrl is not a well-formed absolute URI: $ApiUrl"
    }
    if ($FunctionKey.Length -lt 20) {
        throw "FunctionKey looks too short to be valid."
    }

    # --- Copy payload -------------------------------------------------------
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $payload = @(
        'Invoke-DeviceWipe.ps1',
        'WipeConfirmationDialog.ps1',
        'Launch-Wipe.ps1',
        'version.txt'
    )
    foreach ($f in $payload) {
        $src = Join-Path $PSScriptRoot $f
        if (-not (Test-Path $src)) { throw "Missing payload file: $f" }
        Copy-Item -Path $src -Destination (Join-Path $InstallDir $f) -Force
        Write-Host "  Copied $f"
    }

    # --- Persist config (ACL: SYSTEM + Administrators only) -----------------
    $cfg = [pscustomobject]@{
        ApiUrl                 = $ApiUrl
        FunctionKey            = $FunctionKey
        CertificateSubjectLike = $CertificateSubjectLike
        CertificateIssuerLike  = $CertificateIssuerLike
        CertificateThumbprint  = $CertificateThumbprint
        InstalledVersion       = $Version
        InstalledAtUtc         = (Get-Date).ToUniversalTime().ToString('o')
    }
    $cfg | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding utf8

    $acl = Get-Acl -LiteralPath $ConfigPath
    $acl.SetAccessRuleProtection($true, $false)  # disable inheritance, drop inherited rules
    # Remove all existing explicit rules first.
    foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
    foreach ($sid in 'S-1-5-18','S-1-5-32-544') {
        $idRef = (New-Object Security.Principal.SecurityIdentifier $sid).Translate([Security.Principal.NTAccount])
        $rule  = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $idRef, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([Security.Principal.NTAccount]))
    Set-Acl -LiteralPath $ConfigPath -AclObject $acl
    Write-Host "  Wrote config.json (restricted ACL)"

    # --- Start Menu shortcut (All Users) ------------------------------------
    $allUsersStart = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $lnkPath = Join-Path $allUsersStart ("{0}.lnk" -f $ShortcutName)
    $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut($lnkPath)
    $lnk.TargetPath       = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\Launch-Wipe.ps1`""
    $lnk.WorkingDirectory = $InstallDir
    $lnk.IconLocation     = "$env:WINDIR\System32\shell32.dll,238"  # red shield-ish
    $lnk.Description      = "Esegue il reset aziendale di questo dispositivo (richiede conferma)."
    $lnk.Save()
    Write-Host "  Created shortcut: $lnkPath"

    # --- Detection registry key --------------------------------------------
    New-Item -Path $RegPath -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name 'Version'      -Value $Version     -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name 'ProductCode'  -Value $ProductCode -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name 'InstallDir'   -Value $InstallDir  -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $RegPath -Name 'InstalledOn'  -Value ((Get-Date).ToString('s')) -PropertyType String -Force | Out-Null
    Write-Host "  Registry: $RegPath  (Version=$Version)"

    Write-Host "Install completed successfully."
    exit 0
}
catch {
    Write-Host ("ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    exit 1
}
finally {
    Stop-Transcript | Out-Null
}
