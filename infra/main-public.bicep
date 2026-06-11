targetScope = 'resourceGroup'

// ─────────────────────────────────────────────────────────────────────────────
// IntuneDeviceActions — PUBLIC-NETWORK VARIANT (main-public.bicep)
//
// This is a simplified deployment WITHOUT any network isolation
// infrastructure. Use it when you want a fast / low-cost deployment and you
// accept that the storage / Service Bus / App Configuration endpoints are
// reachable from the public Internet (still protected by Entra ID + RBAC,
// and the only client-facing surface, funcWeb, still requires mTLS).
//
// Removed compared to infra/main.bicep:
//   • VNet (idactions-vnet-*) + 4 subnets
//   • 2 NSGs (flex / web)
//   • NAT Gateway + Standard Public IP (no SNAT stability for Graph egress)
//   • 4 Private DNS zones (blob/file/queue/table) + VNet links
//   • Private Endpoints for storageWeb / storageProc / storageWipe
//   • Flex VNet integration (virtualNetworkSubnetId removed from funcProc,
//     funcWipe; vnetRouteAllEnabled / vnetContentShareEnabled removed from
//     funcWeb)
//
// Other changes:
//   • storageWeb / storageProc / storageWipe — networkAcls.defaultAction
//     flipped from 'Deny' to 'Allow' (no PE path available).
//   • Microsoft.App resource provider registration is no longer strictly
//     required (it was only needed for Flex VNet integration) — keep it
//     registered, harmless.
//
// Resource names are intentionally identical to main.bicep, so you can
// switch between the two on the same RG (note: ARM what-if will show many
// deletions when moving hardened → public).
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// IntuneDeviceActions — Phase C infrastructure (base architecture)
//
// Architecture:
//   funcWeb  (EP1, Linux, dotnet-isolated 10)     ← public mTLS HTTP only
//   funcProc (FC1, Flex Consumption, scale-to-zero) ← dispatcher + status poller
//   funcWipe (FC1, Flex Consumption, scale-to-zero) ← privileged Graph wipe
//   Service Bus Standard namespace + 3 queues:
//     action-requests   web → proc
//     action-dispatch   proc → proc (router)
//     wipe-action       proc → wipe
//   Storage: per-app runtime storage account. Proc account holds shared
//     audit + status tables and the idempotency ledger blob. Each Flex app
//     gets its own dedicated deployment-package container with UAMI
//     Storage Blob Data Contributor scoped to that container.
//   AppConfig: shared store, label = App__Role, read via UAMI.
//   Automation Account + runbook (PS 7.2) demo plug-in remains optional.
// ─────────────────────────────────────────────────────────────────────────────

@minLength(3)
@maxLength(12)
param namePrefix string = 'idactions'

param location string = resourceGroup().location

@description('Tenant ID where Graph calls are made')
param graphTenantId string = subscription().tenantId

// ── Client cert validation (unchanged from previous architecture) ────────────
@description('Comma-separated list of trusted CA certificate thumbprints (root and/or intermediate). At least one must appear in the client certificate chain. Required unless trustedRootCertificatesBase64 (or legacy trustedCaCertificatesBase64) is provided.')
param trustedCaThumbprints string = ''

@description('Base64-encoded DER ROOT CA certificates (self-signed). Loaded into CustomTrustStore as trust anchors. Separate multiple certificates with pipe (|), comma (,) or semicolon (;).')
@secure()
param trustedRootCertificatesBase64 string = ''

@description('Base64-encoded DER INTERMEDIATE CA certificates. Loaded into ExtraStore only (path-building hints, NOT trust anchors). Separate multiple certificates with pipe (|), comma (,) or semicolon (;).')
@secure()
param trustedIntermediateCertificatesBase64 string = ''

@description('DEPRECATED. Use trustedRootCertificatesBase64 + trustedIntermediateCertificatesBase64. Legacy bag of CA certs (auto-classified by self-signed flag at startup). Kept for backward compatibility.')
@secure()
param trustedCaCertificatesBase64 string = ''

@description('Optional comma-separated list of leaf certificate thumbprints to pin (defense-in-depth). Empty disables leaf pinning.')
param allowedLeafThumbprints string = ''

@description('Enable CRL/OCSP revocation checks on the client certificate chain.')
param checkRevocation bool = false

@allowed([ 'Online', 'Offline', 'NoCheck' ])
param revocationMode string = 'Online'

@allowed([ 'ExcludeRoot', 'EntireChain', 'EndCertificateOnly' ])
param revocationFlag string = 'ExcludeRoot'

@description('Require Client Authentication EKU (1.3.6.1.5.5.7.3.2) on the client certificate.')
param requireClientAuthEku bool = true

@allowed([ 'Auto', 'SubjectCN', 'SanDns', 'SanUri', 'Thumbprint', 'SanDnsLookup', 'Disabled' ])
param deviceIdBindingClaim string = 'Auto'

@description('Operator-maintained mapping cert-thumbprint -> EntraDeviceId for the Thumbprint/Auto binding modes. Format: "THUMB1=guid1|THUMB2=guid2".')
@secure()
param clientCertThumbprintToDeviceMap string = ''

@description('Maximum acceptable clock skew (seconds) between client X-Request-Timestamp and server time.')
param maxTimestampSkewSeconds int = 300

@description('Object Id of the Entra ID security group whose member devices are authorized to self-wipe')
param allowedGroupId string

@description('Object Id of the Entra ID security group whose member devices are authorized to self-service rotate their BitLocker recovery key. Defaults to the wipe group; override to isolate the BitLocker allow-list.')
param bitlockerAllowedGroupId string = allowedGroupId

@description('Wipe options')
param keepEnrollmentData bool = false
param keepUserData bool = false

// ── Service Bus queues ───────────────────────────────────────────────────────
@description('Service Bus queue name for action requests published by the public Web app.')
param actionRequestsQueueName string = 'action-requests'

@description('Service Bus queue name for the plug-in action dispatch router consumed by ActionDispatchFunction.')
param actionDispatchQueueName string = 'action-dispatch'

@description('Service Bus queue name for the dedicated wipe-runner Function App.')
param wipeActionQueueName string = 'wipe-action'

@description('Service Bus queue name for the dedicated autopilot-runner Function App.')
param autopilotActionQueueName string = 'autopilot-action'

@description('Service Bus queue name for the dedicated bitlocker-runner Function App.')
param bitlockerActionQueueName string = 'bitlocker-action'

@description('Service Bus queue name for the dedicated rename-runner Function App.')
param renameActionQueueName string = 'rename-action'

@description('Customer-internal device-rename REST endpoint URL (LOOKUP — given a serial returns the canonical new name). Supports {serial} placeholder. Leave empty to configure via App Configuration post-deploy.')
param renameEndpoint string = ''

@description('HTTP header name used to authenticate against the customer rename lookup endpoint.')
param renameAuthHeaderName string = 'X-Api-Key'

@description('Name of the response JSON property holding the resolved hostname. Default: newName.')
param renameNewNameJsonPath string = 'newName'

@description('Behaviour when the resolved name collides with an existing Entra device displayName. "block" → fail closed (recommended); "warn" → audit + proceed.')
@allowed([ 'block', 'warn' ])
param renameOnCollision string = 'block'

// ── Storage (blob + tables) ──────────────────────────────────────────────────
@description('Blob container name used as the idempotency ledger for action operations')
param ledgerContainerName string = 'action-ledger'

@description('Table name used for long-term audit event persistence (dual-write alongside App Insights)')
param auditTableName string = 'auditevents'

@description('Azure Table holding per-correlationId action status. Polled by ActionStatusPollerFunction.')
param actionStatusTableName string = 'actionstatus'

@description('NCRONTAB expression for the action status poller. Default: every 2 minutes.')
param actionStatusPollerCron string = '0 */2 * * * *'

@description('Max age (hours) of action-status rows the poller will still consider. Rows older than this with non-terminal state are flipped to action.poll-timeout. Defaults to 24 (one full day after request).')
param actionStatusPollMaxAgeHours int = 24

// ── Idempotency ledger ───────────────────────────────────────────────────────
@description('Max wipes per device per 24h. Hard ceiling enforced by the ledger.')
param idempotencyMaxActionsPerDay int = 5
@description('Hours to wait before auto-rearming a ledger whose previous wipe ended in pollTimeout.')
param idempotencyRearmGracePeriodHours int = 48
@description('If true, the X-Force-Rearm HTTP header bypasses the tracker-based rearm gate. Keep false in prod.')
param idempotencyAllowForceRearm bool = true
@description('If true, the /api/actions/ledger/* endpoints are reachable (function key still required). Default false in prod.')
param idempotencyAdminApiEnabled bool = true

@description('Provisions an Azure Automation Account + PowerShell 7.2 runbook (Invoke-DeviceWipe) as an alternative wipe executor.')
param enableRunbookVariant bool = true

// ── Storage network access (operator IPs whitelisted on the public endpoint)
// Storage stays publicNetworkAccess=Enabled with defaultAction=Deny: only
// Azure trusted services (bypass=AzureServices) and listed operator IPs can
// reach the data plane. The Function Apps reach storage via the
// AzureServices bypass today; the private endpoints below provide the
// future path for VNet-integrated clients.
@description('IPv4 addresses or CIDR ranges of operators / build agents allowed to reach the storage data plane through the public endpoint (e.g. local dev box, GitHub Actions). Empty disables the IP allow-list (only AzureServices bypass remains).')
param storageAllowedIpRanges array = []

// ── Naming ───────────────────────────────────────────────────────────────────
@description('Disambiguation suffix appended to globally-unique resource names (Storage, App Configuration, Service Bus, Function App FQDN, etc.). Leave default for deterministic per-RG hash; override with empty string to omit (only safe if namePrefix is already globally unique).')
param nameSuffix string = uniqueString(resourceGroup().id)

@description('Tags applied to every taggable Azure resource. Sub-resources (queues, containers, role assignments, DNS records) are not tagged because the platform does not support it.')
param tags object = {}

var suffix = nameSuffix
var sep    = empty(nameSuffix) ? '' : '-'
var stWebRaw  = toLower('${namePrefix}stw${suffix}')
var stWebName = length(stWebRaw) > 24 ? substring(stWebRaw, 0, 24) : stWebRaw
var stProcRaw  = toLower('${namePrefix}stp${suffix}')
var stProcName = length(stProcRaw) > 24 ? substring(stProcRaw, 0, 24) : stProcRaw
var stWipeRaw  = toLower('${namePrefix}stwp${suffix}')
var stWipeName = length(stWipeRaw) > 24 ? substring(stWipeRaw, 0, 24) : stWipeRaw
var stAplRaw   = toLower('${namePrefix}stap${suffix}')
var stAplName  = length(stAplRaw) > 24 ? substring(stAplRaw, 0, 24) : stAplRaw
var stBlkRaw   = toLower('${namePrefix}stbl${suffix}')
var stBlkName  = length(stBlkRaw) > 24 ? substring(stBlkRaw, 0, 24) : stBlkRaw
var stRnRaw    = toLower('${namePrefix}strn${suffix}')
var stRnName   = length(stRnRaw) > 24 ? substring(stRnRaw, 0, 24) : stRnRaw

var webName  = toLower('${namePrefix}-web${sep}${suffix}')
var procName = toLower('${namePrefix}-proc${sep}${suffix}')
var wipeName = toLower('${namePrefix}-wipe${sep}${suffix}')
var autopilotName = toLower('${namePrefix}-autopilot${sep}${suffix}')
var bitlockerName = toLower('${namePrefix}-bitlocker${sep}${suffix}')
var renameName = toLower('${namePrefix}-rename${sep}${suffix}')
var aiName   = toLower('${namePrefix}-ai${sep}${suffix}')
var lawName  = toLower('${namePrefix}-law${sep}${suffix}')

var uamiName     = toLower('${namePrefix}-uami${sep}${suffix}')      // dispatcher (no Graph)
var uamiWebName  = toLower('${namePrefix}-uami-web${sep}${suffix}')   // public web (Graph: Device.Read.All only, for DeviceDirectoryResolver SAN-DNS -> Entra deviceId binding)
var uamiWipeName = toLower('${namePrefix}-uami-wipe${sep}${suffix}')  // privileged Graph
var uamiAutopilotName = toLower('${namePrefix}-uami-autopilot${sep}${suffix}')  // privileged Graph (Autopilot import)
var uamiBitLockerName = toLower('${namePrefix}-uami-bitlocker${sep}${suffix}')  // privileged Graph (BitLocker rotate)
var uamiRenameName = toLower('${namePrefix}-uami-rename${sep}${suffix}')

var planWebName  = toLower('${namePrefix}-plan-web${sep}${suffix}')   // EP1
var planProcName = toLower('${namePrefix}-plan-proc${sep}${suffix}')  // FC1
var planWipeName = toLower('${namePrefix}-plan-wipe${sep}${suffix}')  // FC1
var planAutopilotName = toLower('${namePrefix}-plan-autopilot${sep}${suffix}')  // FC1
var planBitLockerName = toLower('${namePrefix}-plan-bitlocker${sep}${suffix}')  // FC1
var planRenameName = toLower('${namePrefix}-plan-rename${sep}${suffix}')

var sbNamespaceName = toLower('${namePrefix}-sb${sep}${suffix}')
var appConfigName   = toLower('${namePrefix}-appcfg${sep}${suffix}')

// Per-Flex-app deployment package containers (Flex Consumption requirement).
var procDeployContainer = 'app-package-proc'
var wipeDeployContainer = 'app-package-wipe'
var autopilotDeployContainer = 'app-package-autopilot'
var bitlockerDeployContainer = 'app-package-bitlocker'
var renameDeployContainer = 'app-package-rename'

// ── Observability ────────────────────────────────────────────────────────────
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  tags:     tags
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

resource ai 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  tags:     tags
  kind: 'web'
  properties: { Application_Type: 'web', WorkspaceResourceId: law.id }
}

// ── Storage accounts (one per app) ───────────────────────────────────────────
resource storageWeb 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: stWebName
  location: location
  tags:     tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices, Logging, Metrics'
      ipRules: [for ip in storageAllowedIpRanges: { value: ip, action: 'Allow' }]
      virtualNetworkRules: []
    }
  }
}

resource storageProc 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: stProcName
  location: location
  tags:     tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices, Logging, Metrics'
      ipRules: [for ip in storageAllowedIpRanges: { value: ip, action: 'Allow' }]
      virtualNetworkRules: []
    }
  }
}

resource storageWipe 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: stWipeName
  location: location
  tags:     tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices, Logging, Metrics'
      ipRules: [for ip in storageAllowedIpRanges: { value: ip, action: 'Allow' }]
      virtualNetworkRules: []
    }
  }
}

// ── Blob containers ──────────────────────────────────────────────────────────
resource blobSvcProc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageProc
  name: 'default'
}
resource ledgerContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobSvcProc
  name: ledgerContainerName
  properties: { publicAccess: 'None' }
}
// Flex Consumption deployment package container for the Proc app.
resource procDeployBlobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobSvcProc
  name: procDeployContainer
  properties: { publicAccess: 'None' }
}

resource blobSvcWipe 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageWipe
  name: 'default'
}
// Flex Consumption deployment package container for the Wipe app.
resource wipeDeployBlobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobSvcWipe
  name: wipeDeployContainer
  properties: { publicAccess: 'None' }
}

// ── Shared tables (audit + action status) on storageProc ────────────────────
resource tableSvcProc 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storageProc
  name: 'default'
}
resource auditTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableSvcProc
  name: auditTableName
}
resource actionStatusTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableSvcProc
  name: actionStatusTableName
}

// ── User-assigned managed identities ─────────────────────────────────────────
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
  tags:     tags
}
resource uamiWeb 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiWebName
  location: location
  tags:     tags
}
resource uamiWipe 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiWipeName
  location: location
  tags:     tags
}

// ── Service Bus Standard namespace + 3 queues ────────────────────────────────
// Standard tier is required for: queue auto-forwarding (not used here but kept
// in our back-pocket), DLQ, and topic/subscription affordances if we extend.
// Basic would not support topics — Standard at ~10€/mo is cheap insurance.
resource sbNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: sbNamespaceName
  location: location
  tags:     tags
  sku: { name: 'Standard', tier: 'Standard' }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true  // force AAD/MI auth, no SAS
  }
}

// Conservative defaults: TTL 1 day, 5 deliveries before DLQ, 5-minute lock.
// No sessions. requiresDuplicateDetection=false is INTENTIONAL: producers set
// MessageId=correlationId for diagnostic traceability and SB-native correlation,
// NOT for idempotency. Idempotency is enforced by the IdempotencyService blob
// ledger. Enabling dedup here would silently swallow legitimate retries that
// reuse the same correlationId (replay, lock-expiry redelivery, etc.).
resource sbQueueActionRequests 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sbNamespace
  name: actionRequestsQueueName
  properties: {
    lockDuration: 'PT5M'
    defaultMessageTimeToLive: 'P1D'
    maxDeliveryCount: 5
    deadLetteringOnMessageExpiration: true
    enablePartitioning: false
    requiresSession: false
    requiresDuplicateDetection: false
  }
}
resource sbQueueActionDispatch 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sbNamespace
  name: actionDispatchQueueName
  properties: {
    lockDuration: 'PT5M'
    defaultMessageTimeToLive: 'P1D'
    maxDeliveryCount: 5
    deadLetteringOnMessageExpiration: true
    enablePartitioning: false
    requiresSession: false
    requiresDuplicateDetection: false
  }
}
resource sbQueueWipeAction 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sbNamespace
  name: wipeActionQueueName
  properties: {
    lockDuration: 'PT5M'
    defaultMessageTimeToLive: 'P1D'
    maxDeliveryCount: 5
    deadLetteringOnMessageExpiration: true
    enablePartitioning: false
    requiresSession: false
    requiresDuplicateDetection: false
  }
}
resource sbQueueAutopilotAction 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sbNamespace
  name: autopilotActionQueueName
  properties: {
    lockDuration: 'PT5M'
    defaultMessageTimeToLive: 'P1D'
    maxDeliveryCount: 5
    deadLetteringOnMessageExpiration: true
    enablePartitioning: false
    requiresSession: false
    requiresDuplicateDetection: false
  }
}
resource sbQueueBitLockerAction 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sbNamespace
  name: bitlockerActionQueueName
  properties: {
    lockDuration: 'PT5M'
    defaultMessageTimeToLive: 'P1D'
    maxDeliveryCount: 5
    deadLetteringOnMessageExpiration: true
    enablePartitioning: false
    requiresSession: false
    requiresDuplicateDetection: false
  }
}
resource sbQueueRenameAction 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sbNamespace
  name: renameActionQueueName
  properties: {
    lockDuration: 'PT5M'
    defaultMessageTimeToLive: 'P1D'
    maxDeliveryCount: 5
    deadLetteringOnMessageExpiration: true
    enablePartitioning: false
    requiresSession: false
    requiresDuplicateDetection: false
  }
}

// ── App Service Plans ────────────────────────────────────────────────────────
// Web stays on Linux EP1 because: (a) mTLS + always-warm intake demand
// predictable concurrency and no cold-start; (b) clientCertEnabled is not
// supported on Flex Consumption today.
resource planWeb 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planWebName
  location: location
  tags:     tags
  sku: { name: 'EP1', tier: 'ElasticPremium' }
  kind: 'elastic'
  properties: { reserved: true, maximumElasticWorkerCount: 5 }
}

// Proc + Wipe move to Flex Consumption (FC1) for scale-to-zero + per-second
// billing. Both apps are event-driven (SB triggers + timer) with bursty load.
resource planProc 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planProcName
  location: location
  tags:     tags
  sku: { tier: 'FlexConsumption', name: 'FC1' }
  kind: 'functionapp'
  properties: { reserved: true }
}
resource planWipe 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planWipeName
  location: location
  tags:     tags
  sku: { tier: 'FlexConsumption', name: 'FC1' }
  kind: 'functionapp'
  properties: { reserved: true }
}

// ─────────────────────────────────────────────────────────────────────────────
// Public Function App (web): hosts ActionRequest + ActionStatus + ActionLedger.
// mTLS terminated by App Service. Identity has NO Graph permissions; the
// only data-plane writes outside its own storage are: SB Sender on
// action-requests + Blob Data Contributor on the ledger container + Table
// Data Contributor on the shared audit/status tables.
// ─────────────────────────────────────────────────────────────────────────────
resource funcWeb 'Microsoft.Web/sites@2023-12-01' = {
  name: webName
  location: location
  tags:     tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uamiWeb.id}': {} }
  }
  properties: {
    serverFarmId: planWeb.id
    httpsOnly: true
    clientCertEnabled: true
    clientCertMode: 'Required'
    // SECURITY: no clientCertExclusionPaths — every route (including the
    // operator-only /api/actions/ledger admin surface) must present a valid
    // client certificate. The admin surface additionally requires the caller
    // thumbprint to be in Idempotency:AdminCertThumbprints (see
    // ActionLedgerAdminFunction). The previous configuration excluded the
    // ledger path from mTLS, leaving function-key-only auth on a destructive
    // surface — fixed for banking-grade compliance (separation of duties).
    keyVaultReferenceIdentity: uamiWeb.id
    // Public variant: NO VNet integration. Storage is reachable directly via
    // its public endpoint (publicNetworkAccess='Enabled',
    // networkAcls.defaultAction='Allow'). All outbound (Storage / Graph /
    // Service Bus / App Config / App Insights) leaves on App Service public
    // IPs. Use main.bicep if you require Private Endpoints, NAT Gateway with
    // stable SNAT, and full VNet isolation.
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      linuxFxVersion: 'DOTNET-ISOLATED|10.0'
      scmIpSecurityRestrictionsUseMain: true
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',    value: 'dotnet-isolated' }
        { name: 'WEBSITE_RUN_FROM_PACKAGE',    value: '1' }
        { name: 'AzureWebJobsStorage__accountName', value: storageWeb.name }
        { name: 'AzureWebJobsStorage__credential',  value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId',    value: uamiWeb.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: ai.properties.ConnectionString }
        { name: 'AZURE_CLIENT_ID', value: uamiWeb.properties.clientId }
        { name: 'AppConfig__Endpoint', value: appConfig.properties.endpoint }
        { name: 'App__Role', value: 'web' }
        // Service Bus (MI auth, namespace-scoped FQDN, Sender on action-requests only).
        { name: 'ServiceBus__fullyQualifiedNamespace', value: '${sbNamespace.name}.servicebus.windows.net' }
        { name: 'ServiceBus__credential',              value: 'managedidentity' }
        { name: 'ServiceBus__clientId',                value: uamiWeb.properties.clientId }
        { name: 'ServiceBus__ActionRequestsQueue',     value: actionRequestsQueueName }
        // Audit + action status tables on the proc storage account.
        { name: 'Audit__StorageAccount',     value: storageProc.name }
        { name: 'Audit__TableName',          value: auditTableName }
        { name: 'ActionStatus__TableName',   value: actionStatusTableName }
        // Idempotency ledger access (web reads/resets via admin endpoints).
        { name: 'Idempotency__StorageAccount',          value: storageProc.name }
        { name: 'Idempotency__BlobContainer',           value: ledgerContainerName }
        { name: 'Idempotency__AllowForceRearm',         value: string(idempotencyAllowForceRearm) }
        { name: 'Idempotency__AdminApiEnabled',         value: string(idempotencyAdminApiEnabled) }
        { name: 'Idempotency__MaxActionsPerDevicePerDay', value: string(idempotencyMaxActionsPerDay) }
        { name: 'Idempotency__RearmGracePeriodHours',   value: string(idempotencyRearmGracePeriodHours) }
        // GraphWipeService is pulled in transitively via the admin endpoint resolver.
        { name: 'Wipe__AllowedGroupId',     value: allowedGroupId }
        { name: 'Wipe__KeepEnrollmentData', value: string(keepEnrollmentData) }
        { name: 'Wipe__KeepUserData',       value: string(keepUserData) }
        { name: 'ClientCert__TrustedCaThumbprints',           value: trustedCaThumbprints }
        { name: 'ClientCert__TrustedRootCertificates',        value: trustedRootCertificatesBase64 }
        { name: 'ClientCert__TrustedIntermediateCertificates', value: trustedIntermediateCertificatesBase64 }
        { name: 'ClientCert__TrustedCaCertificates',          value: trustedCaCertificatesBase64 }
        { name: 'ClientCert__AllowedLeafThumbprints',  value: allowedLeafThumbprints }
        { name: 'ClientCert__CheckRevocation',         value: string(checkRevocation) }
        { name: 'ClientCert__RevocationMode',          value: revocationMode }
        { name: 'ClientCert__RevocationFlag',          value: revocationFlag }
        { name: 'ClientCert__RequireClientAuthEku',    value: string(requireClientAuthEku) }
        { name: 'ClientCert__RequireClientCert',       value: 'true' }
        { name: 'ClientCert__TrustForwardedHeader',    value: 'true' }
        { name: 'ClientCert__DeviceIdBindingClaim',    value: deviceIdBindingClaim }
        { name: 'ClientCert__ThumbprintToDeviceMap',   value: clientCertThumbprintToDeviceMap }
        { name: 'Replay__MaxTimestampSkewSeconds',     value: string(maxTimestampSkewSeconds) }
      ]
    }
  }
  // Force role assignments to be created (and start propagating) BEFORE the
  // Function App is provisioned. Mitigates the cold-boot RBAC race where the
  // app tries to read AppConfig / send to SB before its UAMI has the role.
  // NOTE: still pair with a 60-120s wait + app restart in Phase D.
  dependsOn: [
    raWebBlob
    raWebTable
    raWebTableOnProc
    raWebLedger
    raWebSbSendRequests
    raAppConfigWeb
  ]
}

// ─────────────────────────────────────────────────────────────────────────────
// Dispatcher Function App (proc): Flex Consumption.
// Hosts RequestIntake (SB trigger) + ActionDispatch (SB trigger, router) +
// ActionStatusPoller (timer). Forwards 'wipe' via WipeForwardingRunner to
// the wipe-action queue. NO Graph permissions.
// ─────────────────────────────────────────────────────────────────────────────
resource funcProc 'Microsoft.Web/sites@2023-12-01' = {
  name: procName
  location: location
  tags:     tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uami.id}': {} }
  }
  properties: {
    serverFarmId: planProc.id
    httpsOnly: true
    keyVaultReferenceIdentity: uami.id
    // Flex Consumption VNet integration. proc-flex-subnet is delegated to
    // Microsoft.App/environments. Flex always routes ALL outbound through
    // the VNet when integrated, so Graph / Service Bus / AppConfig / App
    // Insights egress through the NAT Gateway on this subnet → 1 static
    // public IP. Storage hits the blob PE via the linked private DNS zone.
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageProc.properties.primaryEndpoints.blob}${procDeployContainer}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: uami.id
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
        // Flex Consumption per-function scaler does NOT auto-register Service
        // Bus triggers that authenticate via managed identity. Without an
        // alwaysReady entry the SB listener is never created and queue
        // messages pile up. Names must be 'function:<lowercase-name>'.
        alwaysReady: [
          { name: 'function:requestintake',  instanceCount: 1 }
          { name: 'function:actiondispatch', instanceCount: 1 }
        ]
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storageProc.name }
        { name: 'AzureWebJobsStorage__credential',  value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId',    value: uami.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: ai.properties.ConnectionString }
        { name: 'AZURE_CLIENT_ID', value: uami.properties.clientId }
        { name: 'AppConfig__Endpoint', value: appConfig.properties.endpoint }
        { name: 'App__Role', value: 'proc' }
        // Service Bus (MI auth) — Receiver action-requests + Sender/Receiver action-dispatch + Sender wipe-action.
        { name: 'ServiceBus__fullyQualifiedNamespace', value: '${sbNamespace.name}.servicebus.windows.net' }
        { name: 'ServiceBus__credential',              value: 'managedidentity' }
        { name: 'ServiceBus__clientId',                value: uami.properties.clientId }
        { name: 'ServiceBus__ActionRequestsQueue',     value: actionRequestsQueueName }
        { name: 'ServiceBus__ActionDispatchQueue',     value: actionDispatchQueueName }
        { name: 'ServiceBus__WipeActionQueue',         value: wipeActionQueueName }
        { name: 'ServiceBus__AutopilotActionQueue',    value: autopilotActionQueueName }
        { name: 'ServiceBus__BitLockerActionQueue',    value: bitlockerActionQueueName }
        { name: 'ServiceBus__RenameActionQueue',       value: renameActionQueueName }
        { name: 'ActionStatus__TableName',             value: actionStatusTableName }
        { name: 'ActionStatus__PollMaxAgeHours',       value: string(actionStatusPollMaxAgeHours) }
        { name: 'ActionStatusPoller__CronExpression',  value: actionStatusPollerCron }
        // Idempotency ledger (Proc reads/queries but does NOT reserve here).
        { name: 'Idempotency__BlobContainer',           value: ledgerContainerName }
        { name: 'Idempotency__StorageAccount',          value: storageProc.name }
        { name: 'Idempotency__AllowForceRearm',         value: string(idempotencyAllowForceRearm) }
        { name: 'Idempotency__AdminApiEnabled',         value: string(idempotencyAdminApiEnabled) }
        { name: 'Idempotency__MaxActionsPerDevicePerDay', value: string(idempotencyMaxActionsPerDay) }
        { name: 'Idempotency__RearmGracePeriodHours',   value: string(idempotencyRearmGracePeriodHours) }
        // Audit (dual-write).
        { name: 'Audit__StorageAccount', value: storageProc.name }
        { name: 'Audit__TableName',      value: auditTableName }
        // Status poller calls Graph managedDeviceActions (Read.All only — no /wipe).
        { name: 'Graph__TenantId',                value: graphTenantId }
        { name: 'Graph__ManagedIdentityClientId', value: uami.properties.clientId }
        { name: 'Wipe__AllowedGroupId',     value: allowedGroupId }
        { name: 'Wipe__KeepEnrollmentData', value: string(keepEnrollmentData) }
        { name: 'Wipe__KeepUserData',       value: string(keepUserData) }
      ]
    }
  }
  // Same RBAC race mitigation as funcWeb. Proc needs Blob/Queue/Table on its
  // own storage, SB receiver+sender on 3 queues, AppConfig reader, and the
  // Flex deployment-container Blob role before its first cold start.
  dependsOn: [
    raProcBlob
    raProcQueue
    raProcTable
    raProcSbRecvRequests
    raProcSbSendDispatch
    raProcSbRecvDispatch
    raProcSbSendWipe
    raProcSbSendAutopilot
    raProcSbSendBitLocker
    raProcDeploy
    raAppConfigProc
  ]
}

// ─────────────────────────────────────────────────────────────────────────────
// Privileged Wipe Function App: Flex Consumption.
// Hosts ONLY WipeActionConsumer (SB trigger). After deployment grant
// uamiWipe these Graph application permissions:
//   DeviceManagementManagedDevices.PrivilegedOperations.All
//   DeviceManagementManagedDevices.Read.All
//   Device.Read.All
//   GroupMember.Read.All
// (See README post-deploy script.)
// ─────────────────────────────────────────────────────────────────────────────
resource funcWipe 'Microsoft.Web/sites@2023-12-01' = {
  name: wipeName
  location: location
  tags:     tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uamiWipe.id}': {} }
  }
  properties: {
    serverFarmId: planWipe.id
    httpsOnly: true
    keyVaultReferenceIdentity: uamiWipe.id
    // Flex Consumption VNet integration. wipe-flex-subnet is delegated to
    // Microsoft.App/environments and shares the NAT Gateway with proc-flex
    // for stable SNAT to Graph (wipe is the heaviest Graph consumer).
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageWipe.properties.primaryEndpoints.blob}${wipeDeployContainer}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: uamiWipe.id
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
        // See Proc app note: SB+MI trigger requires an alwaysReady entry.
        alwaysReady: [
          { name: 'function:wipeaction', instanceCount: 1 }
        ]
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storageWipe.name }
        { name: 'AzureWebJobsStorage__credential',  value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId',    value: uamiWipe.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: ai.properties.ConnectionString }
        { name: 'AZURE_CLIENT_ID', value: uamiWipe.properties.clientId }
        { name: 'AppConfig__Endpoint', value: appConfig.properties.endpoint }
        { name: 'App__Role', value: 'wipe' }
        // Service Bus (MI auth) — Receiver on wipe-action only.
        { name: 'ServiceBus__fullyQualifiedNamespace', value: '${sbNamespace.name}.servicebus.windows.net' }
        { name: 'ServiceBus__credential',              value: 'managedidentity' }
        { name: 'ServiceBus__clientId',                value: uamiWipe.properties.clientId }
        { name: 'ServiceBus__WipeActionQueue',         value: wipeActionQueueName }
        // Idempotency ledger (Reserve/MarkIssued executed by WipeActionRunner here).
        { name: 'Idempotency__BlobContainer',           value: ledgerContainerName }
        { name: 'Idempotency__StorageAccount',          value: storageProc.name }
        { name: 'Idempotency__AllowForceRearm',         value: string(idempotencyAllowForceRearm) }
        { name: 'Idempotency__AdminApiEnabled',         value: 'false' }
        { name: 'Idempotency__MaxActionsPerDevicePerDay', value: string(idempotencyMaxActionsPerDay) }
        { name: 'Idempotency__RearmGracePeriodHours',   value: string(idempotencyRearmGracePeriodHours) }
        // Audit + action status tables shared.
        { name: 'Audit__StorageAccount',   value: storageProc.name }
        { name: 'Audit__TableName',        value: auditTableName }
        { name: 'ActionStatus__TableName',   value: actionStatusTableName }
        { name: 'ActionStatus__PollMaxAgeHours', value: string(actionStatusPollMaxAgeHours) }
        // Microsoft Graph wipe call (privileged).
        { name: 'Graph__TenantId',                value: graphTenantId }
        { name: 'Graph__ManagedIdentityClientId', value: uamiWipe.properties.clientId }
        { name: 'Wipe__AllowedGroupId',     value: allowedGroupId }
        { name: 'Wipe__KeepEnrollmentData', value: string(keepEnrollmentData) }
        { name: 'Wipe__KeepUserData',       value: string(keepUserData) }
      ]
    }
  }
  // Same RBAC race mitigation. Wipe needs Blob/Table on its own storage,
  // Blob Owner on the ledger container (Reserve/MarkIssued writes), Table
  // contributor on storageProc (action-status table is on Proc storage), SB
  // receiver on wipe-action, AppConfig reader, and Flex deployment container.
  dependsOn: [
    raWipeBlob
    raWipeTable
    raWipeLedger
    raWipeTableOnProc
    raWipeSbRecv
    raWipeDeploy
    raAppConfigWipe
  ]
}

// ─────────────────────────────────────────────────────────────────────────────
// RBAC
// ─────────────────────────────────────────────────────────────────────────────
var blobDataOwner          = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var blobDataContributor    = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var queueDataContributor   = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
var tableDataContributor   = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
var sbDataSender           = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39')
var sbDataReceiver         = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0')

// ── Proc UAMI → full data-plane on its own storage (Functions host) ─────────
resource raProcBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageProc.id, uami.id, 'blob')
  scope: storageProc
  properties: { roleDefinitionId: blobDataOwner, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raProcQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageProc.id, uami.id, 'queue')
  scope: storageProc
  properties: { roleDefinitionId: queueDataContributor, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raProcTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageProc.id, uami.id, 'table')
  scope: storageProc
  properties: { roleDefinitionId: tableDataContributor, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}

// ── Web UAMI → full data-plane on its own runtime storage ───────────────────
resource raWebBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageWeb.id, uamiWeb.id, 'blob')
  scope: storageWeb
  properties: { roleDefinitionId: blobDataOwner, principalId: uamiWeb.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raWebQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageWeb.id, uamiWeb.id, 'queue')
  scope: storageWeb
  properties: { roleDefinitionId: queueDataContributor, principalId: uamiWeb.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raWebTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageWeb.id, uamiWeb.id, 'table')
  scope: storageWeb
  properties: { roleDefinitionId: tableDataContributor, principalId: uamiWeb.properties.principalId, principalType: 'ServicePrincipal' }
}
// Audit dual-write needs cross-account table access to storageProc.
resource raWebTableOnProc 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageProc.id, uamiWeb.id, 'table-audit')
  scope: storageProc
  properties: { roleDefinitionId: tableDataContributor, principalId: uamiWeb.properties.principalId, principalType: 'ServicePrincipal' }
}
// Admin ledger endpoints — container-scoped (least privilege).
resource raWebLedger 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ledgerContainer.id, uamiWeb.id, 'blob-ledger')
  scope: ledgerContainer
  properties: { roleDefinitionId: blobDataContributor, principalId: uamiWeb.properties.principalId, principalType: 'ServicePrincipal' }
}

// ── Wipe UAMI → full data-plane on its own runtime storage ──────────────────
resource raWipeBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageWipe.id, uamiWipe.id, 'blob')
  scope: storageWipe
  properties: { roleDefinitionId: blobDataOwner, principalId: uamiWipe.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raWipeQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageWipe.id, uamiWipe.id, 'queue')
  scope: storageWipe
  properties: { roleDefinitionId: queueDataContributor, principalId: uamiWipe.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raWipeTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageWipe.id, uamiWipe.id, 'table')
  scope: storageWipe
  properties: { roleDefinitionId: tableDataContributor, principalId: uamiWipe.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raWipeLedger 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ledgerContainer.id, uamiWipe.id, 'blob-ledger')
  scope: ledgerContainer
  properties: { roleDefinitionId: blobDataContributor, principalId: uamiWipe.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raWipeTableOnProc 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageProc.id, uamiWipe.id, 'table-shared')
  scope: storageProc
  properties: { roleDefinitionId: tableDataContributor, principalId: uamiWipe.properties.principalId, principalType: 'ServicePrincipal' }
}

// ── Flex Consumption deployment-container access (per-app, container-scoped) ─
resource raProcDeploy 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(procDeployBlobContainer.id, uami.id, 'flex-deploy')
  scope: procDeployBlobContainer
  properties: { roleDefinitionId: blobDataContributor, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raWipeDeploy 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(wipeDeployBlobContainer.id, uamiWipe.id, 'flex-deploy')
  scope: wipeDeployBlobContainer
  properties: { roleDefinitionId: blobDataContributor, principalId: uamiWipe.properties.principalId, principalType: 'ServicePrincipal' }
}

// ── Service Bus RBAC (queue-scoped, least privilege) ─────────────────────────
// Web → Sender on action-requests only.
resource raWebSbSendRequests 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbQueueActionRequests.id, uamiWeb.id, 'sb-send')
  scope: sbQueueActionRequests
  properties: { roleDefinitionId: sbDataSender, principalId: uamiWeb.properties.principalId, principalType: 'ServicePrincipal' }
}

// Proc → Receiver on action-requests, Sender+Receiver on action-dispatch, Sender on wipe-action.
resource raProcSbRecvRequests 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbQueueActionRequests.id, uami.id, 'sb-recv')
  scope: sbQueueActionRequests
  properties: { roleDefinitionId: sbDataReceiver, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raProcSbSendDispatch 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbQueueActionDispatch.id, uami.id, 'sb-send')
  scope: sbQueueActionDispatch
  properties: { roleDefinitionId: sbDataSender, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raProcSbRecvDispatch 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbQueueActionDispatch.id, uami.id, 'sb-recv')
  scope: sbQueueActionDispatch
  properties: { roleDefinitionId: sbDataReceiver, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raProcSbSendWipe 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbQueueWipeAction.id, uami.id, 'sb-send')
  scope: sbQueueWipeAction
  properties: { roleDefinitionId: sbDataSender, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}

// Wipe → Receiver on wipe-action only.
resource raWipeSbRecv 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbQueueWipeAction.id, uamiWipe.id, 'sb-recv')
  scope: sbQueueWipeAction
  properties: { roleDefinitionId: sbDataReceiver, principalId: uamiWipe.properties.principalId, principalType: 'ServicePrincipal' }
}

// ─────────────────────────────────────────────────────────────────────────────
// Optional: Azure Automation Account + PowerShell 7.2 runbook variant
// (plug-in demo — same envelope, different runtime).
// ─────────────────────────────────────────────────────────────────────────────
var automationAccountName = toLower('${namePrefix}-aa${sep}${suffix}')
var runbookName           = 'Invoke-DeviceWipe'

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = if (enableRunbookVariant) {
  name: automationAccountName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    sku: { name: 'Basic' }
    publicNetworkAccess: true
    disableLocalAuth: false
  }
}

resource aaVarLedgerStorage 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'LedgerStorageAccount'
  properties: { isEncrypted: false, value: '"${storageProc.name}"' }
}
resource aaVarLedgerContainer 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'LedgerContainer'
  properties: { isEncrypted: false, value: '"${ledgerContainerName}"' }
}
resource aaVarAuditStorage 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'AuditStorageAccount'
  properties: { isEncrypted: false, value: '"${storageProc.name}"' }
}
resource aaVarAuditTable 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'AuditTableName'
  properties: { isEncrypted: false, value: '"${auditTableName}"' }
}
resource aaVarKeepEnrollment 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'KeepEnrollmentData'
  properties: { isEncrypted: false, value: keepEnrollmentData ? 'true' : 'false' }
}
resource aaVarKeepUser 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'KeepUserData'
  properties: { isEncrypted: false, value: keepUserData ? 'true' : 'false' }
}

resource aaVarStatusStorage 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'StatusStorageAccount'
  properties: { isEncrypted: false, value: '"${storageProc.name}"' }
}
resource aaVarStatusTable 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'StatusTableName'
  properties: { isEncrypted: false, value: '"${actionStatusTableName}"' }
}
resource aaVarAllowedGroup 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'AllowedGroupId'
  properties: { isEncrypted: false, value: '"${allowedGroupId}"' }
}
resource aaVarBitLockerGroup 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'BitLockerAllowedGroupId'
  properties: { isEncrypted: false, value: '"${bitlockerAllowedGroupId}"' }
}
resource aaVarMaxActions 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'MaxActionsPerDevicePerDay'
  properties: { isEncrypted: false, value: '"5"' }
}

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: runbookName
  location: location
  properties: {
    runbookType: 'PowerShell72'
    logVerbose: true
    logProgress: true
    description: 'Alternative wipe executor (demo plug-in variant). Same envelope as WipeActionConsumerFunction.'
  }
}

// ── Runbook plug-in variants for autopilot-register and bitlocker-rotate ────
// Same demo intent as the wipe runbook: prove that any capability in the
// capability-plugin architecture can be implemented on a different runtime
// (Azure Automation PowerShell 7.2) without touching the core router or
// Service Bus topology. Content is published out-of-band by
// tools/Deploy-IntuneDeviceActions.ps1 via `az automation runbook
// replace-content` + `publish` so the Bicep stays storage-account-free.
resource runbookAutopilot 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'Invoke-AutopilotRegister'
  location: location
  properties: {
    runbookType: 'PowerShell72'
    logVerbose: true
    logProgress: true
    description: 'Alternative autopilot-register executor (demo plug-in variant). Same envelope as AutopilotRegisterRunner.'
  }
}

resource runbookBitLocker 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'Invoke-RotateBitLockerKey'
  location: location
  properties: {
    runbookType: 'PowerShell72'
    logVerbose: true
    logProgress: true
    description: 'Alternative bitlocker-rotate executor (demo plug-in variant). Same envelope as BitLockerRotateRunner.'
  }
}

resource runbookRename 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'Invoke-DeviceRename'
  location: location
  properties: {
    runbookType: 'PowerShell72'
    logVerbose: true
    logProgress: true
    description: 'Alternative device-rename executor (demo plug-in variant). Same envelope as RenameActionRunner; LOOKUP customer CMDB + Entra collision check + Graph setDeviceName.'
  }
}

resource aaVarRenameEndpoint 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'Rename:Endpoint'
  properties: { isEncrypted: false, value: '"${renameEndpoint}"' }
}
resource aaVarRenameAuthHeaderName 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'Rename:AuthHeaderName'
  properties: { isEncrypted: false, value: '"${renameAuthHeaderName}"' }
}
resource aaVarRenameAuthHeaderValue 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'Rename:AuthHeaderValue'
  properties: { isEncrypted: true, value: '""' }
}
resource aaVarRenameNewNameJsonPath 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'Rename:NewNameJsonPath'
  properties: { isEncrypted: false, value: '"${renameNewNameJsonPath}"' }
}
resource aaVarRenameOnCollision 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = if (enableRunbookVariant) {
  parent: automationAccount
  name: 'Rename:OnCollision'
  properties: { isEncrypted: false, value: '"${renameOnCollision}"' }
}

resource raAaLedger 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableRunbookVariant) {
  name: guid(ledgerContainer.id, automationAccount.id, 'aa-blob-ledger')
  scope: ledgerContainer
  properties: { roleDefinitionId: blobDataContributor, principalId: automationAccount.identity.principalId, principalType: 'ServicePrincipal' }
}
resource raAaTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableRunbookVariant) {
  name: guid(storageProc.id, automationAccount.id, 'aa-table')
  scope: storageProc
  properties: { roleDefinitionId: tableDataContributor, principalId: automationAccount.identity.principalId, principalType: 'ServicePrincipal' }
}

// ─────────────────────────────────────────────────────────────────────────────
// Azure App Configuration — centralized config store for all 3 Function Apps
// ─────────────────────────────────────────────────────────────────────────────
resource appConfig 'Microsoft.AppConfiguration/configurationStores@2024-05-01' = {
  name: appConfigName
  location: location
  tags:     tags
  sku: { name: 'standard' }
  properties: {
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    enablePurgeProtection: false
    dataPlaneProxy: {
      authenticationMode: 'Pass-through'
      privateLinkDelegation: 'Disabled'
    }
  }
}

var appConfigDataReader = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '516239f1-63e1-4d78-a4de-a74fb236a071')

resource raAppConfigWeb 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appConfig.id, uamiWeb.id, 'appcfg-reader')
  scope: appConfig
  properties: { roleDefinitionId: appConfigDataReader, principalId: uamiWeb.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raAppConfigProc 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appConfig.id, uami.id, 'appcfg-reader')
  scope: appConfig
  properties: { roleDefinitionId: appConfigDataReader, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raAppConfigWipe 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appConfig.id, uamiWipe.id, 'appcfg-reader')
  scope: appConfig
  properties: { roleDefinitionId: appConfigDataReader, principalId: uamiWipe.properties.principalId, principalType: 'ServicePrincipal' }
}

// ═════════════════════════════════════════════════════════════════════════════
// Additive privileged capabilities: Autopilot self-registration + BitLocker
// recovery-key rotation. Each mirrors the Wipe capability (dedicated UAMI with
// its own minimal Graph consent, dedicated FC1 Flex app, dedicated per-capability
// Service Bus queue). The shared VNet /24 is fully allocated, so these two Flex
// apps run WITHOUT VNet integration: their storage uses networkAcls
// defaultAction='Allow' (publicNetworkAccess='Enabled', no private endpoint),
// which is the operationally-proven config for Flex + MI storage access. They
// egress to Graph via dynamic platform IPs (not the NAT GW static IP) — accepted
// for these non-destructive admin actions.
// ═════════════════════════════════════════════════════════════════════════════

// ── Storage (Allow — no VNet integration) ────────────────────────────────────
resource storageAutopilot 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: stAplName
  location: location
  tags:     tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices, Logging, Metrics'
    }
  }
}
resource blobSvcAutopilot 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAutopilot
  name: 'default'
}
resource autopilotDeployBlobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobSvcAutopilot
  name: autopilotDeployContainer
  properties: { publicAccess: 'None' }
}

resource storageBitLocker 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: stBlkName
  location: location
  tags:     tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices, Logging, Metrics'
    }
  }
}
resource blobSvcBitLocker 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageBitLocker
  name: 'default'
}
resource bitlockerDeployBlobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobSvcBitLocker
  name: bitlockerDeployContainer
  properties: { publicAccess: 'None' }
}

resource storageRename 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: stRnName
  location: location
  tags:     tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices, Logging, Metrics'
    }
  }
}
resource blobSvcRename 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageRename
  name: 'default'
}
resource renameDeployBlobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobSvcRename
  name: renameDeployContainer
  properties: { publicAccess: 'None' }
}

// ── Dedicated privileged UAMIs (isolated Graph consent per capability) ────────
// uamiAutopilot Graph permissions: DeviceManagementServiceConfig.ReadWrite.All,
//   DeviceManagementManagedDevices.Read.All, Device.Read.All, GroupMember.Read.All
// uamiBitLocker Graph permissions: DeviceManagementManagedDevices.PrivilegedOperations.All,
//   DeviceManagementManagedDevices.Read.All, Device.Read.All, GroupMember.Read.All
// (Granted on the app registration post-deploy, NOT in Bicep.)
resource uamiAutopilot 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiAutopilotName
  location: location
  tags:     tags
}
resource uamiBitLocker 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiBitLockerName
  location: location
  tags:     tags
}
resource uamiRename 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiRenameName
  location: location
  tags:     tags
}

// ── FC1 Flex plans ───────────────────────────────────────────────────────────
resource planAutopilot 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planAutopilotName
  location: location
  tags:     tags
  sku: { tier: 'FlexConsumption', name: 'FC1' }
  kind: 'functionapp'
  properties: { reserved: true }
}
resource planBitLocker 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planBitLockerName
  location: location
  tags:     tags
  sku: { tier: 'FlexConsumption', name: 'FC1' }
  kind: 'functionapp'
  properties: { reserved: true }
}
resource planRename 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planRenameName
  location: location
  tags:     tags
  sku: { tier: 'FlexConsumption', name: 'FC1' }
  kind: 'functionapp'
  properties: { reserved: true }
}

// ── Role assignments: Autopilot app ──────────────────────────────────────────
resource raAutopilotBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAutopilot.id, uamiAutopilot.id, 'blob')
  scope: storageAutopilot
  properties: { roleDefinitionId: blobDataOwner, principalId: uamiAutopilot.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raAutopilotTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAutopilot.id, uamiAutopilot.id, 'table')
  scope: storageAutopilot
  properties: { roleDefinitionId: tableDataContributor, principalId: uamiAutopilot.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raAutopilotLedger 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ledgerContainer.id, uamiAutopilot.id, 'blob-ledger')
  scope: ledgerContainer
  properties: { roleDefinitionId: blobDataContributor, principalId: uamiAutopilot.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raAutopilotTableOnProc 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageProc.id, uamiAutopilot.id, 'table-shared')
  scope: storageProc
  properties: { roleDefinitionId: tableDataContributor, principalId: uamiAutopilot.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raAutopilotSbRecv 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbQueueAutopilotAction.id, uamiAutopilot.id, 'sb-recv')
  scope: sbQueueAutopilotAction
  properties: { roleDefinitionId: sbDataReceiver, principalId: uamiAutopilot.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raAutopilotDeploy 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(autopilotDeployBlobContainer.id, uamiAutopilot.id, 'flex-deploy')
  scope: autopilotDeployBlobContainer
  properties: { roleDefinitionId: blobDataContributor, principalId: uamiAutopilot.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raAppConfigAutopilot 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appConfig.id, uamiAutopilot.id, 'appcfg-reader')
  scope: appConfig
  properties: { roleDefinitionId: appConfigDataReader, principalId: uamiAutopilot.properties.principalId, principalType: 'ServicePrincipal' }
}

// ── Role assignments: BitLocker app ──────────────────────────────────────────
resource raBitLockerBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageBitLocker.id, uamiBitLocker.id, 'blob')
  scope: storageBitLocker
  properties: { roleDefinitionId: blobDataOwner, principalId: uamiBitLocker.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raBitLockerTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageBitLocker.id, uamiBitLocker.id, 'table')
  scope: storageBitLocker
  properties: { roleDefinitionId: tableDataContributor, principalId: uamiBitLocker.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raBitLockerLedger 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ledgerContainer.id, uamiBitLocker.id, 'blob-ledger')
  scope: ledgerContainer
  properties: { roleDefinitionId: blobDataContributor, principalId: uamiBitLocker.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raBitLockerTableOnProc 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageProc.id, uamiBitLocker.id, 'table-shared')
  scope: storageProc
  properties: { roleDefinitionId: tableDataContributor, principalId: uamiBitLocker.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raBitLockerSbRecv 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbQueueBitLockerAction.id, uamiBitLocker.id, 'sb-recv')
  scope: sbQueueBitLockerAction
  properties: { roleDefinitionId: sbDataReceiver, principalId: uamiBitLocker.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raBitLockerDeploy 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(bitlockerDeployBlobContainer.id, uamiBitLocker.id, 'flex-deploy')
  scope: bitlockerDeployBlobContainer
  properties: { roleDefinitionId: blobDataContributor, principalId: uamiBitLocker.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raAppConfigBitLocker 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appConfig.id, uamiBitLocker.id, 'appcfg-reader')
  scope: appConfig
  properties: { roleDefinitionId: appConfigDataReader, principalId: uamiBitLocker.properties.principalId, principalType: 'ServicePrincipal' }
}

// ── Role assignments: Rename app ─────────────────────────────────────────────
resource raRenameBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageRename.id, uamiRename.id, 'blob')
  scope: storageRename
  properties: { roleDefinitionId: blobDataOwner, principalId: uamiRename.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raRenameTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageRename.id, uamiRename.id, 'table')
  scope: storageRename
  properties: { roleDefinitionId: tableDataContributor, principalId: uamiRename.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raRenameLedger 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ledgerContainer.id, uamiRename.id, 'blob-ledger')
  scope: ledgerContainer
  properties: { roleDefinitionId: blobDataContributor, principalId: uamiRename.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raRenameTableOnProc 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageProc.id, uamiRename.id, 'table-shared')
  scope: storageProc
  properties: { roleDefinitionId: tableDataContributor, principalId: uamiRename.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raRenameSbRecv 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbQueueRenameAction.id, uamiRename.id, 'sb-recv')
  scope: sbQueueRenameAction
  properties: { roleDefinitionId: sbDataReceiver, principalId: uamiRename.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raRenameDeploy 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(renameDeployBlobContainer.id, uamiRename.id, 'flex-deploy')
  scope: renameDeployBlobContainer
  properties: { roleDefinitionId: blobDataContributor, principalId: uamiRename.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raAppConfigRename 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appConfig.id, uamiRename.id, 'appcfg-reader')
  scope: appConfig
  properties: { roleDefinitionId: appConfigDataReader, principalId: uamiRename.properties.principalId, principalType: 'ServicePrincipal' }
}

// ── Proc → Service Bus Sender on the new per-capability queues ────────────────
resource raProcSbSendAutopilot 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbQueueAutopilotAction.id, uami.id, 'sb-send')
  scope: sbQueueAutopilotAction
  properties: { roleDefinitionId: sbDataSender, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raProcSbSendBitLocker 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbQueueBitLockerAction.id, uami.id, 'sb-send')
  scope: sbQueueBitLockerAction
  properties: { roleDefinitionId: sbDataSender, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raProcSbSendRename 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbQueueRenameAction.id, uami.id, 'sb-send')
  scope: sbQueueRenameAction
  properties: { roleDefinitionId: sbDataSender, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}

// ── Autopilot Function App (privileged, no VNet) ─────────────────────────────
resource funcAutopilot 'Microsoft.Web/sites@2023-12-01' = {
  name: autopilotName
  location: location
  tags:     tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uamiAutopilot.id}': {} }
  }
  properties: {
    serverFarmId: planAutopilot.id
    httpsOnly: true
    keyVaultReferenceIdentity: uamiAutopilot.id
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAutopilot.properties.primaryEndpoints.blob}${autopilotDeployContainer}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: uamiAutopilot.id
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
        // See Proc app note: SB+MI trigger requires an alwaysReady entry.
        alwaysReady: [
          { name: 'function:autopilotaction', instanceCount: 1 }
        ]
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storageAutopilot.name }
        { name: 'AzureWebJobsStorage__credential',  value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId',    value: uamiAutopilot.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: ai.properties.ConnectionString }
        { name: 'AZURE_CLIENT_ID', value: uamiAutopilot.properties.clientId }
        { name: 'AppConfig__Endpoint', value: appConfig.properties.endpoint }
        { name: 'App__Role', value: 'autopilot' }
        { name: 'ServiceBus__fullyQualifiedNamespace', value: '${sbNamespace.name}.servicebus.windows.net' }
        { name: 'ServiceBus__credential',              value: 'managedidentity' }
        { name: 'ServiceBus__clientId',                value: uamiAutopilot.properties.clientId }
        { name: 'ServiceBus__AutopilotActionQueue',    value: autopilotActionQueueName }
        { name: 'Idempotency__BlobContainer',           value: ledgerContainerName }
        { name: 'Idempotency__StorageAccount',          value: storageProc.name }
        { name: 'Idempotency__AllowForceRearm',         value: string(idempotencyAllowForceRearm) }
        { name: 'Idempotency__AdminApiEnabled',         value: 'false' }
        { name: 'Idempotency__MaxActionsPerDevicePerDay', value: string(idempotencyMaxActionsPerDay) }
        { name: 'Idempotency__RearmGracePeriodHours',   value: string(idempotencyRearmGracePeriodHours) }
        { name: 'Audit__StorageAccount',   value: storageProc.name }
        { name: 'Audit__TableName',        value: auditTableName }
        { name: 'ActionStatus__TableName',   value: actionStatusTableName }
        { name: 'ActionStatus__PollMaxAgeHours', value: string(actionStatusPollMaxAgeHours) }
        { name: 'Graph__TenantId',                value: graphTenantId }
        { name: 'Graph__ManagedIdentityClientId', value: uamiAutopilot.properties.clientId }
      ]
    }
  }
  dependsOn: [
    raAutopilotBlob
    raAutopilotTable
    raAutopilotLedger
    raAutopilotTableOnProc
    raAutopilotSbRecv
    raAutopilotDeploy
    raAppConfigAutopilot
  ]
}

// ── BitLocker Function App (privileged, no VNet) ─────────────────────────────
resource funcBitLocker 'Microsoft.Web/sites@2023-12-01' = {
  name: bitlockerName
  location: location
  tags:     tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uamiBitLocker.id}': {} }
  }
  properties: {
    serverFarmId: planBitLocker.id
    httpsOnly: true
    keyVaultReferenceIdentity: uamiBitLocker.id
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageBitLocker.properties.primaryEndpoints.blob}${bitlockerDeployContainer}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: uamiBitLocker.id
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
        // See Proc app note: SB+MI trigger requires an alwaysReady entry.
        alwaysReady: [
          { name: 'function:bitlockeraction', instanceCount: 1 }
        ]
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storageBitLocker.name }
        { name: 'AzureWebJobsStorage__credential',  value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId',    value: uamiBitLocker.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: ai.properties.ConnectionString }
        { name: 'AZURE_CLIENT_ID', value: uamiBitLocker.properties.clientId }
        { name: 'AppConfig__Endpoint', value: appConfig.properties.endpoint }
        { name: 'App__Role', value: 'bitlocker' }
        { name: 'ServiceBus__fullyQualifiedNamespace', value: '${sbNamespace.name}.servicebus.windows.net' }
        { name: 'ServiceBus__credential',              value: 'managedidentity' }
        { name: 'ServiceBus__clientId',                value: uamiBitLocker.properties.clientId }
        { name: 'ServiceBus__BitLockerActionQueue',    value: bitlockerActionQueueName }
        { name: 'Idempotency__BlobContainer',           value: ledgerContainerName }
        { name: 'Idempotency__StorageAccount',          value: storageProc.name }
        { name: 'Idempotency__AllowForceRearm',         value: string(idempotencyAllowForceRearm) }
        { name: 'Idempotency__AdminApiEnabled',         value: 'false' }
        { name: 'Idempotency__MaxActionsPerDevicePerDay', value: string(idempotencyMaxActionsPerDay) }
        { name: 'Idempotency__RearmGracePeriodHours',   value: string(idempotencyRearmGracePeriodHours) }
        { name: 'Audit__StorageAccount',   value: storageProc.name }
        { name: 'Audit__TableName',        value: auditTableName }
        { name: 'ActionStatus__TableName',   value: actionStatusTableName }
        { name: 'ActionStatus__PollMaxAgeHours', value: string(actionStatusPollMaxAgeHours) }
        { name: 'Graph__TenantId',                value: graphTenantId }
        { name: 'Graph__ManagedIdentityClientId', value: uamiBitLocker.properties.clientId }
        { name: 'BitLocker__AllowedGroupId',     value: bitlockerAllowedGroupId }
      ]
    }
  }
  dependsOn: [
    raBitLockerBlob
    raBitLockerTable
    raBitLockerLedger
    raBitLockerTableOnProc
    raBitLockerSbRecv
    raBitLockerDeploy
    raAppConfigBitLocker
  ]
}

// ── Rename Function App (customer-internal REST, no Graph, no VNet) ──────────
resource funcRename 'Microsoft.Web/sites@2023-12-01' = {
  name: renameName
  location: location
  tags:     tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uamiRename.id}': {} }
  }
  properties: {
    serverFarmId: planRename.id
    httpsOnly: true
    keyVaultReferenceIdentity: uamiRename.id
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageRename.properties.primaryEndpoints.blob}${renameDeployContainer}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: uamiRename.id
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
        // See Proc app note: SB+MI trigger requires an alwaysReady entry.
        alwaysReady: [
          { name: 'function:renameaction', instanceCount: 1 }
        ]
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '10.0'
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storageRename.name }
        { name: 'AzureWebJobsStorage__credential',  value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId',    value: uamiRename.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: ai.properties.ConnectionString }
        { name: 'AZURE_CLIENT_ID', value: uamiRename.properties.clientId }
        { name: 'AppConfig__Endpoint', value: appConfig.properties.endpoint }
        { name: 'App__Role', value: 'rename' }
        { name: 'ServiceBus__fullyQualifiedNamespace', value: '${sbNamespace.name}.servicebus.windows.net' }
        { name: 'ServiceBus__credential',              value: 'managedidentity' }
        { name: 'ServiceBus__clientId',                value: uamiRename.properties.clientId }
        { name: 'ServiceBus__RenameActionQueue',       value: renameActionQueueName }
        { name: 'Idempotency__BlobContainer',           value: ledgerContainerName }
        { name: 'Idempotency__StorageAccount',          value: storageProc.name }
        { name: 'Idempotency__AllowForceRearm',         value: string(idempotencyAllowForceRearm) }
        { name: 'Idempotency__AdminApiEnabled',         value: 'false' }
        { name: 'Idempotency__MaxActionsPerDevicePerDay', value: string(idempotencyMaxActionsPerDay) }
        { name: 'Idempotency__RearmGracePeriodHours',   value: string(idempotencyRearmGracePeriodHours) }
        { name: 'Audit__StorageAccount',   value: storageProc.name }
        { name: 'Audit__TableName',        value: auditTableName }
        { name: 'ActionStatus__TableName',   value: actionStatusTableName }
        { name: 'ActionStatus__PollMaxAgeHours', value: string(actionStatusPollMaxAgeHours) }
        { name: 'Rename__Endpoint',          value: renameEndpoint }
        { name: 'Rename__AuthHeaderName',    value: renameAuthHeaderName }
        { name: 'Rename__NewNameJsonPath',   value: renameNewNameJsonPath }
        { name: 'Rename__OnCollision',       value: renameOnCollision }
        { name: 'Rename__TimeoutSeconds',    value: '30' }
      ]
    }
  }
  dependsOn: [
    raRenameBlob
    raRenameTable
    raRenameLedger
    raRenameTableOnProc
    raRenameSbRecv
    raRenameDeploy
    raAppConfigRename
  ]
}

// ─────────────────────────────────────────────────────────────────────────────
// Outputs
// ─────────────────────────────────────────────────────────────────────────────
output appConfigName     string = appConfig.name
output appConfigEndpoint string = appConfig.properties.endpoint

output webAppName     string = funcWeb.name
output webAppHostname string = funcWeb.properties.defaultHostName
output procAppName    string = funcProc.name
output procAppHostname string = funcProc.properties.defaultHostName
output wipeAppName    string = funcWipe.name
output wipeAppHostname string = funcWipe.properties.defaultHostName
output autopilotAppName     string = funcAutopilot.name
output autopilotAppHostname string = funcAutopilot.properties.defaultHostName
output bitlockerAppName     string = funcBitLocker.name
output bitlockerAppHostname string = funcBitLocker.properties.defaultHostName
output renameAppName        string = funcRename.name
output renameAppHostname    string = funcRename.properties.defaultHostName

output uamiWorkerClientId    string = uami.properties.clientId
output uamiWorkerPrincipalId string = uami.properties.principalId
output uamiWebClientId       string = uamiWeb.properties.clientId
output uamiWebPrincipalId    string = uamiWeb.properties.principalId
output uamiWipeClientId      string = uamiWipe.properties.clientId
output uamiWipePrincipalId   string = uamiWipe.properties.principalId
output uamiAutopilotClientId    string = uamiAutopilot.properties.clientId
output uamiAutopilotPrincipalId string = uamiAutopilot.properties.principalId
output uamiBitLockerClientId    string = uamiBitLocker.properties.clientId
output uamiBitLockerPrincipalId string = uamiBitLocker.properties.principalId
output uamiRenameClientId       string = uamiRename.properties.clientId
output uamiRenamePrincipalId    string = uamiRename.properties.principalId

output storageWebAccount  string = storageWeb.name
output storageProcAccount string = storageProc.name
output storageWipeAccount string = storageWipe.name
output storageAutopilotAccount string = storageAutopilot.name
output storageBitLockerAccount string = storageBitLocker.name
output storageRenameAccount    string = storageRename.name

output serviceBusNamespace   string = sbNamespace.name
output serviceBusFqdn        string = '${sbNamespace.name}.servicebus.windows.net'
output actionRequestsQueueName string = actionRequestsQueueName
output actionDispatchQueueName string = actionDispatchQueueName
output wipeActionQueueName     string = wipeActionQueueName
output autopilotActionQueueName string = autopilotActionQueueName
output bitlockerActionQueueName string = bitlockerActionQueueName
output renameActionQueueName    string = renameActionQueueName

output ledgerContainerName string = ledgerContainerName
output procDeployContainer string = procDeployContainer
output wipeDeployContainer string = wipeDeployContainer

output automationAccountName string = enableRunbookVariant ? automationAccount.name : ''
output runbookName           string = enableRunbookVariant ? runbookName : ''
output automationPrincipalId string = enableRunbookVariant ? automationAccount.identity.principalId : ''

