using Azure.ApiManagement.PolicyToolkit.Authoring;

namespace Contoso.Apis.Policies.Fragments;

/// <summary>
/// Reusable building block for policy documents: ensures every inbound
/// request carries a correlation identifier and that the same value is
/// echoed back on the response so clients can stitch their telemetry
/// together with ours.
///
/// <para>
/// ⚠️ <b>Toolkit v1.0.0 limitation.</b> The original template assumed that
/// <c>[Document]</c> classes could compose behaviour by invoking the static
/// <c>Apply*</c> methods below. The v1.0.0 compiler rejects that pattern
/// (error <c>APIM9991: Method 'ApplyXxx' not supported in policy document</c>)
/// and silently drops the call from the emitted XML. To reuse policy logic
/// across documents today you have two options:
/// </para>
/// <list type="number">
///   <item>
///     <b>Inline.</b> Copy the body of the relevant <c>Apply*</c> method into
///     each <c>[Document]</c> that needs it (what <see cref="Documents.PetstoreApiPolicy"/>
///     currently does). Cheap; no shared deployment artefact; OK for small
///     amounts of logic.
///   </item>
///   <item>
///     <b>Real APIM Policy Fragments.</b> Author the snippet as its own
///     <c>[Document]</c>, deploy it as an APIM Policy Fragment resource
///     (Bicep / APIOps), and reference it from documents via
///     <c>context.IncludeFragment("add-correlation-id-header")</c>. This is
///     the gateway-native composition model.
///   </item>
/// </list>
/// <para>
/// The <c>HeaderName</c> constant below is still useful (shared by callers
/// and tests) so this class is intentionally retained as a thin helper.
/// </para>
/// </summary>
public static class AddCorrelationIdHeader
{
    /// <summary>Header name used both inbound and outbound.</summary>
    public const string HeaderName = "x-correlation-id";
}

