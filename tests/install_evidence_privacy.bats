#!/usr/bin/env bats

load 'helpers/test_helper.bash'

setup() {
  setup_test_env
  HEALTHY_FIXTURE="$PROJECT_ROOT/tests/fixtures/install-evidence/healthy-personal-macos.json"
}

teardown() {
  teardown_test_env
}

@test "fixture output has unverified caller-supplied provenance" {
  local document="$TEST_ROOT/fixture-output.json"

  run "$PROJECT_ROOT/install-evidence" --fixture "$HEALTHY_FIXTURE" --format json

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$document"
  run python3 - "$document" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)

assert document["collection"]["mode"] == "fixture"
assert document["schema_version"] == "1.2.0"
assert document["collection"]["privacy"] == {
    "distribution": "local_only",
    "mode": "fixture_replay",
    "provenance": "caller_supplied_unverified",
    "raw_command_paths_retained": False,
    "raw_error_messages_retained": False,
    "raw_marker_values_retained": False,
    "raw_symlink_targets_retained": False,
    "safe_to_publish": False,
}
PY
  [ "$status" -eq 0 ]
}

@test "synthetic live collection says that host-state output is not publishable" {
  local document="$TEST_ROOT/live-output.json"

  run /usr/bin/env PATH="$TEST_BIN" PYTHONPATH="$PROJECT_ROOT" \
    "$TEST_BIN/python3" -m tools.install_evidence.cli \
    --live --profile agent --platform macos \
    --installed-repo "$HOME/.dotfiles" --format json

  [ "$status" -eq 1 ]
  [[ "$output" != *"$TEST_ROOT"* ]]
  [[ "$output" != *"$HOME"* ]]
  printf '%s\n' "$output" >"$document"
  run python3 - "$document" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)

privacy = document["collection"]["privacy"]
assert document["collection"]["mode"] == "live"
assert privacy["mode"] == "sanitized_local"
assert privacy["distribution"] == "local_only"
assert privacy["contains_host_state"] is True
assert privacy["safe_to_publish"] is False
assert privacy["raw_command_paths_retained"] is False
assert privacy["raw_error_messages_retained"] is False
assert privacy["raw_marker_values_retained"] is False
assert privacy["raw_symlink_targets_retained"] is False
PY
  [ "$status" -eq 0 ]
}

@test "terminal summaries mark fixture and live reports as not publishable" {
  run "$PROJECT_ROOT/install-evidence" --fixture "$HEALTHY_FIXTURE"

  [ "$status" -eq 0 ]
  assert_output_contains "caller-supplied fixture replay"
  assert_output_contains "provenance is unverified"
  assert_output_contains "not safe to publish"

  run /usr/bin/env PATH="$TEST_BIN" PYTHONPATH="$PROJECT_ROOT" \
    "$TEST_BIN/python3" -m tools.install_evidence.cli \
    --live --profile agent --platform macos \
    --installed-repo "$HOME/.dotfiles"

  [ "$status" -eq 1 ]
  assert_output_contains "sanitized live host state; not safe to publish or commit"
}

@test "fixture DOT output has a deterministic local-only privacy warning" {
  run "$PROJECT_ROOT/install-evidence" --fixture "$HEALTHY_FIXTURE" --format dot

  [ "$status" -eq 0 ]
  local first="$output"
  assert_output_contains \
    'Privacy: distribution=local_only; safe_to_publish=false; provenance=caller_supplied_unverified'

  run "$PROJECT_ROOT/install-evidence" --fixture "$HEALTHY_FIXTURE" --format dot

  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
}

@test "synthetic live DOT output warns that it contains host state" {
  run /usr/bin/env PATH="$TEST_BIN" PYTHONPATH="$PROJECT_ROOT" \
    "$TEST_BIN/python3" -m tools.install_evidence.cli \
    --live --profile agent --platform macos \
    --installed-repo "$HOME/.dotfiles" --format dot

  [ "$status" -eq 1 ]
  [[ "$output" != *"$TEST_ROOT"* ]]
  [[ "$output" != *"$HOME"* ]]
  assert_output_contains \
    'Privacy: distribution=local_only; safe_to_publish=false; contains_host_state=true'
}
