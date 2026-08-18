#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if command -v bats >/dev/null 2>&1; then
  BATS_BIN="$(command -v bats)"
  exec "$BATS_BIN" "$ROOT_DIR/tests"
fi

if ! command -v git >/dev/null 2>&1; then
  echo "error: bats is not installed and git is required to fetch bats-core" >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

BATS_CORE_REPOSITORY="https://github.com/bats-core/bats-core.git"
BATS_CORE_COMMIT="eb7f42f8d608ac693d7a4b67474f6714ea68cfc5" # v1.14.0

git init --quiet "$TEMP_DIR/bats-core"
git -C "$TEMP_DIR/bats-core" remote add origin "$BATS_CORE_REPOSITORY"
git -C "$TEMP_DIR/bats-core" fetch --quiet --depth 1 origin "$BATS_CORE_COMMIT"
git -C "$TEMP_DIR/bats-core" checkout --quiet --detach "$BATS_CORE_COMMIT"
exec "$TEMP_DIR/bats-core/bin/bats" "$ROOT_DIR/tests"
