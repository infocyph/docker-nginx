#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readme="$repo_root/README.md"
handoff="$repo_root/docs/release-readiness.md"
dockerfile="$repo_root/Dockerfile"

fail() {
  printf 'Documentation/release readiness contract failed: %s\n' "$*" >&2
  exit 1
}

require_file_text() {
  local file="$1" needle="$2"
  grep -Fq -- "$needle" "$file" || fail "$(basename "$file") missing: $needle"
}

[[ -s "$readme" ]] || fail 'README.md is missing or empty'
[[ -s "$handoff" ]] || fail 'docs/release-readiness.md is missing or empty'
[[ -s "$dockerfile" ]] || fail 'Dockerfile is missing or empty'

for needle in \
  'docker.io/infocyph/nginx' \
  'ghcr.io/infocyph/nginx' \
  'linux/amd64' \
  'linux/arm64' \
  'admin.localhost' \
  'webmail.localhost' \
  'db.localhost' \
  'ri.localhost' \
  'me.localhost' \
  'kibana.localhost' \
  'llm.localhost' \
  'llm-sm:11434' \
  'LOCALHOST_ROUTES' \
  'LOCALHOST_CLIENT_MAX_BODY_SIZE' \
  'AUTO_DISABLE_INVALID_CONFS' \
  'MAX_DISABLE_ATTEMPTS' \
  'AUTO_RESTORE_DISABLED_CONFS' \
  'AUTO_RESTORE_INTERVAL_SECONDS' \
  'nginx-healthcheck' \
  'Release tags are immutable' \
  'update only `latest`'; do
  require_file_text "$readme" "$needle"
done

require_file_text "$readme" 'Ollama port `11434` is never exposed by this image.'
require_file_text "$readme" 'BuildKit SBOM/provenance'
require_file_text "$readme" 'Docker Hub and GHCR are required to resolve to the same resulting manifest digest'

for needle in \
  'infocyph/nginx:latest' \
  '172.28.0.10' \
  'no `llm-sm` service is present yet' \
  'runner `0.5`' \
  'lds_nginx_host' \
  '127.0.0.1:11434' \
  'remove static addresses only as part of a separately-tested broader LocalDevStack DNS migration'; do
  require_file_text "$handoff" "$needle"
done

require_file_text "$dockerfile" 'FROM nginx:alpine'
require_file_text "$dockerfile" 'EXPOSE 80 443'
require_file_text "$dockerfile" 'HEALTHCHECK'
require_file_text "$dockerfile" 'ENTRYPOINT ["nginx-entrypoint"]'

if grep -Eq '^EXPOSE .*11434' "$dockerfile"; then
  fail 'Dockerfile must not expose Ollama port 11434'
fi

printf 'Documentation and release readiness contracts passed.\n'
