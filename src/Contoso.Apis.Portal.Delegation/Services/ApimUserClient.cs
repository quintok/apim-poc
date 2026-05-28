using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Azure.Core;
using Microsoft.Extensions.Options;

using Contoso.Apis.Portal.Delegation.Configuration;

namespace Contoso.Apis.Portal.Delegation.Services;

/// <summary>
/// Talks to the APIM ARM REST API to (a) find-or-create the user whose
/// identity Auth0 just authenticated and (b) mint a single-sign-on token
/// that the dev portal accepts at <c>/signin-sso</c>.
///
/// <para><b>Authentication</b>: the Function App's system-assigned managed
/// identity gets a bearer token for <c>https://management.azure.com/</c>
/// via <see cref="TokenCredential"/> on each call (the credential caches
/// internally).</para>
///
/// <para><b>Roles required</b>: configured by <c>infra/main.bicep</c> —
/// API Management Service Contributor (broad) or a custom role granting
/// <c>Microsoft.ApiManagement/service/users/token/action</c> +
/// <c>users/write</c> + <c>users/read</c>.</para>
/// </summary>
public sealed class ApimUserClient
{
    private const string ArmScope = "https://management.azure.com/.default";
    private const string ArmBase = "https://management.azure.com";
    private const string ApiVersion = "2022-08-01";

    private readonly HttpClient _http;
    private readonly TokenCredential _credential;
    private readonly ApimOptions _opts;

    public ApimUserClient(HttpClient http, TokenCredential credential, IOptions<ApimOptions> opts)
    {
        ArgumentNullException.ThrowIfNull(http);
        ArgumentNullException.ThrowIfNull(credential);
        ArgumentNullException.ThrowIfNull(opts);
        _http = http;
        _credential = credential;
        _opts = opts.Value;
    }

    /// <summary>
    /// Returns the APIM user ID (the <c>{uid}</c> in the resource path) for
    /// the given email — creating a new user when not found.
    /// </summary>
    public async Task<string> FindOrCreateUserAsync(string email, string firstName, string lastName, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(email))
        {
            throw new ArgumentException("email is required to look up the APIM user.", nameof(email));
        }

        var token = await GetArmTokenAsync(cancellationToken).ConfigureAwait(false);

        // Try to find an existing user by email. APIM's $filter uses OData syntax.
        var filter = Uri.EscapeDataString($"email eq '{email.Replace("'", "''", StringComparison.Ordinal)}'");
        var listUri = $"{ArmBase}{_opts.ResourceId}/users?$filter={filter}&api-version={ApiVersion}";
        var existing = await SendAsync<UserListResponse>(HttpMethod.Get, listUri, body: null, token, cancellationToken).ConfigureAwait(false);

        if (existing.Value is { Length: > 0 } users && users[0].Name is { Length: > 0 } existingName)
        {
            return existingName;
        }

        // Not found — create. APIM requires a UUID-like user ID per service.
        var newUserId = Guid.NewGuid().ToString("N");
        var createUri = $"{ArmBase}{_opts.ResourceId}/users/{newUserId}?notify=false&api-version={ApiVersion}";
        var createBody = new
        {
            properties = new
            {
                email,
                firstName = string.IsNullOrWhiteSpace(firstName) ? "Auth0" : firstName,
                lastName  = string.IsNullOrWhiteSpace(lastName) ? "User" : lastName,
                state     = "active",
                confirmation = "signup",
            },
        };
        var created = await SendAsync<UserResource>(HttpMethod.Put, createUri, JsonContent.Create(createBody), token, cancellationToken).ConfigureAwait(false);
        return created.Name ?? throw new InvalidOperationException("APIM returned a created user without a name.");
    }

    /// <summary>
    /// Mints an SSO token for the given user. Default lifetime: 1 hour.
    /// </summary>
    /// <returns>The opaque token to append as <c>?token=...</c> to the
    /// portal's <c>/signin-sso</c> URL.</returns>
    public async Task<string> MintSsoTokenAsync(string userId, TimeSpan? lifetime, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(userId))
        {
            throw new ArgumentException("userId is required.", nameof(userId));
        }

        var armToken = await GetArmTokenAsync(cancellationToken).ConfigureAwait(false);
        var ttl = lifetime ?? TimeSpan.FromHours(1);
        var body = new
        {
            keyType = "primary",
            expiry = DateTimeOffset.UtcNow.Add(ttl).ToString("O"),
        };
        var uri = $"{ArmBase}{_opts.ResourceId}/users/{userId}/token?api-version={ApiVersion}";
        var response = await SendAsync<UserTokenResponse>(HttpMethod.Post, uri, JsonContent.Create(body), armToken, cancellationToken).ConfigureAwait(false);
        return response.Value ?? throw new InvalidOperationException("APIM returned an empty SSO token.");
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    private async Task<string> GetArmTokenAsync(CancellationToken cancellationToken)
    {
        var ctx = new TokenRequestContext(new[] { ArmScope });
        var token = await _credential.GetTokenAsync(ctx, cancellationToken).ConfigureAwait(false);
        return token.Token;
    }

    private async Task<T> SendAsync<T>(HttpMethod method, string uri, HttpContent? body, string bearer, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(method, uri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearer);
        if (body is not null)
        {
            request.Content = body;
        }

        using var response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            var payload = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            throw new HttpRequestException($"APIM REST call to {uri} failed ({(int)response.StatusCode} {response.ReasonPhrase}): {payload}");
        }

        var result = await response.Content.ReadFromJsonAsync<T>(cancellationToken: cancellationToken).ConfigureAwait(false);
        return result ?? throw new InvalidOperationException($"APIM REST call to {uri} returned an empty body.");
    }

    // ARM resource shapes (minimal — only the fields we care about).
    private sealed class UserListResponse
    {
        [JsonPropertyName("value")]
        public UserResource[]? Value { get; init; }
    }

    private sealed class UserResource
    {
        [JsonPropertyName("name")]
        public string? Name { get; init; }
    }

    private sealed class UserTokenResponse
    {
        [JsonPropertyName("value")]
        public string? Value { get; init; }
    }
}
