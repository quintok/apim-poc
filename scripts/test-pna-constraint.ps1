#!/usr/bin/env pwsh
# Empirically test whether StandardV2 APIM accepts publicNetworkAccess=Disabled at CREATE time.
$ErrorActionPreference = 'Continue'

$sub  = az account show --query id -o tsv
$rg   = 'rg-apim-pna-test'
$loc  = 'australiaeast'
$name = "apimpna$((New-Guid).ToString().Substring(0,6))"

az group create -n $rg -l $loc -o none

$body = @{
    location   = $loc
    sku        = @{ name = 'StandardV2'; capacity = 1 }
    properties = @{
        publisherEmail      = 'test@example.com'
        publisherName       = 'Test'
        publicNetworkAccess = 'Disabled'
    }
} | ConvertTo-Json -Depth 10 -Compress

$uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/${name}?api-version=2023-05-01-preview"
Write-Host "PUT $uri"
Write-Host "Body: $body"
Write-Host ""

$tmp = New-TemporaryFile
Set-Content -Path $tmp -Value $body -NoNewline
$result = az rest --method put --uri $uri --body "@$tmp" 2>&1
$exit = $LASTEXITCODE
Remove-Item $tmp -Force

Write-Host "--- Response ---"
$result | ForEach-Object { Write-Host $_ }
Write-Host "--- Exit code: $exit ---"
