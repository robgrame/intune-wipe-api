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
          -ApiUrl "https://func.example.net/api/actions" `
          -FunctionKey "abcd...==" `
          -CertificateIssuerLike "*MSLABS-SUBCA01*;*MSLABS-ADCS*"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ApiUrl,
    [Parameter(Mandatory = $true)] [string] $FunctionKey,
    [Parameter(Mandatory = $false)] [string] $CertificateSubjectLike,
    [Parameter(Mandatory = $false)] [string] $CertificateIssuerLike = '*MSLABS-SUBCA01*;*MSLABS-ADCS*',
    [Parameter(Mandatory = $false)] [string] $CertificateThumbprint,
    [Parameter(Mandatory = $false)] [int] $StatusPollIntervalSeconds = 5,
    [Parameter(Mandatory = $false)] [int] $StatusPollMaxMinutes = 30,
    [Parameter(Mandatory = $false)] [string] $ShortcutName = 'Migrazione a MODERN',
    # Legacy shortcut names removed during install so that upgrades from older
    # versions don't leave stale .lnk files alongside the renamed one. Keep
    # appending past names here, never removing — Win32 upgrades only run
    # Install.ps1 (Uninstall.ps1 is invoked on supersedence, not on upgrade).
    [Parameter(Mandatory = $false)] [string[]] $LegacyShortcutNames = @(
        'Reset aziendale del dispositivo'
    )
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
        'Watch-WipeStatus.ps1',
        'WipeConfirmationDialog.ps1',
        'WipeResultDialogs.ps1',
        'Show-WipeProgressDialog.ps1',
        'Launch-Wipe.ps1',
        'ActionStatusClient.psm1',
        'DeviceIdentity.psm1',
        'MdmSyncNudge.psm1',
        'version.txt'
    )
    foreach ($f in $payload) {
        $src = Join-Path $PSScriptRoot $f
        if (-not (Test-Path $src)) { throw "Missing payload file: $f" }
        Copy-Item -Path $src -Destination (Join-Path $InstallDir $f) -Force
        Write-Host "  Copied $f"
    }

    # --- Copy assets (icon set) ---------------------------------------------
    $assetsSrc = Join-Path $PSScriptRoot 'assets'
    $assetsDst = Join-Path $InstallDir 'assets'
    if (Test-Path $assetsSrc) {
        New-Item -ItemType Directory -Force -Path $assetsDst | Out-Null
        Copy-Item -Path (Join-Path $assetsSrc '*') -Destination $assetsDst -Force -Recurse
        Write-Host "  Copied assets/ ($((Get-ChildItem $assetsDst -File | Measure-Object).Count) file(s))"
    }

    # --- Persist config (ACL: SYSTEM + Administrators only) -----------------
    $cfg = [pscustomobject]@{
        ApiUrl                 = $ApiUrl
        FunctionKey            = $FunctionKey
        CertificateSubjectLike = $CertificateSubjectLike
        CertificateIssuerLike  = $CertificateIssuerLike
        CertificateThumbprint  = $CertificateThumbprint
        StatusPollIntervalSeconds = [Math]::Max(1, $StatusPollIntervalSeconds)
        StatusPollMaxMinutes      = [Math]::Max(1, $StatusPollMaxMinutes)
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
    # Prefer the custom branded icon shipped in <InstallDir>\assets\, fall
    # back to imageres.dll,229 (the Windows 10/11 "Reset this PC" icon) so
    # the shortcut never ends up with the generic PowerShell icon if the
    # asset is missing.
    $customIco      = Join-Path $InstallDir 'assets\IntuneWipeClient.ico'
    $iconLocation   = if (Test-Path $customIco) { "$customIco,0" } else { "$env:WINDIR\System32\imageres.dll,229" }
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
        # Clean up legacy shortcut names (renames across versions) so the
        # device ends up with a single, current shortcut after upgrade.
        foreach ($legacy in $LegacyShortcutNames) {
            if ([string]::IsNullOrWhiteSpace($legacy) -or $legacy -eq $ShortcutName) { continue }
            $legacyPath = Join-Path $folder ("{0}.lnk" -f $legacy)
            if (Test-Path -LiteralPath $legacyPath) {
                Remove-Item -LiteralPath $legacyPath -Force -ErrorAction SilentlyContinue
                Write-Host "  Removed legacy shortcut: $legacyPath"
            }
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

    # --- Scheduled task: StatusPoller (SYSTEM, on-demand, executable by Users) ---
    # Runs Watch-WipeStatus.ps1, which polls GET /api/actions/status/{corrId}
    # using the device cert (mTLS) every 5s by default for up to 30 min and writes
    # %ProgramData%\IntuneWipeClient\status\<corrId>.json. The user-side
    # Launch-Wipe.ps1 launches Show-WipeProgressDialog which tails that
    # file - no msg.exe / Terminal-Services popups involved.
    #
    # /Run does not pass arguments, so Watch-WipeStatus.ps1 falls back to
    # reading the correlationId from %ProgramData%\IntuneWipeClient\last-result.json
    # (freshly written by Invoke-WipeFromTask.ps1 right before triggering us).
    $PollerName = 'StatusPoller'
    $PollerFull = ($TaskFolder.TrimEnd('\')) + '\' + $PollerName
    $pollerXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Polls the wipe status endpoint for an in-flight self-service wipe. Triggered on-demand by Invoke-WipeFromTask.ps1 right after the API accepts the request.</Description>
    <Author>MSLABS IT</Author>
    <URI>$PollerFull</URI>
  </RegistrationInfo>
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>StopExisting</MultipleInstancesPolicy>
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
    <ExecutionTimeLimit>PT35M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$InstallDir\Watch-WipeStatus.ps1"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    $tmpPollerXml = Join-Path $env:TEMP ("IntuneWipePoller_{0}.xml" -f ([guid]::NewGuid()))
    [IO.File]::WriteAllText($tmpPollerXml, $pollerXml, [Text.UnicodeEncoding]::new($false,$true))
    & schtasks.exe /Create /TN $PollerFull /XML $tmpPollerXml /F | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "schtasks /Create (StatusPoller) failed (exit $LASTEXITCODE)" }
    Remove-Item -LiteralPath $tmpPollerXml -Force -ErrorAction SilentlyContinue

    $svc2  = New-Object -ComObject 'Schedule.Service'
    $svc2.Connect()
    $folder2 = $svc2.GetFolder($TaskFolder.TrimEnd('\'))
    $task2   = $folder2.GetTask($PollerName)
    $task2.SetSecurityDescriptor($sddl, 0)
    Write-Host "  Registered scheduled task: $PollerFull (SYSTEM, on-demand, executable by Users)"

    # --- Data dir for last-result.json + per-user logs + status snapshots ---
    $DataDir = Join-Path $env:ProgramData 'IntuneWipeClient'
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $DataDir 'status') | Out-Null

    # --- Event Log source (pre-create so we don't pay first-write latency) ---
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists('IntuneWipeClient')) {
            [System.Diagnostics.EventLog]::CreateEventSource('IntuneWipeClient', 'Application')
            Write-Host "  Registered Event Log source: IntuneWipeClient (Application)"
        }
    } catch {
        Write-Host ("  WARN: could not pre-create Event Log source: {0}" -f $_.Exception.Message)
    }

    Write-Host "Install completed successfully."

    # --- Self-test: prove the SYSTEM-context wrapper can actually execute --
    # Install.ps1 already runs as SYSTEM (via Intune Management Extension).
    # Invoke the wrapper with -SelfTest so it writes a marker file without
    # contacting the API. If this fails, the device blocks SYSTEM-context
    # PowerShell invocation (AppLocker / WDAC / Constrained Language mode)
    # and the wipe flow cannot work - surface the failure NOW at install time
    # instead of waiting for the user's first wipe attempt.
    try {
        $selfTestMarker = Join-Path $env:ProgramData 'IntuneWipeClient\selftest.json'
        if (Test-Path $selfTestMarker) { Remove-Item -LiteralPath $selfTestMarker -Force -ErrorAction SilentlyContinue }
        $wrapperPath = Join-Path $InstallDir 'Invoke-WipeFromTask.ps1'
        $selfTestExit = (Start-Process powershell.exe `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$wrapperPath`"",'-SelfTest') `
            -Wait -PassThru -WindowStyle Hidden).ExitCode
        Start-Sleep -Seconds 1
        if (Test-Path $selfTestMarker) {
            Write-Host ("  Self-test PASSED (exit {0}); wrapper marker written to {1}" -f $selfTestExit, $selfTestMarker)
        } else {
            Write-Host ("  Self-test FAILED: wrapper exited with {0} but produced no marker file. SYSTEM-context PowerShell invocation is likely blocked on this device (AppLocker / WDAC / Constrained Language mode). The wipe flow will NOT work." -f $selfTestExit) -ForegroundColor Yellow
            Write-Host ("  Investigate: Event Viewer -> Applications and Services Logs -> Microsoft -> Windows -> AppLocker, and check Get-AppLockerPolicy / Get-WDACConfig.")
        }
    } catch {
        Write-Host ("  Self-test ERROR: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }

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
