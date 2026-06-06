targetScope = 'resourceGroup'

// ─────────────────────────────────────────────────────────────────────────────
// IntuneDeviceActions — Phase C infrastructure
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
var suffix = uniqueString(resourceGroup().id)
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

var webName  = toLower('${namePrefix}-web-${suffix}')
var procName = toLower('${namePrefix}-proc-${suffix}')
var wipeName = toLower('${namePrefix}-wipe-${suffix}')
var autopilotName = toLower('${namePrefix}-autopilot-${suffix}')
var bitlockerName = toLower('${namePrefix}-bitlocker-${suffix}')
var aiName   = toLower('${namePrefix}-ai-${suffix}')
var lawName  = toLower('${namePrefix}-law-${suffix}')

var uamiName     = toLower('${namePrefix}-uami-${suffix}')      // dispatcher (no Graph)
var uamiWebName  = toLower('${namePrefix}-uami-web-${suffix}')   // public web (no Graph)
var uamiWipeName = toLower('${namePrefix}-uami-wipe-${suffix}')  // privileged Graph
var uamiAutopilotName = toLower('${namePrefix}-uami-autopilot-${suffix}')  // privileged Graph (Autopilot import)
var uamiBitLockerName = toLower('${namePrefix}-uami-bitlocker-${suffix}')  // privileged Graph (BitLocker rotate)

var planWebName  = toLower('${namePrefix}-plan-web-${suffix}')   // EP1
var planProcName = toLower('${namePrefix}-plan-proc-${suffix}')  // FC1
var planWipeName = toLower('${namePrefix}-plan-wipe-${suffix}')  // FC1
var planAutopilotName = toLower('${namePrefix}-plan-autopilot-${suffix}')  // FC1
var planBitLockerName = toLower('${namePrefix}-plan-bitlocker-${suffix}')  // FC1

var sbNamespaceName = toLower('${namePrefix}-sb-${suffix}')
var appConfigName   = toLower('${namePrefix}-appcfg-${suffix}')

// Per-Flex-app deployment package containers (Flex Consumption requirement).
var procDeployContainer = 'app-package-proc'
var wipeDeployContainer = 'app-package-wipe'
var autopilotDeployContainer = 'app-package-autopilot'
var bitlockerDeployContainer = 'app-package-bitlocker'

// ── Observability ────────────────────────────────────────────────────────────
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

resource ai 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  kind: 'web'
  properties: { Application_Type: 'web', WorkspaceResourceId: law.id }
}

// ── Storage accounts (one per app) ───────────────────────────────────────────
resource storageWeb 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: stWebName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices, Logging, Metrics'
      ipRules: [for ip in storageAllowedIpRanges: { value: ip, action: 'Allow' }]
      virtualNetworkRules: []
    }
  }
}

resource storageProc 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: stProcName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices, Logging, Metrics'
      ipRules: [for ip in storageAllowedIpRanges: { value: ip, action: 'Allow' }]
      virtualNetworkRules: []
    }
  }
}

resource storageWipe 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: stWipeName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
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
}
resource uamiWeb 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiWebName
  location: location
}
resource uamiWipe 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiWipeName
  location: location
}

// ── Service Bus Standard namespace + 3 queues ────────────────────────────────
// Standard tier is required for: queue auto-forwarding (not used here but kept
// in our back-pocket), DLQ, and topic/subscription affordances if we extend.
// Basic would not support topics — Standard at ~10€/mo is cheap insurance.
resource sbNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: sbNamespaceName
  location: location
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

// ── App Service Plans ────────────────────────────────────────────────────────
// Web stays on Linux EP1 because: (a) mTLS + always-warm intake demand
// predictable concurrency and no cold-start; (b) clientCertEnabled is not
// supported on Flex Consumption today.
resource planWeb 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planWebName
  location: location
  sku: { name: 'EP1', tier: 'ElasticPremium' }
  kind: 'elastic'
  properties: { reserved: true, maximumElasticWorkerCount: 5 }
}

// Proc + Wipe move to Flex Consumption (FC1) for scale-to-zero + per-second
// billing. Both apps are event-driven (SB triggers + timer) with bursty load.
resource planProc 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planProcName
  location: location
  sku: { tier: 'FlexConsumption', name: 'FC1' }
  kind: 'functionapp'
  properties: { reserved: true }
}
resource planWipe 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planWipeName
  location: location
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
    clientCertExclusionPaths: '/api/actions/ledger'
    keyVaultReferenceIdentity: uamiWeb.id
    // VNet integration (Option B). web-subnet is delegated to
    // Microsoft.Web/serverFarms. vnetRouteAllEnabled=false keeps Internet
    // outbound on App Service public IPs (Graph / Service Bus / AppConfig /
    // App Insights — high volume); only RFC1918 destinations (the storage
    // PE IPs resolved via the linked private DNS zones) traverse the VNet.
    // vnetContentShareEnabled=true is REQUIRED so the Azure Files content
    // share (WEBSITE_CONTENTSHARE on storageWeb) also flows through the
    // VNet → file PE, otherwise the EP1 platform breaks when storage is
    // locked down.
    virtualNetworkSubnetId: webSubnet.id
    vnetRouteAllEnabled: false
    vnetContentShareEnabled: true
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
    virtualNetworkSubnetId: procFlexSubnet.id
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
    virtualNetworkSubnetId: wipeFlexSubnet.id
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
var automationAccountName = toLower('${namePrefix}-aa-${suffix}')
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

// Action status tracker — same table as the Function App runners so the
// /api/actions/status endpoint sees runbook-issued rows too.
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

// Wipe-runner default allowed-group; the BitLocker runbook falls back to
// this when 'BitLockerAllowedGroupId' is not set, matching the
// `bitlockerAllowedGroupId = allowedGroupId` default in the Function App config.
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

// Idempotency rate-limiter cap (per-device, rolling 24h window). Matches
// the Function App default of 5.
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

// ─────────────────────────────────────────────────────────────────────────────
// Private Endpoint + VNet integration infrastructure (Option B — active)
//
// All 3 Function Apps are VNet-integrated. Storage is reachable ONLY via
// Private Endpoints from inside the VNet (plus a dev IP whitelist). Flex
// outbound to public services (Graph, Service Bus, App Configuration, App
// Insights) flows through a NAT Gateway → 1 Standard public IP for stable
// SNAT. Web (EP1) keeps vnetRouteAllEnabled=false so its Internet outbound
// stays on App Service public IPs (avoids NAT SNAT cost on high-volume Graph
// calls); only its RFC1918 destinations (the storage PEs) route through VNet.
// Web has vnetContentShareEnabled=true so the Azure Files content-share path
// (WEBSITE_CONTENTSHARE) also goes through the VNet → file PE.
//
// Subnet budget (10.20.0.0/24):
//   pe-subnet         10.20.0.0/27   (.0-.31)   — 6 PEs
//   reserved          10.20.0.32/27  (.32-.63)
//   proc-flex-subnet  10.20.0.64/26  (.64-.127) — Microsoft.App/environments
//   wipe-flex-subnet  10.20.0.128/26 (.128-.191) — Microsoft.App/environments
//   web-subnet        10.20.0.192/26 (.192-.255) — Microsoft.Web/serverFarms
//
// 2 NSGs (flex shared, web dedicated). PE subnet has no NSG because
// privateEndpointNetworkPolicies=Disabled disables NSG enforcement on PE NICs.
// 1 NAT Gateway + 1 Standard Public IP, attached to both flex subnets.
// ─────────────────────────────────────────────────────────────────────────────
var vnetName           = toLower('${namePrefix}-vnet-${suffix}')
var peSubnetName       = 'pe-subnet'
var webSubnetName      = 'web-subnet'
var procFlexSubnetName = 'proc-flex-subnet'
var wipeFlexSubnetName = 'wipe-flex-subnet'
var nsgFlexName        = toLower('${namePrefix}-nsg-flex-${suffix}')
var nsgWebName         = toLower('${namePrefix}-nsg-web-${suffix}')
var natGatewayName     = toLower('${namePrefix}-natgw-${suffix}')
var natPipName         = toLower('${namePrefix}-natgw-pip-${suffix}')

// NSGs need to exist BEFORE the subnets that reference them, and they must
// be parented at the resource group (not the VNet). Azure default rules
// already allow VNet-to-VNet + outbound-to-Internet and deny inbound from
// Internet; we add no explicit rules (empty securityRules) to keep this
// behavior. Tighten later if specific deny rules become necessary.
resource nsgFlex 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgFlexName
  location: location
  properties: {
    securityRules: [
      // Explicitly allow outbound to Storage service tag (PE traffic stays on
      // private path; this rule documents intent and would still permit any
      // future fallback to public storage endpoint). Default Azure rules
      // would also allow this; making it explicit aids security review.
      {
        name: 'Allow-Outbound-Storage'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Storage'
          destinationPortRange: '*'
        }
      }
      // Explicitly allow outbound to AzureCloud (covers Service Bus, Graph,
      // App Configuration, App Insights, Entra ID via service tags).
      {
        name: 'Allow-Outbound-AzureCloud'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgWeb 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgWebName
  location: location
  properties: {
    securityRules: [
      {
        name: 'Allow-Outbound-Storage'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Storage'
          destinationPortRange: '*'
        }
      }
      // Web has vnetRouteAllEnabled=false so non-RFC1918 traffic stays on
      // App Service public outbound — these AzureCloud destinations
      // (Service Bus, Graph, etc.) won't actually traverse this subnet.
      // Rule kept for symmetry with nsgFlex.
      {
        name: 'Allow-Outbound-AzureCloud'
        properties: {
          priority: 110
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'AzureCloud'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// Standard Public IP (zone-redundant) for the NAT Gateway. Static so the
// Graph allowlist (if/when added at the tenant level) can pin the IP.
resource natPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: natPipName
  location: location
  sku: { name: 'Standard' }
  zones: [ '1', '2', '3' ]
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
  }
}

// NAT Gateway shared by both Flex subnets. Flex routes ALL outbound through
// the VNet when integrated, so without NAT GW the apps would have no Internet
// path for Graph / Service Bus / App Configuration.
resource natGateway 'Microsoft.Network/natGateways@2024-01-01' = {
  name: natGatewayName
  location: location
  sku: { name: 'Standard' }
  zones: [ '1' ]
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [ { id: natPip.id } ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.20.0.0/24' ] }
    subnets: [
      {
        name: peSubnetName
        properties: {
          addressPrefix: '10.20.0.0/27'
          // PE subnet must allow NIC creation by the PE control plane.
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
      }
      {
        name: procFlexSubnetName
        properties: {
          addressPrefix: '10.20.0.64/26'
          delegations: [
            {
              name: 'flex-delegation'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
          networkSecurityGroup: { id: nsgFlex.id }
          natGateway: { id: natGateway.id }
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: wipeFlexSubnetName
        properties: {
          addressPrefix: '10.20.0.128/26'
          delegations: [
            {
              name: 'flex-delegation'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
          networkSecurityGroup: { id: nsgFlex.id }
          natGateway: { id: natGateway.id }
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: webSubnetName
        properties: {
          addressPrefix: '10.20.0.192/26'
          delegations: [
            {
              name: 'web-delegation'
              properties: { serviceName: 'Microsoft.Web/serverFarms' }
            }
          ]
          networkSecurityGroup: { id: nsgWeb.id }
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  parent: vnet
  name: peSubnetName
}

resource webSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  parent: vnet
  name: webSubnetName
}

resource procFlexSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  parent: vnet
  name: procFlexSubnetName
}

resource wipeFlexSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' existing = {
  parent: vnet
  name: wipeFlexSubnetName
}

// One private DNS zone per storage subresource we PE. Storage suffix is
// 'core.windows.net' in commercial Azure; environment().suffixes.storage
// resolves to the right value per cloud (e.g. core.chinacloudapi.cn).
resource pdnsBlob 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
}
resource pdnsFile 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.file.${environment().suffixes.storage}'
  location: 'global'
}
resource pdnsQueue 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.queue.${environment().suffixes.storage}'
  location: 'global'
}
resource pdnsTable 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.table.${environment().suffixes.storage}'
  location: 'global'
}

resource pdnsBlobLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: pdnsBlob
  name: '${vnetName}-link'
  location: 'global'
  properties: { virtualNetwork: { id: vnet.id }, registrationEnabled: false }
}
resource pdnsFileLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: pdnsFile
  name: '${vnetName}-link'
  location: 'global'
  properties: { virtualNetwork: { id: vnet.id }, registrationEnabled: false }
}
resource pdnsQueueLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: pdnsQueue
  name: '${vnetName}-link'
  location: 'global'
  properties: { virtualNetwork: { id: vnet.id }, registrationEnabled: false }
}
resource pdnsTableLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: pdnsTable
  name: '${vnetName}-link'
  location: 'global'
  properties: { virtualNetwork: { id: vnet.id }, registrationEnabled: false }
}

// Web's storage is an EP1 Function content store and uses all 4 subresources
// (blob+queue+table for AzureWebJobsStorage host lease/control/state plus
// file for WEBSITE_CONTENTSHARE). One PE per subresource — Azure Storage
// requires distinct PEs per group ID.
var webPeSubresources = [ 'blob', 'file', 'queue', 'table' ]
resource peStorageWeb 'Microsoft.Network/privateEndpoints@2024-01-01' = [for sub in webPeSubresources: {
  name: '${stWebName}-pe-${sub}'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: sub
        properties: {
          privateLinkServiceId: storageWeb.id
          groupIds: [ sub ]
        }
      }
    ]
  }
}]

// Proc and Wipe Flex Consumption deployment storages use blob only (the
// app-package container). No file/queue/table needed.
// storageProc hosts the shared audit + status tables and the idempotency
// ledger blob. Web (VNet-integrated) reaches them via private endpoints —
// one per subresource. blob+table+queue cover the current data plane;
// adding `file` is unnecessary because no Function App uses storageProc as
// its WEBSITE_CONTENTSHARE backing.
var procPeSubresources = [ 'blob', 'table', 'queue' ]
resource peStorageProc 'Microsoft.Network/privateEndpoints@2024-01-01' = [for sub in procPeSubresources: {
  name: '${stProcName}-pe-${sub}'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: sub
        properties: {
          privateLinkServiceId: storageProc.id
          groupIds: [ sub ]
        }
      }
    ]
  }
}]
resource peStorageWipeBlob 'Microsoft.Network/privateEndpoints@2024-01-01' = {
  name: '${stWipeName}-pe-blob'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: storageWipe.id
          groupIds: [ 'blob' ]
        }
      }
    ]
  }
}

// DNS zone groups auto-register the PE's private IP into the correct DNS
// zone so resolution from inside the linked VNet returns the PE IP instead
// of the public storage IP. Maps subresource → DNS zone in a single place.
var subresourceToDnsZoneId = {
  blob:  pdnsBlob.id
  file:  pdnsFile.id
  queue: pdnsQueue.id
  table: pdnsTable.id
}
resource peStorageWebDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = [for (sub, i) in webPeSubresources: {
  parent: peStorageWeb[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: sub, properties: { privateDnsZoneId: subresourceToDnsZoneId[sub] } }
    ]
  }
}]
resource peStorageProcDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = [for (sub, i) in procPeSubresources: {
  parent: peStorageProc[i]
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: sub, properties: { privateDnsZoneId: subresourceToDnsZoneId[sub] } }
    ]
  }
}]
resource peStorageWipeBlobDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = {
  parent: peStorageWipeBlob
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'blob', properties: { privateDnsZoneId: pdnsBlob.id } }
    ]
  }
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

// ── Dedicated privileged UAMIs (isolated Graph consent per capability) ────────
// uamiAutopilot Graph permissions: DeviceManagementServiceConfig.ReadWrite.All,
//   DeviceManagementManagedDevices.Read.All, Device.Read.All, GroupMember.Read.All
// uamiBitLocker Graph permissions: DeviceManagementManagedDevices.PrivilegedOperations.All,
//   DeviceManagementManagedDevices.Read.All, Device.Read.All, GroupMember.Read.All
// (Granted on the app registration post-deploy, NOT in Bicep.)
resource uamiAutopilot 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiAutopilotName
  location: location
}
resource uamiBitLocker 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiBitLockerName
  location: location
}

// ── FC1 Flex plans ───────────────────────────────────────────────────────────
resource planAutopilot 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planAutopilotName
  location: location
  sku: { tier: 'FlexConsumption', name: 'FC1' }
  kind: 'functionapp'
  properties: { reserved: true }
}
resource planBitLocker 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planBitLockerName
  location: location
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

// ── Autopilot Function App (privileged, no VNet) ─────────────────────────────
resource funcAutopilot 'Microsoft.Web/sites@2023-12-01' = {
  name: autopilotName
  location: location
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

output storageWebAccount  string = storageWeb.name
output storageProcAccount string = storageProc.name
output storageWipeAccount string = storageWipe.name
output storageAutopilotAccount string = storageAutopilot.name
output storageBitLockerAccount string = storageBitLocker.name

output serviceBusNamespace   string = sbNamespace.name
output serviceBusFqdn        string = '${sbNamespace.name}.servicebus.windows.net'
output actionRequestsQueueName string = actionRequestsQueueName
output actionDispatchQueueName string = actionDispatchQueueName
output wipeActionQueueName     string = wipeActionQueueName
output autopilotActionQueueName string = autopilotActionQueueName
output bitlockerActionQueueName string = bitlockerActionQueueName

output ledgerContainerName string = ledgerContainerName
output procDeployContainer string = procDeployContainer
output wipeDeployContainer string = wipeDeployContainer

output automationAccountName string = enableRunbookVariant ? automationAccount.name : ''
output runbookName           string = enableRunbookVariant ? runbookName : ''
output automationPrincipalId string = enableRunbookVariant ? automationAccount.identity.principalId : ''

output vnetName              string = vnet.name
output peSubnetName          string = peSubnetName
output webSubnetName         string = webSubnetName
output procFlexSubnetName    string = procFlexSubnetName
output wipeFlexSubnetName    string = wipeFlexSubnetName
output nsgFlexName           string = nsgFlex.name
output nsgWebName            string = nsgWeb.name
output natGatewayName        string = natGateway.name
output natGatewayPipAddress  string = natPip.properties.ipAddress
output privateDnsZoneBlob    string = pdnsBlob.name
output privateDnsZoneFile    string = pdnsFile.name
output privateDnsZoneQueue   string = pdnsQueue.name
output privateDnsZoneTable   string = pdnsTable.name
output peStorageProcBlobId   string = peStorageProc[0].id
output peStorageProcTableId  string = peStorageProc[1].id
output peStorageProcQueueId  string = peStorageProc[2].id
output peStorageWipeBlobId   string = peStorageWipeBlob.id
output peStorageWebBlobId    string = peStorageWeb[0].id
output peStorageWebFileId    string = peStorageWeb[1].id
output peStorageWebQueueId   string = peStorageWeb[2].id
output peStorageWebTableId   string = peStorageWeb[3].id
