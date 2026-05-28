---
title: "ADR-0001: Author APIM Policies in C# with Policy Toolkit"
status: "Accepted"
date: "2026-05-27"
authors:
	- "Contoso API Platform Team"
tags:
	- architecture
	- apim
	- policy-toolkit
supersedes: ""
superseded_by: ""
---

# ADR-0001: Author APIM Policies in C# with Policy Toolkit

## Status

Accepted

## Context

This repository manages Azure API Management (APIM) policies. Hand-authored XML is difficult to review, test, and reuse safely. The project already uses the Azure APIM Policy Toolkit and unit tests for policy behavior.

## Decision

Author APIM policies as C# documents and fragments in `src/Contoso.Apis.Policies`, compile them to XML during validation/build, and treat generated XML in `dist/policies` as deployment artifacts.

## Consequences

### Positive

- POS-001: Improves readability and maintainability of policy logic.
- POS-002: Enables unit testing of policy behavior before deployment.

### Negative

- NEG-001: Introduces a toolchain dependency (`azure-apim-policy-compiler`).
- NEG-002: Requires discipline to keep policy code and tests aligned.

## Alternatives Considered

### Hand-author APIM XML directly

- ALT-001: Description: Keep policies as manually maintained XML files.
- ALT-002: Rejection Reason: Harder to review, reuse, and unit test reliably.

### Hybrid approach (C# for some policies, XML for others)

- ALT-003: Description: Use C# only for complex policies and XML for simple ones.
- ALT-004: Rejection Reason: Increases cognitive overhead and reduces consistency.

## Implementation Notes

- IMP-001: Keep policy source in `src/Contoso.Apis.Policies` and test coverage in `tests/Contoso.Apis.Policies.Tests`.
- IMP-002: Treat `dist/policies` as generated artifacts from CI/local validation.
- IMP-003: Fail CI on build, test, or policy compiler errors.
- IMP-004: Global cross-cutting policies (e.g. correlation-id) belong in `GlobalPolicy.cs`; API-specific policies inherit via `context.Base()`.
- IMP-005: Compiled XML is merged into `apim-artifacts/` by `scripts/merge-policies-to-apiops.ps1` for APIOps deployment (see ADR-0005).

## Acceptance Criteria

- AC-001: Given policy source under `src/Contoso.Apis.Policies`, when CI runs `dotnet build APIMPolicies.sln`, then the build succeeds.
- AC-002: Given policy behavior tests, when CI runs `dotnet test APIMPolicies.sln`, then tests pass.
- AC-003: Given a policy compile step, when `azure-apim-policy-compiler` runs, then XML artifacts are generated under `dist/policies` with no compiler errors.
- AC-004: Given a new policy document in a PR, when the PR is reviewed, then at least one related unit test exists in `tests/Contoso.Apis.Policies.Tests`.

## References

- REF-001: `README.md`
- REF-002: `src/Contoso.Apis.Policies`
- REF-003: `tests/Contoso.Apis.Policies.Tests`
- REF-004: `src/Contoso.Apis.Policies/Documents/GlobalPolicy.cs`
- REF-005: `scripts/merge-policies-to-apiops.ps1`
