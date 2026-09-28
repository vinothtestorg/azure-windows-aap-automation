# azure-windows-aap-automation

CI/CD for a .NET Framework 4.7.2 app on an Azure Windows VM, deployed by the Ansible Automation Platform from GitHub Actions.

- Design: [docs/HLD.md](docs/HLD.md) (see [§15.1](docs/HLD.md#151-as-built-2026-09-28) for as-built deviations from the design)
- Requirement: [requirement/requirement.md](requirement/requirement.md)
- Runbooks: [first manual deployment](docs/runbooks/manual-deploy.md) · [validation (V1–V9)](docs/runbooks/validation.md) · [teardown](docs/runbooks/teardown.md)

## Quick start (PoC)

1. **Deploy the infrastructure** - resource group, both VMs, Key Vault, Nexus, identities and RBAC (Bicep):
   ```bash
   source infra/scripts/lib.sh
   require_az_login
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
