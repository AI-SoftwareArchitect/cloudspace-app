@description('Prefix for resource names (lowercase, letters/numbers).')
param prefix string = toLower('app${uniqueString(resourceGroup().id)}')

@description('Location for all resources')
param location string = resourceGroup().location

@description('Linux runtime for webapp, e.g. "NODE|20-lts" or "PYTHON|3.11"')
param linuxFxVersion string = 'PYTHON|3.11'

@description('App Service plan SKU (F1 is free tier for learning).')
param appServiceSku string = 'F1'

@description('Storage account name (must be globally unique, lowercase, 3-24 chars).')
param storageAccountName string = toLower('${prefix}stg')

@description('File share name')
param fileShareName string = 'uploads'

@description('Cosmos DB account name (max 44 chars, lowercase).')
param cosmosAccountName string = toLower('${prefix}cosmos')

@description('Cosmos SQL database name')
param cosmosDatabaseName string = 'appdb'

@description('Cosmos SQL container name')
param cosmosContainerName string = 'items'

@description('Enable Azure Cognitive Search (set false to skip creating).')
param enableSearch bool = false

@description('Search service name (if enabled). must be lowercase, 2-60 chars.')
param searchServiceName string = toLower('${prefix}search')

/* --------- App Service Plan + Web App (Linux) --------- */
var appServicePlanName = toLower('plan-${prefix}')
var webAppName = toLower('web-${prefix}')

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: appServiceSku
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  kind: 'app'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: linuxFxVersion
      alwaysOn: false
      http20Enabled: true
      minTlsVersion: '1.2'
    }
    httpsOnly: true
  }
}

/* --------- Storage Account + File Share (Blob & Files) --------- */
resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

/* file service child resource */
resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2024-01-01' = {
  name: 'default'
  parent: storageAccount
}

/* create file share */
resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-01-01' = {
  parent: fileService
  name: fileShareName
  properties: {
    shareQuota: 5  // GiB; adjust if needed
  }
}

/* --------- Cosmos DB (Free-tier SQL API) --------- */
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2023-11-15' = {
  name: cosmosAccountName
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    enableFreeTier: true
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
      }
    ]
  }
}

/* Create a SQL database (shared throughput) */
resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2023-11-15' = {
  parent: cosmosAccount
  name: cosmosDatabaseName
  properties: {
    resource: {
      id: cosmosDatabaseName
    }
    options: {
      throughput: 400
    }
  }
}

/* Create a container */
resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-11-15' = {
  parent: cosmosDatabase
  name: cosmosContainerName
  properties: {
    resource: {
      id: cosmosContainerName
      partitionKey: {
        paths: [
          '/partitionKey'
        ]
        kind: 'Hash'
      }
    }
    options: {
      throughput: 400
    }
  }
}

/* --------- (Optional) Cognitive Search --------- */
resource searchService 'Microsoft.Search/searchServices@2020-08-01' = if (enableSearch) {
  name: searchServiceName
  location: location
  sku: {
    // free | basic | standard ...
    name: 'free'
  }
  properties: {
    partitionCount: 1
    replicaCount: 1
  }
}

/* --------- RBAC: grant Web App access to Storage (Blob Data) --------- */
var storageBlobDataContributorRoleGuid = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe' // Storage Blob Data Contributor

resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2020-10-01-preview' = {
  name: guid(storageAccount.id, webApp.identity.principalId, storageBlobDataContributorRoleGuid)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleGuid)
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    webApp
    storageAccount
  ]
}

/* --------- Cosmos DB data-plane role assignment (Cosmos built-in data contributor) --------- */
var cosmosDataContributorGuid = '00000000-0000-0000-0000-000000000002' // Cosmos DB Built-in Data Contributor

resource cosmosSqlRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2025-05-01-preview' = {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, webApp.identity.principalId, cosmosDataContributorGuid)
  properties: {
    principalId: webApp.identity.principalId
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/${cosmosDataContributorGuid}'
    scope: cosmosAccount.id
  }
  dependsOn: [
    cosmosAccount
    webApp
  ]
}

/* --------- Outputs --------- */
output webAppDefaultHostname string = webApp.properties.defaultHostName
output webAppId string = webApp.id
output storageAccountNameOut string = storageAccount.name
output fileShareNameOut string = fileShare.name
output cosmosAccountNameOut string = cosmosAccount.name
output cosmosEndpoint string = cosmosAccount.properties.documentEndpoint
output managedIdentityPrincipalId string = webApp.identity.principalId
