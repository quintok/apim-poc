---
title: "ADR-0003: Standardize Auth0 JWT Validation as a Reusable APIM Policy"
status: "Accepted"
date: "2026-05-27"
authors:
	- "Contoso API Platform Team"
tags:
	- architecture
	- security
	- auth0
supersedes: ""
superseded_by: ""
---

# ADR-0003: Standardize Auth0 JWT Validation as a Reusable APIM Policy

## Status

Accepted

## Context

Protected APIs require consistent JWT validation behavior across products and APIs. Drift in issuer, audience, or token requirements can create security gaps.

## Decision

Maintain a dedicated policy document (`ValidateAuth0JwtPolicy`) that enforces Auth0 JWT validation requirements and uses APIM named values for tenant and audience.

## Consequences

### Positive

- POS-001: Establishes a single source of truth for Auth0 token validation.
- POS-002: Reduces copy-paste and configuration drift.

### Negative

- NEG-001: Requires named values to be provisioned in APIM.
- NEG-002: Requires updates when identity provider requirements change.

## Alternatives Considered

### Duplicate JWT policy per API

- ALT-001: Description: Keep JWT validation policy logic embedded separately in each API policy.
- ALT-002: Rejection Reason: High drift risk and harder governance across APIs.

### Validate tokens only in backend services

- ALT-003: Description: Remove gateway validation and rely exclusively on backend token checks.
- ALT-004: Rejection Reason: Loses uniform edge enforcement and increases downstream load.

## Implementation Notes

- IMP-001: Keep canonical JWT requirements in `ValidateAuth0JwtPolicy.cs`.
- IMP-002: Validate configuration by unit tests that assert issuer, audience, scheme, and failure behavior.
- IMP-003: Ensure infrastructure provisions `auth0-tenant-domain` and `auth0-audience` when Auth0 is enabled.

## Acceptance Criteria

- AC-001: Given `ValidateAuth0JwtPolicy.cs`, when policy configuration is evaluated, then it validates `Authorization` with `Bearer` scheme.
- AC-002: Given named values are configured, when policy values are rendered, then issuer and OpenID metadata resolve from `{{auth0-tenant-domain}}` and audience from `{{auth0-audience}}`.
- AC-003: Given JWT validation failure, when request processing continues, then the response status is HTTP 401.
- AC-004: Given policy unit tests, when `ValidateAuth0JwtPolicyTests` run, then issuer, audience, scheme, and failed-validation behavior assertions pass.
- AC-005: Given Auth0 integration is enabled in infrastructure, when deployment succeeds, then required named values exist for policy resolution.

## References

- REF-001: `src/Contoso.Apis.Policies/Documents/ValidateAuth0JwtPolicy.cs`
- REF-002: `tests/Contoso.Apis.Policies.Tests/ValidateAuth0JwtPolicyTests.cs`
- REF-003: `infra/main.bicep`
