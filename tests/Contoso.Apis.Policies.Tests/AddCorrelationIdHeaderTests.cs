namespace Contoso.Apis.Policies.Tests;

using Azure.ApiManagement.PolicyToolkit.Testing;
using Contoso.Apis.Policies.Documents;
using Contoso.Apis.Policies.Fragments;
using Xunit;

/// <summary>
/// Unit tests for correlation-id header propagation.
///
/// The correlation-id logic now lives in <see cref="GlobalPolicy"/> (the
/// service-level policy applied to all APIs). These tests verify that the
/// global document sets the header, and that <see cref="PetstoreApiPolicy"/>
/// no longer duplicates it.
/// </summary>
public class AddCorrelationIdHeaderTests
{
    [Fact]
    public void GlobalPolicy_Inbound_SetsCorrelationIdHeader()
    {
        var test = new TestDocument(new GlobalPolicy());
        test.RunInbound();

        Assert.True(
            test.Context.Request.Headers.ContainsKey(AddCorrelationIdHeader.HeaderName),
            $"expected request header '{AddCorrelationIdHeader.HeaderName}' to be set by global inbound policy");
    }

    [Fact]
    public void GlobalPolicy_Outbound_EchoesCorrelationIdHeader()
    {
        var test = new TestDocument(new GlobalPolicy());
        test.RunOutbound();

        Assert.True(
            test.Context.Response.Headers.ContainsKey(AddCorrelationIdHeader.HeaderName),
            $"expected response header '{AddCorrelationIdHeader.HeaderName}' to be set by global outbound policy");
    }

    [Fact]
    public void PetstoreApiPolicy_Inbound_DoesNotSetCorrelationIdHeader()
    {
        // PetstoreApiPolicy delegates correlation-id to the global policy via context.Base().
        var test = new TestDocument(new PetstoreApiPolicy());
        test.RunInbound();

        Assert.False(
            test.Context.Request.Headers.ContainsKey(AddCorrelationIdHeader.HeaderName),
            $"PetstoreApiPolicy should NOT set '{AddCorrelationIdHeader.HeaderName}' — global policy owns it");
    }
}

