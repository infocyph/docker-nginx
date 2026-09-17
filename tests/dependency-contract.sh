#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if grep -RIn --exclude-dir=.git 'Scriptomatic/master' Dockerfile scripts .github 2>/dev/null; then
  echo 'Found stale Scriptomatic/master dependency.' >&2
  exit 1
fi

if grep -RIn --exclude-dir=.git 'raw.githubusercontent.com/infocyph/Toolset/main' Dockerfile scripts .github 2>/dev/null; then
  echo 'Found raw Toolset/main dependency.' >&2
  exit 1
fi

grep -Fq 'https://raw.githubusercontent.com/infocyph/Scriptomatic/main/bash/banner.sh' Dockerfile
grep -Fq 'https://github.com/infocyph/Toolset/releases/latest/download/install.sh' Dockerfile

retry_count="$(grep -Fc -- '--retry 3 --retry-delay 1 --connect-timeout 10' Dockerfile)"
if [ "$retry_count" -lt 2 ]; then
  echo 'Both mutable dependency fetches must use bounded retry/connect-timeout behavior.' >&2
  exit 1
fi

printf 'Dependency contracts passed.\n'
