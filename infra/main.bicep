// =============================================================================
// main.bicep
// Deploys an Azure API Management (APIM) instance.
//
// Defaults target the **Premium v2** SKU in **internal VNet mode** with
// private endpoint readiness — matching the production topology. For
// ephemeral / PR environments callers typically override `sku` to a cheaper
// tier and skip the VNet wiring by leaving `subnetResourceId` empty.
//
// Inspired by Azure Verified Modules (AVM) style guidance:
//   * parameterise every meaningful knob
//   * sensible, opinionated defaults
//   * useful outputs for downstream pipelines
// =============================================================================

@description('Name of the APIM instance. 1-50 chars, globally unique.')
@minLength(1)
@maxLength(50)
param apimName string

@description('Azure region for the APIM instance.')
param location string = resourceGroup().location

@description('Publisher email shown in the developer portal & sent admin notifications.')
param publisherEmail string

@description('Publisher organisation name shown in the developer portal.')
param publisherName string

@description('APIM SKU. Use `Premium` or `PremiumV2` (where GA) for production. `Developer` is the cheapest and is ideal for ephemeral PR environments.')
@allowed([
  'Developer'
  'Basic'
  'Standard'
  'Premium'
  'PremiumV2'
])
param sku string = 'Premium'

@description('Number of scale units. Premium supports >1.')
@minValue(1)
@maxValue(12)
param capacity int = 1

@description('VNet integration mode. `None` for ephemeral PR environments, `Internal` for production.')
@allowed([
  'None'
  'External'
  'Internal'
])
param virtualNetworkType string = 'Internal'

@description('Resource ID of the subnet to delegate APIM into. Required when virtualNetworkType != None.')
param subnetResourceId string = ''

@description('Tags applied to every resource.')
param tags object = {
  workload: 'apim-policy-pipeline'
  managedBy: 'bicep'
}

// -----------------------------------------------------------------------------
// APIM
// -----------------------------------------------------------------------------
resource apim 'Microsoft.ApiManagement/service@2023-05-01-preview' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: sku
    capacity: capacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    virtualNetworkType: virtualNetworkType
    virtualNetworkConfiguration: virtualNetworkType == 'None' ? null : {
      subnetResourceId: subnetResourceId
    }
    // Hardened defaults: disable legacy protocols & ciphers, enforce TLS 1.2+.
    customProperties: {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.TLS10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.TLS11': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls11': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Ssl30': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Protocols.Server.Http2': 'true'
    }
    publicNetworkAccess: virtualNetworkType == 'Internal' ? 'Disabled' : 'Enabled'
  }
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------
@description('Resource ID of the APIM service.')
output apimResourceId string = apim.id

@description('Default gateway hostname. Internal-mode APIM resolves only inside the VNet.')
output apimGatewayHostname string = apim.properties.gatewayUrl

@description('Principal ID of the system-assigned managed identity (use for Key Vault access policies etc.).')
output apimPrincipalId string = apim.identity.principalId
