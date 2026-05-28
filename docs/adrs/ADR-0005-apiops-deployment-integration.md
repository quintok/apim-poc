---
title: "ADR-0005: Deploy APIM Configuration via APIOps with Policy Toolkit Integration"
status: "Accepted"
date: "2026-05-28"
authors:
  - "Contoso API Platform Team"
tags:
  - architecture
  - apim
  - apiops
  - deployment
supersedes: ""
superseded_by: ""
---

# ADR-0005: Deploy APIM Configuration via APIOps with Policy Toolkit Integration

## Status

Accepted

## Context

APIM configuration (APIs, operations, policies, subscriptions, named values, products) must be deployed consistently across dev, sit, and prod environments. The Policy Toolkit compiles C# to XML but does not handle deployment. Bicep provisions infrastructure but should not own API-level configuration to avoid dual-ownership conflicts with the deployment tool.

## Decision

Use APIOps as the single deployment mechanism for all APIM configuration. Bicep owns infrastructure only (APIM service, observability, delegation). A committed `apim-artifacts/` folder holds the APIOps artifact tree. CI compiles C# policies to XML and merges them into the artifact tree via `scripts/merge-policies-to-apiops.ps1` before the APIOps publisher deploys. Environment-specific overrides (backend URLs, named values) are managed via `configuration.<env>.yaml` files.

## Consequences

### Positive

- POS-001: Single owner for all APIM configuration — no Bicep/APIOps conflicts.
- POS-002: Environment promotion via config overlays, not separate artifact trees.
- POS-003: Policy XML is compiled and tested in CI before reaching APIOps.

### Negative

- NEG-001: Requires APIOps tooling in the deployment pipeline.
- NEG-002: Local smoke testing uses a separate script (`deploy-local.ps1`) that simulates APIOps via ARM REST.

## Alternatives Considered

### Deploy policies and APIs via Bicep

- ALT-001: Description: Keep APIs, subscriptions, and policies in `infra/main.bicep`.
- ALT-002: Rejection Reason: Creates dual ownership with APIOps, leading to drift and deployment conflicts.

### Deploy policies via az CLI only

- ALT-003: Description: Use `az rest` or `az apim` commands directly in CI.
- ALT-004: Rejection Reason: Lacks the full configuration management APIOps provides (products, subscriptions, named values, versioning).

## Implementation Notes

- IMP-001: `apim-artifacts/` is committed to the repo. Policy XML files inside it are overwritten by CI; everything else is hand-authored.
- IMP-002: `scripts/merge-policies-to-apiops.ps1` maps `dist/policies/` output to the APIOps folder layout (global, per-API, fragments with wrapper stripping).
- IMP-003: Environment configs live at `apim-artifacts/configuration.{dev,sit,prod}.yaml`.

## Acceptance Criteria

- AC-001: Given compiled policies in `dist/policies/`, when `merge-policies-to-apiops.ps1` runs, then `apim-artifacts/` contains updated `policy.xml` files in the correct APIOps layout.
- AC-002: Given a global policy document, when merged, then it appears at `apim-artifacts/policy.xml` (not under an API path).
- AC-003: Given a fragment document, when merged, then the outer `<policies>` wrapper is stripped and only the inner element is written to `apim-artifacts/fragments/<name>/policy.xml`.
- AC-004: Given three environment configs, when APIOps deploys to an environment, then the correct named values and backend URLs are applied.
- AC-005: Given `infra/main.bicep`, when deployed, then it contains no API, subscription, named value, or policy resources.

## References

- REF-001: `apim-artifacts/`
- REF-002: `scripts/merge-policies-to-apiops.ps1`
- REF-003: `apim-artifacts/configuration.{dev,sit,prod}.yaml`
- REF-004: `infra/main.bicep`
