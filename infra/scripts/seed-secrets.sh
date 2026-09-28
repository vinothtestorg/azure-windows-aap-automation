#!/usr/bin/env bash
# Seeds generated secret values into the foundation Key Vault, idempotently.
# Never prints secret values: only "created <name>" or "exists <name>".
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source "$(dirname "$0")/lib.sh"

SECRET_NAMES=(
  vm-admin-password
  ansible-svc-password
  nexus-admin-password
  nexus-deployer-password
  nexus-reader-password
  aap-svc-github-cd-password
)

kv="$(kv_name)"

set_secret_with_retry() {
  local name="$1"
  local value="$2"
  local attempt
  for attempt in $(seq 1 10); do
    if az keyvault secret set --vault-name "$kv" --name "$name" --value "$value" --output none; then
      return 0
    fi
    log "attempt $attempt/10 to set secret $name failed (likely RBAC propagation delay), retrying in 15s"
    sleep 15
  done
  log "failed to set secret $name after 10 attempts"
  return 1
}

for name in "${SECRET_NAMES[@]}"; do
  if az keyvault secret show --vault-name "$kv" --name "$name" >/dev/null 2>&1; then
    echo "exists $name"
  else
    set_secret_with_retry "$name" "$(gen_password)"
    echo "created $name"
  fi
done
