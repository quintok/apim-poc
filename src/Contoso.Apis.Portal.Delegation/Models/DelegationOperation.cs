namespace Contoso.Apis.Portal.Delegation.Models;

/// <summary>
/// Delegation operations APIM sends to the handler URL. The full list is
/// documented at
/// https://learn.microsoft.com/azure/api-management/api-management-howto-setup-delegation
/// </summary>
public static class DelegationOperation
{
    /// <summary>User clicked "Sign in" in the dev portal.</summary>
    public const string SignIn = "SignIn";

    /// <summary>User clicked "Sign up".</summary>
    public const string SignUp = "SignUp";

    /// <summary>User clicked "Sign out".</summary>
    public const string SignOut = "SignOut";

    /// <summary>Subscribe to a product (UI flow with productId in query).</summary>
    public const string Subscribe = "Subscribe";

    /// <summary>Unsubscribe from a product.</summary>
    public const string Unsubscribe = "Unsubscribe";

    /// <summary>Subscribe via product page (slightly different APIM contract from <see cref="Subscribe"/>).</summary>
    public const string ProductSubscribe = "ProductSubscribe";

    /// <summary>Renew a subscription.</summary>
    public const string RenewSubscription = "RenewSubscription";

    /// <summary>User edited their profile.</summary>
    public const string ChangeProfile = "ChangeProfile";

    /// <summary>User closed/deleted their account.</summary>
    public const string CloseAccount = "CloseAccount";
}
