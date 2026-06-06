<#
.SYNOPSIS
    Shared PowerShell 7.2 toolkit for the Azure Automation runbook variant of
    the Intune Device Actions capabilities. Provides functional parity with
    the .NET Function App runners (WipeActionRunner / AutopilotRegisterRunner /
    BitLockerRotateRunner).

.DESCRIPTION
    This file is NOT a standalone runbook. It is **concatenated** in front of
    each Invoke-*.runbook.ps1 by tools/Deploy-IntuneDeviceActions.ps1 at
    publish time so the merged content uploaded to Azure Automation is a
    self-contained script (Automation has no module-import mechanism for
    runbook-local libraries).

    What this toolkit replicates from the .NET runners:
      1. Microsoft Graph helpers with the same Transient/Permanent error
         classification (HTTP 408/429/5xx → throw to retry, other 4xx →
         capability swallows + audits + records terminal status).
      2. The 3 fail-closed pre-issue checks (resolve device object id,
         allowed-group membership, ownership via managedDevices).
      3. The idempotency ledger blob (action-ledger container) with the same
         JSON shape as IntuneDeviceActions.Services.ActionIdempotencyService
         (PUT-If-None-Match for fresh, PUT-If-Match for rearm; tracker-driven
         auto-rearm on terminal LastState, 24h rolling rate limiter).
      4. The action status tracker Table (actionstatus) — Initialize on issue,
         RecordTerminal on every denial path.
      5. The dual audit sink (Table auditevents row + Write-Output trace) —
         App Insights customEvents are intentionally NOT emitted (the Table is
         the canonical durable audit; the runbook job stream is the live
         counterpart of the worker log).
      6. Post-action nudges for wipe (syncDevice + rebootNow) with bounded
         backoff retries.

    What is deliberately simplified vs the .NET runners:
      - No App Insights TrackEvent. Audit Table is the durable sink (90-day
         AI retention is moot when Table keeps multi-year history); the live
         counterpart is the Automation job stream.
      - No GraphServiceClient SDK — direct REST against graph.microsoft.com.
      - No background fire-and-forget for audit writes — writes are awaited
         since Automation jobs have generous timeouts.

.NOTES
    Requires: PowerShell 7.2+, Az.Accounts >= 2.13 (for Get-AzAccessToken).
    The Automation Account's system-assigned managed identity must hold:
      - Graph: DeviceManagementManagedDevices.PrivilegedOperations.All,
               DeviceManagementManagedDevices.Read.All,
               DeviceManagementServiceConfig.ReadWrite.All,
               Device.Read.All, GroupMember.Read.All
      - Storage Blob Data Contributor on the action-ledger container
        (storageProc account)
      - Storage Table Data Contributor on the auditevents + actionstatus
        tables (storageProc account)
#>

# Shared event-name constants — kept in lock-step with
# IntuneDeviceActions.Services.AuditEvents + per-capability *AuditEvents classes.
$script:RbcAudit = @{
    DeniedDeviceResolveFailed        = 'action.denied.device-resolve-failed'
    DeniedDeviceNotInEntra           = 'action.denied.device-not-in-entra'
    DeniedGroupCheckFailed           = 'action.denied.group-check-failed'
    DeniedNotInAllowedGroup          = 'action.denied.not-in-allowed-group'
    DeniedManagedDeviceResolveFailed = 'action.denied.managed-device-resolve-failed'
    DeniedOwnershipMismatch          = 'action.denied.ownership-mismatch'
    DeniedRateLimited                = 'action.denied.rate-limited'
    ActionAlreadyIssued              = 'action.already-issued'
    ActionInProgressElsewhere        = 'action.in-progress-elsewhere'
    LedgerRearmedAfterSuccess        = 'action.ledger.rearmed.after-success'
    LedgerRearmedAfterFailure        = 'action.ledger.rearmed.after-failure'
    LedgerRearmedAfterTimeout        = 'action.ledger.rearmed.after-timeout'
    LedgerRearmedForced              = 'action.ledger.rearmed.forced'

    WipeIssued                       = 'wipe.graph.issued'
    WipeFailedPermanent              = 'wipe.graph.failed-permanent'
    WipeTransientError               = 'wipe.graph.transient-error'
    SyncFallbackIssued               = 'wipe.graph.sync-fallback.issued'
    SyncFallbackRetrying             = 'wipe.graph.sync-fallback.retrying'
    SyncFallbackFailed               = 'wipe.graph.sync-fallback.failed'
    SyncFallbackExhausted            = 'wipe.graph.sync-fallback.exhausted'
    RebootFallbackIssued             = 'wipe.graph.reboot-fallback.issued'
    RebootFallbackRetrying           = 'wipe.graph.reboot-fallback.retrying'
    RebootFallbackFailed             = 'wipe.graph.reboot-fallback.failed'
    RebootFallbackExhausted          = 'wipe.graph.reboot-fallback.exhausted'

    ApImportIssued                   = 'autopilot.graph.import.issued'
    ApImportFailedPermanent          = 'autopilot.graph.import.failed-permanent'
    ApImportTransientError           = 'autopilot.graph.import.transient-error'
    ApDeniedMissingHardwareHash      = 'autopilot.denied.missing-hardware-hash'

    BlRotateIssued                   = 'bitlocker.graph.rotate.issued'
    BlRotateFailedPermanent          = 'bitlocker.graph.rotate.failed-permanent'
    BlRotateTransientError           = 'bitlocker.graph.rotate.transient-error'
}

# Storage REST API version. 2020-12-06 supports Bearer-token (AAD) auth for
# both Blob and Table services.
$script:RbcStorageApiVersion = '2020-12-06'

# Token caches: avoid re-acquiring on every helper call.
$script:RbcTokenCache = @{ Graph = $null; Storage = $null }

# ─── Diagnostics / output ───────────────────────────────────────────────────

function Write-RbcInfo {
    param([string]$Message, [hashtable]$Props)
    $line = "[INFO ] $Message"
    if ($Props -and $Props.Count -gt 0) {
        $kv = ($Props.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
        $line += " $kv"
    }
    Write-Output $line
}

function Write-RbcWarn {
    param([string]$Message, [hashtable]$Props)
    $line = "[WARN ] $Message"
    if ($Props -and $Props.Count -gt 0) {
        $kv = ($Props.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
        $line += " $kv"
    }
    Write-Warning $line
}

# ─── Token acquisition ──────────────────────────────────────────────────────

function Get-RbcGraphToken {
    [OutputType([string])]
    param()
    $cached = $script:RbcTokenCache.Graph
    if ($cached -and ($cached.ExpiresOn -gt (Get-Date).AddSeconds(60))) {
        return $cached.Token
    }
    $t = $null
    try {
        $t = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -AsSecureString:$false -ErrorAction Stop
    } catch [System.Management.Automation.ParameterBindingException] {
        $t = Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -ErrorAction Stop
    }
    $script:RbcTokenCache.Graph = $t
    return $t.Token
}

function Get-RbcStorageToken {
    [OutputType([string])]
    param()
    $cached = $script:RbcTokenCache.Storage
    if ($cached -and ($cached.ExpiresOn -gt (Get-Date).AddSeconds(60))) {
        return $cached.Token
    }
    $t = $null
    try {
        $t = Get-AzAccessToken -ResourceUrl 'https://storage.azure.com/' -AsSecureString:$false -ErrorAction Stop
    } catch [System.Management.Automation.ParameterBindingException] {
        $t = Get-AzAccessToken -ResourceUrl 'https://storage.azure.com/' -ErrorAction Stop
    }
    $script:RbcTokenCache.Storage = $t
    return $t.Token
}

# ─── Error classification (mirrors GraphWipeService.Classify) ───────────────

class RbcGraphError : System.Exception {
    [int]$StatusCode
    [string]$Kind    # 'Transient' | 'Permanent'
    [string]$Method
    [string]$Uri
    [string]$Body
    RbcGraphError([string]$Message, [int]$Status, [string]$Kind, [string]$Method, [string]$Uri, [string]$Body)
        : base($Message) {
        $this.StatusCode = $Status
        $this.Kind = $Kind
        $this.Method = $Method
        $this.Uri = $Uri
        $this.Body = $Body
    }
}

function ConvertTo-RbcErrorKind {
    [OutputType([string])]
    param([int]$StatusCode)
    if ($StatusCode -eq 0) { return 'Transient' }
    if ($StatusCode -eq 408 -or $StatusCode -eq 429 -or $StatusCode -ge 500) { return 'Transient' }
    if ($StatusCode -ge 400 -and $StatusCode -lt 500) { return 'Permanent' }
    return 'Transient'
}

# ─── Generic HTTP helper ────────────────────────────────────────────────────

function Invoke-RbcRest {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Uri,
        [Parameter(Mandatory)] [hashtable]$Headers,
        [string]$Body,
        [int]$TimeoutSec = 100
    )
    $p = @{
        Method                  = $Method
        Uri                     = $Uri
        Headers                 = $Headers
        TimeoutSec              = $TimeoutSec
        SkipHttpErrorCheck      = $true
        StatusCodeVariable      = 'rbcStatus'
        ResponseHeadersVariable = 'rbcHeaders'
    }
    if ($PSBoundParameters.ContainsKey('Body') -and $Body) { $p['Body'] = $Body }
    $content = Invoke-RestMethod @p
    return @{ StatusCode = [int]$rbcStatus; Headers = $rbcHeaders; Content = $content }
}

function Invoke-RbcGraphApi {
    param(
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Uri,
        [object]$Body
    )
    $headers = @{
        Authorization = "Bearer $(Get-RbcGraphToken)"
        Accept        = 'application/json'
    }
    $bodyJson = $null
    if ($null -ne $Body) {
        $bodyJson = if ($Body -is [string]) { $Body } else { ($Body | ConvertTo-Json -Depth 16 -Compress) }
        $headers['Content-Type'] = 'application/json'
    }
    $r = Invoke-RbcRest -Method $Method -Uri $Uri -Headers $headers -Body $bodyJson
    if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { return $r.Content }
    $kind = ConvertTo-RbcErrorKind -StatusCode $r.StatusCode
    $msg  = if ($r.Content) { ($r.Content | ConvertTo-Json -Depth 8 -Compress) } else { "HTTP $($r.StatusCode)" }
    throw [RbcGraphError]::new("Graph $Method $Uri failed (HTTP $($r.StatusCode), $kind): $msg",
        $r.StatusCode, $kind, $Method, $Uri, $msg)
}

# ─── Azure Tables (REST) ────────────────────────────────────────────────────

function New-RbcTableHeaders {
    param([string]$AdditionalAccept)
    return @{
        Authorization         = "Bearer $(Get-RbcStorageToken)"
        'x-ms-version'        = $script:RbcStorageApiVersion
        'x-ms-date'           = ([DateTime]::UtcNow.ToString('R'))
        Accept                = ($AdditionalAccept ? $AdditionalAccept : 'application/json;odata=nometadata')
        DataServiceVersion    = '3.0;NetFx'
        MaxDataServiceVersion = '3.0;NetFx'
    }
}

function ConvertTo-RbcTableEntity {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string]$PartitionKey,
        [Parameter(Mandatory)] [string]$RowKey,
        [Parameter(Mandatory)] [hashtable]$Properties
    )
    $ordered = [ordered]@{}
    $ordered['PartitionKey'] = $PartitionKey
    $ordered['RowKey']       = $RowKey
    foreach ($k in $Properties.Keys) {
        $v = $Properties[$k]
        if ($null -eq $v) { continue }
        if ($v -is [datetime]) {
            $ordered[$k] = $v.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $ordered[("$k@odata.type")] = 'Edm.DateTime'
        } elseif ($v -is [datetimeoffset]) {
            $ordered[$k] = $v.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $ordered[("$k@odata.type")] = 'Edm.DateTime'
        } elseif ($v -is [bool]) {
            $ordered[$k] = $v
        } elseif ($v -is [int] -or $v -is [long]) {
            $ordered[$k] = $v
            $ordered[("$k@odata.type")] = if ($v -is [long]) { 'Edm.Int64' } else { 'Edm.Int32' }
        } else {
            $ordered[$k] = [string]$v
        }
    }
    return ($ordered | ConvertTo-Json -Depth 8 -Compress)
}

function Test-RbcKeySafe {
    [OutputType([string])]
    param([string]$Key)
    if ([string]::IsNullOrEmpty($Key)) { return '_' }
    $sb = [System.Text.StringBuilder]::new()
    foreach ($c in $Key.ToCharArray()) {
        if ($c -eq '/' -or $c -eq '\' -or $c -eq '#' -or $c -eq '?' -or [char]::IsControl($c)) {
            [void]$sb.Append('_')
        } else {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString()
}

function New-RbcTableIfMissing {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$StorageAccount,
        [Parameter(Mandatory)] [string]$TableName
    )
    $uri = "https://$StorageAccount.table.core.windows.net/Tables"
    $headers = New-RbcTableHeaders
    $headers['Content-Type'] = 'application/json'
    $payload = "{`"TableName`":`"$TableName`"}"
    try {
        $r = Invoke-RbcRest -Method POST -Uri $uri -Headers $headers -Body $payload
        return ($r.StatusCode -eq 201 -or $r.StatusCode -eq 409)
    } catch { return $false }
}

function Add-RbcTableEntity {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$StorageAccount,
        [Parameter(Mandatory)] [string]$TableName,
        [Parameter(Mandatory)] [string]$PartitionKey,
        [Parameter(Mandatory)] [string]$RowKey,
        [Parameter(Mandatory)] [hashtable]$Properties,
        [int]$Retries = 1
    )
    $uri = "https://$StorageAccount.table.core.windows.net/$TableName"
    $headers = New-RbcTableHeaders
    $headers['Content-Type'] = 'application/json'
    $headers['Prefer']       = 'return-no-content'

    $rkLocal = $RowKey
    for ($i = 0; $i -le $Retries; $i++) {
        $payload = ConvertTo-RbcTableEntity -PartitionKey $PartitionKey -RowKey $rkLocal -Properties $Properties
        try {
            $r = Invoke-RbcRest -Method POST -Uri $uri -Headers $headers -Body $payload
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { return $true }
            if ($r.StatusCode -eq 404 -and $i -eq 0) {
                # Table missing — create then retry once.
                [void](New-RbcTableIfMissing -StorageAccount $StorageAccount -TableName $TableName)
                continue
            }
            if ($r.StatusCode -eq 409 -and $i -lt $Retries) {
                $rkLocal = "$RowKey-$([Guid]::NewGuid().ToString('N').Substring(0,4))"
                continue
            }
            Write-RbcWarn "Table insert failed (HTTP $($r.StatusCode))" @{ table=$TableName; pk=$PartitionKey; rk=$rkLocal }
            return $false
        } catch {
            Write-RbcWarn "Table insert exception: $($_.Exception.Message)" @{ table=$TableName; pk=$PartitionKey; rk=$rkLocal }
            return $false
        }
    }
    return $false
}

function Set-RbcTableEntity {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$StorageAccount,
        [Parameter(Mandatory)] [string]$TableName,
        [Parameter(Mandatory)] [string]$PartitionKey,
        [Parameter(Mandatory)] [string]$RowKey,
        [Parameter(Mandatory)] [hashtable]$Properties
    )
    $uri = "https://$StorageAccount.table.core.windows.net/$TableName(PartitionKey='$PartitionKey',RowKey='$RowKey')"
    $headers = New-RbcTableHeaders
    $headers['Content-Type'] = 'application/json'
    $headers['Prefer']       = 'return-no-content'
    $headers['If-Match']     = '*'
    $payload = ConvertTo-RbcTableEntity -PartitionKey $PartitionKey -RowKey $RowKey -Properties $Properties
    try {
        $r = Invoke-RbcRest -Method PUT -Uri $uri -Headers $headers -Body $payload
        if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { return $true }
        if ($r.StatusCode -eq 404) {
            [void](New-RbcTableIfMissing -StorageAccount $StorageAccount -TableName $TableName)
            $r2 = Invoke-RbcRest -Method PUT -Uri $uri -Headers $headers -Body $payload
            return ($r2.StatusCode -ge 200 -and $r2.StatusCode -lt 300)
        }
        Write-RbcWarn "Table upsert failed (HTTP $($r.StatusCode))" @{ table=$TableName; pk=$PartitionKey; rk=$RowKey }
        return $false
    } catch {
        Write-RbcWarn "Table upsert exception: $($_.Exception.Message)" @{ table=$TableName }
        return $false
    }
}

function Get-RbcTableEntity {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$StorageAccount,
        [Parameter(Mandatory)] [string]$TableName,
        [Parameter(Mandatory)] [string]$PartitionKey,
        [Parameter(Mandatory)] [string]$RowKey
    )
    $uri = "https://$StorageAccount.table.core.windows.net/$TableName(PartitionKey='$PartitionKey',RowKey='$RowKey')"
    $headers = New-RbcTableHeaders
    try {
        $r = Invoke-RbcRest -Method GET -Uri $uri -Headers $headers
        if ($r.StatusCode -eq 200) {
            $h = @{}
            $r.Content.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
            return $h
        }
        return $null
    } catch { return $null }
}

# ─── Azure Blobs (REST) for the idempotency ledger ──────────────────────────

function New-RbcBlobHeaders {
    [OutputType([hashtable])]
    param()
    return @{
        Authorization  = "Bearer $(Get-RbcStorageToken)"
        'x-ms-version' = $script:RbcStorageApiVersion
        'x-ms-date'    = ([DateTime]::UtcNow.ToString('R'))
    }
}

function Get-RbcBlob {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$StorageAccount,
        [Parameter(Mandatory)] [string]$Container,
        [Parameter(Mandatory)] [string]$BlobName
    )
    $uri = "https://$StorageAccount.blob.core.windows.net/$Container/$([uri]::EscapeDataString($BlobName))"
    $headers = New-RbcBlobHeaders
    try {
        $r = Invoke-RbcRest -Method GET -Uri $uri -Headers $headers
        if ($r.StatusCode -eq 200) {
            $etagHeader = $r.Headers['ETag']
            $etag = if ($etagHeader -is [array]) { [string]$etagHeader[0] } else { [string]$etagHeader }
            $content = if ($r.Content -is [string]) { $r.Content } else { ($r.Content | ConvertTo-Json -Depth 32 -Compress) }
            return @{ Found = $true; Content = $content; ETag = $etag }
        }
        if ($r.StatusCode -eq 404) { return @{ Found = $false } }
        return $null
    } catch { return $null }
}

function Set-RbcBlob {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$StorageAccount,
        [Parameter(Mandatory)] [string]$Container,
        [Parameter(Mandatory)] [string]$BlobName,
        [Parameter(Mandatory)] [string]$Content,
        [string]$IfMatch,
        [switch]$IfNoneMatchAll
    )
    $uri = "https://$StorageAccount.blob.core.windows.net/$Container/$([uri]::EscapeDataString($BlobName))"
    $headers = New-RbcBlobHeaders
    $headers['x-ms-blob-type'] = 'BlockBlob'
    $headers['Content-Type']   = 'application/json'
    if ($IfMatch)        { $headers['If-Match']      = $IfMatch }
    if ($IfNoneMatchAll) { $headers['If-None-Match'] = '*' }
    try {
        $r = Invoke-RbcRest -Method PUT -Uri $uri -Headers $headers -Body $Content
        if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) {
            $etagHeader = $r.Headers['ETag']
            $etag = if ($etagHeader -is [array]) { [string]$etagHeader[0] } else { [string]$etagHeader }
            return @{ Success = $true; ETag = $etag }
        }
        return @{ Success = $false; Status = [int]$r.StatusCode }
    } catch {
        return @{ Success = $false; Status = 0; Error = $_.Exception.Message }
    }
}

# ─── Audit (durable Table sink) ─────────────────────────────────────────────

function Write-RbcAudit {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$EventName,
        [Parameter(Mandatory)] [hashtable]$Context,
        [hashtable]$Props,
        [string]$Level = 'Information',
        [System.Exception]$Exception
    )
    if (-not $Context.AuditStorageAccount) { return $false }
    $corr = [string]$Context.CorrelationId
    if ([string]::IsNullOrWhiteSpace($corr)) { $corr = 'no-correlation' }

    $bag = @{
        correlationId  = $corr
        deviceName     = [string]$Context.DeviceName
        entraDeviceId  = [string]$Context.EntraDeviceId
        intuneDeviceId = [string]$Context.IntuneDeviceId
        actionType     = [string]$Context.ActionType
        source         = 'runbook'
        audit          = 'true'
    }
    if ($Props) { foreach ($k in $Props.Keys) { $bag[$k] = [string]$Props[$k] } }
    if ($Exception) {
        $bag['exceptionType'] = $Exception.GetType().FullName
        $msg = $Exception.Message
        if ($msg.Length -gt 512) { $msg = $msg.Substring(0,512) + '…' }
        $bag['exceptionMessage'] = $msg
    }

    $now = [DateTimeOffset]::UtcNow
    $rk  = "{0:D19}_{1}" -f $now.UtcTicks, ([Guid]::NewGuid().ToString('N').Substring(0,8))
    $pk  = Test-RbcKeySafe -Key $corr

    $properties = @{
        Name             = $EventName
        Level            = $Level
        EventTimestamp   = $now
        DeviceName       = $bag['deviceName']
        EntraDeviceId    = $bag['entraDeviceId']
        IntuneDeviceId   = $bag['intuneDeviceId']
        ManagedDeviceId  = [string]($Props ? $Props['managedDeviceId'] : '')
        Reason           = [string]($Props ? $Props['reason'] : '')
        ExceptionType    = [string]$bag['exceptionType']
        ExceptionMessage = [string]$bag['exceptionMessage']
        PropertiesJson   = ($bag | ConvertTo-Json -Depth 8 -Compress)
    }

    $ok = Add-RbcTableEntity `
        -StorageAccount $Context.AuditStorageAccount `
        -TableName      $Context.AuditTableName `
        -PartitionKey   $pk `
        -RowKey         $rk `
        -Properties     $properties `
        -Retries        1

    $kv = "event=$EventName corr=$corr device=$($bag['deviceName']) intune=$($bag['intuneDeviceId'])"
    if ($Level -in @('Warning','Error','Critical')) { Write-Warning "AUDIT $kv" } else { Write-Output "AUDIT $kv" }
    return $ok
}

# ─── Action status tracker (actionstatus table) ─────────────────────────────

function Initialize-RbcActionStatus {
    param(
        [Parameter(Mandatory)] [hashtable]$Context,
        [Parameter(Mandatory)] [string]$ManagedDeviceId
    )
    if (-not $Context.StatusStorageAccount) { return }
    $now   = [DateTimeOffset]::UtcNow
    $epoch = [DateTimeOffset]::FromUnixTimeSeconds(0)
    $pk    = Test-RbcKeySafe -Key ([string]$Context.CorrelationId)
    [void](Set-RbcTableEntity `
        -StorageAccount $Context.StatusStorageAccount `
        -TableName      $Context.StatusTableName `
        -PartitionKey   $pk `
        -RowKey         'status' `
        -Properties     @{
            ActionType      = ([string]$Context.ActionType).ToLowerInvariant()
            ManagedDeviceId = $ManagedDeviceId
            DeviceName      = [string]$Context.DeviceName
            EntraDeviceId   = [string]$Context.EntraDeviceId
            IntuneDeviceId  = [string]$Context.IntuneDeviceId
            IssuedAt        = $now
            LastPolledAt    = $epoch
            LastChangedAt   = $now
            LastState       = 'pending'
            PreviousState   = ''
            PollAttempts    = 0
            Terminal        = $false
        })
}

function Write-RbcTerminalStatus {
    param(
        [Parameter(Mandatory)] [hashtable]$Context,
        [Parameter(Mandatory)] [string]$State,
        [string]$ManagedDeviceId = ''
    )
    if (-not $Context.StatusStorageAccount) { return }
    $now   = [DateTimeOffset]::UtcNow
    $epoch = [DateTimeOffset]::FromUnixTimeSeconds(0)
    $pk    = Test-RbcKeySafe -Key ([string]$Context.CorrelationId)
    [void](Set-RbcTableEntity `
        -StorageAccount $Context.StatusStorageAccount `
        -TableName      $Context.StatusTableName `
        -PartitionKey   $pk `
        -RowKey         'status' `
        -Properties     @{
            ActionType      = ([string]$Context.ActionType).ToLowerInvariant()
            ManagedDeviceId = $ManagedDeviceId
            DeviceName      = [string]$Context.DeviceName
            EntraDeviceId   = [string]$Context.EntraDeviceId
            IntuneDeviceId  = [string]$Context.IntuneDeviceId
            IssuedAt        = $now
            LastPolledAt    = $epoch
            LastChangedAt   = $now
            LastState       = $State
            PreviousState   = ''
            PollAttempts    = 0
            Terminal        = $true
        })
}

function Get-RbcActionStatus {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable]$Context,
        [Parameter(Mandatory)] [string]$CorrelationId
    )
    if (-not $Context.StatusStorageAccount) { return $null }
    return Get-RbcTableEntity `
        -StorageAccount $Context.StatusStorageAccount `
        -TableName      $Context.StatusTableName `
        -PartitionKey   (Test-RbcKeySafe -Key $CorrelationId) `
        -RowKey         'status'
}

# ─── Idempotency ledger (mirrors ActionIdempotencyService) ──────────────────

$script:RbcLedgerSuccessStates    = @('done', 'removedfromintune')
$script:RbcLedgerFailureStates    = @('failed', 'canceled', 'notsupported')
$script:RbcLedgerMaxRearmAttempts = 3
$script:RbcLedgerRateWindowHours  = 24

function New-RbcLedgerEntry {
    param(
        [string]$IntuneDeviceId,
        [string]$CorrelationId,
        [string]$State = 'Reserved',
        [int]$ActionSequence = 1
    )
    return @{
        IntuneDeviceId         = $IntuneDeviceId
        CorrelationId          = $CorrelationId
        State                  = $State
        ReservedAt             = ([DateTimeOffset]::UtcNow).ToString('o')
        IssuedAt               = $null
        FailedAt               = $null
        FailureReason          = $null
        Attempts               = 1
        ActionSequence         = $ActionSequence
        LastRearmedAt          = $null
        LastTerminalState      = $null
        LastRearmReason        = 'None'
        RecentActionTimestamps = @()
    }
}

function Get-RbcLedgerBlobName {
    param([string]$IntuneDeviceId)
    return "$($IntuneDeviceId.ToLowerInvariant()).json"
}

function ConvertFrom-RbcLedger {
    param([string]$Json)
    $o = $Json | ConvertFrom-Json -Depth 32
    $h = @{}
    $o.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
    if (-not $h.ContainsKey('RecentActionTimestamps') -or $null -eq $h['RecentActionTimestamps']) {
        $h['RecentActionTimestamps'] = @()
    }
    return $h
}

function Reserve-RbcLedger {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [hashtable]$Context,
        [Parameter(Mandatory)] [string]$IntuneDeviceId,
        [Parameter(Mandatory)] [string]$CorrelationId,
        [bool]$ForceRearm = $false
    )
    $sa         = $Context.LedgerStorageAccount
    $cont       = $Context.LedgerContainer
    $maxCap     = [int]($Context.MaxActionsPerDevicePerDay)
    if ($maxCap -le 0) { $maxCap = 5 }
    $grace      = [int]($Context.RearmGracePeriodHours)
    if ($grace -le 0) { $grace = 48 }
    $allowForce = [bool]($Context.AllowForceRearm)
    $blobName   = Get-RbcLedgerBlobName -IntuneDeviceId $IntuneDeviceId

    $fresh = New-RbcLedgerEntry -IntuneDeviceId $IntuneDeviceId -CorrelationId $CorrelationId
    $put = Set-RbcBlob -StorageAccount $sa -Container $cont -BlobName $blobName `
                       -Content ($fresh | ConvertTo-Json -Depth 8 -Compress) -IfNoneMatchAll
    if ($put.Success) {
        return @{ State='New'; Entry=$fresh; Rearmed='None'; RecentActionsInWindow=0; MaxActionsPerDevicePerDay=$maxCap }
    }
    if ($put.Status -notin @(409, 412, 0)) {
        throw [RbcGraphError]::new("Ledger initial PUT failed (HTTP $($put.Status))", $put.Status,
            (ConvertTo-RbcErrorKind -StatusCode $put.Status), 'PUT', $blobName, '')
    }

    for ($i = 0; $i -lt $script:RbcLedgerMaxRearmAttempts; $i++) {
        $r = Get-RbcBlob -StorageAccount $sa -Container $cont -BlobName $blobName
        if (-not $r -or -not $r.Found) {
            $put2 = Set-RbcBlob -StorageAccount $sa -Container $cont -BlobName $blobName `
                                -Content ($fresh | ConvertTo-Json -Depth 8 -Compress) -IfNoneMatchAll
            if ($put2.Success) {
                return @{ State='New'; Entry=$fresh; Rearmed='None'; RecentActionsInWindow=0; MaxActionsPerDevicePerDay=$maxCap }
            }
            continue
        }
        $existing = ConvertFrom-RbcLedger -Json $r.Content
        $etag     = $r.ETag

        if ([string]$existing.CorrelationId -eq $CorrelationId) {
            return @{ State=[string]$existing.State; Entry=$existing; Rearmed='None';
                      RecentActionsInWindow=0; MaxActionsPerDevicePerDay=$maxCap }
        }

        $existingState = [string]$existing.State
        if ($existingState -eq 'Reserved') {
            return @{ State='Reserved'; Entry=$existing; Rearmed='None';
                      RecentActionsInWindow=0; MaxActionsPerDevicePerDay=$maxCap }
        }

        $decision = 'None'
        $ageHours = $null
        if ($ForceRearm -and $allowForce) {
            $decision = 'Forced'
        } else {
            $snap = Get-RbcActionStatus -Context $Context -CorrelationId ([string]$existing.CorrelationId)
            if ($snap -and ($snap['Terminal'] -eq $true)) {
                $lastChanged = $null
                if ($snap.ContainsKey('LastChangedAt') -and $snap['LastChangedAt']) {
                    try { $lastChanged = [DateTimeOffset]::Parse([string]$snap['LastChangedAt']) } catch {}
                }
                if ($lastChanged) {
                    $ageHours = ([DateTimeOffset]::UtcNow - $lastChanged).TotalHours
                }
                $ls = ([string]$snap['LastState']).ToLowerInvariant()
                if     ($script:RbcLedgerSuccessStates -contains $ls)   { $decision = 'AfterSuccess' }
                elseif ($script:RbcLedgerFailureStates -contains $ls)   { $decision = 'AfterFailure' }
                elseif ($ls -eq 'polltimeout' -and $null -ne $ageHours -and $ageHours -ge $grace) { $decision = 'AfterPollTimeout' }
            }
        }

        if ($decision -eq 'None') {
            return @{ State=$existingState; Entry=$existing; Rearmed='None';
                      RecentActionsInWindow=0; MaxActionsPerDevicePerDay=$maxCap;
                      AgeSinceTerminalHours=$ageHours }
        }

        $now    = [DateTimeOffset]::UtcNow
        $recent = @()
        foreach ($t in @($existing.RecentActionTimestamps)) {
            if (-not $t) { continue }
            try {
                $ts = [DateTimeOffset]::Parse([string]$t)
                if (($now - $ts).TotalHours -lt $script:RbcLedgerRateWindowHours) { $recent += $ts.ToString('o') }
            } catch {}
        }
        if ($recent.Count -ge $maxCap -and $decision -ne 'Forced') {
            return @{ State='RateLimited'; Entry=$existing; Rearmed='None';
                      RecentActionsInWindow=$recent.Count; MaxActionsPerDevicePerDay=$maxCap;
                      AgeSinceTerminalHours=$ageHours }
        }

        $priorTerminal = if ([string]::IsNullOrEmpty([string]$existing.LastTerminalState)) {
            switch ($existingState) {
                'Issued' { 'issued-no-tracker-feedback' }
                'Failed' { "failed:$([string]$existing.FailureReason)" }
                default  { $existingState }
            }
        } else { [string]$existing.LastTerminalState }

        $rearmed = @{
            IntuneDeviceId         = $IntuneDeviceId
            CorrelationId          = $CorrelationId
            State                  = 'Reserved'
            ReservedAt             = $now.ToString('o')
            IssuedAt               = $null
            FailedAt               = $null
            FailureReason          = $null
            Attempts               = 1
            ActionSequence         = [int]$existing.ActionSequence + 1
            LastRearmedAt          = $now.ToString('o')
            LastTerminalState      = $priorTerminal
            LastRearmReason        = $decision
            RecentActionTimestamps = $recent
        }
        $body = $rearmed | ConvertTo-Json -Depth 8 -Compress
        $put3 = Set-RbcBlob -StorageAccount $sa -Container $cont -BlobName $blobName -Content $body -IfMatch $etag
        if ($put3.Success) {
            return @{ State='New'; Entry=$rearmed; Rearmed=$decision;
                      RecentActionsInWindow=$recent.Count; MaxActionsPerDevicePerDay=$maxCap;
                      AgeSinceTerminalHours=$ageHours }
        }
        if ($put3.Status -eq 412) { continue }
        throw [RbcGraphError]::new("Ledger rearm PUT failed (HTTP $($put3.Status))", $put3.Status,
            (ConvertTo-RbcErrorKind -StatusCode $put3.Status), 'PUT', $blobName, '')
    }

    $final = Get-RbcBlob -StorageAccount $sa -Container $cont -BlobName $blobName
    if ($final -and $final.Found) {
        $finalE = ConvertFrom-RbcLedger -Json $final.Content
        return @{ State=[string]$finalE.State; Entry=$finalE; Rearmed='None';
                  RecentActionsInWindow=0; MaxActionsPerDevicePerDay=$maxCap }
    }
    return @{ State='Reserved'; Entry=$fresh; Rearmed='None'; RecentActionsInWindow=0; MaxActionsPerDevicePerDay=$maxCap }
}

function Set-RbcLedgerOutcome {
    param(
        [Parameter(Mandatory)] [hashtable]$Context,
        [Parameter(Mandatory)] [string]$IntuneDeviceId,
        [Parameter(Mandatory)] [string]$CorrelationId,
        [Parameter(Mandatory)] [ValidateSet('Issued','Failed')] [string]$Outcome,
        [string]$FailureReason
    )
    $sa       = $Context.LedgerStorageAccount
    $cont     = $Context.LedgerContainer
    $blobName = Get-RbcLedgerBlobName -IntuneDeviceId $IntuneDeviceId

    for ($i = 0; $i -lt 3; $i++) {
        $r = Get-RbcBlob -StorageAccount $sa -Container $cont -BlobName $blobName
        $current = if ($r -and $r.Found) { ConvertFrom-RbcLedger -Json $r.Content }
                   else { New-RbcLedgerEntry -IntuneDeviceId $IntuneDeviceId -CorrelationId $CorrelationId }
        $current['Attempts'] = [int]$current['Attempts'] + 1
        $now = [DateTimeOffset]::UtcNow
        if ($Outcome -eq 'Issued') {
            $current['State']    = 'Issued'
            $current['IssuedAt'] = $now.ToString('o')
            $list = @($current['RecentActionTimestamps'])
            $list += $now.ToString('o')
            $pruned = @()
            foreach ($t in $list) {
                if (-not $t) { continue }
                try {
                    $ts = [DateTimeOffset]::Parse([string]$t)
                    if (($now - $ts).TotalHours -lt $script:RbcLedgerRateWindowHours) { $pruned += $ts.ToString('o') }
                } catch {}
            }
            $current['RecentActionTimestamps'] = $pruned
        } else {
            $current['State']         = 'Failed'
            $current['FailedAt']      = $now.ToString('o')
            $current['FailureReason'] = $FailureReason
        }
        $body = $current | ConvertTo-Json -Depth 8 -Compress
        $etag = if ($r -and $r.Found) { $r.ETag } else { $null }
        $put = if ($etag) {
            Set-RbcBlob -StorageAccount $sa -Container $cont -BlobName $blobName -Content $body -IfMatch $etag
        } else {
            Set-RbcBlob -StorageAccount $sa -Container $cont -BlobName $blobName -Content $body
        }
        if ($put.Success) { return $true }
        if ($put.Status -eq 412) { Start-Sleep -Milliseconds 250; continue }
        Write-RbcWarn "Ledger $Outcome update failed (HTTP $($put.Status))" @{ device=$IntuneDeviceId }
        return $false
    }
    return $false
}

# ─── Graph pre-issue helpers ────────────────────────────────────────────────

function Resolve-RbcDeviceObjectId {
    [OutputType([string])]
    param([Parameter(Mandatory)] [string]$EntraDeviceId)
    $g = [guid]::Empty
    if (-not [guid]::TryParse($EntraDeviceId, [ref]$g)) {
        throw [System.ArgumentException]::new("entraDeviceId must be a GUID")
    }
    $uri = "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId eq '$EntraDeviceId'&`$select=id,deviceId,displayName&`$top=1"
    $resp = Invoke-RbcGraphApi -Method GET -Uri $uri
    $page = @($resp.value)
    if ($page.Count -eq 0) { return $null }
    return [string]$page[0].id
}

function Test-RbcDeviceInAllowedGroup {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string]$DeviceObjectId,
        [Parameter(Mandatory)] [string]$AllowedGroupId
    )
    $uri  = "https://graph.microsoft.com/v1.0/devices/$DeviceObjectId/checkMemberGroups"
    $body = @{ groupIds = @($AllowedGroupId) }
    $resp = Invoke-RbcGraphApi -Method POST -Uri $uri -Body $body
    $matches = @($resp.value)
    return [bool]($matches | Where-Object { $_ -ieq $AllowedGroupId })
}

function Resolve-RbcManagedDeviceId {
    [OutputType([string])]
    param([Parameter(Mandatory)] [string]$EntraDeviceId)
    $g = [guid]::Empty
    if (-not [guid]::TryParse($EntraDeviceId, [ref]$g)) {
        throw [System.ArgumentException]::new("entraDeviceId must be a GUID")
    }
    $uri  = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=azureADDeviceId eq '$EntraDeviceId'&`$select=id,deviceName,azureADDeviceId,managementState&`$top=2"
    $resp = Invoke-RbcGraphApi -Method GET -Uri $uri
    $list = @($resp.value)
    if ($list.Count -ne 1) { return $null }
    return [string]$list[0].id
}

# ─── Post-action nudges (wipe only) ─────────────────────────────────────────

function Invoke-RbcGraphPostNudge {
    param(
        [Parameter(Mandatory)] [hashtable]$Context,
        [Parameter(Mandatory)] [string]$ManagedDeviceId,
        [Parameter(Mandatory)] [ValidateSet('syncDevice','rebootNow')] [string]$Action,
        [int]$MaxAttempts = 3,
        [int[]]$BackoffSeconds = @(1, 3, 10)
    )
    $isSync       = ($Action -eq 'syncDevice')
    $issuedEvent  = if ($isSync) { $script:RbcAudit.SyncFallbackIssued }    else { $script:RbcAudit.RebootFallbackIssued }
    $retryEvent   = if ($isSync) { $script:RbcAudit.SyncFallbackRetrying }  else { $script:RbcAudit.RebootFallbackRetrying }
    $failedEvent  = if ($isSync) { $script:RbcAudit.SyncFallbackFailed }    else { $script:RbcAudit.RebootFallbackFailed }
    $exhEvent     = if ($isSync) { $script:RbcAudit.SyncFallbackExhausted } else { $script:RbcAudit.RebootFallbackExhausted }
    $uri          = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$ManagedDeviceId/$Action"

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Invoke-RbcGraphApi -Method POST -Uri $uri | Out-Null
            Write-RbcAudit -EventName $issuedEvent -Context $Context -Props @{
                managedDeviceId = $ManagedDeviceId
                attemptNumber   = $attempt
                maxAttempts     = $MaxAttempts
            }
            return
        } catch [RbcGraphError] {
            $err = $_.Exception
            if ($err.StatusCode -eq 404) {
                Write-RbcInfo "$Action returned 404 — device already gone, treating as success" @{ managedDeviceId=$ManagedDeviceId }
                return
            }
            $isTransient = ($err.Kind -eq 'Transient')
            if (-not $isTransient -or $attempt -ge $MaxAttempts) {
                $eventName = if ($isTransient) { $exhEvent } else { $failedEvent }
                Write-RbcAudit -EventName $eventName -Context $Context -Level 'Warning' -Exception $err -Props @{
                    managedDeviceId = $ManagedDeviceId
                    attemptNumber   = $attempt
                    maxAttempts     = $MaxAttempts
                }
                return
            }
            $delay = [int]($BackoffSeconds[[Math]::Min($attempt - 1, $BackoffSeconds.Length - 1)])
            Write-RbcAudit -EventName $retryEvent -Context $Context -Level 'Warning' -Exception $err -Props @{
                managedDeviceId = $ManagedDeviceId
                attemptNumber   = $attempt
                maxAttempts     = $MaxAttempts
                backoffMs       = ($delay * 1000)
            }
            Start-Sleep -Seconds $delay
        } catch {
            Write-RbcAudit -EventName $failedEvent -Context $Context -Level 'Warning' -Exception $_.Exception -Props @{
                managedDeviceId = $ManagedDeviceId
                attemptNumber   = $attempt
            }
            return
        }
    }
}

# ─── Context construction ───────────────────────────────────────────────────

function Get-RbcAutomationVar {
    param([string]$Name, $Default = $null)
    try {
        $v = Get-AutomationVariable -Name $Name -ErrorAction Stop
        if ($null -ne $v -and $v -ne '') { return $v }
    } catch {}
    return $Default
}

function New-RbcContext {
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string]$ActionType,
        [Parameter(Mandatory)] [string]$CorrelationId,
        [Parameter(Mandatory)] [string]$IntuneDeviceId,
        [string]$EntraDeviceId,
        [string]$DeviceName,
        [bool]$ForceRearm = $false
    )

    $audit  = Get-RbcAutomationVar 'AuditStorageAccount'
    $status = Get-RbcAutomationVar 'StatusStorageAccount' $audit
    $ledger = Get-RbcAutomationVar 'LedgerStorageAccount' $audit

    $ctx = @{
        ActionType     = $ActionType
        CorrelationId  = $CorrelationId
        IntuneDeviceId = $IntuneDeviceId
        EntraDeviceId  = $EntraDeviceId
        DeviceName     = $DeviceName
        ForceRearm     = $ForceRearm

        AuditStorageAccount  = $audit
        AuditTableName       = (Get-RbcAutomationVar 'AuditTableName' 'auditevents')
        StatusStorageAccount = $status
        StatusTableName      = (Get-RbcAutomationVar 'StatusTableName' 'actionstatus')
        LedgerStorageAccount = $ledger
        LedgerContainer      = (Get-RbcAutomationVar 'LedgerContainer' 'action-ledger')

        MaxActionsPerDevicePerDay = [int](Get-RbcAutomationVar 'MaxActionsPerDevicePerDay' 5)
        RearmGracePeriodHours     = [int](Get-RbcAutomationVar 'RearmGracePeriodHours' 48)
        AllowForceRearm           = [bool]::Parse((Get-RbcAutomationVar 'AllowForceRearm' 'false'))

        KeepEnrollmentData         = [bool]::Parse((Get-RbcAutomationVar 'KeepEnrollmentData' 'false'))
        KeepUserData               = [bool]::Parse((Get-RbcAutomationVar 'KeepUserData' 'false'))
        SyncFallbackDelaySeconds   = [int](Get-RbcAutomationVar 'SyncFallbackDelaySeconds' 60)
        RebootFallbackDelaySeconds = [int](Get-RbcAutomationVar 'RebootFallbackDelaySeconds' 60)
        SyncFallbackMaxAttempts    = [int](Get-RbcAutomationVar 'SyncFallbackMaxAttempts' 3)
        RebootFallbackMaxAttempts  = [int](Get-RbcAutomationVar 'RebootFallbackMaxAttempts' 3)

        AllowedGroupId = if ($ActionType -eq 'bitlocker-rotate') {
            (Get-RbcAutomationVar 'BitLockerAllowedGroupId' (Get-RbcAutomationVar 'AllowedGroupId'))
        } else {
            (Get-RbcAutomationVar 'AllowedGroupId')
        }
    }

    if (-not $ctx.AuditStorageAccount) {
        throw "Automation Variable 'AuditStorageAccount' is not set — required for audit Table writes."
    }
    return $ctx
}

# ─── Envelope parser (parity with ActionRequestMessage) ─────────────────────

function ConvertFrom-RbcEnvelope {
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] [string]$Json)
    $o = $Json | ConvertFrom-Json -Depth 32
    $inner = $o
    if ($o.PSObject.Properties.Name -contains 'payload' -and $o.payload) { $inner = $o.payload }
    elseif ($o.PSObject.Properties.Name -contains 'Payload' -and $o.Payload) { $inner = $o.Payload }

    function _g {
        param($obj, $name)
        foreach ($n in @($name, $name.Substring(0,1).ToUpperInvariant()+$name.Substring(1))) {
            if ($obj.PSObject.Properties.Name -contains $n) { return $obj.$n }
        }
        return $null
    }

    $extras = (_g $inner 'extras')
    if (-not $extras) { $extras = (_g $o 'extras') }

    $get = {
        param($n, $default = '')
        $v = (_g $inner $n)
        if ($null -eq $v -or $v -eq '') { $v = (_g $o $n) }
        if ($null -eq $v) { return $default }
        return [string]$v
    }

    $forceRaw = (_g $inner 'forceRearm')
    if ($null -eq $forceRaw) { $forceRaw = (_g $o 'forceRearm') }
    $force = ($forceRaw -eq $true) -or ([string]$forceRaw -ieq 'true')

    return @{
        ActionType     = (& $get 'actionType')
        CorrelationId  = (& $get 'correlationId')
        DeviceName     = (& $get 'deviceName')
        EntraDeviceId  = (& $get 'entraDeviceId')
        IntuneDeviceId = (& $get 'intuneDeviceId')
        ForceRearm     = $force
        Extras         = $extras
    }
}

function Get-RbcExtra {
    param($Extras, [string]$Name)
    if (-not $Extras) { return $null }
    foreach ($n in @($Name, $Name.Substring(0,1).ToUpperInvariant()+$Name.Substring(1))) {
        if ($Extras.PSObject.Properties.Name -contains $n) {
            $v = $Extras.$n
            if ($null -ne $v) { return [string]$v }
        }
    }
    return $null
}
