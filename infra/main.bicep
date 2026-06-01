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

// ── Storage (blob + tables) ──────────────────────────────────────────────────
@description('Blob container name used as the idempotency ledger for action operations')
param ledgerContainerName string = 'action-ledger'

@description('Table name used for long-term audit event persistence (dual-write alongside App Insights)')
param auditTableName string = 'auditevents'

@description('Azure Table holding per-correlationId action status. Polled by ActionStatusPollerFunction.')
param actionStatusTableName string = 'actionstatus'

@description('NCRONTAB expression for the action status poller. Default: every 2 minutes.')
param actionStatusPollerCron string = '0 */2 * * * *'

// ── Idempotency ledger ───────────────────────────────────────────────────────
@description('Max wipes per device per 24h. Hard ceiling enforced by the ledger.')
param idempotencyMaxWipesPerDay int = 5
@description('Hours to wait before auto-rearming a ledger whose previous wipe ended in pollTimeout.')
param idempotencyRearmGracePeriodHours int = 48
@description('If true, the X-Force-Rearm HTTP header bypasses the tracker-based rearm gate. Keep false in prod.')
param idempotencyAllowForceRearm bool = true
@description('If true, the /api/actions/ledger/* endpoints are reachable (function key still required). Default false in prod.')
param idempotencyAdminApiEnabled bool = true

@description('Provisions an Azure Automation Account + PowerShell 7.2 runbook (Invoke-DeviceWipe) as an alternative wipe executor.')
param enableRunbookVariant bool = true

// ── Naming ───────────────────────────────────────────────────────────────────
var suffix = uniqueString(resourceGroup().id)
var stWebRaw  = toLower('${namePrefix}stw${suffix}')
var stWebName = length(stWebRaw) > 24 ? substring(stWebRaw, 0, 24) : stWebRaw
var stProcRaw  = toLower('${namePrefix}stp${suffix}')
var stProcName = length(stProcRaw) > 24 ? substring(stProcRaw, 0, 24) : stProcRaw
var stWipeRaw  = toLower('${namePrefix}stwp${suffix}')
var stWipeName = length(stWipeRaw) > 24 ? substring(stWipeRaw, 0, 24) : stWipeRaw

var webName  = toLower('${namePrefix}-web-${suffix}')
var procName = toLower('${namePrefix}-proc-${suffix}')
var wipeName = toLower('${namePrefix}-wipe-${suffix}')
var aiName   = toLower('${namePrefix}-ai-${suffix}')
var lawName  = toLower('${namePrefix}-law-${suffix}')

var uamiName     = toLower('${namePrefix}-uami-${suffix}')      // dispatcher (no Graph)
var uamiWebName  = toLower('${namePrefix}-uami-web-${suffix}')   // public web (no Graph)
var uamiWipeName = toLower('${namePrefix}-uami-wipe-${suffix}')  // privileged Graph

var planWebName  = toLower('${namePrefix}-plan-web-${suffix}')   // EP1
var planProcName = toLower('${namePrefix}-plan-proc-${suffix}')  // FC1
var planWipeName = toLower('${namePrefix}-plan-wipe-${suffix}')  // FC1

var sbNamespaceName = toLower('${namePrefix}-sb-${suffix}')
var appConfigName   = toLower('${namePrefix}-appcfg-${suffix}')

// Per-Flex-app deployment package containers (Flex Consumption requirement).
var procDeployContainer = 'app-package-proc'
var wipeDeployContainer = 'app-package-wipe'

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
// No sessions, no duplicate-detection (we use idempotency ledger instead).
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
        { name: 'ServiceBus__FullyQualifiedNamespace', value: '${sbNamespace.name}.servicebus.windows.net' }
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
        { name: 'Idempotency__MaxWipesPerDevicePerDay', value: string(idempotencyMaxWipesPerDay) }
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
        { name: 'ServiceBus__FullyQualifiedNamespace', value: '${sbNamespace.name}.servicebus.windows.net' }
        { name: 'ServiceBus__ActionRequestsQueue',     value: actionRequestsQueueName }
        { name: 'ServiceBus__ActionDispatchQueue',     value: actionDispatchQueueName }
        { name: 'ServiceBus__WipeActionQueue',         value: wipeActionQueueName }
        { name: 'ActionStatus__TableName',             value: actionStatusTableName }
        { name: 'ActionStatusPoller__CronExpression',  value: actionStatusPollerCron }
        // Idempotency ledger (Proc reads/queries but does NOT reserve here).
        { name: 'Idempotency__BlobContainer',           value: ledgerContainerName }
        { name: 'Idempotency__StorageAccount',          value: storageProc.name }
        { name: 'Idempotency__AllowForceRearm',         value: string(idempotencyAllowForceRearm) }
        { name: 'Idempotency__AdminApiEnabled',         value: string(idempotencyAdminApiEnabled) }
        { name: 'Idempotency__MaxWipesPerDevicePerDay', value: string(idempotencyMaxWipesPerDay) }
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
        { name: 'ServiceBus__FullyQualifiedNamespace', value: '${sbNamespace.name}.servicebus.windows.net' }
        { name: 'ServiceBus__WipeActionQueue',         value: wipeActionQueueName }
        // Idempotency ledger (Reserve/MarkIssued executed by WipeActionRunner here).
        { name: 'Idempotency__BlobContainer',           value: ledgerContainerName }
        { name: 'Idempotency__StorageAccount',          value: storageProc.name }
        { name: 'Idempotency__AllowForceRearm',         value: string(idempotencyAllowForceRearm) }
        { name: 'Idempotency__AdminApiEnabled',         value: 'false' }
        { name: 'Idempotency__MaxWipesPerDevicePerDay', value: string(idempotencyMaxWipesPerDay) }
        { name: 'Idempotency__RearmGracePeriodHours',   value: string(idempotencyRearmGracePeriodHours) }
        // Audit + action status tables shared.
        { name: 'Audit__StorageAccount',   value: storageProc.name }
        { name: 'Audit__TableName',        value: auditTableName }
        { name: 'ActionStatus__TableName', value: actionStatusTableName }
        // Microsoft Graph wipe call (privileged).
        { name: 'Graph__TenantId',                value: graphTenantId }
        { name: 'Graph__ManagedIdentityClientId', value: uamiWipe.properties.clientId }
        { name: 'Wipe__AllowedGroupId',     value: allowedGroupId }
        { name: 'Wipe__KeepEnrollmentData', value: string(keepEnrollmentData) }
        { name: 'Wipe__KeepUserData',       value: string(keepUserData) }
      ]
    }
  }
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

output uamiWorkerClientId    string = uami.properties.clientId
output uamiWorkerPrincipalId string = uami.properties.principalId
output uamiWebClientId       string = uamiWeb.properties.clientId
output uamiWebPrincipalId    string = uamiWeb.properties.principalId
output uamiWipeClientId      string = uamiWipe.properties.clientId
output uamiWipePrincipalId   string = uamiWipe.properties.principalId

output storageWebAccount  string = storageWeb.name
output storageProcAccount string = storageProc.name
output storageWipeAccount string = storageWipe.name

output serviceBusNamespace   string = sbNamespace.name
output serviceBusFqdn        string = '${sbNamespace.name}.servicebus.windows.net'
output actionRequestsQueueName string = actionRequestsQueueName
output actionDispatchQueueName string = actionDispatchQueueName
output wipeActionQueueName     string = wipeActionQueueName

output ledgerContainerName string = ledgerContainerName
output procDeployContainer string = procDeployContainer
output wipeDeployContainer string = wipeDeployContainer

output automationAccountName string = enableRunbookVariant ? automationAccount.name : ''
output runbookName           string = enableRunbookVariant ? runbookName : ''
output automationPrincipalId string = enableRunbookVariant ? automationAccount.identity.principalId : ''
