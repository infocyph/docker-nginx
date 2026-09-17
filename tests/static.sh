#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

sh -n scripts/render-locals.sh
sh -n scripts/nginx-entrypoint.sh
sh -n scripts/nginx-healthcheck.sh
bash -n scripts/fcgi-params.sh
bash -n scripts/proxy-params.sh

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=error -s sh scripts/render-locals.sh scripts/nginx-entrypoint.sh scripts/nginx-healthcheck.sh
  shellcheck --severity=error -s bash scripts/fcgi-params.sh scripts/proxy-params.sh
fi

printf 'Static shell checks passed.\n'
