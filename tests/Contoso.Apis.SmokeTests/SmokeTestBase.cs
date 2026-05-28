using System.Net;
using Xunit;

namespace Contoso.Apis.SmokeTests;

/// <summary>
/// Base class for API smoke tests. Provides <see cref="HttpClient"/>,
/// gateway URL, and subscription-key resolution from environment variables.
///
/// <para><b>Environment variables (set by CI or deploy-local.ps1):</b></para>
/// <list type="bullet">
///   <item><c>APIM_GATEWAY_URL</c> — e.g. <c>https://apim-poc-8fdc26ac.azure-api.net</c></item>
///   <item><c>APIM_SUBSCRIPTION_KEY__{API_ID}</c> — per-API subscription key,
///         e.g. <c>APIM_SUBSCRIPTION_KEY__PETSTORE</c>. The API ID is upper-cased
///         with hyphens replaced by underscores.</item>
/// </list>
///
/// <para>
/// API owners subclass this, set <see cref="ApiPath"/> and <see cref="ApiId"/>,
/// and write regular xUnit <c>[Fact]</c> / <c>[Theory]</c> tests using
/// <see cref="Client"/> to make HTTP requests.
/// </para>
/// </summary>
public abstract class SmokeTestBase : IDisposable
{
    /// <summary>APIM API id (used to resolve subscription key). Override in subclass.</summary>
    protected abstract string ApiId { get; }

    /// <summary>API base path on the gateway (e.g. "petstore"). Override in subclass.</summary>
    protected abstract string ApiPath { get; }

    /// <summary>Pre-configured <see cref="HttpClient"/> targeting the API's base URL with subscription key.</summary>
    protected HttpClient Client { get; }

    /// <summary>The full base URL for this API (gateway + path).</summary>
    protected string BaseUrl { get; }

    protected SmokeTestBase()
    {
        var gatewayUrl = Environment.GetEnvironmentVariable("APIM_GATEWAY_URL")
            ?? throw new InvalidOperationException(
                "APIM_GATEWAY_URL environment variable is not set. " +
                "Set it to the APIM gateway URL, e.g. https://my-apim.azure-api.net");

        gatewayUrl = gatewayUrl.TrimEnd('/');
        BaseUrl = $"{gatewayUrl}/{ApiPath}";

        var envKey = $"APIM_SUBSCRIPTION_KEY__{ApiId.ToUpperInvariant().Replace('-', '_')}";
        var subscriptionKey = Environment.GetEnvironmentVariable(envKey);

        Client = new HttpClient { BaseAddress = new Uri(BaseUrl + "/") };
        Client.Timeout = TimeSpan.FromSeconds(30);

        if (!string.IsNullOrEmpty(subscriptionKey))
        {
            Client.DefaultRequestHeaders.Add("Ocp-Apim-Subscription-Key", subscriptionKey);
        }
    }

    /// <summary>Assert the response has a non-empty header value.</summary>
    protected static void AssertHeaderPresent(HttpResponseMessage response, string headerName)
    {
        Assert.True(
            response.Headers.TryGetValues(headerName, out var values) && values.Any(v => !string.IsNullOrEmpty(v)),
            $"Expected response header '{headerName}' to be present and non-empty");
    }

    /// <summary>Assert the response header has an exact value.</summary>
    protected static void AssertHeaderValue(HttpResponseMessage response, string headerName, string expected)
    {
        Assert.True(response.Headers.TryGetValues(headerName, out var values), $"Expected header '{headerName}' to be present");
        Assert.Contains(expected, values!);
    }

    public void Dispose()
    {
        Client.Dispose();
        GC.SuppressFinalize(this);
    }
}
