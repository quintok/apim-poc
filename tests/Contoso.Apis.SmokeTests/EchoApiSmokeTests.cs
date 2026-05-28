using System.Net;
using Xunit;

namespace Contoso.Apis.SmokeTests;

/// <summary>
/// Smoke tests for the Echo API (demo / infrastructure validation).
/// </summary>
public class EchoApiSmokeTests : SmokeTestBase
{
    protected override string ApiId => "echo-api";
    protected override string ApiPath => "echo";

    [Fact]
    public async Task Hello_Returns200()
    {
        var response = await Client.GetAsync("hello");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task Hello_ReturnsCorrelationIdHeader()
    {
        var response = await Client.GetAsync("hello");

        response.EnsureSuccessStatusCode();
        AssertHeaderPresent(response, "x-correlation-id");
    }
}
