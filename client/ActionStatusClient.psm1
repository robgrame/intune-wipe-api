Set-StrictMode -Version Latest

function Get-ActionStatusNow {
    Get-Date
}

function Wait-ActionStatusDelay {
    param([int] $Seconds)
    Start-Sleep -Seconds $Seconds
}

function Invoke-ActionStatusRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $StatusUrl,
        [Parameter(Mandatory = $true)] [object] $Certificate,
        [Parameter(Mandatory = $true)] [hashtable] $Headers
    )

    Invoke-RestMethod -Method Get -Uri $StatusUrl -Certificate $Certificate -Headers $Headers -TimeoutSec 30 -ErrorAction Stop
}

function Get-ActionStatusUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $ApiUrl,
        [Parameter(Mandatory = $true)] [string] $CorrelationId
    )

    $trimmed = $ApiUrl.TrimEnd('/')
    return ("{0}/status/{1}" -f $trimmed, $CorrelationId)
}

function Resolve-ActionStatusMonitoringOptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)] [object] $Config,
        [Parameter(Mandatory = $false)] [int] $IntervalSeconds = 0,
        [Parameter(Mandatory = $false)] [int] $MaxMinutes = 0
    )

    $resolvedInterval = 5
    $resolvedMaxMinutes = 30

    if ($IntervalSeconds -gt 0) {
        $resolvedInterval = $IntervalSeconds
    } elseif ($Config -and $Config.PSObject.Properties.Name -contains 'StatusPollIntervalSeconds') {
        try {
            $candidate = [int]$Config.StatusPollIntervalSeconds
            if ($candidate -gt 0) { $resolvedInterval = $candidate }
        } catch { }
    }

    if ($MaxMinutes -gt 0) {
        $resolvedMaxMinutes = $MaxMinutes
    } elseif ($Config -and $Config.PSObject.Properties.Name -contains 'StatusPollMaxMinutes') {
        try {
            $candidate = [int]$Config.StatusPollMaxMinutes
            if ($candidate -gt 0) { $resolvedMaxMinutes = $candidate }
        } catch { }
    }

    [pscustomobject]@{
        IntervalSeconds = $resolvedInterval
        MaxMinutes      = $resolvedMaxMinutes
    }
}

function Wait-ActionStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $ApiUrl,
        [Parameter(Mandatory = $true)] [string] $CorrelationId,
        [Parameter(Mandatory = $true)] [object] $Certificate,
        [Parameter(Mandatory = $true)] [string] $FunctionKey,
        [Parameter(Mandatory = $false)] [int] $IntervalSeconds = 5,
        [Parameter(Mandatory = $false)] [int] $MaxMinutes = 30,
        [Parameter(Mandatory = $false)] [scriptblock] $OnUpdate
    )

    $statusUrl = Get-ActionStatusUrl -ApiUrl $ApiUrl -CorrelationId $CorrelationId
    $deadline = (Get-ActionStatusNow).AddMinutes($MaxMinutes)
    $headers = @{ 'x-functions-key' = $FunctionKey }
    $attempt = 0
    $lastSnapshot = $null

    while ((Get-ActionStatusNow) -lt $deadline) {
        $attempt++
        try {
            $snapshot = Invoke-ActionStatusRequest -StatusUrl $statusUrl -Certificate $Certificate -Headers $headers
            $lastSnapshot = $snapshot
            if ($OnUpdate) {
                & $OnUpdate ([pscustomobject]@{
                    Attempt    = $attempt
                    LocalState = $(if ([bool]$snapshot.terminal) { 'terminal' } else { 'polling' })
                    Snapshot   = $snapshot
                    Note       = ("attempt {0}" -f $attempt)
                })
            }

            if ([bool]$snapshot.terminal) {
                return [pscustomobject]@{
                    LocalState = 'terminal'
                    Snapshot   = $snapshot
                    Attempt    = $attempt
                    TimedOut   = $false
                    StatusUrl  = $statusUrl
                }
            }
        } catch {
            $statusCode = $null
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
            $msg = $_.Exception.Message
            if ($OnUpdate) {
                & $OnUpdate ([pscustomobject]@{
                    Attempt    = $attempt
                    LocalState = 'error'
                    Snapshot   = $null
                    Note       = ("attempt {0}: HTTP {1} - {2}" -f $attempt, $statusCode, $msg)
                })
            }
        }

        Wait-ActionStatusDelay -Seconds $IntervalSeconds
    }

    if ($OnUpdate) {
        & $OnUpdate ([pscustomobject]@{
            Attempt    = $attempt
            LocalState = 'timeout'
            Snapshot   = $lastSnapshot
            Note       = ("no terminal state after {0} minutes" -f $MaxMinutes)
        })
    }

    [pscustomobject]@{
        LocalState = 'timeout'
        Snapshot   = $lastSnapshot
        Attempt    = $attempt
        TimedOut   = $true
        StatusUrl  = $statusUrl
    }
}

Export-ModuleMember -Function Get-ActionStatusUrl, Resolve-ActionStatusMonitoringOptions, Wait-ActionStatus
