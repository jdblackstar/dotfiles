#!/usr/bin/env bats

load 'helpers/test_helper.bash'

setup() {
  setup_test_env
  export REMOTE_REPO
  REMOTE_REPO="$(create_bootstrap_remote "v1")"
}

teardown() {
  teardown_test_env
}

@test "bootstrap clones a missing repo and forwards installer arguments" {
  run env DOTFILES_REPO_URL="$REMOTE_REPO" DOTFILES_DIR="$HOME/.dotfiles" \
    sh "$PROJECT_ROOT/bootstrap.sh" --no-brew

  [ "$status" -eq 0 ]
  [ -d "$HOME/.dotfiles/.git" ]
  assert_file_contains "$HOME/install-version.txt" "v1"
  assert_file_contains "$HOME/install-args.txt" "--no-brew"
}

@test "bootstrap fast-forwards a clean repo before running the installer" {
  git clone "$REMOTE_REPO" "$HOME/.dotfiles" >/dev/null
  original_head="$(git -C "$HOME/.dotfiles" rev-parse HEAD)"
  update_bootstrap_remote "$REMOTE_REPO" "v2"

  run env DOTFILES_REPO_URL="$REMOTE_REPO" DOTFILES_DIR="$HOME/.dotfiles" \
    sh "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 0 ]
  assert_output_contains "Updating existing dotfiles repo"
  assert_file_contains "$HOME/install-version.txt" "v2"
  [ "$(git -C "$HOME/.dotfiles" rev-parse HEAD)" != "$original_head" ]
}

@test "bootstrap leaves a dirty repo untouched and still runs the local installer" {
  git clone "$REMOTE_REPO" "$HOME/.dotfiles" >/dev/null
  local_head="$(git -C "$HOME/.dotfiles" rev-parse HEAD)"
  update_bootstrap_remote "$REMOTE_REPO" "v2"
  printf 'dirty\n' >>"$HOME/.dotfiles/README.md"

  run env DOTFILES_REPO_URL="$REMOTE_REPO" DOTFILES_DIR="$HOME/.dotfiles" \
    sh "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 0 ]
  assert_output_contains "Dotfiles repo has local changes; leaving it untouched."
  assert_file_contains "$HOME/install-version.txt" "v1"
  [ "$(git -C "$HOME/.dotfiles" rev-parse HEAD)" = "$local_head" ]
}

@test "bootstrap fails when the destination exists but is not a git repo" {
  mkdir -p "$HOME/.dotfiles"
  printf 'not a repo\n' >"$HOME/.dotfiles/README.md"

  run env DOTFILES_REPO_URL="$REMOTE_REPO" DOTFILES_DIR="$HOME/.dotfiles" \
    sh "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 1 ]
  assert_output_contains "Path exists but is not a git repo"
}

@test "bootstrap on Darwin without git triggers Command Line Tools installer and exits" {
  install_stub uname uname.stub
  install_stub xcode-select xcode-select.stub
  export STUB_UNAME_S="Darwin"

  run env PATH="$TEST_BIN" HOME="$HOME" \
    DOTFILES_REPO_URL="$REMOTE_REPO" DOTFILES_DIR="$HOME/.dotfiles" \
    /bin/sh "$PROJECT_ROOT/bootstrap.sh"

  [ "$status" -eq 1 ]
  assert_output_contains "Launching Command Line Tools installer"
  assert_output_contains "Re-run this installer after Command Line Tools finishes installing."
  assert_log_contains "xcode-select --install"
}
