#!/usr/bin/env bats

load 'helpers/test_helper.bash'

setup() {
  setup_test_env
  HEALTHY_FIXTURE="$PROJECT_ROOT/tests/fixtures/install-evidence/healthy-personal-macos.json"
}

teardown() {
  teardown_test_env
}

@test "fixture input must be a regular file and its final link is not followed" {
  local link="$TEST_ROOT/fixture-link.json"
  local fifo="$TEST_ROOT/fixture-fifo.json"
  ln -s "$HEALTHY_FIXTURE" "$link"
  mkfifo "$fifo"

  run "$PROJECT_ROOT/install-evidence" --fixture "$link"
  [ "$status" -eq 64 ]
  assert_output_contains "cannot read fixture data"

  run "$PROJECT_ROOT/install-evidence" --fixture "$fifo"
  [ "$status" -eq 64 ]
  assert_output_contains "fixture must be a regular file"

  run "$PROJECT_ROOT/install-evidence" --fixture "$TEST_ROOT"
  [ "$status" -eq 64 ]
  assert_output_contains "fixture must be a regular file"
}

@test "fixture JSON nesting has a safe parser limit" {
  local fixture="$TEST_ROOT/deeply-nested.json"
  python3 - "$fixture" <<'PY'
import sys

depth = 2000
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write("[" * depth + "0" + "]" * depth)
PY

  run "$PROJECT_ROOT/install-evidence" --fixture "$fixture"
  [ "$status" -eq 64 ]
  assert_output_contains "fixture JSON nesting is too deep"
}

@test "fixture input has a fixed byte limit" {
  local fixture="$TEST_ROOT/oversized.json"
  python3 - "$fixture" <<'PY'
import sys

with open(sys.argv[1], "wb") as handle:
    handle.write(b" " * (1024 * 1024 + 1))
PY

  run "$PROJECT_ROOT/install-evidence" --fixture "$fixture"
  [ "$status" -eq 64 ]
  assert_output_contains "fixture exceeds the size limit"
}

@test "each probe has a fixed observation record limit" {
  local fixture="$TEST_ROOT/too-many-records.json"
  python3 - "$HEALTHY_FIXTURE" "$fixture" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    fixture = json.load(handle)
fixture["observations"]["command.rg"] = [
    {"status": "present", "resolution": "allowed"}
] * 9
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(fixture, handle)
PY

  run "$PROJECT_ROOT/install-evidence" --fixture "$fixture"
  [ "$status" -eq 64 ]
  assert_output_contains "exceeds the record limit"
}
