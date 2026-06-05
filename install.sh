#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="$DOTFILES_DIR/profiles"
PLATFORMS_DIR="$DOTFILES_DIR/platforms"
MACOS_SCRIPT="$DOTFILES_DIR/config/.macos"
OH_MY_ZSH_DIR="$HOME/.oh-my-zsh"
OH_MY_ZSH_INSTALL_URL="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
TPM_DIR="$HOME/.tmux/plugins/tpm"
PROFILE="personal"
PLATFORM=""

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
Usage: ./install.sh [--profile personal|work|agent] [--platform macos|linux]

Profiles:
  personal  Daily personal setup: terminal, personal apps/tools, personal Git identity.
  work      Daily coding setup: shared dev tools, relay config, work-safe Git config.
  agent     Headless dev setup: terminal links, relay config, no GUI package layer.

Platforms:
  macos     Homebrew package layers and optional macOS defaults.
  linux     Linux package layers when available; no macOS defaults.

If --platform is omitted, it is detected from uname.
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

  if [ -L "$target_file" ]; then
    rm "$target_file"
  elif [ -e "$target_file" ]; then
    backup_file="${target_file}.backup.$(date +%Y%m%d%H%M%S)"
    warn "Backing up existing file: $target_file -> $backup_file"
    mv "$target_file" "$backup_file"
  fi

  ln -s "$source_file" "$target_file"
  log "Linked $target_file -> $source_file"
}

load_profile() {
  local profile_file="$PROFILES_DIR/$PROFILE.sh"

  case "$PROFILE" in
    personal|work|agent)
      ;;
    *)
      warn "Unknown profile: $PROFILE"
      usage >&2
      exit 1
      ;;
  esac

  if [ ! -f "$profile_file" ]; then
    warn "Profile file not found: $profile_file"
    exit 1
  fi

  PROFILE_NAME="$PROFILE"
  PROFILE_GITCONFIG="$DOTFILES_DIR/git/.gitconfig"
  PROFILE_MACOS_BREWFILES=()
  PROFILE_LINUX_PACKAGE_FILES=()
  PROFILE_INSTALL_OH_MY_ZSH=0
  PROFILE_INSTALL_TPM=1
  PROFILE_RUN_MACOS_DEFAULTS=0
  PROFILE_LINK_RELAY=0

  # shellcheck source=/dev/null
  source "$profile_file"
}

detect_platform() {
  local uname_s

  uname_s="$(uname -s)"
  case "$uname_s" in
    Darwin)
      PLATFORM="macos"
      ;;
    Linux)
      PLATFORM="linux"
      ;;
    *)
      warn "Unsupported platform from uname -s: $uname_s"
      usage >&2
      exit 1
      ;;
  esac
}

load_platform() {
  local platform_file

  if [ -z "$PLATFORM" ]; then
    detect_platform
  fi

  platform_file="$PLATFORMS_DIR/$PLATFORM.sh"
  case "$PLATFORM" in
    macos|linux)
      ;;
    *)
      warn "Unknown platform: $PLATFORM"
      usage >&2
      exit 1
      ;;
  esac

  if [ ! -f "$platform_file" ]; then
    warn "Platform file not found: $platform_file"
    exit 1
  fi

  PLATFORM_NAME="$PLATFORM"
  PLATFORM_PACKAGE_MANAGER="none"
  PLATFORM_SUPPORTS_MACOS_DEFAULTS=0

  # shellcheck source=/dev/null
  source "$platform_file"
}

write_install_markers() {
  ensure_dir "$HOME/.config/dotfiles"
  printf '%s\n' "$PROFILE_NAME" >"$HOME/.config/dotfiles/profile"
  printf '%s\n' "$PLATFORM_NAME" >"$HOME/.config/dotfiles/platform"
  log "Selected profile: $PROFILE_NAME"
  log "Selected platform: $PLATFORM_NAME"
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
  if [ "$PROFILE_INSTALL_OH_MY_ZSH" -eq 0 ]; then
    log "Skipping Oh My Zsh for profile: $PROFILE_NAME"
    return 0
  fi

  if [ -d "$OH_MY_ZSH_DIR" ]; then
    log "Oh My Zsh already installed"
    return 0
  fi

  log "Installing Oh My Zsh"
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL "$OH_MY_ZSH_INSTALL_URL")"
}

run_brew_bundles() {
  local brew_cmd
  local brewfile

  if [ "$PLATFORM_PACKAGE_MANAGER" != "brew" ]; then
    return 0
  fi

  if [ "${#PROFILE_MACOS_BREWFILES[@]}" -eq 0 ]; then
    log "Skipping Homebrew and Brewfile for profile/platform: $PROFILE_NAME/$PLATFORM_NAME"
    return 0
  fi

  install_homebrew_if_missing

  brew_cmd="$(brew_bin)"
  log "Updating Homebrew"
  "$brew_cmd" update

  for brewfile in "${PROFILE_MACOS_BREWFILES[@]}"; do
    if [ ! -f "$brewfile" ]; then
      warn "Brewfile not found: $brewfile"
      return 1
    fi

    if "$brew_cmd" bundle check --file "$brewfile" >/dev/null 2>&1; then
      log "Brewfile already satisfied: $brewfile"
      continue
    fi

    log "Installing Brewfile dependencies: $brewfile"
    "$brew_cmd" bundle --file "$brewfile"
  done
}

linux_package_manager() {
  if [ -n "${DOTFILES_TEST_LINUX_PACKAGE_MANAGER:-}" ]; then
    printf '%s\n' "$DOTFILES_TEST_LINUX_PACKAGE_MANAGER"
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    printf '%s\n' apt-get
    return 0
  fi

  if command -v dnf >/dev/null 2>&1; then
    printf '%s\n' dnf
    return 0
  fi

  if command -v pacman >/dev/null 2>&1; then
    printf '%s\n' pacman
    return 0
  fi

  return 1
}

linux_package_name() {
  local package_manager="$1"
  local package_name="$2"

  case "$package_manager:$package_name" in
    pacman:python3)
      printf '%s\n' python
      ;;
    *)
      printf '%s\n' "$package_name"
      ;;
  esac
}

run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return $?
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    warn "sudo is required to install Linux packages when not running as root"
    return 1
  fi

  sudo "$@"
}

run_linux_packages() {
  local package_manager
  local package_file
  local packages=()

  if [ "$PLATFORM_PACKAGE_MANAGER" != "linux" ]; then
    return 0
  fi

  if [ "${#PROFILE_LINUX_PACKAGE_FILES[@]}" -eq 0 ]; then
    log "Skipping Linux packages for profile/platform: $PROFILE_NAME/$PLATFORM_NAME"
    return 0
  fi

  if [ "${DOTFILES_SKIP_LINUX_PACKAGES:-}" = 1 ]; then
    log "Skipping Linux packages (test mode)"
    return 0
  fi

  if ! package_manager="$(linux_package_manager)"; then
    warn "No supported Linux package manager found; skipping Linux packages"
    return 0
  fi

  for package_file in "${PROFILE_LINUX_PACKAGE_FILES[@]}"; do
    if [ ! -f "$package_file" ]; then
      warn "Linux package file not found: $package_file"
      return 1
    fi

    while IFS= read -r package_name; do
      case "$package_name" in
        ""|\#*)
          continue
          ;;
      esac
      packages+=("$(linux_package_name "$package_manager" "$package_name")")
    done <"$package_file"
  done

  if [ "${#packages[@]}" -eq 0 ]; then
    log "No Linux packages selected for profile/platform: $PROFILE_NAME/$PLATFORM_NAME"
    return 0
  fi

  log "Installing Linux packages with $package_manager"
  case "$package_manager" in
    apt-get)
      run_privileged apt-get update
      run_privileged apt-get install -y "${packages[@]}"
      ;;
    dnf)
      run_privileged dnf install -y "${packages[@]}"
      ;;
    pacman)
      run_privileged pacman -Syu --needed --noconfirm "${packages[@]}"
      ;;
  esac
}

run_macos_defaults() {
  if [ "$PROFILE_RUN_MACOS_DEFAULTS" -eq 0 ]; then
    log "Skipping macOS defaults for profile: $PROFILE_NAME"
    return 0
  fi

  if [ "$PLATFORM_SUPPORTS_MACOS_DEFAULTS" -eq 0 ]; then
    log "Skipping macOS defaults for platform: $PLATFORM_NAME"
    return 0
  fi

  if [ "$(uname -s)" != "Darwin" ]; then
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

install_tpm_if_missing() {
  if [ "$PROFILE_INSTALL_TPM" -eq 0 ]; then
    log "Skipping TPM for profile: $PROFILE_NAME"
    return 0
  fi

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

link_relay_config() {
  if [ "$PROFILE_LINK_RELAY" -eq 0 ]; then
    return 0
  fi

  ensure_symlink "$DOTFILES_DIR/config/relay" "$HOME/.config/relay"
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
    --platform)
      if [ -z "${2:-}" ]; then
        warn "--platform requires a value"
        usage >&2
        exit 1
      fi
      PLATFORM="$2"
      shift 2
      ;;
    --platform=*)
      PLATFORM="${1#*=}"
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

load_profile
load_platform

log "Preparing config directories"
ensure_dir "$HOME/.config"
write_install_markers

log "Linking dotfiles"
ensure_symlink "$PROFILE_GITCONFIG" "$HOME/.gitconfig"
ensure_symlink "$DOTFILES_DIR/git/.gitignore_global" "$HOME/.gitignore_global"
ensure_symlink "$DOTFILES_DIR/config/.zshrc" "$HOME/.zshrc"
ensure_symlink "$DOTFILES_DIR/config/.vimrc" "$HOME/.vimrc"
ensure_symlink "$DOTFILES_DIR/config/tmux.conf" "$HOME/.tmux.conf"
ensure_symlink "$DOTFILES_DIR/config/starship.toml" "$HOME/.config/starship.toml"
link_relay_config

run_linux_packages
install_oh_my_zsh_if_missing
run_brew_bundles
run_macos_defaults
if [ "$PROFILE_INSTALL_TPM" -eq 1 ]; then
  require_cmd git
fi
install_tpm_if_missing
