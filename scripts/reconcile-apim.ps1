<#
.SYNOPSIS
    Reconciles an APIM instance against the APIOps artifact tree.
    Detects resources in APIM that are not defined in the artifact folder
    and optionally deletes them.

.PARAMETER ArtifactsPath
    Path to the APIOps artifact folder (e.g. ./apim-artifacts).

.PARAMETER SubscriptionId
    Azure subscription ID containing the APIM instance.

.PARAMETER ResourceGroup
    Resource group containing the APIM instance.

.PARAMETER ServiceName
    Name of the APIM service instance.

.PARAMETER AllowListPath
    Path to a YAML file listing resources that should be ignored during
    reconciliation (e.g. built-in APIs, auto-managed named values).
    See reconcile-allowlist.dev.yaml for the format.

.PARAMETER Delete
    When set, deletes drifted resources instead of just warning.

.EXAMPLE
    # Warn only (CI default for prod):
    ./reconcile-apim.ps1 -ArtifactsPath ./apim-artifacts -SubscriptionId xxx \
        -ResourceGroup rg-apim -ServiceName my-apim \
        -AllowListPath ./apim-artifacts/reconcile-allowlist.prod.yaml

    # Delete drift (CI default for dev):
    ./reconcile-apim.ps1 -ArtifactsPath ./apim-artifacts -SubscriptionId xxx \
        -ResourceGroup rg-apim -ServiceName my-apim \
        -AllowListPath ./apim-artifacts/reconcile-allowlist.dev.yaml -Delete
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArtifactsPath,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$ServiceName,
    [string]$AllowListPath,
    [switch]$Delete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$apiVersion = '2022-08-01'
$baseUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ServiceName"

# ── Load allowlist ──
$allowedApis = @()
$allowedSubscriptions = @()
$allowedNamedValues = @()
$allowedFragments = @()
$allowedRevisions = @()   # format: "apiName;rev=N"

if ($AllowListPath -and (Test-Path $AllowListPath)) {
    Write-Host "Loading allowlist from $AllowListPath" -ForegroundColor Cyan
    $currentKey = $null
    foreach ($line in Get-Content $AllowListPath) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '^(\w+):') {
            $currentKey = $Matches[1]
            if ($trimmed -match ':\s*\[\s*\]') { $currentKey = $null }
            continue
        }
        if ($currentKey -and $trimmed -match '^-\s+(.+)') {
            $value = $Matches[1].Trim()
            # Strip inline comments
            if ($value -match '^([^#]+)#') { $value = $Matches[1].Trim() }
            switch ($currentKey) {
                'apis'          { $allowedApis += $value }
                'subscriptions' { $allowedSubscriptions += $value }
                'namedValues'   { $allowedNamedValues += $value }
                'fragments'     { $allowedFragments += $value }
                'apiRevisions'  { $allowedRevisions += $value }
            }
        }
    }
    Write-Host "  Allowed: $($allowedApis.Count) APIs, $($allowedSubscriptions.Count) subscriptions, $($allowedNamedValues.Count) named values, $($allowedFragments.Count) fragments, $($allowedRevisions.Count) revisions"
}
elseif ($AllowListPath) {
    Write-Warning "Allowlist not found at $AllowListPath — no resources will be excluded."
}

function Invoke-ApimApi {
    param([string]$Method, [string]$Url)
    $restArgs = @('rest', '--method', $Method, '--url', $Url)
    $result = az @restArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "API call failed: $Method $Url — $result"
        return $null
    }
    return $result | ConvertFrom-Json
}

$driftFound = $false
$driftItems = @()

function Add-Drift {
    param([string]$Type, [string]$Name, [string]$ResourceUrl)
    $script:driftFound = $true
    $script:driftItems += [PSCustomObject]@{
        Type        = $Type
        Name        = $Name
        ResourceUrl = $ResourceUrl
    }
}

# ═══════════════════════════════════════════════════════════════════
# 1. APIs
# ═══════════════════════════════════════════════════════════════════
Write-Host "`n── Reconciling APIs ──" -ForegroundColor Cyan

$apisDir = Join-Path $ArtifactsPath 'apis'
$artifactApis = @()
if (Test-Path $apisDir) {
    $artifactApis = Get-ChildItem -Path $apisDir -Directory | Select-Object -ExpandProperty Name
}

$apimApis = Invoke-ApimApi -Method GET -Url "$baseUrl/apis?api-version=$apiVersion"
if ($apimApis -and $apimApis.value) {
    foreach ($api in $apimApis.value) {
        $apiName = $api.name
        $baseName = ($apiName -split ';')[0]
        if ($baseName -in $allowedApis) { continue }
        if ($baseName -notin $artifactApis) {
            $url = "$baseUrl/apis/$($apiName)?api-version=$apiVersion"
            Add-Drift -Type 'API' -Name $apiName -ResourceUrl $url
        }
    }
}

# ═══════════════════════════════════════════════════════════════════
# 2. API Revisions — for each artifact API, check for extra revisions
# ═══════════════════════════════════════════════════════════════════
Write-Host "── Reconciling API Revisions ──" -ForegroundColor Cyan

foreach ($apiName in $artifactApis) {
    $revisions = Invoke-ApimApi -Method GET -Url "$baseUrl/apis/$apiName/revisions?api-version=$apiVersion"
    if ($revisions -and $revisions.value) {
        foreach ($rev in $revisions.value) {
            if (-not $rev.isCurrent) {
                $revNum = $rev.apiRevision
                $revId = "$apiName;rev=$revNum"
                if ($revId -in $allowedRevisions) { continue }
                $url = "$baseUrl/apis/${apiName};rev=${revNum}?api-version=$apiVersion"
                Add-Drift -Type 'API Revision' -Name $revId -ResourceUrl $url
            }
        }
    }
}

# ═══════════════════════════════════════════════════════════════════
# 3. Policy Fragments
# ═══════════════════════════════════════════════════════════════════
Write-Host "── Reconciling Policy Fragments ──" -ForegroundColor Cyan

$fragmentsDir = Join-Path $ArtifactsPath 'fragments'
$artifactFragments = @()
if (Test-Path $fragmentsDir) {
    $artifactFragments = Get-ChildItem -Path $fragmentsDir -Directory | Select-Object -ExpandProperty Name
}

$apimFragments = Invoke-ApimApi -Method GET -Url "$baseUrl/policyFragments?api-version=$apiVersion"
if ($apimFragments -and $apimFragments.value) {
    foreach ($frag in $apimFragments.value) {
        $fragName = $frag.name
        if ($fragName -in $allowedFragments) { continue }
        if ($fragName -notin $artifactFragments) {
            $url = "$baseUrl/policyFragments/$($fragName)?api-version=$apiVersion"
            Add-Drift -Type 'Policy Fragment' -Name $fragName -ResourceUrl $url
        }
    }
}

# ═══════════════════════════════════════════════════════════════════
# 4. Named Values
# ═══════════════════════════════════════════════════════════════════
Write-Host "── Reconciling Named Values ──" -ForegroundColor Cyan

$namedValuesDir = Join-Path $ArtifactsPath 'namedValues'
$artifactNamedValues = @()
if (Test-Path $namedValuesDir) {
    $artifactNamedValues = Get-ChildItem -Path $namedValuesDir -Filter '*.json' |
        ForEach-Object { $_.BaseName }
}

$apimNamedValues = Invoke-ApimApi -Method GET -Url "$baseUrl/namedValues?api-version=$apiVersion"
if ($apimNamedValues -and $apimNamedValues.value) {
    foreach ($nv in $apimNamedValues.value) {
        $nvName = $nv.name
        if ($nvName -in $allowedNamedValues) { continue }
        if ($nvName -notin $artifactNamedValues) {
            $url = "$baseUrl/namedValues/$($nvName)?api-version=$apiVersion"
            Add-Drift -Type 'Named Value' -Name "$nvName ($($nv.properties.displayName))" -ResourceUrl $url
        }
    }
}

# ═══════════════════════════════════════════════════════════════════
# 5. Subscriptions
# ═══════════════════════════════════════════════════════════════════
Write-Host "── Reconciling Subscriptions ──" -ForegroundColor Cyan

$subsDir = Join-Path $ArtifactsPath 'subscriptions'
$artifactSubs = @()
if (Test-Path $subsDir) {
    $artifactSubs = Get-ChildItem -Path $subsDir -Filter '*.json' |
        ForEach-Object { $_.BaseName }
}

$apimSubs = Invoke-ApimApi -Method GET -Url "$baseUrl/subscriptions?api-version=$apiVersion"
if ($apimSubs -and $apimSubs.value) {
    foreach ($sub in $apimSubs.value) {
        $subName = $sub.name
        if ($subName -in $allowedSubscriptions) { continue }
        if ($subName -notin $artifactSubs) {
            $url = "$baseUrl/subscriptions/$($subName)?api-version=$apiVersion"
            Add-Drift -Type 'Subscription' -Name $subName -ResourceUrl $url
        }
    }
}

# ═══════════════════════════════════════════════════════════════════
# Report & act
# ═══════════════════════════════════════════════════════════════════
Write-Host "`n── Results ──" -ForegroundColor Cyan

if (-not $driftFound) {
    Write-Host "No drift detected. APIM is in sync with artifacts." -ForegroundColor Green
    exit 0
}

Write-Host "`nDrift detected — $($driftItems.Count) resource(s) in APIM not in artifacts:" -ForegroundColor Yellow
foreach ($item in $driftItems) {
    Write-Host "  [$($item.Type)] $($item.Name)" -ForegroundColor Yellow
}

if ($Delete) {
    Write-Host "`n-Delete flag set. Removing drifted resources..." -ForegroundColor Red
    foreach ($item in $driftItems) {
        Write-Host "  Deleting [$($item.Type)] $($item.Name)..." -ForegroundColor Red
        Invoke-ApimApi -Method DELETE -Url "$($item.ResourceUrl)" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Deleted." -ForegroundColor Green
        }
        else {
            Write-Warning "    Failed to delete $($item.Name)."
        }
    }
}
else {
    Write-Host "`nRunning in warn-only mode. Use -Delete to remove drifted resources." -ForegroundColor Yellow
    exit 1
}
