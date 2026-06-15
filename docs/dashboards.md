# Operator Dashboards (cruscotto)

Due implementazioni dello stesso "cruscotto Prius" (flusso messaggi della
pipeline IntuneDeviceActions). Coesistono temporaneamente — useremo l'uso
reale per scegliere quale tenere.

| Opzione | Cosa | Pro | Contro |
|---|---|---|---|
| **2 — Grafana** | `infra/dashboard-grafana.bicep` + `infra/grafana/intunedeviceactions-dashboard.json` | Resource-graph maturo, alert nativi, time-series naturale, condivisibile via URL pubblico | Risorsa Azure separata (~$10/mo SKU Essentials), Bicep + import manuale del JSON, niente "frecce animate" |
| **3 — Web SVG** | `src/Web/Dashboard/dashboard.html` + `DashboardFunction.cs` + `DashboardTelemetryService.cs` | Zero infra extra (sta dentro Web), SVG animato vero stile Prius, riusa mTLS+function key+cert allow-list, real-time SB admin | Vista singola (no esplorazione storica), nuovo codice da mantenere, accesso solo da browser con cert client |

## Opzione 3 — HTML+SVG sul Web Function App

**Endpoint**: `GET https://idactions-web-<suffix>.azurewebsites.net/api/dashboard?code=<FunctionKey>` (richiede anche cert mTLS).

**Configurazione App Config**:
```
Dashboard:Enabled                    = true
Dashboard:AllowedCertThumbprints     = <thumb1>,<thumb2>   # opzionale; fallback ad Idempotency:AdminCertThumbprints
Dashboard:LogsWorkspaceId            = <LAW customerId GUID>  # richiesto per trace/timeline (v2)
Idempotency:AdminApiEnabled          = true                  # richiesto per il bottone "Reset ledger"
```

**RBAC richiesto sulla Web UAMI**:
- `Monitoring Reader` sul namespace Service Bus (overview code).
- `Storage Blob Data Reader` (o superiore) sullo storage `idactionsstpdev` container `action-ledger`.
- `Log Analytics Reader` sul workspace dietro App Insights `idactions-ai-dev` (v2 trace/timeline).
  - Trovalo con: `az monitor app-insights component show -g RG-INTUNE-DEVICEACTIONS -n idactions-ai-dev --query workspaceResourceId`
  - Poi: `az monitor log-analytics workspace show --ids <ws-id> --query customerId` → quello è il valore di `Dashboard:LogsWorkspaceId`.

**Cosa mostra (v2 troubleshooting end-to-end)**:
- **Panoramica**: topologia Client → Web → SB action-requests → Proc → SB action-dispatch → SB *-action × 4 → capability apps → Graph, con nodi colorati per stato (verde/giallo/rosso/grigio) basato su queue depth real-time e particelle SVG che fluiscono dove c'è traffico.
- **Search bar globale**: incolla un `correlationId` GUID, un `intuneDeviceId` GUID, oppure il hostname (es. `FC1DSK005`) → in un click vedi cosa è successo.
- **Trace timeline per correlationId**: timeline verticale evento-per-evento dell'intera pipeline (Web `accepted`, Proc `received/forwarded`, capability `consumed/completed/failed`, ledger `already-issued/rearmed`). Colorata per severità e con badge del role che ha emesso l'evento.
- **Recommendation engine**: dato l'ultimo evento, il cruscotto suggerisce in italiano cosa fare. Tre azioni 1-click:
  - 🔧 **Reset ledger e riprova** — quando il ledger ha marcato `Issued` senza terminale (caso FC1DSK005 del 11/06): bottone che richiama `POST /api/dashboard/actions/reset-ledger`, archivia l'entry corrente sotto `_archive/` e libera il device per una nuova richiesta. Richiede prompt per il `reason` (auditato).
  - 🔍 **Apri in App Insights** — quando serve la stack trace completa di un'exception runtime.
  - 🌐 **Apri portale Azure** — quando serve l'ispezione di un componente upstream (es. coda DLQ).
- **Diagnostica componenti**: ultimo tick del poller, freschezza delle ultime invocazioni per ciascuna capability app, problemi rilevati (es. KQL non configurato).
- **Ledger bloccate (azioni rapide)**: top entry stuck con bottone Reset diretto in panoramica.
- **Storico device**: cerca per hostname → vedi le ultime N richieste con timestamp + ultimo evento, cliccando vai al trace.

**Limitazioni note**:
- Snapshot panoramica è real-time, ma trace si basa su App Insights → ritardo ~30s-2min per ingestion.
- Funzioni *DashboardFunction* non sono cacheable: ogni `GET /api/dashboard/data` fa fan-out SB admin + enumeration ledger. Su un RG con migliaia di entry di ledger, considerare paginazione/caching.
- Auth identica al resto del Web (mTLS + function key); accesso da browser richiede certificato client installato.

## Opzione 2 — Azure Managed Grafana

**Deploy** (one-off, non incluso in `main.bicep`):

```powershell
az deployment group create -g RG-INTUNE-DEVICEACTIONS `
  -f infra/dashboard-grafana.bicep `
  -p suffix=dev `
     operatorObjectId=(az ad signed-in-user show --query id -o tsv) `
     sbNamespaceName=idactions-sb-dev `
     appInsightsName=idactions-ai-dev `
     ledgerStorageAccountName=idactionsstpdev
```

**Post-deploy**:
1. Apri l'`grafanaEndpoint` di output con il tuo account Entra ID.
2. **Connections → Data sources → Add data source**:
   - **Azure Monitor** (auto-discovery via Managed Identity) → usalo sia per metriche Azure Monitor sia per Log Analytics su App Insights workspace.
3. **Dashboards → Import → Upload JSON**: carica `infra/grafana/intunedeviceactions-dashboard.json`.
4. Quando richiesto, mappa `${DS_AZURE}` e `${DS_AI}` sul data source Azure Monitor appena aggiunto.
5. Imposta le variabili dashboard `sb_namespace` (es. `idactions-sb-dev`) e `sb_resource_id` (full ARM ID — `az servicebus namespace show -g RG-INTUNE-DEVICEACTIONS -n idactions-sb-dev --query id -o tsv`).

**Pannelli inclusi**:
- SB ActiveMessages per coda (timeseries, soglia giallo/rosso)
- SB DeadletteredMessages per coda (timeseries, soglia rosso > 0)
- Capability runner invocations 15m (stat per role)
- Tabella `action.already-issued` 24h (la causa-radice del wipe bloccato di FC1DSK005 sarebbe stata visibile qui in tempo reale)
- Web intake success/failure
- Graph dep p95 + failure rate

## Cosa manca rispetto al brief originale

| Componente | Implementato in Web SVG | Implementato in Grafana | TODO |
|---|---|---|---|
| Code SB depth | ✅ real-time | ✅ timeseries | — |
| DLQ | ✅ | ✅ | — |
| Function App health | derivato da SB | KQL su `requests` | ARM `siteState` come fonte alternativa |
| Capability throughput | metric per coda destinazione | ✅ KQL `requests` | — |
| Ledger health | ✅ enumeration + stuck detector | ✅ proxy via `action.already-issued` | panel diretto su blob storage (richiede Function proxy) |
| Status poller heartbeat | ❌ | ❌ | aggiungere un trace `poller.tick` e KQL su `traces` |
| Runbook AA jobs | ❌ | ❌ | abilitare diagnostic settings → Log Analytics, poi KQL `AzureDiagnostics` |
| Storage `publicNetworkAccess` drift | ❌ | ❌ | ARG query (Workbook only) o alert dedicato |

Le caselle "TODO" non sono bloccanti — la fase 1 indirizza il sintomo principale che ha fatto perdere ore (ledger stuck silenziosamente).
