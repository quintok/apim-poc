namespace Contoso.Apis.Portal.Delegation.Tests;

using Microsoft.Extensions.Options;
using Xunit;

using Contoso.Apis.Portal.Delegation.Configuration;
using Contoso.Apis.Portal.Delegation.Services;

/// <summary>
/// Round-trip + tamper-detection + expiry tests for the OIDC state token
/// service.
/// </summary>
public class StateTokenServiceTests
{
    private const string KeyB64 = "VW5pdC10ZXN0LWtleS1mb3Itc3RhdGUtdG9rZW4tc2VydmljZS10ZXN0cy0wMQ==";

    [Fact]
    public void Issue_ThenValidate_RoundTripsToken()
    {
        var sut = Make(lifetime: 600);
        var (state, nonce) = sut.Issue("https://portal.example/products/p1", Models.DelegationOperation.SignIn);

        var decoded = sut.Validate(state);

        Assert.NotNull(decoded);
        Assert.Equal("https://portal.example/products/p1", decoded!.ReturnUrl);
        Assert.Equal(Models.DelegationOperation.SignIn, decoded.Operation);
        Assert.Equal(nonce, decoded.Nonce);
    }

    [Fact]
    public void Issue_ProducesDistinctNoncesPerCall()
    {
        var sut = Make();
        var (_, n1) = sut.Issue("u", "op");
        var (_, n2) = sut.Issue("u", "op");
        Assert.NotEqual(n1, n2);
    }

    [Fact]
    public void Validate_ReturnsNull_ForTamperedPayload()
    {
        var sut = Make();
        var (state, _) = sut.Issue("https://portal.example/home", "SignIn");

        // Flip the payload portion: decode, change a byte, re-encode.
        var parts = state.Split('.');
        var payload = parts[0].Replace('-', '+').Replace('_', '/');
        switch (payload.Length % 4) { case 2: payload += "=="; break; case 3: payload += "="; break; }
        var bytes = Convert.FromBase64String(payload);
        bytes[0] ^= 0x01;
        var tamperedPayload = Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var tampered = $"{tamperedPayload}.{parts[1]}";

        Assert.Null(sut.Validate(tampered));
    }

    [Fact]
    public void Validate_ReturnsNull_ForTamperedSignature()
    {
        var sut = Make();
        var (state, _) = sut.Issue("https://portal.example/home", "SignIn");
        var parts = state.Split('.');
        // Append a junk byte to the signature.
        var sigBytes = Convert.FromBase64String(parts[1].Replace('-', '+').Replace('_', '/').PadRight(parts[1].Length + (4 - parts[1].Length % 4) % 4, '='));
        sigBytes[^1] ^= 0xFF;
        var tamperedSig = Convert.ToBase64String(sigBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var tampered = $"{parts[0]}.{tamperedSig}";

        Assert.Null(sut.Validate(tampered));
    }

    [Fact]
    public void Validate_ReturnsNull_ForMalformedToken()
    {
        var sut = Make();
        Assert.Null(sut.Validate(null));
        Assert.Null(sut.Validate(""));
        Assert.Null(sut.Validate("not-a-token"));
        Assert.Null(sut.Validate("only.one.dot.too.many"));
    }

    [Fact]
    public void Validate_ReturnsNull_ForExpiredToken()
    {
        var sut = Make(lifetime: 1);
        var (state, _) = sut.Issue("u", "op");
        // Wait past lifetime.
        Thread.Sleep(TimeSpan.FromSeconds(2));
        Assert.Null(sut.Validate(state));
    }

    [Fact]
    public void Validate_RejectsTokens_SignedWithDifferentSeed()
    {
        var a = Make(seedB64: "QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE=");
        var b = Make(seedB64: "QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI=");

        var (stateFromA, _) = a.Issue("u", "op");
        Assert.NotNull(a.Validate(stateFromA));
        Assert.Null(b.Validate(stateFromA));
    }

    // -------------------------------------------------------------------------

    private static StateTokenService Make(int lifetime = 600, string seedB64 = KeyB64) =>
        new(
            Options.Create(new ApimOptions
            {
                DelegationValidationKey = seedB64,
                ServiceName = "x",
                ResourceId = "/x",
                PortalUrl = "https://x",
            }),
            Options.Create(new StateOptions { LifetimeSeconds = lifetime }));
}
