# AAP configuration as code

Configures the Ansible Automation Platform (AAP 2.7 gateway / controller
4.8) objects the PoC needs for CI/CD: organization, team, user, Azure and
machine credentials, project, inventory + inventory source, and the
`winapp-ping` and `winapp-deploy` job templates.

## Prerequisites

- `.env.aap` in the repo root (git-ignored, never committed) with:
  - `TOWER_HOST` — the gateway URL (all API calls go through the gateway;
    `AWXKIT_API_BASE_PATH=/api/controller/` matches what the
    `ansible.controller` collection already uses by default for controller
    endpoints, so no extra path config is needed).
  - `TOWER_OAUTH_TOKEN` — a token for the sandbox admin superuser. **Local
    use only** — this and every other value in `.env.aap` must never be
    printed, logged, or committed.
  - `AUTOMATION_HUB_TOKEN` — the Automation Hub token, stored under this
    name (not `ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN`, which is what
    `ansible.cfg`'s `[galaxy_server.automation_hub]` section actually reads).
    Map it at run time — do not rename anything in `.env.aap`:
    ```bash
    set -a; . ./.env.aap; set +a
    export ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN="$AUTOMATION_HUB_TOKEN"
    ```
- `az login` with access to subscription `03b6c75f-a3f1-429f-ab89-0f9b07087638`
  (used to read the Key Vault name and secrets at apply time).
- Run every command from the **repo root** — `aap/configure.yml` and
  `aap/verify.yml` shell out to `infra/scripts/lib.sh` with a relative path.

## Install the collections

```bash
set -a; . ./.env.aap; set +a
export ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN="$AUTOMATION_HUB_TOKEN"
ansible-galaxy collection install -r ansible/collections/requirements.yml
```

Installs the certified `ansible.platform` (gateway) and `ansible.controller`
(controller) collections from Automation Hub, plus `ansible.windows` and
`azure.azcollection`.

## Run

```bash
set -a; . ./.env.aap; set +a
ansible-playbook aap/configure.yml
ansible-playbook aap/verify.yml
```

`aap_project_branch` (`aap/vars/poc.yml`) defaults to `main`, matching the
AAP project's actual SCM branch — the default run above needs no override.
Pass `-e aap_project_branch=<branch>` only as a **development aid**, to
point the AAP project at a task branch temporarily before it merges; do not
leave a run pinned to a branch other than `main`, since every other command
in this repo (CD, the validation runbook) assumes AAP is tracking `main`.

Both playbooks are idempotent — a second `configure.yml` run reports
`changed=0`. The `winapp-deploy` job template's creation is preceded by a
forced project sync (`ansible.controller.project_update`, needed so its
playbook path - `ansible/playbooks/deploy.yml` - already resolves in the
project's checked out tree the first time the job template is created);
that task itself always runs but is `changed_when: false`, since refreshing
the project's checkout never changes any configured AAP object's state, so
it does not break the `changed=0` re-run guarantee above.

### Rotating the Azure SP secret

`configure.yml` never pushes a rotated `aap-sp-client-secret` (or the
`svc-github-cd` password) into AAP by default: `update_secrets: false` on
those credentials/user is what keeps a plain re-run `changed=0` instead of
resetting a secret AAP already has correctly. After running
`infra/scripts/create-aap-sp.sh --rotate` (which writes the new secret to
Key Vault only), push it into AAP with:

```bash
ansible-playbook aap/configure.yml -e aap_update_secrets=true
```

See [docs/runbooks/sp-rotation.md](../docs/runbooks/sp-rotation.md) for the
full procedure and verification.

## What it creates

- Organization `winapp-poc`, team `cd-automation`, user `svc-github-cd`
  (non-superuser, `Team Member` role on the team).
- Credentials: `azure-sp-poc` (Microsoft Azure Resource Manager),
  `azure-kv-poc` (Microsoft Azure Key Vault), `win-ansible-svc` (Machine,
  username `ansible_svc`, password wired to the `ansible-svc-password` Key
  Vault secret via a credential input source — never stored in AAP itself).
- Project `azure-windows-aap-automation` (git, `scm_update_on_launch`,
  `scm_clean`, no SCM credential — the repo is public).
- Inventory `azure-windows-poc` with an `azure_rm` inventory source scoped
  to `rg-winapp-poc`, filtered to Windows hosts tagged `app=demoapp` (so
  `vm-nexus-01` never appears), grouped into `windows_web`. Role `Inventory
  Use` granted to `svc-github-cd`.
- Job template `winapp-ping` (playbook `ansible/playbooks/ping.yml`,
  `win-ansible-svc` credential, `ask_limit_on_launch`).
- Job template `winapp-deploy` (playbook `ansible/playbooks/deploy.yml`,
  `win-ansible-svc` credential, `ask_limit_on_launch`, `allow_simultaneous:
  false`, `timeout: 1800`). Its project is force-synced immediately before
  it is created (`ansible.controller.project_update`, `changed_when:
  false`) so `ansible/playbooks/deploy.yml` already resolves in the
  project's checked-out tree the first time the job template is made.
  Role `JobTemplate Execute` on `winapp-deploy` is granted to
  `svc-github-cd` (the only AAP object CD is actually allowed to run).
  - **Survey, not free-form extra_vars.** `winapp-deploy` has
    `ask_variables_on_launch: false` and a `survey_spec` with exactly four
    required text questions — `app_version` (max 32), `artifact_url` (max
    512), `artifact_sha256` (min/max 64), `git_sha` (max 40). AAP accepts
    and passes through only these four keys at launch and silently drops
    any other `extra_vars` key, so a launch-time payload cannot override a
    role default such as `demoapp_allowed_artifact_prefix` or
    `ansible_host`/`ansible_psrp_*` (see HLD finding I1 and
    [docs/runbooks/validation.md](../docs/runbooks/validation.md)'s
    V7-bis). `.github/scripts/aap-launch.sh` and `cd.yml` need no change:
    AAP 2.7 still accepts survey answers as ordinary `extra_vars` in the
    launch POST body, because they match the survey's variable names.
    `ansible/roles/demoapp_deploy/tasks/validate.yml` still re-checks the
    format/prefix of all four values as defence in depth.

`aap/verify.yml` re-syncs the inventory source, asserts `windows_web`
contains exactly `vm-winapp-01`, launches `winapp-ping` and asserts it
succeeds, then (with `--tags deploy`) launches `winapp-deploy` and asserts
its stdout never contains the Nexus reader password.

## How secrets are handled

- The gateway/controller host and token come from `.env.aap` via
  `module_defaults` (`aap_hostname` / `aap_token`, resolved with
  `lookup('ansible.builtin.env', ...)`); they are never written to a file
  or echoed. Both collections' `aap_token` argument is declared `no_log`
  in the module argspec, so it is redacted automatically even without a
  task-level `no_log`.
- Application secrets (the CD user's password, the Azure SP client
  id/secret) are read once per run from Key Vault with `az keyvault secret
  show`, wrapped in `infra/scripts/lib.sh`'s `with_timeout` so a network
  stall can't hang the play, and every task that reads or uses one of
  these values is `no_log: true`.
- The `ansible-svc-password` secret is never read locally at all: it is
  wired to the `win-ansible-svc` Machine credential through a credential
  input source pointing at the `azure-kv-poc` Key Vault credential, so AAP
  resolves it dynamically from Key Vault at job-run time using the
  `azure-sp-poc` service principal's own Key Vault access.
- `.env.aap` and the admin token never leave the workstation — they are
  git-ignored and are only read into the shell environment for the
  duration of a run.
