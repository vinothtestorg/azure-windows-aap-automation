#!/usr/bin/env bash
# Creates (or reuses) the sp-aap-poc service principal for AAP, idempotently.
# Usage: create-aap-sp.sh [--rotate]
# Never prints appId secrets, passwords, or tenant IDs: only "sp-aap-poc appId=<appId>".
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"

rotate=false
[[ "${1:-}" == "--rotate" ]] && rotate=true

kv="$(kv_name)"
rg_scope="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"

appId="$(az ad sp list --display-name sp-aap-poc --query "[0].appId" -o tsv)"
newly_created=false

if [[ -z "$appId" ]]; then
  log "creating service principal sp-aap-poc"
  appId="$(az ad sp create-for-rbac --name sp-aap-poc --role Reader \
    --scopes "$rg_scope" --query appId -o tsv)"
  newly_created=true
fi

need_new_secret=false
if [[ "$newly_created" == true || "$rotate" == true ]]; then
  need_new_secret=true
elif ! az keyvault secret show --vault-name "$kv" --name aap-sp-client-secret >/dev/null 2>&1; then
  need_new_secret=true
fi

if [[ "$need_new_secret" == true ]]; then
  # Fresh credential (create-for-rbac's default expiry is 1 year); reset with an
  # explicit 45-day end date so the expiry is exactly 45 days from today.
  end_date="$(python3 -c 'import datetime;print((datetime.date.today()+datetime.timedelta(days=45)).isoformat())')"
  log "resetting sp-aap-poc credential (end date $end_date)"
  password="$(az ad app credential reset --id "$appId" --end-date "$end_date" --query password -o tsv)"
  az keyvault secret set --vault-name "$kv" --name aap-sp-client-secret --value "$password" --output none
fi

az keyvault secret set --vault-name "$kv" --name aap-sp-client-id --value "$appId" --output none

az role assignment create --assignee "$appId" --role Reader \
  --scope "$rg_scope" --only-show-errors --output none

kv_id="$(az keyvault show -n "$kv" --query id -o tsv)"
az role assignment create --assignee "$appId" --role "Key Vault Secrets User" \
  --scope "$kv_id/secrets/ansible-svc-password" --only-show-errors --output none

echo "sp-aap-poc appId=$appId"
