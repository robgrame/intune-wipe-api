<#
.SYNOPSIS
    Smoke-tests the mTLS-protected Web Function App using the test PKI generated
    by Generate-SmokePki.ps1.

.DESCRIPTION
    Two modes:

      -Mode Status (default, non-destructive):
        Sends GET /api/actions/status/<random-correlation-id> using the leaf
        cert. Expects HTTP 404 ("not-found") — proves that mTLS handshake +
        chain validation + EKU + thumbprint allow-list + cert<->device
        binding all pass without enqueuing any work.

      -Mode Request (POST → 202, generates Service Bus traffic):
        Sends POST /api/actions with a fictitious EntraDeviceId/IntuneDeviceId
        equal to the leaf CN. Expects HTTP 202 ("queued"). The downstream
        pipeline (Proc → Wipe) will fail at the Graph call ("device not
        found"), which is the expected outcome for a smoke test against a
        non-existent device. Use sparingly — leaves a "wipe-permanent-failed"
        trace in App Insights.

.PARAMETER FunctionAppHost
    FQDN of the Web Function App. Defaults to the dev app.

.PARAMETER FunctionKey
    Function key for /api/actions and /api/actions/status. If omitted, fetched
    on the fly via "az functionapp keys list" (you must be az-logged-in).

.PARAMETER ResourceGroup
    Resource group of the Function App, used only when -FunctionKey is omitted.

.PARAMETER MetaJsonPath
    Path to the meta.json produced by Generate-SmokePki.ps1. Default is
    smoke-pki\meta.json next to this script.

.PARAMETER Mode
    Status | Request

.EXAMPLE
    .\Invoke-SmokeTest.ps1
    .\Invoke-SmokeTest.ps1 -Mode Request

.NOTES
    Requires PowerShell 7.x for -SkipCertificateCheck-free TLS negotiation with
    server cert from a public CA + client cert from our test PKI. Server-side
    cert validation is NOT skipped — only the client cert side is asserted.
#>
[CmdletBinding()]
param(
    [Parameter()] [string] $FunctionAppHost = 'idactions-web-kngz2afknjtjk.azurewebsites.net',
    [Parameter()] [string] $FunctionKey,
    [Parameter()] [string] $ResourceGroup = 'rg-idactions-dev',
    [Parameter()] [string] $FunctionAppName = 'idactions-web-kngz2afknjtjk',
    [Parameter()] [string] $MetaJsonPath = (Join-Path $PSScriptRoot 'smoke-pki\meta.json'),
    [Parameter()] [ValidateSet('Status','Request','RoundTrip')] [string] $Mode = 'RoundTrip'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path $MetaJsonPath)) {
    throw "PKI metadata not found at '$MetaJsonPath'. Run Generate-SmokePki.ps1 first."
}
$meta = Get-Content $MetaJsonPath -Raw | ConvertFrom-Json

if (-not (Test-Path $meta.leafPfxPath)) {
    throw "Leaf PFX not found at '$($meta.leafPfxPath)'. Re-run Generate-SmokePki.ps1."
}

# Load the leaf cert + private key from the PFX. Use the X509Certificate2
# (X509KeyStorageFlags.MachineKeySet not needed; CurrentUser is fine for a
# one-shot smoke test).
$pwd  = ConvertTo-SecureString -String $meta.pfxPassword -AsPlainText -Force
$leaf = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
    $meta.leafPfxPath,
    $pwd,
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet -bor `
    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
)

if (-not $leaf.HasPrivateKey) {
    throw "Loaded leaf cert does NOT carry a private key — cannot mTLS-authenticate."
}

if (-not $FunctionKey) {
    Write-Host "==> Fetching function key for $FunctionAppName via az CLI..."
    $FunctionKey = az functionapp keys list -g $ResourceGroup -n $FunctionAppName --query 'functionKeys.default' -o tsv 2>$null
    if (-not $FunctionKey) {
        $FunctionKey = az functionapp keys list -g $ResourceGroup -n $FunctionAppName --query 'masterKey' -o tsv
    }
    if (-not $FunctionKey) { throw "Could not retrieve function key. Pass -FunctionKey explicitly." }
}

$headers = @{
    'x-functions-key'      = $FunctionKey
    'X-Request-Timestamp'  = (Get-Date).ToUniversalTime().ToString('o')
    'X-Request-Nonce'      = [Guid]::NewGuid().ToString()
}

function Invoke-StatusCheck {
    param([string]$Corr, [hashtable]$BaseHeaders, [string]$ExpectedHttpHint)
    # Status doesn't enforce replay headers but accepts them; always re-roll
    # the nonce so a previous send doesn't trip the in-memory replay cache.
    $hdrs = $BaseHeaders.Clone()
    $hdrs['X-Request-Timestamp'] = (Get-Date).ToUniversalTime().ToString('o')
    $hdrs['X-Request-Nonce']     = [Guid]::NewGuid().ToString()
    $uri = "https://$FunctionAppHost/api/actions/status/$Corr"
    Write-Host "==> GET $uri  ($ExpectedHttpHint)"
    try {
        $resp = Invoke-WebRequest -Uri $uri -Method Get -Headers $hdrs -Certificate $leaf -UseBasicParsing
        Write-Host "RESULT: HTTP $($resp.StatusCode)" -ForegroundColor Green
        Write-Host "Body:   $($resp.Content)"
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $resp.Content }
    }
    catch {
        $sc  = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { -1 }
        $msg = if ($_.ErrorDetails)       { $_.ErrorDetails.Message }               else { $_.Exception.Message }
        $color = if ($sc -in 404, 200) { 'Green' } else { 'Red' }
        Write-Host "RESULT: HTTP $sc" -ForegroundColor $color
        Write-Host "Body:   $msg"
        return [pscustomobject]@{ Status = $sc; Body = $msg }
    }
}

switch ($Mode) {
    'Status' {
        $corr = [Guid]::NewGuid().ToString('N')
        $r = Invoke-StatusCheck -Corr $corr -BaseHeaders $headers -ExpectedHttpHint 'expect 404 not-found'
        if ($r.Status -ne 404) { throw "Expected 404, got $($r.Status)" }
    }
    'Request' {
        $uri  = "https://$FunctionAppHost/api/actions"
        $body = @{
            actionType     = 'wipe'
            deviceName     = "smoke-test-$($meta.entraDeviceId.Substring(0,8))"
            entraDeviceId  = $meta.entraDeviceId
            intuneDeviceId = $meta.entraDeviceId   # NOT a real Intune id — Graph will 404 downstream (expected)
        } | ConvertTo-Json -Compress
        $headers['Content-Type'] = 'application/json'
        Write-Host "==> POST $uri  (expect 202 queued)"
        Write-Host "    body: $body"
        try {
            $resp = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -Certificate $leaf -Body $body -UseBasicParsing
            Write-Host "RESULT: HTTP $($resp.StatusCode) — request queued." -ForegroundColor Green
            Write-Host "Body:   $($resp.Content)"
        }
        catch {
            $sc = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { -1 }
            $msg = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            Write-Host "RESULT: HTTP $sc" -ForegroundColor Red
            Write-Host "Body:   $msg"
            throw
        }
    }
    'RoundTrip' {
        # 1) Status on a random correlationId — must return 404 (proves auth+tracker read path).
        $randomCorr = [Guid]::NewGuid().ToString('N')
        Write-Host ""
        Write-Host "── STEP 1/3: Status on unknown corr (expect 404) ───────────────"
        $r1 = Invoke-StatusCheck -Corr $randomCorr -BaseHeaders $headers -ExpectedHttpHint 'expect 404'
        if ($r1.Status -ne 404) { throw "STEP 1 failed: expected 404, got $($r1.Status)" }

        # 2) Submit a real action.
        Write-Host ""
        Write-Host "── STEP 2/3: POST /api/actions (expect 202) ───────────────────"
        $uri  = "https://$FunctionAppHost/api/actions"
        $body = @{
            actionType     = 'wipe'
            deviceName     = "smoke-test-$($meta.entraDeviceId.Substring(0,8))"
            entraDeviceId  = $meta.entraDeviceId
            intuneDeviceId = $meta.entraDeviceId
        } | ConvertTo-Json -Compress
        $postHdrs = $headers.Clone()
        $postHdrs['Content-Type'] = 'application/json'
        Write-Host "==> POST $uri"
        Write-Host "    body: $body"
        $postResp = Invoke-WebRequest -Uri $uri -Method Post -Headers $postHdrs -Certificate $leaf -Body $body -UseBasicParsing
        if ([int]$postResp.StatusCode -ne 202) { throw "STEP 2 failed: expected 202, got $($postResp.StatusCode)" }
        $postObj = $postResp.Content | ConvertFrom-Json
        $newCorr = $postObj.correlationId
        Write-Host "RESULT: HTTP 202  corr=$newCorr" -ForegroundColor Green

        # 3) Poll the status. Now that the wipe runner writes a terminal row
        #    on every denial path (commit after rubber-duck pass), STEP 3 must
        #    reach HTTP 200. For a fictitious smoke device the row will carry
        #    LastState='denied:device-not-in-entra' and Terminal=true.
        Write-Host ""
        Write-Host "── STEP 3/3: Poll status until 200 (timeout 60s) ──────────────"
        $deadline = (Get-Date).AddSeconds(60)
        $r3 = $null
        do {
            Start-Sleep -Seconds 5
            $r3 = Invoke-StatusCheck -Corr $newCorr -BaseHeaders $headers -ExpectedHttpHint 'polling…'
            if ($r3.Status -eq 200) { break }
        } while ((Get-Date) -lt $deadline)

        if ($r3.Status -ne 200) {
            throw "STEP 3 failed: expected 200 within 60s (last=$($r3.Status)). The wipe runner should write a terminal status row on the denial path."
        }
        $snap = $r3.Body | ConvertFrom-Json
        Write-Host ""
        Write-Host "SMOKE TEST PASSED ✓ — tracker write+read path validated end-to-end." -ForegroundColor Green
        Write-Host "  corr      = $($snap.correlationId)"
        Write-Host "  device    = $($snap.deviceName)"
        Write-Host "  state     = $($snap.state)"
        Write-Host "  terminal  = $($snap.terminal)"
        Write-Host "  issuedAt  = $($snap.issuedAt)"
        if ($snap.terminal -ne $true) {
            Write-Warning "Status row is non-terminal — expected denial path to mark terminal=true."
        }
        if ($snap.state -notlike 'denied:*' -and $snap.state -notlike 'failed:*' -and $snap.state -ne 'pending') {
            Write-Warning "Unexpected state '$($snap.state)' — expected denied:* / failed:* / pending."
        }
    }
}
