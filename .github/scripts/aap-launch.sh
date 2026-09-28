#!/usr/bin/env bash
# Launch an AAP job template through the platform gateway and wait for it.
# Usage: aap-launch.sh <job-template-name> <extra-vars-json-file-or-inline-json>
#   The second argument is a path to a JSON file, or, when it starts with
#   '{', an inline JSON string (extra vars object).
# Env: TOWER_HOST, TOWER_OAUTH_TOKEN, AWXKIT_API_BASE_PATH (e.g. /api/controller/)
# Optional env: AAP_JOB_TIMEOUT (default 1800s), AAP_POLL_INTERVAL (default 10s)
#
# Prints job_id=<id> and job_url=<url> to stdout as soon as the job
# launches (and appends them to $GITHUB_OUTPUT when set), then polls until
# the job reaches a terminal status. Exits 0 only when that status is
# "successful"; on failure/error/cancel or a not-found template, prints
# diagnostics to stderr and exits non-zero.
set -euo pipefail
name="$1"; vars_arg="$2"
: "${TOWER_HOST:?}" "${TOWER_OAUTH_TOKEN:?}" "${AWXKIT_API_BASE_PATH:?}"
api="${TOWER_HOST%/}${AWXKIT_API_BASE_PATH%/}/v2"
timeout_s="${AAP_JOB_TIMEOUT:-1800}"; poll_s="${AAP_POLL_INTERVAL:-10}"

# Every call is bounded: 15s to connect, 30s total. All of these (template
# lookup, launch, and each status/stdout poll) are small, fast API calls.
aap() { curl -sS --connect-timeout 15 --max-time 30 --fail-with-body -H "Authorization: Bearer $TOWER_OAUTH_TOKEN" -H 'Content-Type: application/json' "$@"; }

jt_id="$(aap -G "$api/job_templates/" --data-urlencode "name=$name" | jq -r '.results[0].id // empty')"
[[ -n "$jt_id" ]] || { echo "job template '$name' not found or not visible to this token" >&2; exit 2; }

if [[ "$vars_arg" == '{'* ]]; then
  payload="$(jq -c '{extra_vars: .}' <<<"$vars_arg")"
else
  payload="$(jq -c '{extra_vars: .}' "$vars_arg")"
fi

job_id="$(aap -X POST "$api/job_templates/$jt_id/launch/" -d "$payload" | jq -r '.job // .id')"
job_url="${TOWER_HOST%/}/execution/jobs/playbook/$job_id/output"
echo "job_id=$job_id"; echo "job_url=$job_url"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then { echo "job_id=$job_id"; echo "job_url=$job_url"; } >> "$GITHUB_OUTPUT"; fi

deadline=$(( $(date +%s) + timeout_s ))
while :; do
  status="$(aap "$api/jobs/$job_id/" | jq -r '.status')"
  case "$status" in
    successful) echo "AAP job $job_id successful" >&2; exit 0 ;;
    failed|error|canceled)
      echo "AAP job $job_id finished with status $status" >&2
      aap "$api/jobs/$job_id/stdout/?format=txt" | tail -n 60 >&2 || true
      exit 1 ;;
    new|pending|waiting|running) ;;
    *) echo "unexpected status '$status'" >&2 ;;
  esac
  (( $(date +%s) < deadline )) || { echo "timed out after ${timeout_s}s waiting for job $job_id" >&2; exit 1; }
  sleep "$poll_s"
done
