#!/usr/bin/env bats

load 'helpers/test_helper.bash'

setup() {
  setup_test_env
  export TEST_DOTFILES="$TEST_ROOT/dotfiles"

  copy_dotfiles_fixture "$TEST_DOTFILES"
  install_stub git git.stub
  install_stub curl curl.stub
  install_stub rg noop.stub
  install_stub fzf noop.stub
  install_stub tmux noop.stub
  install_stub starship noop.stub
  install_stub zoxide noop.stub
  install_stub eza noop.stub
  install_stub nvim noop.stub
}

teardown() {
  teardown_test_env
}

prepare_verified_profile() {
  local profile="$1"
  local gitconfig="$2"

  mkdir -p "$HOME/.config/dotfiles" "$HOME/.config" "$HOME/.tmux/plugins/tpm/.git"
  printf '%s\n' "$profile" >"$HOME/.config/dotfiles/profile"
  printf '%s\n' "macos" >"$HOME/.config/dotfiles/platform"

  ln -s "$gitconfig" "$HOME/.gitconfig"
  ln -s "$TEST_DOTFILES/git/.gitignore_global" "$HOME/.gitignore_global"
  ln -s "$TEST_DOTFILES/config/.zshrc" "$HOME/.zshrc"
  ln -s "$TEST_DOTFILES/config/.vimrc" "$HOME/.vimrc"
  ln -s "$TEST_DOTFILES/config/tmux.conf" "$HOME/.tmux.conf"
  ln -s "$TEST_DOTFILES/config/starship.toml" "$HOME/.config/starship.toml"
  ln -s "$TEST_DOTFILES/config/relay" "$HOME/.config/relay"
}

@test "mac install verifier accepts a personal workstation profile" {
  prepare_verified_profile "personal" "$TEST_DOTFILES/git/.gitconfig"
  mkdir -p "$HOME/.oh-my-zsh"

  run env DOTFILES_DIR="$TEST_DOTFILES" "$PROJECT_ROOT/tests/verify-mac-install.sh" --profile personal

  [ "$status" -eq 0 ]
  assert_output_contains "ok: dotfiles profile marker"
  assert_output_contains "ok: symlink $HOME/.config/relay"
  assert_output_contains "==> 0 error(s), 0 warning(s)"
}

@test "work-laptop verifier delegates to the work profile checks" {
  prepare_verified_profile "work" "$TEST_DOTFILES/git/work.gitconfig"
  mkdir -p "$HOME/.oh-my-zsh"

  run env DOTFILES_DIR="$TEST_DOTFILES" "$PROJECT_ROOT/tests/verify-work-laptop.sh"

  [ "$status" -eq 0 ]
  assert_output_contains "ok: dotfiles profile marker"
  assert_output_contains "Optional local Git identity file is missing: $HOME/.gitconfig.work.local"
  assert_output_contains "==> 0 error(s), 1 warning(s)"
}
