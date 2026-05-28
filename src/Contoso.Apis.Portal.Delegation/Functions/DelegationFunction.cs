using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

using Contoso.Apis.Portal.Delegation.Configuration;
using Contoso.Apis.Portal.Delegation.Models;
using Contoso.Apis.Portal.Delegation.Services;

namespace Contoso.Apis.Portal.Delegation.Functions;

/// <summary>
/// The entry point APIM hits at <c>/delegation?operation=...&amp;sig=...</c>.
///
/// <para>Per
/// <see href="https://learn.microsoft.com/azure/api-management/api-management-howto-setup-delegation">
/// the APIM delegation reference</see>, this single endpoint receives all
/// delegated operations (SignIn, SignOut, SignUp, Subscribe, etc.). We
/// branch on <c>operation</c> after verifying the HMAC signature.</para>
///
/// <para>For sign-in / sign-up we kick off an OIDC roundtrip with Auth0 —
/// the actual session minting happens in <see cref="Auth0CallbackFunction"/>
/// once Auth0 redirects back.</para>
/// </summary>
public sealed class DelegationFunction
{
    private readonly DelegationSignatureValidator _sigValidator;
    private readonly StateTokenService _state;
    private readonly Auth0OidcClient _auth0;
    private readonly ApimUserClient _apim;
    private readonly Auth0Options _auth0Opts;
    private readonly ApimOptions _apimOpts;
    private readonly ILogger<DelegationFunction> _log;

    public DelegationFunction(
        DelegationSignatureValidator sigValidator,
        StateTokenService state,
        Auth0OidcClient auth0,
        ApimUserClient apim,
        IOptions<Auth0Options> auth0Opts,
        IOptions<ApimOptions> apimOpts,
        ILogger<DelegationFunction> log)
    {
        _sigValidator = sigValidator;
        _state = state;
        _auth0 = auth0;
        _apim = apim;
        _auth0Opts = auth0Opts.Value;
        _apimOpts = apimOpts.Value;
        _log = log;
    }

    [Function("Delegation")]
    public IActionResult Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "delegation")] HttpRequest req)
    {
        var operation = req.Query["operation"].ToString();
        var salt       = req.Query["salt"].ToString();
        var sig        = req.Query["sig"].ToString();
        var returnUrl  = req.Query["returnUrl"].ToString();

        if (string.IsNullOrEmpty(operation) || string.IsNullOrEmpty(salt) || string.IsNullOrEmpty(sig))
        {
            _log.LogWarning("Delegation request missing required parameters.");
            return new BadRequestObjectResult("Missing required query parameters.");
        }

        switch (operation)
        {
            case DelegationOperation.SignIn:
            case DelegationOperation.SignUp:
                return HandleSignInOrSignUp(operation, salt, returnUrl, sig, req);

            case DelegationOperation.SignOut:
                return HandleSignOut(salt, returnUrl, sig);

            case DelegationOperation.Subscribe:
            case DelegationOperation.ProductSubscribe:
            case DelegationOperation.Unsubscribe:
            case DelegationOperation.RenewSubscription:
            case DelegationOperation.ChangeProfile:
            case DelegationOperation.CloseAccount:
                // These flows operate on the *already-signed-in* user and
                // need an APIM REST call rather than an Auth0 roundtrip.
                // Implementing them follows the same pattern as
                // ApimUserClient.MintSsoTokenAsync — left as a TODO so the
                // file size doesn't balloon. Returning 501 makes the gap
                // explicit instead of silently 200-ing.
                return HandleSubscriptionOperation(operation, salt, sig, returnUrl, req);

            default:
                _log.LogWarning("Unsupported delegation operation: {Operation}", operation);
                return new BadRequestObjectResult($"Operation '{operation}' is not supported by this handler.");
        }
    }

    private IActionResult HandleSignInOrSignUp(string operation, string salt, string returnUrl, string sig, HttpRequest req)
    {
        if (!_sigValidator.Verify(salt, returnUrl, sig))
        {
            _log.LogWarning("Rejecting {Op}: HMAC signature did not validate.", operation);
            return new StatusCodeResult(StatusCodes.Status403Forbidden);
        }

        var redirectUri = BuildCallbackUri(req);
        var (stateValue, nonce) = _state.Issue(returnUrl, operation);
        var authorizeUrl = _auth0.BuildAuthorizeUrl(redirectUri, stateValue, nonce);
        _log.LogInformation("{Op}: redirecting to Auth0 /authorize.", operation);
        return new RedirectResult(authorizeUrl.ToString(), permanent: false, preserveMethod: false);
    }

    private IActionResult HandleSignOut(string salt, string returnUrl, string sig)
    {
        if (!_sigValidator.Verify(salt, returnUrl, sig))
        {
            _log.LogWarning("Rejecting SignOut: HMAC signature did not validate.");
            return new StatusCodeResult(StatusCodes.Status403Forbidden);
        }

        // APIM has already destroyed its portal session by the time it
        // redirects us. We just bounce the user through Auth0's
        // /v2/logout so the IdP session goes with it, then back to the
        // portal home page.
        var target = string.IsNullOrEmpty(returnUrl) ? _apimOpts.PortalUrl : returnUrl;
        var logoutUrl = _auth0.BuildLogoutUrl(target);
        return new RedirectResult(logoutUrl.ToString(), permanent: false, preserveMethod: false);
    }

    private IActionResult HandleSubscriptionOperation(string operation, string salt, string sig, string returnUrl, HttpRequest req)
    {
        // The payload signed by APIM for these operations is the productId
        // / subscriptionId / userId rather than returnUrl. Pull whichever
        // is present (only one will be).
        var productId       = req.Query["productId"].ToString();
        var subscriptionId  = req.Query["subscriptionId"].ToString();
        var userId          = req.Query["userId"].ToString();
        var payload = !string.IsNullOrEmpty(productId)       ? productId
                    : !string.IsNullOrEmpty(subscriptionId)  ? subscriptionId
                    : !string.IsNullOrEmpty(userId)          ? userId
                    : string.Empty;

        if (!_sigValidator.Verify(salt, payload, sig))
        {
            _log.LogWarning("Rejecting {Op}: HMAC signature did not validate.", operation);
            return new StatusCodeResult(StatusCodes.Status403Forbidden);
        }

        // Implement per-operation logic against ApimUserClient (extend with
        // subscription endpoints) and redirect back to returnUrl. Kept as a
        // 501 so the gap is loud, not silent.
        _log.LogWarning("Delegation operation '{Op}' signature verified but handler logic is not yet implemented.", operation);
        return new ObjectResult($"Operation '{operation}' is signature-verified but not yet implemented.")
        {
            StatusCode = StatusCodes.Status501NotImplemented,
        };
    }

    /// <summary>
    /// Computes the absolute URL to <see cref="Auth0CallbackFunction"/> for
    /// the current request's scheme + host. Must EXACTLY match the
    /// "Allowed Callback URL" configured in the Auth0 application.
    /// </summary>
    internal static string BuildCallbackUri(HttpRequest req)
        => $"{req.Scheme}://{req.Host}/auth0-callback";
}
