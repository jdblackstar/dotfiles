"""Command-line interface for the read-only installation evidence graph."""

import argparse
import json
import os
from pathlib import Path
import platform as host_platform
import sys
from typing import Optional, Sequence

from .graph import GraphError, assemble_document, discover_intent
from .intent import IntentError, PLATFORM_NAMES, PROFILE_NAMES
from .probes import ProbeError, collect_live, load_fixture, read_fixture
from .render import render_dot, render_summary


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="./install-evidence",
        description=(
            "Explain dotfiles installation claims from repository intent and "
            "read-only evidence."
        ),
    )
    mode = parser.add_mutually_exclusive_group(required=False)
    mode.add_argument(
        "--fixture",
        type=Path,
        help="replay inert observations from a versioned JSON fixture",
    )
    mode.add_argument(
        "--live",
        action="store_true",
        help="run the explicit read-only live probe allowlist",
    )
    parser.add_argument("--profile", choices=PROFILE_NAMES)
    parser.add_argument("--platform", choices=PLATFORM_NAMES)
    parser.add_argument(
        "--installed-repo",
        type=Path,
        help="expected installed checkout (default: $HOME/.dotfiles)",
    )
    parser.add_argument(
        "--format",
        choices=("summary", "json", "dot"),
        default="summary",
    )
    parser.add_argument(
        "--list-probes",
        action="store_true",
        help="list probe definitions without executing them",
    )
    return parser


def _detected_platform() -> str:
    name = host_platform.system()
    if name == "Darwin":
        return "macos"
    if name == "Linux":
        return "linux"
    raise ProbeError("unsupported live platform")


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _list_probes(definitions) -> str:
    lines = [
        "Read-only live probe allowlist (no subprocess execution):",
        "  marker: no-follow read of at most 257 bytes; accepts at most 256",
        "  symlink: descriptor-relative no-follow type check + readlink",
        "  directory: descriptor-relative no-follow type check",
        "  git_directory: descriptor-relative no-follow TPM .git check",
        "  command: PATH resolution only (the command is never executed)",
        "",
        "Resolved probe definitions:",
    ]
    for definition in sorted(definitions, key=lambda item: item.id):
        subject = definition.command or definition.path or ""
        lines.append(
            "  %-26s %-14s %-32s %s"
            % (
                definition.id,
                definition.kind,
                subject,
                "applicable" if definition.applicable else "not applicable",
            )
        )
    return "\n".join(lines) + "\n"


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    if not args.live and args.fixture is None and not args.list_probes:
        parser.error("choose --fixture FILE or explicit --live")

    try:
        repo_root = _repo_root()
        if args.fixture is not None:
            # Read profile/platform metadata once; fixture values still cannot define probes.
            raw = read_fixture(args.fixture)
            fixture_profile = raw.get("profile") if isinstance(raw, dict) else None
            fixture_platform = raw.get("platform") if isinstance(raw, dict) else None
            profile = args.profile or fixture_profile
            selected_platform = args.platform or fixture_platform
        else:
            profile = args.profile or "personal"
            selected_platform = args.platform or _detected_platform()
        if profile not in PROFILE_NAMES:
            raise ProbeError("unknown profile in fixture")
        if selected_platform not in PLATFORM_NAMES:
            raise ProbeError("unknown platform in fixture")

        intent = discover_intent(repo_root, profile, selected_platform)
        if args.list_probes:
            sys.stdout.write(_list_probes(intent.definitions))
            return 0
        if args.fixture is not None:
            collection = load_fixture(
                args.fixture, intent.definitions, args.profile, data=raw
            )
            if collection.platform != selected_platform:
                raise ProbeError("fixture platform does not match --platform")
        else:
            home = Path(os.environ.get("HOME", ""))
            installed_repo = args.installed_repo or home / ".dotfiles"
            collection = collect_live(
                intent.definitions,
                profile,
                selected_platform,
                home,
                installed_repo,
                repo_root,
            )
        document = assemble_document(repo_root, intent, collection)
        if args.format == "json":
            json.dump(document, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
        elif args.format == "dot":
            sys.stdout.write(render_dot(document))
        else:
            sys.stdout.write(render_summary(document))

        state = document["summary"]["health_state"]
        if state == "proven":
            return 0
        if state == "failed":
            return 1
        return 2
    except (GraphError, IntentError, ProbeError) as exc:
        sys.stderr.write("error: %s\n" % exc)
        return 64
    except (OSError, UnicodeError, ValueError):
        sys.stderr.write("error: input or filesystem operation failed\n")
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
