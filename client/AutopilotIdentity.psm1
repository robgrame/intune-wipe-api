<#
.SYNOPSIS
    Windows Autopilot device-identity helpers for the self-registration client.

.DESCRIPTION
    Collects the data Microsoft Graph needs to import a device into Windows
    Autopilot (importedWindowsAutopilotDeviceIdentities): the 4K hardware hash
    (DeviceHardwareData), the BIOS serial number, and — when present — the OEM
    Windows product key. This is the client-side half of the autopilot-register
    capability: the hardware hash is NOT available server-side, so it must be
    gathered on the device, exactly like the wipe flow gathers device identity.

    All CIM/registry accesses go through cmdlets with string-typed parameters
    (Get-CimInstance -Namespace/-ClassName, Get-ItemProperty) so they can be
    mocked by Pester — see client\tests\AutopilotIdentity.Tests.ps1.

.NOTES
    PS 5.1 compatible. No external dependencies. Intended to run in SYSTEM
    context (the MDM_DevDetail_Ext01 class is readable by SYSTEM).
#>

Set-StrictMode -Version Latest

function Invoke-CimQuery {
    <#
    .SYNOPSIS
        Internal thin wrapper around Get-CimInstance returning the first instance.
    .DESCRIPTION
        Centralises every CIM access so it can be mocked in one place by Pester
        (the underlying Get-CimInstance cmdlet only exists on Windows). All
        parameters are string-typed for clean mocking — see the repository's
        "extract calls into wrapper functions for testability" convention.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClassName,
        [string]$Namespace,
        [string]$Filter
    )
    $params = @{ ClassName = $ClassName; ErrorAction = 'SilentlyContinue' }
    if ($Namespace) { $params['Namespace'] = $Namespace }
    if ($Filter)    { $params['Filter']    = $Filter }
    return (Get-CimInstance @params | Select-Object -First 1)
}

function Get-AutopilotHardwareHash {
    <#
    .SYNOPSIS
        Returns the base64-encoded 4K Autopilot hardware hash (DeviceHardwareData).
    .DESCRIPTION
        Reads the MDM_DevDetail_Ext01 CIM class in the root\cimv2\mdm\dmmap
        namespace — the same source used by Get-WindowsAutopilotInfo. Throws when
        the class/property is unavailable (e.g. not running as SYSTEM, or an
        unsupported OS).
    .OUTPUTS
        [string] base64 hardware hash.
    #>
    [CmdletBinding()]
    param()

    $inst = Invoke-CimQuery -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_DevDetail_Ext01' `
                -Filter "InstanceID='Ext' AND ParentID='./DevDetail'"
    if (-not $inst) {
        $inst = Invoke-CimQuery -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_DevDetail_Ext01'
    }
    if (-not $inst -or -not ($inst.PSObject.Properties.Name -contains 'DeviceHardwareData') -or -not $inst.DeviceHardwareData) {
        throw "Autopilot hardware hash not available (DeviceHardwareData). Run as SYSTEM on a supported Windows build."
    }
    return [string]$inst.DeviceHardwareData
}

function Get-DeviceSerialNumber {
    <#
    .SYNOPSIS
        Returns the device BIOS serial number (used by Graph to dedupe imports).
    .OUTPUTS
        [string] serial number, or '' when unavailable.
    #>
    [CmdletBinding()]
    param()

    $bios = Invoke-CimQuery -ClassName 'Win32_BIOS'
    if ($bios -and ($bios.PSObject.Properties.Name -contains 'SerialNumber') -and $bios.SerialNumber) {
        return ([string]$bios.SerialNumber).Trim()
    }
    return ''
}

function Get-WindowsProductKey {
    <#
    .SYNOPSIS
        Best-effort lookup of the OEM Windows product key (OA3xOriginalProductKey).
    .OUTPUTS
        [string] product key, or '' when unavailable.
    #>
    [CmdletBinding()]
    param()

    $slp = Invoke-CimQuery -ClassName 'SoftwareLicensingService'
    if ($slp -and ($slp.PSObject.Properties.Name -contains 'OA3xOriginalProductKey') -and $slp.OA3xOriginalProductKey) {
        return ([string]$slp.OA3xOriginalProductKey).Trim()
    }
    return ''
}

function Get-AutopilotIdentityPayload {
    <#
    .SYNOPSIS
        Builds the `autopilot` payload object POSTed alongside an
        autopilot-register action request.
    .DESCRIPTION
        Gathers hardware hash (required) + serial number + product key, and
        stamps the optional GroupTag / AssignedUserPrincipalName supplied by the
        caller. Only non-empty values are included so the JSON body stays minimal.
    .OUTPUTS
        [hashtable] matching the server AutopilotIdentityPayload contract
        (hardwareHash, serialNumber, productKey, groupTag, assignedUserPrincipalName).
    #>
    [CmdletBinding()]
    param(
        [string]$GroupTag,
        [string]$AssignedUserPrincipalName
    )

    $payload = @{ hardwareHash = (Get-AutopilotHardwareHash) }

    $serial = Get-DeviceSerialNumber
    if ($serial) { $payload['serialNumber'] = $serial }

    $productKey = Get-WindowsProductKey
    if ($productKey) { $payload['productKey'] = $productKey }

    if ($GroupTag) { $payload['groupTag'] = $GroupTag }
    if ($AssignedUserPrincipalName) { $payload['assignedUserPrincipalName'] = $AssignedUserPrincipalName }

    return $payload
}

Export-ModuleMember -Function `
    Get-AutopilotHardwareHash, `
    Get-DeviceSerialNumber, `
    Get-WindowsProductKey, `
    Get-AutopilotIdentityPayload
