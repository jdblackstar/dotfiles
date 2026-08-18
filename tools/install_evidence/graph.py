"""Graph assembly and traceable claim-state inference."""

from collections import Counter
from dataclasses import dataclass
from pathlib import Path
import re
from typing import Any, Dict, List, Mapping, Sequence, Set, Tuple

from . import SCHEMA_VERSION
from .intent import (
    PackageEntry,
    PlatformIntent,
    ProfileIntent,
    Source,
    VerifierCheck,
    discover_packages,
    discover_platform,
    discover_profile,
    discover_verifier_checks,
    find_install_source,
    verifier_condition_applies,
)
from .probes import Collection, ProbeDefinition


COMMAND_BY_PACKAGE = {
    "curl": "curl",
    "eza": "eza",
    "fzf": "fzf",
    "git": "git",
    "neovim": "nvim",
    "ripgrep": "rg",
    "starship": "starship",
    "tmux": "tmux",
    "zoxide": "zoxide",
}
REPRESENTATIVE_UNVERIFIED = {"1password", "cursor"}
STATE_ORDER = {
    "failed": 0,
    "conflicted": 1,
    "unknown": 2,
    "skipped": 3,
    "proven": 4,
    "not_applicable": 5,
}


class GraphError(ValueError):
    """Graph assembly failed because tracked intent is unsupported."""


def slug(value: str) -> str:
    cleaned = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return cleaned or "item"


def _source_id(source: Source) -> str:
    return "evidence:source:%s:%d" % (slug(source.path), source.line)


def _source_evidence(source: Source) -> Dict[str, Any]:
    return {
        "id": _source_id(source),
        "kind": "source",
        "probe": "tracked_source",
        "outcome": "declared",
        "details": {
            "path": source.path,
            "line": source.line,
        },
    }


def _path_label(template: str) -> str:
    return template.replace("$HOME", "~").replace("$DOTFILES_DIR", "<repo>")


def _expected_target(template: str, profile: ProfileIntent) -> str:
    if template == "$gitconfig":
        return "<repo>/" + profile.gitconfig
    if template.startswith("$DOTFILES_DIR/"):
        return "<repo>/" + template[len("$DOTFILES_DIR/") :]
    return template.replace("$HOME", "<home>")


def _probe_id(check: VerifierCheck) -> str:
    if check.check_type == "command":
        return "command." + check.arguments[0]
    if check.check_type == "file_contains":
        if check.arguments[0].endswith("/profile"):
            return "marker.profile"
        if check.arguments[0].endswith("/platform"):
            return "marker.platform"
    if check.check_type == "symlink":
        names = {
            "$HOME/.gitconfig": "gitconfig",
            "$HOME/.gitignore_global": "gitignore-global",
            "$HOME/.zshrc": "zshrc",
            "$HOME/.vimrc": "vimrc",
            "$HOME/.tmux.conf": "tmux-conf",
            "$HOME/.config/starship.toml": "starship-config",
            "$HOME/.config/relay": "relay-config",
        }
        return "symlink." + names[check.arguments[0]]
    if check.check_type == "dir":
        return "directory.oh-my-zsh"
    if check.check_type == "git_dir":
        return "directory.tpm-git"
    raise GraphError("verifier check is outside the public-safe probe allowlist")


def _expected_roots(command: str, platform: str) -> Tuple[str, ...]:
    if platform == "macos":
        roots = ["/opt/homebrew/bin", "/usr/local/bin"]
        if command in ("curl", "git"):
            roots.extend(["/usr/bin", "/bin"])
        return tuple(roots)
    roots = ["/usr/bin", "/bin", "/usr/local/bin", "/snap/bin"]
    return tuple(roots)


@dataclass(frozen=True)
class IntentBundle:
    profile: ProfileIntent
    platform: PlatformIntent
    packages: Tuple[PackageEntry, ...]
    checks: Tuple[VerifierCheck, ...]
    definitions: Tuple[ProbeDefinition, ...]
    command_packages: Mapping[str, PackageEntry]


def discover_intent(repo_root: Path, profile_name: str, platform: str) -> IntentBundle:
    profile = discover_profile(repo_root, profile_name)
    platform_intent = discover_platform(repo_root, platform)
    packages = tuple(discover_packages(repo_root, profile.manifests_for(platform)))
    checks = tuple(discover_verifier_checks(repo_root))
    command_packages: Dict[str, PackageEntry] = {}
    for package in packages:
        command = COMMAND_BY_PACKAGE.get(package.name)
        if command and command not in command_packages:
            command_packages[command] = package
    declared_commands = set(command_packages)
    definitions: List[ProbeDefinition] = []

    for check in checks:
        probe_id = _probe_id(check)
        command = check.arguments[0] if check.check_type == "command" else None
        applicable = verifier_condition_applies(
            check.condition, profile, platform, command, declared_commands
        )
        if check.check_type == "file_contains":
            expected = profile.name if probe_id == "marker.profile" else platform
            definitions.append(
                ProbeDefinition(
                    probe_id, "marker", check.arguments[0], expected, applicable=True
                )
            )
        elif check.check_type == "symlink":
            definitions.append(
                ProbeDefinition(
                    probe_id,
                    "symlink",
                    check.arguments[0],
                    _expected_target(check.arguments[1], profile),
                    applicable=applicable,
                )
            )
        elif check.check_type == "command":
            definitions.append(
                ProbeDefinition(
                    probe_id,
                    "command",
                    command=command,
                    expected_roots=_expected_roots(command or "", platform),
                    applicable=applicable,
                )
            )
        elif check.check_type == "dir":
            definitions.append(
                ProbeDefinition(
                    probe_id, "directory", check.arguments[0], applicable=applicable
                )
            )
        elif check.check_type == "git_dir":
            definitions.append(
                ProbeDefinition(
                    probe_id,
                    "git_directory",
                    check.arguments[0] + "/.git",
                    applicable=applicable,
                )
            )
    return IntentBundle(
        profile,
        platform_intent,
        packages,
        checks,
        tuple(definitions),
        command_packages,
    )


def _infer_observation(
    definition: ProbeDefinition, records: Sequence[Mapping[str, Any]]
) -> Tuple[str, str, str]:
    if not definition.applicable:
        return (
            "not_applicable",
            "profile_platform_applicability",
            "check does not apply to the selected profile/platform",
        )
    if not records:
        return (
            "unknown",
            "missing_observation",
            "fixture/live collection supplied no observation",
        )
    statuses = {str(record.get("status")) for record in records}
    record_fingerprints = {
        tuple(sorted((str(key), str(value)) for key, value in record.items()))
        for record in records
    }
    if len(record_fingerprints) > 1:
        return (
            "conflicted",
            "conflicting_observations",
            "observations disagree despite reporting the same probe",
        )
    if len(statuses) > 1:
        return (
            "conflicted",
            "conflicting_observations",
            "observations disagree: %s" % ", ".join(sorted(statuses)),
        )
    status = next(iter(statuses))
    if status == "error":
        error_code = str(records[0].get("error_code", "io_error"))
        return (
            "unknown",
            "probe_error_is_unknown",
            "probe failed (%s); no raw error text was retained" % error_code,
        )
    if status == "skipped":
        return ("skipped", "explicit_probe_skip", "probe was intentionally skipped")
    if status == "missing":
        return ("failed", "required_item_missing", "required item is absent")

    record = records[0]
    if definition.kind == "marker":
        comparison = str(record.get("comparison", ""))
        if status == "present" and comparison == "matched":
            return ("proven", "marker_value_matches", "marker value matches")
        return (
            "failed",
            "marker_value_mismatch",
            "marker value did not match; the observed value was discarded",
        )
    if definition.kind == "symlink":
        if status != "symlink":
            return (
                "failed",
                "wrong_path_type",
                "observed %s; expected symlink" % record.get("type", status),
            )
        if record.get("comparison") == "matched":
            return ("proven", "symlink_target_matches", "symlink target matches")
        return (
            "failed",
            "symlink_target_mismatch",
            "symlink target differs (scope: %s); the target was discarded"
            % record.get("target_scope", "unknown"),
        )
    if definition.kind == "command":
        if status != "present":
            return ("failed", "command_missing", "command is not on PATH")
        if record.get("resolution") == "allowed":
            return (
                "proven",
                "command_resolution_allowed",
                "resolved within an allowed command root; exact path discarded",
            )
        return (
            "failed",
            "unexpected_command_resolution",
            "resolved outside allowed command roots; exact path discarded",
        )
    if definition.kind in ("directory", "git_directory"):
        if status == "directory":
            return ("proven", "directory_exists", "directory exists")
        return (
            "failed",
            "wrong_path_type",
            "observed %s; expected directory" % record.get("type", status),
        )
    raise GraphError("unsupported probe kind: %s" % definition.kind)


def _check_label(check: VerifierCheck) -> str:
    if check.check_type == "command":
        return "command %s resolves as expected" % check.arguments[0]
    if check.check_type == "file_contains":
        return "%s has the selected value" % _path_label(check.arguments[0])
    if check.check_type == "symlink":
        return "%s targets the managed source" % _path_label(check.arguments[0])
    if check.check_type == "dir":
        return "%s exists" % _path_label(check.arguments[0])
    if check.check_type == "git_dir":
        return "%s is a Git checkout" % _path_label(check.arguments[0])
    return check.check_type


def assemble_document(
    repo_root: Path, intent: IntentBundle, collection: Collection
) -> Dict[str, Any]:
    nodes: Dict[str, Dict[str, Any]] = {}
    edges: Set[Tuple[str, str, str]] = set()
    evidence: Dict[str, Dict[str, Any]] = {}
    claims: List[Dict[str, Any]] = []
    profile_id = "profile:" + intent.profile.name
    platform_id = "platform:" + intent.platform.name
    nodes[profile_id] = {
        "id": profile_id,
        "kind": "profile",
        "label": "%s profile" % intent.profile.name,
        "attributes": {"platform": collection.platform},
    }
    profile_source = _source_evidence(intent.profile.source)
    evidence[profile_source["id"]] = profile_source
    nodes[profile_source["id"]] = {
        "id": profile_source["id"],
        "kind": "evidence",
        "label": "%s:%d" % (
            intent.profile.source.path,
            intent.profile.source.line,
        ),
        "attributes": {"evidence_type": "source"},
    }
    edges.add((profile_id, profile_source["id"], "proven_by"))
    nodes[platform_id] = {
        "id": platform_id,
        "kind": "platform",
        "label": "%s platform" % intent.platform.name,
        "attributes": {
            "package_manager": intent.platform.package_manager,
            "supports_macos_defaults": intent.platform.supports_macos_defaults,
        },
    }
    platform_source = _source_evidence(intent.platform.source)
    evidence[platform_source["id"]] = platform_source
    nodes[platform_source["id"]] = {
        "id": platform_source["id"],
        "kind": "evidence",
        "label": "%s:%d"
        % (intent.platform.source.path, intent.platform.source.line),
        "attributes": {"evidence_type": "source"},
    }
    edges.add((profile_id, platform_id, "applies_on"))
    edges.add((platform_id, platform_source["id"], "proven_by"))

    for manifest in intent.profile.manifests_for(collection.platform):
        manifest_id = "manifest:" + slug(manifest)
        manifest_source = intent.profile.source_for_manifest(manifest)
        nodes[manifest_id] = {
            "id": manifest_id,
            "kind": "manifest",
            "label": manifest,
            "attributes": {
                "platform": collection.platform,
                "profile_source": {
                    "path": manifest_source.path,
                    "line": manifest_source.line,
                },
            },
        }
        edges.add((profile_id, manifest_id, "profile_includes"))
        manifest_source_record = _source_evidence(manifest_source)
        evidence[manifest_source_record["id"]] = manifest_source_record
        nodes[manifest_source_record["id"]] = {
            "id": manifest_source_record["id"],
            "kind": "evidence",
            "label": "%s:%d"
            % (manifest_source.path, manifest_source.line),
            "attributes": {"evidence_type": "source"},
        }
        edges.add((manifest_id, manifest_source_record["id"], "proven_by"))

    for package in intent.packages:
        manifest_id = "manifest:" + slug(package.source.path)
        package_id = "package:%s:%s" % (package.manager, slug(package.name))
        nodes[package_id] = {
            "id": package_id,
            "kind": "package",
            "label": "%s %s" % (package.manager, package.name),
            "attributes": {"name": package.name, "manager": package.manager},
        }
        edges.add((manifest_id, package_id, "declares"))
        source_record = _source_evidence(package.source)
        evidence[source_record["id"]] = source_record
        nodes[source_record["id"]] = {
            "id": source_record["id"],
            "kind": "evidence",
            "label": "%s:%d" % (package.source.path, package.source.line),
            "attributes": {"evidence_type": "source"},
        }
        edges.add((package_id, source_record["id"], "proven_by"))

    checks_by_probe = {_probe_id(check): check for check in intent.checks}
    definitions_by_id = {definition.id: definition for definition in intent.definitions}

    for probe_id in sorted(definitions_by_id):
        definition = definitions_by_id[probe_id]
        check = checks_by_probe[probe_id]
        claim_id = "claim:" + probe_id
        observation_records = collection.observations.get(probe_id, ())
        state, rule, explanation = _infer_observation(
            definition, observation_records
        )
        source_records: List[Dict[str, Any]] = [_source_evidence(check.source)]
        install_source = None
        if check.check_type in ("file_contains", "symlink"):
            install_source = find_install_source(repo_root, check.arguments[0])
            if install_source:
                source_records.append(_source_evidence(install_source))
        for source_record in source_records:
            evidence[source_record["id"]] = source_record
            nodes[source_record["id"]] = {
                "id": source_record["id"],
                "kind": "evidence",
                "label": "%s:%d"
                % (
                    source_record["details"]["path"],
                    source_record["details"]["line"],
                ),
                "attributes": {"evidence_type": "source"},
            }
            edges.add((claim_id, source_record["id"], "proven_by"))

        observed_ids: List[str] = []
        for index, record in enumerate(observation_records, 1):
            observed_id = "evidence:observation:%s:%d" % (slug(probe_id), index)
            observed_ids.append(observed_id)
            observed = {
                "id": observed_id,
                "kind": "observation",
                "probe": probe_id,
                "outcome": record.get("status"),
                "details": dict(sorted(record.items())),
            }
            evidence[observed_id] = observed
            nodes[observed_id] = {
                "id": observed_id,
                "kind": "evidence",
                "label": "%s: %s" % (probe_id, record.get("status")),
                "attributes": {"evidence_type": "observation"},
            }
            edges.add((claim_id, observed_id, "proven_by"))

        nodes[claim_id] = {
            "id": claim_id,
            "kind": "claim",
            "label": _check_label(check),
            "state": state,
            "attributes": {
                "probe_id": probe_id,
                "required": definition.applicable,
                "rule": rule,
            },
        }
        edges.add((profile_id, claim_id, "requires"))
        if probe_id == "marker.platform":
            edges.add((platform_id, claim_id, "requires"))
        command = definition.command
        if command and command in intent.command_packages:
            package = intent.command_packages[command]
            package_id = "package:%s:%s" % (package.manager, slug(package.name))
            edges.add((package_id, claim_id, "installs"))
        claims.append(
            {
                "id": claim_id,
                "label": _check_label(check),
                "state": state,
                "required": definition.applicable,
                "rule": rule,
                "explanation": explanation,
                "evidence_ids": sorted(
                    [record["id"] for record in source_records] + observed_ids
                ),
                "source": {
                    "path": check.source.path,
                    "line": check.source.line,
                },
            }
        )

    for package in intent.packages:
        if package.name not in REPRESENTATIVE_UNVERIFIED:
            continue
        package_id = "package:%s:%s" % (package.manager, slug(package.name))
        claim_id = "claim:package-unverified:" + slug(package.name)
        state = (
            "unknown"
            if collection.platform == "macos"
            else "not_applicable"
        )
        rule = (
            "no_safe_probe_mapped"
            if state == "unknown"
            else "profile_platform_applicability"
        )
        explanation = (
            "declared package has no probe in this vertical slice"
            if state == "unknown"
            else "macOS package does not apply on this platform"
        )
        nodes[claim_id] = {
            "id": claim_id,
            "kind": "claim",
            "label": "%s installation is verified" % package.name,
            "state": state,
            "attributes": {"required": False, "rule": rule},
        }
        edges.add((package_id, claim_id, "requires"))
        claims.append(
            {
                "id": claim_id,
                "label": "%s installation is verified" % package.name,
                "state": state,
                "required": False,
                "rule": rule,
                "explanation": explanation,
                "evidence_ids": [
                    _source_id(package.source)
                ],
                "source": {
                    "path": package.source.path,
                    "line": package.source.line,
                },
            }
        )

    required_claims = [
        claim
        for claim in claims
        if claim["required"] and claim["state"] != "not_applicable"
    ]
    health_id = "claim:installation-healthy"
    failed = [
        claim
        for claim in required_claims
        if claim["state"] in ("failed", "conflicted")
    ]
    unresolved = [
        claim
        for claim in required_claims
        if claim["state"] in ("unknown", "skipped")
    ]
    if failed:
        health_state = "failed"
        health_rule = "required_failure_propagation"
        health_explanation = "%d required claim(s) failed or conflicted" % len(failed)
    elif unresolved:
        health_state = "unknown"
        health_rule = "required_unknown_propagation"
        health_explanation = "%d required claim(s) remain unresolved" % len(unresolved)
    else:
        health_state = "proven"
        health_rule = "all_required_claims_proven"
        health_explanation = "all applicable required claims are proven"
    nodes[health_id] = {
        "id": health_id,
        "kind": "claim",
        "label": "%s/%s installation is healthy"
        % (collection.profile, collection.platform),
        "state": health_state,
        "attributes": {"required": True, "rule": health_rule},
    }
    edges.add((profile_id, health_id, "requires"))
    for blocker in failed + unresolved:
        edges.add((health_id, blocker["id"], "blocked_by"))
    health_claim = {
        "id": health_id,
        "label": nodes[health_id]["label"],
        "state": health_state,
        "required": True,
        "rule": health_rule,
        "explanation": health_explanation,
        "evidence_ids": [],
        "source": None,
        "blocked_by": sorted(claim["id"] for claim in failed + unresolved),
    }
    claims.append(health_claim)

    counts = Counter(claim["state"] for claim in claims if claim["id"] != health_id)
    privacy = {
        "distribution": "local_only",
        "raw_marker_values_retained": False,
        "raw_command_paths_retained": False,
        "raw_symlink_targets_retained": False,
        "raw_error_messages_retained": False,
    }
    if collection.mode == "live":
        privacy.update(
            {
                "contains_host_state": True,
                "mode": "sanitized_local",
                "safe_to_publish": False,
            }
        )
    elif collection.mode == "fixture":
        privacy.update(
            {
                "mode": "fixture_replay",
                "provenance": "caller_supplied_unverified",
                "safe_to_publish": False,
            }
        )
    else:
        raise GraphError("unsupported collection mode")

    return {
        "schema_version": SCHEMA_VERSION,
        "collection": {
            "mode": collection.mode,
            "timestamp": collection.collected_at,
            "platform": collection.platform,
            "profile": collection.profile,
            "sanitization": {
                "home": "<home>",
                "installed_repository": "<repo>",
                "source_repository": "<source-repo>",
            },
            "privacy": privacy,
        },
        "summary": {
            "health_claim_id": health_id,
            "health_state": health_state,
            "claim_counts": {
                state: counts.get(state, 0)
                for state in (
                    "proven",
                    "failed",
                    "unknown",
                    "skipped",
                    "not_applicable",
                    "conflicted",
                )
            },
            "mapped_verifier_checks": len(intent.checks),
            "package_declarations": len(intent.packages),
            "unverified_representative_packages": sum(
                1
                for claim in claims
                if claim["rule"] == "no_safe_probe_mapped"
            ),
        },
        "claims": sorted(
            claims,
            key=lambda claim: (
                STATE_ORDER[claim["state"]],
                claim["id"],
            ),
        ),
        "evidence": sorted(evidence.values(), key=lambda item: item["id"]),
        "graph": {
            "nodes": sorted(nodes.values(), key=lambda item: item["id"]),
            "edges": [
                {"from": source, "to": target, "relation": relation}
                for source, target, relation in sorted(edges)
            ],
        },
    }
