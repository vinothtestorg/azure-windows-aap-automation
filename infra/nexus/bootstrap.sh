#!/usr/bin/env bash
# Idempotent Nexus bootstrap: reset the generated admin password, accept the
# EULA, disable anonymous access, and reconcile the demoapp-releases repo,
# roles and service users against Key Vault. Never prints a password.
# Usage: bootstrap.sh
set -euo pipefail
# shellcheck source=SCRIPTDIR/../scripts/lib.sh
source "$(git rev-parse --show-toplevel)/infra/scripts/lib.sh"

url="https://nexus-winapp-poc.eastus.cloudapp.azure.com"
kv="$(kv_name)"

nexus_admin="$(az keyvault secret show --vault-name "$kv" -n nexus-admin-password --query value -o tsv)"
nexus_deployer="$(az keyvault secret show --vault-name "$kv" -n nexus-deployer-password --query value -o tsv)"
nexus_reader="$(az keyvault secret show --vault-name "$kv" -n nexus-reader-password --query value -o tsv)"

# --- helpers -----------------------------------------------------------
# api_get PATH: sets REPLY_CODE and REPLY_BODY, never aborts the script.
api_get() {
  local tmp
  tmp="$(mktemp)"
  REPLY_CODE="$(curl -sS -u "admin:$nexus_admin" -o "$tmp" -w '%{http_code}' "$url$1")"
  REPLY_BODY="$(cat "$tmp")"
  rm -f "$tmp"
}

# api_send METHOD PATH [JSON_DATA]: hard-fails the script (with body) on a
# non-2xx response, since these calls are expected to succeed.
api_send() {
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl --fail-with-body -sS -u "admin:$nexus_admin" -X "$method" \
      -H 'Content-Type: application/json' --data "$data" "$url$path" >/dev/null
  else
    curl --fail-with-body -sS -u "admin:$nexus_admin" -X "$method" "$url$path" >/dev/null
  fi
}

# --- 1: wait for Caddy TLS + Nexus to come up (cert issuance can take a
# while on first boot) ---------------------------------------------------
log "waiting for $url to report writable (up to 20 minutes)"
deadline=$((SECONDS + 1200))
code=""
until [[ "$code" == "200" ]]; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$url/service/rest/v1/status/writable" || true)"
  [[ "$code" == "200" ]] && break
  if (( SECONDS >= deadline )); then
    log "timed out waiting for $url/service/rest/v1/status/writable (last status: ${code:-none})"
    exit 1
  fi
  sleep 15
done
echo "ok wait-writable"

# --- 2: initial admin password -----------------------------------------
# Nexus writes a random initial password to /nexus-data/admin.password on
# first start and clears the on-disk marker once the admin password is
# actually changed away from it, so on a second run this is normally empty.
init="$(az vm run-command invoke -g "$RESOURCE_GROUP" -n vm-nexus-01 --command-id RunShellScript \
  --scripts 'cat /nexus-data/admin.password 2>/dev/null || true' \
  --query 'value[0].message' -o tsv | sed -n '/\[stdout\]/,/\[stderr\]/p' | sed '1d;$d' | tr -d '[:space:]')"

if [[ -n "$init" ]]; then
  tmp="$(mktemp)"
  pw_code="$(curl -sS -u "admin:$init" -o "$tmp" -w '%{http_code}' -X PUT \
    -H 'Content-Type: text/plain' --data-raw "$nexus_admin" \
    "$url/service/rest/v1/security/users/admin/change-password")"
  rm -f "$tmp"
  case "$pw_code" in
    200|204) ;; # changed (Nexus returns 204 No Content on success)
    401|403) ;; # already changed on an earlier run; admin.password is stale
    *) log "unexpected status $pw_code changing the initial admin password"; exit 1 ;;
  esac
fi
echo "ok admin-password"

# --- 3: EULA (Community Edition) ----------------------------------------
api_get /service/rest/v1/system/eula
if [[ "$REPLY_CODE" == "404" ]]; then
  log "skip eula"
elif [[ "$(jq -r '.accepted' <<<"$REPLY_BODY")" == "false" ]]; then
  api_send POST /service/rest/v1/system/eula "$(jq -c '.accepted = true' <<<"$REPLY_BODY")"
fi
echo "ok eula"

# --- 4: anonymous access off ---------------------------------------------
api_send PUT /service/rest/v1/security/anonymous \
  '{"enabled":false,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}'
echo "ok anonymous-off"

# --- 5: demoapp-releases repository --------------------------------------
api_get /service/rest/v1/repositories/demoapp-releases
if [[ "$REPLY_CODE" == "404" ]]; then
  api_send POST /service/rest/v1/repositories/raw/hosted \
    '{"name":"demoapp-releases","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":false,"writePolicy":"ALLOW_ONCE"},"raw":{"contentDisposition":"ATTACHMENT"}}'
fi
echo "ok repository"

# --- 6: roles --------------------------------------------------------------
put_role() { # id privilege...
  local id="$1"; shift
  local body
  body="$(jq -n --arg id "$id" --args '{id:$id,name:$id,description:("PoC " + $id),privileges:$ARGS.positional,roles:[]}' "$@")"
  api_get "/service/rest/v1/security/roles/$id"
  if [[ "$REPLY_CODE" == "404" ]]; then
    api_send POST /service/rest/v1/security/roles "$body"
  else
    api_send PUT "/service/rest/v1/security/roles/$id" "$body"
  fi
}
put_role demoapp-deployer \
  nx-repository-view-raw-demoapp-releases-add \
  nx-repository-view-raw-demoapp-releases-edit \
  nx-repository-view-raw-demoapp-releases-read \
  nx-repository-view-raw-demoapp-releases-browse
echo "ok role-demoapp-deployer"

put_role demoapp-reader \
  nx-repository-view-raw-demoapp-releases-read \
  nx-repository-view-raw-demoapp-releases-browse
echo "ok role-demoapp-reader"

# --- 7: users ----------------------------------------------------------
put_user() { # id role password
  local id="$1" role="$2" password="$3"
  api_get "/service/rest/v1/security/users?userId=$id"
  if [[ "$(jq -c '.' <<<"$REPLY_BODY")" == "[]" ]]; then
    api_send POST /service/rest/v1/security/users \
      "$(jq -n --arg id "$id" --arg role "$role" --arg pw "$password" \
        '{userId:$id,firstName:"svc",lastName:$id,emailAddress:($id+"@example.invalid"),password:$pw,status:"active",roles:[$role]}')"
  else
    # Nexus's user-update schema requires "source" (the realm the user was
    # created in — "default" for local users) even though the create schema
    # does not; a PUT without it fails with a 400 "must not be blank".
    api_send PUT "/service/rest/v1/security/users/$id" \
      "$(jq -n --arg id "$id" --arg role "$role" \
        '{userId:$id,firstName:"svc",lastName:$id,emailAddress:($id+"@example.invalid"),source:"default",status:"active",roles:[$role]}')"
    curl --fail-with-body -sS -u "admin:$nexus_admin" -X PUT \
      -H 'Content-Type: text/plain' --data-raw "$password" \
      "$url/service/rest/v1/security/users/$id/change-password" >/dev/null
  fi
}
put_user svc-gh-deployer demoapp-deployer "$nexus_deployer"
echo "ok user-svc-gh-deployer"

put_user svc-win-reader demoapp-reader "$nexus_reader"
echo "ok user-svc-win-reader"
