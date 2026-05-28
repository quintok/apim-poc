---
title: "ADR-0007: Time-Based API Release and Retirement via Lifecycle Gate Policy"
status: "Proposed"
date: "2026-05-28"
authors:
  - "Contoso API Platform Team"
tags:
  - architecture
  - lifecycle
  - policy
  - apiops
supersedes: ""
superseded_by: ""
---

# ADR-0007: Time-Based API Release and Retirement via Lifecycle Gate Policy

## Status

Proposed

## Context

API producers need to schedule when an API (or a specific version) becomes available to consumers ("go-live"), when it enters a deprecation window with sunset warnings, and when it is fully retired. Today the repository has no standard mechanism for date/time-driven lifecycle transitions; releases and retirements require ad-hoc policy edits and redeployments at the exact cut-over moment, which is operationally fragile, hard to audit, and inconsistent across environments (`dev`, `sit`, `prod`).

Constraints and forces:

- Policies are authored in C# via the Azure APIM Policy Toolkit (ADR-0001) and compiled to `policy.xml` artifacts.
- Deployment is performed by APIOps (ADR-0005); per-environment configuration is expressed in `apim-artifacts/configuration.<env>.yaml` and `apim-artifacts/namedValues/`.
- Reusable cross-cutting policy concerns are implemented as policy fragments (e.g., `apim-artifacts/fragments/validate-auth0-jwt/`).
- Consumers expect industry-standard deprecation signals (`Sunset`, `Deprecation`, `Link rel="sunset"`) per RFC 8594 and RFC 9745.
- Different environments must be able to transition on different schedules without code changes (e.g., retire in `dev` two weeks before `prod`).

## Decision

Adopt a two-layer, time-based lifecycle model for every managed API:

1. **Soft lifecycle (gateway policy)** — A reusable C# policy fragment, `LifecycleGate`, is included from every API's inbound policy. It reads three per-API named values containing ISO-8601 UTC timestamps:
   - `api.<name>.goLiveUtc`
   - `api.<name>.deprecateUtc`
   - `api.<name>.retireUtc`

   At request time the fragment compares `context.Timestamp` against these values and applies one of four behaviors:
   - **Pre-release** (`now < goLiveUtc`): short-circuit with `503 Service Unavailable` and `Retry-After: <goLiveUtc>`.
   - **Active** (`goLiveUtc <= now < deprecateUtc`): pass through unchanged.
   - **Deprecated** (`deprecateUtc <= now < retireUtc`): pass through and add `Deprecation: true`, `Sunset: <retireUtc as HTTP-date>`, and `Link: <{{api.<name>.sunsetDocsUrl}}>; rel="sunset"` response headers.
   - **Retired** (`now >= retireUtc`): short-circuit with `410 Gone` and the same `Sunset`/`Link` headers for traceability.

2. **Hard retirement (APIOps)** — A scheduled GitHub Actions workflow runs daily, evaluates each API's `retireUtc` (plus a configurable grace period), removes the API directory under `apim-artifacts/apis/<name>/`, updates `reconcile-allowlist.<env>.yaml`, and lets the existing APIOps publish pipeline (ADR-0005) reconcile the deletion from the gateway and developer portal.

Named values are managed in `apim-artifacts/namedValues/` and surfaced per environment via `configuration.<env>.yaml`, so the same compiled policy ships everywhere and lifecycle transitions are driven entirely by configuration.

## Consequences

### Positive

- POS-001: Lifecycle cut-overs occur on schedule with no code change or redeploy at the exact moment of transition.
- POS-002: Consumers receive standards-based deprecation signals (`Sunset`, `Deprecation`, `Link`) ahead of retirement, improving client migration outcomes.
- POS-003: Per-environment timestamps allow staggered rollouts (e.g., retire in `dev` first to validate consumer impact).
- POS-004: Reusing the fragment pattern (as with `validate-auth0-jwt`) keeps lifecycle behavior consistent across all APIs and centrally testable.
- POS-005: Hard removal is auditable through Git history of `apim-artifacts/apis/` and the scheduled workflow run logs.

### Negative

- NEG-001: Adds three required named values per API; missing values must be handled defensively (fragment defaults to "active" when any timestamp is unset).
- NEG-002: Gateway clock skew or named-value propagation lag can cause sub-minute transition inaccuracy; not suitable for hard millisecond cut-overs.
- NEG-003: Hard-retirement workflow has destructive intent and requires guardrails (allowlist confirmation, dry-run, manual approval for `prod`).
- NEG-004: Smoke tests (ADR-0006) must be able to override timestamps to exercise pre-release, deprecated, and retired states.

## Alternatives Considered

### Ad-hoc redeploy at cut-over

- ALT-001: Description: Manually edit the API's policy or remove the API directory at the precise moment of release or retirement.
- ALT-002: Rejection Reason: Operationally fragile, requires out-of-hours human action, no standard deprecation signaling, and high drift risk across environments.

### Azure-platform scheduling (e.g., Logic App / Function flipping APIM state)

- ALT-003: Description: An external scheduler toggles API state via the APIM ARM/REST API at the configured time.
- ALT-004: Rejection Reason: Bypasses APIOps as the source of truth (ADR-0005), creates configuration drift between Git and the gateway, and provides no consumer-facing deprecation headers.

### Versioning alone (publish v2, leave v1 in place indefinitely)

- ALT-005: Description: Rely solely on APIM version sets and never formally retire old versions.
- ALT-006: Rejection Reason: Accumulates unmaintained surface area, increases security and support burden, and gives consumers no deadline to migrate.

### Backend-enforced retirement

- ALT-007: Description: Have backend services return `410` after the retirement date.
- ALT-008: Rejection Reason: Wastes gateway-to-backend round trips, fragments the policy across teams, and prevents removal of the API surface from the developer portal.

## Implementation Notes

- IMP-001: Add `src/Contoso.Apis.Policies/Fragments/LifecycleGatePolicy.cs` implementing the four-state `<choose>` block; compile to `apim-artifacts/fragments/lifecycle-gate/`.
- IMP-002: Include the fragment from every API's `policy.xml` inbound section immediately after `<base />` and before authentication policies, so retired APIs short-circuit before token validation.
- IMP-003: Define named values in `apim-artifacts/namedValues/` with naming convention `api.<api-name>.goLiveUtc`, `api.<api-name>.deprecateUtc`, `api.<api-name>.retireUtc`, `api.<api-name>.sunsetDocsUrl`. Values are ISO-8601 UTC (`yyyy-MM-ddTHH:mm:ssZ`).
- IMP-004: Per-environment overrides live in `apim-artifacts/configuration.dev.yaml`, `configuration.sit.yaml`, and `configuration.prod.yaml`.
- IMP-005: When any timestamp named value is missing or unparseable, the fragment treats the API as active and emits a diagnostic via `trace` so misconfiguration is observable rather than failing closed.
- IMP-006: Unit-test the fragment with `LifecycleGatePolicyTests` covering all four states and missing/invalid timestamps, following the pattern in `tests/Contoso.Apis.Policies.Tests/`.
- IMP-007: Add smoke tests (ADR-0006) that assert status code and `Sunset`/`Deprecation`/`Link` headers for representative APIs, using a fixed test clock or named-value override.
- IMP-008: Add a scheduled GitHub Actions workflow `.github/workflows/retire-apis.yml` running daily (cron) that:
  - Reads `retireUtc` for every API in `apim-artifacts/apis/`.
  - For APIs past `retireUtc + gracePeriodDays` (default 14), opens an automated PR removing the API directory and updating the reconcile allowlist.
  - Requires manual approval before merge for `prod`.
- IMP-009: Document the lifecycle states, header semantics, and operator runbook (how to bring forward, postpone, or roll back a retirement) in `apim-artifacts/README.md`.
- IMP-010: Ownership: API Platform team owns the fragment, workflow, and convention; individual API teams own the timestamp values for their APIs.

## Acceptance Criteria

- AC-001: Given an API with `goLiveUtc` in the future, when a request arrives, then the gateway responds `503` with a `Retry-After` header equal to `goLiveUtc`.
- AC-002: Given an API with `goLiveUtc <= now < deprecateUtc`, when a request arrives, then the gateway forwards the request to the backend and adds no lifecycle headers.
- AC-003: Given an API with `deprecateUtc <= now < retireUtc`, when a request arrives, then the response includes `Deprecation: true`, `Sunset: <retireUtc as HTTP-date>`, and `Link: <docs>; rel="sunset"` headers.
- AC-004: Given an API with `now >= retireUtc`, when a request arrives, then the gateway responds `410 Gone` and includes `Sunset` and `Link` headers.
- AC-005: Given any lifecycle timestamp named value is missing or unparseable, when a request arrives, then the API behaves as active and a trace entry is emitted.
- AC-006: Given `LifecycleGatePolicyTests` run, when the test suite executes, then all four state transitions and the misconfiguration fallback pass.
- AC-007: Given the scheduled retirement workflow runs, when an API's `retireUtc` plus grace period has elapsed, then a PR is opened that removes the API directory and updates the reconcile allowlist; merges to `prod` require manual approval.
- AC-008: Given timestamps differ across `configuration.dev.yaml`, `configuration.sit.yaml`, and `configuration.prod.yaml`, when APIOps deploys each environment, then each gateway transitions on its own schedule without code changes.

## References

- REF-001: ADR-0001 — Author APIM policies in C# using the Azure APIM Policy Toolkit.
- REF-002: ADR-0005 — Deploy APIM configuration via APIOps with Policy Toolkit integration.
- REF-003: ADR-0006 — Post-deployment smoke tests as C# xUnit project.
- REF-004: `apim-artifacts/fragments/validate-auth0-jwt/` — reference pattern for reusable policy fragments.
- REF-005: RFC 8594 — The `Sunset` HTTP Header Field.
- REF-006: RFC 9745 — The `Deprecation` HTTP Header Field.
- REF-007: Azure API Management policy expressions — `context.Timestamp`.
