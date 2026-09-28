#!/usr/bin/env bash
# Verifies Nexus access rules. Exit 0 only when every check passes.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/infra/scripts/lib.sh"
url="https://nexus-winapp-poc.eastus.cloudapp.azure.com"
repo="$url/repository/demoapp-releases"
kv="$(kv_name)"
dep_pw="$(az keyvault secret show --vault-name "$kv" -n nexus-deployer-password --query value -o tsv)"
rd_pw="$(az keyvault secret show --vault-name "$kv" -n nexus-reader-password --query value -o tsv)"
probe="smoke/$(date -u +%Y%m%d%H%M%S)-$RANDOM.txt"
tmp="$(mktemp)"; echo "smoke" > "$tmp"
fails=0
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then echo "PASS $1 ($3)"; else echo "FAIL $1 expected $2 got $3"; fails=$((fails+1)); fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check "status writable"        200 "$(code "$url/service/rest/v1/status/writable")"
check "anonymous read denied"  401 "$(code "$repo/$probe")"
check "reader upload denied"   403 "$(code -u "svc-win-reader:$rd_pw" --upload-file "$tmp" "$repo/$probe")"
check "deployer upload"        201 "$(code -u "svc-gh-deployer:$dep_pw" --upload-file "$tmp" "$repo/$probe")"
check "redeploy rejected"      409 "$(code -u "svc-gh-deployer:$dep_pw" --upload-file "$tmp" "$repo/$probe")"
check "reader download"        200 "$(code -u "svc-win-reader:$rd_pw" "$repo/$probe")"
rm -f "$tmp"
[[ $fails -eq 0 ]] && echo "SMOKE PASS" || { echo "SMOKE FAIL ($fails)"; exit 1; }
