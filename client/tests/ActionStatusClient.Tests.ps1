#requires -Version 5.1

BeforeAll {
    $script:ModulePath = Resolve-Path (Join-Path $PSScriptRoot '..\ActionStatusClient.psm1')
    Import-Module $script:ModulePath -Force -DisableNameChecking
}

AfterAll {
    Remove-Module ActionStatusClient -Force -ErrorAction SilentlyContinue
}

Describe 'Get-ActionStatusUrl' {
    It 'appends /status/{correlationId} to the canonical actions endpoint' {
        InModuleScope ActionStatusClient {
            Get-ActionStatusUrl -ApiUrl 'https://host/api/actions/' -CorrelationId 'abc-123' |
                Should -Be 'https://host/api/actions/status/abc-123'
        }
    }
}

Describe 'Resolve-ActionStatusMonitoringOptions' {
    It 'defaults to 5 seconds and 30 minutes' {
        InModuleScope ActionStatusClient {
            $opts = Resolve-ActionStatusMonitoringOptions
            $opts.IntervalSeconds | Should -Be 5
            $opts.MaxMinutes | Should -Be 30
        }
    }

    It 'reads values from config when explicit parameters are absent' {
        InModuleScope ActionStatusClient {
            $cfg = [pscustomobject]@{
                StatusPollIntervalSeconds = 9
                StatusPollMaxMinutes = 44
            }
            $opts = Resolve-ActionStatusMonitoringOptions -Config $cfg
            $opts.IntervalSeconds | Should -Be 9
            $opts.MaxMinutes | Should -Be 44
        }
    }

    It 'prefers explicit parameters over config values' {
        InModuleScope ActionStatusClient {
            $cfg = [pscustomobject]@{
                StatusPollIntervalSeconds = 9
                StatusPollMaxMinutes = 44
            }
            $opts = Resolve-ActionStatusMonitoringOptions -Config $cfg -IntervalSeconds 5 -MaxMinutes 30
            $opts.IntervalSeconds | Should -Be 5
            $opts.MaxMinutes | Should -Be 30
        }
    }
}
