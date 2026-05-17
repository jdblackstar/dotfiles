#!/usr/bin/env bats

load 'helpers/test_helper.bash'

setup() {
  setup_test_env
  export TEST_DOTFILES="$HOME/.dotfiles"
  copy_dotfiles_fixture "$TEST_DOTFILES"
  init_git_repo "$TEST_DOTFILES"
}

teardown() {
  teardown_test_env
}

@test "cleanup switches expected HTTPS origin to SSH" {
  git -C "$TEST_DOTFILES" remote add origin "https://github.com/jdblackstar/dotfiles.git"

  run bash "$TEST_DOTFILES/cleanup.sh"

  [ "$status" -eq 0 ]
  assert_output_contains "Switching origin from HTTPS to SSH"
  [ "$(git -C "$TEST_DOTFILES" remote get-url origin)" = "git@github.com:jdblackstar/dotfiles.git" ]
}

@test "cleanup exits cleanly when origin already uses SSH" {
  git -C "$TEST_DOTFILES" remote add origin "git@github.com:jdblackstar/dotfiles.git"

  run bash "$TEST_DOTFILES/cleanup.sh"

  [ "$status" -eq 0 ]
  assert_output_contains "Origin already uses SSH"
  [ "$(git -C "$TEST_DOTFILES" remote get-url origin)" = "git@github.com:jdblackstar/dotfiles.git" ]
}

@test "cleanup leaves unexpected remotes untouched" {
  git -C "$TEST_DOTFILES" remote add origin "git@github.com:someone-else/dotfiles.git"

  run bash "$TEST_DOTFILES/cleanup.sh"

  [ "$status" -eq 0 ]
  assert_output_contains "Origin uses an unexpected URL, leaving it unchanged"
  [ "$(git -C "$TEST_DOTFILES" remote get-url origin)" = "git@github.com:someone-else/dotfiles.git" ]
}

@test "cleanup fails when origin is missing" {
  run bash "$TEST_DOTFILES/cleanup.sh"

  [ "$status" -eq 1 ]
  assert_output_contains "Remote 'origin' is not configured"
}
