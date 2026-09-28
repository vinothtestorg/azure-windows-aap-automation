# Azure Windows VM + AAP CD PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the PoC described in the HLD: a .NET Framework 4.7.2 MVC app built by GitHub Actions, published to a PoC Nexus, and deployed to an Azure Windows VM by an AAP job template, with managed-identity-based RBAC.

**Architecture:** Bicep provisions one resource group in East US (network, Key Vault, identities, Windows app VM, Ubuntu Nexus VM). GitHub Actions builds on `windows-2022`, and on `main` a reusable CD workflow signs in to Azure through OIDC, uploads to Nexus and launches AAP through the platform gateway REST API. AAP (Red Hat Developer Sandbox, 2.7) runs an `ansible.windows`-only role over PSRP that pulls the artifact on the VM using the VM's managed identity and swaps a `current` junction.

**Tech Stack:** .NET Framework 4.7.2, ASP.NET MVC 5.3 (SDK-style via `MSBuild.SDK.SystemWeb` 4.0.107), MSTest, Bicep 0.47, Azure CLI 2.90, Ubuntu 24.04 + Docker Compose, Nexus CE 3.96.3, Caddy 2, ansible-core 2.21 (local) / AAP 2.7, `ansible.windows`, `ansible.platform` ≥ 2.7.0, `ansible.controller` ≥ 4.8.0, GitHub Actions, bash, PowerShell 5.1 (VM) / pwsh 7.5 (local parse checks).

**Spec:** `docs/HLD.md` (v0.4). Where this plan and the HLD disagree, the HLD wins unless a ruling below says otherwise.

## Global Constraints

Values copied from the HLD. Every task's requirements include this section.

- Subscription `03b6c75f-a3f1-429f-ab89-0f9b07087638`, tenant `e31db877-05a5-4e5a-acfe-c0384e23172a`, region `eastus`, resource group `rg-winapp-poc`.
- Tags: every resource `env=poc`. Only the resource group and `vm-winapp-01` carry `app=demoapp` (the inventory filters on it).
- Names: `vnet-winapp-poc` (10.20.0.0/16), `snet-app` (10.20.1.0/24), `snet-tools` (10.20.2.0/24), `nsg-winapp-app`, `nsg-winapp-tools`, `pip-winapp-vm` (DNS label `winapp-poc`), `pip-nexus` (DNS label `nexus-winapp-poc`), `vm-winapp-01`, `vm-nexus-01`, `id-gh-deployer`, `sp-aap-poc`.
- Key Vault name: `kv-winapp-poc-<first 6 chars of uniqueString(resourceGroup().id)>`, RBAC authorization, soft delete on, purge protection off, `enabledForTemplateDeployment: true`. Scripts read the name from the `main` deployment output `keyVaultName`.
- Key Vault secrets: `vm-admin-password`, `ansible-svc-password`, `nexus-admin-password`, `nexus-deployer-password`, `nexus-reader-password`, `aap-sp-client-id`, `aap-sp-client-secret`, `aap-svc-github-cd-password`.
- Generated passwords: 28 random `[A-Za-z0-9]` characters followed by `Aa1_` (32 chars). No other special characters (they break PowerShell and shell quoting).
- Admin source IP for RDP/SSH NSG rules: `161.142.151.25/32`.
- App VM: Windows Server 2022 Datacenter Azure Edition (`MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest`), `Standard_D2as_v7` (NVMe disk controller), Premium SSD, Trusted Launch, system-assigned MI, admin user `azureadmin`, automation user `ansible_svc`.
- Nexus VM: Ubuntu 24.04 LTS (`Canonical:ubuntu-24_04-lts:server:latest`), `Standard_D2as_v7` (NVMe disk controller), 64 GiB Premium SSD data disk at `/nexus-data`, SSH key auth only, admin user `azureadmin`.
- Nexus: image `sonatype/nexus3:3.96.3`, JVM `-Xms2g -Xmx2g -XX:MaxDirectMemorySize=2g`, URL `https://nexus-winapp-poc.eastus.cloudapp.azure.com`, raw hosted repo `demoapp-releases` with write policy `ALLOW_ONCE`, roles `demoapp-deployer` (add, edit, read, browse) and `demoapp-reader` (read, browse), users `svc-gh-deployer` and `svc-win-reader`, anonymous access disabled.
- Artifact: version `1.0.<GITHUB_RUN_NUMBER>`, package `DemoApp-<version>-<sha7>.zip`, Nexus path `demoapp/<version>/DemoApp-<version>-<sha7>.zip` plus `.sha256`. Zip root = published site root (`Web.config` at the root). Package contains `version.json` = `{"version":"<version>","gitSha":"<sha7>"}`.
- App endpoints: `/health` → HTTP 200 `{"status":"ok"}`; `/version` → HTTP 200 `{"version":"…","gitSha":"…"}`; `/` HTML page showing the version.
- VM layout: `C:\inetpub\demoapp\{current,releases,staging}`, `C:\inetpub\demoapp\deployments.log`, app pool `DemoAppPool` (.NET CLR v4.0, Integrated), site `DemoApp` on port 80 with physical path `C:\inetpub\demoapp\current`, keep 5 releases, health retries 10 × 6 s.
- PSRP: listener HTTPS 5986 only (HTTP listener removed), self-signed cert, NTLM. Connection vars: `ansible_connection=psrp`, `ansible_port=5986`, `ansible_psrp_protocol=https`, `ansible_psrp_auth=ntlm`, `ansible_psrp_cert_validation=ignore`.
- Launch variables and validation: `app_version` `^\d+\.\d+\.\d+$`; `artifact_url` must start with `https://nexus-winapp-poc.eastus.cloudapp.azure.com/repository/demoapp-releases/` and end `.zip`; `artifact_sha256` `^[a-f0-9]{64}$`; `git_sha` `^[0-9a-f]{7,40}$`.
- AAP objects: org `winapp-poc`, team `cd-automation`, user `svc-github-cd`, project `azure-windows-aap-automation` (`https://github.com/vinothtestorg/azure-windows-aap-automation.git`, no SCM credential), credentials `azure-sp-poc`, `azure-kv-poc`, `win-ansible-svc`, inventory `azure-windows-poc`, job templates `winapp-ping` and `winapp-deploy`. Role definitions (verified live): `JobTemplate Execute`, `Inventory Use`, `Team Member`.
- AAP API: gateway only. `TOWER_HOST` = gateway URL, `AWXKIT_API_BASE_PATH` = `/api/controller/`. Local admin token lives only in `.env.aap` (gitignored).
- GitHub: org/repo `vinothtestorg/azure-windows-aap-automation` (public), environment `poc` (deployment branch `main` only), federated subject `repo:vinothtestorg/azure-windows-aap-automation:environment:poc`, issuer `https://token.actions.githubusercontent.com`, audience `api://AzureADTokenExchange`. CI runner `windows-2022`, CD runner `ubuntu-latest`, concurrency group `cd-poc`.
- Role definition IDs: Reader `acdd72a7-3385-48ef-bd42-f606fba81ae7`, Key Vault Secrets User `4633458b-17de-408a-b874-0445c86b69e6`, Key Vault Secrets Officer `b86a8fe4-44ce-4948-aee5-eccb2c155cd7`.
- Never commit or print a secret. The repo is public. Line endings are LF (`.gitattributes`).
- Local tools: `az` 2.90 + Bicep 0.47.16, `pwsh` at `~/.dotnet/tools/pwsh`, `ansible-lint` 26.9, `ansible` 2.21.4 with `pypsrp`, `dotnet` 9 SDK, `gh` (authenticated, repo admin), `jq`.
- Work on branch `poc/implementation`. Push after every task (CI gives feedback on the branch).

## Preflight rulings

- Ruling: Nexus VM is 2 vCPU, not `Standard_B4ms` — the subscription is Azure Free Trial (4 vCPU regional cap), and 2 + 2 vCPU fits — cost if wrong: Nexus runs slowly; resize later.
- Ruling (added during Task 4): both VMs use `Standard_D2as_v7` with `storageProfile.diskControllerType: 'NVMe'` — this Free Trial subscription marks B-series and older D-series `NotAvailableForSubscription`; v7 sizes are unrestricted, and total cores (4) and `StandardDasv7Family` (4) quotas fit exactly. Both images (`2022-datacenter-azure-edition`, `ubuntu-24_04-lts/server`) support NVMe and Trusted Launch — cost if wrong: redeploy with another unrestricted size.
- Ruling: App uses an SDK-style project (`MSBuild.SDK.SystemWeb`) instead of a classic csproj — it compiles on macOS (verified by a spike), so implementers get a local compile loop — cost if wrong: switch to a classic csproj built only in CI.
- Ruling: `HomeController` returns HTML through `ContentResult` (no Razor views) — removes runtime view-compilation risk — cost if wrong: add a view later.
- Ruling: VM configuration uses a managed Run Command resource instead of the Custom Script Extension — it takes the inline script and protected parameters without length or quoting limits — cost if wrong: none functionally.
- Ruling: SP client ID/secret and the `svc-github-cd` password are also stored in Key Vault as the config-as-code source (HLD said the SP secret lives only in AAP) — cost if wrong: one extra copy of a secret in a vault only the deployer can read.
- Ruling: `ansible.cfg` sits at the repo root (HLD layout said `ansible/ansible.cfg`), because AAP runs playbooks from the project root — cost if wrong: none.
- Ruling: PSRP connection variables live in `ansible/playbooks/group_vars/windows_web.yml` (playbook-adjacent, used by both AAP and local runs) — cost if wrong: none.
- Ruling: inventory host name is the VM name, `ansible_host` = first public DNS name (HLD said `hostnames: public_dns_hostnames`) — same connection target, readable host names.
- Ruling: Nexus cleanup policy is dropped (YAGNI for a disposable PoC).
- Ruling: the "manual" first deployment (R3) runs through `az vm run-command` instead of an RDP session, and the runbook documents both — no GUI is available to the implementer.
- Ruling: VM auto-shutdown is daily at 18:00 UTC (02:00 in UTC+8).
- Ruling: `ci.yml` also runs on pushes to `poc/**` so each task gets CI feedback.

## Review Focus

1. **Secrets in logs.** A reasonable person expects no password, token or Nexus credential in CI logs, AAP job output, or script stdout. Tests: Task 3 (seed script prints names only), Task 8 (`no_log` on secret-handling tasks, checked by grepping job output), Task 9 (`::add-mask::`, and a grep of the run log).
2. **Re-running anything.** Every script, deployment and playbook must be safe to run again with no change the second time. Tests: Task 3/4/5 re-run `deploy.sh` (no new secrets, and what-if shows no changes), Task 5 re-run `bootstrap.sh`, Task 7 second `configure.yml` run reports `changed=0`, Task 8 same-version redeploy reports no switch.
3. **First deployment and first failure.** No previous release, `Default Web Site` still bound to port 80, and a health failure on the very first deploy (nothing to roll back to). Tests: Task 8 first-deploy run on a clean path, plus the rescue path when `previous` is empty.
4. **Slow or not-ready dependencies.** Nexus takes minutes to start, Let's Encrypt issuance lags, IMDS or Key Vault role propagation delays, and AAP jobs sit in `pending`/`waiting`. Tests: Task 5 bootstrap waits on `/service/rest/v1/status/writable` with a timeout, Task 8 retries the IMDS/Key Vault call, Task 9 poller treats `pending`/`waiting`/`running` as in-progress and times out at 30 minutes.
5. **Hostile or malformed launch input.** `artifact_url` pointing elsewhere, bad checksum, bad version string. Tests: Task 8 validation asserts, plus live runs for V6 and V7.

---

### Task 1: .NET Framework 4.7.2 MVC application with tests

**Files:**
- Create: `global.json`, `src/DemoApp.sln`, `src/DemoApp/DemoApp.csproj`, `src/DemoApp/Web.config`, `src/DemoApp/Global.asax`, `src/DemoApp/Global.asax.cs`, `src/DemoApp/App_Start/RouteConfig.cs`, `src/DemoApp/Controllers/HomeController.cs`, `src/DemoApp/Controllers/HealthController.cs`, `src/DemoApp/Controllers/VersionController.cs`, `src/DemoApp/Services/VersionInfo.cs`, `src/DemoApp/version.json`
- Create: `src/DemoApp.Tests/DemoApp.Tests.csproj`, `src/DemoApp.Tests/HealthControllerTests.cs`, `src/DemoApp.Tests/VersionInfoTests.cs`, `src/DemoApp.Tests/VersionControllerTests.cs`
- Modify: `.gitignore` (add `bin/`, `obj/`, `out/`, `*.user`, `TestResults/`)

**Interfaces:**
- Produces: `DemoApp.Services.VersionInfo` with `string Version`, `string GitSha`, `static VersionInfo Load(string path)` (returns `0.0.0-dev` / `unknown` when the file is missing or malformed) and `static VersionInfo Current` (loads `~/version.json` once). Task 2 overwrites `version.json` in the publish output. Task 8 compares `/version` → `version` with `app_version`.

- [ ] **Step 1: Pin the SDK version and create the web project**

`global.json` (repo root):
```json
{ "msbuild-sdks": { "MSBuild.SDK.SystemWeb": "4.0.107" } }
```

`src/DemoApp/DemoApp.csproj`:
```xml
<Project Sdk="MSBuild.SDK.SystemWeb">
  <PropertyGroup>
    <TargetFramework>net472</TargetFramework>
    <RootNamespace>DemoApp</RootNamespace>
    <AssemblyName>DemoApp</AssemblyName>
    <GeneratedBindingRedirectsAction>Overwrite</GeneratedBindingRedirectsAction>
    <!-- On machines without Visual Studio (macOS, Linux) use the packaged web targets so the project compiles. -->
    <WebApplicationsTargetPath Condition="!Exists('$(WebApplicationsTargetPath)')">$(NuGetPackageRoot)msbuild.microsoft.visualstudio.web.targets/14.0.0.3/tools/VSToolsPath/WebApplications/Microsoft.WebApplication.targets</WebApplicationsTargetPath>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.AspNet.Mvc" Version="5.3.0" />
    <PackageReference Include="MSBuild.Microsoft.VisualStudio.Web.targets" Version="14.0.0.3" PrivateAssets="all" />
    <PackageReference Include="Microsoft.NETFramework.ReferenceAssemblies" Version="1.0.3" PrivateAssets="all" />
  </ItemGroup>
  <ItemGroup>
    <Reference Include="System.Web.Extensions" />
    <Content Include="version.json" CopyToOutputDirectory="Never" />
  </ItemGroup>
</Project>
```

`src/DemoApp/Web.config`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.web>
    <compilation debug="false" targetFramework="4.7.2" />
    <httpRuntime targetFramework="4.7.2" enableVersionHeader="false" />
    <customErrors mode="RemoteOnly" />
  </system.web>
  <system.webServer>
    <httpProtocol>
      <customHeaders>
        <remove name="X-Powered-By" />
      </customHeaders>
    </httpProtocol>
  </system.webServer>
</configuration>
```

`src/DemoApp/version.json` (development default, replaced by CI in the publish output):
```json
{"version":"0.0.0-dev","gitSha":"local"}
```

`src/DemoApp/Global.asax`:
```
<%@ Application Codebehind="Global.asax.cs" Inherits="DemoApp.MvcApplication" Language="C#" %>
```

`src/DemoApp/Global.asax.cs`:
```csharp
using System.Web.Mvc;
using System.Web.Routing;

namespace DemoApp
{
    public class MvcApplication : System.Web.HttpApplication
    {
        protected void Application_Start()
        {
            MvcHandler.DisableMvcResponseHeader = true;
            RouteConfig.RegisterRoutes(RouteTable.Routes);
        }
    }
}
```

`src/DemoApp/App_Start/RouteConfig.cs`:
```csharp
using System.Web.Mvc;
using System.Web.Routing;

namespace DemoApp
{
    public static class RouteConfig
    {
        public static void RegisterRoutes(RouteCollection routes)
        {
            routes.IgnoreRoute("{resource}.axd/{*pathInfo}");
            routes.MapRoute("Health", "health", new { controller = "Health", action = "Index" });
            routes.MapRoute("Version", "version", new { controller = "Version", action = "Index" });
            routes.MapRoute("Default", "", new { controller = "Home", action = "Index" });
        }
    }
}
```

- [ ] **Step 2: Create the test project and write failing tests**

`src/DemoApp.Tests/DemoApp.Tests.csproj`:
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net472</TargetFramework>
    <IsPackable>false</IsPackable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.11.1" />
    <PackageReference Include="MSTest.TestAdapter" Version="3.6.1" />
    <PackageReference Include="MSTest.TestFramework" Version="3.6.1" />
    <PackageReference Include="Microsoft.NETFramework.ReferenceAssemblies" Version="1.0.3" PrivateAssets="all" />
  </ItemGroup>
  <ItemGroup>
    <Reference Include="System.Web.Extensions" />
    <ProjectReference Include="../DemoApp/DemoApp.csproj" />
  </ItemGroup>
</Project>
```

`src/DemoApp.Tests/VersionInfoTests.cs`:
```csharp
using System.IO;
using DemoApp.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace DemoApp.Tests
{
    [TestClass]
    public class VersionInfoTests
    {
        private string _dir;

        [TestInitialize]
        public void Init() { _dir = Path.Combine(Path.GetTempPath(), Path.GetRandomFileName()); Directory.CreateDirectory(_dir); }

        [TestCleanup]
        public void Cleanup() { Directory.Delete(_dir, true); }

        [TestMethod]
        public void Load_reads_version_and_sha()
        {
            var path = Path.Combine(_dir, "version.json");
            File.WriteAllText(path, "{\"version\":\"1.0.42\",\"gitSha\":\"a1b2c3d\"}");
            var info = VersionInfo.Load(path);
            Assert.AreEqual("1.0.42", info.Version);
            Assert.AreEqual("a1b2c3d", info.GitSha);
        }

        [TestMethod]
        public void Load_falls_back_when_file_missing()
        {
            var info = VersionInfo.Load(Path.Combine(_dir, "missing.json"));
            Assert.AreEqual("0.0.0-dev", info.Version);
            Assert.AreEqual("unknown", info.GitSha);
        }

        [TestMethod]
        public void Load_falls_back_when_file_malformed()
        {
            var path = Path.Combine(_dir, "version.json");
            File.WriteAllText(path, "not json");
            var info = VersionInfo.Load(path);
            Assert.AreEqual("0.0.0-dev", info.Version);
            Assert.AreEqual("unknown", info.GitSha);
        }

        [TestMethod]
        public void Load_falls_back_per_field_when_field_missing()
        {
            var path = Path.Combine(_dir, "version.json");
            File.WriteAllText(path, "{\"version\":\"1.0.7\"}");
            var info = VersionInfo.Load(path);
            Assert.AreEqual("1.0.7", info.Version);
            Assert.AreEqual("unknown", info.GitSha);
        }
    }
}
```

`src/DemoApp.Tests/HealthControllerTests.cs`:
```csharp
using System.Web.Mvc;
using System.Web.Script.Serialization;
using DemoApp.Controllers;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace DemoApp.Tests
{
    [TestClass]
    public class HealthControllerTests
    {
        [TestMethod]
        public void Index_returns_status_ok_json_allowing_get()
        {
            var result = new HealthController().Index() as JsonResult;
            Assert.IsNotNull(result);
            Assert.AreEqual(JsonRequestBehavior.AllowGet, result.JsonRequestBehavior);
            Assert.AreEqual("{\"status\":\"ok\"}", new JavaScriptSerializer().Serialize(result.Data));
        }
    }
}
```

`src/DemoApp.Tests/VersionControllerTests.cs`:
```csharp
using System.Web.Mvc;
using System.Web.Script.Serialization;
using DemoApp.Controllers;
using DemoApp.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace DemoApp.Tests
{
    [TestClass]
    public class VersionControllerTests
    {
        [TestMethod]
        public void Index_returns_injected_version_info()
        {
            var controller = new VersionController(new VersionInfo("1.0.42", "a1b2c3d"));
            var result = controller.Index() as JsonResult;
            Assert.IsNotNull(result);
            Assert.AreEqual(JsonRequestBehavior.AllowGet, result.JsonRequestBehavior);
            Assert.AreEqual("{\"version\":\"1.0.42\",\"gitSha\":\"a1b2c3d\"}", new JavaScriptSerializer().Serialize(result.Data));
        }
    }
}
```

`src/DemoApp.sln`: create with `dotnet new sln -n DemoApp -o src` then `dotnet sln src/DemoApp.sln add src/DemoApp/DemoApp.csproj src/DemoApp.Tests/DemoApp.Tests.csproj`.

- [ ] **Step 3: Compile to verify the tests fail to build**

Run: `dotnet build src/DemoApp.Tests/DemoApp.Tests.csproj -nologo -v q`
Expected: FAIL with `CS0246`/`CS0234` for `HealthController`, `VersionController`, `VersionInfo`.

- [ ] **Step 4: Implement**

`src/DemoApp/Services/VersionInfo.cs`:
```csharp
using System;
using System.Collections.Generic;
using System.IO;
using System.Web.Hosting;
using System.Web.Script.Serialization;

namespace DemoApp.Services
{
    public sealed class VersionInfo
    {
        public const string UnknownVersion = "0.0.0-dev";
        public const string UnknownSha = "unknown";

        private static readonly Lazy<VersionInfo> _current =
            new Lazy<VersionInfo>(() => Load(HostingEnvironment.MapPath("~/version.json")));

        public VersionInfo(string version, string gitSha)
        {
            Version = string.IsNullOrWhiteSpace(version) ? UnknownVersion : version;
            GitSha = string.IsNullOrWhiteSpace(gitSha) ? UnknownSha : gitSha;
        }

        public string Version { get; }
        public string GitSha { get; }

        public static VersionInfo Current => _current.Value;

        public static VersionInfo Load(string path)
        {
            try
            {
                if (string.IsNullOrEmpty(path) || !File.Exists(path))
                    return new VersionInfo(null, null);
                var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(path));
                return new VersionInfo(Read(data, "version"), Read(data, "gitSha"));
            }
            catch (ArgumentException) { return new VersionInfo(null, null); }
            catch (InvalidOperationException) { return new VersionInfo(null, null); }
            catch (IOException) { return new VersionInfo(null, null); }
        }

        private static string Read(Dictionary<string, object> data, string key)
        {
            object value;
            return data != null && data.TryGetValue(key, out value) ? value as string : null;
        }
    }
}
```

`src/DemoApp/Controllers/HealthController.cs`:
```csharp
using System.Web.Mvc;

namespace DemoApp.Controllers
{
    public class HealthController : Controller
    {
        [HttpGet]
        public ActionResult Index()
        {
            return Json(new { status = "ok" }, JsonRequestBehavior.AllowGet);
        }
    }
}
```

`src/DemoApp/Controllers/VersionController.cs`:
```csharp
using System.Web.Mvc;
using DemoApp.Services;

namespace DemoApp.Controllers
{
    public class VersionController : Controller
    {
        private readonly VersionInfo _info;

        public VersionController() : this(VersionInfo.Current) { }

        public VersionController(VersionInfo info) { _info = info; }

        [HttpGet]
        public ActionResult Index()
        {
            return Json(new { version = _info.Version, gitSha = _info.GitSha }, JsonRequestBehavior.AllowGet);
        }
    }
}
```

`src/DemoApp/Controllers/HomeController.cs`:
```csharp
using System.Web;
using System.Web.Mvc;
using DemoApp.Services;

namespace DemoApp.Controllers
{
    public class HomeController : Controller
    {
        [HttpGet]
        public ActionResult Index()
        {
            var info = VersionInfo.Current;
            var html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>DemoApp</title></head>"
                     + "<body><h1>DemoApp</h1><p>Version " + HttpUtility.HtmlEncode(info.Version)
                     + " (" + HttpUtility.HtmlEncode(info.GitSha) + ")</p></body></html>";
            return Content(html, "text/html");
        }
    }
}
```

- [ ] **Step 5: Compile to verify the build passes**

Run: `dotnet build src/DemoApp.sln -nologo -v q`
Expected: `Build succeeded.` with `0 Warning(s)` and `0 Error(s)`. Tests cannot run on macOS (no Mono). They run in CI in Task 2, and the implementer of Task 1 records that in the report.

- [ ] **Step 6: Commit and push**

```bash
git add global.json src .gitignore
git commit -m "feat(app): add ASP.NET MVC 4.7.2 DemoApp with health and version endpoints"
git push -u origin poc/implementation
```

### Task 2: CI workflow (build, test, package)

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `src/DemoApp.sln`, `src/DemoApp/DemoApp.csproj`, `src/DemoApp.Tests/DemoApp.Tests.csproj` (Task 1).
- Produces: workflow `ci.yml` with job `build` exposing outputs `version`, `package_name`, `sha256`, `git_sha`, and an uploaded artifact named `demoapp-package` holding `<package_name>` and `<package_name>.sha256`. Task 9 adds a `cd` job that calls `.github/workflows/cd.yml` with these outputs.

- [ ] **Step 1: Write the workflow**

`.github/workflows/ci.yml`:
```yaml
name: ci

on:
  push:
    branches: [main, 'poc/**']
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  build:
    runs-on: windows-2022
    outputs:
      version: ${{ steps.meta.outputs.version }}
      git_sha: ${{ steps.meta.outputs.git_sha }}
      package_name: ${{ steps.package.outputs.package_name }}
      sha256: ${{ steps.package.outputs.sha256 }}
    steps:
      - uses: actions/checkout@v4

      - name: Compute version
        id: meta
        shell: pwsh
        run: |
          $sha7 = "${{ github.sha }}".Substring(0, 7)
          "version=1.0.${{ github.run_number }}" >> $env:GITHUB_OUTPUT
          "git_sha=$sha7" >> $env:GITHUB_OUTPUT

      - uses: microsoft/setup-msbuild@v2

      - name: Test
        run: dotnet test src/DemoApp.Tests/DemoApp.Tests.csproj -c Release --logger "trx;LogFileName=results.trx" --results-directory TestResults

      - name: Publish web app
        run: msbuild src/DemoApp/DemoApp.csproj /restore /p:Configuration=Release /p:DeployOnBuild=true /p:WebPublishMethod=FileSystem /p:PublishUrl=${{ github.workspace }}\out /p:DeleteExistingFiles=true /v:minimal

      - name: Stamp version and package
        id: package
        shell: pwsh
        run: |
          $version = "${{ steps.meta.outputs.version }}"
          $sha7 = "${{ steps.meta.outputs.git_sha }}"
          $out = Join-Path $env:GITHUB_WORKSPACE 'out'
          foreach ($required in 'Web.config', 'Global.asax', 'bin\DemoApp.dll') {
            if (-not (Test-Path (Join-Path $out $required))) { throw "Publish output is missing $required" }
          }
          @{ version = $version; gitSha = $sha7 } | ConvertTo-Json -Compress | Set-Content -Path (Join-Path $out 'version.json') -Encoding ascii -NoNewline
          $name = "DemoApp-$version-$sha7.zip"
          $dist = Join-Path $env:GITHUB_WORKSPACE 'dist'
          New-Item -ItemType Directory -Force -Path $dist | Out-Null
          Compress-Archive -Path (Join-Path $out '*') -DestinationPath (Join-Path $dist $name)
          $hash = (Get-FileHash -Algorithm SHA256 (Join-Path $dist $name)).Hash.ToLowerInvariant()
          "$hash  $name" | Set-Content -Path (Join-Path $dist "$name.sha256") -Encoding ascii -NoNewline
          "package_name=$name" >> $env:GITHUB_OUTPUT
          "sha256=$hash" >> $env:GITHUB_OUTPUT

      - uses: actions/upload-artifact@v4
        with:
          name: demoapp-package
          path: dist/
          if-no-files-found: error
          retention-days: 30

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: test-results
          path: TestResults/
          if-no-files-found: warn
```

- [ ] **Step 2: Lint locally**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml")' && echo ok` (or `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"` using `./venv/bin/python`)
Expected: `ok` / no exception.

- [ ] **Step 3: Commit, push and watch the run**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: build, test and package DemoApp on windows-2022"
git push
gh run watch --exit-status "$(gh run list --workflow ci.yml --branch poc/implementation --limit 1 --json databaseId --jq '.[0].databaseId')"
```
Expected: run concludes `success`. If `msbuild` publish fails because the SDK's publish targets are not picked up, fix the csproj or publish command until it succeeds. Do not skip the publish step.

- [ ] **Step 4: Verify the artifact contents**

```bash
rm -rf /tmp/demoapp-art && gh run download "$(gh run list --workflow ci.yml --branch poc/implementation --limit 1 --json databaseId --jq '.[0].databaseId')" -n demoapp-package -D /tmp/demoapp-art
ls /tmp/demoapp-art
cd /tmp/demoapp-art && zip=$(ls DemoApp-*.zip) && shasum -a 256 "$zip" && cat "$zip.sha256" && unzip -l "$zip" | grep -E ' (Web.config|Global.asax|version.json|bin/DemoApp.dll)$' && unzip -p "$zip" version.json
```
Expected: the two hashes match; the four files are listed at the zip root; `version.json` is `{"version":"1.0.<n>","gitSha":"<sha7>"}`. The test run shows 6 tests passed (check the `Test` step log).

- [ ] **Step 5: Record the evidence**

Put the run URL, artifact file name, hash and test count in the report file. No extra commit is needed.

### Task 3: Azure foundation (providers, network, Key Vault, identities, secrets, AAP service principal)

**Files:**
- Create: `infra/bicep/main.bicep`, `infra/bicep/main.bicepparam`, `infra/bicep/modules/network.bicep`, `infra/bicep/modules/keyvault.bicep`, `infra/bicep/modules/identity.bicep`, `infra/bicep/modules/secret-reader.bicep`
- Create: `infra/scripts/lib.sh`, `infra/scripts/deploy.sh`, `infra/scripts/seed-secrets.sh`, `infra/scripts/create-aap-sp.sh`

**Interfaces:**
- Produces: `main.bicep` params `location` (default `eastus`), `adminSourceIp` (`161.142.151.25/32`), `deployerObjectId`, `githubOrg` (`vinothtestorg`), `githubRepo` (`azure-windows-aap-automation`), `deployCompute` (bool, default `false`), `nexusSshPublicKey` (string, default `''`). Outputs `keyVaultName`, `keyVaultUri`, `ghDeployerClientId`, `ghDeployerPrincipalId`, `appSubnetId`, `toolsSubnetId`. Tasks 4 and 5 add conditional modules under `deployCompute`.
- Produces: `infra/scripts/lib.sh` functions `kv_name` (echo Key Vault name from the `main` deployment output), `gen_password` (echo a password matching the Global Constraints format), `require_az_login`.
- Produces: `infra/scripts/deploy.sh [--foundation-only]` (idempotent: registers providers, creates the RG, deploys `main.bicep` with `deployCompute=false`, seeds secrets, creates the SP, then deploys again with `deployCompute=true` unless `--foundation-only`).
- Produces: `secret-reader.bicep` params `vaultName`, `secretName`, `principalId`, `principalType` (`ServicePrincipal`). Tasks 4 and 5 reuse it.

- [ ] **Step 1: Write the helper library**

`infra/scripts/lib.sh`:
```bash
#!/usr/bin/env bash
# Shared helpers for PoC infra scripts. Source, do not execute.
set -euo pipefail

readonly SUBSCRIPTION_ID="03b6c75f-a3f1-429f-ab89-0f9b07087638"
readonly RESOURCE_GROUP="rg-winapp-poc"
readonly LOCATION="eastus"
readonly DEPLOYMENT_NAME="main"
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

require_az_login() {
  az account show --query id -o tsv >/dev/null 2>&1 || { log "run 'az login' first"; exit 1; }
  az account set --subscription "$SUBSCRIPTION_ID"
}

kv_name() {
  az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" \
    --query properties.outputs.keyVaultName.value -o tsv
}

# 28 random alphanumerics + fixed "Aa1_" suffix: satisfies Windows complexity,
# contains no characters that need shell or PowerShell quoting.
gen_password() {
  local body
  body="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 28)"
  printf '%sAa1_' "$body"
}
```

- [ ] **Step 2: Write a failing test for `gen_password`**

Create `infra/scripts/tests/test_lib.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../lib.sh
source infra/scripts/lib.sh
fail=0
for _ in $(seq 1 200); do
  pw="$(gen_password)"
  [[ "$pw" =~ ^[A-Za-z0-9]{28}Aa1_$ ]] || { echo "bad password format: length ${#pw}"; fail=1; break; }
done
a="$(gen_password)"; b="$(gen_password)"
[[ "$a" != "$b" ]] || { echo "passwords not random"; fail=1; }
[[ $fail -eq 0 ]] && echo "PASS test_lib" || { echo "FAIL test_lib"; exit 1; }
```
Run it before `lib.sh` exists (or with `gen_password` stubbed to `echo x`): expected `FAIL`. Then with the real `lib.sh`: `bash infra/scripts/tests/test_lib.sh` → `PASS test_lib`. Also run `shellcheck infra/scripts/*.sh infra/scripts/tests/*.sh` if `shellcheck` is installed (`brew install shellcheck` is allowed).

- [ ] **Step 3: Write the Bicep modules**

`infra/bicep/modules/network.bicep` — VNet `vnet-winapp-poc` 10.20.0.0/16 with `snet-app` (10.20.1.0/24, NSG `nsg-winapp-app`) and `snet-tools` (10.20.2.0/24, NSG `nsg-winapp-tools`). NSG rules (priority, name, source, port):
- `nsg-winapp-app`: 100 `allow-http-in` Internet → 80; 110 `allow-psrp-https-in` Internet → 5986 (accepted risk K1); 120 `allow-rdp-admin` `adminSourceIp` → 3389.
- `nsg-winapp-tools`: 100 `allow-https-in` Internet → 443; 110 `allow-http-in` Internet → 80 (ACME + redirect); 120 `allow-ssh-admin` `adminSourceIp` → 22.
Params: `location`, `adminSourceIp`, `tags`. Outputs: `appSubnetId`, `toolsSubnetId`.

`infra/bicep/modules/keyvault.bicep`:
```bicep
param name string
param location string
param tags object
@description('Object ID of the engineer running deployments; gets Key Vault Secrets Officer to seed secrets.')
param deployerObjectId string

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enabledForTemplateDeployment: true
    publicNetworkAccess: 'Enabled'
  }
}

resource deployerOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kv
  name: guid(kv.id, deployerObjectId, 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  properties: {
    principalId: deployerObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  }
}

output name string = kv.name
output uri string = kv.properties.vaultUri
```

`infra/bicep/modules/identity.bicep`:
```bicep
param location string
param tags object
param githubOrg string
param githubRepo string

resource ghDeployer 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-gh-deployer'
  location: location
  tags: tags
}

resource ghFederation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: ghDeployer
  name: 'github-${githubRepo}-poc'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    subject: 'repo:${githubOrg}/${githubRepo}:environment:poc'
    audiences: [ 'api://AzureADTokenExchange' ]
  }
}

output clientId string = ghDeployer.properties.clientId
output principalId string = ghDeployer.properties.principalId
```

`infra/bicep/modules/secret-reader.bicep`:
```bicep
@description('Grants Key Vault Secrets User on ONE secret.')
param vaultName string
param secretName string
param principalId string
@allowed([ 'ServicePrincipal', 'User', 'Group' ])
param principalType string = 'ServicePrincipal'

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = { name: vaultName }
resource secret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = { parent: kv, name: secretName }

resource assignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: secret
  name: guid(secret.id, principalId, '4633458b-17de-408a-b874-0445c86b69e6')
  properties: {
    principalId: principalId
    principalType: principalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}
```

`infra/bicep/main.bicep` (resource group scope): variables `kvName = 'kv-winapp-poc-${take(uniqueString(resourceGroup().id), 6)}'`, `commonTags = { env: 'poc' }`. Calls `network`, `keyvault`, `identity` unconditionally. Calls `secret-reader` for `id-gh-deployer` → `nexus-deployer-password` **only when `deployCompute` is true** (the secret exists by then; the foundation pass runs before seeding). Leaves a marked section `// Compute (Tasks 4 and 5)` for later modules. Outputs as listed in Interfaces.

`infra/bicep/main.bicepparam`:
```bicep
using './main.bicep'

param location = 'eastus'
param adminSourceIp = '161.142.151.25/32'
param githubOrg = 'vinothtestorg'
param githubRepo = 'azure-windows-aap-automation'
param deployerObjectId = readEnvironmentVariable('DEPLOYER_OBJECT_ID')
param deployCompute = bool(readEnvironmentVariable('DEPLOY_COMPUTE', 'false'))
param nexusSshPublicKey = readEnvironmentVariable('NEXUS_SSH_PUBLIC_KEY', '')
```

- [ ] **Step 4: Validate the Bicep**

Run: `az bicep build --file infra/bicep/main.bicep --stdout >/dev/null && az bicep lint --file infra/bicep/main.bicep`
Expected: no errors. Warnings about `secure` outputs or unused params must be fixed or justified in the report.

- [ ] **Step 5: Write `seed-secrets.sh` and `create-aap-sp.sh`**

`infra/scripts/seed-secrets.sh`: sources `lib.sh`. For each of `vm-admin-password ansible-svc-password nexus-admin-password nexus-deployer-password nexus-reader-password aap-svc-github-cd-password`, if `az keyvault secret show --vault-name "$kv" --name "$s"` fails, set it with `gen_password` passed through stdin-free form `--value "$(gen_password)"` and `--output none`. It prints only `created <name>` or `exists <name>`. Retry `az keyvault secret set` up to 10 times with 15 s sleep to ride out RBAC propagation for the freshly assigned Secrets Officer role.

`infra/scripts/create-aap-sp.sh`: sources `lib.sh`. Idempotent:
1. `appId=$(az ad sp list --display-name sp-aap-poc --query "[0].appId" -o tsv)`. If empty: `az ad sp create-for-rbac --name sp-aap-poc --role Reader --scopes "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP" --output json` and capture `appId`, `password`, `tenant` without printing them.
2. If the SP already existed and Key Vault secret `aap-sp-client-secret` is missing, or `--rotate` was passed: `az ad app credential reset --id "$appId" --end-date "<today+45d as YYYY-MM-DD>" --query password -o tsv` (compute the date with `python3 -c 'import datetime;print((datetime.date.today()+datetime.timedelta(days=45)).isoformat())'`). When newly created, also reset once with the 45-day end date so the expiry is exactly 45 days.
3. Store `aap-sp-client-id` (appId) and `aap-sp-client-secret` in Key Vault (`--output none`).
4. Ensure role assignments with `az role assignment create --only-show-errors --output none` (idempotent): Reader on the RG, and Key Vault Secrets User scoped to the secret `ansible-svc-password` (`--scope "$(az keyvault secret show --vault-name "$kv" -n ansible-svc-password --query id -o tsv | sed 's#/[^/]*$##')"`: the secret resource ID without version, i.e. `.../vaults/<kv>/secrets/ansible-svc-password`; get it with `az keyvault show -n "$kv" --query id -o tsv` + `/secrets/ansible-svc-password`).
5. Print `sp-aap-poc appId=<appId>` only (appId is not a secret).

- [ ] **Step 6: Write `deploy.sh`**

`infra/scripts/deploy.sh`:
```bash
#!/usr/bin/env bash
# Idempotent PoC infrastructure deployment. Usage: deploy.sh [--foundation-only]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

foundation_only=false
[[ "${1:-}" == "--foundation-only" ]] && foundation_only=true

require_az_login

for p in Microsoft.Compute Microsoft.Network Microsoft.KeyVault Microsoft.ManagedIdentity Microsoft.DevTestLab; do
  state="$(az provider show -n "$p" --query registrationState -o tsv)"
  if [[ "$state" != "Registered" ]]; then
    log "registering $p"
    az provider register -n "$p" --wait --output none
  fi
done

az group create -n "$RESOURCE_GROUP" -l "$LOCATION" --tags app=demoapp env=poc --output none

export DEPLOYER_OBJECT_ID
DEPLOYER_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv)"

deploy() {
  DEPLOY_COMPUTE="$1" az deployment group create -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" \
    --template-file "$REPO_ROOT/infra/bicep/main.bicep" \
    --parameters "$REPO_ROOT/infra/bicep/main.bicepparam" --output none
}

log "foundation deployment"
deploy false
"$REPO_ROOT/infra/scripts/seed-secrets.sh"
"$REPO_ROOT/infra/scripts/create-aap-sp.sh"

if [[ "$foundation_only" == false ]]; then
  log "compute deployment"
  deploy true
fi
log "done: key vault $(kv_name)"
```
(Task 5 adds the Nexus SSH key export before `deploy true`.)

- [ ] **Step 7: Deploy the foundation**

Run: `bash infra/scripts/deploy.sh --foundation-only`
Expected: providers registered, RG created, deployment succeeds, output lists `created <name>` for 6 secrets and `sp-aap-poc appId=…`.

- [ ] **Step 8: Verify, then prove idempotency**

```bash
source infra/scripts/lib.sh
kv=$(kv_name); echo "$kv"
az keyvault secret list --vault-name "$kv" --query "[].name" -o tsv | sort
az identity federated-credential list -g rg-winapp-poc --identity-name id-gh-deployer --query "[].subject" -o tsv
az role assignment list --all --assignee "$(az ad sp list --display-name sp-aap-poc --query '[0].id' -o tsv)" --query "[].{role:roleDefinitionName,scope:scope}" -o tsv
az vm list-usage -l eastus --query "[?name.value=='cores' || name.value=='standardBSFamily'].{n:name.value,cur:currentValue,lim:limit}" -o tsv
bash infra/scripts/deploy.sh --foundation-only   # second run
```
Expected: 8 secrets (6 seeded + `aap-sp-client-id` + `aap-sp-client-secret`); subject `repo:vinothtestorg/azure-windows-aap-automation:environment:poc`; SP has Reader on the RG and Key Vault Secrets User on `.../secrets/ansible-svc-password`; the regional vCPU limit is ≥ 4 (record the exact values; if it is below 4, report BLOCKED). The second run prints `exists <name>` for every secret and creates nothing new. `az deployment group what-if` with the same parameters reports no changes except `Ignore`/`NoChange`.

- [ ] **Step 9: Commit and push**

```bash
git add infra
git commit -m "feat(infra): foundation Bicep, secret seeding and AAP service principal"
git push
```

### Task 4: Windows app VM with PSRP listener

**Files:**
- Create: `infra/bicep/modules/vm-windows.bicep`, `infra/bicep/scripts/configure-remoting.ps1`
- Modify: `infra/bicep/main.bicep` (add the conditional module, the VM MI secret-reader assignment, and outputs `appVmFqdn`, `appVmPrincipalId`)
- Create: `ansible/inventories/poc/hosts.yml`, `ansible/playbooks/group_vars/windows_web.yml`, `ansible/playbooks/ping.yml`, `ansible.cfg`

**Interfaces:**
- Consumes: Task 3 `main.bicep`, `secret-reader.bicep`, `lib.sh`, Key Vault secrets `vm-admin-password`, `ansible-svc-password`.
- Produces: VM `vm-winapp-01` reachable at `winapp-poc.eastus.cloudapp.azure.com` (PSRP 5986, HTTP 80). Output `appVmFqdn`. Group vars file and `ping.yml` used by Tasks 7 and 8. Root `ansible.cfg` used by every later Ansible task.

- [ ] **Step 1: Write the remoting script**

`infra/bicep/scripts/configure-remoting.ps1`:
```powershell
<#
  Runs once through a managed Run Command on vm-winapp-01.
  Installs IIS + ASP.NET 4.x, creates the automation account, and exposes
  PowerShell remoting over HTTPS 5986 only.
#>
param(
    [Parameter(Mandatory)] [string] $AnsibleUser,
    [Parameter(Mandatory)] [string] $AnsiblePassword,
    [Parameter(Mandatory)] [string] $CertDnsName
)
$ErrorActionPreference = 'Stop'

# IIS and ASP.NET 4.x
Install-WindowsFeature -Name Web-Server, Web-Asp-Net45, NET-Framework-45-ASPNET, Web-Mgmt-Console | Out-Null

# Automation account (local admin; required for IIS management)
$secure = ConvertTo-SecureString $AnsiblePassword -AsPlainText -Force
if (Get-LocalUser -Name $AnsibleUser -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $AnsibleUser -Password $secure -PasswordNeverExpires $true
} else {
    New-LocalUser -Name $AnsibleUser -Password $secure -PasswordNeverExpires -AccountNeverExpires -Description 'Ansible automation (PoC)' | Out-Null
}
if (-not (Get-LocalGroupMember -Group 'Administrators' -Member $AnsibleUser -ErrorAction SilentlyContinue)) {
    Add-LocalGroupMember -Group 'Administrators' -Member $AnsibleUser
}
# Local admin accounts need a full token over remoting
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null

# Lockout high enough that password spraying cannot lock out the pipeline (HLD section 9)
net accounts /lockoutthreshold:20 /lockoutwindow:15 /lockoutduration:15 | Out-Null

# HTTPS listener on 5986 with a self-signed certificate; HTTP listener removed
Enable-PSRemoting -SkipNetworkProfileCheck -Force | Out-Null
$cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -eq "CN=$CertDnsName" -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
    Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -DnsName $CertDnsName, $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(1)
}
Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' } | Remove-Item -Recurse -Force
New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null
Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTP' } | Remove-Item -Recurse -Force
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $false
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $false

if (-not (Get-NetFirewallRule -Name 'PSRP-HTTPS-In' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'PSRP-HTTPS-In' -DisplayName 'PowerShell remoting HTTPS (5986)' -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow | Out-Null
}
Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue | Disable-NetFirewallRule

Write-Output "remoting configured: https listener thumbprint $($cert.Thumbprint)"
```

Parse check: `~/.dotnet/tools/pwsh -NoProfile -c '$e=$null; [System.Management.Automation.Language.Parser]::ParseFile("infra/bicep/scripts/configure-remoting.ps1",[ref]$null,[ref]$e) | Out-Null; if ($e) { $e; exit 1 } else { "parse ok" }'` → `parse ok`.

- [ ] **Step 2: Write `vm-windows.bicep`**

Params: `location`, `tags` (must include `app: 'demoapp'`), `subnetId`, `adminUsername` (`azureadmin`), `@secure() adminPassword`, `@secure() ansiblePassword`, `vmSize` (`Standard_D2as_v7`), `dnsLabel` (`winapp-poc`), `shutdownTimeUtc` (`1800`).
Resources:
- `pip-winapp-vm`: Standard SKU, Static, `dnsSettings.domainNameLabel: dnsLabel`.
- NIC `nic-vm-winapp-01` in `subnetId` with the public IP.
- VM `vm-winapp-01`: `identity: { type: 'SystemAssigned' }`, image `MicrosoftWindowsServer/WindowsServer/2022-datacenter-azure-edition/latest`, `securityProfile: { securityType: 'TrustedLaunch', uefiSettings: { secureBootEnabled: true, vTpmEnabled: true } }`, OS disk `Premium_LRS`, `osProfile.windowsConfiguration.patchSettings: { patchMode: 'AutomaticByPlatform', assessmentMode: 'AutomaticByPlatform' }`, `provisionVMAgent: true`, boot diagnostics enabled (managed storage).
- Run Command `Microsoft.Compute/virtualMachines/runCommands@2024-07-01` child `configure-remoting`:
```bicep
resource configure 'Microsoft.Compute/virtualMachines/runCommands@2024-07-01' = {
  parent: vm
  name: 'configure-remoting'
  location: location
  properties: {
    source: { script: loadTextContent('../scripts/configure-remoting.ps1') }
    parameters: [
      { name: 'AnsibleUser', value: 'ansible_svc' }
      { name: 'CertDnsName', value: pip.properties.dnsSettings.fqdn }
    ]
    protectedParameters: [
      { name: 'AnsiblePassword', value: ansiblePassword }
    ]
    asyncExecution: false
    timeoutInSeconds: 1800
    treatFailureAsDeploymentFailure: true
  }
}
```
- Auto-shutdown `Microsoft.DevTestLab/schedules@2018-09-15` named `shutdown-computevm-vm-winapp-01`: `status: 'Enabled'`, `taskType: 'ComputeVmShutdownTask'`, `dailyRecurrence: { time: shutdownTimeUtc }`, `timeZoneId: 'UTC'`, `targetResourceId: vm.id`, `notificationSettings: { status: 'Disabled' }`.
Outputs: `fqdn`, `principalId`.

In `main.bicep` (compute section): `resource kvRef 'Microsoft.KeyVault/vaults@2023-07-01' existing = { name: kvName }`, then `module appVm 'modules/vm-windows.bicep' = if (deployCompute) { … adminPassword: kvRef.getSecret('vm-admin-password'), ansiblePassword: kvRef.getSecret('ansible-svc-password'), tags: union(commonTags, { app: 'demoapp' }) }`, plus `module appVmSecret 'modules/secret-reader.bicep' = if (deployCompute)` granting `appVm.outputs.principalId` Secrets User on `nexus-reader-password`. Outputs `appVmFqdn` and `appVmPrincipalId` use `deployCompute ? appVm.outputs.fqdn : ''` (and the same for `principalId`).

- [ ] **Step 3: Validate and deploy**

```bash
az bicep build --file infra/bicep/main.bicep --stdout >/dev/null && az bicep lint --file infra/bicep/main.bicep
bash infra/scripts/deploy.sh
```
Expected: the deployment succeeds; the Run Command output contains `remoting configured`. (Nexus is added in Task 5, and `deploy.sh` stays idempotent.)

- [ ] **Step 4: Write the Ansible connection files**

`ansible.cfg` (repo root):
```ini
[defaults]
roles_path = ansible/roles
inventory = ansible/inventories/poc/hosts.yml
host_key_checking = False
stdout_callback = default
result_format = yaml
interpreter_python = auto_silent

[galaxy]
server_list = automation_hub, release_galaxy

[galaxy_server.automation_hub]
url = https://console.redhat.com/api/automation-hub/content/published/
auth_url = https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token
# token comes from ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN (in .env.aap, never committed)

[galaxy_server.release_galaxy]
url = https://galaxy.ansible.com/
```

`ansible/playbooks/group_vars/windows_web.yml`:
```yaml
---
ansible_connection: psrp
ansible_port: 5986
ansible_psrp_protocol: https
ansible_psrp_auth: ntlm
ansible_psrp_cert_validation: ignore   # PoC only: self-signed listener certificate (HLD risk K2)
```

`ansible/inventories/poc/hosts.yml` (static fallback and local runs):
```yaml
---
windows_web:
  hosts:
    vm-winapp-01:
      ansible_host: winapp-poc.eastus.cloudapp.azure.com
      ansible_user: ansible_svc
      ansible_password: "{{ lookup('ansible.builtin.env', 'ANSIBLE_SVC_PASSWORD') }}"
```

`ansible/playbooks/ping.yml`:
```yaml
---
- name: Check connectivity to Windows web hosts
  hosts: windows_web
  gather_facts: false
  tasks:
    - name: Ping over PSRP
      ansible.windows.win_ping:
```

- [ ] **Step 5: Verify end to end from the workstation**

```bash
source infra/scripts/lib.sh; kv=$(kv_name)
nc -vz -G 10 winapp-poc.eastus.cloudapp.azure.com 5986          # expect succeeded
curl -s -o /dev/null -w '%{http_code}\n' http://winapp-poc.eastus.cloudapp.azure.com/   # expect 200 (IIS default page)
export ANSIBLE_SVC_PASSWORD="$(az keyvault secret show --vault-name "$kv" -n ansible-svc-password --query value -o tsv)"
ansible-playbook ansible/playbooks/ping.yml
unset ANSIBLE_SVC_PASSWORD
ansible-lint ansible/playbooks/ping.yml
```
Expected: port open, HTTP 200, the ping play reports `ok=1`, and `ansible-lint` passes.

Verify that the VM managed identity can read only its own secret:
```bash
cat > /tmp/mi-check.ps1 <<'EOF'
param([string]$Vault)
$t = (Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net').access_token
foreach ($s in 'nexus-reader-password','nexus-deployer-password') {
  try { $v = Invoke-RestMethod -Headers @{Authorization="Bearer $t"} -Uri "https://$Vault.vault.azure.net/secrets/${s}?api-version=7.4"; "$s readable length=$($v.value.Length)" }
  catch { "$s denied $($_.Exception.Response.StatusCode.value__)" }
}
EOF
az vm run-command invoke -g rg-winapp-poc -n vm-winapp-01 --command-id RunPowerShellScript --scripts @/tmp/mi-check.ps1 --parameters "Vault=$kv" --query "value[0].message" -o tsv
```
Expected: `nexus-reader-password readable length=32` and `nexus-deployer-password denied 403`. (If the role has not propagated yet, wait 2 minutes and retry.)

- [ ] **Step 6: Commit and push**

```bash
git add infra ansible ansible.cfg
git commit -m "feat(infra): Windows app VM with PSRP over HTTPS and local ping playbook"
git push
```

### Task 5: PoC Nexus Repository on Ubuntu

**Files:**
- Create: `infra/bicep/modules/vm-nexus.bicep`, `infra/nexus/cloud-init.yaml`, `infra/nexus/docker-compose.yml`, `infra/nexus/Caddyfile`, `infra/nexus/bootstrap.sh`, `infra/nexus/tests/smoke.sh`
- Modify: `infra/bicep/main.bicep` (conditional Nexus module, `id-gh-deployer` secret-reader on `nexus-deployer-password` already there from Task 3, output `nexusFqdn`), `infra/scripts/deploy.sh` (SSH key generation and export)

**Interfaces:**
- Consumes: Task 3 network/Key Vault/secrets, `lib.sh`.
- Produces: `https://nexus-winapp-poc.eastus.cloudapp.azure.com` with repo `demoapp-releases`, users `svc-gh-deployer`/`svc-win-reader` whose passwords equal the Key Vault secrets `nexus-deployer-password`/`nexus-reader-password`. `infra/nexus/tests/smoke.sh` is reused by Task 10.

- [ ] **Step 1: Write the Compose stack and Caddyfile**

`infra/nexus/docker-compose.yml`:
```yaml
services:
  nexus:
    image: sonatype/nexus3:3.96.3
    restart: unless-stopped
    environment:
      INSTALL4J_ADD_VM_PARAMS: "-Xms2g -Xmx2g -XX:MaxDirectMemorySize=2g -Djava.util.prefs.userRoot=/nexus-data/javaprefs"
    volumes:
      - /nexus-data:/nexus-data
    expose:
      - "8081"
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - nexus
volumes:
  caddy_data: {}
  caddy_config: {}
```

`infra/nexus/Caddyfile`:
```
nexus-winapp-poc.eastus.cloudapp.azure.com {
	reverse_proxy nexus:8081
}
```

- [ ] **Step 2: Write cloud-init**

`infra/nexus/cloud-init.yaml` (Bicep injects the two files with `loadTextContent` + `replace` for the placeholders `__COMPOSE__` and `__CADDYFILE__`, indented by 6 spaces, then passes the result through `base64()` as `customData`):
```yaml
#cloud-config
package_update: true
packages:
  - docker.io
  - docker-compose-v2
write_files:
  - path: /opt/nexus/docker-compose.yml
    permissions: '0644'
    content: |
      __COMPOSE__
  - path: /opt/nexus/Caddyfile
    permissions: '0644'
    content: |
      __CADDYFILE__
  - path: /opt/nexus/mount-data.sh
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      for dev in /dev/disk/azure/data/by-lun/0 /dev/disk/azure/scsi1/lun0; do
        [ -e "$dev" ] && disk="$(readlink -f "$dev")" && break
      done
      : "${disk:?data disk for LUN 0 not found}"
      if ! blkid "$disk" >/dev/null 2>&1; then mkfs.ext4 -L nexusdata "$disk"; fi
      mkdir -p /nexus-data
      uuid="$(blkid -s UUID -o value "$disk")"
      grep -q "$uuid" /etc/fstab || echo "UUID=$uuid /nexus-data ext4 defaults,nofail 0 2" >> /etc/fstab
      mount -a
      chown -R 200:200 /nexus-data
runcmd:
  - /opt/nexus/mount-data.sh
  - systemctl enable --now docker
  - cd /opt/nexus && docker compose up -d
```

- [ ] **Step 3: Write `vm-nexus.bicep` and wire it in**

Params: `location`, `tags` (no `app` tag), `subnetId`, `adminUsername` (`azureadmin`), `sshPublicKey`, `vmSize` (`Standard_D2as_v7`), `dnsLabel` (`nexus-winapp-poc`). Resources: `pip-nexus` (Standard, Static, DNS label), NIC `nic-vm-nexus-01`, VM `vm-nexus-01` with image `Canonical/ubuntu-24_04-lts/server/latest`, `linuxConfiguration: { disablePasswordAuthentication: true, ssh: { publicKeys: [ { path: '/home/azureadmin/.ssh/authorized_keys', keyData: sshPublicKey } ] } }`, Trusted Launch, OS disk `Premium_LRS`, data disk LUN 0 `createOption: 'Empty'`, `diskSizeGB: 64`, `Premium_LRS`, and `customData` built from cloud-init as described in Step 2. Output `fqdn`.

`deploy.sh` additions before `deploy true`:
```bash
key="$HOME/.ssh/winapp_poc_nexus"
[[ -f "$key" ]] || ssh-keygen -t ed25519 -N '' -C 'winapp-poc-nexus' -f "$key" >/dev/null
export NEXUS_SSH_PUBLIC_KEY; NEXUS_SSH_PUBLIC_KEY="$(cat "$key.pub")"
```
Main: `module nexusVm 'modules/vm-nexus.bicep' = if (deployCompute)` with `sshPublicKey: nexusSshPublicKey`, and an `@sys.description` noting the SSH key lives only on the admin workstation. Output `nexusFqdn`.

Validate: `az bicep build --file infra/bicep/main.bicep --stdout >/dev/null && az bicep lint --file infra/bicep/main.bicep`. Then `bash infra/scripts/deploy.sh`.

- [ ] **Step 4: Write the smoke test first (it must fail before bootstrap)**

`infra/nexus/tests/smoke.sh`:
```bash
#!/usr/bin/env bash
# Verifies Nexus access rules. Exit 0 only when every check passes.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/infra/scripts/lib.sh"
url="https://nexus-winapp-poc.eastus.cloudapp.azure.com"
repo="$url/repository/demoapp-releases"
kv="$(kv_name)"
dep_pw="$(az keyvault secret show --vault-name "$kv" -n nexus-deployer-password --query value -o tsv)"
rd_pw="$(az keyvault secret show --vault-name "$kv" -n nexus-reader-password --query value -o tsv)"
probe="smoke/$(date -u +%Y%m%d%H%M%S)-$RANDOM.txt"
tmp="$(mktemp)"; echo "smoke" > "$tmp"
fails=0
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then echo "PASS $1 ($3)"; else echo "FAIL $1 expected $2 got $3"; fails=$((fails+1)); fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check "status writable"        200 "$(code "$url/service/rest/v1/status/writable")"
check "anonymous read denied"  401 "$(code "$repo/$probe")"
check "reader upload denied"   403 "$(code -u "svc-win-reader:$rd_pw" --upload-file "$tmp" "$repo/$probe")"
check "deployer upload"        201 "$(code -u "svc-gh-deployer:$dep_pw" --upload-file "$tmp" "$repo/$probe")"
check "redeploy rejected"      400 "$(code -u "svc-gh-deployer:$dep_pw" --upload-file "$tmp" "$repo/$probe")"
check "reader download"        200 "$(code -u "svc-win-reader:$rd_pw" "$repo/$probe")"
rm -f "$tmp"
[[ $fails -eq 0 ]] && echo "SMOKE PASS" || { echo "SMOKE FAIL ($fails)"; exit 1; }
```
Run it now: expected `SMOKE FAIL` (repo and users do not exist yet; anonymous access still on).

- [ ] **Step 5: Write `bootstrap.sh`**

`infra/nexus/bootstrap.sh` (idempotent; never prints a password):
1. Source `lib.sh`; `url=https://nexus-winapp-poc.eastus.cloudapp.azure.com`; read the three Nexus secrets from Key Vault into variables.
2. Wait for `GET $url/service/rest/v1/status/writable` → 200, polling every 15 s for up to 20 minutes (Caddy certificate issuance plus Nexus start). Exit 1 with a clear message on timeout.
3. Initial password: `init="$(az vm run-command invoke -g rg-winapp-poc -n vm-nexus-01 --command-id RunShellScript --scripts 'cat /nexus-data/admin.password 2>/dev/null || true' --query 'value[0].message' -o tsv | sed -n '/\[stdout\]/,/\[stderr\]/p' | sed '1d;$d' | tr -d '[:space:]')"`. If non-empty, `PUT $url/service/rest/v1/security/users/admin/change-password` with `Content-Type: text/plain` and body = the Key Vault admin password, authenticated with `admin:$init`. After that, use `admin:$nexus_admin` for everything.
4. EULA (Community Edition): `GET $url/service/rest/v1/system/eula`; if `accepted` is false, `POST` the same JSON back with `"accepted": true`. If the endpoint returns 404 on this version, log `skip eula` and continue.
5. Anonymous off: `PUT $url/service/rest/v1/security/anonymous` with `{"enabled":false,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}`.
6. Repository: if `GET $url/service/rest/v1/repositories/demoapp-releases` is 404, `POST $url/service/rest/v1/repositories/raw/hosted` with `{"name":"demoapp-releases","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":false,"writePolicy":"ALLOW_ONCE"},"raw":{"contentDisposition":"ATTACHMENT"}}`.
7. Roles `demoapp-deployer` (privileges `nx-repository-view-raw-demoapp-releases-add`, `-edit`, `-read`, `-browse`) and `demoapp-reader` (`-read`, `-browse`): `GET /service/rest/v1/security/roles/<id>` → 404 ⇒ `POST /service/rest/v1/security/roles`, else `PUT /service/rest/v1/security/roles/<id>`. Body `{"id":"<id>","name":"<id>","description":"PoC <id>","privileges":[…],"roles":[]}`.
8. Users `svc-gh-deployer` (role `demoapp-deployer`) and `svc-win-reader` (role `demoapp-reader`): `GET /service/rest/v1/security/users?userId=<id>` returns `[]` ⇒ `POST /service/rest/v1/security/users` with `{"userId":"<id>","firstName":"svc","lastName":"<id>","emailAddress":"<id>@example.invalid","password":"<kv value>","status":"active","roles":["<role>"]}`; otherwise `PUT /service/rest/v1/security/users/<id>` (same body without `password`) and `PUT /service/rest/v1/security/users/<id>/change-password` with the Key Vault value, so Nexus always matches Key Vault.
9. Every `curl` uses `--fail-with-body -sS`, and passwords go through `-u` built from variables (never `set -x`). Print one line per step: `ok <step>`.

- [ ] **Step 6: Run bootstrap, the smoke test, and a second bootstrap**

```bash
bash infra/nexus/bootstrap.sh
bash infra/nexus/tests/smoke.sh     # expect SMOKE PASS
bash infra/nexus/bootstrap.sh       # second run: same "ok" lines, no errors
bash infra/nexus/tests/smoke.sh     # still SMOKE PASS
curl -sI https://nexus-winapp-poc.eastus.cloudapp.azure.com | head -1   # TLS works (HTTP/2 200 or 302)
```

- [ ] **Step 7: Commit and push**

```bash
git add infra
git commit -m "feat(nexus): PoC Nexus CE with Caddy TLS, bootstrap and smoke test"
git push
```

### Task 6: First manual deployment (R3) and runbook

**Files:**
- Create: `infra/scripts/manual/manual-deploy.ps1`, `infra/scripts/manual/manual-deploy.sh`, `docs/runbooks/manual-deploy.md`

**Interfaces:**
- Consumes: the CI artifact from Task 2 (`gh run download … -n demoapp-package`), Nexus (Task 5), VM (Task 4).
- Produces: DemoApp served at `http://winapp-poc.eastus.cloudapp.azure.com/` from `C:\inetpub\demoapp\current` → `releases\<version>`, with `DemoAppPool` and site `DemoApp` on port 80 and `Default Web Site` removed. Task 8's role must accept this state as its starting point.

- [ ] **Step 1: Write `manual-deploy.ps1` (runs on the VM through `az vm run-command`)**

```powershell
param(
    [Parameter(Mandatory)] [string] $ArtifactUrl,
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $Sha256,
    [Parameter(Mandatory)] [string] $KeyVaultName
)
$ErrorActionPreference = 'Stop'
$root = 'C:\inetpub\demoapp'
$release = Join-Path $root "releases\$Version"
$current = Join-Path $root 'current'
$zip = Join-Path $root "staging\DemoApp-$Version.zip"
New-Item -ItemType Directory -Force -Path (Join-Path $root 'releases'), (Join-Path $root 'staging') | Out-Null

# Nexus reader password via the VM managed identity
$token = (Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net').access_token
$pw = (Invoke-RestMethod -Headers @{Authorization="Bearer $token"} -Uri "https://$KeyVaultName.vault.azure.net/secrets/nexus-reader-password?api-version=7.4").value
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("svc-win-reader:${pw}"))
Invoke-WebRequest -UseBasicParsing -Headers @{Authorization="Basic $basic"} -Uri $ArtifactUrl -OutFile $zip
if ((Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant() -ne $Sha256) { throw 'checksum mismatch' }
if (-not (Test-Path $release)) { Expand-Archive -Path $zip -DestinationPath $release }

Import-Module WebAdministration
if (Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue) { Remove-Website -Name 'Default Web Site' }
if (-not (Test-Path 'IIS:\AppPools\DemoAppPool')) { New-WebAppPool -Name 'DemoAppPool' | Out-Null }
Set-ItemProperty 'IIS:\AppPools\DemoAppPool' -Name managedRuntimeVersion -Value 'v4.0'
Set-ItemProperty 'IIS:\AppPools\DemoAppPool' -Name managedPipelineMode -Value 'Integrated'
if (Test-Path $current) { cmd /c rmdir "$current" | Out-Null }
New-Item -ItemType Junction -Path $current -Target $release | Out-Null
if (-not (Get-Website -Name 'DemoApp' -ErrorAction SilentlyContinue)) {
    New-Website -Name 'DemoApp' -Port 80 -PhysicalPath $current -ApplicationPool 'DemoAppPool' | Out-Null
}
Start-Website -Name 'DemoApp'
Add-Content -Path (Join-Path $root 'deployments.log') -Value ("{0:o} version={1} git_sha=manual job=manual result=success" -f (Get-Date).ToUniversalTime(), $Version)
"manual deploy ok $Version"
```
Parse-check with pwsh as in Task 4.

- [ ] **Step 2: Write `manual-deploy.sh` (workstation side)**

It downloads the latest `demoapp-package` artifact from the `poc/implementation` CI run, uploads the zip and `.sha256` to `demoapp-releases/demoapp/<version>/` with the deployer credentials from Key Vault (`curl --fail-with-body -sS -u … --upload-file`), then calls `az vm run-command invoke -g rg-winapp-poc -n vm-winapp-01 --command-id RunPowerShellScript --scripts @infra/scripts/manual/manual-deploy.ps1 --parameters "ArtifactUrl=…" "Version=…" "Sha256=…" "KeyVaultName=…"`, prints the run-command message, and finally curls `/health` and `/version`. It exits non-zero if `/version` ≠ the uploaded version.

- [ ] **Step 3: Run it and verify D1/D2**

```bash
bash infra/scripts/manual/manual-deploy.sh
curl -s http://winapp-poc.eastus.cloudapp.azure.com/health     # {"status":"ok"}
curl -s http://winapp-poc.eastus.cloudapp.azure.com/version    # {"version":"1.0.<n>","gitSha":"<sha7>"}
curl -s http://winapp-poc.eastus.cloudapp.azure.com/ | grep -o 'Version [^<]*'
```

- [ ] **Step 4: Write the runbook**

`docs/runbooks/manual-deploy.md` with two paths: (a) the RDP path from HLD §11.3 (copy the zip, unpack, junction, pool, site), and (b) the run-command path this task executed (`manual-deploy.sh`). Include the verification commands, the evidence captured (date, version, hashes, responses) and a note that no secret is printed.

- [ ] **Step 5: Commit and push**

```bash
git add infra/scripts/manual docs/runbooks/manual-deploy.md
git commit -m "feat(deploy): manual first deployment script and runbook (R3)"
git push
```

### Task 7: AAP configuration as code (org, identity, credentials, project, inventory, ping template)

**Files:**
- Create: `ansible/collections/requirements.yml`, `aap/configure.yml`, `aap/verify.yml`, `aap/vars/poc.yml`, `aap/README.md`

**Interfaces:**
- Consumes: `.env.aap` (`TOWER_HOST`, `TOWER_OAUTH_TOKEN`, `AWXKIT_API_BASE_PATH`, `ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN`), Key Vault secrets `aap-sp-client-id`, `aap-sp-client-secret`, `aap-svc-github-cd-password`, Task 4 `ping.yml` and group vars.
- Produces: AAP objects listed in Global Constraints except `winapp-deploy` (added in Task 8). A variable `aap_project_branch` (default `main`) that is set to `poc/implementation` during development with `-e aap_project_branch=poc/implementation`. `aap/configure.yml` accepts tags `base` and `deploy` (Task 8 adds `deploy`-tagged tasks).

- [ ] **Step 1: Install the collections**

`ansible/collections/requirements.yml`:
```yaml
---
collections:
  - name: ansible.platform
    version: ">=2.7.0"
    source: https://console.redhat.com/api/automation-hub/content/published/
  - name: ansible.controller
    version: ">=4.8.0"
    source: https://console.redhat.com/api/automation-hub/content/published/
  - name: ansible.windows
  - name: azure.azcollection
```
Run: `set -a; . ./.env.aap; set +a; ansible-galaxy collection install -r ansible/collections/requirements.yml`
Expected: both certified collections install. If `ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN` is missing or rejected, report BLOCKED with that exact message. Do not fall back to another approach.

Then read the module docs you need, and note the exact parameter names in the report: `ansible-doc ansible.platform.organization ansible.platform.team ansible.platform.user ansible.platform.role_user_assignment ansible.controller.credential ansible.controller.credential_input_source ansible.controller.project ansible.controller.inventory ansible.controller.inventory_source ansible.controller.job_template ansible.controller.role_user_assignment ansible.controller.inventory_source_update ansible.controller.job_launch`. Also check how each collection takes the gateway host and token from the environment (`CONTROLLER_HOST`/`TOWER_HOST`, `AAP_HOSTNAME`, `CONTROLLER_OAUTH_TOKEN`/`TOWER_OAUTH_TOKEN`, `AAP_TOKEN`) and whether `ansible.controller` needs an API path setting for `/api/controller/`.

- [ ] **Step 2: Write the variables file**

`aap/vars/poc.yml`:
```yaml
---
aap_org: winapp-poc
aap_team: cd-automation
aap_cd_user: svc-github-cd
aap_project_name: azure-windows-aap-automation
aap_project_url: https://github.com/vinothtestorg/azure-windows-aap-automation.git
aap_project_branch: main
aap_inventory: azure-windows-poc
aap_cred_azure_rm: azure-sp-poc
aap_cred_key_vault: azure-kv-poc
aap_cred_machine: win-ansible-svc
aap_jt_ping: winapp-ping
aap_jt_deploy: winapp-deploy
azure_subscription_id: 03b6c75f-a3f1-429f-ab89-0f9b07087638
azure_tenant_id: e31db877-05a5-4e5a-acfe-c0384e23172a
azure_resource_group: rg-winapp-poc
key_vault_name: "{{ lookup('ansible.builtin.pipe', 'az deployment group show -g rg-winapp-poc -n main --query properties.outputs.keyVaultName.value -o tsv') }}"
```

- [ ] **Step 3: Write `aap/configure.yml`**

A local play (`hosts: localhost`, `connection: local`, `gather_facts: false`) with `module_defaults` for the `group/ansible.platform.gateway` and `group/ansible.controller.controller` action groups (host and token from the environment of `.env.aap`). All tasks tagged `base`. Secrets come from Key Vault with `lookup('ansible.builtin.pipe', 'az keyvault secret show --vault-name ' ~ key_vault_name ~ ' -n <name> --query value -o tsv')`, and every task that handles a secret has `no_log: true`. Tasks, in order:
1. Organization `winapp-poc`.
2. Team `cd-automation` in the org.
3. User `svc-github-cd` (not superuser, password = Key Vault `aap-svc-github-cd-password`, `update_secrets: false` so re-runs do not report a change).
4. Role assignment `Team Member` on team `cd-automation` for `svc-github-cd`.
5. Credential `azure-sp-poc`, type `Microsoft Azure Resource Manager`, inputs `subscription`, `client`, `secret`, `tenant` (from Key Vault `aap-sp-client-id`/`aap-sp-client-secret` and `azure_tenant_id`), `update_secrets: false`.
6. Credential `azure-kv-poc`, type `Microsoft Azure Key Vault`, inputs `url: https://<key_vault_name>.vault.azure.net`, `client`, `secret`, `tenant`, `update_secrets: false`.
7. Credential `win-ansible-svc`, type `Machine`, input `username: ansible_svc`.
8. Credential input source: target `win-ansible-svc`, input field `password`, source `azure-kv-poc`, metadata `{secret_field: ansible-svc-password, secret_version: ""}`.
9. Project `azure-windows-aap-automation`: SCM git, `aap_project_url`, branch `aap_project_branch`, `scm_update_on_launch: true`, `scm_clean: true`, no SCM credential, `wait: true`.
10. Inventory `azure-windows-poc` in the org.
11. Inventory source `azure-rm` on that inventory: source `azure_rm`, credential `azure-sp-poc`, `overwrite: true`, `update_on_launch: true`, `source_vars`:
    ```yaml
    include_vm_resource_groups: [rg-winapp-poc]
    exclude_host_filters:
      - "tags.app is not defined or tags.app != 'demoapp'"
      - "os_profile.system != 'windows'"
    conditional_groups:
      windows_web: "true"
    hostvar_expressions:
      ansible_host: "public_dns_hostnames[0]"
    ```
12. Role assignment `Inventory Use` on `azure-windows-poc` for `svc-github-cd`.
13. Job template `winapp-ping`: project, playbook `ansible/playbooks/ping.yml`, inventory, credential `win-ansible-svc`, `ask_limit_on_launch: true`.

`aap/README.md`: how to run (source `.env.aap`, install collections, `ansible-playbook aap/configure.yml -e aap_project_branch=poc/implementation`), what it creates, and that `.env.aap` and the admin token never leave the workstation.

- [ ] **Step 4: Apply, then prove idempotency**

```bash
set -a; . ./.env.aap; set +a
ansible-lint aap/configure.yml
ansible-playbook aap/configure.yml -e aap_project_branch=poc/implementation
ansible-playbook aap/configure.yml -e aap_project_branch=poc/implementation   # expect changed=0
```
If the second run reports changes, find the non-idempotent task and fix it (typical causes: secrets without `update_secrets: false`, input sources recreated).

- [ ] **Step 5: Verify inventory sync and the ping job in AAP**

Add a verification play, `aap/verify.yml` (tagged `base`), that runs `ansible.controller.inventory_source_update` (name `azure-rm`, `wait: true`), asserts that the inventory contains host `vm-winapp-01` in group `windows_web` (with `ansible.controller.export` or the `ansible.controller.controller_api` lookup on `hosts/?inventory=<id>`), and runs `ansible.controller.job_launch` for `winapp-ping` with `wait: true`, asserting `status == 'successful'`.
Run: `ansible-playbook aap/verify.yml`
Expected: inventory sync successful, `vm-winapp-01` present, `winapp-ping` successful. This also proves the default EE ships `pypsrp` (risk K3). If the ping fails with a missing `pypsrp` error, change `ansible_connection` to `winrm` in `ansible/playbooks/group_vars/windows_web.yml` (and set `ansible_winrm_transport: ntlm`, `ansible_winrm_server_cert_validation: ignore`, `ansible_winrm_scheme: https`), push, and re-run. Record which connection was used.

- [ ] **Step 6: Commit and push**

```bash
git add ansible/collections aap
git commit -m "feat(aap): configuration as code for org, credentials, inventory and ping template"
git push
```

### Task 8: Deployment role, `winapp-deploy` job template, and deploy-path tests

**Files:**
- Create: `ansible/playbooks/deploy.yml`, `ansible/roles/demoapp_deploy/defaults/main.yml`, `ansible/roles/demoapp_deploy/meta/main.yml`, `ansible/roles/demoapp_deploy/tasks/main.yml`, `…/tasks/validate.yml`, `…/tasks/iis.yml`, `…/tasks/fetch.yml`, `…/tasks/switch.yml`, `…/tasks/verify.yml`, `…/tasks/rollback.yml`, `…/tasks/record.yml`, `…/tasks/prune.yml`, `ansible/roles/demoapp_deploy/files/switch-release.ps1`
- Create: `ansible/tests/deploy-scenarios.sh`
- Modify: `ansible/playbooks/group_vars/windows_web.yml` (add `demoapp_key_vault_name`), `aap/configure.yml` (tagged `deploy`: job template `winapp-deploy` + `JobTemplate Execute` for `svc-github-cd`), `aap/verify.yml` (tagged `deploy`: launch `winapp-deploy`)

**Interfaces:**
- Consumes: launch vars `app_version`, `artifact_url`, `artifact_sha256`, `git_sha` (Global Constraints). AAP injects `awx_job_id` (default `local` when absent). Task 6 left the VM with a deployed release, and the role must also work on a VM with no release.
- Produces: job template `winapp-deploy` (prompt on launch for variables and limit, concurrent jobs off, timeout 1800). Task 9 launches it by name.

- [ ] **Step 1: Write the playbook, defaults and validation, with a failing validation test**

`ansible/playbooks/deploy.yml`:
```yaml
---
- name: Deploy DemoApp to IIS
  hosts: windows_web
  gather_facts: false
  roles:
    - role: demoapp_deploy
```

`ansible/roles/demoapp_deploy/defaults/main.yml`:
```yaml
---
demoapp_root: 'C:\inetpub\demoapp'
demoapp_site_name: DemoApp
demoapp_pool_name: DemoAppPool
demoapp_port: 80
demoapp_keep_releases: 5
demoapp_health_retries: 10
demoapp_health_delay: 6
demoapp_allowed_artifact_prefix: https://nexus-winapp-poc.eastus.cloudapp.azure.com/repository/demoapp-releases/
demoapp_nexus_reader_user: svc-win-reader
demoapp_nexus_reader_secret: nexus-reader-password
demoapp_key_vault_name: ""   # set in group_vars/windows_web.yml
demoapp_job_id: "{{ awx_job_id | default('local') }}"
git_sha: unknown
```

`ansible/roles/demoapp_deploy/tasks/validate.yml`:
```yaml
---
- name: Validate launch variables
  ansible.builtin.assert:
    quiet: true
    that:
      - app_version is defined and app_version is match('^\d+\.\d+\.\d+$')
      - artifact_url is defined and artifact_url is string
      - artifact_url.startswith(demoapp_allowed_artifact_prefix)
      - artifact_url.endswith('.zip')
      - "'..' not in artifact_url and '?' not in artifact_url and '#' not in artifact_url"
      - artifact_sha256 is defined and artifact_sha256 is match('^[a-f0-9]{64}$')
      - git_sha == 'unknown' or git_sha is match('^[0-9a-f]{7,40}$')
      - demoapp_key_vault_name | length > 0
    fail_msg: "Invalid launch variables: app_version, artifact_url (must be under {{ demoapp_allowed_artifact_prefix }}), artifact_sha256 or git_sha"
```

Test first: `ansible/tests/deploy-scenarios.sh` starts with a `validation` scenario that runs `ansible-playbook ansible/playbooks/deploy.yml --tags validate` with each bad input below, and expects a non-zero exit and the `Invalid launch variables` message, with no connection made to the host:
- `artifact_url=https://evil.example.com/x.zip`
- `artifact_url=<prefix>demoapp/../../x.zip`
- `artifact_sha256=ABC` (uppercase / short)
- `app_version=1.0`

Run it before `validate.yml` exists → the scenario fails (the play errors on the missing role/tasks, not on validation). Then with `validate.yml` → all four PASS.

`tasks/main.yml`:
```yaml
---
- name: Validate
  ansible.builtin.import_tasks: validate.yml
  tags: [validate]

- name: Deploy with automatic rollback
  block:
    - name: Ensure IIS
      ansible.builtin.import_tasks: iis.yml
    - name: Fetch artifact
      ansible.builtin.import_tasks: fetch.yml
    - name: Switch release
      ansible.builtin.import_tasks: switch.yml
    - name: Verify health
      ansible.builtin.import_tasks: verify.yml
    - name: Prune old releases
      ansible.builtin.import_tasks: prune.yml
    - name: Record success
      ansible.builtin.include_tasks: record.yml
      vars:
        demoapp_result: success
  rescue:
    - name: Roll back
      ansible.builtin.import_tasks: rollback.yml
    - name: Record failure
      ansible.builtin.include_tasks: record.yml
      vars:
        demoapp_result: "{{ 'rolled_back' if (demoapp_switched | default(false) and demoapp_previous_release | default('') | length > 0) else 'failed' }}"
    - name: Fail the job
      ansible.builtin.fail:
        msg: "Deployment of {{ app_version }} failed: {{ ansible_failed_result.msg | default('see previous task') }}"
```

- [ ] **Step 2: IIS and fetch tasks**

`tasks/iis.yml`: `ansible.windows.win_feature` (`Web-Server`, `Web-Asp-Net45`); `ansible.windows.win_file` directories `{{ demoapp_root }}\releases` and `{{ demoapp_root }}\staging`; then `ansible.windows.win_powershell` (idempotent, sets `$Ansible.Changed` only on real change):
```powershell
param([string]$SiteName, [string]$PoolName, [string]$PhysicalPath, [int]$Port)
$ErrorActionPreference = 'Stop'
Import-Module WebAdministration
$Ansible.Changed = $false
if (Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue) { Remove-Website -Name 'Default Web Site'; $Ansible.Changed = $true }
if (-not (Test-Path "IIS:\AppPools\$PoolName")) { New-WebAppPool -Name $PoolName | Out-Null; $Ansible.Changed = $true }
$pool = Get-Item "IIS:\AppPools\$PoolName"
if ($pool.managedRuntimeVersion -ne 'v4.0') { Set-ItemProperty "IIS:\AppPools\$PoolName" -Name managedRuntimeVersion -Value 'v4.0'; $Ansible.Changed = $true }
if ($pool.managedPipelineMode -ne 'Integrated') { Set-ItemProperty "IIS:\AppPools\$PoolName" -Name managedPipelineMode -Value 'Integrated'; $Ansible.Changed = $true }
if (-not (Get-Website -Name $SiteName -ErrorAction SilentlyContinue)) {
    New-Website -Name $SiteName -Port $Port -PhysicalPath $PhysicalPath -ApplicationPool $PoolName -Force | Out-Null
    $Ansible.Changed = $true
}
```
with `parameters: {SiteName: …, PoolName: …, PhysicalPath: "{{ demoapp_root }}\\current", Port: …}`.

`tasks/fetch.yml`:
1. `ansible.windows.win_stat` on `{{ demoapp_root }}\releases\{{ app_version }}\.complete` → `demoapp_release_stat`.
2. When not present: `ansible.windows.win_powershell` with `no_log: true` that gets the IMDS token (retry 5 times, 10 s apart), reads the secret, and downloads to `{{ demoapp_root }}\staging\DemoApp-{{ app_version }}.zip`:
```powershell
param([string]$KeyVaultName, [string]$SecretName, [string]$NexusUser, [string]$ArtifactUrl, [string]$OutFile)
$ErrorActionPreference = 'Stop'
$token = $null
for ($i = 1; $i -le 5 -and -not $token; $i++) {
    try { $token = (Invoke-RestMethod -Headers @{Metadata='true'} -Uri 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net').access_token }
    catch { if ($i -eq 5) { throw 'IMDS token request failed' }; Start-Sleep -Seconds 10 }
}
$password = (Invoke-RestMethod -Headers @{Authorization="Bearer $token"} -Uri "https://$KeyVaultName.vault.azure.net/secrets/${SecretName}?api-version=7.4").value
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${NexusUser}:${password}"))
Invoke-WebRequest -UseBasicParsing -Headers @{Authorization="Basic $basic"} -Uri $ArtifactUrl -OutFile $OutFile
$Ansible.Changed = $true
```
   Note `${NexusUser}:` — in PowerShell `"$NexusUser:"` would be parsed as a scope-qualified variable.
3. When not present: `ansible.windows.win_stat` on the zip with `get_checksum: true`, `checksum_algorithm: sha256`, then `ansible.builtin.assert` that `stat.checksum == artifact_sha256` (message `checksum mismatch`).
4. When not present: `ansible.windows.win_powershell` that expands into `releases\<version>.tmp`, renames it to `releases\<version>`, writes `.complete`, and deletes the staging zip. If `.tmp` already exists from an interrupted run, delete it first.

- [ ] **Step 3: Switch, verify, rollback, record, prune**

`tasks/switch.yml`: `ansible.windows.win_powershell` registered as `demoapp_switch`:
```powershell
param([string]$Root, [string]$Version, [string]$PoolName, [string]$SiteName)
$ErrorActionPreference = 'Stop'
Import-Module WebAdministration
$current = Join-Path $Root 'current'
$target = Join-Path $Root "releases\$Version"
$previous = ''
if (Test-Path $current) { $previous = [string]((Get-Item $current -Force).Target | Select-Object -First 1) }
if ($previous -eq $target) {
    $Ansible.Changed = $false
    $Ansible.Result = @{ previous = $previous; switched = $false }
    return
}
if ((Get-WebAppPoolState -Name $PoolName).Value -ne 'Stopped') {
    Stop-WebAppPool -Name $PoolName
    for ($i = 0; $i -lt 30 -and (Get-WebAppPoolState -Name $PoolName).Value -ne 'Stopped'; $i++) { Start-Sleep -Seconds 1 }
}
if (Test-Path $current) { cmd /c rmdir "$current" | Out-Null }   # removes the junction only, never the release
New-Item -ItemType Junction -Path $current -Target $target | Out-Null
Start-WebAppPool -Name $PoolName
if ((Get-Website -Name $SiteName).State -ne 'Started') { Start-Website -Name $SiteName }
$Ansible.Result = @{ previous = $previous; switched = $true }
$Ansible.Changed = $true
```
Then `ansible.builtin.set_fact`: `demoapp_previous_release: "{{ demoapp_switch.result.previous }}"`, `demoapp_switched: "{{ demoapp_switch.result.switched }}"`.

`tasks/verify.yml`: `ansible.windows.win_uri` `http://localhost:{{ demoapp_port }}/health` with `status_code: 200`, `return_content: true`, `until: demoapp_health.status_code == 200`, `retries: "{{ demoapp_health_retries }}"`, `delay: "{{ demoapp_health_delay }}"`. Then `win_uri` `/version`, and `assert` `(demoapp_version_resp.content | from_json).version == app_version`.

`tasks/rollback.yml`: runs only `when: demoapp_switched | default(false) and demoapp_previous_release | default('') | length > 0`. It runs the same PowerShell as switch, with the target = `demoapp_previous_release` (pass the full path; make the switch script accept an optional `-TargetPath` so there is one script, stored as `ansible/roles/demoapp_deploy/files/switch-release.ps1` and loaded with `lookup('ansible.builtin.file', 'switch-release.ps1')` by both tasks), then recycles the pool.

`tasks/record.yml`: `ansible.windows.win_powershell` that appends `"{0:o} version={1} git_sha={2} job={3} result={4}"` to `{{ demoapp_root }}\deployments.log`.

`tasks/prune.yml`: `ansible.windows.win_powershell` that lists `releases\*` directories (not ending `.tmp`), excludes the current target and `demoapp_previous_release`, sorts by `CreationTime` descending, skips `demoapp_keep_releases`, and removes the rest with `Remove-Item -Recurse -Force`. Sets `$Ansible.Changed` only if something was removed.

`ansible/playbooks/group_vars/windows_web.yml` gets `demoapp_key_vault_name: <value of kv_name>` (not a secret).

- [ ] **Step 4: Lint**

Run: `ansible-lint ansible/ && ansible-playbook --syntax-check ansible/playbooks/deploy.yml`
Expected: `Passed` with 0 failures, and the syntax check is OK.

- [ ] **Step 5: Live scenarios from the workstation**

`ansible/tests/deploy-scenarios.sh` (bash, sources `infra/scripts/lib.sh`, exports `ANSIBLE_SVC_PASSWORD` from Key Vault, never echoes it) implements these scenarios, each printing `PASS <name>`/`FAIL <name>` and exiting non-zero on any FAIL:
- `validation`: from Step 1 (no host contact).
- `good`: take the latest CI `demoapp-package` (Task 2) and **re-package it as a fresh version** `1.0.<9000+epoch-minutes mod 1000>` (unzip, rewrite `version.json`, re-zip, recompute sha256), upload to Nexus, run `deploy.yml` → exit 0, and `/version` over HTTP returns that version.
- `idempotent`: rerun `good` with the same vars → exit 0, and the `Switch release` task reports `changed=false` (grep the output with `ANSIBLE_STDOUT_CALLBACK=json` or a callback-free check of `deployments.log` plus the task status).
- `bad_checksum` (V6): same artifact, wrong `artifact_sha256` → exit non-zero, and `/version` is unchanged.
- `unhealthy` (V4): re-package with `Web.config` replaced by `<configuration><broken` (malformed XML → HTTP 500) as a new version, upload, deploy → exit non-zero, rollback runs, `/version` returns the previous good version, and `deployments.log` last line has `result=rolled_back`.
- `first_deploy_failure`: the rescue path with no previous release must not crash. Test it by running the role against the unhealthy artifact with `-e demoapp_root='C:\inetpub\demoapp-firsttest' -e demoapp_site_name=DemoAppFirstTest -e demoapp_port=8081 -e demoapp_pool_name=DemoAppFirstTestPool` → exit non-zero with `result=failed` in that root's log and no Python/Ansible exception in the rescue. Clean up that site, pool and folder afterwards with `win_powershell`.
- `no_secret_leak`: grep all captured outputs for the three Nexus passwords and the `ansible_svc` password (loaded into variables, not printed). Expect zero matches.

Run: `bash ansible/tests/deploy-scenarios.sh`
Expected: every scenario PASS.

- [ ] **Step 6: Add the job template in AAP and launch it**

In `aap/configure.yml`, add tasks tagged `deploy`: job template `winapp-deploy` (project, playbook `ansible/playbooks/deploy.yml`, inventory `azure-windows-poc`, credential `win-ansible-svc`, `ask_variables_on_launch: true`, `ask_limit_on_launch: true`, `allow_simultaneous: false`, `timeout: 1800`), and role `JobTemplate Execute` on it for `svc-github-cd`. In `aap/verify.yml`, add a `deploy`-tagged launch of `winapp-deploy` with extra vars for a new re-packaged version (the scenario script exposes `--prepare-only`, which uploads a fresh good version and prints the four vars as JSON), `wait: true`, asserting `successful`, and fetching the job stdout to assert it does not contain the Nexus reader password.

Run:
```bash
set -a; . ./.env.aap; set +a
git push   # AAP project syncs poc/implementation on launch
ansible-playbook aap/configure.yml -e aap_project_branch=poc/implementation
ansible-playbook aap/verify.yml --tags deploy -e @<(bash ansible/tests/deploy-scenarios.sh --prepare-only)
```
Expected: `winapp-deploy` successful in AAP, and the site serves the new version.

- [ ] **Step 7: Commit and push**

```bash
git add ansible aap
git commit -m "feat(deploy): demoapp_deploy role with rollback, winapp-deploy job template and scenario tests"
git push
```

### Task 9: CD workflow (GitHub → Nexus → AAP) and GitHub environment

**Files:**
- Create: `.github/workflows/cd.yml`, `.github/scripts/aap-launch.sh`, `.github/scripts/nexus-upload.sh`, `.github/scripts/tests/test-aap-launch.sh`, `infra/scripts/setup-github-env.sh`
- Modify: `.github/workflows/ci.yml` (add the `cd` job)

**Interfaces:**
- Consumes: CI outputs `version`, `package_name`, `sha256`, `git_sha` and artifact `demoapp-package` (Task 2); `winapp-deploy` (Task 8); Key Vault secret `nexus-deployer-password`; UAMI `id-gh-deployer` (Task 3).
- Produces: `aap-launch.sh <job-template-name> <extra-vars-json-file>`, which prints `job_id=<id>` and `job_url=<url>` to stdout (and to `$GITHUB_OUTPUT` when set) and exits 0 only on `successful`. `nexus-upload.sh <file> <remote-path>` exits non-zero on any non-201 response.

- [ ] **Step 1: Write the launcher test first**

`.github/scripts/tests/test-aap-launch.sh` (runs locally against the sandbox with `.env.aap`):
- `unknown_template`: `aap-launch.sh does-not-exist vars.json` → exit code ≠ 0, and stderr contains `job template 'does-not-exist' not found`.
- `ping_success`: `aap-launch.sh winapp-ping '{}'` → exit 0, stdout has `job_id=` and `job_url=`.
- `failure_propagates`: launch `winapp-deploy` with an invalid `artifact_sha256` → exit ≠ 0, and stderr shows the job's final status `failed` and the tail of the job output.
Run it before the script exists → FAIL.

- [ ] **Step 2: Write `aap-launch.sh`**

```bash
#!/usr/bin/env bash
# Launch an AAP job template through the platform gateway and wait for it.
# Usage: aap-launch.sh <job-template-name> <extra-vars-json-file>
# Env: TOWER_HOST, TOWER_OAUTH_TOKEN, AWXKIT_API_BASE_PATH (e.g. /api/controller/)
set -euo pipefail
name="$1"; vars_file="$2"
: "${TOWER_HOST:?}" "${TOWER_OAUTH_TOKEN:?}" "${AWXKIT_API_BASE_PATH:?}"
api="${TOWER_HOST%/}${AWXKIT_API_BASE_PATH%/}/v2"
timeout_s="${AAP_JOB_TIMEOUT:-1800}"; poll_s="${AAP_POLL_INTERVAL:-10}"

aap() { curl -sS --fail-with-body -H "Authorization: Bearer $TOWER_OAUTH_TOKEN" -H 'Content-Type: application/json' "$@"; }

jt_id="$(aap -G "$api/job_templates/" --data-urlencode "name=$name" | jq -r '.results[0].id // empty')"
[[ -n "$jt_id" ]] || { echo "job template '$name' not found or not visible to this token" >&2; exit 2; }

payload="$(jq -c '{extra_vars: .}' "$vars_file")"
job_id="$(aap -X POST "$api/job_templates/$jt_id/launch/" -d "$payload" | jq -r '.job // .id')"
job_url="${TOWER_HOST%/}/execution/jobs/playbook/$job_id/output"
echo "job_id=$job_id"; echo "job_url=$job_url"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then { echo "job_id=$job_id"; echo "job_url=$job_url"; } >> "$GITHUB_OUTPUT"; fi

deadline=$(( $(date +%s) + timeout_s ))
while :; do
  status="$(aap "$api/jobs/$job_id/" | jq -r '.status')"
  case "$status" in
    successful) echo "AAP job $job_id successful" >&2; exit 0 ;;
    failed|error|canceled)
      echo "AAP job $job_id finished with status $status" >&2
      aap "$api/jobs/$job_id/stdout/?format=txt" | tail -n 60 >&2 || true
      exit 1 ;;
    new|pending|waiting|running) ;;
    *) echo "unexpected status '$status'" >&2 ;;
  esac
  (( $(date +%s) < deadline )) || { echo "timed out after ${timeout_s}s waiting for job $job_id" >&2; exit 1; }
  sleep "$poll_s"
done
```
The test passes `'{}'` inline. Accept either a file path or, when the argument starts with `{`, a JSON string (use `jq -c '{extra_vars: .}' <<<"$2"`).

`nexus-upload.sh`:
```bash
#!/usr/bin/env bash
# Usage: nexus-upload.sh <local-file> <path-inside-repo>   Env: NEXUS_URL, NEXUS_REPOSITORY, NEXUS_USER, NEXUS_PASSWORD
set -euo pipefail
file="$1"; remote="$2"
url="${NEXUS_URL%/}/repository/${NEXUS_REPOSITORY}/${remote}"
code="$(curl -sS -o /dev/stderr -w '%{http_code}' -u "${NEXUS_USER}:${NEXUS_PASSWORD}" --upload-file "$file" "$url")"
[[ "$code" == 201 ]] || { echo "upload of $remote failed: HTTP $code" >&2; exit 1; }
echo "uploaded $url"
```

Run `bash .github/scripts/tests/test-aap-launch.sh` → all PASS. Also run `shellcheck .github/scripts/*.sh`.

- [ ] **Step 3: Write `cd.yml` and wire it into `ci.yml`**

`.github/workflows/cd.yml`:
```yaml
name: cd

on:
  workflow_call:
    inputs:
      version: { required: true, type: string }
      package_name: { required: true, type: string }
      sha256: { required: true, type: string }
      git_sha: { required: true, type: string }

permissions:
  id-token: write
  contents: read

concurrency:
  group: cd-poc
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: poc
    steps:
      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4
        with:
          name: demoapp-package
          path: dist

      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Read Nexus deployer password
        id: nexus
        run: |
          pw="$(az keyvault secret show --vault-name "${{ vars.KEY_VAULT_NAME }}" -n nexus-deployer-password --query value -o tsv)"
          echo "::add-mask::$pw"
          echo "password=$pw" >> "$GITHUB_OUTPUT"

      - name: Upload to Nexus
        env:
          NEXUS_URL: ${{ vars.NEXUS_URL }}
          NEXUS_REPOSITORY: ${{ vars.NEXUS_REPOSITORY }}
          NEXUS_USER: svc-gh-deployer
          NEXUS_PASSWORD: ${{ steps.nexus.outputs.password }}
        run: |
          remote="demoapp/${{ inputs.version }}/${{ inputs.package_name }}"
          bash .github/scripts/nexus-upload.sh "dist/${{ inputs.package_name }}" "$remote"
          bash .github/scripts/nexus-upload.sh "dist/${{ inputs.package_name }}.sha256" "$remote.sha256"
          echo "artifact_url=${NEXUS_URL%/}/repository/${NEXUS_REPOSITORY}/$remote" >> "$GITHUB_ENV"

      - name: Launch AAP job template
        id: aap
        env:
          TOWER_HOST: ${{ vars.TOWER_HOST }}
          AWXKIT_API_BASE_PATH: ${{ vars.AWXKIT_API_BASE_PATH }}
          TOWER_OAUTH_TOKEN: ${{ secrets.TOWER_OAUTH_TOKEN }}
        run: |
          jq -n --arg v "${{ inputs.version }}" --arg u "$artifact_url" --arg s "${{ inputs.sha256 }}" --arg g "${{ inputs.git_sha }}" \
            '{app_version:$v, artifact_url:$u, artifact_sha256:$s, git_sha:$g}' > extra-vars.json
          bash .github/scripts/aap-launch.sh "${{ vars.AAP_JOB_TEMPLATE }}" extra-vars.json

      - name: Summary
        if: always()
        run: |
          {
            echo "### DemoApp deployment"
            echo "| Item | Value |"; echo "|---|---|"
            echo "| Version | ${{ inputs.version }} |"
            echo "| Artifact | ${artifact_url:-not uploaded} |"
            echo "| AAP job | ${{ steps.aap.outputs.job_url || 'not launched' }} |"
            echo "| Result | ${{ job.status }} |"
          } >> "$GITHUB_STEP_SUMMARY"
```

`ci.yml` addition:
```yaml
  cd:
    needs: build
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    uses: ./.github/workflows/cd.yml
    permissions:
      id-token: write
      contents: read
    with:
      version: ${{ needs.build.outputs.version }}
      package_name: ${{ needs.build.outputs.package_name }}
      sha256: ${{ needs.build.outputs.sha256 }}
      git_sha: ${{ needs.build.outputs.git_sha }}
    secrets: inherit
```

- [ ] **Step 4: Write and run `setup-github-env.sh`**

`infra/scripts/setup-github-env.sh` (idempotent; sources `lib.sh` and `.env.aap`; never prints secret values):
1. `gh api -X PUT repos/vinothtestorg/azure-windows-aap-automation/environments/poc --input -` with `{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}`.
2. Ensure branch policy `main`: list `…/environments/poc/deployment-branch-policies`; if absent, `gh api -X POST … -f name=main -f type=branch`.
3. Variables with `gh variable set <NAME> --env poc --body <value>`: `AZURE_CLIENT_ID` (`az identity show -g rg-winapp-poc -n id-gh-deployer --query clientId -o tsv`), `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `KEY_VAULT_NAME` (`kv_name`), `NEXUS_URL` (`https://nexus-winapp-poc.eastus.cloudapp.azure.com`), `NEXUS_REPOSITORY` (`demoapp-releases`), `TOWER_HOST`, `AWXKIT_API_BASE_PATH`, `AAP_JOB_TEMPLATE` (`winapp-deploy`).
4. Secret `TOWER_OAUTH_TOKEN`: only when it is missing (`gh secret list --env poc`) or `--rotate` is passed. Mint the token as the service user through the gateway: `curl -sS --fail-with-body -u "svc-github-cd:$pw" -H 'Content-Type: application/json' -X POST "${TOWER_HOST%/}/api/gateway/v1/tokens/" -d '{"description":"github-actions-cd","scope":"write"}' | jq -r .token | gh secret set TOWER_OAUTH_TOKEN --env poc` (`$pw` from Key Vault `aap-svc-github-cd-password`).
5. Print a table of names set (values only for non-secret variables).

Verify with the service user's token that least privilege holds. Mint a throwaway token the same way into a shell variable, then:
- `GET …/api/controller/v2/job_templates/?name=winapp-ping` → `count` 0 (not visible) and `…?name=winapp-deploy` → `count` 1.
- `PATCH …/job_templates/<winapp-deploy id>/` with `{"description":"x"}` → HTTP 403.
Then revoke the throwaway token (`DELETE /api/gateway/v1/tokens/<id>/`). Record the results for V5.

- [ ] **Step 5: Push and confirm the branch build still passes (the CD job is skipped off `main`)**

```bash
git add .github infra/scripts/setup-github-env.sh
git commit -m "feat(cd): reusable CD workflow uploading to Nexus and launching AAP via gateway API"
git push
gh run watch --exit-status "$(gh run list --workflow ci.yml --branch poc/implementation --limit 1 --json databaseId --jq '.[0].databaseId')"
```
Expected: `build` succeeds and `cd` is skipped. The end-to-end CD run happens after the merge to `main` (Task 10).

### Task 10: End-to-end validation (V1–V9), runbooks and as-built docs

**Files:**
- Create: `docs/runbooks/validation.md`, `docs/runbooks/teardown.md`
- Modify: `docs/HLD.md` (as-built notes: the preflight rulings that changed the design, and actual names such as the Key Vault name), `README.md` (quick start)
- Modify: `aap/configure.yml` vars usage: switch the AAP project branch to `main` (`ansible-playbook aap/configure.yml` without the override) after the merge.

**Interfaces:**
- Consumes: everything above. Requires the `poc/implementation` → `main` merge. The controller opens that PR and merges it after the user approves.

- [ ] **Step 1: After the merge, point AAP at `main` and run CD**

```bash
set -a; . ./.env.aap; set +a
ansible-playbook aap/configure.yml               # project branch back to main
gh run watch --exit-status "$(gh run list --workflow ci.yml --branch main --limit 1 --json databaseId --jq '.[0].databaseId')"
curl -s http://winapp-poc.eastus.cloudapp.azure.com/version
```
Expected: `build` and `cd / deploy` succeed, the step summary shows the AAP job URL, and `/version` equals `1.0.<run_number>` of that run (V2).

- [ ] **Step 2: Run the validation matrix and record evidence**

Execute V1–V9 from HLD §12.2, reusing `ansible/tests/deploy-scenarios.sh`, `infra/nexus/tests/smoke.sh`, `.github/scripts/tests/test-aap-launch.sh` and the Task 9 least-privilege checks. For V1 open a throwaway PR (for example a README typo fix) and confirm that only `build` runs, then close it without merging. For V5 (Entra), also push a temporary workflow (trigger `push` on branch `poc/v5-negative`, because `workflow_dispatch` only works for workflows on the default branch) with two jobs that call `azure/login`: one with `environment: poc` (GitHub must refuse it because of the `main`-only branch policy) and one without an environment (Entra must reject the subject `repo:…:ref:refs/heads/poc/v5-negative`). Delete the temporary workflow and branch afterwards. Also grep the CD run log (`gh run view --log`) for the Nexus deployer password (Review Focus 1): zero matches.

`docs/runbooks/validation.md`: one row per test with date, command, expected, actual, evidence link (run URL / AAP job id), PASS/FAIL.

- [ ] **Step 3: Write the teardown runbook (do not execute it)**

`docs/runbooks/teardown.md`: `az group delete -n rg-winapp-poc --yes`, purge the soft-deleted Key Vault (`az keyvault purge -n <kv>`), delete `sp-aap-poc` (`az ad app delete --id <appId>`), revoke the `svc-github-cd` and admin tokens in AAP, delete GitHub environment `poc`, and remove `~/.ssh/winapp_poc_nexus*`.

- [ ] **Step 4: As-built docs**

Add an "As built (2026-09-27)" subsection to HLD §15 that lists every preflight ruling from this plan that changed a design value (Nexus VM size, Run Command instead of CSE, SDK-style project, `ansible.cfg` location, group vars location, the extra Key Vault secrets, no cleanup policy, auto-shutdown time) and the actual Key Vault name. Update `README.md` with a quick start (deploy, bootstrap, configure AAP, set up GitHub environment, push to main) and links to the runbooks.

- [ ] **Step 5: Commit and push**

```bash
git add docs README.md
git commit -m "docs: validation evidence, teardown runbook and as-built notes"
git push
```
