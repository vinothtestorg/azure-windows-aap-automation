# Runbook: PoC teardown (P7)

Scope: fully decommission the Azure Windows AAP PoC once it's no longer
needed (HLD [§15](../HLD.md#15-delivery-phases), phase P7). **Not executed
as part of Task 10** - this is a runbook only. Run each step in order; later
steps depend on values read in earlier ones. Nothing here prints a secret
value.

Resources being removed:

- Resource group `rg-winapp-poc` (both VMs, both public IPs, both NSGs, the
  VNet, `id-gh-deployer`, and Key Vault `kv-winapp-poc-afppbe` - Key Vault
  soft-delete means the vault itself survives the resource group delete in a
  recoverable, deleted state until purged).
- Entra app registration and service principal `sp-aap-poc`.
- The AAP sandbox objects this PoC created (org, team, user, credentials,
  project, inventory, job templates) live only in the AAP Developer
  Sandbox and are not deleted here - the sandbox itself expires 30 days
  after creation (HLD risk K5). Only the long-lived tokens (below) are
  revoked explicitly.
- The GitHub `poc` deployment environment (its variables and the
  `TOWER_OAUTH_TOKEN` secret).
- The local SSH keypair used to bootstrap `vm-nexus-01`.

## 1. Revoke AAP tokens

Revoke the `TOWER_OAUTH_TOKEN` currently stored in the GitHub `poc`
environment (minted as `svc-github-cd`) and your own local admin token from
`.env.aap`, so neither can be used after the sandbox is gone from your
workstation's perspective.

```bash
set -a; . ./.env.aap; set +a

# Find and revoke the svc-github-cd token (mint one first only if you don't
# already know its id - listing tokens requires the token owner or an admin).
curl -sS --connect-timeout 15 --max-time 30 -H "Authorization: Bearer $TOWER_OAUTH_TOKEN" \
  "${TOWER_HOST%/}/api/gateway/v1/tokens/?user__username=svc-github-cd" | jq '.results[].id'
# For each id printed above:
curl -sS --connect-timeout 15 --max-time 30 -H "Authorization: Bearer $TOWER_OAUTH_TOKEN" \
  -X DELETE "${TOWER_HOST%/}/api/gateway/v1/tokens/<id>/"   # expect 204

# Revoke your own local admin token (the one in .env.aap) last, since the
# calls above use it:
curl -sS --connect-timeout 15 --max-time 30 -u "<admin-user>:<admin-password>" \
  -X DELETE "${TOWER_HOST%/}/api/gateway/v1/tokens/<your-token-id>/"   # expect 204
```

## 2. Delete the GitHub `poc` environment

Removes its variables and the `TOWER_OAUTH_TOKEN` secret in one call.

```bash
gh api -X DELETE "repos/vinothtestorg/azure-windows-aap-automation/environments/poc"
```

## 3. Delete the Azure resource group

```bash
source infra/scripts/lib.sh
require_az_login
with_timeout 1800 az group delete -n rg-winapp-poc --yes
```

This is the long step (both VMs, disks, NICs, public IPs, NSGs, VNet, the
UAMI and its federated credential, and the Key Vault). Azure soft-deletes
the Key Vault rather than purging it immediately - it survives this step in
a `Deleted` (recoverable) state for the vault's retention period.

## 4. Purge the soft-deleted Key Vault

```bash
source infra/scripts/lib.sh
require_az_login
with_timeout 120 az keyvault purge -n kv-winapp-poc-afppbe --location eastus
```

Confirm no other `kv-winapp-poc-*` vaults are left soft-deleted from an
earlier deploy attempt: `az keyvault list-deleted --query
"[?starts_with(name,'kv-winapp-poc')].name"`.

## 5. Delete the SP app registration

```bash
appId="$(az ad sp list --display-name sp-aap-poc --query '[0].appId' -o tsv)"
az ad app delete --id "$appId"
```

`az ad app delete` removes both the app registration and its associated
service principal.

## 6. Remove the local Nexus SSH keypair

```bash
rm -f ~/.ssh/winapp_poc_nexus ~/.ssh/winapp_poc_nexus.pub
```

Also drop any `known_hosts` entry for the Nexus VM's DNS name/IP if you want
a fully clean workstation:

```bash
ssh-keygen -R nexus-winapp-poc.eastus.cloudapp.azure.com
```

## 7. Local workspace hygiene (optional)

```bash
rm -f .env.aap    # gitignored, but it holds a live-until-revoked admin token until step 1 runs
```

## Verification

- `az group show -n rg-winapp-poc` → `ResourceGroupNotFound`.
- `az keyvault list-deleted --query "[?starts_with(name,'kv-winapp-poc')]"` → empty.
- `az ad sp list --display-name sp-aap-poc --query '[0].appId'` → empty.
- `gh api repos/vinothtestorg/azure-windows-aap-automation/environments/poc` → 404.
- Both AAP tokens return 401 if reused.
- `winapp-poc.eastus.cloudapp.azure.com` and
  `nexus-winapp-poc.eastus.cloudapp.azure.com` no longer resolve/respond.
