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

# $env:ProgramFiles returns "C:\Program Files (x86)" inside a 32-bit process
# (Intune Management Extension runs Win32 install scripts under 32-bit PS).
# $env:ProgramW6432 is always the native 64-bit Program Files path on both
# 32-bit and 64-bit processes, so we pin to it for consistency.
$ProgramFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }

$InstallDir   = Join-Path $ProgramFiles64 'IntuneWipeClient'
$LogDir       = Join-Path $env:ProgramData  'IntuneWipeClient\Logs'
$ConfigPath   = Join-Path $InstallDir       'config.json'
$RegPath      = 'HKLM:\SOFTWARE\MSLABS\IntuneWipeClient'
$RegSubKey    = 'SOFTWARE\MSLABS\IntuneWipeClient'  # used via Registry64 view to bypass WOW6432Node redirection
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
        'Invoke-WipeFromTask.ps1',
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

    # --- Shortcuts (Start Menu + Public Desktop, All Users) -----------------
    # Use a "speaking" icon: imageres.dll,229 = the "Reset this PC" icon on
    # Windows 10/11. Falls back gracefully if the icon index isn't present.
    $iconLocation   = "$env:WINDIR\System32\imageres.dll,229"
    $shortcutTarget = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcutArgs   = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\Launch-Wipe.ps1`""
    $shortcutDesc   = "Esegue il reset aziendale di questo dispositivo (richiede conferma)."
    $wsh = New-Object -ComObject WScript.Shell

    $allUsersStart  = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $publicDesktop  = Join-Path $env:PUBLIC      'Desktop'
    foreach ($folder in @($allUsersStart, $publicDesktop)) {
        if (-not (Test-Path -LiteralPath $folder)) {
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
        }
        $lnkPath = Join-Path $folder ("{0}.lnk" -f $ShortcutName)
        $lnk = $wsh.CreateShortcut($lnkPath)
        $lnk.TargetPath       = $shortcutTarget
        $lnk.Arguments        = $shortcutArgs
        $lnk.WorkingDirectory = $InstallDir
        $lnk.IconLocation     = $iconLocation
        $lnk.Description      = $shortcutDesc
        $lnk.Save()
        Write-Host "  Created shortcut: $lnkPath"
    }

    # --- Detection registry key (write to 64-bit hive explicitly) ----------
    # Intune Management Extension launches Win32 install scripts under
    # 32-bit PowerShell, which redirects HKLM\SOFTWARE writes into
    # HKLM\SOFTWARE\WOW6432Node. Detection often runs in 64-bit context and
    # would miss the redirected key. Use Registry64 view to always write to
    # the native 64-bit hive so both views can find it.
    $base64 = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
    $key64 = $base64.CreateSubKey($RegSubKey, $true)
    $key64.SetValue('Version',     $Version,     [Microsoft.Win32.RegistryValueKind]::String)
    $key64.SetValue('ProductCode', $ProductCode, [Microsoft.Win32.RegistryValueKind]::String)
    $key64.SetValue('InstallDir',  $InstallDir,  [Microsoft.Win32.RegistryValueKind]::String)
    $key64.SetValue('InstalledOn', (Get-Date).ToString('s'), [Microsoft.Win32.RegistryValueKind]::String)
    $key64.Close(); $base64.Close()
    Write-Host "  Registry (64-bit hive): $RegPath  (Version=$Version)"

    # --- Scheduled task (SYSTEM, on-demand, executable by Users) ------------
    # The end-user launcher (Launch-Wipe.ps1) runs in user context and
    # cannot use the device certificate's private key (ACL'd to SYSTEM).
    # This scheduled task runs as SYSTEM so Invoke-WipeFromTask.ps1 can do
    # the TLS client-auth call; the launcher only triggers it on demand.
    $TaskFolder  = '\IntuneWipeClient\'
    $TaskName    = 'InvokeWipe'
    $TaskFull    = ($TaskFolder.TrimEnd('\')) + '\' + $TaskName

    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Self-service Intune device wipe (runs as SYSTEM, triggered on-demand by Launch-Wipe.ps1).</Description>
    <Author>MSLABS IT</Author>
    <URI>$TaskFull</URI>
  </RegistrationInfo>
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$InstallDir\Invoke-WipeFromTask.ps1"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    $tmpXml = Join-Path $env:TEMP ("IntuneWipeTask_{0}.xml" -f ([guid]::NewGuid()))
    [IO.File]::WriteAllText($tmpXml, $taskXml, [Text.UnicodeEncoding]::new($false,$true))
    & schtasks.exe /Create /TN $TaskFull /XML $tmpXml /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks /Create failed (exit $LASTEXITCODE)" }
    Remove-Item -LiteralPath $tmpXml -Force -ErrorAction SilentlyContinue

    # Allow BUILTIN\Users to read AND execute the task.
    #   FA = Full Access (kept for SYSTEM and BUILTIN\Administrators)
    #   GR|GX = Generic Read + Generic Execute for BUILTIN\Users
    $sddl = 'D:P(A;;FA;;;BA)(A;;FA;;;SY)(A;;GRGX;;;BU)'
    $svc  = New-Object -ComObject 'Schedule.Service'
    $svc.Connect()
    $folder = $svc.GetFolder($TaskFolder.TrimEnd('\'))
    $task   = $folder.GetTask($TaskName)
    $task.SetSecurityDescriptor($sddl, 0)
    Write-Host "  Registered scheduled task: $TaskFull (SYSTEM, on-demand, executable by Users)"

    # --- Data dir for last-result.json + per-user logs --------------------
    $DataDir = Join-Path $env:ProgramData 'IntuneWipeClient'
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

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
