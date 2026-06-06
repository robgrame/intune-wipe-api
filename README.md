# IntuneDeviceActions

[![.NET](https://img.shields.io/badge/.NET-10-512BD4?logo=dotnet&logoColor=white)](https://dotnet.microsoft.com/)
[![Azure Functions](https://img.shields.io/badge/Azure_Functions-isolated-0062AD?logo=azurefunctions&logoColor=white)](https://learn.microsoft.com/azure/azure-functions/)
[![Bicep](https://img.shields.io/badge/IaC-Bicep-1E5DBE?logo=azurepipelines&logoColor=white)](https://learn.microsoft.com/azure/azure-resource-manager/bicep/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> Soluzione serverless end-to-end per consentire ad un dispositivo Windows gestito da Intune di richiedere in autonomia il proprio **wipe (factory reset)** — e, in prospettiva, altre _device actions_ amministrative — con difesa in profondità: certificato dispositivo Intune (mTLS), allow-list nativa via gruppo Entra ID, validazione di ownership, esecuzione asincrona disaccoppiata via Service Bus e audit completo.

> Il nome storico del repository è `intune-wipe-api`; la codebase attuale (`IntuneDeviceActions`) generalizza il modello per ospitare nuove _action_ oltre al wipe.

## Indice

- [Architettura](#architettura)
- [Componenti](#componenti)
- [Isolamento delle tre Function App](#isolamento-delle-tre-function-app)
- [Controlli di sicurezza](#controlli-di-sicurezza-in-profondit%C3%A0)
- [Permessi Microsoft Graph](#permessi-microsoft-graph)
- [Quickstart deploy](#quickstart-deploy)
- [Uso del client PowerShell](#uso-del-client-powershell-51)
- [API](#api)
- [Configurazione](#configurazione)
- [Osservabilità & audit](#osservabilit%C3%A0--audit)
- [Struttura del repository](#struttura-del-repository)
- [Roadmap](#roadmap)
- [Licenza](#licenza)

## Architettura

L'endpoint pubblico fa **solo** validazione (certificato + payload + allow-list) e
accodamento. L'esecuzione effettiva del wipe avviene su una **terza Function App
dedicata e privilegiata**, disaccoppiata e ritentabile, raggiunta tramite un
router plug-in. La soluzione è organizzata in **tre Function App** (`Web`,
`Proc`, `Wipe`) più una libreria condivisa (`Shared`), con identità, storage,
hosting plan e permessi separati per ciascun ruolo.

**Hosting plan asimmetrico** (cost + latenza):

| App | Plan | Motivazione |
|---|---|---|
| `Web` | EP1 (ElasticPremium) | Always-on, mTLS terminato dalla platform, no cold start sull'API client-facing |
| `Proc` | FC1 (Flex Consumption) | Scale-to-zero quando idle, FQ-namespace MI auth su Service Bus |
| `Wipe` | FC1 (Flex Consumption) | Scale-to-zero, isolato a runtime distinto |

Flex Consumption richiede **un plan dedicato per Function App** (non condivisibile come EP), quindi i piani sono 3 ma solo l'EP1 ha costo fisso.

**Disaccoppiamento via Azure Service Bus** (al posto di Storage Queues): managed-identity auth (`disableLocalAuth=true`), dead-letter nativo, lock renewal automatico, message peek, supporto sessions/duplicate-detection se servono in futuro.

### Pipeline plug-in (router + runner)

```text
HTTP / mTLS  ──▶  ActionRequest      ──▶  [action-requests]  ──▶  RequestIntake (DISPATCHER)
   (Web app)        (Web app)            (Service Bus)              (Proc app)
                                                                       │ enqueue ActionDispatchMessage{type="wipe"}
                                                                       ▼
                                                              [action-dispatch] (Service Bus)
                                                                       │
                                                                       ▼
                                                              ActionDispatch (ROUTER, Proc app)
                                                                       │ ActionRunnerRegistry.Resolve(type)
                                                                       ▼
                              ┌──────────────────────────────────────────────────────────────┐
                              │ WipeForwardingRunner        type="wipe"          (built-in)   │
                              │   └─▶ [wipe-action] ─▶ WipeAction ─▶ WipeActionRunner          │
                              │                         (Wipe app, PRIVILEGED Graph identity)  │
                              │ WipeRunbookForwardingRunner type="wipe-runbook"  (demo variant)│
                              │   └─▶ POST webhook ─▶ Azure Automation runbook (PowerShell 7.2)│
                              │ AutopilotForwardingRunner   type="autopilot-register"          │
                              │   └─▶ [autopilot-action] ─▶ AutopilotAction ─▶ AutopilotRegisterRunner │
                              │                         (Autopilot app, PRIVILEGED Graph identity) │
                              │ BitLockerForwardingRunner   type="bitlocker-rotate"            │
                              │   └─▶ [bitlocker-action] ─▶ BitLockerAction ─▶ BitLockerRotateRunner │
                              │                         (BitLocker app, PRIVILEGED Graph identity) │
                              │ LockActionRunner            type="lock"          (futuro)      │
                              └──────────────────────────────────────────────────────────────┘
                                                                      ▲
                                                                      │ aggiungi qui per nuove capability
```

`RequestIntake` / `ActionDispatch` (Proc) **non** chiamano mai Microsoft Graph
né toccano il ledger di idempotenza: si limitano a instradare. La logica
distruttiva e l'identità Graph privilegiata vivono **solo** sulla `Wipe`
Function App, dietro la coda per-capability `wipe-action`.

Le risorse **CORE** (`Shared`, `Web`, `Proc/RequestIntake`, `Proc/ActionDispatch`,
HTTP function, code `action-requests` / `action-dispatch`, modello di busta
`ActionRequest` / `ActionDispatchMessage` / `IActionRunner`) sono **immutabili
rispetto alle capability**: aggiungerne una nuova non deve modificare nessun
file in `Shared/` né in `Web/`, né cambiare lo schema delle queue, della
tabella `actionstatus`, del blob `action-ledger` o del Bicep core.

Il contratto è la coppia `ActionDispatchMessage` (busta opaca con `ActionType`
discriminatore + `Payload JsonElement`) + `IActionRunner` (risolto per
`ActionType` da `ActionRunnerRegistry`). Le proprietà capability-specific che
arrivano in `ActionRequest` viaggiano nell'`[JsonExtensionData] Extras` senza
toccare il core (vedi `.github/copilot-instructions.md`).

#### Aggiungere un nuovo action runner

Esempio: una capability `lock`.

1. Crea il progetto `src/Capabilities.Lock/IntuneDeviceActions.Capabilities.Lock.csproj`
   (referenzia `Shared`). Layout consigliato (specchio di `Capabilities.Autopilot`):
   ```text
   src/Capabilities.Lock/
   ├── Models/LockPayload.cs             # payload tipato + ExtrasKey = "lock"
   ├── Runners/LockForwardingRunner.cs   # Proc: enqueue su lock-action (Type = "lock")
   ├── Runners/LockActionRunner.cs       # host privilegiato: chiama Graph (Type = "lock")
   ├── Runners/LockPayloadExtractor.cs   # internal helper Extras → LockPayload
   ├── Services/GraphLockService.cs
   └── LockHostBuilderExtensions.cs    # AddLockForwarding() / AddLockExecutor() / AddLockProbe()
   ```
   Il runner implementa `IActionRunner` e deserializza la busta come
   `ActionRequestMessage` per accedere a `Extras` (l'extractor lavora sul
   messaggio, non sull'envelope):
   ```csharp
   public sealed class LockActionRunner : IActionRunner
   {
       public string Type => "lock";
       public async Task RunAsync(ActionDispatchMessage env, CancellationToken ct)
       {
           var msg = env.Payload.Deserialize<ActionRequestMessage>()
               ?? throw new InvalidOperationException("Lock payload missing/invalid in dispatch envelope.");
           var payload = LockPayloadExtractor.TryRead(msg);
           // ... logica + audit + idempotency
       }
   }
   ```
2. Registra la capability tramite l'extension method dedicato — **nessuna riga
   da aggiungere in `Shared`**:
   - `src/Proc/Program.cs` → `services.AddLockForwarding(); services.AddLockProbe();`
   - se serve un privilege boundary (modello `Wipe`/`Autopilot`/`BitLocker`),
     crea un nuovo host `src/Lock/` che chiama `services.AddLockExecutor();`
     e la sua function `LockAction` (Service Bus trigger su `lock-action`)
     risolve `LockActionRunner` come tipo concreto.
3. Producer: i client esistenti chiamano già `POST /api/actions` con
   `actionType: "lock"` e le proprietà capability-specifiche nel corpo —
   l'`[JsonExtensionData] Extras` di `ActionRequest` le cattura senza modifiche
   a `Web` né a `Shared`. (Le chiavi che collidono con campi server-stamped
   come `forceRearm` / `correlationId` vengono scartate da
   `ActionRequestMessage.SanitizeExtras` per impedire spoofing.)
4. Per esporre il nuovo tipo ai client, aggiungi `lock` alla CSV
   `Actions:AllowedTypes` (App Configuration, hot-reload): **modifica di
   configurazione, non di codice**.
5. Per le risorse Azure capability-specifiche (queue `lock-action`, eventuale
   Function App `lock`), aggiungi un modulo Bicep dedicato in
   `infra/modules/lock.bicep` orchestrato da `main.bicep`. Le risorse core
   (HTTP function, `action-requests`, `action-dispatch`, ledger, status table)
   restano invariate.
6. Crea il progetto test parallelo `src/Capabilities.Lock.Tests/` (xUnit +
   FluentAssertions) con almeno: `LockPayloadExtractor` round-trip, `Type`
   discriminatore, contratto JSON del payload. Vedi
   `src/Capabilities.Autopilot.Tests/` come modello.

Eventi audit dedicati: `action.dispatch.enqueued`, `action.dispatch.received`,
`action.dispatch.completed`, `action.dispatch.runner-failed`,
`action.dispatch.no-runner`, `action.dispatch.invalid-envelope`.

## Componenti

| # | Componente | App | Ruolo |
|---|---|---|---|
| 1 | **`Invoke-DeviceWipe.ps1`** (PowerShell 5.1) | client | Raccoglie identità device, mostra UI WinForms di conferma (irreversibilità + ~90 min indisponibilità + parola `WIPE` da digitare), invoca l'API in mTLS con timestamp + nonce anti-replay. |
| 2 | **`ActionRequest`** (HTTP Function) | **Web** | Valida headers anti-replay, valida cert client (X509 chain + EKU + CRL opzionale), verifica binding cert↔device, valida payload, accoda messaggio su Service Bus `action-requests`, risponde `202 Accepted` con `correlationId`. |
| 3 | **Service Bus queue** `action-requests` | Web→Proc | Disaccoppia ricezione ed esecuzione; retry automatici, dead-letter nativo. |
| 4 | **`RequestIntake`** (Service Bus trigger, non esposta) | **Proc** | **Dispatcher sottile**: valida formato + app role, traduce il messaggio in un `ActionDispatchMessage{ActionType="wipe"}` e lo accoda su `action-dispatch`. Nessuna logica di business. |
| 4b | **Service Bus queue** `action-dispatch` | Proc | Coda del router plug-in. Decouple il dispatcher dai runner concreti; nuove capability si aggiungono come nuovo `IActionRunner` senza toccare HTTP, queue o dispatcher. |
| 4c | **`ActionDispatch`** (Service Bus trigger, non esposta) | **Proc** | **Router** plug-in: deserializza la busta, risolve l'`IActionRunner` per `ActionType` via `ActionRunnerRegistry`, esegue. Onora `FailOnError` per la retry policy della coda. |
| 4d | **`WipeForwardingRunner`** (`IActionRunner`, Type=`wipe`) | **Proc** | Runner non privilegiato: **inoltra** la busta sulla coda `wipe-action`. Il Proc non chiama Graph né tocca il ledger. |
| 4e | **`WipeRunbookForwardingRunner`** (`IActionRunner`, Type=`wipe-runbook`) | **Proc** | Variante demo: invece di accodare, fa `POST` su un webhook **Azure Automation** (runbook PowerShell 7.2 `Invoke-DeviceWipe`). Stesso contratto, runtime diverso. |
| 4f | **Service Bus queue** `wipe-action` | Proc→Wipe | Coda per-capability che consegna la busta alla sola app privilegiata. |
| 4g | **`WipeAction`** (Service Bus trigger, non esposta) | **Wipe** | Consumer dedicato che risolve direttamente `WipeActionRunner`. È l'unica function deployata sull'app privilegiata. |
| 4h | **`WipeActionRunner`** (`IActionRunner`, Type=`wipe`) | **Wipe** | Logica wipe vera: risolve device Entra, verifica membership gruppo, verifica ownership Intune↔Entra, **riserva slot idempotency su blob ledger**, esegue `POST /deviceManagement/managedDevices/{id}/wipe`, inizializza status tracker, esegue nudges (sync + reboot) best-effort. |
| 5 | **Blob container** `action-ledger` | Wipe | Ledger idempotency: un blob per `intuneDeviceId` con stato `Reserved`/`Issued`/`Failed` per garantire un singolo wipe anche con retry at-least-once. |
| 6a | **`ActionStatus`** (HTTP Function) | **Web** | `GET /api/actions/status/{correlationId}` (canonico, action-agnostic). In mTLS, ritorna la proiezione della tabella `actionstatus`. Binding cert↔device anti-IDOR. |
| 6b | **`ActionStatusPoller`** (Timer trigger) | **Proc** | Poller schedulato che interroga Graph per `actionState` dei wipe non terminali e aggiorna `actionstatus` + audit. |
| 6c | **`ActionLedger_Get`** / **`ActionLedger_Reset`** (HTTP) | **Web** | Endpoint SecOps `GET`/`POST /api/action-ledger/{intuneDeviceId}[/reset]` per ispezionare/resettare il ledger. Gated da `Idempotency:AdminApiEnabled` (off di default). |
| 7 | **Tre User-Assigned Managed Identity** | — | `idactions-uami-web` (no Graph privilegiato), `idactions-uami` (worker/proc, `Device.Read.All` + `DeviceManagementManagedDevices.Read.All` per il poller), `idactions-uami-wipe` (l'unica con i consent Graph distruttivi). |
| 8 | **Azure App Configuration** | tutte | Store centralizzato delle impostazioni con refresh sentinel; ogni app lo legge via `AppConfigRefreshMiddleware` con `roleHint` (`web`/`proc`/`wipe`). |
| 9 | **Application Insights + tabella `auditevents`** | tutte | Audit dual-write: `customEvents` (non-sampled) + Azure Table durabile, entrambi con `correlationId`. |

## Isolamento delle tre Function App

L'API HTTP pubblica (`Web`), il dispatcher/router (`Proc`) e l'esecutore
privilegiato del wipe (`Wipe`) girano in **tre Function App distinte**
(`idactions-web-*`, `idactions-proc-*`, `idactions-wipe-*`) su **plan
separati** (1× EP1 + 2× FC1), con identità (`uami-web`, `uami`, `uami-wipe`),
permessi, **storage account separati** (`*stw*`, `*stp*`, `*stwp*`) e
configurazione separata. **Isolamento per artefatto**: ogni function class è
compilata in un assembly diverso (`IntuneDeviceActions.Web/Proc/Wipe`), quindi
una function esiste fisicamente solo sull'app a cui appartiene. Il guard
in-code `AppRoleGuard` (legge `App__Role`, impostato via `roleHint` su App
Configuration) è un'ulteriore difesa fail-closed.

Risultato:

- **Web** ha **solo** `Azure Service Bus Data Sender` scoped sulla singola coda
  `action-requests` — non può leggere/cancellare messaggi né accedere alle altre code.
- **Proc** instrada soltanto: ha `Receiver` su `action-requests` + `Sender/Receiver`
  su `action-dispatch` + `Sender` su `wipe-action`, ma **non** ha l'identità Graph
  privilegiata e non esegue il wipe.
- Il **privilege boundary distruttivo** (consent
  `DeviceManagementManagedDevices.PrivilegedOperations.All`) vive **solo**
  sull'identità `uami-wipe` della `Wipe` Function App, l'unica che consuma
  `wipe-action` e chiama l'API di wipe Graph.
- I plan separati significano **VM host distinti**: un eventuale escape di
  sandbox / vulnerabilità host-level su una superficie non vede i processi né i
  token UAMI cached in memoria delle altre.

## Controlli di sicurezza in profondità

Una richiesta deve superare **tutti** questi controlli, nell'ordine:

1. **TLS mutual auth** a livello platform (`clientCertMode: Required`) — handshake rifiutato senza cert
2. **Function key** sull'HTTP call (`x-functions-key`)
3. **Anti-replay**: `X-Request-Timestamp` (skew ±5 min) + `X-Request-Nonce` (GUID, dedup cache)
4. **X509 chain validation** del cert client: validità, EKU `Client Authentication`, chain build con `CustomTrustStore` pinnato su CA Intune SCEP/PKCS, pinning per thumbprint CA, **CRL/OCSP** opzionale
5. **Cert ↔ device binding**: il claim configurato del cert (default `Subject CN`) deve uguagliare `entraDeviceId` nel body → previene IDOR
6. **Payload ben formato** (tre GUID validi)
7. **Device presente** nell'Entra ID del tenant
8. **Device membro** (anche transitivo) del gruppo di sicurezza Entra autorizzato → allow-list nativa, integrabile con membership dinamica
9. **Ownership match**: `managedDevice.azureADDeviceId` deve uguagliare l'`entraDeviceId` dichiarato
10. **Idempotency reservation** sul blob ledger (conditional `If-None-Match: *`) → un solo wipe per device anche con retry
11. **Solo allora** viene chiamata l'API di wipe Microsoft Graph; errori 4xx permanenti non vengono ritentati

Inoltre: HTTPS-only, TLS 1.2 minimo, `clientCertEnabled = true`,
Managed Identity con permessi minimi, nessuna credenziale in codice,
Service Bus / Storage / App Configuration con `disableLocalAuth=true`.

## Permessi Microsoft Graph

Assegnati come **application permissions** alla UAMI corrispondente (richiede consent admin):

| UAMI | Ruoli Graph |
|---|---|
| `idactions-uami-wipe` (privilegiata) | `DeviceManagementManagedDevices.PrivilegedOperations.All`, `DeviceManagementManagedDevices.Read.All`, `Device.Read.All`, `GroupMember.Read.All` |
| `idactions-uami` (worker / poller) | `DeviceManagementManagedDevices.Read.All` |
| `idactions-uami-web` | nessuno (oppure `Device.Read.All` solo se si abilita `SanDnsLookup`) |

Lo script `tools/Grant-GraphPermissions.ps1` esegue questi assignment in modo
idempotente; viene anche invocato automaticamente dallo script di deploy
end-to-end (disabilita con `-SkipGraphConsent` se non hai i diritti).

## Quickstart deploy

### Prerequisiti

- Azure subscription + permessi `Owner` o `Contributor` + `User Access Administrator` sul RG (per le role assignment)
- Tenant con Intune e CA SCEP/PKCS che emette certificati ai dispositivi
- Per la grant dei ruoli Graph: **Global Administrator** / **Privileged Role Administrator** / **Cloud Application Administrator**
- Un gruppo di sicurezza Entra ID che conterrà i device autorizzati al self-wipe
- `dotnet` SDK 10, `az` CLI ≥ 2.60, Bicep CLI (lo script verifica/installa)

### Deploy end-to-end (consigliato)

Un singolo comando:

```pwsh
.\tools\Deploy-IntuneDeviceActions.ps1 -ResourceGroup rg-idactions-dev
```

Lo script:

1. Verifica / installa .NET 10 SDK, Azure CLI, Bicep (winget → fallback installer ufficiali).
2. Autentica ad Azure e seleziona la subscription.
3. `dotnet publish` di `Web`, `Proc`, `Wipe` + zip Flex-compliant (entry names con `/`).
4. `az deployment group create` di `infra/main.bicep` con `main.parameters.json`.
5. Restart + zip-deploy delle 3 Function App (`az functionapp deployment source config-zip`, funziona sia su EP1 sia su Flex).
6. **Grant automatico** dei ruoli Microsoft Graph alle due UAMI (`tools/Grant-GraphPermissions.ps1`).
7. Smoke test: Web `POST /api/actions` (atteso 403 senza cert = mTLS attivo), root Flex (atteso 200).
8. Stampa link e azioni manuali residue (cert/CA chain verify, AppConfig seed opzionale, test client end-to-end).

Flag di skip per re-run incrementali: `-SkipPrereqInstall -SkipPublish -SkipInfra -SkipDeploy -SkipGraphConsent -NoSmokeTest`.

### Deploy manuale (alternativa)

```pwsh
# 1. RG
az group create -n rg-idactions-dev -l westeurope

# 2. Infra
az deployment group create `
  -g rg-idactions-dev `
  -f infra/main.bicep `
  -p infra/main.parameters.json

# 3. Publish + zip + deploy delle 3 app
cd src
foreach ($p in @(
  @{ proj = 'Web';  app = '<webAppName>'  },
  @{ proj = 'Proc'; app = '<procAppName>' },
  @{ proj = 'Wipe'; app = '<wipeAppName>' }
)) {
  dotnet publish "$($p.proj)/IntuneDeviceActions.$($p.proj).csproj" -c Release -o "../publish/$($p.proj)"
  # NB: usare ZipArchive con entry names forward-slash, NON Compress-Archive
  # (Compress-Archive produce '\' che Flex Consumption rifiuta).
  az functionapp deployment source config-zip `
    -g rg-idactions-dev -n $p.app --src "../publish/$($p.proj).zip"
}

# 4. Graph consent
.\tools\Grant-GraphPermissions.ps1 -ResourceGroup rg-idactions-dev

# 5. Aggiungi device al gruppo allow-list
$deviceObjId = az ad device list --filter "deviceId eq '<entraDeviceId>'" --query "[0].id" -o tsv
az ad group member add --group <allowedGroupId> --member-id $deviceObjId
```

Output bicep utili: `webAppName`, `webAppHostname`, `procAppName`, `wipeAppName`,
`appConfigName`, `appConfigEndpoint`, `serviceBusNamespace`,
`actionRequestsQueueName`, `actionDispatchQueueName`, `wipeActionQueueName`,
`ledgerContainerName`, `uamiWipePrincipalId`, `uamiWorkerPrincipalId`,
`uamiWebPrincipalId`.

## Uso del client PowerShell 5.1

Distribuibile via Intune (Win32 app, esecuzione in contesto SYSTEM) oppure
eseguibile manualmente:

```powershell
.\client\Invoke-DeviceWipe.ps1 `
  -ApiUrl       'https://<webHost>.azurewebsites.net/api/actions' `
  -CertificateSubjectLike '*Intune MDM Device CA*' `
  -FunctionKey  '<function-key>'
```

Lo script:

1. Legge l'**Entra Device Id** da `dsregcmd /status`
2. Legge l'**Intune Device Id** (`DeviceClientId`) dal registro `HKLM:\SOFTWARE\Microsoft\Enrollments\*`
3. Mostra una finestra WinForms con: intestazione rossa di warning, dettagli del dispositivo, avviso esplicito di irreversibilità e ~90 minuti di downtime, checkbox di consapevolezza obbligatoria, input testuale che richiede di digitare `WIPE` per abilitare il bottone
4. Sceglie il certificato dispositivo da `Cert:\LocalMachine\My`
5. Invoca l'API con `Invoke-RestMethod -Certificate` e mostra il `correlationId`

Usa `-Silent` per scenari unattended (test).

## API

### `POST /api/actions`

Endpoint **action-agnostic**: il tipo di azione viaggia nel body come
`actionType` (default `"wipe"` se omesso, validato contro
`Actions:AllowedTypes`). Headers obbligatori:

- `x-functions-key: <function-key>`
- `Content-Type: application/json`
- `X-Request-Timestamp` (ISO-8601 UTC, ±5 min)
- `X-Request-Nonce` (GUID)
- mutual TLS con certificato dispositivo Intune

Body:

```json
{
  "actionType": "wipe",
  "deviceName": "DESKTOP-ABC",
  "entraDeviceId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "intuneDeviceId": "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
}
```

Risposta `202 Accepted`:

```json
{ "status": "queued", "message": "wipe request accepted and queued", "correlationId": "..." }
```

| Code | Significato |
|------|-------------|
| 400 | Payload non valido (campi mancanti o non GUID) |
| 401 | Certificato client mancante o non valido |
| 403 | Device fuori allow-list o ownership mismatch |
| 502 | Errore upstream Microsoft Graph (riconciliato via retry coda) |

### `GET /api/actions/status/{correlationId}`

Stato di un'azione precedentemente accodata (proiezione della tabella `actionstatus`,
aggiornata dal poller). Action-agnostic: il `correlationId` identifica univocamente
la richiesta, l'`actionType` è opaco al chiamante. Stessi requisiti di auth di
`POST /api/actions` (mTLS + binding cert↔device): un device può leggere solo il
proprio esito. Esiti possibili: `404` (nessuna riga), `401` (cert/binding),
`403` (riga di un altro device).

### `GET` / `POST /api/action-ledger/{intuneDeviceId}[/reset]`

Endpoint operativi SecOps per ispezionare e resettare manualmente il ledger di
idempotenza (sblocco di un device quando un re-wipe è intenzionalmente bloccato).
Solo sulla `Web` Function App, protetti da function key e disabilitati di default
(`Idempotency:AdminApiEnabled=true` per abilitarli).

## Configurazione

Tutte le impostazioni sono centralizzate in **Azure App Configuration** (lette
da ogni app via `AppConfigRefreshMiddleware` con refresh sentinel) e possono
essere override come app settings della singola Function App.

### Service Bus & storage

| Setting | Default | Descrizione |
|---|---|---|
| `AppConfig__Endpoint` | _(da bicep)_ | Endpoint dell'Azure App Configuration store. Accesso via UAMI (`App Configuration Data Reader`), local auth disabilitato. |
| `ServiceBus__fullyQualifiedNamespace` | _(da bicep)_ | FQDN namespace Service Bus per managed-identity auth. Case-insensitive: serve sia all'estensione trigger sia all'SDK client. |
| `ServiceBus__ActionRequestsQueue` | `action-requests` | Coda Web → Proc |
| `ServiceBus__ActionDispatchQueue` | `action-dispatch` | Coda interna Proc (router plug-in) |
| `ServiceBus__WipeActionQueue` | `wipe-action` | Coda Proc → Wipe (privilegiata) |
| `ServiceBus__AutopilotActionQueue` | `autopilot-action` | Coda Proc → Autopilot (privilegiata) |
| `ServiceBus__BitLockerActionQueue` | `bitlocker-action` | Coda Proc → BitLocker (privilegiata) |
| `Idempotency__StorageAccount` | _(da bicep)_ | Storage account del ledger blob |
| `Idempotency__BlobContainer` | `action-ledger` | Container blob del ledger idempotency |
| `ActionStatus__TableName` | `actionstatus` | Tabella di tracking dello stato (alimenta `GET /api/actions/status`) |
| `ActionStatus__PollMaxAgeHours` | `48` | Età massima delle righe non terminali da riconciliare via poller |
| `Audit__TableName` | `auditevents` | Tabella audit durabile (dual-write con App Insights) |

### Cert validation (mTLS)

| Setting | Default | Descrizione |
|---|---|---|
| `ClientCert__TrustedCaThumbprints` | _(vuoto)_ | CSV thumbprint root/intermediate CA che devono comparire nella chain. **Richiesto** (o almeno un cert in `TrustedRootCertificates`) |
| `ClientCert__TrustedRootCertificates` | _(vuoto)_ | Base64 DER delle **ROOT CA** (self-signed). Caricate in `CustomTrustStore` come trust anchors. Separa con `\|` `,` o `;`. |
| `ClientCert__TrustedIntermediateCertificates` | _(vuoto)_ | Base64 DER delle **CA intermedie**. Caricate solo in `ExtraStore` (hint per la costruzione della catena, **non** trust anchor). |
| `ClientCert__AllowedLeafThumbprints` | _(vuoto)_ | CSV pin opzionale del thumbprint del certificato leaf |
| `ClientCert__CheckRevocation` | `false` | Abilita check CRL/OCSP sulla chain |
| `ClientCert__RevocationMode` | `Online` | `Online`\|`Offline`\|`NoCheck` |
| `ClientCert__RevocationFlag` | `ExcludeRoot` | `ExcludeRoot`\|`EntireChain`\|`EndCertificateOnly` |
| `ClientCert__RequireClientAuthEku` | `true` | Richiede EKU Client Authentication (1.3.6.1.5.5.7.3.2) |
| `ClientCert__RequireClientCert` | `true` | Impone cert client (fail-closed se mancante) |
| `ClientCert__TrustForwardedHeader` | `true` | **DEVE essere `true` su App Service**: anche con `clientCertMode=Required` il cert viene consegnato all'app via header `X-ARR-ClientCert`. |
| `ClientCert__DeviceIdBindingClaim` | `Auto` | `Auto`\|`SubjectCN`\|`SanDns`\|`SanUri`\|`Thumbprint`\|`SanDnsLookup`\|`Disabled` — strategia per legare il certificato all'`entraDeviceId`. **`Auto`** prova in ordine: `ThumbprintToDeviceMap` → `SanUri` → `SanDns` → `SubjectCN` → `SanDnsLookup`. Strategie claim-based **strict**: il valore deve essere uguale a un GUID (anti-IDOR). |
| `ClientCert__ThumbprintToDeviceMap` | _(vuoto)_ | Mappa operatore `thumbprint=EntraDeviceId`. Formato: `THUMB1=guid1\|THUMB2=guid2`. Escape-hatch per cert senza device id nel Subject. |

### Anti-replay, wipe, runbook

| Setting | Default | Descrizione |
|---|---|---|
| `Replay__MaxTimestampSkewSeconds` | `300` | Skew massimo (s) per `X-Request-Timestamp` |
| `Wipe__AllowedGroupId` | _(obbligatorio)_ | ObjectId gruppo Entra |
| `Wipe__KeepEnrollmentData` | `false` | Mantiene enrollment Intune (utile in DEV per evitare provisioning Autopilot da zero) |
| `Wipe__KeepUserData` | `false` | Mantiene dati utente |
| `ActionStatusPoller__CronExpression` | _(da bicep)_ | NCRONTAB del poller (Proc) |
| `Idempotency__AdminApiEnabled` | `false` | Abilita gli endpoint `action-ledger` admin (solo Web) |
| `WipeRunbook__WebhookUrl` | _(vuoto)_ | Webhook del runbook Automation per la capability `wipe-runbook` (trattare come secret, Key Vault reference raccomandato) |
| `Autopilot__AllowedGroupId` | _(default = `Wipe__AllowedGroupId`)_ | ObjectId gruppo Entra autorizzato alla self-registration Autopilot (capability `autopilot-register`) |
| `BitLocker__AllowedGroupId` | _(default = `Wipe__AllowedGroupId`)_ | ObjectId gruppo Entra autorizzato alla rotazione recovery key (capability `bitlocker-rotate`) |
| `Graph__TenantId` | tenant corrente | Tenant per i token Graph |
| `Graph__ManagedIdentityClientId` | _(da bicep)_ | clientId della UAMI |
| `App__Role` | _(da bicep)_ | `web`\|`proc`\|`wipe`\|`autopilot`\|`bitlocker` — letto da `AppRoleGuard` per fail-closed |

### Headers HTTP richiesti dal client

| Header | Esempio | Note |
|---|---|---|
| `x-functions-key` | `<function key>` | Auth livello Function |
| `Content-Type` | `application/json` | |
| `X-Request-Timestamp` | `2026-05-26T19:30:00.000Z` | ISO-8601 UTC, ±5 min |
| `X-Request-Nonce` | GUID | Dedupe in cache 10 min |

Inoltre la richiesta **deve** presentare un certificato client valido in TLS handshake (mTLS).

## Osservabilità & audit

Ogni operazione security-critical emette un **customEvent strutturato** in
Application Insights (tabella `customEvents`, sampling **disabilitato** sul
worker telemetry pipeline → `SamplingRatio = 1.0`, e `excludedTypes` include
`Event;Exception` in `host.json`). I traces classici (`ILogger`) restano
disponibili come mirror per i flussi locali. In parallelo, ogni evento è anche
scritto nella tabella Azure `auditevents` per audit durabile indipendente
dalla retention di App Insights.

Convenzioni nomi:

- `wipe.<area>.<esito>` per gli eventi del flusso wipe (request/denied/graph/ledger)
- `action.dispatch.<esito>` per il router plug-in

Vedi `src/Shared/Services/AuditEvents.cs` per la lista completa. Ogni evento
porta `correlationId`, `deviceName`, `entraDeviceId`, `intuneDeviceId` e — quando
applicabile — `certThumbprint`, `reason`, `managedDeviceId`, `expectedRole`/`actualRole`.

Esempi KQL:

```kql
// Tutti gli eventi di audit nelle ultime 24h
customEvents
| where timestamp > ago(24h)
| where name startswith "wipe." or name startswith "action."
| project timestamp, name,
          correlationId = tostring(customDimensions.correlationId),
          device        = tostring(customDimensions.deviceName),
          intune        = tostring(customDimensions.intuneDeviceId),
          reason        = tostring(customDimensions.reason)
| order by timestamp desc

// Wipe negati per device fuori dal gruppo allow-list
customEvents
| where name == "wipe.denied.not-in-allowed-group"
| project timestamp, customDimensions

// Trail completo di un wipe (request → graph)
customEvents
| where tostring(customDimensions.correlationId) == "<corr-id>"
| order by timestamp asc
| project timestamp, name, customDimensions
```

## Struttura del repository

```
.
├── infra/
│   ├── main.bicep                      # 3 Function App + plan (1 EP1 + 2 FC1), 3 storage,
│   │                                   #   3 UAMI, Service Bus + queue, App Configuration,
│   │                                   #   App Insights, RBAC, runbook Automation
│   └── main.parameters.json
├── src/                                # .NET 10 isolated — soluzione multi-progetto
│   ├── IntuneDeviceActions.slnx
│   ├── Shared/                         # IntuneDeviceActions.Shared — CORE immutabile
│   │   ├── HostBuilderExtensions.cs    # DI + App Configuration helpers
│   │   ├── Actions/                    # contratti plug-in: registry, envelope, interfaccia
│   │   │   ├── IActionRunner.cs
│   │   │   ├── ActionRunnerRegistry.cs
│   │   │   └── ActionDispatch*.cs      # ActionDispatchMessage, sender, enqueuer
│   │   ├── Services/                   # ClientCertValidator, GraphErrorClassifier,
│   │   │                               #   Idempotency, ReplayProtector, Audit*,
│   │   │                               #   ActionStatusTracker, DeviceDirectoryResolver
│   │   ├── Middleware/                 # AppConfigRefreshMiddleware, ServiceBusTraceContext
│   │   └── Models/                     # ActionRequest, ActionRequestMessage
│   │                                   #   (con [JsonExtensionData] Extras)
│   ├── Shared.Tests/                   # xUnit + FluentAssertions sul core
│   ├── Capabilities.Wipe/              # capability "wipe" (Models, Runners, Services)
│   ├── Capabilities.BitLocker/         # capability "bitlocker-rotate"
│   ├── Capabilities.Autopilot/         # capability "autopilot-register"
│   ├── Capabilities.Autopilot.Tests/   # xUnit sulla capability Autopilot
│   ├── Web/                            # IntuneDeviceActions.Web (EP1, mTLS)
│   │   └── Functions/                  # ActionRequest, ActionStatus, ActionLedger_*
│   ├── Proc/                           # IntuneDeviceActions.Proc (Flex)
│   │   └── Functions/                  # RequestIntake, ActionDispatch, ActionStatusPoller
│   ├── Wipe/                           # IntuneDeviceActions.Wipe (Flex, privilegiata)
│   │   └── Functions/                  # WipeAction (consumer wipe-action)
│   ├── BitLocker/                      # host privilegiato BitLocker (consumer bitlocker-action)
│   └── Autopilot/                      # host privilegiato Autopilot (consumer autopilot-action)
├── tools/
│   ├── Deploy-IntuneDeviceActions.ps1  # orchestrator end-to-end
│   └── Grant-GraphPermissions.ps1      # grant idempotente dei ruoli Graph alle UAMI
├── runbooks/                           # variante Automation PowerShell 7.2
│   ├── Invoke-DeviceWipe.runbook.ps1
│   └── README.md
├── client/
│   ├── Invoke-DeviceWipe.ps1           # PS 5.1 client (entrypoint)
│   ├── DeviceIdentity.psm1             # modulo identità device (Pester-tested)
│   └── WipeConfirmationDialog.ps1      # WinForms dialog (shared module)
└── docs/
    ├── architecture.png
    ├── architectural-improvements.md
    ├── dialog-screenshot.png
    ├── Capture-DialogScreenshot.ps1
    └── Presentazione-Soluzione-Intune-Self-Wipe.eml
```

> **Nota sull'email di presentazione** (`docs/Presentazione-Soluzione-Intune-Self-Wipe.eml`):
> include `X-Unsent: 1` per aprirsi come bozza editabile in **Outlook classic**.
> Il nuovo Outlook e Outlook Web la aprono in sola lettura.

## Roadmap

- [x] Validazione cert via `chain.Build()` con root CA pinning (`CustomTrustStore`)
- [x] Split web/worker + esecutore privilegiato dedicato (3 Function App isolate)
- [x] Modello plug-in `IActionRunner` (router + runner, variante runbook Automation)
- [x] Service Bus al posto di Storage Queues (managed-identity, dead-letter nativo)
- [x] Flex Consumption per Proc + Wipe (scale-to-zero); EP1 solo per Web
- [x] Configurazione centralizzata via Azure App Configuration
- [x] Audit durabile dual-write (App Insights non-sampled + tabella `auditevents`)
- [x] Endpoint `GET /api/actions/status` + poller di riconciliazione
- [x] Script `Deploy-IntuneDeviceActions.ps1` + `Grant-GraphPermissions.ps1` end-to-end idempotenti
- [x] Capability `autopilot-register` (self-registration in Windows Autopilot; il client raccoglie l'hardware hash, l'API esegue l'import Graph)
- [x] Capability `bitlocker-rotate` (rotazione self-service della recovery key BitLocker)
- [ ] Notifica esito (Teams webhook / email) al termine del wipe
- [ ] Rimozione della Function Key dal client (mTLS-only dietro APIM/App Gateway)
- [ ] CA trust lifecycle via Key Vault references
- [ ] APIM/App Gateway WAF davanti alla Function con rate-limit per device
- [ ] Workflow GitHub Actions per CI/CD (con boundary checks post-deploy)

> Dettaglio completo delle proposte architetturali in
> [`docs/architectural-improvements.md`](docs/architectural-improvements.md).

## Licenza

[MIT](LICENSE) © Roberto Gramellini