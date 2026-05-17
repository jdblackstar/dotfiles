#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_HTTPS_URLS=(
  "https://github.com/jdblackstar/dotfiles.git"
  "https://github.com/jdblackstar/dotfiles"
)
EXPECTED_SSH_URL="git@github.com:jdblackstar/dotfiles.git"

log() {
  printf '==> %s\n' "$1"
}

warn() {
  printf 'warning: %s\n' "$1" >&2
}

if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  warn "Not a git repository: $REPO_ROOT"
  exit 1
fi

if ! git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
  warn "Remote 'origin' is not configured"
  exit 1
fi

current_origin_url="$(git -C "$REPO_ROOT" remote get-url origin)"

if [ "$current_origin_url" = "$EXPECTED_SSH_URL" ]; then
  log "Origin already uses SSH"
  exit 0
fi

for https_url in "${EXPECTED_HTTPS_URLS[@]}"; do
  if [ "$current_origin_url" = "$https_url" ]; then
    log "Switching origin from HTTPS to SSH"
    git -C "$REPO_ROOT" remote set-url origin "$EXPECTED_SSH_URL"
    exit 0
  fi
done

warn "Origin uses an unexpected URL, leaving it unchanged: $current_origin_url"