#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../lib.sh
source infra/scripts/lib.sh
fail=0
for _ in $(seq 1 200); do
  pw="$(gen_password)"
  [[ "$pw" =~ ^[A-Za-z0-9]{28}Aa1_$ ]] || { echo "bad password format: length ${#pw}"; fail=1; break; }
done
a="$(gen_password)"; b="$(gen_password)"
[[ "$a" != "$b" ]] || { echo "passwords not random"; fail=1; }
[[ $fail -eq 0 ]] && echo "PASS test_lib" || { echo "FAIL test_lib"; exit 1; }
