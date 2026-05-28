using System.Text.Json.Serialization;

namespace Contoso.Apis.Portal.Delegation.Models;

/// <summary>
/// Shape of the JSON Auth0 returns from <c>POST /oauth/token</c> for the
/// authorization-code grant.
/// </summary>
public sealed class Auth0TokenResponse
{
    [JsonPropertyName("access_token")]
    public string AccessToken { get; init; } = string.Empty;

    [JsonPropertyName("id_token")]
    public string IdToken { get; init; } = string.Empty;

    [JsonPropertyName("token_type")]
    public string TokenType { get; init; } = string.Empty;

    [JsonPropertyName("expires_in")]
    public int ExpiresIn { get; init; }
}
