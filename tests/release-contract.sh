#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$repo_root/.github/workflows/docker.publish.yml"

fail() {
  printf 'Release contract failed: %s\n' "$*" >&2
  exit 1
}

require() {
  local needle="$1"
  grep -Fq -- "$needle" "$workflow" || fail "missing: $needle"
}

reject() {
  local needle="$1"
  if grep -Fq -- "$needle" "$workflow"; then
    fail "stale/forbidden publish contract present: $needle"
  fi
}

[[ -f "$workflow" ]] || fail 'publish workflow is missing'

require 'workflow_dispatch:'
require 'group: docker-publish'
require 'cancel-in-progress: false'
require 'timeout-minutes: 60'
require 'artifact-metadata: write'

require 'uses: actions/checkout@v7'
require 'uses: docker/setup-qemu-action@v4'
require 'uses: docker/setup-buildx-action@v4'
require 'uses: docker/login-action@v4'
require 'uses: docker/metadata-action@v6'
require 'uses: docker/build-push-action@v7'
require 'uses: actions/attest@v4'

reject 'uses: actions/checkout@v4'
reject 'uses: docker/login-action@v3'
reject 'uses: docker/metadata-action@v5'
reject 'uses: docker/build-push-action@v6'
reject 'uses: actions/attest-build-provenance@'

require 'releases/latest'
require "Stable publish workflow refuses draft/prerelease releases."
require 'PUBLISH_RELEASE_TAG=false'
require 'VERIFY_TAG=latest'
require 'if: env.PUBLISH_RELEASE_TAG == '\''true'\'''
require 'assert_absent "docker.io/infocyph/nginx:${VERSION_TAG}"'
require 'assert_absent "ghcr.io/infocyph/nginx:${VERSION_TAG}"'

require 'docker.io/infocyph/nginx'
require 'ghcr.io/infocyph/nginx'
require 'platforms: linux/amd64,linux/arm64'
require 'provenance: mode=max'
require 'sbom: true'
require 'subject-name: docker.io/infocyph/nginx'
require 'subject-name: ghcr.io/infocyph/nginx'

require 'Final amd64 release-candidate gate'
require 'Final arm64 release-candidate gate'
require 'pull: true'
require 'no-cache: true'
require 'docker buildx imagetools inspect'
require 'test "$docker_digest" = "$DIGEST"'
require 'test "$ghcr_digest" = "$DIGEST"'
require "grep -Fq 'linux/amd64'"
require "grep -Fq 'linux/arm64'"
require 'test "$published_nginx" = "$CANDIDATE_NGINX_VERSION"'
require 'test "$published_banner_sha256" = "$CANDIDATE_BANNER_SHA256"'

printf 'Publish/release contracts passed.\n'
