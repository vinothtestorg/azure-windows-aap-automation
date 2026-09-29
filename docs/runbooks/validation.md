# Runbook: end-to-end validation (V1–V9)

Scope: execute HLD [§12.2](../HLD.md#122-validation-plan-r9)'s validation plan
against the live PoC (`rg-winapp-poc`, gateway
`https://sandbox-aap-vinothkaruppuchamypr-dev.apps.rm3.7wse.p1.openshiftapps.com`,
Nexus `https://nexus-winapp-poc.eastus.cloudapp.azure.com`) and record
evidence. All tests below were run on 2026-09-28/2026-09-29 against `main`
at commit `c5961e1` (app version `1.0.27`) and `poc/implementation`. Every
command that reads a secret prints only its length, a status code, or a
match count - never the value.

## Summary

| ID | Test | Result | Evidence |
|---|---|---|---|
| V1 | Open a PR | **PASS** | [PR #4](https://github.com/vinothtestorg/azure-windows-aap-automation/pull/4), [run 36499211332](https://github.com/vinothtestorg/azure-windows-aap-automation/actions/runs/36499211332) |
| V2 | Merge to `main` | **PASS** | [run 36496295180](https://github.com/vinothtestorg/azure-windows-aap-automation/actions/runs/36496295180), AAP job 21 |
| V3 | Relaunch the same version in AAP | **PASS** | AAP job 27 |
| V4 | Deploy a build where `/health` returns 500 | **PASS** | `ansible/tests/deploy-scenarios.sh unhealthy` |
| V5 | RBAC negative tests | **PASS** | see sub-table below |
| V6 | Launch with a wrong `artifact_sha256` | **PASS** | `ansible/tests/deploy-scenarios.sh bad_checksum` |
| V7 | Launch with an `artifact_url` outside the allowed prefix | **PASS** | `ansible/tests/deploy-scenarios.sh validation` |
| V7-bis | Launch-time extra_vars cannot override role defaults (I1 fix) | **PASS** | AAP jobs 48 (positive), 51 (negative) |
| V8 | Upload the same version to Nexus twice | **PASS** | `infra/nexus/tests/smoke.sh` |
| V9 | Run `winapp-ping` from AAP | **PASS** | AAP job 30 |

**10/10 PASS.**

---

## V1 - Open a PR (build only, no CD)

Date: 2026-09-29. Opened a throwaway PR from a temporary branch
(`poc/v1-readme-typo`, a one-word README fix) targeting `main`.

```
gh pr create --base main --head poc/v1-readme-typo \
  --title "docs: fix missing article in README (V1 throwaway)"
# -> https://github.com/vinothtestorg/azure-windows-aap-automation/pull/4
```

Expected: `ci.yml` builds and tests; `cd` does not run (no Nexus upload, no
AAP job).

Actual - run
[36499211332](https://github.com/vinothtestorg/azure-windows-aap-automation/actions/runs/36499211332)
(triggered by `pull_request`):

```json
{"conclusion":"success","name":"build"}
{"conclusion":"skipped","name":"cd"}
```

`build` succeeded in 1m32s. `cd`'s `if: github.event_name == 'push' &&
github.ref == 'refs/heads/main'` correctly evaluated false for a
`pull_request` event, so the job was skipped entirely (0s) - no Nexus
upload, no AAP job.

Cleanup: `gh pr close 4 -c "Throwaway V1 validation PR - closing without
merging."`, then `git push origin --delete poc/v1-readme-typo` and the local
branch deleted. PR left in the `CLOSED` (not merged) state.

**PASS.**

## V2 - Merge to `main`

Date: 2026-09-28. Evidence is the first successful end-to-end CD run against
`main` after PR #2 and PR #3 were merged and the OIDC federated-credential
subject fix (commit `68d1ccd`, see HLD [§15.1](../HLD.md#151-as-built-2026-09-28))
was applied: run
[36496295180](https://github.com/vinothtestorg/azure-windows-aap-automation/actions/runs/36496295180)
(`head_sha c5961e1`, app version `1.0.27`).

Expected: `build` and `cd / deploy` succeed, the step summary shows the AAP
job URL, and `/version` returns `1.0.27`.

Actual - both jobs and every step succeeded:

```json
{"conclusion":"success","name":"cd / deploy"}
{"conclusion":"success","name":"build"}
```

`cd / deploy` step conclusions (all `success`): Set up job, checkout,
download-artifact, `azure/login@v2`, Read Nexus deployer password, Upload to
Nexus, Launch AAP job template, Summary, both post-steps, Complete job.

From the run log: `job_id=21`,
`job_url=https://sandbox-aap-vinothkaruppuchamypr-dev.apps.rm3.7wse.p1.openshiftapps.com/execution/jobs/playbook/21/output`,
step summary `| Version | 1.0.27 |`, `| Result | success |`.

```
$ curl -s http://winapp-poc.eastus.cloudapp.azure.com/version
{"version":"1.0.27","gitSha":"c5961e1"}
```

**Secret-leak check** (Review Focus 1): downloaded the live
`nexus-deployer-password` value from Key Vault and grepped the full run log
(`gh run view 36496295180 --log`, 521 lines) for it under `bash` (never
`zsh`, to avoid printing it to an interactive shell's history mechanisms):

```
nexus-deployer-password leak count in run log: 0
```

**PASS.**

## V3 - Relaunch the same version in AAP

Date: 2026-09-28, immediately after V2. First, pointed the AAP project back
at `main` (Step 1 of this task - PRs had already merged, so the project only
needed to be re-synced off the override used during earlier manual testing):

```
$ ansible-playbook aap/configure.yml     # no aap_project_branch override -> defaults to main
...
TASK [Ensure project azure-windows-aap-automation exists] **********************
changed: [localhost]
...
PLAY RECAP: localhost : ok=21 changed=1 unreachable=0 failed=0 skipped=0
```

The single `changed=1` is exactly that project task - confirming the branch
flip to `main` took effect (every other AAP object was already up to date).

Then relaunched `winapp-deploy` with the same `1.0.27` launch variables the
CD run used (`artifact_url`, `artifact_sha256` and `git_sha` recovered from
the CI artifact of that run, downloaded via `gh run download 36496295180 -n
demoapp-package`, and independently re-hashed to confirm the sha256):

```
$ bash .github/scripts/aap-launch.sh winapp-deploy v3-vars.json
job_id=27
job_url=https://sandbox-aap-vinothkaruppuchamypr-dev.apps.rm3.7wse.p1.openshiftapps.com/execution/jobs/playbook/27/output
AAP job 27 successful
```

Job 27's stdout confirms no change to `current`:

```
TASK [demoapp_deploy : Check whether this version is already fetched and complete] ***
ok: [vm-winapp-01]
TASK [demoapp_deploy : Download the release artifact from Nexus] ***************
skipping: [vm-winapp-01]
TASK [demoapp_deploy : Checksum the downloaded artifact] ***********************
skipping: [vm-winapp-01]
TASK [demoapp_deploy : Expand the artifact into the release directory] *********
skipping: [vm-winapp-01]
TASK [demoapp_deploy : Switch current to the new release] **********************
ok: [vm-winapp-01]
...
PLAY RECAP: vm-winapp-01 : ok=14 changed=2 unreachable=0 failed=0 skipped=4
```

`ok` (not `changed`) on "Switch current to the new release" means the
junction already pointed at `1.0.27` and was left untouched. Of the two
`changed` tasks, only one is guaranteed on every run: the append-only
`deployments.log` record, written unconditionally. The other is
release-retention pruning, which only reports `changed` when there is a
release directory beyond the keep count to remove (see HLD
[§5.5](../HLD.md#55-ansible-deployment-playbook)) - it happened to be
`changed` here because this same validation session's earlier runs had
already accumulated more than `demoapp_keep_releases` (5) old release
directories on the VM; a `changed=1` outcome here (deployments.log only,
nothing to prune) would be equally correct on a quieter VM. `/version`
confirmed unchanged at `1.0.27` afterward.

**PASS.**

## V4 - Deploy a build where `/health` returns 500

Date: 2026-09-28. `ansible/tests/deploy-scenarios.sh unhealthy` uploads a
freshly repackaged version with a deliberately corrupted `Web.config` (so IIS
serves a 500) and deploys it. Live `/version` at the start of the run was
`1.0.27`, so the script used that as the baseline "should still be serving
this after rollback" version (no `good` scenario was run first in this
invocation):

```
$ bash ansible/tests/deploy-scenarios.sh validation bad_checksum unhealthy no_secret_leak
...
[23:30:53] live /version at start of this run: 1.0.27
PASS validation
[23:31:01] uploaded demoapp/1.0.9972/DemoApp-1.0.9972.zip
PASS bad_checksum
[23:31:52] uploaded demoapp/1.0.9971/DemoApp-1.0.9971.zip
PASS unhealthy
[23:34:31] no_secret_leak: 0 match(es) across 7 captured log(s)
PASS no_secret_leak
[23:34:31] all scenarios PASSED
```

The `unhealthy` scenario internally asserts: (1) `ansible-playbook` exits
non-zero (the health-check task fails the play); (2) live `/version`
afterward still returns the baseline version (`1.0.27`), i.e. `current` was
rolled back; (3) the last line of `C:\inetpub\demoapp\deployments.log`
contains `result=rolled_back`. All three held (scenario reported `PASS`).
Confirmed independently after the run:

```
$ curl -s http://winapp-poc.eastus.cloudapp.azure.com/version
{"version":"1.0.27","gitSha":"c5961e1"}
$ curl -s -o /dev/null -w '%{http_code}\n' http://winapp-poc.eastus.cloudapp.azure.com/health
200
```

**PASS.**

## V5 - RBAC negative tests

Five sub-checks, all against the live environment on 2026-09-28.

| Sub-check | Expected | Actual |
|---|---|---|
| `svc-github-cd` launches/edits outside its role | AAP 403 / invisible | `winapp-ping` invisible (`count=0`); `PATCH job_templates/10/` (winapp-deploy) → **403** `{"detail":"You do not have permission to perform this action."}` |
| Workflow outside environment `poc` calls `azure/login` | Entra token refused | See Entra sub-section below - both variants refused |
| VM MI reads `nexus-deployer-password` | Key Vault 403 | `nexus-reader-password readable length=32`; `nexus-deployer-password denied 403` |
| SP reads any `nexus-*` secret | Key Vault 403 | `sp-aap-poc` → `nexus-deployer-password` **403**; (control) `ansible-svc-password` **200** |
| `svc-win-reader` uploads to Nexus | Nexus 403 | `infra/nexus/tests/smoke.sh`: `PASS reader upload denied (403)` |

### AAP: `svc-github-cd` least privilege

Minted a throwaway `svc-github-cd` gateway token (`POST
/api/gateway/v1/tokens/`, same pattern as `infra/scripts/setup-github-env.sh`),
exercised it, then revoked it:

```
minted token id=5 (length=30)
winapp-ping count=0
winapp-deploy id=10
PATCH status=403
{"detail":"You do not have permission to perform this action."}
revoke(with bearer) status=204
```

### Entra: branch/environment policy and OIDC subject

Pushed a temporary workflow (`.github/workflows/v5-negative.yml`, deleted
afterward) on a temporary branch `poc/v5-negative` (`push` trigger, since
`workflow_dispatch` only works for workflows already on the default branch),
with two jobs that both call `azure/login` using `id-gh-deployer`'s real
(non-secret) client/tenant/subscription IDs:

- `with-environment-poc` (`environment: poc`): GitHub's deployment-branch
  policy for environment `poc` (main only) blocked the job before any step
  ran - the job shows **0 steps** and `conclusion: failure`; the deployment
  record (`id 6723008772`, `ref poc/v5-negative`) transitioned
  `waiting` → `failure`.
- `without-environment` (no `environment:` key): the job ran and
  `azure/login`'s OIDC subject was `repo:vinothtestorg@289159619/azure-windows-aap-automation@1390388831:ref:refs/heads/poc/v5-negative`
  (no `environment:poc` claim, since the job declares no environment). Entra
  rejected the token exchange:
  ```
  ##[error]AADSTS700213: No matching federated identity record found for presented
  assertion subject 'repo:vinothtestorg@289159619/azure-windows-aap-automation@1390388831:ref:refs/heads/poc/v5-negative'.
  ```

Run: [36498957141](https://github.com/vinothtestorg/azure-windows-aap-automation/actions/runs/36498957141)
(`conclusion: failure`, as expected - both jobs were meant to fail).

Cleanup: `git push origin --delete poc/v5-negative` (removes the workflow
file along with the branch) and the local branch deleted.

### VM managed identity: single-secret scope

Ran the MI least-privilege check (`mi-check.ps1`, HLD §11.3's script) via a
bounded `az vm run-command invoke`:

```
nexus-reader-password readable length=32
nexus-deployer-password denied 403
```

### SP: single-secret scope, without `az login`

To avoid disturbing the workstation's own `az` session, the SP's token was
minted with a direct client-credentials `curl` to Entra (never `az login
--service-principal`):

```
curl -d grant_type=client_credentials -d client_id=$client_id -d client_secret=$client_secret \
     -d scope=https%3A%2F%2Fvault.azure.net%2F.default \
     https://login.microsoftonline.com/e31db877-05a5-4e5a-acfe-c0384e23172a/oauth2/v2.0/token
```

```
minted SP token (length=1711)
SP GET nexus-deployer-password status=403
SP GET ansible-svc-password status=200
```

(The 200 on `ansible-svc-password` is a control: it confirms the token is
valid and the SP's Key Vault Secrets User role does work on the one secret
it's actually scoped to - the 403 above is a real deny, not an invalid
token.) Confirmed the workstation's own `az` session was unaffected
afterward (`az account show` still showed the original signed-in user).

### Nexus: `svc-win-reader` cannot upload

Covered by V8's `infra/nexus/tests/smoke.sh` run below: `PASS reader upload
denied (403)`.

**V5: PASS** (5/5 sub-checks).

## V6 - Launch with a wrong `artifact_sha256`

Date: 2026-09-28, `ansible/tests/deploy-scenarios.sh bad_checksum` (part of
the same invocation as V4 above). Uploads a syntactically valid package,
then launches the deploy with a well-formed but wrong SHA-256:

```
[23:31:01] uploaded demoapp/1.0.9972/DemoApp-1.0.9972.zip
PASS bad_checksum
```

The scenario asserts: `ansible-playbook` exits non-zero, the output contains
`checksum mismatch`, and live `/version` is unchanged from the baseline
(`1.0.27`) - i.e. the artifact was downloaded and hashed, the checksum
verification task failed the play, and the switch to the new release never
ran. All held (scenario reported `PASS`).

**PASS.**

## V7 - Launch with an `artifact_url` outside the allowed prefix

Date: 2026-09-28, `ansible/tests/deploy-scenarios.sh validation` (same
invocation). Runs `ansible-playbook ansible/playbooks/deploy.yml --tags
validate` (no host contact) four times, each with different invalid launch
variables, including an `artifact_url` pointing outside the allowed Nexus
prefix and one with a `../` path-traversal attempt against the prefix:

```
PASS validation
```

Each of the four cases exited non-zero with `Invalid launch variables` in
the output, confirmed against no host contact ever being attempted (the
`--tags validate` run only exercises `demoapp_deploy`'s pre-flight `assert`
task).

**PASS.**

## V7-bis - Launch-time extra_vars cannot override role defaults (I1 fix)

Date: 2026-09-29. This wave's I1 fix gave `winapp-deploy` a `survey_spec`
with exactly four required text questions (`app_version` max 32,
`artifact_url` max 512, `artifact_sha256` min/max 64, `git_sha` max 40) and
set `ask_variables_on_launch: false`, so AAP now accepts and passes through
only these four keys at launch and silently drops everything else - closing
the hole where a token holder could pass `demoapp_allowed_artifact_prefix`
(to redirect the `svc-win-reader` Nexus credential to an attacker URL) or
`ansible_host`/`ansible_psrp_*` (to redirect the whole play) as ordinary
`extra_vars`.

**Positive control - the normal path through the survey still works.**
`ansible/tests/deploy-scenarios.sh --prepare-only` uploaded a fresh version
and printed its four values, launched with exactly those four keys via
`.github/scripts/aap-launch.sh` (unchanged - confirms AAP 2.7 still accepts
survey answers as `extra_vars` in the launch POST body even with
`ask_variables_on_launch: false`, because they match survey variable
names):

```
$ bash .github/scripts/aap-launch.sh winapp-deploy v7bis-vars.json
job_id=48
job_url=.../execution/jobs/playbook/48/output
AAP job 48 successful
```

Job 48's recorded `extra_vars` (`GET /api/controller/v2/jobs/48/`) contain
exactly the four keys sent - `app_version`, `artifact_url`,
`artifact_sha256`, `git_sha`.

**Negative control - the override is not honoured.** Same four values for
that now-current version (`1.0.9039`), plus
`demoapp_allowed_artifact_prefix: https://evil.example.com/` and
`artifact_url` repointed at `https://evil.example.com/x.zip`:

```
$ bash .github/scripts/aap-launch.sh winapp-deploy v7bis-negative.json
job_id=51
AAP job 51 finished with status failed

TASK [demoapp_deploy : Validate launch variables] ******************************
fatal: [vm-winapp-01]: FAILED! => {"assertion": "artifact_url.startswith(demoapp_allowed_artifact_prefix)", ...,
"msg": "Invalid launch variables: app_version, artifact_url (must be under
https://nexus-winapp-poc.eastus.cloudapp.azure.com/repository/demoapp-releases/),
artifact_sha256 or git_sha"}
```

The failure message itself proves the role used its own default prefix
(`https://nexus-winapp-poc.eastus.cloudapp.azure.com/repository/demoapp-releases/`),
never the attacker-supplied `https://evil.example.com/` - the override never
reached the play. Confirmed independently from job 51's own recorded
`extra_vars` (`GET /api/controller/v2/jobs/51/`):

```json
{
  "app_version": "1.0.9039",
  "artifact_url": "https://evil.example.com/x.zip",
  "git_sha": "d1ddec8379c4bb7dbd626a8067d72d842f1fa195",
  "artifact_sha256": "d980275ca0c053c1d94d698aaa9149264b14830b49d6e92ad45c29de83ac7156"
}
```

`demoapp_allowed_artifact_prefix` is absent - AAP's survey dropped it before
the job ever launched, exactly as the fix intends. The live site was
unaffected: `/version` still returned `1.0.9039` (job 48's release)
immediately after job 51 failed.

**PASS** (both the positive and negative control).

## V8 - Upload the same version to Nexus twice

Date: 2026-09-29, `infra/nexus/tests/smoke.sh`:

```
PASS status writable (200)
PASS anonymous read denied (401)
PASS reader upload denied (403)
PASS deployer upload (201)
PASS redeploy rejected (409)
PASS reader download (200)
SMOKE PASS
```

`redeploy rejected (409)` uploads the same probe file twice to the same path
as `svc-gh-deployer`: the first upload returns `201 Created`, the immediate
second upload to the identical path returns `409 Conflict` (Nexus's
`ALLOW_ONCE` write policy - see HLD [§15.1](../HLD.md#151-as-built-2026-09-28)
for why this is 409 and not the originally assumed 400). A genuinely new
upload attempt of the same version is still hard-rejected exactly as V8
requires.

Note: this task also made `.github/scripts/nexus-upload.sh` (the CD
pipeline's wrapper, not this raw smoke test) tolerate a 409 when the
*already-uploaded* content is byte-identical to what it would have
uploaded - a reliability fix for a CD "re-run failed jobs" after a later
pipeline step failed, not a change to what V8 is testing. A 409 against
*different* content, or one whose existing `.sha256` sidecar can't be
verified, still fails the wrapper too (see the commit for
`.github/scripts/nexus-upload.sh` and its new test,
`.github/scripts/tests/test-nexus-upload.sh`).

**Upload order (M2 fix, this wave).** `cd.yml`'s "Upload to Nexus" step
now uploads `<package>.sha256` before `<package>.zip`, not after. The zip's
own 409-tolerance check works by fetching `<zip-path>.sha256` and comparing
hashes; if the zip were uploaded first and the workflow then failed before
the sidecar upload ran, a re-run's zip attempt would 409 against Nexus's
`ALLOW_ONCE` policy with no sidecar to compare against - a permanent,
un-recoverable failure, since the zip path can never be overwritten.
Uploading the sidecar first means a re-run can always tell whether a
partially-completed upload from a prior attempt matches its own bytes.
`nexus-upload.sh` itself needed no change: its 409 logic already keys off
the file's own name (`*.sha256` vs not), not upload order.

**Operator note.** Because Nexus's `ALLOW_ONCE` write policy makes every
`<version>` path write-once, always use GitHub Actions' **"Re-run failed
jobs"** (which reuses the same build artifact and the same bytes) to retry
a failed `cd` run, never **"Re-run all jobs"**. A full re-run rebuilds the
package from source under the same `${{ github.run_number }}`-derived
version, producing different bytes (new timestamps inside the zip, etc.)
for the same path - which 409s against whatever was already uploaded and
can never be resolved for that version without cutting a new one.

**PASS.**

## V9 - Run `winapp-ping` from AAP

Date: 2026-09-28.

```
$ bash .github/scripts/aap-launch.sh winapp-ping "{}"
job_id=30
job_url=https://sandbox-aap-vinothkaruppuchamypr-dev.apps.rm3.7wse.p1.openshiftapps.com/execution/jobs/playbook/30/output
AAP job 30 successful
```

**PASS.**

*Note on sandbox stability:* a later, unrelated re-run of
`.github/scripts/tests/test-aap-launch.sh` (done as a regression check after
switching the AAP project to `main`) saw one transient `ping_success`
failure (job 33: `"Task was marked as running at system start up. The
system must have not shut down properly, so it has been marked as failed."`)
- an AAP Developer Sandbox infrastructure hiccup unrelated to any change in
this task (see HLD risk K5: the sandbox's pods can be recycled). An
immediate retry passed cleanly (`all tests PASSED`). V9's own evidence above
(job 30) was captured before this hiccup and is unaffected.

---

## Fix-wave re-validation (I2, M4) - 2026-09-29

I2 (a failed release switch could leave the site down - `switch-release.ps1`
wrapped in try/catch with a best-effort restore) and M4 (fetch.yml: record
the verified checksum in `.complete` and compare it on a relaunch; clean up
an incomplete release directory before renaming onto it; surface a
sanitised message on a Nexus download failure) both touch the deploy role's
happy path and its rescue path, so the full scenario suite - plus a new
`checksum_drift` scenario for M4(a) - was re-run end to end against the
live VM (local `ansible-playbook` runs against the working tree, not
through AAP - the AAP project tracks `main`, so it does not see these
role changes until a future merge):

```
$ bash ansible/tests/deploy-scenarios.sh good idempotent checksum_drift bad_checksum unhealthy first_deploy_failure no_secret_leak
...
PASS good
PASS idempotent
PASS checksum_drift
PASS bad_checksum
PASS unhealthy
PASS first_deploy_failure
[00:55:09] no_secret_leak: 0 match(es) across 9 captured log(s)
PASS no_secret_leak
[00:55:09] all scenarios PASSED
```

`checksum_drift` (new, M4(a)): relaunches the version `good` just deployed,
same `artifact_url`, but a different (still valid-format) `artifact_sha256`
- confirms the play now reads the checksum recorded in `.complete` and
fails with `checksum mismatch` instead of silently reusing the on-disk
release, and that `/version` stays unchanged. `unhealthy` and
`first_deploy_failure` between them exercise `switch-release.ps1`'s normal
switch, and the role's own `block/rescue` calling `rollback.yml` (which
re-invokes the same script with `TargetPath` set) - both still pass,
confirming the I2 try/catch rewrite did not change observable behaviour on
either path. `pwsh` was not available on the admin workstation to run a
standalone parse check on `switch-release.ps1`; this live re-run (which
executes that exact script on the Windows VM via PSRP on every scenario)
is the stronger check in practice - a syntax error would have failed
`good` immediately.

Live site left serving `1.0.9045` (`gitSha d1ddec8`), `/health` → 200,
confirmed after the run.

## Final state

- `vm-winapp-01` serving `1.0.9045` (`gitSha d1ddec8`), `/health` → 200 -
  updated by this fix wave's re-validation above (V1-V9's original
  `1.0.27` evidence, captured 2026-09-28/29, is unchanged and still holds).
- AAP project `azure-windows-aap-automation` points at `main`.
- All temporary branches, PRs, workflow files and tokens created for the
  original validation run have been cleaned up (see the Task 10 report's
  Cleanup section for the full list). This fix wave created no new
  branches or PRs; it used disposable Nexus versions (`1.0.90xx`, evicted
  by retention over time) and two throwaway `winapp-deploy` AAP job
  launches (48, 51 - see V7-bis).
