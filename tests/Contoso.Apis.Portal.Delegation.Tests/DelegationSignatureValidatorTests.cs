namespace Contoso.Apis.Portal.Delegation.Tests;

using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;
using Xunit;

using Contoso.Apis.Portal.Delegation.Configuration;
using Contoso.Apis.Portal.Delegation.Services;

/// <summary>
/// Tests for the HMAC-SHA512 signature verifier used to authenticate the
/// inbound delegation request from APIM. Security-critical — golden vectors
/// + tamper detection + timing-safe comparison.
/// </summary>
public class DelegationSignatureValidatorTests
{
    // 48 random bytes, base64-encoded — the canonical shape of an APIM
    // delegation validation key (output of `openssl rand -base64 48`).
    private const string KeyB64 = "VW5pdC10ZXN0LWtleS1mb3ItYXBpbS1kZWxlZ2F0aW9uLXNpZ25hdHVyZS12ZXJpZmllci0wMQ==";

    [Fact]
    public void Verify_ReturnsTrue_ForGoldenSignature()
    {
        var sut = MakeValidator();
        const string salt = "VGhpcyBpcyBhIGdvbGRlbiBzYWx0";       // base64 random
        const string returnUrl = "https://portal.example/home";
        var sig = ComputeSig(KeyB64, salt, returnUrl);

        Assert.True(sut.Verify(salt, returnUrl, sig));
    }

    [Fact]
    public void Verify_ReturnsFalse_WhenSignatureTampered()
    {
        var sut = MakeValidator();
        const string salt = "U29tZS1zYWx0LXZhbHVlLWZvci10ZXN0";
        const string returnUrl = "https://portal.example/products/p1";
        var sig = ComputeSig(KeyB64, salt, returnUrl);
        // Flip one bit in the signature.
        var tamperedBytes = Convert.FromBase64String(sig);
        tamperedBytes[0] ^= 0x01;
        var tampered = Convert.ToBase64String(tamperedBytes);

        Assert.False(sut.Verify(salt, returnUrl, tampered));
    }

    [Fact]
    public void Verify_ReturnsFalse_WhenReturnUrlTampered()
    {
        var sut = MakeValidator();
        const string salt = "U29tZS1zYWx0LXZhbHVlLWZvci10ZXN0";
        const string returnUrl = "https://portal.example/home";
        var sig = ComputeSig(KeyB64, salt, returnUrl);

        Assert.False(sut.Verify(salt, "https://evil.example/home", sig));
    }

    [Fact]
    public void Verify_ReturnsFalse_WhenSaltTampered()
    {
        var sut = MakeValidator();
        const string salt = "U29tZS1zYWx0LXZhbHVlLWZvci10ZXN0";
        const string returnUrl = "https://portal.example/home";
        var sig = ComputeSig(KeyB64, salt, returnUrl);

        Assert.False(sut.Verify("XXX-different-salt", returnUrl, sig));
    }

    [Theory]
    [InlineData(null, "url", "sig")]
    [InlineData("",   "url", "sig")]
    [InlineData("s",   null, "sig")]
    [InlineData("s",  "url", null)]
    [InlineData("s",  "url", "")]
    public void Verify_ReturnsFalse_ForMissingParts(string? salt, string? url, string? sig)
    {
        var sut = MakeValidator();
        Assert.False(sut.Verify(salt!, url!, sig!));
    }

    [Fact]
    public void Verify_ReturnsFalse_WhenProvidedSignatureIsNotBase64()
    {
        var sut = MakeValidator();
        Assert.False(sut.Verify("salt", "url", "!!! not base64 !!!"));
    }

    [Fact]
    public void Ctor_Throws_WhenKeyIsMissing()
    {
        Assert.Throws<InvalidOperationException>(() => new DelegationSignatureValidator(
            Options.Create(new ApimOptions { DelegationValidationKey = "" })));
    }

    [Fact]
    public void Verify_AcceptsRawUtf8Key_WhenNotValidBase64()
    {
        // Some operators store the validation key as a plain string rather
        // than base64. The validator should still work — falling back to
        // UTF-8 bytes.
        const string rawKey = "this-is-not-base64-but-should-still-work-as-a-utf8-key";
        var sut = new DelegationSignatureValidator(Options.Create(new ApimOptions
        {
            DelegationValidationKey = rawKey,
            ServiceName = "x",
            ResourceId = "/x",
            PortalUrl = "https://x",
        }));
        const string salt = "abc";
        const string url = "https://x/";

        using var hmac = new HMACSHA512(Encoding.UTF8.GetBytes(rawKey));
        var sig = Convert.ToBase64String(hmac.ComputeHash(Encoding.UTF8.GetBytes($"{salt}\n{url}")));

        Assert.True(sut.Verify(salt, url, sig));
    }

    // -------------------------------------------------------------------------

    private static DelegationSignatureValidator MakeValidator() =>
        new(Options.Create(new ApimOptions
        {
            DelegationValidationKey = KeyB64,
            ServiceName = "x",
            ResourceId = "/x",
            PortalUrl = "https://x",
        }));

    private static string ComputeSig(string keyB64, string salt, string payload)
    {
        using var hmac = new HMACSHA512(Convert.FromBase64String(keyB64));
        var msg = Encoding.UTF8.GetBytes($"{salt}\n{payload}");
        return Convert.ToBase64String(hmac.ComputeHash(msg));
    }
}
