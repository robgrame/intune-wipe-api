# Analisi costi: variante `main.bicep` (VNet + PE) vs `main-public.bicep` (no-VNet)

Confronto del **TCO mensile a regime** delle due varianti di deployment
disponibili. I valori sono **stime indicative** basate sul listino Azure
**Italy North / West Europe** a giugno 2026 e su volume reale tipico per
un cliente medio (qualche centinaio di azioni/giorno, ~10k device sotto
governance). Per pricing autoritativo usa
[Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/).

---

## TL;DR

| Variante | Costo fisso mensile (idle) | Per 10k azioni/mese | Delta vs no-VNet |
|---|---|---|---|
| **`main-public.bicep`** (no-VNet) | **~€55 – €75** | **~€60 – €85** | baseline |
| **`main.bicep`** (VNet + 8 PE + 4 DNS) | **~€130 – €170** | **~€140 – €185** | **+€75 – €100 / mese** |

Il delta è composto quasi interamente da **private endpoint** (~€7.30
ognuno × 8 = ~€58) + **NAT Gateway** opzionale se aggiunto (~€32 fisso
+ €0.045/GB). Le private DNS zone sono trascurabili (~€0.50/zona/mese).

> **Quando il delta vale la spesa:** richiesti compliance/regolatori
> (NIS2, ISO 27001 nei pattern "no-public-endpoint"), perimetro tenant
> rigoroso con NSG/Firewall obbligatori. Per dev/test/POC e clienti senza
> requisito esplicito di rete privata: la variante public è equivalente
> in sicurezza applicativa (mTLS + Entra OAuth + Managed Identity +
> Private RBAC + `publicNetworkAccess=Enabled` con `networkAcls
> defaultAction=Allow` ma traffico autenticato).

---

## Risorse comuni a entrambe le varianti

Queste risorse sono presenti in **entrambi** i bicep e hanno costo
identico. Sono escluse dal delta.

| Risorsa | SKU | Costo mensile stimato |
|---|---|---|
| Service Bus Namespace | Standard | **€8 – €10** |
| App Configuration | Standard (1 store) | **€36** (€1.20/giorno) |
| Key Vault | Standard | **€0.027 / 10k ops** → ~€1 |
| Storage Account `stWeb` | StandardV2 LRS, hot | **€0.5 – €2** (consumo ridotto) |
| Storage Account `stProc` | StandardV2 LRS, hot | **€2 – €5** (audit + ledger + status) |
| Storage Account `stWipe` | StandardV2 LRS, hot | **€0.5 – €1** (solo deploy zip) |
| Storage Account `stAutopilot` | StandardV2 LRS, hot | **€0.5 – €1** |
| Storage Account `stBitLocker` | StandardV2 LRS, hot | **€0.5 – €1** |
| Function App `Web` (Flex Consumption) | Flex, EP1 always-ready 1 | **€18 – €25** baseline |
| Function App `Proc` (Flex Consumption) | Flex, on-demand | **€2 – €8** per 10k esec |
| Function App `Wipe` (Flex Consumption) | Flex, on-demand | **€1 – €5** per 10k esec |
| Function App `Autopilot` (Flex Consumption) | Flex, on-demand | **€0.5 – €3** per 10k esec |
| Function App `BitLocker` (Flex Consumption) | Flex, on-demand | **€0.5 – €3** per 10k esec |
| Automation Account (runbook variant) | Pay-as-you-go | **€0 – €1** (500 min/mese gratis, poi €0.002/min) |
| Log Analytics workspace | Pay-as-you-go, 30 GB free | **€0 – €5** (~€2.30/GB oltre la quota) |
| Application Insights | Connesso a LA, pricing LA | incluso sopra |
| 5× User-Assigned Managed Identity | – | **€0** |

**Totale risorse comuni a regime:** **~€55 – €75 / mese** (idle, escluse
le esecuzioni); **~€75 – €110 / mese** per 10k azioni/mese.

> Le Flex Consumption hanno un **always-ready** consigliato di 1 istanza
> sul Web (~€18 fisso) per evitare cold-start sull'endpoint pubblico mTLS;
> Proc/Wipe/Autopilot/BitLocker sono on-demand e fatturano solo per
> esecuzione (€0.000017/s vCPU-s + €0.000002/s GB-s).

---

## Componenti specifici di `main.bicep` (VNet variant)

Tutto quello che la variante **public NON ha**:

| Risorsa | Quantità | Costo unitario / mese | Costo totale / mese |
|---|---|---|---|
| Virtual Network | 1 | **€0** (VNet free) | €0 |
| Subnet con delegation Microsoft.App | 4 (`pe-subnet`, `wipe-flex-subnet`, `autopilot-flex-subnet`, `bitlocker-flex-subnet`) | €0 | €0 |
| **Private Endpoint** (storage subresource) | **8** | **~€7.30** (€0.01/h × 730h) | **~€58** |
| **Private DNS zone** | **4** (`blob`, `file`, `queue`, `table`.core.windows.net) | **~€0.50** (€0.50/zona/mese, gratis i primi 25 record DNS) | **~€2** |
| Private DNS zone VNet link | 4 | **€0** (incluso nel costo zona) | €0 |
| PE inbound/outbound data processing | – | **€0.01/GB** | **€0 – €2** (volumi minimi: token + ledger blob update + audit row, ~50–200 KB per azione) |
| (opz.) NAT Gateway per egress Flex | 0 (non incluso nel bicep, ma menzionato in alcuni pattern enterprise) | €32 + €0.045/GB | **non incluso** |
| (opz.) Azure Firewall / WAF | 0 | da €0.95/h + dati | **non incluso** |

> **Dettaglio sui 8 PE:** 4 per `stWeb` (blob/file/queue/table) + 3 per
> `stProc` (blob/table/queue) + 1 per `stWipe` (blob, solo per deploy zip).
> **Autopilot/BitLocker storage NON hanno PE** nel bicep attuale —
> restano public-access ma con `Idempotency:Container` montato altrove
> (su `stProc`). Se vuoi PE anche per quelle aggiungi 2 PE (~€15
> aggiuntivi).

**Totale specifico VNet:** **~€60 – €75 / mese**, prevalentemente PE.

---

## Confronto sintetico

```
                  ┌──────────────────┬──────────────────┐
                  │  main-public     │  main (VNet)     │
                  ├──────────────────┼──────────────────┤
 Idle (no exec)   │  ~€55 – €75      │  ~€130 – €170    │
 10k azioni/mese  │  ~€60 – €85      │  ~€140 – €185    │
 100k azioni/mese │  ~€90 – €150     │  ~€170 – €260    │
                  └──────────────────┴──────────────────┘

Delta fisso ~ €75 – €100/mese (98% PE, 2% DNS).
Delta variabile ~ trascurabile (€0.01/GB PE traffic; le azioni
sono token-based + small payload).
```

---

## Componenti del costo di esecuzione (entrambe le varianti)

Per 1 azione end-to-end (es. 1 wipe):

| Step | Risorsa | Costo |
|---|---|---|
| 1 POST mTLS al Web | Web Function (200ms execution) | ~€0.000003 |
| 1 enqueue `action-requests` | Service Bus | ~€0.000005 |
| RequestIntake (300ms) | Proc Function | ~€0.000004 |
| 1 enqueue `action-dispatch` | Service Bus | ~€0.000005 |
| Dispatch (200ms) | Proc Function | ~€0.000003 |
| 1 enqueue `wipe-action` | Service Bus | ~€0.000005 |
| Wipe runner (1.5s + Graph call) | Wipe Function | ~€0.00003 |
| 3 row audit table | Storage Table | ~€0.000001 |
| 1 ledger blob PUT | Storage Blob | ~€0.000001 |
| 1 status row Table | Storage Table | ~€0.0000005 |
| 1 Graph call (token incluso) | Entra/Graph | **€0** |
| **Totale per azione** | – | **~€0.00006** |

→ 10k azioni costano **~€0.60** (negligibile contro il costo fisso).

I costi variabili dominanti sono **Application Insights/Log Analytics
ingestion** (se non si imposta sampling) e **Service Bus operations** sui
volumi alti (Standard ha 12.5M ops/mese inclusi nel canone, oltre €0.05/M).

---

## Variante runbook (sostituisce o affianca le Function di capability)

| Scenario | Costo aggiuntivo / mese |
|---|---|
| AA esistente (già nel bicep), 0–500 min job/mese | **€0** (quota gratuita) |
| 1000 min job/mese (~ 8h, ~50 azioni/giorno con job ~15s) | **~€1** |
| 10 000 min job/mese | **~€19** (€0.002/min oltre la quota) |

> **Nota:** runbook **non sostituiscono** completamente le Function
> nelle 2 varianti bicep — sono offerti come **alternativa attivabile**
> via `RunbookBridge:Routes:*`. Se sostituisci una Function App con un
> runbook puoi **risparmiare €2–€8/mese** sulla Flex on-demand di quella
> capability. Se le tieni entrambe pronte (uno usato, l'altro warm),
> il costo aggiuntivo dell'AA è trascurabile (~€0).

---

## Raccomandazioni

| Profilo cliente | Variante consigliata |
|---|---|
| **Dev/test/POC** | `main-public.bicep` — risparmio €75–€100/mese, security applicativa identica. |
| **PMI senza requisito di rete privata** | `main-public.bicep` — mTLS + Entra + RBAC sono sufficienti per la maggior parte degli use-case Intune. |
| **Enterprise con policy "no-public-endpoint" / NIS2 / ISO 27001** | `main.bicep` — i €75–€100/mese extra sono accettabili e richiesti dalla compliance. |
| **Government / Banking (dati regolamentati)** | `main.bicep` **+** estensioni: PE anche su SB / App Config / Key Vault (oggi non incluso, +€30/mese), Azure Firewall in hub (+€1500/mese). |

### Ottimizzazioni applicabili a entrambe

- **Service Bus**: passa a **Basic** (€0.05/M ops) invece di Standard se
  non usi topic/subscriptions e mantieni < 1M ops/mese → risparmio €8/mese.
- **Application Insights**: imposta **adaptive sampling** (default 5
  items/sec) per evitare blow-up su LA ingestion. Su 100k azioni/mese
  può risparmiare €30–€80.
- **Flex always-ready Web**: se la latenza cold-start (~1–2s) è
  tollerabile, porta `alwaysReady=0` → risparmio ~€18/mese (perde però
  responsiveness sull'endpoint pubblico).
- **Log Analytics retention**: default 30 giorni gratis; non aumentare
  oltre se il sink Storage Table `auditevents` è la fonte canonica per
  retention pluriennale (lo è — vedi [`capabilities-autopilot-bitlocker.md`](./capabilities-autopilot-bitlocker.md)).

### Ottimizzazioni applicabili solo a `main.bicep`

- **PE consolidamento**: se accetti che `stWipe` deploy-only resti
  pubblico (è in container `app-package-wipe` con `publicNetworkAccess`
  e RBAC stretto), elimina i suoi PE → risparmio ~€7/mese.
- **NON aggiungere PE su Autopilot/BitLocker storage** se sono solo
  deploy-zip backing (già il default).
- **Disabilita private DNS zone non usate**: se non monti `file`
  subresource (true se rimuovi `WEBSITE_CONTENTSHARE` da Flex), elimina
  la zona `privatelink.file.core.windows.net` → risparmio €0.50/mese
  (cosmetico).

---

## Costo nascosto: troubleshooting della VNet

Spesso dimenticato: la variante `main.bicep` introduce **vettori di
failure non presenti** nella variante public:

| Failure mode tipico | Causa | Impatto |
|---|---|---|
| `403 AuthorizationFailure` da Flex su `AzureWebJobsStorage` | `networkAcls.defaultAction=Deny` su storage anche con `bypass=AzureServices` | Function host unhealthy, requiere PATCH a `defaultAction=Allow` o PE + VNet integration |
| `Microsoft.App` provider not registered | Subnet delegation Flex richiede il provider anche se l'app è `Microsoft.Web/sites` | Deploy bicep fail; risolvi con `az provider register --namespace Microsoft.App` |
| Cold-start lento dopo idle | VNet integration aggiunge ~300–800ms al cold-start Flex | Latenza percepita peggiore |
| DNS resolution failure post-deploy | Private DNS zone link timing race | Function host non risolve `*.core.windows.net` per ~5 min |
| Ledger PUT 403 | RBAC su container vs account scope confusion | Audit/ledger non scrivibili, azioni non issued |

Aggiungi **20–40 ore one-shot** di troubleshooting per il primo deploy
VNet (~€2k–€5k a tariffe consulenza). Il costo ricorrente di operations
è ~+10–20% per la variante VNet (più allarmi sui PE, NSG audit,
configurazioni DNS).

---

## Conclusione

| Domanda | Risposta |
|---|---|
| La variante VNet aggiunge sicurezza applicativa? | **No.** mTLS + Entra OAuth + Managed Identity + RBAC sono presenti in entrambe. La VNet aggiunge **isolamento di rete** (i token e i ledger transitano su backbone Microsoft invece che su Internet), utile per compliance ma non per security model. |
| Il costo è giustificato? | **Solo** se hai un requisito regolatorio o di policy interna esplicita. Altrimenti: variante public. |
| Posso migrare dopo? | **Sì**, ma richiede ridreploy con state migration manuale del ledger blob + audit table (copy con `azcopy`). Bicep deployment failure model è ricreativo (deployment failures dipendono dal provider registration; vedi nota su `Microsoft.AlertsManagement` in memory). |
| Runbook variant cambia l'equazione? | Marginalmente. Aggiunge ~€0–€20/mese a seconda dei minuti job. Vale come **demo del modello plug-in cross-runtime** più che come ottimizzazione costi. |

> **Numeri ufficiali sempre validare** con Azure Pricing Calculator
> aggiornato e il piano EA/CSP del cliente — possono esserci sconti
> volume del 10–25% non riflessi nel listino pubblico.
