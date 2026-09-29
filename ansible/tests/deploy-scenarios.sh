#!/usr/bin/env bash
# Live deploy-path scenarios for the demoapp_deploy Ansible role (Task 8).
#
# Re-packages the latest successful ci.yml artifact (Task 2) into fresh
# versions so every run is idempotent-safe against Nexus's ALLOW_ONCE write
# policy (409 on a byte-identical re-upload of the same path), uploads them
# to Nexus, and drives ansible/playbooks/deploy.yml against vm-winapp-01
# through each scenario below. Never echoes a secret: passwords are read
# from Key Vault straight into shell variables and only ever used inside
# `curl -u` / passed to Ansible, never printed or grepped for anything but
# absence.
#
# Usage:
#   bash ansible/tests/deploy-scenarios.sh                 # run all scenarios
#   bash ansible/tests/deploy-scenarios.sh unhealthy no_secret_leak   # run only
#     the named scenarios, in the order given (any of validation, good,
#     idempotent, checksum_drift, bad_checksum, unhealthy,
#     first_deploy_failure, no_secret_leak). checksum_drift, like
#     idempotent, needs `good` to have run earlier in the SAME invocation.
#     bad_checksum/unhealthy compare the live /version
#     against whatever it was when the script started if `good` was not
#     part of this run, so a targeted re-run after an interruption still
#     checks the right baseline.
#   bash ansible/tests/deploy-scenarios.sh --prepare-only   # upload one fresh
#     good version and print {app_version,artifact_url,artifact_sha256,git_sha}
#     as JSON on stdout (used by aap/verify.yml's --tags deploy launch vars)
set -euo pipefail
# shellcheck source=SCRIPTDIR/../../infra/scripts/lib.sh
source "$(git rev-parse --show-toplevel)/infra/scripts/lib.sh"
cd "$REPO_ROOT"

export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
export no_proxy='*'
python3 -c 'import os; [os.set_blocking(f, True) for f in (0, 1, 2)]' 2>/dev/null || true

readonly APP_URL="http://winapp-poc.eastus.cloudapp.azure.com"
readonly NEXUS_URL="https://nexus-winapp-poc.eastus.cloudapp.azure.com"
readonly NEXUS_REPO="demoapp-releases"
readonly VM_NAME="vm-winapp-01"
readonly DEPLOY_PLAYBOOK="ansible/playbooks/deploy.yml"
readonly CONNECT_VARS_YAML='    ansible_connection: psrp
    ansible_port: 5986
    ansible_psrp_protocol: https
    ansible_psrp_auth: ntlm
    ansible_psrp_cert_validation: ignore'

PREPARE_ONLY=false
if [[ "${1:-}" == "--prepare-only" ]]; then
  PREPARE_ONLY=true
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
CAPTURE_DIR="$WORK_DIR/captures"
mkdir -p "$CAPTURE_DIR"

FAIL_COUNT=0
GOOD_DEPLOYED=false
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# expected_good_version -> the version bad_checksum/unhealthy should find
# live: the one `good` just deployed in THIS run if it ran (GOOD_DEPLOYED),
# otherwise whatever was already live when this run started
# (BASELINE_GOOD_VERSION) - GOOD_VERSION itself is always non-empty (computed
# unconditionally in common_setup) so it cannot be used as the "did good
# actually run" signal.
expected_good_version() {
  if [[ "$GOOD_DEPLOYED" == "true" ]]; then
    printf '%s' "$GOOD_VERSION"
  else
    printf '%s' "$BASELINE_GOOD_VERSION"
  fi
}

# ---------------------------------------------------------------------------
# Setup: secrets, VM power state, the CI artifact, and the versions this run
# will use. Never logs a secret value; only the *names* of what was read.
# ---------------------------------------------------------------------------
common_setup() {
  require_az_login
  if ! KV_NAME="$(kv_name)"; then
    log "timed out or failed reading the Key Vault name"; exit 1
  fi

  if ! ANSIBLE_SVC_PASSWORD="$(with_timeout 60 az keyvault secret show --vault-name "$KV_NAME" -n ansible-svc-password --query value -o tsv)"; then
    log "failed to read ansible-svc-password from Key Vault"; exit 1
  fi
  export ANSIBLE_SVC_PASSWORD
  if ! NEXUS_DEPLOYER_PW="$(with_timeout 60 az keyvault secret show --vault-name "$KV_NAME" -n nexus-deployer-password --query value -o tsv)"; then
    log "failed to read nexus-deployer-password from Key Vault"; exit 1
  fi
  if ! NEXUS_READER_PW="$(with_timeout 60 az keyvault secret show --vault-name "$KV_NAME" -n nexus-reader-password --query value -o tsv)"; then
    log "failed to read nexus-reader-password from Key Vault"; exit 1
  fi
  if ! NEXUS_ADMIN_PW="$(with_timeout 60 az keyvault secret show --vault-name "$KV_NAME" -n nexus-admin-password --query value -o tsv)"; then
    log "failed to read nexus-admin-password from Key Vault"; exit 1
  fi

  log "checking $VM_NAME power state"
  if ! power="$(with_timeout 120 az vm get-instance-view -g rg-winapp-poc -n "$VM_NAME" --query "instanceView.statuses[?starts_with(code,'PowerState')].displayStatus" -o tsv)"; then
    log "failed to read power state of $VM_NAME"; exit 1
  fi
  if [[ "$power" != "VM running" ]]; then
    log "$VM_NAME is $power - starting it"
    with_timeout 600 az vm start -g rg-winapp-poc -n "$VM_NAME" --output none || { log "failed to start $VM_NAME"; exit 1; }
  fi

  log "looking up latest successful ci.yml run on poc/implementation"
  local run_json
  if ! run_json="$(with_timeout 60 gh run list --workflow ci.yml --branch poc/implementation --status success --limit 1 --json databaseId,headSha)"; then
    log "gh run list timed out or failed"; exit 1
  fi
  CI_RUN_ID="$(jq -r '.[0].databaseId // empty' <<<"$run_json")"
  CI_HEAD_SHA="$(jq -r '.[0].headSha // empty' <<<"$run_json")"
  [[ -n "$CI_RUN_ID" ]] || { log "no successful ci.yml run found on poc/implementation"; exit 1; }
  CI_GIT_SHA7="${CI_HEAD_SHA:0:7}"

  local ci_dir="$WORK_DIR/ci"
  mkdir -p "$ci_dir"
  with_timeout 180 gh run download "$CI_RUN_ID" -n demoapp-package -D "$ci_dir" >/dev/null || { log "gh run download timed out or failed"; exit 1; }
  CI_ZIP="$(find "$ci_dir" -maxdepth 1 -name 'DemoApp-*.zip' | head -1)"
  [[ -n "$CI_ZIP" ]] || { log "no DemoApp-*.zip found in the demoapp-package artifact"; exit 1; }
  log "using CI run $CI_RUN_ID (git_sha $CI_GIT_SHA7), artifact $(basename "$CI_ZIP")"

  local epoch_min=$(( $(date -u +%s) / 60 ))
  GOOD_VERSION="1.0.$(( 9000 + (epoch_min % 1000) ))"
  UNHEALTHY_VERSION="1.0.$(( 9000 + ((epoch_min + 1) % 1000) ))"
  BAD_CHECKSUM_VERSION="1.0.$(( 9000 + ((epoch_min + 2) % 1000) ))"
  log "versions for this run: good=$GOOD_VERSION unhealthy=$UNHEALTHY_VERSION bad_checksum=$BAD_CHECKSUM_VERSION"

  # Baseline for bad_checksum/unhealthy's "did the live version stay/return
  # unchanged" check when this invocation does not itself run `good` (e.g. a
  # targeted re-run after an earlier invocation was interrupted): whatever
  # /version already returns right now, before this run touches anything.
  BASELINE_GOOD_VERSION="$(remote_version)"
  log "live /version at start of this run: ${BASELINE_GOOD_VERSION:-<none>}"
}

# repackage VERSION MANGLE(0/1) -> sets REPKG_ZIP, REPKG_SHA256
repackage() {
  local version="$1" mangle="$2"
  local rdir="$WORK_DIR/pkg-$version" extract
  mkdir -p "$rdir"
  extract="$rdir/out"
  mkdir -p "$extract"
  unzip -q "$CI_ZIP" -d "$extract"
  printf '{"version":"%s","gitSha":"%s"}' "$version" "$CI_GIT_SHA7" > "$extract/version.json"
  if [[ "$mangle" == "1" ]]; then
    printf '<configuration><broken' > "$extract/Web.config"
  fi
  local zip="$rdir/DemoApp-$version.zip"
  rm -f "$zip"
  (cd "$extract" && zip -qr "$zip" .)
  REPKG_ZIP="$zip"
  REPKG_SHA256="$(shasum -a 256 "$zip" | awk '{print $1}')"
}

# upload_to_nexus VERSION LOCAL_ZIP -> sets UPLOAD_URL; returns non-zero on
# a hard failure. A 409 (ALLOW_ONCE conflict - e.g. a version left over from
# an interrupted prior run) is only accepted when the existing remote object
# is byte-identical to what this run would have uploaded; a 409 with
# different content is a hard failure, not a silent reuse (see
# infra/scripts/manual/manual-deploy.sh for the same reasoning, there via a
# .sha256 sidecar - here via a direct download-and-compare since this path
# has no sidecar).
upload_to_nexus() {
  local version="$1" zip="$2"
  local zip_name path url status
  zip_name="$(basename "$zip")"
  path="demoapp/$version/$zip_name"
  url="$NEXUS_URL/repository/$NEXUS_REPO/$path"
  if ! status="$(curl -sS --connect-timeout 15 --max-time 300 -o /dev/null -w '%{http_code}' -u "svc-gh-deployer:$NEXUS_DEPLOYER_PW" --upload-file "$zip" "$url")"; then
    log "upload request for $path timed out or failed (network error)"
    return 1
  fi
  case "$status" in
    201) log "uploaded $path" ;;
    409)
      log "$path already exists in Nexus (409) - verifying its content matches before reusing it"
      local remote_tmp local_sha remote_sha
      remote_tmp="$(mktemp "$WORK_DIR/remote-XXXXXX.zip")"
      if ! curl -sS --connect-timeout 15 --max-time 300 -u "svc-win-reader:$NEXUS_READER_PW" -o "$remote_tmp" "$url"; then
        log "failed to download the existing $path to verify it"
        rm -f "$remote_tmp"
        return 1
      fi
      local_sha="$(shasum -a 256 "$zip" | awk '{print $1}')"
      remote_sha="$(shasum -a 256 "$remote_tmp" | awk '{print $1}')"
      rm -f "$remote_tmp"
      if [[ "$local_sha" != "$remote_sha" ]]; then
        log "existing $path does not match this run's content (local=$local_sha remote=$remote_sha) - refusing to reuse it"
        return 1
      fi
      log "existing $path matches this run's content - reusing it"
      ;;
    *) log "unexpected status $status uploading $path"; return 1 ;;
  esac
  UPLOAD_URL="$url"
}

# run_ps_on_host SCRIPT_FILE OUT_LOG -> runs SCRIPT_FILE's contents on
# windows_web via win_shell (a throwaway playbook, not part of the role) and
# writes the full ansible-playbook output to OUT_LOG. Connection vars are
# inlined so this does not depend on group_vars adjacency to a one-off
# playbook path.
run_ps_on_host() {
  local script_file="$1" outlog="$2"
  local tmp_pb="$WORK_DIR/_adhoc_$RANDOM.yml"
  {
    printf -- '---\n- hosts: windows_web\n  gather_facts: false\n  vars:\n%s\n' "$CONNECT_VARS_YAML"
    printf '  tasks:\n    - name: Run ad hoc PowerShell\n      ansible.windows.win_shell: "{{ lookup(%s, %s) }}"\n' "'ansible.builtin.file'" "'$script_file'"
    printf '      register: _adhoc_out\n    - ansible.builtin.debug:\n        var: _adhoc_out.stdout_lines\n'
  } > "$tmp_pb"
  with_timeout 120 ansible-playbook "$tmp_pb" </dev/null >"$outlog" 2>&1
}

tail_deployments_log() {
  local logpath="$1" outlog="$2"
  local ps_file="$WORK_DIR/tail_$RANDOM.ps1"
  printf "Get-Content '%s' -Tail 1\n" "$logpath" > "$ps_file"
  run_ps_on_host "$ps_file" "$outlog"
}

cleanup_first_deploy_failure() {
  local ps_file="$WORK_DIR/cleanup_firsttest.ps1"
  cat > "$ps_file" <<'PS1'
Import-Module WebAdministration
if (Get-Website -Name 'DemoAppFirstTest' -ErrorAction SilentlyContinue) { Remove-Website -Name 'DemoAppFirstTest' }
if (Test-Path 'IIS:\AppPools\DemoAppFirstTestPool') { Remove-WebAppPool -Name 'DemoAppFirstTestPool' }
$root = 'C:\inetpub\demoapp-firsttest'
$current = Join-Path $root 'current'
if (Test-Path $current) { cmd /c rmdir "$current" | Out-Null }
if (Test-Path $root) { Remove-Item -Recurse -Force $root }
PS1
  if ! run_ps_on_host "$ps_file" "$CAPTURE_DIR/cleanup-firsttest.log"; then
    log "cleanup of the first-deploy-failure site/pool/folder may have failed - see $CAPTURE_DIR/cleanup-firsttest.log"
  fi
}

remote_version() {
  curl -sS --connect-timeout 10 --max-time 20 "$APP_URL/version" 2>/dev/null | jq -r '.version // empty'
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

scenario_validation() {
  local name="validation"
  local good_sha good_url
  good_sha="$(printf 'a%.0s' $(seq 1 64))"
  good_url="${NEXUS_URL}/repository/${NEXUS_REPO}/demoapp/1.2.3/DemoApp-1.2.3.zip"

  local i=0
  local -a versions=("1.2.3" "1.2.3" "1.2.3" "1.0")
  local -a urls=("https://evil.example.com/x.zip" "${NEXUS_URL}/repository/${NEXUS_REPO}/demoapp/../../x.zip" "$good_url" "$good_url")
  local -a shas=("$good_sha" "$good_sha" "ABC" "$good_sha")

  for i in 0 1 2 3; do
    local logfile="$CAPTURE_DIR/validation-$i.log"
    if with_timeout 90 ansible-playbook "$DEPLOY_PLAYBOOK" --tags validate \
        -e app_version="${versions[$i]}" -e artifact_url="${urls[$i]}" -e artifact_sha256="${shas[$i]}" -e git_sha=abc1234 \
        </dev/null >"$logfile" 2>&1; then
      fail "$name" "case $i (no host contact expected) unexpectedly succeeded, see $logfile"
      return
    fi
    if ! grep -q "Invalid launch variables" "$logfile"; then
      fail "$name" "case $i did not show the 'Invalid launch variables' message, see $logfile"
      return
    fi
  done
  pass "$name"
}

scenario_good() {
  local name="good"
  repackage "$GOOD_VERSION" 0
  if ! upload_to_nexus "$GOOD_VERSION" "$REPKG_ZIP"; then
    fail "$name" "upload to Nexus failed"; return
  fi
  GOOD_URL="$UPLOAD_URL"
  GOOD_SHA256="$REPKG_SHA256"

  local logfile="$CAPTURE_DIR/good.log"
  if ! with_timeout 600 ansible-playbook "$DEPLOY_PLAYBOOK" \
      -e app_version="$GOOD_VERSION" -e artifact_url="$GOOD_URL" -e artifact_sha256="$GOOD_SHA256" -e git_sha="$CI_HEAD_SHA" \
      </dev/null >"$logfile" 2>&1; then
    fail "$name" "ansible-playbook failed, see $logfile"; return
  fi
  local v; v="$(remote_version)"
  if [[ "$v" != "$GOOD_VERSION" ]]; then
    fail "$name" "/version returned '$v', expected $GOOD_VERSION"; return
  fi
  GOOD_DEPLOYED=true
  pass "$name"
}

scenario_idempotent() {
  local name="idempotent"
  if [[ -z "${GOOD_URL:-}" ]]; then fail "$name" "good scenario did not run first"; return; fi

  local logfile="$CAPTURE_DIR/idempotent.log"
  if ! with_timeout 600 ansible-playbook "$DEPLOY_PLAYBOOK" \
      -e app_version="$GOOD_VERSION" -e artifact_url="$GOOD_URL" -e artifact_sha256="$GOOD_SHA256" -e git_sha="$CI_HEAD_SHA" \
      </dev/null >"$logfile" 2>&1; then
    fail "$name" "ansible-playbook failed on a repeat deploy, see $logfile"; return
  fi
  local switch_status
  switch_status="$(awk '/TASK \[demoapp_deploy : Switch current to the new release\]/{getline; print; exit}' "$logfile")"
  if [[ "$switch_status" != ok:* ]]; then
    fail "$name" "switch task reported '$switch_status', expected 'ok:' (changed=false)"; return
  fi
  local v; v="$(remote_version)"
  if [[ "$v" != "$GOOD_VERSION" ]]; then
    fail "$name" "/version returned '$v', expected unchanged $GOOD_VERSION"; return
  fi
  pass "$name"
}

# M4(a) regression test: relaunching an already-fetched version (releases\
# <version>\.complete exists) with a different, still well-formed
# artifact_sha256 must fail, not silently reuse the on-disk bytes. Requires
# `good` to have run first in this invocation (reuses its release, no new
# upload needed).
scenario_checksum_drift() {
  local name="checksum_drift"
  if [[ -z "${GOOD_URL:-}" ]]; then fail "$name" "good scenario did not run first"; return; fi

  # Flip the first hex digit of GOOD_SHA256 to get a different, still
  # valid-format (64 lowercase hex chars) checksum.
  local wrong_sha
  case "${GOOD_SHA256:0:1}" in
    a) wrong_sha="b${GOOD_SHA256:1}" ;;
    *) wrong_sha="a${GOOD_SHA256:1}" ;;
  esac

  local logfile="$CAPTURE_DIR/checksum_drift.log"
  if with_timeout 300 ansible-playbook "$DEPLOY_PLAYBOOK" \
      -e app_version="$GOOD_VERSION" -e artifact_url="$GOOD_URL" -e artifact_sha256="$wrong_sha" -e git_sha="$CI_HEAD_SHA" \
      </dev/null >"$logfile" 2>&1; then
    fail "$name" "ansible-playbook unexpectedly succeeded relaunching already-fetched $GOOD_VERSION with a mismatched (but valid-format) sha256, see $logfile"; return
  fi
  if ! grep -q "checksum mismatch" "$logfile"; then
    fail "$name" "expected 'checksum mismatch' in the output for the already-fetched release, see $logfile"; return
  fi
  local v; v="$(remote_version)"
  if [[ "$v" != "$GOOD_VERSION" ]]; then
    fail "$name" "/version is '$v', expected it unchanged at $GOOD_VERSION"; return
  fi
  pass "$name"
}

scenario_bad_checksum() {
  local name="bad_checksum"
  repackage "$BAD_CHECKSUM_VERSION" 0
  if ! upload_to_nexus "$BAD_CHECKSUM_VERSION" "$REPKG_ZIP"; then
    fail "$name" "upload to Nexus failed"; return
  fi
  local wrong_sha; wrong_sha="$(printf '0%.0s' $(seq 1 64))"

  local logfile="$CAPTURE_DIR/bad_checksum.log"
  if with_timeout 300 ansible-playbook "$DEPLOY_PLAYBOOK" \
      -e app_version="$BAD_CHECKSUM_VERSION" -e artifact_url="$UPLOAD_URL" -e artifact_sha256="$wrong_sha" -e git_sha="$CI_HEAD_SHA" \
      </dev/null >"$logfile" 2>&1; then
    fail "$name" "ansible-playbook unexpectedly succeeded with a wrong checksum, see $logfile"; return
  fi
  if ! grep -q "checksum mismatch" "$logfile"; then
    fail "$name" "expected 'checksum mismatch' in the output, see $logfile"; return
  fi
  local expected; expected="$(expected_good_version)"
  local v; v="$(remote_version)"
  if [[ "$v" != "$expected" ]]; then
    fail "$name" "/version is '$v', expected it unchanged from $expected"; return
  fi
  pass "$name"
}

scenario_unhealthy() {
  local name="unhealthy"
  repackage "$UNHEALTHY_VERSION" 1
  if ! upload_to_nexus "$UNHEALTHY_VERSION" "$REPKG_ZIP"; then
    fail "$name" "upload to Nexus failed"; return
  fi
  UNHEALTHY_URL="$UPLOAD_URL"
  UNHEALTHY_SHA256="$REPKG_SHA256"

  local logfile="$CAPTURE_DIR/unhealthy.log"
  if with_timeout 300 ansible-playbook "$DEPLOY_PLAYBOOK" \
      -e app_version="$UNHEALTHY_VERSION" -e artifact_url="$UNHEALTHY_URL" -e artifact_sha256="$UNHEALTHY_SHA256" -e git_sha="$CI_HEAD_SHA" \
      </dev/null >"$logfile" 2>&1; then
    fail "$name" "ansible-playbook unexpectedly succeeded deploying a broken Web.config, see $logfile"; return
  fi
  local expected; expected="$(expected_good_version)"
  local v; v="$(remote_version)"
  if [[ "$v" != "$expected" ]]; then
    fail "$name" "/version after rollback is '$v', expected previous good $expected"; return
  fi
  local taillog="$CAPTURE_DIR/unhealthy-tail.log"
  tail_deployments_log 'C:\inetpub\demoapp\deployments.log' "$taillog" || true
  if ! grep -q "result=rolled_back" "$taillog"; then
    fail "$name" "deployments.log's last line did not show result=rolled_back, see $taillog"; return
  fi
  pass "$name"
}

scenario_first_deploy_failure() {
  local name="first_deploy_failure"
  if [[ -z "${UNHEALTHY_URL:-}" ]]; then fail "$name" "unhealthy scenario did not run first"; return; fi

  local logfile="$CAPTURE_DIR/first_deploy_failure.log"
  local rc=0
  with_timeout 300 ansible-playbook "$DEPLOY_PLAYBOOK" \
      -e app_version="$UNHEALTHY_VERSION" -e artifact_url="$UNHEALTHY_URL" -e artifact_sha256="$UNHEALTHY_SHA256" -e git_sha="$CI_HEAD_SHA" \
      -e demoapp_root='C:\inetpub\demoapp-firsttest' -e demoapp_site_name=DemoAppFirstTest -e demoapp_port=8081 -e demoapp_pool_name=DemoAppFirstTestPool \
      </dev/null >"$logfile" 2>&1 || rc=$?

  if [[ "$rc" -eq 0 ]]; then
    fail "$name" "ansible-playbook unexpectedly succeeded on a first-ever deploy of a broken artifact, see $logfile"
    cleanup_first_deploy_failure
    return
  fi
  if grep -qi "Traceback (most recent call last)" "$logfile"; then
    fail "$name" "found a Python traceback in the rescue path, see $logfile"
    cleanup_first_deploy_failure
    return
  fi
  local taillog="$CAPTURE_DIR/first_deploy_failure-tail.log"
  tail_deployments_log 'C:\inetpub\demoapp-firsttest\deployments.log' "$taillog" || true
  if ! grep -q "result=failed" "$taillog"; then
    fail "$name" "deployments.log at demoapp-firsttest did not show result=failed, see $taillog"
    cleanup_first_deploy_failure
    return
  fi
  cleanup_first_deploy_failure
  pass "$name"
}

scenario_no_secret_leak() {
  local name="no_secret_leak"
  local -a secrets=("$NEXUS_DEPLOYER_PW" "$NEXUS_READER_PW" "$NEXUS_ADMIN_PW" "$ANSIBLE_SVC_PASSWORD")
  local total=0 f s c
  for f in "$CAPTURE_DIR"/*.log; do
    [[ -e "$f" ]] || continue
    for s in "${secrets[@]}"; do
      [[ -n "$s" ]] || continue
      c="$(grep -c -F -- "$s" "$f" || true)"
      total=$((total + c))
    done
  done
  log "no_secret_leak: $total match(es) across $(find "$CAPTURE_DIR" -name '*.log' | wc -l | tr -d ' ') captured log(s)"
  if [[ "$total" -ne 0 ]]; then
    fail "$name" "$total secret occurrence(s) found in captured output"; return
  fi
  pass "$name"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if $PREPARE_ONLY; then
  common_setup
  repackage "$GOOD_VERSION" 0
  if ! upload_to_nexus "$GOOD_VERSION" "$REPKG_ZIP"; then
    log "prepare-only: upload to Nexus failed"; exit 1
  fi
  jq -n --arg app_version "$GOOD_VERSION" --arg artifact_url "$UPLOAD_URL" \
        --arg artifact_sha256 "$REPKG_SHA256" --arg git_sha "$CI_HEAD_SHA" \
        '{app_version: $app_version, artifact_url: $artifact_url, artifact_sha256: $artifact_sha256, git_sha: $git_sha}'
  exit 0
fi

# Any positional args name the scenarios to run, in the order given (see the
# usage comment at the top); with none, run all seven in the fixed order.
readonly ALL_SCENARIOS=(validation good idempotent checksum_drift bad_checksum unhealthy first_deploy_failure no_secret_leak)
if [[ "$#" -gt 0 ]]; then
  SELECTED=("$@")
  for s in "${SELECTED[@]}"; do
    case " ${ALL_SCENARIOS[*]} " in
      *" $s "*) : ;;
      *) log "unknown scenario: $s (expected one of: ${ALL_SCENARIOS[*]})"; exit 1 ;;
    esac
  done
else
  SELECTED=("${ALL_SCENARIOS[@]}")
fi

common_setup
for s in "${SELECTED[@]}"; do
  "scenario_$s"
done

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  log "$FAIL_COUNT scenario(s) FAILED"
  exit 1
fi
log "all scenarios PASSED"
exit 0
