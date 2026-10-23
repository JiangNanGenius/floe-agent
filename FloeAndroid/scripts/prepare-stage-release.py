#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Prepare one clean Android stage-release asset set from a signed APK.

The tool has two read-only/write-local subcommands:

``check``
    Verify the supplied APK in place and print a JSON report. It never writes
    to the APK, the repository, GitHub, or any output directory.

``prepare``
    Verify the supplied APK, copy the exact bytes into a private staging
    directory while hashing them a second time, then atomically publish:

        OUTPUT/
          Floe-Android-<version>-full-arm64.apk
          SHA256SUMS

    It also writes a separately addressed release-body input (Markdown) that
    is *not* part of the upload asset directory. No update feed, update.json,
    symbols, native libraries, logs, or release notes are added as assets.

This is deliberately not a publisher. It does not invoke ``gh``, git, adb,
Gradle, a compiler, or any signing command. Publication, tag creation,
version selection, signing identity, upload, readback, device installation
and coverage-upgrade acceptance remain Main's responsibility.

The checks are deliberately fail-closed:

* the APK must be explicitly signed and verify through the installed
  ``apksigner``; v2 or newer signing is required and debug signers are
  rejected;
* the merged binary manifest must name the expected package, versionCode,
  versionName, minSdk and targetSdk, and must not be debuggable, test-only,
  split, or an instrumentation/test package;
* the full distribution must be evidenced by the current full-only DEX marker
  classes, so a Play or test APK is not accepted because its filename says
  "release";
* the APK must be a single ``arm64-v8a`` artifact with native libraries that
  are stored, 16 KiB zip-aligned, 16 KiB ELF ``PT_LOAD``-aligned, carry build
  IDs, resolve their ``DT_NEEDED`` entries, and contain no meaningful
  ``.debug_*`` data;
* the supplied preverified SHA-256, source commit, tag and formal signer
  certificate are bound to the exact bytes that are staged and published;
* an existing non-empty destination is never replaced, and a failure leaves
  the staging area and any existing committed asset set untouched.

Known limitations are recorded in the report rather than silently converted
into success: source/qualification acceptance, runtime native equivalence
after stripping, actual upload/readback, and real coverage installation cannot
be proven by an offline checker.

Run ``--help`` for the complete CLI. The focused offline tests are in
``tests/test_prepare_stage_release.py``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Set, Tuple

TOOL_NAME = "prepare-stage-release"
TOOL_VERSION = "1.0.0"
SCHEMA_VERSION = 1

PAGE_16K = 16384
COPY_CHUNK = 1024 * 1024
MAX_APK_BYTES = 2 * 1024 * 1024 * 1024
MAX_ZIP_ENTRIES = 200000
MAX_ENTRY_BYTES = 512 * 1024 * 1024
MAX_TOTAL_UNCOMPRESSED = 3 * 1024 * 1024 * 1024
MAX_NATIVE_LIB_BYTES = 256 * 1024 * 1024
MAX_DEBUG_TOTAL_BYTES = 1024
MAX_DEBUG_SECTION_BYTES = 256
MAX_MANIFEST_JSON_BYTES = 5 * 1024 * 1024

CHECKSUM_FILENAME = "SHA256SUMS"
ANDROID_ABI = "arm64-v8a"
FULL_DISTRIBUTION = "full"

ANDROID_TAG_RE = re.compile(r"^android/v([0-9A-Za-z][0-9A-Za-z._+-]{0,63})$")
VERSION_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$")
PACKAGE_RE = re.compile(
    r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$"
)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SOURCE_COMMIT_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
REPOSITORY_RE = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$"
)
STAGE_LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._+-]{0,39}$")
NATIVE_LIBRARY_NAME_RE = re.compile(r"^[A-Za-z0-9._+-]+\.so$")
DEX_NAME_RE = re.compile(r"^classes\d*\.dex$")

# Current full-only marker classes. Their presence is a positive control that
# the artifact really is the GitHub/full distribution rather than Play or a
# test-only build. This mirrors the existing read-only check-apk.py boundary
# checker and intentionally fails closed if the classes are renamed/obfuscated.
FULL_ONLY_MARKERS = (
    "Lcom/floe/android/phonecontrol/PhoneControlModule;",
    "Lcom/floe/android/rootsystem/RootSystemModule;",
)
TEST_ONLY_NATIVE = {
    "libXCTest.so",
    "libTesting.so",
    "lib_TestingInterop.so",
    "lib_Testing_Foundation.so",
    "libfloe_qualification_jni.so",
}
REQUIRED_NATIVE = ("libFloeAndroidCore.so", "libfloe_jni.so")

# The ONE exception to the generic nested-package refusal. The formal
# full-channel app embeds exactly one independently signed Linux runtime
# installer component (the G03 architecture): the digest sidecar pair
# assets/linux-runtime/runtime.apk + runtime.apk.sha256. Only this exact
# layout may pass, and only after strict deep verification of the child:
# sidecar SHA-256 equality, a real apksigner verification whose signer
# certificate equals the formal identity, the expected runtime package
# (app package .full -> .runtime.full), versionCode/versionName/minSdk/
# targetSdk equality with the parent policy, arm64-v8a only, non-
# debuggable, non-test-only, no split, no instrumentation, no sharedUserId,
# legacy package-manager extraction of its executables, and no nested
# package or test-only native library inside the child, all with bounded
# extraction and sizes. Every other nested .apk/.aab entry, every
# unexpected asset sibling, every malformed or mismatched sidecar and every
# failed child check keeps the ORIGINAL generic
# ``zip.entry.nested-package`` refusal unchanged. There is no skip switch.
RUNTIME_CHILD_ASSET = "assets/linux-runtime/runtime.apk"
RUNTIME_CHILD_SIDECAR = "assets/linux-runtime/runtime.apk.sha256"
RUNTIME_CHILD_ASSET_DIR = "assets/linux-runtime/"
MAX_RUNTIME_CHILD_BYTES = 1024 * 1024 * 1024
MAX_RUNTIME_CHILD_SIDECAR_BYTES = 128
RUNTIME_REQUIRED_NATIVE = (
    "libFloeAndroidLinuxAuthority.so",
    "libfloe_linux_authority_jni.so",
    "libfloepty.so",
    "libproot.so",
    "libproot_loader.so",
)

# The pinned checkout debug identity observed on the qualification APK. The
# digest is public certificate metadata, not a secret. It is denied in
# addition to the Android Debug DN so a debug-signed artifact cannot be
# presented as formal merely by naming the expected digest.
KNOWN_DEBUG_CERT_SHA256 = {
    "44c68beed4bf95da6d1653b2b1f724dd879d72b9b4ff7dd6fdcb7487120a3789",
}
DEBUG_CERT_DN_RE = re.compile(r"(?:^|,\s*)CN=Android Debug(?:\s*,|$)", re.IGNORECASE)

# Public Android NDK system libraries (API 28+). A packaged library may depend
# on these by basename without shipping a copy; every other DT_NEEDED entry
# must resolve to another packaged lib/arm64-v8a entry.
ANDROID_PUBLIC_LIBRARIES = {
    "libEGL.so",
    "libGLESv1_CM.so",
    "libGLESv2.so",
    "libGLESv3.so",
    "libOpenMAXAL.so",
    "libOpenSLES.so",
    "libaaudio.so",
    "libamidi.so",
    "libandroid.so",
    "libc.so",
    "libcamera2ndk.so",
    "libdl.so",
    "libjnigraphics.so",
    "liblog.so",
    "libm.so",
    "libmediandk.so",
    "libnativewindow.so",
    "libneuralnetworks.so",
    "libsync.so",
    "libvulkan.so",
    "libz.so",
}

ELF_PT_LOAD = 1
ELF_PT_DYNAMIC = 2
ELF_PT_NOTE = 4
ELF_EM_AARCH64 = 183
ELF_DT_NULL = 0
ELF_DT_NEEDED = 1
ELF_DT_STRTAB = 5
ELF_DT_STRSZ = 10
ELF_SHT_STRTAB = 3
ELF_SHT_DYNSYM = 11
ELF_SHT_NOBITS = 8
ELF_STB_GLOBAL = 1
ELF_STB_WEAK = 2

PUBLICATION_BLOCK = {
    "performed": False,
    "mutatedGithub": False,
    "uploaded": False,
    "releaseCreated": False,
    "tagCreated": False,
    "latestFlag": "--latest=false",
    "repositoryLatest": (
        "reserved for the existing iOS stable release; Android must not "
        "capture repository releases/latest"
    ),
    "androidUpdateSelection": (
        "android/v<version> tags or a platform-filtered Android release feed; "
        "repository Latest is never an Android feed"
    ),
    "updaterMetadata": (
        "not generated: no implemented Android updater/feed schema exists at "
        "this stage; do not invent update.json"
    ),
}

LIMITATIONS = [
    "Static inspection only: the APK is not installed, launched, or exercised "
    "on a device by this tool.",
    "apksigner verifies the APK signature and prints the signer certificate "
    "digest; key possession, certificate policy, and Play acceptance are not "
    "verified here.",
    "A private-mocked signer/manifest fixture used by the unit tests is not "
    "evidence that a real formally signed APK passed; production CLI has no "
    "skip-verification switch.",
    "Native ELF layout/build-ID/export/dependency checks are packaging "
    "evidence, not proof that stripped/derived libraries are runtime "
    "equivalent to the canonical build; canonical-versus-derived hash "
    "differences are reported, never rewritten.",
    "Source commit, qualification evidence, unused version/tag, and stage "
    "maturity are supplied by Main. The tool binds the supplied artifact hash "
    "and metadata but cannot prove those prior decisions.",
    "GitHub publication, --latest=false enforcement, release readback, "
    "download hash comparison, and coverage upgrade installation are outside "
    "this offline tool.",
    "No Android update feed or update.json is implemented or emitted; this "
    "stage asset set supports manual installation only.",
    "The single embedded runtime installer asset is accepted only by deep "
    "child verification: exact asset plus digest sidecar pair, bounded "
    "extraction, real apksigner verification with signer-certificate "
    "equality against the formal identity, and the expected component "
    "package/version/SDK/ABI/UID/non-debuggable/extraction layout. There is "
    "no generic nested-package acceptance and no skip switch; every other "
    "nested artifact keeps the original refusal.",
]


class StageReleaseError(Exception):
    """A clear, bounded failure with a stable report identifier."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


class ElfError(Exception):
    """Malformed or unsupported ELF input."""


@dataclass
class ReleasePolicy:
    apk: Path
    expected_sha256: str
    package: str
    version_code: int
    version_name: str
    tag: str
    cert_sha256: str
    source_commit: str
    min_sdk: int
    target_sdk: int
    maturity: str
    source_repository: Optional[str] = None
    previous_version_code: Optional[int] = None
    previous_cert_sha256: Optional[str] = None
    previous_package: Optional[str] = None
    previous_release_tag: Optional[str] = None
    stage_label: Optional[str] = None
    native_manifest: Optional[Dict[str, Any]] = None
    native_manifest_role: str = "canonical"
    aapt2: Optional[Path] = None
    apksigner: Optional[Path] = None

    def asset_filename(self) -> str:
        return "Floe-Android-{}-{}-{}.apk".format(
            self.version_name, FULL_DISTRIBUTION, ANDROID_ABI
        )


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def normalize_sha256(value: str, label: str) -> str:
    if not isinstance(value, str):
        raise StageReleaseError("arg.sha256", "{} must be a SHA-256 hex string".format(label))
    normalized = value.strip().lower().replace(":", "")
    if not SHA256_RE.fullmatch(normalized):
        raise StageReleaseError(
            "arg.sha256",
            "{} must be exactly 64 hexadecimal characters".format(label),
        )
    return normalized


def normalize_source_commit(value: str) -> str:
    normalized = value.strip().lower()
    if not SOURCE_COMMIT_RE.fullmatch(normalized):
        raise StageReleaseError(
            "arg.source-commit",
            "source commit must be a 40- or 64-character hexadecimal Git object id",
        )
    return normalized


def validate_package(value: str, label: str = "package") -> str:
    normalized = value.strip()
    if not PACKAGE_RE.fullmatch(normalized) or len(normalized) > 255:
        raise StageReleaseError(
            "arg.package",
            "{} must be a dotted Android package name (for example "
            "com.floe.agent.full)".format(label),
        )
    lowered = normalized.lower()
    if (
        lowered.endswith(".dev")
        or lowered.endswith(".debug")
        or lowered.endswith(".test")
        or ".androidtest" in lowered
    ):
        raise StageReleaseError(
            "arg.package",
            "{} looks like a development/test package: {!r}".format(label, normalized),
        )
    return normalized


def validate_tag(value: str) -> Tuple[str, str]:
    match = ANDROID_TAG_RE.fullmatch(value.strip())
    if match is None:
        raise StageReleaseError(
            "arg.tag",
            "Android tag must match android/v<version> (for example "
            "android/v0.1.0-g02); got {!r}".format(value),
        )
    return value.strip(), match.group(1)


def validate_version_name(value: str) -> str:
    normalized = value.strip()
    if not VERSION_RE.fullmatch(normalized):
        raise StageReleaseError(
            "arg.version-name",
            "versionName must be 1-64 characters from [A-Za-z0-9._+-] and "
            "start with a letter or digit",
        )
    return normalized


def validate_source_repository(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    normalized = value.strip()
    if not REPOSITORY_RE.fullmatch(normalized):
        raise StageReleaseError(
            "arg.source-repository",
            "source repository must be a public GitHub OWNER/REPO identifier, "
            "not a URL or local path",
        )
    return normalized


def validate_stage_label(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    normalized = value.strip()
    if not STAGE_LABEL_RE.fullmatch(normalized):
        raise StageReleaseError(
            "arg.stage-label",
            "stage label must be 1-40 safe characters",
        )
    return normalized


def load_native_manifest(path_value: str) -> Dict[str, Any]:
    path = Path(path_value).expanduser()
    try:
        resolved = path.resolve(strict=True)
    except FileNotFoundError:
        raise StageReleaseError(
            "native-manifest.missing",
            "native manifest not found: {}".format(path),
        )
    if not resolved.is_file():
        raise StageReleaseError(
            "native-manifest.not-file",
            "native manifest is not a regular file: {}".format(path),
        )
    if resolved.stat().st_size > MAX_MANIFEST_JSON_BYTES:
        raise StageReleaseError(
            "native-manifest.too-large",
            "native manifest exceeds the bounded JSON size",
        )
    try:
        data = json.loads(resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as exc:
        raise StageReleaseError(
            "native-manifest.invalid",
            "native manifest is not readable JSON: {}".format(exc),
        )
    if not isinstance(data, dict):
        raise StageReleaseError(
            "native-manifest.invalid", "native manifest root must be an object"
        )
    if data.get("schemaVersion") != 1:
        raise StageReleaseError(
            "native-manifest.schema",
            "native manifest schemaVersion must be 1",
        )
    if data.get("abi") != ANDROID_ABI:
        raise StageReleaseError(
            "native-manifest.abi",
            "native manifest ABI must be {}".format(ANDROID_ABI),
        )
    libraries = data.get("libraries")
    if not isinstance(libraries, dict) or not libraries:
        raise StageReleaseError(
            "native-manifest.libraries",
            "native manifest must contain a non-empty libraries object",
        )
    normalized_libraries = {}
    for name, digest in libraries.items():
        if not isinstance(name, str) or not NATIVE_LIBRARY_NAME_RE.fullmatch(name):
            raise StageReleaseError(
                "native-manifest.libraries",
                "native manifest contains an invalid library name",
            )
        normalized_libraries[name] = normalize_sha256(
            digest, "native manifest library {}".format(name)
        )
    if "libFloeAndroidCore.so" not in normalized_libraries:
        raise StageReleaseError(
            "native-manifest.libraries",
            "native manifest must record libFloeAndroidCore.so",
        )
    input_digest = data.get("inputDigest")
    if input_digest is not None:
        input_digest = normalize_sha256(input_digest, "native manifest inputDigest")
    return {
        "inputDigest": input_digest,
        "libraries": normalized_libraries,
    }


def policy_from_args(args: argparse.Namespace) -> ReleasePolicy:
    apk_path = Path(args.apk).expanduser()
    try:
        apk = apk_path.resolve(strict=True)
    except FileNotFoundError:
        raise StageReleaseError("apk.missing", "APK not found: {}".format(apk_path))
    if not apk.is_file():
        raise StageReleaseError("apk.not-file", "APK is not a regular file: {}".format(apk_path))
    if not str(apk).lower().endswith(".apk"):
        raise StageReleaseError(
            "apk.extension",
            "input must be an .apk file (an AAB or renamed archive is rejected)",
        )

    tag, tag_version = validate_tag(args.tag)
    version_name = validate_version_name(args.version_name)
    if version_name != tag_version:
        raise StageReleaseError(
            "arg.version-name-mismatch",
            "versionName {!r} must exactly equal the android/v tag version "
            "{!r}".format(version_name, tag_version),
        )

    version_code = int(args.version_code)
    if version_code < 1 or version_code > 2_100_000_000:
        raise StageReleaseError(
            "arg.version-code",
            "versionCode must be between 1 and 2100000000",
        )

    package = validate_package(args.package)
    cert_sha256 = normalize_sha256(args.cert_sha256, "formal signer certificate")
    if cert_sha256 in KNOWN_DEBUG_CERT_SHA256:
        raise StageReleaseError(
            "arg.cert-debug",
            "the supplied formal signer digest is the known developer debug "
            "certificate; a debug artifact cannot be prepared as a formal "
            "release",
        )

    min_sdk = int(args.min_sdk)
    target_sdk = int(args.target_sdk)
    if min_sdk < 1 or target_sdk < 1 or min_sdk > target_sdk:
        raise StageReleaseError(
            "arg.sdk",
            "minSdk and targetSdk must be positive and minSdk <= targetSdk",
        )

    previous_fields = (
        args.previous_version_code,
        args.previous_cert_sha256,
        args.previous_package,
    )
    if any(value is not None for value in previous_fields) and not all(
        value is not None for value in previous_fields
    ):
        raise StageReleaseError(
            "arg.previous-incomplete",
            "previous-release continuity requires previous versionCode, "
            "certificate SHA-256 and package together (or none of them)",
        )

    previous_version_code = None
    previous_cert_sha256 = None
    previous_package = None
    if args.previous_version_code is not None:
        previous_version_code = int(args.previous_version_code)
        if previous_version_code < 1:
            raise StageReleaseError(
                "arg.previous-version-code",
                "previous versionCode must be positive",
            )
        if version_code <= previous_version_code:
            raise StageReleaseError(
                "arg.version-code-not-increasing",
                "current versionCode {} must be greater than the supplied "
                "previous versionCode {}".format(version_code, previous_version_code),
            )
        previous_cert_sha256 = normalize_sha256(
            args.previous_cert_sha256, "previous signer certificate"
        )
        if previous_cert_sha256 in KNOWN_DEBUG_CERT_SHA256:
            raise StageReleaseError(
                "arg.previous-cert-debug",
                "the previous release certificate is the known developer debug "
                "certificate; signing identity continuity is not formal",
            )
        previous_package = validate_package(args.previous_package, "previous package")
        if previous_package != package:
            raise StageReleaseError(
                "arg.previous-package-mismatch",
                "previous package {!r} does not match current package "
                "{!r}".format(previous_package, package),
            )
        if previous_cert_sha256 != cert_sha256:
            raise StageReleaseError(
                "arg.previous-cert-mismatch",
                "previous signer certificate does not match the intended formal "
                "signer; stable upgrade continuity requires the same identity",
            )

    previous_release_tag = None
    if args.previous_release_tag:
        previous_release_tag, _ = validate_tag(args.previous_release_tag)
        if previous_release_tag == tag:
            raise StageReleaseError(
                "arg.previous-tag-same",
                "previous release tag is the same as the current tag",
            )

    native_manifest = None
    if args.native_manifest:
        native_manifest = load_native_manifest(args.native_manifest)

    return ReleasePolicy(
        apk=apk,
        expected_sha256=normalize_sha256(args.expected_sha256, "expected artifact"),
        package=package,
        version_code=version_code,
        version_name=version_name,
        tag=tag,
        cert_sha256=cert_sha256,
        source_commit=normalize_source_commit(args.source_commit),
        min_sdk=min_sdk,
        target_sdk=target_sdk,
        maturity=args.maturity,
        source_repository=validate_source_repository(args.source_repository),
        previous_version_code=previous_version_code,
        previous_cert_sha256=previous_cert_sha256,
        previous_package=previous_package,
        previous_release_tag=previous_release_tag,
        stage_label=validate_stage_label(args.stage_label),
        native_manifest=native_manifest,
        native_manifest_role=args.native_manifest_role,
        aapt2=Path(args.aapt2).expanduser() if args.aapt2 else None,
        apksigner=Path(args.apksigner).expanduser() if args.apksigner else None,
    )


# ---------------------------------------------------------------------------
# Discovery and external read-only tools
# ---------------------------------------------------------------------------


def _version_sort_key(name: str) -> Tuple[int, ...]:
    return tuple(
        int(part) if part.isdigit() else 0
        for part in re.split(r"[.\-]", name)
    )


def _build_tools_binary(sdk: Path, name: str) -> Optional[Path]:
    build_tools = sdk / "build-tools"
    if not build_tools.is_dir():
        return None
    candidates = []
    for child in build_tools.iterdir():
        binary = child / name
        if binary.is_file():
            candidates.append((_version_sort_key(child.name), binary))
    if not candidates:
        return None
    candidates.sort(key=lambda item: item[0])
    return candidates[-1][1]


def find_sdk_tool(name: str, explicit: Optional[str], flag: str) -> Path:
    if explicit:
        path = Path(explicit).expanduser()
        if path.is_file():
            return path.resolve()
        found = shutil.which(explicit)
        if found:
            return Path(found).resolve()
        raise StageReleaseError(
            "tool.{}".format(name),
            "{} was not found (pass {} PATH or set ANDROID_HOME)".format(name, flag),
        )

    sdk_roots = []
    for variable in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        value = os.environ.get(variable)
        if value:
            sdk_roots.append(Path(value).expanduser())
    sdk_roots.extend(
        [
            Path.home() / "Library" / "Android" / "sdk",
            Path("/opt/homebrew/share/android-commandlinetools"),
            Path("/usr/local/share/android-commandlinetools"),
        ]
    )
    for sdk in sdk_roots:
        binary = _build_tools_binary(sdk, name)
        if binary is not None:
            return binary.resolve()

    found = shutil.which(name)
    if found:
        return Path(found).resolve()
    raise StageReleaseError(
        "tool.{}".format(name),
        "{} was not found; set ANDROID_HOME or pass {} PATH (checks fail "
        "closed rather than being skipped)".format(name, flag),
    )


def run_readonly_tool(command: Sequence[str], timeout: int = 240) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            list(command),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        raise StageReleaseError(
            "tool.exec",
            "tool not found while running {}".format(command[0]),
        )
    except OSError as exc:
        raise StageReleaseError(
            "tool.exec",
            "{} could not be executed: {}".format(command[0], exc),
        )
    except subprocess.TimeoutExpired:
        raise StageReleaseError(
            "tool.timeout",
            "{} did not finish within {} seconds".format(command[0], timeout),
        )


def tool_version(command: Sequence[str]) -> str:
    proc = run_readonly_tool(command, timeout=60)
    lines = (proc.stdout or "").strip().splitlines()
    if not lines:
        # aapt2 prints its version to stderr while returning success.
        lines = (proc.stderr or "").strip().splitlines()
    if proc.returncode != 0 or not lines:
        detail = (proc.stderr or "").strip() or (proc.stdout or "").strip()
        if "Java Runtime" in detail:
            detail += " (set JAVA_HOME to a working JDK)"
        raise StageReleaseError(
            "tool.version",
            "{} is not usable: {}".format(command[0], detail[:500]),
        )
    return lines[0].strip()[:200]


# ---------------------------------------------------------------------------
# Binary manifest parsing (aapt2)
# ---------------------------------------------------------------------------


_ATTRIBUTE_RE = re.compile(r'^\s*A: (.*?)=(?:"(.*?)"|([^\s"]+))')
_ELEMENT_RE = re.compile(r"^(\s*)E: (\S+)")


def parse_xmltree(text: str) -> Dict[str, Any]:
    """Build a minimal tree from ``aapt2 dump xmltree`` output."""

    root = {"tag": None, "attrs": {}, "children": [], "depth": -1}
    stack = [root]
    for line in text.splitlines():
        match = _ELEMENT_RE.match(line)
        if match:
            depth = len(match.group(1))
            node = {
                "tag": match.group(2),
                "attrs": {},
                "children": [],
                "depth": depth,
            }
            while stack and stack[-1]["depth"] >= depth:
                stack.pop()
            stack[-1]["children"].append(node)
            stack.append(node)
            continue
        match = _ATTRIBUTE_RE.match(line)
        if match and len(stack) > 1:
            key = re.sub(r"\(0x[0-9a-fA-F]+\)$", "", match.group(1))
            if ":" in key:
                key = key.rsplit(":", 1)[1]
            value = match.group(2) if match.group(2) is not None else match.group(3)
            stack[-1]["attrs"][key] = value
    if not root["children"]:
        raise StageReleaseError(
            "aapt2.xmltree", "aapt2 returned no manifest elements"
        )
    return root["children"][0]


def walk_nodes(node: Dict[str, Any]) -> Iterable[Dict[str, Any]]:
    yield node
    for child in node["children"]:
        for descendant in walk_nodes(child):
            yield descendant


def _int_attr(value: Optional[str], label: str) -> Optional[int]:
    if value is None:
        return None
    if value.startswith("@") or value.startswith("?"):
        return None
    try:
        return int(value, 0)
    except (TypeError, ValueError):
        return None


def _bool_attr(value: Optional[str]) -> Optional[bool]:
    if value is None:
        return None
    lowered = value.strip().lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    return None


def manifest_tree_facts(root: Dict[str, Any]) -> Dict[str, Any]:
    nodes = list(walk_nodes(root))
    manifest_node = next(
        (node for node in nodes if node["tag"] == "manifest"), None
    )
    if manifest_node is None:
        raise StageReleaseError("aapt2.manifest", "binary manifest has no manifest element")
    attrs = manifest_node["attrs"]
    uses_sdk = next((node for node in nodes if node["tag"] == "uses-sdk"), None)
    application = next(
        (node for node in nodes if node["tag"] == "application"), None
    )
    app_attrs = application["attrs"] if application else {}
    test_only = _bool_attr(attrs.get("testOnly"))
    if test_only is None:
        test_only = _bool_attr(app_attrs.get("testOnly"))
    return {
        "package": attrs.get("package"),
        "versionCode": _int_attr(attrs.get("versionCode"), "versionCode"),
        "versionName": attrs.get("versionName"),
        "minSdk": _int_attr(
            uses_sdk["attrs"].get("minSdkVersion") if uses_sdk else None,
            "minSdkVersion",
        ),
        "targetSdk": _int_attr(
            uses_sdk["attrs"].get("targetSdkVersion") if uses_sdk else None,
            "targetSdkVersion",
        ),
        "debuggable": _bool_attr(app_attrs.get("debuggable")) is True,
        "testOnly": test_only is True,
        "split": attrs.get("split") or None,
        "extractNativeLibs": _bool_attr(app_attrs.get("extractNativeLibs")),
        "sharedUserId": attrs.get("sharedUserId")
        or app_attrs.get("sharedUserId")
        or None,
        "hasInstrumentation": any(node["tag"] == "instrumentation" for node in nodes),
        "applicationLabel": app_attrs.get("label"),
    }


def manifest_facts(aapt2: Path, apk: Path) -> Dict[str, Any]:
    proc = run_readonly_tool(
        [str(aapt2), "dump", "xmltree", "--file", "AndroidManifest.xml", str(apk)]
    )
    if proc.returncode != 0:
        detail = (proc.stderr or "").strip() or (proc.stdout or "").strip()
        raise StageReleaseError(
            "aapt2.manifest",
            "aapt2 could not read the binary manifest: {}".format(detail[:500]),
        )
    return manifest_tree_facts(parse_xmltree(proc.stdout))


def parse_badging_output(text: str) -> Dict[str, Any]:
    package_line = None
    native_code = None
    for line in text.splitlines():
        if line.startswith("package: ") and package_line is None:
            package_line = line
        elif line.startswith("native-code:") and native_code is None:
            native_code = line
    if package_line is None:
        raise StageReleaseError("aapt2.badging", "aapt2 badging has no package line")
    match = re.match(
        r"^package: name='([^']*)' versionCode='([^']*)' versionName='([^']*)'",
        package_line,
    )
    if match is None:
        raise StageReleaseError(
            "aapt2.badging",
            "aapt2 badging package line has an unexpected shape",
        )
    abis = re.findall(r"'([^']*)'", native_code) if native_code else []
    return {
        "package": match.group(1),
        "versionCode": match.group(2),
        "versionName": match.group(3),
        "abis": abis,
    }


def badging_facts(aapt2: Path, apk: Path) -> Dict[str, Any]:
    proc = run_readonly_tool([str(aapt2), "dump", "badging", str(apk)])
    if proc.returncode != 0:
        detail = (proc.stderr or "").strip() or (proc.stdout or "").strip()
        raise StageReleaseError(
            "aapt2.badging",
            "aapt2 could not read APK badging: {}".format(detail[:500]),
        )
    return parse_badging_output(proc.stdout)


# ---------------------------------------------------------------------------
# APK container, DEX and signing checks
# ---------------------------------------------------------------------------


def _zip_name_problem(name: str) -> Optional[Tuple[str, str]]:
    if not name:
        return ("zip.entry.empty", "zip contains an empty entry name")
    if "\x00" in name:
        return ("zip.entry.nul", "zip entry name contains NUL")
    if name.startswith("/"):
        return ("zip.entry.absolute", "zip entry uses an absolute path: {!r}".format(name))
    if "\\" in name:
        return ("zip.entry.backslash", "zip entry uses a backslash: {!r}".format(name))
    if re.match(r"^[A-Za-z]:", name):
        return ("zip.entry.drive", "zip entry uses a drive path: {!r}".format(name))
    if len(name) > 4096:
        return ("zip.entry.long", "zip entry name is too long")
    if any(ord(character) < 32 for character in name):
        return ("zip.entry.control", "zip entry name contains a control character")
    parts = name.rstrip("/").split("/")
    if any(part in ("", ".", "..") for part in parts):
        return (
            "zip.entry.traversal",
            "zip entry has a path traversal/empty segment: {!r}".format(name),
        )
    return None


def zip_structure_facts(path: Path) -> Dict[str, Any]:
    problems = []
    names = []
    seen = set()
    total_uncompressed = 0
    with zipfile.ZipFile(str(path), "r") as archive:
        infos = archive.infolist()
        if len(infos) > MAX_ZIP_ENTRIES:
            problems.append(
                {
                    "id": "zip.entries.too-many",
                    "message": "zip has {} entries (limit {})".format(
                        len(infos), MAX_ZIP_ENTRIES
                    ),
                }
            )
        for info in infos:
            name = info.filename
            names.append(name)
            problem = _zip_name_problem(name)
            if problem:
                problems.append({"id": problem[0], "message": problem[1]})
            if name in seen:
                problems.append(
                    {
                        "id": "zip.entry.duplicate",
                        "message": "zip contains duplicate entry {!r}".format(name),
                    }
                )
            seen.add(name)
            mode = (info.external_attr >> 16) & 0xFFFF
            if stat.S_ISLNK(mode):
                problems.append(
                    {
                        "id": "zip.entry.symlink",
                        "message": "zip contains a symlink entry {!r}".format(name),
                    }
                )
            if info.flag_bits & 0x1:
                problems.append(
                    {
                        "id": "zip.entry.encrypted",
                        "message": "zip contains an encrypted entry {!r}".format(name),
                    }
                )
            if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                problems.append(
                    {
                        "id": "zip.entry.compression",
                        "message": "zip entry {!r} uses unsupported compression".format(name),
                    }
                )
            if info.file_size > MAX_ENTRY_BYTES:
                problems.append(
                    {
                        "id": "zip.entry.size",
                        "message": "zip entry {!r} exceeds the bounded entry size".format(name),
                    }
                )
            total_uncompressed += info.file_size
            if name == "BundleConfig.pb" or name.startswith("base/manifest/"):
                problems.append(
                    {
                        "id": "input.aab",
                        "message": "input looks like an Android App Bundle, not an APK",
                    }
                )
            if name.lower().endswith((".apk", ".aab")):
                problems.append(
                    {
                        "id": "zip.entry.nested-package",
                        "message": "APK contains a nested package artifact {!r}".format(name),
                    }
                )
    if total_uncompressed > MAX_TOTAL_UNCOMPRESSED:
        problems.append(
            {
                "id": "zip.total-size",
                "message": "zip uncompressed size exceeds the bounded total",
            }
        )
    native_entries = sorted(
        name for name in names if name.startswith("lib/") and name.endswith(".so")
    )
    nested_package_entries = sorted(
        name for name in names if name.lower().endswith((".apk", ".aab"))
    )
    abis = set()
    for name in native_entries:
        parts = name.split("/")
        if len(parts) >= 3:
            abis.add(parts[1])
    dex_entries = sorted(name for name in names if DEX_NAME_RE.fullmatch(name))
    license_entries = sorted(
        name
        for name in names
        if any(
            part.lower() in ("license", "licenses", "notice", "notices")
            for part in name.split("/")
        )
        or os.path.basename(name).lower().startswith(("license", "notice", "copying"))
    )
    return {
        "entryCount": len(names),
        "uncompressedBytes": total_uncompressed,
        "abis": sorted(abis),
        "nativeEntries": native_entries,
        "nestedPackageEntries": nested_package_entries,
        "dexEntries": dex_entries,
        "licenseEntries": license_entries,
        "hasManifest": "AndroidManifest.xml" in names,
        "problems": problems,
    }


def _uleb128(data: bytes, offset: int) -> Tuple[int, int]:
    result = 0
    shift = 0
    while True:
        if offset >= len(data):
            raise StageReleaseError("dex.truncated", "truncated uleb128 in DEX")
        byte = data[offset]
        offset += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, offset
        shift += 7
        if shift > 35:
            raise StageReleaseError("dex.uleb128", "invalid uleb128 in DEX")


def _u32(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 4 > len(data):
        raise StageReleaseError("dex.bounds", "DEX offset outside file")
    return struct.unpack_from("<I", data, offset)[0]


def dex_class_descriptors(data: bytes) -> List[str]:
    """Return the class descriptors defined by one DEX file.

    Adapted from the existing read-only ``check-apk.py`` helper so the
    stage-release check does not maintain a second interpretation of the DEX
    class table.
    """

    if len(data) < 0x70 or data[:4] != b"dex\n":
        raise StageReleaseError("dex.invalid", "not a DEX file")
    if _u32(data, 40) not in (0x12345678, 0x78563412):
        raise StageReleaseError("dex.invalid", "unsupported DEX endian tag")
    if _u32(data, 36) < 0x70:
        raise StageReleaseError("dex.invalid", "DEX header too small")
    string_ids_size = _u32(data, 56)
    string_ids_off = _u32(data, 60)
    type_ids_size = _u32(data, 64)
    type_ids_off = _u32(data, 68)
    class_defs_size = _u32(data, 96)
    class_defs_off = _u32(data, 100)
    for size, off, item in (
        (string_ids_size, string_ids_off, 4),
        (type_ids_size, type_ids_off, 4),
        (class_defs_size, class_defs_off, 32),
    ):
        if size and (off < 0x70 or off + size * item > len(data)):
            raise StageReleaseError("dex.invalid", "DEX table outside file")

    descriptor_cache: Dict[int, str] = {}

    def descriptor_for_type(type_idx: int) -> str:
        if type_idx >= type_ids_size:
            raise StageReleaseError("dex.invalid", "DEX type index out of range")
        if type_idx in descriptor_cache:
            return descriptor_cache[type_idx]
        string_idx = _u32(data, type_ids_off + type_idx * 4)
        if string_idx >= string_ids_size:
            raise StageReleaseError("dex.invalid", "DEX string index out of range")
        string_off = _u32(data, string_ids_off + string_idx * 4)
        _, position = _uleb128(data, string_off)
        end = data.find(b"\x00", position)
        if end < 0:
            raise StageReleaseError("dex.invalid", "unterminated DEX string")
        value = data[position:end].decode("utf-8", "replace")
        descriptor_cache[type_idx] = value
        return value

    classes = []
    for index in range(class_defs_size):
        class_idx = _u32(data, class_defs_off + index * 32)
        classes.append(descriptor_for_type(class_idx))
    return classes


def dex_facts(path: Path) -> Dict[str, Any]:
    with zipfile.ZipFile(str(path), "r") as archive:
        infos = archive.infolist()
        dex_infos = [
            info for info in infos if DEX_NAME_RE.fullmatch(info.filename)
        ]
        dex_infos.sort(key=lambda info: (len(info.filename), info.filename))
        classes: Set[str] = set()
        for info in dex_infos:
            if info.file_size > MAX_ENTRY_BYTES:
                raise StageReleaseError(
                    "dex.size", "DEX entry exceeds the bounded size"
                )
            data = archive.read(info)
            classes.update(dex_class_descriptors(data))
    markers = {marker: marker in classes for marker in FULL_ONLY_MARKERS}
    full_only_count = sum(
        1
        for name in classes
        if name.startswith("Lcom/floe/android/phonecontrol/")
        or name.startswith("Lcom/floe/android/rootsystem/")
    )
    return {
        "dexFiles": [info.filename for info in dex_infos],
        "classCount": len(classes),
        "markers": markers,
        "fullOnlyClassCount": full_only_count,
    }


_CERT_DIGEST_RE = re.compile(
    r"(?:V[0-9.]+ Signer|Signer #[0-9]+): certificate SHA-256 digest:\s*"
    r"([0-9a-fA-F]{64})",
    re.MULTILINE,
)
_CERT_DN_RE = re.compile(
    r"(?:V[0-9.]+ Signer|Signer #[0-9]+): certificate DN:\s*(.+)",
    re.MULTILINE,
)
_SIGNER_COUNT_RE = re.compile(r"^Number of signers:\s*(\d+)\s*$", re.MULTILINE)
_SCHEME_RE = re.compile(
    r"^Verified using (v[0-9.]+) scheme[^:]*:\s*(true|false)\s*$",
    re.MULTILINE,
)


def parse_apksigner_output(text: str) -> Dict[str, Any]:
    problems = []
    schemes = {}
    for version, value in _SCHEME_RE.findall(text):
        schemes[version] = value.strip().lower() == "true"
    signer_counts = [int(value) for value in _SIGNER_COUNT_RE.findall(text)]
    signer_count = signer_counts[0] if signer_counts else None
    digests = sorted({match.lower() for match in _CERT_DIGEST_RE.findall(text)})
    dns = sorted({match.strip() for match in _CERT_DN_RE.findall(text)})
    verifies = re.search(r"^Verifies\s*$", text, re.MULTILINE) is not None
    does_not_verify = "DOES NOT VERIFY" in text

    if does_not_verify or not verifies:
        problems.append(
            {
                "id": "signing.not-verified",
                "message": "apksigner did not verify the APK (unsigned, corrupt, "
                "or unsupported signature)",
            }
        )
    if not schemes:
        problems.append(
            {
                "id": "signing.no-scheme",
                "message": "apksigner reported no signature scheme result",
            }
        )
    modern_schemes = [
        version
        for version, value in schemes.items()
        if value and version in ("v2", "v3", "v3.1", "v3.2")
    ]
    if schemes and not modern_schemes:
        problems.append(
            {
                "id": "signing.legacy-only",
                "message": "APK has no v2/v3 signature; a v1-only artifact is "
                "not accepted",
            }
        )
    if signer_count is None:
        problems.append(
            {
                "id": "signing.signer-count",
                "message": "apksigner output has no signer count",
            }
        )
    elif signer_count != 1:
        problems.append(
            {
                "id": "signing.multiple-signers",
                "message": "APK has {} signers; exactly one formal signer is "
                "required".format(signer_count),
            }
        )
    if len(digests) != 1:
        problems.append(
            {
                "id": "signing.certificate-count",
                "message": "apksigner reported {} distinct signer certificate "
                "digests; exactly one is required".format(len(digests)),
            }
        )
    if len(dns) > 1:
        problems.append(
            {
                "id": "signing.certificate-dn-count",
                "message": "apksigner reported {} distinct signer DNs".format(len(dns)),
            }
        )
    cert_sha256 = digests[0] if len(digests) == 1 else None
    dn = dns[0] if len(dns) == 1 else None
    debug_certificate = bool(
        (dn and DEBUG_CERT_DN_RE.search(dn))
        or (cert_sha256 and cert_sha256 in KNOWN_DEBUG_CERT_SHA256)
    )
    if debug_certificate:
        problems.append(
            {
                "id": "signing.debug-certificate",
                "message": "APK is signed by the known developer debug "
                "certificate; it cannot be a formal release",
            }
        )
    return {
        "verified": not problems,
        "schemes": schemes,
        "modernScheme": bool(modern_schemes),
        "signerCount": signer_count,
        "certSha256": cert_sha256,
        "dn": dn,
        "debugCertificate": debug_certificate,
        "problems": problems,
    }


def signing_facts(apksigner: Path, apk: Path) -> Dict[str, Any]:
    proc = run_readonly_tool(
        [str(apksigner), "verify", "--verbose", "--print-certs", str(apk)]
    )
    if proc.returncode != 0:
        detail = (proc.stderr or "").strip() or (proc.stdout or "").strip()
        if "Java Runtime" in detail:
            detail += " (set JAVA_HOME to a working JDK)"
        return {
            "verified": False,
            "schemes": {},
            "modernScheme": False,
            "signerCount": None,
            "certSha256": None,
            "dn": None,
            "debugCertificate": False,
            "problems": [
                {
                    "id": "signing.apksigner-failed",
                    "message": "apksigner failed: {}".format(detail[:500]),
                }
            ],
        }
    return parse_apksigner_output((proc.stdout or "") + "\n" + (proc.stderr or ""))


# ---------------------------------------------------------------------------
# Native ELF / zip packaging evidence
# ---------------------------------------------------------------------------


def _range(data: bytes, offset: int, size: int, label: str) -> bytes:
    if offset < 0 or size < 0 or offset + size > len(data):
        raise ElfError("{} outside file".format(label))
    return data[offset : offset + size]


def _align4(value: int) -> int:
    return (value + 3) & ~3


def _scan_notes(data: bytes, segments: Sequence[Tuple[int, int]]) -> Optional[str]:
    for offset, size in segments:
        position = offset
        end = offset + size
        if end > len(data):
            raise ElfError("PT_NOTE outside file")
        while position + 12 <= end:
            namesz, descsz, note_type = struct.unpack_from("<III", data, position)
            name_start = position + 12
            name_end = name_start + namesz
            desc_start = _align4(name_end)
            desc_end = desc_start + descsz
            if desc_end > end:
                raise ElfError("ELF note outside segment")
            name = data[name_start:name_end].rstrip(b"\x00")
            if name == b"GNU" and note_type == 3:
                return data[desc_start:desc_end].hex()
            position = _align4(desc_end)
    return None


def _parse_sections(
    data: bytes,
    shoff: int,
    shentsize: int,
    shnum: int,
    shstrndx: int,
) -> Dict[str, Tuple[int, int, int, int, int, int, int]]:
    if shentsize < 64:
        raise ElfError("section header entry too small")
    if shoff + shnum * shentsize > len(data):
        raise ElfError("section header table outside file")
    headers = []
    for index in range(shnum):
        base = shoff + index * shentsize
        headers.append(
            struct.unpack_from("<IIQQQQIIQQ", data, base)
        )
    if shstrndx >= shnum:
        raise ElfError("section name string table index out of range")
    name_header = headers[shstrndx]
    strtab = _range(data, name_header[4], name_header[5], ".shstrtab")
    sections = {}
    for header in headers:
        name_offset = header[0]
        if name_offset >= len(strtab):
            raise ElfError("section name outside .shstrtab")
        end = strtab.find(b"\x00", name_offset)
        if end < 0:
            raise ElfError("unterminated section name")
        name = strtab[name_offset:end].decode("utf-8", "replace")
        sections[name] = (
            header[1],  # type
            header[4],  # offset
            header[5],  # size
            header[6],  # link
            header[8],  # alignment
            header[9],  # entry size
            header[7],  # info
        )
    return sections


def _dynamic_needed(data: bytes, loads: Sequence[Tuple[int, int, int, int]], dynamic: Tuple[int, int]) -> List[str]:
    offset, size = dynamic
    entries = _range(data, offset, size, "PT_DYNAMIC")
    needed_offsets = []
    strtab_address = None
    strsz = None
    position = 0
    while position + 16 <= len(entries):
        tag, value = struct.unpack_from("<qQ", entries, position)
        position += 16
        if tag == ELF_DT_NULL:
            break
        if tag == ELF_DT_NEEDED:
            needed_offsets.append(value)
        elif tag == ELF_DT_STRTAB:
            strtab_address = value
        elif tag == ELF_DT_STRSZ:
            strsz = value
    if not needed_offsets:
        return []
    if strtab_address is None or strsz is None:
        raise ElfError("ELF has DT_NEEDED but no DT_STRTAB/DT_STRSZ")

    def virtual_to_offset(address: int) -> int:
        for p_offset, p_vaddr, p_filesz, _ in loads:
            if p_vaddr <= address < p_vaddr + p_filesz:
                return p_offset + (address - p_vaddr)
        raise ElfError("ELF dynamic string table address outside PT_LOAD")

    table_offset = virtual_to_offset(strtab_address)
    if strsz > len(data) or table_offset + strsz > len(data):
        raise ElfError("ELF DT_STRTAB outside file")
    table = data[table_offset : table_offset + strsz]
    names = []
    for name_offset in needed_offsets:
        if name_offset >= len(table):
            raise ElfError("ELF DT_NEEDED offset outside string table")
        end = table.find(b"\x00", name_offset)
        if end < 0:
            raise ElfError("unterminated ELF DT_NEEDED string")
        names.append(table[name_offset:end].decode("utf-8", "replace"))
    return names


def elf_facts(data: bytes) -> Dict[str, Any]:
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise ElfError("not an ELF file")
    if data[4] != 2:
        raise ElfError("not a 64-bit ELF")
    if data[5] != 1:
        raise ElfError("not a little-endian ELF")
    machine = struct.unpack_from("<H", data, 18)[0]
    if machine != ELF_EM_AARCH64:
        raise ElfError("not an AArch64 ELF")
    phoff = struct.unpack_from("<Q", data, 32)[0]
    shoff = struct.unpack_from("<Q", data, 40)[0]
    phentsize = struct.unpack_from("<H", data, 54)[0]
    phnum = struct.unpack_from("<H", data, 56)[0]
    shentsize = struct.unpack_from("<H", data, 58)[0]
    shnum = struct.unpack_from("<H", data, 60)[0]
    shstrndx = struct.unpack_from("<H", data, 62)[0]

    loads: List[Tuple[int, int, int, int]] = []
    note_segments: List[Tuple[int, int]] = []
    dynamic = None
    if phnum:
        if phentsize < 56:
            raise ElfError("ELF program header entry too small")
        if phoff + phnum * phentsize > len(data):
            raise ElfError("ELF program header table outside file")
        for index in range(phnum):
            base = phoff + index * phentsize
            p_type = struct.unpack_from("<I", data, base)[0]
            p_offset = struct.unpack_from("<Q", data, base + 8)[0]
            p_vaddr = struct.unpack_from("<Q", data, base + 16)[0]
            p_filesz = struct.unpack_from("<Q", data, base + 32)[0]
            p_align = struct.unpack_from("<Q", data, base + 48)[0]
            if p_type == ELF_PT_LOAD:
                loads.append((p_offset, p_vaddr, p_filesz, p_align))
            elif p_type == ELF_PT_NOTE:
                note_segments.append((p_offset, p_filesz))
            elif p_type == ELF_PT_DYNAMIC:
                dynamic = (p_offset, p_filesz)
    if not loads:
        raise ElfError("ELF has no PT_LOAD segment")

    build_id = _scan_notes(data, note_segments)
    sections: Dict[str, Tuple[int, int, int, int, int, int, int]] = {}
    if shoff:
        if shnum == 0:
            # ELF extended numbering: the real count is section 0's sh_size and
            # the real shstrndx is section 0's sh_link.
            if shentsize < 64 or shoff + shentsize > len(data):
                raise ElfError("ELF extended section numbering outside file")
            section_zero = struct.unpack_from("<IIQQQQIIQQ", data, shoff)
            shnum = section_zero[5]
            if shstrndx == 0xFFFF:
                shstrndx = section_zero[6]
        sections = _parse_sections(data, shoff, shentsize, shnum, shstrndx)

    debug_section_bytes = 0
    debug_sections: Dict[str, int] = {}
    for name, (section_type, offset, size, _, _, _, _) in sections.items():
        if name.startswith(".debug_") or name.startswith(".zdebug_"):
            if size:
                debug_sections[name] = size
                if section_type != ELF_SHT_NOBITS:
                    _range(data, offset, size, name)
                debug_section_bytes += size
    if build_id is None and ".note.gnu.build-id" in sections:
        section_type, offset, size, _, _, _, _ = sections[".note.gnu.build-id"]
        if section_type != ELF_SHT_NOBITS:
            build_id = _scan_notes(data, [(offset, size)])

    export_count = 0
    jni_export_count = 0
    # Resolve .dynsym/.dynstr directly from raw section headers for reliable
    # sh_link handling.
    if shoff and shnum:
        raw_headers = []
        for index in range(shnum):
            base = shoff + index * shentsize
            raw_headers.append(struct.unpack_from("<IIQQQQIIQQ", data, base))
        for header in raw_headers:
            if header[1] != ELF_SHT_DYNSYM:
                continue
            link = header[6]
            if link >= len(raw_headers):
                raise ElfError(".dynsym sh_link out of range")
            string_header = raw_headers[link]
            if string_header[1] != ELF_SHT_STRTAB:
                raise ElfError(".dynsym sh_link is not a string table")
            sym_data = _range(data, header[4], header[5], ".dynsym")
            string_data = _range(data, string_header[4], string_header[5], ".dynstr")
            entry = header[9] or 24
            if entry < 24:
                raise ElfError(".dynsym entry too small")
            for position in range(0, len(sym_data) - 23, entry):
                st_name, st_info, _, st_shndx, _, _ = struct.unpack_from(
                    "<IBBHQQ", sym_data, position
                )
                if not st_name or st_shndx == 0:
                    continue
                binding = st_info >> 4
                if binding not in (ELF_STB_GLOBAL, ELF_STB_WEAK):
                    continue
                if st_name >= len(string_data):
                    raise ElfError(".dynsym name outside .dynstr")
                end = string_data.find(b"\x00", st_name)
                if end < 0:
                    raise ElfError("unterminated .dynsym name")
                name = string_data[st_name:end].decode("utf-8", "replace")
                export_count += 1
                if name.startswith("Java_") or name == "JNI_OnLoad":
                    jni_export_count += 1

    needed = []
    if dynamic is not None:
        needed = _dynamic_needed(data, loads, dynamic)

    return {
        "machine": machine,
        "loadAlignments": [align for _, _, _, align in loads],
        "minLoadAlignment": min(align for _, _, _, align in loads),
        "buildId": build_id,
        "debugSectionBytes": debug_section_bytes,
        "debugSections": debug_sections,
        "needed": needed,
        "exportCount": export_count,
        "jniExportCount": jni_export_count,
        "sectionHeaders": bool(sections),
    }


def zip_data_offset(archive: zipfile.ZipFile, info: zipfile.ZipInfo) -> int:
    if info.header_offset < 0:
        raise StageReleaseError("zip.local-header", "invalid zip local header offset")
    archive.fp.seek(info.header_offset)
    header = archive.fp.read(30)
    if len(header) != 30:
        raise StageReleaseError("zip.local-header", "truncated zip local header")
    signature, _, _, _, _, _, _, _, _, name_len, extra_len = struct.unpack(
        "<IHHHHHIIIHH", header
    )
    if signature != 0x04034B50:
        raise StageReleaseError("zip.local-header", "bad zip local header signature")
    local_name = archive.fp.read(name_len)
    try:
        decoded_name = local_name.decode("utf-8")
    except UnicodeDecodeError:
        decoded_name = local_name.decode("cp437", "replace")
    if decoded_name != info.filename:
        raise StageReleaseError(
            "zip.local-header",
            "zip local header name does not match the central directory",
        )
    return info.header_offset + 30 + name_len + extra_len


def native_facts(path: Path) -> Dict[str, Any]:
    problems = []
    libraries = []
    total_debug = 0
    max_debug_section = 0
    debug_problem = False
    test_only_libraries = []
    with zipfile.ZipFile(str(path), "r") as archive:
        infos = archive.infolist()
        native_infos = [
            info
            for info in infos
            if info.filename.startswith("lib/") and info.filename.endswith(".so")
        ]
        native_infos.sort(key=lambda info: info.filename)
        if not native_infos:
            problems.append(
                {
                    "id": "native.missing",
                    "message": "APK has no native libraries under lib/",
                }
            )
        abis = sorted(
            {
                info.filename.split("/")[1]
                for info in native_infos
                if len(info.filename.split("/")) >= 3
            }
        )
        if abis != [ANDROID_ABI]:
            problems.append(
                {
                    "id": "native.abi",
                    "message": "native ABI set must be exactly ['{}']; got {}".format(
                        ANDROID_ABI, abis
                    ),
                }
            )
        packaged_names = {info.filename.rsplit("/", 1)[-1] for info in native_infos}
        for info in native_infos:
            name = info.filename
            basename = name.rsplit("/", 1)[-1]
            if info.file_size > MAX_NATIVE_LIB_BYTES:
                problems.append(
                    {
                        "id": "native.size",
                        "message": "{} exceeds the bounded native library size".format(name),
                    }
                )
                continue
            try:
                data = archive.read(info)
            except (OSError, RuntimeError, zipfile.BadZipFile) as exc:
                problems.append(
                    {
                        "id": "native.read",
                        "message": "{} could not be read: {}".format(name, exc),
                    }
                )
                continue
            if len(data) != info.file_size:
                problems.append(
                    {
                        "id": "native.size",
                        "message": "{} size does not match the zip directory".format(name),
                    }
                )
            sha256 = hashlib.sha256(data).hexdigest()
            try:
                elf = elf_facts(data)
            except ElfError as exc:
                problems.append(
                    {
                        "id": "native.elf",
                        "message": "{} is not valid AArch64 ELF: {}".format(name, exc),
                    }
                )
                libraries.append(
                    {
                        "name": name,
                        "bytes": len(data),
                        "sha256": sha256,
                        "error": str(exc),
                    }
                )
                continue
            stored = info.compress_type == zipfile.ZIP_STORED
            try:
                data_offset = zip_data_offset(archive, info)
            except StageReleaseError as exc:
                problems.append({"id": exc.code, "message": "{}: {}".format(name, exc.message)})
                data_offset = None
            zip_aligned = data_offset is not None and data_offset % PAGE_16K == 0
            if not stored:
                problems.append(
                    {
                        "id": "native.compression",
                        "message": "{} is compressed; native libraries must be stored".format(name),
                    }
                )
            if not zip_aligned:
                problems.append(
                    {
                        "id": "native.zip-alignment",
                        "message": "{} is not 16 KiB-aligned in the zip".format(name),
                    }
                )
            if (
                elf["minLoadAlignment"] < PAGE_16K
                or any(align % PAGE_16K for align in elf["loadAlignments"])
            ):
                problems.append(
                    {
                        "id": "native.elf-alignment",
                        "message": "{} does not use 16 KiB-multiple PT_LOAD "
                        "alignment".format(name),
                    }
                )
            if not elf["buildId"]:
                problems.append(
                    {
                        "id": "native.build-id",
                        "message": "{} has no GNU build id".format(name),
                    }
                )
            max_section_debug = max(elf["debugSections"].values() or [0])
            if (
                elf["debugSectionBytes"] > MAX_DEBUG_TOTAL_BYTES
                or max_section_debug > MAX_DEBUG_SECTION_BYTES
            ):
                debug_problem = True
                problems.append(
                    {
                        "id": "native.debug-sections",
                        "message": "{} carries {} bytes of debug sections (largest "
                        "{}); native debug stripping must precede final "
                        "signing".format(
                            name, elf["debugSectionBytes"], max_section_debug
                        ),
                    }
                )
            total_debug += elf["debugSectionBytes"]
            max_debug_section = max(max_debug_section, max_section_debug)
            for needed in elf["needed"]:
                if (
                    "/" in needed
                    or (
                        needed not in packaged_names
                        and needed not in ANDROID_PUBLIC_LIBRARIES
                    )
                ):
                    problems.append(
                        {
                            "id": "native.needed",
                            "message": "{} depends on unresolved {}".format(name, needed),
                        }
                    )
            if basename in TEST_ONLY_NATIVE:
                test_only_libraries.append(basename)
                problems.append(
                    {
                        "id": "native.test-only",
                        "message": "{} is a test-only native library and must not "
                        "ship in a formal APK".format(basename),
                    }
                )
            if basename == "libfloe_jni.so" and elf["jniExportCount"] == 0:
                problems.append(
                    {
                        "id": "native.jni-exports",
                        "message": "libfloe_jni.so exports no Java_/JNI_OnLoad entry point",
                    }
                )
            libraries.append(
                {
                    "name": name,
                    "bytes": len(data),
                    "sha256": sha256,
                    "stored": stored,
                    "zipDataOffset": data_offset,
                    "zipAligned": zip_aligned,
                    "minLoadAlignment": elf["minLoadAlignment"],
                    "loadAlignments": elf["loadAlignments"],
                    "buildId": elf["buildId"],
                    "debugSectionBytes": elf["debugSectionBytes"],
                    "maxDebugSectionBytes": max_section_debug,
                    "debugSections": elf["debugSections"],
                    "needed": elf["needed"],
                    "exportCount": elf["exportCount"],
                    "jniExportCount": elf["jniExportCount"],
                    "sectionHeaders": elf["sectionHeaders"],
                }
            )
        present = {info.filename.rsplit("/", 1)[-1] for info in native_infos}
        for required in REQUIRED_NATIVE:
            if required not in present:
                problems.append(
                    {
                        "id": "native.required",
                        "message": "required native library {} is missing".format(required),
                    }
                )
    return {
        "abi": ANDROID_ABI,
        "libraries": libraries,
        "problems": problems,
        "debugSectionBytes": total_debug,
        "maxDebugSectionBytes": max_debug_section,
        "testOnlyLibraries": sorted(set(test_only_libraries)),
        "stripped": not debug_problem,
    }


# ---------------------------------------------------------------------------
# Embedded runtime installer component (the ONE nested-package exception)
# ---------------------------------------------------------------------------


def _read_zip_entry_bounded(
    archive: zipfile.ZipFile, info: zipfile.ZipInfo, limit: int, label: str
) -> bytes:
    if info.file_size > limit:
        raise StageReleaseError(
            "runtime.child.size",
            "{} claims {} bytes (limit {})".format(label, info.file_size, limit),
        )
    chunks = []
    total = 0
    try:
        with archive.open(info, "r") as handle:
            while True:
                block = handle.read(COPY_CHUNK)
                if not block:
                    break
                total += len(block)
                if total > limit:
                    raise StageReleaseError(
                        "runtime.child.size",
                        "{} decompressed beyond {} bytes while reading".format(
                            label, limit
                        ),
                    )
                chunks.append(block)
    except (OSError, RuntimeError, zipfile.BadZipFile) as exc:
        raise StageReleaseError(
            "runtime.child.read",
            "{} could not be read: {}".format(label, exc),
        )
    if total != info.file_size:
        raise StageReleaseError(
            "runtime.child.size",
            "{} decompressed to {} bytes but the zip directory claims {}".format(
                label, total, info.file_size
            ),
        )
    return b"".join(chunks)


def runtime_child_extraction(apk: Path) -> Optional[Dict[str, Any]]:
    """Bounded extraction of the single legitimate embedded runtime installer.

    Returns None only when the parent APK embeds neither the exact asset nor
    its digest sidecar; the generic nested-package refusal then applies to
    any other nested entry exactly as before. Layout problems raise with
    ``runtime.child.*`` codes. A malformed or mismatched sidecar is reported
    (not raised) so the evaluation records explicit digest evidence plus the
    retained generic refusal.
    """
    with zipfile.ZipFile(str(apk), "r") as archive:
        infos = archive.infolist()
        assets = [i for i in infos if i.filename == RUNTIME_CHILD_ASSET]
        sidecars = [i for i in infos if i.filename == RUNTIME_CHILD_SIDECAR]
        if not assets and not sidecars:
            return None
        if not assets:
            raise StageReleaseError(
                "runtime.child.asset-missing",
                "the embedded runtime digest sidecar exists without the "
                "expected runtime.apk asset",
            )
        if len(assets) != 1 or len(sidecars) != 1:
            raise StageReleaseError(
                "runtime.child.entries",
                "expected exactly one {} asset and one {} sidecar; got {} "
                "and {}".format(
                    RUNTIME_CHILD_ASSET, RUNTIME_CHILD_SIDECAR,
                    len(assets), len(sidecars),
                ),
            )
        siblings = sorted(
            info.filename
            for info in infos
            if info.filename.startswith(RUNTIME_CHILD_ASSET_DIR)
            and not (info.filename.endswith("/") and info.file_size == 0)
        )
        if siblings != sorted([RUNTIME_CHILD_ASSET, RUNTIME_CHILD_SIDECAR]):
            raise StageReleaseError(
                "runtime.child.asset-siblings",
                "{} must contain exactly the runtime.apk asset and its "
                "digest sidecar; found {}".format(
                    RUNTIME_CHILD_ASSET_DIR, siblings
                ),
            )
        asset = assets[0]
        sidecar = sidecars[0]
        if asset.flag_bits & 0x1:
            raise StageReleaseError(
                "runtime.child.encrypted", "the embedded runtime asset is encrypted"
            )
        if sidecar.flag_bits & 0x1:
            raise StageReleaseError(
                "runtime.child.encrypted",
                "the embedded runtime digest sidecar is encrypted",
            )
        sidecar_raw = _read_zip_entry_bounded(
            archive, sidecar, MAX_RUNTIME_CHILD_SIDECAR_BYTES,
            "embedded runtime digest sidecar",
        )
        try:
            sidecar_text = sidecar_raw.decode("ascii").strip()
        except UnicodeDecodeError:
            sidecar_text = ""
        sidecar_valid = SHA256_RE.fullmatch(sidecar_text) is not None
        child_bytes = _read_zip_entry_bounded(
            archive, asset, MAX_RUNTIME_CHILD_BYTES, "embedded runtime APK"
        )
    computed = hashlib.sha256(child_bytes).hexdigest()
    return {
        "assetEntry": RUNTIME_CHILD_ASSET,
        "sidecarEntry": RUNTIME_CHILD_SIDECAR,
        "bytes": len(child_bytes),
        "childBytes": child_bytes,
        "computedSha256": computed,
        "sidecarSha256": sidecar_text if sidecar_valid else None,
        "sidecarMalformed": not sidecar_valid,
        "digestMatched": bool(sidecar_valid and computed == sidecar_text),
    }


def runtime_native_facts(path: Path) -> Dict[str, Any]:
    """Focused native evidence for the embedded runtime installer child.

    The installer legitimately ships legacy package-manager-extracted
    executables: its libraries may be deflate-compressed, carry no 16 KiB
    ZIP data-offset alignment and the qualified proot payloads intentionally
    retain debug symbols, so the formal app's ZIP-storage and stripping
    gates are deliberately not reused. The gates that protect any embedded
    product ARE enforced: one arm64-v8a ABI set, valid AArch64 ELF per
    library, 16 KiB-multiple ELF PT_LOAD alignment (an extractNativeLibs
    layout exemption never waives the API37 16 KiB page load requirement),
    bounded sizes, resolvable DT_NEEDED (the dependency proof that removed
    SDK test libraries were never required), no test-only native library
    and the required runtime authority set.
    """
    problems = []
    libraries = []
    test_only_libraries = []
    with zipfile.ZipFile(str(path), "r") as archive:
        infos = [
            info
            for info in archive.infolist()
            if info.filename.startswith("lib/") and info.filename.endswith(".so")
        ]
        infos.sort(key=lambda info: info.filename)
        abis = sorted(
            {
                info.filename.split("/")[1]
                for info in infos
                if len(info.filename.split("/")) >= 3
            }
        )
        if abis != [ANDROID_ABI]:
            problems.append(
                {
                    "id": "runtime.child.native.abi",
                    "message": "embedded runtime native ABI set must be exactly "
                    "['{}']; got {}".format(ANDROID_ABI, abis),
                }
            )
        packaged_names = {info.filename.rsplit("/", 1)[-1] for info in infos}
        for info in infos:
            name = info.filename
            basename = name.rsplit("/", 1)[-1]
            if info.file_size > MAX_NATIVE_LIB_BYTES:
                problems.append(
                    {
                        "id": "runtime.child.native.size",
                        "message": "{} exceeds the bounded native library "
                        "size".format(name),
                    }
                )
                continue
            try:
                data = archive.read(info)
            except (OSError, RuntimeError, zipfile.BadZipFile) as exc:
                problems.append(
                    {
                        "id": "runtime.child.native.read",
                        "message": "{} could not be read: {}".format(name, exc),
                    }
                )
                continue
            try:
                elf = elf_facts(data)
            except ElfError as exc:
                problems.append(
                    {
                        "id": "runtime.child.native.elf",
                        "message": "{} is not valid AArch64 ELF: {}".format(
                            name, exc
                        ),
                    }
                )
                continue
            if (
                elf["minLoadAlignment"] < PAGE_16K
                or any(align % PAGE_16K for align in elf["loadAlignments"])
            ):
                problems.append(
                    {
                        "id": "runtime.child.native.elf-alignment",
                        "message": "{} does not use 16 KiB-multiple PT_LOAD "
                        "alignment".format(name),
                    }
                )
            for needed in elf["needed"]:
                if (
                    "/" in needed
                    or (
                        needed not in packaged_names
                        and needed not in ANDROID_PUBLIC_LIBRARIES
                    )
                ):
                    problems.append(
                        {
                            "id": "runtime.child.native.needed",
                            "message": "embedded runtime {} depends on "
                            "unresolved {}".format(name, needed),
                        }
                    )
            if basename in TEST_ONLY_NATIVE:
                test_only_libraries.append(basename)
                problems.append(
                    {
                        "id": "runtime.child.native.test-only",
                        "message": "{} is a test-only native library and must "
                        "not ship inside the embedded runtime installer".format(
                            basename
                        ),
                    }
                )
            libraries.append(
                {
                    "name": name,
                    "bytes": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(),
                    "compressionMethod": info.compress_type,
                    "minLoadAlignment": elf["minLoadAlignment"],
                    "loadAlignments": elf["loadAlignments"],
                    "needed": elf["needed"],
                }
            )
        for required in RUNTIME_REQUIRED_NATIVE:
            if required not in packaged_names:
                problems.append(
                    {
                        "id": "runtime.child.native.required",
                        "message": "required embedded runtime library {} is "
                        "missing".format(required),
                    }
                )
    return {
        "abi": ANDROID_ABI,
        "libraries": libraries,
        "problems": problems,
        "testOnlyLibraries": sorted(set(test_only_libraries)),
    }


def expected_runtime_package(package: str) -> Optional[str]:
    """Derive the embedded runtime installer package from the app package.

    Mirrors the Gradle applicationId composition exactly: the full-channel
    app is ``<prefix>.full`` and its component installer is
    ``<prefix>.runtime.full``. Anything that cannot be derived fails closed,
    because the embedded child can then not be bound to this policy.
    """
    prefix, _, channel = package.rpartition(".")
    if not prefix or channel != FULL_DISTRIBUTION:
        return None
    return "{}.runtime.{}".format(prefix, channel)


# ---------------------------------------------------------------------------
# Inspection / policy evaluation
# ---------------------------------------------------------------------------


class ApkInspector:
    """Real read-only inspector; constructed only by the production CLI."""

    def __init__(self, aapt2: Path, apksigner: Path):
        self.aapt2 = Path(aapt2)
        self.apksigner = Path(apksigner)
        self.versions = {
            "aapt2": tool_version([str(self.aapt2), "version"]),
            "apksigner": tool_version([str(self.apksigner), "version"]),
        }

    def inspect(self, apk: Path) -> Dict[str, Any]:
        facts = {
            "zip": zip_structure_facts(apk),
            "manifest": manifest_facts(self.aapt2, apk),
            "badging": badging_facts(self.aapt2, apk),
            "signing": signing_facts(self.apksigner, apk),
            "dex": dex_facts(apk),
            "native": native_facts(apk),
            "toolVersions": dict(self.versions),
        }
        facts["runtimeChild"] = self._inspect_runtime_child(apk)
        return facts

    def _inspect_runtime_child(self, apk: Path) -> Optional[Dict[str, Any]]:
        """Bounded extraction and real-tool verification of the embedded child.

        Extraction or tooling failures are returned as an ``error`` record;
        they never raise out of the inspector because the generic nested-
        package refusal must still be reported by evaluation. The child is
        verified exactly like an APK through the same read-only aapt2 and
        apksigner helpers, in a private 0700 temporary directory that is
        always removed.
        """
        try:
            extraction = runtime_child_extraction(apk)
        except StageReleaseError as exc:
            return {"error": {"id": exc.code, "message": exc.message}}
        if extraction is None:
            return None
        child_bytes = extraction.pop("childBytes")
        temp_dir = tempfile.mkdtemp(prefix=".prepare-stage-release-child-")
        try:
            os.chmod(temp_dir, 0o700)
            child_path = Path(temp_dir) / "runtime.apk"
            descriptor = os.open(
                str(child_path),
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(child_bytes)
                handle.flush()
                os.fsync(handle.fileno())
            child_facts = {
                "zip": zip_structure_facts(child_path),
                "manifest": manifest_facts(self.aapt2, child_path),
                "badging": badging_facts(self.aapt2, child_path),
                "signing": signing_facts(self.apksigner, child_path),
                "native": runtime_native_facts(child_path),
            }
        except StageReleaseError as exc:
            return {"error": {"id": exc.code, "message": exc.message}}
        except (OSError, ValueError, zipfile.BadZipFile) as exc:
            return {
                "error": {
                    "id": "runtime.child.inspect",
                    "message": "embedded runtime child could not be verified: "
                    "{}: {}".format(type(exc).__name__, exc),
                }
            }
        finally:
            shutil.rmtree(temp_dir, ignore_errors=True)
        facts = dict(extraction)
        facts.update(child_facts)
        return facts


def _failure(failures: List[Dict[str, str]], identifier: str, message: str) -> None:
    failures.append({"id": identifier, "message": message})


def _compare_native_manifest(
    policy: ReleasePolicy, native: Dict[str, Any]
) -> Dict[str, Any]:
    manifest = policy.native_manifest or {}
    expected = manifest.get("libraries", {})
    actual = {
        library["name"].rsplit("/", 1)[-1]: library["sha256"]
        for library in native.get("libraries", [])
        if library.get("sha256")
    }
    matching = []
    derived = []
    missing = []
    for name, expected_sha in sorted(expected.items()):
        actual_sha = actual.get(name)
        if actual_sha is None:
            missing.append(name)
        elif actual_sha == expected_sha:
            matching.append(name)
        else:
            derived.append(
                {
                    "name": name,
                    "manifestSha256": expected_sha,
                    "apkSha256": actual_sha,
                }
            )
    extra = sorted(set(actual) - set(expected))
    if policy.native_manifest_role == "derived":
        basis = (
            "derived-manifest-exact"
            if not missing and not derived
            else "derived-manifest-mismatch"
        )
    else:
        basis = (
            "canonical-exact"
            if not missing and not derived
            else "derived-after-final-build"
        )
    return {
        "role": policy.native_manifest_role,
        "inputDigest": manifest.get("inputDigest"),
        "recordedLibraries": len(expected),
        "matching": matching,
        "derived": derived,
        "missing": missing,
        "extra": extra,
        "basis": basis,
        "runtimeEquivalenceVerified": False,
    }


def _evaluate_runtime_child(
    policy: ReleasePolicy,
    facts: Dict[str, Any],
    failures: List[Dict[str, str]],
) -> Optional[Dict[str, Any]]:
    """Strictly qualify the one legitimate embedded runtime installer.

    Returns None when the APK contains no nested package and no embedded
    runtime asset. A nested entry that is not exactly the known asset, or a
    known asset whose deep child facts are absent, keeps the original
    generic ``zip.entry.nested-package`` refusal. Child problems are added
    as ``runtime.child.*`` failures and never suppress that refusal; only a
    fully validated child does.
    """
    zip_facts = facts.get("zip", {})
    child = facts.get("runtimeChild")
    nested_entries = list(zip_facts.get("nestedPackageEntries", []))
    known_asset_only = nested_entries == [RUNTIME_CHILD_ASSET]

    if isinstance(child, dict) and child.get("error"):
        _failure(
            failures,
            child["error"].get("id", "runtime.child.inspect"),
            child["error"].get("message", "embedded runtime child could not be verified"),
        )
        return {
            "assetEntry": RUNTIME_CHILD_ASSET,
            "nestedPackageEntries": nested_entries,
            "extractionError": child["error"],
            "validated": False,
        }
    if not nested_entries and child is None:
        return None
    if not known_asset_only:
        return {
            "nestedPackageEntries": nested_entries,
            "assetEntry": (
                RUNTIME_CHILD_ASSET
                if isinstance(child, dict)
                else None
            ),
            "validated": False,
            "note": (
                "nested package entries are not exactly the one legitimate "
                "embedded runtime asset; the generic nested-package refusal "
                "applies unchanged"
            ),
        }
    if not isinstance(child, dict):
        return {
            "assetEntry": RUNTIME_CHILD_ASSET,
            "nestedPackageEntries": nested_entries,
            "validated": False,
            "note": (
                "the embedded runtime asset was not deeply extracted and "
                "verified; failing closed with the generic nested-package "
                "refusal"
            ),
        }

    problems: List[Dict[str, str]] = []

    def fail(identifier: str, message: str) -> None:
        problems.append({"id": identifier, "message": message})

    expected_package = expected_runtime_package(policy.package)
    if expected_package is None:
        fail(
            "runtime.child.package-undeterminable",
            "the embedded runtime package cannot be derived from the app "
            "package {!r}; expected the <prefix>.full full-channel "
            "layout".format(policy.package),
        )
    if child.get("sidecarMalformed"):
        fail(
            "runtime.child.sidecar",
            "the embedded runtime digest sidecar is not exactly one "
            "lowercase SHA-256 hex string",
        )
    elif not child.get("digestMatched"):
        fail(
            "runtime.child.digest",
            "embedded runtime SHA-256 {} does not match its digest sidecar "
            "{!r}".format(child.get("computedSha256"), child.get("sidecarSha256")),
        )

    child_manifest = child.get("manifest") or {}
    child_zip = child.get("zip") or {}
    child_badging = child.get("badging") or {}
    child_signing = child.get("signing") or {}
    child_native = child.get("native") or {}

    if expected_package is not None and child_manifest.get("package") != expected_package:
        fail(
            "runtime.child.package",
            "embedded runtime manifest package {!r} does not match the "
            "expected component package {!r}".format(
                child_manifest.get("package"), expected_package
            ),
        )
    if child_manifest.get("versionCode") != policy.version_code:
        fail(
            "runtime.child.version-code",
            "embedded runtime versionCode {!r} does not match the release "
            "versionCode {!r}".format(
                child_manifest.get("versionCode"), policy.version_code
            ),
        )
    if child_manifest.get("versionName") != policy.version_name:
        fail(
            "runtime.child.version-name",
            "embedded runtime versionName {!r} does not match the release "
            "versionName {!r}".format(
                child_manifest.get("versionName"), policy.version_name
            ),
        )
    if child_manifest.get("minSdk") != policy.min_sdk:
        fail(
            "runtime.child.min-sdk",
            "embedded runtime minSdk {!r} does not match the release minSdk "
            "{!r}".format(child_manifest.get("minSdk"), policy.min_sdk),
        )
    if child_manifest.get("targetSdk") != policy.target_sdk:
        fail(
            "runtime.child.target-sdk",
            "embedded runtime targetSdk {!r} does not match the release "
            "targetSdk {!r}".format(child_manifest.get("targetSdk"), policy.target_sdk),
        )
    if child_manifest.get("debuggable"):
        fail("runtime.child.debuggable", "embedded runtime manifest is debuggable")
    if child_manifest.get("testOnly"):
        fail("runtime.child.test-only", "embedded runtime manifest is test-only")
    if child_manifest.get("split"):
        fail(
            "runtime.child.split",
            "embedded runtime APK is a split APK (split={!r})".format(
                child_manifest.get("split")
            ),
        )
    if child_manifest.get("hasInstrumentation"):
        fail(
            "runtime.child.instrumentation",
            "embedded runtime APK declares instrumentation (test APK)",
        )
    if child_manifest.get("sharedUserId"):
        fail(
            "runtime.child.shared-user-id",
            "embedded runtime declares android:sharedUserId {!r}; the "
            "component installer must run under its own UID".format(
                child_manifest.get("sharedUserId")
            ),
        )
    if child_manifest.get("extractNativeLibs") is not True:
        fail(
            "runtime.child.extract-native-libs",
            "embedded runtime installer must keep package-manager "
            "extraction of its executables "
            "(android:extractNativeLibs=true); got {!r}".format(
                child_manifest.get("extractNativeLibs")
            ),
        )
    if not child_zip.get("hasManifest"):
        fail("runtime.child.manifest", "embedded runtime APK has no AndroidManifest.xml")
    if not child_zip.get("dexEntries"):
        fail("runtime.child.dex", "embedded runtime APK has no classes*.dex")
    if sorted(child_zip.get("abis", [])) != [ANDROID_ABI]:
        fail(
            "runtime.child.abi",
            "embedded runtime ABI set is {}; exactly one {} artifact is "
            "required".format(child_zip.get("abis"), ANDROID_ABI),
        )
    for problem in child_zip.get("problems", []):
        fail(
            "runtime.child.zip",
            "embedded runtime zip problem: {}".format(
                problem.get("message", "zip problem")
            ),
        )
    if child_badging:
        badging_package = child_badging.get("package")
        if badging_package is not None and badging_package != child_manifest.get("package"):
            fail(
                "runtime.child.badging.package",
                "embedded runtime badging package {!r} does not match the "
                "binary manifest {!r}".format(
                    badging_package, child_manifest.get("package")
                ),
            )
        try:
            badging_version_code = int(child_badging.get("versionCode"))
        except (TypeError, ValueError):
            badging_version_code = None
        if (
            badging_version_code is not None
            and badging_version_code != child_manifest.get("versionCode")
        ):
            fail(
                "runtime.child.badging.version-code",
                "embedded runtime badging versionCode {!r} does not match "
                "the binary manifest {!r}".format(
                    badging_version_code, child_manifest.get("versionCode")
                ),
            )
    for problem in child_signing.get("problems", []):
        fail(
            "runtime.child.signing",
            "embedded runtime signing problem: {}".format(
                problem.get("message", "signing problem")
            ),
        )
    if child_signing.get("certSha256") != policy.cert_sha256:
        fail(
            "runtime.child.cert-mismatch",
            "embedded runtime signer certificate {!r} does not equal the "
            "formal signer certificate {!r}".format(
                child_signing.get("certSha256"), policy.cert_sha256
            ),
        )
    for problem in child_native.get("problems", []):
        fail(
            problem.get("id", "runtime.child.native"),
            problem.get("message", "embedded runtime native problem"),
        )

    for problem in problems:
        _failure(failures, problem["id"], problem["message"])
    return {
        "assetEntry": RUNTIME_CHILD_ASSET,
        "sidecarEntry": RUNTIME_CHILD_SIDECAR,
        "bytes": child.get("bytes"),
        "computedSha256": child.get("computedSha256"),
        "sidecarSha256": child.get("sidecarSha256"),
        "digestMatched": bool(child.get("digestMatched")),
        "expectedPackage": expected_package,
        "package": child_manifest.get("package"),
        "versionCode": child_manifest.get("versionCode"),
        "versionName": child_manifest.get("versionName"),
        "minSdk": child_manifest.get("minSdk"),
        "targetSdk": child_manifest.get("targetSdk"),
        "debuggable": child_manifest.get("debuggable"),
        "testOnly": child_manifest.get("testOnly"),
        "sharedUserId": child_manifest.get("sharedUserId"),
        "split": child_manifest.get("split"),
        "extractNativeLibs": child_manifest.get("extractNativeLibs"),
        "hasInstrumentation": child_manifest.get("hasInstrumentation"),
        "abis": child_zip.get("abis"),
        "entryCount": child_zip.get("entryCount"),
        "nativeLibraryCount": len(child_native.get("libraries", [])),
        "nativeTestOnlyLibraries": child_native.get("testOnlyLibraries", []),
        "signing": {
            "verified": child_signing.get("verified"),
            "modernScheme": child_signing.get("modernScheme"),
            "signerCount": child_signing.get("signerCount"),
            "certSha256": child_signing.get("certSha256"),
            "dn": child_signing.get("dn"),
            "debugCertificate": child_signing.get("debugCertificate"),
        },
        "validationFailures": problems,
        "validated": not problems,
        "note": (
            "strict single-component verification with bounded extraction; "
            "the generic nested-package refusal remains in effect for every "
            "other nested artifact"
        ),
    }


def evaluate(
    policy: ReleasePolicy,
    facts: Dict[str, Any],
    apk_sha256: str,
    apk_bytes: int,
    failures: Optional[List[Dict[str, str]]] = None,
) -> Dict[str, Any]:
    failures = list(failures or [])
    zip_facts = facts.get("zip", {})
    manifest = facts.get("manifest", {})
    badging = facts.get("badging", {})
    signing = facts.get("signing", {})
    dex = facts.get("dex", {})
    native = facts.get("native", {})

    runtime_section = _evaluate_runtime_child(policy, facts, failures)
    for problem in zip_facts.get("problems", []):
        if (
            runtime_section is not None
            and runtime_section.get("validated")
            and problem.get("id") == "zip.entry.nested-package"
        ):
            continue
        _failure(failures, problem.get("id", "zip.problem"), problem.get("message", "zip problem"))
    if not zip_facts.get("hasManifest"):
        _failure(failures, "zip.manifest", "APK has no AndroidManifest.xml")
    if not zip_facts.get("dexEntries"):
        _failure(failures, "zip.dex", "APK has no classes*.dex")
    if sorted(zip_facts.get("abis", [])) != [ANDROID_ABI]:
        _failure(
            failures,
            "zip.abi",
            "APK ABI set is {}; exactly one {} artifact is required".format(
                zip_facts.get("abis"), ANDROID_ABI
            ),
        )

    if manifest.get("package") != policy.package:
        _failure(
            failures,
            "manifest.package",
            "binary manifest package {!r} does not match expected {!r}".format(
                manifest.get("package"), policy.package
            ),
        )
    if manifest.get("versionCode") != policy.version_code:
        _failure(
            failures,
            "manifest.version-code",
            "binary manifest versionCode {!r} does not match expected {!r}".format(
                manifest.get("versionCode"), policy.version_code
            ),
        )
    if manifest.get("versionName") != policy.version_name:
        _failure(
            failures,
            "manifest.version-name",
            "binary manifest versionName {!r} does not match expected {!r}".format(
                manifest.get("versionName"), policy.version_name
            ),
        )
    if manifest.get("minSdk") != policy.min_sdk:
        _failure(
            failures,
            "manifest.min-sdk",
            "binary manifest minSdk {!r} does not match expected {!r}".format(
                manifest.get("minSdk"), policy.min_sdk
            ),
        )
    if manifest.get("targetSdk") != policy.target_sdk:
        _failure(
            failures,
            "manifest.target-sdk",
            "binary manifest targetSdk {!r} does not match expected {!r}".format(
                manifest.get("targetSdk"), policy.target_sdk
            ),
        )
    if manifest.get("debuggable"):
        _failure(failures, "manifest.debuggable", "APK manifest is debuggable")
    if manifest.get("testOnly"):
        _failure(failures, "manifest.test-only", "APK manifest is test-only")
    if manifest.get("split"):
        _failure(
            failures,
            "manifest.split",
            "APK is a split APK (split={!r}); one universal/arm64 APK is required".format(
                manifest.get("split")
            ),
        )
    if manifest.get("hasInstrumentation"):
        _failure(
            failures,
            "manifest.instrumentation",
            "APK declares instrumentation (test APK), not a user-facing release",
        )
    if manifest.get("extractNativeLibs") is not False:
        _failure(
            failures,
            "manifest.extract-native-libs",
            "APK must set android:extractNativeLibs=false for the packaged "
            "native libraries",
        )
    if badging:
        for field in ("package", "versionCode", "versionName"):
            manifest_value = manifest.get(field)
            badging_value = badging.get(field)
            if field == "versionCode":
                try:
                    badging_value = int(badging_value)
                except (TypeError, ValueError):
                    badging_value = None
            if badging_value is not None and manifest_value != badging_value:
                _failure(
                    failures,
                    "badging.{}".format(field),
                    "aapt2 badging {} {!r} does not match the binary manifest "
                    "{!r}".format(field, badging_value, manifest_value),
                )
        if sorted(badging.get("abis", [])) != sorted(zip_facts.get("abis", [])):
            _failure(
                failures,
                "badging.abi",
                "aapt2 badging native-code {} does not match packaged ABI {}".format(
                    badging.get("abis"), zip_facts.get("abis")
                ),
            )
    if signing:
        for problem in signing.get("problems", []):
            _failure(failures, problem.get("id", "signing.problem"), problem.get("message", "signing problem"))
        if signing.get("certSha256") != policy.cert_sha256:
            _failure(
                failures,
                "signing.cert-mismatch",
                "APK signer certificate {!r} does not match the intended formal "
                "certificate {!r}".format(signing.get("certSha256"), policy.cert_sha256),
            )
    markers = dex.get("markers", {})
    if not all(markers.get(marker) for marker in FULL_ONLY_MARKERS):
        _failure(
            failures,
            "channel.full",
            "APK does not contain both full-only marker classes; a Play/test or "
            "different channel artifact is rejected",
        )
    for problem in native.get("problems", []):
        _failure(failures, problem.get("id", "native.problem"), problem.get("message", "native problem"))
    if native.get("stripped") is False and not any(
        problem.get("id") == "native.debug-sections"
        for problem in native.get("problems", [])
    ):
        _failure(
            failures,
            "native.debug-sections",
            "native debug sections remain; stripping must precede final signing",
        )

    native_report = dict(native)
    if policy.native_manifest is not None:
        comparison = _compare_native_manifest(policy, native)
        if policy.native_manifest_role == "derived":
            for name in comparison["missing"]:
                _failure(
                    failures,
                    "native.manifest.derived-missing",
                    "derived native manifest is missing packaged library {}".format(name),
                )
            for item in comparison["derived"]:
                _failure(
                    failures,
                    "native.manifest.derived-mismatch",
                    "derived native manifest hash mismatch for {}".format(item["name"]),
                )
        else:
            for name in comparison["missing"]:
                _failure(
                    failures,
                    "native.manifest.missing",
                    "canonical native manifest records missing library {}".format(name),
                )
        native_report["canonicalManifest"] = comparison
        native_report["libraryBasis"] = comparison["basis"]
    else:
        native_report["canonicalManifest"] = None
        native_report["libraryBasis"] = "not-compared"
    native_report["runtimeEquivalenceVerified"] = False

    if apk_sha256 != policy.expected_sha256:
        _failure(
            failures,
            "provenance.hash",
            "staged artifact SHA-256 does not match the supplied preverified hash",
        )

    if policy.previous_version_code is not None:
        if policy.version_code <= policy.previous_version_code:
            _failure(
                failures,
                "upgrade.version-code",
                "versionCode is not greater than the supplied previous release",
            )
        if signing.get("certSha256") != policy.previous_cert_sha256:
            _failure(
                failures,
                "upgrade.certificate",
                "signer certificate does not match the previous release identity",
            )
        if manifest.get("package") != policy.previous_package:
            _failure(
                failures,
                "upgrade.package",
                "package does not match the previous release package",
            )
        continuity = "supplied-and-matching"
    else:
        continuity = "not-established"

    badging_abis = badging.get("abis", []) if badging else []
    report = {
        "schemaVersion": SCHEMA_VERSION,
        "tool": {
            "name": TOOL_NAME,
            "version": TOOL_VERSION,
            "versions": facts.get("toolVersions", {}),
        },
        "generatedAt": utc_now(),
        "platform": "android",
        "channel": FULL_DISTRIBUTION,
        "tag": policy.tag,
        "versionName": policy.version_name,
        "versionCode": policy.version_code,
        "package": policy.package,
        "abi": ANDROID_ABI,
        "sourceCommit": policy.source_commit,
        "sourceRepository": policy.source_repository,
        "stageLabel": policy.stage_label,
        "maturity": policy.maturity,
        "apk": {
            "fileName": policy.asset_filename(),
            "sha256": apk_sha256,
            "bytes": apk_bytes,
        },
        "zip": {
            "entryCount": zip_facts.get("entryCount"),
            "uncompressedBytes": zip_facts.get("uncompressedBytes"),
            "nativeLibraryCount": len(zip_facts.get("nativeEntries", [])),
            "nativeEntries": zip_facts.get("nativeEntries", []),
            "nestedPackageEntries": zip_facts.get("nestedPackageEntries", []),
            "dexFiles": zip_facts.get("dexEntries", []),
            "licenseEntries": zip_facts.get("licenseEntries", []),
            "problems": zip_facts.get("problems", []),
        },
        "manifest": {
            "package": manifest.get("package"),
            "versionCode": manifest.get("versionCode"),
            "versionName": manifest.get("versionName"),
            "minSdk": manifest.get("minSdk"),
            "targetSdk": manifest.get("targetSdk"),
            "abis": badging_abis,
            "debuggable": manifest.get("debuggable"),
            "testOnly": manifest.get("testOnly"),
            "split": manifest.get("split"),
            "sharedUserId": manifest.get("sharedUserId"),
            "extractNativeLibs": manifest.get("extractNativeLibs"),
            "hasInstrumentation": manifest.get("hasInstrumentation"),
        },
        "signing": {
            "verified": signing.get("verified", False),
            "schemes": signing.get("schemes", {}),
            "modernScheme": signing.get("modernScheme", False),
            "signerCount": signing.get("signerCount"),
            "certSha256": signing.get("certSha256"),
            "dn": signing.get("dn"),
            "debugCertificate": signing.get("debugCertificate", False),
            "problems": signing.get("problems", []),
        },
        "channelEvidence": {
            "markers": markers,
            "fullOnlyClassCount": dex.get("fullOnlyClassCount", 0),
            "ok": all(markers.get(marker) for marker in FULL_ONLY_MARKERS),
        },
        "license": {
            "project": "MPL-2.0",
            "packagedLicenseEntries": zip_facts.get("licenseEntries", []),
            "noticeUrl": (
                "https://github.com/{}/blob/{}/FloeAndroid/NOTICE.md".format(
                    policy.source_repository, policy.source_commit
                )
                if policy.source_repository
                else None
            ),
            "completenessVerified": False,
            "note": "Packaged notices are preserved; completeness of third-party "
            "redistribution obligations remains Main's review.",
        },
        "native": native_report,
        "embeddedRuntime": runtime_section,
        "upgrade": {
            "previousVersionCode": policy.previous_version_code,
            "previousCertSha256": policy.previous_cert_sha256,
            "previousPackage": policy.previous_package,
            "previousReleaseTag": policy.previous_release_tag,
            "versionCodeIncremented": (
                policy.version_code > policy.previous_version_code
                if policy.previous_version_code is not None
                else None
            ),
            "identityContinuity": continuity,
        },
        "provenance": {
            "expectedArtifactSha256": policy.expected_sha256,
            "actualArtifactSha256": apk_sha256,
            "expectedArtifactHashMatched": apk_sha256 == policy.expected_sha256,
            "sourceCommit": policy.source_commit,
            "sourceRepository": policy.source_repository,
            "qualificationVerifiedByToolkit": False,
            "note": "Source/qualification acceptance is Main-supplied; this "
            "toolkit binds the artifact hash and supplied metadata only.",
        },
        "publication": dict(PUBLICATION_BLOCK),
        "mainGates": [
            "Main confirms the exact source commit and qualification evidence.",
            "Main confirms the version, versionCode and android/v tag are unused "
            "and the tag points to the exact source commit.",
            "Main confirms the supplied certificate is the intended formal "
            "signing identity and protects the key.",
            "Main confirms stripped/derived native libraries preserve allocated "
            "sections, build IDs, exports, dependencies and 16 KiB layout "
            "against the canonical build; the toolkit reports hashes and ELF "
            "evidence but does not prove runtime equivalence.",
            "Main creates/edits/publishes the Android Release with "
            "--latest=false; repository Latest stays reserved for iOS.",
            "Main downloads the published APK, verifies SHA256SUMS, and performs "
            "an actual coverage install from the previous version with data "
            "retained.",
            "Main performs the actual stage/basic-usability acceptance; this "
            "toolkit does not claim G02 or first-release acceptance.",
        ],
        "limitations": list(LIMITATIONS),
        "ok": not failures,
        "failures": failures,
    }
    return report


def base_report(policy: ReleasePolicy) -> Dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "tool": {"name": TOOL_NAME, "version": TOOL_VERSION, "versions": {}},
        "generatedAt": utc_now(),
        "platform": "android",
        "channel": FULL_DISTRIBUTION,
        "tag": policy.tag,
        "versionName": policy.version_name,
        "versionCode": policy.version_code,
        "package": policy.package,
        "abi": ANDROID_ABI,
        "sourceCommit": policy.source_commit,
        "sourceRepository": policy.source_repository,
        "stageLabel": policy.stage_label,
        "maturity": policy.maturity,
        "publication": dict(PUBLICATION_BLOCK),
        "limitations": list(LIMITATIONS),
        "ok": False,
        "failures": [],
    }


# ---------------------------------------------------------------------------
# Stable copy, atomic commit, body generation
# ---------------------------------------------------------------------------


def _file_identity(info: os.stat_result) -> Tuple[int, int, int, int]:
    mtime = getattr(info, "st_mtime_ns", int(info.st_mtime * 1_000_000_000))
    return (int(info.st_dev), int(info.st_ino), int(info.st_size), int(mtime))


def _open_no_follow(path: Path) -> int:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return os.open(str(path), flags)


def _read_all_chunked(fd: int, chunk_size: int) -> Iterable[bytes]:
    while True:
        chunk = os.read(fd, chunk_size)
        if not chunk:
            return
        yield chunk


def stable_hash(path: Path, chunk_size: int = COPY_CHUNK) -> Dict[str, Any]:
    fd = _open_no_follow(path)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise StageReleaseError("source.not-file", "source is not a regular file")
        if before.st_size <= 0:
            raise StageReleaseError("source.empty", "source APK is empty")
        if before.st_size > MAX_APK_BYTES:
            raise StageReleaseError("source.size", "source APK exceeds the bounded size")
        digest = hashlib.sha256()
        total = 0
        for chunk in _read_all_chunked(fd, chunk_size):
            total += len(chunk)
            if total > MAX_APK_BYTES:
                raise StageReleaseError("source.size", "source APK exceeds the bounded size")
            digest.update(chunk)
        after = os.fstat(fd)
    finally:
        os.close(fd)
    try:
        path_info = os.stat(str(path), follow_symlinks=False)
    except OSError as exc:
        raise StageReleaseError("source.changed", "source disappeared during hashing: {}".format(exc))
    if _file_identity(before) != _file_identity(after) or _file_identity(before) != _file_identity(path_info):
        raise StageReleaseError("source.changed", "source APK changed while it was being hashed")
    if total != before.st_size:
        raise StageReleaseError("source.changed", "source size changed while it was being hashed")
    return {
        "sha256": digest.hexdigest(),
        "bytes": total,
        "identity": _file_identity(after),
    }


def copy_source_to_path(
    source: Path,
    destination: Path,
    expected_sha256: str,
    chunk_size: int = COPY_CHUNK,
    on_chunk: Optional[Callable[[int], None]] = None,
) -> Dict[str, Any]:
    """Copy exact source bytes with a stable identity check and bounded buffers."""

    if destination.exists():
        raise StageReleaseError("copy.destination", "staging destination already exists")
    source_fd = _open_no_follow(source)
    destination_fd = None
    completed = False
    try:
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode):
            raise StageReleaseError("source.not-file", "source is not a regular file")
        if before.st_size <= 0:
            raise StageReleaseError("source.empty", "source APK is empty")
        if before.st_size > MAX_APK_BYTES:
            raise StageReleaseError("source.size", "source APK exceeds the bounded size")
        destination_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            destination_flags |= os.O_NOFOLLOW
        destination_fd = os.open(str(destination), destination_flags, 0o644)
        digest = hashlib.sha256()
        total = 0
        for chunk in _read_all_chunked(source_fd, chunk_size):
            total += len(chunk)
            if total > MAX_APK_BYTES:
                raise StageReleaseError("source.size", "source APK exceeds the bounded size")
            digest.update(chunk)
            written = 0
            while written < len(chunk):
                written += os.write(destination_fd, chunk[written:])
            if on_chunk is not None:
                on_chunk(total)
        os.fsync(destination_fd)
        os.chmod(str(destination), 0o644)
        after = os.fstat(source_fd)
        path_info = os.stat(str(source), follow_symlinks=False)
        if _file_identity(before) != _file_identity(after) or _file_identity(before) != _file_identity(path_info):
            raise StageReleaseError(
                "source.changed", "source APK changed while it was being copied"
            )
        if total != before.st_size:
            raise StageReleaseError(
                "source.changed", "source size changed while it was being copied"
            )
        actual = digest.hexdigest()
        if actual != expected_sha256:
            raise StageReleaseError(
                "provenance.hash",
                "source SHA-256 {} does not match the supplied preverified "
                "hash {}".format(actual, expected_sha256),
            )
        completed = True
        return {"sha256": actual, "bytes": total}
    finally:
        if destination_fd is not None:
            os.close(destination_fd)
        os.close(source_fd)
        if not completed:
            try:
                destination.unlink()
            except FileNotFoundError:
                pass


def _write_new_file(path: Path, content: bytes) -> None:
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        position = 0
        while position < len(content):
            position += os.write(fd, content[position:])
        os.fsync(fd)
    finally:
        os.close(fd)
    os.chmod(str(path), 0o644)


def _fsync_directory(path: Path) -> None:
    try:
        fd = os.open(str(path), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def _validate_output_destination(output: Path) -> Path:
    if os.path.islink(str(output)):
        raise StageReleaseError(
            "output.symlink", "output path is a symlink; choose a real directory"
        )
    resolved = output.resolve(strict=False)
    if resolved == Path(resolved.anchor):
        raise StageReleaseError("output.root", "output must not be a filesystem root")
    parent = resolved.parent
    if not parent.is_dir():
        raise StageReleaseError(
            "output.parent", "output parent directory does not exist: {}".format(parent)
        )
    if resolved.exists():
        if not resolved.is_dir():
            raise StageReleaseError("output.not-directory", "output exists and is not a directory")
        entries = list(os.scandir(str(resolved)))
        if entries:
            raise StageReleaseError(
                "output.nonempty",
                "output directory is not empty; refusing to replace an existing "
                "asset set",
            )
    return resolved


def _is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _validate_side_destination(path: Path, output: Path, label: str) -> Path:
    if os.path.islink(str(path)):
        raise StageReleaseError(
            "output.{}".format(label), "{} path is a symlink".format(label)
        )
    resolved = path.resolve(strict=False)
    if resolved == Path(resolved.anchor):
        raise StageReleaseError(
            "output.{}".format(label), "{} must not be a filesystem root".format(label)
        )
    if resolved == output or _is_within(resolved, output):
        raise StageReleaseError(
            "output.{}".format(label),
            "{} must be outside the upload-asset directory".format(label),
        )
    if os.path.lexists(str(resolved)):
        raise StageReleaseError(
            "output.{}".format(label),
            "{} already exists; remove it or choose a new path (existing files "
            "are never overwritten)".format(label),
        )
    if not resolved.parent.is_dir():
        raise StageReleaseError(
            "output.{}".format(label),
            "{} parent directory does not exist".format(label),
        )
    return resolved


def _verify_asset_directory(directory: Path, apk_name: str) -> Dict[str, Any]:
    entries = list(os.scandir(str(directory)))
    names = sorted(entry.name for entry in entries)
    expected = sorted([apk_name, CHECKSUM_FILENAME])
    if names != expected:
        raise StageReleaseError(
            "output.shape",
            "asset directory must contain exactly {!r}; got {!r}".format(
                expected, names
            ),
        )
    for entry in entries:
        if entry.is_symlink() or not entry.is_file(follow_symlinks=False):
            raise StageReleaseError(
                "output.shape",
                "asset directory contains a non-regular entry: {}".format(entry.name),
            )
    return {"names": names}


def _checksum_content(apk_name: str, digest: str) -> bytes:
    return "{}  {}\n".format(digest, apk_name).encode("ascii")


def verify_checksum_text(text: str, apk_name: str, digest: str) -> bool:
    lines = text.splitlines()
    if len(lines) != 1:
        return False
    fields = lines[0].split("  ", 1)
    if len(fields) != 2:
        return False
    return fields[0].lower() == digest and fields[1] == apk_name


def _write_temp_in_parent(target: Path, content: bytes) -> Path:
    fd, name = tempfile.mkstemp(prefix=".prepare-stage-body-", dir=str(target.parent))
    tmp = Path(name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(str(tmp), 0o644)
    except Exception:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        raise
    return tmp


def _publish_temp_no_clobber(tmp: Path, target: Path) -> None:
    published = False
    try:
        os.link(str(tmp), str(target), follow_symlinks=False)
        published = True
    except FileExistsError:
        raise StageReleaseError(
            "output.body",
            "body output appeared while preparing; refusing to overwrite it",
        )
    except OSError:
        # Filesystems without hardlinks: fall back to an atomic rename, but
        # only after confirming the target is still absent.
        if os.path.lexists(str(target)):
            raise StageReleaseError(
                "output.body",
                "body output appeared while preparing; refusing to overwrite it",
            )
        os.rename(str(tmp), str(target))
        published = True
    finally:
        if published:
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass
    _fsync_directory(target.parent)


def build_body(policy: ReleasePolicy, report: Dict[str, Any]) -> str:
    version = policy.version_name
    maturity = (
        "prerelease stage build"
        if policy.maturity == "prerelease"
        else "stable stage build"
    )
    apk = report["apk"]
    lines = [
        "# Floe for Android {}".format(version),
        "",
        "Android {} (full distribution).".format(maturity),
        "",
        "## Build",
        "",
        "- Tag: `{}`".format(policy.tag),
        "- Package: `{}`".format(policy.package),
        "- Version: `{}` (versionCode {})".format(policy.version_name, policy.version_code),
        "- ABI: `{}`".format(ANDROID_ABI),
        "- Minimum Android: API {}".format(report["manifest"]["minSdk"]),
        "- Target Android: API {}".format(report["manifest"]["targetSdk"]),
        "- APK: `{}`".format(apk["fileName"]),
        "- SHA-256: `{}`".format(apk["sha256"]),
    ]
    if policy.stage_label:
        lines.append("- Stage: {}".format(policy.stage_label))
    if policy.source_repository:
        lines.append(
            "- Source: [{repo}@{commit}](https://github.com/{repo}/tree/{commit})".format(
                repo=policy.source_repository, commit=policy.source_commit
            )
        )
    else:
        lines.append("- Source commit: `{}`".format(policy.source_commit))
    lines.extend(
        [
            "",
            "## Install",
            "",
            "1. Download `{}` and `SHA256SUMS` from this release.".format(apk["fileName"]),
            "2. Verify the download (Linux: `sha256sum -c SHA256SUMS`; macOS: "
            "`shasum -a 256 -c SHA256SUMS`).",
            "3. Open the APK in your device's package installer. Android may ask "
            "you to allow installs from the app that opened the file.",
            "",
            "Installing over an older build keeps app data when the package name "
            "and signing identity match. If the signer differs, Android will "
            "reject the update; uninstalling first erases app data, so back up "
            "anything important.",
            "",
            "## Updates",
            "",
            "This stage supports **manual APK installation only**. No Android "
            "update feed or in-app automatic update check is included yet, and "
            "this release does not contain `update.json` or another updater "
            "metadata file. Install newer stage APKs manually when published.",
            "",
            "## Known limitations",
            "",
            "- This is a {}; features may be incomplete and behavior may change.".format(
                "prerelease" if policy.maturity == "prerelease" else "stage release"
            ),
            "- Full distribution, `arm64-v8a` devices only. There is no 32-bit "
            "or x86 artifact and no Google Play submission implied.",
            "- Android API {} or newer is required.".format(report["manifest"]["minSdk"]),
            "- Device-specific behavior, full CJK input/TalkBack parity, and "
            "16 KiB-page runtime behavior are not implied by a successful "
            "installation.",
            "",
            "## License",
            "",
            "Floe is licensed under the Mozilla Public License 2.0. Third-party "
            "notices are included with the app where packaged and in the source "
            "distribution.",
        ]
    )
    if policy.source_repository:
        lines.append(
            "License and notices: [LICENSE](https://github.com/{repo}/blob/{commit}/LICENSE), "
            "[FloeAndroid/NOTICE.md](https://github.com/{repo}/blob/{commit}/FloeAndroid/NOTICE.md).".format(
                repo=policy.source_repository, commit=policy.source_commit
            )
        )
    lines.append("")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# check / prepare operations
# ---------------------------------------------------------------------------


def check_release(
    policy: ReleasePolicy,
    inspector: Optional[Any] = None,
) -> Dict[str, Any]:
    inspector = inspector or build_inspector(policy)
    source_info = stable_hash(policy.apk)
    facts = inspector.inspect(policy.apk)
    path_after = os.stat(str(policy.apk), follow_symlinks=False)
    if _file_identity(path_after) != source_info["identity"]:
        raise StageReleaseError(
            "source.changed", "source APK changed while it was being inspected"
        )
    after_info = stable_hash(policy.apk)
    if after_info["sha256"] != source_info["sha256"]:
        raise StageReleaseError(
            "source.changed", "source APK changed while it was being inspected"
        )
    report = evaluate(policy, facts, source_info["sha256"], source_info["bytes"])
    report["mode"] = "check"
    report["actions"] = ["read", "hash", "verify"]
    report["assetSetCommitted"] = False
    report["bodyWritten"] = False
    report["apkInputName"] = policy.apk.name
    return report


def build_inspector(policy: ReleasePolicy) -> ApkInspector:
    aapt2 = find_sdk_tool(
        "aapt2", str(policy.aapt2) if policy.aapt2 else None, "--aapt2"
    )
    apksigner = find_sdk_tool(
        "apksigner", str(policy.apksigner) if policy.apksigner else None, "--apksigner"
    )
    return ApkInspector(aapt2, apksigner)


def prepare_release(
    policy: ReleasePolicy,
    output: Path,
    body_out: Path,
    inspector: Optional[Any] = None,
) -> Dict[str, Any]:
    report = base_report(policy)
    report["mode"] = "prepare"
    report["actions"] = ["read", "hash", "verify", "copy", "checksum"]
    report["assetSetCommitted"] = False
    report["bodyWritten"] = False
    report["assets"] = None
    report["outputs"] = None

    staging = None
    body_tmp = None
    try:
        output_resolved = _validate_output_destination(Path(output).expanduser())
        body_resolved = _validate_side_destination(
            Path(body_out).expanduser(), output_resolved, "body"
        )
        inspector = inspector or build_inspector(policy)
        staging = Path(
            tempfile.mkdtemp(
                prefix=".prepare-stage-release-", dir=str(output_resolved.parent)
            )
        )
        os.chmod(str(staging), 0o700)
        apk_name = policy.asset_filename()
        staged_apk = staging / apk_name
        copy_info = copy_source_to_path(
            policy.apk, staged_apk, policy.expected_sha256
        )
        facts = inspector.inspect(staged_apk)
        report = evaluate(policy, facts, copy_info["sha256"], copy_info["bytes"])
        report["mode"] = "prepare"
        report["actions"] = ["read", "hash", "verify", "copy", "checksum"]
        report["assetSetCommitted"] = False
        report["bodyWritten"] = False
        report["apkInputName"] = policy.apk.name
        report["apk"] = {
            "fileName": apk_name,
            "sha256": copy_info["sha256"],
            "bytes": copy_info["bytes"],
        }
        if not report["ok"]:
            return report

        checksum_bytes = _checksum_content(apk_name, copy_info["sha256"])
        _write_new_file(staging / CHECKSUM_FILENAME, checksum_bytes)
        _verify_asset_directory(staging, apk_name)
        staged_sha = stable_hash(staged_apk)["sha256"]
        if staged_sha != copy_info["sha256"]:
            raise StageReleaseError(
                "copy.verification",
                "staged APK hash changed after verification; refusing to commit",
            )
        checksum_hash = hashlib.sha256(checksum_bytes).hexdigest()
        report["assets"] = [
            {
                "name": apk_name,
                "sha256": copy_info["sha256"],
                "bytes": copy_info["bytes"],
            },
            {
                "name": CHECKSUM_FILENAME,
                "sha256": checksum_hash,
                "bytes": len(checksum_bytes),
            },
        ]

        body_bytes = build_body(policy, report).encode("utf-8")
        body_tmp = _write_temp_in_parent(body_resolved, body_bytes)
        os.chmod(str(staging), 0o755)
        os.rename(str(staging), str(output_resolved))
        staging = None
        _fsync_directory(output_resolved.parent)
        report["assetSetCommitted"] = True
        try:
            _publish_temp_no_clobber(body_tmp, body_resolved)
            body_tmp = None
            report["bodyWritten"] = True
        except StageReleaseError as exc:
            report["ok"] = False
            report["failures"].append({"id": exc.code, "message": exc.message})
            return report

        _verify_asset_directory(output_resolved, apk_name)
        final_sha = stable_hash(output_resolved / apk_name)["sha256"]
        if final_sha != copy_info["sha256"]:
            report["ok"] = False
            report["failures"].append(
                {
                    "id": "output.verification",
                    "message": "committed APK hash does not match the verified "
                    "staged hash",
                }
            )
        checksum_text = (output_resolved / CHECKSUM_FILENAME).read_text(
            encoding="ascii"
        )
        if not verify_checksum_text(checksum_text, apk_name, copy_info["sha256"]):
            report["ok"] = False
            report["failures"].append(
                {
                    "id": "output.checksum",
                    "message": "committed SHA256SUMS does not match the APK",
                }
            )
        report["outputs"] = {
            "assetDirectory": output_resolved.name,
            "apkFile": apk_name,
            "checksumFile": CHECKSUM_FILENAME,
            "bodyFile": body_resolved.name,
        }
        return report
    except StageReleaseError as exc:
        report["ok"] = False
        report["failures"].append({"id": exc.code, "message": exc.message})
        return report
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        report["ok"] = False
        report["failures"].append(
            {"id": "prepare.error", "message": "{}: {}".format(type(exc).__name__, exc)}
        )
        return report
    finally:
        if body_tmp is not None:
            try:
                body_tmp.unlink()
            except FileNotFoundError:
                pass
        if staging is not None:
            shutil.rmtree(str(staging), ignore_errors=True)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _add_common_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--apk", required=True, help="exact signed full-channel APK")
    parser.add_argument("--apksigner", help="apksigner executable (default: SDK/PATH)")
    parser.add_argument("--aapt2", help="aapt2 executable (default: SDK/PATH)")
    parser.add_argument(
        "--expected-sha256",
        required=True,
        help="preverified SHA-256 of the exact APK supplied by Main",
    )
    parser.add_argument("--package", required=True, help="expected Android package")
    parser.add_argument("--version-code", required=True, type=int)
    parser.add_argument("--version-name", required=True)
    parser.add_argument("--tag", required=True, help="android/v<version>")
    parser.add_argument("--cert-sha256", required=True, help="intended formal signer cert SHA-256")
    parser.add_argument("--source-commit", required=True, help="exact Git source commit")
    parser.add_argument("--source-repository", help="public GitHub OWNER/REPO (optional)")
    parser.add_argument("--min-sdk", required=True, type=int)
    parser.add_argument("--target-sdk", required=True, type=int)
    parser.add_argument(
        "--maturity",
        required=True,
        choices=("prerelease", "stable"),
        help="declared GitHub release maturity",
    )
    parser.add_argument("--stage-label", help="optional stage label such as G02")
    parser.add_argument("--previous-version-code", type=int)
    parser.add_argument("--previous-cert-sha256")
    parser.add_argument("--previous-package")
    parser.add_argument("--previous-release-tag", help="previous android/v tag, if any")
    parser.add_argument(
        "--native-manifest",
        help="existing native-manifest.json (canonical or derived role)",
    )
    parser.add_argument(
        "--native-manifest-role",
        choices=("canonical", "derived"),
        default="canonical",
        help="canonical compares hashes and reports derived differences; derived "
        "requires exact staged hashes",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=TOOL_NAME,
        description="Prepare a clean one-APK + SHA256SUMS Android stage-release "
        "asset set after read-only verification. Never publishes.",
        allow_abbrev=False,
    )
    parser.add_argument("--version", action="version", version=TOOL_VERSION)
    subparsers = parser.add_subparsers(dest="command", required=True)

    check = subparsers.add_parser(
        "check",
        help="read-only verification report; writes nothing",
        allow_abbrev=False,
    )
    _add_common_arguments(check)

    prepare = subparsers.add_parser(
        "prepare",
        help="verify, stable-copy, checksum and atomically commit the asset set",
        allow_abbrev=False,
    )
    _add_common_arguments(prepare)
    prepare.add_argument(
        "--output", required=True, help="empty/absent upload-assets directory"
    )
    prepare.add_argument(
        "--body-out",
        required=True,
        help="release-body Markdown file OUTSIDE the upload-assets directory",
    )
    return parser


def failure_report(code: str, message: str) -> Dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "tool": {"name": TOOL_NAME, "version": TOOL_VERSION, "versions": {}},
        "generatedAt": utc_now(),
        "ok": False,
        "failures": [{"id": code, "message": message}],
        "publication": dict(PUBLICATION_BLOCK),
        "limitations": list(LIMITATIONS),
    }


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        policy = policy_from_args(args)
        if args.command == "check":
            reporter = check_release(policy)
        else:
            reporter = prepare_release(policy, Path(args.output), Path(args.body_out))
    except StageReleaseError as exc:
        reporter = failure_report(exc.code, exc.message)
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        reporter = failure_report(
            "unexpected.error", "{}: {}".format(type(exc).__name__, exc)
        )
    except Exception as exc:
        reporter = failure_report(
            "unexpected.error", "{}: {}".format(type(exc).__name__, exc)
        )
    print(json.dumps(reporter, indent=2, sort_keys=False))
    if not reporter.get("ok"):
        messages = "; ".join(
            failure.get("message", "unknown failure")
            for failure in reporter.get("failures", [])
        )
        print("ERROR: {}".format(messages), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
