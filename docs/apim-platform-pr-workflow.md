# APIM Platform — PR Workflow & API Lifecycle Guide

> **Audience:** Product teams onboarding APIs to the Contoso APIM platform, and the MAP (Managed API Platform) team who maintain it.
> **Last updated:** May 2026

---

## Table of Contents

1. [Overview](#overview)
2. [Ephemeral Test Environments](#ephemeral-test-environments)
3. [Deploying a New API](#deploying-a-new-api)
4. [Deploying API Revisions](#deploying-api-revisions)
5. [Deploying API Versions](#deploying-api-versions)
6. [Decommissioning an API](#decommissioning-an-api)
7. [Revisions, Versions, and Products — How They Relate](#revisions-versions-and-products--how-they-relate)
8. [Workflow: Product Teams](#workflow-product-teams)
9. [Workflow: MAP Team (Platform)](#workflow-map-team-platform)

---

## Overview

The Contoso APIM platform uses a **GitOps-driven, PR-based workflow** to manage API gateway configuration. Every change — whether it's a new API, a policy update, or an infrastructure tweak — flows through a pull request with automated validation before reaching any shared environment.

The key components are:

| Component | Purpose |
|---|---|
| **C# Policy Toolkit** | Author APIM policies in C# instead of raw XML. Unit-testable, composable, reviewed in PRs. |
| **APIOps** | GitOps deployment engine. A committed `apim-artifacts/` folder is the single source of truth for all APIM configuration (APIs, products, subscriptions, named values, policies). |
| **Bicep (IaC)** | Provisions APIM *infrastructure only* — the service instance, observability, delegation handler. Does **not** own APIs, policies, or subscriptions. |
| **Buildkite CI** | Runs build, test, policy compilation, OpenAPI linting, and breaking-change detection on every PR. |
| **GitHub Actions** | Provisions ephemeral APIM environments for end-to-end PR validation when the `preview` label is applied. |
| **Environment configs** | `configuration.{dev,sit,prod}.yaml` files apply per-environment overrides (backend URLs, named values) during APIOps deployment. |

### High-Level Flow

```
┌────────────┐     ┌──────────┐     ┌────────────────┐     ┌────────────┐     ┌──────────┐
│ Author     │ ──▶ │ dev-test │ ──▶ │ PR + Buildkite │ ──▶ │  APIOps    │ ──▶ │  Smoke   │
│ changes    │     │ .ps1/.sh │     │   green build  │     │  publisher │     │  tests   │
└────────────┘     └──────────┘     └────────────────┘     └────────────┘     └──────────┘
                                          │                                       │
                                          ├── (optional) preview label ──▶ Ephemeral APIM
                                          │
                                          └── merge ──▶ APIOps deploys to dev → sit → prod
```

---

## Ephemeral Test Environments

### What Are They?

Ephemeral APIM environments are **short-lived, isolated APIM instances** spun up per pull request for end-to-end validation. They give reviewers confidence that policies, OpenAPI contracts, and API routing work against a real Azure API Management gateway — not just in unit tests.

### How They Work

1. A contributor opens a PR with their changes.
2. A reviewer (or the author) **applies the `preview` label** to the PR.
3. GitHub Actions triggers the `ephemeral-apim.yml` workflow:
   - Checks out the PR branch.
   - Builds the .NET solution and compiles C# policies to XML.
   - Logs into Azure via OIDC (federated credentials).
   - Deploys a new APIM instance using `infra/main.bicep` with cost-optimised overrides:
     - **SKU:** `StandardV2` (not Premium)
     - **VNet:** `None` (internet-facing, no private endpoint wiring)
   - The instance is named `contoso-apim-pr-<PR_NUMBER>` in the `rg-apim-ephemeral` resource group.
4. APIOps publisher deploys the full artifact tree (APIs, policies, named values, subscriptions) to the ephemeral instance.
5. **Smoke tests** run against the live ephemeral gateway.
6. A bot comments on the PR with the gateway URL so reviewers can manually test if needed.
7. On PR close/merge, a cleanup workflow tears down the ephemeral resource group.

### Why Not Just Use Dev?

| Approach | Trade-off |
|---|---|
| Shared dev environment | Risk of cross-PR interference; non-deterministic test outcomes when multiple PRs deploy simultaneously. |
| Unit tests only | No gateway/runtime confidence — policies may compile correctly but fail at request time. |
| **Ephemeral per-PR** | Full isolation. Higher cost, but environments are short-lived and use cheaper SKUs. |

### Cost Controls

- Ephemeral instances use `StandardV2` SKU (significantly cheaper than production `Premium`).
- No VNet integration (avoids private DNS / subnet provisioning costs).
- Concurrency groups prevent duplicate deployments for the same PR.
- Explicit teardown on PR close.

---

## Deploying a New API

When a product team wants to expose a new API through the APIM gateway, they create a PR with the following artifacts:

### Step-by-Step

1. **Add the OpenAPI specification** to `openapi/<api-name>.yaml`.
   - This is the canonical contract. Spectral linting enforces style and correctness in CI.

2. **Create the APIOps API definition** at `apim-artifacts/apis/<api-id>/`:
   - `apiInformation.json` — metadata: display name, description, path, protocols, subscription requirements.
   - `specification.yaml` — the OpenAPI spec that APIOps imports into APIM.

   Example `apiInformation.json`:
   ```json
   {
     "properties": {
       "displayName": "Petstore API",
       "description": "Pet management endpoints.",
       "path": "petstore",
       "apiRevision": "1",
       "protocols": ["https"],
       "subscriptionRequired": true,
       "serviceUrl": "https://echoapi.cloudapp.net/api",
       "apiType": "http"
     }
   }
   ```

3. **Add environment-specific backend URLs** to each `configuration.<env>.yaml`:
   ```yaml
   apis:
     - name: petstore
       properties:
         serviceUrl: https://petstore-backend.contoso.example
   ```

4. **(Optional) Author API-specific policies** in `src/Contoso.Apis.Policies/Documents/` if the API needs custom request/response handling beyond the global policy.

5. **Add smoke tests** by creating a new class in `tests/Contoso.Apis.SmokeTests/` that extends `SmokeTestBase`:
   ```csharp
   public class PetstoreSmokeTests : SmokeTestBase
   {
       protected override string ApiId => "petstore";
       protected override string ApiPath => "petstore";

       [Fact]
       public async Task ListPets_Returns200()
       {
           var response = await Client.GetAsync("pets");
           Assert.Equal(HttpStatusCode.OK, response.StatusCode);
       }
   }
   ```

6. **Open a PR**. CI validates: build, unit tests, policy compilation, OpenAPI lint, breaking-change diff.

7. **(Optional) Add the `preview` label** to deploy to an ephemeral APIM and run smoke tests.

8. **Merge**. APIOps deploys the new API to dev → sit → prod.

---

## Deploying API Revisions

**API revisions** are non-breaking, in-place updates to an existing API. Use revisions when you need to test changes before making them live, or to safely roll out modifications to an existing API version.

### How Revisions Work in APIOps

Revisions are represented as separate folders in the artifact tree using the `;rev=N` naming convention:

```
apim-artifacts/
  apis/
    animalstore/                  ← Revision 1 (original)
      apiInformation.json         ← "apiRevision": "1", "isCurrent": true
      specification.yaml
    animalstore;rev=2/            ← Revision 2 (new)
      apiInformation.json         ← "apiRevision": "2"
      specification.yaml          ← updated contract
```

### Step-by-Step

1. **Create a new revision folder** at `apim-artifacts/apis/<api-id>;rev=<N>/`.

2. **Copy `apiInformation.json`** from the current revision and update:
   - Set `"apiRevision": "<N>"`.
   - Add an `"apiRevisionDescription"` explaining what changed.
   - Do **not** set `"isCurrent": true` yet — the new revision deploys in a non-current (draft) state.

   ```json
   {
     "properties": {
       "displayName": "Animalstore API",
       "path": "animalstore",
       "apiRevision": "2",
       "apiRevisionDescription": "Added species property to Animal response.",
       "protocols": ["https"],
       "subscriptionRequired": true,
       "serviceUrl": "https://echoapi.cloudapp.net/api",
       "apiType": "http"
     }
   }
   ```

3. **Add the updated `specification.yaml`** with the contract changes.

4. **Update environment configs** to set backend URLs for the new revision and control which revision is current:
   ```yaml
   apis:
     - name: animalstore
       properties:
         serviceUrl: https://echoapi.cloudapp.net/api
         isCurrent: false
     - name: "animalstore;rev=2"
       properties:
         serviceUrl: https://echoapi.cloudapp.net/api
         isCurrent: true
   ```

5. **Open a PR**, validate, optionally preview, and merge.

### Making a Revision Current

To promote a revision to "current" (the version consumers see by default):
- Set `isCurrent: true` on the new revision in the environment config.
- Set `isCurrent: false` on the old revision.
- This can be done in the same PR or as a follow-up PR for a phased rollout.

### Testing Revisions Before They Go Live

Non-current revisions are accessible in APIM via a revision-specific URL (`/api-path;rev=2/endpoint`). You can use the ephemeral environment or the dev gateway to validate the new revision before promoting it.

---

## Deploying API Versions

**API versions** represent breaking changes that require consumers to explicitly opt in to the new contract. Unlike revisions (which share a base API and swap in-place), versions are separate APIs with distinct URL paths or headers.

### When to Version vs. Revise

| Scenario | Use |
|---|---|
| Adding a new optional field to a response | **Revision** |
| Fixing a bug in policy logic | **Revision** |
| Renaming a field, removing an endpoint, changing auth | **Version** |
| Major contract overhaul | **Version** |

### Step-by-Step

1. **Create a new API definition** as a separate API in the artifact tree. The convention is to include the version in the path:
   ```
   apim-artifacts/
     apis/
       petstore/              ← v1 (path: /petstore)
       petstore-v2/           ← v2 (path: /petstore/v2)
   ```

2. **Define the new `apiInformation.json`** with a distinct `path`, `displayName`, and `apiVersion`:
   ```json
   {
     "properties": {
       "displayName": "Petstore API v2",
       "path": "petstore/v2",
       "apiRevision": "1",
       "apiVersion": "v2",
       "apiVersionSetId": "/apiVersionSets/petstore-version-set",
       "protocols": ["https"],
       "subscriptionRequired": true,
       "serviceUrl": "https://petstore-v2-backend.contoso.example",
       "apiType": "http"
     }
   }
   ```

3. **Create or reference an API Version Set** in `apim-artifacts/apiVersionSets/` to group the versions. Version sets define the versioning scheme (path, header, or query parameter).

4. **Add the OpenAPI spec**, environment configs, and smoke tests for the new version.

5. The old version continues to function at its original path until explicitly decommissioned.

---

## Decommissioning an API

When an API reaches end-of-life, the decommissioning process is the reverse of onboarding — with a controlled deprecation period.

### Step-by-Step

1. **Announce deprecation** to consumers. Update the API description in `apiInformation.json` to include a deprecation notice and sunset date.

2. **Add a deprecation policy** (optional) that injects a `Sunset` and/or `Deprecation` header into responses, alerting consumers programmatically.

3. **Remove from products** — if the API is assigned to any APIM products, remove it from those product definitions first.

4. **Remove the API definition** from `apim-artifacts/apis/<api-id>/` (delete the folder).

5. **Remove associated artifacts**:
   - Environment config entries from each `configuration.<env>.yaml`.
   - Any API-specific policy documents from `src/Contoso.Apis.Policies/Documents/`.
   - Smoke tests from `tests/Contoso.Apis.SmokeTests/`.
   - The OpenAPI spec from `openapi/`.

6. **Update the reconcile allowlist** if needed. The `reconcile-allowlist.<env>.yaml` file lists resources in APIM that should *not* be flagged as drift. During the transition period you may need to temporarily allowlist the API.

7. **Open a PR**. CI confirms the remaining configuration is valid. APIOps deploys the removal.

8. **Reconciliation script** (`scripts/reconcile-apim.ps1`) can detect and optionally delete resources that exist in the live APIM but not in the artifact tree — catching any manual portal changes that weren't cleaned up.

---

## Revisions, Versions, and Products — How They Relate

### Concept Map

```
┌─────────────────────────────────────────────────────────┐
│                    API Version Set                       │
│              (groups versions together)                  │
│                                                         │
│  ┌──────────────┐     ┌──────────────┐                  │
│  │ Petstore v1  │     │ Petstore v2  │  ← Versions      │
│  │  /petstore   │     │ /petstore/v2 │     (breaking     │
│  │              │     │              │      changes)     │
│  │  ┌── rev 1 ──┐     │  ┌── rev 1 ──┐                  │
│  │  │ (current) │     │  │ (current) │  ← Revisions     │
│  │  ├── rev 2 ──┤     │  └───────────┘     (non-breaking │
│  │  │ (draft)   │     │                     updates)     │
│  │  └───────────┘     │                                  │
│  └──────────────┘     └──────────────┘                  │
└─────────────────────────────────────────────────────────┘
         │                      │
         └──────────┬───────────┘
                    ▼
            ┌──────────────┐
            │   Product    │  ← Products group APIs for
            │ "Pet APIs"   │     consumers and control
            │              │     access/subscriptions
            └──────────────┘
```

### Definitions

| Concept | What It Is | When to Use |
|---|---|---|
| **Revision** | A non-breaking iteration on an API. Multiple revisions exist simultaneously, but only one is "current" (the default consumers hit). Non-current revisions are accessible via `;rev=N` in the URL. | Bug fixes, new optional fields, policy tweaks — anything backward-compatible. |
| **Version** | A distinct API contract with a separate URL path (or header/query). Part of a Version Set that groups related versions. | Breaking changes: renamed fields, removed endpoints, auth scheme changes. |
| **Product** | A logical grouping of one or more APIs. Products control access (subscriptions, rate limits, terms of use). Consumers subscribe to a product to get access to its APIs. | Packaging APIs for external or internal consumers. A product like "Pet APIs" might include both Petstore v1 and v2. |

### How Smoke Tests Fit In

- **Smoke tests validate per-API**, not per-product or per-revision. Each API (or version) gets its own test class extending `SmokeTestBase`.
- The `SmokeTestBase` resolves the gateway URL and subscription key from environment variables, making tests environment-agnostic.
- Smoke tests are **excluded from offline CI** (`dev-test.ps1`/`dev-test.sh`) and only run post-deployment against a live gateway — either an ephemeral preview instance or a real environment.
- When a new revision becomes current, existing smoke tests continue to pass because they target the API path (not a specific revision). If the revision changes behavior, update the tests in the same PR.
- New API versions need their own smoke test class (new `ApiId`, new `ApiPath`).

---

## Workflow: Product Teams

Product teams own their APIs and are responsible for their contracts, policies, and smoke tests. Here is the end-to-end workflow for common scenarios.

### Adding or Updating an API

```
 Product Team                              CI / Automation                    Environments
 ────────────                              ───────────────                    ────────────
 1. Create feature branch
 2. Add/update artifacts:
    • openapi/<api>.yaml
    • apim-artifacts/apis/<api>/
    • configuration.<env>.yaml
    • (optional) C# policy document
    • Smoke test class
 3. Run ./dev-test.ps1 locally ──────────▶ Build, test, compile,
                                           lint, diff — all pass
 4. Open PR ─────────────────────────────▶ Buildkite runs the same
                                           checks. Policy XML merged
                                           into APIOps artifact tree.
 5. (Optional) Add `preview` label ──────▶ GitHub Actions:
                                           • Deploy ephemeral APIM
                                           • APIOps publish
                                           • Smoke tests run
                                           • Bot comments with URL
 6. PR review + approval
 7. Merge ───────────────────────────────▶ APIOps publisher deploys ──────▶ dev
                                                                           sit (after gate)
                                                                           prod (after gate)
                                           Smoke tests run per env ◀──────
```

### What Product Teams Own

| Artifact | Location | Notes |
|---|---|---|
| OpenAPI spec | `openapi/<api>.yaml` | Canonical contract. Linted by Spectral. |
| API definition | `apim-artifacts/apis/<api-id>/` | `apiInformation.json` + `specification.yaml` |
| Environment config entries | `configuration.<env>.yaml` | Backend URLs, named values for their API |
| API-specific policies | `src/Contoso.Apis.Policies/Documents/` | Only if custom policy logic is needed |
| Smoke tests | `tests/Contoso.Apis.SmokeTests/` | Extend `SmokeTestBase`, one class per API |

### What Product Teams Do NOT Own

- Global policies (e.g. correlation-id injection, global error handling)
- Infrastructure (Bicep templates)
- APIOps tooling and pipeline configuration
- Shared policy fragments (e.g. Auth0 JWT validation)
- Named values for cross-cutting concerns (Auth0 tenant/audience)
- Reconciliation scripts and allowlists

---

## Workflow: MAP Team (Platform)

The MAP (Managed API Platform) team owns the APIM infrastructure, shared policies, CI/CD pipelines, and developer experience. Their changes flow through the same PR process but touch different parts of the repository.

### MAP Team Responsibilities

| Area | Artifacts | Examples |
|---|---|---|
| **Infrastructure** | `infra/main.bicep`, `infra/main.parameters.json` | APIM SKU changes, VNet config, observability, delegation handler, scaling |
| **Global policies** | `src/Contoso.Apis.Policies/Documents/GlobalPolicy.cs` | Correlation-id injection, global error handling, rate limiting |
| **Shared fragments** | `src/Contoso.Apis.Policies/Fragments/` | Auth0 JWT validation, common header manipulation |
| **CI/CD pipelines** | `.buildkite/pipeline.yaml`, `.github/workflows/ephemeral-apim.yml` | Build steps, deployment gates, smoke test wiring |
| **Tooling & scripts** | `scripts/merge-policies-to-apiops.ps1`, `scripts/reconcile-apim.ps1`, `dev-test.ps1` | Policy merge logic, drift detection, local dev experience |
| **Named values (cross-cutting)** | `apim-artifacts/namedValues/` | Auth0 tenant domain, audience, shared secrets |
| **Reconciliation** | `reconcile-allowlist.<env>.yaml`, `scripts/reconcile-apim.ps1` | Detecting and cleaning drift between APIM and the artifact tree |
| **Documentation & ADRs** | `docs/adrs/` | Architectural decisions, onboarding guides |

### MAP Team Workflow

```
 MAP Team                                  CI / Automation                    Environments
 ────────                                  ───────────────                    ────────────
 1. Create feature branch
 2. Make platform changes:
    • Bicep template updates
    • Global policy changes
    • Pipeline modifications
    • New shared fragments
    • Tooling updates
 3. Run ./dev-test.ps1 locally
    (+ ./infra/deploy-local.ps1 if
     testing infra changes) ─────────────▶ Full local validation.
                                           deploy-local.ps1 provisions
                                           a personal APIM instance
                                           for infra smoke testing.
 4. Open PR ─────────────────────────────▶ Buildkite CI:
                                           • Build + unit tests
                                           • Policy compilation
                                           • OpenAPI lint + diff
                                           • Merge into artifact tree
 5. Add `preview` label ─────────────────▶ Ephemeral APIM:
                                           • End-to-end infra validation
                                           • Full APIOps deployment
                                           • Smoke tests confirm no
                                             regressions for ALL APIs
 6. PR review (MAP team peer review)
 7. Merge ───────────────────────────────▶ Bicep deploys infra ──────────▶ dev → sit → prod
                                           APIOps deploys config ────────▶ dev → sit → prod
                                           Smoke tests per environment ◀──
```

### Drift Reconciliation

The MAP team periodically runs `scripts/reconcile-apim.ps1` to detect resources in APIM that aren't in the artifact tree:

- **In dev**: the script can auto-delete drifted resources (`-Delete` flag).
- **In prod**: the script warns only — manual review required before deletion.
- The `reconcile-allowlist.<env>.yaml` file excludes known non-APIOps resources (built-in APIs, auto-managed named values, etc.).

### Key Principles

1. **Bicep owns infrastructure; APIOps owns configuration.** There is no overlap — Bicep does not deploy APIs, policies, or subscriptions.
2. **Every change goes through a PR.** No portal edits. The reconciliation script catches drift.
3. **Policies are code.** C# policies are unit-tested, compiled to XML, and merged into the artifact tree by CI. No hand-edited XML in the artifact folder.
4. **Environment promotion via config overlays.** The same artifact tree deploys to every environment; only `configuration.<env>.yaml` differs.
5. **Ephemeral environments provide runtime confidence.** Unit tests catch logic errors; ephemeral APIM catches gateway/routing/infrastructure errors.

---

## Quick Reference: File Locations

| What | Where |
|---|---|
| OpenAPI specs | `openapi/` |
| APIOps artifact tree | `apim-artifacts/` |
| API definitions | `apim-artifacts/apis/<api-id>/` |
| Environment overrides | `apim-artifacts/configuration.<env>.yaml` |
| Reconciliation allowlists | `apim-artifacts/reconcile-allowlist.<env>.yaml` |
| C# policy source | `src/Contoso.Apis.Policies/Documents/` |
| Shared fragments | `src/Contoso.Apis.Policies/Fragments/` |
| Policy unit tests | `tests/Contoso.Apis.Policies.Tests/` |
| Smoke tests | `tests/Contoso.Apis.SmokeTests/` |
| Infrastructure (Bicep) | `infra/main.bicep` |
| CI pipeline | `.buildkite/pipeline.yaml` |
| Ephemeral APIM workflow | `.github/workflows/ephemeral-apim.yml` |
| Local validation | `dev-test.ps1` / `dev-test.sh` |
| Local deployment | `infra/deploy-local.ps1` |
| Policy merge script | `scripts/merge-policies-to-apiops.ps1` |
| Drift reconciliation | `scripts/reconcile-apim.ps1` |
| Architecture decisions | `docs/adrs/` |
