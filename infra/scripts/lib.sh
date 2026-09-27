#!/usr/bin/env bash
# Shared helpers for PoC infra scripts. Source, do not execute.
set -euo pipefail

readonly SUBSCRIPTION_ID="03b6c75f-a3f1-429f-ab89-0f9b07087638"
readonly RESOURCE_GROUP="rg-winapp-poc"
readonly LOCATION="eastus"
readonly DEPLOYMENT_NAME="main"
REPO_ROOT="$(git rev-parse --show-toplevel)"
readonly REPO_ROOT

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

require_az_login() {
  az account show --query id -o tsv >/dev/null 2>&1 || { log "run 'az login' first"; exit 1; }
  az account set --subscription "$SUBSCRIPTION_ID"
}

kv_name() {
  az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" \
    --query properties.outputs.keyVaultName.value -o tsv
}

# 28 random alphanumerics + fixed "Aa1_" suffix: satisfies Windows complexity,
# contains no characters that need shell or PowerShell quoting.
gen_password() {
  local body
  body="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 28)"
  printf '%sAa1_' "$body"
}
