using Azure.ApiManagement.PolicyToolkit.Authoring;

namespace Contoso.Apis.Policies.Documents;

/// <summary>
/// Standalone policy document that validates an Auth0-issued JWT presented
/// as a <c>Bearer</c> token in the <c>Authorization</c> header.
///
/// <para><b>Where this XML can be deployed</b></para>
/// <para>
/// The toolkit compiles this class to
/// <c>dist/policies/fragments/validate-auth0-jwt.xml</c>. It is a full
/// <c>&lt;policies&gt;</c> document, so you can deploy it as:
/// </para>
/// <list type="bullet">
///   <item>An API- or operation-scoped policy on any API that should be
///         locked down to Auth0-issued tokens.</item>
///   <item>An APIM <i>Policy Fragment</i> resource — strip the outer
///         <c>&lt;policies&gt;&lt;inbound&gt; … &lt;/inbound&gt;&lt;/policies&gt;</c>
///         wrapper, deploy the inner <c>&lt;validate-jwt&gt;</c> as a
///         <c>Microsoft.ApiManagement/service/policyFragments</c> resource,
///         and reference it from other documents via
///         <c>context.IncludeFragment("validate-auth0-jwt")</c>.</item>
///   <item>A drop-in body copied into an existing document's
///         <c>Inbound</c> section (the toolkit's "static helper" composition
///         pattern is silently dropped — see
///         <see cref="Fragments.AddCorrelationIdHeader"/> for context).</item>
/// </list>
///
/// <para><b>APIM named values this policy depends on</b></para>
/// <list type="bullet">
///   <item><c>auth0-tenant-domain</c> — your Auth0 tenant domain without
///         scheme or trailing slash, e.g. <c>contoso.auth0.com</c> or
///         <c>contoso.eu.auth0.com</c>. Used to build both the issuer URL
///         (Auth0 always issues with a trailing slash) and the OpenID
///         configuration discovery URL.</item>
///   <item><c>auth0-audience</c> — the API Identifier configured in the
///         Auth0 dashboard (Applications → APIs), e.g.
///         <c>https://api.contoso.example</c>.</item>
/// </list>
///
/// <para><b>Toolkit v1.0.0 string-literal constraint</b></para>
/// <para>
/// The compiler (error <c>APIM2005</c>) only accepts string literals as
/// policy argument values — not C# constants or interpolated strings — so
/// the named-value tokens appear inline below. Tests assert on these exact
/// literals to catch accidental drift.
/// </para>
/// </summary>
[Document("fragments/validate-auth0-jwt.xml")]
public class ValidateAuth0JwtPolicy : IDocument
{
    /// <summary>Header that carries the bearer token (single source of truth for tests).</summary>
    public const string TokenHeader = "Authorization";

    /// <summary>Required JWT scheme.</summary>
    public const string TokenScheme = "Bearer";

    /// <summary>Auth0-issued tokens always have a trailing-slash issuer.</summary>
    public const string ExpectedIssuer = "https://{{auth0-tenant-domain}}/";

    /// <summary>OpenID Connect discovery document Auth0 publishes per tenant.</summary>
    public const string OpenIdConfigUrl = "https://{{auth0-tenant-domain}}/.well-known/openid-configuration";

    /// <summary>The Auth0 API Identifier the token must be issued for.</summary>
    public const string ExpectedAudience = "{{auth0-audience}}";

    /// <summary>HTTP status returned when validation fails.</summary>
    public const int FailedValidationStatusCode = 401;

    /// <summary>Body returned to the caller on validation failure.</summary>
    public const string FailedValidationMessage = "Unauthorized. A valid Auth0-issued access token is required.";

    /// <inheritdoc />
    public void Inbound(IInboundContext context)
    {
        context.Base();

        context.ValidateJwt(new ValidateJwtConfig
        {
            HeaderName = "Authorization",
            FailedValidationHttpCode = 401,
            FailedValidationErrorMessage = "Unauthorized. A valid Auth0-issued access token is required.",
            RequireScheme = "Bearer",
            RequireExpirationTime = true,
            RequireSignedTokens = true,
            ClockSkew = 60,
            OpenIdConfigs = new[]
            {
                new OpenIdConfig
                {
                    Url = "https://{{auth0-tenant-domain}}/.well-known/openid-configuration",
                },
            },
            Issuers = new[] { "https://{{auth0-tenant-domain}}/" },
            Audiences = new[] { "{{auth0-audience}}" },
        });
    }

    /// <inheritdoc />
    public void Outbound(IOutboundContext context)
    {
        context.Base();
    }

    /// <inheritdoc />
    public void Backend(IBackendContext context)
    {
        context.Base();
    }

    /// <inheritdoc />
    public void OnError(IOnErrorContext context)
    {
        context.Base();
    }
}
