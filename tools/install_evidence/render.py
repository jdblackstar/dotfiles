"""Human and DOT renderers for evidence graph documents."""

from typing import Any, Dict


ISSUE_STATES = ("failed", "conflicted", "unknown", "skipped")


def render_summary(document: Dict[str, Any]) -> str:
    collection = document["collection"]
    privacy = collection["privacy"]
    summary = document["summary"]
    counts = summary["claim_counts"]
    lines = [
        "Installation evidence: %s/%s (%s)"
        % (
            collection["profile"],
            collection["platform"],
            collection["mode"],
        ),
        "HEALTH %s — %s"
        % (
            summary["health_state"].upper(),
            next(
                claim["explanation"]
                for claim in document["claims"]
                if claim["id"] == summary["health_claim_id"]
            ),
        ),
    ]
    issues = [
        claim
        for claim in document["claims"]
        if claim["id"] != summary["health_claim_id"]
        and claim["state"] in ISSUE_STATES
    ]
    if issues:
        lines.append("")
        lines.append("Non-proven claims (required failures first; optional gaps included):")
        for claim in issues:
            source = claim.get("source")
            state_label = claim["state"].upper()
            if not claim["required"]:
                state_label += " OPTIONAL"
            source_text = (
                "%s:%s" % (source["path"], source["line"])
                if source
                else "derived"
            )
            lines.extend(
                [
                    "  [%s] %s" % (state_label, claim["label"]),
                    "    profile -> %s -> %s"
                    % (source_text, claim["rule"]),
                    "    %s" % claim["explanation"],
                ]
            )
    if privacy["mode"] == "sanitized_local":
        privacy_notice = (
            "Privacy: sanitized live host state; not safe to publish or commit."
        )
    else:
        privacy_notice = (
            "Privacy: caller-supplied fixture replay; provenance is unverified; "
            "not safe to publish."
        )
    lines.extend(
        [
            "",
            "Claims: %d proven, %d failed, %d conflicted, %d unknown, "
            "%d skipped, %d not applicable"
            % (
                counts["proven"],
                counts["failed"],
                counts["conflicted"],
                counts["unknown"],
                counts["skipped"],
                counts["not_applicable"],
            ),
            "Coverage: %d verifier checks mapped; %d selected manifest declarations"
            % (
                summary["mapped_verifier_checks"],
                summary["package_declarations"],
            ),
            "Read-only explanation only; no repair action was attempted.",
            privacy_notice,
        ]
    )
    return "\n".join(lines) + "\n"


def _dot_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def render_dot(document: Dict[str, Any]) -> str:
    privacy = document["collection"]["privacy"]
    privacy_fields = [
        "distribution=%s" % privacy["distribution"],
        "safe_to_publish=%s" % str(privacy["safe_to_publish"]).lower(),
    ]
    if "contains_host_state" in privacy:
        privacy_fields.append(
            "contains_host_state=%s"
            % str(privacy["contains_host_state"]).lower()
        )
    if "provenance" in privacy:
        privacy_fields.append("provenance=%s" % privacy["provenance"])
    privacy_warning = "Privacy: " + "; ".join(privacy_fields)
    lines = [
        "digraph install_evidence {",
        '  graph [rankdir="LR", label="%s", labelloc="t"];'
        % _dot_escape(privacy_warning),
        '  node [fontname="Helvetica"];',
    ]
    colors = {
        "proven": "palegreen",
        "failed": "lightcoral",
        "conflicted": "orange",
        "unknown": "khaki",
        "skipped": "lightgray",
        "not_applicable": "white",
    }
    for node in document["graph"]["nodes"]:
        attributes = ['label="%s"' % _dot_escape(node["label"])]
        if node["kind"] == "claim":
            attributes.append('shape="box"')
            attributes.append('style="filled"')
            attributes.append(
                'fillcolor="%s"' % colors.get(node.get("state"), "white")
            )
        elif node["kind"] == "evidence":
            attributes.append('shape="note"')
        elif node["kind"] == "profile":
            attributes.append('shape="oval"')
        else:
            attributes.append('shape="ellipse"')
        lines.append(
            '  "%s" [%s];' % (_dot_escape(node["id"]), ", ".join(attributes))
        )
    for edge in document["graph"]["edges"]:
        lines.append(
            '  "%s" -> "%s" [label="%s"];'
            % (
                _dot_escape(edge["from"]),
                _dot_escape(edge["to"]),
                _dot_escape(edge["relation"]),
            )
        )
    lines.append("}")
    return "\n".join(lines) + "\n"
