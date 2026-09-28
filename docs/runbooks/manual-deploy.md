# Runbook: first manual deployment (R3)

Scope: get DemoApp running on `vm-winapp-01` (`winapp-poc.eastus.cloudapp.azure.com`)
before any automated (AAP) deployment path exists. Produces the layout that
Task 8's automated role must accept as its starting point:

```
C:\inetpub\demoapp\
  releases\<version>\     one folder per deployed version, unpacked from the CI zip
  current                 a directory junction -> releases\<version>
  staging\                scratch zip download location
  deployments.log         append-only, one line per deploy
```

with `DemoAppPool` (.NET CLR v4.0, Integrated pipeline) and site `DemoApp`
bound to port 80, and IIS's default `Default Web Site` removed.

Two paths are documented: **(a)** RDP, fully manual, from HLD §11.3; **(b)**
the semi-automated `manual-deploy.sh` / `manual-deploy.ps1` pair this task
added, driven from a workstation over `az vm run-command` (no RDP, no inbound
port needed beyond what already exists). Path (b) is what was actually run to
produce the evidence below. Both converge on the identical on-disk/IIS layout
above.

Prerequisites for either path:
- Bicep deployed (Task 4): `vm-winapp-01` up, IIS + ASP.NET 4.x installed,
  system-assigned managed identity with **Key Vault Secrets User** on
  `nexus-reader-password` only.
- Nexus up (Task 5): `https://nexus-winapp-poc.eastus.cloudapp.azure.com`,
  repo `demoapp-releases`, users `svc-gh-deployer` (upload) / `svc-win-reader`
  (download), passwords in Key Vault `kv-winapp-poc-afppbe` as
  `nexus-deployer-password` / `nexus-reader-password`.
- CI green on `poc/implementation` (Task 2): artifact `demoapp-package`
  (`DemoApp-<version>-<sha7>.zip` + `.sha256`, sidecar format `<hash>  <name>`).
- `vm-winapp-01` auto-shuts down daily at 18:00 UTC (DevTestLab schedule). If
  deallocated: `az vm start -g rg-winapp-poc -n vm-winapp-01` before either
  path (path (b)'s script does this automatically).

## Path (a): RDP (HLD §11.3)

1. Confirm your workstation's public IP is the one allowed by the
   `nsg-winapp-tools`/`nsg-winapp-app` admin-IP rule (N13 in the HLD network
   table); RDP (3389) is only open from that IP.
2. Get the CI artifact locally: `gh run list --workflow ci.yml --branch
   poc/implementation --status success --limit 1 --json databaseId,headSha`,
   then `gh run download <id> -n demoapp-package -D ./dist`.
3. Get the VM admin password: `az keyvault secret show --vault-name
   kv-winapp-poc-afppbe -n vm-admin-password --query value -o tsv` (read it
   into the RDP client's credential prompt; do not paste it into a terminal
   that logs history, and do not print it to a file).
4. RDP to `winapp-poc.eastus.cloudapp.azure.com` as `azureadmin`. Copy
   `DemoApp-<version>-<sha7>.zip` to the VM (RDP clipboard or a mapped local
   drive).
5. On the VM, in an elevated PowerShell session:
   ```powershell
   $version = '<version>'   # e.g. 1.0.15, from the zip's filename
   $root = 'C:\inetpub\demoapp'
   $release = "$root\releases\$version"
   $current = "$root\current"
   New-Item -ItemType Directory -Force -Path "$root\releases", "$root\staging" | Out-Null
   Expand-Archive -Path "<path to the copied zip>" -DestinationPath $release

   Import-Module WebAdministration
   if (Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue) { Remove-Website -Name 'Default Web Site' }
   if (-not (Test-Path 'IIS:\AppPools\DemoAppPool')) { New-WebAppPool -Name 'DemoAppPool' | Out-Null }
   Set-ItemProperty 'IIS:\AppPools\DemoAppPool' -Name managedRuntimeVersion -Value 'v4.0'
   Set-ItemProperty 'IIS:\AppPools\DemoAppPool' -Name managedPipelineMode -Value 'Integrated'

   # Stop the pool before repointing the junction — IIS keeps the previously
   # loaded assembly resident in the worker process and never notices files
   # changing underneath an already-open junction, so skipping this step
   # would deploy the new bits to disk without ever actually serving them.
   # Skip the stop/swap/start entirely if $current already points at
   # $release (redeploying the same version must not bounce the site).
   $needsSwap = -not ((Test-Path $current) -and (@((Get-Item $current).Target) -contains $release))
   if ($needsSwap) {
       if ((Get-Item 'IIS:\AppPools\DemoAppPool').state -ne 'Stopped') {
           Stop-WebAppPool -Name 'DemoAppPool'
           $deadline = (Get-Date).AddSeconds(30)
           while ((Get-Item 'IIS:\AppPools\DemoAppPool').state -ne 'Stopped') {
               if ((Get-Date) -gt $deadline) { throw 'timed out waiting for DemoAppPool to stop' }
               Start-Sleep -Milliseconds 500
           }
       }
       if (Test-Path $current) { cmd /c rmdir "$current" | Out-Null }
       New-Item -ItemType Junction -Path $current -Target $release | Out-Null
       Start-WebAppPool -Name 'DemoAppPool'
   }

   if (-not (Get-Website -Name 'DemoApp' -ErrorAction SilentlyContinue)) {
       New-Website -Name 'DemoApp' -Port 80 -PhysicalPath $current -ApplicationPool 'DemoAppPool' | Out-Null
   }
   if ((Get-Website -Name 'DemoApp').State -ne 'Started') { Start-Website -Name 'DemoApp' }
   ```
6. From your workstation, browse/curl `http://winapp-poc.eastus.cloudapp.azure.com/health`
   and `/version` (verification commands below).

Path (a) does not need Nexus at all (HLD §11.3: "The manual deploy does not
need Nexus") — the zip travels over the RDP session directly.

## Path (b): `manual-deploy.sh` (what was actually run)

`infra/scripts/manual/manual-deploy.sh` (workstation) drives
`infra/scripts/manual/manual-deploy.ps1` (runs on the VM via
`az vm run-command`). It does not need RDP or an interactive session on the
VM. Steps, in order:

1. Find the latest successful `ci.yml` run on `poc/implementation`
   (`gh run list ... --status success --limit 1`) and download its
   `demoapp-package` artifact to a temp dir.
2. Parse `<version>` and `<sha7>` out of the zip's filename
   (`DemoApp-<version>-<sha7>.zip`) and re-hash the zip locally, checking it
   against the downloaded `.sha256` sidecar before trusting either.
3. Read `nexus-deployer-password` from Key Vault and upload the zip and its
   `.sha256` to `demoapp-releases/demoapp/<version>/` in Nexus as
   `svc-gh-deployer`.
   - **Idempotent re-run behavior:** Nexus's `demoapp-releases` repo has
     write policy `ALLOW_ONCE`, so re-uploading a path that already has
     content returns **HTTP 409** (not a network/auth error). On a 409 the
     script fetches the *remote* `.sha256` sidecar and compares its content,
     byte-for-byte, against the local one:
     - **match** → this exact version was already uploaded (most likely by
       an earlier, successful run of this same script) — log and skip the
       upload, proceed to the deploy step using the existing Nexus object.
     - **mismatch, or the sidecar is missing/unreadable** → hard failure
       (`exit 1`). This is deliberately conservative: `ALLOW_ONCE` means the
       zip itself can never be silently overwritten, so a mismatch here means
       something inconsistent is already sitting at that path and a human
       needs to look at it (e.g. deploy a differently-numbered version
       instead) rather than have the script guess.
   - Any other status (not 201, not 409) is a hard failure.
4. Checks `vm-winapp-01`'s power state and starts it if the daily
   auto-shutdown deallocated it.
5. Runs `manual-deploy.ps1` on the VM via
   `az vm run-command invoke --command-id RunPowerShellScript --scripts
   @infra/scripts/manual/manual-deploy.ps1 --parameters ArtifactUrl=... Version=...
   Sha256=... KeyVaultName=...`. The script is idempotent (it only
   `Expand-Archive`s if the release folder doesn't already exist, only
   creates the app pool/site if missing) and, when the target release is
   actually **changing**, stops `DemoAppPool` (waiting, bounded to ~30s,
   until it reports `Stopped`), repoints the `current` junction, then starts
   the pool again before ensuring the site is started — this recycle is
   required because IIS/ASP.NET keeps the previously-deployed assembly
   resident in the running worker process and never notices the on-disk
   swap underneath an already-open junction, so without it a new version
   would sit on disk correctly but simply never be served. When the target
   release is **unchanged** (a same-version re-run), the script skips the
   stop/swap/start sequence entirely — it never touches the pool or site —
   so redeploying the same version twice in a row does not bounce anything.
   `manual-deploy.ps1` fetches the **reader** password
   (`nexus-reader-password`) itself, straight from Key Vault using the VM's
   own managed identity token — the deployer password never leaves the
   workstation, and the run-command parameters passed by `manual-deploy.sh`
   carry no secret (`ArtifactUrl`, `Version`, `Sha256`, `KeyVaultName` are
   all non-sensitive), so the run-command message/output captured by `az`
   (and printed by the script) never contains a password.
6. Curls `/health` and `/version` on the app URL and fails (`exit 1`) if
   `/version`'s `version` field doesn't equal the version just deployed.

Every `az` call in the script is wrapped in `with_timeout` (120s for reads,
600s for `az vm start`, 900s for the run-command invoke, matching the
"`Expand-Archive` plus IIS setup can take minutes" guidance) so a network
stall fails loudly instead of hanging forever — see "Operational notes"
below for a caveat found while producing this runbook's evidence.

Usage:
```bash
bash infra/scripts/manual/manual-deploy.sh
```

## Verification commands (D1/D2)

```bash
curl -s http://winapp-poc.eastus.cloudapp.azure.com/health     # {"status":"ok"}
curl -s http://winapp-poc.eastus.cloudapp.azure.com/version    # {"version":"1.0.<n>","gitSha":"<sha7>"}
curl -s http://winapp-poc.eastus.cloudapp.azure.com/ | grep -o 'Version [^<]*'
```

## Evidence captured (this task's actual run)

- Date: 2026-09-28, ~12:54–12:57 UTC.
- CI run: `36424042152` (head `5a8a31c6668b8d927907d1540abefb3b7f88c821`,
  the current `poc/implementation` HEAD).
- Artifact: `DemoApp-1.0.13-5a8a31c.zip`, sha256
  `1aee7eeded5f5df121f5e55ba724b937b2e4c455a286ef6fde816bdad9f53cb0`
  (matches the CI-produced `.sha256` sidecar and the hash re-verified
  locally before upload and again on the VM by `manual-deploy.ps1`).
- Nexus path: `demoapp-releases/demoapp/1.0.13/DemoApp-1.0.13-5a8a31c.zip`
  (+ `.sha256`), uploaded 201 on the first run.

First run (fresh upload):
```
[12:54:00] looking up latest successful ci.yml run on poc/implementation
[12:54:01] using run 36424042152 (head 5a8a31c6668b8d927907d1540abefb3b7f88c821)
[12:54:09] artifact DemoApp-1.0.13-5a8a31c.zip -> version=1.0.13 git_sha=5a8a31c
[12:54:12] uploading demoapp/1.0.13/DemoApp-1.0.13-5a8a31c.zip to Nexus
[12:54:17] uploaded demoapp/1.0.13/DemoApp-1.0.13-5a8a31c.zip
[12:54:18] uploaded demoapp/1.0.13/DemoApp-1.0.13-5a8a31c.zip.sha256
[12:54:19] running manual-deploy.ps1 on vm-winapp-01 via az vm run-command
[12:55:23] run-command result:
manual deploy ok 1.0.13
[12:55:23] verifying http://winapp-poc.eastus.cloudapp.azure.com
health: {"status":"ok"}
version: {"version":"1.0.13","gitSha":"5a8a31c"}
home: Version 1.0.13 (5a8a31c)
[12:55:31] manual deploy verified: 1.0.13 is live at http://winapp-poc.eastus.cloudapp.azure.com
```

Second run, immediately after, same version, unchanged Nexus/VM state
(idempotency proof — required by this task):
```
[12:55:38] looking up latest successful ci.yml run on poc/implementation
[12:55:39] using run 36424042152 (head 5a8a31c6668b8d927907d1540abefb3b7f88c821)
[12:55:47] artifact DemoApp-1.0.13-5a8a31c.zip -> version=1.0.13 git_sha=5a8a31c
[12:55:51] uploading demoapp/1.0.13/DemoApp-1.0.13-5a8a31c.zip to Nexus
[12:55:56] demoapp/1.0.13/DemoApp-1.0.13-5a8a31c.zip already exists in Nexus (409, ALLOW_ONCE) — checking remote .sha256 for a safe re-run
[12:55:57] remote .sha256 matches local — version already deployed to Nexus, skipping upload
[12:55:58] running manual-deploy.ps1 on vm-winapp-01 via az vm run-command
[12:57:04] run-command result:
manual deploy ok 1.0.13
[12:57:04] verifying http://winapp-poc.eastus.cloudapp.azure.com
health: {"status":"ok"}
version: {"version":"1.0.13","gitSha":"5a8a31c"}
home: Version 1.0.13 (5a8a31c)
[12:57:05] manual deploy verified: 1.0.13 is live at http://winapp-poc.eastus.cloudapp.azure.com
```

Independent curl check (outside the script, same result):
```
$ curl -s http://winapp-poc.eastus.cloudapp.azure.com/health
{"status":"ok"}
$ curl -s http://winapp-poc.eastus.cloudapp.azure.com/version
{"version":"1.0.13","gitSha":"5a8a31c"}
$ curl -s http://winapp-poc.eastus.cloudapp.azure.com/ | grep -o 'Version [^<]*'
Version 1.0.13 (5a8a31c)
$ curl -s -o /dev/null -w '%{http_code}\n' http://winapp-poc.eastus.cloudapp.azure.com/
200
```

IIS state on the VM (`Get-Website` / app pool / junction / releases dir, via
`az vm run-command`, read-only):
```
--- Get-Website ---
name    state   physicalPath               id
----    -----   ------------               --
DemoApp Started C:\inetpub\demoapp\current  1

--- IIS:\AppPools ---
name              state
----              -----
.NET v4.5         Started
.NET v4.5 Classic Started
DefaultAppPool    Started
DemoAppPool       Started

--- DemoAppPool detail ---
name=DemoAppPool state=Started
managedRuntimeVersion=v4.0 managedPipelineMode=Integrated

--- current junction ---
FullName : C:\inetpub\demoapp\current
LinkType : Junction
Target   : {C:\inetpub\demoapp\releases\1.0.13}

--- releases dir ---
Name
----
1.0.13

--- Default Web Site present? ---
False
```
Confirms: `Default Web Site` is gone, `DemoApp` is the only site (port 80,
physical path `current`), `DemoAppPool` exists with the required .NET 4.0 /
Integrated-pipeline settings, and `current` is a junction pointing at
`releases\1.0.13` — exactly the state Task 8's role must be able to take
over from.

No secret value (Nexus deployer/reader password, VM admin password) was
printed to stdout, a log, or this runbook at any point; only step names,
public hostnames, version strings, hashes and HTTP status/JSON bodies
appear above.

## Operational notes

- **`with_timeout` and orphaned `az` child processes.** While gathering the
  IIS evidence above, an ad hoc read-only diagnostic `az vm run-command
  invoke` (not part of either script, just extra verification for this
  runbook) stalled past its 180s `with_timeout` bound and kept running for
  over 30 minutes. Root cause, confirmed via `ps`: on this workstation,
  `/opt/homebrew/bin/az` is a bash launcher that **forks** (rather than
  `exec`s) the real `python3 -m azure.cli` process. `with_timeout`'s
  `perl -e 'alarm shift; exec @ARGV'` correctly delivered `SIGALRM` and
  killed the bash launcher at the 180s mark, but the orphaned Python child
  had already inherited the command-substitution's stdout pipe and kept it
  open while it sat on a stalled network read — so the calling shell's
  `out="$(with_timeout ...)"` kept waiting for that pipe to close and never
  saw the timeout. The fix in the moment was to `ps` for the leaked
  `azure.cli` process and `kill -9` it directly, then retry (the retry
  completed in a few seconds — consistent with Task 4/5's prior observation
  that these are transient client-side network stalls, not systemic
  failures). Neither `manual-deploy.sh` nor `manual-deploy.ps1` hit this in
  either full run recorded above (both `az vm run-command invoke` calls for
  the actual deploy completed in ~64–66s, well inside the 900s bound). This
  is noted here, not fixed in `lib.sh`, because it's outside this task's
  scope and only ever manifested on an ad hoc diagnostic call outside the
  deliverable scripts; if a future task hits a genuinely silent hang past a
  `with_timeout` bound, check for a leaked `python3 -m azure.cli` process
  with the same PPID pattern before assuming the timeout helper itself is
  broken.
- The repository is public: never commit or paste a secret value from Key
  Vault (`vm-admin-password`, `nexus-deployer-password`,
  `nexus-reader-password`) into a script, a commit, a log file, or this
  runbook.
