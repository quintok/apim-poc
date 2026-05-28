using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;

using Contoso.Apis.Portal.Delegation.Configuration;

namespace Contoso.Apis.Portal.Delegation.Services;

/// <summary>
/// Verifies the <c>sig</c> query parameter APIM attaches to every delegation
/// request — proving the request really came from APIM and was not tampered
/// with in transit.
///
/// <para><b>Algorithm</b> (per
/// <see href="https://learn.microsoft.com/azure/api-management/api-management-howto-setup-delegation">
/// Microsoft delegation reference</see>):</para>
/// <code>
///   sig = base64( HMAC-SHA512( validationKey , salt + "\n" + payload ) )
/// </code>
/// where <c>payload</c> is:
/// <list type="bullet">
///   <item>For UI ops (SignIn/SignOut/SignUp/ChangeProfile/CloseAccount):
///         the <c>returnUrl</c>.</item>
///   <item>For product subscription ops (Subscribe/ProductSubscribe/
///         Unsubscribe/RenewSubscription): the <c>productId</c> or
///         <c>subscriptionId</c> depending on the operation.</item>
/// </list>
///
/// Comparison is constant-time to defeat signature timing attacks.
/// </summary>
public sealed class DelegationSignatureValidator
{
    private readonly byte[] _key;

    public DelegationSignatureValidator(IOptions<ApimOptions> options)
    {
        ArgumentNullException.ThrowIfNull(options);
        var raw = options.Value.DelegationValidationKey;
        if (string.IsNullOrWhiteSpace(raw))
        {
            throw new InvalidOperationException(
                "Apim:DelegationValidationKey is not configured. The Function App cannot verify APIM signatures without it.");
        }

        _key = TryDecodeBase64(raw, out var decoded)
            ? decoded
            : Encoding.UTF8.GetBytes(raw);
    }

    /// <summary>
    /// Returns <c>true</c> when <paramref name="providedSignature"/> matches
    /// <c>HMAC-SHA512(key, salt + "\n" + payload)</c> base64. Constant-time
    /// comparison.
    /// </summary>
    public bool Verify(string? salt, string? payload, string? providedSignature)
    {
        if (string.IsNullOrEmpty(salt) || payload is null || string.IsNullOrEmpty(providedSignature))
        {
            return false;
        }

        var message = $"{salt}\n{payload}";
        var messageBytes = Encoding.UTF8.GetBytes(message);

        using var hmac = new HMACSHA512(_key);
        var computed = hmac.ComputeHash(messageBytes);

        if (!TryDecodeBase64(providedSignature, out var providedBytes))
        {
            return false;
        }

        return CryptographicOperations.FixedTimeEquals(computed, providedBytes);
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
