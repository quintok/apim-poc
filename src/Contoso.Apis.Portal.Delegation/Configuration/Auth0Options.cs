using System.ComponentModel.DataAnnotations;

namespace Contoso.Apis.Portal.Delegation.Configuration;

/// <summary>
/// Auth0 OIDC client configuration. All values come from Function App settings
/// (set by <c>infra/main.bicep</c>) — secrets via Key Vault references.
/// </summary>
public sealed class Auth0Options
{
    public const string SectionName = "Auth0";

    /// <summary>Auth0 tenant domain, no scheme, no trailing slash. e.g. <c>contoso.auth0.com</c>.</summary>
    [Required]
    public string Domain { get; set; } = string.Empty;

    /// <summary>API Identifier (audience) the access token must be issued for.</summary>
    [Required]
    public string Audience { get; set; } = string.Empty;

    /// <summary>Auth0 application client ID (public).</summary>
    [Required]
    public string ClientId { get; set; } = string.Empty;

    /// <summary>Auth0 application client secret (from Key Vault).</summary>
    [Required]
    public string ClientSecret { get; set; } = string.Empty;

    /// <summary>Clock skew tolerance for ID token <c>exp</c>/<c>iat</c>/<c>nbf</c> validation. Default 60 s.</summary>
    public int ClockSkewSeconds { get; set; } = 60;

    /// <summary>Auth0 issuer URL with trailing slash, derived from <see cref="Domain"/>.</summary>
    public string Issuer => $"https://{Domain}/";

    /// <summary>OpenID Connect discovery document URL, derived from <see cref="Domain"/>.</summary>
    public string OpenIdConfigurationUrl => $"https://{Domain}/.well-known/openid-configuration";

    /// <summary><c>/authorize</c> endpoint URL.</summary>
    public string AuthorizeEndpoint => $"https://{Domain}/authorize";

    /// <summary><c>/oauth/token</c> endpoint URL.</summary>
    public string TokenEndpoint => $"https://{Domain}/oauth/token";

    /// <summary><c>/v2/logout</c> endpoint URL.</summary>
    public string LogoutEndpoint => $"https://{Domain}/v2/logout";
}
