"""Probe definitions, safe live execution, and inert fixture replay."""

from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
from typing import Any, Dict, Mapping, Optional, Sequence, Tuple

from . import FIXTURE_VERSION


class ProbeError(ValueError):
    """Probe input or fixture data violated the safe contract."""


@dataclass(frozen=True)
class ProbeDefinition:
    id: str
    kind: str
    path: Optional[str] = None
    expected: Optional[str] = None
    command: Optional[str] = None
    expected_roots: Tuple[str, ...] = ()
    applicable: bool = True


@dataclass(frozen=True)
class Collection:
    mode: str
    profile: str
    platform: str
    collected_at: str
    observations: Mapping[str, Tuple[Mapping[str, Any], ...]]


_STATUS_BY_KIND = {
    "marker": {"present", "missing", "error", "skipped"},
    "symlink": {"symlink", "missing", "other", "error", "skipped"},
    "command": {"present", "missing", "error", "skipped"},
    "directory": {"directory", "missing", "other", "error", "skipped"},
    "git_directory": {"directory", "missing", "other", "error", "skipped"},
}
_ALLOWED_KEYS = {
    "marker": {"status", "comparison", "error_code"},
    "symlink": {"status", "comparison", "target_scope", "type", "error_code"},
    "command": {"status", "resolution", "error_code"},
    "directory": {"status", "type", "error_code"},
    "git_directory": {"status", "type", "error_code"},
}
_COMPARISONS = {"matched", "mismatched"}
_COMMAND_RESOLUTIONS = {"allowed", "unexpected"}
_TARGET_SCOPES = {
    "installed_repo",
    "home",
    "source_repo",
    "external",
    "relative",
}
_ERROR_CODES = {
    "permission_denied",
    "invalid_encoding",
    "marker_too_large",
    "io_error",
    "fixture_error",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def _safe_absolute(path: str, label: str) -> Path:
    candidate = Path(path)
    if not candidate.is_absolute() or ".." in PurePosixPath(path).parts:
        raise ProbeError("%s must be an absolute path without '..'" % label)
    return candidate


def expand_declared_path(template: str, home: Path, installed_repo: Path) -> Path:
    if template == "$HOME":
        return home
    if template.startswith("$HOME/"):
        relative = template[len("$HOME/") :]
        base = home
    elif template.startswith("$DOTFILES_DIR/"):
        relative = template[len("$DOTFILES_DIR/") :]
        base = installed_repo
    else:
        raise ProbeError("path is not rooted at $HOME or $DOTFILES_DIR")
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts or not pure.parts:
        raise ProbeError("unsafe declared path")
    return base.joinpath(*pure.parts)


def _file_type(mode: int) -> str:
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISREG(mode):
        return "file"
    return "other"


def _error_code(exc: BaseException) -> str:
    if isinstance(exc, PermissionError):
        return "permission_denied"
    if isinstance(exc, UnicodeError):
        return "invalid_encoding"
    return "io_error"


def _error_record(exc: BaseException) -> Mapping[str, str]:
    return {"status": "error", "error_code": _error_code(exc)}


def _target_scope(
    target: str, home: Path, installed_repo: Path, source_repo: Path
) -> str:
    if not os.path.isabs(target):
        return "relative"
    target_path = Path(os.path.normpath(target))
    for root, scope in (
        (installed_repo, "installed_repo"),
        (home, "home"),
        (source_repo, "source_repo"),
    ):
        try:
            target_path.relative_to(Path(os.path.normpath(str(root))))
            return scope
        except ValueError:
            continue
    return "external"


def _command_resolution(resolved: str, expected_roots: Sequence[str]) -> str:
    normalized = os.path.normpath(resolved)
    if any(
        normalized == os.path.normpath(root)
        or normalized.startswith(os.path.normpath(root).rstrip("/") + "/")
        for root in expected_roots
    ):
        return "allowed"
    return "unexpected"


def collect_live(
    definitions: Sequence[ProbeDefinition],
    profile: str,
    platform: str,
    home: Path,
    installed_repo: Path,
    source_repo: Path,
) -> Collection:
    """Execute the fixed read-only probe allowlist; no subprocesses are used."""
    home = _safe_absolute(str(home), "HOME")
    installed_repo = _safe_absolute(str(installed_repo), "installed repo")
    observations: Dict[str, Tuple[Mapping[str, Any], ...]] = {}

    for definition in definitions:
        if not definition.applicable:
            continue
        try:
            if definition.kind == "command":
                resolved = shutil.which(definition.command or "")
                record: Dict[str, Any]
                if resolved is None:
                    record = {"status": "missing"}
                else:
                    record = {
                        "status": "present",
                        "resolution": _command_resolution(
                            resolved, definition.expected_roots
                        ),
                    }
            else:
                if definition.path is None:
                    raise ProbeError("path probe missing declared path")
                path = expand_declared_path(definition.path, home, installed_repo)
                try:
                    mode = os.lstat(str(path)).st_mode
                except FileNotFoundError:
                    record = {"status": "missing"}
                except OSError as exc:
                    record = _error_record(exc)
                else:
                    observed_type = _file_type(mode)
                    if definition.kind == "symlink":
                        if observed_type != "symlink":
                            record = {"status": "other", "type": observed_type}
                        else:
                            try:
                                target = os.readlink(str(path))
                                expected_target = definition.expected or ""
                                expected_path = expected_target.replace(
                                    "<repo>", str(installed_repo), 1
                                ).replace("<home>", str(home), 1)
                                comparison = (
                                    "matched"
                                    if target.rstrip("/") == expected_path.rstrip("/")
                                    else "mismatched"
                                )
                                record = {
                                    "status": "symlink",
                                    "comparison": comparison,
                                }
                                if comparison == "mismatched":
                                    record["target_scope"] = _target_scope(
                                        target, home, installed_repo, source_repo
                                    )
                            except OSError as exc:
                                record = _error_record(exc)
                    elif definition.kind == "marker":
                        if observed_type != "file":
                            record = {"status": "missing"}
                        else:
                            try:
                                with path.open("rb") as handle:
                                    raw = handle.read(257)
                                if len(raw) > 256:
                                    raise ProbeError(
                                        "marker exceeds the 256-byte read limit"
                                    )
                                value = raw.decode("utf-8").strip()
                                record = {
                                    "status": "present",
                                    "comparison": (
                                        "matched"
                                        if value == definition.expected
                                        else "mismatched"
                                    ),
                                }
                            except ProbeError as exc:
                                record = {
                                    "status": "error",
                                    "error_code": (
                                        "marker_too_large"
                                        if "256-byte" in str(exc)
                                        else "io_error"
                                    ),
                                }
                            except (OSError, UnicodeError) as exc:
                                record = _error_record(exc)
                    elif definition.kind in ("directory", "git_directory"):
                        if observed_type == "directory":
                            record = {"status": "directory"}
                        elif observed_type == "symlink":
                            try:
                                if path.is_dir():
                                    record = {"status": "directory"}
                                else:
                                    record = {
                                        "status": "other",
                                        "type": observed_type,
                                    }
                            except OSError as exc:
                                record = _error_record(exc)
                        else:
                            record = {"status": "other", "type": observed_type}
                    else:
                        raise ProbeError(
                            "unsupported probe kind: %s" % definition.kind
                        )
            observations[definition.id] = (record,)
        except ProbeError:
            raise

    return Collection(
        mode="live",
        profile=profile,
        platform=platform,
        collected_at=utc_now(),
        observations=observations,
    )


def _validate_fixture_string(value: Any, field: str) -> str:
    if not isinstance(value, str):
        raise ProbeError("fixture %s must be a string" % field)
    if len(value) > 4096 or any(
        ord(character) < 32 or ord(character) == 127 for character in value
    ):
        raise ProbeError("fixture %s contains disallowed characters" % field)
    return value


def _validate_record(
    definition: ProbeDefinition, record: Any
) -> Mapping[str, Any]:
    if not isinstance(record, dict):
        raise ProbeError("fixture observation %s must be an object" % definition.id)
    extra = set(record) - _ALLOWED_KEYS[definition.kind]
    if extra:
        raise ProbeError("fixture observation %s has unknown keys" % definition.id)
    status = record.get("status")
    if status not in _STATUS_BY_KIND[definition.kind]:
        raise ProbeError(
            "fixture observation %s has invalid status" % definition.id
        )
    validated: Dict[str, Any] = {"status": status}
    for field in sorted(set(record) - {"status"}):
        validated[field] = _validate_fixture_string(record[field], field)
    if "comparison" in validated and validated["comparison"] not in _COMPARISONS:
        raise ProbeError(
            "fixture observation %s has invalid comparison" % definition.id
        )
    if (
        "resolution" in validated
        and validated["resolution"] not in _COMMAND_RESOLUTIONS
    ):
        raise ProbeError(
            "fixture observation %s has invalid resolution" % definition.id
        )
    if (
        "target_scope" in validated
        and validated["target_scope"] not in _TARGET_SCOPES
    ):
        raise ProbeError(
            "fixture observation %s has invalid target_scope" % definition.id
        )
    if "error_code" in validated and validated["error_code"] not in _ERROR_CODES:
        raise ProbeError(
            "fixture observation %s has invalid error_code" % definition.id
        )
    required_field = {
        ("marker", "present"): "comparison",
        ("symlink", "symlink"): "comparison",
        ("command", "present"): "resolution",
        ("symlink", "other"): "type",
        ("directory", "other"): "type",
        ("git_directory", "other"): "type",
        ("marker", "error"): "error_code",
        ("symlink", "error"): "error_code",
        ("command", "error"): "error_code",
        ("directory", "error"): "error_code",
        ("git_directory", "error"): "error_code",
    }.get((definition.kind, status))
    if required_field and required_field not in validated:
        raise ProbeError(
            "fixture observation %s requires %s" % (definition.id, required_field)
        )
    if (
        definition.kind == "symlink"
        and status == "symlink"
        and validated.get("comparison") == "mismatched"
        and "target_scope" not in validated
    ):
        raise ProbeError(
            "fixture observation %s requires target_scope for a mismatch"
            % definition.id
        )
    if (
        definition.kind == "symlink"
        and validated.get("comparison") == "matched"
        and "target_scope" in validated
    ):
        raise ProbeError(
            "fixture observation %s must omit target_scope for a match"
            % definition.id
        )
    return validated


def load_fixture(
    path: Path, definitions: Sequence[ProbeDefinition], profile: Optional[str]
) -> Collection:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError:
        raise ProbeError("cannot read fixture data")
    except UnicodeError:
        raise ProbeError("fixture data is not valid UTF-8")
    except json.JSONDecodeError as exc:
        raise ProbeError(
            "fixture JSON is invalid at line %d column %d"
            % (exc.lineno, exc.colno)
        )
    if not isinstance(data, dict):
        raise ProbeError("fixture root must be an object")
    allowed_root = {
        "fixture_version",
        "profile",
        "platform",
        "collected_at",
        "observations",
    }
    extra = set(data) - allowed_root
    if extra:
        raise ProbeError("fixture has unknown keys")
    if data.get("fixture_version") != FIXTURE_VERSION:
        raise ProbeError("unsupported fixture_version")
    fixture_profile = _validate_fixture_string(data.get("profile"), "profile")
    if fixture_profile not in ("agent", "personal", "work"):
        raise ProbeError("fixture profile is not supported")
    if profile is not None and profile != fixture_profile:
        raise ProbeError(
            "fixture profile %s does not match --profile %s"
            % (fixture_profile, profile)
        )
    platform = _validate_fixture_string(data.get("platform"), "platform")
    if platform not in ("linux", "macos"):
        raise ProbeError("fixture platform is not supported")
    collected_at = _validate_fixture_string(data.get("collected_at"), "collected_at")
    try:
        parsed_timestamp = datetime.fromisoformat(
            collected_at.replace("Z", "+00:00")
        )
    except ValueError:
        raise ProbeError("fixture collected_at must be an ISO-8601 timestamp")
    if parsed_timestamp.tzinfo is None:
        raise ProbeError("fixture collected_at must include a timezone")
    raw_observations = data.get("observations")
    if not isinstance(raw_observations, dict):
        raise ProbeError("fixture observations must be an object")

    by_id = {definition.id: definition for definition in definitions}
    unknown = set(raw_observations) - set(by_id)
    if unknown:
        raise ProbeError("fixture contains unknown probe ids")
    observations: Dict[str, Tuple[Mapping[str, Any], ...]] = {}
    for probe_id, raw in raw_observations.items():
        values = raw if isinstance(raw, list) else [raw]
        if not values:
            raise ProbeError("fixture observation %s is empty" % probe_id)
        observations[probe_id] = tuple(
            _validate_record(by_id[probe_id], value) for value in values
        )
    return Collection(
        mode="fixture",
        profile=fixture_profile,
        platform=platform,
        collected_at=collected_at,
        observations=observations,
    )
