#!/usr/bin/env bash
# Upload a local file to a path inside a Nexus hosted repository.
# Usage: nexus-upload.sh <local-file> <path-inside-repo>
# Env: NEXUS_URL, NEXUS_REPOSITORY, NEXUS_USER, NEXUS_PASSWORD
#
# Treats anything other than HTTP 201 (Created) as failure - including 409,
# which demoapp-releases' ALLOW_ONCE write policy returns for a re-upload
# of an existing path. Never echoes NEXUS_PASSWORD.
set -euo pipefail
file="$1"; remote="$2"
: "${NEXUS_URL:?}" "${NEXUS_REPOSITORY:?}" "${NEXUS_USER:?}" "${NEXUS_PASSWORD:?}"
[[ -f "$file" ]] || { echo "no such file: $file" >&2; exit 1; }

url="${NEXUS_URL%/}/repository/${NEXUS_REPOSITORY}/${remote}"
code="$(curl -sS --connect-timeout 15 --max-time 300 -o /dev/stderr -w '%{http_code}' -u "${NEXUS_USER}:${NEXUS_PASSWORD}" --upload-file "$file" "$url")"
[[ "$code" == 201 ]] || { echo "upload of $remote failed: HTTP $code" >&2; exit 1; }
echo "uploaded $url"
