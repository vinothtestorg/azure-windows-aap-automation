#!/usr/bin/env bash
# First manual deployment (R3): downloads the latest successful demoapp-package
# CI artifact, uploads it to Nexus, runs manual-deploy.ps1 on vm-winapp-01 via
# az vm run-command, then verifies /health and /version. Never prints a secret.
#
# Safe to re-run: if the version's zip already exists in Nexus (write policy
# ALLOW_ONCE returns 409 on a repeat upload of the same path), the upload is
# skipped only when the remote .sha256 sidecar's content matches the local
# one byte-for-byte; any other 409 (missing/mismatched sidecar) is a hard
# failure rather than a silent skip. See docs/runbooks/manual-deploy.md.
#
# Usage: manual-deploy.sh
set -euo pipefail
# shellcheck source=SCRIPTDIR/../lib.sh
source "$(git rev-parse --show-toplevel)/infra/scripts/lib.sh"
cd "$REPO_ROOT"

readonly VM_NAME="vm-winapp-01"
readonly APP_URL="http://winapp-poc.eastus.cloudapp.azure.com"
readonly NEXUS_URL="https://nexus-winapp-poc.eastus.cloudapp.azure.com"
readonly NEXUS_REPO="demoapp-releases"

require_az_login

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# --- 1: find the latest successful ci.yml run on poc/implementation and
# download its demoapp-package artifact --------------------------------
log "looking up latest successful ci.yml run on poc/implementation"
if ! run_json="$(with_timeout 60 gh run list --workflow ci.yml --branch poc/implementation --status success --limit 1 --json databaseId,headSha)"; then
  log "gh run list timed out or failed"
  exit 1
fi
run_id="$(jq -r '.[0].databaseId // empty' <<<"$run_json")"
head_sha="$(jq -r '.[0].headSha // empty' <<<"$run_json")"
if [[ -z "$run_id" ]]; then
  log "no successful ci.yml run found on branch poc/implementation"
  exit 1
fi
log "using run $run_id (head $head_sha)"

if ! with_timeout 180 gh run download "$run_id" -n demoapp-package -D "$work_dir" >/dev/null; then
  log "gh run download timed out or failed"
  exit 1
fi

zip_matches=()
while IFS= read -r -d '' f; do zip_matches+=("$f"); done < <(find "$work_dir" -maxdepth 1 -name 'DemoApp-*.zip' -print0)
[[ "${#zip_matches[@]}" -eq 1 ]] || { log "expected exactly one DemoApp-*.zip in the artifact, found ${#zip_matches[@]}"; exit 1; }
zip_file="${zip_matches[0]}"
sha_file="${zip_file}.sha256"
[[ -f "$sha_file" ]] || { log "missing sidecar: $sha_file"; exit 1; }

zip_name="$(basename "$zip_file")"
# DemoApp-<version>-<sha7>.zip -> version=<version> (sha7 is the trailing
# "-<7 hex chars>" segment; version is everything before it).
stem="${zip_name#DemoApp-}"; stem="${stem%.zip}"
version="${stem%-*}"
sha7="${stem##*-}"
[[ -n "$version" && -n "$sha7" ]] || { log "could not parse version/sha7 from $zip_name"; exit 1; }
log "artifact $zip_name -> version=$version git_sha=$sha7"

local_sha_line="$(cat "$sha_file")"
local_hash="${local_sha_line%% *}"
computed_hash="$(shasum -a 256 "$zip_file" | awk '{print $1}')"
[[ "$computed_hash" == "$local_hash" ]] || { log "downloaded zip does not match its own .sha256 sidecar"; exit 1; }

# --- 2: upload to Nexus with the deployer credentials -------------------
if ! kv="$(kv_name)"; then
  log "timed out or failed reading Key Vault name"
  exit 1
fi
if ! dep_pw="$(with_timeout 120 az keyvault secret show --vault-name "$kv" -n nexus-deployer-password --query value -o tsv)"; then
  log "failed to read secret nexus-deployer-password from Key Vault (timeout or az error)"
  exit 1
fi

zip_path="demoapp/$version/$zip_name"
sha_path="${zip_path}.sha256"
zip_url="$NEXUS_URL/repository/$NEXUS_REPO/$zip_path"
sha_url="$NEXUS_URL/repository/$NEXUS_REPO/$sha_path"

log "uploading $zip_path to Nexus"
# Not --fail-with-body here: a 409 (ALLOW_ONCE conflict) is an expected,
# handled outcome on a re-run, not a hard error, so the status is inspected
# explicitly instead of letting curl turn it into a nonzero exit. Every curl
# below is bounded (--connect-timeout/--max-time) and its own network-level
# failure (not the same thing as a non-2xx HTTP status, which curl without
# --fail still reports as exit 0) is checked explicitly, so a Nexus/app
# network stall fails loudly instead of hanging the script.
if ! zip_status="$(curl -sS --connect-timeout 15 --max-time 300 -o /dev/null -w '%{http_code}' -u "svc-gh-deployer:$dep_pw" --upload-file "$zip_file" "$zip_url")"; then
  log "upload request for $zip_path timed out or failed (network error, not an HTTP status)"
  exit 1
fi
case "$zip_status" in
  201)
    log "uploaded $zip_path"
    if ! sha_status="$(curl -sS --connect-timeout 15 --max-time 300 -o /dev/null -w '%{http_code}' -u "svc-gh-deployer:$dep_pw" --upload-file "$sha_file" "$sha_url")"; then
      log "upload request for $sha_path timed out or failed (network error, not an HTTP status)"
      exit 1
    fi
    [[ "$sha_status" == "201" ]] || { log "unexpected status $sha_status uploading $sha_path"; exit 1; }
    log "uploaded $sha_path"
    ;;
  409)
    log "$zip_path already exists in Nexus (409, ALLOW_ONCE) — checking remote .sha256 for a safe re-run"
    if ! remote_sha_body="$(curl -sS --connect-timeout 15 --max-time 30 -u "svc-gh-deployer:$dep_pw" "$sha_url")"; then
      log "request for remote $sha_path timed out or failed (network error) — cannot verify a safe re-run"
      exit 1
    fi
    if [[ "$remote_sha_body" == "$local_sha_line" ]]; then
      log "remote .sha256 matches local — version already deployed to Nexus, skipping upload"
    else
      log "remote .sha256 does not match local (or is missing) for $sha_path — refusing to proceed"
      exit 1
    fi
    ;;
  *)
    log "unexpected status $zip_status uploading $zip_path"
    exit 1
    ;;
esac

# --- 3: make sure the VM is running (daily auto-shutdown at 18:00 UTC) --
if ! power="$(with_timeout 120 az vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM_NAME" --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv)"; then
  log "failed to read power state of $VM_NAME (timeout or az error)"
  exit 1
fi
if [[ "$power" != "VM running" ]]; then
  log "$VM_NAME is $power — starting it"
  if ! with_timeout 600 az vm start -g "$RESOURCE_GROUP" -n "$VM_NAME" --output none; then
    log "failed to start $VM_NAME (timeout or az error)"
    exit 1
  fi
fi

# --- 4: run manual-deploy.ps1 on the VM ----------------------------------
log "running manual-deploy.ps1 on $VM_NAME via az vm run-command"
if ! run_out="$(with_timeout 900 az vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" \
  --command-id RunPowerShellScript --scripts @infra/scripts/manual/manual-deploy.ps1 \
  --parameters "ArtifactUrl=$zip_url" "Version=$version" "Sha256=$local_hash" "KeyVaultName=$kv" \
  --query 'value[0].message' -o tsv)"; then
  log "run-command timed out or failed"
  exit 1
fi
# The message is the script's own stdout/stderr; it never contains the Nexus
# reader password (the VM fetches it from Key Vault directly and never
# echoes it — see manual-deploy.ps1).
log "run-command result:"
printf '%s\n' "$run_out"

# --- 5: verify ------------------------------------------------------------
log "verifying $APP_URL"
if ! health="$(curl -sS --connect-timeout 15 --max-time 30 "$APP_URL/health")"; then
  log "GET $APP_URL/health timed out or failed"
  exit 1
fi
echo "health: $health"
if ! version_body="$(curl -sS --connect-timeout 15 --max-time 30 "$APP_URL/version")"; then
  log "GET $APP_URL/version timed out or failed"
  exit 1
fi
echo "version: $version_body"
remote_version="$(jq -r '.version' <<<"$version_body")"
if [[ "$remote_version" != "$version" ]]; then
  log "deployed version mismatch: expected $version, /version returned $remote_version"
  exit 1
fi
# Purely informational (the version gate above already decided pass/fail),
# so a failure here is non-fatal — but still bounded, so a stall can't hang
# the script after the real verification has already succeeded.
home_snippet="$(curl -sS --connect-timeout 15 --max-time 30 "$APP_URL/" | grep -o 'Version [^<]*' || true)"
echo "home: $home_snippet"

log "manual deploy verified: $version is live at $APP_URL"
