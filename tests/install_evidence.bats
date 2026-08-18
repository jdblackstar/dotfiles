#!/usr/bin/env bats

load 'helpers/test_helper.bash'

setup() {
  setup_test_env
  HEALTHY_FIXTURE="$PROJECT_ROOT/tests/fixtures/install-evidence/healthy-personal-macos.json"
  LINUX_FIXTURE="$PROJECT_ROOT/tests/fixtures/install-evidence/healthy-personal-linux.json"
}

teardown() {
  teardown_test_env
}

mutate_fixture() {
  local source_fixture="$1"
  local destination="$2"
  local probe_id="$3"
  local replacement_json="$4"

  python3 - "$source_fixture" "$destination" "$probe_id" "$replacement_json" <<'PY'
import json
import sys

source, destination, probe_id, replacement = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    fixture = json.load(handle)
fixture["observations"][probe_id] = json.loads(replacement)
with open(destination, "w", encoding="utf-8") as handle:
    json.dump(fixture, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

claim_field() {
  local document="$1"
  local claim_id="$2"
  local field="$3"

  python3 - "$document" "$claim_id" "$field" <<'PY'
import json
import sys

path, claim_id, field = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
claim = next(item for item in document["claims"] if item["id"] == claim_id)
value = claim[field]
print(json.dumps(value, sort_keys=True) if isinstance(value, (dict, list)) else value)
PY
}

prepare_agent_live_home() {
  local installed_repo="$HOME/.dotfiles"

  mkdir -p "$HOME/.config/dotfiles" "$HOME/.config" \
    "$HOME/.tmux/plugins/tpm/.git"
  printf '%s\n' "agent" >"$HOME/.config/dotfiles/profile"
  printf '%s\n' "macos" >"$HOME/.config/dotfiles/platform"

  ln -s "$installed_repo/git/agent.gitconfig" "$HOME/.gitconfig"
  ln -s "$installed_repo/git/.gitignore_global" "$HOME/.gitignore_global"
  ln -s "$installed_repo/config/.zshrc" "$HOME/.zshrc"
  ln -s "$installed_repo/config/.vimrc" "$HOME/.vimrc"
  ln -s "$installed_repo/config/tmux.conf" "$HOME/.tmux.conf"
  ln -s "$installed_repo/config/starship.toml" "$HOME/.config/starship.toml"
  ln -s "$installed_repo/config/relay" "$HOME/.config/relay"
}

@test "evidence command requires explicit fixture or live mode" {
  run "$PROJECT_ROOT/install-evidence"

  [ "$status" -eq 2 ]
  assert_output_contains "choose --fixture FILE or explicit --live"
}

@test "healthy fixture proves the mapped installation health claim" {
  run "$PROJECT_ROOT/install-evidence" --fixture "$HEALTHY_FIXTURE"

  [ "$status" -eq 0 ]
  assert_output_contains "HEALTH PROVEN"
  assert_output_contains "20 verifier checks mapped"
  assert_output_contains "1password installation is verified"
  assert_output_contains "no_safe_probe_mapped"
}

@test "missing item fails its claim and blocks installation health" {
  local fixture="$TEST_ROOT/missing.json"
  local document="$TEST_ROOT/missing-output.json"
  mutate_fixture "$HEALTHY_FIXTURE" "$fixture" "command.rg" '{"status":"missing"}'

  run "$PROJECT_ROOT/install-evidence" --fixture "$fixture" --format json
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" >"$document"

  [ "$(claim_field "$document" "claim:command.rg" "state")" = "failed" ]
  [ "$(claim_field "$document" "claim:command.rg" "rule")" = "required_item_missing" ]
  run claim_field "$document" "claim:installation-healthy" "blocked_by"
  [ "$status" -eq 0 ]
  assert_output_contains "claim:command.rg"
}

@test "wrong symlink target retains only a non-sensitive scope" {
  local fixture="$TEST_ROOT/wrong-link.json"
  mutate_fixture "$HEALTHY_FIXTURE" "$fixture" "symlink.zshrc" \
    '{"status":"symlink","comparison":"mismatched","target_scope":"installed_repo"}'

  run "$PROJECT_ROOT/install-evidence" --fixture "$fixture"

  [ "$status" -eq 1 ]
  assert_output_contains "[FAILED] ~/.zshrc targets the managed source"
  assert_output_contains "symlink_target_mismatch"
  assert_output_contains "scope: installed_repo"
  assert_output_contains "target was discarded"
}

@test "unexpected command resolution is a failure with an explanation chain" {
  local fixture="$TEST_ROOT/shadowed-command.json"
  mutate_fixture "$HEALTHY_FIXTURE" "$fixture" "command.rg" \
    '{"status":"present","resolution":"unexpected"}'

  run "$PROJECT_ROOT/install-evidence" --fixture "$fixture"

  [ "$status" -eq 1 ]
  assert_output_contains "[FAILED] command rg resolves as expected"
  assert_output_contains "profile -> tests/verify-mac-install.sh:191 -> unexpected_command_resolution"
  assert_output_contains "exact path discarded"
}

@test "Linux fixture marks mac-only verifier commands not applicable" {
  run "$PROJECT_ROOT/install-evidence" --fixture "$LINUX_FIXTURE"

  [ "$status" -eq 0 ]
  assert_output_contains "HEALTH PROVEN"
  assert_output_contains "3 not applicable"
}

@test "explicitly skipped required probe makes health unknown" {
  local fixture="$TEST_ROOT/skipped.json"
  mutate_fixture "$HEALTHY_FIXTURE" "$fixture" "command.rg" '{"status":"skipped"}'

  run "$PROJECT_ROOT/install-evidence" --fixture "$fixture"

  [ "$status" -eq 2 ]
  assert_output_contains "HEALTH UNKNOWN"
  assert_output_contains "[SKIPPED] command rg resolves as expected"
  assert_output_contains "explicit_probe_skip"
}

@test "permission and probe errors are unknown rather than absent" {
  local fixture="$TEST_ROOT/permission.json"
  local document="$TEST_ROOT/permission-output.json"
  mutate_fixture "$HEALTHY_FIXTURE" "$fixture" "symlink.zshrc" \
    '{"status":"error","error_code":"permission_denied"}'

  run "$PROJECT_ROOT/install-evidence" --fixture "$fixture" --format json
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" >"$document"

  [ "$(claim_field "$document" "claim:symlink.zshrc" "state")" = "unknown" ]
  [ "$(claim_field "$document" "claim:symlink.zshrc" "rule")" = "probe_error_is_unknown" ]
}

@test "conflicting observations are explicit and block health" {
  local fixture="$TEST_ROOT/conflict.json"
  local document="$TEST_ROOT/conflict-output.json"
  mutate_fixture "$HEALTHY_FIXTURE" "$fixture" "command.rg" \
    '[{"status":"present","resolution":"allowed"},{"status":"present","resolution":"unexpected"}]'

  run "$PROJECT_ROOT/install-evidence" --fixture "$fixture" --format json
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" >"$document"

  [ "$(claim_field "$document" "claim:command.rg" "state")" = "conflicted" ]
  [ "$(claim_field "$document" "claim:command.rg" "rule")" = "conflicting_observations" ]
}

@test "fixture JSON is deterministic and validates the versioned schema shape" {
  run "$PROJECT_ROOT/install-evidence" --fixture "$HEALTHY_FIXTURE" --format json
  [ "$status" -eq 0 ]
  local first="$output"

  run "$PROJECT_ROOT/install-evidence" --fixture "$HEALTHY_FIXTURE" --format json
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  printf '%s\n' "$output" >"$TEST_ROOT/document.json"

  run python3 - "$TEST_ROOT/document.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
assert document["schema_version"] == "1.1.0"
assert document["collection"]["timestamp"] == "2000-01-01T00:00:00Z"
assert document["collection"]["sanitization"]["home"] == "<home>"
assert document["collection"]["privacy"] == {
    "distribution": "local_only",
    "mode": "public_safe",
    "raw_command_paths_retained": False,
    "raw_error_messages_retained": False,
    "raw_marker_values_retained": False,
    "raw_symlink_targets_retained": False,
}
relations = {edge["relation"] for edge in document["graph"]["edges"]}
assert {
    "applies_on",
    "profile_includes",
    "declares",
    "installs",
    "proven_by",
    "requires",
} <= relations
base_manifest = next(
    node
    for node in document["graph"]["nodes"]
    if node["id"] == "manifest:packages-brew-base-brewfile"
)
assert base_manifest["attributes"]["profile_source"] == {
    "path": "profiles/personal.sh",
    "line": 4,
}
assert document["summary"]["health_state"] == "proven"
PY
  [ "$status" -eq 0 ]
}

@test "failed graph includes a blocked_by edge" {
  local fixture="$TEST_ROOT/blocked.json"
  mutate_fixture "$HEALTHY_FIXTURE" "$fixture" "command.rg" '{"status":"missing"}'

  run "$PROJECT_ROOT/install-evidence" --fixture "$fixture" --format json
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" >"$TEST_ROOT/blocked-output.json"

  run python3 - "$TEST_ROOT/blocked-output.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
assert {
    "from": "claim:installation-healthy",
    "to": "claim:command.rg",
    "relation": "blocked_by",
} in document["graph"]["edges"]
PY
  [ "$status" -eq 0 ]
}

@test "DOT rendering is dependency-free and includes state and relation labels" {
  run "$PROJECT_ROOT/install-evidence" --fixture "$HEALTHY_FIXTURE" --format dot

  [ "$status" -eq 0 ]
  assert_output_contains "digraph install_evidence"
  assert_output_contains 'fillcolor="palegreen"'
  assert_output_contains 'label="profile_includes"'
}

@test "raw error strings are rejected and never reach output" {
  local fixture="$TEST_ROOT/inert.json"
  local sentinel="$TEST_ROOT/fixture-executed"
  mutate_fixture "$HEALTHY_FIXTURE" "$fixture" "command.rg" \
    "{\"status\":\"error\",\"error\":\"\$(touch $sentinel)\"}"

  run "$PROJECT_ROOT/install-evidence" --fixture "$fixture"

  [ "$status" -eq 64 ]
  [ ! -e "$sentinel" ]
  [[ "$output" != *"$sentinel"* ]]
  assert_output_contains "has unknown keys"
}

@test "fixture path fields are rejected before graph construction" {
  local fixture="$TEST_ROOT/traversal.json"
  mutate_fixture "$HEALTHY_FIXTURE" "$fixture" "symlink.zshrc" \
    '{"status":"symlink","target":"../../private-file"}'

  run "$PROJECT_ROOT/install-evidence" --fixture "$fixture"

  [ "$status" -eq 64 ]
  assert_output_contains "has unknown keys"
}

@test "fixtures cannot invent probe identifiers" {
  local fixture="$TEST_ROOT/unknown-probe.json"
  python3 - "$HEALTHY_FIXTURE" "$fixture" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    fixture = json.load(handle)
fixture["observations"]["command.$(touch nope)"] = {"status": "missing"}
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(fixture, handle)
PY

  run "$PROJECT_ROOT/install-evidence" --fixture "$fixture"

  [ "$status" -eq 64 ]
  assert_output_contains "unknown probe ids"
}

@test "fixture metadata is versioned and timestamp validated" {
  local fixture="$TEST_ROOT/bad-metadata.json"
  python3 - "$HEALTHY_FIXTURE" "$fixture" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    fixture = json.load(handle)
fixture["collected_at"] = "not-a-timestamp"
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(fixture, handle)
PY

  run "$PROJECT_ROOT/install-evidence" --fixture "$fixture"

  [ "$status" -eq 64 ]
  assert_output_contains "must be an ISO-8601 timestamp"
}

@test "probe listing documents the live allowlist without collecting evidence" {
  run "$PROJECT_ROOT/install-evidence" --list-probes --profile personal --platform macos

  [ "$status" -eq 0 ]
  assert_output_contains "no subprocess execution"
  assert_output_contains "command is never executed"
  assert_output_contains "command.rg"
}

@test "live executor inspects only a synthetic HOME and never executes commands" {
  prepare_agent_live_home
  install_stub git git.stub

  run "$PROJECT_ROOT/install-evidence" --live --profile agent --platform macos

  [ "$status" -eq 1 ]
  assert_output_contains "unexpected_command_resolution"
  assert_output_contains "exact path discarded"
  [[ "$output" != *"$TEST_ROOT"* ]]
  [[ "$output" != *"$HOME"* ]]
  [ ! -s "$TEST_STUB_LOG" ]
}

@test "lexical traversal cannot masquerade as an allowed path scope" {
  run python3 - "$PROJECT_ROOT" <<'PY'
import pathlib
import sys

sys.path.insert(0, sys.argv[1])
from tools.install_evidence.probes import _command_resolution, _target_scope

assert _command_resolution(
    "/allowed/bin/../../outside/tool", ("/allowed/bin",)
) == "unexpected"
assert _target_scope(
    "/managed/home/../../outside/private",
    pathlib.Path("/managed/home"),
    pathlib.Path("/managed/home/repository"),
    pathlib.Path("/source/repository"),
) == "external"
PY

  [ "$status" -eq 0 ]
}

@test "live JSON discards marker values, command paths, symlink targets, and raw errors" {
  local secret_marker="private-profile-value"
  local secret_target="$TEST_ROOT/private/synthetic-secret-token"
  prepare_agent_live_home
  install_stub git git.stub
  printf '%s\n' "$secret_marker" >"$HOME/.config/dotfiles/profile"
  rm "$HOME/.zshrc"
  ln -s "$secret_target" "$HOME/.zshrc"

  run "$PROJECT_ROOT/install-evidence" --live --profile agent --platform macos \
    --format json

  [ "$status" -eq 1 ]
  [[ "$output" != *"$secret_marker"* ]]
  [[ "$output" != *"$secret_target"* ]]
  [[ "$output" != *"$TEST_ROOT"* ]]
  [[ "$output" != *"$HOME"* ]]
  assert_output_contains '"comparison": "mismatched"'
  assert_output_contains '"target_scope": "external"'
  assert_output_contains '"resolution": "unexpected"'
  assert_output_contains '"raw_marker_values_retained": false'
  assert_output_contains '"raw_command_paths_retained": false'
  assert_output_contains '"raw_symlink_targets_retained": false'
  assert_output_contains '"raw_error_messages_retained": false'
  assert_output_contains '"distribution": "local_only"'
  [ ! -s "$TEST_STUB_LOG" ]
}

@test "tracked fixtures contain only synthetic classified observations" {
  run /usr/bin/grep -ERn '/Users/|/home/|/private/|/opt/|/usr/|2026-' \
    "$PROJECT_ROOT/tests/fixtures/install-evidence"

  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
