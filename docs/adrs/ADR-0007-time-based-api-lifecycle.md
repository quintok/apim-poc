---
title: "ADR-0007: Time-Based API Lifecycle Scheduling at the Product Scope"
status: "Proposed"
date: "2026-05-29"
authors:
  - "Contoso API Platform Team"
tags:
  - architecture
  - lifecycle
  - policy
  - apiops
  - developer-portal
supersedes: ""
superseded_by: ""
---

# ADR-0007: Time-Based API Lifecycle Scheduling at the Product Scope

## Status

Proposed

## Context

API producers need to schedule when a consumer offering becomes available ("go-live"), when it enters a deprecation window with sunset warnings, and when it is fully retired. Today the repository has no standard mechanism for date/time-driven lifecycle transitions; releases and retirements require ad-hoc edits and manual redeploys at the exact cut-over moment, which is operationally fragile, hard to audit, and inconsistent across environments (`dev`, `sit`, `prod`).

Three concerns must be addressed together, not in isolation:

1. **Gateway behaviour** — pre-release requests should be refused; deprecated requests should carry standards-based warning headers; retired requests should be rejected.
2. **Developer portal visibility** — a not-yet-live offering must not appear in the public portal, and a retired offering must disappear from it. Portal visibility is controlled by Product membership and group visibility, not by API state.
3. **Coexistence with revisions and versions** — non-breaking change (revisions) and breaking change (versions) are existing APIM mechanisms that must not be conflated with lifecycle scheduling.

In APIM the **Product** is the unit that already aligns with all three: it controls portal visibility (per group), subscription issuance, and Product-scoped policy. APIs and their revisions are *technical artefacts*; Products are the *commercial contract*. Scheduling lifecycle at the Product scope therefore lines up with how APIM already separates these concerns.

Constraints and forces:

- Policies are authored in C# via the Azure APIM Policy Toolkit (ADR-0001) and compiled to `policy.xml` artifacts.
- Deployment is performed by APIOps (ADR-0005); per-environment configuration is expressed in `apim-artifacts/configuration.<env>.yaml` and `apim-artifacts/namedValues/`.
- Reusable cross-cutting policy concerns are implemented as policy fragments (e.g., `apim-artifacts/fragments/validate-auth0-jwt/`).
- Consumers expect industry-standard deprecation signals (`Sunset`, `Deprecation`, `Link rel="sunset"`) per RFC 8594 and RFC 9745.
- Smoke tests (ADR-0006) must be able to assert lifecycle state without waiting for wall-clock transitions.
- Different environments must transition on different schedules without code changes (e.g., retire in `dev` two weeks before `prod`).

## Decision

Adopt a **Product-scoped**, time-based lifecycle model with three coordinated layers:

1. **Gateway gating (Product-scope policy fragment).** A reusable C# policy fragment, `LifecycleGate`, is included from each Product's inbound policy (not the API's). It reads four per-Product named values:
   - `product.<name>.goLiveUtc`
   - `product.<name>.deprecateUtc`
   - `product.<name>.retireUtc`
   - `product.<name>.sunsetDocsUrl`

   At request time the fragment compares `context.Timestamp` against the timestamps and applies one of four behaviours, which apply uniformly to **every API and every revision** in that Product:
   - **Pre-release** (`now < goLiveUtc`): short-circuit with `503 Service Unavailable` and `Retry-After: <goLiveUtc>`.
   - **Active** (`goLiveUtc <= now < deprecateUtc`): pass through unchanged.
   - **Deprecated** (`deprecateUtc <= now < retireUtc`): pass through and add `Deprecation: true`, `Sunset: <retireUtc as HTTP-date>`, and `Link: <{{product.<name>.sunsetDocsUrl}}>; rel="sunset"` response headers.
   - **Retired** (`now >= retireUtc`): short-circuit with `410 Gone` plus `Sunset` / `Link` headers for traceability.

   The fragment is forbidden at API scope to avoid double-application; this is enforced by a lint check in the policy build.

2. **Portal visibility (APIOps-driven Product membership).** The same scheduled APIOps workflow that owns lifecycle transitions also owns Product group-visibility and API↔Product link files in `apim-artifacts/`:
   - Before `goLiveUtc`: the Product is visible only to internal groups (e.g., `apim-internal`) so the API does **not** appear in the developer portal for `Guests` or `Developers`.
   - At `goLiveUtc`: a PR is opened that grants `Guests`/`Developers` group visibility (per the Product's published visibility policy).
   - At `retireUtc`: a PR is opened that revokes public group visibility; the Product (and therefore its APIs) disappears from the portal.
   - After `retireUtc + gracePeriodDays`: an optional PR removes the Product directory entirely. APIs themselves are not deleted by lifecycle automation — they may belong to other Products with independent schedules.

3. **Revisions and versions remain orthogonal.** Lifecycle scheduling **does not** drive revision promotion or version creation:
   - **Revisions** (non-breaking change) are promoted by API teams at any time during the Product's active window. The Product gate fires before revision routing, so a freshly-promoted revision inherits the Product's state automatically. A revision may be promoted *before* `goLiveUtc` (for soak testing via an internal-Product subscription) without becoming externally visible.
   - **Versions** (breaking change) live in **separate Products** (e.g., `petstore-v1`, `petstore-v2`), each with its own lifecycle schedule. Retiring `v1` is retiring the `petstore-v1` Product; it has no effect on `petstore-v2`.
   - An API may belong to multiple Products simultaneously (e.g., `internal` with no schedule and `public-v1` with a retirement date). Subscriptions to the unretired Product continue to work after the retired Product is gated.

Named values, Product↔API links, and Product group-visibility live in `apim-artifacts/` and are surfaced per environment via `configuration.<env>.yaml`, so the same compiled policy ships everywhere and lifecycle transitions are driven entirely by configuration.

## Consequences

### Positive

- POS-001: Lifecycle cut-overs occur on schedule with no code change or redeploy at the moment of transition.
- POS-002: Consumers receive standards-based deprecation signals (`Sunset`, `Deprecation`, `Link`) ahead of retirement, improving migration outcomes.
- POS-003: Pre-release Products do not appear in the public developer portal — the visibility, gating, and subscription concerns all align with the Product scope.
- POS-004: Per-environment timestamps allow staggered rollouts (e.g., retire in `dev` first to validate consumer impact).
- POS-005: Revisions remain a pure non-breaking-change mechanism; teams can soak a new revision under an internal Product before the public Product opens, with no extra coordination.
- POS-006: Versioning stays a pure breaking-change mechanism; v1 and v2 retire on independent Product schedules, and shared APIs are unaffected.
- POS-007: One API in multiple Products supports the common case where internal consumers keep using something the public Product has retired.

### Negative

- NEG-001: Adds four required named values per Product; missing values must be handled defensively (fragment defaults to "active" when any timestamp is unset).
- NEG-002: Gateway clock skew or named-value propagation lag can cause sub-minute transition inaccuracy; not suitable for hard millisecond cut-overs.
- NEG-003: Lifecycle automation has destructive intent (group-visibility changes, eventual Product removal) and requires guardrails (allowlist confirmation, dry-run, manual approval for `prod`).
- NEG-004: Smoke tests (ADR-0006) must exercise lifecycle states without waiting on the wall clock (test clock for unit tests; named-value overrides in ephemeral preview environments — see ADR-0002).
- NEG-005: Product-scope `LifecycleGate` forbids API-scope use to prevent double evaluation; this needs to be enforced and documented for API teams who might otherwise reach for it.

## Alternatives Considered

### API-scope lifecycle scheduling

- ALT-001: Description: Include `LifecycleGate` at the API policy scope with `api.<name>.*` named values (the original draft of this ADR).
- ALT-002: Rejection Reason: Misaligned with how APIM exposes offerings — portal visibility and subscriptions are Product-scoped, so API-scope timestamps would not solve "don't show it in the portal until it's live." Also forces duplication when an API belongs to two Products with different lifecycles (e.g., `internal` and `public-v1`).

### Ad-hoc redeploy at cut-over

- ALT-003: Description: Manually edit the Product or API and redeploy at the exact moment of release or retirement.
- ALT-004: Rejection Reason: Operationally fragile, requires out-of-hours human action, no standard deprecation signaling, and high drift risk across environments.

### Azure-platform scheduling (Logic App / Function flipping APIM state)

- ALT-005: Description: An external scheduler toggles Product state via the APIM ARM/REST API at the configured time.
- ALT-006: Rejection Reason: Bypasses APIOps as the source of truth (ADR-0005), creates drift between Git and the gateway, and provides no consumer-facing deprecation headers.

### Versioning alone (publish v2, leave v1 in place indefinitely)

- ALT-007: Description: Rely solely on APIM version sets and never formally retire old versions.
- ALT-008: Rejection Reason: Accumulates unmaintained surface area, increases security and support burden, and gives consumers no deadline to migrate.

### Backend-enforced retirement

- ALT-009: Description: Have backend services return `410` after the retirement date.
- ALT-010: Rejection Reason: Wastes gateway-to-backend round trips, fragments the policy across teams, and prevents removal of the offering from the developer portal.

### Use revisions as a lifecycle mechanism

- ALT-011: Description: Model retirement as making the "retired" behaviour a non-current revision; model pre-release as a non-current revision until cut-over.
- ALT-012: Rejection Reason: Revisions are explicitly for non-breaking change. Retirement is a breaking change for consumers and a *commercial* event, not a technical one; Products are the right scope.

## Implementation Notes

- IMP-001: Add `src/Contoso.Apis.Policies/Fragments/LifecycleGatePolicy.cs` implementing the four-state `<choose>` block; compile to `apim-artifacts/fragments/lifecycle-gate/`.
- IMP-002: Include the fragment from each **Product** policy's inbound section immediately after `<base />` and before authentication policies, so pre-release/retired Products short-circuit before token validation.
- IMP-003: Define named values in `apim-artifacts/namedValues/` with naming convention `product.<product-name>.goLiveUtc`, `product.<product-name>.deprecateUtc`, `product.<product-name>.retireUtc`, `product.<product-name>.sunsetDocsUrl`. Values are ISO-8601 UTC (`yyyy-MM-ddTHH:mm:ssZ`).
- IMP-004: Per-environment overrides live in `apim-artifacts/configuration.dev.yaml`, `configuration.sit.yaml`, and `configuration.prod.yaml`.
- IMP-005: When any timestamp named value is missing or unparseable, the fragment treats the Product as active and emits a diagnostic via `trace` so misconfiguration is observable rather than failing closed.
- IMP-006: Add a build-time lint check that fails compilation if `LifecycleGate` is referenced from any API-scope or operation-scope policy. Document the rule in `apim-artifacts/README.md`.
- IMP-007: Unit-test the fragment with `LifecycleGatePolicyTests` covering all four states and missing/invalid timestamps, using the Policy Toolkit test harness with an injected clock. Follow the pattern in `tests/Contoso.Apis.Policies.Tests/`.
- IMP-008: Add smoke tests (ADR-0006) that, **per Product**, assert:
  - Gateway status code and `Sunset`/`Deprecation`/`Link` headers for the current state.
  - That every API in a `now < goLiveUtc` Product is not returned when listing APIs from the developer portal as a `Guests`/`Developers` user (call APIM's management API or the portal REST surface).
  - That every API in a `now >= retireUtc` Product is not visible to `Guests`/`Developers`.
  Pre-live Product smoke tests use a subscription key scoped to the internal Product so the soak path is exercisable.
- IMP-009: Add a scheduled GitHub Actions workflow `.github/workflows/product-lifecycle.yml` running daily (cron) that:
  - Reads `goLiveUtc`, `deprecateUtc`, `retireUtc` for every Product in `apim-artifacts/`.
  - At `goLiveUtc`: opens a PR adding public group visibility (`Guests`/`Developers`) to the Product.
  - At `retireUtc`: opens a PR revoking public group visibility.
  - At `retireUtc + gracePeriodDays` (default 14): opens a PR removing the Product directory and updating the reconcile allowlist.
  - Auto-merges for `dev`/`sit`; requires manual approval for `prod`.
- IMP-010: Document the lifecycle states, header semantics, revision/version interaction, and operator runbook (how to bring forward, postpone, or roll back) in `apim-artifacts/README.md`.
- IMP-011: Ownership: API Platform team owns the fragment, workflow, lint check, and convention; individual API teams own the timestamp values and Product↔API link files for their offerings.

## Acceptance Criteria

- AC-001: Given a Product with `goLiveUtc` in the future, when a subscribed request arrives, then the gateway responds `503` with `Retry-After` equal to `goLiveUtc`.
- AC-002: Given a Product with `goLiveUtc <= now < deprecateUtc`, when a request arrives, then the gateway forwards to the backend and adds no lifecycle headers.
- AC-003: Given a Product with `deprecateUtc <= now < retireUtc`, when a request arrives, then the response includes `Deprecation: true`, `Sunset: <retireUtc as HTTP-date>`, and `Link: <docs>; rel="sunset"`.
- AC-004: Given a Product with `now >= retireUtc`, when a request arrives, then the gateway responds `410 Gone` with `Sunset` and `Link` headers.
- AC-005: Given any lifecycle timestamp named value is missing or unparseable, when a request arrives, then the Product behaves as active and a trace entry is emitted.
- AC-006: Given `LifecycleGatePolicyTests` run with an injected clock, when the suite executes, then all four state transitions and the misconfiguration fallback pass.
- AC-007: Given a Product with `now < goLiveUtc`, when a `Guests` or `Developers` user lists APIs in the developer portal, then no API belonging to that Product is returned.
- AC-008: Given a Product with `now >= retireUtc`, when a `Guests` or `Developers` user lists APIs in the developer portal, then no API belonging to that Product is returned.
- AC-009: Given a new revision is promoted to `current` while `now < goLiveUtc`, when external consumers call the Product, then they still receive `503`; when internal consumers call the API via the internal Product, then they receive the promoted revision's behaviour.
- AC-010: Given an API belongs to a retired Product and an active Product, when a request uses the active Product's subscription, then it succeeds with no lifecycle headers.
- AC-011: Given API version `v2` lives in Product `public-v2` and version `v1` lives in Product `public-v1`, when `public-v1.retireUtc` elapses, then `public-v2` is unaffected.
- AC-012: Given a developer adds `LifecycleGate` at API or operation scope, when the policy build runs, then the lint check fails with a clear error message.
- AC-013: Given the scheduled workflow runs, when a Product passes `goLiveUtc`, `retireUtc`, or `retireUtc + gracePeriodDays`, then the corresponding PR is opened; `prod` merges require manual approval.
- AC-014: Given timestamps differ across `configuration.dev.yaml`, `configuration.sit.yaml`, and `configuration.prod.yaml`, when APIOps deploys each environment, then each gateway transitions on its own schedule without code changes.

## References

- REF-001: ADR-0001 — Author APIM policies in C# using the Azure APIM Policy Toolkit.
- REF-002: ADR-0002 — Ephemeral APIM preview environments for PR validation.
- REF-003: ADR-0004 — Developer portal delegation handler.
- REF-004: ADR-0005 — Deploy APIM configuration via APIOps with Policy Toolkit integration.
- REF-005: ADR-0006 — Post-deployment smoke tests as C# xUnit project.
- REF-006: `apim-artifacts/fragments/validate-auth0-jwt/` — reference pattern for reusable policy fragments.
- REF-007: RFC 8594 — The `Sunset` HTTP Header Field.
- REF-008: RFC 9745 — The `Deprecation` HTTP Header Field.
- REF-009: Azure API Management — Products, revisions, and versions documentation.
- REF-010: Azure API Management policy expressions — `context.Timestamp`.
