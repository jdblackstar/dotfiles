#!/usr/bin/env bash
# Non-mutating checks for a Mac work-laptop install. Run after bootstrap/install.
# Exit 0 if required checks pass; exit 1 if any required check fails. Warnings do not affect exit code.
# Do not use `set -e`: checks record errors and continue.
set -uo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
ERRORS=0
WARNINGS=0

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

  if [ ! -L "$link_path" ]; then
    err "Expected symlink: $link_path"
    return 1
  fi
  local actual
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

require_file() {
  local path="$1"
  local label="$2"
  if [ ! -f "$path" ]; then
    err "Missing $label: $path"
    return 1
  fi
  info "$label"
  return 0
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  warn "This verifier targets macOS; some checks may not apply."
fi

if [ ! -d "$DOTFILES_DIR" ]; then
  err "Dotfiles repo not found: $DOTFILES_DIR (set DOTFILES_DIR if needed)"
  printf '==> %d error(s), %d warning(s)\n' "$ERRORS" "$WARNINGS"
  exit 1
fi

# Symlinks created by install.sh (paths must match install.sh)
require_symlink "$HOME/.gitconfig" "$DOTFILES_DIR/git/.gitconfig"
require_symlink "$HOME/.gitignore_global" "$DOTFILES_DIR/git/.gitignore_global"
require_symlink "$HOME/.zshrc" "$DOTFILES_DIR/config/.zshrc"
require_symlink "$HOME/.vimrc" "$DOTFILES_DIR/config/.vimrc"
require_symlink "$HOME/.tmux.conf" "$DOTFILES_DIR/config/tmux.conf"
require_symlink "$HOME/.config/starship.toml" "$DOTFILES_DIR/config/starship.toml"
require_symlink "$HOME/.config/alacritty/alacritty.toml" "$DOTFILES_DIR/config/alacritty.toml"

# CLI tools from Brewfile (formula names -> common binaries)
require_command git
require_command curl
require_command rg
require_command fzf
require_command tmux
require_command starship
require_command zoxide
require_command eza
require_command nvim

# Oh My Zsh, TPM, Alacritty theme (install.sh)
require_dir "$HOME/.oh-my-zsh" "Oh My Zsh directory"
require_git_dir "$HOME/.tmux/plugins/tpm" "TPM"
require_file "$HOME/.config/alacritty/catppuccin-mocha.toml" "Alacritty Catppuccin theme"

# Optional: 1Password SSH signer referenced by managed .gitconfig
if [ -f "$DOTFILES_DIR/git/.gitconfig" ] && grep -q 'op-ssh-sign' "$DOTFILES_DIR/git/.gitconfig" 2>/dev/null; then
  _signer_path=""
  _signer_path="$(git config --file "$DOTFILES_DIR/git/.gitconfig" --get gpg.ssh.program 2>/dev/null || true)"
  if [ -n "$_signer_path" ] && [ ! -x "$_signer_path" ]; then
    warn "Git signing program not executable (install 1Password or adjust git config): $_signer_path"
  fi
fi

printf '\n==> %d error(s), %d warning(s)\n' "$ERRORS" "$WARNINGS"
if [ "$ERRORS" -gt 0 ]; then
  exit 1
fi
exit 0
