using System.Net;
using Xunit;

namespace Contoso.Apis.SmokeTests;

/// <summary>
/// Smoke tests for the Petstore API.
///
/// API owners: add your smoke tests here as <c>[Fact]</c> methods.
/// The base class provides <see cref="SmokeTestBase.Client"/> pre-configured
/// with the gateway URL and subscription key.
///
/// These tests run after deployment to verify the API is operational.
/// Keep them fast and idempotent — they run against every environment.
/// </summary>
public class PetstoreSmokeTests : SmokeTestBase
{
    protected override string ApiId => "petstore";
    protected override string ApiPath => "petstore";

    [Fact]
    public async Task ListPets_Returns200()
    {
        var response = await Client.GetAsync("pets");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task ListPets_ReturnsCorrelationIdHeader()
    {
        var response = await Client.GetAsync("pets");

        response.EnsureSuccessStatusCode();
        AssertHeaderPresent(response, "x-correlation-id");
    }

    [Fact]
    public async Task GetPetById_Returns200()
    {
        var response = await Client.GetAsync("pets/1");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task CreatePet_Succeeds()
    {
        var body = new StringContent(
            """{"name": "Fido", "tag": "dog"}""",
            System.Text.Encoding.UTF8,
            "application/json");

        var response = await Client.PostAsync("pets", body);

        // Echo backend returns 200 for all methods; a real backend would return 201.
        Assert.True(
            response.StatusCode is HttpStatusCode.OK or HttpStatusCode.Created,
            $"Expected 200 or 201, got {(int)response.StatusCode}");
    }
}
