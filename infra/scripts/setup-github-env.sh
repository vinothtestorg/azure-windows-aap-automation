#!/usr/bin/env bash
# Idempotently configures the GitHub `poc` deployment environment that
# cd.yml runs against: ensures the environment and its main-only branch
# policy, sets the non-secret variables cd.yml reads via `vars.*`, and
# mints the TOWER_OAUTH_TOKEN secret (only when missing, or when --rotate
# is passed) by authenticating to the AAP gateway as svc-github-cd.
# Usage: setup-github-env.sh [--rotate]
# Never prints a secret value or a minted token: only secret/variable
# *names*, and the values of the non-secret variables.
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"

set -a
# shellcheck source=/dev/null
source "$REPO_ROOT/.env.aap"
set +a

readonly REPO="vinothtestorg/azure-windows-aap-automation"
readonly ENV_NAME="poc"

rotate=false
[[ "${1:-}" == "--rotate" ]] && rotate=true

require_az_login

# --- 1. Environment (PUT is idempotent: creates on first run, no-ops after) ---
log "ensuring GitHub environment '$ENV_NAME' exists"
echo '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
  | with_timeout 30 gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input - >/dev/null

# --- 2. Branch policy: main ---
log "ensuring branch policy: main"
existing_policies="$(with_timeout 30 gh api "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" --jq '.branch_policies[].name' 2>/dev/null || true)"
if grep -qx "main" <<<"$existing_policies"; then
  log "branch policy 'main' already present"
else
  with_timeout 30 gh api -X POST "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" -f name=main -f type=branch >/dev/null
  log "added branch policy: main"
fi

# --- 3. Variables ---
kv="$(kv_name)"
tenant_id="$(with_timeout 30 az account show --query tenantId -o tsv)"
subscription_id="$(with_timeout 30 az account show --query id -o tsv)"
client_id="$(with_timeout 60 az identity show -g rg-winapp-poc -n id-gh-deployer --query clientId -o tsv)"

VAR_NAMES=()
VAR_VALUES=()
set_var() {
  local var_name="$1" var_value="$2"
  with_timeout 30 gh variable set "$var_name" --env "$ENV_NAME" --body "$var_value" -R "$REPO" >/dev/null
  VAR_NAMES+=("$var_name")
  VAR_VALUES+=("$var_value")
}

log "setting variables"
set_var AZURE_CLIENT_ID "$client_id"
set_var AZURE_TENANT_ID "$tenant_id"
set_var AZURE_SUBSCRIPTION_ID "$subscription_id"
set_var KEY_VAULT_NAME "$kv"
set_var NEXUS_URL "https://nexus-winapp-poc.eastus.cloudapp.azure.com"
set_var NEXUS_REPOSITORY "demoapp-releases"
set_var TOWER_HOST "$TOWER_HOST"
set_var AWXKIT_API_BASE_PATH "$AWXKIT_API_BASE_PATH"
set_var AAP_JOB_TEMPLATE "winapp-deploy"

# --- 4. Secret: TOWER_OAUTH_TOKEN (minted only when missing, or --rotate) ---
log "checking TOWER_OAUTH_TOKEN secret"
have_secret="$(with_timeout 30 gh secret list --env "$ENV_NAME" -R "$REPO" --json name --jq '.[] | select(.name=="TOWER_OAUTH_TOKEN") | .name' 2>/dev/null || true)"

secret_status="unchanged (already set; pass --rotate to mint a new one)"
if [[ -z "$have_secret" || "$rotate" == true ]]; then
  log "minting TOWER_OAUTH_TOKEN as svc-github-cd via the gateway"
  cd_pw="$(with_timeout 60 az keyvault secret show --vault-name "$kv" -n aap-svc-github-cd-password --query value -o tsv)"
  token_resp="$(curl -sS --connect-timeout 15 --max-time 30 --fail-with-body \
    -u "svc-github-cd:$cd_pw" -H 'Content-Type: application/json' \
    -X POST "${TOWER_HOST%/}/api/gateway/v1/tokens/" \
    -d '{"description":"github-actions-cd","scope":"write"}')"
  unset cd_pw
  token="$(jq -r '.token // empty' <<<"$token_resp")"
  unset token_resp
  [[ -n "$token" ]] || { echo "failed to mint TOWER_OAUTH_TOKEN: gateway response had no token" >&2; exit 1; }
  printf '%s' "$token" | with_timeout 30 gh secret set TOWER_OAUTH_TOKEN --env "$ENV_NAME" -R "$REPO"
  unset token
  secret_status="minted just now"
else
  log "TOWER_OAUTH_TOKEN already set; pass --rotate to mint a new one"
fi

echo
echo "poc environment configured ($REPO):"
printf '  %-24s %s\n' "NAME" "VALUE"
for i in "${!VAR_NAMES[@]}"; do
  printf '  %-24s %s\n' "${VAR_NAMES[$i]}" "${VAR_VALUES[$i]}"
done
printf '  %-24s %s\n' "TOWER_OAUTH_TOKEN (secret)" "$secret_status"
