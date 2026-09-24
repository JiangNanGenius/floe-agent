#!/usr/bin/env python3
"""Isolated MLX dependency-profile diagnostics for the local inference host.

This tool exists so the cloud qualification workflow can verify the committed
production declarations and can still materialize the *historical* baseline
pair, without ever changing the dependency declarations that are committed to
the product outside a CI working copy. Nothing here builds, downloads, resolves
or reaches the network; the real ``swift package resolve`` is run by the
workflow, not by this script.

Profiles
--------
``current``
    The accepted production declarations. ``mlx-swift`` stays a remote
    exact-revision dependency (``CURRENT_REMOTE_PINS``). ``mlx-swift-lm`` is the
    reviewed in-repo package ``FloeAgent/ThirdParty/MLXSwiftLM``
    (``CURRENT_LOCAL_PACKAGE``): the upstream revision
    ``d5d8b290e601ac1bf11f24635f8f811a83b98bf8`` plus the Floe gated-delta
    prefill patch. ``check`` audits that declaration and directory read-only;
    no file is written.

``historical-baseline``
    The frozen pre-adoption pair (``HISTORICAL_BASELINE_PINS``): mlx-swift
    ``0.31.4`` + mlx-swift-lm ``bd4b7434...`` as two *remote* declarations.
    Materialized on demand so the earlier lifecycle evidence stays comparable.
    Never the default, and only ever written inside a caller-supplied working
    copy by ``apply-patch``.

Subcommands
-----------
``apply-patch`` (writes)
    Rewrites the two ``current`` declarations into the two
    ``historical-baseline`` remote declarations in a caller supplied
    ``Package.swift``. It refuses unless exactly one accepted ``current``
    declaration exists per target, the resulting diff changes only those two
    declaration regions, and the changed and added lines are exactly the
    expected tokens. On any mismatch the target file is left byte-identical and
    a failure manifest is still written for recovery evidence. The cloud
    workflow invokes it only in the ephemeral runner checkout.

``verify-lock`` (read-only unless ``--output`` is given)
    Compares a freshly resolved lock against the committed baseline lock. For
    ``current`` the ``mlx-swift`` revision must be exact and the local
    ``mlx-swift-lm`` package is allowed to have no remote pin (SwiftPM does not
    lock local packages); every other addition, removal or drift fails. For
    ``historical-baseline`` the two target revisions must be exactly the
    historical values and every other pin must be identical. An optional
    XcodeGen project permits only the omission of matching app-only pins from
    the host graph. ``--check`` prints JSON to stdout and is forbidden from
    writing any output path.

``check`` (read-only)
    Reports whether the target declarations in a ``Package.swift`` match the
    requested profile without writing anything. For ``current`` it also audits
    the vendored package directory (manifest name, provenance revision, patch
    file) that the declaration points at.
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

LOCAL_IDENTITY = "mlx-swift-lm"
TARGET_IDENTITIES = ("mlx-swift", LOCAL_IDENTITY)
_TARGET_URLS = {
    "mlx-swift": MLX_SWIFT_URL,
    LOCAL_IDENTITY: MLX_SWIFT_LM_URL,
}

SUPPORTED_PROFILES = ("current", "historical-baseline")

# Accepted production declarations committed in FloeAgent/Package.swift. The
# mlx-swift revision is the exact upstream GPU error-handling pin qualified by
# cloud run 35189276226 (source 43a68eb8). Changing these constants is a
# product decision.
CURRENT_REMOTE_PINS = {
    "mlx-swift": {"revision": "ab924c82ead3b970caaa1c0ac11171de23f0305a"},
}

# The reviewed local package the committed manifest points at with
# `.package(name: "mlx-swift-lm", path: "ThirdParty/MLXSwiftLM")`. The path is
# relative to FloeAgent/Package.swift; ``revision`` is the upstream revision
# recorded in the vendored FLOE_VENDOR.md provenance notes and the ``patch`` is
# the Floe gated-delta prefill hotfix applied to that copy.
CURRENT_LOCAL_PACKAGE = {
    "identity": LOCAL_IDENTITY,
    "name": "mlx-swift-lm",
    "path": "ThirdParty/MLXSwiftLM",
    "revision": "d5d8b290e601ac1bf11f24635f8f811a83b98bf8",
    "provenance_file": "FLOE_VENDOR.md",
    "patch": "patches/0001-gdn-prefill-t1-ops-route.patch",
}

# Frozen pre-adoption pair. Kept only so the historical baseline lifecycle
# evidence (retained compiled traces) stays reproducible on demand; the cloud
# run with this pair retained ~1.3-1.6 GB per engine, so it must not be used as
# a production profile. The patch step may only move the committed current
# declarations to this exact pair, never the reverse direction.
HISTORICAL_BASELINE_PINS = {
    LOCAL_IDENTITY: {"revision": "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57"},
    "mlx-swift": {"exact": "0.31.4"},
}

# What a `Package.resolved` lock records for the historical baseline. A lock pin
# always carries a concrete revision (and the exact-version tag), never the
# manifest's `exact:` declaration form.
HISTORICAL_BASELINE_RESOLVED_PINS = {
    LOCAL_IDENTITY: {"revision": "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57"},
    "mlx-swift": {
        "revision": "dc43e62d7055353c7f99fa071a4e71d29dfddc44",
        "version": "0.31.4",
    },
}


def profile_targets(profile):
    """Return the expected target declarations for a supported profile."""
    if profile == "current":
        return {
            "mlx-swift": {
                "kind": "remote",
                "state": dict(CURRENT_REMOTE_PINS["mlx-swift"]),
            },
            LOCAL_IDENTITY: {
                "kind": "local",
                "name": CURRENT_LOCAL_PACKAGE["name"],
                "path": CURRENT_LOCAL_PACKAGE["path"],
            },
        }
    if profile == "historical-baseline":
        return {
            identity: {"kind": "remote", "state": dict(state)}
            for identity, state in HISTORICAL_BASELINE_PINS.items()
        }
    raise ValueError("unsupported dependency profile: %r" % (profile,))


class PatchError(ValueError):
    """The historical baseline patch could not be applied without ambiguity."""


def normalize_url(url):
    return url.rstrip("/").removesuffix(".git").lower()


def _normalize_path(value):
    return os.path.normpath(value.replace("\\", "/")).replace(os.sep, "/")


def _local_path_matches(declared, package_dir=None):
    """True when a `.package(path:)` declaration points at the vendored copy.

    With ``package_dir`` both paths are resolved against it; without it the
    normalized relative paths are compared. Never touches the filesystem.
    """
    expected = CURRENT_LOCAL_PACKAGE["path"]
    if package_dir:
        base = os.path.abspath(package_dir)
        return (os.path.normpath(os.path.join(base, declared))
                == os.path.normpath(os.path.join(base, expected)))
    return _normalize_path(declared) == _normalize_path(expected)


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
            "path": _string_value(block, "path"),
        })
    return declarations


def pin_state(block):
    state = {}
    for key in ("revision", "exact", "branch"):
        value = _string_value(block, key)
        if value is not None:
            state[key] = value
    return state


def declaration_kind(block):
    has_url = _string_value(block, "url") is not None
    has_path = _string_value(block, "path") is not None
    if has_url and has_path:
        return "mixed"
    if has_url:
        return "remote"
    if has_path:
        return "local"
    return "unknown"


def local_declaration_state(block):
    return {
        "name": _string_value(block, "name"),
        "path": _string_value(block, "path"),
    }


def find_target_declarations(text, package_dir=None):
    """Locate the two target declarations by URL or vendored path.

    Remote declarations match the accepted URLs. A `.package(path:)`
    declaration matches only when it resolves to the reviewed vendored
    directory.
    """
    found = {}
    for declaration in package_declarations(text):
        url = declaration["url"]
        path = declaration["path"]
        if url:
            normalized = normalize_url(url)
            for identity, target_url in _TARGET_URLS.items():
                if normalized == normalize_url(target_url):
                    found.setdefault(identity, []).append(declaration)
                    break
        elif path and _local_path_matches(path, package_dir):
            found.setdefault(LOCAL_IDENTITY, []).append(declaration)
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


def _region_bounds(text, start, end):
    """Full-line bounds of a declaration span."""
    line_start = text.rfind("\n", 0, start) + 1
    line_end = text.find("\n", end)
    if line_end == -1:
        line_end = len(text)
    return line_start, line_end


def plan_historical_baseline_patch(text, package_dir=None):
    """Return ``(patched_text, changes)`` for the historical baseline or raise.

    Only the committed ``current`` declarations may be moved to
    ``HISTORICAL_BASELINE_PINS``: the remote mlx-swift revision becomes the
    frozen exact version and the local mlx-swift-lm path declaration becomes
    the frozen remote revision declaration. The original text is never mutated
    and no file is touched here.
    """
    found = find_target_declarations(text, package_dir)
    replacements = []
    changes = []
    for identity in TARGET_IDENTITIES:
        declarations = found.get(identity, [])
        if len(declarations) != 1:
            raise PatchError(
                "expected exactly one %s declaration, found %d" % (identity, len(declarations)))
        declaration = declarations[0]
        block = declaration["block"]
        kind = declaration_kind(block)
        baseline = HISTORICAL_BASELINE_PINS[identity]
        if len(baseline) != 1:
            raise PatchError("historical baseline pin for %s must be a single key" % identity)
        new_key, new_value = next(iter(baseline.items()))
        if identity == LOCAL_IDENTITY:
            if kind != "local":
                raise PatchError(
                    "%s must be the committed local path declaration, found %s" % (identity, kind))
            actual = local_declaration_state(block)
            expected = {
                "name": CURRENT_LOCAL_PACKAGE["name"],
                "path": CURRENT_LOCAL_PACKAGE["path"],
            }
            if actual != expected:
                raise PatchError(
                    "%s local declaration %r does not match accepted %r"
                    % (identity, actual, expected))
            new_block = '.package(url: "%s", %s: "%s")' % (MLX_SWIFT_LM_URL, new_key, new_value)
            old_text = block
        else:
            if kind != "remote":
                raise PatchError(
                    "%s must be the committed remote declaration, found %s" % (identity, kind))
            state = pin_state(block)
            expected_state = CURRENT_REMOTE_PINS[identity]
            if state != expected_state:
                raise PatchError(
                    "%s declaration state %r does not match accepted current %r"
                    % (identity, state, expected_state))
            old_key = next(iter(state))
            old_token = '%s: "%s"' % (old_key, state[old_key])
            new_token = '%s: "%s"' % (new_key, new_value)
            if block.count(old_token) != 1:
                raise PatchError("%s current token %r is not unique" % (identity, old_token))
            new_block = block.replace(old_token, new_token, 1)
            old_text = old_token
        replacements.append((declaration["start"], declaration["end"], new_block))
        changes.append({"identity": identity, "kind": kind, "from": old_text, "to": new_block})
    patched = text
    for start, end, new_block in sorted(replacements, reverse=True):
        patched = patched[:start] + new_block + patched[end:]
    if patched == text:
        raise PatchError("historical baseline patch produced no change")
    # The diff of the whole manifest must equal the union of the two
    # declaration-region diffs: nothing else may change.
    expected_removed = []
    expected_added = []
    for start, end, new_block in replacements:
        line_start, line_end = _region_bounds(text, start, end)
        old_region = text[line_start:line_end]
        new_region = old_region[:start - line_start] + new_block + old_region[end - line_start:]
        removed, added = line_changes(old_region, new_region)
        expected_removed += removed
        expected_added += added
    removed, added = line_changes(text, patched)
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
    if profile == "current":
        # The target pins are owned by this script, not by the committed lock:
        # a stale baseline must fail closed instead of defining the expectation.
        for identity, state in CURRENT_REMOTE_PINS.items():
            if identity not in expected:
                raise ValueError("baseline lock is missing target dependency %s" % identity)
            location = expected[identity]["location"]
            if normalize_url(location) != normalize_url(_TARGET_URLS[identity]):
                raise ValueError(
                    "baseline lock pins %s to an unexpected source: %s" % (identity, location))
            expected[identity] = {
                "identity": identity,
                "location": location,
                "state": dict(state),
            }
        local_identity = CURRENT_LOCAL_PACKAGE["identity"]
        local_state = {"revision": CURRENT_LOCAL_PACKAGE["revision"]}
        if local_identity in expected:
            pin = expected[local_identity]
            if (normalize_url(pin["location"]) != normalize_url(MLX_SWIFT_LM_URL)
                    or pin["state"] != local_state):
                raise ValueError(
                    "baseline lock carries a non-reviewed %s pin" % local_identity)
            expected[local_identity] = {
                "identity": local_identity,
                "location": pin["location"],
                "state": dict(local_state),
            }
    else:
        for identity in TARGET_IDENTITIES:
            location = expected.get(identity, {}).get("location") or _TARGET_URLS[identity]
            expected[identity] = {
                "identity": identity,
                "location": location,
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
    # SwiftPM does not pin a local path package. For the current profile the
    # reviewed mlx-swift-lm pin may therefore be absent from a fresh lock; any
    # other removal still fails.
    omitted_local = []
    if profile == "current":
        omitted_local = sorted(
            (set(expected) - set(resolved)) & {CURRENT_LOCAL_PACKAGE["identity"]})
    removed = sorted((set(expected) - set(resolved)) - set(app) - set(omitted_local))
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
    targets_exact = all(
        target_state[identity] == expected_target_state[identity]
        or (target_state[identity] is None and identity in omitted_local)
        for identity in TARGET_IDENTITIES)
    return {
        "profile": profile,
        "ok": not added and not removed and not drifted and targets_exact,
        "added": added,
        "removed": removed,
        "omitted_application_pins": omitted_app,
        "omitted_local_packages": omitted_local,
        "equivalent_source_urls": equivalent_source_urls,
        "drifted": drifted,
        "targets": target_state,
        "expected_targets": expected_target_state,
    }


def audit_local_package(package_dir):
    """Read-only audit of the vendored mlx-swift-lm package.

    Verifies that the declared path exists, that its manifest declares the
    expected package name, that the provenance notes record the reviewed
    upstream revision and that the Floe patch file is present. Never writes.
    """
    root = os.path.normpath(os.path.join(os.path.abspath(package_dir), CURRENT_LOCAL_PACKAGE["path"]))
    report = {
        "path": CURRENT_LOCAL_PACKAGE["path"],
        "root": root,
        "manifest": {"path": "Package.swift", "package_name": None},
        "provenance": {"path": CURRENT_LOCAL_PACKAGE["provenance_file"], "records_revision": False},
        "patch": {"path": CURRENT_LOCAL_PACKAGE["patch"], "present": False},
        "errors": [],
    }

    manifest_path = os.path.join(root, "Package.swift")
    try:
        with open(manifest_path, "r", encoding="utf-8") as handle:
            manifest_text = handle.read()
    except OSError as error:
        report["errors"].append("cannot read vendored Package.swift: %s" % error)
    else:
        match = re.search(r'\bname\s*:\s*"([^"]+)"', manifest_text)
        name = match.group(1) if match else None
        report["manifest"]["package_name"] = name
        if name != CURRENT_LOCAL_PACKAGE["name"]:
            report["errors"].append(
                "vendored package name %r does not match %r"
                % (name, CURRENT_LOCAL_PACKAGE["name"]))

    provenance_path = os.path.join(root, CURRENT_LOCAL_PACKAGE["provenance_file"])
    try:
        with open(provenance_path, "r", encoding="utf-8") as handle:
            provenance_text = handle.read()
    except OSError as error:
        report["errors"].append("cannot read vendored provenance notes: %s" % error)
    else:
        recorded = CURRENT_LOCAL_PACKAGE["revision"] in provenance_text
        report["provenance"]["records_revision"] = recorded
        if not recorded:
            report["errors"].append(
                "provenance notes do not record revision %s" % CURRENT_LOCAL_PACKAGE["revision"])

    patch_path = os.path.join(root, CURRENT_LOCAL_PACKAGE["patch"])
    report["patch"]["present"] = os.path.isfile(patch_path)
    if not report["patch"]["present"]:
        report["errors"].append("vendored patch missing: %s" % CURRENT_LOCAL_PACKAGE["patch"])

    report["ok"] = not report["errors"]
    return report


def check_declarations(profile, text, package_dir=None):
    """Read-only profile check of the two target declarations.

    For the ``current`` profile and a known ``package_dir`` the vendored
    package directory is audited as well; a missing or mismatched vendored tree
    fails the check.
    """
    targets = profile_targets(profile)
    found = find_target_declarations(text, package_dir)
    report = {"profile": profile, "ok": True, "declarations": {}}
    for identity in TARGET_IDENTITIES:
        declarations = found.get(identity, [])
        actual = None
        if len(declarations) == 1:
            block = declarations[0]["block"]
            kind = declaration_kind(block)
            if kind == "remote":
                actual = {"kind": "remote", "state": pin_state(block)}
            elif kind == "local":
                actual = {"kind": "local", **local_declaration_state(block)}
            else:
                actual = {"kind": kind}
        expected = targets[identity]
        entry = {
            "count": len(declarations),
            "expected": expected,
            "actual": actual,
            "ok": len(declarations) == 1 and actual == expected,
        }
        report["declarations"][identity] = entry
        report["ok"] = report["ok"] and entry["ok"]
    if profile == "current" and package_dir is not None:
        audit = audit_local_package(package_dir)
        report["local_package"] = audit
        report["ok"] = report["ok"] and audit["ok"]
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
    package_dir = os.path.dirname(os.path.abspath(args.package_swift))
    try:
        patched, changes = plan_historical_baseline_patch(original, package_dir)
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
    removed, added = line_changes(original, patched)
    _write_json(args.manifest, {
        "profile": args.profile,
        "applied": True,
        "changes": changes,
        "removed_lines": removed,
        "added_lines": added,
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
    package_dir = os.path.dirname(os.path.abspath(args.package_swift))
    report = check_declarations(args.profile, text, package_dir)
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
