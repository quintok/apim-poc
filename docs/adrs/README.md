# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for this repository.

This ADR style is aligned with guidance from `github/awesome-copilot` ADR resources (especially the ADR generator and technical writer patterns), adapted for this codebase.

## ADR Index

- [ADR-0001](./ADR-0001-author-policies-in-csharp.md): Author APIM policies in C# using the Azure APIM Policy Toolkit.
- [ADR-0002](./ADR-0002-ephemeral-apim-preview-environments.md): Use ephemeral APIM preview environments for PR validation.
- [ADR-0003](./ADR-0003-auth0-jwt-validation-policy.md): Standardize Auth0 JWT validation as a reusable APIM policy document.
- [ADR-0004](./ADR-0004-developer-portal-delegation-handler.md): Implement developer portal delegation with a .NET isolated Azure Function.
- [ADR-0005](./ADR-0005-apiops-deployment-integration.md): Deploy APIM configuration via APIOps with Policy Toolkit integration.
- [ADR-0006](./ADR-0006-smoke-tests.md): Post-deployment smoke tests as C# xUnit project.
- [ADR Template](./ADR-template.md): Standard template for all new ADRs.

## ADR Standard

Each ADR in this folder includes:

- YAML front matter (`title`, `status`, `date`, `authors`, `tags`, `supersedes`, `superseded_by`)
- Status section (`Proposed`, `Accepted`, `Rejected`, `Superseded`, `Deprecated`)
- Context and Decision sections
- Consequences split into Positive and Negative
- Alternatives Considered with rejection rationale
- Implementation Notes
- Acceptance Criteria
- References

## Acceptance Criteria Format

Use clear, testable criteria. Prefer one of:

- Given/When/Then statements
- Verifiable "shall" statements tied to code, tests, or pipeline outcomes

Example:

- AC-001: Given a PR with policy changes, when CI runs, then policy compilation completes without errors.
