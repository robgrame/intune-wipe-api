# IntuneDeviceActions

[![.NET](https://img.shields.io/badge/.NET-10-512BD4?logo=dotnet&logoColor=white)](https://dotnet.microsoft.com/)
[![Azure Functions](https://img.shields.io/badge/Azure_Functions-isolated-0062AD?logo=azurefunctions&logoColor=white)](https://learn.microsoft.com/azure/azure-functions/)
[![Bicep](https://img.shields.io/badge/IaC-Bicep-1E5DBE?logo=azurepipelines&logoColor=white)](https://learn.microsoft.com/azure/azure-resource-manager/bicep/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> Soluzione serverless end-to-end per consentire ad un dispositivo Windows gestito da Intune di richiedere in autonomia un set di **device actions** amministrative (wipe / Autopilot self-registration / BitLocker recovery-key rotation / **device rename**) — con difesa in profondità: certificato dispositivo Intune (mTLS), allow-list nativa via gruppo Entra ID, validazione di ownership, esecuzione asincrona disaccoppiata via Service Bus e audit completo.

> Il nome storico del repository è `intune-wipe-api`; la codebase attuale (`IntuneDeviceActions`) generalizza il modello per ospitare nuove _action_ oltre al wipe.

## Indice

- [Architettura](#architettura)
- [Componenti](#componenti)
- [Isolamento delle Function App per capability](#isolamento-delle-function-app-per-capability)
- [Controlli di sicurezza](#controlli-di-sicurezza-in-profondit%C3%A0)
- [Permessi Microsoft Graph](#permessi-microsoft-graph)
- [Quickstart deploy](#quickstart-deploy)
- [Client Win32 — esperienza utente](#client-win32--distribuzione-e-esperienza-utente-wipe)
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
| 4d | **`WipeForwardingRunner` / `AutopilotForwardingRunner` / `BitLockerForwardingRunner` / `RenameForwardingRunner`** (`IActionRunner`) | **Proc** | Runner non privilegiati: **inoltrano** la busta sulla coda per-capability (`wipe-action`, `autopilot-action`, `bitlocker-action`, `rename-action`). Il Proc non chiama Graph né tocca il ledger. |
| 4e | **`*RunbookForwardingRunner`** (varianti `wipe-runbook` / `autopilot-runbook` / `bitlocker-runbook` / `device-rename-runbook`) | **Proc** | Varianti demo: invece di accodare, fanno `POST` su un webhook **Azure Automation** (runbook PowerShell 7.2 in `runbooks/`). Stesso contratto, runtime diverso, attach **config-driven** via `RunbookBridge:Routes:<actionType>` (zero codice infrastrutturale per aggiungere una nuova runbook). |
| 4f | **Service Bus queue** `wipe-action` / `autopilot-action` / `bitlocker-action` / `rename-action` | Proc→app privilegiata | Code per-capability che consegnano la busta alla sola app autorizzata. |
| 4g | **`WipeAction` / `AutopilotAction` / `BitLockerAction` / `RenameAction`** (Service Bus trigger, non esposte) | **Wipe / Autopilot / BitLocker / Rename** | Consumer dedicati che risolvono direttamente il runner della capability. Sono le uniche function deployate sulla rispettiva app privilegiata. |
| 4h | **`WipeActionRunner`** (`IActionRunner`, Type=`wipe`) | **Wipe** | Logica wipe vera: risolve device Entra, verifica membership gruppo, verifica ownership Intune↔Entra, **riserva slot idempotency su blob ledger**, esegue `POST /deviceManagement/managedDevices/{id}/wipe`, inizializza status tracker, esegue nudges (sync + reboot) best-effort. |
| 4i | **`AutopilotRegisterRunner`** (Type=`autopilot-register`) | **Autopilot** | Self-registration in Windows Autopilot: importa l'hardware hash via `POST /deviceManagement/importedWindowsAutopilotDeviceIdentities`, attende il completamento dell'import, ledger + status come per il wipe. |
| 4j | **`BitLockerRotateRunner`** (Type=`bitlocker-rotate`) | **BitLocker** | Rotazione recovery key: risolve device, verifica membership gruppo + ownership, `POST /deviceManagement/managedDevices/{id}/rotateBitLockerKeys` (chiamata raw via Kiota), ledger + status. |
| 4k | **`RenameActionRunner`** (Type=`device-rename`) | **Rename** | Pipeline LOOKUP+Graph: **GET** verso l'endpoint CMDB del cliente (`{serial}` → `newName`), pre-check **collisioni** displayName su **Entra** _e_ Intune managedDevices (policy `block`/`warn`), `POST /deviceManagement/managedDevices/{id}/setDeviceName`, ledger + status. Non esiste probe di completamento (Intune accoda al prossimo MDM sync + reboot Windows): lo status viene marcato **terminale `issued`** appena la chiamata Graph ha successo. |
| 5 | **Blob container** `action-ledger` | Wipe | Ledger idempotency: un blob per `intuneDeviceId` con stato `Reserved`/`Issued`/`Failed` per garantire un singolo wipe anche con retry at-least-once. |
| 6a | **`ActionStatus`** (HTTP Function) | **Web** | `GET /api/actions/status/{correlationId}` (canonico, action-agnostic). In mTLS, ritorna la proiezione della tabella `actionstatus`. Binding cert↔device anti-IDOR. |
| 6b | **`ActionStatusPoller`** (Timer trigger) | **Proc** | Poller schedulato che interroga Graph per `actionState` dei wipe non terminali e aggiorna `actionstatus` + audit. |
| 6c | **`ActionLedger_Get`** / **`ActionLedger_Reset`** (HTTP) | **Web** | Endpoint SecOps `GET`/`POST /api/actions/ledger/{intuneDeviceId}[/reset]` per ispezionare/resettare il ledger. Defense-in-depth banking-grade: (1) function key, (2) kill-switch `Idempotency:AdminApiEnabled` (off di default), (3) **mTLS richiesto** (nessun `clientCertExclusionPaths`), (4) **allow-list operatore** via `Idempotency:AdminCertThumbprints`. L'attore audit è il thumbprint del certificato verificato, non un campo del body. |
| 7 | **User-Assigned Managed Identities** | — | `idactions-uami-web` (no Graph privilegiato), `idactions-uami` (worker/proc, poller), `idactions-uami-wipe`, `idactions-uami-autopilot`, `idactions-uami-bitlocker`, `idactions-uami-rename` (una per capability, ciascuna con i soli consent Graph necessari per la propria action). |
| 8 | **Azure App Configuration** | tutte | Store centralizzato delle impostazioni con refresh sentinel; ogni app lo legge via `AppConfigRefreshMiddleware` con `roleHint` (`web`/`proc`/`wipe`). |
| 9 | **Application Insights + tabella `auditevents`** | tutte | Audit dual-write: `customEvents` (non-sampled) + Azure Table durabile, entrambi con `correlationId`. |

## Isolamento delle Function App per capability

L'API HTTP pubblica (`Web`), il dispatcher/router (`Proc`) e i quattro
esecutori privilegiati (`Wipe`, `Autopilot`, `BitLocker`, `Rename`) girano in
**Function App distinte** (`idactions-web-*`, `idactions-proc-*`,
`idactions-wipe-*`, `idactions-autopilot-*`, `idactions-bitlocker-*`,
`idactions-rename-*`) su **plan separati** (1× EP1 + 5× FC1), con identità
(`uami-web`, `uami`, `uami-wipe`, `uami-autopilot`, `uami-bitlocker`,
`uami-rename`), permessi, **storage account separati** e configurazione
separata. **Isolamento per artefatto**: ogni function class è compilata in un
assembly diverso (`IntuneDeviceActions.Web/Proc/Wipe/Autopilot/BitLocker/Rename`),
quindi una function esiste fisicamente solo sull'app a cui appartiene. Il guard
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
| `idactions-uami-autopilot` | `DeviceManagementServiceConfig.ReadWrite.All`, `Device.Read.All`, `GroupMember.Read.All` |
| `idactions-uami-bitlocker` | `DeviceManagementManagedDevices.PrivilegedOperations.All`, `DeviceManagementManagedDevices.Read.All`, `Device.Read.All`, `GroupMember.Read.All` |
| `idactions-uami-rename` | `DeviceManagementManagedDevices.PrivilegedOperations.All`, `DeviceManagementManagedDevices.Read.All`, `Device.Read.All` (la `Device.Read.All` è usata dal pre-check di collisione `displayName` su Entra — vedi sotto) |
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
- **Resource provider registrati a livello subscription** (vedi sotto). `tools/Deploy-IntuneDeviceActions.ps1` li registra automaticamente prima del deploy; se deploi manualmente con `az deployment group create` devi farlo a mano.

#### Resource provider richiesti

Il Bicep usa risorse di 13 namespace. Senza registrazione il deploy fallisce con `The subscription is not registered to use namespace 'Microsoft.X'`. Sono già registrati di default sulle subscription nuove ad eccezione di `Microsoft.App` (richiesto da Flex Consumption per VNet integration anche se gli host sono `Microsoft.Web/sites`) e `Microsoft.AlertsManagement` (creato implicitamente da Application Insights per gli Smart Detector alert rule).

| Namespace | Uso |
|-----------|-----|
| `Microsoft.Resources` | Resource group + sub-resources base |
| `Microsoft.Authorization` | Role assignments (RBAC) |
| `Microsoft.ManagedIdentity` | User-Assigned Managed Identities (5: web/proc/wipe/autopilot/bitlocker) |
| `Microsoft.Storage` | Storage account (web, proc, wipe, autopilot, bitlocker) — blob/table/queue/file |
| `Microsoft.Network` | VNet, subnet, NSG, NAT Gateway, Private DNS Zones, Private Endpoints |
| `Microsoft.Web` | Function Apps + serverfarms (EP1 per Web, Flex Consumption FC1 per gli altri) |
| `Microsoft.App` | **Necessario per Flex Consumption + VNet integration** anche se gli host sono `Microsoft.Web/sites` |
| `Microsoft.ServiceBus` | Namespace + 5 code (`action-requests`, `action-dispatch`, `wipe-action`, `autopilot-action`, `bitlocker-action`) |
| `Microsoft.OperationalInsights` | Log Analytics workspace |
| `Microsoft.Insights` | Application Insights (component v2 + classic) |
| `Microsoft.AlertsManagement` | Smart Detector alert rules creati implicitamente da App Insights |
| `Microsoft.AppConfiguration` | App Configuration store (override runtime) |
| `Microsoft.Automation` | Runbook variant (solo se `enableRunbookVariant=true`) |

Registrazione manuale (one-shot per subscription):

```pwsh
$providers = @(
  'Microsoft.Resources','Microsoft.Authorization','Microsoft.ManagedIdentity',
  'Microsoft.Storage','Microsoft.Network','Microsoft.Web','Microsoft.App',
  'Microsoft.ServiceBus','Microsoft.OperationalInsights','Microsoft.Insights',
  'Microsoft.AlertsManagement','Microsoft.AppConfiguration','Microsoft.Automation'
)
foreach ($ns in $providers) { az provider register --namespace $ns }
```

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

### Variante di rete: `hardened` (default) vs `public`

Lo script accetta `-NetworkProfile {hardened|public}`:

| Profilo    | Bicep file                       | Network isolation                                                                                                                                                                                                       | Quando usarlo                                                                                                                                                                |
| ---------- | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `hardened` | `infra/main.bicep`               | VNet `/24` + 4 subnet, 2 NSG, NAT Gateway con 1 Standard Public IP (SNAT stabile su Graph), 4 Private DNS zone (blob/file/queue/table), Private Endpoint su `storageWeb`/`storageProc`/`storageWipe`, Flex VNet-integrated. | Produzione, hardening, requisiti di compliance, IP egress stabile (whitelisting Graph / SOC). Costo aggiuntivo: ~25–40 €/mese (NAT GW + PIP + PE).                            |
| `public`   | `infra/main-public.bicep`        | Nessuna risorsa di rete. Storage `publicNetworkAccess=Enabled` con `networkAcls.defaultAction=Allow`. Funzioni senza VNet integration. Service Bus / App Config raggiungibili dall'Internet pubblico.                   | PoC, demo, ambienti di sviluppo, clienti che non possono / non vogliono gestire un Private DNS hub. Sicurezza ancora garantita da Entra ID + RBAC + UAMI + mTLS sul Web.    |

```pwsh
# variante public
.\tools\Deploy-IntuneDeviceActions.ps1 -ResourceGroup rg-idactions-dev -NetworkProfile public
```

I nomi delle risorse sono identici tra le due varianti, quindi si può migrare un ambiente esistente da `public` → `hardened` (o viceversa) riapplicando l'altro Bicep — attenzione che `what-if` mostrerà molte cancellazioni/aggiunte. Il payload mTLS, le UAMI, i Graph role assignments, il modello di plug-in/runner e i runbook di Automation sono invariati tra le due varianti.

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

## Client Win32 — distribuzione e esperienza utente (wipe)

Il client è distribuito come **Win32 app Intune** (pacchetto in
`client/intune-win32-package/`) oppure eseguibile manualmente da PowerShell
5.1. L'architettura è **biprocesso** per via del vincolo di ACL del
certificato SCEP/PKCS:

| Processo | Contesto | Ruolo |
|---|---|---|
| `Launch-Wipe.ps1` | **Utente interattivo** | Mostra la UI di conferma (WinForms), triggera il task SYSTEM al click *Esegui reset* |
| `Invoke-WipeFromTask.ps1` | **SYSTEM** (Scheduled Task) | Accede al certificato in `Cert:\LocalMachine\My`, chiama l'API, persiste il risultato |
| `Watch-WipeStatus.ps1` | **SYSTEM** (Scheduled Task) | Polla `GET /api/actions/status/{correlationId}` e aggiorna il file di stato per la UI |

Il private key del certificato dispositivo è ACL'd a SYSTEM/Administrators:
un processo non-admin non può usarlo per TLS client auth. Il dialogo di
conferma deve però girare nella sessione interattiva dell'utente (Session 0
isolation impedisce a SYSTEM di aprire UI). La separazione risolve il
conflitto: `Launch-Wipe.ps1` mostra la UI, poi triggera il task.

### Fase 1 — Dialogo di conferma

`Launch-Wipe.ps1` carica il modulo `WipeConfirmationDialog.ps1` e mostra la
finestra di conferma:

- intestazione rossa con simbolo di avviso
- testo esplicito: irreversibilità dell'operazione e ~90 min di downtime
- dettagli identificativi del dispositivo (nome, EntraDeviceId, IntuneDeviceId)
- checkbox obbligatoria di consapevolezza
- campo di testo che richiede di digitare `WIPE` in maiuscolo per abilitare il bottone

![Dialogo di conferma wipe — Fase 1](docs/dialog-screenshot.png)

> **Generazione screenshot:** su Windows, esegui
> `powershell.exe -STA -File docs\Capture-DialogScreenshot.ps1`
> per rigenerare tutti e quattro i frame (`dialog-screenshot.png`,
> `dialog-progress.png`, `dialog-result-success.png`,
> `dialog-result-error.png`).

### Fase 2 — Esecuzione con avanzamento live

Appena l'utente clicca *Esegui reset*, il dialogo **non si chiude**: la
fase 1 viene nascosta e la fase 2 subentra nella stessa finestra con:

- barra di avanzamento (marquee → deterministic al completamento)
- etichetta di stato colorata (blu → verde successo / rosso errore)
- `CorrelationId` del wipe stampato in modo prominente (serve all'helpdesk)
- log a colori con timestamp (info / success / warning / error / muted)
- pulsante *Monitora avanzamento live...* (visibile al completamento) che
  apre `Show-WipeProgressDialog` per seguire l'avanzamento Intune in tempo reale
- pulsante *Chiudi* abilitato solo al termine dell'operazione

### Dialoghi di risultato

Terminata la fase 2, la UI mostra dialoghi dedicati (`WipeResultDialogs.ps1`):

| Esito | Dialogo |
|---|---|
| **Successo** | Conferma in verde, `CorrelationId` evidenziato, pulsante "Copia dettagli" per helpdesk ticket |
| **Errore** | Messaggio di errore business-friendly, HTTP status, dettagli tecnici collassabili + "Copia dettagli" |
| **Stato sconosciuto** | Avviso "wipe avviato ma esito non confermato" con `CorrelationId` per verifica manuale |

### Dialogo di monitoraggio live

`Show-WipeProgressDialog` — aperto manualmente o dal pulsante *Monitora
avanzamento live...* — segue il file di stato scritto dal task SYSTEM
(`%ProgramData%\IntuneWipeClient\status\<corrId>.json`) e mostra:

- stato Intune tradotto in italiano (`pending` → `active` → `done` / `removedFromIntune`)
- metadati del device dall'ultimo poll Graph (LastSync, ComplianceState, OsVersion)
- timeline delle transizioni di stato
- pulsante *Chiudi* (il task SYSTEM continua in background)

### Distribuzione via Intune (Win32 app)

```pwsh
# 1. Build del pacchetto .intunewin
cd client\intune-win32-package
.\Build-IntuneWinPackage.ps1
# → dist\IntuneWipeClient.intunewin

# 2. Pubblicazione su Intune (idempotente: rimuove e ripubblica se esiste)
.\Publish-ToIntune.ps1 `
    -ApiUrl          'https://<webHost>.azurewebsites.net/api/actions' `
    -FunctionKey     '<host-key>' `
    -AssignToGroupId '<entra-group-object-id>'   # opzionale
```

`Publish-ToIntune.ps1` autentica via Microsoft Graph (modulo `IntuneWin32App`,
installato automaticamente). Il pacchetto installa:

| Percorso | Contenuto |
|---|---|
| `%ProgramFiles%\IntuneWipeClient\` | script + moduli + `config.json` (ACL: SYSTEM + Administrators) |
| `%ProgramData%\Microsoft\Windows\Start Menu\Programs\Migrazione a MODERN.lnk` | Collegamento Start Menu (tutti gli utenti) |
| `%PUBLIC%\Desktop\Migrazione a MODERN.lnk` | Collegamento Desktop pubblico |
| `HKLM:\SOFTWARE\MSLABS\IntuneWipeClient` | Chiave di detection (Version, ProductCode, InstallDir) |

`Install.ps1` esegue un **self-test** automatico subito dopo la registrazione
del task SYSTEM (`-SelfTest`) per rilevare eventuali blocchi AppLocker / WDAC
prima del primo uso reale da parte dell'utente.

### Uso standalone (senza Win32 package)

```powershell
.\client\Invoke-DeviceWipe.ps1 `
  -ApiUrl       'https://<webHost>.azurewebsites.net/api/actions' `
  -CertificateSubjectLike '*Intune MDM Device CA*' `
  -FunctionKey  '<function-key>'
```

Usa `-Silent` per scenari unattended (test). Il poller di stato usa
`GET /api/actions/status/{correlationId}` ogni 5 secondi (configurabile via
`StatusPollIntervalSeconds` / `StatusPollMaxMinutes`).

## API

### `POST /api/actions`

Endpoint **action-agnostic**: il tipo di azione viaggia nel body come
`actionType` (default `"wipe"` se omesso, validato contro
`Actions:AllowedTypes`). Valori supportati di default: `wipe`,
`autopilot-register`, `bitlocker-rotate`, `device-rename` (più le rispettive
varianti `*-runbook` se sono mappate in `RunbookBridge:Routes`). Headers obbligatori:

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

Esempio body `device-rename` (il `newName` **non** viene passato dal client;
lo risolve il backend interrogando il CMDB del cliente — vedi `Rename__Endpoint`):

```json
{
  "actionType": "device-rename",
  "deviceName": "DESKTOP-ABC",
  "entraDeviceId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "intuneDeviceId": "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy",
  "rename": { "serial": "PF3X1ABC" }
}
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

Questo è l'endpoint canonico per il monitoraggio client-side: sia il client standalone
sia il pacchetto Win32 fanno polling del `correlationId` restituito dal `POST /api/actions`
invece di ripetere chiamate al `POST`.

### `GET` / `POST /api/actions/ledger/{intuneDeviceId}[/reset]`

Endpoint operativi SecOps per ispezionare e resettare manualmente il ledger di
idempotenza (sblocco di un device quando un re-issue è intenzionalmente bloccato).
Solo sulla `Web` Function App. Defense-in-depth banking-grade:

1. **Function key** sul route HTTP;
2. **Kill-switch** `Idempotency:AdminApiEnabled=true` (off di default);
3. **mTLS richiesto** — il piano App Service ha `clientCertMode=Required` e
   **nessun** `clientCertExclusionPaths`, quindi anche l'admin surface riceve
   l'handshake del certificato client;
4. **Allow-list operatore** — il thumbprint del leaf certificato del chiamante
   deve essere in `Idempotency:AdminCertThumbprints` (CSV). Trust list
   distinta da `ClientCert:AllowedLeafThumbprints` (che pin-a i cert dei
   device), così a SecOps si può rilasciare un cert dedicato
   (smartcard/HSM-backed) senza dare ad ogni device cert il potere di reset.

Il campo `actor` dell'audit è vincolato al thumbprint del certificato
**verificato** (non al campo `actor` del body) — l'eventuale `actor` JSON è
conservato come `actorClaimed` solo per contesto operatore, accanto
all'identità anchored crittograficamente. Una function key trapelata **non**
può quindi più impersonare un admin nel trail non-ripudiabile.

Body POST: `{ "reason": "free-text mandatory", "actor": "alice@bank.com (optional context)" }`.

### `GET /api/schedule/me`

Endpoint **action-agnostic** che restituisce al device chiamante (mTLS +
binding cert↔EntraDeviceId) la wave schedulata più imminente che lo
riguarda, oppure `204 No Content` se non è membro di alcuna wave attiva.

Il *core* (Web Function) non sa cosa sia una "wave wipe": espone solo il
contratto generico `IScheduleProvider` (in `Shared`). Ogni capability che
vuole far parte della schedulazione registra un proprio provider nel
composition root del Web (`Program.cs`); l'aggregatore (`ScheduleAggregator`)
unisce le risposte di tutti i provider e ritorna quella con
`scheduledAtUtc` più vicino. Nuova capability ⇒ zero modifiche al core.

Filtri opzionali: `?actionType=wipe` (limita alla capability indicata).

Risposta 200:

```json
{
  "waveId": "9c2c6f01-2b54-4d6f-8a4b-1b9d3b18b8d0",
  "name": "Wipe ondata 3 - filiale Milano",
  "actionType": "wipe",
  "scheduledAtUtc": "2026-07-15T18:00:00+00:00",
  "status": "scheduled",
  "isImmediate": false,
  "description": "Devices ceduti al magazzino",
  "generatedAtUtc": "2026-07-10T09:42:01.123+00:00"
}
```

**Doppio gate temporale** (defense-in-depth):

- **Client-side** — un pacchetto Intune **Proactive Remediation**
  in `client/intune-remediation-schedule/` polla periodicamente
  `/api/schedule/me` (ogni 4h è il default raccomandato) e persiste lo
  snapshot in `%ProgramData%\IntuneWipeClient\schedule.json`.
  `Launch-Wipe.ps1` legge questo file prima di triggerare lo scheduled
  task del wipe: se è presente una wave futura, mostra all'utente
  "il wipe partirà alle 18:00" e non chiama l'API. Vedi il README
  dedicato in `client/intune-remediation-schedule/README.md` per il
  caricamento del pacchetto su Intune.
- **Capability-side** — `WipeActionRunner.RunAsync` consulta lo store
  `WipeScheduleStore` **prima** di chiamare Graph wipe: se il device è
  in una wave la cui `ScheduledAtUtc` è ancora futura, l'azione viene
  *deferita* (no Graph call, no ledger reservation, no status row) e
  l'evento `action.schedule.gated` viene emesso. Garantisce che un client
  manomesso o non aggiornato non possa anticipare il wipe.

#### Schema dello storage (contratto Portal ↔ Wipe capability)

Le wave vivono in due tabelle Azure sullo storage account del role Web
(stesso account di `actionstatus`):

| Tabella | PartitionKey | RowKey | Owner write | Owner read |
|---|---|---|---|---|
| `wipeschedulewaves`   | `WipeScheduleWave` (cost.) | `<waveId>` (GUID lower) | Portal | Portal + Wipe runner + Web (provider) |
| `wipeschedulemembers` | `<waveId>` (GUID lower) | `<entraDeviceId>` (GUID lower) | Portal | Portal + Wipe runner + Web (provider) |

Colonne wave: `ActionType` (sempre `wipe`), `Name`, `Description`,
`ScheduledAtUtc`, `Status` (`draft|scheduled|executing|completed|canceled`),
`CreatedBy`, `CreatedAtUtc`, `UpdatedAtUtc`. Colonne member: `DeviceName`,
`IntuneDeviceId`, `AddedBy`, `AddedAtUtc`.

I nomi di colonna sono il contratto tra il portale (write) e la
capability wipe (read) — vanno rinominati in entrambi i repo
contestualmente o si rompe il flusso.

#### Role assignment richiesto (manual one-shot fino al prossimo deploy infra)

Il portale (UAMI del web app) e il Web/Wipe role della Function App devono
poter leggere/scrivere sulle due tabelle:

```pwsh
$webStorage = az storage account show -g rg-idactions-dev `
  -n <idactionsstw...> --query id -o tsv
$portalUami = az identity show -g rg-idactions-portal-dev `
  -n <portal-uami-name> --query principalId -o tsv

# Portal: write-side
az role assignment create --assignee $portalUami `
  --role 'Storage Table Data Contributor' --scope $webStorage

# Wipe role UAMI (read-side, capability gate). Web role UAMI già ha
# permessi sullo stesso storage per 'actionstatus' — verificare che il
# ruolo sia almeno 'Storage Table Data Reader' o estenderlo a Contributor.
$wipeUami = az identity show -g rg-idactions-dev -n <wipe-uami-name> --query principalId -o tsv
az role assignment create --assignee $wipeUami `
  --role 'Storage Table Data Reader' --scope $webStorage
```

## Configurazione

Tutte le impostazioni sono centralizzate in **Azure App Configuration** (lette
da ogni app via `AppConfigRefreshMiddleware` con refresh sentinel) e possono
essere override come app settings della singola Function App.

> **Perché ogni Function App ha comunque diverse chiavi in `siteConfig.appSettings`?**
> Sono il **bootstrap minimo + i default**. Tre famiglie:
> 1. **Bootstrap obbligatorio del runtime Functions** — letto _prima_ che parta l'host (App Config non è ancora caricato): `AzureWebJobsStorage__*`, `APPLICATIONINSIGHTS_CONNECTION_STRING`, `AZURE_CLIENT_ID`.
> 2. **Bootstrap del provider App Configuration stesso** — `AppConfig__Endpoint` (URI dello store) e `App__Role` (etichetta usata per filtrare le key-value: `roleHint:"web"|"proc"|"wipe"|"autopilot"|"bitlocker"`).
> 3. **Default fallback** — tutto il resto (`ServiceBus__*`, `Idempotency__*`, `Audit__*`, `Graph__*`, `BitLocker__AllowedGroupId`, …). Sono i valori di partenza: il provider App Config li **sovrascrive a runtime** non appena trova le chiavi corrispondenti nello store, **senza redeploy**. Le 5 app hanno il ruolo `App Configuration Data Reader` su `appConfig` via UAMI (vedi `raAppConfigWeb/Proc/Wipe/Autopilot/BitLocker`).

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
| `ServiceBus__RenameActionQueue` | `rename-action` | Coda Proc → Rename (privilegiata) |
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
| `ActionStatusPoller__CronExpression` | _(da bicep)_ | NCRONTAB del poller (Proc). Default: ogni 5 secondi |
| `ActionStatus__MinPollIntervalSeconds` | `5` | Intervallo minimo tra due probe server-side della stessa riga `actionstatus` |
| `Idempotency__AdminApiEnabled` | `false` | Abilita gli endpoint `actions/ledger` admin (solo Web) |
| `Idempotency__AdminCertThumbprints` | _(vuoto = fail-closed)_ | CSV/`\|`/`;`-separated SHA-1 thumbprint dei certificati operatore autorizzati a chiamare `actions/ledger/*`. Vuoto significa "nessun admin abilitato" → ogni chiamata risponde 403. Usare un set di cert dedicati (smartcard/HSM-backed), **distinto** dai cert device. |
| `WipeRunbook__WebhookUrl` | _(vuoto)_ | **Deprecato** — usato dal vecchio `WipeRunbookForwardingRunner` per la sola capability `wipe-runbook`. Preferire `RunbookBridge:Routes:wipe-runbook` (vedi sotto). |
| `RunbookBridge:Routes:<actionType>` | _(vuoto)_ | **Meccanismo plug-in** per collegare una runbook al dispatcher. Esempio: `RunbookBridge:Routes:lock-runbook = https://<webhook>`. Una chiave per ciascuna capability runbook. Trattare come secret (Key Vault reference raccomandato). Cambia richiede restart del Proc app. |
| `BitLocker__AllowedGroupId` | _(default = `Wipe__AllowedGroupId`)_ | ObjectId gruppo Entra autorizzato alla rotazione recovery key (capability `bitlocker-rotate`) |
| `Rename__Endpoint` | _(obbligatorio per `device-rename`)_ | URL del CMDB del cliente per il **lookup** `serial → newName`. Può contenere il placeholder `{serial}` (sostituito URL-encoded) oppure essere un base URL a cui viene appeso il serial come ultimo segmento. Mancante ⇒ esito **permanent** (`failed:config-error`), nessun retry. |
| `Rename__AuthHeaderName` / `Rename__AuthHeaderValue` | `X-Api-Key` / _(vuoto)_ | Header opzionale per autenticare il lookup verso il CMDB. Il valore va trattato come secret (Key Vault reference raccomandato). |
| `Rename__NewNameJsonPath` | `newName` | Nome della property nella risposta JSON 200 del CMDB che contiene il nome canonico (case-insensitive). |
| `Rename__OnCollision` | `block` | Policy se il `newName` collide con un altro device su **Entra** (`/devices?$filter=displayName eq …`) o **Intune** (`/deviceManagement/managedDevices?$filter=deviceName eq …`). `block` = fail-closed (`denied:name-collision`); `warn` = audit + proseguire. Entra non impone unicità su `displayName` come l'AD on-prem, da qui il guardrail. |
| `Graph__TenantId` | tenant corrente | Tenant per i token Graph |
| `Graph__ManagedIdentityClientId` | _(da bicep)_ | clientId della UAMI |
| `App__Role` | _(da bicep)_ | `web`\|`proc`\|`wipe`\|`autopilot`\|`bitlocker`\|`rename` — letto da `AppRoleGuard` per fail-closed |

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
│   ├── main.bicep                      # Variante HARDENED: Function App + plan (1 EP1 + 5 FC1),
│   │                                   #   6 storage, 6 UAMI, Service Bus + queue, App Configuration,
│   │                                   #   App Insights, RBAC, VNet + NAT GW + Private Endpoint,
│   │                                   #   Automation Account + runbook (opt-in)
│   ├── main.parameters.json
│   ├── main-public.bicep               # Variante PUBLIC: stesso scope ma senza VNet/NAT GW/PE/
│   │                                   #   Private DNS/NSG. Storage con publicNetworkAccess=Enabled
│   │                                   #   e networkAcls.defaultAction=Allow.
│   └── main-public.parameters.json
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
│   ├── Capabilities.Wipe/              # capability "wipe" (Models, Runners, Services, Schedule)
│   ├── Capabilities.BitLocker/         # capability "bitlocker-rotate"
│   ├── Capabilities.Autopilot/         # capability "autopilot-register"
│   ├── Capabilities.Autopilot.Tests/   # xUnit sulla capability Autopilot
│   ├── Capabilities.Rename/            # capability "device-rename" (LOOKUP customer CMDB + Graph setDeviceName)
│   ├── Web/                            # IntuneDeviceActions.Web (EP1, mTLS)
│   │   └── Functions/                  # ActionRequest, ActionStatus, ActionLedger_*, ScheduleManifest
│   ├── Proc/                           # IntuneDeviceActions.Proc (Flex)
│   │   └── Functions/                  # RequestIntake, ActionDispatch, ActionStatusPoller
│   ├── Wipe/                           # IntuneDeviceActions.Wipe (Flex, privilegiata)
│   │   └── Functions/                  # WipeAction (consumer wipe-action)
│   ├── BitLocker/                      # host privilegiato BitLocker (consumer bitlocker-action)
│   ├── Autopilot/                      # host privilegiato Autopilot (consumer autopilot-action)
│   └── Rename/                         # host privilegiato Rename (consumer rename-action)
├── tools/
│   ├── Deploy-IntuneDeviceActions.ps1  # orchestrator end-to-end
│   └── Grant-GraphPermissions.ps1      # grant idempotente dei ruoli Graph alle UAMI
├── runbooks/                           # variante Automation PowerShell 7.2 (demo plug-in)
│   ├── Invoke-DeviceWipe.runbook.ps1
│   ├── Invoke-AutopilotRegister.runbook.ps1
│   ├── Invoke-RotateBitLockerKey.runbook.ps1
│   ├── Invoke-DeviceRename.runbook.ps1
│   └── README.md
├── client/
│   ├── Invoke-DeviceWipe.ps1           # PS 5.1 client standalone (entrypoint wipe)
│   ├── Invoke-AutopilotRegister.ps1    # PS 5.1 client (self-registration Autopilot)
│   ├── Invoke-BitLockerKeyRotation.ps1 # PS 5.1 client (rotate BitLocker key)
│   ├── Invoke-RenameDevice.ps1         # PS 5.1 client (device rename)
│   ├── DeviceIdentity.psm1             # modulo identità device (Pester-tested)
│   ├── ActionStatusClient.psm1         # helper polling GET /api/actions/status
│   ├── MdmSyncNudge.psm1               # nudge MDM sync post-wipe (best-effort)
│   ├── WipeConfirmationDialog.ps1      # builder WinForms bifase (fase 1 + fase 2)
│   ├── intune-remediation-schedule/    # Intune Proactive Remediation — schedule gate
│   │   ├── Detect.ps1                  # verifica freschezza di schedule.json
│   │   ├── Remediate.ps1               # polla /api/schedule/me, persiste schedule.json
│   │   └── README.md
│   ├── intune-win32-package/           # Win32 LOB app per distribuzione via Intune
│   │   ├── Build-IntuneWinPackage.ps1  # produce dist\IntuneWipeClient.intunewin
│   │   ├── Publish-ToIntune.ps1        # pubblica / aggiorna la Win32 app su Intune (idempotente)
│   │   ├── README.md
│   │   └── source/                     # file installati sul device
│   │       ├── Install.ps1             # installa file, task SYSTEM, shortcut, chiave di detection
│   │       ├── Uninstall.ps1           # rimozione pulita
│   │       ├── Detect.ps1              # detection rule Intune
│   │       ├── Launch-Wipe.ps1         # launcher user-context: mostra UI, triggera il task SYSTEM
│   │       ├── Invoke-WipeFromTask.ps1 # task SYSTEM: usa il cert, chiama l'API, persiste result
│   │       ├── Watch-WipeStatus.ps1    # task SYSTEM: polla status e aggiorna il file di stato
│   │       ├── WipeConfirmationDialog.ps1  # UI bifase (fase 1 conferma + fase 2 progress live)
│   │       ├── WipeResultDialogs.ps1   # dialoghi di risultato (success / error / unknown)
│   │       ├── Show-WipeProgressDialog.ps1 # dialogo monitoraggio live (tails status JSON)
│   │       ├── DeviceIdentity.psm1
│   │       ├── ActionStatusClient.psm1
│   │       ├── MdmSyncNudge.psm1
│   │       ├── Invoke-DeviceWipe.ps1   # copia dal parent — synced da Build-IntuneWinPackage.ps1
│   │       ├── config.json             # ApiUrl + FunctionKey (ACL = SYSTEM + Administrators)
│   │       ├── version.txt             # versione package (es. 1.0.22)
│   │       └── assets/                 # icone Win32 (16/24/32/48/64/128/256 px)
│   └── tests/                          # Pester tests (DeviceIdentity, ActionStatusClient)
└── docs/
    ├── architecture.png
    ├── dialog-screenshot.png           # screenshot fase 1 — conferma (generato da Capture-DialogScreenshot.ps1)
    ├── dialog-progress.png             # screenshot fase 2 — esecuzione live (generato da Capture-DialogScreenshot.ps1)
    ├── Capture-DialogScreenshot.ps1    # genera tutti i frame PNG (phase1/phase2/success/error)
    ├── architectural-improvements.md
    ├── capabilities-autopilot-bitlocker.md
    ├── cost-analysis-vnet-vs-public.md
    ├── howto-new-capability-function.md
    ├── howto-new-capability-runbook.md
    ├── security-compliance-banking.md  # inventario controlli + mappatura PCI-DSS/ISO 27001/EBA/DORA/Banca d'Italia 285/13
    ├── security-gaps-pending.md        # cosa manca / normativa / costo infra (vista sintetica per stakeholder)
    └── security-remediation-roadmap.md # sizing effort + phasing 3 sprint per chiudere i gap
```

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
- [x] Capability `device-rename` (rename via lookup CMDB cliente + `setDeviceName` Graph, con pre-check collisioni `displayName` su Entra _e_ `deviceName` su Intune)
- [x] **Client Win32 package** — architettura biprocesso user/SYSTEM, dialogo bifase (conferma + progress live), dialoghi di risultato (success/error/unknown), self-test automatico all'installazione
- [x] **Schedule gate** — `GET /api/schedule/me` (endpoint action-agnostic + `IScheduleProvider` plug-in), gate server-side in `WipeActionRunner`, Intune Proactive Remediation (`client/intune-remediation-schedule/`) per sincronizzare il manifest sul device
- [ ] Notifica esito (Teams webhook / email) al termine del wipe
- [ ] Rimozione della Function Key dal client (mTLS-only dietro APIM/App Gateway)
- [ ] CA trust lifecycle via Key Vault references
- [ ] APIM/App Gateway WAF davanti alla Function con rate-limit per device
- [ ] Workflow GitHub Actions per CI/CD (con boundary checks post-deploy)

> Dettaglio completo delle proposte architetturali in
> [`docs/architectural-improvements.md`](docs/architectural-improvements.md).
>
> Inventario controlli di sicurezza con mappatura ai framework bancari
> (PCI-DSS v4.0, ISO 27001:2022, EBA/GL/2019/04, DORA, Banca d'Italia 285/13,
> NIS2, GDPR) in
> [`docs/security-compliance-banking.md`](docs/security-compliance-banking.md).
>
> **Roadmap di remediation** per chiudere i 10 gap banking-grade (sizing
> effort + costi infra + decisioni cliente + phasing 3 sprint) in
> [`docs/security-remediation-roadmap.md`](docs/security-remediation-roadmap.md).
>
> Vista **sintetica per stakeholder** (cosa manca / normativa / costo infra,
> senza effort né phasing) in
> [`docs/security-gaps-pending.md`](docs/security-gaps-pending.md).

## Licenza

[MIT](LICENSE) © Roberto Gramellini