namespace Contoso.Apis.Portal.Delegation.Models;

/// <summary>
/// What we encode into the OIDC <c>state</c> parameter on the way out to Auth0
/// and verify when Auth0 calls us back. Persisting this server-side would
/// add infrastructure for no benefit — instead we HMAC-sign it so the round
/// trip is stateless but tamper-evident.
/// </summary>
public sealed class StateToken
{
    /// <summary>The original APIM <c>returnUrl</c> we redirect to after SSO.</summary>
    public string ReturnUrl { get; init; } = string.Empty;

    /// <summary>The delegation operation that initiated the flow (currently always <c>SignIn</c>).</summary>
    public string Operation { get; init; } = string.Empty;

    /// <summary>OIDC nonce the ID token must echo back.</summary>
    public string Nonce { get; init; } = string.Empty;

    /// <summary>Unix-seconds timestamp at which the state was issued.</summary>
    public long IssuedAt { get; init; }
}
