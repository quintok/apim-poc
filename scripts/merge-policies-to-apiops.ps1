#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Copies the APIOps artifact tree to a build output directory, then merges
  compiled Policy Toolkit XML from dist/policies/ into the copy.

  The source apim-artifacts/ folder is NEVER modified — all generated files
  go into the build output (default: dist/apim-artifacts/).

  APIOps expects a specific folder layout. The Policy Toolkit compiles C#
  documents to a flat XML structure. This script bridges the two:

    dist/policies/global-policy.xml           → <output>/policy.xml
    dist/policies/apis/<id>/policy.xml        → <output>/apis/<id>/policy.xml
    dist/policies/fragments/<name>.xml        → <output>/fragments/<name>/policy.xml

  Run this AFTER `dotnet azure-apim-policy-compiler` and BEFORE the APIOps
  publisher. Point the publisher at the output directory.

.EXAMPLE
  # Typical CI flow:
  dotnet azure-apim-policy-compiler --s src/Contoso.Apis.Policies/Documents --o dist/policies --format true
  ./scripts/merge-policies-to-apiops.ps1
  # Then run APIOps publisher against dist/apim-artifacts/

.PARAMETER ArtifactsPath
  Root of the source APIOps artifact tree (read-only). Default: ./apim-artifacts

.PARAMETER DistPath
  Root of the compiled policy XML. Default: ./dist/policies

.PARAMETER OutputPath
  Root of the build output directory. Default: ./dist/apim-artifacts
  The source artifact tree is copied here, then policies are merged in.
#>
[CmdletBinding()]
param(
    [string]$ArtifactsPath = './apim-artifacts',
    [string]$DistPath      = './dist/policies',
    [string]$OutputPath    = './dist/apim-artifacts'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $DistPath)) {
    Write-Error "dist/policies/ not found at '$DistPath'. Run the policy compiler first."
    exit 1
}

if (-not (Test-Path $ArtifactsPath)) {
    Write-Error "APIOps artifact tree not found at '$ArtifactsPath'."
    exit 1
}

# --- Copy source artifacts to build output ----------------------------------
if (Test-Path $OutputPath) {
    Remove-Item -Recurse -Force $OutputPath
}
Copy-Item -Recurse -Force $ArtifactsPath $OutputPath
Write-Host "  Copied $ArtifactsPath -> $OutputPath"

$count = 0

# --- Global policy ----------------------------------------------------------
$globalSrc = Join-Path $DistPath 'global-policy.xml'
if (Test-Path $globalSrc) {
    $globalDst = Join-Path $OutputPath 'policy.xml'
    Copy-Item $globalSrc $globalDst -Force
    Write-Host "  global-policy.xml -> policy.xml"
    $count++
}

# --- API-scoped policies ----------------------------------------------------
$apiPolicies = Get-ChildItem -Path (Join-Path $DistPath 'apis') -Filter 'policy.xml' -Recurse -ErrorAction SilentlyContinue
foreach ($f in $apiPolicies) {
    $apiId = $f.Directory.Name
    $dstDir = Join-Path $OutputPath "apis/$apiId"
    if (-not (Test-Path $dstDir)) {
        Write-Warning "  API folder '$dstDir' does not exist in artifact tree — creating it."
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    }
    Copy-Item $f.FullName (Join-Path $dstDir 'policy.xml') -Force
    Write-Host "  apis/$apiId/policy.xml -> apis/$apiId/policy.xml"
    $count++
}

# --- Fragments --------------------------------------------------------------
# The toolkit produces a full <policies> wrapper; APIOps expects just the
# inner element. Strip the wrapper before writing.
$fragments = Get-ChildItem -Path (Join-Path $DistPath 'fragments') -Filter '*.xml' -ErrorAction SilentlyContinue
foreach ($f in $fragments) {
    $fragName = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    $dstDir = Join-Path $OutputPath "fragments/$fragName"
    if (-not (Test-Path $dstDir)) {
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    }

    $xml = Get-Content $f.FullName -Raw

    # Strip the <policies><inbound><base /> ... </inbound>...</policies> wrapper
    $innerXml = $xml
    if ($xml -match '(?s)<base\s*/>\s*(.*?)\s*</inbound>') {
        $innerXml = $Matches[1].Trim()
    }

    $innerXml | Set-Content (Join-Path $dstDir 'policy.xml') -Encoding utf8NoBOM
    Write-Host "  fragments/$($f.Name) -> fragments/$fragName/policy.xml (inner element only)"

    # Create fragmentInformation.json if it doesn't exist
    $infoFile = Join-Path $dstDir 'fragmentInformation.json'
    if (-not (Test-Path $infoFile)) {
        @{
            properties = @{
                description = "$fragName (compiled from C# via Policy Toolkit)"
                format      = 'xml'
            }
        } | ConvertTo-Json -Depth 4 | Set-Content $infoFile -Encoding utf8NoBOM
        Write-Host "    + created fragmentInformation.json"
    }
    $count++
}

Write-Host ""
Write-Host "Merged $count policy file(s) into $OutputPath" -ForegroundColor Green
