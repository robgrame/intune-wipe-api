targetScope = 'resourceGroup'

@minLength(3)
@maxLength(12)
param namePrefix string = 'intwipe'

param location string = resourceGroup().location

@description('Tenant ID where Graph calls are made')
param graphTenantId string = subscription().tenantId

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

@description('Revocation lookup mode: Online | Offline | NoCheck')
@allowed([ 'Online', 'Offline', 'NoCheck' ])
param revocationMode string = 'Online'

@description('Revocation scope: ExcludeRoot | EntireChain | EndCertificateOnly')
@allowed([ 'ExcludeRoot', 'EntireChain', 'EndCertificateOnly' ])
param revocationFlag string = 'ExcludeRoot'

@description('Require Client Authentication EKU (1.3.6.1.5.5.7.3.2) on the client certificate.')
param requireClientAuthEku bool = true

@description('Which claim from the client certificate identifies the device. Auto (recommended for multi-PKI) tries in order: ThumbprintToDeviceMap (operator intent wins) -> SanUri -> SanDns -> SubjectCN -> SanDnsLookup (Graph directory resolution by displayName, for legacy AD CS certs). All claim strategies are STRICT: the SAN value or CN must EQUAL a GUID. SanDnsLookup resolves the cert SAN DNS via Microsoft Graph and requires the WEB UAMI to have Device.Read.All granted. Thumbprint uses ONLY the operator map. Disabled turns off cert<->device binding (NOT recommended).')
@allowed([ 'Auto', 'SubjectCN', 'SanDns', 'SanUri', 'Thumbprint', 'SanDnsLookup', 'Disabled' ])
param deviceIdBindingClaim string = 'Auto'

@description('Operator-maintained mapping cert-thumbprint -> EntraDeviceId for the Thumbprint and Auto binding modes. Format: "THUMB1=guid1|THUMB2=guid2". Duplicate thumbprints mapping to different GUIDs are rejected fail-closed at startup. Use this when the client certificate Subject/SAN does not embed the device id (third-party PKI templates).')
@secure()
param clientCertThumbprintToDeviceMap string = ''

@description('Maximum acceptable clock skew (seconds) between client X-Request-Timestamp and server time.')
param maxTimestampSkewSeconds int = 300

@description('Object Id of the Entra ID security group whose member devices are authorized to self-wipe')
param allowedGroupId string

@description('Wipe options')
param keepEnrollmentData bool = false
param keepUserData bool = false

@description('Storage queue name for wipe requests')
param wipeQueueName string = 'wipe-requests'

@description('Storage queue name for plug-in action dispatch (router queue consumed by ActionDispatchFunction).')
param actionDispatchQueueName string = 'action-dispatch'

@description('Storage queue name for the dedicated wipe-runner Function App. The worker enqueues here via WipeForwardingRunner; the wipe app consumes via WipeActionConsumerFunction.')
param wipeActionQueueName string = 'wipe-action'

@description('Blob container name used as the idempotency ledger for wipe operations')
param ledgerContainerName string = 'wipe-ledger'

@description('Table name used for long-term audit event persistence (dual-write alongside App Insights)')
param auditTableName string = 'auditevents'
@description('Name of the Azure Table holding per-correlationId wipe action status. Polled by WipeStatusPollerFunction.')
param wipeStatusTableName string = 'wipestatus'
@description('NCRONTAB expression for the wipe-action status poller. Default: every 2 minutes (tight polling for prompt operator visibility on stuck wipes).')
param wipeStatusPollerCron string = '0 */2 * * * *'

// Idempotency ledger re-arm controls (see IdempotencyService for behaviour).
// Defaults are dev-friendly; tighten in prod via main.parameters.json.
@description('Max wipes per device per 24h. Hard ceiling enforced by the ledger.')
param idempotencyMaxWipesPerDay int = 5
@description('Hours to wait before auto-rearming a ledger whose previous wipe ended in pollTimeout.')
param idempotencyRearmGracePeriodHours int = 48
@description('If true, the X-Force-Rearm HTTP header bypasses the tracker-based rearm gate. Keep false in prod.')
param idempotencyAllowForceRearm bool = true
@description('If true, the /api/admin/wipe-ledger/* endpoints are reachable (function key still required). Default false in prod.')
param idempotencyAdminApiEnabled bool = true

@description('If true, provisions an Azure Automation Account + PowerShell 7.2 runbook (Invoke-DeviceWipe) as an alternative wipe executor. Demo of the plug-in model: same input envelope, different runtime.')
param enableRunbookVariant bool = true

var suffix = uniqueString(resourceGroup().id)
var stWebRaw = toLower('${namePrefix}stw${suffix}')
var stWebName = length(stWebRaw) > 24 ? substring(stWebRaw, 0, 24) : stWebRaw
var stProcRaw = toLower('${namePrefix}stp${suffix}')
var stProcName = length(stProcRaw) > 24 ? substring(stProcRaw, 0, 24) : stProcRaw
var webName    = toLower('${namePrefix}-web-${suffix}')
var procName   = toLower('${namePrefix}-proc-${suffix}')
var aiName     = toLower('${namePrefix}-ai-${suffix}')
var lawName    = toLower('${namePrefix}-law-${suffix}')
var uamiName    = toLower('${namePrefix}-uami-${suffix}')      // worker identity (Graph-consented)
var uamiWebName = toLower('${namePrefix}-uami-web-${suffix}')   // public web identity (NO Graph)
// Separate App Service Plans for host-level isolation between the Internet-
// facing app and the Graph-privileged worker. Linux EP1 (cheaper than Windows,
// native host for dotnet-isolated). Each plan = different underlying VMs, so
// a hypothetical sandbox/host escape on the public surface cannot read the
// worker process' environment (which holds the Graph-consented UAMI token).
var planWebName  = toLower('${namePrefix}-plan-web-${suffix}')
var planProcName = toLower('${namePrefix}-plan-proc-${suffix}')
var planWipeName = toLower('${namePrefix}-plan-wipe-${suffix}')

// Dedicated wipe-runner Function App + identity (privileged Graph identity
// lives here EXCLUSIVELY, isolated from the generic dispatcher on the worker).
var wipeName     = toLower('${namePrefix}-wipe-${suffix}')
var uamiWipeName = toLower('${namePrefix}-uami-wipe-${suffix}')
var stWipeRaw    = toLower('${namePrefix}stwp${suffix}')
var stWipeName   = length(stWipeRaw) > 24 ? substring(stWipeRaw, 0, 24) : stWipeRaw

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

// Web app's runtime storage. Holds ONLY AzureWebJobsStorage data (host lease,
// run-from-package zip, secrets). The web identity has Blob Data Owner here
// because the Functions host requires it; this account is isolated from the
// worker's deployment artifact and from the wipe ledger.
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

// Worker app's runtime storage. Also hosts the wipe queue (web identity has
// Sender-only on the queue resource) and the idempotency ledger container.
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

resource queueSvc 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storageProc
  name: 'default'
}

resource wipeQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueSvc
  name: wipeQueueName
}

// Plug-in router queue. Produced by WipeProcessorFunction (and any future
// producer), consumed by ActionDispatchFunction which fans out to the
// matching IActionRunner.
resource actionDispatchQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueSvc
  name: actionDispatchQueueName
}

// Per-capability dedicated queue for the wipe runner. Producer:
// WipeForwardingRunner on the worker (Sender-only). Consumer:
// WipeActionConsumerFunction on the wipe-runner Function App
// (Storage Queue Data Contributor scoped to this queue).
resource wipeActionQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueSvc
  name: wipeActionQueueName
}

resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageProc
  name: 'default'
}

resource ledgerContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobSvc
  name: ledgerContainerName
  properties: { publicAccess: 'None' }
}

// Pre-provisioned table for long-term audit event persistence. Worker
// (AuditTableSink) auto-creates on miss in dev, but explicit declaration
// here keeps RBAC + lifecycle policies attachable from IaC.
resource tableSvcProc 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storageProc
  name: 'default'
}
resource auditTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableSvcProc
  name: auditTableName
}
resource wipeStatusTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableSvcProc
  name: wipeStatusTableName
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

// Dedicated identity for the wipe-runner Function App. After deployment, the
// privileged Graph permissions (DeviceManagementManagedDevices.PrivilegedOperations.All
// + Read.All + Device.Read.All + GroupMember.Read.All) MUST be granted to
// THIS principal via the README post-deploy script. The worker identity
// (uami) should NOT carry these permissions in the target state.
resource uamiWipe 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiWipeName
  location: location
}

// Wipe-runner app's runtime storage. Isolated from web and worker accounts
// so the Functions host requirements (lease/secrets/scale tables) don't
// inflate the privilege surface on shared infrastructure.
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

resource planWeb 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planWebName
  location: location
  sku: { name: 'EP1', tier: 'ElasticPremium' }
  kind: 'elastic'
  // reserved: true marks the plan as Linux. Required for linuxFxVersion on sites.
  properties: {
    reserved: true
    maximumElasticWorkerCount: 5
  }
}

resource planProc 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planProcName
  location: location
  sku: { name: 'EP1', tier: 'ElasticPremium' }
  kind: 'elastic'
  properties: {
    reserved: true
    maximumElasticWorkerCount: 5
  }
}

// Dedicated plan for the wipe-runner. Separate from planProc so a runaway
// wipe capability cannot starve the generic dispatcher (or vice versa) and
// scaling is independent per capability.
resource planWipe 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planWipeName
  location: location
  sku: { name: 'EP1', tier: 'ElasticPremium' }
  kind: 'elastic'
  properties: {
    reserved: true
    maximumElasticWorkerCount: 5
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Public Function App (web): hosts only the HTTP trigger (WipeRequest).
// mTLS terminated by App Service. Identity has NO Graph permissions.
// ───────────────────────────────────────────────────────────────────────────
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
    // Admin/operator endpoints don't use mTLS device auth — they rely on the
    // function key plus the Idempotency:AdminApiEnabled kill switch. Exempt
    // the wipe-ledger admin path from the device-cert requirement.
    clientCertExclusionPaths: '/api/wipe-ledger'
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
        // Azure App Configuration (centralized settings, with refresh sentinel).
        { name: 'AppConfig__Endpoint', value: appConfig.properties.endpoint }
        // App role guard: in-code defense-in-depth (AzureWebJobs disabled is unreliable on isolated).
        { name: 'App__Role', value: 'web' }
        // Selector: keep only the HTTP trigger on this app.
        { name: 'AzureWebJobs.WipeProcessor.Disabled', value: 'true' }
        { name: 'AzureWebJobs.WipeStatusPoller.Disabled', value: 'true' }
        // The plug-in router lives on the worker app — disable here so the
        // web app doesn't try to bind the action-dispatch queue trigger.
        { name: 'AzureWebJobs.ActionDispatch.Disabled', value: 'true' }
        // The wipe-action consumer lives on the dedicated wipe-runner app.
        { name: 'AzureWebJobs.WipeAction.Disabled', value: 'true' }
        // Queue write (enqueue only — identity has Sender role on the queue
        // resource of the *worker's* storage account, not on this app's runtime
        // storage).
        { name: 'Queue__StorageAccount', value: storageProc.name }
        { name: 'Queue__WipeQueueName', value: wipeQueueName }
        // Audit persistence (dual-write to Table Storage alongside App Insights).
        { name: 'Audit__StorageAccount', value: storageProc.name }
        { name: 'Audit__TableName', value: auditTableName }
        // Idempotency ledger access (web reads/resets via admin endpoints).
        { name: 'Idempotency__StorageAccount',          value: storageProc.name }
        { name: 'Idempotency__BlobContainer',           value: ledgerContainerName }
        { name: 'Idempotency__AllowForceRearm',         value: string(idempotencyAllowForceRearm) }
        { name: 'Idempotency__AdminApiEnabled',         value: string(idempotencyAdminApiEnabled) }
        { name: 'Idempotency__MaxWipesPerDevicePerDay', value: string(idempotencyMaxWipesPerDay) }
        { name: 'Idempotency__RearmGracePeriodHours',   value: string(idempotencyRearmGracePeriodHours) }
        // Wipe status table (web reads for admin GET join view).
        { name: 'WipeStatus__TableName', value: wipeStatusTableName }
        // GraphWipeService is pulled in transitively by WipeStatusTracker (DI graph)
        // even though the web app never calls Graph. Required to avoid startup
        // construction failure of the admin endpoint resolver.
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
        // Must be true on App Service: even with clientCertMode=Required
        // App Service terminates TLS at the front-end and the validated
        // client cert is delivered to the app ONLY via the X-ARR-ClientCert
        // header — HttpContext.Connection.ClientCertificate is empty unless
        // Microsoft.AspNetCore.Authentication.Certificate forwarding is
        // wired up. Leaving this 'false' makes every request return
        // "client certificate missing" even when the client presented one.
        { name: 'ClientCert__TrustForwardedHeader',    value: 'true' }
        { name: 'ClientCert__DeviceIdBindingClaim',    value: deviceIdBindingClaim }
        { name: 'ClientCert__ThumbprintToDeviceMap',   value: clientCertThumbprintToDeviceMap }
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
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uami.id}': {} }
  }
  properties: {
    serverFarmId: planProc.id
    httpsOnly: true
    clientCertEnabled: false
    keyVaultReferenceIdentity: uami.id
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      linuxFxVersion: 'DOTNET-ISOLATED|10.0'
      scmIpSecurityRestrictionsUseMain: true
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',    value: 'dotnet-isolated' }
        { name: 'WEBSITE_RUN_FROM_PACKAGE',    value: '1' }
        { name: 'AzureWebJobsStorage__accountName', value: storageProc.name }
        { name: 'AzureWebJobsStorage__credential',  value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId',    value: uami.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: ai.properties.ConnectionString }
        { name: 'AZURE_CLIENT_ID', value: uami.properties.clientId }
        // Azure App Configuration (centralized settings, with refresh sentinel).
        { name: 'AppConfig__Endpoint', value: appConfig.properties.endpoint }
        // App role guard: in-code defense-in-depth (AzureWebJobs disabled is unreliable on isolated).
        { name: 'App__Role', value: 'proc' }
        // Selector: keep only the queue trigger on this app.
        { name: 'AzureWebJobs.WipeRequest.Disabled', value: 'true' }
        { name: 'WipeStatus__TableName', value: wipeStatusTableName }
        { name: 'WipeStatusPoller__CronExpression', value: wipeStatusPollerCron }
        // Queue + ledger live in this app's own storage account.
        { name: 'Queue__StorageAccount', value: storageProc.name }
        { name: 'Queue__WipeQueueName', value: wipeQueueName }
        { name: 'Actions__DispatchQueueName', value: actionDispatchQueueName }
        // Forwarding to the dedicated wipe-runner Function App (Option-2
        // architecture). The worker only enqueues; the actual Graph call is
        // performed on the wipe-runner app.
        { name: 'WipeAction__QueueName', value: wipeActionQueueName }
        // The WipeAction queue trigger does NOT live on this app — disable to
        // avoid the host attempting to bind it here.
        { name: 'AzureWebJobs.WipeAction.Disabled', value: 'true' }
        { name: 'Idempotency__BlobContainer', value: ledgerContainerName }
        { name: 'Idempotency__StorageAccount', value: storageProc.name }
        { name: 'Idempotency__AllowForceRearm',         value: string(idempotencyAllowForceRearm) }
        { name: 'Idempotency__AdminApiEnabled',         value: string(idempotencyAdminApiEnabled) }
        { name: 'Idempotency__MaxWipesPerDevicePerDay', value: string(idempotencyMaxWipesPerDay) }
        { name: 'Idempotency__RearmGracePeriodHours',   value: string(idempotencyRearmGracePeriodHours) }
        // Audit persistence (dual-write to Table Storage alongside App Insights).
        { name: 'Audit__StorageAccount', value: storageProc.name }
        { name: 'Audit__TableName', value: auditTableName }
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

// RBAC: identity-based AzureWebJobsStorage. Each function app's UAMI gets
// Blob + Queue + Table data-plane on its own runtime storage account
// (Functions host requires all three for leases, secret repository, timer
// singleton locks and the scale controller). On top of that, the web
// identity gets Queue Data Message Sender on the worker's wipe queue
// (enqueue-only), and the worker identity has full Blob/Queue/Table on its
// own storage for the queue trigger + ledger.
var blobDataOwner         = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var queueDataContributor  = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
var tableDataContributor  = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
// Sender is enqueue-only — does NOT allow read/peek/delete on the queue.
var queueDataMessageSender = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'c6a89b2d-59bc-44d0-9896-0f6e12d7b80a')
var blobDataContributor    = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

// Worker identity → full data-plane on its own storage account.
// Functions host (identity-based AzureWebJobsStorage) needs Blob (host lease
// + secret repository when no Key Vault is configured), Queue (singleton +
// the WipeProcessor trigger) and Table (timer triggers, scale controller).
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

// Web identity → full data-plane on its OWN runtime storage account
// (Functions host requires Blob+Queue+Table even when there are no
// queue/table bindings — host internals use them for leases, secrets,
// singleton locks and the scale controller). On the *worker's* storage
// account the web identity only gets Queue Data Message Sender, scoped to
// the single wipe queue resource (enqueue-only, no read/peek/delete).
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
resource raWebQueueSend 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(wipeQueue.id, uamiWeb.id, 'queue-send')
  scope: wipeQueue
  properties: { roleDefinitionId: queueDataMessageSender, principalId: uamiWeb.properties.principalId, principalType: 'ServicePrincipal' }
}

// Web identity needs Table Data Contributor on the worker's storage account
// so AuditTableSink can write HTTP-path audit events (AcceptedQueued, denials,
// replay, cert validation failures) to the shared audit table.
resource raWebTableOnProc 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageProc.id, uamiWeb.id, 'table-audit')
  scope: storageProc
  properties: { roleDefinitionId: tableDataContributor, principalId: uamiWeb.properties.principalId, principalType: 'ServicePrincipal' }
}

// Admin ledger endpoints (web app) need to read+reset blobs in the wipe-ledger
// container on the worker's storage account. Scoped to the single container,
// least privilege: no access to any other blob namespace (eml archives,
// AzureWebJobs internals, etc.).
resource raWebLedger 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ledgerContainer.id, uamiWeb.id, 'blob-ledger')
  scope: ledgerContainer
  properties: { roleDefinitionId: blobDataContributor, principalId: uamiWeb.properties.principalId, principalType: 'ServicePrincipal' }
}

// Worker identity → Sender on the per-capability wipe-action queue. The
// WipeForwardingRunner uses ONLY this enqueue path; no read/peek/delete
// is granted on this queue, so the worker cannot consume its own forwards.
resource raProcWipeActionSend 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(wipeActionQueue.id, uami.id, 'queue-send')
  scope: wipeActionQueue
  properties: { roleDefinitionId: queueDataMessageSender, principalId: uami.properties.principalId, principalType: 'ServicePrincipal' }
}

// ───────────────────────────────────────────────────────────────────────────
// Dedicated wipe-runner Function App: hosts ONLY WipeActionConsumerFunction.
// Privileged Graph identity (DeviceManagementManagedDevices.PrivilegedOperations.All)
// MUST be granted to uamiWipe (post-deploy script). This app is the only one
// in the topology authorized to execute managedDevices/{id}/wipe.
// ───────────────────────────────────────────────────────────────────────────
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
    clientCertEnabled: false
    keyVaultReferenceIdentity: uamiWipe.id
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      linuxFxVersion: 'DOTNET-ISOLATED|10.0'
      scmIpSecurityRestrictionsUseMain: true
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',    value: 'dotnet-isolated' }
        { name: 'WEBSITE_RUN_FROM_PACKAGE',    value: '1' }
        { name: 'AzureWebJobsStorage__accountName', value: storageWipe.name }
        { name: 'AzureWebJobsStorage__credential',  value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId',    value: uamiWipe.properties.clientId }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: ai.properties.ConnectionString }
        { name: 'AZURE_CLIENT_ID', value: uamiWipe.properties.clientId }
        // Azure App Configuration (centralized settings, with refresh sentinel).
        { name: 'AppConfig__Endpoint', value: appConfig.properties.endpoint }
        // App role guard: this app is the dedicated wipe-runner.
        { name: 'App__Role', value: 'wipe' }
        // Selector: keep ONLY the wipe-action consumer enabled here.
        { name: 'AzureWebJobs.WipeRequest.Disabled',       value: 'true' }
        { name: 'AzureWebJobs.WipeStatus.Disabled',        value: 'true' }
        { name: 'AzureWebJobs.WipeProcessor.Disabled',     value: 'true' }
        { name: 'AzureWebJobs.WipeStatusPoller.Disabled',  value: 'true' }
        { name: 'AzureWebJobs.ActionDispatch.Disabled',    value: 'true' }
        { name: 'AzureWebJobs.WipeLedger_Get.Disabled',    value: 'true' }
        { name: 'AzureWebJobs.WipeLedger_Reset.Disabled',  value: 'true' }
        // Per-capability queue consumed by WipeActionConsumerFunction.
        { name: 'WipeAction__QueueName',  value: wipeActionQueueName }
        { name: 'Queue__StorageAccount',  value: storageProc.name }
        // Idempotency ledger (Reserve/MarkIssued executed by WipeActionRunner here).
        { name: 'Idempotency__BlobContainer',           value: ledgerContainerName }
        { name: 'Idempotency__StorageAccount',          value: storageProc.name }
        { name: 'Idempotency__AllowForceRearm',         value: string(idempotencyAllowForceRearm) }
        { name: 'Idempotency__AdminApiEnabled',         value: 'false' }
        { name: 'Idempotency__MaxWipesPerDevicePerDay', value: string(idempotencyMaxWipesPerDay) }
        { name: 'Idempotency__RearmGracePeriodHours',   value: string(idempotencyRearmGracePeriodHours) }
        // Audit + wipe-status tables shared with the worker.
        { name: 'Audit__StorageAccount', value: storageProc.name }
        { name: 'Audit__TableName',      value: auditTableName }
        { name: 'WipeStatus__TableName', value: wipeStatusTableName }
        // Microsoft Graph wipe call (privileged).
        { name: 'Graph__TenantId', value: graphTenantId }
        { name: 'Graph__ManagedIdentityClientId', value: uamiWipe.properties.clientId }
        { name: 'Wipe__AllowedGroupId',     value: allowedGroupId }
        { name: 'Wipe__KeepEnrollmentData', value: string(keepEnrollmentData) }
        { name: 'Wipe__KeepUserData',       value: string(keepUserData) }
      ]
    }
  }
}

// Wipe-runner identity → full data-plane on its OWN runtime storage account
// (Functions host requirement for lease/secrets/scale).
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

// Wipe-runner identity → consumer (full Queue Data Contributor) on the
// wipe-action queue resource only. Scoping to the queue resource (not the
// account) keeps least privilege.
resource raWipeActionConsume 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(wipeActionQueue.id, uamiWipe.id, 'queue-consume')
  scope: wipeActionQueue
  properties: { roleDefinitionId: queueDataContributor, principalId: uamiWipe.properties.principalId, principalType: 'ServicePrincipal' }
}

// Wipe-runner identity → Blob Data Contributor on the ledger container
// (Reserve/MarkIssued/MarkFailed live in WipeActionRunner which now runs here).
resource raWipeLedger 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ledgerContainer.id, uamiWipe.id, 'blob-ledger')
  scope: ledgerContainer
  properties: { roleDefinitionId: blobDataContributor, principalId: uamiWipe.properties.principalId, principalType: 'ServicePrincipal' }
}

// Wipe-runner identity → Table Data Contributor on the worker's storage
// account so it can write audit events and upsert wipe-status rows.
// Account-scoped because both tables (auditevents + wipestatus) live there
// and getting individual table-scope is messier with current ARM resource model.
resource raWipeTableOnProc 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageProc.id, uamiWipe.id, 'table-shared')
  scope: storageProc
  properties: { roleDefinitionId: tableDataContributor, principalId: uamiWipe.properties.principalId, principalType: 'ServicePrincipal' }
}

// ───────────────────────────────────────────────────────────────────────────
// Optional: Azure Automation Account + PowerShell 7.2 runbook variant.
// Demonstrates the plug-in model: the same "wipe" capability can be executed
// by a PowerShell runtime alongside the dotnet-isolated WipeActionConsumerFunction.
// The runbook content itself is uploaded post-deploy via:
//   az automation runbook replace-content … --content @runbooks/Invoke-DeviceWipe.runbook.ps1
//   az automation runbook publish …
// ───────────────────────────────────────────────────────────────────────────
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

// Automation MI → Blob Data Contributor on the ledger container (idempotency).
resource raAaLedger 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableRunbookVariant) {
  name: guid(ledgerContainer.id, automationAccount.id, 'aa-blob-ledger')
  scope: ledgerContainer
  properties: { roleDefinitionId: blobDataContributor, principalId: automationAccount.identity.principalId, principalType: 'ServicePrincipal' }
}

// Automation MI → Table Data Contributor on storageProc (audit + wipestatus).
resource raAaTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableRunbookVariant) {
  name: guid(storageProc.id, automationAccount.id, 'aa-table')
  scope: storageProc
  properties: { roleDefinitionId: tableDataContributor, principalId: automationAccount.identity.principalId, principalType: 'ServicePrincipal' }
}

// ───────────────────────────────────────────────────────────────────────────
// Azure App Configuration — centralized config store for all three Function
// Apps. Each app reads:
//   * keys with NO label  → shared defaults
//   * keys with label = App__Role (web|proc|wipe) → per-app overrides
// A 'Sentinel' key (bumped manually or via deploy) triggers reload of any
// refresh-flagged key (e.g. Wipe:ActionType) without restarting the workers.
// Local auth is disabled — all access via UAMI + App Configuration Data Reader.
// ───────────────────────────────────────────────────────────────────────────
var appConfigName = toLower('${namePrefix}-appcfg-${suffix}')

resource appConfig 'Microsoft.AppConfiguration/configurationStores@2024-05-01' = {
  name: appConfigName
  location: location
  sku: { name: 'standard' }
  properties: {
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    enablePurgeProtection: false
    // Required so ARM-driven Microsoft.AppConfiguration/.../keyValues
    // resources (declared below) can write through ARM even though
    // local data-plane auth is disabled.
    dataPlaneProxy: {
      authenticationMode: 'Pass-through'
      privateLinkDelegation: 'Disabled'
    }
  }
}

// Seed keys are provisioned OUT-OF-BAND (CLI/portal) — not via Bicep —
// because data-plane ARM writes against a store with disableLocalAuth=true
// require the deployer to have App Configuration Data Owner with full RBAC
// propagation, which is brittle in CI. Bootstrap is performed by
// `tools/seed-appconfig.ps1` (or the equivalent `az appconfig kv set`
// commands documented in the README). Bicep owns ONLY the store + RBAC.

// RBAC: App Configuration Data Reader for every consumer identity.
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

output appConfigName string = appConfig.name
output appConfigEndpoint string = appConfig.properties.endpoint

output webAppName string = funcWeb.name
output webAppHostname string = funcWeb.properties.defaultHostName
output procAppName string = funcProc.name
output procAppHostname string = funcProc.properties.defaultHostName
output wipeAppName string = funcWipe.name
output wipeAppHostname string = funcWipe.properties.defaultHostName
output uamiWorkerClientId string = uami.properties.clientId
output uamiWorkerPrincipalId string = uami.properties.principalId
output uamiWebClientId string = uamiWeb.properties.clientId
output uamiWebPrincipalId string = uamiWeb.properties.principalId
output uamiWipeClientId string = uamiWipe.properties.clientId
output uamiWipePrincipalId string = uamiWipe.properties.principalId
output storageWebAccount string = storageWeb.name
output storageProcAccount string = storageProc.name
output storageWipeAccount string = storageWipe.name
output wipeQueueName string = wipeQueueName
output wipeActionQueueName string = wipeActionQueueName
output ledgerContainerName string = ledgerContainerName
output automationAccountName string = enableRunbookVariant ? automationAccount.name : ''
output runbookName string = enableRunbookVariant ? runbookName : ''
output automationPrincipalId string = enableRunbookVariant ? automationAccount.identity.principalId : ''
