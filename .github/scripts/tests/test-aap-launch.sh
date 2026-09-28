#!/usr/bin/env bash
# Live tests for aap-launch.sh against the AAP sandbox described by .env.aap.
# Usage: bash .github/scripts/tests/test-aap-launch.sh
#
# Exercises the real gateway/controller API (no mocks): an unknown job
# template, a successful winapp-ping launch, and a winapp-deploy launch with
# an invalid artifact_sha256 that demoapp_deploy's validate.yml rejects
# before any host contact (see ansible/roles/demoapp_deploy/tasks/validate.yml).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=SCRIPTDIR/../../../infra/scripts/lib.sh
source infra/scripts/lib.sh

set -a
# shellcheck source=/dev/null
source .env.aap
set +a

LAUNCH="$REPO_ROOT/.github/scripts/aap-launch.sh"

FAIL_COUNT=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# run_launch <timeout_s> <template> <vars-arg>: runs aap-launch.sh under a
# hard wall-clock budget, capturing stdout/stderr to files and the exit
# code, without letting `set -e` abort the test script on a non-zero exit
# (several of these scenarios expect one).
RC=0
OUT=""
ERR=""
run_launch() {
  local budget="$1" template="$2" vars_arg="$3"
  OUT="$WORK_DIR/out.$RANDOM"
  ERR="$WORK_DIR/err.$RANDOM"
  RC=0
  with_timeout "$budget" bash "$LAUNCH" "$template" "$vars_arg" >"$OUT" 2>"$ERR" || RC=$?
}

test_unknown_template() {
  local name="unknown_template"
  echo '{}' >"$WORK_DIR/vars.json"
  run_launch 60 "does-not-exist" "$WORK_DIR/vars.json"
  if [[ "$RC" -eq 0 ]]; then
    fail "$name" "expected a non-zero exit code, got 0"; return
  fi
  if ! grep -q "job template 'does-not-exist' not found" "$ERR"; then
    fail "$name" "stderr did not contain the expected message: $(cat "$ERR")"; return
  fi
  pass "$name"
}

test_ping_success() {
  local name="ping_success"
  run_launch 120 "winapp-ping" '{}'
  if [[ "$RC" -ne 0 ]]; then
    fail "$name" "expected exit 0, got $RC (stderr: $(tail -c 500 "$ERR"))"; return
  fi
  if ! grep -q '^job_id=' "$OUT"; then
    fail "$name" "stdout missing job_id=: $(cat "$OUT")"; return
  fi
  if ! grep -q '^job_url=' "$OUT"; then
    fail "$name" "stdout missing job_url=: $(cat "$OUT")"; return
  fi
  pass "$name"
}

test_failure_propagates() {
  local name="failure_propagates"
  # app_version/artifact_url/git_sha are all shaped to pass validate.yml's
  # other assertions; only artifact_sha256 is deliberately malformed (not
  # 64 lowercase hex chars), so the assert task fails fast, before any
  # attempt to fetch the (nonexistent) artifact or touch the VM.
  local vars='{"app_version":"9.9.9","artifact_url":"https://nexus-winapp-poc.eastus.cloudapp.azure.com/repository/demoapp-releases/demoapp/9.9.9/DemoApp-9.9.9-0000000.zip","artifact_sha256":"not-a-valid-sha256","git_sha":"0000000"}'
  run_launch 180 "winapp-deploy" "$vars"
  if [[ "$RC" -eq 0 ]]; then
    fail "$name" "expected a non-zero exit code, got 0"; return
  fi
  if ! grep -q 'finished with status failed' "$ERR"; then
    fail "$name" "stderr did not show the job's final failed status: $(cat "$ERR")"; return
  fi
  if [[ ! -s "$ERR" ]]; then
    fail "$name" "stderr had no job output tail"; return
  fi
  pass "$name"
}

test_unknown_template
test_ping_success
test_failure_propagates

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "$FAIL_COUNT test(s) FAILED"
  exit 1
fi
echo "all tests PASSED"
exit 0
