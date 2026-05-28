# APIOps Artifact Tree

This folder contains the APIOps-managed APIM configuration — everything that
the [APIOps publisher](https://github.com/Azure/apiops) deploys to the APIM
service.

## What lives here (committed by humans / extractor)

- **API definitions** — `apis/<id>/apiInformation.json`, operations, schemas
- **Products** — `products/<id>/productInformation.json`
- **Subscriptions** — `subscriptions/<id>.json`
- **Named values** — `namedValues/<name>.json`
- **Fragment metadata** — `fragments/<name>/fragmentInformation.json`

## What gets overwritten by CI (do NOT hand-edit)

- `policy.xml` (global) — compiled from `src/.../Documents/GlobalPolicy.cs`
- `apis/*/policy.xml` — compiled from API-scoped `[Document]` classes
- `fragments/*/policy.xml` — compiled from fragment `[Document]` classes

The merge step (`scripts/merge-policies-to-apiops.ps1`) copies compiled XML
from `dist/policies/` into this tree during CI, overwriting only the policy
files. Everything else in this folder is the source of truth.

## Workflow

```
 Author C#       compile         merge            APIOps
 policies   ──▶  to XML    ──▶  into this   ──▶  publisher
                 (dist/)        folder           (to APIM)
                                ▲
                                │
                 Hand-author ───┘
                 API defs, products,
                 named values, etc.
```
