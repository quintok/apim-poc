#!/usr/bin/env pwsh
<#
.SYNOPSIS
  One-stop local validation — PowerShell equivalent of dev-test.sh.

  Build the .NET solution, run unit tests, compile policy fragments to
  APIM XML, lint OpenAPI specs with Spectral, and optionally diff specs
  against a baseline for breaking changes.

  Designed to mirror the Buildkite pipeline so "green locally" == "green in CI".

.EXAMPLE
  ./dev-test.ps1                          # run everything
  $env:SKIP_DIFF=1; ./dev-test.ps1        # skip openapi diff
  ./dev-test.ps1 -SkipDiff                # same, via parameter
  ./dev-test.ps1 -BaselineRef main        # diff against a specific ref
#>
[CmdletBinding()]
param(
    [switch]$SkipDiff,
    [string]$BaselineRef = 'origin/main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # don't abort on first failure — collect all results

Push-Location $PSScriptRoot
try {

# --- Helpers ----------------------------------------------------------------
$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$overall = 0

function Run-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Host ""
    Write-Host "==> $Name" -ForegroundColor White
    try {
        & $Action
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "exit code $LASTEXITCODE" }
        $results.Add([PSCustomObject]@{ Status = 'PASS'; Name = $Name })
    } catch {
        $results.Add([PSCustomObject]@{ Status = 'FAIL'; Name = $Name })
        $script:overall = 1
        Write-Host "  FAILED: $_" -ForegroundColor Red
    }
}

function Skip-Step {
    param([string]$Name, [string]$Reason)
    $results.Add([PSCustomObject]@{ Status = 'SKIP'; Name = $Name })
    Write-Host ""
    Write-Host "==> SKIP $Name — $Reason" -ForegroundColor Yellow
}

# --- 0. Toolkit bootstrap check --------------------------------------------
$pkgs = Get-ChildItem -Path packages -Filter *.nupkg -ErrorAction SilentlyContinue
if (-not $pkgs) {
    Write-Host "Warning: no .nupkg files in ./packages/." -ForegroundColor Yellow
    Write-Host "Download the toolkit release packages from"
    Write-Host "  https://github.com/Azure/azure-api-management-policy-toolkit/releases"
    Write-Host "into ./packages/ before running this script. See packages/README.md."
}

# --- 1. Build ---------------------------------------------------------------
Run-Step "dotnet restore (incl. local toolkit feed)" {
    dotnet restore APIMPolicies.sln
}

Run-Step "dotnet build (APIMPolicies.sln)" {
    dotnet build APIMPolicies.sln --nologo -c Release --no-restore
}

# --- 2. Unit tests (excludes smoke tests — those need a live gateway) -------
Run-Step "dotnet test (policy unit tests)" {
    dotnet test APIMPolicies.sln --nologo -c Release --no-build `
        --filter "FullyQualifiedName!~SmokeTests"
}

# --- 3. Compile policy fragments -> XML -------------------------------------
if (-not (Test-Path dist/policies)) { New-Item -ItemType Directory -Path dist/policies -Force | Out-Null }

Run-Step "dotnet tool restore (policy compiler)" {
    dotnet tool restore
}

Run-Step "compile policy fragments -> dist/policies/*.xml" {
    dotnet azure-apim-policy-compiler `
        --s ./src/Contoso.Apis.Policies/Documents `
        --o ./dist/policies `
        --format true
}

# --- 4. Lint OpenAPI specs --------------------------------------------------
$hasNpx = Get-Command npx -ErrorAction SilentlyContinue
if ($hasNpx) {
    Run-Step "spectral lint (openapi/**)" {
        npx --yes @stoplight/spectral-cli lint --ruleset .spectral.yml "openapi/**/*.yaml" "openapi/**/*.yml" "openapi/**/*.json"
    }
} else {
    Skip-Step "spectral lint" "npx not installed"
}

# --- 5. OpenAPI breaking-change diff ----------------------------------------
$skipDiffEnv = $env:SKIP_DIFF -eq '1'
if ($SkipDiff -or $skipDiffEnv) {
    Skip-Step "openapi-diff" "SKIP_DIFF"
} elseif (-not $hasNpx) {
    Skip-Step "openapi-diff" "npx not installed"
} elseif (-not (Test-Path .git)) {
    Skip-Step "openapi-diff" "not a git checkout"
} else {
    Run-Step "openapi breaking-change diff" {
        bash scripts/openapi-diff.sh $BaselineRef
    }
}

# --- 6. Merge policies into APIOps artifacts --------------------------------
Run-Step "merge policies -> apim-artifacts/" {
    & "$PSScriptRoot/scripts/merge-policies-to-apiops.ps1" `
        -ArtifactsPath ./apim-artifacts `
        -DistPath ./dist/policies
}

# NOTE: Smoke tests (tests/Contoso.Apis.SmokeTests) are NOT included here.
# They require a live APIM gateway and run post-deployment:
#   - Locally:  ./infra/deploy-local.ps1 -DeployPolicies -RunSmokeTests
#   - CI:       after APIOps publishes to the target environment

# --- Summary ----------------------------------------------------------------
Write-Host ""
Write-Host "===== Summary =====" -ForegroundColor White
foreach ($r in $results) {
    $color = switch ($r.Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'SKIP' { 'Yellow' }
    }
    Write-Host "  $($r.Status)  $($r.Name)" -ForegroundColor $color
}
Write-Host ""

if ($overall -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
} else {
    Write-Host "One or more checks failed." -ForegroundColor Red
}

exit $overall

} finally { Pop-Location }
