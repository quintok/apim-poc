using Azure.ApiManagement.PolicyToolkit.Authoring;

namespace Contoso.Apis.Policies.Documents;

/// <summary>
/// Global (all-APIs) policy document. Applied to every request that transits
/// the APIM gateway regardless of which API or product is targeted.
///
/// <para>
/// The toolkit compiles this to <c>dist/policies/global-policy.xml</c>.
/// The deploy script pushes it to the service-level policy endpoint
/// (<c>PUT .../policies/policy</c>) rather than under a specific API.
/// </para>
///
/// <para><b>What belongs here vs. an API-level document?</b></para>
/// <list type="bullet">
///   <item><b>Global:</b> correlation-id propagation, CORS, standard error
///         shaping, telemetry headers — anything every API should inherit.</item>
///   <item><b>API-level:</b> validate-jwt (audience differs per API),
///         rate-limit-by-key, backend routing, caching — anything that
///         varies per API or product.</item>
/// </list>
/// </summary>
[Document("global-policy.xml")]
public class GlobalPolicy : IDocument
{
    /// <inheritdoc />
    public void Inbound(IInboundContext context)
    {
        // No context.Base() — this IS the top of the policy hierarchy.

        // Propagate or generate a correlation-id on every inbound request.
        context.SetHeader(
            "x-correlation-id",
            "@(context.Request.Headers.GetValueOrDefault(\"x-correlation-id\", context.RequestId.ToString()))");
    }

    /// <inheritdoc />
    public void Outbound(IOutboundContext context)
    {
        // Echo correlation-id back to the caller on every response.
        context.SetHeader(
            "x-correlation-id",
            "@(context.Request.Headers.GetValueOrDefault(\"x-correlation-id\", context.RequestId.ToString()))");
    }

    /// <inheritdoc />
    public void Backend(IBackendContext context)
    {
    }

    /// <inheritdoc />
    public void OnError(IOnErrorContext context)
    {
    }
}
