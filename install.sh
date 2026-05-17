#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BREWFILE_PATH="$DOTFILES_DIR/config/Brewfile"
MACOS_SCRIPT="$DOTFILES_DIR/config/.macos"
ALACRITTY_CONFIG_DIR="$HOME/.config/alacritty"
ALACRITTY_THEME_PATH="$ALACRITTY_CONFIG_DIR/catppuccin-mocha.toml"
ALACRITTY_THEME_URL="https://github.com/catppuccin/alacritty/raw/main/catppuccin-mocha.toml"
OH_MY_ZSH_DIR="$HOME/.oh-my-zsh"
OH_MY_ZSH_INSTALL_URL="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
TPM_DIR="$HOME/.tmux/plugins/tpm"
SKIP_BREW=0
SKIP_MACOS=0

log() {
  printf '==> %s\n' "$1"
}

warn() {
  printf 'warning: %s\n' "$1" >&2
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    warn "Required command not found: $1"
    exit 1
  fi
}

usage() {
  cat <<'EOF'
Usage: ./install.sh [--no-brew] [--no-macos]

Options:
  --no-brew    Skip Homebrew install/update and Brewfile processing.
  --no-macos   Skip macOS defaults.
EOF
}

ensure_dir() {
  mkdir -p "$1"
}

ensure_symlink() {
  local source_file="$1"
  local target_file="$2"
  local target_dir
  local backup_file

  if [ ! -e "$source_file" ]; then
    warn "Missing source file: $source_file"
    return 1
  fi

  target_dir="$(dirname "$target_file")"
  ensure_dir "$target_dir"

  if [ -L "$target_file" ] && [ "$(readlink "$target_file")" = "$source_file" ]; then
    log "Already linked: $target_file"
    return 0
  fi

  if [ -e "$target_file" ] && [ ! -L "$target_file" ]; then
    backup_file="${target_file}.backup.$(date +%Y%m%d%H%M%S)"
    warn "Backing up existing file: $target_file -> $backup_file"
    mv "$target_file" "$backup_file"
  fi

  ln -sfn "$source_file" "$target_file"
  log "Linked $target_file -> $source_file"
}

# Resolve brew without DOTFILES_TEST_BREW_BIN (used to decide whether to run the real installer).
brew_bin_system_only() {
  if command -v brew >/dev/null 2>&1; then
    command -v brew
    return 0
  fi

  # Hermetic tests: only PATH counts so hosts with Homebrew outside PATH do not skip the test branch.
  if [ "${DOTFILES_TEST_IGNORE_SYSTEM_BREW:-}" = 1 ]; then
    return 1
  fi

  if [ -x /opt/homebrew/bin/brew ]; then
    printf '%s\n' /opt/homebrew/bin/brew
    return 0
  fi

  if [ -x /usr/local/bin/brew ]; then
    printf '%s\n' /usr/local/bin/brew
    return 0
  fi

  return 1
}

brew_bin() {
  # Hermetic tests set this to a stub brew executable (no /opt/homebrew on CI).
  if [ -n "${DOTFILES_TEST_BREW_BIN:-}" ]; then
    printf '%s\n' "$DOTFILES_TEST_BREW_BIN"
    return 0
  fi

  brew_bin_system_only
}

install_homebrew_if_missing() {
  if brew_bin_system_only >/dev/null 2>&1; then
    log "Homebrew already installed"
    return 0
  fi

  # Hermetic tests skip the real Homebrew installer; pair with DOTFILES_TEST_BREW_BIN for bundle steps.
  if [ "${DOTFILES_SKIP_HOMEBREW_INSTALL:-}" = 1 ]; then
    log "Skipping Homebrew install (test mode)"
    return 0
  fi

  log "Installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}

install_oh_my_zsh_if_missing() {
  if [ -d "$OH_MY_ZSH_DIR" ]; then
    log "Oh My Zsh already installed"
    return 0
  fi

  log "Installing Oh My Zsh"
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL "$OH_MY_ZSH_INSTALL_URL")"
}

run_brew_bundle() {
  local brew_cmd

  if [ ! -f "$BREWFILE_PATH" ]; then
    warn "Brewfile not found: $BREWFILE_PATH"
    return 1
  fi

  brew_cmd="$(brew_bin)"
  log "Updating Homebrew"
  "$brew_cmd" update

  if "$brew_cmd" bundle check --file "$BREWFILE_PATH" >/dev/null 2>&1; then
    log "Brewfile already satisfied"
    return 0
  fi

  log "Installing Brewfile dependencies"
  "$brew_cmd" bundle --file "$BREWFILE_PATH"
}

run_macos_defaults() {
  if [[ "$OSTYPE" != darwin* ]]; then
    log "Skipping macOS defaults on non-macOS host"
    return 0
  fi

  if [ ! -f "$MACOS_SCRIPT" ]; then
    warn "macOS defaults script not found: $MACOS_SCRIPT"
    return 1
  fi

  log "Applying macOS defaults"
  /usr/bin/env bash "$MACOS_SCRIPT"
  killall Dock >/dev/null 2>&1 || true
}

download_if_changed() {
  local url="$1"
  local target_file="$2"
  local temp_file

  ensure_dir "$(dirname "$target_file")"
  temp_file="$(mktemp)"

  curl -fsSL "$url" -o "$temp_file"

  if [ -f "$target_file" ] && cmp -s "$temp_file" "$target_file"; then
    rm -f "$temp_file"
    log "Already up to date: $target_file"
    return 0
  fi

  mv "$temp_file" "$target_file"
  log "Updated $target_file"
}

install_tpm_if_missing() {
  ensure_dir "$(dirname "$TPM_DIR")"

  if [ -d "$TPM_DIR/.git" ]; then
    log "TPM already installed"
    return 0
  fi

  if [ -e "$TPM_DIR" ] && [ ! -d "$TPM_DIR/.git" ]; then
    warn "TPM path exists but is not a git repo: $TPM_DIR"
    return 1
  fi

  log "Installing TPM"
  git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-brew)
      SKIP_BREW=1
      ;;
    --no-macos)
      SKIP_MACOS=1
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
  shift
done

require_cmd curl
require_cmd git

log "Preparing config directories"
ensure_dir "$HOME/.config"
ensure_dir "$ALACRITTY_CONFIG_DIR"

log "Linking dotfiles"
ensure_symlink "$DOTFILES_DIR/git/.gitconfig" "$HOME/.gitconfig"
ensure_symlink "$DOTFILES_DIR/git/.gitignore_global" "$HOME/.gitignore_global"
ensure_symlink "$DOTFILES_DIR/config/.zshrc" "$HOME/.zshrc"
ensure_symlink "$DOTFILES_DIR/config/.vimrc" "$HOME/.vimrc"
ensure_symlink "$DOTFILES_DIR/config/tmux.conf" "$HOME/.tmux.conf"
ensure_symlink "$DOTFILES_DIR/config/starship.toml" "$HOME/.config/starship.toml"
ensure_symlink "$DOTFILES_DIR/config/alacritty.toml" "$ALACRITTY_CONFIG_DIR/alacritty.toml"

install_oh_my_zsh_if_missing

if [ "$SKIP_BREW" -eq 0 ]; then
  install_homebrew_if_missing
  run_brew_bundle
else
  log "Skipping Homebrew and Brewfile"
fi

if [ "$SKIP_MACOS" -eq 0 ]; then
  run_macos_defaults
else
  log "Skipping macOS defaults"
fi

download_if_changed "$ALACRITTY_THEME_URL" "$ALACRITTY_THEME_PATH"
install_tpm_if_missing
