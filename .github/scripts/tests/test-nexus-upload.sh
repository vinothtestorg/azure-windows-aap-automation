#!/usr/bin/env bash
# Live tests for nexus-upload.sh's idempotent-409 behavior against the real
# demoapp-releases repo.
#
# Task 10 controller ruling: a CD "re-run failed jobs" after a post-upload
# step failed (e.g. the AAP launch step, run after both nexus-upload.sh
# calls already succeeded) would otherwise get permanently stuck, because
# demoapp-releases' ALLOW_ONCE write policy returns 409 for a re-upload of
# an existing path and the original script treated any non-201 as a hard
# failure. nexus-upload.sh now verifies a 409's existing remote content is
# byte-identical (via the small .sha256 sidecar for a main artifact, or
# directly when the upload itself IS a .sha256 file) before accepting it as
# already-done.
#
# Uses a unique throwaway path under demoapp/_test/ in demoapp-releases for
# every run (Nexus has no cleanup policy in this PoC - ruling recorded in
# HLD's as-built notes - so these throwaway objects are never deleted
# automatically). Never echoes NEXUS_PASSWORD.
#
# Usage: bash .github/scripts/tests/test-nexus-upload.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=SCRIPTDIR/../../../infra/scripts/lib.sh
source infra/scripts/lib.sh

require_az_login
KV_NAME="$(kv_name)"
NEXUS_DEPLOYER_PW="$(with_timeout 60 az keyvault secret show --vault-name "$KV_NAME" -n nexus-deployer-password --query value -o tsv)"

export NEXUS_URL="https://nexus-winapp-poc.eastus.cloudapp.azure.com"
export NEXUS_REPOSITORY="demoapp-releases"
export NEXUS_USER="svc-gh-deployer"
export NEXUS_PASSWORD="$NEXUS_DEPLOYER_PW"
unset NEXUS_DEPLOYER_PW

UPLOAD="$REPO_ROOT/.github/scripts/nexus-upload.sh"

FAIL_COUNT=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

UNIQUE="nexus-upload-test-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
BASE_PATH="demoapp/_test/$UNIQUE"
log "using throwaway path $BASE_PATH"

FILE_A="$WORK_DIR/a.bin"
FILE_B="$WORK_DIR/b.bin"
printf 'content-a-%s\n' "$RANDOM" > "$FILE_A"
printf 'content-b-%s\n' "$RANDOM" > "$FILE_B"
SHA_A="$(shasum -a 256 "$FILE_A" | awk '{print $1}')"
SHA_A_FILE="$WORK_DIR/a.bin.sha256"
printf '%s  a.bin\n' "$SHA_A" > "$SHA_A_FILE"

# run_upload BUDGET FILE REMOTE: runs nexus-upload.sh under a hard
# wall-clock budget, capturing stdout/stderr to files and the exit code,
# without letting `set -e` abort this test script on a non-zero exit
# (some scenarios expect one).
RC=0
OUT=""
ERR=""
run_upload() {
  local budget="$1" file="$2" remote="$3"
  OUT="$WORK_DIR/out.$RANDOM"
  ERR="$WORK_DIR/err.$RANDOM"
  RC=0
  with_timeout "$budget" bash "$UPLOAD" "$file" "$remote" >"$OUT" 2>"$ERR" || RC=$?
}

test_new_upload() {
  local name="new_upload"
  run_upload 60 "$FILE_A" "$BASE_PATH/a.bin"
  if [[ "$RC" -ne 0 ]]; then
    fail "$name" "expected exit 0 on a fresh path, got $RC (stderr: $(cat "$ERR"))"; return
  fi
  if ! grep -q "^uploaded " "$OUT"; then
    fail "$name" "stdout missing 'uploaded ': $(cat "$OUT")"; return
  fi
  pass "$name"
}

test_new_upload_sidecar() {
  local name="new_upload_sidecar"
  run_upload 60 "$SHA_A_FILE" "$BASE_PATH/a.bin.sha256"
  if [[ "$RC" -ne 0 ]]; then
    fail "$name" "expected exit 0 uploading the .sha256 sidecar, got $RC (stderr: $(cat "$ERR"))"; return
  fi
  pass "$name"
}

test_identical_reupload() {
  local name="identical_reupload"
  run_upload 60 "$FILE_A" "$BASE_PATH/a.bin"
  if [[ "$RC" -ne 0 ]]; then
    fail "$name" "expected exit 0 re-uploading byte-identical content (409 + sidecar match), got $RC (stderr: $(cat "$ERR"))"; return
  fi
  if ! grep -q "already uploaded (identical)" "$OUT"; then
    fail "$name" "stdout missing 'already uploaded (identical)': $(cat "$OUT")"; return
  fi
  pass "$name"
}

test_identical_sidecar_reupload() {
  local name="identical_sidecar_reupload"
  run_upload 60 "$SHA_A_FILE" "$BASE_PATH/a.bin.sha256"
  if [[ "$RC" -ne 0 ]]; then
    fail "$name" "expected exit 0 re-uploading a byte-identical .sha256 file (409 + direct content match), got $RC (stderr: $(cat "$ERR"))"; return
  fi
  if ! grep -q "already uploaded (identical)" "$OUT"; then
    fail "$name" "stdout missing 'already uploaded (identical)': $(cat "$OUT")"; return
  fi
  pass "$name"
}

test_different_content_same_path() {
  local name="different_content_same_path"
  run_upload 60 "$FILE_B" "$BASE_PATH/a.bin"
  if [[ "$RC" -eq 0 ]]; then
    fail "$name" "expected a non-zero exit uploading different content to an existing path, got 0"; return
  fi
  if ! grep -qiE "differ|does not match" "$ERR"; then
    fail "$name" "stderr did not explain the content mismatch: $(cat "$ERR")"; return
  fi
  pass "$name"
}

test_new_upload
test_new_upload_sidecar
test_identical_reupload
test_identical_sidecar_reupload
test_different_content_same_path

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "$FAIL_COUNT test(s) FAILED"
  exit 1
fi
echo "all tests PASSED"
exit 0
