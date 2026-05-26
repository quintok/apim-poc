# Azure APIM Policy Development Pipeline

Starter template for developing **Azure API Management (APIM) Premium v2**
policies **as code** with a fast local feedback loop, automated CI, and
ephemeral cloud testing.

Inspired by:

- [Azure API Management Policy Toolkit](https://github.com/Azure/azure-api-management-policy-toolkit) — author policies in C#, compile to APIM XML.
- [Azure APIOps](https://github.com/Azure/apiops) — GitOps workflows for APIM.
- [Azure Verified Modules (AVM)](https://aka.ms/avm) — opinionated, parameterised IaC.

## Why this template?

Hand-editing APIM `<policies>` XML is error-prone and hard to test. This
repository shows how to:

1. **Write policies in C#** as small, reusable fragments.
2. **Unit-test** that C# logic against a simulated APIM context.
3. **Compile** fragments to the XML APIM expects, on every build.
4. **Lint** OpenAPI specs and detect breaking changes before they ship.
5. **Provision an ephemeral APIM** per pull request for end-to-end validation.

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
│       ├── Fragments/              # Reusable building blocks (static helpers)
│       └── Documents/              # Full [Document] classes composed of fragments
├── tests/
│   └── Contoso.Apis.Policies.Tests # xUnit tests using Policy Toolkit test helpers
├── openapi/
│   └── petstore.yaml               # Sample OpenAPI spec
├── .spectral.yml                   # Spectral ruleset (extends spectral:oas)
├── infra/
│   ├── main.bicep                  # APIM Bicep (Premium / internal VNet)
│   └── main.parameters.json
├── scripts/
│   └── openapi-diff.sh             # Breaking-change diff vs. baseline ref
├── .buildkite/
│   └── pipeline.yaml               # Primary CI pipeline
├── .github/workflows/
│   └── ephemeral-apim.yml          # Ephemeral APIM on PRs labelled `preview`
├── dev-test.sh                     # One-stop local validation
├── dist/policies/                  # (gitignored) compiled XML output
└── LICENSE                         # MIT
```

## Development workflow

```
   ┌────────────┐      ┌──────────┐      ┌────────────────┐      ┌────────────┐
   │ author C#  │ ───▶ │ dev-test │ ───▶ │ PR + Buildkite │ ───▶ │ ephemeral  │
   │ fragments  │      │   .sh    │      │   green build  │      │   APIM     │
   └────────────┘      └──────────┘      └────────────────┘      └────────────┘
                                                                       │
                                                                       ▼
                                                              ┌────────────────┐
                                                              │ shared dev /   │
                                                              │ prod APIM      │
                                                              └────────────────┘
```

1. **Author** a new fragment under `src/Contoso.Apis.Policies/Fragments/`.
   Reference it from a `Document` class to compose into a full policy.
2. **Validate locally** with `./dev-test.sh` — build, test, compile to XML,
   lint OpenAPI, and diff against `origin/main`.
3. **Open a PR**. Buildkite re-runs the same steps and packages
   `dist/policies/*.xml` as an artifact.
4. **Label the PR `preview`** to provision an ephemeral APIM via GitHub
   Actions (`infra/main.bicep`) for end-to-end validation.
5. **Merge**. A downstream deployment pipeline (out of scope here) promotes
   the compiled XML to the shared non-prod and production APIM instances —
   typically via [APIOps](https://github.com/Azure/apiops).

## Quick start

Prerequisites: [.NET 8 SDK](https://dotnet.microsoft.com/), Node.js 20+ (for
Spectral via `npx`), Bash.

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
# Run every check the CI pipeline runs.
./dev-test.sh

# Skip the openapi diff (e.g. on the very first commit).
SKIP_DIFF=1 ./dev-test.sh
```

Output XML for deployment lands in `dist/policies/`.

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
without copy-pasting XML across APIs:

```csharp
[Document("apis/petstore/policy.xml")]
public class PetstoreApiPolicy : IDocument
{
    public void Inbound(IInboundContext context)
    {
        context.Base();
        AddCorrelationIdHeader.ApplyInbound(context); // <-- reusable fragment
    }
    // Outbound / Backend / OnError elided
}
```

The `[Document("apis/petstore/policy.xml")]` argument tells the compiler
to mirror the APIOps folder layout in `dist/policies/`, ready for an
APIOps-style deployment.

Unit tests use `MockInboundContext` / `MockOutboundContext` from the
`Microsoft.Azure.ApiManagement.PolicyToolkit.Testing` package to record
the operations a fragment performs without standing up a real gateway —
see [`tests/Contoso.Apis.Policies.Tests/`](./tests/Contoso.Apis.Policies.Tests/).

## CI integration

- **Buildkite** (primary): `.buildkite/pipeline.yaml` runs the same five
  steps as `dev-test.sh`, then packages `dist/policies/*.xml` as a build
  artifact for downstream deploys.
- **GitHub Actions** (optional, for ephemeral envs):
  `.github/workflows/ephemeral-apim.yml` deploys an APIM instance per PR
  when the `preview` label is applied. Wire it up by configuring an OIDC
  service principal and the `AZURE_*` repository secrets — see the comments
  at the top of the workflow file.

## Infrastructure

`infra/main.bicep` deploys an APIM service in **internal VNet mode** by
default (production topology). For ephemeral PR environments override
`virtualNetworkType=None` and `sku=Developer` to keep cost and provisioning
time low.

Outputs (`apimResourceId`, `apimGatewayHostname`, `apimPrincipalId`) are
ready to be consumed by downstream Key Vault / Private DNS / APIOps steps.

## References

- [Azure API Management Policy Toolkit](https://github.com/Azure/azure-api-management-policy-toolkit)
- [Azure APIOps Toolkit](https://github.com/Azure/apiops)
- [Azure Verified Modules](https://aka.ms/avm)
- [APIM policy reference](https://learn.microsoft.com/azure/api-management/api-management-policies)
- [Spectral OpenAPI linter](https://stoplight.io/open-source/spectral)
- [oasdiff (OpenAPI breaking-change diff)](https://github.com/Tufin/oasdiff)

## License

[MIT](./LICENSE)
