#!/usr/bin/env bash
set -euo pipefail

TEST_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_HELPER_DIR/../.." && pwd)"
STUB_TEMPLATE_DIR="$TEST_HELPER_DIR/stubs"

setup_test_env() {
  export TEST_ROOT
  TEST_ROOT="$(mktemp -d)"
  export TEST_HOME="$TEST_ROOT/home"
  export TEST_BIN="$TEST_ROOT/bin"
  export TEST_STUB_LOG="$TEST_ROOT/stub.log"
  export HOME="$TEST_HOME"
  export PATH="$TEST_BIN:/usr/bin:/bin:/usr/sbin:/sbin"

  mkdir -p "$TEST_HOME" "$TEST_BIN"
  : >"$TEST_STUB_LOG"
}

teardown_test_env() {
  if [ -n "${TEST_ROOT:-}" ] && [ -d "${TEST_ROOT:-}" ]; then
    rm -rf "$TEST_ROOT"
  fi
}

copy_dotfiles_fixture() {
  local destination="${1:-$HOME/.dotfiles}"

  mkdir -p "$destination/config" "$destination/git"

  cp "$PROJECT_ROOT/install.sh" "$destination/install.sh"
  cp "$PROJECT_ROOT/bootstrap.sh" "$destination/bootstrap.sh"
  cp "$PROJECT_ROOT/cleanup.sh" "$destination/cleanup.sh"

  cp "$PROJECT_ROOT/config/.zshrc" "$destination/config/.zshrc"
  cp "$PROJECT_ROOT/config/.aliases" "$destination/config/.aliases"
  cp "$PROJECT_ROOT/config/.vimrc" "$destination/config/.vimrc"
  cp "$PROJECT_ROOT/config/tmux.conf" "$destination/config/tmux.conf"
  cp "$PROJECT_ROOT/config/starship.toml" "$destination/config/starship.toml"
  cp "$PROJECT_ROOT/config/.macos" "$destination/config/.macos"
  cp "$PROJECT_ROOT/config/Brewfile" "$destination/config/Brewfile"

  cp "$PROJECT_ROOT/git/.gitconfig" "$destination/git/.gitconfig"
  cp "$PROJECT_ROOT/git/.gitignore_global" "$destination/git/.gitignore_global"
}

write_minimal_macos_fixture() {
  local dotfiles_dir="$1"

  cat >"$dotfiles_dir/config/.macos" <<'EOF'
#!/bin/bash
printf '%s\n' "fixture-macos-ran"
EOF
}

init_git_repo() {
  local repo_dir="$1"

  git -C "$repo_dir" init -b main >/dev/null
  git -C "$repo_dir" config user.name "Test User"
  git -C "$repo_dir" config user.email "test@example.com"
  git -C "$repo_dir" add . >/dev/null
  git -C "$repo_dir" commit -m "Initial commit" >/dev/null
}

create_bootstrap_remote() {
  local version="${1:-v1}"
  local worktree="$TEST_ROOT/remote-worktree"
  local remote_repo="$TEST_ROOT/remote.git"

  mkdir -p "$worktree"
  cat >"$worktree/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$version" > "\$HOME/install-version.txt"
printf '%s\n' "\$@" > "\$HOME/install-args.txt"
EOF
  cat >"$worktree/README.md" <<EOF
# bootstrap fixture $version
EOF

  init_git_repo "$worktree"
  git clone --bare "$worktree" "$remote_repo" >/dev/null

  printf '%s\n' "$remote_repo"
}

update_bootstrap_remote() {
  local remote_repo="$1"
  local version="$2"
  local worktree="$TEST_ROOT/remote-update-$version"

  git clone "$remote_repo" "$worktree" >/dev/null
  git -C "$worktree" config user.name "Test User"
  git -C "$worktree" config user.email "test@example.com"

  cat >"$worktree/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$version" > "\$HOME/install-version.txt"
printf '%s\n' "\$@" > "\$HOME/install-args.txt"
EOF
  cat >"$worktree/README.md" <<EOF
# bootstrap fixture $version
EOF

  git -C "$worktree" add install.sh README.md >/dev/null
  git -C "$worktree" commit -m "Update to $version" >/dev/null
  git -C "$worktree" push origin main >/dev/null
}

install_stub() {
  local command_name="$1"
  local template_name="$2"

  cp "$STUB_TEMPLATE_DIR/$template_name" "$TEST_BIN/$command_name"
  chmod +x "$TEST_BIN/$command_name"
}

assert_output_contains() {
  local expected="$1"
  [[ "$output" == *"$expected"* ]]
}

assert_file_contains() {
  local file_path="$1"
  local expected="$2"

  [ -f "$file_path" ]
  grep -Fq -- "$expected" "$file_path"
}

assert_symlink_target() {
  local link_path="$1"
  local expected_target="$2"

  [ -L "$link_path" ]
  [ "$(readlink "$link_path")" = "$expected_target" ]
}

assert_log_contains() {
  local expected="$1"
  grep -Fq -- "$expected" "$TEST_STUB_LOG"
}

assert_log_not_contains() {
  local unexpected="$1"
  if [ ! -f "$TEST_STUB_LOG" ]; then
    return 0
  fi

  ! grep -Fq -- "$unexpected" "$TEST_STUB_LOG"
}

count_matches() {
  local pattern="$1"

  find "$(dirname "$pattern")" -maxdepth 1 -name "$(basename "$pattern")" | wc -l | tr -d ' '
}
