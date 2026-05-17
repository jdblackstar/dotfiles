#!/usr/bin/env bats

load 'helpers/test_helper.bash'

setup() {
  setup_test_env
  export TEST_DOTFILES="$TEST_ROOT/dotfiles"
  export OSTYPE="linux-gnu"
  export STUB_CURL_STDOUT_CONTENT='mkdir -p "$HOME/.oh-my-zsh"'
  export STUB_CURL_FILE_CONTENT='catppuccin-theme'

  copy_dotfiles_fixture "$TEST_DOTFILES"
  install_stub curl curl.stub
  install_stub git git.stub
}

teardown() {
  teardown_test_env
}

@test "install links managed files and skips brew when --no-brew is passed" {
  run bash "$TEST_DOTFILES/install.sh" --no-brew

  [ "$status" -eq 0 ]
  assert_output_contains "Skipping Homebrew and Brewfile"
  assert_symlink_target "$HOME/.gitconfig" "$TEST_DOTFILES/git/.gitconfig"
  assert_symlink_target "$HOME/.gitignore_global" "$TEST_DOTFILES/git/.gitignore_global"
  assert_symlink_target "$HOME/.zshrc" "$TEST_DOTFILES/config/.zshrc"
  assert_symlink_target "$HOME/.vimrc" "$TEST_DOTFILES/config/.vimrc"
  assert_symlink_target "$HOME/.tmux.conf" "$TEST_DOTFILES/config/tmux.conf"
  assert_symlink_target "$HOME/.config/starship.toml" "$TEST_DOTFILES/config/starship.toml"
  assert_symlink_target "$HOME/.config/alacritty/alacritty.toml" "$TEST_DOTFILES/config/alacritty.toml"
  [ -d "$HOME/.oh-my-zsh" ]
  [ -d "$HOME/.tmux/plugins/tpm/.git" ]
  assert_file_contains "$HOME/.config/alacritty/catppuccin-mocha.toml" "catppuccin-theme"
  assert_log_not_contains "brew "
}

@test "install backs up conflicting files and stays rerun-safe" {
  printf 'legacy config\n' >"$HOME/.zshrc"

  run bash "$TEST_DOTFILES/install.sh" --no-brew

  [ "$status" -eq 0 ]
  [ "$(count_matches "$HOME/.zshrc.backup.*")" = "1" ]
  assert_symlink_target "$HOME/.zshrc" "$TEST_DOTFILES/config/.zshrc"

  run bash "$TEST_DOTFILES/install.sh" --no-brew

  [ "$status" -eq 0 ]
  assert_output_contains "Already linked: $HOME/.zshrc"
  [ "$(count_matches "$HOME/.zshrc.backup.*")" = "1" ]
}

@test "install skips TPM clone and theme rewrite when both are already present" {
  mkdir -p "$HOME/.config/alacritty"
  printf '%s' "$STUB_CURL_FILE_CONTENT" >"$HOME/.config/alacritty/catppuccin-mocha.toml"
  mkdir -p "$HOME/.tmux/plugins/tpm/.git"

  run bash "$TEST_DOTFILES/install.sh" --no-brew

  [ "$status" -eq 0 ]
  assert_output_contains "Already up to date: $HOME/.config/alacritty/catppuccin-mocha.toml"
  assert_output_contains "TPM already installed"
}

@test "install runs brew update and bundle when Brewfile is not satisfied" {
  install_stub brew brew.stub
  export DOTFILES_TEST_BREW_BIN="$TEST_BIN/brew"
  export STUB_BREW_BUNDLE_CHECK_STATUS=1

  run bash "$TEST_DOTFILES/install.sh"

  [ "$status" -eq 0 ]
  assert_output_contains "Homebrew already installed"
  assert_output_contains "Updating Homebrew"
  assert_output_contains "Installing Brewfile dependencies"
  assert_log_contains "brew update"
  assert_log_contains "brew bundle --file"
}

@test "install skips real Homebrew installer in test mode and satisfies Brewfile check" {
  # Stub must not be named "brew" on PATH or brew_bin_system_only would skip the installer branch incorrectly.
  cp "$STUB_TEMPLATE_DIR/brew.stub" "$TEST_BIN/brew-for-bundle"
  chmod +x "$TEST_BIN/brew-for-bundle"
  export DOTFILES_SKIP_HOMEBREW_INSTALL=1
  export DOTFILES_TEST_IGNORE_SYSTEM_BREW=1
  export DOTFILES_TEST_BREW_BIN="$TEST_BIN/brew-for-bundle"
  export STUB_BREW_BUNDLE_CHECK_STATUS=0

  run bash "$TEST_DOTFILES/install.sh"

  [ "$status" -eq 0 ]
  assert_output_contains "Skipping Homebrew install (test mode)"
  assert_output_contains "Brewfile already satisfied"
}

@test "install applies macOS defaults on Darwin and restarts Dock" {
  export OSTYPE="darwin23"
  write_minimal_macos_fixture "$TEST_DOTFILES"
  install_stub killall killall.stub

  run bash "$TEST_DOTFILES/install.sh" --no-brew

  [ "$status" -eq 0 ]
  assert_output_contains "Applying macOS defaults"
  assert_output_contains "fixture-macos-ran"
  assert_log_contains "killall Dock"
}

@test "install rejects unknown arguments" {
  run bash "$TEST_DOTFILES/install.sh" --no-brew --not-a-real-flag

  [ "$status" -eq 1 ]
  assert_output_contains "Unknown argument"
}

@test "install fails when TPM path exists but is not a git repo" {
  mkdir -p "$HOME/.tmux/plugins/tpm"
  printf 'blocker\n' >"$HOME/.tmux/plugins/tpm/readme.txt"

  run bash "$TEST_DOTFILES/install.sh" --no-brew

  [ "$status" -eq 1 ]
  assert_output_contains "TPM path exists but is not a git repo"
}
