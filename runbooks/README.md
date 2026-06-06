# Runbook variant — alternative capability executors (parità funzionale)

Questa cartella contiene una **variante alternativa** dei 3 esecutori delle
capability, scritti in PowerShell 7.2 e ospitati su Azure Automation:

| Capability | Function App runner (default) | Runbook variant |
|---|---|---|
| `wipe` | `IntuneDeviceActions.Wipe` ─ `WipeActionRunner.cs` | `Invoke-DeviceWipe.runbook.ps1` |
| `autopilot-register` | `IntuneDeviceActions.Autopilot` ─ `AutopilotRegisterRunner.cs` | `Invoke-AutopilotRegister.runbook.ps1` |
| `bitlocker-rotate` | `IntuneDeviceActions.BitLocker` ─ `BitLockerRotateRunner.cs` | `Invoke-RotateBitLockerKey.runbook.ps1` |

Tutti girano su **Azure Automation, runtime PowerShell 7.2**, agganciati
esattamente alla stessa infrastruttura core (HTTP front-end, dispatcher,
code Service Bus, audit table, ledger blob, action-status table).

## Razionale

L'architettura plug-in via `IActionRunner` dimostra il modello sul runtime
.NET. La variante runbook **dimostra che ogni capability può essere
implementata in un linguaggio/runtime diverso** senza toccare nessun
componente core:

```
HTTP front-end → Service Bus / dispatcher (invariato)
       ↓
   ActionDispatchFunction (router invariato)
       ↓
   RunbookWebhookRunner (singolo generico, registrato N volte
   automaticamente al boot leggendo App Config
   RunbookBridge:Routes:<actionType>=<webhook>)
       ↓ POST webhook
   Invoke-<Capability>.runbook.ps1 + RunbookCore.ps1
       → resolve / group / ownership / idempotency / Graph / audit
```

## Parità funzionale con le Function

I 3 runbook ora replicano **esattamente** lo stesso state machine dei
runner .NET — non più un demo minimale. Ciascuno esegue, nell'ordine
identico al runner di riferimento:

1. **Resolve Entra device object id** (`Graph /devices?$filter=deviceId eq …`)
   con classificazione errori Transient (408/429/5xx → re-throw per retry) /
   Permanent (4xx → audit + terminal status). **Non eseguito** per
   `autopilot-register` — è intenzionale, lo stesso vale per il runner .NET
   perché Autopilot deve funzionare su hardware non ancora hybrid-joined.
2. **Group membership check** via `checkMemberGroups` contro l'`AllowedGroupId`
   (variabile Automation; per BitLocker fallback su `BitLockerAllowedGroupId`).
   **Non eseguito** per `autopilot-register`.
3. **Ownership validation** risolvendo `managedDevices` via
   `azureADDeviceId` (fail-closed su 0 o ≥2 match). **Non eseguito** per
   `autopilot-register`.
4. **Idempotency ledger** sul blob `<intuneDeviceId>.json` nel container
   `action-ledger` (PUT-If-None-Match per il primo lock, PUT-If-Match per
   l'auto-rearm con ETag optimistic concurrency). Auto-rearm guidato dallo
   status tracker — riconosce gli stati terminali `done` /
   `removedFromIntune` (after-success), `failed` / `canceled` / `notSupported`
   (after-failure), `polltimeout` con grace period (after-timeout) — e applica
   il rate limiter rolling 24h con cap configurabile
   (`MaxActionsPerDevicePerDay`, default 5). Identici eventi audit
   (`action.already-issued`, `action.in-progress-elsewhere`,
   `action.ledger.rearmed.*`, `action.denied.rate-limited`).
5. **Chiamata Graph dell'azione** con la stessa classificazione
   Transient/Permanent del runner .NET; su Permanent il ledger è marcato
   `Failed`, il tracker registra `failed:permanent`, audit dedicato emesso
   (`wipe.graph.failed-permanent` / `autopilot.graph.import.failed-permanent`
   / `bitlocker.graph.rotate.failed-permanent`) e l'errore **non** è
   re-thrown (no retry su permanent — identico al runner .NET).
6. **Initialize action-status tracker** (`actionstatus` table, row
   `correlationId/status` con `Terminal=false LastState=pending`) così
   `GET /api/actions/status` vede l'azione issued anche dal runbook.
7. **Post-action nudges** (solo `wipe`): `syncDevice` poi `rebootNow` con
   backoff retry bounded — stessa logica `WipeActionRunner.RunNudgeWithRetryAsync`
   (404 trattato come success, exhausted/failed eventi audit). Le delay e
   max-attempts sono configurabili via Automation Variables
   (`SyncFallbackDelaySeconds`, `SyncFallbackMaxAttempts`,
   `RebootFallbackDelaySeconds`, `RebootFallbackMaxAttempts`; default
   60s/3 attempts ognuno).

Tutti i path "denied:\*" granulari sono replicati con lo stesso evento audit
e lo stesso `LastState` sulla actionstatus table:
`denied:device-resolve-failed`, `denied:device-not-in-entra`,
`denied:group-check-failed`, `denied:not-in-allowed-group`,
`denied:managed-device-resolve-failed`, `denied:ownership-mismatch`,
`denied:rate-limited`, `denied:already-issued`,
`denied:in-progress-elsewhere`, `denied:missing-hardware-hash` (Autopilot).

### Differenze esplicite rispetto al runner .NET

| Aspetto | Function App runner | Runbook runner | Note |
|---|---|---|---|
| Audit App Insights customEvents | sì (TrackEvent) | **no** | Il sink Table `auditevents` è il canale durevole canonico (90-giorni AI cap vs anni su Table); il job stream Automation è la controparte live del log del worker. |
| Audit Table `auditevents` | sì | sì (schema-compatibile) | Stesso PartitionKey=correlationId, RowKey=`{ticks:D19}_{guid8}`, stesse colonne promosse (Name/Level/EventTimestamp/DeviceName/EntraDeviceId/IntuneDeviceId/ManagedDeviceId/Reason/ExceptionType/ExceptionMessage/PropertiesJson). KQL/queries spans entrambi i runner senza modifiche. |
| Audit metadata `source` | `wipe-runner` / `proc-host` / ecc. | `runbook` | Permette di filtrare per origine. |
| Idempotency ledger | identico (stessa JSON shape, stesso container) | identico (PUT-If-None-Match / PUT-If-Match REST diretto via token Storage del MI) | |
| ActionStatusTracker | identico | identico (stessa table, stessa shape) | |
| Post-action nudges | configurabili da `Wipe:*FallbackDelaySeconds`/`*FallbackMaxAttempts` | configurabili da Automation Variables `SyncFallback*` / `RebootFallback*` | Stessa logica e stessi audit events. |

## Architettura del codice

```
runbooks/
├── _lib/
│   └── RunbookCore.ps1          ← toolkit condiviso (~900 LOC):
│                                    Get-RbcGraphToken, Invoke-RbcGraphApi,
│                                    Reserve-RbcLedger, Set-RbcLedgerOutcome,
│                                    Initialize-RbcActionStatus, Write-RbcAudit,
│                                    Resolve-RbcDeviceObjectId,
│                                    Test-RbcDeviceInAllowedGroup,
│                                    Resolve-RbcManagedDeviceId,
│                                    Invoke-RbcGraphPostNudge, ecc.
├── Invoke-DeviceWipe.runbook.ps1          ← entry-point con marker
├── Invoke-AutopilotRegister.runbook.ps1   ← entry-point con marker
└── Invoke-RotateBitLockerKey.runbook.ps1  ← entry-point con marker
```

Azure Automation **non supporta** dot-source / module-import per librerie
"runbook-local". Per evitare di duplicare ~900 righe di helper in 3 file:

- Ciascun runbook contiene il marker `# >>> RBC-LIB-INSERTION-POINT <<<`
  posizionato **immediatamente dopo il blocco `param()`** (deve restare
  come prima istruzione eseguibile dello script).
- `tools/Deploy-IntuneDeviceActions.ps1` durante `Invoke-RunbookPublish`
  legge `_lib/RunbookCore.ps1`, sostituisce il marker con il contenuto
  del lib, scrive il file merged in `$env:TEMP\<guid>\<runbook>.ps1`,
  e lo carica su Azure Automation con `az automation runbook
  replace-content --content "@<merged-file>"` seguito da `publish`.
- Il file merged è auto-contenuto: Automation esegue lo script come
  unica unità senza dipendenze esterne (oltre ad `Az.Accounts` per il
  token via Managed Identity).

## Wire-up

1. **Deploy Bicep** con `enableRunbookVariant=true` (default). Crea:
   - Automation Account `<namePrefix>-aa-<suffix>` con SystemAssigned MI.
   - Automation Variables: `LedgerStorageAccount`, `LedgerContainer`,
     `AuditStorageAccount`, `AuditTableName`, `StatusStorageAccount`,
     `StatusTableName`, `AllowedGroupId`, `BitLockerAllowedGroupId`,
     `KeepEnrollmentData`, `KeepUserData`, `MaxActionsPerDevicePerDay`.
   - 3 runbook resource vuote ("shell").
   - Role assignments per la MI dell'AA:
     - `Storage Blob Data Contributor` su `ledger-container`
     - `Storage Table Data Contributor` su `storageProc` (copre
       `auditevents` + `actionstatus`).

2. **`tools/Deploy-IntuneDeviceActions.ps1`** (step `Invoke-RunbookPublish`)
   merging + uploading dei 3 runbook (lib + entry-point) tramite
   `az automation runbook replace-content` + `publish`.

3. **`tools/Grant-GraphPermissions.ps1`** (sezione "Optional: Automation
   Account") concede i ruoli Graph alla SystemAssigned MI dell'AA:
   - `DeviceManagementManagedDevices.PrivilegedOperations.All` (wipe, rotateBitLockerKeys)
   - `DeviceManagementManagedDevices.Read.All` (resolve managedDevice)
   - `DeviceManagementServiceConfig.ReadWrite.All` (autopilot import)
   - `Device.Read.All`, `GroupMember.Read.All`

4. **Per agganciarli al dispatcher (zero-code)**:
   1. Crea un webhook su ciascuna runbook
      (`New-AzAutomationWebhook -RunbookName Invoke-DeviceWipe -Name wipe-bridge -ExpiryTime (Get-Date).AddYears(1) -IsEnabled $true …`)
      e copia l'URI restituito (è mostrato UNA sola volta).
   2. Inserisci l'URI in App Configuration (Key Vault reference raccomandata):
      ```
      RunbookBridge:Routes:wipe-runbook            = https://<aa>.webhook.<region>.azure-automation.net/webhooks?token=…
      RunbookBridge:Routes:autopilot-runbook       = https://…
      RunbookBridge:Routes:bitlocker-rotate-runbook= https://…
      ```
   3. Restart dell'app `idactions-proc` (o aspetta il prossimo cold-start
      Flex). Il dispatcher core risolve l'`actionType` tramite il
      `RunbookWebhookRunner` generico registrato al boot da
      `services.AddIntuneDeviceActionsCore(ctx.Configuration)` →
      `RunbookBridgeExtensions.AddRunbookBridgeRunners`.
   4. Aggiungi gli `actionType` ai `Actions:AllowedTypes` (CSV) per
      autorizzare il client a richiederli.

   Nessuna nuova classe C# da scrivere, nessuna modifica al Bicep core,
   nessuna nuova coda Service Bus.

## Test locale di una runbook

```pwsh
# Sintassi del singolo entry-point
$err = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\runbooks\Invoke-DeviceWipe.runbook.ps1), [ref]$null, [ref]$err)
if ($err) { $err } else { 'syntax OK' }

# Sintassi del file MERGED (quello che andrà su Automation)
$lib    = Get-Content .\runbooks\_lib\RunbookCore.ps1 -Raw
$body   = Get-Content .\runbooks\Invoke-DeviceWipe.runbook.ps1 -Raw
$merged = $body.Replace('# >>> RBC-LIB-INSERTION-POINT <<<', $lib)
$tmp    = "$env:TEMP\merged.ps1"
Set-Content $tmp $merged
[System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$null) | Out-Null
```

Esecuzione end-to-end fuori dall'Automation Account: richiede
`Connect-AzAccount` con un identity che abbia gli stessi ruoli Graph + Storage
della SystemAssigned MI dell'AA. Non consigliato — usa il portale o
`Start-AzAutomationRunbook` con un envelope JSON di test.

## Quando preferirla?

- **Ops PowerShell-centric**: il runbook può essere debuggato/editato
  in-portal senza CI/CD, con visibilità diretta sul job stream.
- **Cap di costo molto basso**: 500 min/mese gratis su Automation;
  tipicamente €0.
- **Demo al cliente** del modello plug-in zero-code: stesso envelope,
  due implementazioni intercambiabili, runtime diversi, audit unificato.

## Quando NON usarla?

- **Latenza alta vs Flex Consumption Function**: Automation jobs
  hanno un cold-start nell'ordine di 30–60s (vs 1–3s per Flex). Per
  carichi sub-secondo o burst, le Function App restano preferibili.
- **Esecuzione parallela su scala**: il job concurrency su Automation è
  limitato dallo SKU (Basic: 200 concurrent jobs); Function Flex scala
  orizzontalmente fino al cap configurato.
- **Affiancata alle Function**: NON usare entrambi i runner per lo
  stesso `actionType` contemporaneamente — il ledger è single-writer
  per device ma il dispatcher invierebbe lo stesso messaggio a entrambi
  raddoppiando audit e introducendo race su ETag. Usa l'allowlist
  `Actions:AllowedTypes` per scegliere uno solo dei due
  (`wipe` → Function, `wipe-runbook` → Runbook).
