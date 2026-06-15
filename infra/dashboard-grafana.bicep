targetScope = 'resourceGroup'

// ─────────────────────────────────────────────────────────────────────────────
// IntuneDeviceActions — operator dashboard on Azure Managed Grafana.
//
// Provisioned as a standalone module (per repo convention: main.bicep grows
// additively, and a Grafana instance has no dependencies on app code or
// existing infra). Deploy with:
//   az deployment group create -g RG-INTUNE-DEVICEACTIONS \
//     -f infra/dashboard-grafana.bicep \
//     -p sbNamespaceName=idactions-sb-dev appInsightsName=idactions-ai-dev \
//        ledgerStorageAccountName=idactionsstpdev operatorObjectId=<your-oid>
//
// After the first deployment:
//   1. Log in to the Grafana endpoint (output `grafanaEndpoint`).
//   2. Add data sources: Azure Monitor (auto via MSI), Application Insights
//      (same data source, point at the AI workspace).
//   3. Import infra/grafana/intunedeviceactions-dashboard.json from the repo.
//
// The Grafana MSI is granted Monitoring Reader on the RG so it can query
// Azure Monitor metrics for the SB namespace and the Function Apps; and
// Storage Blob Data Reader on the ledger storage account so future custom
// panels backed by the BlobContainerClient (via a Function App proxy) keep
// working when added.
// ─────────────────────────────────────────────────────────────────────────────

@description('Name prefix used to align with the existing app stamp. Keep the same prefix as main.bicep.')
@minLength(3)
@maxLength(12)
param namePrefix string = 'idactions'

@description('Suffix to distinguish the dev/prod stamp. Match the suffix used by your *-<suffix> Function Apps.')
param suffix string = 'dev'

@description('Azure region. Managed Grafana is not available in every region — westeurope, northeurope, italynorth (preview) all work; check current availability if you hit a deployment error.')
param location string = resourceGroup().location

@description('Object ID (oid) of the operator who should receive Grafana Admin on this instance. Required.')
param operatorObjectId string

@description('Name of the Service Bus namespace whose queues feed the dashboard panels. Used only for the role-assignment scope.')
param sbNamespaceName string

@description('Application Insights component name backing the KQL panels.')
param appInsightsName string

@description('Storage account hosting the action-ledger blob container.')
param ledgerStorageAccountName string

@description('SKU for the managed Grafana instance. Essentials is the cheapest paid SKU (~$10/mo).')
@allowed([
  'Essential'
  'Standard'
])
param grafanaSku string = 'Essential'

// ─────────────────────────────────────────────────────────────────────────────
// Resources
// ─────────────────────────────────────────────────────────────────────────────

resource grafana 'Microsoft.Dashboard/grafana@2024-10-01' = {
  name: '${namePrefix}-grafana-${suffix}'
  location: location
  sku: {
    name: grafanaSku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    apiKey: 'Disabled'
    deterministicOutboundIP: 'Disabled'
    publicNetworkAccess: 'Enabled'
    grafanaMajorVersion: '11'
    zoneRedundancy: 'Disabled'
  }
}

// Existing resources we'll bind role assignments to. Looked up at deploy time
// — they MUST already exist (created by main.bicep), this module never
// modifies them.
resource sb 'Microsoft.ServiceBus/namespaces@2024-01-01' existing = {
  name: sbNamespaceName
}
resource ai 'Microsoft.Insights/components@2020-02-02' existing = {
  name: appInsightsName
}
resource ledgerSa 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: ledgerStorageAccountName
}

// Built-in role definition IDs.
var roleMonitoringReader      = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
var roleStorageBlobDataReader = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
var roleGrafanaAdmin          = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '22926164-76b3-42b3-bc55-97df8dab3e41')

// Grafana MSI → Monitoring Reader on the SB namespace (queue depth metrics)
resource raGrafanaSb 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sb.id, grafana.id, 'MonitoringReader')
  scope: sb
  properties: {
    principalId: grafana.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleMonitoringReader
  }
}

// Grafana MSI → Monitoring Reader on App Insights (requests/dependencies KQL)
resource raGrafanaAi 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ai.id, grafana.id, 'MonitoringReader')
  scope: ai
  properties: {
    principalId: grafana.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleMonitoringReader
  }
}

// Grafana MSI → Storage Blob Data Reader on the ledger SA (for future panels
// that proxy ledger reads via a Function — currently the dashboard reaches
// the ledger via App Insights customEvents, but granting read here keeps the
// path open without requiring another redeploy).
resource raGrafanaLedger 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(ledgerSa.id, grafana.id, 'StorageBlobDataReader')
  scope: ledgerSa
  properties: {
    principalId: grafana.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleStorageBlobDataReader
  }
}

// Operator → Grafana Admin on the instance
resource raOperatorGrafanaAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(grafana.id, operatorObjectId, 'GrafanaAdmin')
  scope: grafana
  properties: {
    principalId: operatorObjectId
    principalType: 'User'
    roleDefinitionId: roleGrafanaAdmin
  }
}

output grafanaName     string = grafana.name
output grafanaEndpoint string = grafana.properties.endpoint
output grafanaPrincipalId string = grafana.identity.principalId
