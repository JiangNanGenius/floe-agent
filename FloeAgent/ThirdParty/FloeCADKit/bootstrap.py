#!/usr/bin/env python3
"""
bootstrap.py - deterministic, content-addressed installer for FloeCADKit's
pinned native OCCT static slices.

Why this exists
---------------
The two OCCT .a slices are ~149 MB / ~147 MB and exceed the ordinary Git
block-push limit, so they are not meant to be committed as Git blobs. Headers
and the xcframework Info.plist remain Git-tracked. This script fetches the
*exact* objects recorded in DEPENDENCIES.json from the pinned upstream Git-LFS
repository and installs them only after verifying size and SHA-256.

Safety guarantees
-----------------
* The Git-tracked working tree is never partially overwritten: every download
  lands in a temporary sibling file and is atomically renamed into place only
  after the full content verifies. A partial or wrong-hash download is deleted
  and the pre-existing file is left byte-for-byte untouched.
* A legacy artifact whose size and SHA-256 match its manifest is kept. A
  derivation-bearing artifact is kept only with its valid derivation receipt;
  the base pin alone still needs preparation.
* Deliberate local rebuild/replacement is an explicit opt-in
  (`FLOECAD_LOCAL_RELINK=1` or `--local-relink`): existing bytes that differ
  from the pin are then never overwritten and are reported as `LOCAL`. Without
  the opt-in a legacy artifact is restored to its pin; a derivation-bearing
  slice is rebuilt from the pinned base and verified recipe instead.
* installPath entries are confined to the package directory; absolute paths
  and ".." escapes are refused.
* `--check` is strictly read-only: it performs no network access and no
  writes, and exits non-zero if any artifact is absent or invalid. With
  `--local-relink` a present-but-unpinned slice is reported `LOCAL` (exit 0).
* Artifacts may declare a required source derivation (currently the OCCT
  `Standard_Type` lifetime backport).  The schema is bumped to 2 so older
  bootstrap revisions refuse it instead of replacing a corrected slice with
  the known-crashing pinned base.  A derived slice is accepted only with a
  valid receipt bound to the pinned base, the tracked recipe/source/patch,
  the declared toolchain and the actual archive member set.  The pinned base
  alone is reported `UNPREPARED` and fails; a stale receipt fails `STALE`.
  `--release-check` is the strict read-only release gate: it ignores the
  local-relink opt-in and additionally requires the recipe's qualified
  Xcode/SDK and a tracked `expectedResult` for each derived slice.
* All network calls use explicit connect/read timeouts and an overall deadline.
  The Git-LFS batch response is size-bounded. Redirects are followed only
  under the same URL policy: an HTTPS request never downgrades to plain HTTP.
* Remote error text is redacted (URL query strings and token-like parameters
  removed, length-capped) so short-lived pre-signed download URLs cannot leak
  into logs or exception messages.

Run `python3 bootstrap.py --help` for usage. Exit code 0 means every required
artifact is present (and verified, unless the local-relink opt-in is set).
Standard library only (Python 3.8+).
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

# ---- bounded-network defaults (override with env for tests / slow links) ----
CONNECT_TIMEOUT = float(os.environ.get("FLOECAD_CONNECT_TIMEOUT", "20"))  # seconds
READ_TIMEOUT = float(os.environ.get("FLOECAD_READ_TIMEOUT", "60"))        # seconds
DEADLINE = float(os.environ.get("FLOECAD_DEADLINE", "1800"))             # seconds total
MAX_RETRIES = int(os.environ.get("FLOECAD_MAX_RETRIES", "3"))
READ_CHUNK = 1024 * 1024  # 1 MiB

# The LFS batch response only carries oid/size/actions metadata; anything past
# this bound is a misbehaving or hostile endpoint and is refused unread.
MAX_BATCH_RESPONSE_BYTES = 4 * 1024 * 1024
# Remote error strings are capped and redacted before they reach logs.
MAX_ERROR_TEXT = 240

MANIFEST_NAME = "DEPENDENCIES.json"
# Schema 1 is the original legacy shape (exact pinned bytes only). Schema 2
# adds optional per-artifact derivations. Older bootstrap.py revisions refuse
# schema 2 rather than silently replacing a derived slice with the pinned base.
SUPPORTED_SCHEMA_VERSIONS = (1, 2)
CURRENT_SCHEMA_VERSION = 2
_REQUIRED_SOURCE_KIND = "git-lfs"
# Opt-in flag/env for a deliberate local rebuild/replacement of the slices.
ENV_LOCAL_RELINK = "FLOECAD_LOCAL_RELINK"
_TRUTHY = ("1", "true", "yes", "on")


class BootstrapError(Exception):
    """Base class for actionable bootstrap failures."""


class ManifestError(BootstrapError):
    pass


class PathEscapeError(BootstrapError):
    pass


class IntegrityError(BootstrapError):
    pass


class UnsupportedSourceError(BootstrapError):
    pass


class FetchError(BootstrapError):
    pass


class DerivationError(BootstrapError):
    pass


# --------------------------------------------------------------------------- #
# Path safety
# --------------------------------------------------------------------------- #
def package_root() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def safe_install_path(root: str, rel_path: str) -> str:
    """Resolve rel_path under root, refusing absolute paths and '..' escapes."""
    if not rel_path or not rel_path.strip():
        raise PathEscapeError("empty installPath in manifest")
    if os.path.isabs(rel_path) or rel_path.startswith(("/", "\\")):
        raise PathEscapeError("absolute installPath is not allowed: %r" % rel_path)
    # Normalise without requiring existence, then confirm containment.
    root_abs = os.path.realpath(root)
    candidate = os.path.realpath(os.path.join(root_abs, rel_path))
    try:
        common = os.path.commonpath([root_abs, candidate])
    except ValueError:
        raise PathEscapeError(
            "installPath is on a different drive/root than the package: %r"
            % rel_path
        )
    if common != root_abs:
        raise PathEscapeError(
            "installPath escapes the package directory: %r" % rel_path
        )
    return candidate


# --------------------------------------------------------------------------- #
# Manifest
# --------------------------------------------------------------------------- #
def load_manifest(root: str) -> dict:
    path = os.path.join(root, MANIFEST_NAME)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        raise ManifestError("manifest not found: %s" % path)
    except json.JSONDecodeError as exc:
        raise ManifestError("manifest is not valid JSON (%s): %s" % (path, exc))
    validate_manifest(data)
    return data


def validate_manifest(data: dict) -> None:
    if not isinstance(data, dict):
        raise ManifestError("%s must contain a JSON object" % MANIFEST_NAME)
    raw_version = data.get("schemaVersion")
    if isinstance(raw_version, bool) or not isinstance(raw_version, int):
        raise ManifestError(
            "%s has missing or non-integer schemaVersion %r; this bootstrap "
            "supports schemaVersion 1 (legacy) and %d (derivation-aware)"
            % (MANIFEST_NAME, raw_version, CURRENT_SCHEMA_VERSION)
        )
    # Exact match: an unknown schema may change field semantics, so it is
    # refused rather than silently interpreted with this schema's rules.
    if raw_version not in SUPPORTED_SCHEMA_VERSIONS:
        raise ManifestError(
            "unsupported schemaVersion %r in %s; this bootstrap supports "
            "schemaVersion 1 (legacy) and %d (derivation-aware)"
            % (raw_version, MANIFEST_NAME, CURRENT_SCHEMA_VERSION)
        )
    artifacts = data.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise ManifestError("manifest declares no artifacts")
    for art in artifacts:
        for key in ("installPath", "size", "sha256", "source"):
            if key not in art:
                raise ManifestError("artifact missing %r: %r" % (key, art.get("name")))
        if not isinstance(art["size"], int) or art["size"] < 0:
            raise ManifestError("artifact %r has invalid size" % art.get("name"))
        if not _is_hex(art["sha256"], 64):
            raise ManifestError("artifact %r has invalid sha256" % art.get("name"))
        src = art["source"]
        if src.get("kind") != _REQUIRED_SOURCE_KIND:
            raise UnsupportedSourceError(
                "artifact %r uses unsupported source kind %r (only %r is supported)"
                % (art.get("name"), src.get("kind"), _REQUIRED_SOURCE_KIND)
            )
        for key in ("sourceId", "oid", "upstreamPath"):
            if not src.get(key):
                raise ManifestError(
                    "artifact %r source missing %r" % (art.get("name"), key)
                )
        if not _is_hex(src["oid"], 64):
            raise ManifestError("artifact %r has invalid LFS oid" % art.get("name"))
        if src["oid"] != art["sha256"]:
            raise ManifestError(
                "artifact %r: LFS oid does not match sha256" % art.get("name")
            )
        derivation = art.get("derivation")
        if derivation is not None:
            if raw_version < 2:
                raise ManifestError(
                    "artifact %r declares a derivation but %s uses schemaVersion "
                    "1; use schemaVersion %d"
                    % (art.get("name"), MANIFEST_NAME, CURRENT_SCHEMA_VERSION)
                )
            if not isinstance(derivation, dict):
                raise ManifestError(
                    "artifact %r derivation must be an object" % art.get("name")
                )
            for key in ("id", "recipe", "recipeSha256", "receiptPath"):
                if not isinstance(derivation.get(key), str) or not derivation[key].strip():
                    raise ManifestError(
                        "artifact %r derivation missing %r"
                        % (art.get("name"), key)
                    )
            if not _is_hex(derivation["recipeSha256"], 64):
                raise ManifestError(
                    "artifact %r derivation has invalid recipeSha256"
                    % art.get("name")
                )
            for key in ("recipe", "receiptPath"):
                if os.path.isabs(derivation[key]) or derivation[key].startswith(("/", "\\")):
                    raise ManifestError(
                        "artifact %r derivation.%s must be relative"
                        % (art.get("name"), key)
                    )
            _validate_parent_derivation(derivation, art.get("name"))
            expected = derivation.get("expectedResult")
            if expected is not None:
                if not isinstance(expected, dict):
                    raise ManifestError(
                        "artifact %r derivation.expectedResult must be an object"
                        % art.get("name")
                    )
                if (isinstance(expected.get("size"), bool)
                        or not isinstance(expected.get("size"), int)
                        or expected["size"] < 0):
                    raise ManifestError(
                        "artifact %r derivation.expectedResult.size is invalid"
                        % art.get("name")
                    )
                if not _is_hex(expected.get("sha256"), 64):
                    raise ManifestError(
                        "artifact %r derivation.expectedResult.sha256 is invalid"
                        % art.get("name")
                    )


def _validate_parent_derivation(derivation, artifact_name):
    parent = derivation.get("parent")
    if parent is None:
        return
    if not isinstance(parent, dict) or "parent" in parent:
        raise ManifestError("artifact %r requires exactly one input derivation stage" % artifact_name)
    for key in ("id", "recipe", "recipeSha256", "receiptPath"):
        if not isinstance(parent.get(key), str) or not parent[key].strip():
            raise ManifestError("artifact %r input derivation missing %r" % (artifact_name, key))
    if not _is_hex(parent["recipeSha256"], 64):
        raise ManifestError("artifact %r input derivation recipe hash is invalid" % artifact_name)
    for key in ("recipe", "receiptPath"):
        if os.path.isabs(parent[key]) or parent[key].startswith(("/", "\\")):
            raise ManifestError("artifact %r input derivation path must be relative" % artifact_name)
    expected = parent.get("expectedResult")
    if (not isinstance(expected, dict) or isinstance(expected.get("size"), bool)
            or not isinstance(expected.get("size"), int) or expected["size"] < 0
            or not _is_hex(expected.get("sha256"), 64)):
        raise ManifestError("artifact %r input derivation needs a tracked expectedResult" % artifact_name)


def _input_artifact(art):
    parent = art.get("derivation", {}).get("parent")
    if parent is None:
        return None
    return dict(art, derivation=parent)


def _is_hex(value: object, length: int) -> bool:
    return (
        isinstance(value, str)
        and len(value) == length
        and all(c in "0123456789abcdef" for c in value.lower())
    )


def _is_safe_url(url: str) -> bool:
    """HTTPS from any host is allowed. Plain HTTP is allowed only for loopback,
    so the hermetic test bridge (and an on-prem LFS mirror on localhost) works
    without enabling cleartext downloads from remote hosts."""
    lower = url.lower()
    if lower.startswith("https://"):
        return True
    if lower.startswith("http://"):
        rest = lower[len("http://"):]
        host = rest.split("/", 1)[0].split(":", 1)[0]
        return host in ("127.0.0.1", "localhost", "::1", "[::1]")
    return False


# --------------------------------------------------------------------------- #
# Error-message redaction
# --------------------------------------------------------------------------- #
# LFS download hrefs are short-lived pre-signed URLs: their query strings carry
# bearer credentials. None of them may ever be written to stdout/stderr or into
# an exception that a caller might log. Remote error messages are also
# attacker-influenced text, so they are cleaned and length-capped before use.
_QUERY_URL_RE = re.compile(r"(https?://[^\s?#\"'<>]+)\?[^\s\"'<>]*")
_SECRET_PARAM_RE = re.compile(
    r"(?i)\b(access[_-]?token|auth|token|sig|signature|expires|policy|"
    r"key-pair-id|x-amz-[a-z0-9-]+)=([^\s&\"'<>]+)"
)


def redact(text: object, limit: int = MAX_ERROR_TEXT) -> str:
    """Return `text` safe for logs: URL queries and token-like parameters are
    replaced, and the result is capped at `limit` characters."""
    value = str(text)
    value = _QUERY_URL_RE.sub(r"\1?<redacted>", value)
    value = _SECRET_PARAM_RE.sub(r"\1=<redacted>", value)
    if len(value) > limit:
        value = value[:limit] + "...(truncated)"
    return value


def resolve_sources(manifest: dict) -> dict:
    sources = manifest.get("sources", {})
    if not isinstance(sources, dict):
        raise ManifestError("manifest 'sources' must be an object")
    return sources


# --------------------------------------------------------------------------- #
# Hashing / verification
# --------------------------------------------------------------------------- #
def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(READ_CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_matches(path: str, size: int, sha256: str) -> bool:
    try:
        if os.path.getsize(path) != size:
            return False
    except OSError:
        return False
    return sha256_file(path) == sha256.lower()


# --------------------------------------------------------------------------- #
# Required source derivations (OCCT Standard_Type lifetime backport)
# --------------------------------------------------------------------------- #
# A derived artifact is not the pinned upstream binary: it is reconstructed
# from the pinned base plus a tracked source patch.  The receipt binds the
# produced bytes to the base pin, the tracked recipe/source/patch hashes, the
# declared toolchain and the exact archive member set.  A missing, malformed or
# stale receipt fails closed; the pinned base alone is reported UNPREPARED, not
# accepted, because it is the known-crashing object.  `--local-relink` remains
# an honest presence-only opt-in for a developer's own rebuilt slice, but it
# can never satisfy `--release-check`.
_DERIVATION_MODULES = None


def _derivation_modules():
    global _DERIVATION_MODULES
    if _DERIVATION_MODULES is None:
        directory = os.path.join(package_root(), "relink", "derivations")
        if directory not in sys.path:
            sys.path.insert(0, directory)
        # A fresh --check must also stay read-only when Python imports these
        # support modules for the first time. Do not create __pycache__ as a
        # side effect of validating an otherwise unchanged native package.
        previous_bytecode_policy = sys.dont_write_bytecode
        sys.dont_write_bytecode = True
        try:
            import derivation_common  # type: ignore
            import occt_archive  # type: ignore
        except ImportError as exc:
            raise DerivationError(
                "derivation support modules are missing (%s); restore "
                "FloeCADKit/relink/derivations" % exc
            )
        finally:
            sys.dont_write_bytecode = previous_bytecode_policy
        _DERIVATION_MODULES = (derivation_common, occt_archive)
    return _DERIVATION_MODULES


def _load_derivation(root: str, art: dict):
    der = art["derivation"]
    dc, oa = _derivation_modules()
    recipe_path = safe_install_path(root, der["recipe"])
    try:
        recipe = dc.load_recipe(recipe_path, der["recipeSha256"], der["id"])
        slice_name, slice_cfg = dc.slice_config(
            recipe, install_path=art["installPath"]
        )
    except dc.DerivationError as exc:
        raise DerivationError(str(exc))
    parent_art = _input_artifact(art)
    if parent_art is not None:
        _validate_parent_derivation(art["derivation"], art.get("name"))
        _load_derivation(root, parent_art)  # retains the upstream archive anchor
        parent = parent_art["derivation"]
        expected = dc.expected_result(parent)
        binding = recipe.get("inputDerivation") or {}
        if not isinstance(binding, dict):
            raise DerivationError("recipe inputDerivation must be an object")
        if (binding.get("id") != parent["id"]
                or binding.get("recipeSha256") != parent["recipeSha256"]):
            raise DerivationError("recipe does not bind the declared input derivation")
        if (slice_cfg["baseSize"] != expected["size"]
                or slice_cfg["baseSha256"].lower() != expected["sha256"]):
            raise DerivationError("second-stage base pin differs from input expectedResult")
    elif (slice_cfg["baseSize"] != art["size"]
            or slice_cfg["baseSha256"].lower() != art["sha256"].lower()):
        raise DerivationError(
            "recipe base pin does not match the manifest artifact"
        )
    return dc, oa, recipe, slice_name, slice_cfg


def _read_json_file(path: str, label: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        raise DerivationError("%s not found: %s" % (label, path))
    except (OSError, json.JSONDecodeError) as exc:
        raise DerivationError("cannot read %s %s: %s" % (label, path, exc))


def _validate_derivation_receipt(root, art, receipt, installed_size, installed_sha,
                                 strict_toolchain=False, require_expected=False,
                                 warnings=None):
    dc, oa, recipe, slice_name, slice_cfg = _load_derivation(root, art)
    # The final stage starts from the pinned parent output; the parent receipt
    # is separately validated against the unchanged upstream manifest anchor.
    stage_input = {"installPath": art["installPath"],
                   "size": slice_cfg["baseSize"], "sha256": slice_cfg["baseSha256"]}
    problems, qualified = dc.validate_receipt(
        recipe, stage_input, receipt, installed_size, installed_sha
    )
    for key in ("baseSource", "overlaySource", "patch"):
        item = recipe["occt"][key]
        source = dc.resolve_relative(root, item["path"], "recipe.occt.%s.path" % key)
        if not file_matches(source, item["size"], item["sha256"]):
            problems.append("tracked derivation %s does not match recipe source hash" % key)
    parent_qualified = True
    parent_art = _input_artifact(art)
    if parent_art is not None:
        parent = parent_art["derivation"]
        binding = receipt.get("inputDerivation") or {}
        if not isinstance(binding, dict):
            raise DerivationError("receipt inputDerivation must be an object")
        if (binding.get("id") != parent["id"]
                or binding.get("recipeSha256") != parent["recipeSha256"]
                or not isinstance(binding.get("receipt"), dict)):
            problems.append("missing or mismatched input derivation receipt")
        else:
            parent_info = _validate_derivation_receipt(
                root, parent_art, binding["receipt"],
                slice_cfg["baseSize"], slice_cfg["baseSha256"],
                strict_toolchain=strict_toolchain, require_expected=True,
                warnings=warnings)
            parent_qualified = parent_info["qualified"]
    expected = dc.expected_result(art["derivation"])
    if expected is None:
        if require_expected:
            problems.append(
                "no tracked expectedResult is recorded; after Root derives and "
                "qualifies this slice, record its size/SHA-256 in DEPENDENCIES.json"
            )
    elif (installed_size != expected["size"]
          or installed_sha != expected["sha256"]):
        message = (
            "installed bytes do not match the tracked expectedResult "
            "(size %d/%d, sha256 %s/%s)"
            % (installed_size, expected["size"], installed_sha, expected["sha256"])
        )
        if strict_toolchain or qualified:
            problems.append(message)
        elif warnings is not None:
            warnings.append(message + "; this toolchain is not the qualified one")
    if strict_toolchain and not qualified:
        _matched, mismatches = dc.toolchain_matches_qualified(receipt, recipe)
        problems.append(
            "derivation toolchain is not the qualified release toolchain: %s"
            % "; ".join(mismatches)
        )
    if strict_toolchain:
        build = recipe.get("build") or {}
        expected_headers = build.get("headersTreeSha256")
        if expected_headers:
            try:
                actual_headers = dc.headers_identity(root, recipe)
            except dc.DerivationError as exc:
                problems.append("cannot verify pinned headers: %s" % exc)
            else:
                if (actual_headers["headersTreeSha256"] != expected_headers
                        or actual_headers["headersFileCount"] != build.get("headersFileCount")):
                    problems.append(
                        "pinned OCCT headers tree does not match the recipe"
                    )
    if problems:
        raise DerivationError(dc.describe_problems(problems))
    return {
        "receipt": receipt,
        "summary": receipt.get("archive"),
        "qualified": qualified and parent_qualified,
        "toolchain": dc.toolchain_summary(receipt),
        "expected": expected,
    }


def _validate_derivation_paths(root: str, art: dict, archive_path: str,
                               receipt_path: str, strict_toolchain: bool = False,
                               require_expected: bool = False,
                               warnings=None) -> dict:
    receipt = _read_json_file(receipt_path, "derivation receipt")
    info = _validate_derivation_receipt(
        root, art, receipt, os.path.getsize(archive_path), sha256_file(archive_path),
        strict_toolchain=strict_toolchain, require_expected=require_expected,
        warnings=warnings)
    dc, oa, recipe, _, slice_cfg = _load_derivation(root, art)
    problems, summary = dc.verify_installed_archive(archive_path, recipe, slice_cfg, receipt)
    if problems:
        raise DerivationError(dc.describe_problems(problems))
    info["summary"] = summary
    return info


def _artifact_status_detail(root: str, art: dict,
                            local_relink: bool = False):
    """Return (status, human-readable detail) for one artifact."""
    dest = safe_install_path(root, art["installPath"])
    if not os.path.exists(dest):
        return "missing", "artifact file is absent"
    der = art.get("derivation")
    if not der:
        if file_matches(dest, art["size"], art["sha256"]):
            return "ok", "matches the pinned size and SHA-256"
        return (
            ("local" if local_relink else "invalid"),
            "bytes do not match the pinned size/SHA-256",
        )
    if file_matches(dest, art["size"], art["sha256"]):
        return "unprepared", (
            "installed bytes are the pinned upstream base and lack the required "
            "derivation %s" % der["id"]
        )
    receipt_path = safe_install_path(root, der["receiptPath"])
    if not os.path.exists(receipt_path):
        return (
            ("local" if local_relink else "underived"),
            "no derivation receipt is installed",
        )
    warnings = []
    try:
        info = _validate_derivation_paths(root, art, dest, receipt_path,
                                          warnings=warnings)
    except DerivationError as exc:
        return (("local-stale" if local_relink else "stale"), str(exc))
    detail = "derivation %s; %s%s" % (
        der["id"], info["toolchain"],
        "" if info["qualified"] else " (unqualified toolchain)",
    )
    if warnings:
        detail += "; WARNING: " + "; ".join(warnings)
    return "derived", detail


def artifact_status(root: str, art: dict, local_relink: bool = False) -> str:
    """Return 'ok', 'missing', 'invalid' for legacy artifacts; derived
    artifacts additionally use 'unprepared', 'underived', 'stale' and
    'derived'.  'local'/'local-stale' are presence-only local-relink states."""
    return _artifact_status_detail(root, art, local_relink)[0]


def _fetch_verified_temp(dest_dir: str, art: dict, source: dict,
                         deadline: float, log) -> str:
    oid = art["source"]["oid"]
    urls = resolve_lfs_urls(source, [{"oid": oid, "size": art["size"]}], deadline)
    href = urls[oid]
    os.makedirs(dest_dir, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(
        prefix=".floecad-base-", suffix=".a", dir=dest_dir
    )
    os.close(fd)
    try:
        log("fetch  %s verified base (%d bytes) for derivation"
            % (art.get("name", art["installPath"]), art["size"]))
        download_verified(href, tmp_path, art["size"], art["sha256"], deadline)
    except BaseException:
        _remove_quiet(tmp_path)
        raise
    return tmp_path


def _run_single_derive_tool(root: str, art: dict, recipe: dict, slice_name: str,
                     base_path: str, output_path: str, receipt_path: str, log):
    tool = os.path.join(package_root(), "relink", "derivations",
                        "derive_standard_type_slice.py")
    if not os.path.isfile(tool):
        raise DerivationError("derivation tool is missing: %s" % tool)
    timeout = float(os.environ.get("FLOECAD_DERIVE_TIMEOUT", "1800"))
    argv = [
        sys.executable, tool, "derive",
        "--package-root", package_root(),
        "--recipe", recipe["_path"],
        "--recipe-sha256", recipe["_sha256"],
        "--slice", slice_name,
        "--base", base_path,
        "--output", output_path,
        "--receipt", receipt_path,
        "--timeout", str(int(timeout)),
    ]
    log("derive %s (single-object %s; %s)"
        % (art.get("name", art["installPath"]), recipe["member"]["name"],
           os.environ.get("DEVELOPER_DIR", "system Xcode")))
    try:
        result = subprocess.run(
            argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout + 60,
        )
    except OSError as exc:
        raise DerivationError("could not start the derivation tool: %s" % exc)
    except subprocess.TimeoutExpired:
        raise DerivationError("derivation timed out after %s seconds" % timeout)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        if not detail:
            detail = result.stdout.decode("utf-8", "replace").strip()
        raise DerivationError(
            "derivation failed (exit %d): %s"
            % (result.returncode, redact(detail[-1500:]))
        )


def _run_derive_tool(root, art, recipe, slice_name, base_path, output_path,
                     receipt_path, log, prepared_input_receipt=None):
    parent_art = _input_artifact(art)
    if parent_art is None:
        return _run_single_derive_tool(root, art, recipe, slice_name, base_path,
                                       output_path, receipt_path, log)
    staging = tempfile.mkdtemp(prefix=".floecad-input-", dir=os.path.dirname(output_path))
    try:
        parent = parent_art["derivation"]
        if prepared_input_receipt is None:
            _, _, parent_recipe, parent_slice, _ = _load_derivation(root, parent_art)
            parent_archive = os.path.join(staging, "input.a")
            parent_receipt = os.path.join(staging, "input-receipt.json")
            _run_single_derive_tool(root, parent_art, parent_recipe, parent_slice,
                                   base_path, parent_archive, parent_receipt, log)
            info = _validate_derivation_paths(root, parent_art, parent_archive,
                                              parent_receipt, require_expected=True)
            prepared_input_receipt = info["receipt"]
            base_path = parent_archive
        _run_single_derive_tool(root, art, recipe, slice_name, base_path,
                                output_path, receipt_path, log)
        receipt = _read_json_file(receipt_path, "derived receipt")
        receipt["inputDerivation"] = {"id": parent["id"],
            "recipeSha256": parent["recipeSha256"], "receipt": prepared_input_receipt}
        with open(receipt_path, "w", encoding="utf-8") as handle:
            json.dump(receipt, handle, indent=2, sort_keys=True)
            handle.write("\n")
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def _install_receipt(source_path: str, receipt_path: str) -> None:
    directory = os.path.dirname(receipt_path)
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(
        prefix=".floecad-receipt-", suffix=".json", dir=directory
    )
    os.close(fd)
    try:
        with open(source_path, "rb") as src, open(tmp_path, "wb") as dst:
            for chunk in iter(lambda: src.read(READ_CHUNK), b""):
                dst.write(chunk)
        os.replace(tmp_path, receipt_path)
    except BaseException:
        _remove_quiet(tmp_path)
        raise


def install_derived_artifact(root: str, art: dict, source: dict, deadline: float,
                             offline: bool, log, local_relink: bool = False) -> str:
    """Prepare/keep one derived artifact without ever installing unchecked bytes."""
    dest = safe_install_path(root, art["installPath"])
    der = art["derivation"]
    receipt_path = safe_install_path(root, der["receiptPath"])
    name = art.get("name", art["installPath"])
    kind, detail = _artifact_status_detail(root, art, local_relink)
    if kind == "derived":
        log("keep   %s (verified derivation %s; %s)" % (name, der["id"], detail))
        return "kept-derived"
    if kind in ("local", "local-stale") and local_relink:
        log("keep   %s (local relink bytes are deliberately NOT overwritten)" % name)
        if kind == "local-stale":
            log("WARN   %s: local bytes do not satisfy the derivation receipt; "
                "official verification will fail until the slice is re-derived"
                % name)
        return "kept-local"

    dc, oa, recipe, slice_name, slice_cfg = _load_derivation(root, art)
    temp_base = None
    prepared_input_receipt = None
    parent_art = _input_artifact(art)
    if parent_art is not None and os.path.exists(dest) and os.path.exists(receipt_path):
        # Reuse a fully verified existing lifetime-repaired slice. This avoids
        # downloading/rebuilding an unchanged first stage and also works offline.
        try:
            info = _validate_derivation_paths(root, parent_art, dest, receipt_path,
                                              require_expected=True)
            prepared_input_receipt = info["receipt"]
        except DerivationError:
            pass
    if prepared_input_receipt is not None:
        base_path = dest
        log("reuse  %s verified input derivation" % name)
    elif kind == "unprepared":
        base_path = dest
        log("prepare %s: the pinned upstream base is present but lacks the "
            "required repair; reconstructing the single Standard_Type object"
            % name)
    else:
        if offline:
            raise FetchError(
                "--offline set and %s needs a verified pinned base before the "
                "derivation can run" % name
            )
        temp_base = _fetch_verified_temp(
            os.path.dirname(dest), art, source, deadline, log
        )
        base_path = temp_base

    staging = tempfile.mkdtemp(
        prefix=".floecad-derive-", dir=os.path.dirname(dest)
    )
    derived_tmp = os.path.join(staging, os.path.basename(dest) + ".derived")
    receipt_tmp = os.path.join(staging, "receipt.json")
    warnings = []
    try:
        _run_derive_tool(root, art, recipe, slice_name, base_path, derived_tmp,
                         receipt_tmp, log, prepared_input_receipt=prepared_input_receipt)
        info = _validate_derivation_paths(
            root, art, derived_tmp, receipt_tmp, warnings=warnings
        )
        for warning in warnings:
            log("WARN   %s: %s" % (name, warning))
        if os.path.exists(receipt_path):
            previous = _read_json_file(receipt_path, "existing derivation receipt")
            previous_sha = ((previous.get("archive") or {}).get("sha256"))
            new_sha = sha256_file(derived_tmp)
            parent = der.get("parent") or {}
            expected_parent = parent.get("expectedResult") or {}
            upgrading_verified_input = (
                parent_art is not None
                and previous.get("recipeSha256") == parent.get("recipeSha256")
                and previous_sha == expected_parent.get("sha256"))
            if previous_sha and previous_sha != new_sha and not upgrading_verified_input:
                raise DerivationError(
                    "derivation is not reproducible on this toolchain: the "
                    "existing receipt records %s but the new derivation produced "
                    "%s; refusing to replace the installed slice"
                    % (previous_sha, new_sha)
                )
        # Receipt first, then the archive: a crash between the two leaves a
        # receipt that does not match the installed bytes, so --check fails
        # closed instead of accepting an unverified archive.  Re-running
        # bootstrap repairs it.
        _install_receipt(receipt_tmp, receipt_path)
        os.replace(derived_tmp, dest)
        log("verify %s OK (derived slice installed; target object %s; %s)"
            % (name, info["summary"]["targetPayloadSha256"][:12],
               info["toolchain"]))
        return "prepared"
    finally:
        if temp_base:
            _remove_quiet(temp_base)
        shutil.rmtree(staging, ignore_errors=True)


# --------------------------------------------------------------------------- #
# Git-LFS fetch: HTTP with a strict redirect policy
# --------------------------------------------------------------------------- #
class _SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Follow redirects only when the target satisfies the same URL policy.

    In particular an HTTPS request may never be redirected to plain HTTP (a
    transport downgrade), and no redirect may point at a scheme/host the
    initial policy would have refused.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is None:
            return None
        if (req.full_url.lower().startswith("https://")
                and not newurl.lower().startswith("https://")):
            raise FetchError(
                "refusing HTTPS-to-non-HTTPS redirect to %s" % redact(newurl)
            )
        if not _is_safe_url(newurl):
            raise FetchError("refusing redirect to unsafe URL %s" % redact(newurl))
        return redirected


_OPENER = urllib.request.build_opener(_SafeRedirectHandler())


def _urlopen(req, timeout):
    # urllib uses a single timeout for connect and each read; callers bound the
    # overall operation with the deadline as well. The opener enforces the
    # redirect policy above.
    return _OPENER.open(req, timeout=timeout)


def _read_bounded(resp, limit: int) -> bytes:
    """Read at most `limit` bytes from `resp`; raise if the body is larger."""
    chunks = []
    total = 0
    while True:
        chunk = resp.read(min(READ_CHUNK, limit + 1 - total))
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise FetchError(
                "LFS batch response exceeds the %d-byte limit; refusing to "
                "read further" % limit
            )
        chunks.append(chunk)
    return b"".join(chunks)


def _http_post_json(url: str, payload: dict) -> dict:
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Accept": "application/vnd.git-lfs+json",
            "Content-Type": "application/vnd.git-lfs+json",
        },
    )
    with _urlopen(req, CONNECT_TIMEOUT) as resp:
        raw = _read_bounded(resp, MAX_BATCH_RESPONSE_BYTES)
    return json.loads(raw.decode("utf-8"))


def resolve_lfs_urls(source: dict, objects: list, deadline: float) -> dict:
    """Ask the pinned LFS batch endpoint for fresh download URLs.

    Returns {oid: href}. The returned URLs are short-lived pre-signed links and
    are deliberately never persisted; only endpoint + oid are durable pins.
    """
    endpoint = source.get("lfsBatchApi")
    if not endpoint:
        raise ManifestError("LFS source missing 'lfsBatchApi'")
    batch_objects = [{"oid": o["oid"], "size": o["size"]} for o in objects]
    payload = {
        "operation": "download",
        "transfers": [source.get("lfsTransfer", "basic")],
        "objects": batch_objects,
    }
    last_exc = None
    for attempt in range(1, MAX_RETRIES + 1):
        _check_deadline(deadline)
        try:
            data = _http_post_json(endpoint, payload)
            break
        except (urllib.error.URLError, OSError, http.client.HTTPException,
                json.JSONDecodeError) as exc:
            last_exc = exc
            if attempt >= MAX_RETRIES or time.monotonic() >= deadline:
                raise FetchError(
                    "could not reach LFS batch endpoint %s after %d attempt(s): %s\n"
                    "Check network access. The libraries can also be obtained by "
                    "running the relink kit (see OCCT_RELINK.md), or a deliberate "
                    "local replacement can be kept by setting %s=1."
                    % (redact(endpoint), attempt, _reason(exc), ENV_LOCAL_RELINK)
                )
            time.sleep(min(2 ** attempt, 10))
    else:  # pragma: no cover - defensive
        raise FetchError("LFS batch resolution failed: %s" % _reason(last_exc))

    by_oid = {o["oid"]: o for o in objects}
    resolved = {}
    for obj in data.get("objects", []):
        oid = obj.get("oid")
        if oid not in by_oid:
            continue
        if "error" in obj:
            error = obj["error"] if isinstance(obj["error"], dict) else {}
            message = error.get("message") or obj["error"]
            raise FetchError(
                "LFS server rejected object %s: %s"
                % (oid[:12], redact(message))
            )
        action = (obj.get("actions") or {}).get("download")
        href = (action or {}).get("href")
        if not href:
            raise FetchError(
                "LFS object %s is not available for download from the pinned source"
                % oid[:12]
            )
        if not _is_safe_url(href):
            raise FetchError("refusing non-HTTPS LFS download URL for %s" % oid[:12])
        resolved[oid] = href
    missing = [o["oid"] for o in objects if o["oid"] not in resolved]
    if missing:
        raise FetchError(
            "pinned LFS source did not return a download URL for: %s"
            % ", ".join(m[:12] for m in missing)
        )
    return resolved


def _check_deadline(deadline: float) -> None:
    if time.monotonic() >= deadline:
        raise FetchError("network deadline exceeded (set FLOECAD_DEADLINE to extend)")


def _reason(exc) -> str:
    return redact(getattr(exc, "reason", None) or str(exc))


def download_verified(url: str, dest_tmp: str, size: int, sha256: str,
                      deadline: float) -> None:
    """Stream url -> dest_tmp, enforcing exact size and SHA-256.

    Raises IntegrityError on a wrong hash or wrong length and FetchError on
    network problems. Never touches the final destination.
    """
    req = urllib.request.Request(url, method="GET")
    last_exc = None
    for attempt in range(1, MAX_RETRIES + 1):
        _check_deadline(deadline)
        digest = hashlib.sha256()
        written = 0
        try:
            with _urlopen(req, min(READ_TIMEOUT, max(1.0, deadline - time.monotonic()))) as resp:
                if resp.status != 200:
                    raise FetchError("HTTP %s fetching object" % resp.status)
                with open(dest_tmp, "wb") as out:
                    while True:
                        _check_deadline(deadline)
                        chunk = resp.read(READ_CHUNK)
                        if not chunk:
                            break
                        written += len(chunk)
                        if written > size:
                            raise IntegrityError(
                                "download is larger than the pinned size "
                                "(expected %d bytes)" % size
                            )
                        digest.update(chunk)
                        out.write(chunk)
            got_hash = digest.hexdigest()
            if written != size:
                raise IntegrityError(
                    "partial download: got %d of %d bytes" % (written, size)
                )
            if got_hash != sha256.lower():
                raise IntegrityError(
                    "download hash mismatch: expected %s, got %s"
                    % (sha256[:12], got_hash[:12])
                )
            return
        except IntegrityError:
            # A wrong hash or truncated body will not be repaired by a blind
            # retry from scratch against the same pinned object; fail loudly.
            _remove_quiet(dest_tmp)
            raise
        except (urllib.error.URLError, OSError, http.client.HTTPException) as exc:
            last_exc = exc
            _remove_quiet(dest_tmp)
            if attempt >= MAX_RETRIES or time.monotonic() >= deadline:
                raise FetchError(
                    "download failed after %d attempt(s): %s"
                    % (attempt, _reason(exc))
                )
            time.sleep(min(2 ** attempt, 10))
    # pragma: no cover - defensive
    raise FetchError("download failed: %s" % last_exc)


def _remove_quiet(path: str) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


# --------------------------------------------------------------------------- #
# Install
# --------------------------------------------------------------------------- #
def install_artifact(root: str, art: dict, source: dict, deadline: float,
                     offline: bool, log, local_relink: bool = False) -> str:
    """Ensure one artifact is present and verified. Returns the action taken."""
    if art.get("derivation"):
        return install_derived_artifact(root, art, source, deadline, offline,
                                        log, local_relink=local_relink)
    dest = safe_install_path(root, art["installPath"])
    name = art.get("name", art["installPath"])

    if os.path.exists(dest):
        if file_matches(dest, art["size"], art["sha256"]):
            log("keep   %s (already matches pinned SHA-256, not rewritten)" % name)
            return "kept"
        if local_relink:
            log("keep   %s (local relink in effect: bytes differ from the pinned "
                "SHA-256 and are deliberately NOT overwritten)" % name)
            return "kept-local"

    preexisting = os.path.exists(dest)
    if preexisting:
        log("replace %s (present but size/hash do not match the pin)" % name)

    if offline:
        raise FetchError(
            "--offline set and %s is missing or invalid at %s; cannot fetch"
            % (name, art["installPath"])
        )

    urls = resolve_lfs_urls(
        source, [{"oid": art["source"]["oid"], "size": art["size"]}], deadline
    )
    href = urls[art["source"]["oid"]]

    os.makedirs(os.path.dirname(dest), exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(
        prefix=".floecad-tmp-", suffix=".a", dir=os.path.dirname(dest)
    )
    os.close(fd)
    try:
        log("fetch  %s (%d bytes) from pinned LFS source" % (name, art["size"]))
        download_verified(href, tmp_path, art["size"], art["sha256"], deadline)
        # Atomic on the same volume (tmp is a sibling of the destination).
        os.replace(tmp_path, dest)
    except BaseException:
        _remove_quiet(tmp_path)
        raise
    log("verify %s OK (size + SHA-256 match)" % name)
    return "replaced" if preexisting else "installed"


def run(root: str, check: bool, offline: bool, log=print,
        local_relink: bool = False, release_check: bool = False) -> int:
    manifest = load_manifest(root)
    sources = resolve_sources(manifest)
    artifacts = manifest["artifacts"]

    if release_check:
        check = True
        if local_relink:
            log("NOTE: --release-check ignores the local-relink opt-in; only "
                "exact pinned bytes or a qualified derived slice are accepted.")
            local_relink = False

    if check:
        # Strictly read-only: no network, no writes.
        ok = True
        local_count = 0
        derived_count = 0
        labels = {
            "ok": "OK    ", "missing": "MISS  ", "invalid": "BAD   ",
            "unprepared": "UNPREP", "underived": "UNDERI", "stale": "STALE ",
            "derived": "PREPD ", "local": "LOCAL ", "local-stale": "LOCAL*",
        }
        for art in artifacts:
            safe_install_path(root, art["installPath"])  # surface escape errors
            if art.get("derivation"):
                safe_install_path(root, art["derivation"]["recipe"])
                safe_install_path(root, art["derivation"]["receiptPath"])
            status, detail = _artifact_status_detail(root, art, local_relink)
            label = labels.get(status, "BAD   ")
            if status == "derived":
                if release_check:
                    receipt_path = safe_install_path(
                        root, art["derivation"]["receiptPath"]
                    )
                    try:
                        _validate_derivation_paths(
                            root, art,
                            safe_install_path(root, art["installPath"]),
                            receipt_path, strict_toolchain=True,
                            require_expected=True,
                        )
                    except DerivationError as exc:
                        ok = False
                        log("REJECT %s (%s)" % (art["installPath"], exc))
                        continue
                    log("%s %s (%s; qualified)" % (label, art["installPath"], detail))
                else:
                    log("%s %s (%s)" % (label, art["installPath"], detail))
                derived_count += 1
                continue
            if status == "ok":
                log("%s %s (%s)" % (label, art["installPath"], detail))
                continue
            if status in ("local", "local-stale") and local_relink:
                local_count += 1
                log("%s %s (%s)" % (label, art["installPath"], detail))
                if status == "local-stale":
                    log("WARN   %s: local bytes are presence-only under %s and "
                        "do not satisfy the derivation receipt"
                        % (art["installPath"], ENV_LOCAL_RELINK))
                continue
            ok = False
            log("%s %s (%s)" % (label, art["installPath"], detail))
            if status == "unprepared":
                log("       run: python3 bootstrap.py  (reconstruct the reviewed "
                    "single object locally)")
            elif status in ("stale", "underived"):
                log("       run: python3 bootstrap.py  (re-derive or repair the "
                    "derivation receipt)")
        if ok:
            if derived_count and local_count:
                log("%d artifact(s) are verified derivations and %d are "
                    "presence-only local replacements; neither is the pinned "
                    "upstream bytes. Release verification must run "
                    "python3 bootstrap.py --release-check."
                    % (derived_count, local_count))
                return 0
            if derived_count:
                log("All %d artifact(s) prepared and verified (%d derived from the "
                    "pinned base; these are NOT the pinned upstream bytes)."
                    % (len(artifacts), derived_count))
                return 0
            if local_count:
                log("%d of %d artifact(s) are deliberate local replacements accepted "
                    "by %s; they are NOT the pinned official bytes. Official/release "
                    "verification must run plain --check."
                    % (local_count, len(artifacts), ENV_LOCAL_RELINK))
                return 0
            log("All %d pinned artifact(s) present and verified." % len(artifacts))
            return 0
        log("Some artifacts are missing, unprepared or invalid. "
            "Run: python3 bootstrap.py")
        return 2

    deadline = time.monotonic() + DEADLINE
    actions = []
    for art in artifacts:
        source_id = art["source"]["sourceId"]
        source = sources.get(source_id)
        if not source:
            raise ManifestError(
                "artifact %r references unknown source %r"
                % (art.get("name"), source_id)
            )
        if source.get("kind") != _REQUIRED_SOURCE_KIND:
            raise UnsupportedSourceError(
                "source %r has unsupported kind %r"
                % (source_id, source.get("kind"))
            )
        actions.append(install_artifact(root, art, source, deadline, offline, log,
                                        local_relink=local_relink))

    # Post-install verification (defense in depth). Unpinned derived/local
    # bytes only pass when the corresponding receipt validates, or when the
    # local-relink opt-in explicitly allows a presence-only replacement.
    derived_count = 0
    for art in artifacts:
        status = artifact_status(root, art, local_relink=local_relink)
        if art.get("derivation"):
            allowed = {"derived"}
            derived_count += 1 if status == "derived" else 0
        else:
            allowed = {"ok"}
        if local_relink:
            allowed |= {"local", "local-stale"}
        if status not in allowed:
            raise IntegrityError(
                "post-install verification failed for %s (status %s)"
                % (art["installPath"], status)
            )
    if "kept-local" in actions:
        log("NOTE: %d artifact(s) kept as deliberate local replacements; the "
            "pinned official bytes were NOT restored. Official/release builds "
            "must run without %s." % (actions.count("kept-local"), ENV_LOCAL_RELINK))
    if derived_count:
        log("NOTE: %d derived artifact(s) are intentionally NOT the pinned "
            "upstream bytes; their receipts bind them to the pinned base, tracked "
            "recipe/source/patch and the recorded toolchain. Release verification "
            "must run: python3 bootstrap.py --release-check"
            % derived_count)
    log("Done. %d artifact(s) ready: %s."
        % (len(artifacts), ", ".join(sorted(set(actions)))))
    return 0


def _env_flag(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in _TRUTHY


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fetch and verify FloeCADKit's pinned native OCCT slices."
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="read-only: verify installed artifacts without network or writes",
    )
    parser.add_argument(
        "--offline",
        action="store_true",
        help="never use the network; fail if an artifact is missing/invalid",
    )
    parser.add_argument(
        "--local-relink",
        action="store_true",
        help="deliberate local rebuild/replacement: never overwrite existing "
             "slices that differ from the pins; for --check, report them as "
             "LOCAL and exit 0 (also enabled by %s=1)" % ENV_LOCAL_RELINK,
    )
    parser.add_argument(
        "--release-check",
        action="store_true",
        help="read-only release gate: require a valid derived artifact, the "
             "recipe's qualified Xcode/SDK toolchain and a tracked "
             "expectedResult; ignores the local-relink opt-in",
    )
    parser.add_argument(
        "--root",
        default=None,
        help="package root containing DEPENDENCIES.json (default: this script's dir)",
    )
    return parser


def main(argv=None) -> int:
    args = build_parser().parse_args(argv)
    root = os.path.abspath(args.root) if args.root else package_root()
    local_relink = args.local_relink or _env_flag(ENV_LOCAL_RELINK)
    started = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        print("FloeCADKit bootstrap starting at %s (root=%s, check=%s, offline=%s, "
              "local_relink=%s, release_check=%s)"
              % (started, root, args.check, args.offline, local_relink,
                 args.release_check))
        return run(root, check=args.check, offline=args.offline,
                   local_relink=local_relink,
                   release_check=args.release_check)
    except BootstrapError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1
    except OSError as exc:
        print("error: filesystem operation failed: %s" % exc, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
