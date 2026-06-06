# Capability `autopilot-register` e `bitlocker-rotate`

Due nuove capability plug-in costruite sul medesimo flusso del wipe
(`client mTLS → ActionRequest (Web) → action-requests → RequestIntake →
action-dispatch → ActionDispatch (router) → IActionRunner`). Nessuna risorsa
**CORE** (HTTP function, code Service Bus core, `RequestIntake`,
`ActionDispatch`, contratto `ActionDispatchMessage`) è stata modificata: ogni
capability si aggiunge come nuovo runner + forwarder + app/coda dedicata +
voce nell'allow-list `Actions:AllowedTypes`, esattamente come previsto dal
design.

Entrambe seguono lo stesso isolamento di privilegio della `Wipe`: il `Proc`
inoltra la busta su una coda per-capability; una **Function App dedicata** la
consuma con la propria **UAMI** (identità Graph isolata) e la propria coda.

---

## `autopilot-register` — self-registration in Windows Autopilot

Il device chiede di registrare sé stesso in Windows Autopilot riusando lo
stesso flusso del wipe. Il punto architetturale chiave: l'**hardware hash**
(`MDM_DevDetail_Ext01` / `Get-WindowsAutopilotInfo`) **non è disponibile
lato server** — va raccolto sul device, esattamente come l'identità nel wipe.

- **Client:** `client/Invoke-AutopilotRegister.ps1` + `client/AutopilotIdentity.psm1`
  raccolgono hardware hash, serial number e product key e li inviano nel
  campo `autopilot` del payload (deserializzato lato server in
  `IntuneDeviceActions.Capabilities.Autopilot.Models.AutopilotIdentityPayload`
  tramite la bag opaca `ActionRequest.Extras` di Shared), riusando il
  client cert mTLS. Nessun dialog "digita WIPE": esecuzione silente in
  SYSTEM context.
- **Server:** `AutopilotRegisterRunner` (`Type = "autopilot-register"`) esegue
  l'**import esplicito** via Graph
  `POST /deviceManagement/importedWindowsAutopilotDeviceIdentities` con
  l'hardware hash → deterministico e idempotente per device. Non esegue la
  verifica di ownership distruttiva del wipe.
- **UAMI dedicata** `uami-autopilot` con permesso Graph
  **`DeviceManagementServiceConfig.ReadWrite.All`** (+ `...ManagedDevices.Read.All`,
  `Device.Read.All`, `GroupMember.Read.All`).
- **App/coda dedicata:** `Autopilot` Function App, coda `autopilot-action`.
- **Status:** `AutopilotActionStatusProbe` interroga lo stato
  dell'`importedWindowsAutopilotDeviceIdentity` (complete→done, error→failed).

## `bitlocker-rotate` — rotazione self-service della recovery key BitLocker

Azione amministrativa **non distruttiva** invocabile dall'utente ("temo che la
mia recovery key sia stata esposta"). Riusa identicamente il flusso del wipe,
inclusi ownership-check e rate-limit.

- **Client:** `client/Invoke-BitLockerKeyRotation.ps1` (nessun dato extra oltre
  l'identità già raccolta).
- **Server:** `BitLockerRotateRunner` (`Type = "bitlocker-rotate"`) chiama Graph
  `POST /deviceManagement/managedDevices/{id}/rotateBitLockerKeys`.
- **UAMI dedicata** `uami-bitlocker` con permesso Graph
  **`DeviceManagementManagedDevices.PrivilegedOperations.All`** (+ `...Read.All`,
  `Device.Read.All`, `GroupMember.Read.All`).
- **App/coda dedicata:** `BitLocker` Function App, coda `bitlocker-action`.

---

## Abilitazione (operatori)

1. **Allow-list:** aggiungere il tipo all'app setting/App Configuration
   `Actions:AllowedTypes` (default `wipe`, fail-closed). Esempio:
   `wipe,autopilot-register,bitlocker-rotate`.
2. **Gruppo Entra di allow-list per device** (opzionale, default = gruppo wipe):
   - `Autopilot__AllowedGroupId` ← param Bicep `autopilotAllowedGroupId`
   - `BitLocker__AllowedGroupId` ← param Bicep `bitlockerAllowedGroupId`
3. **Consent Graph** sulle nuove UAMI: `tools/Grant-GraphPermissions.ps1`
   assegna i ruoli sopra a `uami-autopilot` e `uami-bitlocker`.
4. **Deploy:** `tools/Deploy-IntuneDeviceActions.ps1` pubblica e distribuisce
   anche le app `autopilot` e `bitlocker` (5 ruoli totali:
   web/proc/wipe/autopilot/bitlocker).

## Nota infrastrutturale

La VNet condivisa `/24` è interamente allocata, quindi le due nuove Function
App Flex Consumption girano **senza VNet integration**: il loro storage usa
`networkAcls.defaultAction='Allow'` (no private endpoint). Egress verso Graph
via IP di piattaforma dinamici (non l'IP statico del NAT Gateway) — accettabile
per queste azioni amministrative non distruttive.
