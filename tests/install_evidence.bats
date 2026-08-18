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
assert document["schema_version"] == "1.2.0"
assert document["collection"]["timestamp"] == "2000-01-01T00:00:00Z"
assert document["collection"]["sanitization"]["home"] == "<home>"
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

  run /usr/bin/env PATH="$TEST_BIN" PYTHONPATH="$PROJECT_ROOT" \
    "$TEST_BIN/python3" -m tools.install_evidence.cli \
    --live --profile agent --platform macos

  [ "$status" -eq 1 ]
  assert_output_contains "unexpected_command_resolution"
  assert_output_contains "exact path discarded"
  [[ "$output" != *"$TEST_ROOT"* ]]
  [[ "$output" != *"$HOME"* ]]
  [ ! -s "$TEST_STUB_LOG" ]
}

@test "directory probes reject symlinks without inspecting their targets" {
  mkdir -p "$HOME/real-plugin/.git" "$HOME/plugin"
  rmdir "$HOME/plugin"
  ln -s "$HOME/real-plugin" "$HOME/plugin"
  ln -s "$HOME/real-plugin/.git" "$HOME/plugin-git"

  run python3 - "$PROJECT_ROOT" "$HOME" <<'PY'
import pathlib
import sys

project_root, home = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(project_root))

from tools.install_evidence.probes import ProbeDefinition, collect_live

collection = collect_live(
    (
        ProbeDefinition("directory.plugin", "directory", "$HOME/plugin"),
        ProbeDefinition("git-directory.plugin", "git_directory", "$HOME/plugin-git"),
    ),
    "agent",
    "macos",
    home,
    home / ".dotfiles",
    project_root,
)
assert collection.observations["directory.plugin"] == (
    {"status": "other", "type": "symlink"},
)
assert collection.observations["git-directory.plugin"] == (
    {"status": "other", "type": "symlink"},
)
PY

  [ "$status" -eq 0 ]
}

@test "marker probes use one no-follow nonblocking descriptor" {
  mkdir -p "$HOME/.config/dotfiles"
  printf '%s\n' "agent" >"$HOME/.config/dotfiles/profile"

  run python3 - "$PROJECT_ROOT" "$HOME" <<'PY'
import os
import pathlib
import sys
from unittest import mock

project_root, home = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(project_root))

from tools.install_evidence import probes

definition = probes.ProbeDefinition(
    "marker.profile", "marker", "$HOME/.config/dotfiles/profile", "agent"
)
real_open = os.open
real_fstat = os.fstat
real_read = os.read
marker_open_calls = []

def tracked_open(path, flags, *args, **kwargs):
    if path == "profile":
        marker_open_calls.append((flags, kwargs.get("dir_fd")))
    return real_open(path, flags, *args, **kwargs)

with (
    mock.patch.object(
        probes.os,
        "lstat",
        side_effect=AssertionError("marker probe must not check then reopen"),
    ),
    mock.patch.object(probes.os, "open", side_effect=tracked_open) as opened,
    mock.patch.object(probes.os, "fstat", wraps=real_fstat) as fstat_called,
    mock.patch.object(probes.os, "read", wraps=real_read) as read_called,
):
    collection = probes.collect_live(
        (definition,),
        "agent",
        "macos",
        home,
        home / ".dotfiles",
        project_root,
    )

assert collection.observations["marker.profile"] == (
    {"status": "present", "comparison": "matched"},
)
assert opened.call_count >= 1
assert fstat_called.call_count == 1
assert read_called.call_count == 1
assert len(marker_open_calls) == 1
flags, directory_descriptor = marker_open_calls[0]
assert flags & os.O_NOFOLLOW
assert flags & os.O_NONBLOCK
assert directory_descriptor is not None
PY

  [ "$status" -eq 0 ]
}

@test "marker probes reject symlinks and FIFOs without reading them" {
  local marker="$HOME/.config/dotfiles/profile"
  local private_value="$TEST_ROOT/private-marker"
  local fifo="$HOME/.config/dotfiles/platform"
  mkdir -p "$HOME/.config/dotfiles"
  printf '%s\n' "must-not-be-read" >"$private_value"
  ln -s "$private_value" "$marker"
  mkfifo "$fifo"

  run python3 - "$PROJECT_ROOT" "$HOME" <<'PY'
import pathlib
import sys

project_root, home = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(project_root))

from tools.install_evidence.probes import ProbeDefinition, collect_live

collection = collect_live(
    (
        ProbeDefinition(
            "marker.profile", "marker", "$HOME/.config/dotfiles/profile", "agent"
        ),
        ProbeDefinition(
            "marker.platform", "marker", "$HOME/.config/dotfiles/platform", "macos"
        ),
    ),
    "agent",
    "macos",
    home,
    home / ".dotfiles",
    project_root,
)
assert collection.observations["marker.profile"] == ({"status": "missing"},)
assert collection.observations["marker.platform"] == ({"status": "missing"},)
PY

  [ "$status" -eq 0 ]
}

@test "live path probes reject symbolic links in parent directories" {
  local external="$TEST_ROOT/external"
  mkdir -p "$external/plugin" "$external/repository/config" "$HOME"
  printf '%s\n' "agent" >"$external/profile"
  ln -s "$external/repository/config/.zshrc" "$external/zshrc"
  ln -s "$external" "$HOME/redirect"

  run python3 - "$PROJECT_ROOT" "$HOME" <<'PY'
import pathlib
import sys

project_root, home = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(project_root))

from tools.install_evidence.probes import ProbeDefinition, collect_live

collection = collect_live(
    (
        ProbeDefinition("marker.parent", "marker", "$HOME/redirect/profile", "agent"),
        ProbeDefinition(
            "symlink.parent",
            "symlink",
            "$HOME/redirect/zshrc",
            "<repo>/config/.zshrc",
        ),
        ProbeDefinition("directory.parent", "directory", "$HOME/redirect/plugin"),
        ProbeDefinition(
            "git-directory.parent", "git_directory", "$HOME/redirect/plugin"
        ),
    ),
    "agent",
    "macos",
    home,
    home / ".dotfiles",
    project_root,
)
for probe_id in (
    "marker.parent",
    "symlink.parent",
    "directory.parent",
    "git-directory.parent",
):
    record = collection.observations[probe_id][0]
    assert record == {"status": "error", "error_code": "io_error"}
PY

  [ "$status" -eq 0 ]
}

@test "command probes do not trust linked commands or PATH directories" {
  local real_bin="$TEST_ROOT/real-bin"
  local linked_bin="$TEST_ROOT/linked-bin"
  mkdir -p "$real_bin"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$real_bin/tool"
  chmod +x "$real_bin/tool"
  ln -s "$real_bin/tool" "$TEST_BIN/tool"
  ln -s "$real_bin" "$linked_bin"

  run python3 - "$PROJECT_ROOT" "$TEST_BIN" "$linked_bin" <<'PY'
import os
import pathlib
import sys

project_root, test_bin, linked_bin = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(project_root))

from tools.install_evidence.probes import ProbeDefinition, collect_live

definition = ProbeDefinition(
    "command.tool", "command", command="tool", expected_roots=(str(test_bin),)
)
for path_value in (str(test_bin), str(linked_bin)):
    os.environ["PATH"] = path_value
    collection = collect_live(
        (definition,),
        "agent",
        "macos",
        pathlib.Path("/synthetic/home"),
        pathlib.Path("/synthetic/home/.dotfiles"),
        project_root,
    )
    record = collection.observations["command.tool"][0]
    assert record == {"status": "error", "error_code": "io_error"}
PY

  [ "$status" -eq 0 ]
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
assert _target_scope(
    "/managed/home/source/config",
    pathlib.Path("/managed/home"),
    pathlib.Path("/managed/home/installed"),
    pathlib.Path("/managed/home/source"),
) == "source_repo"
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

  run /usr/bin/env PATH="$TEST_BIN" PYTHONPATH="$PROJECT_ROOT" \
    "$TEST_BIN/python3" -m tools.install_evidence.cli \
    --live --profile agent --platform macos --format json

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
