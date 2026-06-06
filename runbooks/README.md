# Runbook variant — alternative capability executors (demo)

Questa cartella contiene una **variante alternativa** dei 3 esecutori
delle capability:

| Capability | Function App runner (default) | Runbook variant |
|---|---|---|
| `wipe` | `IntuneDeviceActions.Wipe` ─ `WipeActionRunner.cs` | `Invoke-DeviceWipe.runbook.ps1` |
| `autopilot-register` | `IntuneDeviceActions.Autopilot` ─ `AutopilotRegisterRunner.cs` | `Invoke-AutopilotRegister.runbook.ps1` |
| `bitlocker-rotate` | `IntuneDeviceActions.BitLocker` ─ `BitLockerRotateRunner.cs` | `Invoke-RotateBitLockerKey.runbook.ps1` |

Tutti girano su **Azure Automation, runtime PowerShell 7.2**, agganciati
esattamente alla stessa infrastruttura core (HTTP front-end, dispatcher,
code Service Bus, audit table, ledger blob).

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
  ┌────────────┴────────────┐
  ▼                         ▼
<capability>ForwardingRunner   [variant] <capability>RunbookForwardingRunner
  ↓ enqueue                    ↓ POST webhook
<capability>-action queue      Automation webhook
  ↓                            ↓
<Capability>ActionConsumer     Invoke-<Capability>.runbook.ps1
  → Graph call                 → Graph call
```

Entrambi gli esecutori, per ogni capability:
- Ricevono lo stesso envelope (`ActionRequestMessage` JSON).
- Chiamano gli stessi endpoint Microsoft Graph.
- Scrivono audit nella stessa Azure Table `auditevents` (così il portale
  vede entrambi i trail nello stesso posto).
- Usano la stessa SystemAssigned Managed Identity dell'Automation Account
  (granted dei ruoli Graph via `tools/Grant-GraphPermissions.ps1`).

## Stato (cosa è demo, cosa è produzione)

**Demo deliberatamente minimale**: i runbook **non** re-implementano il
ledger di idempotenza, i post-action nudges (sync/reboot dopo wipe), né
i path "denied:*" granulari. Si fermano alla sequenza:
`auth via MI → chiamata Graph → 1 riga audit → output JSON terminale`.

Questo è voluto: l'obiettivo è dare visibilità che la capability è
**replicabile** su un runtime diverso senza intervento sul core, non
sostituire la pipeline produzione.

## Wire-up

1. Deploy Bicep con `enableRunbookVariant=true` (override in
   `main.parameters.json` o via `--parameters enableRunbookVariant=true`).
   Crea l'Automation Account, le Automation Variables condivise
   (`KeepEnrollmentData`, `KeepUserData`, `AuditStorageAccount`,
   `AuditTableName`, `LedgerStorageAccount`, `LedgerContainer`), e le 3
   runbook resource (vuote — solo lo "shell").
2. `tools/Deploy-IntuneDeviceActions.ps1` (step `Invoke-RunbookPublish`)
   pubblica il contenuto dei 3 `.runbook.ps1` via
   `az automation runbook replace-content` + `publish`.
3. `tools/Grant-GraphPermissions.ps1` (sezione "Optional: Automation
   Account") concede i ruoli Graph alla SystemAssigned MI dell'AA:
   - `DeviceManagementManagedDevices.PrivilegedOperations.All` (wipe, rotateBitLockerKeys)
   - `DeviceManagementManagedDevices.Read.All` (resolve managedDevice)
   - `DeviceManagementServiceConfig.ReadWrite.All` (autopilot import)
   - `Device.Read.All`, `GroupMember.Read.All`
4. Per agganciarli al dispatcher: creare un webhook su ognuna delle 3
   runbook (1-year expiry) e implementare un `<Capability>RunbookForwardingRunner`
   alternativo che faccia `POST` al webhook invece di enqueue su Service
   Bus (lo `WipeRunbookForwardingRunner.cs` esistente è il template).
   Lasciato come hook documentato per non duplicare le superfici di audit
   in produzione.

## Test locale di una runbook

```pwsh
# Esempio: validare sintassi + dry-run di parsing dell'envelope
$env = @{
    actionType     = 'wipe'
    correlationId  = ([guid]::NewGuid().ToString('N'))
    intuneDeviceId = '11111111-1111-1111-1111-111111111111'
    entraDeviceId  = '22222222-2222-2222-2222-222222222222'
    deviceName     = 'CONTOSO-LAB-01'
} | ConvertTo-Json -Compress

# Sintassi
$err = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\runbooks\Invoke-DeviceWipe.runbook.ps1), [ref]$null, [ref]$err)
if ($err) { $err } else { 'syntax OK' }

# Esecuzione locale richiede `Connect-AzAccount` + ruoli equivalenti
# alla MI dell'Automation Account (non consigliato fuori dal portale).
```

## Quando usarla?

- **Demo al cliente** del modello plug-in: stesso input, due implementazioni
  intercambiabili, runtime diversi.
- Scenari **ops PowerShell-centric**: il runbook può essere debuggato/
  editato in-portal senza CI/CD.
- **Cap di costo molto basso**: 500 min/mese gratis su Automation;
  tipicamente €0 al nostro rate.

## Quando NON usarla?

- **Default produzione**: le 3 Function App runner sono già isolate e
  privilegiate correttamente, con idempotency ledger + post-action nudges
  + path "denied:*" granulari. Aggiungere il runbook **in parallelo**
  raddoppia le superfici di audit e i grant di permission senza valore
  netto, e perde le garanzie di idempotenza del ledger.
