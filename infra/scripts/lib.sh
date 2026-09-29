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
# timeout (macOS ships no `timeout` binary, so this uses perl). On a timeout
# (exit code 142) it logs a clear message to stderr and returns non-zero;
# any other exit code (success or a genuine command failure) is passed
# through unchanged so callers can tell the two apart.
# Callers must check the return status explicitly (e.g. `if ! out="$(with_timeout ...)"; then ...; fi`)
# rather than relying on `set -e`, since a failed command substitution
# assignment alone does not trigger it.
#
# Implementation note: an earlier version just did `perl -e 'alarm shift;
# exec @ARGV'`, replacing the perl process with CMD and relying on SIGALRM
# to kill it directly. That has a real hole: if CMD's own process (e.g. the
# `az` CLI's bash launcher on this workstation) *forks* a child instead of
# `exec`ing it (observed with the Homebrew `az` wrapper forking a
# `python3 -m azure.cli` process), SIGALRM only kills the direct process —
# the forked grandchild survives, keeps holding the caller's captured
# stdout pipe open, and the command substitution around `with_timeout`
# blocks forever even though the "timed out" process is long dead. Fix:
# fork here ourselves, put the child in its own process group
# (`setpgrp(0,0)`), and on timeout signal the whole group (`kill $sig,
# -$pid`) so any grandchildren die too, not just the direct child.
with_timeout() {
  local secs="$1"; shift
  local rc=0
  perl -e '
    my $t = shift @ARGV;
    my $pid = fork();
    if (!defined $pid) { print STDERR "fork failed: $!\n"; exit 71; }
    if ($pid == 0) {
      # New process group, with this child as leader: a group-wide kill
      # from the parent below reaches any further children CMD forks too.
      setpgrp(0, 0);
      exec { $ARGV[0] } @ARGV or exit 127;
    }
    $SIG{ALRM} = sub {
      kill("TERM", -$pid);
      sleep 2;
      kill("KILL", -$pid);
      exit 142;
    };
    alarm($t);
    waitpid($pid, 0);
    alarm(0);
    my $status = $?;
    if ($status & 127) { exit(128 + ($status & 127)); }
    exit($status >> 8);
  ' "$secs" "$@" || rc=$?
  if [[ "$rc" -eq 142 ]]; then
    log "timed out after ${secs}s: $*"
  fi
  return "$rc"
}

require_az_login() {
  if ! with_timeout 60 az account show --query id -o tsv >/dev/null 2>&1; then
    log "run 'az login' first"
    exit 1
  fi
  if ! with_timeout 60 az account set --subscription "$SUBSCRIPTION_ID"; then
    log "failed to set subscription $SUBSCRIPTION_ID (timeout or az error)"
    exit 1
  fi
}

kv_name() {
  with_timeout 120 az deployment group show -g "$RESOURCE_GROUP" -n "$DEPLOYMENT_NAME" \
    --query properties.outputs.keyVaultName.value -o tsv
}

# 28 random alphanumerics + fixed "Aa1_" suffix: satisfies Windows complexity,
# contains no characters that need shell or PowerShell quoting.
gen_password() {
  local body
  body="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 28)"
  printf '%sAa1_' "$body"
}
