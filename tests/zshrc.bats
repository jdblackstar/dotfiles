#!/usr/bin/env bats

load 'helpers/test_helper.bash'

setup() {
  setup_test_env
  copy_dotfiles_fixture "$HOME/.dotfiles"
  mkdir -p "$HOME/.dotfiles/functions"
  cat >"$HOME/.dotfiles/functions/.test_fixture" <<'EOF'
export TEST_FUNCTIONS_LOADED=1
EOF
}

teardown() {
  teardown_test_env
}

@test "zshrc passes syntax validation" {
  run zsh -n "$PROJECT_ROOT/config/.zshrc"

  [ "$status" -eq 0 ]
}

@test "zshrc loads cleanly without optional tools installed" {
  run env HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    zsh -f -c 'OSTYPE=darwin23; source "$HOME/.dotfiles/config/.zshrc"; print -r -- "TEST_FUNCTIONS_LOADED=${TEST_FUNCTIONS_LOADED:-missing}"; print -r -- "$FZF_DEFAULT_COMMAND"; print -r -- "$PATH"'

  [ "$status" -eq 0 ]
  assert_output_contains "TEST_FUNCTIONS_LOADED=1"
  assert_output_contains "!Library"
  assert_output_contains "$HOME/.npm-global/bin"
  assert_output_contains "$HOME/.local/bin"
}
