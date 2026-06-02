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

@description('APIM SKU. Use `Premium` or `PremiumV2` (where GA) for production. `Developer` is the cheapest and is ideal for ephemeral PR environments. `StandardV2` / `BasicV2` are the v2 platform tiers.')
@allowed([
  'Developer'
  'Basic'
  'BasicV2'
  'Standard'
  'StandardV2'
  'Premium'
  'PremiumV2'
])
param sku string = 'Premium'

@description('Number of scale units. Premium supports >1.')
@minValue(1)
@maxValue(12)
param capacity int = 1

@description('VNet integration mode. Must be `None` for v2 SKUs (StandardV2/PremiumV2) — v2 only supports outbound VNet integration via `virtualNetworkConfiguration`, never `Internal` mode. `Internal` is only valid for classic Developer/Premium tiers. The APIM RP returns `ManagingVirtualNetworkConfigurationNotSupported` if you set `Internal` on a v2 SKU.')
@allowed([
  'None'
  'External'
  'Internal'
])
param virtualNetworkType string = 'None'

@description('Desired publicNetworkAccess value. The APIM RP only accepts `Disabled` AFTER a private endpoint exists, so callers must pass `Enabled` on the first deploy. Subsequent deploys should pass the current live value (read via `az apim show`) so the lockdown flip done by the pipeline is preserved — see the deploy-dev job in `.github/workflows/ci.yml`. When `deployVirtualNetwork==false` (no PE) this is forced to `Enabled` regardless. Docs: https://learn.microsoft.com/azure/api-management/private-endpoint#optionally-disable-public-network-access')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

@description('Set to true (default) to deploy a new VNet with an APIM subnet (and Function App integration subnet when delegation is enabled). Set to false to BYO an existing subnet via `subnetResourceId`.')
param deployVirtualNetwork bool = true

@description('Resource ID of an EXISTING subnet to delegate APIM into. Required only when `deployVirtualNetwork` is false. When `deployVirtualNetwork` is true this is ignored and the new subnet is used.')
param subnetResourceId string = ''

@description('Name of the VNet to create (used only when `deployVirtualNetwork` is true).')
param vnetName string = '${apimName}-vnet'

@description('Address space for the new VNet (used only when `deployVirtualNetwork` is true).')
param vnetAddressPrefix string = '10.40.0.0/16'

@description('Address prefix for the APIM subnet (used only when `deployVirtualNetwork` is true). Must be /27 or larger for Premium/Developer SKUs.')
param apimSubnetAddressPrefix string = '10.40.1.0/27'

@description('Address prefix for the Function App regional VNet integration subnet (used only when `deployVirtualNetwork` is true and `enableDelegation` is true).')
param functionSubnetAddressPrefix string = '10.40.2.0/26'

@description('Address prefix for private endpoints (used only when `deployVirtualNetwork` is true).')
param privateEndpointSubnetAddressPrefix string = '10.40.3.0/27'

@description('Tags applied to every resource.')
param tags object = {
  workload: 'apim-policy-pipeline'
  managedBy: 'bicep'
}

// -----------------------------------------------------------------------------
// Auth0 integration (opt-in)
// -----------------------------------------------------------------------------
// Three independent feature switches:
//   * `auth0TenantDomain` non-empty       -> deploy APIM named values that the
//                                            validate-auth0-jwt policy fragment
//                                            resolves at request time.
//   * `enableDelegation` true             -> deploy Storage + Flex Consumption
//                                            Function App + Key Vault for the
//                                            delegation handler, configure
//                                            APIM portalsettings/delegation.
//   * `enableObservability` true (default) -> deploy Log Analytics + App
//                                            Insights + diagnostic settings
//                                            for every resource above.
// Existing dev deploys that pass none of the above (and disable observability)
// see no behavioural change.
// -----------------------------------------------------------------------------

@description('Auth0 tenant domain WITHOUT scheme/trailing slash, e.g. `contoso.auth0.com`. Empty disables the named values that the validate-auth0-jwt policy fragment depends on.')
param auth0TenantDomain string = ''

@description('Auth0 API Identifier (audience) the access tokens must be issued for, e.g. `https://api.contoso.example`. Required when auth0TenantDomain is set.')
param auth0Audience string = ''

@description('Deploy the developer portal delegation infrastructure (Key Vault, App Service shell, portalsettings/delegation). The handler code itself is BYO — see README.')
param enableDelegation bool = false

@description('Public URL of the delegation handler. When empty AND enableDelegation=true the URL of the provisioned App Service is used.')
param delegationHandlerUrl string = ''

@description('Hex/base64 validation key APIM uses to HMAC-SHA512-sign delegation request parameters. Generate with: `openssl rand -base64 48`. Stored in Key Vault, not in resource properties.')
@secure()
param delegationValidationKey string = ''

@description('Auth0 application client ID (a public value — NOT a secret). Required when enableDelegation=true.')
param auth0ClientId string = ''

@description('Auth0 application client secret. Stored in Key Vault; referenced by the Function App as a Key Vault reference.')
@secure()
param auth0ClientSecret string = ''

@description('Maximum number of Flex Consumption instances. Default 100 (the platform max for FC1).')
@minValue(40)
@maxValue(1000)
param delegationHandlerMaxInstances int = 100

@description('Instance memory (MB) for the Flex Consumption plan. Allowed values per platform: 512, 2048, 4096.')
@allowed([
  512
  2048
  4096
])
param delegationHandlerInstanceMemoryMB int = 2048

// -----------------------------------------------------------------------------
// Observability + governance (opt-in)
// -----------------------------------------------------------------------------

@description('Deploy Log Analytics workspace + Application Insights + diagnostic settings for APIM, KV, Storage, and the Function App. Required for the handler code’s Application Insights telemetry to actually flow.')
param enableObservability bool = true

@description('Log Analytics workspace retention in days (Pay-As-You-Go: 30-730).')
@minValue(30)
@maxValue(730)
param logRetentionDays int = 30

@description('Enable Key Vault purge protection. Once on it CANNOT be turned off for the lifetime of the vault. Strongly recommended for production.')
param keyVaultPurgeProtection bool = false

@description('Key Vault soft-delete retention in days. 7-90.')
@minValue(7)
@maxValue(90)
param keyVaultSoftDeleteRetentionDays int = 7

@description('Storage account redundancy. Standard_LRS for dev, Standard_ZRS or Standard_GZRS for production single-region / geo HA.')
@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GZRS'
  'Standard_RAGRS'
])
param delegationStorageSku string = 'Standard_LRS'

@description('Deploy a custom least-privilege role definition (users/read + users/write + users/token/action) and assign that to the handler MI instead of the broad `API Management Service Contributor`. Requires Microsoft.Authorization/roleDefinitions/write at the subscription scope.')
param useCustomApimRole bool = false

// -----------------------------------------------------------------------------
// Log Analytics workspace + Application Insights (workspace-based)
// -----------------------------------------------------------------------------
// Defined ahead of APIM so the APIM service/loggers child resource can
// reference the AI instrumentation key without ordering tricks.
// -----------------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = if (enableObservability) {
  name: '${apimName}-law'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (enableObservability) {
  name: '${apimName}-ai'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    DisableLocalAuth: false
  }
}

// -----------------------------------------------------------------------------
// Virtual Network (optional — set deployVirtualNetwork=false to BYO)
// -----------------------------------------------------------------------------
// Layout:
//   * apim                — delegated subnet for APIM Internal VNet mode.
//                           NSG must allow the APIM control-plane inbound
//                           rules documented at
//                           https://learn.microsoft.com/azure/api-management/api-management-using-with-internal-vnet
//   * functions           — regional VNet integration subnet for the Flex
//                           Consumption delegation Function App. Delegated
//                           to Microsoft.App/environments (Flex requirement).
//   * private-endpoints   — flat subnet for Key Vault / Storage private
//                           endpoints (not provisioned by this template,
//                           but the subnet is reserved so a follow-up PR
//                           can drop PEs in without re-IPing).
// -----------------------------------------------------------------------------

// APIM control-plane NSG: minimum required inbound rules for Internal VNet
// mode. Source: Microsoft Learn (link above).
resource apimNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = if (deployVirtualNetwork) {
  name: '${apimName}-apim-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowApimManagementInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '3443'
          sourceAddressPrefix: 'ApiManagement'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '6390'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowTrafficManagerInbound'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'AzureTrafficManager'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
    ]
  }
}

resource functionsNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = if (deployVirtualNetwork) {
  name: '${apimName}-functions-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource privateEndpointsNsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = if (deployVirtualNetwork) {
  name: '${apimName}-pe-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = if (deployVirtualNetwork) {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'apim'
        properties: {
          addressPrefix: apimSubnetAddressPrefix
          networkSecurityGroup: {
            id: apimNsg.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          // Required for APIM v2 (StandardV2/PremiumV2) outbound VNet
          // integration. v2 SKUs use regional VNet integration (same
          // mechanism as App Service / Functions), which requires the
          // subnet be delegated to `Microsoft.Web/serverFarms`.
          delegations: [
            {
              name: 'Microsoft.Web.serverFarms'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: 'functions'
        properties: {
          addressPrefix: functionSubnetAddressPrefix
          networkSecurityGroup: {
            id: functionsNsg.id
          }
          delegations: [
            {
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: 'private-endpoints'
        properties: {
          addressPrefix: privateEndpointSubnetAddressPrefix
          networkSecurityGroup: {
            id: privateEndpointsNsg.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// Resolved subnet ID used by APIM: the new subnet when we provisioned the
// VNet, otherwise the BYO `subnetResourceId` parameter. When BYO mode is
// chosen, an empty `subnetResourceId` will fail APIM validation at deploy
// time with a clear error.
var resolvedApimSubnetId = deployVirtualNetwork
  ? '${vnet.id}/subnets/apim'
  : subnetResourceId

// -----------------------------------------------------------------------------
// APIM
// -----------------------------------------------------------------------------
// publicNetworkAccess self-healing pattern:
//   * The pipeline (.github/workflows/ci.yml deploy-dev job) runs
//     `az apim show ... --query publicNetworkAccess` BEFORE calling Bicep
//     and passes the result as the `publicNetworkAccess` parameter.
//     - First deploy: APIM doesn't exist → pipeline passes `Enabled` (the
//       only value the RP accepts when there's no private endpoint yet).
//     - Subsequent deploys: pipeline passes the live value (`Disabled` after
//       the lockdown step has run), so Bicep never re-opens public access.
//   * Reading the value inside Bicep via an `existing` resource of the same
//     name creates a self-cycle, which is why this is parameter-driven.
//   * `deployVirtualNetwork==false` (ephemeral previews) hard-forces `Enabled`
//     regardless of the parameter — there's no PE to gate behind.
// Docs:
//   https://learn.microsoft.com/azure/api-management/private-endpoint#optionally-disable-public-network-access
// -----------------------------------------------------------------------------
var effectivePublicNetworkAccess = deployVirtualNetwork ? publicNetworkAccess : 'Enabled'

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
    // virtualNetworkType: keep 'None' for v2 SKUs (StandardV2/PremiumV2).
    // Only classic Developer/Premium accept 'Internal'/'External'.
    virtualNetworkType: virtualNetworkType
    // Outbound VNet integration. Wired whenever we provisioned a VNet,
    // regardless of virtualNetworkType — for v2 SKUs this is the *only*
    // VNet hookup; for classic SKUs it pairs with virtualNetworkType.
    virtualNetworkConfiguration: deployVirtualNetwork ? {
      subnetResourceId: resolvedApimSubnetId
    } : null
    // Hardened defaults: disable legacy protocols & ciphers, enforce TLS 1.2+.
    customProperties: {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.TLS10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.TLS11': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls10': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls11': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Ssl30': 'false'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Protocols.Server.Http2': 'true'
    }
    // See the comment block above this resource for how the pipeline keeps
    // this idempotent across re-runs.
    publicNetworkAccess: effectivePublicNetworkAccess
  }
}

// -----------------------------------------------------------------------------
// Private endpoint + private DNS zone for the APIM gateway
// -----------------------------------------------------------------------------
// Inbound private access path. Provisioned in the dedicated
// `private-endpoints` subnet of the VNet this template creates (or skipped
// entirely in BYO mode — the PE is then the caller's responsibility).
//
// Once this PE exists, the post-deploy step in `infra/deploy-local.ps1`
// can flip `publicNetworkAccess` to `Disabled` via `az apim update`.
// -----------------------------------------------------------------------------
resource apimPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-01-01' = if (deployVirtualNetwork) {
  name: '${apimName}-gateway-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: '${vnet.id}/subnets/private-endpoints'
    }
    privateLinkServiceConnections: [
      {
        name: 'gateway'
        properties: {
          privateLinkServiceId: apim.id
          groupIds: [
            'Gateway'
          ]
        }
      }
    ]
  }
}

resource apimPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (deployVirtualNetwork) {
  name: 'privatelink.azure-api.net'
  location: 'global'
  tags: tags
}

resource apimPrivateDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (deployVirtualNetwork) {
  parent: apimPrivateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource apimPrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-01-01' = if (deployVirtualNetwork) {
  parent: apimPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-azure-api-net'
        properties: {
          privateDnsZoneId: apimPrivateDnsZone.id
        }
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// APIM observability: logger (App Insights) + service-level diagnostics +
// gateway diagnostic settings to Log Analytics.
// -----------------------------------------------------------------------------
// Without this triplet, validate-jwt failures + gateway requests stay
// invisible. The logger object is the bridge between the APIM control
// plane and App Insights; `service/diagnostics/applicationinsights`
// is what actually emits per-request telemetry.
// -----------------------------------------------------------------------------
resource apimAppInsightsLogger 'Microsoft.ApiManagement/service/loggers@2023-05-01-preview' = if (enableObservability) {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Workspace-based Application Insights'
    resourceId: appInsights.id
    credentials: {
      // Using the AI connection string (preferred over instrumentation key).
      connectionString: appInsights.properties.ConnectionString
    }
    isBuffered: true
  }
}

resource apimAppInsightsDiagnostics 'Microsoft.ApiManagement/service/diagnostics@2023-05-01-preview' = if (enableObservability) {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerId: apimAppInsightsLogger.id
    alwaysLog: 'allErrors'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    httpCorrelationProtocol: 'W3C'
    verbosity: 'information'
    logClientIp: true
    frontend: {
      request: {
        headers: ['x-correlation-id']
      }
      response: {}
    }
    backend: {
      request: {}
      response: {}
    }
  }
}

resource apimGatewayDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enableObservability) {
  scope: apim
  name: 'to-log-analytics'
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Auth0 named values
// -----------------------------------------------------------------------------
// In production these are deployed by APIOps (not Bicep) so the APIM
// configuration tree has a single owner. The parameters remain here so
// the delegation handler's App Settings can still reference the values
// at deploy time.
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Delegation: Key Vault for the validation key + Auth0 client secret
// -----------------------------------------------------------------------------
// The handler App Service reads both via Key Vault references; APIM's
// portalsettings/delegation receives the validation key directly (it is
// configuration, not a runtime fetch).
// -----------------------------------------------------------------------------
var kvName = take(toLower(replace('${apimName}-deleg-kv', '_', '-')), 24)

resource delegationKeyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (enableDelegation) {
  name: kvName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: keyVaultSoftDeleteRetentionDays
    // Once on, this CANNOT be turned off for the vault's lifetime. Surface
    // as a parameter so dev environments stay disposable.
    enablePurgeProtection: keyVaultPurgeProtection ? true : null
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource delegationKeyVaultDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enableDelegation && enableObservability) {
  scope: delegationKeyVault
  name: 'to-log-analytics'
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource delegationKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (enableDelegation && !empty(delegationValidationKey)) {
  parent: delegationKeyVault
  name: 'apim-delegation-validation-key'
  properties: {
    value: delegationValidationKey
  }
}

resource auth0SecretKv 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = if (enableDelegation && !empty(auth0ClientSecret)) {
  parent: delegationKeyVault
  name: 'auth0-client-secret'
  properties: {
    value: auth0ClientSecret
  }
}

// -----------------------------------------------------------------------------
// Delegation handler: Flex Consumption Function App + Storage
// -----------------------------------------------------------------------------
// Flex Consumption (FC1) gives us scale-to-zero pricing with sub-second cold
// start for HTTP triggers — ideal for an interactive OIDC roundtrip. The
// runtime uses MI for storage access (no shared keys, no connection strings).
//
// The Function App is provisioned with the .NET 8 isolated runtime; the
// Contoso.Apis.Portal.Delegation project under `src/` deploys here via
//   func azure functionapp publish <name>  --or--
//   az functionapp deployment source config-zip ...
//
// See `src/Contoso.Apis.Portal.Delegation/README.md` for the handler
// implementation and deployment instructions.
// -----------------------------------------------------------------------------

// Storage account name: 3-24 chars, lowercase alphanumeric only.
// `apimName` has minLength=1; the `deleg` suffix guarantees >=6 chars.
var storageAccountName = take(toLower(replace(replace('${apimName}deleg', '-', ''), '_', '')), 24)
var deploymentContainerName = 'function-deployment'

resource handlerStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = if (enableDelegation) {
  #disable-next-line BCP334
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: delegationStorageSku
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    // Flex Consumption uses Managed Identity to access storage — no shared
    // key access needed. Disabling shared key auth is a meaningful hardening
    // step (blocks SAS attacks, account-key leaks).
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

// Storage diagnostics: blob/queue/table sub-resources emit logs separately
// from the account itself. Account-level only carries Transaction metrics.
resource handlerStorageBlobDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enableDelegation && enableObservability) {
  scope: handlerStorageBlobSvc
  name: 'to-log-analytics'
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

resource handlerStorageBlobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = if (enableDelegation) {
  parent: handlerStorage
  name: 'default'
}

resource handlerDeploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = if (enableDelegation) {
  parent: handlerStorageBlobSvc
  name: deploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource handlerPlan 'Microsoft.Web/serverfarms@2024-04-01' = if (enableDelegation) {
  name: '${apimName}-deleg-plan'
  location: location
  tags: tags
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

resource handlerSite 'Microsoft.Web/sites@2024-04-01' = if (enableDelegation) {
  name: '${apimName}-deleg'
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: handlerPlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${handlerStorage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      runtime: {
        name: 'dotnet-isolated'
        version: '8.0'
      }
      scaleAndConcurrency: {
        maximumInstanceCount: delegationHandlerMaxInstances
        instanceMemoryMB: delegationHandlerInstanceMemoryMB
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      appSettings: [
        // Functions host uses MI for the AzureWebJobsStorage account
        // (no connection string, no shared keys).
        {
          name: 'AzureWebJobsStorage__accountName'
          value: handlerStorage.name
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        // --- Auth0 OIDC ---
        {
          name: 'Auth0__Domain'
          value: auth0TenantDomain
        }
        {
          name: 'Auth0__Audience'
          value: auth0Audience
        }
        {
          name: 'Auth0__ClientId'
          value: auth0ClientId
        }
        {
          name: 'Auth0__ClientSecret'
          value: enableDelegation && !empty(auth0ClientSecret) ? '@Microsoft.KeyVault(SecretUri=${auth0SecretKv.properties.secretUri})' : ''
        }
        // --- APIM delegation contract ---
        {
          name: 'Apim__ServiceName'
          value: apim.name
        }
        {
          name: 'Apim__ResourceId'
          value: apim.id
        }
        {
          name: 'Apim__PortalUrl'
          value: 'https://${apim.name}.developer.azure-api.net'
        }
        {
          name: 'Apim__DelegationValidationKey'
          value: enableDelegation && !empty(delegationValidationKey) ? '@Microsoft.KeyVault(SecretUri=${delegationKeySecret.properties.secretUri})' : ''
        }
        // ID token + state token validation tolerances
        {
          name: 'Auth0__ClockSkewSeconds'
          value: '60'
        }
        {
          name: 'State__LifetimeSeconds'
          value: '600'
        }
        // Application Insights (workspace-based) connection string — makes
        // `AddApplicationInsightsTelemetryWorkerService()` actually ship
        // telemetry. Without this it silently no-ops.
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: enableObservability ? appInsights.properties.ConnectionString : ''
        }
      ]
    }
  }
}

resource handlerSiteDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (enableDelegation && enableObservability) {
  scope: handlerSite
  name: 'to-log-analytics'
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// RBAC for the handler MI
// -----------------------------------------------------------------------------
// Built-in role IDs are stable GUIDs — documented at:
//   https://learn.microsoft.com/azure/role-based-access-control/built-in-roles
// -----------------------------------------------------------------------------
var keyVaultSecretsUserRoleId    = '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User
var apimServiceContributorRoleId = '312a565d-c81f-4fd8-895a-4e21e48d571c' // API Management Service Contributor
var storageBlobDataOwnerRoleId   = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' // Storage Blob Data Owner
var storageQueueDataContribRole  = '974c5e8b-45b9-4653-ba55-5f855dd0fb88' // Storage Queue Data Contributor (AzureWebJobsStorage queues)
var storageTableDataContribRole  = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3' // Storage Table Data Contributor (AzureWebJobsStorage tables)

resource handlerKvAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableDelegation) {
  scope: delegationKeyVault
  name: guid(delegationKeyVault.id, handlerSite.id, keyVaultSecretsUserRoleId)
  properties: {
    principalId: handlerSite.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalType: 'ServicePrincipal'
  }
}

// Flex Consumption Function App MI → Storage. Required for both AzureWebJobsStorage
// (host runtime tables/queues/blobs) and the deployment container (where the
// publish step uploads the function package zip).
resource handlerStorageBlobAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableDelegation) {
  scope: handlerStorage
  name: guid(handlerStorage.id, handlerSite.id, storageBlobDataOwnerRoleId)
  properties: {
    principalId: handlerSite.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalType: 'ServicePrincipal'
  }
}

resource handlerStorageQueueAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableDelegation) {
  scope: handlerStorage
  name: guid(handlerStorage.id, handlerSite.id, storageQueueDataContribRole)
  properties: {
    principalId: handlerSite.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContribRole)
    principalType: 'ServicePrincipal'
  }
}

resource handlerStorageTableAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableDelegation) {
  scope: handlerStorage
  name: guid(handlerStorage.id, handlerSite.id, storageTableDataContribRole)
  properties: {
    principalId: handlerSite.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContribRole)
    principalType: 'ServicePrincipal'
  }
}

// The handler needs to call APIM's data-plane REST endpoint
//   POST .../users/{uid}/token
// to mint a single-sign-on token after Auth0 authenticates the user.
// Two RBAC strategies, controlled by `useCustomApimRole`:
//   - false (default): built-in `API Management Service Contributor` —
//     simple, works everywhere, broader than needed.
//   - true: deploy a custom role granting only the three actions the
//     handler actually needs, then assign that. Requires
//     Microsoft.Authorization/roleDefinitions/write at the subscription scope.
// -----------------------------------------------------------------------------
resource apimUserSsoTokenMinterRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = if (enableDelegation && useCustomApimRole) {
  name: guid(subscription().id, apim.id, 'apim-user-sso-token-minter')
  scope: apim
  properties: {
    roleName: 'APIM User SSO Token Minter (${apimName})'
    description: 'Least-privileged role for the delegation handler MI: read/write users and mint SSO tokens on a single APIM service.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.ApiManagement/service/users/read'
          'Microsoft.ApiManagement/service/users/write'
          'Microsoft.ApiManagement/service/users/token/action'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    assignableScopes: [
      apim.id
    ]
  }
}

resource handlerApimAccessCustom 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableDelegation && useCustomApimRole) {
  scope: apim
  name: guid(apim.id, handlerSite.id, 'custom-apim-user-sso-token-minter')
  properties: {
    principalId: handlerSite.identity.principalId
    roleDefinitionId: apimUserSsoTokenMinterRole.id
    principalType: 'ServicePrincipal'
  }
}

resource handlerApimAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableDelegation && !useCustomApimRole) {
  scope: apim
  name: guid(apim.id, handlerSite.id, apimServiceContributorRoleId)
  properties: {
    principalId: handlerSite.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', apimServiceContributorRoleId)
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// APIM portalsettings/delegation
// -----------------------------------------------------------------------------
// Tells the dev portal to redirect signin/signup/subscribe operations to
// `url` instead of showing the built-in pages. APIM signs each redirect with
// HMAC-SHA512(validationKey) so the handler can verify authenticity.
// -----------------------------------------------------------------------------
var resolvedDelegationUrl = !empty(delegationHandlerUrl)
  ? delegationHandlerUrl
  : (enableDelegation ? 'https://${handlerSite.properties.defaultHostName}/delegation' : '')

resource delegationSettings 'Microsoft.ApiManagement/service/portalsettings@2023-05-01-preview' = if (enableDelegation && !empty(delegationValidationKey)) {
  parent: apim
  name: 'delegation'
  properties: {
    url: resolvedDelegationUrl
    validationKey: delegationValidationKey
    subscriptions: {
      enabled: true
    }
    userRegistration: {
      enabled: true
    }
  }
}

// -----------------------------------------------------------------------------
// APIs, subscriptions, policies, and named values are deployed by APIOps —
// not Bicep. The deploy-local.ps1 script provides a smoke-test path that
// pushes compiled policy XML and seeds a demo API via az rest / ARM, but
// that is explicitly outside the IaC contract.
//
// See: docs/adrs/ADR-0001-author-policies-in-csharp.md
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------
@description('Resource ID of the APIM service.')
output apimResourceId string = apim.id

@description('Default gateway hostname. Internal-mode APIM resolves only inside the VNet.')
output apimGatewayHostname string = apim.properties.gatewayUrl

@description('Principal ID of the system-assigned managed identity (use for Key Vault access policies etc.).')
output apimPrincipalId string = apim.identity.principalId

@description('Developer portal URL.')
output developerPortalUrl string = 'https://${apim.name}.developer.azure-api.net'

@description('Default hostname of the (empty) delegation handler App Service. Deploy your handler code here.')
output delegationHandlerHostname string = enableDelegation ? handlerSite.properties.defaultHostName : ''

@description('Principal ID of the delegation handler’s managed identity.')
output delegationHandlerPrincipalId string = enableDelegation ? handlerSite.identity.principalId : ''

@description('Resource ID of the Key Vault holding the delegation validation key and Auth0 client secret.')
output delegationKeyVaultId string = enableDelegation ? delegationKeyVault.id : ''

@description('Resource ID of the Log Analytics workspace receiving diagnostic logs (empty when observability is disabled).')
output logAnalyticsWorkspaceId string = enableObservability ? logAnalytics.id : ''

@description('Resource ID of the Application Insights component used by APIM and the delegation handler (empty when observability is disabled).')
output applicationInsightsId string = enableObservability ? appInsights.id : ''

@description('Resource ID of the VNet provisioned by this template (empty when deployVirtualNetwork is false).')
output vnetResourceId string = deployVirtualNetwork ? vnet.id : ''

@description('Resource ID of the APIM subnet actually used (either the new one or the BYO subnet).')
output apimSubnetResourceId string = resolvedApimSubnetId

@description('Resource ID of the Function App regional integration subnet (empty when deployVirtualNetwork is false).')
output functionsSubnetResourceId string = deployVirtualNetwork ? '${vnet.id}/subnets/functions' : ''

@description('Resource ID of the private-endpoints subnet (empty when deployVirtualNetwork is false).')
output privateEndpointsSubnetResourceId string = deployVirtualNetwork ? '${vnet.id}/subnets/private-endpoints' : ''

@description('Resource ID of the APIM gateway private endpoint (empty when deployVirtualNetwork is false).')
output apimPrivateEndpointId string = deployVirtualNetwork ? apimPrivateEndpoint.id : ''

@description('Effective publicNetworkAccess value applied to the APIM service by this deployment. After the lockdown step has run for the first time, the pipeline reads the live value and passes it back in via the `publicNetworkAccess` parameter, so subsequent Bicep runs preserve it.')
output apimPublicNetworkAccess string = effectivePublicNetworkAccess
