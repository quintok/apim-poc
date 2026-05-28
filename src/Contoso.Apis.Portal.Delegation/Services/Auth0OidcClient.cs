using System.Net.Http.Json;
using System.Security.Claims;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using System.IdentityModel.Tokens.Jwt;

using Contoso.Apis.Portal.Delegation.Configuration;
using Contoso.Apis.Portal.Delegation.Models;

namespace Contoso.Apis.Portal.Delegation.Services;

/// <summary>
/// Talks to Auth0 over OIDC: builds the <c>/authorize</c> URL, exchanges
/// the returned code for tokens at <c>/oauth/token</c>, and validates the
/// returned ID token against Auth0's JWKS.
/// </summary>
public sealed class Auth0OidcClient
{
    private readonly HttpClient _http;
    private readonly Auth0Options _opts;
    private readonly ConfigurationManager<OpenIdConnectConfiguration> _oidcConfig;

    public Auth0OidcClient(HttpClient http, IOptions<Auth0Options> opts)
    {
        ArgumentNullException.ThrowIfNull(http);
        ArgumentNullException.ThrowIfNull(opts);
        _http = http;
        _opts = opts.Value;

        // ConfigurationManager auto-refreshes the OIDC discovery doc and
        // JWKS every 24h (default). Cheap and safe to construct once.
        _oidcConfig = new ConfigurationManager<OpenIdConnectConfiguration>(
            _opts.OpenIdConfigurationUrl,
            new OpenIdConnectConfigurationRetriever(),
            new HttpDocumentRetriever { RequireHttps = true });
    }

    /// <summary>
    /// Builds the Auth0 <c>/authorize</c> URL we redirect the browser to.
    /// </summary>
    public Uri BuildAuthorizeUrl(string redirectUri, string state, string nonce)
    {
        var qs = new List<KeyValuePair<string, string>>
        {
            new("response_type", "code"),
            new("client_id", _opts.ClientId),
            new("redirect_uri", redirectUri),
            new("scope", "openid profile email"),
            new("audience", _opts.Audience),
            new("state", state),
            new("nonce", nonce),
            new("prompt", "login"),
        };
        var query = string.Join("&",
            qs.Select(kv => $"{Uri.EscapeDataString(kv.Key)}={Uri.EscapeDataString(kv.Value)}"));
        return new Uri($"{_opts.AuthorizeEndpoint}?{query}");
    }

    /// <summary>
    /// Builds the Auth0 <c>/v2/logout</c> URL. APIM has already cleared its
    /// portal cookies before redirecting us here.
    /// </summary>
    public Uri BuildLogoutUrl(string returnTo)
        => new($"{_opts.LogoutEndpoint}?client_id={Uri.EscapeDataString(_opts.ClientId)}&returnTo={Uri.EscapeDataString(returnTo)}");

    /// <summary>
    /// Exchanges an authorization code for access + ID tokens.
    /// </summary>
    public async Task<Auth0TokenResponse> ExchangeCodeAsync(string code, string redirectUri, CancellationToken cancellationToken)
    {
        var body = new FormUrlEncodedContent(new[]
        {
            new KeyValuePair<string, string>("grant_type", "authorization_code"),
            new KeyValuePair<string, string>("client_id", _opts.ClientId),
            new KeyValuePair<string, string>("client_secret", _opts.ClientSecret),
            new KeyValuePair<string, string>("code", code),
            new KeyValuePair<string, string>("redirect_uri", redirectUri),
        });

        using var response = await _http.PostAsync(_opts.TokenEndpoint, body, cancellationToken).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        var tokens = await response.Content.ReadFromJsonAsync<Auth0TokenResponse>(cancellationToken).ConfigureAwait(false);
        return tokens ?? throw new InvalidOperationException("Auth0 returned an empty token response.");
    }

    /// <summary>
    /// Validates the ID token's signature, issuer, audience, lifetime, and
    /// (when <paramref name="expectedNonce"/> is non-empty) its nonce
    /// claim. Returns the principal's claims on success; throws on any
    /// validation failure.
    /// </summary>
    public async Task<ClaimsPrincipal> ValidateIdTokenAsync(string idToken, string expectedNonce, CancellationToken cancellationToken)
    {
        var oidc = await _oidcConfig.GetConfigurationAsync(cancellationToken).ConfigureAwait(false);

        var parameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = _opts.Issuer,
            ValidateAudience = true,
            ValidAudience = _opts.ClientId, // ID token aud = client_id for Auth0 OIDC
            ValidateLifetime = true,
            ClockSkew = TimeSpan.FromSeconds(_opts.ClockSkewSeconds),
            ValidateIssuerSigningKey = true,
            IssuerSigningKeys = oidc.SigningKeys,
        };

        var handler = new JwtSecurityTokenHandler();
        var principal = handler.ValidateToken(idToken, parameters, out var validated);

        if (!string.IsNullOrEmpty(expectedNonce))
        {
            var jwt = (JwtSecurityToken)validated;
            var nonceClaim = jwt.Payload.TryGetValue("nonce", out var n) ? n?.ToString() : null;
            if (!string.Equals(nonceClaim, expectedNonce, StringComparison.Ordinal))
            {
                throw new SecurityTokenException("Auth0 ID token nonce did not match the value sent on /authorize.");
            }
        }

        return principal;
    }
}
