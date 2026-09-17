#!/usr/bin/env python3
"""Isolated MLX dependency-profile diagnostics for the local inference host.

This tool exists so the cloud qualification workflow can verify the accepted MLX
pin pair, and can still reproduce the *historical* baseline pair, without ever
changing the dependency declarations that are committed to the product. Nothing
here builds, downloads, resolves or reaches the network; the real
``swift package resolve`` is run by the workflow, not by this script.

Profiles
--------
``current``
    The accepted production pair (``CURRENT_PINS``): mlx-swift
    ``ab924c82ead3b970caaa1c0ac11171de23f0305a`` + mlx-swift-lm
    ``d5d8b290e601ac1bf11f24635f8f811a83b98bf8``. No file is patched.

``historical-baseline``
    The frozen pre-adoption pair (``HISTORICAL_BASELINE_PINS``): mlx-swift
    ``0.31.4`` + mlx-swift-lm ``bd4b7434...``. Reproducible on demand so the
    earlier lifecycle evidence stays comparable. Never the default.

Subcommands
-----------
``apply-patch`` (writes)
    Writes the two ``historical-baseline`` declarations into a caller supplied
    ``Package.swift``. It refuses unless exactly one declaration exists per
    target URL, the two original pin states match ``CURRENT_PINS`` exactly, and
    the resulting file differs from the original in exactly those two lines. On
    any mismatch the target file is left byte-identical and a failure manifest
    is still written for recovery evidence.

``verify-lock`` (read-only unless ``--output`` is given)
    Compares a freshly resolved lock against the immutable baseline lock. For
    the ``historical-baseline`` profile the two target revisions must be exactly
    the historical values and every other pin must be identical; added, removed
    or drifted pins fail. An optional XcodeGen project permits only the omission
    of matching app-only pins from the host graph. ``--check`` prints JSON to
    stdout and is forbidden from writing any output path.

``check`` (read-only)
    Reports whether the target declarations in a ``Package.swift`` match the
    requested profile without writing anything.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys

from resolved_pins import application_pins, resolved_pins

MLX_SWIFT_URL = "https://github.com/ml-explore/mlx-swift"
MLX_SWIFT_LM_URL = "https://github.com/ml-explore/mlx-swift-lm.git"

TARGET_IDENTITIES = ("mlx-swift", "mlx-swift-lm")
_TARGET_URLS = {
    "mlx-swift": MLX_SWIFT_URL,
    "mlx-swift-lm": MLX_SWIFT_LM_URL,
}

SUPPORTED_PROFILES = ("current", "historical-baseline")

# Accepted production declarations committed in FloeAgent/Package.swift. These
# are the exact revisions qualified by cloud run 35189276226 (source 43a68eb8)
# with MLX compiled traces disabled: mlx-swift carries the upstream GPU
# error-handling fix and mlx-swift-lm keeps the existing prefill-parameter
# behavior (upstream #389/#381/#488). Changing these constants is a product
# decision.
CURRENT_PINS = {
    "mlx-swift-lm": {"revision": "d5d8b290e601ac1bf11f24635f8f811a83b98bf8"},
    "mlx-swift": {"revision": "ab924c82ead3b970caaa1c0ac11171de23f0305a"},
}

# Frozen pre-adoption pair. Kept only so the historical baseline lifecycle
# evidence (retained compiled traces) stays reproducible on demand; the cloud
# run with this pair retained ~1.3-1.6 GB per engine, so it must not be used as
# a production profile. The patch step may only move the committed current
# declarations to this exact pair, never the reverse direction.
HISTORICAL_BASELINE_PINS = {
    "mlx-swift-lm": {"revision": "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57"},
    "mlx-swift": {"exact": "0.31.4"},
}

# What a `Package.resolved` lock records for the historical baseline. A lock pin
# always carries a concrete revision (and the exact-version tag), never the
# manifest's `exact:` declaration form.
HISTORICAL_BASELINE_RESOLVED_PINS = {
    "mlx-swift-lm": {"revision": "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57"},
    "mlx-swift": {
        "revision": "dc43e62d7055353c7f99fa071a4e71d29dfddc44",
        "version": "0.31.4",
    },
}


def profile_pins(profile):
    """Return the expected target declarations for a supported profile."""
    if profile == "current":
        return CURRENT_PINS
    if profile == "historical-baseline":
        return HISTORICAL_BASELINE_PINS
    raise ValueError("unsupported dependency profile: %r" % (profile,))


class PatchError(ValueError):
    """The historical baseline patch could not be applied without ambiguity."""


def normalize_url(url):
    return url.rstrip("/").removesuffix(".git").lower()


def _declaration_spans(text):
    """Yield (start, end) spans of top-level ``.package(...)`` calls."""
    spans = []
    token = ".package("
    index = 0
    while True:
        start = text.find(token, index)
        if start == -1:
            return spans
        position = start + len(token) - 1  # at the opening parenthesis
        depth = 0
        in_string = False
        while position < len(text):
            character = text[position]
            if in_string:
                if character == "\\":
                    position += 2
                    continue
                if character == '"':
                    in_string = False
            elif character == '"':
                in_string = True
            elif character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
                if depth == 0:
                    break
            position += 1
        spans.append((start, position + 1))
        index = position + 1


def _string_value(block, key):
    match = re.search(r'\b%s\s*:\s*"([^"]*)"' % key, block)
    return match.group(1) if match else None


def package_declarations(text):
    declarations = []
    for start, end in _declaration_spans(text):
        block = text[start:end]
        declarations.append({
            "start": start,
            "end": end,
            "block": block,
            "url": _string_value(block, "url"),
        })
    return declarations


def pin_state(block):
    state = {}
    for key in ("revision", "exact", "branch"):
        value = _string_value(block, key)
        if value is not None:
            state[key] = value
    return state


def find_target_declarations(text):
    found = {}
    for declaration in package_declarations(text):
        if not declaration["url"]:
            continue
        normalized = normalize_url(declaration["url"])
        for identity, url in _TARGET_URLS.items():
            if normalized == normalize_url(url):
                found.setdefault(identity, []).append(declaration)
    return found


def line_changes(before, after):
    """Return (removed_lines, added_lines) for a unified diff with no context."""
    removed = []
    added = []
    for line in difflib.unified_diff(before.splitlines(), after.splitlines(), lineterm="", n=0):
        if line.startswith(("---", "+++", "@@")):
            continue
        if line.startswith("-"):
            removed.append(line[1:].strip())
        elif line.startswith("+"):
            added.append(line[1:].strip())
    return removed, added


def plan_historical_baseline_patch(text):
    """Return ``(patched_text, changes)`` for the historical baseline or raise.

    Only the committed ``CURRENT_PINS`` declarations may be moved to
    ``HISTORICAL_BASELINE_PINS``. The original text is never mutated and no
    file is touched here.
    """
    found = find_target_declarations(text)
    replacements = []
    expected_removed = []
    expected_added = []
    changes = []
    for identity in TARGET_IDENTITIES:
        declarations = found.get(identity, [])
        if len(declarations) != 1:
            raise PatchError(
                "expected exactly one %s declaration, found %d" % (identity, len(declarations)))
        declaration = declarations[0]
        state = pin_state(declaration["block"])
        if state != CURRENT_PINS[identity]:
            raise PatchError(
                "%s declaration state %r does not match accepted current %r"
                % (identity, state, CURRENT_PINS[identity]))
        baseline = HISTORICAL_BASELINE_PINS[identity]
        if len(baseline) != 1:
            raise PatchError("historical baseline pin for %s must be a single key" % identity)
        old_key = next(iter(state))
        old_token = '%s: "%s"' % (old_key, state[old_key])
        new_key, new_value = next(iter(baseline.items()))
        new_token = '%s: "%s"' % (new_key, new_value)
        if declaration["block"].count(old_token) != 1:
            raise PatchError("%s current token %r is not unique" % (identity, old_token))
        new_block = declaration["block"].replace(old_token, new_token, 1)
        replacements.append((declaration["start"], declaration["end"], new_block))
        expected_removed.append(old_token)
        expected_added.append(new_token)
        changes.append({"identity": identity, "from": old_token, "to": new_token})
    patched = text
    for start, end, new_block in sorted(replacements, reverse=True):
        patched = patched[:start] + new_block + patched[end:]
    removed, added = line_changes(text, patched)
    if len(removed) != 2 or len(added) != 2:
        raise PatchError(
            "historical baseline patch must change exactly two lines, got removed=%r added=%r"
            % (removed, added))
    if sorted(removed) != sorted(expected_removed) or sorted(added) != sorted(expected_added):
        raise PatchError(
            "historical baseline patch changed unexpected lines: removed=%r added=%r"
            % (removed, added))
    return patched, changes


def verify_lock(profile, baseline_document, resolved_document, app_only=()):
    """Compare a resolved lock to the baseline; return a report.

    Never writes. The report's ``ok`` flag is the pass/fail signal.
    """
    if profile not in SUPPORTED_PROFILES:
        raise ValueError("unsupported dependency profile: %r" % (profile,))
    baseline = {pin["identity"]: pin for pin in resolved_pins(baseline_document)}
    resolved = {pin["identity"]: pin for pin in resolved_pins(resolved_document)}
    expected = {identity: dict(pin) for identity, pin in baseline.items()}
    if profile == "historical-baseline":
        for identity in TARGET_IDENTITIES:
            if identity not in expected:
                raise ValueError("baseline lock is missing target dependency %s" % identity)
            expected[identity] = {
                "identity": identity,
                "location": expected[identity]["location"],
                "state": dict(HISTORICAL_BASELINE_RESOLVED_PINS[identity]),
            }
    # App-only packages (currently WhisperKit) occur in the shared committed
    # lock, but SwiftPM may omit them from this host graph. Authorize only the
    # exact immutable declarations in project.yml, never arbitrary removals.
    app = {pin["identity"]: pin for pin in app_only}
    for identity, pin in app.items():
        if baseline.get(identity) != pin or identity in TARGET_IDENTITIES:
            raise ValueError("application-only pin differs from baseline: %s" % identity)
    added = sorted(set(resolved) - set(expected))
    omitted_app = sorted((set(expected) - set(resolved)) & set(app))
    removed = sorted((set(expected) - set(resolved)) - set(app))
    drifted = []
    equivalent_source_urls = []
    for identity in sorted(set(expected) & set(resolved)):
        comparison = dict(resolved[identity])
        if identity in TARGET_IDENTITIES and comparison["location"] != expected[identity]["location"]:
            if normalize_url(comparison["location"]) == normalize_url(expected[identity]["location"]):
                equivalent_source_urls.append({"identity": identity,
                                              "original": expected[identity]["location"],
                                              "resolved": comparison["location"]})
                comparison["location"] = expected[identity]["location"]
        if expected[identity] != comparison:
            drifted.append({
                "identity": identity,
                "expected": expected[identity],
                "actual": resolved[identity],
            })
    target_state = {identity: resolved.get(identity, {}).get("state") for identity in TARGET_IDENTITIES}
    expected_target_state = {identity: expected.get(identity, {}).get("state") for identity in TARGET_IDENTITIES}
    targets_exact = all(target_state[identity] == expected_target_state[identity]
                        for identity in TARGET_IDENTITIES)
    return {
        "profile": profile,
        "ok": not added and not removed and not drifted and targets_exact,
        "added": added,
        "removed": removed,
        "omitted_application_pins": omitted_app,
        "equivalent_source_urls": equivalent_source_urls,
        "drifted": drifted,
        "targets": target_state,
        "expected_targets": expected_target_state,
    }


def check_declarations(profile, text):
    """Read-only profile check of the two target declarations."""
    expected = profile_pins(profile)
    found = find_target_declarations(text)
    report = {"profile": profile, "ok": True, "declarations": {}}
    for identity in TARGET_IDENTITIES:
        declarations = found.get(identity, [])
        state = pin_state(declarations[0]["block"]) if len(declarations) == 1 else None
        report["declarations"][identity] = {
            "count": len(declarations),
            "state": state,
            "expected": expected[identity],
        }
        if len(declarations) != 1 or state != expected[identity]:
            report["ok"] = False
    return report


def _load_json(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _write_json(path, payload):
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")


def _write_text(path, text):
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)


def command_apply_patch(args):
    if args.profile != "historical-baseline":
        error = "profile %r does not patch pinned declarations" % (args.profile,)
        _write_json(args.manifest, {"profile": args.profile, "applied": False, "error": error})
        print("FAIL: %s" % error, file=sys.stderr)
        return 1
    with open(args.package_swift, "r", encoding="utf-8") as handle:
        original = handle.read()
    try:
        patched, changes = plan_historical_baseline_patch(original)
    except PatchError as error:
        _write_json(args.manifest, {"profile": args.profile, "applied": False, "error": str(error)})
        print("FAIL: %s" % error, file=sys.stderr)
        return 1
    if patched == original:
        error = "historical baseline patch produced no change"
        _write_json(args.manifest, {"profile": args.profile, "applied": False, "error": error})
        print("FAIL: %s" % error, file=sys.stderr)
        return 1
    # Only after every guard has passed do we touch the target file.
    _write_text(args.package_swift, patched)
    diff = "".join(difflib.unified_diff(
        original.splitlines(keepends=True),
        patched.splitlines(keepends=True),
        fromfile="Package.swift:accepted-current",
        tofile="Package.swift:historical-baseline",
    ))
    _write_text(args.diff, diff)
    _write_json(args.manifest, {
        "profile": args.profile,
        "applied": True,
        "changes": changes,
        "changed_line_count": 2,
    })
    return 0


def command_verify_lock(args):
    try:
        app_only = ()
        if args.app_project:
            with open(args.app_project, "r", encoding="utf-8") as handle:
                app_only = application_pins(handle.read())
        report = verify_lock(args.profile, _load_json(args.baseline), _load_json(args.resolved), app_only)
    except (OSError, ValueError) as error:
        report = {"profile": args.profile, "ok": False, "error": str(error)}
    text = json.dumps(report, indent=2, sort_keys=True)
    if args.check:
        if args.output:
            raise SystemExit("--check is read-only and cannot be combined with --output")
        print(text)
        return 0 if report["ok"] else 1
    if args.output:
        _write_json(args.output, report)
    print(text)
    return 0 if report["ok"] else 1


def command_check(args):
    with open(args.package_swift, "r", encoding="utf-8") as handle:
        text = handle.read()
    report = check_declarations(args.profile, text)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


def build_parser():
    parser = argparse.ArgumentParser(
        description="Diagnose an isolated MLX dependency profile without touching product pins.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    apply_parser = subparsers.add_parser(
        "apply-patch", help="apply the historical baseline declarations (CI working copy only)")
    apply_parser.add_argument("--package-swift", required=True)
    apply_parser.add_argument("--profile", required=True, choices=SUPPORTED_PROFILES)
    apply_parser.add_argument("--diff", required=True)
    apply_parser.add_argument("--manifest", required=True)
    apply_parser.set_defaults(func=command_apply_patch)

    verify_parser = subparsers.add_parser(
        "verify-lock", help="verify a freshly resolved lock against the baseline lock")
    verify_parser.add_argument("--profile", required=True, choices=SUPPORTED_PROFILES)
    verify_parser.add_argument("--baseline", required=True)
    verify_parser.add_argument("--resolved", required=True)
    verify_parser.add_argument("--app-project", help="XcodeGen source for exact application-only pins")
    verify_parser.add_argument("--check", action="store_true",
                               help="read-only: print JSON to stdout and write nothing")
    verify_parser.add_argument("--output")
    verify_parser.set_defaults(func=command_verify_lock)

    check_parser = subparsers.add_parser(
        "check", help="read-only check that the target declarations match a profile")
    check_parser.add_argument("--profile", required=True, choices=SUPPORTED_PROFILES)
    check_parser.add_argument("--package-swift", required=True)
    check_parser.set_defaults(func=command_check)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
