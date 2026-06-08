# IntuneDeviceActions — Gap di sicurezza ancora aperti

> **Scopo.** Documento sintetico dei controlli di sicurezza **non ancora
> implementati** sulla soluzione, con il riferimento normativo bancario di
> riferimento e il costo infrastrutturale stimato per chiuderli.
>
> **Cosa NON contiene questo documento.**
> - Effort di sviluppo (person-day) e phasing → `docs/security-remediation-roadmap.md`
> - Inventario dei controlli già implementati e mappatura completa ai framework
>   → `docs/security-compliance-banking.md` (Parte 1)
>
> **Punto di partenza.** Commit `e9622fd` (HIGH chiuso: mTLS admin + actor
> verificato). Gap residui = 10, tutti **non-exploitable in isolamento** ma
> richiesti per audit bancario pieno.

---

## Framework normativi citati

| Acronimo | Estensione |
|---|---|
| **PCI-DSS v4.0** | Payment Card Industry Data Security Standard |
| **ISO/IEC 27001:2022** | Information Security Management System |
| **NIST SP 800-53 r5** / **800-63B** | US Federal controls / Digital Identity |
| **EBA/GL/2019/04** | EBA Guidelines on ICT and security risk management (vincolante banche EU/EEA) |
| **DORA** (Reg. UE 2022/2554) | Digital Operational Resilience Act (vigente dal 17/01/2025) |
| **NIS2** (Dir. UE 2022/2555 — D.Lgs. 138/2024) | Network and Information Security 2 |
| **Banca d'Italia Circ. 285/2013** parte I tit. IV cap. 4 | Disposizioni vigilanza prudenziale — Sistema informativo |
| **GDPR** (Reg. UE 2016/679) | Tutela dati personali |
| **RFC 9421** | HTTP Message Signatures |
| **FIPS 140-2 / 140-3** | Standard moduli crittografici |

---

## Tabella riassuntiva

| # | Gap | Costo infra/mese | Categoria normativa |
|---|---|---|---|
| 1 | Anti-replay distribuito | ~zero (Azure Table) o ~$15 (Redis Basic) | EBA, NIST 800-63B |
| 2 | HTTP Message Signatures (body-bound nonce) | $0 | RFC 9421, EBA |
| 3 | Key Vault HSM-backed obbligatorio | ~$1 (KV Premium) **oppure** ~$2.500 (Managed HSM FIPS L3) | PCI-DSS, EBA, FIPS |
| 4a | Storage / App Config con Customer-Managed Keys | $0 incrementale (oltre al KV di #3) | EBA, DORA |
| 4b | Service Bus Premium + CMK | +$660 (Premium vs Standard) | EBA, DORA |
| 5a | Revocation check default-on | $0 | EBA, PCI-DSS |
| 5b | OCSP stapling all'edge (APIM / App Gateway) | +$700 (APIM Standard v2) o +$250 (App Gateway WAF v2 Small) | EBA |
| 6 | Audit log immutabili (WORM) 5-7 anni | +$2-5 (Storage immutable, ~$0,018/GB-mese) | PCI-DSS 10.5, ISO A.12.4.2, DORA |
| 7 | Retention log esplicita 365+ giorni | +$5-15 (Log Analytics oltre 31gg) | Banca d'Italia 285/13, DORA |
| 8 | Automation Account: disableLocalAuth + Hybrid Worker AAD | +$30 (VM B2s Hybrid Worker) | DORA, EBA |
| 9 | `TrustedCaCertificates` legacy → fail-deploy | $0 | ISO A.5.17, PCI-DSS 8.3.2 |
| 10 | Function host key separata per admin | $0 | PCI-DSS 7.1, ISO A.9.4 |

**Totale costo infra incrementale per scenario:**

| Scenario | Costo aggiuntivo/mese |
|---|---|
| **Baseline audit-pass** (gap #1, #5a, #7, #9, #10) | **+$20-30** |
| **Banking-grade "minimal"** (sopra + #3 KV Premium + #4a + #6) | **+$30-50** |
| **Banking-grade "full"** (tutto, FIPS L3 + APIM + SB Premium) | **+$2.500-3.000** |

---

## Dettaglio gap

### Gap #1 — Anti-replay non distribuito

| | |
|---|---|
| **Cosa manca** | `ReplayProtector` usa `IMemoryCache` per-istanza. Su Function EP1 multi-worker, due richieste con stessa tupla `(timestamp, nonce, body)` su istanze diverse non vengono entrambe rifiutate. Il ledger idempotency neutralizza il danno per azioni distruttive ma il **controllo anti-replay in sé** non è conforme. |
| **Normativa** | NIST SP 800-63B §5.2.8 · EBA/GL/2019/04 §3.4.3 |
| **Costo infra** | ~zero (Azure Table riusa storage esistente) · oppure ~$15/mese (Redis Cache Basic C0) |

### Gap #2 — Nonce non legato al body (HTTP Message Signatures)

| | |
|---|---|
| **Cosa manca** | `X-Request-Nonce` è solo un GUID — non un HMAC/firma di `body + timestamp + cert thumbprint`. Un MITM che ottiene una tupla valida può replayarla entro la finestra di skew. |
| **Normativa** | RFC 9421 HTTP Message Signatures · EBA/GL/2019/04 §3.4.3 |
| **Costo infra** | $0 (solo codice; richiede però aggiornamento client PowerShell — PS 5.1 ha API crypto limitate) |

### Gap #3 — Key Vault HSM-backed non obbligatorio

| | |
|---|---|
| **Cosa manca** | `Rename:AuthHeaderValue`, `RunbookBridge:Routes:*` e altri secret di control-plane sono stringhe in App Configuration. I commenti suggeriscono Key Vault reference ma il bicep non lo enforce e non c'è Managed HSM. Custody dei secret non FIPS 140-2/3. |
| **Normativa** | PCI-DSS v4.0 §3.5/3.7 · FIPS 140-2 (L2) / 140-3 (L3) · EBA/GL/2019/04 §3.4.5 |
| **Costo infra** | **FIPS 140-2 L2**: Key Vault Premium SKU ~$1/mese + ~$0,03 per 10k operazioni · **FIPS 140-3 L3**: Managed HSM ~$3,50/h ≈ **$2.520/mese** (3 HSM partitions in HA) |

### Gap #4a — Customer-Managed Keys (CMK) su Storage / App Config

| | |
|---|---|
| **Cosa manca** | Storage Account, Service Bus, App Configuration cifrati con chiavi Microsoft-managed. Nessuna separation of duties con Microsoft come custode crittografico. |
| **Normativa** | EBA/GL/2019/04 §3.4.5 · DORA art. 9 §4 lett. e |
| **Costo infra** | $0 incrementale (riusa il Key Vault di #3); richiede però documentazione rotation policy |

### Gap #4b — Service Bus Premium + CMK

| | |
|---|---|
| **Cosa manca** | Service Bus Standard non supporta CMK. Per allineamento full CMK serve passare a Premium. |
| **Normativa** | EBA/GL/2019/04 §3.4.5 · DORA art. 9 §4 lett. e |
| **Costo infra** | **+$660/mese fisso** (Premium ~$670 vs Standard ~$10 di throughput unit base). *Spesso accettato Microsoft-managed dagli audit EBA se Storage è CMK.* |

### Gap #5a — Revocation check off di default

| | |
|---|---|
| **Cosa manca** | `ClientCert:CheckRevocation=false` di default. Cert dispositivo revocato continua ad autenticare fino a scadenza CA. |
| **Normativa** | EBA/GL/2019/04 · PCI-DSS v4.0 App. A2 |
| **Costo infra** | $0 (solo cambio default) |

### Gap #5b — OCSP stapling all'edge

| | |
|---|---|
| **Cosa manca** | Nessun OCSP stapling davanti alla Function. Ogni client deve fare lookup OCSP indipendente (latenza + dipendenza CA esterna). |
| **Normativa** | EBA/GL/2019/04 |
| **Costo infra** | **APIM Standard v2**: ~$700/mese · **App Gateway WAF v2 Small**: ~$250/mese |

### Gap #6 — Audit log non tamper-resistant (WORM)

| | |
|---|---|
| **Cosa manca** | Audit Table scrivibile/cancellabile dalla stessa UAMI (`Table Data Contributor`). Nessuna policy WORM, nessun legal hold. Stesso principal può scrivere e cancellare. |
| **Normativa** | PCI-DSS v4.0 §10.5 · ISO 27001:2022 A.12.4.2 · DORA art. 12 |
| **Costo infra** | +$2-5/mese (Storage `immutableStorageWithVersioning` o export verso Log Analytics + Blob immutability, ~$0,018/GB-mese). Volume audit stimato: 1-5 GB/anno → trascurabile |

### Gap #7 — Retention log non specificata

| | |
|---|---|
| **Cosa manca** | Nessun `retentionInDays` esplicito su Log Analytics / Application Insights. Retention di default Microsoft (90gg) sotto i 5-7 anni richiesti dal settore bancario. |
| **Normativa** | Banca d'Italia Circ. 285/13 parte I tit. IV cap. 4 (conservazione log accessi privilegiati) · DORA art. 12 |
| **Costo infra** | +$5-15/mese (Log Analytics: gratis fino a 31gg, poi ~$0,12/GB-mese). Per 7 anni di storage freddo: export verso Blob immutable, ~$0,018/GB-mese |

### Gap #8 — Automation Account: `disableLocalAuth=false` + webhook bearer

| | |
|---|---|
| **Cosa manca** | Automation Account con `disableLocalAuth=false` e `publicNetworkAccess=true`; webhook URL = long-lived bearer secret. Chi conosce la URL esegue il runbook senza identity check. |
| **Normativa** | DORA art. 9 §3 lett. a · EBA/GL/2019/04 §3.4.4 |
| **Costo infra** | +$30/mese (VM B2s come Hybrid Runbook Worker su VNet con Private Endpoint). *Alternativa zero-cost: rimuovere la variante runbook in produzione, tenerla solo dev.* |

### Gap #9 — `TrustedCaCertificates` legacy auto-classifica come root

| | |
|---|---|
| **Cosa manca** | `ClientCertValidator` accetta nel parametro legacy `TrustedCaCertificates` cert self-signed promossi automaticamente a root. Un operatore distratto può promuovere un intermedio a trust anchor. |
| **Normativa** | ISO 27001:2022 A.5.17 · PCI-DSS v4.0 §8.3.2 |
| **Costo infra** | $0 (solo guard di deploy) |

### Gap #10 — Separation of duties function key

| | |
|---|---|
| **Cosa manca** | Stessa function host key per intake pubblico **e** endpoint admin (dopo `e9622fd` l'admin richiede comunque mTLS + thumbprint allow-list, ma la function key è ancora condivisa). Non c'è exploit path diretto — è una scelta sub-ottima per audit. |
| **Normativa** | PCI-DSS v4.0 §7.1 · ISO 27001:2022 A.9.4 |
| **Costo infra** | $0 (Azure Functions supporta multiple host keys nativamente) |

---

## Decisioni cliente bloccanti

Per dimensionare correttamente i gap #3, #4b, #7, #8 servono 4 decisioni
strategiche del cliente:

1. **FIPS level richiesto**: 140-2 L2 (Key Vault Premium, ~$1/mese) oppure
   140-3 L3 (Managed HSM, ~$2.500/mese)?
2. **Retention log**: 5, 7 o 10 anni? (impatta dimensionamento storage immutable)
3. **Runbook in produzione**: sì con Hybrid Worker (gap #8 da chiudere) o
   solo dev (gap #8 N/A in prod)?
4. **Service Bus CMK**: Premium (+$660/mese) o accettare Microsoft-managed
   con motivazione documentata in risk assessment?

---

## Costi una-tantum fuori scope tecnico

Non inclusi sopra (a carico cliente / vendor terzi):

| Voce | Costo orientativo |
|---|---|
| Penetration test esterno | $8.000-25.000 |
| PCI QSA assessment | $15.000-40.000 |
| Audit ISO 27001 (organismo certificazione) | $10.000-30.000 |
| DPIA GDPR (consulente privacy) | $3.000-8.000 |
| Formalizzazione procedure operative (BCM, IR plan, key management policy) | $5.000-15.000 |

---

## Riferimenti correlati

- `docs/security-compliance-banking.md` — controlli già implementati (Parte 1) e gap (Parte 2) con mappatura framework estesa.
- `docs/security-remediation-roadmap.md` — sizing effort (person-day) e phasing in 3 sprint.
- `docs/architectural-improvements.md` — miglioramenti architetturali generali (non security-specific).
