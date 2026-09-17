#!/usr/bin/env bash
set -euo pipefail

image="${1:-infocyph/nginx:ci}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash "$repo_root/tests/generated-config.sh" "$image"
bash "$repo_root/tests/config-smoke.sh" "$image"
bash "$repo_root/tests/render-locals.sh" "$image"
bash "$repo_root/tests/route-smoke.sh" "$image"
bash "$repo_root/tests/llm-route-smoke.sh" "$image"
bash "$repo_root/tests/image-smoke.sh" "$image"

printf 'Release gate passed for %s.\n' "$image"
