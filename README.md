# Azure APIM Policy Development Pipeline

Starter template for developing **Azure API Management (APIM)**
policies **as code** with a fast local feedback loop, automated CI,
ephemeral cloud testing, and [APIOps](https://github.com/Azure/apiops)
deployment across dev, sit, and prod environments.

Inspired by:

- [Azure API Management Policy Toolkit](https://github.com/Azure/azure-api-management-policy-toolkit) — author policies in C#, compile to APIM XML.
- [Azure APIOps](https://github.com/Azure/apiops) — GitOps workflows for APIM.
- [Azure Verified Modules (AVM)](https://aka.ms/avm) — opinionated, parameterised IaC.

## Why this template?

Hand-editing APIM `<policies>` XML is error-prone and hard to test. This
repository shows how to:

1. **Write policies in C#** as small, reusable documents and fragments.
2. **Unit-test** that C# logic against a simulated APIM context.
3. **Compile** documents to the XML APIM expects, on every build.
4. **Merge** compiled XML into an APIOps artifact tree for deployment.
5. **Lint** OpenAPI specs and detect breaking changes before they ship.
6. **Deploy** via APIOps across dev / sit / prod with per-environment config.
7. **Smoke-test** APIs post-deployment with a C# xUnit test project.
8. **Provision ephemeral APIM** per pull request for end-to-end validation.

## Repository layout

```
.
├── APIMPolicies.sln                # .NET solution
├── Directory.Build.props           # Shared MSBuild props (target framework, nullable, etc.)
├── nuget.config                    # Wires `packages/` up as a local NuGet feed
├── .config/
│   └── dotnet-tools.json           # Pinned `azure-apim-policy-compiler` dotnet tool
├── packages/                       # Drop toolkit .nupkg files here (see README inside)
├── src/
│   └── Contoso.Apis.Policies/      # Class library — policy code in C#
│       ├── Documents/              # [Document] classes: GlobalPolicy, PetstoreApiPolicy, ...
│       └── Fragments/              # Reusable constants & shared helpers
├── tests/
│   ├── Contoso.Apis.Policies.Tests # xUnit unit tests for policy documents
│   └── Contoso.Apis.SmokeTests     # xUnit post-deployment smoke tests (needs live APIM)
├── openapi/
│   └── petstore.yaml               # Sample OpenAPI spec
├── apim-artifacts/                 # APIOps artifact tree (committed)
│   ├── apis/petstore/              # API definition + operations
│   ├── fragments/                  # Policy fragment metadata
│   ├── namedValues/                # APIM named values
│   ├── subscriptions/              # Test subscriptions
│   ├── configuration.dev.yaml      # Environment overrides (dev / sit / prod)
│   ├── configuration.sit.yaml
│   ├── configuration.prod.yaml
│   └── policy.xml                  # Global policy (written by merge script)
├── .spectral.yml                   # Spectral ruleset (extends spectral:oas)
├── infra/
│   ├── main.bicep                  # APIM Bicep (infra only — no APIs/policies)
│   ├── main.parameters.json
│   └── deploy-local.ps1            # Local smoke-test deployment script
├── scripts/
│   ├── openapi-diff.sh             # Breaking-change diff vs. baseline ref
│   └── merge-policies-to-apiops.ps1 # Merges compiled XML into apim-artifacts/
├── .buildkite/
│   └── pipeline.yaml               # Primary CI pipeline
├── .github/workflows/
│   └── ephemeral-apim.yml          # Ephemeral APIM on PRs labelled `preview`
├── docs/adrs/                      # Architecture Decision Records
├── dev-test.sh                     # One-stop local validation (bash)
├── dev-test.ps1                    # One-stop local validation (PowerShell)
├── dist/policies/                  # (gitignored) compiled XML output
└── LICENSE                         # MIT
```

## Development workflow

```
   ┌────────────┐     ┌──────────┐     ┌────────────────┐     ┌────────────┐     ┌──────────┐
   │ author C#  │ ──▶ │ dev-test │ ──▶ │ PR + Buildkite │ ──▶ │  APIOps    │ ──▶ │  smoke   │
   │ policies  │     │ .sh/.ps1 │     │   green build  │     │  publisher │     │  tests   │
   └────────────┘     └──────────┘     └────────────────┘     └────────────┘     └──────────┘
                                                              │                    │
                                         merge-policies       │   deploy to        │
                                         -to-apiops.ps1 ───▶  │   dev/sit/prod     │
                                         (CI step)            │                    │
                                                              └────────────────────┘
```

1. **Author** a new document under `src/Contoso.Apis.Policies/Documents/`.
   Global cross-cutting policies go in `GlobalPolicy.cs`; API-specific
   policies go in per-API documents (e.g. `PetstoreApiPolicy.cs`).
2. **Validate locally** with `./dev-test.sh` or `./dev-test.ps1` — build, test,
   compile to XML, merge into `apim-artifacts/`, lint OpenAPI, and diff
   against `origin/main`.
3. **Open a PR**. Buildkite re-runs the same steps and merges compiled
   policies into the APIOps artifact tree.
4. **Label the PR `preview`** to provision an ephemeral APIM via GitHub
   Actions (`infra/main.bicep`) and run smoke tests.
5. **Merge**. APIOps publisher deploys `apim-artifacts/` to the target
   environment using `configuration.<env>.yaml` for overrides.

## Quick start

Prerequisites: [.NET 8 SDK](https://dotnet.microsoft.com/), Node.js 20+ (for
Spectral via `npx`), Bash or PowerShell.

### One-time bootstrap

The Azure API Management Policy Toolkit is not yet published to nuget.org.
Download the latest `.nupkg` files from the toolkit's
[GitHub Releases](https://github.com/Azure/azure-api-management-policy-toolkit/releases)
into the repo-root [`packages/`](./packages/) folder — the `nuget.config`
checked in at the root wires that folder up as a local NuGet feed.
[`packages/README.md`](./packages/README.md) has step-by-step instructions.

```bash
# After populating ./packages/ with the toolkit .nupkg files:
dotnet restore APIMPolicies.sln
dotnet tool restore                # installs `azure-apim-policy-compiler`
```

### Run the full validation loop

```bash
# Bash (Linux / macOS / WSL)
./dev-test.sh
SKIP_DIFF=1 ./dev-test.sh    # skip openapi diff on first commit

# PowerShell (Windows)
./dev-test.ps1
./dev-test.ps1 -SkipDiff
```

Output XML for deployment lands in `dist/policies/`. The merge step copies
it into `apim-artifacts/` ready for APIOps.

### Run individual steps

```bash
dotnet build  APIMPolicies.sln
dotnet test   APIMPolicies.sln

# Compile fragments -> XML via the toolkit's `dotnet tool`.
dotnet azure-apim-policy-compiler \
    --s ./src/Contoso.Apis.Policies \
    --o ./dist/policies \
    --format true

# Lint OpenAPI.
npx --yes @stoplight/spectral-cli lint --ruleset .spectral.yml \
    "openapi/**/*.{yaml,yml,json}"

# Breaking-change diff against origin/main.
./scripts/openapi-diff.sh
```

### Local smoke test deployment

Deploy APIM infrastructure, seed demo APIs, push compiled policies, and
run smoke tests against a live gateway — all from your local machine:

```powershell
# Deploy infra + seed APIs + push policies + run smoke tests
./infra/deploy-local.ps1 -DeployPolicies -RunSmokeTests
```

### APIOps deployment

In production, APIs and policies are deployed via APIOps — not the local
script. The `apim-artifacts/` folder is the APIOps artifact tree:

```bash
# Deploy to dev
apiops publish --configuration-file apim-artifacts/configuration.dev.yaml

# Promote to sit / prod
apiops publish --configuration-file apim-artifacts/configuration.sit.yaml
apiops publish --configuration-file apim-artifacts/configuration.prod.yaml
```

See [`apim-artifacts/README.md`](./apim-artifacts/README.md) and
[ADR-0005](./docs/adrs/ADR-0005-apiops-deployment-integration.md) for details.

## Using the Policy Toolkit

Each **policy document** is a C# class decorated with `[Document]` that
implements `IDocument` from
`Microsoft.Azure.ApiManagement.PolicyToolkit.Authoring`. The toolkit
translates method calls such as `context.SetHeader(...)` into the
corresponding `<set-header>` XML element.

Reusable behaviour (this template calls them "fragments") lives in
[`src/Contoso.Apis.Policies/Fragments/`](./src/Contoso.Apis.Policies/Fragments/)
as plain static helpers. Documents under
[`src/Contoso.Apis.Policies/Documents/`](./src/Contoso.Apis.Policies/Documents/)
compose them with ordinary method calls — so the same logic is shared
without copy-pasting XML across APIs.

**Global policy** (`GlobalPolicy.cs`) is applied to every request. It
handles cross-cutting concerns like correlation-id propagation. API-level
documents inherit global behaviour via `context.Base()`:

```csharp
[Document("apis/petstore/policy.xml")]
public class PetstoreApiPolicy : IDocument
{
    public void Inbound(IInboundContext context)
    {
        context.Base();
        // NOTE: Policy Toolkit v1.0.0 silently drops calls to arbitrary
        // static helpers (compiler error APIM9991), so the documents in
        // this template inline policy calls directly. The
        // `Fragments/` folder holds shared constants only; see the doc
        // comment on `AddCorrelationIdHeader` for the real reuse
        // mechanism (APIM Policy Fragments + `context.IncludeFragment`).
        context.SetHeader("x-correlation-id", "@(context.Request.Headers.GetValueOrDefault(\"x-correlation-id\", context.RequestId))");
    }
    // Outbound / Backend / OnError elided
}
```

The `[Document("apis/petstore/policy.xml")]` argument tells the compiler
to mirror the APIOps folder layout in `dist/policies/`, ready for an
APIOps-style deployment.

Unit tests wrap an `IDocument` in `TestDocument` from
`Azure.ApiManagement.PolicyToolkit.Testing` and run it through the
toolkit's policy emulator. Section effects (set-header, validate-jwt,
set-backend-service, …) mutate `test.Context.Request` / `test.Context.Response`
— see [`tests/Contoso.Apis.Policies.Tests/`](./tests/Contoso.Apis.Policies.Tests/)
for working examples. `SetupInbound().ValidateJwt().WithCallback(…)`
lets tests capture a policy's configuration object and assert on it
(see `ValidateAuth0JwtPolicyTests`).

## CI integration

- **Buildkite** (primary): `.buildkite/pipeline.yaml` runs the same steps
  as `dev-test.sh` / `dev-test.ps1`, merges compiled policies into
  `apim-artifacts/`, and produces the artifact tree for APIOps. Smoke
  tests run post-deploy (see commented step in the pipeline).
- **GitHub Actions** (optional, for ephemeral envs):
  `.github/workflows/ephemeral-apim.yml` deploys an APIM instance per PR
  when the `preview` label is applied, runs smoke tests, and comments on
  the PR. OIDC service principal and `AZURE_*` secrets are pre-configured.

## Infrastructure

`infra/main.bicep` deploys APIM infrastructure only — the service,
observability (Log Analytics + App Insights), and optional delegation
infra (Key Vault, Function App). APIs, policies, subscriptions, and
named values are deployed by APIOps (see
[ADR-0005](./docs/adrs/ADR-0005-apiops-deployment-integration.md)).

Default topology is **internal VNet mode** with **Premium** SKU. For
ephemeral / dev environments override `virtualNetworkType=None` and
`sku=StandardV2` or `sku=Developer`.

## Auth0 integration

This template ships two complementary Auth0 pieces. Both are opt-in —
deploys that don't pass the Auth0 parameters behave exactly as before.

### 1. `validate-auth0-jwt` policy fragment

A standalone policy document (`ValidateAuth0JwtPolicy`) compiles to
[`dist/policies/fragments/validate-auth0-jwt.xml`](./dist/policies/fragments/validate-auth0-jwt.xml)
and contains a fully-configured `<validate-jwt>` block for Auth0:

- `<openid-config url="https://{{auth0-tenant-domain}}/.well-known/openid-configuration"/>`
- `<audiences><audience>{{auth0-audience}}</audience></audiences>`
- `<issuers><issuer>https://{{auth0-tenant-domain}}/</issuer></issuers>` (trailing slash matters)
- `Authorization: Bearer <token>` enforced, 401 on failure, 60s clock skew, signed-tokens required.

The two `{{...}}` placeholders are APIM **named values**, deployed by
`infra/main.bicep` when `auth0TenantDomain` is set. Set them at deploy
time:

```bash
az deployment group create -g <rg> -f infra/main.bicep -p infra/main.parameters.json \
    auth0TenantDomain=contoso.auth0.com \
    auth0Audience=https://api.contoso.example
```

Unit tests (`ValidateAuth0JwtPolicyTests`) wrap the document in
`TestDocument`, hook the validate-jwt provider with
`SetupInbound().ValidateJwt().WithCallback(…)`, and assert on the
`ValidateJwtConfig` that gets handed to the gateway — catching drift
before it ships.

> **Toolkit caveat.** The toolkit v1.0.0 has no `[Fragment]` attribute, so
> the compiled XML is a full `<policies><inbound>…</inbound>…</policies>`
> document, not the snippet shape APIM Policy Fragments expect. Three
> deployment paths:
>
> 1. **Attach to an API or operation policy.** Deploy the XML as-is via
>    APIOps / `az apim api policy create`. Simplest, no transformation.
> 2. **Inline.** Copy the `<validate-jwt>` block into any document's
>    `Inbound` section that needs Auth0 protection. Verified by the
>    unit tests above.
> 3. **APIM Policy Fragment.** Hand-strip the outer `<policies>/<inbound>`
>    wrappers and deploy as `Microsoft.ApiManagement/service/policyFragments`,
>    then reference from other documents via
>    `context.IncludeFragment("validate-auth0-jwt")`.

### 2. Developer portal delegation infrastructure

Set `enableDelegation=true` to deploy the full Auth0 sign-in flow for the
APIM developer portal:

- **Storage account** (Standard_LRS, shared-key access **disabled**, MI-only)
  with a `function-deployment` blob container for the Flex Consumption
  deployment package.
- **Flex Consumption Function App** (`FC1`, .NET 8 isolated, scale-to-zero)
  hosting the delegation handler. Pre-wired with system-assigned MI,
  `AzureWebJobsStorage__accountName` / `__credential=managedidentity`
  (no connection strings), Auth0 + APIM app settings, and Key Vault
  references for `auth0ClientSecret` and `delegationValidationKey`.
- **Key Vault** holding the delegation validation key and Auth0 client
  secret. RBAC-only access; no access policies.
- **RBAC**: handler MI →
  - `Key Vault Secrets User` on the vault
  - `Storage Blob Data Owner` + `Storage Queue Data Contributor` +
    `Storage Table Data Contributor` on the storage account (required
    for AzureWebJobsStorage runtime + deployment container)
  - `API Management Service Contributor` on APIM (mint SSO tokens). In
    production, narrow to a custom role granting only
    `Microsoft.ApiManagement/service/users/token/action` plus the user
    read/write actions.
- **APIM `portalsettings/delegation`** pointing at
  `https://<func-app>.azurewebsites.net/delegation` (or your
  `delegationHandlerUrl` override).

Required secure parameters when `enableDelegation=true`:

```bash
openssl rand -base64 48  # delegationValidationKey

az deployment group create -g <rg> -f infra/main.bicep \
    -p infra/main.parameters.json \
    -p enableDelegation=true \
    -p delegationValidationKey="$(openssl rand -base64 48)" \
    -p auth0ClientId="<from Auth0 dashboard>" \
    -p auth0ClientSecret="<from Auth0 dashboard>" \
    -p auth0TenantDomain=contoso.auth0.com \
    -p auth0Audience=https://api.contoso.example
```

#### Delegation handler (shipped, in `src/Contoso.Apis.Portal.Delegation`)

The Function App project under
[`src/Contoso.Apis.Portal.Delegation/`](./src/Contoso.Apis.Portal.Delegation/)
implements the full delegated-auth flow:

| Component | File | What it does |
|---|---|---|
| `DelegationFunction` | [`Functions/DelegationFunction.cs`](./src/Contoso.Apis.Portal.Delegation/Functions/DelegationFunction.cs) | HTTP `GET /delegation` — verifies the APIM HMAC signature, branches by `operation`. `SignIn`/`SignUp` redirect to Auth0; `SignOut` redirects to Auth0 `/v2/logout`. Subscription operations 501 (signature-verified, logic TODO). |
| `Auth0CallbackFunction` | [`Functions/Auth0CallbackFunction.cs`](./src/Contoso.Apis.Portal.Delegation/Functions/Auth0CallbackFunction.cs) | HTTP `GET /auth0-callback` — validates state, exchanges code for tokens, validates the ID token (issuer/audience/lifetime/nonce + JWKS signature), looks up or creates the APIM user, mints an SSO token, redirects to `{portal}/signin-sso`. |
| `DelegationSignatureValidator` | [`Services/DelegationSignatureValidator.cs`](./src/Contoso.Apis.Portal.Delegation/Services/DelegationSignatureValidator.cs) | HMAC-SHA512(`key`, `salt + "\n" + payload`) with `CryptographicOperations.FixedTimeEquals`. |
| `StateTokenService` | [`Services/StateTokenService.cs`](./src/Contoso.Apis.Portal.Delegation/Services/StateTokenService.cs) | Stateless OIDC `state` = `base64url(json) + "." + base64url(HMAC)`. Signing key derived from the delegation validation key via HKDF with a domain-separation label — one secret, two channels, no overlap. 10-minute default lifetime. |
| `Auth0OidcClient` | [`Services/Auth0OidcClient.cs`](./src/Contoso.Apis.Portal.Delegation/Services/Auth0OidcClient.cs) | Builds `/authorize` URLs, exchanges codes at `/oauth/token`, validates ID tokens against Auth0's JWKS via `ConfigurationManager<OpenIdConnectConfiguration>` (auto-refreshing). |
| `ApimUserClient` | [`Services/ApimUserClient.cs`](./src/Contoso.Apis.Portal.Delegation/Services/ApimUserClient.cs) | ARM REST: `GET /users?$filter=email eq …`, `PUT /users/{guid}` on miss, `POST /users/{uid}/token` to mint SSO. Uses `DefaultAzureCredential` for the management.azure.com bearer token. |

Tests under
[`tests/Contoso.Apis.Portal.Delegation.Tests/`](./tests/Contoso.Apis.Portal.Delegation.Tests/)
cover the two security-critical pieces:

- `DelegationSignatureValidatorTests` — golden vector, tamper detection on
  every parameter, missing-input handling, constant-time comparison via the
  underlying API, base64-vs-utf8 key fallback.
- `StateTokenServiceTests` — round-trip, distinct nonces, payload tamper,
  signature tamper, malformed token, expiry, cross-seed rejection.

#### Deploy the handler

```bash
cd src/Contoso.Apis.Portal.Delegation
dotnet publish -c Release -o publish
Compress-Archive -Path publish/* -DestinationPath publish.zip -Force
az functionapp deployment source config-zip \
    -g <rg> -n <apim-name>-deleg --src publish.zip
```

The function URLs:

- `https://<apim-name>-deleg.azurewebsites.net/delegation`   ← APIM hits this
- `https://<apim-name>-deleg.azurewebsites.net/auth0-callback` ← Auth0 hits this

#### Auth0 application configuration (manual)

In the Auth0 dashboard, create a **Regular Web Application** with:

- Allowed Callback URL: `https://<apim-name>-deleg.azurewebsites.net/auth0-callback`
- Allowed Logout URL: `https://<apim-name>.developer.azure-api.net`
- Grant Types: Authorization Code
- Token Endpoint Authentication: `Post`
- Connections: as required (Username-Password, social, etc.)

And a separate **API** with:

- Identifier (audience) matching the `auth0Audience` parameter
- Signing Algorithm: RS256

#### What's deliberately not implemented

- **Subscription operations** (`Subscribe`, `Unsubscribe`,
  `ProductSubscribe`, `RenewSubscription`, `ChangeProfile`, `CloseAccount`)
  are signature-verified but return `501 Not Implemented`. The pattern is
  identical to `ApimUserClient.MintSsoTokenAsync` — add the corresponding
  ARM REST call and redirect to `returnUrl`.
- **`screen_hint=signup`** for the `SignUp` operation — Auth0-specific
  authorize parameter not added.
- **Custom Auth0 connection (database vs social) selection** —
  `connection` query param not forwarded.
- **Refresh tokens** — not requested; the APIM SSO token replaces the
  Auth0 session for portal access, so we don't need long-lived Auth0
  credentials at the handler.

### Observability + governance (opt-in, default ON)

`enableObservability=true` (default) wires up:

- **Log Analytics workspace** (`<apim>-law`, `PerGB2018`, retention
  `logRetentionDays`).
- **Application Insights component** (workspace-based, linked to the LAW).
- **APIM `service/loggers/applicationinsights`** + **`service/diagnostics/applicationinsights`** so
  `validate-auth0-jwt` failures, gateway requests, and the
  `x-correlation-id` header flow into App Insights.
- **Diagnostic settings** to LAW for APIM (allLogs + AllMetrics),
  Key Vault (audit + allLogs), Storage blob service (audit + transactions),
  and the Function App (allLogs + AllMetrics).
- **`APPLICATIONINSIGHTS_CONNECTION_STRING`** app setting on the Function
  App — without this, `AddApplicationInsightsTelemetryWorkerService()`
  silently no-ops.

Other governance knobs:

| Parameter | Default | Recommended for prod |
|---|---|---|
| `keyVaultPurgeProtection` | `false` | `true` — once on it cannot be turned off, so dev stays disposable |
| `keyVaultSoftDeleteRetentionDays` | `7` | `90` |
| `delegationStorageSku` | `Standard_LRS` | `Standard_ZRS` (in-region HA) or `Standard_GZRS` (geo-paired) |
| `useCustomApimRole` | `false` | `true` — replaces the broad `API Management Service Contributor` assignment with a custom 3-action role (`users/read`, `users/write`, `users/token/action`). Requires `Microsoft.Authorization/roleDefinitions/write` at the subscription scope |
| `logRetentionDays` | `30` | `90`–`730` depending on compliance |

### HttpClient resilience

The Auth0 token-exchange and APIM ARM REST clients are wrapped with
[`AddStandardResilienceHandler()`](https://learn.microsoft.com/dotnet/core/resilience/http-resilience)
(`Microsoft.Extensions.Http.Resilience`), which gives them:

- Exponential backoff retry with jitter on 5xx / 408 / `HttpRequestException`
- Per-attempt + total-request timeouts
- Circuit breaker

This means a transient Auth0 hiccup during JWKS fetch or token exchange
no longer 403's the user on the first try.

### Known architectural gaps (deliberately opt-in)

These aren't free additions — they need decisions about subnets, private
DNS zones, and certificate lifecycles. The current Bicep is **public-endpoint**
across all dependencies.

1. **VNet integration for the Function App.** When `virtualNetworkType=Internal`,
   the APIM developer portal is private-DNS-only; the browser hitting
   `/delegation` then needs to also reach the Function App through private
   networking. Solution: add `vnetRouteAllEnabled` + a virtual network
   integration subnet + a Private Endpoint with `Sites` group ID on the
   Function App, and put both behind the same private DNS zone.
2. **Private endpoints for Key Vault and Storage.** Storage is already
   locked down via `allowSharedKeyAccess: false`, but inbound is still
   on public Azure. Add `privateEndpoints` for `vault`/`blob`/`queue`/`table`
   + `privatelink.vaultcore.azure.net` / `privatelink.blob.core.windows.net` /
   etc. DNS zones.
3. **Storage CMK + Key Vault HSM.** Move from PMK to customer-managed
   keys for both, with an HSM-backed Key Vault for the encryption key.
4. **Custom domain + certificate** on the Function App (Azure-managed cert
   on App Service is the cheapest path).
5. **Alerts.** No metric/log alerts on APIM 5xx, KV throttling, Function
   exceptions, or AI Failed Request rate. Add via
   `Microsoft.Insights/metricAlerts` + `scheduledQueryRules`.
6. **Resource locks** on production-tier resources (APIM, KV, LAW).

## Smoke tests

Post-deployment smoke tests live in
[`tests/Contoso.Apis.SmokeTests/`](./tests/Contoso.Apis.SmokeTests/).
API owners add xUnit test classes extending `SmokeTestBase`:

```csharp
public class MyApiSmokeTests : SmokeTestBase
{
    protected override string ApiId => "my-api";
    protected override string ApiPath => "my-api";

    [Fact]
    public async Task HealthCheck_Returns200()
    {
        var response = await Client.GetAsync("health");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }
}
```

Smoke tests require `APIM_GATEWAY_URL` and per-API subscription key env
vars. They are excluded from `dev-test.sh` / `dev-test.ps1` (offline
validation) and run only after deployment to a live gateway. See
[ADR-0006](./docs/adrs/ADR-0006-smoke-tests.md).

## Architecture Decision Records

Key design decisions are documented in [`docs/adrs/`](./docs/adrs/):

| ADR | Decision |
|-----|----------|
| [ADR-0001](./docs/adrs/ADR-0001-author-policies-in-csharp.md) | Author policies in C# with Policy Toolkit |
| [ADR-0002](./docs/adrs/ADR-0002-ephemeral-apim-preview-environments.md) | Ephemeral APIM preview environments |
| [ADR-0003](./docs/adrs/ADR-0003-auth0-jwt-validation-policy.md) | Standardize Auth0 JWT validation |
| [ADR-0004](./docs/adrs/ADR-0004-developer-portal-delegation-handler.md) | Developer portal delegation handler |
| [ADR-0005](./docs/adrs/ADR-0005-apiops-deployment-integration.md) | APIOps deployment integration |
| [ADR-0006](./docs/adrs/ADR-0006-smoke-tests.md) | Post-deployment smoke tests |

## References

- [Azure API Management Policy Toolkit](https://github.com/Azure/azure-api-management-policy-toolkit)
- [Azure APIOps Toolkit](https://github.com/Azure/apiops)
- [Azure Verified Modules](https://aka.ms/avm)
- [APIM policy reference](https://learn.microsoft.com/azure/api-management/api-management-policies)
- [Spectral OpenAPI linter](https://stoplight.io/open-source/spectral)
- [oasdiff (OpenAPI breaking-change diff)](https://github.com/Tufin/oasdiff)

## License

[MIT](./LICENSE)
