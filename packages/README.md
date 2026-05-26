# Local NuGet feed

The Azure API Management Policy Toolkit packages are **not yet published
to nuget.org**. Instead, download the latest release `.nupkg` files from

  https://github.com/Azure/azure-api-management-policy-toolkit/releases

and drop them into this directory. Expected contents (names may vary by
release):

```
packages/
├── Microsoft.Azure.ApiManagement.PolicyToolkit.Authoring.<version>.nupkg
├── Microsoft.Azure.ApiManagement.PolicyToolkit.Testing.<version>.nupkg
└── Azure.ApiManagement.PolicyToolkit.Compiling.<version>.nupkg
```

After copying the files, run `dotnet restore` and `dotnet tool restore`
from the repository root. The `nuget.config` at the repository root wires
this folder up as a local feed.

This directory is intentionally checked in (with this README) so the
local feed exists from a clean clone; the `.nupkg` files themselves are
ignored by `.gitignore`.
