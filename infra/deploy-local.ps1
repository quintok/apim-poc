#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Quick local deployment of the APIM PoC for smoke testing.

  Step 1: Deploys infrastructure only via Bicep (APIM service, observability).
          APIs, subscriptions, policies, and named values are NOT in Bicep —
          those are owned by APIOps in production.

  Step 2: Seeds a demo Echo API + Petstore API via ARM REST so there is
          something to smoke-test against. This simulates what APIOps would
          deploy in a real environment.

  Step 3: Pushes compiled policy XML from dist/policies/ (global, per-API,
          fragments) via ARM REST — again simulating the APIOps publisher.

.EXAMPLE
  ./infra/deploy-local.ps1                    # infra + seed APIs
  ./infra/deploy-local.ps1 -DeployPolicies    # infra + seed APIs + push policies + smoke test
  ./infra/deploy-local.ps1 -DeployPolicies -RunSmokeTests  # + run API smoke tests
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup   = 'rg-apim-poc',
    [string]$Location        = 'australiaeast',
    [switch]$DeployPolicies,
    [switch]$RunSmokeTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Resolve a unique-ish APIM name from the subscription ID ----------------
$sub = az account show --query id -o tsv
$suffix = ($sub.Substring(0, 8))
$apimName = "apim-poc-$suffix"

$publisherEmail = az account show --query user.name -o tsv
$publisherName  = 'Contoso'

$apiVersion = '2023-05-01-preview'
$baseUrl    = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$apimName"

# Helper: get a bearer token for ARM REST calls
function Get-ArmToken {
    az account get-access-token --query accessToken -o tsv
}

# Helper: PUT a JSON body to an ARM URL using Invoke-RestMethod (avoids az rest charmap bug on Windows)
function Invoke-ArmPut {
    param([string]$Url, [string]$Body)
    $headers = @{ Authorization = "Bearer $(Get-ArmToken)"; 'Content-Type' = 'application/json' }
    Invoke-RestMethod -Uri $Url -Method Put -Headers $headers -Body $Body
}

Write-Host ""
Write-Host "=== APIM PoC — local smoke-test deployment ==="
Write-Host "  Subscription  : $sub"
Write-Host "  Resource group: $ResourceGroup"
Write-Host "  Location      : $Location"
Write-Host "  APIM name     : $apimName"
Write-Host "  Publisher     : $publisherEmail ($publisherName)"
Write-Host "  SKU           : StandardV2 (internet-facing)"
Write-Host ""

# =============================================================================
# Step 1: Deploy infrastructure (Bicep)
# =============================================================================
Write-Host "[1/4] Ensuring resource group '$ResourceGroup' exists..."
az group create --name $ResourceGroup --location $Location --output none

Write-Host "[2/4] Deploying infra/main.bicep (infra only — no APIs)..."
Write-Host "       This takes ~3-5 minutes for StandardV2..."
$deployment = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file "$PSScriptRoot/main.bicep" `
    --parameters apimName=$apimName `
                 publisherEmail=$publisherEmail `
                 publisherName=$publisherName `
                 sku=StandardV2 `
                 capacity=1 `
                 virtualNetworkType=None `
                 enableObservability=true `
                 enableDelegation=false `
    --output json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed. Check output above."
    exit 1
}

$gatewayUrl = $deployment.properties.outputs.apimGatewayHostname.value
$portalUrl  = $deployment.properties.outputs.developerPortalUrl.value

Write-Host ""
Write-Host "  Gateway : $gatewayUrl"
Write-Host "  Portal  : $portalUrl"
Write-Host ""

# =============================================================================
# Step 2: Seed demo APIs via ARM REST (simulates APIOps)
# =============================================================================
Write-Host "[3/4] Seeding demo APIs (Echo + Petstore) via ARM REST..."

$repoRoot = Split-Path $PSScriptRoot -Parent

# --- Echo API ---------------------------------------------------------------
Write-Host "  Creating Echo API..."
$echoBody = @{
    properties = @{
        displayName = 'Echo API'
        description = 'Smoke-test API — echoes requests back.'
        path = 'echo'
        protocols = @('https')
        subscriptionRequired = $true
        serviceUrl = 'https://echoapi.cloudapp.net/api'
    }
} | ConvertTo-Json -Depth 4
Invoke-ArmPut -Url "$baseUrl/apis/echo-api?api-version=$apiVersion" -Body $echoBody | Out-Null

$helloBody = @{
    properties = @{
        displayName = 'Hello'
        method = 'GET'
        urlTemplate = '/hello'
        description = 'Returns a simple echo response.'
        responses = @(@{ statusCode = 200; description = 'OK' })
    }
} | ConvertTo-Json -Depth 4
Invoke-ArmPut -Url "$baseUrl/apis/echo-api/operations/hello?api-version=$apiVersion" -Body $helloBody | Out-Null

$echoSubBody = @{
    properties = @{
        displayName = 'Echo API Test Subscription'
        scope = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$apimName/apis/echo-api"
        state = 'active'
    }
} | ConvertTo-Json -Depth 4
Invoke-ArmPut -Url "$baseUrl/subscriptions/echo-api-test-sub?api-version=$apiVersion" -Body $echoSubBody | Out-Null
Write-Host "    Echo API + /hello + subscription: OK" -ForegroundColor Green

# --- Petstore API -----------------------------------------------------------
Write-Host "  Creating Petstore API (from OpenAPI spec)..."
$petstoreSpec = Get-Content (Join-Path $repoRoot 'openapi' 'petstore.yaml') -Raw
$petstoreBody = @{
    properties = @{
        displayName = 'Petstore API'
        description = 'Example API from the repo OpenAPI spec.'
        path = 'petstore'
        protocols = @('https')
        subscriptionRequired = $true
        serviceUrl = 'https://echoapi.cloudapp.net/api'
        format = 'openapi'
        value = $petstoreSpec
    }
} | ConvertTo-Json -Depth 4
Invoke-ArmPut -Url "$baseUrl/apis/petstore?api-version=$apiVersion" -Body $petstoreBody | Out-Null

$petSubBody = @{
    properties = @{
        displayName = 'Petstore API Test Subscription'
        scope = "/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$apimName/apis/petstore"
        state = 'active'
    }
} | ConvertTo-Json -Depth 4
Invoke-ArmPut -Url "$baseUrl/subscriptions/petstore-test-sub?api-version=$apiVersion" -Body $petSubBody | Out-Null
Write-Host "    Petstore API + subscription: OK" -ForegroundColor Green

# =============================================================================
# Step 3: Deploy compiled policies (optional)
# =============================================================================
if ($DeployPolicies) {
    Write-Host "[4/4] Deploying compiled policy XML to APIM..."

    $distPolicies = Join-Path $repoRoot 'dist' 'policies'

    if (-not (Test-Path $distPolicies)) {
        Write-Warning "dist/policies/ not found. Run dev-test.ps1 first to compile policies."
    } else {
        # Global policy
        $globalPolicyFile = Join-Path $distPolicies 'global-policy.xml'
        if (Test-Path $globalPolicyFile) {
            Write-Host "  Deploying global policy..."
            $body = @{ properties = @{ format = 'xml'; value = (Get-Content $globalPolicyFile -Raw) } } | ConvertTo-Json -Depth 4
            Invoke-ArmPut -Url "$baseUrl/policies/policy?api-version=$apiVersion" -Body $body | Out-Null
            Write-Host "    OK" -ForegroundColor Green
        }

        # API-scoped policies
        $apiPolicies = Get-ChildItem -Path (Join-Path $distPolicies 'apis') -Filter 'policy.xml' -Recurse -ErrorAction SilentlyContinue
        foreach ($policyFile in $apiPolicies) {
            $apiId = $policyFile.Directory.Name
            Write-Host "  Deploying API policy: $apiId..."
            $body = @{ properties = @{ format = 'xml'; value = (Get-Content $policyFile.FullName -Raw) } } | ConvertTo-Json -Depth 4
            try {
                Invoke-ArmPut -Url "$baseUrl/apis/$apiId/policies/policy?api-version=$apiVersion" -Body $body | Out-Null
                Write-Host "    OK" -ForegroundColor Green
            } catch {
                Write-Host "    Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        # Fragments (strip outer <policies> wrapper the toolkit produces)
        $fragments = Get-ChildItem -Path (Join-Path $distPolicies 'fragments') -Filter '*.xml' -ErrorAction SilentlyContinue
        foreach ($fragFile in $fragments) {
            $fragName = [System.IO.Path]::GetFileNameWithoutExtension($fragFile.Name)
            $xmlContent = Get-Content $fragFile.FullName -Raw
            Write-Host "  Deploying fragment: $fragName..."

            $innerXml = $xmlContent
            if ($xmlContent -match '(?s)<base\s*/>\s*(.*?)\s*</inbound>') {
                $innerXml = $Matches[1].Trim()
            }

            $body = @{ properties = @{ description = "$fragName (compiled from C#)"; format = 'xml'; value = $innerXml } } | ConvertTo-Json -Depth 4
            try {
                Invoke-ArmPut -Url "$baseUrl/policyFragments/${fragName}?api-version=$apiVersion" -Body $body | Out-Null
                Write-Host "    OK" -ForegroundColor Green
            } catch {
                Write-Host "    Failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        Write-Host "  Policy deployment complete."
    }
} else {
    Write-Host "[4/4] Skipping policy deployment (use -DeployPolicies to push compiled XML)."
}
Write-Host ""

# =============================================================================
# Smoke test
# =============================================================================
Write-Host "=== Smoke test ==="
$echoHelloUrl = "$gatewayUrl/echo/hello"

$echoKeys = Invoke-RestMethod -Uri "$baseUrl/subscriptions/echo-api-test-sub/listSecrets?api-version=$apiVersion" `
    -Method Post -Headers @{ Authorization = "Bearer $(Get-ArmToken)" }
$subKey = $echoKeys.primaryKey

Write-Host "  curl -H 'Ocp-Apim-Subscription-Key: $subKey' '$echoHelloUrl'"
try {
    $r = Invoke-WebRequest -Uri $echoHelloUrl `
        -Headers @{ 'Ocp-Apim-Subscription-Key' = $subKey } `
        -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    Write-Host "  Status : $($r.StatusCode)"
    Write-Host "  x-correlation-id: $($r.Headers['x-correlation-id'])"
    Write-Host ""
    Write-Host "Deployment and smoke test succeeded." -ForegroundColor Green
} catch {
    Write-Warning "Smoke test: $($_.Exception.Message)"
    Write-Host "The APIM gateway may need a minute to warm up. Try the curl above manually."
}

# =============================================================================
# API smoke tests (optional)
# =============================================================================
if ($RunSmokeTests) {
    Write-Host ""
    Write-Host "=== Running API smoke tests (xUnit) ==="

    # Set environment variables for the smoke test base class
    $env:APIM_GATEWAY_URL = $gatewayUrl

    # Resolve subscription keys for each API with a test subscription
    $apiSubs = @('echo-api', 'petstore')
    foreach ($apiId in $apiSubs) {
        $subName = "$apiId-test-sub"
        try {
            $keys = Invoke-RestMethod -Uri "$baseUrl/subscriptions/$subName/listSecrets?api-version=$apiVersion" `
                -Method Post -Headers @{ Authorization = "Bearer $(Get-ArmToken)" }
            $envName = "APIM_SUBSCRIPTION_KEY__$($apiId.ToUpper().Replace('-','_'))"
            Set-Item "env:$envName" $keys.primaryKey
        } catch {
            Write-Warning "Could not get key for $subName — tests for $apiId may fail"
        }
    }

    $repoRoot = Split-Path $PSScriptRoot -Parent
    dotnet test (Join-Path $repoRoot 'tests/Contoso.Apis.SmokeTests/Contoso.Apis.SmokeTests.csproj') `
        --nologo -c Release --logger "console;verbosity=normal"

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Smoke tests failed."
        exit 1
    }
}
