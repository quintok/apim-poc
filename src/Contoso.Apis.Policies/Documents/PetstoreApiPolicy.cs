using Azure.ApiManagement.PolicyToolkit.Authoring;

namespace Contoso.Apis.Policies.Documents;

using Contoso.Apis.Policies.Fragments;

/// <summary>
/// Full API-level policy document for the example "Petstore" API.
///
/// The toolkit compiler emits one XML file per class decorated with
/// <see cref="DocumentAttribute"/>; the file name is taken from the
/// argument (or the class name when omitted). This document orchestrates
/// the four standard APIM sections (<c>inbound</c>, <c>backend</c>,
/// <c>outbound</c>, <c>on-error</c>) and pulls in reusable behaviour from
/// the <c>Fragments</c> folder via plain method calls — so the same logic
/// can be shared across many APIs without copy-pasting XML.
///
/// Add additional behaviour (rate limiting, JWT validation, caching, …)
/// as new fragment classes and reference them here. Keeping orchestration
/// thin in the document — and logic in the fragments — keeps tests focused.
/// </summary>
[Document("apis/petstore/policy.xml")]
public class PetstoreApiPolicy : IDocument
{
    /// <inheritdoc />
    public void Inbound(IInboundContext context)
    {
        // Run base (product / global) inbound policies first.
        // The global policy (GlobalPolicy.cs) handles correlation-id
        // propagation for all APIs — no need to duplicate it here.
        context.Base();

        // TODO: add validate-jwt, rate-limit-by-key, set-backend-service, etc.
    }

    /// <inheritdoc />
    public void Outbound(IOutboundContext context)
    {
        // Correlation-id echo is handled by the global outbound policy.
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

