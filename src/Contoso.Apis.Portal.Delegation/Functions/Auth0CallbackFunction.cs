using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

using Contoso.Apis.Portal.Delegation.Configuration;
using Contoso.Apis.Portal.Delegation.Services;

namespace Contoso.Apis.Portal.Delegation.Functions;

/// <summary>
/// Receives Auth0's <c>code</c>+<c>state</c> callback after a successful
/// sign-in, swaps the code for tokens, validates the ID token, ensures the
/// matching APIM user exists, mints an APIM SSO token, and redirects the
/// browser to <c>{portal}/signin-sso?token=...&amp;returnUrl=...</c>.
///
/// <para>If anything fails — bad state, expired state, invalid ID token,
/// nonce mismatch — we return 403. We deliberately do NOT echo the
/// underlying error to the browser; failures are logged with structured
/// properties for the platform to alert on.</para>
/// </summary>
public sealed class Auth0CallbackFunction
{
    private readonly StateTokenService _state;
    private readonly Auth0OidcClient _auth0;
    private readonly ApimUserClient _apim;
    private readonly ApimOptions _apimOpts;
    private readonly ILogger<Auth0CallbackFunction> _log;

    public Auth0CallbackFunction(
        StateTokenService state,
        Auth0OidcClient auth0,
        ApimUserClient apim,
        IOptions<ApimOptions> apimOpts,
        ILogger<Auth0CallbackFunction> log)
    {
        _state = state;
        _auth0 = auth0;
        _apim = apim;
        _apimOpts = apimOpts.Value;
        _log = log;
    }

    [Function("Auth0Callback")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "auth0-callback")] HttpRequest req,
        CancellationToken cancellationToken)
    {
        var code  = req.Query["code"].ToString();
        var state = req.Query["state"].ToString();
        var error = req.Query["error"].ToString();
        var errorDescription = req.Query["error_description"].ToString();

        if (!string.IsNullOrEmpty(error))
        {
            // Auth0 redirected back with an error (e.g. user cancelled,
            // access_denied). Send them home rather than 500.
            _log.LogWarning("Auth0 returned an error: {Error} ({Description})", error, errorDescription);
            return new RedirectResult(_apimOpts.PortalUrl, permanent: false, preserveMethod: false);
        }

        if (string.IsNullOrEmpty(code) || string.IsNullOrEmpty(state))
        {
            _log.LogWarning("Auth0 callback missing code/state.");
            return new StatusCodeResult(StatusCodes.Status403Forbidden);
        }

        var stateToken = _state.Validate(state);
        if (stateToken is null)
        {
            _log.LogWarning("Auth0 callback rejected: state token failed validation.");
            return new StatusCodeResult(StatusCodes.Status403Forbidden);
        }

        var redirectUri = DelegationFunction.BuildCallbackUri(req);

        Models.Auth0TokenResponse tokens;
        try
        {
            tokens = await _auth0.ExchangeCodeAsync(code, redirectUri, cancellationToken).ConfigureAwait(false);
        }
        catch (HttpRequestException ex)
        {
            _log.LogError(ex, "Auth0 token exchange failed.");
            return new StatusCodeResult(StatusCodes.Status403Forbidden);
        }

        System.Security.Claims.ClaimsPrincipal principal;
        try
        {
            principal = await _auth0.ValidateIdTokenAsync(tokens.IdToken, stateToken.Nonce, cancellationToken).ConfigureAwait(false);
        }
        catch (Microsoft.IdentityModel.Tokens.SecurityTokenException ex)
        {
            _log.LogError(ex, "Auth0 ID token validation failed.");
            return new StatusCodeResult(StatusCodes.Status403Forbidden);
        }

        var email     = principal.FindFirst("email")?.Value ?? string.Empty;
        var firstName = principal.FindFirst("given_name")?.Value ?? string.Empty;
        var lastName  = principal.FindFirst("family_name")?.Value ?? string.Empty;

        if (string.IsNullOrWhiteSpace(email))
        {
            _log.LogWarning("Auth0 ID token has no email claim — cannot map to an APIM user.");
            return new StatusCodeResult(StatusCodes.Status403Forbidden);
        }

        string apimUserId;
        try
        {
            apimUserId = await _apim.FindOrCreateUserAsync(email, firstName, lastName, cancellationToken).ConfigureAwait(false);
        }
        catch (HttpRequestException ex)
        {
            _log.LogError(ex, "APIM user lookup/create failed for {Email}.", email);
            return new StatusCodeResult(StatusCodes.Status403Forbidden);
        }

        string ssoToken;
        try
        {
            ssoToken = await _apim.MintSsoTokenAsync(apimUserId, lifetime: null, cancellationToken).ConfigureAwait(false);
        }
        catch (HttpRequestException ex)
        {
            _log.LogError(ex, "APIM SSO token mint failed for user {UserId}.", apimUserId);
            return new StatusCodeResult(StatusCodes.Status403Forbidden);
        }

        var returnTo = string.IsNullOrEmpty(stateToken.ReturnUrl) ? "/" : stateToken.ReturnUrl;
        var portalSsoUrl =
            $"{_apimOpts.PortalUrl.TrimEnd('/')}/signin-sso" +
            $"?token={Uri.EscapeDataString(ssoToken)}" +
            $"&returnUrl={Uri.EscapeDataString(returnTo)}";

        _log.LogInformation("Auth0 OIDC roundtrip complete for {Email}; redirecting to portal SSO.", email);
        return new RedirectResult(portalSsoUrl, permanent: false, preserveMethod: false);
    }
}
