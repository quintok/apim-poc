#!/usr/bin/env bash
# dev-test.sh
# -----------------------------------------------------------------------------
# One-stop local validation: build the .NET solution, run unit tests, compile
# policy fragments to APIM XML, lint OpenAPI specs with Spectral, and
# optionally diff specs against a baseline for breaking changes.
#
# Designed to mirror the Buildkite pipeline so "green locally" == "green in CI".
#
# Usage:
#   ./dev-test.sh                # run everything
#   SKIP_DIFF=1 ./dev-test.sh    # skip openapi diff (useful on first commit)
#   BASELINE_REF=main ./dev-test.sh
# -----------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# --- Pretty output ----------------------------------------------------------
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
declare -a RESULTS

run_step() {
  local name="$1"; shift
  echo
  echo "${BOLD}==> ${name}${NC}"
  if "$@"; then
    RESULTS+=("${GREEN}PASS${NC}  ${name}")
    return 0
  else
    RESULTS+=("${RED}FAIL${NC}  ${name}")
    return 1
  fi
}

skip_step() {
  local name="$1"; local reason="$2"
  RESULTS+=("${YELLOW}SKIP${NC}  ${name} (${reason})")
  echo
  echo "${YELLOW}==> SKIP ${name} — ${reason}${NC}"
}

overall=0

# --- 0. Toolkit bootstrap check --------------------------------------------
# The Azure API Management Policy Toolkit packages are distributed via
# GitHub Releases (not nuget.org yet). If the local feed is empty, surface a
# clear message instead of a generic NuGet error from `dotnet restore`.
if ! ls packages/*.nupkg >/dev/null 2>&1; then
  echo "${YELLOW}Warning: no .nupkg files in ./packages/.${NC}" >&2
  echo "Download the toolkit release packages from" >&2
  echo "  https://github.com/Azure/azure-api-management-policy-toolkit/releases" >&2
  echo "into ./packages/ before running this script. See packages/README.md." >&2
fi

# --- 1. Build ---------------------------------------------------------------
run_step "dotnet restore (incl. local toolkit feed)" \
  dotnet restore APIMPolicies.sln || overall=1

run_step "dotnet build (APIMPolicies.sln)" \
  dotnet build APIMPolicies.sln --nologo -c Release --no-restore || overall=1

# --- 2. Unit tests ----------------------------------------------------------
run_step "dotnet test (policy unit tests)" \
  dotnet test APIMPolicies.sln --nologo -c Release --no-build \
    --filter "FullyQualifiedName!~SmokeTests" || overall=1

# --- 3. Compile policy fragments -> XML -------------------------------------
# The Policy Toolkit ships a `dotnet tool` named `azure-apim-policy-compiler`
# (pinned in .config/dotnet-tools.json). It walks the source folder, finds
# every `[Document]` class and writes the equivalent APIM XML.
mkdir -p dist/policies
run_step "dotnet tool restore (policy compiler)" \
  dotnet tool restore || overall=1

run_step "compile policy fragments -> dist/policies/*.xml" \
  dotnet azure-apim-policy-compiler \
    --s ./src/Contoso.Apis.Policies/Documents \
    --o ./dist/policies \
    --format true || overall=1

# --- 4. Lint OpenAPI specs --------------------------------------------------
if command -v npx >/dev/null 2>&1; then
  run_step "spectral lint (openapi/**)" \
    npx --yes @stoplight/spectral-cli lint --ruleset .spectral.yml \
        "openapi/**/*.{yaml,yml,json}" || overall=1
else
  skip_step "spectral lint" "npx not installed"
fi

# --- 5. OpenAPI breaking-change diff ----------------------------------------
if [[ "${SKIP_DIFF:-0}" == "1" ]]; then
  skip_step "openapi-diff" "SKIP_DIFF=1"
elif ! command -v npx >/dev/null 2>&1; then
  skip_step "openapi-diff" "npx not installed"
elif [[ ! -d .git ]]; then
  skip_step "openapi-diff" "not a git checkout"
else
  run_step "openapi breaking-change diff" \
    bash scripts/openapi-diff.sh "${BASELINE_REF:-origin/main}" || overall=1
fi

# --- 6. Merge policies into APIOps artifacts --------------------------------
run_step "merge policies -> apim-artifacts/" \
  pwsh scripts/merge-policies-to-apiops.ps1 \
    -ArtifactsPath ./apim-artifacts \
    -DistPath ./dist/policies || overall=1

# NOTE: Smoke tests (tests/Contoso.Apis.SmokeTests) are NOT included here.
# They require a live APIM gateway and run post-deployment:
#   - Locally:  ./infra/deploy-local.ps1 -DeployPolicies -RunSmokeTests
#   - CI:       after APIOps publishes to the target environment

# --- Summary ----------------------------------------------------------------
echo
echo "${BOLD}===== Summary =====${NC}"
for line in "${RESULTS[@]}"; do
  echo "  $line"
done
echo

if [[ $overall -eq 0 ]]; then
  echo "${GREEN}All checks passed.${NC}"
else
  echo "${RED}One or more checks failed.${NC}"
fi
exit "$overall"
