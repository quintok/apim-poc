using System.ComponentModel.DataAnnotations;

namespace Contoso.Apis.Portal.Delegation.Configuration;

/// <summary>
/// APIM connection settings for the delegation handler.
/// </summary>
public sealed class ApimOptions
{
    public const string SectionName = "Apim";

    /// <summary>APIM service name (the <c>{name}</c> in <c>https://{name}.developer.azure-api.net</c>).</summary>
    [Required]
    public string ServiceName { get; set; } = string.Empty;

    /// <summary>Full ARM resource ID of the APIM service.</summary>
    [Required]
    public string ResourceId { get; set; } = string.Empty;

    /// <summary>Developer portal base URL, e.g. <c>https://contoso.developer.azure-api.net</c>.</summary>
    [Required]
    public string PortalUrl { get; set; } = string.Empty;

    /// <summary>Base64-encoded HMAC-SHA512 key APIM uses to sign delegation request parameters.</summary>
    [Required]
    public string DelegationValidationKey { get; set; } = string.Empty;
}

/// <summary>
/// State token (anti-CSRF, OIDC nonce, return URL) tuning.
/// </summary>
public sealed class StateOptions
{
    public const string SectionName = "State";

    /// <summary>How long a signed state token is accepted after issuance. Default 10 minutes.</summary>
    [Range(60, 3600)]
    public int LifetimeSeconds { get; set; } = 600;
}
