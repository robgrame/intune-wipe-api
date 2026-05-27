targetScope = 'resourceGroup'

@minLength(3)
@maxLength(12)
param namePrefix string = 'intwipe'

param location string = resourceGroup().location

@description('Tenant ID where Graph calls are made')
param graphTenantId string = subscription().tenantId

@description('Comma-separated list of trusted CA certificate thumbprints (root and/or intermediate). At least one must appear in the client certificate chain. Required unless trustedCaCertificatesBase64 is provided.')
param trustedCaThumbprints string = ''

@description('Comma-separated list of base64-encoded DER CA certificates loaded into a custom trust store (no dependency on the machine trust store). Optional alternative or complement to trustedCaThumbprints.')
@secure()
param trustedCaCertificatesBase64 string = ''

@description('Optional comma-separated list of leaf certificate thumbprints to pin (defense-in-depth). Empty disables leaf pinning.')
param allowedLeafThumbprints string = ''

@description('Enable CRL/OCSP revocation checks on the client certificate chain.')
param checkRevocation bool = false

@description('Revocation lookup mode: Online | Offline | NoCheck')
@allowed([ 'Online', 'Offline', 'NoCheck' ])
param revocationMode string = 'Online'

@description('Revocation scope: ExcludeRoot | EntireChain | EndCertificateOnly')
@allowed([ 'ExcludeRoot', 'EntireChain', 'EndCertificateOnly' ])
param revocationFlag string = 'ExcludeRoot'

@description('Require Client Authentication EKU (1.3.6.1.5.5.7.3.2) on the client certificate.')
param requireClientAuthEku bool = true

@description('Which claim from the client certificate identifies the device. SubjectCN expects CN=<entraDeviceId GUID>. Disabled turns off cert<->device binding (NOT recommended).')
@allowed([ 'SubjectCN', 'SanDns', 'SanUri', 'Disabled' ])
param deviceIdBindingClaim string = 'SubjectCN'

@description('Maximum acceptable clock skew (seconds) between client X-Request-Timestamp and server time.')
param maxTimestampSkewSeconds int = 300

@description('Object Id of the Entra ID security group whose member devices are authorized to self-wipe')
param allowedGroupId string

@description('Wipe options')
param keepEnrollmentData bool = false
param keepUserData bool = false

@description('Storage queue name for wipe requests')
param wipeQueueName string = 'wipe-requests'

@description('Blob container name used as the idempotency ledger for wipe operations')
param ledgerContainerName string = 'wipe-ledger'

var suffix = uniqueString(resourceGroup().id)
var storageNameRaw = toLower('${namePrefix}st${suffix}')
var storageName    = length(storageNameRaw) > 24 ? substring(storageNameRaw, 0, 24) : storageNameRaw
var webName    = toLower('${namePrefix}-web-${suffix}')
var procName   = toLower('${namePrefix}-proc-${suffix}')
var planName   = toLower('${namePrefix}-plan-${suffix}')
var aiName     = toLower('${namePrefix}-ai-${suffix}')
var lawName    = toLower('${namePrefix}-law-${suffix}')
var uamiName    = toLower('${namePrefix}-uami-${suffix}')      // worker identity (Graph-consented)
var uamiWebName = toLower('${namePrefix}-uami-web-${suffix}')   // public web identity (NO Graph)

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

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
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

resource queueSvc 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource wipeQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueSvc
  name: wipeQueueName
}

resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource ledgerContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobSvc
  name: ledgerContainerName
  properties: { publicAccess: 'None' }
}

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
}

// Separate identity for the public-facing Function App. Has NO Microsoft Graph
// consent grants — so even if the public surface is compromised, the attacker
// cannot drive Graph wipe calls. Only allowed action on data plane is enqueue.
resource uamiWeb 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiWebName
  location: location
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  sku: { name: 'EP1', tier: 'ElasticPremium' }
  kind: 'elastic'
  properties: { maximumElasticWorkerCount: 5 }
}

// ───────────────────────────────────────────────────────────────────────────
// Public Function App (web): hosts only the HTTP trigger (WipeRequest).
// mTLS terminated by App Service. Identity has NO Graph permissions.
// ───────────────────────────────────────────────────────────────────────────
resource funcWeb 'Microsoft.Web/sites@2023-12-01' = {
  name: webName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uamiWeb.id}': {} }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    clientCertEnabled: true
    clientCertMode: 'Required'
    keyVaultReferenceIdentity: uamiWeb.id
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      netFrameworkVersion: 'v10.0'
      use32BitWorkerProcess: false
      scmIpSecurityRestrictionsUseMain: true
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',    value: 'dotnet-isolated' }
        { name: 'WEBSITE_RUN_FROM_PACKAGE',    value: '1' }
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'AzureWebJobsStorage__credential',  value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId',    value: uamiWeb.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: ai.properties.ConnectionString }
        { name: 'AZURE_CLIENT_ID', value: uamiWeb.properties.clientId }
        // App role guard: in-code defense-in-depth (AzureWebJobs disabled is unreliable on isolated).
        { name: 'App__Role', value: 'web' }
        // Selector: keep only the HTTP trigger on this app.
        { name: 'AzureWebJobs.WipeProcessor.Disabled', value: 'true' }
        // Queue write (enqueue only — identity has Sender role).
        { name: 'Queue__WipeQueueName', value: wipeQueueName }
        // Client cert / replay protection (HTTP surface).
        { name: 'ClientCert__TrustedCaThumbprints',    value: trustedCaThumbprints }
        { name: 'ClientCert__TrustedCaCertificates',   value: trustedCaCertificatesBase64 }
        { name: 'ClientCert__AllowedLeafThumbprints',  value: allowedLeafThumbprints }
        { name: 'ClientCert__CheckRevocation',         value: string(checkRevocation) }
        { name: 'ClientCert__RevocationMode',          value: revocationMode }
        { name: 'ClientCert__RevocationFlag',          value: revocationFlag }
        { name: 'ClientCert__RequireClientAuthEku',    value: string(requireClientAuthEku) }
        { name: 'ClientCert__RequireClientCert',       value: 'true' }
        { name: 'ClientCert__TrustForwardedHeader',    value: 'false' }
        { name: 'ClientCert__DeviceIdBindingClaim',    value: deviceIdBindingClaim }
        { name: 'Replay__MaxTimestampSkewSeconds',     value: string(maxTimestampSkewSeconds) }
      ]
    }
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Worker Function App (processor): hosts only the queue trigger.
// No public HTTP triggers. Identity has Microsoft Graph consents to perform
// the actual managedDevices/{id}/wipe call.
// ───────────────────────────────────────────────────────────────────────────
resource funcProc 'Microsoft.Web/sites@2023-12-01' = {
  name: procName
  location: location
  kind: 'functionapp'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uami.id}': {} }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    clientCertEnabled: false
    keyVaultReferenceIdentity: uami.id
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      netFrameworkVersion: 'v10.0'
      use32BitWorkerProcess: false
      scmIpSecurityRestrictionsUseMain: true
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',    value: 'dotnet-isolated' }
        { name: 'WEBSITE_RUN_FROM_PACKAGE',    value: '1' }
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'AzureWebJobsStorage__credential',  value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId',    value: uami.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: ai.properties.ConnectionString }
        { name: 'AZURE_CLIENT_ID', value: uami.properties.clientId }
        // App role guard: in-code defense-in-depth (AzureWebJobs disabled is unreliable on isolated).
        { name: 'App__Role', value: 'proc' }
        // Selector: keep only the queue trigger on this app.
        { name: 'AzureWebJobs.WipeRequest.Disabled', value: 'true' }
        // Queue + ledger.
        { name: 'Queue__WipeQueueName', value: wipeQueueName }
        { name: 'Idempotency__BlobContainer', value: ledgerContainerName }
        { name: 'Idempotency__StorageAccount', value: storage.name }
        // Microsoft Graph wipe call.
        { name: 'Graph__TenantId', value: graphTenantId }
        { name: 'Graph__ManagedIdentityClientId', value: uami.properties.clientId }
        { name: 'Wipe__AllowedGroupId',     value: allowedGroupId }
        { name: 'Wipe__KeepEnrollmentData', value: string(keepEnrollmentData) }
        { name: 'Wipe__KeepUserData',       value: string(keepUserData) }
      ]
    }
  }
}

// RBAC: worker identity → full data-plane on storage (Functions runtime needs
// blob lease + queue control; app needs queue read/delete + blob ledger write).
var blobDataOwner         = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var queueDataContributor  = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
// Sender is enqueue-only — does NOT allow read/peek/delete on the queue.
var queueDataMessageSender = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'c6a89b2d-59bc-44d0-9896-0f6e12d7b80a')

resource raProcBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, uami.id, 'blob')
  scope: storage
  properties: { roleDefinitionId: blobDataOwner, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raProcQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, uami.id, 'queue')
  scope: storage
  properties: { roleDefinitionId: queueDataContributor, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}

// RBAC: web identity → blob (Functions runtime needs it for distributed lease
// on AzureWebJobsStorage) + Queue Data Message Sender ONLY (enqueue, no read).
resource raWebBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, uamiWeb.id, 'blob')
  scope: storage
  properties: { roleDefinitionId: blobDataOwner, principalId: uamiWeb.properties.principalId, principalType: 'ServicePrincipal' }
}
resource raWebQueueSend 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, uamiWeb.id, 'queue-send')
  scope: storage
  properties: { roleDefinitionId: queueDataMessageSender, principalId: uamiWeb.properties.principalId, principalType: 'ServicePrincipal' }
}

output webAppName string = funcWeb.name
output webAppHostname string = funcWeb.properties.defaultHostName
output procAppName string = funcProc.name
output procAppHostname string = funcProc.properties.defaultHostName
output uamiWorkerClientId string = uami.properties.clientId
output uamiWorkerPrincipalId string = uami.properties.principalId
output uamiWebClientId string = uamiWeb.properties.clientId
output uamiWebPrincipalId string = uamiWeb.properties.principalId
output storageAccount string = storage.name
output wipeQueueName string = wipeQueueName
output ledgerContainerName string = ledgerContainerName
