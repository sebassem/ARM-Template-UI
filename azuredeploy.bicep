// Parameters
param webAppName string
param location string = resourceGroup().location
@allowed([
  'S1'
  'S2'
  'S3'
  'B1'
])
param skuName string = 'S1'

@allowed([
  'NODE|16-lts'
  'DOTNETCORE|3.0'
])
param runtime string = 'NODE|16-lts'
param deployGw bool = false
param deployCosmos bool = true
@allowed([
  'Strong'
  'ConsistentPrefix'
])
param defaultConsistencyLevel string = 'ConsistentPrefix'
param isZoneRedundant bool = false
param enableAutomaticFailover bool = false
param enableFreeTier bool = true

@allowed([
  'WAF_v2'
  'Standard_v2'
])
param appGwSku string = 'Standard_v2'
param gwCapacity int = 2
param enableHttp2 bool = false

param cosmosDbName string = '${webAppName}-db-${uniqueString(resourceGroup().id)}'
param vnetName string = 'vnet001'
param appGwName string = '${webAppName}-appGw'
var appSettingsWithCosmos = [
  {
    name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
    value: appInsights.properties.InstrumentationKey
  }
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsights.properties.ConnectionString
  }
  {
    name: 'DOCUMENTDB_ENDPOINT'
    value: cosmosDB.properties.documentEndpoint
  }
  {
    name: 'DOCUMENTDB_PRIMARY_KEY'
    value: cosmosDB.listKeys().primaryMasterKey
  }
]

var appSettingsWithoutCosmos = [
  {
    name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
    value: appInsights.properties.InstrumentationKey
  }
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsights.properties.ConnectionString
  }
]

// Variables
var appServicePlanName = 'plan-${uniqueString(resourceGroup().id)}'
var appgw_id = resourceId('Microsoft.Network/applicationGateways', appGwName)

// Resources
resource appServicePlan 'Microsoft.Web/serverfarms@2021-03-01'= {
  name: appServicePlanName
  location: location
  kind: 'app,linux'
  properties: {
    reserved: true
  }
  sku: {
    name: skuName
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'insights-${webAppName}'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

resource webApp 'Microsoft.Web/sites@2021-03-01'= {
  name: webAppName
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      ipSecurityRestrictions: deployGw ? [
        {
          ipAddress : '${publicIP.properties.ipAddress}/32'
        }
      ] : json('null')
      linuxFxVersion: runtime
      appSettings: deployCosmos ? appSettingsWithCosmos : appSettingsWithoutCosmos
    }
  }
}

resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts@2021-11-15-preview' = if(deployCosmos){
  name: cosmosDbName
  location: location
  properties: {
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: isZoneRedundant

      }
    ]
    databaseAccountOfferType: 'Standard'
    enableAutomaticFailover: enableAutomaticFailover
    enableFreeTier: enableFreeTier
    consistencyPolicy: {
      defaultConsistencyLevel: defaultConsistencyLevel
    }

  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2021-05-01' = if(deployGw){
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '192.168.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'default'
        properties:{
          addressPrefix: '192.168.1.0/24'
        }
      }
      {
        name: 'appGWSubnet'
        properties: {
          addressPrefix: '192.168.2.0/24'
        }
      }
    ]
  }
}

resource publicIP 'Microsoft.Network/publicIPAddresses@2021-05-01'= if(deployGw){
  name: '${webAppName}-PIP'
  location: location
  properties:{
    publicIPAllocationMethod: 'Static'
  }
  sku: {
    name: 'Standard'
  }
}

resource appGw 'Microsoft.Network/applicationGateways@2021-05-01'= if(deployGw){
  name: appGwName
  location: location
  properties: {
    sku: {
      name: appGwSku
      tier: appGwSku
      capacity: gwCapacity
    }
    enableHttp2: enableHttp2
    backendAddressPools: [
      {
        name: 'webApp-pool'
        properties: {
          backendAddresses: [
            {
              fqdn: webApp.properties.hostNames[0]
            }
          ]
        }
      }
    ]
    gatewayIPConfigurations: [
      {
        name: 'gatewayIPConfig'
        properties: {
          subnet: {
            id: deployGw ? vnet.properties.subnets[1].id : json('null')
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'frontend-config'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIP.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port_80'
        properties: {
          port: 80
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'backendHTTPsetting'
        properties: {
          pickHostNameFromBackendAddress: true
          port: 80
          protocol: 'Http'
        }
      }
    ]
    httpListeners: [
      {
        name: 'httpListeners'
        properties: {
          protocol: 'Http'
          frontendIPConfiguration: {
            id: '${appgw_id}/frontendIPConfigurations/frontend-config'
          }
          frontendPort: {
            id: '${appgw_id}/frontendPorts/port_80'
          }
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'routingRule01'
        properties: {
          ruleType: 'Basic'
          httpListener: {
            id: '${appgw_id}/httpListeners/httpListeners'
          }
          backendAddressPool: {
            id: '${appgw_id}/backendAddressPools/webApp-pool'
          }
          backendHttpSettings: {
            id: '${appgw_id}/backendHttpSettingsCollection/backendHTTPsetting'
          }
        }
      }
    ]
  }
}
