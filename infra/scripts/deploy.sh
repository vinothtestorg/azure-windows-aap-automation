#!/usr/bin/env bash
# Idempotent PoC infrastructure deployment. Usage: deploy.sh [--foundation-only]
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
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
