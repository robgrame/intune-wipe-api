# Runbook variant — alternative wipe executor (demo)

Questa cartella contiene una **variante alternativa** dell'esecutore della
capability `wipe`: invece di girare sulla `wipe-runner` Function App, il
comando può essere eseguito da un **Azure Automation Runbook in PowerShell
7.2**, agganciato esattamente alla stessa infrastruttura core (HTTP
front-end, dispatcher, code, audit, ledger).

## Razionale

L'architettura Option-2 (Function App dedicata per la capability `wipe`)
dimostra il modello plug-in via `IActionRunner` registrato in DI sulla
runtime .NET. La variante runbook **dimostra che la stessa capability può
essere implementata in un linguaggio/runtime diverso** senza toccare
nessuno dei componenti core:

```
HTTP front-end → Service Bus / queue dispatcher (invariato)
       ↓
   ActionDispatchFunction (router invariato)
       ↓
  ┌────────────┴────────────┐
  ▼                         ▼
WipeForwardingRunner    [variant] WipeRunbookForwardingRunner
  ↓ enqueue                ↓ POST webhook
wipe-action queue        Automation webhook
  ↓                         ↓
WipeActionConsumerFunction  Invoke-DeviceWipe.runbook.ps1
  → Graph wipe              → Graph wipe
```

Entrambi gli executor:
- Ricevono lo stesso envelope (`ActionDispatchMessage`).
- Chiamano `POST /deviceManagement/managedDevices/{id}/wipe` con gli stessi
  flag `keepEnrollmentData` / `keepUserData`.
- Scrivono audit nello stesso Azure Table `auditevents` (così il portale
  vede entrambi i trail nello stesso posto).
- Usano lo stesso ledger blob per idempotenza/rearm.

## Stato

- **Codice runbook**: `Invoke-DeviceWipe.runbook.ps1` — pronto, opt-in.
- **Bicep / Automation Account resource**: **NON** deployato di default
  per mantenere lean il setup produzione. La sezione "Wire-up" nello
  script header documenta i passi manuali (creazione Automation Account,
  grant Graph perms, import runbook, webhook).
- **Forwarder C# alternativo**: documentato come hook in
  `WipeRunbookWebhook__Url` — implementazione lasciata fuori dal default
  per evitare confusione con il path canonico (queue → consumer).

## Quando usarla?

- Demo al cliente del modello plug-in: stesso input, due implementazioni
  intercambiabili.
- Scenari dove ops PowerShell-centric: il runbook può essere debuggato/
  editato in-portal senza CI/CD.
- Cap di costo molto basso: 500 min/mese gratis su Automation; tipicamente
  €0 al nostro rate.

## Quando NON usarla?

- Default produzione: la `wipe-runner` Function App è già isolata e
  privilegiata correttamente. Aggiungere il runbook **in parallelo**
  raddoppia le superfici di audit e i grant di permission senza valore
  netto.
