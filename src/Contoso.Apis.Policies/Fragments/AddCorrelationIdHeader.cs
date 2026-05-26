using Microsoft.Azure.ApiManagement.PolicyToolkit.Authoring;

namespace Contoso.Apis.Policies.Fragments;

/// <summary>
/// Reusable building block for policy documents: ensures every inbound
/// request carries a correlation identifier and that the same value is
/// echoed back on the response so clients can stitch their telemetry
/// together with ours.
///
/// This is NOT a full policy document — it has no <c>[Document]</c>
/// attribute and is therefore not emitted as an XML file by the compiler.
/// Instead, the static helpers below are invoked from inside a real
/// <c>IDocument</c> (see <see cref="Documents.PetstoreApiPolicy"/>) so the
/// same logic can be shared across many APIs without duplication.
///
/// Add new fragments alongside this file (one fragment per file) and
/// expose them via static <c>Apply*</c> methods that take the relevant
/// section context.
/// </summary>
public static class AddCorrelationIdHeader
{
    /// <summary>Header name used both inbound and outbound.</summary>
    public const string HeaderName = "x-correlation-id";

    /// <summary>
    /// Inbound: keep an existing correlation id if the caller supplied
    /// one, otherwise mint one from the gateway request id so downstream
    /// services always see a value.
    /// </summary>
    public static void ApplyInbound(IInboundContext context)
    {
        // The toolkit translates this to:
        //   <set-header name="x-correlation-id" exists-action="skip">
        //     <value>@(context.Request.Headers.GetValueOrDefault("x-correlation-id", context.RequestId))</value>
        //   </set-header>
        context.SetHeader(
            HeaderName,
            $"@(context.Request.Headers.GetValueOrDefault(\"{HeaderName}\", context.RequestId))");
    }

    /// <summary>Outbound: echo the correlation id back to the client.</summary>
    public static void ApplyOutbound(IOutboundContext context)
    {
        context.SetHeader(
            HeaderName,
            $"@(context.Request.Headers.GetValueOrDefault(\"{HeaderName}\", context.RequestId))");
    }
}

