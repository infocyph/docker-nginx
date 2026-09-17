#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

sh -n scripts/render-locals.sh
sh -n scripts/nginx-entrypoint.sh
sh -n scripts/nginx-healthcheck.sh
bash -n scripts/fcgi-params.sh
bash -n scripts/proxy-params.sh

mapfile -t bash_tests < <(find tests -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort)
for file in "${bash_tests[@]}"; do
  bash -n "$file"
done

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=error -s sh scripts/render-locals.sh scripts/nginx-entrypoint.sh scripts/nginx-healthcheck.sh
  shellcheck --severity=error -s bash scripts/fcgi-params.sh scripts/proxy-params.sh "${bash_tests[@]}"
fi

printf 'Static shell checks passed.\n'
