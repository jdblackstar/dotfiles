#!/usr/bin/env bats

load 'helpers/test_helper.bash'

setup() {
  setup_test_env
  export TEST_DOTFILES="$TEST_ROOT/dotfiles"
  export OSTYPE="linux-gnu"
  export STUB_CURL_STDOUT_CONTENT='mkdir -p "$HOME/.oh-my-zsh"'

  copy_dotfiles_fixture "$TEST_DOTFILES"
  install_stub curl curl.stub
  install_stub git git.stub
  install_stub uname uname.stub
  export STUB_UNAME_S="Linux"
}

teardown() {
  teardown_test_env
}

@test "agent profile links terminal and relay config without Homebrew or Oh My Zsh" {
  run bash "$TEST_DOTFILES/install.sh" --profile agent

  [ "$status" -eq 0 ]
  assert_output_contains "Selected profile: agent"
  assert_output_contains "Selected platform: linux"
  assert_output_contains "Skipping Oh My Zsh for profile: agent"
  assert_output_contains "Skipping Linux packages for profile/platform: agent/linux"
  assert_output_contains "Skipping macOS defaults for profile: agent"
  assert_symlink_target "$HOME/.gitconfig" "$TEST_DOTFILES/git/agent.gitconfig"
  assert_symlink_target "$HOME/.gitignore_global" "$TEST_DOTFILES/git/.gitignore_global"
  assert_symlink_target "$HOME/.zshrc" "$TEST_DOTFILES/config/.zshrc"
  assert_symlink_target "$HOME/.vimrc" "$TEST_DOTFILES/config/.vimrc"
  assert_symlink_target "$HOME/.tmux.conf" "$TEST_DOTFILES/config/tmux.conf"
  assert_symlink_target "$HOME/.config/starship.toml" "$TEST_DOTFILES/config/starship.toml"
  assert_symlink_target "$HOME/.config/relay" "$TEST_DOTFILES/config/relay"
  assert_file_contains "$HOME/.config/dotfiles/profile" "agent"
  assert_file_contains "$HOME/.config/dotfiles/platform" "linux"
  [ ! -d "$HOME/.oh-my-zsh" ]
  [ -d "$HOME/.tmux/plugins/tpm/.git" ]
  assert_log_not_contains "brew "
  assert_log_not_contains "curl "
}

@test "install backs up conflicting files and stays rerun-safe" {
  printf 'legacy config\n' >"$HOME/.zshrc"

  run bash "$TEST_DOTFILES/install.sh" --profile agent

  [ "$status" -eq 0 ]
  [ "$(count_matches "$HOME/.zshrc.backup.*")" = "1" ]
  assert_symlink_target "$HOME/.zshrc" "$TEST_DOTFILES/config/.zshrc"

  run bash "$TEST_DOTFILES/install.sh" --profile agent

  [ "$status" -eq 0 ]
  assert_output_contains "Already linked: $HOME/.zshrc"
  [ "$(count_matches "$HOME/.zshrc.backup.*")" = "1" ]
}

@test "install skips TPM clone when already present" {
  mkdir -p "$HOME/.tmux/plugins/tpm/.git"

  run bash "$TEST_DOTFILES/install.sh" --profile agent

  [ "$status" -eq 0 ]
  assert_output_contains "TPM already installed"
}

@test "personal profile runs base and personal Brewfiles when not satisfied" {
  install_stub brew brew.stub
  export DOTFILES_TEST_BREW_BIN="$TEST_BIN/brew"
  export STUB_BREW_BUNDLE_CHECK_STATUS=1

  run bash "$TEST_DOTFILES/install.sh" --profile personal --platform macos

  [ "$status" -eq 0 ]
  assert_output_contains "Selected profile: personal"
  assert_output_contains "Selected platform: macos"
  assert_output_contains "Homebrew already installed"
  assert_output_contains "Updating Homebrew"
  assert_output_contains "Installing Brewfile dependencies: $TEST_DOTFILES/packages/brew/base.Brewfile"
  assert_output_contains "Installing Brewfile dependencies: $TEST_DOTFILES/packages/brew/personal.Brewfile"
  assert_symlink_target "$HOME/.gitconfig" "$TEST_DOTFILES/git/.gitconfig"
  assert_symlink_target "$HOME/.config/relay" "$TEST_DOTFILES/config/relay"
  assert_log_contains "brew update"
  assert_log_contains "brew bundle --file $TEST_DOTFILES/packages/brew/base.Brewfile"
  assert_log_contains "brew bundle --file $TEST_DOTFILES/packages/brew/personal.Brewfile"
}

@test "personal profile skips real Homebrew installer in test mode and satisfies Brewfile checks" {
  # Stub must not be named "brew" on PATH or brew_bin_system_only would skip the installer branch incorrectly.
  cp "$STUB_TEMPLATE_DIR/brew.stub" "$TEST_BIN/brew-for-bundle"
  chmod +x "$TEST_BIN/brew-for-bundle"
  export DOTFILES_SKIP_HOMEBREW_INSTALL=1
  export DOTFILES_TEST_IGNORE_SYSTEM_BREW=1
  export DOTFILES_TEST_BREW_BIN="$TEST_BIN/brew-for-bundle"
  export STUB_BREW_BUNDLE_CHECK_STATUS=0

  run bash "$TEST_DOTFILES/install.sh" --profile personal --platform macos

  [ "$status" -eq 0 ]
  assert_output_contains "Skipping Homebrew install (test mode)"
  assert_output_contains "Brewfile already satisfied: $TEST_DOTFILES/packages/brew/base.Brewfile"
  assert_output_contains "Brewfile already satisfied: $TEST_DOTFILES/packages/brew/personal.Brewfile"
}

@test "work profile links work Git config and relay with base macOS packages only" {
  install_stub brew brew.stub
  export DOTFILES_TEST_BREW_BIN="$TEST_BIN/brew"
  export STUB_BREW_BUNDLE_CHECK_STATUS=0

  run bash "$TEST_DOTFILES/install.sh" --profile work --platform macos

  [ "$status" -eq 0 ]
  assert_output_contains "Selected profile: work"
  assert_output_contains "Selected platform: macos"
  assert_output_contains "Skipping macOS defaults for profile: work"
  assert_symlink_target "$HOME/.gitconfig" "$TEST_DOTFILES/git/work.gitconfig"
  assert_symlink_target "$HOME/.config/relay" "$TEST_DOTFILES/config/relay"
  assert_file_contains "$HOME/.config/dotfiles/profile" "work"
  assert_log_contains "brew bundle check --file $TEST_DOTFILES/packages/brew/base.Brewfile"
}

@test "personal profile applies macOS defaults on Darwin and restarts Dock" {
  export OSTYPE="darwin23"
  export STUB_UNAME_S="Darwin"
  write_minimal_macos_fixture "$TEST_DOTFILES"
  install_stub brew brew.stub
  install_stub killall killall.stub
  export DOTFILES_TEST_BREW_BIN="$TEST_BIN/brew"
  export STUB_BREW_BUNDLE_CHECK_STATUS=0

  run bash "$TEST_DOTFILES/install.sh" --profile personal --platform macos

  [ "$status" -eq 0 ]
  assert_output_contains "Applying macOS defaults"
  assert_output_contains "fixture-macos-ran"
  assert_log_contains "killall Dock"
}

@test "personal Linux profile can skip package installation in test mode" {
  export DOTFILES_SKIP_LINUX_PACKAGES=1

  run bash "$TEST_DOTFILES/install.sh" --profile personal --platform linux

  [ "$status" -eq 0 ]
  assert_output_contains "Selected profile: personal"
  assert_output_contains "Selected platform: linux"
  assert_output_contains "Skipping Linux packages (test mode)"
  assert_output_contains "Skipping macOS defaults for platform: linux"
  assert_symlink_target "$HOME/.gitconfig" "$TEST_DOTFILES/git/.gitconfig"
  assert_file_contains "$HOME/.config/dotfiles/platform" "linux"
  assert_log_not_contains "brew "
}

@test "personal Linux profile runs apt-get directly when already root" {
  local package_line
  local curl_line

  install_stub apt-get apt-get.stub
  install_stub id id.stub
  rm "$TEST_BIN/curl"
  export STUB_APT_GET_INSTALL_BIN_DIR="$TEST_BIN"
  export STUB_ID_U=0

  run bash "$TEST_DOTFILES/install.sh" --profile personal --platform linux

  [ "$status" -eq 0 ]
  assert_output_contains "Installing Linux packages with apt-get"
  assert_log_contains "apt-get update"
  assert_log_contains "apt-get install -y"
  assert_log_contains "zsh"
  assert_log_not_contains "sudo "

  package_line="$(grep -n 'apt-get install -y' "$TEST_STUB_LOG" | head -n 1 | cut -d: -f1)"
  curl_line="$(grep -n '^curl ' "$TEST_STUB_LOG" | head -n 1 | cut -d: -f1)"
  [ "$package_line" -lt "$curl_line" ]
}

@test "personal Linux profile uses safe pacman upgrade and package names" {
  install_stub pacman pacman.stub
  install_stub id id.stub
  export DOTFILES_TEST_LINUX_PACKAGE_MANAGER=pacman
  export STUB_ID_U=0

  run bash "$TEST_DOTFILES/install.sh" --profile personal --platform linux

  [ "$status" -eq 0 ]
  assert_output_contains "Installing Linux packages with pacman"
  assert_log_contains "pacman -Syu --needed --noconfirm"
  assert_log_contains " python "
  assert_log_not_contains "python3"
  assert_log_not_contains "pacman -Sy --needed --noconfirm"
}

@test "install rejects unknown profiles" {
  run bash "$TEST_DOTFILES/install.sh" --profile not-real

  [ "$status" -eq 1 ]
  assert_output_contains "Unknown profile"
}

@test "install rejects unknown platforms" {
  run bash "$TEST_DOTFILES/install.sh" --profile agent --platform plan9

  [ "$status" -eq 1 ]
  assert_output_contains "Unknown platform"
}

@test "install rejects unknown arguments" {
  run bash "$TEST_DOTFILES/install.sh" --profile agent --not-a-real-flag

  [ "$status" -eq 1 ]
  assert_output_contains "Unknown argument"
}

@test "install fails when TPM path exists but is not a git repo" {
  mkdir -p "$HOME/.tmux/plugins/tpm"
  printf 'blocker\n' >"$HOME/.tmux/plugins/tpm/readme.txt"

  run bash "$TEST_DOTFILES/install.sh" --profile agent

  [ "$status" -eq 1 ]
  assert_output_contains "TPM path exists but is not a git repo"
}
