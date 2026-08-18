"""Strict, non-evaluating discovery of repository installation intent."""

from dataclasses import dataclass
from pathlib import Path, PurePosixPath
import re
import shlex
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


PROFILE_NAMES = ("agent", "personal", "work")
PLATFORM_NAMES = ("linux", "macos")


class IntentError(ValueError):
    """Repository intent did not match the deliberately small supported grammar."""


@dataclass(frozen=True)
class Source:
    path: str
    line: int
    text: str


@dataclass(frozen=True)
class PackageEntry:
    manager: str
    name: str
    source: Source


@dataclass(frozen=True)
class ProfileIntent:
    name: str
    gitconfig: str
    macos_manifests: Tuple[str, ...]
    linux_manifests: Tuple[str, ...]
    install_oh_my_zsh: bool
    install_tpm: bool
    link_relay: bool
    source: Source
    manifest_sources: Mapping[str, Source]

    def manifests_for(self, platform: str) -> Tuple[str, ...]:
        if platform == "macos":
            return self.macos_manifests
        if platform == "linux":
            return self.linux_manifests
        raise IntentError("unsupported platform: %s" % platform)

    def source_for_manifest(self, manifest: str) -> Source:
        try:
            return self.manifest_sources[manifest]
        except KeyError:
            raise IntentError("profile did not declare the selected manifest")


@dataclass(frozen=True)
class PlatformIntent:
    name: str
    package_manager: str
    supports_macos_defaults: bool
    source: Source


@dataclass(frozen=True)
class VerifierCheck:
    check_type: str
    arguments: Tuple[str, ...]
    condition: Optional[str]
    source: Source


_SCALAR_RE = re.compile(r'^([A-Z][A-Z0-9_]*)=(?:"([^"]*)"|([01]))$')
_ARRAY_START_RE = re.compile(r"^([A-Z][A-Z0-9_]*)=\($")
_EMPTY_ARRAY_RE = re.compile(r"^([A-Z][A-Z0-9_]*)=\(\)$")
_ARRAY_ITEM_RE = re.compile(r'^\s*"([^"]+)"\s*$')
_BREW_ENTRY_RE = re.compile(r'^(tap|brew|cask|vscode)\s+"([^"]+)"')
_BREW_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+_.@/-]*$")
_LINUX_PACKAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+_.@-]*$")
_CHECK_RE = re.compile(
    r"^\s*require_(symlink|command|dir|git_dir|file_contains)\s+(.+?)\s*$"
)
_CONDITION_RE = re.compile(
    r'^\s*if \[ "\$(installs_package_tools|installs_oh_my_zsh)" -eq 1 \]; then$'
)


def _read_lines(path: Path, display_path: str) -> List[str]:
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except OSError:
        raise IntentError("cannot read repository file: %s" % display_path)
    except UnicodeError:
        raise IntentError("repository file is not valid UTF-8: %s" % display_path)


def _source(repo_root: Path, path: Path, line: int, text: str) -> Source:
    return Source(str(path.relative_to(repo_root)), line, text.strip())


def _repo_relative(value: str) -> str:
    prefix = "$DOTFILES_DIR/"
    if not value.startswith(prefix):
        raise IntentError("expected a $DOTFILES_DIR-relative value")
    relative = value[len(prefix) :]
    pure = PurePosixPath(relative)
    if pure.is_absolute() or ".." in pure.parts or not pure.parts:
        raise IntentError("unsafe repository-relative value")
    return pure.as_posix()


def discover_profile(repo_root: Path, profile: str) -> ProfileIntent:
    if profile not in PROFILE_NAMES:
        raise IntentError("unknown profile: %s" % profile)
    path = repo_root / "profiles" / (profile + ".sh")
    display_path = str(path.relative_to(repo_root))
    lines = _read_lines(path, display_path)
    scalars: Dict[str, str] = {}
    arrays: Dict[str, List[str]] = {}
    array_sources: Dict[str, List[Tuple[str, Source]]] = {}
    current_array: Optional[str] = None

    for line_number, raw in enumerate(lines, 1):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if current_array:
            if stripped == ")":
                current_array = None
                continue
            match = _ARRAY_ITEM_RE.match(raw)
            if not match:
                raise IntentError(
                    "%s:%d: unsupported array item" % (display_path, line_number)
                )
            relative = _repo_relative(match.group(1))
            arrays[current_array].append(relative)
            array_sources[current_array].append(
                (relative, _source(repo_root, path, line_number, raw))
            )
            continue
        match = _ARRAY_START_RE.match(stripped)
        if match:
            current_array = match.group(1)
            arrays[current_array] = []
            array_sources[current_array] = []
            continue
        match = _EMPTY_ARRAY_RE.match(stripped)
        if match:
            arrays[match.group(1)] = []
            array_sources[match.group(1)] = []
            continue
        match = _SCALAR_RE.match(stripped)
        if not match:
            raise IntentError(
                "%s:%d: unsupported profile syntax" % (display_path, line_number)
            )
        scalars[match.group(1)] = match.group(2) or match.group(3)

    if current_array:
        raise IntentError("%s: unterminated array" % display_path)
    expected_scalars = {
        "PROFILE_NAME",
        "PROFILE_GITCONFIG",
        "PROFILE_INSTALL_OH_MY_ZSH",
        "PROFILE_INSTALL_TPM",
        "PROFILE_RUN_MACOS_DEFAULTS",
        "PROFILE_LINK_RELAY",
    }
    expected_arrays = {
        "PROFILE_MACOS_BREWFILES",
        "PROFILE_LINUX_PACKAGE_FILES",
    }
    if set(scalars) != expected_scalars or set(arrays) != expected_arrays:
        raise IntentError(
            "%s: profile keys changed; update the adapter intentionally"
            % display_path
        )
    if scalars.get("PROFILE_NAME") != profile:
        raise IntentError(
            "%s: PROFILE_NAME does not match filename" % display_path
        )

    gitconfig = _repo_relative(scalars["PROFILE_GITCONFIG"])
    return ProfileIntent(
        name=profile,
        gitconfig=gitconfig,
        macos_manifests=tuple(arrays.get("PROFILE_MACOS_BREWFILES", [])),
        linux_manifests=tuple(arrays.get("PROFILE_LINUX_PACKAGE_FILES", [])),
        install_oh_my_zsh=scalars.get("PROFILE_INSTALL_OH_MY_ZSH") == "1",
        install_tpm=scalars.get("PROFILE_INSTALL_TPM") == "1",
        link_relay=scalars.get("PROFILE_LINK_RELAY") == "1",
        source=_source(repo_root, path, 1, lines[0] if lines else ""),
        manifest_sources=dict(
            array_sources["PROFILE_MACOS_BREWFILES"]
            + array_sources["PROFILE_LINUX_PACKAGE_FILES"]
        ),
    )


def discover_platform(repo_root: Path, platform: str) -> PlatformIntent:
    if platform not in PLATFORM_NAMES:
        raise IntentError("unknown platform: %s" % platform)
    path = repo_root / "platforms" / (platform + ".sh")
    display_path = str(path.relative_to(repo_root))
    lines = _read_lines(path, display_path)
    scalars: Dict[str, str] = {}
    for line_number, raw in enumerate(lines, 1):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = _SCALAR_RE.match(stripped)
        if not match:
            raise IntentError(
                "%s:%d: unsupported platform syntax" % (display_path, line_number)
            )
        scalars[match.group(1)] = match.group(2) or match.group(3)
    expected = {
        "PLATFORM_NAME",
        "PLATFORM_PACKAGE_MANAGER",
        "PLATFORM_SUPPORTS_MACOS_DEFAULTS",
    }
    if set(scalars) != expected or scalars["PLATFORM_NAME"] != platform:
        raise IntentError(
            "%s: platform keys changed; update the adapter intentionally"
            % display_path
        )
    return PlatformIntent(
        name=platform,
        package_manager=scalars["PLATFORM_PACKAGE_MANAGER"],
        supports_macos_defaults=scalars["PLATFORM_SUPPORTS_MACOS_DEFAULTS"] == "1",
        source=_source(repo_root, path, 1, lines[0] if lines else ""),
    )


def discover_packages(repo_root: Path, manifests: Sequence[str]) -> List[PackageEntry]:
    entries: List[PackageEntry] = []
    for relative in manifests:
        pure = PurePosixPath(relative)
        if pure.is_absolute() or ".." in pure.parts:
            raise IntentError("unsafe manifest path")
        path = repo_root / pure
        display_path = str(path.relative_to(repo_root))
        lines = _read_lines(path, display_path)
        if relative.endswith(".Brewfile"):
            for line_number, raw in enumerate(lines, 1):
                stripped = raw.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                if any(token in stripped for token in (";", "`", "$(")):
                    raise IntentError(
                        "%s:%d: unsafe Brewfile control token"
                        % (display_path, line_number)
                    )
                match = _BREW_ENTRY_RE.match(stripped)
                if not match:
                    raise IntentError(
                        "%s:%d: unsupported Brewfile declaration"
                        % (display_path, line_number)
                    )
                if not _BREW_NAME_RE.match(match.group(2)):
                    raise IntentError(
                        "%s:%d: unsafe Brewfile item name"
                        % (display_path, line_number)
                    )
                entries.append(
                    PackageEntry(
                        match.group(1),
                        match.group(2),
                        _source(repo_root, path, line_number, raw),
                    )
                )
        else:
            for line_number, raw in enumerate(lines, 1):
                name = raw.strip()
                if not name or name.startswith("#"):
                    continue
                if not _LINUX_PACKAGE_RE.match(name):
                    raise IntentError(
                        "%s:%d: unsafe Linux package name"
                        % (display_path, line_number)
                    )
                entries.append(
                    PackageEntry(
                        "linux",
                        name,
                        _source(repo_root, path, line_number, raw),
                    )
                )
    return entries


def discover_verifier_checks(repo_root: Path) -> List[VerifierCheck]:
    """Extract the current verifier's granular calls without sourcing shell code."""
    path = repo_root / "tests" / "verify-mac-install.sh"
    display_path = str(path.relative_to(repo_root))
    lines = _read_lines(path, display_path)
    checks: List[VerifierCheck] = []
    condition: Optional[str] = None
    in_function = False
    function_depth = 0

    for line_number, raw in enumerate(lines, 1):
        stripped = raw.strip()
        if re.match(r"^[a-z_]+\(\) \{$", stripped):
            in_function = True
            function_depth = 1
            continue
        if in_function:
            function_depth += stripped.count("{") - stripped.count("}")
            if function_depth <= 0:
                in_function = False
            continue

        condition_match = _CONDITION_RE.match(raw)
        if condition_match:
            if condition is not None:
                raise IntentError(
                    "%s:%d: nested supported condition"
                    % (display_path, line_number)
                )
            condition = condition_match.group(1)
            continue
        if stripped == "fi" and condition is not None:
            condition = None
            continue

        match = _CHECK_RE.match(raw)
        if not match:
            continue
        try:
            arguments = tuple(shlex.split(match.group(2), posix=True))
        except ValueError:
            raise IntentError("%s:%d: invalid shell words" % (display_path, line_number))
        checks.append(
            VerifierCheck(
                match.group(1),
                arguments,
                condition,
                _source(repo_root, path, line_number, raw),
            )
        )

    expected_types = {
        "file_contains": 2,
        "symlink": 7,
        "command": 9,
        "dir": 1,
        "git_dir": 1,
    }
    actual = {name: 0 for name in expected_types}
    for check in checks:
        actual[check.check_type] += 1
    if actual != expected_types:
        raise IntentError(
            "verifier check surface changed; update the adapter intentionally "
            "(expected %r, found %r)" % (expected_types, actual)
        )
    expected_surface = {
        (
            "file_contains",
            (
                "$HOME/.config/dotfiles/profile",
                "$PROFILE",
                "dotfiles profile marker",
            ),
            None,
        ),
        (
            "file_contains",
            (
                "$HOME/.config/dotfiles/platform",
                "macos",
                "dotfiles platform marker",
            ),
            None,
        ),
        ("symlink", ("$HOME/.gitconfig", "$gitconfig"), None),
        (
            "symlink",
            ("$HOME/.gitignore_global", "$DOTFILES_DIR/git/.gitignore_global"),
            None,
        ),
        ("symlink", ("$HOME/.zshrc", "$DOTFILES_DIR/config/.zshrc"), None),
        ("symlink", ("$HOME/.vimrc", "$DOTFILES_DIR/config/.vimrc"), None),
        (
            "symlink",
            ("$HOME/.tmux.conf", "$DOTFILES_DIR/config/tmux.conf"),
            None,
        ),
        (
            "symlink",
            (
                "$HOME/.config/starship.toml",
                "$DOTFILES_DIR/config/starship.toml",
            ),
            None,
        ),
        (
            "symlink",
            ("$HOME/.config/relay", "$DOTFILES_DIR/config/relay"),
            None,
        ),
        ("command", ("git",), None),
        ("command", ("curl",), "installs_package_tools"),
        ("command", ("rg",), "installs_package_tools"),
        ("command", ("fzf",), "installs_package_tools"),
        ("command", ("tmux",), "installs_package_tools"),
        ("command", ("starship",), "installs_package_tools"),
        ("command", ("zoxide",), "installs_package_tools"),
        ("command", ("eza",), "installs_package_tools"),
        ("command", ("nvim",), "installs_package_tools"),
        (
            "dir",
            ("$HOME/.oh-my-zsh", "Oh My Zsh directory"),
            "installs_oh_my_zsh",
        ),
        ("git_dir", ("$HOME/.tmux/plugins/tpm", "TPM"), None),
    }
    actual_surface = {
        (check.check_type, check.arguments, check.condition) for check in checks
    }
    if actual_surface != expected_surface:
        raise IntentError(
            "verifier probe allowlist changed; update the adapter intentionally"
        )
    return checks


def find_install_source(
    repo_root: Path, destination_template: str
) -> Optional[Source]:
    """Find the install.sh declaration corresponding to a verifier destination."""
    path = repo_root / "install.sh"
    lines = _read_lines(path, str(path.relative_to(repo_root)))
    if destination_template == "$HOME/.config/dotfiles/profile":
        needle = '>"$HOME/.config/dotfiles/profile"'
    elif destination_template == "$HOME/.config/dotfiles/platform":
        needle = '>"$HOME/.config/dotfiles/platform"'
    else:
        needle = '"%s"' % destination_template
    for line_number, raw in enumerate(lines, 1):
        if needle in raw and (
            "ensure_symlink " in raw or "printf " in raw
        ):
            return _source(repo_root, path, line_number, raw)
    return None


def verifier_condition_applies(
    condition: Optional[str],
    profile: ProfileIntent,
    platform: str,
    command: Optional[str] = None,
    declared_commands: Iterable[str] = (),
) -> bool:
    if condition is None:
        return True
    if condition == "installs_oh_my_zsh":
        return profile.install_oh_my_zsh
    if condition == "installs_package_tools":
        if platform == "macos":
            return bool(profile.macos_manifests)
        return command in set(declared_commands)
    raise IntentError("unsupported verifier condition: %s" % condition)
