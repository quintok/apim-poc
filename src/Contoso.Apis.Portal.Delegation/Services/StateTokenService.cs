using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Options;

using Contoso.Apis.Portal.Delegation.Configuration;
using Contoso.Apis.Portal.Delegation.Models;

namespace Contoso.Apis.Portal.Delegation.Services;

/// <summary>
/// Serialises a <see cref="StateToken"/> into a stateless, tamper-evident
/// query parameter value for the OIDC <c>state</c> round-trip.
///
/// <para>
/// Format: <c>base64url(json) + "." + base64url(HMAC-SHA256(json))</c>.
/// </para>
/// <para>
/// The HMAC key is derived from the APIM delegation validation key with a
/// domain-separation label so reusing the key here can never produce a
/// signature that's valid in the delegation channel (different message
/// space, different prefix). This keeps the deployed secret count to one.
/// </para>
/// </summary>
public sealed class StateTokenService
{
    private static readonly byte[] DomainSeparator = "auth0-delegation-state-v1"u8.ToArray();
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
    };

    private readonly byte[] _signingKey;
    private readonly TimeSpan _lifetime;

    public StateTokenService(IOptions<ApimOptions> apim, IOptions<StateOptions> state)
    {
        ArgumentNullException.ThrowIfNull(apim);
        ArgumentNullException.ThrowIfNull(state);
        var seed = string.IsNullOrEmpty(apim.Value.DelegationValidationKey)
            ? throw new InvalidOperationException("Apim:DelegationValidationKey is required to derive the state signing key.")
            : apim.Value.DelegationValidationKey;
        var seedBytes = TryDecodeBase64(seed, out var dec) ? dec : Encoding.UTF8.GetBytes(seed);
        _signingKey = HKDF(seedBytes, DomainSeparator, 32);
        _lifetime = TimeSpan.FromSeconds(state.Value.LifetimeSeconds);
    }

    /// <summary>
    /// Issues a state token bound to <paramref name="returnUrl"/> and
    /// <paramref name="operation"/>. The returned <c>nonce</c> must also be
    /// sent to Auth0 in the authorize URL and verified against the ID token.
    /// </summary>
    public (string StateValue, string Nonce) Issue(string returnUrl, string operation)
    {
        var nonce = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
            .TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var token = new StateToken
        {
            ReturnUrl = returnUrl ?? string.Empty,
            Operation = operation ?? string.Empty,
            Nonce = nonce,
            IssuedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
        };

        var json = JsonSerializer.SerializeToUtf8Bytes(token, JsonOpts);
        var sig = HMAC(_signingKey, json);
        return ($"{Base64Url(json)}.{Base64Url(sig)}", nonce);
    }

    /// <summary>
    /// Validates the state value returned by Auth0 in the callback. Returns
    /// the decoded token if (a) the signature matches and (b) it has not
    /// expired. Returns <c>null</c> on any failure — callers MUST treat
    /// null as "reject the request, do not redirect anywhere".
    /// </summary>
    public StateToken? Validate(string? stateValue)
    {
        if (string.IsNullOrEmpty(stateValue))
        {
            return null;
        }

        var parts = stateValue.Split('.', 3);
        if (parts.Length != 2)
        {
            return null;
        }

        if (!TryBase64UrlDecode(parts[0], out var json) || !TryBase64UrlDecode(parts[1], out var providedSig))
        {
            return null;
        }

        var expectedSig = HMAC(_signingKey, json);
        if (!CryptographicOperations.FixedTimeEquals(expectedSig, providedSig))
        {
            return null;
        }

        StateToken? token;
        try
        {
            token = JsonSerializer.Deserialize<StateToken>(json, JsonOpts);
        }
        catch (JsonException)
        {
            return null;
        }

        if (token is null)
        {
            return null;
        }

        var ageSeconds = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - token.IssuedAt;
        if (ageSeconds < 0 || ageSeconds > _lifetime.TotalSeconds)
        {
            return null;
        }

        return token;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private static byte[] HMAC(byte[] key, byte[] message)
    {
        using var h = new HMACSHA256(key);
        return h.ComputeHash(message);
    }

    /// <summary>
    /// Minimal HKDF-Expand replacement: HMAC(seed, label || 0x01). Sufficient
    /// for single-output 32-byte derivation; not a general HKDF.
    /// </summary>
    private static byte[] HKDF(byte[] seed, byte[] label, int outputLength)
    {
        var input = new byte[label.Length + 1];
        Buffer.BlockCopy(label, 0, input, 0, label.Length);
        input[^1] = 0x01;
        using var h = new HMACSHA256(seed);
        var full = h.ComputeHash(input);
        if (outputLength == full.Length)
        {
            return full;
        }
        var trimmed = new byte[outputLength];
        Buffer.BlockCopy(full, 0, trimmed, 0, outputLength);
        return trimmed;
    }

    private static string Base64Url(byte[] bytes)
        => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    private static bool TryBase64UrlDecode(string input, out byte[] bytes)
    {
        try
        {
            var padded = input.Replace('-', '+').Replace('_', '/');
            switch (padded.Length % 4)
            {
                case 2: padded += "=="; break;
                case 3: padded += "="; break;
            }
            bytes = Convert.FromBase64String(padded);
            return true;
        }
        catch (FormatException)
        {
            bytes = Array.Empty<byte>();
            return false;
        }
    }

    private static bool TryDecodeBase64(string input, out byte[] bytes)
    {
        try
        {
            bytes = Convert.FromBase64String(input);
            return true;
        }
        catch (FormatException)
        {
            bytes = Array.Empty<byte>();
            return false;
        }
    }
}
