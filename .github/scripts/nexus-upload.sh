#!/usr/bin/env bash
# Upload a local file to a path inside a Nexus hosted repository,
# idempotently.
# Usage: nexus-upload.sh <local-file> <path-inside-repo>
# Env: NEXUS_URL, NEXUS_REPOSITORY, NEXUS_USER, NEXUS_PASSWORD
#
# Treats HTTP 201 (Created) as success. demoapp-releases' ALLOW_ONCE write
# policy returns 409 for a re-upload of an existing path - which happens
# whenever cd.yml's "Upload to Nexus" step is re-run after a later step
# (e.g. the AAP launch) failed on a prior attempt that had already
# uploaded this exact version. Rather than always treating a 409 as
# failure, this script verifies the existing remote object is
# byte-identical to what it would have uploaded, and only then treats the
# 409 as already-done (exit 0):
#   - Uploading a `.sha256` sidecar file: fetch the existing remote file
#     directly (it is tiny) and compare its bytes to the local one.
#   - Uploading anything else (the release artifact itself): avoid
#     re-downloading the full artifact - fetch its small `<path>.sha256`
#     sidecar instead and compare the hash it records to the local file's
#     own SHA-256.
# A 409 whose existing content does NOT match, or whose sidecar cannot be
# fetched at all (e.g. a prior run failed before ever uploading it), is a
# hard failure, not a silent reuse. Never echoes NEXUS_PASSWORD.
set -euo pipefail
file="$1"; remote="$2"
: "${NEXUS_URL:?}" "${NEXUS_REPOSITORY:?}" "${NEXUS_USER:?}" "${NEXUS_PASSWORD:?}"
[[ -f "$file" ]] || { echo "no such file: $file" >&2; exit 1; }

url="${NEXUS_URL%/}/repository/${NEXUS_REPOSITORY}/${remote}"
code="$(curl -sS --connect-timeout 15 --max-time 300 -o /dev/stderr -w '%{http_code}' -u "${NEXUS_USER}:${NEXUS_PASSWORD}" --upload-file "$file" "$url")"

if [[ "$code" == 201 ]]; then
  echo "uploaded $url"
  exit 0
fi

if [[ "$code" != 409 ]]; then
  echo "upload of $remote failed: HTTP $code" >&2
  exit 1
fi

verify_tmp="$(mktemp)"
trap 'rm -f "$verify_tmp"' EXIT

if [[ "$remote" == *.sha256 ]]; then
  fetch_code="$(curl -sS --connect-timeout 15 --max-time 60 -o "$verify_tmp" -w '%{http_code}' -u "${NEXUS_USER}:${NEXUS_PASSWORD}" "$url")"
  if [[ "$fetch_code" != 200 ]]; then
    echo "upload of $remote failed: HTTP 409, and fetching it back to verify failed: HTTP $fetch_code" >&2
    exit 1
  fi
  if cmp -s "$file" "$verify_tmp"; then
    echo "already uploaded (identical): $url"
    exit 0
  fi
  echo "upload of $remote failed: HTTP 409, and the existing remote content differs from the local file" >&2
  exit 1
fi

sidecar_url="${url}.sha256"
fetch_code="$(curl -sS --connect-timeout 15 --max-time 60 -o "$verify_tmp" -w '%{http_code}' -u "${NEXUS_USER}:${NEXUS_PASSWORD}" "$sidecar_url")"
if [[ "$fetch_code" != 200 ]]; then
  echo "upload of $remote failed: HTTP 409, and fetching $remote.sha256 to verify it failed: HTTP $fetch_code" >&2
  exit 1
fi
local_sha="$(shasum -a 256 "$file" | awk '{print $1}')"
remote_sha="$(awk '{print $1; exit}' "$verify_tmp")"
if [[ "$remote_sha" == "$local_sha" ]]; then
  echo "already uploaded (identical): $url"
  exit 0
fi
echo "upload of $remote failed: HTTP 409, and the existing remote .sha256 ($remote_sha) does not match the local file ($local_sha)" >&2
exit 1
