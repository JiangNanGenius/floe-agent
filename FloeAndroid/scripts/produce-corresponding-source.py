#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Produce one minimal, reproducible public corresponding-source archive for
the shipped Android Linux-runtime native helper (PRoot fork + static talloc).

Scope of the offer
------------------
The shipped payloads ``libproot.so`` / ``libproot_loader.so`` combine the
Termux-maintained PRoot fork (per-file GPL-2.0-or-later, offered for the
combined binary under GPL-3.0-or-later) with statically linked talloc 2.4.2
(LGPL-3.0-or-later). Their complete corresponding source is exactly:
the pinned upstream archives used verbatim, the single pinned local patch,
the producer recipe (build instructions) captured at the frozen revision,
and the retained third-party license texts. Floe-owned Kotlin/Swift/C
sources are MPL-2.0 and live in the public repository at the bound commit;
this archive references them instead of copying them.

The tool has two subcommands:

``check``
    Run every binding check and print a JSON report (including the SHA-256 of
    the deterministic archive it *would* write). Writes nothing anywhere.

``produce``
    Re-verify everything, then atomically write into an output directory:

        OUT/
          floe-linuxruntime-corresponding-source-<release-version>.tar.gz
          MANIFEST.json
          SHA256SUMS

    An existing non-empty destination is never replaced. The tool never runs
    a build, touches Git, uploads, reads credentials or publishes anything;
    execution against the final frozen inputs and publication remain Main's.

Fail-closed bindings (all enforced, none downgraded to warnings):

* the recipe tree recomputes to the provenance ``recipe_tree_sha256`` (the
  exact scope ``build-bootstrap.sh`` hashes) and the pinned patch file
  matches its provenance hash — the archive is bound to one frozen recipe
  revision, never to a mutable working tree;
* the producer script's own pins agree with provenance for the PRoot and
  talloc URLs/hashes (no silent pin drift between recipe and payload run);
* each upstream archive in the cache is byte-exact against the pinned sha256
  (canonical filename, or the producer-cache alias; a wrong cached file is
  rejected, never silently re-downloaded);
* only text recipe/license/document files and the two upstream archives enter
  the archive; relink objects are included only through an exact-filename
  allowlist when ``--relink-evidence`` is passed;
* credential/keystore/log/evidence filename patterns, private-key material
  and any Apple/APSL text in the compat/config/cross recipe BUILD inputs are
  rejected (mirroring the producer's own queue-header license guard, which
  scans compat/queue.h, compat/musl-compat.h, config/* and cross/* and states
  that prose ``.patch`` records may legitimately *describe* the rejected
  header without being compiled inputs themselves);
* the public offer binds exactly the two shipped executable payloads
  (``lib/libproot.so``, ``lib/libproot_loader.so``); a provenance recording
  missing either binding is refused fail-closed. Any additional recorded outputs (for
  example the qualification-only ``lib/libfloeprobe.so``) stay private
  evidence and are never listed as shipped;
* the archive is deterministic: byte-sorted entries, fixed epoch mtime,
  uid/gid 0, ustar format and a gzip member with mtime 0, so re-running on
  the same frozen inputs reproduces identical bytes;
* disclosed packaging-only rendering: when ``--host-run-mapping FILE`` is
  passed, the embedded recipe/relink copies run through a deterministic
  same-length host-identity byte-run mask defined entirely by that private
  mapping file — the tool source itself carries no host/user/volume/task
  identity. Rules must be same-length, uniquely and neutrally named, and the
  render fails closed if any mapped run survives or any forbidden fragment
  remains; with no mapping the inputs render verbatim and the same residual
  scan still fails closed. The mapping path and content are never recorded
  in the archive or MANIFEST; MANIFEST.json records only rule ids, per-rule
  run counts and the original/public digests of each rendered copy.

Optional guest-resolver module (G03-R3):

``--guest-resolver-dir DIR --guest-resolver-manifest FILE``
    All-or-none inputs that additionally include the Floe-owned guest NSS
    helper module (``libnss_floe.c``, its version script, protocol and
    pinned producer script) plus the producer's ``manifest.json`` under
    ``guest-resolver/``. The manifest must validate against the frozen
    PROTOCOL.json ``manifestSchema`` (exact key set, protocol/library/
    target/soname/floor constants, toolchain bound to the existing pinned
    Zig pin, exports == the contract's four entry points, bounded sorted
    source paths), every listed source file must be present under DIR with
    the exact hash/size, and the recomputed ``sourceTreeSha256`` over the
    actual file hashes must match the manifest. Without both flags the
    tool behaves exactly as before; the original proot/talloc recipe hash,
    patch and relink bindings are untouched either way.

Known limitations are recorded in the report instead of silently converted
into success: this tool binds inputs by hash; it does not and cannot prove
that a shipped APK carried those exact payload bytes — that binding stays
with the final producer provenance, the native manifest and Main's release
readback.
"""

from __future__ import annotations

import argparse
import base64
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

TOOL_NAME = "produce-corresponding-source"
# 1.1.1: Apple/APSL content scan aligned to
# the frozen producer's compiled inputs (build-bootstrap.sh 396-403; prose
# .patch attestations describe the rejected header instead of being it), and
# the public offer binds/labels exactly the two shipped executable payloads,
# fail-closed if either libproot.so or libproot_loader.so binding is missing.
# 1.2.0 (packaging-only disclosure transform): the EMBEDDED copies of the
# native-build recipe documents and of the allowlisted talloc relink evidence
# objects may undergo a deterministic, same-length host-identity byte-run
# mask. The mask rules live ONLY in an operator-supplied private mapping file
# (--host-run-mapping); this source carries no host/user/volume/task identity.
# The on-disk inputs are never modified and still pass every original check
# (recipe tree hash vs provenance, text/deny scan, pins consistency,
# allowlist); only the bytes written into the public archive change.
# MANIFEST.json records every rendered copy as {originalSha256, publicSha256,
# maskedRunCounts, bytes} so Main and any reader can audit the two
# generations. Equality of byte length means ELF/ar section headers, symbol
# tables, relocation records and section sizes are untouched; observed host
# runs occur inside recipe prose/comments and inside the .debug_line DWARF
# line-program string tables of the relink objects.
TOOL_VERSION = "1.2.0"
SCHEMA_VERSION = 1

EPOCH_MTIME = 0
MAX_TEXT_BYTES = 2 * 1024 * 1024
MAX_UPSTREAM_BYTES = 64 * 1024 * 1024
MAX_RELINK_BYTES = 16 * 1024 * 1024
MAX_TOTAL_BYTES = 256 * 1024 * 1024

RECIPE_SINGLETONS = ("build-bootstrap.sh", "PINS.md")
RECIPE_DIRS = ("compat", "config", "cross", "patches")
RECIPE_APSL_SCOPES = ("compat", "config", "cross")

# ---- guest-resolver module (optional; constants frozen by PROTOCOL.json
#      manifestSchema / guestAbi — changing them requires a coordinated
#      protocol version change by Main, not an edit here) ----
GUEST_PROTOCOL = "floe-guest-dns-v1"
GUEST_LIBRARY = "libnss_floe.so.2"
GUEST_TARGET = "aarch64-linux-gnu"
GUEST_GLIBC_FLOOR = "2.28"
GUEST_MIN_LOAD_ALIGN = 16384
GUEST_MANIFEST_MAX_BYTES = 65536
GUEST_SOURCES_MAX = 64
GUEST_SOURCE_PATH_MAX = 256
GUEST_BINARY_MAX_BYTES = 4 * 1024 * 1024  # manifestRules: bytes in 1..4194304
GUEST_REQUIRED_EXPORTS = sorted(
    ["_nss_floe_gethostbyname_r", "_nss_floe_gethostbyname2_r",
     "_nss_floe_gethostbyname3_r", "_nss_floe_gethostbyname4_r"],
    key=lambda s: s.encode("utf-8"))
GUEST_MANIFEST_KEYS = {
    "schemaVersion", "protocol", "library", "target", "glibcFloor", "soname",
    "sourceTreeSha256", "sources", "toolchain", "binary",
    "minimumLoadAlignment", "exports"}
GUEST_SAFE_REL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*(?:/[A-Za-z0-9][A-Za-z0-9._+-]*)*$")

RELINK_ALLOWLIST = (
    "talloc.o",
    "replace.o",
    "libtalloc.members.txt",
    "talloc-install/lib/libtalloc.a",
)
RELINK_REQUIRED = ("talloc.o", "replace.o", "talloc-install/lib/libtalloc.a")


# ---- disclosed packaging-only rendering of host identity runs (1.2.0) ----------------
# Applied ONLY to the byte sequences embedded into the public archive from the
# native-build recipe tree and the allowlisted relink evidence: build-host
# directory/user/cache strings captured in recipe prose and comments and inside
# DWARF .debug_line tables. The replacement rules are NOT compiled into this
# tool: the operator supplies a private mapping file through
# --host-run-mapping (it lives only in the private output area; its path and
# content never enter the archive, the MANIFEST or any rendered record). Every
# rule must map one non-empty byte run to another of exactly the same byte
# length, so file sizes, archive member sizes (ar headers), ELF section headers,
# symbol tables and relocation records are byte-identical to the inputs; only
# the masked character runs differ. The unmodified inputs remain the private
# evidence of record and their digests (originalSha256) are recorded beside the
# public digests. Rule ids are recorded instead of the original runs so the
# public MANIFEST never re-exposes them. Without the flag the inputs render
# verbatim and the residual scan below still fails closed on any surviving
# host-form fragment, so a mapping covering the inputs' host runs is mandatory
# for host-bound recipe trees.
# Not applied to: the upstream archives (redistributed byte-exact against their
# pinned provenance hashes), license texts, or the generated offer document -
# those are scanned and already free of host identity runs.
HOST_MAPPING_SCHEMA_VERSION = 1
MAX_HOST_MAPPING_BYTES = 64 * 1024
HOST_RULE_ID_RE = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
# Structural fragments only: generic path forms that name no specific host,
# user, volume or task. Host identity itself enters exclusively through the
# private mapping file (rule old-runs are always residual-checked, and the
# mapping may add further residual fragments).
HOST_RESIDUAL_FRAGMENTS = (b"/Users/", b"/Volumes/", b"Local/Private")


def _mapping_blob(value: object, what: str) -> bytes:
    if not isinstance(value, str):
        raise ProduceError(f"host-run mapping {what} must be a base64 string")
    try:
        blob = base64.b64decode(value.encode("ascii"), validate=True)
    except (UnicodeEncodeError, ValueError) as exc:
        raise ProduceError(f"host-run mapping {what} is not valid base64: {exc}")
    if not blob:
        raise ProduceError(f"host-run mapping {what} decodes to empty bytes")
    return blob


def load_host_run_mapping(path: Path) -> Tuple[List[Tuple[str, bytes, bytes]], Tuple[bytes, ...]]:
    """Strict loader for the private same-length host-run mapping.

    Expected shape (any deviation fails closed):
        {"schemaVersion": 1,
         "rules": [{"id": "<neutral-lowercase-token>",
                    "oldB64": "<base64>", "newB64": "<same-length base64>"}, ...],
         "residualFragmentsB64": ["<base64>", ...]}   (optional)
    Rule ids are the only rule metadata that may be recorded publicly
    (MANIFEST renderedCopies maskedRunCounts keys), so they are grammar-checked
    neutral lowercase tokens and must be unique; every old/new pair must decode
    to non-empty, exactly equal-length bytes. Order of the rules is the order
    in which the mask applies them and is significant for run counts.
    """
    if not path.is_file():
        raise ProduceError(f"host-run mapping file missing: {path.name}")
    raw = read_bounded(path, MAX_HOST_MAPPING_BYTES, "host-run mapping")
    try:
        doc = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProduceError(f"host-run mapping is not UTF-8 JSON: {exc}")
    if not isinstance(doc, dict):
        raise ProduceError("host-run mapping must be a JSON object")
    allowed = {"schemaVersion", "rules", "residualFragmentsB64"}
    if not set(doc) <= allowed or "schemaVersion" not in doc or "rules" not in doc:
        raise ProduceError("host-run mapping keys must be schemaVersion and rules "
                           "(plus optional residualFragmentsB64)")
    if doc["schemaVersion"] != HOST_MAPPING_SCHEMA_VERSION:
        raise ProduceError(f"host-run mapping schemaVersion must be "
                           f"{HOST_MAPPING_SCHEMA_VERSION}")
    rules_doc = doc["rules"]
    if not isinstance(rules_doc, list):
        raise ProduceError("host-run mapping rules must be a list")
    rules: List[Tuple[str, bytes, bytes]] = []
    seen = set()
    for index, entry in enumerate(rules_doc):
        if not isinstance(entry, dict) or set(entry) != {"id", "oldB64", "newB64"}:
            raise ProduceError(f"host-run mapping rule {index} must carry exactly "
                               "the keys id/oldB64/newB64")
        rid = entry["id"]
        if not isinstance(rid, str) or not HOST_RULE_ID_RE.match(rid):
            raise ProduceError(f"host-run mapping rule {index} id must be a neutral "
                               "lowercase [a-z0-9_] token (ids are recorded publicly)")
        if rid in seen:
            raise ProduceError(f"host-run mapping rule id {rid!r} is duplicated")
        seen.add(rid)
        old = _mapping_blob(entry["oldB64"], f"rule {rid} oldB64")
        new = _mapping_blob(entry["newB64"], f"rule {rid} newB64")
        if len(old) != len(new):
            raise ProduceError(f"host-run mapping rule {rid!r} is not same-length "
                               "(the disclosed transform never changes byte counts)")
        rules.append((rid, old, new))
    extra: Tuple[bytes, ...] = ()
    if "residualFragmentsB64" in doc:
        frags_doc = doc["residualFragmentsB64"]
        if not isinstance(frags_doc, list):
            raise ProduceError("host-run mapping residualFragmentsB64 must be a list")
        extra = tuple(_mapping_blob(v, "residualFragmentsB64 entry")
                      for v in frags_doc)
    return rules, extra


def mask_host_runs(data: bytes,
                   rules: List[Tuple[str, bytes, bytes]],
                   extra_residual_fragments: Tuple[bytes, ...] = ()):
    """Deterministic same-length host identity run masking (see 1.2.0 note)."""
    out = data
    counts = {}
    for rule, old, new in rules:
        if len(old) != len(new):  # defensive re-check; loader enforced
            raise ProduceError("host run mask lengths differ (internal error)")
        c = out.count(old)
        if c:
            counts[rule] = c
            out = out.replace(old, new)
    if any(old in out for _, old, _ in rules):
        raise ProduceError("host identity run survived masking (fail-closed)")
    for frag in HOST_RESIDUAL_FRAGMENTS + tuple(extra_residual_fragments):
        if frag in out:
            raise ProduceError("masked bytes still carry a forbidden public fragment "
                               f"{frag!r} (fail-closed)")
    return out, counts

DENY_NAME = re.compile(
    r"(?i)(^|[/._\-\s])(keystore|jks|p12|pfx|pem|secret|token|credential|"
    r"password|passwd|apikey|private|keychain|evidence)([/._\-\s]|$)"
    r"|\.(jks|keystore|p12|pfx|pem|log|bak)$"
    r"|(^|/)\.env($|/)|(^|/)local\.properties$|(^|/)id_(rsa|ed25519)($|\.)"
)
DENY_CONTENT = (b"PRIVATE KEY", b"BEGIN OPENSSH", b"BEGIN EC PRIVATE")
APSL_TEXT_MARKERS = ("APSL", "Apple Inc.")
# Prose attestation records (compat/config/cross *.patch files) are not
# compiled inputs: build-bootstrap.sh lines 396-403 scan only
# compat/queue.h, compat/musl-compat.h, config/* and cross/* for the Apple/
# APSL markers, and its comment states that .patch/prose records may
# legitimately *describe* the rejected header. Mirror that compiled-input
# scope for the content scan only; every recipe input still passes the
# deny-name / NUL / private-key / UTF-8 text_or_reject checks above.
APSL_COMPILED_INPUT_SKIP = ".patch"
# The release APK packages exactly these two executable Linux-runtime payloads
# (FloeAndroid runtimeapp packaging excludes lib/libfloeprobe.so, a
# qualification-only probe). The original immutable provenance may record
# additional non-shipped outputs; that extra evidence stays private and the
# public manifest/offer must never list it as a shipped binary.
SHIPPED_PAYLOADS = ("lib/libproot.so", "lib/libproot_loader.so")

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
VERSION_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$")
LICENSE_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9._+-]{0,63}$")

ARCHIVE_ROOT_FMT = "floe-linuxruntime-corresponding-source-{version}"
ARCHIVE_NAME_FMT = "floe-linuxruntime-corresponding-source-{version}.tar.gz"


class ProduceError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_bounded(path: Path, limit: int, what: str) -> bytes:
    try:
        size = path.stat().st_size
    except OSError as exc:
        raise ProduceError(f"cannot stat {what}: {exc}") from exc
    if size > limit:
        raise ProduceError(f"{what} is {size} bytes, above the {limit}-byte limit")
    return path.read_bytes()


def check_name(name: str, what: str) -> None:
    if DENY_NAME.search(Path(name).name):
        raise ProduceError(f"{what} name {name!r} matches the credential/evidence deny list")


def text_or_reject(path: Path, what: str) -> bytes:
    check_name(path.name, what)
    data = read_bounded(path, MAX_TEXT_BYTES, what)
    if b"\x00" in data:
        raise ProduceError(f"{what} is not a text file (NUL byte present)")
    for marker in DENY_CONTENT:
        if marker in data:
            raise ProduceError(f"{what} contains rejected material {marker!r}")
    try:
        data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ProduceError(f"{what} is not valid UTF-8 text") from exc
    return data


def collect_recipe_tree(recipe_dir: Path) -> List[str]:
    """Relative paths of the producer recipe inputs, in the exact scope that
    build-bootstrap.sh hashes into provenance.recipe_tree_sha256."""
    if not recipe_dir.is_dir():
        raise ProduceError(f"recipe directory missing: {recipe_dir}")
    for singleton in RECIPE_SINGLETONS:
        if not (recipe_dir / singleton).is_file():
            raise ProduceError(f"recipe is missing {singleton} (not the native-build producer tree?)")
    entries: List[str] = list(RECIPE_SINGLETONS)
    for sub in RECIPE_DIRS:
        base = recipe_dir / sub
        if not base.is_dir():
            raise ProduceError(f"recipe input directory missing: {sub}/")
        for path in base.rglob("*"):
            if path.is_symlink():
                raise ProduceError(f"recipe input {path} is a symlink (frozen trees must be material)")
            if path.is_file():
                rel = str(path.relative_to(recipe_dir))
                check_name(rel, "recipe input")
                entries.append(rel)
    return sorted(set(entries), key=lambda s: s.encode("utf-8"))


def recipe_tree_sha256(recipe_dir: Path, entries: List[str]) -> str:
    """Mirror of build-bootstrap.sh:
        find build-bootstrap.sh PINS.md compat config cross patches -type f \
          | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256
    (shasum prints '<hash>  <path>'; the outer hash covers that stream)."""
    stream = "".join(f"{sha256_file(recipe_dir / rel)}  {rel}\n" for rel in entries)
    return hashlib.sha256(stream.encode("utf-8")).hexdigest()


def parse_producer_pins(recipe_dir: Path) -> Dict[str, str]:
    script = (recipe_dir / "build-bootstrap.sh").read_text(encoding="utf-8")

    def one(pattern: str) -> str:
        match = re.search(pattern, script, re.M)
        if not match:
            raise ProduceError(f"producer pin not found in build-bootstrap.sh: {pattern}")
        return match.group(1)

    pins = {
        "proot_url": one(r'^PROOT_URL="([^"]+)"'),
        "proot_sha": one(r'^PROOT_SHA="([0-9a-f]{64})"'),
        "proot_name": one(r'^PROOT_FILENAME="([^"]+)"'),
        "talloc_url": one(r'^TALLOC_URL="([^"]+)"'),
        "talloc_sha": one(r'^TALLOC_SHA="([0-9a-f]{64})"'),
    }
    return pins


def parse_guest_toolchain_pin(recipe_dir: Path) -> Tuple[str, str]:
    """Zig pin (archive sha256, version) from the existing pinned bootstrap
    recipe — the guest-resolver producer reuses this same toolchain pin;
    only consulted when guest-resolver inputs are provided."""
    script = (recipe_dir / "build-bootstrap.sh").read_text(encoding="utf-8")
    sha_m = re.search(r'^ZIG_SHA="([0-9a-f]{64})"', script, re.M)
    dir_m = re.search(r'^ZIG_DIRNAME="zig-aarch64-macos-([0-9][0-9A-Za-z.]*)"', script, re.M)
    if not sha_m or not dir_m:
        raise ProduceError("guest-resolver toolchain pin (ZIG_SHA/ZIG_DIRNAME) "
                           "not found in build-bootstrap.sh; the helper must bind "
                           "to the existing pinned Zig, not an unbound toolchain")
    return sha_m.group(1), dir_m.group(1)


def validate_guest_resolver(args: argparse.Namespace, recipe_dir: Path,
                            files: Dict[str, Tuple[bytes, int]],
                            checks: List[Dict[str, object]]) -> Optional[Dict[str, object]]:
    """Fail-closed binding of the guest NSS helper module into the archive.
    Returns the manifest binding block, or None when no guest inputs given.
    Partial input (only one of dir/manifest) is a hard error: the helper
    source set is all-or-none."""
    has_dir = getattr(args, "guest_resolver_dir", None)
    has_manifest = getattr(args, "guest_resolver_manifest", None)
    if not has_dir and not has_manifest:
        return None
    if bool(has_dir) != bool(has_manifest):
        raise ProduceError("guest-resolver inputs are all-or-none: pass both "
                           "--guest-resolver-dir and --guest-resolver-manifest")
    gdir = Path(has_dir)
    if not gdir.is_dir():
        raise ProduceError(f"guest-resolver source directory missing: {gdir}")
    man_path = Path(has_manifest)
    if not man_path.is_file():
        raise ProduceError(f"guest-resolver manifest missing: {man_path}")
    man_bytes = text_or_reject(man_path, "guest-resolver manifest")
    if len(man_bytes) > GUEST_MANIFEST_MAX_BYTES:
        raise ProduceError(f"guest-resolver manifest is {len(man_bytes)} bytes, "
                           f"above the frozen {GUEST_MANIFEST_MAX_BYTES}-byte bound")
    try:
        man = json.loads(man_bytes.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise ProduceError(f"guest-resolver manifest is not valid JSON: {exc}") from exc
    if not isinstance(man, dict):
        raise ProduceError("guest-resolver manifest must be a JSON object")
    require(set(man) == GUEST_MANIFEST_KEYS, "guest-manifest-key-set", checks,
            f"guest-resolver manifest keys {sorted(man)} differ from the frozen "
            f"manifestSchema keys {sorted(GUEST_MANIFEST_KEYS)} (unknown fields "
            "could carry private paths or volatile state)", sorted(man))
    constants = {
        "schemaVersion": 1,
        "protocol": GUEST_PROTOCOL,
        "library": GUEST_LIBRARY,
        "target": GUEST_TARGET,
        "glibcFloor": GUEST_GLIBC_FLOOR,
        "soname": GUEST_LIBRARY,
        "minimumLoadAlignment": GUEST_MIN_LOAD_ALIGN,
    }
    for key, expected in constants.items():
        require(man.get(key) == expected, f"guest-manifest-{key}", checks,
                f"guest-resolver manifest {key} is {man.get(key)!r}, must be {expected!r} "
                "(frozen PROTOCOL.json)")

    exports = man.get("exports")
    require(isinstance(exports, list)
            and sorted(exports, key=lambda s: str(s).encode("utf-8")) == GUEST_REQUIRED_EXPORTS,
            "guest-manifest-exports", checks,
            f"guest-resolver manifest exports {exports!r} are not exactly the four "
            "contract NSS entry points")

    tc = man.get("toolchain")
    require(isinstance(tc, dict) and set(tc) == {"name", "version", "archiveSha256"}
            and tc.get("name") == "zig" and isinstance(tc.get("version"), str)
            and isinstance(tc.get("archiveSha256"), str)
            and SHA256_RE.match(str(tc.get("archiveSha256", ""))) is not None,
            "guest-manifest-toolchain-shape", checks,
            f"guest-resolver manifest toolchain {tc!r} is malformed")
    pinned_sha, pinned_ver = parse_guest_toolchain_pin(recipe_dir)
    require(tc["archiveSha256"] == pinned_sha and tc["version"] == pinned_ver,
            "guest-manifest-toolchain-pinned", checks,
            f"guest-resolver manifest toolchain {tc['version']}@{tc['archiveSha256']} "
            f"does not match the pinned Zig {pinned_ver}@{pinned_sha} from "
            "build-bootstrap.sh; the helper binary must be bound to the existing "
            "pinned toolchain", {"manifest": tc,
                                 "pinned": {"version": pinned_ver,
                                            "archiveSha256": pinned_sha}})

    bininfo = man.get("binary")
    require(isinstance(bininfo, dict) and set(bininfo) == {"name", "sha256", "bytes"}
            and bininfo.get("name") == GUEST_LIBRARY
            and isinstance(bininfo.get("sha256"), str)
            and SHA256_RE.match(str(bininfo.get("sha256", ""))) is not None
            and isinstance(bininfo.get("bytes"), int)
            and not isinstance(bininfo.get("bytes"), bool)
            and 1 <= bininfo["bytes"] <= GUEST_BINARY_MAX_BYTES,
            "guest-manifest-binary", checks,
            f"guest-resolver manifest binary {bininfo!r} is malformed or exceeds "
            f"the frozen 1..{GUEST_BINARY_MAX_BYTES}-byte bound")

    sources = man.get("sources")
    require(isinstance(sources, list) and 0 < len(sources) <= GUEST_SOURCES_MAX,
            "guest-manifest-sources-bound", checks,
            f"guest-resolver manifest sources must be a nonempty list of at most "
            f"{GUEST_SOURCES_MAX} entries, got {sources!r}")
    paths = [s.get("path") for s in sources if isinstance(s, dict)]
    require(all(isinstance(s, dict) and set(s) == {"path", "sha256", "bytes"} for s in sources)
            and len(paths) == len(sources),
            "guest-manifest-source-shape", checks,
            f"guest-resolver manifest source entries must each carry exactly "
            f"path/sha256/bytes, got {sources!r}")
    require(paths == sorted(paths, key=lambda p: str(p).encode("utf-8"))
            and len(set(paths)) == len(paths),
            "guest-manifest-source-sorted", checks,
            "guest-resolver manifest sources must be unique and sorted by UTF-8 path bytes")

    actual_lines: List[str] = []
    for entry in sources:
        p = entry["path"]
        require(isinstance(p, str) and 0 < len(p.encode("utf-8")) <= GUEST_SOURCE_PATH_MAX
                and GUEST_SAFE_REL.match(p) is not None
                and all(part not in ("", ".", "..") for part in p.split("/")),
                "guest-source-path-safe", checks,
                f"guest-resolver source path {p!r} is not a safe module-relative path "
                "(absolute, traversal, empty or oversized paths are rejected)")
        src = gdir / p
        if src.is_symlink():
            raise ProduceError(f"guest-resolver source {src} is a symlink (frozen module "
                               "inputs must be material files)")
        if not src.is_file():
            raise ProduceError(f"guest-resolver source missing: {src}")
        check_name(p, f"guest-resolver source {p}")
        data = text_or_reject(src, f"guest-resolver source {p}")
        actual_sha = hashlib.sha256(data).hexdigest()
        require(actual_sha == entry["sha256"] and isinstance(entry["bytes"], int)
                and not isinstance(entry["bytes"], bool)
                and entry["bytes"] == len(data),
                "guest-source-hash-matches", checks,
                f"guest-resolver source {p} hashes to {actual_sha}/{len(data)} bytes, "
                f"manifest claims {entry['sha256']}/{entry['bytes']}")
        files[f"guest-resolver/{p}"] = (data, 0o644)
        actual_lines.append(f"{actual_sha}  {p}\n")

    actual_tree = hashlib.sha256("".join(actual_lines).encode("utf-8")).hexdigest()
    require(man.get("sourceTreeSha256") == actual_tree, "guest-source-tree-matches", checks,
            f"guest-resolver sourceTreeSha256 {man.get('sourceTreeSha256')} does not "
            f"match the recomputed tree {actual_tree} over the actual module inputs "
            "(sorted '<sha256>  <path>' lines); the manifest no longer describes the "
            "frozen source set")

    files["guest-resolver-manifest.json"] = (man_bytes, 0o644)
    require(True, "guest-resolver-bound", checks, "", {
        "protocol": GUEST_PROTOCOL,
        "sourceTreeSha256": actual_tree,
        "binary": bininfo,
        "manifestSha256": hashlib.sha256(man_bytes).hexdigest(),
        "sourceCount": len(sources),
    })
    return {"protocol": GUEST_PROTOCOL, "sourceTreeSha256": actual_tree,
            "binary": bininfo, "toolchain": tc, "exports": GUEST_REQUIRED_EXPORTS,
            "sources": [dict(entry) for entry in sources],
            "manifestSha256": hashlib.sha256(man_bytes).hexdigest()}


def resolve_upstream(cache: Path, url: str, sha: str, alias: Optional[str],
                     what: str) -> Tuple[Path, str]:
    names = [url.rsplit("/", 1)[-1]]
    if alias and alias not in names:
        names.append(alias)
    found: Optional[Tuple[Path, str]] = None
    for name in names:
        path = cache / name
        if path.is_file():
            actual = sha256_file(path)
            if actual != sha:
                raise ProduceError(
                    f"{what} cache file {name} hash {actual} != pinned {sha}; the "
                    "retained upstream source must match the pin byte-for-byte"
                )
            if found is None:
                found = (path, name)
    if found is None:
        raise ProduceError(
            f"{what} pinned archive not present under --upstream-cache {cache} "
            f"(expected one of {names}, sha256 {sha}); pass the canonical pinned "
            "download location — this tool never fetches or accepts an unpinned file"
        )
    return found


def require(cond: bool, name: str, checks: List[Dict[str, object]], error: str,
            detail: object = None) -> None:
    if not cond:
        raise ProduceError(error)
    checks.append({"id": name, "ok": True, "detail": detail})


def load_and_validate(args: argparse.Namespace) -> Dict[str, object]:
    checks: List[Dict[str, object]] = []
    files: Dict[str, Tuple[bytes, int]] = {}  # archive-relative -> (bytes, mode)

    # ---- release/version binding ----------------------------------------------
    version = args.release_version
    require(bool(VERSION_RE.match(version)), "release-version-grammar", checks,
            f"release version {version!r} must match the stage-release grammar")
    commit = args.source_commit
    require(bool(COMMIT_RE.match(commit)), "source-commit-grammar", checks,
            f"source commit {commit!r} must be 40 or 64 hex characters")

    # ---- private same-length host-run mapping (optional input; never recorded) --
    if args.host_run_mapping:
        host_rules, host_frags = load_host_run_mapping(Path(args.host_run_mapping))
        require(True, "host-run-mapping", checks, "",
                {"ruleCount": len(host_rules),
                 "ruleIds": [rid for rid, _, _ in host_rules]})
    else:
        host_rules, host_frags = [], ()

    # ---- provenance of the FINAL frozen native payloads ------------------------
    prov_path = Path(args.provenance)
    if not prov_path.is_file():
        raise ProduceError(f"provenance file missing: {prov_path}")
    prov = json.loads(text_or_reject(prov_path, "provenance").decode("utf-8"))
    recipe_sha_recorded = prov.get("recipe_tree_sha256")
    pins = prov.get("pins") or {}
    prov_proot = pins.get("proot") or {}
    prov_talloc = pins.get("talloc") or {}
    outputs = prov.get("outputs_sha256") or {}
    patch_info = (prov.get("patches") or {}).get("tracee-event-exitkill") or {}
    require(isinstance(recipe_sha_recorded, str) and SHA256_RE.match(recipe_sha_recorded) is not None,
            "provenance-recipe-hash", checks,
            "provenance lacks a valid recipe_tree_sha256", recipe_sha_recorded)
    require(bool(outputs), "provenance-payload-hashes", checks,
            "provenance lacks outputs_sha256 (the shipped-payload binding)",
            sorted(outputs))
    shipped: Dict[str, str] = {}
    for key in SHIPPED_PAYLOADS:
        val = outputs.get(key)
        require(isinstance(val, str) and SHA256_RE.match(val) is not None,
                "shipped-payload-bindings", checks,
                f"provenance outputs_sha256 must bind the shipped executable "
                f"payload {key!r} to a valid sha256 (the public offer covers "
                f"exactly {list(SHIPPED_PAYLOADS)}; any other recorded output "
                "is private qualification evidence, never a shipped binary)",
                sorted(outputs))
        shipped[key] = val
    require(isinstance(prov_proot.get("url"), str)
            and isinstance(prov_proot.get("tarball_sha256"), str)
            and SHA256_RE.match(str(prov_proot["tarball_sha256"])) is not None,
            "provenance-proot-pin", checks, "provenance pins.proot is incomplete", prov_proot)
    require(isinstance(prov_talloc.get("url"), str)
            and isinstance(prov_talloc.get("tarball_sha256"), str)
            and SHA256_RE.match(str(prov_talloc["tarball_sha256"])) is not None,
            "provenance-talloc-pin", checks, "provenance pins.talloc is incomplete", prov_talloc)
    patch_rel = patch_info.get("file")
    patch_sha = patch_info.get("sha256")
    require(isinstance(patch_rel, str) and isinstance(patch_sha, str)
            and SHA256_RE.match(patch_sha) is not None,
            "provenance-patch-binding", checks,
            "provenance patch binding (file/sha256) missing", patch_info)

    # ---- recipe tree binds to provenance ---------------------------------------
    recipe_dir = Path(args.recipe_dir)
    rendered = {}
    entries = collect_recipe_tree(recipe_dir)
    recomputed = recipe_tree_sha256(recipe_dir, entries)
    require(recomputed == recipe_sha_recorded, "recipe-tree-binds-provenance", checks,
            f"recipe tree {recomputed} does not match provenance recipe_tree_sha256 "
            f"{recipe_sha_recorded}; archive must be produced from the frozen recipe "
            "that built the shipped payloads",
            {"recomputed": recomputed, "provenance": recipe_sha_recorded,
             "files": len(entries)})
    for rel in entries:
        src = recipe_dir / rel
        data = text_or_reject(src, f"recipe input {rel}")
        scope = rel.split("/", 1)[0]
        if scope in RECIPE_APSL_SCOPES and not rel.endswith(APSL_COMPILED_INPUT_SKIP):
            text = data.decode("utf-8")
            for marker in APSL_TEXT_MARKERS:
                require(marker not in text, "no-apple-apsl-in-recipe", checks,
                        f"recipe input {rel} contains {marker!r} — the Apple/APSL "
                        "queue.h is a rejected input (see THIRD_PARTY.md); the "
                        "producer fails the same way")
        pub_data, rc = mask_host_runs(data, host_rules, host_frags)
        if rc:
            rendered[f"native-build/{rel}"] = {
                "originalSha256": hashlib.sha256(data).hexdigest(),
                "publicSha256": hashlib.sha256(pub_data).hexdigest(),
                "maskedRunCounts": rc, "bytes": len(pub_data),
                "rule": "same-length host-identity run mask (producer 1.2.0)"}
        files[f"native-build/{rel}"] = (
            pub_data, 0o755 if (src.stat().st_mode & 0o111) else 0o644)

    # ---- pinned patch cross-bound ----------------------------------------------
    require(patch_rel in entries, "patch-inside-recipe-tree", checks,
            f"provenance patch {patch_rel} is not part of the frozen recipe tree")
    require(sha256_file(recipe_dir / patch_rel) == patch_sha, "patch-hash-matches", checks,
            f"patch {patch_rel} no longer matches its provenance hash {patch_sha}")

    # ---- producer script pins == provenance pins --------------------------------
    script_pins = parse_producer_pins(recipe_dir)
    require(script_pins["proot_url"] == prov_proot["url"]
            and script_pins["proot_sha"] == prov_proot["tarball_sha256"],
            "proot-pin-consistency", checks,
            f"build-bootstrap.sh PRoot pin {script_pins['proot_url']}@{script_pins['proot_sha']} "
            f"disagrees with provenance {prov_proot}", prov_proot)
    require(script_pins["talloc_url"] == prov_talloc["url"]
            and script_pins["talloc_sha"] == prov_talloc["tarball_sha256"],
            "talloc-pin-consistency", checks,
            f"build-bootstrap.sh talloc pin {script_pins['talloc_url']}@{script_pins['talloc_sha']} "
            f"disagrees with provenance {prov_talloc}", prov_talloc)

    # ---- upstream archives (byte-exact, verbatim) --------------------------------
    cache = Path(args.upstream_cache)
    if not cache.is_dir():
        raise ProduceError(f"upstream cache directory missing: {cache}")
    proot_path, _ = resolve_upstream(cache, prov_proot["url"], prov_proot["tarball_sha256"],
                                     script_pins["proot_name"], "PRoot")
    talloc_path, talloc_name = resolve_upstream(cache, prov_talloc["url"],
                                                prov_talloc["tarball_sha256"], None, "talloc")
    files[f"upstream/{script_pins['proot_name']}"] = (
        read_bounded(proot_path, MAX_UPSTREAM_BYTES, "PRoot archive"), 0o644)
    files[f"upstream/{talloc_name}"] = (
        read_bounded(talloc_path, MAX_UPSTREAM_BYTES, "talloc archive"), 0o644)
    require(True, "upstream-archives-pinned", checks, "", {
        "proot": {"url": prov_proot["url"], "sha256": prov_proot["tarball_sha256"],
                  "archive": f"upstream/{script_pins['proot_name']}"},
        "talloc": {"url": prov_talloc["url"], "sha256": prov_talloc["tarball_sha256"],
                   "archive": f"upstream/{talloc_name}"},
    })

    # ---- third-party obligations document ------------------------------------------
    tpd = Path(args.third_party_doc)
    tpd_text = text_or_reject(tpd, "THIRD_PARTY.md")
    tpd_pub, tpd_rc = mask_host_runs(tpd_text, host_rules, host_frags)
    if tpd_rc:
        rendered["third-party/THIRD_PARTY.md"] = {
            "originalSha256": hashlib.sha256(tpd_text).hexdigest(),
            "publicSha256": hashlib.sha256(tpd_pub).hexdigest(),
            "maskedRunCounts": tpd_rc, "bytes": len(tpd_pub),
            "rule": "same-length host-identity run mask (producer 1.2.0)"}
    files["third-party/THIRD_PARTY.md"] = (tpd_pub, 0o644)
    require(True, "third-party-doc", checks, "",
            {"sha256": hashlib.sha256(tpd_pub).hexdigest()})

    # ---- distributable license texts ------------------------------------------------
    if not args.license_dir:
        raise ProduceError("at least one --license-dir NAME=PATH is required")
    license_index: Dict[str, str] = {}
    for spec in args.license_dir:
        if "=" not in spec:
            raise ProduceError(f"--license-dir must be NAME=PATH, got {spec!r}")
        leaf, raw = spec.split("=", 1)
        if not LICENSE_NAME_RE.match(leaf):
            raise ProduceError(f"license group name {leaf!r} is not a safe archive segment")
        base = Path(raw)
        if not base.is_dir():
            raise ProduceError(f"license directory missing for group {leaf}: {base}")
        seen = 0
        for path in sorted(base.rglob("*"), key=lambda p: str(p)):
            if path.is_symlink() or not path.is_file():
                raise ProduceError(f"license group {leaf} contains a non-regular entry {path}")
            rel = str(path.relative_to(base))
            check_name(rel, f"license file {leaf}/{rel}")
            data = text_or_reject(path, f"license file {leaf}/{rel}")
            files[f"third-party-licenses/{leaf}/{rel}"] = (data, 0o644)
            license_index[f"{leaf}/{rel}"] = hashlib.sha256(data).hexdigest()
            seen += 1
        if seen == 0:
            raise ProduceError(f"license group {leaf} is empty")
    require(bool(license_index), "license-texts", checks,
            "no license texts collected", license_index)
    if args.mpl_license:
        mpl = text_or_reject(Path(args.mpl_license), "Floe MPL-2.0 license")
        require(mpl.startswith(b"Mozilla Public License Version 2.0"), "mpl-license-head", checks,
                "--mpl-license is not the MPL-2.0 text")
        files["LICENSE-MPL-2.0.txt"] = (mpl, 0o644)

    # ---- optional relink evidence (exact allowlist only) ------------------------------
    relink_index: Dict[str, str] = {}
    if args.relink_evidence:
        root = Path(args.relink_evidence)
        if not root.is_dir():
            raise ProduceError(f"relink evidence directory missing: {root}")
        present = [rel for rel in RELINK_ALLOWLIST if (root / rel).is_file()]
        missing = [rel for rel in RELINK_REQUIRED if rel not in present]
        require(not missing, "relink-evidence-complete", checks,
                f"relink evidence lacks {missing} under {root}; pass the producer "
                "build/ export directory carrying the talloc objects/archive")
        for rel in present:
            data = read_bounded(root / rel, MAX_RELINK_BYTES, f"relink object {rel}")
            pub_data, rc = mask_host_runs(data, host_rules, host_frags)
            if rc:
                rendered[f"relink/{rel}"] = {
                    "originalSha256": hashlib.sha256(data).hexdigest(),
                    "publicSha256": hashlib.sha256(pub_data).hexdigest(),
                    "maskedRunCounts": rc, "bytes": len(pub_data),
                    "rule": "same-length host-identity run mask (producer 1.2.0)"}
            files[f"relink/{rel}"] = (pub_data, 0o644)
            relink_index[rel] = hashlib.sha256(pub_data).hexdigest()
        require(True, "relink-evidence", checks, "", relink_index)

    # ---- optional guest-resolver module (all-or-none; see docstring) ----------
    guest = validate_guest_resolver(args, recipe_dir, files, checks)

    # ---- size budget -------------------------------------------------------------------
    total_payload = sum(len(data) for data, _ in files.values())
    require(total_payload <= MAX_TOTAL_BYTES, "archive-size-budget", checks,
            f"archive content {total_payload} bytes exceeds the {MAX_TOTAL_BYTES}-byte budget")

    # ---- generated offer document + manifest --------------------------------------------
    offer = render_offer_document(args, prov, commit, version, shipped,
                                  bool(args.relink_evidence), guest)
    files["CORRESPONDING-SOURCE.md"] = (offer.encode("utf-8"), 0o644)

    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "tool": {"name": TOOL_NAME, "version": TOOL_VERSION},
        "offer": {
            "binaries": sorted(shipped),
            "combinedBinaryLicense": ("GPL-3.0-or-later (exercising the per-file "
                                      "GPL-2.0-or-later option of the maintained PRoot fork; "
                                      "required for compatibility with the statically linked "
                                      "LGPL-3.0-or-later talloc)"),
            "relinkPath": ("relink/ objects + native-build recipe (included)"
                           if args.relink_evidence else
                           "native-build recipe reproduces identical objects from the "
                           "upstream archives for modification and relink"),
            "floeOwnedSource": f"public repository at {commit} (MPL-2.0; not copied here)",
        },
        "releaseVersion": version,
        "sourceCommit": commit,
        "recipeTreeSha256": recomputed,
        "provenance": {
            "producer": prov.get("producer"),
            "generatedUtc": prov.get("generated_utc"),
            "payloadsSha256": shipped,
            "patch": patch_info,
        },
        "pins": {"proot": prov_proot, "talloc": prov_talloc},
        "renderedCopies": rendered,
        **({"guestResolver": guest} if guest is not None else {}),
        "archive": {"rootPrefix": ARCHIVE_ROOT_FMT.format(version=version),
                    "mtimeEpoch": EPOCH_MTIME, "ordering": "byte-sorted",
                    "format": "ustar-in-gzip(mtime=0)"},
        "files": [
            {"path": rel, "sha256": hashlib.sha256(data).hexdigest(),
             "bytes": len(data), "mode": oct(mode)}
            for rel, (data, mode) in sorted(files.items(),
                                            key=lambda kv: kv[0].encode("utf-8"))
        ],
        "exclusions": [
            "build host tools (Zig, Android NDK/SDK) — used, not redistributed",
            "Debian guest rootfs — outside this offer; distribution decisions belong to Main",
            "any private toolchain, keystore, credential, log, evidence or device artifact",
            "binaries other than the two pinned upstream archives"
            + ("" if not args.relink_evidence else
               " and the allowlisted talloc relink objects")
            + ("" if guest is None else
               "; the compiled guest helper binary is referenced by hash through "
               "guest-resolver-manifest.json, not redistributed as source-adjacent payload"),
        ],
        "limitations": [
            "This archive binds the recipe/pins/patch to the recorded native payload provenance by hash; proving the shipped APK carried those exact payload bytes remains the release readback (native manifest + Main's final verification), not this tool.",
            "Upstream archives are included byte-exact; their integrity against the public URLs was established at producer fetch time (hash-pinned).",
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
        "archiveName": ARCHIVE_NAME_FMT.format(version=version),
        "archiveSha256": hashlib.sha256(tar_bytes).hexdigest(),
        "archiveBytes": len(tar_bytes),
        "fileCount": len(files),
        "checks": checks,
        "_tar_bytes": tar_bytes,
        "_manifest_bytes": manifest_bytes,
    }


def render_offer_document(args: argparse.Namespace, prov: Dict[str, object], commit: str,
                          version: str, outputs: Dict[str, str], relink: bool,
                          guest: Optional[Dict[str, object]] = None) -> str:
    pins = prov["pins"]
    proot = pins["proot"]
    talloc = pins["talloc"]
    patch = (prov.get("patches") or {}).get("tracee-event-exitkill") or {}
    lines = [
        "# Corresponding source — Floe Agent Android Linux-runtime native helper",
        "",
        f"Bound to product version `{version}` and public source commit `{commit}`.",
        "Shipped payloads (the executable binaries the release APK packages,",
        "bound by the native-payloads producer run provenance):",
        "",
    ]
    for name in sorted(outputs):
        lines.append(f"- `{name}` — sha256 `{outputs[name]}`")
    lines += [
        "",
        "## What this archive is",
        "",
        "`libproot.so` and `libproot_loader.so` are built from the Termux-maintained",
        "PRoot fork with statically linked talloc 2.4.2. Per-file upstream notices",
        "are GPL-2.0-or-later (STMicroelectronics lineage) and talloc is",
        "LGPL-3.0-or-later, so the combined binary is offered here under",
        "**GPL-3.0-or-later** (exercising the per-file “or later” option),",
        "whose terms are compatible with the statically linked library. The complete",
        "corresponding source is exactly:",
        "",
        f"1. `upstream/` — the pinned upstream archives used verbatim (zero edits):",
        f"   PRoot {proot['url']} (sha256 `{proot['tarball_sha256']}`),",
        f"   talloc {talloc['url']} (sha256 `{talloc['tarball_sha256']}`).",
        "2. `native-build/` — the producer recipe at the frozen revision (tree sha256",
        f"   `{prov['recipe_tree_sha256']}`): `build-bootstrap.sh`, `PINS.md` and the",
        "   compat/config/cross/patches inputs. It contains the only upstream-file",
        f"   edit: `{patch.get('file')}` (sha256 `{patch.get('sha256')}`; ",
        f"   `src/tracee/event.c` {patch.get('before_sha256')} -> {patch.get('after_sha256')}),",
        "   the pinned EXITKILL lifecycle patch; original file notices are preserved.",
        "3. `third-party/THIRD_PARTY.md` and `third-party-licenses/` — the verified",
        "   per-component obligations and the retained license texts.",
    ]
    if relink:
        lines += [
            "4. `relink/` — the exact talloc objects and static archive as built for",
            "   the shipped payload, so recipients can modify and relink without",
            "   reproducing the build toolchain (LGPL-3 static-link path).",
        ]
    if guest is not None:
        lines += [
            "",
            "## Guest DNS resolver helper (`libnss_floe.so.2`)",
            "",
            "The Floe-owned glibc NSS module for the guest DNS bridge v1",
            f"(protocol `{guest['protocol']}`) ships its complete source here:",
            "`guest-resolver/` — `libnss_floe.c`, `nss-floe.map`, the pinned",
            "producer `build-guest-resolver.sh` and `PROTOCOL.json`; bound by",
            f"source-tree hash `{guest['sourceTreeSha256']}` and by the producer",
            "manifest at `guest-resolver-manifest.json`",
            f"(binary `libnss_floe.so.2`, sha256 `{guest['binary']['sha256']}`, "
            f"{guest['binary']['bytes']} bytes, toolchain "
            f"{guest['toolchain']['name']} {guest['toolchain']['version']}).",
            "The module source is MPL-2.0 (see `third-party/THIRD_PARTY.md`);",
            "it contains no third-party code and links against nothing at build",
            "time (it resolves against the guest's own loaded glibc at dlopen).",
        ]
    lines += [
        "",
        "Floe-owned adapter code (Kotlin launcher, `floe_pty_jni.c`, CMake, scripts,",
        "docs) is MPL-2.0 and lives in the public repository at the bound commit",
        "above; it is referenced, not copied, to keep this archive minimal.",
        "",
        "## How to build / relink",
        "",
        "```bash",
        "# Whitespace-free work tree required (see native-build/PINS.md); host tools",
        "# Zig 0.14.1 (MIT) and Android NDK 30.0.16248370 are build-time only.",
        "bash FloeAndroid/core/linuxruntime/native-build/build-bootstrap.sh \\",
        "  --out OUT --cache CACHE --work WORK --jobs 6",
        "```",
        "",
        "The recipe verifies every pinned hash, applies the single patch with its",
        "before/after assertions, replaces the upstream makefile's unreliable exit",
        "signalling with object-set/log/ELF gates, and writes `provenance.json`",
        "whose `recipe_tree_sha256` and `outputs_sha256` must match the values bound",
        "in `MANIFEST.json`. Relinking a modified library: compile the two talloc",
        "TUs and the full PRoot object set with the recorded env CFLAGS/LDFLAGS",
        "(PINS.md §Applied build deltas, generated `build.h`/`loader-info.c` hashes",
        "as acceptance gates) and link per the recipe — `relink/libtalloc.members.txt`",
        "lists the exact archive membership when objects are included.",
        "",
        "## Exclusions",
        "",
        "- The Zig tool, Android NDK and SDK are host build tools and are not",
        "  redistributed (their license positions are in `third-party/THIRD_PARTY.md`).",
        "- The Debian guest rootfs is not part of this offer; its redistribution",
        "  decision belongs to Main with device evidence.",
        "- No private toolchain, credential, key, log or device artifact is included.",
        "",
    ]
    return "\n".join(lines)


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
    # Byte-sorted on the slash-stripped name: tar readers normalise directory
    # entries by dropping the trailing '/', and this order puts each parent
    # immediately before its children while staying deterministic.
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
        raise ProduceError(f"refusing to replace existing {target}")
    tmp = out_dir / (name + ".part")
    with tmp.open("wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, target)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Produce the minimal reproducible public corresponding-source "
                    "archive for the shipped native Linux-runtime helper")
    sub = parser.add_subparsers(dest="command", required=True)

    def add_shared(p: argparse.ArgumentParser) -> None:
        p.add_argument("--recipe-dir", required=True,
                       help="frozen FloeAndroid/core/linuxruntime/native-build tree")
        p.add_argument("--provenance", required=True,
                       help="provenance.json of the FINAL frozen native payloads producer run")
        p.add_argument("--upstream-cache", required=True,
                       help="directory carrying the byte-exact pinned upstream archives")
        p.add_argument("--third-party-doc", required=True,
                       help="frozen FloeAndroid/core/linuxruntime/THIRD_PARTY.md")
        p.add_argument("--license-dir", action="append", default=[], metavar="NAME=PATH",
                       help="distributable license directory; repeatable")
        p.add_argument("--mpl-license",
                       help="optional path to the repository MPL-2.0 LICENSE file")
        p.add_argument("--relink-evidence",
                       help="optional producer build/ export directory (allowlisted talloc objects only)")
        p.add_argument("--guest-resolver-dir",
                       help="optional frozen native-build/guest-resolver source directory "
                            "(must be combined with --guest-resolver-manifest)")
        p.add_argument("--guest-resolver-manifest",
                       help="optional guest-resolver producer manifest.json binding the "
                            "module sources and shipped-binary hash")
        p.add_argument("--release-version", required=True,
                       help="product version this archive is offered with (same token as the tag)")
        p.add_argument("--source-commit", required=True,
                       help="frozen public commit the recipe/docs bind to (40 or 64 hex)")
        p.add_argument("--host-run-mapping",
                       help="optional private JSON file of same-length host-identity "
                            "run rules rendered into the public copies (schemaVersion/"
                            "rules/residualFragmentsB64, base64 byte runs); its path and "
                            "content never enter the archive or MANIFEST")

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
                raise ProduceError(f"output directory must be absent or empty: {out_dir}")
            out_dir.mkdir(parents=True, exist_ok=True)
            archive_name = str(report["archiveName"])
            write_atomically(out_dir, archive_name, tar_bytes)
            write_atomically(out_dir, "MANIFEST.json", manifest_bytes)
            archive_sha = hashlib.sha256(tar_bytes).hexdigest()
            manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()
            write_atomically(out_dir, "SHA256SUMS",
                             (f"{archive_sha}  {archive_name}\n"
                              f"{manifest_sha}  MANIFEST.json\n").encode("utf-8"))
            if sha256_file(out_dir / archive_name) != archive_sha:
                raise ProduceError("written archive does not match its computed hash")
            report["written"] = sorted(p.name for p in out_dir.iterdir())
    except ProduceError as exc:
        print(f"{TOOL_NAME}: FAIL {exc}", file=sys.stderr)
        return 1

    print(json.dumps(report, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
