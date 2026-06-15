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
```

**Cosa mostra**:
- Topologia Client → Web → SB action-requests → Proc → SB action-dispatch → SB *-action × 4 → capability apps → Graph.
- Ogni nodo colorato per stato (verde / giallo / rosso / grigio) basato su queue depth real-time.
- Particelle SVG che fluiscono lungo gli edge dove c'è traffico (active > 0 sulla coda destinazione).
- Pannello laterale: ledger totale, entries stuck (Issued + nessun terminale dopo grace), code, warnings.

**Limitazioni note**:
- Solo snapshot real-time (no trend storico). Per analisi temporale usare Grafana o App Insights direttamente.
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
