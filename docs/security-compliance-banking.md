# IntuneDeviceActions — Funzionalità di sicurezza e mappatura normativa bancaria

> **Scopo del documento.** Inventario sintetico dei controlli di sicurezza
> implementati nella soluzione `IntuneDeviceActions`, con riferimento puntuale
> al codice/IaC e mappatura ai framework di compliance rilevanti per il settore
> finanziario europeo. Il documento è suddiviso in due parti:
>
> 1. **Funzionalità implementate** — controlli oggi presenti e verificabili
>    nel codice (commit `e9622fd` o successivo).
> 2. **Gap residui banking-grade** — controlli non implementati / parzialmente
>    coperti, da indirizzare prima di un go-live regolato.
>
> Il documento **non è** un'attestazione di conformità: è un input per la
> gap-analysis che il team Risk/Compliance del cliente dovrà condurre con i
> propri assessor (interni, audit Banca d'Italia, organismo di certificazione
> ISO, PCI QSA, ecc.).

---

## Framework normativi di riferimento

| Acronimo | Estensione | Ambito |
|---|---|---|
| **PCI-DSS v4.0** | Payment Card Industry Data Security Standard | Obbligatorio per chi gestisce dati PAN; spesso adottato anche fuori scope come baseline tecnica |
| **ISO/IEC 27001:2022** | Information Security Management System | Standard ISMS adottato da tutte le banche italiane vigilate |
| **ISO/IEC 27017** / **27018** | Cloud security / PII in cloud | Estensione cloud-specifica della 27001 |
| **NIST SP 800-53 rev.5** | US Federal controls catalog | Usato come catalogo controlli mappato da framework europei |
| **NIST SP 800-63B** | Digital Identity — Authentication | Strong customer auth |
| **EBA/GL/2019/04** | EBA Guidelines on ICT and security risk management | Vincolante per banche EU/EEA |
| **DORA** (Reg. UE 2022/2554) | Digital Operational Resilience Act | Vigente dal 17/01/2025 per il settore finanziario UE |
| **NIS2** (Dir. UE 2022/2555) | Network and Information Security 2 | Trasposta in Italia con D.Lgs. 138/2024 |
| **Circ. Banca d'Italia 285/2013, parte I, titolo IV, cap. 4** | Disposizioni di vigilanza prudenziale — Sistema informativo | Sezione "Sistema informativo" della Banca d'Italia |
| **GDPR** (Reg. UE 2016/679) | Tutela dati personali | Identificativi device (`entraDeviceId`, `intuneDeviceId`), audit log con metadati operatore |

---

## Parte 1 — Funzionalità di sicurezza implementate

### 1. Autenticazione client (mTLS)

**Cosa.** Tutte le route HTTP (incluse quelle admin, dopo commit `e9622fd`)
richiedono **mutual TLS** con certificato dispositivo Intune (SCEP/PKCS).
L'App Service è configurato `clientCertEnabled=true`, `clientCertMode=Required`
e **senza** `clientCertExclusionPaths`. La validazione del cert avviene
in-process via `ClientCertValidator`:

- chain build con `CustomTrustStore` pinnato sui root CA del cliente
  (`ClientCert:TrustedRootCertificates`, base64 DER);
- pinning per thumbprint CA (`ClientCert:TrustedCaThumbprints`);
- EKU `Client Authentication` (1.3.6.1.5.5.7.3.2) obbligatorio;
- supporto opzionale CRL/OCSP (`ClientCert:CheckRevocation`,
  `RevocationMode`, `RevocationFlag`);
- pin leaf opzionale (`ClientCert:AllowedLeafThumbprints`).

**Codice.** `src/Shared/Services/ClientCertValidator.cs`,
`src/Web/Functions/ActionRequestFunction.cs:121`, `infra/main.bicep:498-505`.

**Mappatura normativa.**

| Framework | Controllo |
|---|---|
| PCI-DSS v4.0 | 8.3.2 (MFA per accessi amministrativi), 4.2.1 (strong cryptography in transit) |
| ISO 27001:2022 | A.5.17 (Authentication information), A.8.20 (Networks security), A.8.24 (Use of cryptography) |
| NIST SP 800-63B | AAL3 (hardware-bound authenticator quando il device cert è in TPM Intune) |
| EBA/GL/2019/04 | §3.4.2 (strong customer authentication), §3.4.5 (cryptographic key mgmt) |
| Banca d'Italia 285/13 | Sez. III, §3 (autenticazione utenti e dispositivi) |
| DORA | art. 9 (mecccanismi di autenticazione robusta) |

---

### 2. Autorizzazione e separation of duties

**Cosa.** Architettura plug-in con **6 Function App** isolate:
`Web`, `Proc`, `Wipe`, `Autopilot`, `BitLocker`, `Rename`. Ciascuna gira su
un proprio plan (1× EP1 + 5× FC1), con UAMI dedicata, storage account
separato e consent Microsoft Graph **minimo** per la propria capability.
Il dispatcher (`Proc`) instrada via Service Bus per-capability ma **non** ha
permessi Graph distruttivi. Il guard in-code `AppRoleGuard` legge
`App:Role` (impostato in App Configuration via `roleHint`) come barriera
fail-closed addizionale rispetto all'isolamento per artefatto.

Per la **admin surface** del ledger (operazioni distruttive lato SecOps) è
stata aggiunta dopo la security review banking-grade una **allow-list
operatore** distinta (`Idempotency:AdminCertThumbprints`) e l'`actor` audit
è vincolato al thumbprint del certificato verificato, non a un campo del
body (commit `e9622fd`).

**Codice.** `src/Shared/Services/AppRoleGuard.cs`,
`src/Proc/Program.cs`, `src/Web/Functions/ActionLedgerAdminFunction.cs`,
`infra/main.bicep` (sezione UAMI + role assignments scoped per coda).

**Mappatura normativa.**

| Framework | Controllo |
|---|---|
| PCI-DSS v4.0 | 7.1, 7.2 (least privilege), 7.3 (separation of duties) |
| ISO 27001:2022 | A.5.3 (Segregation of duties), A.5.15 (Access control), A.8.2 (Privileged access rights) |
| NIST SP 800-53 r5 | AC-5 (Separation of duties), AC-6 (Least privilege) |
| EBA/GL/2019/04 | §3.4.4 (logical access control con segregazione) |
| DORA | art. 9 §4 lett. c (privilegi minimi), art. 9 §4 lett. d (separation of duties) |

---

### 3. Anti-replay

**Cosa.** Ogni richiesta `POST /api/actions` richiede header
`X-Request-Timestamp` (ISO-8601 UTC, skew massimo configurabile ±5 min) e
`X-Request-Nonce` (GUID). `ReplayProtector` valida lo skew e mantiene una
cache dei nonce visti per scartare duplicati nella finestra. **Limite
documentato** (vedi Parte 2 gap #2): la cache è `IMemoryCache` per-istanza —
non blocca replay cross-istanza su EP1 multi-worker.

**Codice.** `src/Shared/Services/ReplayProtector.cs`,
`src/Web/Functions/ActionRequestFunction.cs:106`.

**Mappatura normativa.**

| Framework | Controllo |
|---|---|
| PCI-DSS v4.0 | 4.2.1 (strong cryptography + integrity); A.2 (anti-replay implicito) |
| ISO 27001:2022 | A.5.14 (Information transfer), A.8.21 (Security of network services) |
| NIST SP 800-63B | §5.2.8 (replay resistance) — parzialmente coperto |
| EBA/GL/2019/04 | §3.4.3 (integrità delle sessioni) |

---

### 4. Cert ↔ device binding (anti-IDOR)

**Cosa.** Il claim configurato del cert (default `Subject CN`, opzioni
`SanDns`/`SanUri`/`Thumbprint`/`SanDnsLookup`/`Auto`) deve corrispondere
all'`entraDeviceId` dichiarato nel body. Strategie claim-based **strict**:
il valore deve essere un GUID. La modalità `Auto` prova in ordine
`ThumbprintToDeviceMap → SanUri → SanDns → SubjectCN → SanDnsLookup`.

Risultato: un device non può richiedere azioni distruttive su un device
diverso anche se presenta un cert client valido del tenant.

**Codice.** `src/Shared/Services/ClientCertValidator.cs:280-340`,
`src/Web/Functions/ActionRequestFunction.cs:207-219`.

**Mappatura normativa.**

| Framework | Controllo |
|---|---|
| PCI-DSS v4.0 | 6.2.4 (prevent broken access control / IDOR) |
| ISO 27001:2022 | A.5.15 (Access control), A.8.5 (Secure authentication) |
| OWASP ASVS v4 | 4.2.1 (object-level access checks) |
| GDPR | art. 32 (riservatezza dei dati identificativi tra device terzi) |

---

### 5. Allow-list autorizzativa via gruppo Entra ID

**Cosa.** Solo i device membri (anche transitivi) di un gruppo Entra
configurato (`Wipe:AllowedGroupId`, `BitLocker:AllowedGroupId`, …) possono
ricevere l'azione. Il check è eseguito **server-side** nel runner
privilegiato, dopo l'mTLS, prima della chiamata Graph. La verifica è fatta
con `GroupMember.Read.All` sull'UAMI specifica.

**Codice.** `src/Shared/Services/DeviceDirectoryResolver.cs`,
`src/Capabilities.Wipe/Runners/WipeActionRunner.cs`,
`src/Capabilities.BitLocker/Runners/BitLockerRotateRunner.cs`.

**Mappatura normativa.**

| Framework | Controllo |
|---|---|
| PCI-DSS v4.0 | 7.2.1 (need-to-know access policies) |
| ISO 27001:2022 | A.5.18 (Access rights), A.5.15 (Access control) |
| NIST SP 800-53 r5 | AC-3 (Access enforcement), AC-2 (Account management) |

---

### 6. Ownership match Intune ↔ Entra

**Cosa.** Il backend verifica che `managedDevice.azureADDeviceId` sia
uguale all'`entraDeviceId` dichiarato dal client. Un device con
managedDevice non più associato al proprio Entra object (es. ri-enrollment)
viene rifiutato fail-closed.

**Codice.** `src/Capabilities.Wipe/Runners/WipeActionRunner.cs`
(verifica ownership).

**Mappatura normativa.**

| Framework | Controllo |
|---|---|
| PCI-DSS v4.0 | 6.2.4 (anti-tampering identity binding) |
| ISO 27001:2022 | A.5.15, A.8.5 |
| DORA | art. 9 §4 lett. b (identificazione e autenticazione del soggetto) |

---

### 7. Idempotency ledger (at-most-once destruttivo)

**Cosa.** Per ogni `intuneDeviceId` esiste un blob ledger con stato
`Reserved`/`Issued`/`Failed` e contatore `ActionSequence` con re-arm
controllato (grace period configurabile, max-per-day configurabile,
`X-Force-Rearm` solo se `Idempotency:AllowForceRearm=true`). La reservation
è atomica via `If-None-Match: *`, quindi due retry concorrenti non possono
emettere due wipe sullo stesso device. La reset manuale archivia il blob in
`_archive/` (audit trail conservato).

**Codice.** `src/Shared/Services/ActionIdempotencyService.cs`,
`src/Shared/Services/ActionStatusTracker.cs`.

**Mappatura normativa.**

| Framework | Controllo |
|---|---|
| PCI-DSS v4.0 | 6.2.4 (logic flaws / race conditions); 10.5 (audit trail integrity) |
| ISO 27001:2022 | A.5.30 (ICT readiness for business continuity), A.8.32 (Change management) |
| DORA | art. 9 §4 lett. e (integrità e affidabilità); art. 10 (rilevamento) |
| Banca d'Italia 285/13 | Sez. V (affidabilità) — riduzione rischio operazioni distruttive duplicate |

---

### 8. Validazione collisioni `displayName` (capability `device-rename`)

**Cosa.** Pre-check fail-closed (`Rename:OnCollision=block`) che interroga
sia Entra (`/devices?$filter=displayName eq '...'`) sia Intune
(`/deviceManagement/managedDevices?$filter=deviceName eq '...'`) per
prevenire collisioni — Entra non impone unicità su `displayName` come l'AD
on-prem. Il single quote nel nome è escaped (`'` → `''`) per prevenire
OData $filter injection.

**Codice.** `src/Capabilities.Rename/Services/GraphRenameService.cs`,
`src/Capabilities.Rename/Runners/RenameActionRunner.cs`.

**Mappatura normativa.**

| Framework | Controllo |
|---|---|
| PCI-DSS v4.0 | 6.2.4 (injection prevention) |
| ISO 27001:2022 | A.8.28 (Secure coding) |
| OWASP ASVS v4 | 5.3.x (Output encoding / injection prevention) |

---

### 9. Audit dual-write durabile

**Cosa.** Ogni decisione di allow/deny + ogni outcome è scritto in due
sink indipendenti:

1. **Application Insights** `customEvents` con sampling **disabilitato**;
2. **Tabella Azure Storage** `auditevents` (alimentata da `AuditTableSink`).

Tutti gli eventi portano `correlationId`, `intuneDeviceId`, `actionType`,
`actor` (per gli eventi admin il thumbprint del cert verificato — non più
self-reported dopo `e9622fd`). Gli eventi sono tipizzati in
`AuditEvents.cs` e includono i denial granulari (`denied:missing-serial`,
`denied:name-collision`, `denied:rate-limited`, …).

**Codice.** `src/Shared/Services/AuditService.cs`,
`src/Shared/Services/AuditTableSink.cs`,
`src/Shared/Services/AuditEvents.cs`.

**Mappatura normativa.**

| Framework | Controllo |
|---|---|
| PCI-DSS v4.0 | 10.2 (audit log content), 10.3 (protect audit logs), 10.4 (review) |
| ISO 27001:2022 | A.8.15 (Logging), A.8.16 (Monitoring activities) |
| NIST SP 800-53 r5 | AU-2, AU-3, AU-9 (audit and accountability) |
| EBA/GL/2019/04 | §3.4.4 (logging accessi privilegiati) |
| Banca d'Italia 285/13 | Sez. III, §4 (tracciamento e log) |
| DORA | art. 12 (rilevamento e logging incidents) |
| GDPR | art. 30 (registri attività), art. 32 (integrità log) |

---

### 10. Configurazione centralizzata + zero secret in codice

**Cosa.** Tutta la configurazione (eccetto bootstrap minimo dell'host) è
centralizzata in **Azure App Configuration**, letta via UAMI con
`disableLocalAuth=true`. Sentinel-based refresh: le 6 app rileggono al
prossimo refresh senza redeploy. Service Bus, Storage Account, App
Configuration hanno `disableLocalAuth=true` (no SAS, no connection string).
La soluzione non contiene secret hard-coded.

**Codice.** `src/Shared/HostBuilderExtensions.cs`,
`src/Shared/Middleware/AppConfigRefreshMiddleware.cs`,
`infra/main.bicep` (vedi `disableLocalAuth` su `serviceBus`,
`appConfig`, ogni `storage`).

**Mappatura normativa.**

| Framework | Controllo |
|---|---|
| PCI-DSS v4.0 | 3.7.4 (key/secret management), 8.6.1 (no shared/hardcoded credentials) |
| ISO 27001:2022 | A.5.17 (Authentication information), A.8.24 (Cryptography) |
| NIST SP 800-53 r5 | IA-5 (Authenticator management), SC-12 (Key establishment) |
| EBA/GL/2019/04 | §3.4.5 (key management); §3.4.7 (no credentials in code) |
| DORA | art. 9 §4 lett. c (gestione chiavi/credenziali) |

---

### 11. Managed Identity granulari (no Service Principal con secret)

**Cosa.** **6 User-Assigned Managed Identity** scoped per ruolo:

- `uami-web` — Service Bus Sender solo sulla coda `action-requests`,
  nessun Graph privilegiato;
- `uami` (proc/poller) — Service Bus Receiver/Sender sulle code di dispatch,
  Graph `DeviceManagementManagedDevices.Read.All` per il poller;
- `uami-wipe`, `uami-autopilot`, `uami-bitlocker`, `uami-rename` — ciascuna
  con i soli consent Graph necessari per la propria action (vedi tabella
  README "Permessi Microsoft Graph").

Tutti i role assignment sono scoped al singolo recipient (coda specifica,
account App Config specifico) — niente assegnazioni a livello sottoscrizione
o resource-group.

**Codice.** `infra/main.bicep` (sezione UAMI + role assignments per
risorsa), `tools/Grant-GraphPermissions.ps1`.

**Mappatura normativa.**

| Framework | Controllo |
|---|---|
| PCI-DSS v4.0 | 7.2 (least privilege), 8.6 (system accounts senza shared credentials) |
| ISO 27001:2022 | A.5.16 (Identity management), A.8.2 (Privileged access rights) |
| NIST SP 800-53 r5 | AC-6 (Least privilege), IA-9 (Service identification) |
| DORA | art. 9 §4 lett. d (segregazione e least privilege) |

---

### 12. Network isolation (variante `main.bicep` hardened)

**Cosa.** Variante hardened deploya:

- **VNet** con subnet delegate (`web-subnet`, `proc-subnet`, `wipe-subnet`,
  …) per VNet integration delle Function App;
- **NAT Gateway** per egress prevedibile (IP statico whitelistable
  upstream);
- **Private Endpoint** per Service Bus, Storage Account (4 — wipe ledger,
  audit, status, app config bootstrap), App Configuration;
- **Private DNS Zone** linkate;
- **NSG** sulle subnet con default-deny;
- Storage `publicNetworkAccess=Disabled` (raggiungibile solo via PE).

Variante `main-public.bicep` separata per ambienti dev/test.

**Codice.** `infra/main.bicep` (VNet, NAT, PE, PDZ, NSG).

**Mappatura normativa.**

| Framework | Controllo |
|---|---|
| PCI-DSS v4.0 | 1.3 (network segmentation), 1.4 (controlli ingress/egress) |
| ISO 27001:2022 | A.8.20 (Networks security), A.8.22 (Segregation of networks) |
| NIST SP 800-53 r5 | SC-7 (Boundary protection) |
| EBA/GL/2019/04 | §3.4.4 (segmentazione rete) |
| DORA | art. 9 §3 lett. a (isolamento componenti) |
| Banca d'Italia 285/13 | Sez. III, §2 (segmentazione e protezione perimetrale) |

---

### 13. Crittografia in transito e a riposo

**Cosa.**

- **TLS 1.2 minimo** + HTTPS-only su tutti gli App Service;
- mTLS handshake con cipher suite negoziate da App Service (TLS 1.2/1.3);
- Storage Account, Service Bus, App Configuration, Automation Account
  cifrati at-rest con chiavi gestite Microsoft (CMK opzionale,
  vedi gap #4);
- Blob ledger e audit table cifrati con AES-256 lato Azure Storage.

**Codice/IaC.** `infra/main.bicep` (`httpsOnly: true`, `minTlsVersion:
'1.2'` su ogni `Microsoft.Web/sites`; `supportsHttpsTrafficOnly: true` su
ogni storage).

**Mappatura normativa.**

| Framework | Controllo |
|---|---|
| PCI-DSS v4.0 | 3.5 (encryption at rest), 4.2 (encryption in transit) |
| ISO 27001:2022 | A.8.24 (Use of cryptography) |
| NIST SP 800-53 r5 | SC-13 (Cryptographic protection), SC-28 (Protection at rest) |
| GDPR | art. 32 (cifratura) |
| DORA | art. 9 §4 lett. e (cifratura dati) |

---

## Parte 2 — Gap residui banking-grade

> Tutti i gap qui sotto provengono dalla security-review banking-grade
> (riferimento agente `banking-security-review`). Sono **non-exploitable**
> da soli (l'Alert 1 — mTLS bypass admin — è già stato chiuso nel commit
> `e9622fd`), ma sono richiesti per un audit bancario pieno.

### Gap #1 — Anti-replay non distribuito

| Aspetto | Stato |
|---|---|
| Implementazione | `ReplayProtector` usa `IMemoryCache` per-istanza |
| Rischio residuo | Su EP1 multi-worker, due richieste con stesso `(timestamp, nonce, body)` su istanze diverse non vengono entrambe rifiutate. Il ledger idempotency neutralizza il danno per le azioni distruttive ma il **controllo anti-replay in sé** non è conforme |
| Norma | NIST SP 800-63B §5.2.8; EBA/GL/2019/04 §3.4.3 |
| Remediation | Spostare la nonce-store su Azure Table (TTL nativa) o Redis condiviso |

### Gap #2 — Nonce non legato al body

| Aspetto | Stato |
|---|---|
| Implementazione | `X-Request-Nonce` è solo un GUID — non un HMAC di `body + timestamp + cert thumbprint` |
| Rischio residuo | MITM che ottiene una tuple valida può replayarla in finestra di skew |
| Norma | RFC 9421 HTTP Message Signatures |
| Remediation | Adottare HTTP Message Signatures firmate con la chiave privata del client cert |

### Gap #3 — Key Vault HSM-backed non obbligatorio

| Aspetto | Stato |
|---|---|
| Implementazione | `Rename:AuthHeaderValue`, `RunbookBridge:Routes:*` e altri secret di control-plane sono in App Configuration come stringhe. I commenti suggeriscono Key Vault reference ma il bicep non lo enforce e non c'è Managed HSM |
| Rischio residuo | Custody dei secret operativi non FIPS 140-2/3 |
| Norma | PCI-DSS 3.5/3.7; FIPS 140-2/3; EBA/GL/2019/04 §3.4.5 |
| Remediation | Key Vault Premium HSM SKU + soft-delete + purge protection + RBAC; convertire tutte le chiavi `*Value`/`*Url` in Key Vault references |

### Gap #4 — Cifratura con chiavi cliente (CMK)

| Aspetto | Stato |
|---|---|
| Implementazione | Storage/Service Bus/App Config cifrati con chiavi Microsoft-managed |
| Rischio residuo | Nessuna separation of duties con Microsoft come custode crittografico |
| Norma | EBA/GL/2019/04 §3.4.5; DORA art. 9 §4 lett. e |
| Remediation | Customer-Managed Keys via Key Vault HSM + key rotation policy documentata |

### Gap #5 — Revocation check off di default

| Aspetto | Stato |
|---|---|
| Implementazione | `ClientCert:CheckRevocation=false` di default; nessun OCSP stapling all'edge |
| Rischio residuo | Cert dispositivo revocato continua ad autenticare fino a scadenza CA |
| Norma | EBA/GL/2019/04; PCI-DSS A.2 |
| Remediation | Default → `true` con `RevocationMode=Online`; valutare OCSP stapling via APIM/App Gateway davanti alla Function |

### Gap #6 — Audit tamper-resistance

| Aspetto | Stato |
|---|---|
| Implementazione | Audit Table scrivibile/cancellabile dalla UAMI stessa (`Table Data Contributor`). Nessuna policy WORM, nessun legal hold |
| Rischio residuo | Audit non tamper-evident: stesso principal può scrivere e cancellare |
| Norma | PCI-DSS 10.5; ISO 27001 A.12.4.2; DORA art. 12 |
| Remediation | Storage Account `immutableStorageWithVersioning` o esportare audit verso Log Analytics workspace con retention WORM 5–7 anni; UAMI di scrittura distinta da UAMI di lettura/conservazione |

### Gap #7 — Retention log non specificata

| Aspetto | Stato |
|---|---|
| Implementazione | Nessun `retentionInDays` esplicito su Log Analytics / App Insights |
| Rischio residuo | Retention di default Microsoft (90gg) sotto i 5–7 anni richiesti dal settore |
| Norma | Banca d'Italia 285/13 (conservazione log accessi privilegiati); DORA art. 12 |
| Remediation | Settare `retentionInDays = 365` su workspace + export continuo verso Storage Account con immutability policy 7 anni |

### Gap #8 — Automation Account: `disableLocalAuth=false` + webhook bearer

| Aspetto | Stato |
|---|---|
| Implementazione | AA con `disableLocalAuth=false` e `publicNetworkAccess=true`; webhook URL = long-lived bearer secret |
| Rischio residuo | Chi conosce la webhook URL esegue il runbook senza ulteriore identity check |
| Norma | DORA art. 9 §3 lett. a; EBA/GL/2019/04 §3.4.4 |
| Remediation | `disableLocalAuth=true` + Hybrid Runbook Worker su VNet con PE + invio job autenticato via Entra ID |

### Gap #9 — `TrustedCaCertificates` legacy auto-classifica come root

| Aspetto | Stato |
|---|---|
| Implementazione | `ClientCertValidator` accetta nel parametro legacy `TrustedCaCertificates` cert self-signed promossi automaticamente a root |
| Rischio residuo | Un operatore distratto può promuovere un intermedio a trust anchor |
| Norma | ISO 27001 A.5.17; PCI-DSS 8.3.2 |
| Remediation | Fail-deploy se `TrustedCaCertificates` contiene cert non self-signed — forzare l'uso di `TrustedRootCertificates` / `TrustedIntermediateCertificates` |

### Gap #10 — Separation of duties function key

| Aspetto | Stato |
|---|---|
| Implementazione | Stessa function host key gateway dell'intake pubblico **e** degli endpoint admin (dopo `e9622fd` l'admin richiede comunque mTLS + thumbprint allow-list, ma la function key è ancora condivisa) |
| Rischio residuo | Non sussiste exploit path diretto (gli altri layer sono fail-closed), ma resta una scelta sub-ottima per audit |
| Norma | PCI-DSS 7.1; ISO 27001 A.9.4 |
| Remediation | Dedicare una host key separata `admin` (Functions supports multiple keys); o spostare admin su Function App separata Private-Endpoint-only |

---

## Tabella di sintesi: stato vs framework

| Framework | Controlli coperti | Gap aperti |
|---|---|---|
| **PCI-DSS v4.0** | 1.3/1.4, 3.5/3.7, 4.2.1, 6.2.4, 7.1/7.2/7.3, 8.3.2/8.6, 10.2/10.3, A.2 | 10.5 (audit immutability), 3.7.4 (HSM), separation keys |
| **ISO 27001:2022** | A.5.3, A.5.15-A.5.18, A.5.30, A.8.2, A.8.5, A.8.15-A.8.16, A.8.20, A.8.22, A.8.24, A.8.28, A.8.32 | A.12.4.2 (log integrity), CMK |
| **NIST SP 800-53 r5** | AC-2/3/5/6, AU-2/3, IA-5/9, SC-7/12/13/28 | AU-9 (full), SC-13 con CMK |
| **EBA/GL/2019/04** | §3.4.2, §3.4.4, §3.4.5 (parziale), §3.4.7 | §3.4.5 (HSM/CMK), §3.4.3 (replay distribuito) |
| **DORA (Reg. 2554/2022)** | art. 9 §3-§4, art. 10 (parziale), art. 12 (parziale) | art. 12 (immutability), art. 9 §4 lett. e (CMK) |
| **Banca d'Italia 285/13, IV.4** | Sez. III §2-§4, Sez. V | Conservazione log 5–7 anni WORM |
| **GDPR** | art. 30, art. 32 | DPIA su categoria device identifiers se collegabili a persona |
| **NIS2 (D.Lgs. 138/2024)** | art. 24 §2 lett. d (controlli accesso), lett. h (logging) | Programma di gestione incidenti formalizzato fuori dal codice |

---

## Note finali

- **Versione di riferimento.** Tutti i riferimenti `commit ...` puntano a
  `robgrame/intune-device-actions`. La review banking-grade è stata
  eseguita sul commit `8f0956a`; il fix dell'unico HIGH è in `e9622fd`.
- **Aggiornamento.** Questo documento va rivisto a ogni modifica di
  `ClientCertValidator`, `ActionLedgerAdminFunction`, `AuditService`, o
  delle network policy in `infra/main.bicep`.
- **Out of scope.** Il documento non copre i controlli del cliente fuori
  dal perimetro della soluzione (Conditional Access, Defender for Endpoint,
  Intune Compliance Policy, ecc.) anche se sono complementari per la
  defense-in-depth.
