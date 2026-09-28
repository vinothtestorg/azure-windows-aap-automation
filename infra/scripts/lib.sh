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

# with_timeout SECONDS CMD [ARGS...]: runs CMD under a hard wall-clock
# timeout (macOS ships no `timeout` binary, so this uses perl's alarm(),
# which delivers SIGALRM to the exec'd command after SECONDS). On a timeout
# (exit code 142 = 128 + SIGALRM) it logs a clear message to stderr and
# returns non-zero; any other exit code (success or a genuine command
# failure) is passed through unchanged so callers can tell the two apart.
# Callers must check the return status explicitly (e.g. `if ! out="$(with_timeout ...)"; then ...; fi`)
# rather than relying on `set -e`, since a failed command substitution
# assignment alone does not trigger it.
with_timeout() {
  local secs="$1"; shift
  local status=0
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@" || status=$?
  if [[ "$status" -eq 142 ]]; then
    log "timed out after ${secs}s: $*"
  fi
  return "$status"
}

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
