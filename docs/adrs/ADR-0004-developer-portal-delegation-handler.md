---
title: "ADR-0004: Implement Developer Portal Delegation with .NET Isolated Azure Function"
status: "Accepted"
date: "2026-05-27"
authors:
	- "Contoso API Platform Team"
tags:
	- architecture
	- apim
	- azure-functions
supersedes: ""
superseded_by: ""
---

# ADR-0004: Implement Developer Portal Delegation with .NET Isolated Azure Function

## Status

Accepted

## Context

The APIM developer portal delegation flow requires a secure handler to validate signatures, exchange/validate identity data, and return delegation responses. The repository already contains a .NET isolated Functions project for this responsibility.

## Decision

Implement delegation handling in `src/Contoso.Apis.Portal.Delegation` using Azure Functions (.NET isolated), dependency-injected services, and managed identity-friendly authentication patterns.

## Consequences

### Positive

- POS-001: Uses familiar .NET patterns and testability for delegation logic.
- POS-002: Supports resilient outbound HTTP calls through standard handlers.

### Negative

- NEG-001: Requires cloud configuration (Auth0, APIM, Key Vault, Function settings).
- NEG-002: Requires operational monitoring and secret management discipline.

## Alternatives Considered

### Implement delegation handler as a traditional App Service

- ALT-001: Description: Host the delegation endpoint in an always-on web app.
- ALT-002: Rejection Reason: Higher baseline operational cost for a bursty workload profile.

### Implement handler in a non-.NET runtime

- ALT-003: Description: Use a different language/runtime for the delegation endpoint.
- ALT-004: Rejection Reason: Lower consistency with existing .NET codebase and test patterns.

## Implementation Notes

- IMP-001: Keep configuration strongly typed and validated in startup.
- IMP-002: Keep signature and state token logic isolated in dedicated services with unit tests.
- IMP-003: Use dependency-injected `HttpClient` registrations with resilience handlers for APIM/Auth0 interactions.

## Acceptance Criteria

- AC-001: Given function startup in `Program.cs`, when options are bound, then APIM/Auth0/state option validation succeeds.
- AC-002: Given signature validation service and tests, when tests execute, then valid signatures pass and invalid signatures fail.
- AC-003: Given state token service and tests, when tests execute, then state token generation and validation behavior is correct.
- AC-004: Given outbound APIM/Auth0 integrations, when services are resolved, then calls use dependency-injected `HttpClient` with resilience handlers.
- AC-005: Given delegation is enabled in deployment configuration, when infrastructure is provisioned, then hosting and required configuration dependencies are present.

## References

- REF-001: `src/Contoso.Apis.Portal.Delegation/Program.cs`
- REF-002: `src/Contoso.Apis.Portal.Delegation/Services`
- REF-003: `tests/Contoso.Apis.Portal.Delegation.Tests`
- REF-004: `infra/main.bicep`
