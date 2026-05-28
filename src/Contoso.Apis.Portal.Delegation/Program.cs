using Azure.Core;
using Azure.Identity;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Http.Resilience;
using Microsoft.Extensions.Hosting;

using Contoso.Apis.Portal.Delegation.Configuration;
using Contoso.Apis.Portal.Delegation.Services;

var builder = FunctionsApplication.CreateBuilder(args);

builder.ConfigureFunctionsWebApplication();

builder.Services
    .AddApplicationInsightsTelemetryWorkerService()
    .ConfigureFunctionsApplicationInsights();

// --- Options -----------------------------------------------------------------
builder.Services
    .AddOptions<Auth0Options>()
    .Bind(builder.Configuration.GetSection(Auth0Options.SectionName))
    .ValidateDataAnnotations();

builder.Services
    .AddOptions<ApimOptions>()
    .Bind(builder.Configuration.GetSection(ApimOptions.SectionName))
    .ValidateDataAnnotations();

builder.Services
    .AddOptions<StateOptions>()
    .Bind(builder.Configuration.GetSection(StateOptions.SectionName))
    .ValidateDataAnnotations();

// --- Services ----------------------------------------------------------------
// Single TokenCredential instance. In Azure we get a managed-identity token;
// in local dev `az login` picks up the developer's tenant. The other sources
// DefaultAzureCredential probes (Visual Studio, shared cache, interactive
// browser, PowerShell) are excluded — they add latency on every cold start
// and aren't usable from a Function App anyway.
builder.Services.AddSingleton<TokenCredential>(_ => new DefaultAzureCredential(new DefaultAzureCredentialOptions
{
    ExcludeInteractiveBrowserCredential = true,
    ExcludeSharedTokenCacheCredential   = true,
    ExcludeVisualStudioCredential       = true,
    ExcludeVisualStudioCodeCredential   = true,
    ExcludeAzurePowerShellCredential    = true,
    ExcludeWorkloadIdentityCredential   = true,
    // Kept enabled: ManagedIdentityCredential (Azure), AzureCliCredential (local dev),
    // EnvironmentCredential (CI/CD service principals via env vars).
}));

builder.Services.AddSingleton<DelegationSignatureValidator>();
builder.Services.AddSingleton<StateTokenService>();

// Both HTTP clients get the standard resilience pipeline: retry with
// exponential backoff + jitter, per-attempt timeout, circuit breaker,
// total-request timeout. Sane defaults; safe for idempotent calls. The
// APIM REST calls are idempotent (GET) or use a deterministic GUID for
// PUT so duplicate retries are safe.
builder.Services
    .AddHttpClient<Auth0OidcClient>(http =>
    {
        http.Timeout = TimeSpan.FromSeconds(30); // total — resilience handler enforces shorter per-attempt timeouts
    })
    .AddStandardResilienceHandler();

builder.Services
    .AddHttpClient<ApimUserClient>(http =>
    {
        http.Timeout = TimeSpan.FromSeconds(30);
    })
    .AddStandardResilienceHandler();

builder.Build().Run();
