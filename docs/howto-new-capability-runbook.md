# How-to: aggiungere una nuova capability con un Azure Runbook

Guida passo-passo per implementare una **nuova capability** (es. `restart-device`,
`collect-logs`, `defender-scan`, …) usando un **Azure Automation PowerShell
Runbook** invece di una nuova Function App.

Questo è il path **zero-code-core**: nessuna nuova classe C#, nessun nuovo
progetto, nessuna modifica al dispatcher né al contratto `ActionDispatchMessage`.
La nuova capability si aggancia al core esistente via webhook + App Configuration.

> **Quando preferirlo:** ops PowerShell-centric, latenza tollerante (cold-start
> ~30–60 s), volume basso (< qualche centinaio di azioni/giorno per capability).
> Per latenze sub-secondo o burst usa la guida Function — vedi
> [`howto-new-capability-function.md`](./howto-new-capability-function.md).

---

## Prerequisiti

- L'infrastruttura core è già deployata (`infra/main.bicep` o `main-public.bicep`).
- L'**Automation Account** è presente (`<namePrefix>-aa-<suffix>`) con
  SystemAssigned Managed Identity abilitata.
- Hai accesso owner/contributor sull'AA e ai ruoli per concedere permessi
  Graph alla MI (Application Admin + Privileged Role Admin oppure Global Admin).

---

## Panoramica del flusso (cosa farà la nuova capability)

```
Client mTLS POST /api/v2/actions { "type": "<newcap>", ... }
       ↓
ActionRequestFunction → coda `action-requests`
       ↓
RequestIntakeFunction → coda `action-dispatch`
       ↓
ActionDispatchFunction (router) risolve runner per type=<newcap>
       ↓                              ↑ registrato al boot leggendo
                                       App Config RunbookBridge:Routes:<newcap>
RunbookWebhookRunner (generico, già esistente)
       ↓ HTTP POST {webhookUri}
Azure Automation crea job → esegue Invoke-<NewCap>.runbook.ps1
       ↓
toolkit RunbookCore.ps1: Graph + ledger blob + status table + audit table
```

**Nessuna modifica al core.** Tutto quello che serve sta in 4 punti:
1. uno script PowerShell nella cartella `runbooks/`
2. una risorsa runbook nel Bicep
3. un webhook generato post-deploy + URI in App Configuration
4. l'aggiunta del tipo all'allow-list `Actions:AllowedTypes`

---

## Step 1 — Scrivere lo script del runbook

Crea `runbooks/Invoke-<NewCap>.runbook.ps1`. **Mantieni questa struttura
esatta** (param block come prima istruzione, poi marker, poi body):

```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [object] $WebhookData
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# >>> RBC-LIB-INSERTION-POINT <<<
# ^ NON cancellare e NON spostare questo marker.
#   Il deploy script sostituisce questa riga col contenuto di
#   runbooks/_lib/RunbookCore.ps1 prima dell'upload su Automation.

$ctx = New-RbcContext -ActionType '<newcap>' -WebhookData $WebhookData
try {
    # ------------------------------------------------------------------
    # 1. Resolve device (se la capability è device-scoped — opzionale)
    # ------------------------------------------------------------------
    $entraId = Resolve-RbcDeviceObjectId -Context $ctx
    if (-not $entraId) { return }   # già auditato + status terminale

    # ------------------------------------------------------------------
    # 2. Group membership (opzionale, salta per capability non gated)
    # ------------------------------------------------------------------
    if (-not (Test-RbcDeviceInAllowedGroup -Context $ctx -EntraObjectId $entraId)) {
        return
    }

    # ------------------------------------------------------------------
    # 3. Ownership → managedDeviceId (opzionale, solo se chiami /managedDevices)
    # ------------------------------------------------------------------
    $managedId = Resolve-RbcManagedDeviceId -Context $ctx
    if (-not $managedId) { return }

    # ------------------------------------------------------------------
    # 4. Idempotency ledger (CONSIGLIATO — replay-safe, rate limited)
    # ------------------------------------------------------------------
    $ledger = Reserve-RbcLedger -Context $ctx
    if (-not $ledger.Reserved) { return }   # già issued / rate-limited

    # ------------------------------------------------------------------
    # 5. Chiamata Graph dell'azione (CUORE DELLA CAPABILITY)
    # ------------------------------------------------------------------
    try {
        $resp = Invoke-RbcGraphApi `
            -Context $ctx `
            -Method  'POST' `
            -Uri     "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/$managedId/<yourGraphAction>" `
            -Body    @{ }      # corpo specifico della tua action
        Set-RbcLedgerOutcome -Context $ctx -State 'Issued'
        Write-RbcAudit -Context $ctx -Event '<newcap>.graph.issued' -Level Information
        Initialize-RbcActionStatus -Context $ctx -State 'pending'
    }
    catch [RbcGraphError] {
        $kind = ConvertTo-RbcErrorKind $_.Exception
        if ($kind -eq 'Permanent') {
            Set-RbcLedgerOutcome -Context $ctx -State 'Failed' -Reason $_.Exception.Message
            Write-RbcAudit -Context $ctx -Event '<newcap>.graph.failed-permanent' -Level Error -Exception $_.Exception
            Write-RbcTerminalStatus -Context $ctx -State 'failed:permanent'
            return    # NO re-throw → no retry
        }
        throw         # Transient → Automation retry
    }
}
catch {
    Write-RbcAudit -Context $ctx -Event '<newcap>.unhandled' -Level Error -Exception $_.Exception
    throw
}
```

### Riferimenti

Copia/adatta da uno dei 3 esistenti — sono tutti annotati e completi:
- `runbooks/Invoke-DeviceWipe.runbook.ps1` — pipeline più complessa (con
  ownership-check + post-action nudges).
- `runbooks/Invoke-RotateBitLockerKey.runbook.ps1` — pipeline standard
  device-scoped senza nudges.
- `runbooks/Invoke-AutopilotRegister.runbook.ps1` — pipeline **senza**
  device resolve / group / ownership (utile per capability che agiscono su
  hardware non ancora hybrid-joined).

### Cosa offre `RunbookCore.ps1` (toolkit)

| Helper | Cosa fa |
|---|---|
| `New-RbcContext` | Crea context con token Graph/Storage cached, correlationId, action params. |
| `ConvertFrom-RbcEnvelope` | Parse del WebhookData accettando sia `ActionDispatchMessage` sia `ActionRequestMessage`. |
| `Resolve-RbcDeviceObjectId` | Risolve l'Entra device object id dal device id. Audit + status su fallimento. |
| `Test-RbcDeviceInAllowedGroup` | `checkMemberGroups` contro `AllowedGroupId`. Audit + status su fail. |
| `Resolve-RbcManagedDeviceId` | Lookup `managedDevices` per `azureADDeviceId` (fail-closed se 0 o ≥2). |
| `Reserve-RbcLedger` | Lock blob PUT-If-None-Match + auto-rearm + rate limiter 24h. |
| `Set-RbcLedgerOutcome` | Marca `Issued` / `Failed` con PUT-If-Match. |
| `Initialize-RbcActionStatus` | Crea row `status` su `actionstatus` table. |
| `Write-RbcTerminalStatus` | Aggiorna status con `Terminal=true LastState=<x>`. |
| `Invoke-RbcGraphApi` | HTTP wrapper Graph con error → `[RbcGraphError]`. |
| `ConvertTo-RbcErrorKind` | Classifica `Transient` / `Permanent` (408/429/5xx vs 4xx). |
| `Write-RbcAudit` | Append row su `auditevents` (schema compatibile col sink .NET). |
| `Invoke-RbcGraphPostNudge` | Helper per nudges con retry bounded (404=success). |

---

## Step 2 — Aggiungere la risorsa runbook al Bicep

Apri `infra/main.bicep` (e/o `infra/main-public.bicep`). Cerca dove sono
dichiarati gli altri 3 runbook (cerca `Microsoft.Automation/automationAccounts/runbooks`)
e aggiungi una quarta risorsa identica:

```bicep
resource runbookNewCap 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name:   'Invoke-<NewCap>'
  location: location
  properties: {
    runbookType:    'PowerShell72'
    logVerbose:     false
    logProgress:    false
    logActivityTrace: 0
    description:    'Runbook variant for <newcap> capability'
  }
}
```

**Variabili Automation aggiuntive** — solo se la capability ha parametri
specifici (es. `MaxLogLinesPerCollection`). Aggiungi `Microsoft.Automation/automationAccounts/variables`
seguendo il pattern degli `aaVar*` esistenti (intorno alle righe 906+ di main.bicep).
**Non** servono ledger/audit/status — quelle variabili sono già configurate
e condivise tra tutti i runbook.

Build di verifica:

```pwsh
az bicep build --file infra/main.bicep
```

---

## Step 3 — Concedere i permessi Graph alla MI dell'AA

Modifica `tools/Grant-GraphPermissions.ps1`: nella sezione che gestisce
l'Automation Account (`Optional: Automation Account`) aggiungi i nuovi
ruoli Graph richiesti dalla tua capability, ad esempio:

```pwsh
'DeviceManagementManagedDevices.PrivilegedOperations.All',   # già presente
'DeviceManagementManagedDevices.ReadWrite.All',              # nuovo per <newcap>
```

Esegui lo script dopo il deploy bicep:

```pwsh
.\tools\Grant-GraphPermissions.ps1 -ResourceGroup <rg> -IncludeAutomationAccount
```

> **Permessi necessari per eseguire questo step:** *Privileged Role
> Administrator* + *Application Administrator* (oppure *Global Administrator*).

---

## Step 4 — Deploy

```pwsh
.\tools\Deploy-IntuneDeviceActions.ps1 -ResourceGroup <rg>
```

Lo step `Invoke-RunbookPublish` automaticamente:
1. enumera tutti i `runbooks/Invoke-*.runbook.ps1` (raccoglie anche il tuo)
2. esegue marker-substitution con `_lib/RunbookCore.ps1`
3. carica il merged via `az automation runbook replace-content` + `publish`.

**Nessuna modifica richiesta a `Deploy-IntuneDeviceActions.ps1`.**

---

## Step 5 — Creare il webhook e registrarlo in App Configuration

Genera il webhook una sola volta (l'URI con token è mostrato **solo** in
questo momento — salvalo subito):

```pwsh
$webhook = New-AzAutomationWebhook `
    -ResourceGroupName <rg> `
    -AutomationAccountName <aaName> `
    -RunbookName 'Invoke-<NewCap>' `
    -Name '<newcap>-bridge' `
    -ExpiryTime (Get-Date).AddYears(1) `
    -IsEnabled $true `
    -Force
$webhookUri = $webhook.WebhookURI   # ← copia subito, non viene più mostrato
```

Carica l'URI come **Key Vault reference** in App Configuration:

```pwsh
# 1. metti il secret in Key Vault
az keyvault secret set --vault-name <kv> --name 'RunbookBridge--<newcap>' --value $webhookUri

# 2. crea la key in App Config che referenzia il secret
az appconfig kv set-keyvault `
    --name <appCfgName> `
    --key 'RunbookBridge:Routes:<newcap>' `
    --secret-identifier "https://<kv>.vault.azure.net/secrets/RunbookBridge--<newcap>"
```

---

## Step 6 — Allow-listare il tipo

```pwsh
az appconfig kv set `
    --name <appCfgName> `
    --key 'Actions:AllowedTypes' `
    --value 'wipe,autopilot-register,bitlocker-rotate,<newcap>'
```

Restart dell'app `idactions-proc` (o aspetta il prossimo cold-start Flex).
Il dispatcher rileggerà App Config al boot, troverà la route, registrerà
un `RunbookWebhookRunner` aggiuntivo per `<newcap>`.

---

## Step 7 — Aggiungere lo script client

In `client/` crea `Invoke-<NewCap>.ps1` ricalcato su uno degli esistenti
(es. `Invoke-BitLockerKeyRotation.ps1`):

```pwsh
.\Invoke-<NewCap>.ps1 -ApiBaseUrl 'https://<webApp>/api/v2/actions' `
                     -ClientCertThumbprint '<thumb>'
```

Il client costruisce il payload `ActionRequest` con `type=<newcap>` e
campi extra eventualmente necessari (vanno in `extras` — il toolkit li
recupera via `Get-RbcExtra -Context $ctx -Name '<field>'`).

---

## Step 8 — Test

```pwsh
.\Invoke-<NewCap>.ps1 ...

# segui il job sul portal: AA → Runbooks → Invoke-<NewCap> → Jobs
# verifica:
# - 1 row nella status table actionstatus per il correlationId
# - 1 ledger blob in action-ledger
# - N row audit in auditevents
```

KQL su Log Analytics (se collegato):

```kusto
StorageTableLogs
| where TimeGenerated > ago(10m)
| where Uri endswith 'auditevents'
```

---

## Riepilogo file toccati per una nuova capability runbook

| File | Modifica |
|---|---|
| `runbooks/Invoke-<NewCap>.runbook.ps1` | **NUOVO** — entry-point script |
| `infra/main.bicep` + `main-public.bicep` | 1 risorsa runbook (+ eventuali variabili specifiche) |
| `tools/Grant-GraphPermissions.ps1` | (opz.) nuovi Graph role per la MI dell'AA |
| App Configuration | 2 key: `RunbookBridge:Routes:<newcap>` + aggiornamento `Actions:AllowedTypes` |
| `client/Invoke-<NewCap>.ps1` | **NUOVO** — script client |

**Zero modifiche** a: dispatcher (`ActionDispatchFunction`), router
(`Microsoft.Extensions.DependencyInjection` setup), code Service Bus core,
contratto `ActionDispatchMessage`, schema audit/ledger/status, RBAC core,
Function App esistenti.
