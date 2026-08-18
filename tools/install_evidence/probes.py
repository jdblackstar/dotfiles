"""Probe definitions, safe live execution, and inert fixture replay."""

from dataclasses import dataclass
from datetime import datetime, timezone
import errno
import json
import os
from pathlib import Path, PurePosixPath
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
MAX_FIXTURE_BYTES = 1024 * 1024
MAX_OBSERVATIONS_PER_PROBE = 8
_FIXTURE_DATA_UNSET = object()


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


def _directory_flags(no_follow: bool) -> int:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    if no_follow:
        flags |= getattr(os, "O_NOFOLLOW", 0)
    return flags


def _declared_root_and_parts(
    template: str, home: Path, installed_repo: Path
) -> Tuple[Path, Tuple[str, ...]]:
    if template.startswith("$HOME/"):
        root = home
        relative = template[len("$HOME/") :]
    elif template.startswith("$DOTFILES_DIR/"):
        root = installed_repo
        relative = template[len("$DOTFILES_DIR/") :]
    else:
        raise ProbeError("path must identify an entry below a trusted root")
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts or not pure.parts:
        raise ProbeError("unsafe declared path")
    return root, tuple(pure.parts)


def _open_declared_parent(
    template: str, home: Path, installed_repo: Path
) -> Tuple[int, str]:
    """Open each directory below a trusted root without following links."""
    nofollow = getattr(os, "O_NOFOLLOW", None)
    directory_flag = getattr(os, "O_DIRECTORY", None)
    if nofollow is None or directory_flag is None:
        raise OSError("safe path traversal is not supported")

    root, parts = _declared_root_and_parts(template, home, installed_repo)
    descriptor = os.open(str(root), _directory_flags(no_follow=False))
    try:
        for component in parts[:-1]:
            next_descriptor = os.open(
                component,
                _directory_flags(no_follow=True),
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = next_descriptor
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        raise
    return descriptor, parts[-1]


def _marker_record(
    parent_descriptor: int, name: str, expected: Optional[str]
) -> Mapping[str, str]:
    """Read a small regular marker through one non-following file descriptor."""
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        return {"status": "error", "error_code": "io_error"}

    flags = os.O_RDONLY | nofollow
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    except FileNotFoundError:
        return {"status": "missing"}
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            return {"status": "missing"}
        return _error_record(exc)

    record: Mapping[str, str]
    try:
        mode = os.fstat(descriptor).st_mode
        if not stat.S_ISREG(mode):
            record = {"status": "missing"}
        else:
            raw = os.read(descriptor, 257)
            if len(raw) > 256:
                record = {"status": "error", "error_code": "marker_too_large"}
            else:
                value = raw.decode("utf-8").strip()
                record = {
                    "status": "present",
                    "comparison": "matched" if value == expected else "mismatched",
                }
    except (OSError, UnicodeError) as exc:
        record = _error_record(exc)
    finally:
        try:
            os.close(descriptor)
        except OSError as exc:
            record = _error_record(exc)
    return record


def _mode_is_executable_for_current_user(metadata: os.stat_result) -> bool:
    if not stat.S_ISREG(metadata.st_mode):
        return False
    if os.geteuid() == 0:
        return bool(metadata.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
    if metadata.st_uid == os.geteuid():
        return bool(metadata.st_mode & stat.S_IXUSR)
    groups = {os.getegid(), *os.getgroups()}
    if metadata.st_gid in groups:
        return bool(metadata.st_mode & stat.S_IXGRP)
    return bool(metadata.st_mode & stat.S_IXOTH)


def _executable_at(
    directory_descriptor: int, command: str, metadata: os.stat_result
) -> Optional[bool]:
    """Check execute access and reject a path that changes during the check."""
    try:
        executable = os.access(
            command,
            os.X_OK,
            dir_fd=directory_descriptor,
            follow_symlinks=False,
        )
    except (NotImplementedError, TypeError):
        return _mode_is_executable_for_current_user(metadata)
    try:
        current = os.stat(
            command, dir_fd=directory_descriptor, follow_symlinks=False
        )
    except OSError:
        return None
    initial_identity = (metadata.st_dev, metadata.st_ino, metadata.st_mode)
    current_identity = (current.st_dev, current.st_ino, current.st_mode)
    if initial_identity != current_identity or stat.S_ISLNK(current.st_mode):
        return None
    return executable


def _command_record(
    command: str, expected_roots: Sequence[str]
) -> Mapping[str, str]:
    """Resolve a command without following a PATH-directory or command link."""
    if not command or os.sep in command or (os.altsep and os.altsep in command):
        return {"status": "error", "error_code": "io_error"}
    nofollow = getattr(os, "O_NOFOLLOW", None)
    directory_flag = getattr(os, "O_DIRECTORY", None)
    if nofollow is None or directory_flag is None:
        return {"status": "error", "error_code": "io_error"}

    for entry in os.environ.get("PATH", os.defpath).split(os.pathsep):
        directory = entry or os.curdir
        try:
            directory_metadata = os.lstat(directory)
        except FileNotFoundError:
            continue
        except OSError as exc:
            return _error_record(exc)
        directory_mode = directory_metadata.st_mode
        if stat.S_ISLNK(directory_mode):
            return {"status": "error", "error_code": "io_error"}
        if not stat.S_ISDIR(directory_mode):
            continue

        try:
            descriptor = os.open(directory, _directory_flags(no_follow=True))
        except FileNotFoundError:
            continue
        except OSError as exc:
            return _error_record(exc)
        try:
            try:
                opened_directory = os.fstat(descriptor)
            except OSError as exc:
                return _error_record(exc)
            before_identity = (
                directory_metadata.st_mode,
                directory_metadata.st_dev,
                directory_metadata.st_ino,
            )
            opened_identity = (
                opened_directory.st_mode,
                opened_directory.st_dev,
                opened_directory.st_ino,
            )
            if before_identity != opened_identity:
                return {"status": "error", "error_code": "io_error"}
            try:
                metadata = os.stat(
                    command, dir_fd=descriptor, follow_symlinks=False
                )
            except FileNotFoundError:
                continue
            except OSError as exc:
                return _error_record(exc)
            if stat.S_ISLNK(metadata.st_mode):
                return {"status": "error", "error_code": "io_error"}
            executable = _executable_at(descriptor, command, metadata)
            if executable is None:
                return {"status": "error", "error_code": "io_error"}
            if executable:
                resolved = os.path.join(directory, command)
                return {
                    "status": "present",
                    "resolution": _command_resolution(resolved, expected_roots),
                }
        finally:
            try:
                os.close(descriptor)
            except OSError:
                pass
    return {"status": "missing"}


def _target_scope(
    target: str, home: Path, installed_repo: Path, source_repo: Path
) -> str:
    if not os.path.isabs(target):
        return "relative"
    target_path = Path(os.path.normpath(target))
    for root, scope in (
        (installed_repo, "installed_repo"),
        (source_repo, "source_repo"),
        (home, "home"),
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
                record: Mapping[str, Any] = _command_record(
                    definition.command or "", definition.expected_roots
                )
            else:
                if definition.path is None:
                    raise ProbeError("path probe missing declared path")
                try:
                    parent_descriptor, name = _open_declared_parent(
                        definition.path, home, installed_repo
                    )
                except FileNotFoundError:
                    record = {"status": "missing"}
                except OSError as exc:
                    record = _error_record(exc)
                else:
                    try:
                        if definition.kind == "marker":
                            record = _marker_record(
                                parent_descriptor, name, definition.expected
                            )
                        else:
                            try:
                                mode = os.stat(
                                    name,
                                    dir_fd=parent_descriptor,
                                    follow_symlinks=False,
                                ).st_mode
                            except FileNotFoundError:
                                record = {"status": "missing"}
                            except OSError as exc:
                                record = _error_record(exc)
                            else:
                                observed_type = _file_type(mode)
                                if definition.kind == "symlink":
                                    if observed_type != "symlink":
                                        record = {
                                            "status": "other",
                                            "type": observed_type,
                                        }
                                    else:
                                        try:
                                            target = os.readlink(
                                                name, dir_fd=parent_descriptor
                                            )
                                            expected_target = definition.expected or ""
                                            expected_path = expected_target.replace(
                                                "<repo>", str(installed_repo), 1
                                            ).replace("<home>", str(home), 1)
                                            comparison = (
                                                "matched"
                                                if target.rstrip("/")
                                                == expected_path.rstrip("/")
                                                else "mismatched"
                                            )
                                            record = {
                                                "status": "symlink",
                                                "comparison": comparison,
                                            }
                                            if comparison == "mismatched":
                                                record["target_scope"] = _target_scope(
                                                    target,
                                                    home,
                                                    installed_repo,
                                                    source_repo,
                                                )
                                        except OSError as exc:
                                            record = _error_record(exc)
                                elif definition.kind in (
                                    "directory",
                                    "git_directory",
                                ):
                                    if observed_type == "directory":
                                        record = {"status": "directory"}
                                    else:
                                        record = {
                                            "status": "other",
                                            "type": observed_type,
                                        }
                                else:
                                    raise ProbeError(
                                        "unsupported probe kind: %s"
                                        % definition.kind
                                    )
                    finally:
                        try:
                            os.close(parent_descriptor)
                        except OSError:
                            pass
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


def read_fixture(path: Path) -> Any:
    """Read one bounded regular JSON file without following its final link."""
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        raise ProbeError("safe fixture reads are not supported on this platform")

    flags = os.O_RDONLY | nofollow
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(str(path), flags)
    except OSError:
        raise ProbeError("cannot read fixture data")

    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ProbeError("fixture must be a regular file")
        if metadata.st_size > MAX_FIXTURE_BYTES:
            raise ProbeError("fixture exceeds the size limit")

        chunks = []
        remaining = MAX_FIXTURE_BYTES + 1
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        if len(raw) > MAX_FIXTURE_BYTES:
            raise ProbeError("fixture exceeds the size limit")
    except ProbeError:
        raise
    except OSError:
        raise ProbeError("cannot read fixture data")
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass

    try:
        text = raw.decode("utf-8")
    except UnicodeError:
        raise ProbeError("fixture data is not valid UTF-8")
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise ProbeError(
            "fixture JSON is invalid at line %d column %d"
            % (exc.lineno, exc.colno)
        )
    except RecursionError:
        raise ProbeError("fixture JSON nesting is too deep")


def load_fixture(
    path: Path,
    definitions: Sequence[ProbeDefinition],
    profile: Optional[str],
    data: Any = _FIXTURE_DATA_UNSET,
) -> Collection:
    if data is _FIXTURE_DATA_UNSET:
        data = read_fixture(path)
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
        if len(values) > MAX_OBSERVATIONS_PER_PROBE:
            raise ProbeError(
                "fixture observation %s exceeds the record limit" % probe_id
            )
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
