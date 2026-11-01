#!/usr/bin/env python3
"""Recipe/receipt contract for the OCCT ``Standard_Type.cxx`` backport.

The same contract is used by two callers with different privileges:

* ``derive_standard_type_slice.py`` writes a receipt after compiling the
  reviewed object and splicing it into a private copy of the pinned archive.
* ``bootstrap.py --check`` / ``--release-check`` reads the installed archive,
  the tracked recipe and the generated receipt and proves, without network or
  writes, that the installed bytes satisfy that contract.

The receipt is *not* a signature.  Integrity still comes from tracked,
reviewable hashes: the upstream base archive pin in ``DEPENDENCIES.json``, the
recipe/source/patch hashes in the tracked recipe, and (for a qualified release)
the optional ``expectedResult`` pin recorded in the manifest after Root derives
and qualifies the real slices.  The receipt binds the actual produced bytes to
those tracked inputs and records the exact local toolchain, so a stale,
unrelated or hand-edited result cannot be presented as "prepared".

Python 3.8+, standard library only.
"""

from __future__ import annotations

import hashlib
import json
import os
import re

import occt_archive

RECEIPT_SCHEMA_VERSION = 1
RECIPE_SCHEMA_VERSION = 1
APPROACH = "single-object-surgical-reconstruction"

_REQUIRED_SLICE_FIELDS = (
    "installPath",
    "baseSize",
    "baseSha256",
    "baseMemberCount",
    "baseMemberOrderSha256",
    "baseNonTargetMembersDigestSha256",
    "baseIndexMemberSize",
    "baseIndexPayloadSize",
    "baseIndexPayloadSha256",
    "baseTargetPayloadSize",
    "baseTargetPayloadSha256",
    "arch",
    "machoPlatform",
    "minos",
    "target",
    "sdk",
)


class DerivationError(Exception):
    """Actionable recipe/receipt/archive contract failure."""


def sha256_file(path):
    return occt_archive.sha256_file(path)


def _load_json(path, label):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        raise DerivationError("%s not found: %s" % (label, path))
    except OSError as exc:
        raise DerivationError("cannot read %s %s: %s" % (label, path, exc))
    except json.JSONDecodeError as exc:
        raise DerivationError("%s is not valid JSON (%s): %s" % (label, path, exc))


def resolve_relative(root, relative_path, label):
    """Resolve a manifest/recipe-relative path inside ``root``."""
    if not isinstance(relative_path, str) or not relative_path.strip():
        raise DerivationError("%s is empty" % label)
    if os.path.isabs(relative_path) or relative_path.startswith(("/", "\\")):
        raise DerivationError("%s must be relative: %r" % (label, relative_path))
    root_abs = os.path.realpath(root)
    candidate = os.path.realpath(os.path.join(root_abs, relative_path))
    try:
        common = os.path.commonpath([root_abs, candidate])
    except ValueError:
        raise DerivationError("%s is on a different root: %r" % (label, relative_path))
    if common != root_abs:
        raise DerivationError("%s escapes the package directory: %r"
                             % (label, relative_path))
    return candidate


def _expect(mapping, key, expected_type, where):
    if not isinstance(mapping, dict):
        raise DerivationError("%s must be an object" % where)
    value = mapping.get(key)
    if isinstance(value, bool) and expected_type is int:
        raise DerivationError("%s.%s must be an integer" % (where, key))
    if not isinstance(value, expected_type):
        raise DerivationError("%s.%s has invalid type" % (where, key))
    return value


def headers_identity(package_root, recipe):
    """Return the pinned-header tree identity used by the compile step.

    Algorithm ``sha256-json-map-v1``: walk the recipe's ``build.headersPath``
    recursively, hash every regular file, then SHA-256 the compact, sorted JSON
    object ``{relative path: file SHA-256}``.  The pinned device headers tree is
    platform-independent and is also used by the simulator build.
    """
    relative = (recipe.get("build") or {}).get("headersPath")
    if not relative:
        return None
    path = resolve_relative(package_root, relative, "recipe.build.headersPath")
    if not os.path.isdir(path):
        raise DerivationError("pinned headers directory is missing: %s" % path)
    mapping = {}
    for root, directories, files in os.walk(path):
        directories.sort()
        for name in sorted(files):
            full = os.path.join(root, name)
            if not os.path.isfile(full):
                continue
            rel = os.path.relpath(full, path).replace(os.sep, "/")
            mapping[rel] = sha256_file(full)
    identity = hashlib.sha256(
        json.dumps(mapping, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return {"headersTreeSha256": identity, "headersFileCount": len(mapping)}


def _expect_hex(value, where, length=64):
    if not isinstance(value, str) or len(value) != length:
        raise DerivationError("%s must be a %d-character hex digest" % (where, length))
    lowered = value.lower()
    if any(ch not in "0123456789abcdef" for ch in lowered):
        raise DerivationError("%s contains non-hex characters" % where)
    return lowered


def _expect_int(value, where, minimum=0):
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise DerivationError("%s must be an integer >= %d" % (where, minimum))
    return value


def validate_recipe_shape(recipe, derivation_id):
    if not isinstance(recipe, dict):
        raise DerivationError("recipe must be a JSON object")
    if recipe.get("schemaVersion") != RECIPE_SCHEMA_VERSION:
        raise DerivationError(
            "unsupported recipe schemaVersion %r (expected %d)"
            % (recipe.get("schemaVersion"), RECIPE_SCHEMA_VERSION)
        )
    if recipe.get("id") != derivation_id:
        raise DerivationError(
            "recipe id %r does not match manifest derivation id %r"
            % (recipe.get("id"), derivation_id)
        )
    for key in ("occt", "member", "archive", "slices"):
        if key not in recipe:
            raise DerivationError("recipe missing %r" % key)
    occt = recipe["occt"]
    _expect_hex(_expect(occt, "commit", str, "recipe.occt"), "recipe.occt.commit", 40)
    for source_key in ("baseSource", "overlaySource", "patch"):
        item = occt.get(source_key)
        _expect(item, "path", str, "recipe.occt.%s" % source_key)
        _expect_int(_expect(item, "size", int, "recipe.occt.%s" % source_key),
                    "recipe.occt.%s.size" % source_key)
        _expect_hex(_expect(item, "sha256", str, "recipe.occt.%s" % source_key),
                    "recipe.occt.%s.sha256" % source_key)
    member = recipe["member"]
    _expect(member, "name", str, "recipe.member")
    pattern = _expect(member, "publicSymbolPattern", str, "recipe.member")
    try:
        re.compile(pattern)
    except re.error as exc:
        raise DerivationError("recipe.member.publicSymbolPattern is invalid: %s" % exc)
    expected_symbols = member.get("expectedPublicSymbols")
    if expected_symbols is not None:
        if (not isinstance(expected_symbols, list) or not expected_symbols
                or not all(isinstance(value, str) and value for value in expected_symbols)):
            raise DerivationError(
                "recipe.member.expectedPublicSymbols must be a non-empty string list"
            )
        expected_hash = member.get("expectedPublicSymbolsSha256")
        if expected_hash is None:
            raise DerivationError(
                "recipe.member.expectedPublicSymbols requires expectedPublicSymbolsSha256"
            )
        _expect_hex(expected_hash, "recipe.member.expectedPublicSymbolsSha256")
        actual_hash = hashlib.sha256(
            ("\n".join(sorted(expected_symbols)) + "\n").encode()
        ).hexdigest()
        if actual_hash != expected_hash.lower():
            raise DerivationError(
                "recipe.member.expectedPublicSymbolsSha256 does not match the list"
            )
    build = recipe.get("build")
    if build is not None:
        if not isinstance(build, dict):
            raise DerivationError("recipe.build must be an object")
        headers_tree = build.get("headersTreeSha256")
        if headers_tree is not None:
            _expect_hex(headers_tree, "recipe.build.headersTreeSha256")
            _expect_int(build.get("headersFileCount"),
                        "recipe.build.headersFileCount", minimum=1)
    slices = _expect(recipe, "slices", dict, "recipe")
    if not slices:
        raise DerivationError("recipe declares no slices")
    for slice_name, slice_cfg in slices.items():
        where = "recipe.slices.%s" % slice_name
        _expect(slice_cfg, "installPath", str, where)
        for field in _REQUIRED_SLICE_FIELDS:
            if field not in slice_cfg:
                raise DerivationError("%s missing %r" % (where, field))
        for field in ("baseSize", "baseMemberCount", "baseIndexMemberSize",
                      "baseIndexPayloadSize", "baseTargetPayloadSize"):
            _expect_int(slice_cfg.get(field), "%s.%s" % (where, field))
        for field in ("baseSha256", "baseMemberOrderSha256",
                      "baseNonTargetMembersDigestSha256",
                      "baseIndexPayloadSha256", "baseTargetPayloadSha256"):
            _expect_hex(slice_cfg.get(field), "%s.%s" % (where, field))
        for field in ("arch", "machoPlatform", "minos", "target", "sdk"):
            if not isinstance(slice_cfg.get(field), str) or not slice_cfg[field]:
                raise DerivationError("%s.%s must be a non-empty string" % (where, field))
    qualified = recipe.get("qualifiedToolchain")
    if qualified is not None:
        if not isinstance(qualified, dict):
            raise DerivationError("recipe.qualifiedToolchain must be an object")
        for field in ("xcodeVersion", "xcodeBuild", "sdkVersion"):
            if field in qualified and not isinstance(qualified[field], str):
                raise DerivationError("recipe.qualifiedToolchain.%s must be a string"
                                      % field)
    return recipe


def load_recipe(recipe_path, expected_sha256, derivation_id):
    actual = sha256_file(recipe_path)
    if actual != expected_sha256.lower():
        raise DerivationError(
            "recipe hash mismatch: manifest pins %s, file is %s"
            % (expected_sha256, actual)
        )
    recipe = _load_json(recipe_path, "derivation recipe")
    validate_recipe_shape(recipe, derivation_id)
    recipe["_path"] = recipe_path
    recipe["_sha256"] = actual
    return recipe


def slice_config(recipe, install_path=None, slice_name=None):
    slices = recipe["slices"]
    if slice_name is not None:
        if slice_name not in slices:
            raise DerivationError("recipe has no slice %r" % slice_name)
        return slice_name, slices[slice_name]
    matches = [(name, cfg) for name, cfg in slices.items()
               if cfg.get("installPath") == install_path]
    if len(matches) != 1:
        raise DerivationError(
            "recipe does not declare exactly one slice for installPath %r" % install_path
        )
    return matches[0]


def expected_result(descriptor):
    """Return the optional tracked result pin {size, sha256} or None."""
    value = descriptor.get("expectedResult")
    if value is None:
        return None
    if not isinstance(value, dict):
        raise DerivationError("manifest derivation.expectedResult must be an object")
    size = _expect_int(value.get("size"), "derivation.expectedResult.size")
    sha = _expect_hex(value.get("sha256"), "derivation.expectedResult.sha256")
    return {"size": size, "sha256": sha}


def toolchain_matches_qualified(receipt, recipe):
    """True when the receipt records the recipe's qualified Xcode/SDK."""
    qualified = recipe.get("qualifiedToolchain")
    if not qualified:
        return False, ["recipe declares no qualifiedToolchain"]
    toolchain = receipt.get("toolchain") or {}
    problems = []
    for field in ("xcodeVersion", "xcodeBuild", "sdkVersion"):
        expected = qualified.get(field)
        if expected is None:
            continue
        actual = toolchain.get(field)
        if actual != expected:
            problems.append("%s is %r, qualified value is %r"
                            % (field, actual, expected))
    return (not problems), problems


def toolchain_summary(receipt):
    toolchain = receipt.get("toolchain") or {}
    return "Xcode %s (%s), SDK %s, %s" % (
        toolchain.get("xcodeVersion", "?"),
        toolchain.get("xcodeBuild", "?"),
        toolchain.get("sdkVersion", "?"),
        toolchain.get("target", "?"),
    )


def validate_receipt(recipe, artifact, receipt, installed_size, installed_sha256):
    """Validate receipt structure and its binding to the manifest artifact.

    ``artifact`` is the ``DEPENDENCIES.json`` artifact entry (install path,
    base size/SHA-256, derivation descriptor).  ``installed_size`` and
    ``installed_sha256`` are the actual bytes being validated.  Archive
    member-level checks are performed separately by
    :func:`verify_installed_archive`.
    """
    problems = []

    def check(condition, message):
        if not condition:
            problems.append(message)

    if not isinstance(receipt, dict):
        return ["receipt is not a JSON object"], False
    check(receipt.get("schemaVersion") == RECEIPT_SCHEMA_VERSION,
          "unsupported receipt schemaVersion %r" % receipt.get("schemaVersion"))
    check(receipt.get("approach") == APPROACH,
          "receipt approach %r is not %r" % (receipt.get("approach"), APPROACH))
    check(receipt.get("derivationId") == recipe["id"],
          "receipt derivationId does not match recipe")
    check(receipt.get("recipeSha256") == recipe["_sha256"],
          "receipt recipeSha256 does not match the tracked recipe")
    if receipt.get("testBypass"):
        problems.append("receipt declares a test bypass; it cannot verify a release")
    receipt_artifact = receipt.get("artifact") or {}
    check(receipt_artifact.get("installPath") == artifact.get("installPath"),
          "receipt artifact.installPath does not match the manifest")
    check(receipt_artifact.get("baseSize") == artifact.get("size"),
          "receipt base size does not match the manifest pin")
    check(receipt_artifact.get("baseSha256") == artifact.get("sha256"),
          "receipt base SHA-256 does not match the manifest pin")
    check(receipt_artifact.get("resultSize") == installed_size,
          "installed size %s does not match receipt result size %s"
          % (installed_size, receipt_artifact.get("resultSize")))
    check(receipt_artifact.get("resultSha256") == installed_sha256,
          "installed SHA-256 does not match receipt result SHA-256")
    source = receipt.get("source") or {}
    occt = recipe["occt"]
    check(source.get("commit") == occt["commit"],
          "receipt source commit does not match recipe")
    for receipt_key, recipe_key in (("baseSourceSha256", "baseSource"),
                                    ("overlaySourceSha256", "overlaySource"),
                                    ("patchSha256", "patch")):
        check(source.get(receipt_key) == occt[recipe_key]["sha256"],
              "receipt %s does not match recipe" % receipt_key)
    member = receipt.get("member") or {}
    check(member.get("name") == recipe["member"]["name"],
          "receipt member name does not match recipe")
    slice_name, slice_cfg = slice_config(recipe,
                                         install_path=artifact.get("installPath"))
    check(member.get("basePayloadSize") == slice_cfg["baseTargetPayloadSize"],
          "receipt base member size does not match recipe")
    check(member.get("basePayloadSha256") == slice_cfg["baseTargetPayloadSha256"],
          "receipt base member SHA-256 does not match recipe")
    for field in ("derivedPayloadSize", "derivedPayloadSha256"):
        if field not in member:
            problems.append("receipt member missing %r" % field)
    defined = set(member.get("definedSymbols") or [])
    undefined = set(member.get("undefinedSymbols") or [])
    expected_symbols = recipe["member"].get("expectedPublicSymbols") or []
    for symbol in expected_symbols:
        check(symbol in defined,
              "derived object does not define expected public symbol %s" % symbol)
        check(symbol not in undefined,
              "derived object leaves expected public symbol undefined: %s" % symbol)
    expected_hash = recipe["member"].get("expectedPublicSymbolsSha256")
    if expected_hash:
        check(member.get("publicSymbolSetSha256") == expected_hash,
              "receipt public symbol set does not match the recipe")
        check(member.get("basePublicSymbolSetSha256") == expected_hash,
              "receipt base public symbol set does not match the recipe")
    object_public = member.get("objectPublicSymbols")
    if isinstance(object_public, list):
        actual = hashlib.sha256(
            ("\n".join(sorted(object_public)) + "\n").encode()
        ).hexdigest()
        check(actual == member.get("publicSymbolSetSha256"),
              "receipt objectPublicSymbols does not match publicSymbolSetSha256")
    archive = receipt.get("archive") or {}
    summary_expectations = (
        ("memberCount", slice_cfg["baseMemberCount"]),
        ("memberOrderSha256", slice_cfg["baseMemberOrderSha256"]),
        ("nonTargetMembersDigestSha256", slice_cfg["baseNonTargetMembersDigestSha256"]),
    )
    for field, expected in summary_expectations:
        check(archive.get(field) == expected,
              "receipt archive.%s does not match the pinned base archive" % field)
    for field in ("indexMemberName", "indexPayloadSize", "indexPayloadSha256",
                  "targetPayloadSize", "targetPayloadSha256", "size", "sha256"):
        if field not in archive:
            problems.append("receipt archive missing %r" % field)
    check(archive.get("size") == installed_size,
          "receipt archive size does not match installed bytes")
    check(archive.get("sha256") == installed_sha256,
          "receipt archive SHA-256 does not match installed bytes")
    check(archive.get("targetPayloadSize") == member.get("derivedPayloadSize"),
          "receipt archive target size does not match the derived member")
    check(archive.get("targetPayloadSha256") == member.get("derivedPayloadSha256"),
          "receipt archive target SHA-256 does not match the derived member")
    toolchain = receipt.get("toolchain") or {}
    for field in ("xcodeVersion", "xcodeBuild", "sdkVersion", "clangVersion",
                  "target", "sdkName"):
        if not isinstance(toolchain.get(field), str) or not toolchain[field]:
            problems.append("receipt toolchain.%s is missing" % field)
    flags = toolchain.get("compileFlags")
    if not isinstance(flags, list) or not all(isinstance(flag, str) for flag in flags):
        problems.append("receipt toolchain.compileFlags is invalid")
    build = recipe.get("build") or {}
    expected_headers_tree = build.get("headersTreeSha256")
    if expected_headers_tree:
        check(toolchain.get("headersTreeSha256") == expected_headers_tree,
              "receipt header-tree identity does not match the recipe")
        check(toolchain.get("headersFileCount") == build.get("headersFileCount"),
              "receipt header file count does not match the recipe")
    if not isinstance(receipt.get("producedAt"), str) or not receipt["producedAt"]:
        problems.append("receipt producedAt is missing")
    invariants = receipt.get("invariants") or {}
    for field in ("memberOrderIdentical", "nonTargetMembersIdenticalToBase",
                  "targetOnlyMemberChanged", "indexRebuiltByRanlib"):
        check(invariants.get(field) is True,
              "receipt invariant %s is not true" % field)
    qualified, _ = toolchain_matches_qualified(receipt, recipe)
    return problems, qualified


def verify_installed_archive(archive_path, recipe, slice_cfg, receipt):
    """Prove member identity/order/index against the tracked recipe + receipt.

    Returns ``(problems, summary)``.  This is read-only and performs no
    temporary writes; ``bootstrap.py --check`` calls it directly.
    """
    problems = []
    try:
        members = occt_archive.read_archive(archive_path)
        summary = occt_archive.archive_summary(members, recipe["member"]["name"])
        index_stats = occt_archive.parse_symbol_index(members)
    except occt_archive.ArchiveError as exc:
        return ["archive verification failed: %s" % exc], None

    def check(condition, message):
        if not condition:
            problems.append(message)

    check(summary["memberCount"] == slice_cfg["baseMemberCount"],
          "member count %d does not match pinned base %d"
          % (summary["memberCount"], slice_cfg["baseMemberCount"]))
    check(summary["memberOrderSha256"] == slice_cfg["baseMemberOrderSha256"],
          "member order does not match the pinned base archive")
    check(summary["nonTargetMembersDigestSha256"] ==
          slice_cfg["baseNonTargetMembersDigestSha256"],
          "a non-target object member differs from the pinned base archive")
    archive = receipt.get("archive") or {}
    member = receipt.get("member") or {}
    check(summary["targetPayloadSize"] == member.get("derivedPayloadSize"),
          "target object size does not match receipt")
    check(summary["targetPayloadSha256"] == member.get("derivedPayloadSha256"),
          "target object SHA-256 does not match receipt")
    check(summary["targetPayloadSize"] == archive.get("targetPayloadSize"),
          "target object size does not match receipt archive")
    check(summary["targetPayloadSha256"] == archive.get("targetPayloadSha256"),
          "target object SHA-256 does not match receipt archive")
    check(summary["indexMemberName"] == archive.get("indexMemberName"),
          "symbol index member name does not match receipt")
    check(summary["indexPayloadSize"] == archive.get("indexPayloadSize"),
          "symbol index size does not match receipt")
    check(summary["indexPayloadSha256"] == archive.get("indexPayloadSha256"),
          "symbol index SHA-256 does not match receipt")
    check(archive.get("memberCount") == summary["memberCount"],
          "receipt member count does not match installed archive")
    check(archive.get("memberOrderSha256") == summary["memberOrderSha256"],
          "receipt member order does not match installed archive")
    check(archive.get("nonTargetMembersDigestSha256") ==
          summary["nonTargetMembersDigestSha256"],
          "receipt non-target member digest does not match installed archive")
    summary = dict(summary)
    summary["symbolIndex"] = index_stats
    return problems, summary


def build_receipt(recipe, slice_name, installed_size,
                  installed_sha256, member_result, archive_result, toolchain,
                  source_hashes, produced_at, producer_sha256):
    """Assemble a receipt dictionary (used only by the derivation producer)."""
    slice_cfg = recipe["slices"][slice_name]
    return {
        "schemaVersion": RECEIPT_SCHEMA_VERSION,
        "derivationId": recipe["id"],
        "recipeSha256": recipe["_sha256"],
        "approach": APPROACH,
        "artifact": {
            "installPath": slice_cfg["installPath"],
            "baseSize": slice_cfg["baseSize"],
            "baseSha256": slice_cfg["baseSha256"],
            "resultSize": installed_size,
            "resultSha256": installed_sha256,
        },
        "source": {
            "commit": recipe["occt"]["commit"],
            "baseSourceSha256": source_hashes["baseSource"],
            "overlaySourceSha256": source_hashes["overlaySource"],
            "patchSha256": source_hashes["patch"],
        },
        "member": {
            "name": recipe["member"]["name"],
            "basePayloadSize": slice_cfg["baseTargetPayloadSize"],
            "basePayloadSha256": slice_cfg["baseTargetPayloadSha256"],
            "derivedPayloadSize": member_result["size"],
            "derivedPayloadSha256": member_result["sha256"],
            "definedSymbols": member_result["definedSymbols"],
            "undefinedSymbols": member_result["undefinedSymbols"],
            "basePublicSymbols": member_result["basePublicSymbols"],
            "objectPublicSymbols": member_result["objectPublicSymbols"],
            "basePublicSymbolSetSha256": member_result["basePublicSymbolSetSha256"],
            "publicSymbolSetSha256": member_result["publicSymbolSetSha256"],
        },
        "archive": {
            "memberCount": archive_result["memberCount"],
            "memberOrderSha256": archive_result["memberOrderSha256"],
            "nonTargetMembersDigestSha256": archive_result["nonTargetMembersDigestSha256"],
            "indexMemberName": archive_result["indexMemberName"],
            "targetPayloadSize": archive_result["targetPayloadSize"],
            "targetPayloadSha256": archive_result["targetPayloadSha256"],
            "indexPayloadSize": archive_result["indexPayloadSize"],
            "indexPayloadSha256": archive_result["indexPayloadSha256"],
            "size": installed_size,
            "sha256": installed_sha256,
        },
        "toolchain": toolchain,
        "invariants": {
            "memberOrderIdentical": True,
            "nonTargetMembersIdenticalToBase": True,
            "targetOnlyMemberChanged": True,
            "indexRebuiltByRanlib": True,
        },
        "producedAt": produced_at,
        "producer": {
            "path": "relink/derivations/derive_standard_type_slice.py",
            "sha256": producer_sha256,
        },
        "limitations": list(recipe.get("limitations") or []),
    }


def describe_problems(problems, limit=4):
    if not problems:
        return "unknown derivation problem"
    shown = problems[:limit]
    suffix = "" if len(problems) <= limit else " (+%d more)" % (len(problems) - limit)
    return "; ".join(shown) + suffix
