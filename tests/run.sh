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

git clone --depth 1 https://github.com/bats-core/bats-core "$TEMP_DIR/bats-core" >/dev/null 2>&1
exec "$TEMP_DIR/bats-core/bin/bats" "$ROOT_DIR/tests"
