# How-to: aggiungere una nuova capability con una Azure Function

Guida passo-passo per implementare una **nuova capability** (es. `restart-device`,
`collect-logs`, `defender-scan`, …) usando una **nuova Azure Function App
dedicata** con il pattern `IActionRunner` plug-in.

> **Quando preferirla:** latenza bassa (1–3 s cold-start Flex Consumption),
> volume alto o burst, telemetria App Insights ricca, esecuzione parallela
> su scala (Flex scala orizzontalmente). Per ops PowerShell-centric o volumi
> bassi vedi [`howto-new-capability-runbook.md`](./howto-new-capability-runbook.md).

---

## Prerequisiti

- L'infrastruttura core è già deployata (`infra/main.bicep` o `main-public.bicep`).
- Familiarità con .NET 10 + Azure Functions isolated worker.
- I tool sono installati: `dotnet 10`, `func` core tools v4, `az` CLI, `bicep`.
- Accesso owner/contributor sul resource group + permessi per concedere
  ruoli Graph alla nuova UAMI (vedi Step 7).

---

## Panoramica del flusso (cosa farà la nuova capability)

```
Client mTLS POST /api/v2/actions { "type": "<newcap>", ... }
       ↓
ActionRequestFunction (Web) → coda `action-requests`
       ↓
RequestIntakeFunction (Proc) → coda `action-dispatch`
       ↓
ActionDispatchFunction (Proc, router) risolve type=<newcap>
       ↓                              ↑ tramite Forwarders:<newcap>:Queue
                                      configurato in App Config
ForwardActionFunction (Proc) → coda `<newcap>-action`
       ↓
<NewCap>ActionFunction (NewCap Function App) consuma con UAMI dedicata
       ↓
<NewCap>ActionRunner : IActionRunner
       ↓
ActionIdempotencyService (ledger) + GraphServiceClient + ActionStatusTracker + AuditTableSink
```

**Il core (Web, Proc) non cambia.** L'aggiunta consiste in:
1. Un nuovo progetto C# `Capabilities.<NewCap>` (logica) +
   `<NewCap>` Function App (host).
2. Una nuova coda Service Bus `<newcap>-action`.
3. Una nuova UAMI con Graph role-assignments isolati.
4. Una nuova storage account dedicata (host) — pattern isolation come
   `Wipe` / `Autopilot` / `BitLocker`.
5. Forwarding rule in App Config + allow-list aggiornata.

---

## Step 1 — Creare i 2 progetti C#

### `src/Capabilities.<NewCap>/` (libreria con la logica)

```pwsh
cd src
dotnet new classlib -n Capabilities.<NewCap> -f net10.0
dotnet sln IntuneDeviceActions.slnx add Capabilities.<NewCap>/Capabilities.<NewCap>.csproj
```

Aggiungi reference a `Shared`:

```xml
<ItemGroup>
  <ProjectReference Include="..\Shared\Shared.csproj" />
</ItemGroup>
```

Crea i file (modello consigliato — ricalca `Capabilities.BitLocker/`):

```
Capabilities.<NewCap>/
├── Audit/<NewCap>AuditEvents.cs              ← costanti event names
├── Models/<NewCap>RequestExtras.cs           ← (opz.) payload extra dal client
├── Services/Graph<NewCap>Service.cs          ← chiamata Graph + Classify
├── Runners/<NewCap>ActionRunner.cs           ← implementa IActionRunner
├── Probes/<NewCap>ActionStatusProbe.cs       ← (opz.) status polling
└── DependencyInjection/<NewCap>ServiceCollectionExtensions.cs
```

**Pattern `<NewCap>ActionRunner`** — copia lo skeleton da
`src/Capabilities.BitLocker/Runners/BitLockerRotateRunner.cs` (~285 LOC).
Le 5 fasi sono già implementate; sostituisci solo:
- `BitLockerAuditEvents.*` → `<NewCap>AuditEvents.*`
- chiamata Graph specifica (in `GraphBitLockerService` → `Graph<NewCap>Service`)
- `Type => "bitlocker-rotate"` → `Type => "<newcap>"`

Le seguenti capability sono **opzionali** — omettile se non applicabili:
- Device resolve via `IDeviceResolver` (richiesto solo se serve l'Entra device id)
- Group membership via `IGroupMembershipChecker`
- Ownership check via `IManagedDeviceResolver`
- Post-action nudges (solo wipe ne ha bisogno)

Lo `AutopilotRegisterRunner` è il riferimento per capability che **non**
fanno device-resolve/group/ownership (perché agiscono su hardware non
ancora hybrid-joined).

### `src/<NewCap>/` (Function App host)

```pwsh
cd src
dotnet new worker -n <NewCap> -f net10.0   # → poi convertito in Functions worker
```

Più semplice: **copia in blocco** `src/BitLocker/` (Function App host)
e rinomina:
- `IntuneDeviceActions.BitLocker.csproj` → `IntuneDeviceActions.<NewCap>.csproj`
- Namespace `IntuneDeviceActions.BitLocker` → `IntuneDeviceActions.<NewCap>`
- `BitLockerActionFunction.cs` → `<NewCap>ActionFunction.cs`
  - Cambia `[ServiceBusTrigger("%Queues:BitLockerAction%")]` →
    `[ServiceBusTrigger("%Queues:<NewCap>Action%")]`
- `host.json` invariato.
- `Program.cs` — sostituisci `services.AddBitLockerCapability(...)` con
  `services.Add<NewCap>Capability(...)`.

Add al sln:

```pwsh
dotnet sln IntuneDeviceActions.slnx add src/<NewCap>/IntuneDeviceActions.<NewCap>.csproj
```

### Test project (consigliato)

```pwsh
cd src
dotnet new xunit -n Capabilities.<NewCap>.Tests -f net10.0
dotnet sln IntuneDeviceActions.slnx add Capabilities.<NewCap>.Tests/Capabilities.<NewCap>.Tests.csproj
```

Ricalca `src/Capabilities.BitLocker.Tests/` — gli stub per
`IDeviceResolver`, `IActionIdempotencyService`, `IActionStatusTracker`,
`IAuditTableSink` sono tutti riusabili da `Shared.Tests`.

---

## Step 2 — Registrare il runner nel router

Apri `src/Proc/Program.cs` e aggiungi il forwarder per il nuovo type
**solo se non usi già il pattern generico** (controlla
`ForwarderRegistrationExtensions` — di solito i forwarders sono
auto-registrati leggendo `Forwarders:*:Queue` da App Config, quindi
**non serve scrivere codice**).

In `src/Proc/Program.cs` cerca la sezione dei runner registration; se
i runner sono auto-discovered, il dispatcher prende automaticamente il
nuovo runner via DI. Altrimenti aggiungi:

```csharp
services.Add<NewCap>Capability(ctx.Configuration);
```

> Il `ActionDispatchFunction` router fa lookup
> `IEnumerable<IActionRunner>` e seleziona quello che matcha `runner.Type
> == message.ActionType`. Basta che la DI extension registri il runner;
> non c'è registro statico da modificare.

---

## Step 3 — Aggiungere la coda Service Bus al Bicep

Apri `infra/main.bicep` e cerca `sbQueueBitLockerAction` (intorno alla
riga 382). Aggiungi una risorsa identica:

```bicep
param newcapActionQueueName string = '<newcap>-action'

resource sbQueueNewCapAction 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sbNamespace
  name:   newcapActionQueueName
  properties: {
    lockDuration:                       'PT5M'
    maxDeliveryCount:                   10
    enablePartitioning:                 false
    requiresDuplicateDetection:         false
    deadLetteringOnMessageExpiration:   true
    defaultMessageTimeToLive:           'P14D'
  }
}
```

Replica in `infra/main-public.bicep`.

---

## Step 4 — Aggiungere la UAMI dedicata al Bicep

Cerca `uamiBitLocker` (riga ~1486 di main.bicep) e aggiungi:

```bicep
var uamiNewCapName = toLower('${namePrefix}-uami-<newcap>-${suffix}')

resource uamiNewCap 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiNewCapName
  location: location
}
```

Output (utile per `Grant-GraphPermissions.ps1`):

```bicep
output uamiNewCapClientId string = uamiNewCap.properties.clientId
output uamiNewCapPrincipalId string = uamiNewCap.properties.principalId
```

---

## Step 5 — Aggiungere la storage account e Function App host

Copia il blocco `storageBitLocker` + `bitlockerDeployBlobContainer` +
`bitlockerFunctionApp` (sezione bicep intorno alle righe 1449–1750) e
rinomina con `newcap`. I parametri da aggiornare:

- `AzureWebJobsStorage__accountName = storageNewCap.name`
- App Settings:
  - `Queues__<NewCap>Action     = newcapActionQueueName`
  - `ServiceBus__FullyQualifiedNamespace = sbNamespace.properties.serviceBusEndpoint`
  - `Graph__ClientId          = uamiNewCap.properties.clientId`
  - `Graph__TenantId          = tenant().tenantId`
  - `Actions__AllowedTypes`, `Wipe__AllowedGroupId`, `ActionStatus__*`,
    `Audit__*`, `Idempotency__*` — riusa gli stessi valori delle altre
    Function App di capability.
- `userAssignedIdentities` include sia `uami` (per ServiceBus/AppConfig/Storage)
  sia `uamiNewCap` (per Graph).

VNet integration (solo `main.bicep`):
- aggiungi il subnet delegation: `<newcap>FlexSubnet` con delegation
  `Microsoft.App/environments` (copia `wipeFlexSubnet`).
- riusa lo stesso `azureFunctions` host VNet routing pattern delle altre.

Role assignments (necessari):

```bicep
// Service Bus Data Receiver sulla queue specifica
resource raSbNewCapAction 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbQueueNewCapAction.id, uamiNewCap.id, 'receiver')
  scope: sbQueueNewCapAction
  properties: {
    principalId: uamiNewCap.properties.principalId
    roleDefinitionId: sbDataReceiver
    principalType: 'ServicePrincipal'
  }
}

// Storage Blob Data Contributor sul container ledger (condiviso)
resource raLedgerNewCap 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ledgerContainer.id, uamiNewCap.id, 'ledger')
  scope: ledgerContainer
  properties: {
    principalId: uamiNewCap.properties.principalId
    roleDefinitionId: storageBlobDataContributor
    principalType: 'ServicePrincipal'
  }
}

// Storage Table Data Contributor su storageProc (per audit + status)
resource raTableNewCap 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageProc.id, uamiNewCap.id, 'table')
  scope: storageProc
  properties: {
    principalId: uamiNewCap.properties.principalId
    roleDefinitionId: storageTableDataContributor
    principalType: 'ServicePrincipal'
  }
}
```

`uami` (dispatcher) deve poter **inviare** sulla nuova coda:

```bicep
resource raSbNewCapSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbQueueNewCapAction.id, uami.id, 'sender')
  scope: sbQueueNewCapAction
  properties: {
    principalId: uami.properties.principalId
    roleDefinitionId: sbDataSender
    principalType: 'ServicePrincipal'
  }
}
```

Replica tutto in `main-public.bicep`.

Build di verifica:

```pwsh
az bicep build --file infra/main.bicep
az bicep build --file infra/main-public.bicep
```

---

## Step 6 — Aggiornare lo script di deploy

`tools/Deploy-IntuneDeviceActions.ps1` ha una lista esplicita delle
Function App da pubblicare (zip-deploy). Aggiungi il nuovo progetto
nello switch `$Projects` (cerca `'wipe'`, `'autopilot'`, `'bitlocker'`):

```pwsh
@{ Name='newcap';     Path='src\<NewCap>';     PublishProfile='Release' }
```

Lo step rebuild + zip + deploy automaticamente.

---

## Step 7 — Concedere i ruoli Graph alla nuova UAMI

Modifica `tools/Grant-GraphPermissions.ps1`: aggiungi una sezione per
la nuova UAMI (ricalca quella esistente per `uami-bitlocker`):

```pwsh
$newcapUamiPrincipalId = az identity show -n <uamiNewCapName> -g <rg> --query principalId -o tsv
Grant-GraphAppRoles -PrincipalId $newcapUamiPrincipalId -Roles @(
    'DeviceManagementManagedDevices.PrivilegedOperations.All',
    'DeviceManagementManagedDevices.Read.All',
    'Device.Read.All',
    'GroupMember.Read.All'
    # eventuali altri ruoli specifici della tua capability
)
```

Esegui dopo il deploy bicep:

```pwsh
.\tools\Grant-GraphPermissions.ps1 -ResourceGroup <rg>
```

> **Permessi necessari:** *Privileged Role Administrator* + *Application
> Administrator* (oppure *Global Administrator*).

---

## Step 8 — Deploy

```pwsh
.\tools\Deploy-IntuneDeviceActions.ps1 -ResourceGroup <rg>
```

Sequenza eseguita:
1. `az bicep deployment` → crea coda, UAMI, storage, Function App.
2. `dotnet publish` + `zip` di tutti i progetti incluso il nuovo.
3. `func azure functionapp publish` o `az functionapp deployment` per ciascuna App.

---

## Step 9 — Allow-listare il tipo + forwarding rule

In App Configuration:

```pwsh
# 1. allow-list per il client
az appconfig kv set --name <appCfgName> `
    --key 'Actions:AllowedTypes' `
    --value 'wipe,autopilot-register,bitlocker-rotate,<newcap>'

# 2. forwarding rule: dispatcher invia alla nuova coda
az appconfig kv set --name <appCfgName> `
    --key 'Forwarders:<newcap>:Queue' `
    --value '<newcap>-action'
```

Restart dell'app `idactions-proc` (o aspetta il prossimo cold-start Flex).

---

## Step 10 — Aggiungere lo script client

Crea `client/Invoke-<NewCap>.ps1` ricalcato su
`client/Invoke-BitLockerKeyRotation.ps1`:

```pwsh
.\Invoke-<NewCap>.ps1 -ApiBaseUrl 'https://<webApp>/api/v2/actions' `
                     -ClientCertThumbprint '<thumb>'
```

Il client costruisce il payload `ActionRequest` con `type=<newcap>` e
campi `extras` opzionali che vengono deserializzati lato server in
`<NewCap>RequestExtras` (tramite la bag opaca `ActionRequest.Extras`).

---

## Step 11 — Test e verifica

```pwsh
.\client\Invoke-<NewCap>.ps1 ...
```

Controlla:
- Application Insights → `customEvents` con `Name="<newcap>.graph.issued"`.
- Storage table `auditevents` (sulla storageProc) — row con
  `PartitionKey=<correlationId>` e RowKey timestamp.
- Storage blob `action-ledger` → `<intuneDeviceId>.json` con
  `State=Issued`.
- Storage table `actionstatus` → row `correlationId/status` con
  `Terminal=false LastState=pending`.
- Service Bus queue `<newcap>-action` → 0 messaggi pending dopo qualche
  secondo (consumato).

KQL utili (Log Analytics):

```kusto
AppEvents | where Name startswith "<newcap>." | top 50 by TimeGenerated desc

// errori permanent
AppExceptions
| where TimeGenerated > ago(1h)
| where ProblemId contains "<NewCap>"
```

---

## Riepilogo file toccati per una nuova capability Function

| File | Modifica |
|---|---|
| `src/Capabilities.<NewCap>/*` | **NUOVO** — libreria runner + Graph service + audit events |
| `src/<NewCap>/*` | **NUOVO** — Function App host (copia da BitLocker) |
| `src/Capabilities.<NewCap>.Tests/*` | **NUOVO** — unit tests (consigliato) |
| `IntuneDeviceActions.slnx` | 3 progetti aggiunti |
| `infra/main.bicep` + `main-public.bicep` | coda SB, UAMI, storage, Function App, RBAC, (PE+subnet solo main.bicep) |
| `tools/Deploy-IntuneDeviceActions.ps1` | 1 entry nella lista `$Projects` |
| `tools/Grant-GraphPermissions.ps1` | 1 blocco per la nuova UAMI |
| App Configuration | `Actions:AllowedTypes` + `Forwarders:<newcap>:Queue` |
| `client/Invoke-<NewCap>.ps1` | **NUOVO** — script client |

**Zero modifiche** a: `Web`, `Proc/RequestIntakeFunction`,
`Proc/ActionDispatchFunction`, contratto `ActionDispatchMessage`,
schemi audit/ledger/status, RBAC core di Web/Proc, Function App di altre
capability.

---

## Estensioni opzionali

- **Status probe attivo**: implementa `IActionStatusProbe<TState>` (vedi
  `AutopilotActionStatusProbe`) e registra un timer trigger che chiama
  Graph periodicamente per aggiornare `actionstatus.LastState`.
- **Post-action nudges**: replica il pattern `WipeActionRunner` (sync +
  reboot dopo l'azione, con retry bounded e 404=success).
- **Confronto con runbook**: se vuoi offrire al cliente **entrambe** le
  varianti per la stessa capability, segui [la guida runbook](./howto-new-capability-runbook.md)
  con `type=<newcap>-runbook` (NON `<newcap>`, per evitare doppia
  esecuzione — il ledger è single-writer per device).
