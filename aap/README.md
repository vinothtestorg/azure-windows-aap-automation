# AAP configuration as code

Configures the Ansible Automation Platform (AAP 2.7 gateway / controller
4.8) objects the PoC needs for CI/CD: organization, team, user, Azure and
machine credentials, project, inventory + inventory source, and the
`winapp-ping` job template. Task 8 will extend `configure.yml` with
`deploy`-tagged tasks and a `winapp-deploy` job template.

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
ansible-playbook aap/configure.yml -e aap_project_branch=poc/implementation
ansible-playbook aap/verify.yml
```

`aap_project_branch` defaults to `main`; it is pinned to `poc/implementation`
during PoC development so the AAP project syncs this branch. Both playbooks
are idempotent — a second `configure.yml` run reports `changed=0`.

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

`aap/verify.yml` re-syncs the inventory source, asserts `windows_web`
contains exactly `vm-winapp-01`, launches `winapp-ping`, and asserts it
succeeds.

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
