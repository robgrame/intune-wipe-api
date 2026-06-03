# Intune Device Self-Wipe API

[![.NET](https://img.shields.io/badge/.NET-10-512BD4?logo=dotnet&logoColor=white)](https://dotnet.microsoft.com/)
[![Azure Functions](https://img.shields.io/badge/Azure_Functions-isolated-0062AD?logo=azurefunctions&logoColor=white)](https://learn.microsoft.com/azure/azure-functions/)
[![Bicep](https://img.shields.io/badge/IaC-Bicep-1E5DBE?logo=azurepipelines&logoColor=white)](https://learn.microsoft.com/azure/azure-resource-manager/bicep/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

> Soluzione serverless end-to-end per consentire ad un dispositivo Windows gestito da Intune di richiedere in autonomia il proprio **wipe (factory reset)**, con difesa in profondità: certificato dispositivo Intune (mTLS), allow-list nativa via gruppo Entra ID, validazione di ownership, esecuzione asincrona via coda e audit completo.

> ⚠️ **Architecture update (current canonical state)** — questo README descrive ancora la fase intermedia *plug-in routing*. La codebase deployata oggi (`tools/Deploy-IntuneDeviceActions.ps1`) ha completato tre refactor successivi:
>
> | Aspetto | Vecchio | **Attuale** |
> |---|---|---|
> | Solution / progetti | `IntuneWipeApi*` | `IntuneDeviceActions*` |
> | Function App names | `intwipe-{web,proc,wipe}-*` | `idactions-{web,proc,wipe}-*` |
> | HTTP endpoint | `/api/wipe`, `/api/wipe/status`, `/api/wipe-ledger/*` | `/api/actions/wipe`, `/api/actions/status`, `/api/action-ledger/*` |
> | Function names | `WipeRequest`, `WipeProcessor`, `WipeStatus`, `WipeLedgerAdmin`, `WipeStatusPoller` | `ActionRequest`, `RequestIntake`, `ActionStatus`, `ActionLedger_Get`/`ActionLedger_Reset`, `ActionStatusPoller` |
> | Code di disaccoppiamento | **Azure Storage Queue** (`wipe-requests`, `action-dispatch`, `wipe-action`) | **Azure Service Bus** (`action-requests`, `action-dispatch`, `wipe-action`) — managed identity, dead-letter nativo, lock renewal |
> | Hosting plan | 3× EP1 ElasticPremium | **1× EP1 (Web, mTLS always-on) + 2× FC1 Flex Consumption (Proc + Wipe, scale-to-zero)** |
> | Ledger blob | `wipe-ledger` | `action-ledger` |
> | Configurazione | App Settings / Bicep | **Azure App Configuration** centralizzata + refresh sentinel per app |
>
> Per il deploy end-to-end consulta direttamente `tools/Deploy-IntuneDeviceActions.ps1` e `tools/Grant-GraphPermissions.ps1`. La tabella Componenti e i diagrammi sotto verranno aggiornati in un Phase E commit dedicato.

## Indice

- [Architettura](#architettura)
- [Componenti](#componenti)
- [Controlli di sicurezza](#controlli-di-sicurezza-in-profondit%C3%A0)
- [Permessi Microsoft Graph](#permessi-microsoft-graph)
- [Quickstart deploy](#quickstart-deploy)
- [Uso del client PowerShell](#uso-del-client-powershell-51)
- [API](#api)
- [Configurazione](#configurazione)
- [Osservabilità & audit](#osservabilità--audit)
- [Struttura del repository](#struttura-del-repository)
- [Roadmap](#roadmap)
- [Licenza](#licenza)

## Architettura

<p align="center">
  <img src="docs/architecture.png" alt="Wipe request workflow: PS 5.1 client → mTLS → WipeRequest HTTP function (Web app) → wipe-requests queue → WipeProcessor dispatcher (Proc) → action-dispatch queue → ActionDispatch router → WipeForwardingRunner → wipe-action queue → WipeAction consumer (Wipe app, privileged Graph identity) → Microsoft Graph wipe" width="640" />
</p>

L'endpoint pubblico fa **solo** validazione (certificato + payload) e
accodamento. L'esecuzione effettiva del wipe avviene su una **terza Function
App dedicata e privilegiata**, disaccoppiata e ritentabile, raggiunta tramite
un router plug-in. La soluzione è organizzata in **tre Function App** (`Web`,
`Proc`, `Wipe`) più una libreria condivisa (`Shared`), con identità, storage,
App Service Plan e permessi separati per ciascun ruolo.

## Componenti

| # | Componente | App | Ruolo |
|---|---|---|---|
| 1 | **`Invoke-DeviceWipe.ps1`** (PowerShell 5.1) | client | Raccoglie identità device, mostra UI WinForms di conferma (irreversibilità + ~90 min di indisponibilità + parola `WIPE` da digitare), invoca l'API in mTLS con timestamp + nonce anti-replay. |
| 2 | **`WipeRequest`** (HTTP Function) | **Web** | Valida headers anti-replay, valida cert client (X509 chain + EKU + CRL opzionale), verifica binding cert↔device, valida payload, accoda messaggio, risponde `202 Accepted` con `correlationId`. |
| 3 | **Azure Storage Queue** `wipe-requests` | Web→Proc | Disaccoppia ricezione ed esecuzione; retry automatici, dead-letter su `wipe-requests-poison`. |
| 4 | **`WipeProcessor`** (Queue trigger, non esposta) | **Proc** | **Dispatcher sottile**: valida formato + app role, traduce il messaggio in un `ActionDispatchMessage{ActionType="wipe"}` e lo accoda su `action-dispatch`. Nessuna logica di business. |
| 4b | **Azure Storage Queue** `action-dispatch` | Proc | Coda del router plug-in. Decouple il dispatcher dai runner concreti; nuove capability (lock, BitLocker rotate, ...) si aggiungono come nuovo `IActionRunner` senza toccare HTTP, queue o dispatcher. |
| 4c | **`ActionDispatch`** (Queue trigger, non esposta) | **Proc** | **Router** plug-in: deserializza la busta, risolve l'`IActionRunner` per `ActionType` via `ActionRunnerRegistry`, esegue. Onorare `FailOnError` per la retry policy della coda. |
| 4d | **`WipeForwardingRunner`** (`IActionRunner`, Type="wipe") | **Proc** | Runner non privilegiato: **inoltra** la busta sulla coda `wipe-action`. Il Proc non chiama Graph né tocca il ledger. |
| 4e | **`WipeRunbookForwardingRunner`** (`IActionRunner`, Type="wipe-runbook") | **Proc** | Variante demo del modello plug-in: invece di accodare, fa `POST` su un webhook **Azure Automation** (runbook PowerShell 7.2 `Invoke-DeviceWipe`). Stesso contratto, runtime diverso. |
| 4f | **Azure Storage Queue** `wipe-action` | Proc→Wipe | Coda per-capability che consegna la busta alla sola app privilegiata. |
| 4g | **`WipeAction`** (Queue trigger, non esposta) | **Wipe** | Consumer dedicato che risolve direttamente `WipeActionRunner`. È l'unica function deployata sull'app privilegiata. |
| 4h | **`WipeActionRunner`** (`IActionRunner`, Type="wipe") | **Wipe** | Logica wipe vera: risolve device Entra, verifica membership gruppo, verifica ownership Intune↔Entra, **riserva slot idempotency su blob ledger**, esegue `POST /deviceManagement/managedDevices/{id}/wipe`, inizializza status tracker, esegue nudges (sync + reboot) best-effort. |
| 5 | **Blob `wipe-ledger`** | Wipe/Proc | Ledger idempotency: un blob per `intuneDeviceId` con stato `Reserved`/`Issued`/`Failed` per garantire un singolo wipe anche a fronte di retry queue at-least-once. |
| 6a | **`WipeStatus`** (HTTP Function) | **Web** | `GET /api/wipe/status` — in mTLS, ritorna lo stato di un wipe (proiezione della tabella `wipestatus`). Binding cert↔device anti-IDOR: un device non può leggere l'esito di un altro. |
| 6b | **`WipeStatusPoller`** (Timer trigger) | **Proc** | Poller schedulato che interroga Graph per l'`actionState` dei wipe non terminali e aggiorna la tabella `wipestatus` + audit. |
| 6c | **`WipeLedgerAdmin`** (HTTP Function) | **Web** | Endpoint SecOps `GET`/`POST /api/wipe-ledger/{intuneDeviceId}[/reset]` per ispezionare/resettare il ledger. Gated da `Idempotency:AdminApiEnabled` (off di default). |
| 7 | **Tre User-Assigned Managed Identity** | — | `uami-web` (no Graph privilegiato), `uami` (worker/proc, no Graph privilegiato), `uami-wipe` (l'unica con i consent Graph distruttivi). Vedi [Isolamento](#isolamento-delle-tre-function-app). |
| 8 | **Azure App Configuration** | tutte | Store centralizzato delle impostazioni con refresh sentinel; ogni app lo legge via `AppConfigRefreshMiddleware` con `roleHint` (`web`/`proc`/`wipe`). |
| 9 | **Application Insights + tabella `auditevents`** | tutte | Audit dual-write: `customEvents` (non-sampled) + Azure Table durabile, entrambi con `correlationId`. |

### Architettura plug-in (router + runner)

```text
HTTP / mTLS  ──▶  WipeRequest        ──▶  [wipe-requests]  ──▶  WipeProcessor (DISPATCHER)
   (Web app)        (Web app)                                       (Proc app)
                                                                       │ enqueue ActionDispatchMessage{type="wipe"}
                                                                       ▼
                                                               [action-dispatch]
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
                              │ LockActionRunner            type="lock"          (futuro)      │
                              │ BitLockerRotateRunner       type="bitlocker"     (futuro)      │
                              └──────────────────────────────────────────────────────────────┘
                                                                      ▲
                                                                      │ aggiungi qui per nuove capability
```

Il `WipeProcessor`/`ActionDispatch` (Proc) **non** chiamano mai Microsoft
Graph né toccano il ledger di idempotenza: si limitano a instradare. La logica
distruttiva e l'identità Graph privilegiata vivono **solo** sulla `Wipe`
Function App, dietro la coda per-capability `wipe-action`.

Le risorse **CORE** (HTTP function, queue `wipe-requests`/`action-dispatch`/`wipe-action`,
`WipeProcessor`, `ActionDispatch`, `WipeAction`) non vanno mai modificate per
aggiungere una nuova capability: il contratto è la busta `ActionDispatchMessage` e
l'interfaccia `IActionRunner`.

#### Aggiungere un nuovo action runner

1. Crea una classe in `src/Shared/Actions/Runners/` che implementa `IActionRunner`:
   ```csharp
   public sealed class LockActionRunner : IActionRunner
   {
       public string Type => "lock";
       public async Task RunAsync(ActionDispatchMessage env, CancellationToken ct)
       {
           var payload = env.Payload.Deserialize<LockPayload>();
           // ... logica + audit + idempotency a piacere
       }
   }
   ```
2. Registralo nel `Program.cs` dell'app appropriata (`Proc` per un runner che gira
   inline nel router, oppure su un'app dedicata sul modello `Wipe` se serve un
   privilege boundary):
   ```csharp
   services.AddSingleton<IActionRunner, LockActionRunner>();
   ```
3. Aggiungi un producer (nuovo endpoint HTTP, o estensione di `WipeRequest`)
   che enqueue una `ActionDispatchMessage{ActionType="lock", Payload=...}`
   via `ActionDispatchEnqueuer`.

Nessuna modifica a `WipeRequestFunction`, `WipeProcessorFunction`,
`ActionDispatchFunction`, alle code o al Bicep. Eventi audit dedicati:
`action.dispatch.enqueued`, `action.dispatch.received`, `action.dispatch.completed`,
`action.dispatch.runner-failed`, `action.dispatch.no-runner`,
`action.dispatch.invalid-envelope`.

### Isolamento delle tre Function App

L'API HTTP pubblica (`Web`), il dispatcher/router (`Proc`) e l'esecutore
privilegiato del wipe (`Wipe`) girano in **tre Function App distinte**
(`*-web-*`, `*-proc-*`, `*-wipe-*`) su **tre App Service Plan Linux EP1
separati** (`*-plan-web-*`, `*-plan-proc-*`, `*-plan-wipe-*`), con identità
(`uami-web`, `uami`, `uami-wipe`), permessi, **storage account separati**
(`*stw*`, `*stp*`, `*stwipe*`) e configurazione separata. **Isolamento per
artefatto**: ogni function class è compilata in un assembly diverso
(`IntuneWipeApi.Web/Proc/Wipe`), quindi una function esiste fisicamente solo
sull'app a cui appartiene. Il guard in-code `AppRoleGuard` (legge `App__Role`,
impostato via `roleHint` su App Configuration) è un'ulteriore difesa
fail-closed. Risultato:

- La app pubblica (`Web`) scrive sul proprio `AzureWebJobsStorage` (`*stw*`) e
  ha **solo** `Queue Data Message Sender` **scoped sulla singola coda**
  `wipe-requests` dello storage del Proc — non può leggere/cancellare messaggi.
- Il `Proc` instrada soltanto: ha i permessi sulle proprie code
  (`action-dispatch`, `wipe-action` come sender) ma **non** ha l'identità Graph
  privilegiata e non esegue il wipe.
- Il **privilege boundary distruttivo** (consent `DeviceManagementManagedDevices.PrivilegedOperations.All`)
  vive **solo** sull'identità `uami-wipe` della `Wipe` Function App, l'unica che
  consuma la coda `wipe-action` e chiama l'API di wipe Graph.
- I tre plan separati significano **VM host distinti**: un eventuale escape di
  sandbox / vulnerabilità host-level su una superficie non vede i processi né i
  token UAMI cached in memoria delle altre.
- Anche se la superficie pubblica venisse compromessa, l'attaccante non può
  pilotare Graph, manomettere il ledger, né iniettare codice nell'esecutore
  privilegiato.

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
Managed Identity con permessi minimi, nessuna credenziale in codice.

## Permessi Microsoft Graph

Assegnati come **application permissions** alla Managed Identity (richiede consent admin):

- `DeviceManagementManagedDevices.PrivilegedOperations.All`
- `DeviceManagementManagedDevices.Read.All`
- `Device.Read.All`
- `GroupMember.Read.All` _(per `checkMemberGroups`)_

## Quickstart deploy

### Prerequisiti

- Azure subscription + permessi `Owner` o `Contributor` + `User Access Administrator` sul RG (per le role assignment)
- Tenant con Intune e CA SCEP/PKCS che emette certificati ai dispositivi
- `az` CLI ≥ 2.60, `dotnet` SDK 10
- Un gruppo di sicurezza Entra ID che conterrà i device autorizzati al self-wipe

### 1. Crea il gruppo Entra (se non esiste)

```pwsh
$groupId = az ad group create `
  --display-name 'Intune-Wipe-Authorized' `
  --mail-nickname 'IntuneWipeAuthorized' `
  --description 'Devices authorized to request self-wipe' `
  --query id -o tsv
```

### 2. Deploy infrastruttura

```pwsh
az group create -n rg-intwipe-dev -l westeurope
az deployment group create `
  -g rg-intwipe-dev `
  -f infra/main.bicep `
  -p infra/main.parameters.json `
  -p allowedGroupId=$groupId `
  -p trustedCaThumbprints='<THUMB_ROOT_OR_INTERMEDIATE>'
```

> **Importante**: `trustedCaThumbprints` (o `trustedCaCertificatesBase64`) **deve** essere valorizzato: senza un trust anchor configurato la validazione cert fallisce in modo fail-closed.

Output utili: `appConfigName`, `appConfigEndpoint`, `webAppName`, `webAppHostname`, `procAppName`, `procAppHostname`, `wipeAppName`, `wipeAppHostname`, `uamiWipePrincipalId`, `uamiWorkerPrincipalId`, `uamiWebPrincipalId`, `storageWebAccount`, `storageProcAccount`, `storageWipeAccount`, `wipeQueueName`, `wipeActionQueueName`, `ledgerContainerName`, `automationAccountName`, `runbookName`.

### 3. Concedi i permessi Graph alle Managed Identity

L'UAMI del worker (`uamiWorkerPrincipalId`) riceve **tutti** i consent Graph
(necessari per la chiamata di wipe). L'UAMI web (`uamiWebPrincipalId`) riceve
**solo** `Device.Read.All` — strettamente richiesto dalla modalità di binding
`SanDnsLookup` (risoluzione directory per certificati AD CS che portano
identità AD invece di EntraDeviceId). `Device.Read.All` è read-only e non
concede capacità distruttive: il privilege boundary del wipe (che richiede
`DeviceManagementManagedDevices.PrivilegedOperations.All`) ora vive solo
sulla **wipe-runner Function App dedicata** (UAMI `uamiWipe`). Il worker
(`uamiWorker`) ora si occupa solo del routing/forwarding: NON serve più
concedergli i ruoli privilegiati Graph (mantenerli temporaneamente non
crea rischi, ma per ottenere il privilege boundary completo è raccomandato
rimuoverli dopo il cutover — vedi sezione "Cutover privilegi" più sotto).

Se non userai mai `SanDnsLookup` (cert SCEP/PKCS Intune nativi con
`{{AAD_Device_ID}}`), puoi omettere il consent su `uamiWebPrincipalId` — il
modulo va in fail-closed loggando un warning.

```pwsh
$wipePrincipalId   = '<uamiWipePrincipalId   dall''output>'
$webPrincipalId    = '<uamiWebPrincipalId    dall''output>'
$graphSpId         = az ad sp list --filter "appId eq '00000003-0000-0000-c000-000000000000'" --query "[0].id" -o tsv

function Grant-GraphAppRole($principalId, $roleValue) {
  $rid = az ad sp show --id $graphSpId --query "appRoles[?value=='$roleValue'].id | [0]" -o tsv
  $body = "{`"principalId`":`"$principalId`",`"resourceId`":`"$graphSpId`",`"appRoleId`":`"$rid`"}"
  $tmp = New-TemporaryFile; $body | Set-Content -Encoding ascii $tmp
  az rest --method POST `
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$principalId/appRoleAssignments" `
    --headers "Content-Type=application/json" --body "@$($tmp.FullName)"
  Remove-Item $tmp
}

# Wipe-runner (dedicated): full Graph scope for wipe execution
foreach ($r in @(
  'DeviceManagementManagedDevices.PrivilegedOperations.All',
  'DeviceManagementManagedDevices.Read.All',
  'Device.Read.All',
  'GroupMember.Read.All'
)) { Grant-GraphAppRole $wipePrincipalId $r }

# Web: ONLY Device.Read.All (read-only directory enumeration for SanDnsLookup)
Grant-GraphAppRole $webPrincipalId 'Device.Read.All'
```

**Cutover privilegi (post-deploy Option-2):** una volta che la wipe-runner
app è operativa, puoi revocare i ruoli Graph privilegiati al worker per
chiudere completamente il privilege boundary:

```pwsh
$workerPrincipalId = '<uamiWorkerPrincipalId dall''output>'
$assignments = az rest --method GET `
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$workerPrincipalId/appRoleAssignments" `
  --query "value[?resourceId=='$graphSpId'].id" -o tsv
foreach ($a in ($assignments -split "`n" | Where-Object { $_ })) {
  az rest --method DELETE `
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$workerPrincipalId/appRoleAssignments/$a"
}
```

### 4. Pubblica il codice sulle tre Function App

Ogni Function App ha il proprio assembly (`Web`, `Proc`, `Wipe`): pubblica e
deploya ciascun progetto sull'app corrispondente.

```pwsh
cd src
foreach ($p in @(
  @{ proj = 'Web';  app = '<webAppName>'  },
  @{ proj = 'Proc'; app = '<procAppName>' },
  @{ proj = 'Wipe'; app = '<wipeAppName>' }
)) {
  dotnet publish "$($p.proj)/IntuneWipeApi.$($p.proj).csproj" -c Release -o "./publish-$($p.proj)"
  Compress-Archive -Path "./publish-$($p.proj)/*" -DestinationPath "./publish-$($p.proj).zip" -Force
  az functionapp deployment source config-zip `
    -g rg-intwipe-dev -n $p.app --src "./publish-$($p.proj).zip"
}
```

### 5. Aggiungi device al gruppo allow-list

```pwsh
$deviceObjId = az ad device list --filter "deviceId eq '<entraDeviceId>'" --query "[0].id" -o tsv
az ad group member add --group $groupId --member-id $deviceObjId
```

## Uso del client PowerShell 5.1

Distribuibile via Intune (Win32 app, esecuzione in contesto SYSTEM) oppure
eseguibile manualmente:

```powershell
.\client\Invoke-DeviceWipe.ps1 `
  -ApiUrl       'https://<func>.azurewebsites.net/api/wipe' `
  -CertificateSubjectLike '*Intune MDM Device CA*' `
  -FunctionKey  '<function-key>'
```

Lo script:

1. Legge l'**Entra Device Id** da `dsregcmd /status`
2. Legge l'**Intune Device Id** (`DeviceClientId`) dal registro
   `HKLM:\SOFTWARE\Microsoft\Enrollments\*`
3. Mostra una finestra WinForms con:
   - intestazione rossa di warning
   - dettagli del dispositivo
   - avviso esplicito di irreversibilità e ~90 minuti di downtime
   - checkbox di consapevolezza obbligatoria
   - input testuale che richiede di digitare `WIPE` per abilitare il bottone

   <p align="center">
     <img src="docs/dialog-screenshot.png" alt="Schermata della finestra WinForms di conferma con warning rosso, dettagli del device, checkbox di consapevolezza, campo testuale 'WIPE' e pulsante 'Esegui reset' abilitato" width="520" />
   </p>

4. Sceglie il certificato dispositivo da `Cert:\LocalMachine\My`
5. Invoca l'API con `Invoke-RestMethod -Certificate` e mostra il
   `correlationId` per riferimento al supporto

Usa `-Silent` per scenari unattended (test).

## API

### `POST /api/wipe`

Headers obbligatori:

- `x-functions-key: <function-key>`
- `Content-Type: application/json`
- mutual TLS con certificato dispositivo Intune

Body:

```json
{
  "deviceName": "DESKTOP-ABC",
  "entraDeviceId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "intuneDeviceId": "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
}
```

Risposta `202 Accepted`:

```json
{
  "status": "queued",
  "message": "wipe request accepted and queued",
  "correlationId": "..."
}
```

Codici di errore:

| Code | Significato |
|------|-------------|
| 400 | Payload non valido (campi mancanti o non GUID) |
| 401 | Certificato client mancante o non valido |
| 502 | Errore upstream Microsoft Graph (riconciliato via retry coda) |

### `GET /api/wipe/status`

Stato di un wipe precedentemente accodato (proiezione della tabella
`wipestatus`, aggiornata dal poller). Stessi requisiti di auth di `POST /api/wipe`
(mTLS + binding cert↔device): un device può leggere solo il proprio esito.
Esiti possibili: `404` (nessuna riga), `401` (cert/binding), `403` (la riga
appartiene a un altro device), `410` (chiamata sull'app sbagliata).

### `GET` / `POST /api/wipe-ledger/{intuneDeviceId}[/reset]`

Endpoint operativi SecOps per ispezionare e resettare manualmente il ledger di
idempotenza (sblocco di un device quando un re-wipe è intenzionalmente bloccato).
Solo sulla `Web` Function App, protetti da function key e disabilitati di default
(`Idempotency:AdminApiEnabled=true` per abilitarli).

## Configurazione

Tutte le impostazioni sono centralizzate in **Azure App Configuration** (lette
da ogni app via `AppConfigRefreshMiddleware` con refresh sentinel) e possono
essere override come app settings della singola Function App:

| Setting | Default | Descrizione |
|---|---|---|
| `AppConfig__Endpoint` | _(da bicep)_ | Endpoint dell'Azure App Configuration store. Accesso via UAMI (`App Configuration Data Reader`), local auth disabilitato. |
| `Queue__WipeQueueName` | `wipe-requests` | Nome coda HTTP→dispatcher |
| `Actions__DispatchQueueName` | `action-dispatch` | Coda del router plug-in (Proc) |
| `WipeAction__QueueName` | `wipe-action` | Coda per-capability che consegna alla `Wipe` app privilegiata |
| `ClientCert__TrustedCaThumbprints` | _(vuoto)_ | CSV thumbprint root/intermediate CA che devono comparire nella chain. **Richiesto** (o almeno un cert in `TrustedRootCertificates`) |
| `ClientCert__TrustedRootCertificates` | _(vuoto)_ | Base64 DER delle **ROOT CA** (self-signed). Caricate in `CustomTrustStore` come trust anchors. Separa con `|` `,` o `;`. |
| `ClientCert__TrustedIntermediateCertificates` | _(vuoto)_ | Base64 DER delle **CA intermedie**. Caricate solo in `ExtraStore` (hint per la costruzione della catena, **non** trust anchor). |
| `ClientCert__TrustedCaCertificates` | _(vuoto)_ | **Deprecato.** Bag legacy: i cert vengono classificati automaticamente come root o intermediate in base al flag self-signed. Preferire i due setting sopra. |
| `ClientCert__AllowedLeafThumbprints` | _(vuoto)_ | CSV pin opzionale del thumbprint del certificato leaf |
| `ClientCert__CheckRevocation` | `false` | Abilita check CRL/OCSP sulla chain |
| `ClientCert__RevocationMode` | `Online` | `Online`\|`Offline`\|`NoCheck` |
| `ClientCert__RevocationFlag` | `ExcludeRoot` | `ExcludeRoot`\|`EntireChain`\|`EndCertificateOnly` |
| `ClientCert__RequireClientAuthEku` | `true` | Richiede EKU Client Authentication (1.3.6.1.5.5.7.3.2) |
| `ClientCert__RequireClientCert` | `true` | Impone cert client (fail-closed se mancante) |
| `ClientCert__TrustForwardedHeader` | `true` | **DEVE essere `true` su App Service**: anche con `clientCertMode=Required` il cert viene consegnato all'app via header `X-ARR-ClientCert`, non via `HttpContext.Connection.ClientCertificate`. |
| `ClientCert__DeviceIdBindingClaim` | `Auto` | `Auto`\|`SubjectCN`\|`SanDns`\|`SanUri`\|`Thumbprint`\|`SanDnsLookup`\|`Disabled` — strategia per legare il certificato all'`entraDeviceId`. **`Auto`** (raccomandato multi-PKI) prova in ordine: `ThumbprintToDeviceMap` (intent operatore vince) → `SanUri` → `SanDns` → `SubjectCN` → `SanDnsLookup`. Le strategie claim-based sono **strict**: il valore della SAN o del CN deve **essere uguale** a un GUID — niente estrazione substring, niente scan dell'intero DN (anti-IDOR). **`SanDnsLookup`** risolve il SAN DNS (FQDN/short) via MS Graph `displayName eq` per i cert AD CS che non portano l'EntraDeviceId; richiede `Device.Read.All` sulla UAMI web; fail-closed su 0 match, >1 match, Graph error. **`Thumbprint`** usa solo la mappa operatore. **`Disabled`** disattiva il binding (sconsigliato). |
| `ClientCert__ThumbprintToDeviceMap` | _(vuoto)_ | Mappa operatore `thumbprint=EntraDeviceId` per le modalità `Auto`/`Thumbprint`. Formato: `THUMB1=guid1\|THUMB2=guid2`. Duplicati di stesso thumbprint mappato a GUID diversi sono **rifiutati fail-closed** all'avvio (ERROR loggato). Escape-hatch quando il Subject del cert non contiene il device id. |
| `ClientCert__DirectoryLookupPositiveTtlMinutes` | `15` | TTL della cache per i risultati positivi della `SanDnsLookup` (riduce throttling Graph). |
| `ClientCert__DirectoryLookupNegativeTtlMinutes` | `1` | TTL della cache per i risultati negativi (corto per non bloccare onboarding nuovi device). |
| `Replay__MaxTimestampSkewSeconds` | `300` | Skew massimo (s) per `X-Request-Timestamp` |
| `Idempotency__StorageAccount` | _(da bicep)_ | Storage account del ledger blob |
| `Idempotency__BlobContainer` | `wipe-ledger` | Container blob del ledger idempotency |
| `Wipe__AllowedGroupId` | _(obbligatorio)_ | ObjectId gruppo Entra |
| `Wipe__KeepEnrollmentData` | `false` | Mantiene enrollment Intune (Autopilot rimane registrato; il device si ri-enrolla senza factory-reset completo). **Utile in DEV** per evitare il provisioning Autopilot da zero ad ogni test. In `dev` corrente è impostato a `true`. |
| `Wipe__KeepUserData` | `false` | Mantiene dati utente |
| `WipeStatus__TableName` | `wipestatus` | Tabella di tracking dello stato wipe (alimenta `GET /api/wipe/status`) |
| `WipeStatusPoller__CronExpression` | _(da bicep)_ | NCRONTAB del poller (Proc) che riconcilia lo stato via Graph |
| `Idempotency__AdminApiEnabled` | `false` | Abilita gli endpoint `wipe-ledger` admin (solo Web) |
| `WipeRunbook__WebhookUrl` | _(vuoto)_ | Webhook del runbook Automation per la capability `wipe-runbook` (variante demo). Trattare come secret (Key Vault reference raccomandato). |
| `Graph__TenantId` | tenant corrente | Tenant per i token Graph |
| `Graph__ManagedIdentityClientId` | _(da bicep)_ | clientId della UAMI |

### Headers HTTP richiesti dal client

| Header | Esempio | Note |
|---|---|---|
| `x-functions-key` | `<function key>` | Auth livello Function |
| `Content-Type` | `application/json` | |
| `X-Request-Timestamp` | `2026-05-26T19:30:00.000Z` | ISO-8601 UTC, ±5 min |
| `X-Request-Nonce` | GUID | Dedupe in cache 10 min |

Inoltre la richiesta **deve** presentare un certificato client valido in TLS handshake (mTLS): `clientCertMode: Required` rigetta a livello platform le connessioni senza cert.

## Osservabilità & audit

Ogni operazione security-critical emette un **customEvent strutturato** in
Application Insights (tabella `customEvents`, sampling **disabilitato** sul
worker telemetry pipeline → `SamplingRatio = 1.0`, e `excludedTypes`
include `Event;Exception` in `host.json`). I traces classici (`ILogger`)
restano disponibili come mirror per i flussi locali.

Convenzione nomi: `wipe.<area>.<esito>` (vedi `src/Shared/Services/AuditEvents.cs`).
Ogni evento porta `correlationId`, `deviceName`, `entraDeviceId`,
`intuneDeviceId` e — quando applicabile — `certThumbprint`, `reason`,
`managedDeviceId`, `expectedRole`/`actualRole`.

Esempi KQL:

```kql
// Tutti gli eventi di audit nelle ultime 24h
customEvents
| where timestamp > ago(24h)
| where name startswith "wipe."
| project timestamp, name, correlationId = tostring(customDimensions.correlationId),
          device = tostring(customDimensions.deviceName),
          intune = tostring(customDimensions.intuneDeviceId),
          reason = tostring(customDimensions.reason)
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

> Eventi tipici: `wipe.request.accepted`, `wipe.denied.cert-validation`,
> `wipe.denied.cert-device-mismatch`, `wipe.denied.not-in-allowed-group`,
> `wipe.denied.ownership-mismatch`, `wipe.already-issued`,
> `wipe.graph.issued`, `wipe.graph.failed-permanent`,
> `wipe.graph.transient-error`. Lista completa in `Shared/Services/AuditEvents.cs`.

## Struttura del repository

```
.
├── azure.yaml                          # (opzionale) per azd
├── infra/
│   ├── main.bicep                      # 3 Function App + plan, 3 storage, 3 UAMI,
│   │                                   #   queue, App Configuration, AI, RBAC, runbook
│   └── main.parameters.json
├── src/                                # .NET 10 isolated — soluzione multi-progetto
│   ├── IntuneWipeApi.slnx
│   ├── Shared/                         # libreria condivisa (logica + servizi)
│   │   ├── HostBuilderExtensions.cs    # DI + App Configuration helpers
│   │   ├── Actions/                    # modello plug-in: registry, envelope, runner
│   │   │   ├── IActionRunner.cs
│   │   │   ├── ActionRunnerRegistry.cs
│   │   │   ├── ActionDispatch*.cs
│   │   │   └── Runners/                # WipeActionRunner, *ForwardingRunner
│   │   ├── Services/                   # ClientCertValidator, GraphWipeService,
│   │   │                               #   Idempotency, ReplayProtector, Audit*,
│   │   │                               #   WipeStatusTracker, DeviceDirectoryResolver
│   │   ├── Middleware/                 # AppConfigRefreshMiddleware
│   │   └── Models/
│   ├── Web/                            # App pubblica HTTP (mTLS)
│   │   └── Functions/                  # WipeRequest, WipeStatus, WipeLedgerAdmin
│   ├── Proc/                           # Dispatcher + router + status poller
│   │   └── Functions/                  # WipeProcessor, ActionDispatch, WipeStatusPoller
│   └── Wipe/                           # App privilegiata (esegue il wipe via Graph)
│       └── Functions/                  # WipeAction (consumer wipe-action)
├── runbooks/                           # variante Automation PowerShell 7.2
│   ├── Invoke-DeviceWipe.runbook.ps1
│   └── README.md
├── client/
│   ├── Invoke-DeviceWipe.ps1           # PS 5.1 client (entrypoint)
│   ├── DeviceIdentity.psm1             # modulo identità device (Pester-tested)
│   └── WipeConfirmationDialog.ps1      # WinForms dialog (shared module)
└── docs/
    ├── architecture.png
    ├── architectural-improvements.md   # review architetturale + roadmap
    ├── dialog-screenshot.png
    ├── Capture-DialogScreenshot.ps1    # rigenera lo screenshot del dialog
    └── Presentazione-Soluzione-Intune-Self-Wipe.eml
```

> **Nota sull'email di presentazione** (`docs/Presentazione-Soluzione-Intune-Self-Wipe.eml`):
> il file include `X-Unsent: 1` per aprirsi come bozza editabile in **Outlook classic**
> (campo "A:" modificabile, pulsante Invia attivo). Il nuovo Outlook e Outlook Web
> aprono i `.eml` in sola lettura: usare Outlook classic per modificare il destinatario
> prima dell'invio, oppure copiare il corpo HTML in una nuova mail.

## Roadmap

- [x] Validazione cert via `chain.Build()` con root CA pinning (`CustomTrustStore`)
- [x] Split web/worker + esecutore privilegiato dedicato (3 Function App isolate)
- [x] Modello plug-in `IActionRunner` (router + runner, variante runbook Automation)
- [x] Configurazione centralizzata via Azure App Configuration
- [x] Audit durabile dual-write (App Insights non-sampled + tabella `auditevents`)
- [x] Endpoint `GET /api/wipe/status` per consultare lo stato + poller di riconciliazione
- [ ] Notifica esito (Teams webhook / email) al termine del wipe
- [ ] Rimozione della Function Key dal client (mTLS-only dietro APIM/App Gateway)
- [ ] CA trust lifecycle via Key Vault references
- [ ] APIM/App Gateway WAF davanti alla Function con rate-limit per device
- [ ] Workflow GitHub Actions per CI/CD (con boundary checks post-deploy)

> Dettaglio completo delle proposte architetturali in
> [`docs/architectural-improvements.md`](docs/architectural-improvements.md).

## Licenza

[MIT](LICENSE) © Roberto Gramellini

---

> ⚠️ **Avviso.** Il wipe Intune è un'operazione **distruttiva e irreversibile**.
> Distribuisci questa soluzione solo dopo aver validato la propria CA SCEP,
> il gruppo Entra di allow-list e i meccanismi di approvazione/audit interni.
