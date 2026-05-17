#!/bin/sh
set -eu

DOTFILES_REPO_URL="${DOTFILES_REPO_URL:-https://github.com/jdblackstar/dotfiles.git}"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"

log() {
  printf '==> %s\n' "$1"
}

warn() {
  printf 'warning: %s\n' "$1" >&2
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    warn "Required command not found: $1"
    return 1
  fi
}

ensure_git_available() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi

  if [ "$(uname -s)" = "Darwin" ] && command -v xcode-select >/dev/null 2>&1; then
    warn "Git is not available yet. Launching Command Line Tools installer."
    xcode-select --install || true
    warn "Re-run this installer after Command Line Tools finishes installing."
    exit 1
  fi

  warn "Git is required to continue."
  exit 1
}

clone_or_update_repo() {
  if [ ! -e "$DOTFILES_DIR" ]; then
    log "Cloning dotfiles repo into $DOTFILES_DIR"
    git clone "$DOTFILES_REPO_URL" "$DOTFILES_DIR"
    return 0
  fi

  if [ ! -d "$DOTFILES_DIR/.git" ]; then
    warn "Path exists but is not a git repo: $DOTFILES_DIR"
    exit 1
  fi

  if [ -n "$(git -C "$DOTFILES_DIR" status --porcelain)" ]; then
    warn "Dotfiles repo has local changes; leaving it untouched."
    return 0
  fi

  log "Updating existing dotfiles repo"
  git -C "$DOTFILES_DIR" fetch --quiet origin
  git -C "$DOTFILES_DIR" pull --ff-only --quiet
}

run_local_installer() {
  if [ ! -f "$DOTFILES_DIR/install.sh" ]; then
    warn "Local installer not found: $DOTFILES_DIR/install.sh"
    exit 1
  fi

  log "Running local installer"
  exec bash "$DOTFILES_DIR/install.sh" "$@"
}

require_cmd uname
ensure_git_available
require_cmd bash

clone_or_update_repo
run_local_installer "$@"
