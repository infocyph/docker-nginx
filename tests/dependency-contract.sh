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

printf 'Dependency contracts passed.\n'
