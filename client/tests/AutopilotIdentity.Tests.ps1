#requires -Version 5.1
<#
.SYNOPSIS
    Pester v5 unit tests for client\AutopilotIdentity.psm1.

.DESCRIPTION
    All CIM accesses (MDM_DevDetail_Ext01, Win32_BIOS, SoftwareLicensingService)
    are mocked via Pester so the tests are hermetic and run on any host — no
    Autopilot-capable hardware or SYSTEM context required.

    Run with:
        powershell.exe -NoProfile -File .\client\tests\Invoke-Tests.ps1
    or directly:
        Invoke-Pester -Path .\client\tests\AutopilotIdentity.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..\AutopilotIdentity.psm1')
    Import-Module $script:ModulePath -Force -DisableNameChecking
}

AfterAll {
    Remove-Module AutopilotIdentity -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Describe 'Get-AutopilotHardwareHash' {

    It 'returns the DeviceHardwareData from MDM_DevDetail_Ext01' {
        InModuleScope AutopilotIdentity {
            Mock Invoke-CimQuery -ParameterFilter { $ClassName -eq 'MDM_DevDetail_Ext01' } {
                [pscustomobject]@{ DeviceHardwareData = 'QUJDREVG-hash-base64' }
            }
            Get-AutopilotHardwareHash | Should -Be 'QUJDREVG-hash-base64'
        }
    }

    It 'throws when the class/property is unavailable' {
        InModuleScope AutopilotIdentity {
            Mock Invoke-CimQuery -ParameterFilter { $ClassName -eq 'MDM_DevDetail_Ext01' } { $null }
            { Get-AutopilotHardwareHash } | Should -Throw -ExpectedMessage '*hardware hash not available*'
        }
    }

    It 'throws when DeviceHardwareData is empty' {
        InModuleScope AutopilotIdentity {
            Mock Invoke-CimQuery -ParameterFilter { $ClassName -eq 'MDM_DevDetail_Ext01' } {
                [pscustomobject]@{ DeviceHardwareData = '' }
            }
            { Get-AutopilotHardwareHash } | Should -Throw
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-DeviceSerialNumber' {

    It 'returns the trimmed BIOS serial number' {
        InModuleScope AutopilotIdentity {
            Mock Invoke-CimQuery -ParameterFilter { $ClassName -eq 'Win32_BIOS' } {
                [pscustomobject]@{ SerialNumber = '  SN-12345  ' }
            }
            Get-DeviceSerialNumber | Should -Be 'SN-12345'
        }
    }

    It 'returns empty string when BIOS info is unavailable' {
        InModuleScope AutopilotIdentity {
            Mock Invoke-CimQuery -ParameterFilter { $ClassName -eq 'Win32_BIOS' } { $null }
            Get-DeviceSerialNumber | Should -Be ''
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-WindowsProductKey' {

    It 'returns the OA3xOriginalProductKey when present' {
        InModuleScope AutopilotIdentity {
            Mock Invoke-CimQuery -ParameterFilter { $ClassName -eq 'SoftwareLicensingService' } {
                [pscustomobject]@{ OA3xOriginalProductKey = 'XXXXX-YYYYY-ZZZZZ' }
            }
            Get-WindowsProductKey | Should -Be 'XXXXX-YYYYY-ZZZZZ'
        }
    }

    It 'returns empty string when the key is unavailable' {
        InModuleScope AutopilotIdentity {
            Mock Invoke-CimQuery -ParameterFilter { $ClassName -eq 'SoftwareLicensingService' } { $null }
            Get-WindowsProductKey | Should -Be ''
        }
    }
}

# ---------------------------------------------------------------------------
Describe 'Get-AutopilotIdentityPayload' {

    It 'composes the payload with hash + serial + product key' {
        InModuleScope AutopilotIdentity {
            Mock Invoke-CimQuery -ParameterFilter { $ClassName -eq 'MDM_DevDetail_Ext01' }     { [pscustomobject]@{ DeviceHardwareData = 'HASH' } }
            Mock Invoke-CimQuery -ParameterFilter { $ClassName -eq 'Win32_BIOS' }              { [pscustomobject]@{ SerialNumber = 'SN-1' } }
            Mock Invoke-CimQuery -ParameterFilter { $ClassName -eq 'SoftwareLicensingService' } { [pscustomobject]@{ OA3xOriginalProductKey = 'KEY-1' } }

            $p = Get-AutopilotIdentityPayload
            $p.hardwareHash | Should -Be 'HASH'
            $p.serialNumber | Should -Be 'SN-1'
            $p.productKey   | Should -Be 'KEY-1'
            $p.ContainsKey('groupTag') | Should -BeFalse
        }
    }

    It 'includes groupTag and UPN when supplied and omits empty optional fields' {
        InModuleScope AutopilotIdentity {
            Mock Invoke-CimQuery -ParameterFilter { $ClassName -eq 'MDM_DevDetail_Ext01' }     { [pscustomobject]@{ DeviceHardwareData = 'HASH' } }
            Mock Invoke-CimQuery -ParameterFilter { $ClassName -eq 'Win32_BIOS' }              { $null }
            Mock Invoke-CimQuery -ParameterFilter { $ClassName -eq 'SoftwareLicensingService' } { $null }

            $p = Get-AutopilotIdentityPayload -GroupTag 'Corp' -AssignedUserPrincipalName 'user@contoso.com'
            $p.hardwareHash               | Should -Be 'HASH'
            $p.groupTag                   | Should -Be 'Corp'
            $p.assignedUserPrincipalName  | Should -Be 'user@contoso.com'
            $p.ContainsKey('serialNumber') | Should -BeFalse
            $p.ContainsKey('productKey')   | Should -BeFalse
        }
    }

    It 'propagates the missing-hash failure' {
        InModuleScope AutopilotIdentity {
            Mock Invoke-CimQuery -ParameterFilter { $ClassName -eq 'MDM_DevDetail_Ext01' } { $null }
            { Get-AutopilotIdentityPayload } | Should -Throw
        }
    }
}
