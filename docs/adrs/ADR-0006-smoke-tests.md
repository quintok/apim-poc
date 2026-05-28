---
title: "ADR-0006: Post-Deployment Smoke Tests as C# xUnit Project"
status: "Accepted"
date: "2026-05-28"
authors:
  - "Contoso API Platform Team"
tags:
  - architecture
  - testing
  - smoke-tests
supersedes: ""
superseded_by: ""
---

# ADR-0006: Post-Deployment Smoke Tests as C# xUnit Project

## Status

Accepted

## Context

API owners need confidence that their APIs work after deployment to each environment. Unit tests validate policy logic offline, but cannot confirm gateway routing, subscription-key enforcement, or end-to-end header propagation against a live APIM instance.

## Decision

Provide a dedicated xUnit test project (`tests/Contoso.Apis.SmokeTests`) for post-deployment smoke tests. API owners add test classes that extend `SmokeTestBase`, which provides a pre-configured `HttpClient` with gateway URL and subscription key from environment variables. Smoke tests are excluded from the offline `dev-test` pipeline and run only after deployment to a live gateway.

## Consequences

### Positive

- POS-001: API owners use familiar C# and xUnit patterns — no new tooling to learn.
- POS-002: Smoke tests are discoverable, version-controlled, and run in CI like any other test.
- POS-003: Each API team owns their own test class independently.

### Negative

- NEG-001: Requires a live APIM gateway and subscription keys to run.
- NEG-002: Smoke tests add time to the post-deployment pipeline.

## Alternatives Considered

### YAML-based test definitions with a PowerShell runner

- ALT-001: Description: Define tests as YAML files with a convention-based PS1 runner.
- ALT-002: Rejection Reason: Introduces a second testing paradigm; the team already knows C#/xUnit.

### Postman / Newman collections

- ALT-003: Description: Use Postman collections exported as JSON and run via Newman.
- ALT-004: Rejection Reason: External tool dependency; harder to version-control and review in PRs.

## Implementation Notes

- IMP-001: `SmokeTestBase` reads `APIM_GATEWAY_URL` and `APIM_SUBSCRIPTION_KEY__<API_ID>` from environment variables.
- IMP-002: Smoke tests are filtered out of `dev-test.sh` / `dev-test.ps1` via `--filter "FullyQualifiedName!~SmokeTests"`.
- IMP-003: `deploy-local.ps1 -RunSmokeTests` resolves keys from APIM and runs `dotnet test` with the correct env vars.

## Acceptance Criteria

- AC-001: Given a new API, when an owner adds a class extending `SmokeTestBase` with `[Fact]` methods, then those tests are discovered and run by `dotnet test`.
- AC-002: Given `APIM_GATEWAY_URL` and subscription key env vars are set, when smoke tests run, then requests target the correct gateway and API path.
- AC-003: Given the offline `dev-test` scripts, when they run `dotnet test`, then smoke tests are excluded.
- AC-004: Given `deploy-local.ps1 -RunSmokeTests`, when executed after deployment, then smoke tests run against the live APIM and report pass/fail.

## References

- REF-001: `tests/Contoso.Apis.SmokeTests/SmokeTestBase.cs`
- REF-002: `tests/Contoso.Apis.SmokeTests/PetstoreSmokeTests.cs`
- REF-003: `tests/Contoso.Apis.SmokeTests/EchoApiSmokeTests.cs`
- REF-004: `infra/deploy-local.ps1`
