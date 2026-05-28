namespace Contoso.Apis.Policies.Tests;

using Azure.ApiManagement.PolicyToolkit.Authoring;
using Azure.ApiManagement.PolicyToolkit.Testing;
using Azure.ApiManagement.PolicyToolkit.Testing.Document;
using Contoso.Apis.Policies.Documents;
using Xunit;

/// <summary>
/// Unit tests for <see cref="ValidateAuth0JwtPolicy"/>.
///
/// The toolkit emulator runs the policy document end-to-end. We hook the
/// <c>validate-jwt</c> handler via <c>SetupInbound().ValidateJwt()</c> so
/// we can capture the <see cref="ValidateJwtConfig"/> that the document
/// passes to APIM at request time and assert on it — verifying that the
/// fragment will be configured correctly for Auth0 when it reaches the
/// gateway.
/// </summary>
public class ValidateAuth0JwtPolicyTests
{
    [Fact]
    public void Inbound_ConfiguresValidateJwtForAuth0()
    {
        // Arrange
        var test = new TestDocument(new ValidateAuth0JwtPolicy());
        ValidateJwtConfig? captured = null;
        test.SetupInbound().ValidateJwt().WithCallback((_, cfg) => captured = cfg);

        // Act
        test.RunInbound();

        // Assert
        Assert.NotNull(captured);

        // Token plumbing
        Assert.Equal(ValidateAuth0JwtPolicy.TokenHeader, captured!.HeaderName);
        Assert.Equal(ValidateAuth0JwtPolicy.TokenScheme, captured.RequireScheme);

        // Auth0 trust anchors — the source-of-truth strings the gateway
        // will compare incoming tokens against. Drift here = silent
        // accept of the wrong tenant or audience.
        Assert.NotNull(captured.OpenIdConfigs);
        Assert.Single(captured.OpenIdConfigs!);
        Assert.Equal(ValidateAuth0JwtPolicy.OpenIdConfigUrl, captured.OpenIdConfigs![0].Url);

        Assert.NotNull(captured.Issuers);
        Assert.Single(captured.Issuers!);
        Assert.Equal(ValidateAuth0JwtPolicy.ExpectedIssuer, captured.Issuers![0]);

        Assert.NotNull(captured.Audiences);
        Assert.Single(captured.Audiences!);
        Assert.Equal(ValidateAuth0JwtPolicy.ExpectedAudience, captured.Audiences![0]);

        // Failure response
        Assert.Equal(ValidateAuth0JwtPolicy.FailedValidationStatusCode, captured.FailedValidationHttpCode);
        Assert.Equal(ValidateAuth0JwtPolicy.FailedValidationMessage, captured.FailedValidationErrorMessage);

        // Hardening defaults
        Assert.True(captured.RequireSignedTokens);
        Assert.True(captured.RequireExpirationTime);
    }

    [Fact]
    public void Inbound_OpenIdConfigUrlMatchesAuth0Convention()
    {
        // The OpenID configuration URL Auth0 publishes is always:
        //   https://<tenant>/.well-known/openid-configuration
        // Guarding against regressions in URL shape — wrong URL means APIM
        // can't fetch the signing keys and every request 401s.
        Assert.EndsWith("/.well-known/openid-configuration", ValidateAuth0JwtPolicy.OpenIdConfigUrl);
        Assert.StartsWith("https://", ValidateAuth0JwtPolicy.OpenIdConfigUrl);
    }

    [Fact]
    public void Inbound_IssuerHasTrailingSlash()
    {
        // Auth0 tokens contain `iss` with a trailing slash, e.g.
        //   "iss": "https://contoso.auth0.com/"
        // If the validate-jwt issuer is missing the trailing slash, APIM
        // does a strict string compare and rejects every token.
        Assert.EndsWith("/", ValidateAuth0JwtPolicy.ExpectedIssuer);
    }
}
