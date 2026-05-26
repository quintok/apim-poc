namespace Contoso.Apis.Policies.Tests;

using Contoso.Apis.Policies.Fragments;
using Microsoft.Azure.ApiManagement.PolicyToolkit.Testing;
using Xunit;

/// <summary>
/// Unit tests for <see cref="AddCorrelationIdHeader"/>.
///
/// The toolkit's <c>MockInboundContext</c> / <c>MockOutboundContext</c>
/// simulate the APIM execution context so we can assert on the resulting
/// policy operations without spinning up a gateway. Add new test methods
/// here when you extend the fragment, and create sibling test classes per
/// new fragment under <c>src/Contoso.Apis.Policies/Fragments/</c>.
/// </summary>
public class AddCorrelationIdHeaderTests
{
    [Fact]
    public void ApplyInbound_SetsCorrelationIdHeader()
    {
        // Arrange
        var context = new MockInboundContext();

        // Act
        AddCorrelationIdHeader.ApplyInbound(context);

        // Assert: a set-header operation for our header name was recorded.
        Assert.Contains(
            context.Operations,
            op => op.Name == "set-header"
                  && op.Arguments.TryGetValue("name", out var name)
                  && name?.ToString() == AddCorrelationIdHeader.HeaderName);
    }

    [Fact]
    public void ApplyOutbound_EchoesCorrelationIdHeader()
    {
        // Arrange
        var context = new MockOutboundContext();

        // Act
        AddCorrelationIdHeader.ApplyOutbound(context);

        // Assert
        Assert.Contains(
            context.Operations,
            op => op.Name == "set-header"
                  && op.Arguments.TryGetValue("name", out var name)
                  && name?.ToString() == AddCorrelationIdHeader.HeaderName);
    }
}

