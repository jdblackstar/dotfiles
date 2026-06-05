#!/usr/bin/env bash
# Non-mutating checks for a macOS dotfiles install. Run after bootstrap/install.
# Exit 0 if required checks pass; exit 1 if any required check fails. Warnings do not affect exit code.
# Do not use `set -e`: checks record errors and continue.
set -uo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
PROFILE="personal"
ERRORS=0
WARNINGS=0

usage() {
  cat <<'EOF'
Usage: tests/verify-mac-install.sh [--profile personal|work|agent]
EOF
}

err() {
  printf 'error: %s\n' "$1" >&2
  ERRORS=$((ERRORS + 1))
}

warn() {
  printf 'warning: %s\n' "$1" >&2
  WARNINGS=$((WARNINGS + 1))
}

info() {
  printf 'ok: %s\n' "$1"
}

require_symlink() {
  local link_path="$1"
  local expected_target="$2"
  local actual

  if [ ! -L "$link_path" ]; then
    err "Expected symlink: $link_path"
    return 1
  fi

  actual="$(readlink "$link_path")"
  if [ "$actual" != "$expected_target" ]; then
    err "Symlink $link_path -> $actual (expected $expected_target)"
    return 1
  fi

  info "symlink $link_path"
  return 0
}

require_command() {
  local name="$1"

  if ! command -v "$name" >/dev/null 2>&1; then
    err "Command not on PATH: $name"
    return 1
  fi

  info "command $name"
  return 0
}

require_dir() {
  local path="$1"
  local label="$2"

  if [ ! -d "$path" ]; then
    err "Missing $label: $path"
    return 1
  fi

  info "$label"
  return 0
}

require_git_dir() {
  local path="$1"
  local label="$2"

  if [ ! -d "$path/.git" ]; then
    err "Missing git repo ($label): $path"
    return 1
  fi

  info "git repo $label"
  return 0
}

require_file_contains() {
  local path="$1"
  local expected="$2"
  local label="$3"

  if [ ! -f "$path" ]; then
    err "Missing $label: $path"
    return 1
  fi

  if ! grep -Fq -- "$expected" "$path"; then
    err "$label did not contain expected value: $expected"
    return 1
  fi

  info "$label"
  return 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      if [ -z "${2:-}" ]; then
        warn "--profile requires a value"
        usage >&2
        exit 1
      fi
      PROFILE="$2"
      shift 2
      ;;
    --profile=*)
      PROFILE="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      warn "Unknown argument: $1"
      usage >&2
      exit 1
      ;;
  esac
done

case "$PROFILE" in
  personal|work|agent)
    ;;
  *)
    warn "Unknown profile: $PROFILE"
    usage >&2
    exit 1
    ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
  warn "This verifier targets macOS; some checks may not apply."
fi

if [ ! -d "$DOTFILES_DIR" ]; then
  err "Dotfiles repo not found: $DOTFILES_DIR (set DOTFILES_DIR if needed)"
  printf '==> %d error(s), %d warning(s)\n' "$ERRORS" "$WARNINGS"
  exit 1
fi

case "$PROFILE" in
  personal)
    gitconfig="$DOTFILES_DIR/git/.gitconfig"
    installs_oh_my_zsh=1
    installs_package_tools=1
    local_identity=""
    ;;
  work)
    gitconfig="$DOTFILES_DIR/git/work.gitconfig"
    installs_oh_my_zsh=1
    installs_package_tools=1
    local_identity="$HOME/.gitconfig.work.local"
    ;;
  agent)
    gitconfig="$DOTFILES_DIR/git/agent.gitconfig"
    installs_oh_my_zsh=0
    installs_package_tools=0
    local_identity="$HOME/.gitconfig.agent.local"
    ;;
esac

require_file_contains "$HOME/.config/dotfiles/profile" "$PROFILE" "dotfiles profile marker"
require_file_contains "$HOME/.config/dotfiles/platform" "macos" "dotfiles platform marker"
require_symlink "$HOME/.gitconfig" "$gitconfig"
require_symlink "$HOME/.gitignore_global" "$DOTFILES_DIR/git/.gitignore_global"
require_symlink "$HOME/.zshrc" "$DOTFILES_DIR/config/.zshrc"
require_symlink "$HOME/.vimrc" "$DOTFILES_DIR/config/.vimrc"
require_symlink "$HOME/.tmux.conf" "$DOTFILES_DIR/config/tmux.conf"
require_symlink "$HOME/.config/starship.toml" "$DOTFILES_DIR/config/starship.toml"
require_symlink "$HOME/.config/relay" "$DOTFILES_DIR/config/relay"

require_command git

if [ "$installs_package_tools" -eq 1 ]; then
  require_command curl
  require_command rg
  require_command fzf
  require_command tmux
  require_command starship
  require_command zoxide
  require_command eza
  require_command nvim
fi

if [ "$installs_oh_my_zsh" -eq 1 ]; then
  require_dir "$HOME/.oh-my-zsh" "Oh My Zsh directory"
fi
require_git_dir "$HOME/.tmux/plugins/tpm" "TPM"

if [ -n "$local_identity" ] && [ ! -f "$local_identity" ]; then
  warn "Optional local Git identity file is missing: $local_identity"
fi

printf '\n==> %d error(s), %d warning(s)\n' "$ERRORS" "$WARNINGS"
if [ "$ERRORS" -gt 0 ]; then
  exit 1
fi
exit 0
