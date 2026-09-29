# azure-windows-aap-automation

CI/CD for a .NET Framework 4.7.2 app on an Azure Windows VM, deployed by the Ansible Automation Platform from GitHub Actions.

- Design: [docs/HLD.md](docs/HLD.md) (see [§15.1](docs/HLD.md#151-as-built-2026-09-28) for as-built deviations from the design)
- Requirement: [requirement/requirement.md](requirement/requirement.md)
- Runbooks: [first manual deployment](docs/runbooks/manual-deploy.md) · [validation (V1–V9)](docs/runbooks/validation.md) · [SP secret rotation](docs/runbooks/sp-rotation.md) · [teardown](docs/runbooks/teardown.md)

## Prerequisites

Install on the admin workstation before running anything below:

- `az` (Azure CLI) with the `bicep` extension (`az bicep install`), logged in
  with `az login` to subscription `03b6c75f-a3f1-429f-ab89-0f9b07087638`.
- `gh` (GitHub CLI), logged in with `gh auth login` (repo, workflow scopes).
- `ansible-core` with the `pypsrp` Python package installed (`pip install
  pypsrp`) - required for the `ansible.windows` collection's PSRP connection
  to the Windows VM.
- `ansible-galaxy collection install -r ansible/collections/requirements.yml`
  - installs `ansible.platform` and `ansible.controller` from the
    certified Automation Hub, plus `ansible.windows` and
    `azure.azcollection`. The Automation Hub token maps like this (its
    variable name in `.env.aap`, `AUTOMATION_HUB_TOKEN`, does not match what
    `ansible.cfg`'s `[galaxy_server.automation_hub]` section reads, so it is
    exported under a different name at run time - never rename anything in
    `.env.aap` itself):
    ```bash
    set -a; . ./.env.aap; set +a
    export ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN="$AUTOMATION_HUB_TOKEN"
    ansible-galaxy collection install -r ansible/collections/requirements.yml
    ```
- `jq` and `bash` (the scripts under `infra/`, `.github/scripts/` and
  `ansible/tests/` are bash-only; run them with `bash`, not `sh` or `zsh -c`
  directly - see the note on `lib.sh` below).

`infra/scripts/lib.sh` is meant to be run with `bash`, not sourced into an
interactive shell: it sets `set -euo pipefail`, which would change your
shell's own error-handling behaviour if left on after sourcing. Every
command below invokes it as `bash -c '...'` for that reason.

## Quick start (PoC)

1. **Deploy the infrastructure** - resource group, both VMs, Key Vault, Nexus, identities and RBAC (Bicep):
   ```bash
   bash infra/scripts/deploy.sh
   ```
2. **Bootstrap Nexus** - admin password rotation, the `demoapp-releases` hosted repo, roles and users:
   ```bash
   bash infra/nexus/bootstrap.sh
   ```
   Run [infra/nexus/tests/smoke.sh](infra/nexus/tests/smoke.sh) to confirm access rules (V8).
3. **Configure AAP as code** - org, team, credentials, project, inventory and job templates:
   ```bash
   set -a; . ./.env.aap; set +a   # TOWER_HOST, TOWER_OAUTH_TOKEN, AWXKIT_API_BASE_PATH, AUTOMATION_HUB_TOKEN
   export ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN="$AUTOMATION_HUB_TOKEN"
   ansible-playbook aap/configure.yml
   ```
   `.env.aap` is untracked (see `.gitignore`) - create it locally with your AAP sandbox's host and tokens.
4. **Set up the GitHub `poc` deployment environment** - variables, branch policy (main only), and mint the CD token:
   ```bash
   bash infra/scripts/setup-github-env.sh
   ```
5. **Push to `main`** - `ci.yml` builds and tests, then `cd.yml` uploads the artifact to Nexus and launches `winapp-deploy` in AAP automatically. A pull request only ever runs the build (V1).

Then see [docs/runbooks/validation.md](docs/runbooks/validation.md) for the
full V1–V9 evidence, and [docs/runbooks/teardown.md](docs/runbooks/teardown.md)
when decommissioning the PoC.
