#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Produce ONE final, deterministic, combined public corresponding-source
archive for a Floe Agent Android release that embeds the pinned Office native
module:

  1. the verified Linux/IDE combined corresponding-source output of the
     frozen ``assemble-android-corresponding-source`` tool (v1.0.0+) — the
     tar.gz, MANIFEST.json and SHA256SUMS are embedded byte-exact from the
     passed directory, never repackaged or rewritten; plus
  2. the complete Office engine public group from an explicit frozen
     ``FloeAndroid/core/officeengine`` source directory: host/JNI Kotlin
     sources (MPL notices preserved on upstream-derived files), the engine
     module build source (``build.gradle.kts``, manifest, resources), the
     observer tests, the staging tool and its README (public build recipe),
     the public producer manifest + payload pins (all 14 native library
      hashes, the deliberate official-libc++ exclusion), the full asset
      overlay manifest with every actual overlay file it binds, the bilingual
     notices page, the public-safe notice/source index, and PROVENANCE.md;
  3. rendered README.md / MANIFEST.json binding everything to the FINAL
     immutable Floe source commit, the FINAL signed Full APK sha256 and the
     ``android/v<version>`` release archive URL supplied at run time.

Subcommands (mirroring the proven inner tools):

``check``
    Run every binding check and print a JSON report (including the SHA-256 of
    the deterministic archive it *would* write). Writes nothing.

``produce``
    Re-verify everything, then atomically write into an output directory:

        OUT/
          floe-android-corresponding-source-<release-version>.tar.gz
          MANIFEST.json
          SHA256SUMS

    An existing non-empty destination is never replaced. The tool never runs
    a build, never touches Git, never uploads, never reads credentials and
    never fetches anything; execution against the final frozen inputs and
    publication remain Main's.

Fail-closed bindings (enforced, never downgraded to warnings):

* ``--release-version`` / ``--source-commit`` / ``--apk-name`` /
  ``--apk-sha256`` / ``--source-repository`` are explicit final-binding
  inputs; the APK name must equal the canonical stage-release name derived
  from the version; the public archive URL must equal the URL formed by
  ``https://github.com/<repo>/releases/download/android/v<version>/`` plus
  the output archive name;
* the embedded Linux/IDE archive directory must be the actual output of
  ``assemble-android-corresponding-source`` >= 1.0.0 whose MANIFEST carries
  the *same* release version, the *same* final source commit and the *same*
  release APK name/sha256 as passed here (a stale earlier-generation offer
  is a hard error), whose SHA256SUMS re-verify byte-exactly, whose tar
  contains only safe file/dir members under its expected root prefix, and
  whose structure records both the ``linuxRuntime`` and ``soraEditor``
  blocks (this tool only ever ADDS the Office group; it cannot mask an
  incomplete Linux/IDE generation);
* the Office producer identity is pinned by exact constants, not re-derived:
  upstream monorepo revision ``2333344185931274f9c49d6c12a408cefcef6844``,
  publisher APK ``collabora-office-mobile-26.04.4.2-937`` whole-APK sha256
  ``79e72f810d711706d205a9ff457b4bb830c607a2b988cf44246829ec4593c393`` and
  signer certificate ``573258c8…892cc``. Every identity field in
  ``payload-pins.json``, ``producer-manifest.json``,
  ``asset-overlays.json``, the overlay files themselves and
  ``overlays/notices/source-index.json`` must agree with those constants and
  with each other (manifest digest == pin, per-library hashes, anchor asset
  hashes, every overlay original/new hash, the notice-page digest, the
  source index's own digest via the overlay add entry — no cycle because
   the index never self-embeds its hash, and the index record set must match
   the overlay entries minus its own record);
* the overlay ``sourceAccess`` and ``floeCorrespondingSource`` blocks must
  name exactly ``android/v<release-version>`` and this release's public
  archive URL; the deliberate ``libc++_shared.so`` exclusion is preserved:
  the manifest carries 15 libraries, the pins carry exactly the 14 packaged
  names, the official copy's hash appears only as the excluded-policy pin;
* host sources are enumerated from the frozen directory (nothing silently
  omitted): the module layout is exact (root docs, tools, overlays, src;
  unexpected or missing files fail), the four upstream-derived
  ``org/libreoffice/androidlib`` hosts must retain the Mozilla Public
  License notice text, every overlay artwork/branding/policy file must carry
  the ``SPDX-License-Identifier: MPL-2.0`` marker, and the bilingual notice
  page must link the pinned upstream revision and contain no script;
* the authoritative ``payload-pins.json`` and ``tools/README.md`` contain
  host-local references (private staging path / private toolchain directory)
  that must never enter a public archive. The tool embeds deterministic
  sanitized renderings: for the pins file the single
  ``payload.stagedBy`` key is dropped from an otherwise byte-identical
  JSON re-render; for the recipe document only the exact pinned redaction
  rule below applies. Any remaining private operational fragment is fatal;
  the input digests and the transformation are recorded in MANIFEST.json so
  Main can audit both generations;
* all text inputs and every generated document are scanned for credential
  patterns, private-key markers and private operational path fragments;
  archive entries are byte-sorted, fixed-epoch mtime, uid/gid 0, ustar
  format inside a gzip member with mtime 0 (identical discipline to the
  proven tools), so the same final inputs reproduce identical bytes.

Known limitations are recorded in the report instead of silently converted
into success: this tool binds inputs by hash; proving that the shipped APK
carries the 14 pinned producer libraries, the overlaid assets and the bound
editor/Linux payloads remains the release readback
(``prepare-stage-release.py`` with the Office pins gate + Main's final
verification), not this tool. It also makes no reproducible-build or
third-party attestation claim; the producer binding is the publisher's own
build-id/commit mechanism.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import re
import sys
import tarfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple

TOOL_NAME = "produce-office-corresponding-source"
# 1.0.0: first release; wraps the proven Linux/IDE combined CCS output
# byte-exact and adds the pinned Office engine public group.
# 1.0.1: layout refresh for the current frozen public source. The Office
# engine tree added core/officeengine/tools/test_writer_viewport_sync.js, the
# deterministic public-safe semantic check for the shipped
# floe-writer-viewport-sync.js overlay; the exact-layout enumeration names it
# and the rendered README tree line describes it. No assertion, scan, deny
# list, redaction or binding logic was otherwise changed.
TOOL_VERSION = "1.0.1"
SCHEMA_VERSION = 1

EPOCH_MTIME = 0
MAX_TEXT_BYTES = 2 * 1024 * 1024
MAX_BINARY_MEMBER_BYTES = 8 * 1024 * 1024
MAX_TOTAL_BYTES = 64 * 1024 * 1024

# ---- embedded (unchanged) Linux/IDE combined tool expectations --------------
INNER_TOOL_NAME = "assemble-android-corresponding-source"
INNER_TOOL_MIN_VERSION = (1, 0, 0)
INNER_TAR_FMT = "floe-android-corresponding-source-{version}.tar.gz"

# ---- pinned Office producer identity (immutable, exact) ---------------------
UPSTREAM_REVISION = "2333344185931274f9c49d6c12a408cefcef6844"
UPSTREAM_REPOSITORY = "https://gerrit.collaboraoffice.com/online"
UPSTREAM_MIRROR = "https://github.com/CollaboraOnline/online.mirror"
UPSTREAM_COMMIT_TREE_URL = f"{UPSTREAM_MIRROR}/tree/{UPSTREAM_REVISION}"
UPSTREAM_COMMIT_ARCHIVE_URL = (
    f"https://codeload.github.com/CollaboraOnline/online.mirror/tar.gz/"
    f"{UPSTREAM_REVISION}")
UPSTREAM_RECIPE_URL = (
    f"{UPSTREAM_MIRROR}/blob/{UPSTREAM_REVISION}/android/README.md")
UPSTREAM_DOWNLOAD_LST_URL = (
    f"https://raw.githubusercontent.com/CollaboraOnline/online.mirror/"
    f"{UPSTREAM_REVISION}/engine/download.lst")
PRODUCER_APK_URL = (
    "https://www.collaboraoffice.com/downloads/fdroid/repo/"
    "collabora-office-mobile-26.04.4.2-937-release-arm64-v8a-2026-10-05.apk")
PRODUCER_APK_FILE = ("collabora-office-mobile-26.04.4.2-937-release-"
                     "arm64-v8a-2026-10-05.apk")
PRODUCER_APK_SHA256 = ("79e72f810d711706d205a9ff457b4bb830c607a2b988cf4"
                       "4246829ec4593c393")
PRODUCER_SIGNER_CERT_SHA256 = ("573258c84e149b5f4d9299e7434b2b69a8410372"
                               "921d4ae586ba91ec767892cc")
PRODUCER_VERSION_NAME = "26.04.4.2"
PRODUCER_VERSION_CODE = 937
PRODUCER_ABI = "arm64-v8a"
PINS_SCHEMA = "floe-office-payload-pins/1"
MANIFEST_SCHEMA = "floe-office-producer-manifest/1"
OVERLAYS_SCHEMA = 1
SOURCE_INDEX_SCHEMA = "floe-office-notice-source-index/2"
EMBEDDED_BUILD_ID = UPSTREAM_REVISION[:10]

# The 14 producer native libraries Floe packages (official libc++_shared.so
# is deliberately excluded; Floe ships its own pinned runtime copy).
OFFICE_PINNED_LIBRARIES = sorted([
    "libandroidapp.so", "libfreebl3.so", "liblo-native-code.so",
    "libnspr4.so", "libnss3.so", "libnssckbi.so", "libnssdbm3.so",
    "libnssutil3.so", "libplc4.so", "libplds4.so", "libsmime3.so",
    "libsoftokn3.so", "libsqlite3.so", "libssl3.so",
], key=lambda s: s.encode("utf-8"))
LIBCXX_NAME = "libc++_shared.so"

# Module layout authority for the frozen source directory.
ROOT_DOCS = sorted(["PROVENANCE.md", "asset-overlays.json", "build.gradle.kts",
                    "consumer-rules.pro", "payload-pins.json",
                    "producer-manifest.json"])
TOOLS_FILES = sorted(["tools/README.md", "tools/prepare_payload.py",
                      "tools/test_writer_viewport_sync.js"])
# Files present in the module tree that are NOT part of the public offer:
# host integration notes (contain host-local paths) and the developer-side
# witness harness (references a private contract document).
LOCAL_ONLY_FILES = {
    "README.md": ("host integration notes with host-local build paths; not "
                  "offer material (PROVENANCE.md is the public document)"),
    "tools/test_renderer_witness.js": ("developer-side node harness naming a "
                                       "private qualification contract; the "
                                       "shipped witness source itself is "
                                       "included under office/src/"),
}
UPSTREAM_NOTICE_HOSTS = sorted([
    "src/main/java/org/libreoffice/androidlib/COWebView.kt",
    "src/main/java/org/libreoffice/androidlib/COWebViewClient.kt",
    "src/main/java/org/libreoffice/androidlib/LOActivity.kt",
    "src/main/java/org/libreoffice/androidlib/MobileSocket.kt",
], key=lambda s: s.encode("utf-8"))
TEXT_EXT = {".kt", ".java", ".xml", ".js", ".pro", ".kts", ".md", ".json",
            ".py", ".html", ".css", ".svg", ".xcd", ".txt"}
OVERLAY_PREFIXES = ("dist/", "share/", "notices/", "dexopt/")

# Exact deterministic redactions applied to public renderings. Each rule is
# applied only when its old fragment is present (so a future already-clean
# upstream revision still passes); any forbidden fragment surviving every
# rule is fatal.
README_REDACTIONS = (
    ("`Local/Private/android-toolchains/android-sdk/build-tools/*/apksigner`",
     "`the local Android SDK build-tools directory`"),
)
PINS_REDACTIONS = (("payload", "stagedBy"),)

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
VERSION_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$")
REPOSITORY_RE = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$")
SAFE_REL = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9._+-]*(?:/[A-Za-z0-9][A-Za-z0-9._+-]*)*$")

DENY_NAME = re.compile(
    r"(?i)(^|[/._\-\s])(keystore|jks|p12|pfx|pem|secret|token|credential|"
    r"password|passwd|apikey|private|keychain|evidence)([/._\-\s]|$)"
    r"|\.(jks|keystore|p12|pfx|pem|log|bak)$"
    r"|(^|/)\.env($|/)|(^|/)local\.properties$|(^|/)id_(rsa|ed25519)($|\.)"
)
DENY_CONTENT = (b"PRIVATE KEY", b"BEGIN OPENSSH", b"BEGIN EC PRIVATE")
# Generated / included text must never carry private operational locations.
LEAK_FORBIDDEN = (
    "/Users/", "/Volumes/", "Local/Private", "Local/Artifacts",
    "jiangnangenius", "TECLAST", "Caches/CodexBuild",
)

ARCHIVE_ROOT_FMT = "floe-android-corresponding-source-{version}"
ARCHIVE_NAME_FMT = "floe-android-corresponding-source-{version}.tar.gz"
APK_NAME_FMT = "Floe-Android-{version}-full-arm64-v8a.apk"
RELEASE_URL_FMT = ("https://github.com/{repo}/releases/download/"
                   "android/v{version}/{archive}")


class OfficeSourceError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_input_file(path: Path, what: str) -> None:
    if path.is_symlink():
        raise OfficeSourceError(f"{what} {path} is a symlink (inputs must be material files)")
    if not path.is_file():
        raise OfficeSourceError(f"{what} missing or not a regular file: {path}")


def read_raw(path: Path, limit: int, what: str) -> bytes:
    require_input_file(path, what)
    try:
        size = path.stat().st_size
    except OSError as exc:
        raise OfficeSourceError(f"cannot stat {what}: {exc}") from exc
    if size > limit:
        raise OfficeSourceError(f"{what} is {size} bytes, above the {limit}-byte limit")
    return path.read_bytes()


def scan_text(text: str, what: str) -> None:
    for frag in LEAK_FORBIDDEN:
        if frag in text:
            raise OfficeSourceError(
                f"{what} contains private operational path fragment {frag!r}; "
                "public offer inputs must be free of host-local locations")


def text_or_reject(path: Path, what: str) -> bytes:
    if DENY_NAME.search(Path(path).name):
        raise OfficeSourceError(f"{what} name {path.name!r} matches the credential deny list")
    data = read_raw(path, MAX_TEXT_BYTES, what)
    if b"\x00" in data:
        raise OfficeSourceError(f"{what} is not a text file (NUL byte present)")
    for marker in DENY_CONTENT:
        if marker in data:
            raise OfficeSourceError(f"{what} contains rejected material {marker!r}")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise OfficeSourceError(f"{what} is not valid UTF-8 text") from exc
    scan_text(text, what)
    return data


def safe_rel(name: str, what: str, credential_scan: bool = True) -> None:
    if (SAFE_REL.match(name) is None or ".." in name.split("/")
            or name.startswith("/") or "\\" in name
            or any(part == "" for part in name.split("/"))):
        raise OfficeSourceError(f"{what} path {name!r} is not a safe relative archive path")
    if credential_scan and DENY_NAME.search(name):
        raise OfficeSourceError(f"{what} path {name!r} matches the credential/evidence deny list")


def parse_version(text: str, what: str) -> Tuple[int, ...]:
    parts = text.split(".")
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        raise OfficeSourceError(f"{what} version {text!r} is not a numeric X.Y.Z triple")
    return tuple(int(p) for p in parts)


def require(cond: bool, name: str, checks: List[Dict[str, object]], error: str,
            detail: object = None) -> None:
    if not cond:
        raise OfficeSourceError(error)
    checks.append({"id": name, "ok": True, "detail": detail})


def load_json_text(data: bytes, what: str) -> Dict[str, object]:
    try:
        obj = json.loads(data.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise OfficeSourceError(f"{what} is not valid JSON: {exc}") from exc
    if not isinstance(obj, dict):
        raise OfficeSourceError(f"{what} must be a JSON object")
    return obj


def is_sha(value: object) -> bool:
    return isinstance(value, str) and SHA256_RE.match(value) is not None


# ---------------------------------------------------------------------------
# embedded Linux/IDE combined generation
# ---------------------------------------------------------------------------

def verify_combined(args: argparse.Namespace, version: str, commit: str,
                    checks: List[Dict[str, object]],
                    files: Dict[str, Tuple[bytes, int]]) -> Dict[str, object]:
    root = Path(args.combined_ccs_dir)
    if not root.is_dir() or root.is_symlink():
        raise OfficeSourceError(f"--combined-ccs-dir must be a real directory: {root}")
    stray = sorted(p.name for p in root.iterdir()
                   if p.is_file() and p.name not in
                   (INNER_TAR_FMT.format(version=version), "MANIFEST.json", "SHA256SUMS"))
    require(not stray, "combined-dir-exact", checks,
            f"combined CCS directory carries unexpected files {stray}; pass the "
            "exact produce output directory (symlinks refused too)", stray)
    for p in root.iterdir():
        if not p.is_file():
            raise OfficeSourceError(f"combined CCS directory member {p.name} is not a regular file")
    inner_tar_name = INNER_TAR_FMT.format(version=version)
    tar_bytes = read_raw(root / inner_tar_name, MAX_BINARY_MEMBER_BYTES * 8,
                         "combined Linux/IDE archive")
    man_bytes = text_or_reject(root / "MANIFEST.json", "combined Linux/IDE MANIFEST.json")
    sums_bytes = text_or_reject(root / "SHA256SUMS", "combined Linux/IDE SHA256SUMS")

    lines = [ln for ln in sums_bytes.decode("utf-8").splitlines() if ln.strip()]
    sums: Dict[str, str] = {}
    for ln in lines:
        parts = ln.split()
        if len(parts) != 2 or not SHA256_RE.match(parts[0]):
            raise OfficeSourceError(f"combined SHA256SUMS line malformed: {ln!r}")
        sums[parts[1]] = parts[0]
    if set(sums) != {inner_tar_name, "MANIFEST.json"}:
        raise OfficeSourceError(
            f"combined SHA256SUMS covers {sorted(sums)}, expected exactly "
            f"{sorted([inner_tar_name, 'MANIFEST.json'])}")
    if sha256_bytes(tar_bytes) != sums[inner_tar_name]:
        raise OfficeSourceError("combined archive bytes do not match its SHA256SUMS entry")
    if sha256_bytes(man_bytes) != sums["MANIFEST.json"]:
        raise OfficeSourceError("combined MANIFEST.json bytes do not match its SHA256SUMS entry")

    man = load_json_text(man_bytes, "combined Linux/IDE MANIFEST.json")
    tool = man.get("tool") or {}
    if tool.get("name") != INNER_TOOL_NAME:
        raise OfficeSourceError(
            f"combined CCS tool is {tool.get('name')!r}, expected {INNER_TOOL_NAME!r}")
    inner_ver = parse_version(str(tool.get("version", "")), "combined CCS tool")
    if inner_ver < INNER_TOOL_MIN_VERSION:
        raise OfficeSourceError(
            f"combined CCS tool version {tool.get('version')} is below the proven "
            f"{'.'.join(map(str, INNER_TOOL_MIN_VERSION))} baseline")
    if man.get("releaseVersion") != version:
        raise OfficeSourceError(
            f"combined CCS releaseVersion {man.get('releaseVersion')!r} != "
            f"--release-version {version!r}; regenerate the Linux/IDE offer against "
            "the final release inputs (stale-generation offers are refused)")
    if man.get("sourceCommit") != commit:
        raise OfficeSourceError(
            f"combined CCS sourceCommit {man.get('sourceCommit')!r} != "
            f"--source-commit {commit!r}; the Linux/IDE offer must be regenerated "
            "against the FINAL immutable freeze commit before this assembly "
            "(fail-closed)")
    rel_apk = (man.get("offer") or {}).get("releaseApk") or {}
    if (rel_apk.get("name"), rel_apk.get("sha256")) != (args.apk_name, args.apk_sha256):
        raise OfficeSourceError(
            f"combined CCS release APK binding {rel_apk!r} does not match "
            f"--apk-name/--apk-sha256; the Linux/IDE generation and the Office "
            "group must describe the ONE final signed APK")
    for section in ("linuxRuntime", "soraEditor"):
        if not isinstance(man.get(section), dict):
            raise OfficeSourceError(
                f"combined CCS MANIFEST lacks the {section!r} block; this offer "
                "must carry the complete Linux/IDE generation plus Office, never "
                "a partial archive")
    inner_files = man.get("files")
    if not isinstance(inner_files, list) or not inner_files:
        raise OfficeSourceError("combined CCS MANIFEST.json has no files list")
    for entry in inner_files:
        safe_rel(str(entry.get("path", "")), f"combined CCS member {entry.get('path')!r}")

    root_prefix = ARCHIVE_ROOT_FMT.format(version=version)
    try:
        with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:gz") as tar:
            members = tar.getmembers()
    except (tarfile.TarError, OSError, EOFError) as exc:
        raise OfficeSourceError(f"combined archive is not a readable gzip tar: {exc}") from exc
    seen = set()
    for m in members:
        name = m.name.rstrip("/")
        seen.add(name)
        if name != root_prefix and not name.startswith(root_prefix + "/"):
            raise OfficeSourceError(
                f"combined member {m.name!r} escapes the expected root prefix "
                f"{root_prefix!r}")
        rel = name[len(root_prefix) + 1:]
        if rel and SAFE_REL.match(rel) is None:
            raise OfficeSourceError(f"combined member path unsafe: {m.name!r}")
        if not (m.isfile() or m.isdir()):
            raise OfficeSourceError(
                f"combined member {m.name!r} is a {m.type!r} special entry; "
                "symlinks/hardlinks/devices are refused in the public offer")
    expected_inner = {f"{root_prefix}/{e['path']}" for e in inner_files} | {root_prefix}
    if not expected_inner <= seen:
        raise OfficeSourceError(
            f"combined tar is missing members relative to its MANIFEST: "
            f"{sorted(expected_inner - seen)[:8]}")

    files[f"linux-ide/{inner_tar_name}"] = (tar_bytes, 0o644)
    files["linux-ide/MANIFEST.json"] = (man_bytes, 0o644)
    files["linux-ide/SHA256SUMS"] = (sums_bytes, 0o644)
    require(True, "linux-ide-embedded", checks, "", {
        "archive": f"linux-ide/{inner_tar_name}",
        "archiveSha256": sums[inner_tar_name], "archiveBytes": len(tar_bytes),
        "manifestSha256": sums["MANIFEST.json"],
        "toolVersion": tool.get("version"),
    })
    return {"tool": dict(tool), "tarName": inner_tar_name,
            "tarSha256": sums[inner_tar_name], "tarBytes": len(tar_bytes),
            "manifestSha256": sums["MANIFEST.json"],
            "sumsBytes": sums_bytes.decode("utf-8")}


# ---------------------------------------------------------------------------
# Office engine public group
# ---------------------------------------------------------------------------

def collect_office_tree(base: Path, checks: List[Dict[str, object]]
                        ) -> Dict[str, bytes]:
    """Enumerate the frozen module tree and enforce the exact public layout.
    Returns {module-relative-path: bytes} for every non-local-only file."""
    if not base.is_dir() or base.is_symlink():
        raise OfficeSourceError(f"--office-source-dir must be a real directory: {base}")
    found: Dict[str, bytes] = {}
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        if any(os.path.islink(os.path.join(dirpath, d)) for d in dirnames):
            raise OfficeSourceError(f"office source tree contains a symlink directory under {dirpath}")
        for fn in sorted(filenames):
            p = Path(dirpath) / fn
            rel = str(p.relative_to(base))
            if p.is_symlink():
                raise OfficeSourceError(f"office source file {rel} is a symlink")
            safe_rel(rel, "office source file")
            suffix = Path(rel).suffix.lower()
            if suffix not in TEXT_EXT:
                raise OfficeSourceError(
                    f"office source file {rel} has unexpected type {suffix!r}; "
                    "the public Office group carries source/manifest/notices only")
            found[rel] = read_raw(p, MAX_TEXT_BYTES, f"office source file {rel}")
    unexpected = sorted(set(found) - set(ROOT_DOCS) - set(TOOLS_FILES)
                        - {r for r in found if r.startswith("overlays/")}
                        - {r for r in found if r.startswith("src/")}
                        - set(LOCAL_ONLY_FILES))
    require(not unexpected, "office-layout-root", checks,
            f"unexpected files at the office module root: {unexpected}", unexpected)
    missing = [d for d in ROOT_DOCS + TOOLS_FILES if d not in found]
    require(not missing, "office-required-files", checks,
            f"office module is missing required public files {missing}", missing)
    for rel in found:
        if b"\x00" in found[rel]:
            raise OfficeSourceError(f"office source file {rel} contains NUL bytes")
        try:
            found[rel].decode("utf-8")
        except UnicodeDecodeError as exc:
            raise OfficeSourceError(f"office source file {rel} is not valid UTF-8") from exc
        if any(m in found[rel] for m in DENY_CONTENT):
            raise OfficeSourceError(f"office source file {rel} contains rejected key material")
        if DENY_NAME.search(Path(rel).name):
            raise OfficeSourceError(f"office source file {rel} matches the credential deny list")
    return found


def validate_pins(pins_raw: bytes, manifest_raw: bytes, checks: List[Dict[str, object]]
                  ) -> Dict[str, object]:
    pins = load_json_text(pins_raw, "payload-pins.json")
    manifest = load_json_text(manifest_raw, "producer-manifest.json")
    require(pins.get("schema") == PINS_SCHEMA, "pins-schema", checks,
            f"pins schema {pins.get('schema')!r} != {PINS_SCHEMA!r}")
    src = pins.get("source") or {}
    require(src.get("revision") == UPSTREAM_REVISION, "pins-revision", checks,
            f"pins source.revision {src.get('revision')!r} is not the pinned "
            f"upstream monorepo revision {UPSTREAM_REVISION}")
    require(src.get("repository") == UPSTREAM_REPOSITORY, "pins-upstream-repository", checks,
            f"pins source.repository {src.get('repository')!r} != {UPSTREAM_REPOSITORY!r}")
    require(src.get("apkVersion") == PRODUCER_VERSION_NAME
            and src.get("apkCode") == PRODUCER_VERSION_CODE,
            "pins-producer-version", checks,
            f"pins producer version {src.get('apkVersion')}/{src.get('apkCode')} != "
            f"{PRODUCER_VERSION_NAME}/{PRODUCER_VERSION_CODE}")
    require(src.get("embeddedBuildId") == EMBEDDED_BUILD_ID, "pins-buildid", checks,
            f"pins embeddedBuildId {src.get('embeddedBuildId')!r} != the first 10 "
            f"hex of the pinned revision ({EMBEDDED_BUILD_ID})")
    art = pins.get("artifact") or {}
    require(art.get("url") == PRODUCER_APK_URL and art.get("sha256") == PRODUCER_APK_SHA256
            and art.get("signerCertSha256") == PRODUCER_SIGNER_CERT_SHA256,
            "pins-producer-artifact", checks,
            f"pins artifact identity {art.get('url')}@{art.get('sha256')}/{art.get('signerCertSha256')} "
            "does not match the pinned official producer APK/signer constants")
    payload = pins.get("payload") or {}
    require(payload.get("manifestSha256") == sha256_bytes(manifest_raw),
            "pins-manifest-digest", checks,
            f"pins payload.manifestSha256 {payload.get('manifestSha256')} != the actual "
            f"producer-manifest.json bytes hash {sha256_bytes(manifest_raw)}; the manifest "
            "must be the exact pinned generation")
    require(isinstance(payload.get("files"), int) and payload["files"] == len(manifest.get("files") or {}),
            "pins-file-count", checks,
            f"pins files {payload.get('files')} != manifest records {len(manifest.get('files') or {})}")
    require(isinstance(payload.get("selectedBytes"), int)
            and payload["selectedBytes"] == manifest.get("selectedBytes"),
            "pins-selected-bytes", checks,
            f"pins selectedBytes {payload.get('selectedBytes')} != manifest {manifest.get('selectedBytes')}")
    require(payload.get("nativeLibraries") == 15 and payload.get("arm64And16KiBAligned") is True,
            "pins-native-policy", checks,
            f"pins nativeLibraries {payload.get('nativeLibraries')!r} must be 15 and "
            f"arm64And16KiBAligned must be true, got {payload.get('arm64And16KiBAligned')!r}")
    libs = pins.get("libraries") or {}
    require(sorted(libs, key=lambda s: s.encode("utf-8")) == OFFICE_PINNED_LIBRARIES,
            "pins-library-set", checks,
            f"pins libraries {sorted(libs)} must be exactly the 14 packaged producer "
            f"libraries {OFFICE_PINNED_LIBRARIES} (official {LIBCXX_NAME} is excluded)")
    mfiles = manifest.get("files") or {}
    for name, sha in libs.items():
        rec = mfiles.get(f"lib/{PRODUCER_ABI}/{name}")
        require(isinstance(rec, dict) and rec.get("sha256") == sha and is_sha(sha),
                "pins-library-hashes", checks,
                f"pins library {name} sha {sha!r} != producer-manifest record {rec!r}")
    pol = pins.get("libcxxPolicy") or {}
    official = (mfiles.get(f"lib/{PRODUCER_ABI}/{LIBCXX_NAME}") or {}).get("sha256")
    require(pol.get("packaged") is False and pol.get("officialSha256") == official
            and is_sha(pol.get("appOwnSha256")),
            "pins-libcxx-exclusion", checks,
            f"pins libcxxPolicy {pol!r} must keep packaged=false and pin the official "
            f"{LIBCXX_NAME} manifest hash {official!r} as the excluded copy")
    anchors = pins.get("anchorAssets") or {}
    require(bool(anchors), "pins-anchor-assets", checks, "pins anchorAssets is empty")
    for rel, sha in anchors.items():
        rec = mfiles.get(f"assets/{rel}")
        require(isinstance(rec, dict) and rec.get("sha256") == sha and is_sha(sha),
                "pins-anchor-hashes", checks,
                f"pins anchor asset {rel} sha {sha!r} != manifest record {rec!r}")
    return pins


def validate_manifest(manifest_raw: bytes, checks: List[Dict[str, object]]
                      ) -> Dict[str, object]:
    manifest = load_json_text(manifest_raw, "producer-manifest.json")
    require(manifest.get("schema") == MANIFEST_SCHEMA, "manifest-schema", checks,
            f"producer-manifest.json schema {manifest.get('schema')!r} != "
            f"{MANIFEST_SCHEMA!r}")
    msrc = manifest.get("source") or {}
    mart = manifest.get("artifact") or {}
    require(msrc.get("revision") == UPSTREAM_REVISION
            and msrc.get("repository") == UPSTREAM_REPOSITORY
            and msrc.get("version") == PRODUCER_VERSION_NAME
            and mart.get("url") == PRODUCER_APK_URL
            and mart.get("sha256") == PRODUCER_APK_SHA256
            and mart.get("signerSha256") == PRODUCER_SIGNER_CERT_SHA256,
            "manifest-identity", checks,
            f"producer-manifest identity {msrc.get('repository')}@{msrc.get('revision')} "
            f"{msrc.get('version')} / {mart.get('url')}@{mart.get('sha256')} does not "
            "match the pinned producer constants")
    require(manifest.get("actualArm64And16K") is True, "manifest-arm64-16k", checks,
            "producer-manifest actualArm64And16K is not true")
    files = manifest.get("files")
    require(isinstance(files, dict) and files, "manifest-files", checks,
            "producer-manifest files must be a non-empty object")
    total = 0
    for rel, rec in files.items():
        # These are the producer payload's own paths (recorded, never embedded
        # as members here); the credential deny list applies to this archive's
        # members, so enumerate-record scanning is path-safety only.
        safe_rel(rel, "manifest file record", credential_scan=False)
        if not (rel.startswith("assets/") or rel.startswith(f"lib/{PRODUCER_ABI}/")):
            raise OfficeSourceError(
                f"manifest record {rel!r} is outside the payload layout "
                "(assets/ or lib/arm64-v8a/ prefixes only)")
        if not (isinstance(rec, dict) and isinstance(rec.get("bytes"), int)
                and not isinstance(rec.get("bytes"), bool) and rec["bytes"] >= 0
                and is_sha(rec.get("sha256"))):
            raise OfficeSourceError(f"manifest record {rel!r} is malformed: {rec!r}")
        total += rec["bytes"]
    require(total == manifest.get("selectedBytes")
            and len(files) == manifest.get("selectedFiles"),
            "manifest-counts", checks,
            f"manifest files sum {total}/{len(files)} != selectedBytes/selectedFiles "
            f"{manifest.get('selectedBytes')}/{manifest.get('selectedFiles')}")
    lib_names = sorted(rel.rsplit("/", 1)[-1] for rel in files
                       if rel.startswith(f"lib/{PRODUCER_ABI}/"))
    require(LIBCXX_NAME in lib_names and len(lib_names) == 15,
            "manifest-library-set", checks,
            f"manifest native libraries {lib_names} must be the 14 packaged plus the "
            f"pinned-but-excluded {LIBCXX_NAME}")
    scan_text(manifest_raw.decode("utf-8"), "producer-manifest.json")
    return manifest


def validate_overlays(overlays_raw: bytes, manifest: Dict[str, object],
                      tree: Dict[str, bytes], version: str, repository: str,
                      checks: List[Dict[str, object]]
                      ) -> Dict[str, object]:
    overlays = load_json_text(overlays_raw, "asset-overlays.json")
    require(overlays.get("schema") == OVERLAYS_SCHEMA, "overlays-schema", checks,
            f"asset-overlays.json schema {overlays.get('schema')!r} != {OVERLAYS_SCHEMA}")
    require(overlays.get("producerSource") == UPSTREAM_REVISION, "overlays-producer-source",
            checks, f"asset-overlays producerSource {overlays.get('producerSource')!r} "
            "is not the pinned upstream revision")
    entries = overlays.get("entries")
    require(isinstance(entries, list) and entries, "overlays-entries", checks,
            "asset-overlays.json has no entries")
    mfiles = manifest["files"]
    sources_seen: List[str] = []
    for e in entries:
        op, dest = e.get("operation"), e.get("destination")
        # Overlay destinations name producer payload paths (additionally some
        # Floe additions); path safety only — the credential deny list guards
        # the members this archive actually embeds.
        safe_rel(str(dest), "overlay destination", credential_scan=False)
        if not str(dest).startswith(OVERLAY_PREFIXES):
            raise OfficeSourceError(
                f"overlay destination {dest!r} is outside the payload overlay scope "
                f"{OVERLAY_PREFIXES}")
        if op not in ("add", "remove", "replace"):
            raise OfficeSourceError(f"overlay operation {op!r} is not add/remove/replace")
        if not isinstance(e.get("reason"), str) or not e["reason"].strip():
            raise OfficeSourceError(f"overlay entry for {dest} lacks a recorded reason")
        if op in ("add", "replace") and e.get("source") != dest:
            raise OfficeSourceError(
                f"overlay {op} for {dest} names source {e.get('source')!r}; the "
                "module convention is source == destination (one overlay file per "
                "transformed payload path), enforced fail-closed")
        rec = mfiles.get(f"assets/{dest}")
        if op == "add":
            if e.get("originalSha256") is not None or rec is not None:
                raise OfficeSourceError(
                    f"overlay add for {dest} must not carry an original and the "
                    "producer manifest must not already contain the destination")
            src_rel = f"overlays/{e.get('source')}"
            blob = tree.get(src_rel)
            if blob is None or sha256_bytes(blob) != e.get("sha256"):
                raise OfficeSourceError(
                    f"overlay add {dest}: file {src_rel} missing or hashes to "
                    f"{sha256_bytes(blob) if blob is not None else None} != recorded {e.get('sha256')}")
            sources_seen.append(src_rel)
        elif op == "remove":
            if e.get("source") is not None or e.get("sha256") is not None:
                raise OfficeSourceError(
                    f"overlay remove for {dest} must not carry source/new hash fields")
            if not is_sha(e.get("originalSha256")) or not rec \
                    or rec["sha256"] != e["originalSha256"]:
                raise OfficeSourceError(
                    f"overlay remove {dest}: originalSha256 {e.get('originalSha256')!r} does not "
                    f"match the producer manifest record {rec!r}")
        else:  # replace
            if not is_sha(e.get("originalSha256")) or not is_sha(e.get("sha256")):
                raise OfficeSourceError(f"overlay replace {dest} lacks exact original/new hashes")
            if not rec or rec["sha256"] != e["originalSha256"]:
                raise OfficeSourceError(
                    f"overlay replace {dest}: originalSha256 {e['originalSha256']!r} does not "
                    f"match the producer manifest record {rec['sha256']!r}")
            src_rel = f"overlays/{e.get('source')}"
            blob = tree.get(src_rel)
            if blob is None or sha256_bytes(blob) != e["sha256"]:
                raise OfficeSourceError(
                    f"overlay replace {dest}: file {src_rel} missing or hashes to "
                    f"{sha256_bytes(blob) if blob is not None else None} != recorded {e['sha256']}")
            sources_seen.append(src_rel)
        if "license" in e and not isinstance(e["license"], str):
            raise OfficeSourceError(f"overlay entry for {dest} has a non-string license")
    overlay_files = {rel for rel in tree if rel.startswith("overlays/")}
    require(set(sources_seen) == overlay_files, "overlay-file-set-equality", checks,
            f"overlay tree and manifest disagree; tree-only "
            f"{sorted(overlay_files - set(sources_seen))}, manifest-only "
            f"{sorted(set(sources_seen) - overlay_files)}")
    for rel in overlay_files:
        text = tree[rel].decode("utf-8")
        scan_text(text, rel)
        if "All Rights Reserved" in text:
            raise OfficeSourceError(
                f"overlay file {rel} still carries an All-Rights-Reserved branding "
                "marker; the public group ships only the Floe neutral replacements")
        if rel.startswith("overlays/share/") or rel.startswith("overlays/dist/"):
            if "SPDX-License-Identifier: MPL-2.0" not in text:
                raise OfficeSourceError(
                    f"overlay file {rel} lacks the MPL-2.0 SPDX marker")
    sa = overlays.get("sourceAccess") or {}
    expected_tag = f"android/v{version}"
    expected_url = RELEASE_URL_FMT.format(repo=repository, version=version,
                                          archive=ARCHIVE_NAME_FMT.format(version=version))
    require(sa.get("tag") == expected_tag, "overlays-release-tag", checks,
            f"asset-overlays sourceAccess.tag {sa.get('tag')!r} != {expected_tag!r}; "
            "the overlay manifest must name THIS release (fail-closed on any "
            "stale or borrowed release binding)")
    require(sa.get("archiveUrl") == expected_url, "overlays-archive-url", checks,
            f"asset-overlays archiveUrl {sa.get('archiveUrl')!r} != the public "
            f"release archive URL {expected_url!r}")
    require(sa.get("nativeSource") == UPSTREAM_COMMIT_TREE_URL,
            "overlays-native-source", checks,
            f"asset-overlays nativeSource {sa.get('nativeSource')!r} != the pinned "
            f"commit tree URL {UPSTREAM_COMMIT_TREE_URL!r}")
    require(sa.get("privatePathsExcluded") is True, "overlays-private-exclusion", checks,
            "asset-overlays sourceAccess.privatePathsExcluded is not true")
    return overlays


def validate_notice_index(notice_raw: bytes, overlays: Dict[str, object],
                          pins: Dict[str, object], tree: Dict[str, bytes],
                          version: str, repository: str,
                          checks: List[Dict[str, object]]) -> Dict[str, object]:
    index = load_json_text(notice_raw, "overlays/notices/source-index.json")
    require(index.get("schema") == SOURCE_INDEX_SCHEMA, "notice-index-schema", checks,
            f"source-index schema {index.get('schema')!r} != {SOURCE_INDEX_SCHEMA!r}")
    require(index.get("license") == "MPL-2.0", "notice-index-license", checks,
            f"source-index license {index.get('license')!r} != MPL-2.0")
    pi = index.get("payloadIdentity") or {}
    ppins_art = pins.get("artifact") or {}
    psrc = pins.get("source") or {}
    require(pi.get("apkSha256") == ppins_art.get("sha256") == PRODUCER_APK_SHA256
            and pi.get("signerCertSha256") == ppins_art.get("signerCertSha256")
            == PRODUCER_SIGNER_CERT_SHA256
            and pi.get("apkUrl") == PRODUCER_APK_URL
            and pi.get("apkFile") == PRODUCER_APK_FILE
            and pi.get("versionName") == PRODUCER_VERSION_NAME
            and pi.get("versionCode") == PRODUCER_VERSION_CODE
            and pi.get("abi") == PRODUCER_ABI,
            "notice-index-payload-identity", checks,
            f"source-index payloadIdentity does not match the pinned producer identity")
    sb = index.get("sourceBinding") or {}
    require(sb.get("revision") == UPSTREAM_REVISION
            and sb.get("primaryRepository") == UPSTREAM_REPOSITORY
            and sb.get("officialMirror") == UPSTREAM_MIRROR
            and sb.get("monorepo") is True,
            "notice-index-source-binding", checks,
            "source-index sourceBinding does not match the pinned upstream monorepo")
    ent = (overlays.get("entries") or [])
    fo = index.get("floeOverlay") or {}
    require(fo.get("operationCount") == len(ent), "notice-index-operation-count", checks,
            f"source-index floeOverlay.operationCount {fo.get('operationCount')} != "
            f"asset-overlays entries {len(ent)}")
    recs = fo.get("sourceFileRecords")
    require(isinstance(recs, list), "notice-index-records", checks,
            "source-index floeOverlay.sourceFileRecords is not a list")
    own = "notices/source-index.json"
    by_dest = {e["destination"]: e for e in ent}
    self_entries = [e for e in ent if e["destination"] == own]
    require(len(self_entries) == 1, "notice-index-self-record-single", checks,
            f"asset-overlays must carry exactly one add record for {own}, got "
            f"{len(self_entries)}")
    require(sha256_bytes(notice_raw) == self_entries[0]["sha256"],
            "notice-index-self-hash", checks,
            f"source-index bytes hash {sha256_bytes(notice_raw)} != the overlay add "
            f"record {self_entries[0]['sha256']}; the index binds its own digest "
            "through the overlay manifest (no cycle)")
    expected_records = [d for d in by_dest if d != own]
    require(len(recs) == len(expected_records), "notice-index-records-count", checks,
            f"source-index records {len(recs)} != overlay entries minus self "
            f"{len(expected_records)}")
    for r in recs:
        e = by_dest.get(r.get("path"))
        require(e is not None and r.get("operation") == e["operation"]
                and r.get("originalSha256") == e.get("originalSha256")
                and r.get("newSha256") == e.get("sha256"),
                "notice-index-records-match", checks,
                f"source-index record {r!r} does not match the overlay entry {e!r}")
    np_ = index.get("noticePage") or {}
    html = tree.get("overlays/notices/index.html")
    require(np_.get("path") == "notices/index.html" and html is not None
            and np_.get("sha256") == sha256_bytes(html),
            "notice-index-notice-page", checks,
            "source-index noticePage digest does not match the actual notice html")
    html_text = html.decode("utf-8") if html is not None else ""
    require(UPSTREAM_REVISION in html_text, "notice-page-links-upstream", checks,
            "the notice page does not link the pinned upstream revision")
    require("<script" not in html_text.lower(), "notice-page-no-script", checks,
            "the in-app notice page must be a static page with no script")
    bon = index.get("bundledOriginalNotices") or {}
    anchors = pins.get("anchorAssets") or {}
    for name in ("license.html", "notice.txt"):
        rec = bon.get(name) or {}
        require(is_sha(rec.get("sha256")) and rec.get("sha256") == anchors.get(name)
                and rec.get("modified") is False,
                "notice-original-notices", checks,
                f"source-index bundledOriginalNotices[{name}] {rec!r} does not bind "
                f"the unchanged original anchor hash {anchors.get(name)!r}")
    fcs = index.get("floeCorrespondingSource") or {}
    expected_url = RELEASE_URL_FMT.format(repo=repository, version=version,
                                          archive=ARCHIVE_NAME_FMT.format(version=version))
    require(fcs.get("status") == "release-source-links"
            and fcs.get("tag") == f"android/v{version}"
            and fcs.get("archiveUrl") == expected_url
            and fcs.get("sourceRoot") == "FloeAndroid/core/officeengine",
            "notice-index-release-binding", checks,
            f"source-index floeCorrespondingSource {fcs!r} does not bind this "
            f"release's tag/archive URL {expected_url!r}")
    ep = index.get("externalPins") or {}
    require(ep.get("recipe") == "engine/download.lst"
            and ep.get("recipeUrl") == UPSTREAM_DOWNLOAD_LST_URL
            and is_sha(ep.get("recipeSha256"))
            and UPSTREAM_REVISION in str(ep.get("fetchRecipeUrl")),
            "notice-index-external-pins", checks,
            "source-index externalPins do not bind the pinned download.lst recipe")
    scan_text(notice_raw.decode("utf-8"), "source-index.json")
    scan_text(html_text, "notice page")
    return index


def render_public_pins(pins_raw: bytes, checks: List[Dict[str, object]]
                      ) -> Tuple[bytes, Dict[str, object]]:
    """Deterministic sanitized rendering of payload-pins.json: drop only the
    environment-specific payload.stagedBy reference; everything else is
    byte-preserved through a parse/render round-trip of the same document."""
    pins = load_json_text(pins_raw, "payload-pins.json (sanitizer input)")
    dropped: List[str] = []
    payload = pins.get("payload")
    if isinstance(payload, dict) and PINS_REDACTIONS[0][1] in payload:
        del payload[PINS_REDACTIONS[0][1]]
        dropped.append("payload." + PINS_REDACTIONS[0][1])
    rendered = (json.dumps(pins, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    text = rendered.decode("utf-8")
    scan_text(text, "public payload-pins.json rendering")
    again = load_json_text(rendered, "public payload-pins.json rendering")
    require(again == pins, "pins-render-faithful", checks,
            "the sanitized pins rendering does not parse back to the filtered "
            "input document")
    require(True, "pins-sanitized", checks, "", {
        "inputSha256": sha256_bytes(pins_raw),
        "renderedSha256": sha256_bytes(rendered),
        "droppedKeys": dropped,
    })
    return rendered, {"inputSha256": sha256_bytes(pins_raw),
                      "renderedSha256": sha256_bytes(rendered),
                      "droppedKeys": dropped}


def render_public_recipe(raw: bytes, checks: List[Dict[str, object]]
                         ) -> Tuple[bytes, Dict[str, object]]:
    text = raw.decode("utf-8")
    applied: List[str] = []
    for old, new in README_REDACTIONS:
        if old in text:
            text = text.replace(old, new)
            applied.append(old)
    scan_text(text, "public tools/README.md rendering")
    require(True, "recipe-sanitized", checks, "", {
        "inputSha256": sha256_bytes(raw),
        "renderedSha256": sha256_bytes(text.encode('utf-8')),
        "appliedRedactions": applied,
        "alreadyClean": not applied,
    })
    return text.encode("utf-8"), {"inputSha256": sha256_bytes(raw),
                                  "renderedSha256": sha256_bytes(text.encode("utf-8")),
                                  "appliedRedactions": applied,
                                  "alreadyClean": not applied}


def collect_office_group(args: argparse.Namespace, version: str, repository: str,
                         checks: List[Dict[str, object]],
                         files: Dict[str, Tuple[bytes, int]]) -> Dict[str, object]:
    base = Path(args.office_source_dir)
    tree = collect_office_tree(base, checks)

    # payload-pins.json and tools/README.md may legitimately carry host-local
    # references in the authoritative module tree; they travel only as the
    # sanitized renderings below (re-scanned), never as raw bytes.
    SANITIZED = {"payload-pins.json", "tools/README.md"}
    for rel in ROOT_DOCS + TOOLS_FILES + \
            [r for r in tree if r.startswith("src/")]:
        if rel in SANITIZED:
            continue
        scan_text(tree[rel].decode("utf-8"), rel)

    pins_raw = tree["payload-pins.json"]
    manifest_raw = tree["producer-manifest.json"]
    pins = validate_pins(pins_raw, manifest_raw, checks)
    manifest = validate_manifest(manifest_raw, checks)
    overlays = validate_overlays(tree["asset-overlays.json"], manifest, tree,
                                 version, repository, checks)
    index = validate_notice_index(tree["overlays/notices/source-index.json"],
                                  overlays, pins, tree, version, repository, checks)

    # host sources: exact upstream-notice gates + structural presence
    for rel in UPSTREAM_NOTICE_HOSTS:
        blob = tree.get(rel)
        if blob is None:
            raise OfficeSourceError(
                f"upstream-derived host source {rel} is missing from the frozen module")
        if "Mozilla Public License" not in blob.decode("utf-8"):
            raise OfficeSourceError(
                f"upstream-derived host source {rel} lost the MPL notice; MPL "
                "covered files must travel with their notices intact")
    tests = [r for r in tree if r.startswith("src/test/java/")]
    require(bool(tests), "office-observer-tests-present", checks,
            "src/test/java carries no observer tests; the offer contract includes them",
            len(tests))
    require("src/main/AndroidManifest.xml" in tree, "office-manifest-present", checks,
            "src/main/AndroidManifest.xml is missing from the frozen module")
    require("overlays/dist/cool.html" in tree and
            "SPDX-License-Identifier: MPL-2.0" in tree["overlays/dist/cool.html"].decode("utf-8"),
            "office-cool-overlay-license", checks,
            "the replaced dist/cool.html overlay is missing or lost its MPL marker")
    require(any(r == "src/main/assets/floe-office/renderer-witness.js" for r in tree),
            "office-witness-source-present", checks,
            "the shipped renderer witness source is missing from the frozen module")

    pins_public, pins_meta = render_public_pins(pins_raw, checks)
    recipe_public, recipe_meta = render_public_recipe(tree["tools/README.md"], checks)

    for rel in tree:
        if rel in LOCAL_ONLY_FILES:
            continue
        if rel == "payload-pins.json":
            files[f"office/{rel}"] = (pins_public, 0o644)
        elif rel == "tools/README.md":
            files[f"office/{rel}"] = (recipe_public, 0o644)
        else:
            files[f"office/{rel}"] = (tree[rel], 0o644)
    require(True, "office-group-embedded", checks, "", {
        "embeddedCount": sum(1 for k in files if k.startswith("office/")),
        "localOnlyExcluded": sorted(LOCAL_ONLY_FILES),
        "pinnedLibraries": len(OFFICE_PINNED_LIBRARIES),
        "overlayEntries": len(overlays["entries"]),
    })
    return {"pins": pins, "manifest": manifest, "overlays": overlays,
            "index": index, "pinsMeta": pins_meta, "recipeMeta": recipe_meta,
            "counts": {"embedded": sum(1 for k in files if k.startswith("office/")),
                       "overlayFiles": sum(1 for k in files
                                           if k.startswith("office/overlays/")),
                       "sourceFiles": sum(1 for k in files if k.startswith("office/src/"))}}


# ---------------------------------------------------------------------------
# generated documents + archive
# ---------------------------------------------------------------------------

def clean_generated(text: str, what: str) -> bytes:
    scan_text(text, f"generated {what}")
    data = text.encode("utf-8")
    if b"\x00" in data:
        raise OfficeSourceError(f"generated {what} contains NUL")
    return data


def render_readme(b: Dict[str, object]) -> str:
    lines = [
        "# Corresponding source — Floe Agent Android release (with Office engine)",
        "",
        f"Bound to product version `{b['version']}`, public source commit "
        f"`{b['commit']}` and the signed release APK",
        f"`{b['apk_name']}` (sha256 `{b['apk_sha256']}`).",
        "",
        f"This archive is the single public corresponding-source asset of the "
        f"`{b['tag']}`",
        f"GitHub release (`{b['archive_url']}`).",
        "",
        "## Contents",
        "",
        "```",
        "linux-ide/       the complete Linux/IDE combined corresponding-source",
        "                 archive exactly as produced by the proven",
        f"                 assemble-android-corresponding-source v{b['inner_tool_version']}",
        "                 (Linux-runtime PRoot/talloc/guest-resolver offer plus",
        "                 the Sora editor 0.24.4 LGPL source offer), preserved",
        f"                 byte-for-byte (sha256 `{b['inner_tar_sha']}`) together",
        "                 with its MANIFEST.json and SHA256SUMS",
        "office/          the pinned Office engine public group:",
        "  PROVENANCE.md  producer identity, obligations and honest limits",
        "  payload-pins.json / producer-manifest.json  exact release pins:",
        "                 upstream monorepo revision, whole producer APK sha256,",
        "                 signer certificate, 14 packaged native library hashes,",
        "                 per-file record of all producer payload bytes",
        f"                 ({b['manifest_records']} files, {b['manifest_bytes']} bytes)",
        "  asset-overlays.json + overlays/   every explicit original->new asset",
        f"                 transformation ({b['overlay_count']} entries) and the",
        "                 actual Floe overlay source files they bind",
        "  src/           the module host/JNI-facing Kotlin sources (upstream-",
        "                 derived files keep their MPL-2.0 notices), resources,",
        "                 assets and observer tests",
        "  build.gradle.kts, consumer-rules.pro, src/main/AndroidManifest.xml",
        "                 the module build source wiring",
        "  tools/         prepare_payload.py, README.md and the shipped-overlay",
        "                 semantic check test_writer_viewport_sync.js: the",
        "                 public staging recipe for the pinned producer payload",
        "                 (no downloads performed by this archive's producer)",
        "MANIFEST.json    full member hashes and every binding this tool checked",
        "```",
        "",
        "## Office producer identity (pinned, immutable)",
        "",
        f"- Upstream source: `{UPSTREAM_REPOSITORY}` (mirror "
        f"`{UPSTREAM_MIRROR}`), monorepo revision `{UPSTREAM_REVISION}` —",
        "  Collabora Office Mobile 26.04.4.2 code 937; `engine/` carries the core",
        "  in-tree, so one revision pins core + frontend + Android build sources.",
        f"- Commit tree: {UPSTREAM_COMMIT_TREE_URL}",
        f"- Commit archive (corresponding source of unmodified upstream): {UPSTREAM_COMMIT_ARCHIVE_URL}",
        f"- Build recipe: {UPSTREAM_RECIPE_URL}",
        f"- Dependency pins recipe: {UPSTREAM_DOWNLOAD_LST_URL}",
        f"- Publisher APK: {PRODUCER_APK_URL}",
        f"  (sha256 `{PRODUCER_APK_SHA256}`, signer certificate sha256",
        f"  `{PRODUCER_SIGNER_CERT_SHA256}`).",
        "- Floe packages the 14 producer native libraries byte-for-byte and",
        "  deliberately excludes the producer's `libc++_shared.so`; Floe ships",
        "  its own pinned NDK runtime copy instead (name-level symbol evidence in",
        "  `office/payload-pins.json`; ABI/runtime equivalence is a device gate",
        "  verified by the release owner, not claimed here).",
        "- Original `license.html` and `notice.txt` travel inside the APK",
        "  byte-identical to the upstream NOTICE at the revision; their hashes are",
        "  pinned in `office/payload-pins.json` and `source-index.json`.",
        "- This is the publisher's own build-id/commit binding. It is not a",
        "  reproducible-build proof or a third-party attestation.",
        "",
        "## Floe modifications covered here",
        "",
        f"- {b['overlay_count']} explicit asset-overlay operations (add/remove/replace),",
        "  each bound to the producer manifest by original hash and to the",
        "  included overlay file bytes by new hash; opaque proprietary web",
        "  branding was removed and the native widget theme replaced with",
        "  self-authored MPL-2.0 Floe-neutral artwork source.",
        "- Upstream-derived Android hosts under `office/src/main/java/org/",
        "  libreoffice/androidlib/` retain the Mozilla Public License 2.0 notice;",
        "  Floe-authored module sources carry SPDX MPL-2.0 identifiers.",
        "- `office/payload-pins.json` and `office/tools/README.md` are sanitized",
        "  public renderings of the module files (host-local staging/toolchain",
        "  references removed; every pinned value and byte otherwise preserved —",
        "  the input digests and exact transformations are recorded in",
        "  MANIFEST.json).",
        "",
        "## Exclusions",
        "",
        "- No APKs, native binaries, caches, build outputs, symbol archives,",
        "  keystores, credentials, logs, device artifacts or host-local paths.",
        "- The producer payload itself (it ships inside the release APK; this",
        "  archive carries its exact per-file manifest and pins, and unmodified",
        "  upstream source is provided at the pinned commit links above).",
        "- The module's private host-integration README and developer witness",
        "  harness stay out of the public offer (see MANIFEST.json exclusions).",
        "",
    ]
    return "\n".join(lines)


def load_and_validate(args: argparse.Namespace) -> Dict[str, object]:
    checks: List[Dict[str, object]] = []
    files: Dict[str, Tuple[bytes, int]] = {}

    version = args.release_version
    if not VERSION_RE.match(version):
        raise OfficeSourceError(f"release version {version!r} must match the stage-release grammar")
    commit = args.source_commit
    if not COMMIT_RE.match(commit):
        raise OfficeSourceError(f"source commit {commit!r} must be 40 or 64 lowercase hex")
    if not SHA256_RE.match(args.apk_sha256):
        raise OfficeSourceError(f"--apk-sha256 {args.apk_sha256!r} must be 64 lowercase hex")
    if not REPOSITORY_RE.match(args.source_repository):
        raise OfficeSourceError(
            f"--source-repository {args.source_repository!r} must be OWNER/REPO")
    expected_apk_name = APK_NAME_FMT.format(version=version)
    if args.apk_name != expected_apk_name:
        raise OfficeSourceError(
            f"--apk-name {args.apk_name!r} must equal the canonical stage-release name "
            f"{expected_apk_name!r} derived from --release-version")
    checks.append({"id": "final-binding-inputs", "ok": True, "detail": {
        "releaseVersion": version, "sourceCommit": commit,
        "sourceRepository": args.source_repository,
        "apkName": args.apk_name, "apkSha256": args.apk_sha256}})

    combined = verify_combined(args, version, commit, checks, files)
    office = collect_office_group(args, version, args.source_repository, checks, files)

    archive_url = RELEASE_URL_FMT.format(repo=args.source_repository, version=version,
                                         archive=ARCHIVE_NAME_FMT.format(version=version))
    binding = {
        "version": version, "commit": commit,
        "tag": f"android/v{version}", "archive_url": archive_url,
        "apk_name": args.apk_name, "apk_sha256": args.apk_sha256,
        "inner_tool_version": combined["tool"]["version"],
        "inner_tar_sha": combined["tarSha256"],
        "manifest_records": office["manifest"]["selectedFiles"],
        "manifest_bytes": office["manifest"]["selectedBytes"],
        "overlay_count": len(office["overlays"]["entries"]),
    }
    readme = clean_generated(render_readme(binding), "README.md")
    files["README.md"] = (readme, 0o644)

    total = sum(len(d) for d, _ in files.values())
    if total > MAX_TOTAL_BYTES:
        raise OfficeSourceError(
            f"combined content {total} bytes exceeds the {MAX_TOTAL_BYTES}-byte budget")
    for rel in files:
        safe_rel(rel, "archive member")

    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "tool": {"name": TOOL_NAME, "version": TOOL_VERSION},
        "offer": {
            "purpose": ("single combined corresponding-source archive for the "
                        "signed release APK (Linux/IDE generation + Office "
                        "engine group); publish it as the one source asset of "
                        f"{binding['tag']}"),
            "releaseApk": {"name": args.apk_name, "sha256": args.apk_sha256},
            "publicArchiveUrl": archive_url,
            "floeOwnedSource": f"public repository at {commit}; root and per-file licenses apply",
        },
        "releaseVersion": version,
        "sourceCommit": commit,
        "sourceRepository": args.source_repository,
        "linuxIdeCombined": {
            "embeddedArchive": f"linux-ide/{combined['tarName']}",
            "embeddedArchiveSha256": combined["tarSha256"],
            "embeddedArchiveBytes": combined["tarBytes"],
            "embeddedManifestSha256": combined["manifestSha256"],
            "producerTool": combined["tool"],
            "releaseApkBinding": {"name": args.apk_name, "sha256": args.apk_sha256},
        },
        "officeEngine": {
            "sourceRoot": "FloeAndroid/core/officeengine",
            "upstream": {
                "repository": UPSTREAM_REPOSITORY, "mirror": UPSTREAM_MIRROR,
                "revision": UPSTREAM_REVISION, "monorepo": True,
                "commitTreeUrl": UPSTREAM_COMMIT_TREE_URL,
                "commitArchiveUrl": UPSTREAM_COMMIT_ARCHIVE_URL,
                "recipeUrl": UPSTREAM_RECIPE_URL,
                "downloadLstUrl": UPSTREAM_DOWNLOAD_LST_URL,
                "embeddedBuildId": EMBEDDED_BUILD_ID,
            },
            "producerApk": {"url": PRODUCER_APK_URL, "file": PRODUCER_APK_FILE,
                            "sha256": PRODUCER_APK_SHA256,
                            "signerCertSha256": PRODUCER_SIGNER_CERT_SHA256,
                            "versionName": PRODUCER_VERSION_NAME,
                            "versionCode": PRODUCER_VERSION_CODE,
                            "abi": PRODUCER_ABI},
            "pinnedLibraries": dict(office["pins"]["libraries"]),
            "libcxx": dict(office["pins"]["libcxxPolicy"]),
            "anchorAssets": dict(office["pins"]["anchorAssets"]),
            "producerManifest": {
                "sha256": sha256_bytes(files["office/producer-manifest.json"][0]),
                "selectedFiles": office["manifest"]["selectedFiles"],
                "selectedBytes": office["manifest"]["selectedBytes"],
                "nativeLibraries": office["pins"]["payload"]["nativeLibraries"],
            },
            "overlayManifest": {
                "sha256": sha256_bytes(files["office/asset-overlays.json"][0]),
                "entries": len(office["overlays"]["entries"]),
                "fileSetEqualityVerified": True,
            },
            "noticeIndex": {
                "sha256": sha256_bytes(files["office/overlays/notices/source-index.json"][0]),
                "selfHashBoundThroughOverlayAddEntry": True,
                "operationCount": office["index"]["floeOverlay"]["operationCount"],
                "sourceFileRecords": len(office["index"]["floeOverlay"]["sourceFileRecords"]),
            },
            "pinsRendering": office["pinsMeta"],
            "recipeRendering": office["recipeMeta"],
            "counts": office["counts"],
        },
        "archive": {"rootPrefix": ARCHIVE_ROOT_FMT.format(version=version),
                    "mtimeEpoch": EPOCH_MTIME, "ordering": "byte-sorted",
                    "format": "ustar-in-gzip(mtime=0)"},
        "files": [
            {"path": rel, "sha256": sha256_bytes(data), "bytes": len(data),
             "mode": oct(mode)}
            for rel, (data, mode) in sorted(files.items(),
                                            key=lambda kv: kv[0].encode("utf-8"))
        ],
        "exclusions": [
            "the signed release APK itself (separate release asset)",
            "the producer payload bytes (they ship inside the APK; bound here by "
            "the exact per-file manifest and pins, unmodified upstream provided "
            "at the pinned commit links)",
            "module README.md (host integration notes with host-local build paths)",
            "module tools/test_renderer_witness.js (developer-side harness "
            "referencing a private qualification contract)",
            "the pinned editor AAR binary and producer native libraries (inside "
            "the release APK; bound by sha256)",
            "any private toolchain, keystore, credential, log, device artifact "
            "or host-local path",
        ],
        "limitations": [
            "This archive binds inputs by hash. Proving the shipped APK carries "
            "the 14 pinned producer libraries, the overlaid assets and the bound "
            "Linux/IDE payloads remains the release readback "
            "(prepare-stage-release.py with --office-pins + Main's final "
            "verification), not this tool.",
            "The producer binding is the publisher's own build-id/commit "
            "mechanism; no reproducible-build proof or third-party attestation "
            "is claimed.",
            "payload-pins.json and tools/README.md travel as sanitized public "
            "renderings; the exact input digests and transformations are "
            "recorded above so the authoritative module files can be audited "
            "against them.",
            "No native runtime, rendering, packaging or publication is asserted "
            "by producing this archive.",
        ],
    }
    manifest_bytes = (json.dumps(manifest, indent=1) + "\n").encode("utf-8")
    files["MANIFEST.json"] = (manifest_bytes, 0o644)

    tar_bytes = build_archive(version, files)
    return {
        "tool": {"name": TOOL_NAME, "version": TOOL_VERSION},
        "command": args.command,
        "releaseVersion": version,
        "sourceCommit": commit,
        "sourceRepository": args.source_repository,
        "releaseApk": {"name": args.apk_name, "sha256": args.apk_sha256},
        "publicArchiveUrl": archive_url,
        "archiveName": ARCHIVE_NAME_FMT.format(version=version),
        "archiveSha256": sha256_bytes(tar_bytes),
        "archiveBytes": len(tar_bytes),
        "fileCount": len(files),
        "officeGroup": office["counts"],
        "entryPaths": sorted(files.keys(), key=lambda s: s.encode("utf-8")),
        "checks": checks,
        "_tar_bytes": tar_bytes,
        "_manifest_bytes": manifest_bytes,
    }


def build_archive(version: str, files: Dict[str, Tuple[bytes, int]]) -> bytes:
    root = ARCHIVE_ROOT_FMT.format(version=version)
    dirs = {""}
    for rel in files:
        parts = rel.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add("/".join(parts[:i]))
    entries: List[Tuple[str, Optional[Tuple[bytes, int]]]] = [
        (f"{root}/{d}/" if d else f"{root}/", None) for d in dirs
    ]
    entries += [(f"{root}/{rel}", (data, mode)) for rel, (data, mode) in files.items()]
    entries.sort(key=lambda e: e[0].rstrip("/").encode("utf-8"))

    buffer = io.BytesIO()
    gz = gzip.GzipFile(fileobj=buffer, mode="wb", compresslevel=9,
                       mtime=EPOCH_MTIME, filename="")
    try:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.USTAR_FORMAT) as tar:
            for name, payload in entries:
                info = tarfile.TarInfo(name)
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = EPOCH_MTIME
                if payload is None:
                    info.type = tarfile.DIRTYPE
                    info.mode = 0o755
                    tar.addfile(info)
                else:
                    data, mode = payload
                    info.type = tarfile.REGTYPE
                    info.mode = mode
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
    finally:
        gz.close()
    return buffer.getvalue()


def write_atomically(out_dir: Path, name: str, payload: bytes) -> None:
    target = out_dir / name
    if target.exists():
        raise OfficeSourceError(f"refusing to replace existing {target}")
    tmp = out_dir / (name + ".part")
    with tmp.open("wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, target)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Produce the single combined public corresponding-source "
                    "archive (Linux/IDE generation + Office engine group) for "
                    "one Floe Agent Android release")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_shared(p: argparse.ArgumentParser) -> None:
        p.add_argument("--combined-ccs-dir", required=True,
                       help="output directory of assemble-android-corresponding-source "
                            "for THIS release version and final commit "
                            "(tar.gz + MANIFEST.json + SHA256SUMS)")
        p.add_argument("--office-source-dir", required=True,
                       help="frozen FloeAndroid/core/officeengine module tree")
        p.add_argument("--release-version", required=True,
                       help="product version token, same as the tag (e.g. 0.1.0-alpha.12)")
        p.add_argument("--source-commit", required=True,
                       help="FINAL immutable public Floe commit (40 or 64 hex)")
        p.add_argument("--source-repository", required=True,
                       help="public OWNER/REPO the release tag/archive URLs point at")
        p.add_argument("--apk-name", required=True,
                       help="exact release APK asset name")
        p.add_argument("--apk-sha256", required=True,
                       help="sha256 of the FINAL signed Full APK")

    p_check = sub.add_parser("check", help="verify bindings; print JSON; write nothing")
    add_shared(p_check)
    p_produce = sub.add_parser("produce", help="verify then write the archive atomically")
    add_shared(p_produce)
    p_produce.add_argument("--out", required=True,
                           help="new/empty output directory (never replaced)")
    args = parser.parse_args(argv)

    try:
        report = load_and_validate(args)
        tar_bytes = report.pop("_tar_bytes")
        manifest_bytes = report.pop("_manifest_bytes")
        if args.command == "produce":
            out_dir = Path(args.out)
            if out_dir.exists() and any(out_dir.iterdir()):
                raise OfficeSourceError(f"output directory must be absent or empty: {out_dir}")
            out_dir.mkdir(parents=True, exist_ok=True)
            archive_name = str(report["archiveName"])
            write_atomically(out_dir, archive_name, tar_bytes)
            write_atomically(out_dir, "MANIFEST.json", manifest_bytes)
            archive_sha = sha256_bytes(tar_bytes)
            manifest_sha = sha256_bytes(manifest_bytes)
            write_atomically(out_dir, "SHA256SUMS",
                             (f"{archive_sha}  {archive_name}\n"
                              f"{manifest_sha}  MANIFEST.json\n").encode("utf-8"))
            if sha256_file(out_dir / archive_name) != archive_sha:
                raise OfficeSourceError("written archive does not match its computed hash")
            report["written"] = sorted(p.name for p in out_dir.iterdir())
    except OfficeSourceError as exc:
        print(f"{TOOL_NAME}: FAIL {exc}", file=sys.stderr)
        return 1

    print(json.dumps(report, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
