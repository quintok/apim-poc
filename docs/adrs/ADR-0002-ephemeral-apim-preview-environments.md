---
title: "ADR-0002: Use Ephemeral APIM Preview Environments for PR Validation"
status: "Accepted"
date: "2026-05-27"
authors:
	- "Contoso API Platform Team"
tags:
	- architecture
	- apim
	- environments
supersedes: ""
superseded_by: ""
---

# ADR-0002: Use Ephemeral APIM Preview Environments for PR Validation

## Status

Accepted

## Context

Policy and OpenAPI changes can pass unit tests but still fail in a real APIM runtime context. The repository includes infrastructure and workflow automation for short-lived preview environments.

## Decision

Provision an ephemeral APIM environment per pull request when preview validation is requested, using `infra/main.bicep` and workflow automation. Use lower-cost settings for preview runs and keep production defaults in IaC.

## Consequences

### Positive

- POS-001: Adds high-confidence environment validation before merge.
- POS-002: Reduces risk of runtime regressions in shared environments.

### Negative

- NEG-001: Adds cloud provisioning time and cost for preview runs.
- NEG-002: Requires robust cleanup and naming conventions.

## Alternatives Considered

### Validate only in shared non-production APIM

- ALT-001: Description: Run all integration checks in a long-lived shared environment.
- ALT-002: Rejection Reason: Higher risk of cross-PR interference and non-deterministic test outcomes.

### No preview environment, rely on unit tests only

- ALT-003: Description: Keep validation to local and CI test suites without runtime deployment.
- ALT-004: Rejection Reason: Does not provide gateway/runtime confidence for policy and infrastructure behavior.

## Implementation Notes

- IMP-001: Use `infra/main.bicep` as the single source for preview and production topologies.
- IMP-002: Override preview parameters to lower cost (for example `sku=Developer` and `virtualNetworkType=None`).
- IMP-003: Ensure post-validation cleanup is explicit in workflow logic.

## Acceptance Criteria

- AC-001: Given a PR marked for preview, when workflow automation executes, then infrastructure deployment uses `infra/main.bicep`.
- AC-002: Given a preview deployment, when parameters are resolved, then non-production overrides are applied (for example `sku=Developer` and `virtualNetworkType=None`).
- AC-003: Given successful preview provisioning, when deployment completes, then required outputs include APIM resource ID and gateway hostname.
- AC-004: Given preview validation completion, when teardown runs, then the preview environment is deleted or explicitly scheduled for cleanup.
- AC-005: Given preview provisioning failure, when workflow status is evaluated, then environment-level validation is marked failed.

## References

- REF-001: `infra/main.bicep`
- REF-002: `.github/workflows/ephemeral-apim.yml`
- REF-003: `README.md`
