#!/usr/bin/env python3
"""Verify a Floe iOS Bridge package against trusted project identity.

The verifier deliberately takes the expected marketing version and build
number from ``project.yml`` (or from that file at an explicit committed
source ref) instead of hard-coded constants.  A caller may repeat those
values on the command line as an assertion, but a conflicting caller value is
rejected rather than used as an override.

Three modes are supported:

``qualification``
    Legacy private DDI/device qualification of the retained prototype,
    including the prototype-only file and LAN diagnostic surfaces.  Existing
    prototype assertions (including the historical ``continuous`` background
    marker) are retained for Build 13 compatibility.

``product-qualification``
    Private qualification of product-content IPA.  It uses the same content
    policy as release (no prototype flags/markers, source-bound identity and
    provenance) but permits a privately signed artifact and explicit custom
    bundle IDs.  It is not a public distribution mode.

``release``
    Public standalone IPA.  Prototype flags and the old file/bearer/LAN
    control markers must be absent, a committed source ref is required and the
    artifact must remain unsigned with canonical bundle IDs.  This is
    package/static verification; it does not claim runtime closure.

The topology, linkage, arm64 iphoneos Mach-O, UUID, nested dependency, no-DDI,
notice and signing-boundary checks are shared by all modes.

Public unsigned verification is always bound to the canonical application IDs.
Private re-signed verification may pass ``--bundle-id <explicit host id>``
together with ``--allow-signed``; the tunnel/core/test IDs are derived from it
and every Info.plist is checked.  Executable bytes and source constants are not
rewritten by this verifier.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile
from dataclasses import dataclass
from pathlib import Path

HOST_ID = "org.floeagent.iosbridge"
TUNNEL_ID = "org.floeagent.iosbridge.tunnel"
CORE_ID = "org.floeagent.iosbridge.core"
BUNDLE_ID_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$")
TEST_NAME = "BridgeTests.xctest"
APPEX_NAME = "BridgeTunnel.appex"
HOST_APP_NAME = "BridgeHost.app"
HOST_EXECUTABLE = "BridgeHost"
APPEX_EXECUTABLE = "BridgeTunnel"
TEST_EXECUTABLE = "BridgeTests"
CORE_EXECUTABLE = "BridgeCore"

QUALIFICATION = "qualification"
PRODUCT_QUALIFICATION = "product-qualification"
RELEASE = "release"
MODES = (QUALIFICATION, PRODUCT_QUALIFICATION, RELEASE)
# Product modes use the public-content policy; only the signature boundary
# differs between a private product qualification and a public release.
PRODUCT_MODES = (PRODUCT_QUALIFICATION, RELEASE)
PRIVATE_SIGNING_MODES = (QUALIFICATION, PRODUCT_QUALIFICATION)

# Apple "Configuring background execution modes" documents these values for
# iOS/iPadOS apps (2026).  "continuous" is not one of them.  This static check
# validates declarations only; actual background execution needs separate
# physical-device evidence.
DOCUMENTED_IOS_BACKGROUND_MODES = frozenset({
    "audio",
    "location",
    "voip",
    "external-accessory",
    "bluetooth-central",
    "bluetooth-peripheral",
    "screen-capture",
    "fetch",
    "remote-notification",
    "processing",
    "nearby-interaction",
    "push-to-talk",
})

IOS_MACHO_PLATFORM = 2
MINIMUM_IOS_VERSION = (26, 0)
RELEASE_MINIMUM_MAJOR = 1
RELEASE_MINIMUM_BUILD = 14

FORBIDDEN_HOST_LOADS = (
    "XCTest", "XCTestCore", "XCUIAutomation", "XCTAutomationSupport",
    "libXCTest", "XCTestSupport", "XCTestSwiftSupport",
)
REQUIRED_TEST_LOADS = (
    "XCTest.framework/XCTest",
    "XCUIAutomation.framework/XCUIAutomation",
    "BridgeCore.framework/BridgeCore",
)
REQUIRED_HOST_RPATHS = (
    "/System/Developer/Library/Frameworks",
    "/System/Developer/Library/PrivateFrameworks",
    "/System/Developer/usr/lib",
    "/Developer/Library/Frameworks",
    "/Developer/Library/PrivateFrameworks",
    "/Developer/usr/lib",
    "/private/preboot/Cryptexes/OS/System/Developer/Library/Frameworks",
    "/private/preboot/Cryptexes/OS/System/Developer/Library/PrivateFrameworks",
    "/private/preboot/Cryptexes/OS/System/Developer/usr/lib",
)
FORBIDDEN_ARTIFACT_NAMES = {
    "XCTest.framework", "XCTestCore.framework", "XCUIAutomation.framework",
    "XCTAutomationSupport.framework", "XCTestSupport.framework",
    "libXCTestSwiftSupport.dylib", "Image.dmg", "BuildManifest.plist",
    "IDevice.xcframework",
}
FORBIDDEN_SUFFIXES = (".trustcache", ".cryptex_info", ".root_hash", ".dmg")
SIGNING_FILE_SUFFIXES = (".p12", ".pfx", ".key", ".pem", ".cer")
PROFILE_NAMES = ("embedded.mobileprovision", "embedded.provisionprofile")

TARGET_ROLES = {
    "BridgeHost": "host",
    "BridgeTunnel": "appex",
    "BridgeCore": "core",
    "BridgeTests": "test",
}
ROLE_LABELS = ("host", "appex", "core", "test")
EXPECTED_FILE_TYPES = {
    "host": "EXECUTE",
    "appex": "EXECUTE",
    "test": "BUNDLE",
    "core": "DYLIB",
    "appex-core": "DYLIB",
}

# These are static inclusion markers, not proof that a runtime surface is
# absent.  A public release must fail if the old prototype file/bearer/LAN
# control strings are still compiled into the host or extension.
RELEASE_LEGACY_MARKERS = (
    "FloePrototypeChannels",
    "FloePrototypeDiagnostics",
    "org.floeagent.iosbridge.prototype.",
    "BridgeFileChannel",
    "prototypeToken",
    "fileChannelAccount",
    "controlKey",
    "controlEnabled",
    "replacementToken",
    "LAN control (prototype)",
    "Prototype token copied",
)

MARKETING_RE = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._-]*$")
SEMVER_RE = re.compile(r"^([0-9]+)\.([0-9]+)\.([0-9]+)$")
BUILD_RE = re.compile(r"^[0-9]+$")
UUID_RE = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
BRIDGEBUILD_VERSION_RE = re.compile(r'marketingVersion\s*=\s*"([^"]+)"')
BRIDGEBUILD_NUMBER_RE = re.compile(r'buildNumber\s*=\s*"([^"]+)"')
BRIDGEBUILD_PROTOTYPE_RE = re.compile(r"prototypeDiagnostics\s*=\s*(true|false)")
FETCH_VERSION_RE = re.compile(r'^VERSION="([^"]+)"', re.MULTILINE)
FETCH_ASSET_RE = re.compile(r'^ASSET_SHA256="([^"]+)"', re.MULTILINE)


class IdentityError(ValueError):
    """The trusted expected version/source does not describe this package."""


def derive_bundle_ids(host_bundle_id: str = HOST_ID) -> dict[str, str]:
    """Derive the host/tunnel/core/test bundle IDs from one explicit host ID."""
    host = (host_bundle_id or "").strip()
    if not BUNDLE_ID_RE.fullmatch(host):
        raise IdentityError(
            "host bundle ID must be a reverse-DNS identifier using letters, "
            "digits and hyphens"
        )
    if host.endswith((".tunnel", ".core")):
        raise IdentityError("host bundle ID must not end in .tunnel or .core")
    return {
        "host": host,
        "tunnel": host + ".tunnel",
        "core": host + ".core",
        "test": host,
    }


def canonical_bundle_ids() -> dict[str, str]:
    return derive_bundle_ids(HOST_ID)


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, capture_output=True)


def plist_raw(path: Path, key: str) -> str | None:
    result = run(["/usr/bin/plutil", "-extract", key, "raw", "-o", "-", str(path)])
    return result.stdout.strip() if result.returncode == 0 else None


def plist_all(path: Path) -> dict:
    try:
        with path.open("rb") as handle:
            payload = plistlib.load(handle)
        return payload if isinstance(payload, dict) else {}
    except (OSError, plistlib.InvalidFileException, ValueError):
        return {}


def plist_json(path: Path, key: str):
    result = run(["/usr/bin/plutil", "-extract", key, "json", "-o", "-", str(path)])
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def _value_is_truthy(value) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"true", "yes", "1"}
    return value == 1


def _strip_comment(line: str) -> str:
    single = False
    double = False
    for index, character in enumerate(line):
        if character == "'" and not double:
            single = not single
        elif character == '"' and not single:
            double = not double
        elif character == "#" and not single and not double:
            if index == 0 or line[index - 1].isspace():
                return line[:index]
    return line


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def parse_simple_mapping(text: str) -> dict:
    """Parse the mapping subset used by project.yml.

    Lists are intentionally ignored; only nested mappings of scalar values are
    needed for build settings and target overrides.
    """
    root: dict = {}
    stack: list[tuple[int, dict]] = [(-1, root)]
    for raw in text.splitlines():
        line = _strip_comment(raw)
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        content = line.strip()
        if content.startswith("- ") or ":" not in content:
            continue
        key, _, value = content.partition(":")
        key = key.strip()
        if not key:
            continue
        value = _unquote(value)
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        if value == "":
            child: dict = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = value
    return root


@dataclass(frozen=True)
class BuildIdentity:
    marketing_version: str
    build_number: str
    source: str
    roles: dict

    def as_json(self) -> dict:
        return {
            "marketingVersion": self.marketing_version,
            "buildNumber": self.build_number,
            "source": self.source,
            "roles": self.roles,
        }


def _role_values_from_document(document: dict, source: str) -> BuildIdentity:
    settings = document.get("settings")
    base = settings.get("base") if isinstance(settings, dict) else None
    if not isinstance(base, dict):
        base = {}
    targets = document.get("targets")
    if not isinstance(targets, dict):
        raise IdentityError("project.yml has no targets mapping")

    roles: dict = {}
    for target, role in TARGET_ROLES.items():
        entry = targets.get(target)
        if not isinstance(entry, dict):
            raise IdentityError(f"project.yml has no target {target!r}")
        target_settings = entry.get("settings")
        target_base = target_settings.get("base") if isinstance(target_settings, dict) else None
        if not isinstance(target_base, dict):
            target_base = {}
        marketing = target_base.get("MARKETING_VERSION", base.get("MARKETING_VERSION"))
        build = target_base.get("CURRENT_PROJECT_VERSION", base.get("CURRENT_PROJECT_VERSION"))
        if not isinstance(marketing, str) or not isinstance(build, str):
            raise IdentityError(
                f"target {target!r} does not resolve MARKETING_VERSION and "
                "CURRENT_PROJECT_VERSION from project.yml"
            )
        roles[role] = {"marketingVersion": marketing, "buildNumber": build}

    values = {(item["marketingVersion"], item["buildNumber"]) for item in roles.values()}
    if len(values) != 1:
        raise IdentityError(
            "project.yml target versions disagree: "
            + json.dumps(roles, sort_keys=True)
        )
    marketing, build = next(iter(values))
    return BuildIdentity(marketing, build, source, roles)


def build_identity_from_project_text(text: str, source: str) -> BuildIdentity:
    return _role_values_from_document(parse_simple_mapping(text), source)


def load_project_identity(path: Path) -> BuildIdentity:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as error:
        raise IdentityError(f"cannot read project source {path}: {error}") from error
    return build_identity_from_project_text(text, str(path))


def resolve_ref(repo_root: Path, reference: str) -> str:
    if not reference or reference.startswith("-"):
        raise IdentityError("source ref is empty or starts with '-'")
    result = run([
        "git", "-C", str(repo_root), "rev-parse", "--verify", "--quiet",
        f"{reference}^{{commit}}",
    ])
    if result.returncode != 0:
        raise IdentityError(f"source ref does not resolve to a commit: {reference}")
    value = result.stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise IdentityError(f"source ref resolved to an unexpected commit id: {value!r}")
    return value


def git_show_text(repo_root: Path, reference: str, relative_path: str) -> str:
    result = run([
        "git", "-C", str(repo_root), "show", f"{reference}:{relative_path}",
    ])
    if result.returncode != 0:
        raise IdentityError(
            f"source ref {reference} does not contain {relative_path}"
        )
    return result.stdout


def load_identity_for_source(
    project_path: Path,
    repo_root: Path | None = None,
    source_ref: str | None = None,
) -> tuple[BuildIdentity, str | None]:
    project_path = Path(project_path).resolve()
    if not source_ref:
        return load_project_identity(project_path), None
    if repo_root is None:
        repo_root = project_path.parent.parent
    repo_root = Path(repo_root).resolve()
    try:
        relative = project_path.relative_to(repo_root).as_posix()
    except ValueError as error:
        raise IdentityError("project.yml is outside the repository root") from error
    commit = resolve_ref(repo_root, source_ref)
    identity = build_identity_from_project_text(
        git_show_text(repo_root, commit, relative),
        f"git:{commit}:{relative}",
    )
    return identity, commit


def source_prototype_diagnostics(
    project_path: Path,
    repo_root: Path | None = None,
    source_ref: str | None = None,
) -> bool:
    """Read ``BridgeBuild.prototypeDiagnostics`` from trusted project source.

    This deliberately does not infer content policy from the IPA under test.
    The caller may pin a committed ref; otherwise the current project worktree
    is used.
    """
    project_path = Path(project_path).resolve()
    relative_path = "Sources/BridgeCore/BridgeBuild.swift"
    if source_ref:
        if repo_root is None:
            repo_root = project_path.parent.parent
        repo_root = Path(repo_root).resolve()
        try:
            project_relative = project_path.relative_to(repo_root)
        except ValueError as error:
            raise IdentityError("project.yml is outside the repository root") from error
        commit = resolve_ref(repo_root, source_ref)
        source_path = (project_relative.parent / relative_path).as_posix()
        text = git_show_text(repo_root, commit, source_path)
    else:
        try:
            text = (project_path.parent / relative_path).read_text(encoding="utf-8")
        except OSError as error:
            raise IdentityError(
                f"cannot read trusted BridgeBuild source: {error}"
            ) from error
    match = BRIDGEBUILD_PROTOTYPE_RE.search(text)
    if match is None:
        raise IdentityError("BridgeBuild source does not declare prototypeDiagnostics")
    return match.group(1) == "true"


def derive_verification_mode(
    project_path: Path,
    repo_root: Path | None = None,
    source_ref: str | None = None,
) -> str:
    """Derive the private qualification mode from trusted project source."""
    if source_prototype_diagnostics(project_path, repo_root, source_ref):
        return QUALIFICATION
    return PRODUCT_QUALIFICATION


def validate_identity(identity: BuildIdentity, mode: str) -> BuildIdentity:
    if mode not in MODES:
        raise IdentityError(f"unknown mode {mode!r}")
    marketing = identity.marketing_version
    build = identity.build_number
    if not MARKETING_RE.fullmatch(marketing):
        raise IdentityError(f"invalid marketing version: {marketing!r}")
    if not BUILD_RE.fullmatch(build):
        raise IdentityError(f"build number must be numeric: {build!r}")
    if len({(item["marketingVersion"], item["buildNumber"])
            for item in identity.roles.values()}) != 1:
        raise IdentityError("identity roles disagree")
    if mode in PRODUCT_MODES:
        match = SEMVER_RE.fullmatch(marketing)
        if not match:
            raise IdentityError(
                f"{mode} marketing version must be x.y.z: {marketing!r}"
            )
        if int(match.group(1)) < RELEASE_MINIMUM_MAJOR:
            raise IdentityError(
                f"{mode} marketing version must be at least "
                f"{RELEASE_MINIMUM_MAJOR}.0.0: {marketing!r}"
            )
        if int(build) < RELEASE_MINIMUM_BUILD:
            raise IdentityError(
                f"{mode} build must be at least {RELEASE_MINIMUM_BUILD}: {build!r}"
            )
    return identity


def apply_identity_overrides(
    identity: BuildIdentity,
    marketing_version: str | None,
    build_number: str | None,
) -> BuildIdentity:
    if marketing_version is not None and marketing_version != identity.marketing_version:
        raise IdentityError(
            "caller-supplied marketing version does not match project source "
            f"({marketing_version!r} != {identity.marketing_version!r})"
        )
    if build_number is not None and build_number != identity.build_number:
        raise IdentityError(
            "caller-supplied build number does not match project source "
            f"({build_number!r} != {identity.build_number!r})"
        )
    return identity


def project_release_surface_findings(text: str) -> list[str]:
    """Return project-level prototype surface markers that block release."""
    findings: list[str] = []
    document = parse_simple_mapping(text)
    targets = document.get("targets")
    if not isinstance(targets, dict):
        return findings
    for target, entry in targets.items():
        if not isinstance(entry, dict):
            continue
        settings = entry.get("settings")
        base = settings.get("base") if isinstance(settings, dict) else None
        if not isinstance(base, dict):
            continue
        conditions = base.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS")
        if isinstance(conditions, str) and "BRIDGE_PROTOTYPE_DIAGNOSTICS" in conditions:
            findings.append(f"{target}.SWIFT_ACTIVE_COMPILATION_CONDITIONS")
    return findings


def check_source_project(
    project_path: Path,
    identity: BuildIdentity,
    mode: str,
) -> list[dict]:
    checks: list[dict] = []
    project_path = Path(project_path).resolve()
    source_root = project_path.parent

    def add(name: str, ok: bool, detail: str) -> None:
        checks.append({"name": name, "ok": bool(ok), "detail": detail})

    try:
        project_identity = load_project_identity(project_path)
        add(
            "source-project-identity-matches",
            project_identity.marketing_version == identity.marketing_version
            and project_identity.build_number == identity.build_number,
            json.dumps(project_identity.as_json(), sort_keys=True),
        )
    except IdentityError as error:
        add("source-project-identity-matches", False, str(error))

    bridge_build = source_root / "Sources" / "BridgeCore" / "BridgeBuild.swift"
    try:
        source = bridge_build.read_text(encoding="utf-8")
    except OSError as error:
        add("bridgebuild-source-present", False, str(error))
        return checks

    add("bridgebuild-source-present", True, str(bridge_build))
    marketing = BRIDGEBUILD_VERSION_RE.search(source)
    build = BRIDGEBUILD_NUMBER_RE.search(source)
    prototype = BRIDGEBUILD_PROTOTYPE_RE.search(source)
    add(
        "bridgebuild-marketing-version",
        marketing is not None and marketing.group(1) == identity.marketing_version,
        marketing.group(1) if marketing else "<missing>",
    )
    add(
        "bridgebuild-build-number",
        build is not None and build.group(1) == identity.build_number,
        build.group(1) if build else "<missing>",
    )
    expected_prototype = mode == QUALIFICATION
    add(
        "bridgebuild-prototype-diagnostics",
        prototype is not None and (prototype.group(1) == "true") == expected_prototype,
        prototype.group(1) if prototype else "<missing>",
    )

    if mode in PRODUCT_MODES:
        try:
            findings = project_release_surface_findings(project_path.read_text(encoding="utf-8"))
        except OSError as error:
            findings = [str(error)]
        add("release-project-no-prototype-compilation", not findings, json.dumps(findings))
    return checks


def validate_lock(project_root: Path) -> list[dict]:
    """Read-only validation of Vendor/idevice.lock.json and fetch pins."""
    checks: list[dict] = []
    project_root = Path(project_root).resolve()
    lock_path = project_root / "Vendor" / "idevice.lock.json"
    fetch_path = project_root / "scripts" / "fetch_idevice.sh"
    try:
        raw = lock_path.read_bytes()
        lock = json.loads(raw.decode("utf-8"))
    except (OSError, ValueError) as error:
        return [{"name": "idevice-lock", "ok": False, "detail": str(error)}]

    def add(name: str, ok: bool, detail: str) -> None:
        checks.append({"name": name, "ok": bool(ok), "detail": detail})

    add("idevice-lock", True, hashlib.sha256(raw).hexdigest())
    add("idevice-lock-component", lock.get("component") == "idevice", str(lock.get("component")))
    commit = lock.get("commit")
    asset = lock.get("assetSHA256")
    add("idevice-lock-commit", isinstance(commit, str) and bool(re.fullmatch(r"[0-9a-f]{40}", commit)), str(commit))
    add("idevice-lock-asset", isinstance(asset, str) and bool(re.fullmatch(r"[0-9a-f]{64}", asset)), str(asset))
    add("idevice-lock-release", isinstance(lock.get("release"), str) and bool(lock.get("release")), str(lock.get("release")))
    add("idevice-lock-not-local", "/Users/" not in json.dumps(lock) and "/Volumes/" not in json.dumps(lock), "private paths absent")

    try:
        fetch = fetch_path.read_text(encoding="utf-8")
    except OSError as error:
        add("idevice-fetch-pins", False, str(error))
        return checks
    version = FETCH_VERSION_RE.search(fetch)
    asset_sha = FETCH_ASSET_RE.search(fetch)
    add(
        "idevice-fetch-version-matches-lock",
        version is not None and version.group(1) == lock.get("release"),
        version.group(1) if version else "<missing>",
    )
    add(
        "idevice-fetch-asset-matches-lock",
        asset_sha is not None and asset_sha.group(1) == asset,
        asset_sha.group(1) if asset_sha else "<missing>",
    )
    return checks


@dataclass(frozen=True)
class MachOInfo:
    magic: str
    cpu: str
    filetype: str
    platform: int | None
    minos: str | None
    sdk: str | None


def _version_tuple(value: str | None) -> tuple[int, ...]:
    if not value:
        return ()
    parts = []
    for item in value.split("."):
        digits = re.match(r"^[0-9]+", item)
        if not digits:
            break
        parts.append(int(digits.group(0)))
    return tuple(parts)


class SystemMachOProbe:
    """Thin, read-only wrapper around the installed Apple developer tools."""

    def file_description(self, binary: Path) -> str:
        result = run(["/usr/bin/file", str(binary)])
        return result.stdout.strip() if result.returncode == 0 else ""

    def linked_libraries(self, binary: Path) -> list[str]:
        result = run(["/usr/bin/otool", "-L", str(binary)])
        if result.returncode != 0:
            return []
        libraries = []
        for line in result.stdout.splitlines()[1:]:
            stripped = line.strip()
            if stripped:
                libraries.append(stripped.split(" (compatibility")[0])
        return libraries

    def rpaths(self, binary: Path) -> list[str]:
        result = run(["/usr/bin/otool", "-l", str(binary)])
        if result.returncode != 0:
            return []
        values = []
        lines = result.stdout.splitlines()
        for index, line in enumerate(lines):
            if line.strip() == "cmd LC_RPATH" and index + 2 < len(lines):
                path_line = lines[index + 2].strip()
                if path_line.startswith("path "):
                    values.append(path_line[len("path "):].split(" (offset")[0])
        return values

    def undefined_symbols(self, binary: Path) -> list[str]:
        result = run(["/usr/bin/nm", "-u", str(binary)])
        if result.returncode != 0:
            return []
        return [line.strip() for line in result.stdout.splitlines() if line.strip()]

    def global_symbols(self, binary: Path) -> list[str]:
        result = run(["/usr/bin/nm", "-g", str(binary)])
        if result.returncode != 0:
            return []
        return [line.strip() for line in result.stdout.splitlines() if line.strip()]

    def installed_name(self, binary: Path) -> str:
        result = run(["/usr/bin/otool", "-D", str(binary)])
        if result.returncode != 0:
            return ""
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        return lines[1] if len(lines) > 1 else ""

    def macho(self, binary: Path) -> MachOInfo:
        header = run(["/usr/bin/otool", "-hv", str(binary)])
        magic = cpu = filetype = ""
        if header.returncode == 0:
            for line in header.stdout.splitlines():
                parts = line.split()
                if len(parts) >= 6 and parts[0].startswith("MH_"):
                    magic, cpu, filetype = parts[0], parts[1], parts[4]
                    break
        platform: int | None = None
        minos: str | None = None
        sdk: str | None = None
        loads = run(["/usr/bin/otool", "-l", str(binary)])
        if loads.returncode == 0:
            lines = loads.stdout.splitlines()
            for index, line in enumerate(lines):
                stripped = line.strip()
                if stripped == "cmd LC_BUILD_VERSION":
                    window = lines[index + 1:index + 6]
                    for entry in window:
                        entry = entry.strip()
                        if entry.startswith("platform "):
                            try:
                                platform = int(entry.split()[1])
                            except (IndexError, ValueError):
                                platform = None
                        elif entry.startswith("minos "):
                            minos = entry.split()[1]
                        elif entry.startswith("sdk "):
                            sdk = entry.split()[1]
                elif stripped == "cmd LC_VERSION_MIN_IPHONEOS":
                    platform = IOS_MACHO_PLATFORM
                    window = lines[index + 1:index + 5]
                    for entry in window:
                        entry = entry.strip()
                        if entry.startswith("version "):
                            minos = entry.split()[1]
                        elif entry.startswith("sdk "):
                            sdk = entry.split()[1]
        return MachOInfo(magic, cpu, filetype, platform, minos, sdk)

    def uuids(self, binary: Path) -> dict[str, str]:
        result = run(["/usr/bin/dwarfdump", "--uuid", str(binary)])
        if result.returncode != 0:
            return {}
        values: dict[str, str] = {}
        for line in result.stdout.splitlines():
            match = re.match(r"\s*UUID:\s*([0-9A-Fa-f-]+)\s+\(([^)]+)\)", line)
            if match:
                values[match.group(2).strip()] = match.group(1).upper()
        return values

    def strings(self, binary: Path) -> list[str]:
        result = run(["/usr/bin/strings", "-a", str(binary)])
        if result.returncode != 0:
            return []
        return result.stdout.splitlines()


def check(name: str, ok: bool, detail: str) -> dict:
    return {"name": name, "ok": bool(ok), "detail": detail}


def _uuid_value(probe, binary: Path, role: str, checks: list[dict]) -> str | None:
    try:
        values = probe.uuids(binary)
    except Exception as error:  # noqa: BLE001 - report tool failure as a check
        checks.append(check(f"{role}-uuid", False, f"uuid inspection failed: {error}"))
        return None
    valid = {
        arch: value for arch, value in values.items()
        if UUID_RE.fullmatch(value)
    }
    ok = len(valid) == 1 and "arm64" in valid
    checks.append(check(f"{role}-uuid", ok, json.dumps(values, sort_keys=True)))
    return valid.get("arm64")


def _macho_checks(probe, binary: Path, role: str, checks: list[dict]) -> None:
    try:
        info = probe.macho(binary)
    except Exception as error:  # noqa: BLE001
        checks.append(check(f"{role}-macho-platform", False, f"macho inspection failed: {error}"))
        return
    checks.append(check(
        f"{role}-macho-platform",
        info.platform == IOS_MACHO_PLATFORM,
        f"platform={info.platform} minos={info.minos} sdk={info.sdk}",
    ))
    checks.append(check(
        f"{role}-macho-arm64",
        info.magic == "MH_MAGIC_64" and info.cpu.upper() == "ARM64",
        f"magic={info.magic} cpu={info.cpu}",
    ))
    checks.append(check(
        f"{role}-macho-filetype",
        info.filetype == EXPECTED_FILE_TYPES[role],
        f"filetype={info.filetype} expected={EXPECTED_FILE_TYPES[role]}",
    ))
    checks.append(check(
        f"{role}-minos-minimum",
        _version_tuple(info.minos) >= MINIMUM_IOS_VERSION,
        f"minos={info.minos}",
    ))


def _framework_entries(directory: Path) -> list[str]:
    if not directory.is_dir():
        return []
    return sorted(
        path.name for path in directory.iterdir()
        if path.name.endswith((".framework", ".xcframework"))
    )


def _dylib_entries(directory: Path) -> list[str]:
    if not directory.is_dir():
        return []
    values = []
    for path in directory.rglob("*"):
        if path.is_file() and path.suffix in {".dylib", ".so"}:
            values.append(str(path.relative_to(directory)))
    return sorted(values)


def _load_is_allowed(role: str, load: str) -> bool:
    if load.startswith("/System/Library/") or load.startswith("/usr/lib/"):
        return True
    if load == "@rpath/BridgeCore.framework/BridgeCore":
        return role in {"host", "appex", "test"}
    if role == "test" and load in {
        "@rpath/XCTest.framework/XCTest",
        "@rpath/XCUIAutomation.framework/XCUIAutomation",
        "@rpath/libXCTestSwiftSupport.dylib",
    }:
        return True
    return False


def _signed_or_profile_entries(root: Path) -> tuple[list[str], list[str]]:
    signatures = [str(path.relative_to(root)) for path in root.rglob("_CodeSignature")]
    profiles = [
        str(path.relative_to(root)) for path in root.rglob("*")
        if path.is_file() and path.name in PROFILE_NAMES
    ]
    return signatures, profiles


def _credential_files(root: Path) -> list[str]:
    return sorted(
        str(path.relative_to(root)) for path in root.rglob("*")
        if path.is_file() and path.suffix.lower() in SIGNING_FILE_SUFFIXES
    )


def _escaping_symlinks(root: Path) -> list[str]:
    root = root.resolve()
    values = []
    for path in root.rglob("*"):
        if not path.is_symlink():
            continue
        try:
            resolved = path.resolve()
            resolved.relative_to(root)
        except (OSError, ValueError):
            values.append(str(path.relative_to(root)))
    return sorted(values)


def _embedded_checks(app: Path, appex: Path, test_bundle: Path, checks: list[dict]) -> None:
    host_frameworks = _framework_entries(app / "Frameworks")
    checks.append(check(
        "host-embedded-frameworks-exact",
        host_frameworks == ["BridgeCore.framework"],
        json.dumps(host_frameworks),
    ))
    appex_frameworks = _framework_entries(appex / "Frameworks")
    checks.append(check(
        "appex-embedded-frameworks-exact",
        appex_frameworks == ["BridgeCore.framework"],
        json.dumps(appex_frameworks),
    ))
    test_frameworks = _framework_entries(test_bundle / "Frameworks")
    checks.append(check("test-no-embedded-frameworks", not test_frameworks, json.dumps(test_frameworks)))

    host_dylibs = _dylib_entries(app / "Frameworks")
    appex_dylibs = _dylib_entries(appex / "Frameworks")
    test_dylibs = _dylib_entries(test_bundle / "Frameworks")
    checks.append(check("host-no-embedded-dylibs", not host_dylibs, json.dumps(host_dylibs)))
    checks.append(check("appex-no-embedded-dylibs", not appex_dylibs, json.dumps(appex_dylibs)))
    checks.append(check("test-no-embedded-dylibs", not test_dylibs, json.dumps(test_dylibs)))

    xcframeworks = [
        str(path.relative_to(app)) for path in app.rglob("*.xcframework")
    ]
    checks.append(check("no-embedded-xcframework", not xcframeworks, json.dumps(xcframeworks)))


def _notice_checks(app: Path, source_root: Path, checks: list[dict]) -> None:
    source_notices = source_root / "ThirdParty"
    for relative in ("iCTRL/LICENSE", "iCTRL/NOTICE.md", "idevice/LICENSE"):
        bundled = app / "ThirdParty" / relative
        canonical = source_notices / relative
        matches = (
            bundled.is_file() and canonical.is_file()
            and bool(canonical.read_bytes())
            and hashlib.sha256(bundled.read_bytes()).digest()
            == hashlib.sha256(canonical.read_bytes()).digest()
        )
        checks.append(check(
            "bundled-notice-" + relative.replace("/", "-"),
            matches,
            relative,
        ))


def check_app(
    app: Path,
    require_unsigned: bool = True,
    *,
    mode: str = QUALIFICATION,
    identity: BuildIdentity | None = None,
    bundle_ids: dict[str, str] | None = None,
    probe=None,
    source_root: Path | None = None,
    project_yml: Path | None = None,
) -> dict:
    app = Path(app)
    checks: list[dict] = []
    probe = probe or SystemMachOProbe()
    bundle_ids = bundle_ids or canonical_bundle_ids()
    if set(bundle_ids) != {"host", "tunnel", "core", "test"}:
        raise IdentityError("bundle_ids must contain host, tunnel, core and test")
    if mode == RELEASE and bundle_ids != canonical_bundle_ids():
        raise IdentityError("public release verification requires canonical bundle IDs")
    if source_root is None:
        source_root = Path(__file__).resolve().parent.parent
    source_root = Path(source_root)
    if project_yml is None:
        project_yml = source_root / "project.yml"
    if identity is None:
        identity = load_project_identity(project_yml)
    identity = validate_identity(identity, mode)

    def add(name: str, ok: bool, detail: str) -> None:
        checks.append(check(name, ok, detail))

    add("app-directory", app.is_dir(), str(app))
    if not app.is_dir():
        failures = [item["name"] for item in checks if not item["ok"]]
        return {
            "app": str(app), "mode": mode, "identity": identity.as_json(),
            "bundleIds": bundle_ids,
            "checks": checks, "failures": failures, "ok": False,
        }

    host_plist = app / "Info.plist"
    host_binary = app / HOST_EXECUTABLE
    add("host-info-plist", host_plist.is_file(), str(host_plist))
    add("host-executable", host_binary.is_file(), str(host_binary))
    add(
        "host-bundle-id",
        plist_raw(host_plist, "CFBundleIdentifier") == bundle_ids["host"],
        str(plist_raw(host_plist, "CFBundleIdentifier")),
    )
    add(
        "host-version",
        plist_raw(host_plist, "CFBundleShortVersionString") == identity.marketing_version,
        str(plist_raw(host_plist, "CFBundleShortVersionString")),
    )
    add(
        "host-build",
        plist_raw(host_plist, "CFBundleVersion") == identity.build_number,
        str(plist_raw(host_plist, "CFBundleVersion")),
    )
    background_raw = plist_json(host_plist, "UIBackgroundModes")
    background_type_ok = background_raw is None or isinstance(background_raw, list)
    background_modes = background_raw if isinstance(background_raw, list) else []
    if mode == QUALIFICATION:
        # Retained legacy prototype assertion for the immutable Build 13
        # artifact.  "continuous" is not a documented iOS background mode.
        add("host-background-continuous", "continuous" in background_modes, str(background_raw))
    else:
        unsupported = [
            value for value in background_modes
            if not isinstance(value, str)
            or value not in DOCUMENTED_IOS_BACKGROUND_MODES
        ]
        add(
            "product-background-modes-type",
            background_type_ok,
            str(background_raw),
        )
        add(
            "product-background-modes-documented",
            background_type_ok and not unsupported,
            json.dumps({"declared": background_modes, "unsupported": unsupported}),
        )
        add(
            "product-background-continuous-absent",
            "continuous" not in background_modes,
            str(background_raw),
        )
    add(
        "host-scene-manifest",
        isinstance(plist_json(host_plist, "UIApplicationSceneManifest"), dict),
        str(plist_json(host_plist, "UIApplicationSceneManifest")),
    )
    local_network = (plist_raw(host_plist, "NSLocalNetworkUsageDescription") or "").strip()
    add("host-local-network-description", local_network != "", local_network)

    if mode == QUALIFICATION:
        add(
            "host-prototype-channels",
            plist_raw(host_plist, "FloePrototypeChannels") in {"true", "YES", "1"},
            str(plist_raw(host_plist, "FloePrototypeChannels")),
        )
        add(
            "host-prototype-diagnostics",
            plist_raw(host_plist, "FloePrototypeDiagnostics") in {"true", "YES", "1"},
            str(plist_raw(host_plist, "FloePrototypeDiagnostics")),
        )
    else:
        truthy_prototype = {}
        for key, value in plist_all(host_plist).items():
            if isinstance(key, str) and key.startswith("FloePrototype") and _value_is_truthy(value):
                truthy_prototype[key] = value
        add("release-no-prototype-flags", not truthy_prototype, json.dumps(truthy_prototype))
        add(
            "release-no-prototype-local-network-copy",
            "prototype" not in local_network.lower(),
            local_network,
        )

    add("host-arch-arm64", "arm64" in probe.file_description(host_binary)
        and "Mach-O 64-bit" in probe.file_description(host_binary),
        probe.file_description(host_binary))
    _macho_checks(probe, host_binary, "host", checks)
    host_uuid = _uuid_value(probe, host_binary, "host", checks)

    host_loads = probe.linked_libraries(host_binary) if host_binary.is_file() else []
    host_forbidden = [item for item in host_loads if any(token in item for token in FORBIDDEN_HOST_LOADS)]
    add("host-no-xctest-load", not host_forbidden, json.dumps(host_forbidden))
    host_undefined = probe.undefined_symbols(host_binary) if host_binary.is_file() else []
    add(
        "host-no-xctest-symbol",
        not [item for item in host_undefined if "XCTestMain" in item],
        json.dumps([item for item in host_undefined if "XCTestMain" in item]),
    )
    host_rpaths = probe.rpaths(host_binary) if host_binary.is_file() else []
    missing_host_rpaths = [item for item in REQUIRED_HOST_RPATHS if item not in host_rpaths]
    add("host-ddi-rpaths", not missing_host_rpaths, json.dumps(missing_host_rpaths))
    add("host-core-rpath", "@executable_path/Frameworks" in host_rpaths, json.dumps(host_rpaths))
    add(
        "host-links-core",
        any("BridgeCore.framework/BridgeCore" in item for item in host_loads),
        json.dumps(host_loads),
    )
    host_symbols = probe.global_symbols(host_binary) if host_binary.is_file() else []
    add(
        "host-idevice-symbols",
        any("tunnel_create_rppairing" in item for item in host_symbols),
        json.dumps([item for item in host_symbols if "tunnel_create" in item or "cryptexd_install" in item][:8]),
    )
    bad_host_loads = [item for item in host_loads if not _load_is_allowed("host", item)]
    add("host-load-allowlist", not bad_host_loads, json.dumps(bad_host_loads))

    appex = app / "PlugIns" / APPEX_NAME
    appex_binary = appex / APPEX_EXECUTABLE
    appex_plist = appex / "Info.plist"
    add("appex-present", appex.is_dir(), str(appex))
    add("appex-executable", appex_binary.is_file(), str(appex_binary))
    add(
        "appex-bundle-id",
        plist_raw(appex_plist, "CFBundleIdentifier") == bundle_ids["tunnel"],
        str(plist_raw(appex_plist, "CFBundleIdentifier")),
    )
    add(
        "appex-version",
        plist_raw(appex_plist, "CFBundleShortVersionString") == identity.marketing_version,
        str(plist_raw(appex_plist, "CFBundleShortVersionString")),
    )
    add(
        "appex-build",
        plist_raw(appex_plist, "CFBundleVersion") == identity.build_number,
        str(plist_raw(appex_plist, "CFBundleVersion")),
    )
    add(
        "appex-package-type",
        plist_raw(appex_plist, "CFBundlePackageType") in {"XPC!", "XPC"},
        str(plist_raw(appex_plist, "CFBundlePackageType")),
    )
    extension = plist_json(appex_plist, "NSExtension") or {}
    add(
        "appex-packet-tunnel-point",
        extension.get("NSExtensionPointIdentifier") == "com.apple.networkextension.packet-tunnel",
        str(extension.get("NSExtensionPointIdentifier")),
    )
    principal = extension.get("NSExtensionPrincipalClass", "")
    add(
        "appex-principal-class",
        isinstance(principal, str) and principal.endswith(".PacketTunnelProvider"),
        str(principal),
    )
    appex_uuid = None
    if appex_binary.is_file():
        appex_loads = probe.linked_libraries(appex_binary)
        add("appex-arch-arm64", "arm64" in probe.file_description(appex_binary)
            and "Mach-O 64-bit" in probe.file_description(appex_binary),
            probe.file_description(appex_binary))
        _macho_checks(probe, appex_binary, "appex", checks)
        appex_uuid = _uuid_value(probe, appex_binary, "appex", checks)
        add(
            "appex-no-xctest",
            not [item for item in appex_loads if "XCTest" in item],
            json.dumps(appex_loads),
        )
        add(
            "appex-links-core",
            any("BridgeCore.framework/BridgeCore" in item for item in appex_loads),
            json.dumps(appex_loads),
        )
        appex_rpaths = probe.rpaths(appex_binary)
        add(
            "appex-core-rpath",
            "@executable_path/Frameworks" in appex_rpaths,
            json.dumps(appex_rpaths),
        )
        bad_appex_loads = [item for item in appex_loads if not _load_is_allowed("appex", item)]
        add("appex-load-allowlist", not bad_appex_loads, json.dumps(bad_appex_loads))
    appex_core = appex / "Frameworks" / "BridgeCore.framework" / CORE_EXECUTABLE
    add("appex-embeds-core", appex_core.is_file(), str(appex_core))
    host_core = app / "Frameworks" / "BridgeCore.framework" / CORE_EXECUTABLE
    core_uuid = None
    appex_core_uuid = None
    if appex_core.is_file() and host_core.is_file() and require_unsigned:
        add(
            "appex-core-bytes-match-host",
            appex_core.read_bytes() == host_core.read_bytes(),
            "appex and host BridgeCore binaries differ",
        )

    test_bundle = app / "PlugIns" / TEST_NAME
    test_binary = test_bundle / TEST_EXECUTABLE
    test_plist = test_bundle / "Info.plist"
    add("test-bundle-present", test_bundle.is_dir(), str(test_bundle))
    add("test-executable", test_binary.is_file(), str(test_binary))
    add(
        "test-bundle-id-aligns-host",
        plist_raw(test_plist, "CFBundleIdentifier") == bundle_ids["test"],
        str(plist_raw(test_plist, "CFBundleIdentifier")),
    )
    add(
        "test-contains-ui-tests",
        plist_raw(test_plist, "XCTContainsUITests") in {"true", "YES", "1"},
        str(plist_raw(test_plist, "XCTContainsUITests")),
    )
    add(
        "test-version",
        plist_raw(test_plist, "CFBundleShortVersionString") == identity.marketing_version,
        str(plist_raw(test_plist, "CFBundleShortVersionString")),
    )
    add(
        "test-build",
        plist_raw(test_plist, "CFBundleVersion") == identity.build_number,
        str(plist_raw(test_plist, "CFBundleVersion")),
    )
    test_uuid = None
    if test_binary.is_file():
        test_loads = probe.linked_libraries(test_binary)
        missing_loads = [item for item in REQUIRED_TEST_LOADS if not any(item in load for load in test_loads)]
        add("test-links-required", not missing_loads, json.dumps(missing_loads))
        test_rpaths = probe.rpaths(test_binary)
        add(
            "test-core-rpath",
            "@loader_path/../../Frameworks" in test_rpaths,
            json.dumps(test_rpaths),
        )
        add("test-arch-arm64", "arm64" in probe.file_description(test_binary)
            and "Mach-O 64-bit" in probe.file_description(test_binary),
            probe.file_description(test_binary))
        _macho_checks(probe, test_binary, "test", checks)
        test_uuid = _uuid_value(probe, test_binary, "test", checks)
        bad_test_loads = [item for item in test_loads if not _load_is_allowed("test", item)]
        add("test-load-allowlist", not bad_test_loads, json.dumps(bad_test_loads))

    add("host-embeds-core", host_core.is_file(), str(host_core))
    if host_core.is_file():
        add(
            "host-core-install-name",
            probe.installed_name(host_core) == "@rpath/BridgeCore.framework/BridgeCore",
            probe.installed_name(host_core),
        )
        add("host-core-arch-arm64", "arm64" in probe.file_description(host_core)
            and "Mach-O 64-bit" in probe.file_description(host_core),
            probe.file_description(host_core))
        _macho_checks(probe, host_core, "core", checks)
        core_uuid = _uuid_value(probe, host_core, "core", checks)
        core_plist = app / "Frameworks" / "BridgeCore.framework" / "Info.plist"
        add(
            "host-core-bundle-id",
            plist_raw(core_plist, "CFBundleIdentifier") == bundle_ids["core"],
            str(plist_raw(core_plist, "CFBundleIdentifier")),
        )
        add(
            "host-core-version",
            plist_raw(core_plist, "CFBundleShortVersionString") == identity.marketing_version,
            str(plist_raw(core_plist, "CFBundleShortVersionString")),
        )
        add(
            "host-core-build",
            plist_raw(core_plist, "CFBundleVersion") == identity.build_number,
            str(plist_raw(core_plist, "CFBundleVersion")),
        )
    appex_core_plist = appex / "Frameworks" / "BridgeCore.framework" / "Info.plist"
    add("appex-core-info-plist", appex_core_plist.is_file(), str(appex_core_plist))
    add(
        "appex-core-bundle-id",
        plist_raw(appex_core_plist, "CFBundleIdentifier") == bundle_ids["core"],
        str(plist_raw(appex_core_plist, "CFBundleIdentifier")),
    )
    add(
        "appex-core-version",
        plist_raw(appex_core_plist, "CFBundleShortVersionString") == identity.marketing_version,
        str(plist_raw(appex_core_plist, "CFBundleShortVersionString")),
    )
    add(
        "appex-core-build",
        plist_raw(appex_core_plist, "CFBundleVersion") == identity.build_number,
        str(plist_raw(appex_core_plist, "CFBundleVersion")),
    )
    if appex_core.is_file() and not require_unsigned:
        _macho_checks(probe, appex_core, "appex-core", checks)
        appex_core_uuid = _uuid_value(probe, appex_core, "appex-core", checks)
        add(
            "appex-core-uuid-match-host",
            appex_core_uuid is not None and core_uuid is not None and appex_core_uuid == core_uuid,
            f"appex={appex_core_uuid} host={core_uuid}",
        )

    role_uuids = [value for value in (host_uuid, appex_uuid, test_uuid) if value]
    add(
        "role-uuids-distinct",
        len(role_uuids) == len(set(role_uuids)) and len(role_uuids) == 3,
        json.dumps({"host": host_uuid, "appex": appex_uuid, "test": test_uuid}),
    )
    if core_uuid and host_uuid:
        add("host-core-uuid-distinct-from-host", core_uuid != host_uuid, core_uuid)

    nested_apps = [str(path.relative_to(app)) for path in app.rglob("*.app") if path != app]
    add("no-nested-app", not nested_apps, json.dumps(nested_apps))
    appexes = [str(path.relative_to(app)) for path in app.rglob("*.appex")]
    add("exactly-one-appex", appexes == [f"PlugIns/{APPEX_NAME}"], json.dumps(appexes))
    xctests = [str(path.relative_to(app)) for path in app.rglob("*.xctest")]
    add("exactly-one-xctest", xctests == [f"PlugIns/{TEST_NAME}"], json.dumps(xctests))

    forbidden = []
    for path in app.rglob("*"):
        if path.name in FORBIDDEN_ARTIFACT_NAMES or path.name.endswith(FORBIDDEN_SUFFIXES):
            forbidden.append(str(path.relative_to(app)))
    add("no-bundled-ddi-or-test-frameworks", not forbidden, json.dumps(forbidden[:20]))

    _embedded_checks(app, appex, test_bundle, checks)
    escaping = _escaping_symlinks(app)
    add("no-escaping-symlinks", not escaping, json.dumps(escaping[:20]))
    signatures, profiles = _signed_or_profile_entries(app)
    add(
        "unsigned-no-code-signature",
        (not signatures) if require_unsigned else True,
        json.dumps(signatures),
    )
    add(
        "unsigned-no-profile",
        (not profiles) if require_unsigned else True,
        json.dumps(profiles),
    )
    credentials = _credential_files(app)
    add("no-signing-credential-files", not credentials, json.dumps(credentials[:20]))

    if mode in PRODUCT_MODES:
        markers = []
        for role, binary in (("host", host_binary), ("appex", appex_binary)):
            if not binary.is_file():
                continue
            strings = probe.strings(binary)
            for marker in RELEASE_LEGACY_MARKERS:
                if any(marker in value for value in strings):
                    markers.append(f"{role}:{marker}")
        add("release-no-legacy-surface-markers", not markers, json.dumps(sorted(set(markers))))

    checks.extend(check_source_project(project_yml, identity, mode))
    _notice_checks(app, source_root, checks)

    failures = [item["name"] for item in checks if not item["ok"]]
    return {
        "app": str(app),
        "mode": mode,
        "contentPolicy": "legacy-prototype" if mode == QUALIFICATION else "product",
        "identity": identity.as_json(),
        "bundleIds": bundle_ids,
        "metadataMode": "source-unsigned" if require_unsigned else (
            "canonical" if bundle_ids == canonical_bundle_ids() else "resigned-explicit-ids"
        ),
        "checks": checks,
        "failures": failures,
        "ok": not failures,
        "hostLoads": host_loads,
        "hostRpaths": host_rpaths,
        "testLoads": probe.linked_libraries(test_binary) if test_binary.is_file() else [],
        "testRpaths": probe.rpaths(test_binary) if test_binary.is_file() else [],
        "uuids": {
            "host": host_uuid,
            "appex": appex_uuid,
            "test": test_uuid,
            "core": core_uuid,
        },
        "embedded": {
            "hostFrameworks": _framework_entries(app / "Frameworks"),
            "appexFrameworks": _framework_entries(appex / "Frameworks"),
        },
        "signing": {
            "signatures": signatures,
            "profiles": profiles,
            "credentialFiles": credentials,
        },
    }


def check_ipa(
    ipa: Path,
    require_unsigned: bool = True,
    *,
    mode: str = QUALIFICATION,
    identity: BuildIdentity | None = None,
    bundle_ids: dict[str, str] | None = None,
    probe=None,
    source_root: Path | None = None,
    project_yml: Path | None = None,
) -> dict:
    ipa = Path(ipa)
    checks: list[dict] = []
    if not ipa.is_file():
        return {
            "ipa": str(ipa), "checks": [check("ipa-exists", False, str(ipa))],
            "failures": ["ipa-exists"], "ok": False,
        }
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
    top_apps = sorted({
        name.split("/")[1] for name in names
        if name.startswith("Payload/") and len(name.split("/")) > 2
        and name.split("/")[1].endswith(".app")
    })
    checks.append(check("ipa-single-app", top_apps == [HOST_APP_NAME], json.dumps(top_apps)))
    checks.append(check("ipa-payload-prefix", all(name.startswith("Payload/") for name in names),
                        "all entries under Payload/"))
    checks.append(check("ipa-no-macosx", not any(name.startswith("__MACOSX") for name in names),
                        "no __MACOSX"))

    profile_entries = [
        name for name in names
        if name.endswith(PROFILE_NAMES[0]) or name.endswith(PROFILE_NAMES[1])
    ]
    signature_entries = [name for name in names if "_CodeSignature/" in name]
    credential_entries = [
        name for name in names
        if Path(name).suffix.lower() in SIGNING_FILE_SUFFIXES
    ]
    checks.append(check(
        "ipa-no-signature-dir",
        (not signature_entries) if require_unsigned else True,
        json.dumps(signature_entries[:10]),
    ))
    checks.append(check(
        "ipa-no-embedded-profile",
        (not profile_entries) if require_unsigned else True,
        json.dumps(profile_entries[:10]),
    ))
    checks.append(check("ipa-no-signing-credential-files", not credential_entries,
                        json.dumps(credential_entries[:10])))

    with tempfile.TemporaryDirectory(prefix="floe-bridge-verify-") as temporary:
        with zipfile.ZipFile(ipa) as archive:
            archive.extractall(temporary)
        app = Path(temporary) / "Payload" / HOST_APP_NAME
        app_result = check_app(
            app,
            require_unsigned=require_unsigned,
            mode=mode,
            identity=identity,
            bundle_ids=bundle_ids,
            probe=probe,
            source_root=source_root,
            project_yml=project_yml,
        )
    checks.extend(app_result["checks"])
    failures = [item["name"] for item in checks if not item["ok"]]
    return {
        "ipa": str(ipa),
        "mode": mode,
        "contentPolicy": app_result.get("contentPolicy"),
        "identity": app_result.get("identity"),
        "bundleIds": app_result.get("bundleIds"),
        "metadataMode": app_result.get("metadataMode"),
        "checks": checks,
        "failures": failures,
        "ok": not failures,
        "appResult": app_result,
    }


DSYM_ROLE_SUFFIXES = (
    ("BridgeHost.app.dSYM", "host"),
    ("BridgeTunnel.appex.dSYM", "appex"),
    ("BridgeCore.framework.dSYM", "core"),
    ("BridgeTests.xctest.dSYM", "test"),
)
DSYM_REQUIRED_ROLES = {"host", "appex", "core", "test"}


def _dsym_role(path: Path) -> str | None:
    for suffix, role in DSYM_ROLE_SUFFIXES:
        if path.name == suffix:
            return role
    return None


def check_dsyms(
    app_result: dict,
    dsym_paths: list[Path],
    mode: str = QUALIFICATION,
    probe=None,
) -> dict:
    probe = probe or SystemMachOProbe()
    checks: list[dict] = []
    seen: dict[str, str] = {}
    for value in dsym_paths:
        path = Path(value)
        role = _dsym_role(path)
        checks.append(check(
            f"dsym-{role or path.name}-recognized",
            role is not None,
            str(path),
        ))
        if role is None or not path.is_dir():
            continue
        if role in seen:
            checks.append(check(f"dsym-{role}-unique", False, json.dumps(seen[role])))
            continue
        values = probe.uuids(path)
        valid = {arch: uuid for arch, uuid in values.items() if UUID_RE.fullmatch(uuid)}
        expected = (app_result.get("uuids") or {}).get(role)
        matches = len(valid) == 1 and "arm64" in valid and expected is not None and valid["arm64"] == expected
        checks.append(check(
            f"dsym-{role}-uuid-matches-binary",
            matches,
            json.dumps({"dsym": values, "binary": expected}),
        ))
        if matches:
            seen[role] = valid["arm64"]
    if mode == RELEASE:
        missing = sorted(DSYM_REQUIRED_ROLES - set(seen))
        checks.append(check("dsym-complete-set", not missing, json.dumps(missing)))
    failures = [item["name"] for item in checks if not item["ok"]]
    return {"checks": checks, "failures": failures, "ok": not failures, "uuids": seen}


def check_project(
    project_yml: Path,
    repo_root: Path,
    mode: str,
    source_ref: str | None,
    expected_version: str | None,
    expected_build: str | None,
) -> dict:
    identity, commit = load_identity_for_source(project_yml, repo_root, source_ref)
    identity = apply_identity_overrides(identity, expected_version, expected_build)
    identity = validate_identity(identity, mode)
    checks = [
        check("project-identity", True, json.dumps(identity.as_json(), sort_keys=True)),
        check("source-ref", commit is not None or mode == QUALIFICATION,
              commit or "<not supplied>"),
    ]
    checks.extend(validate_lock(Path(project_yml).resolve().parent))
    checks.extend(check_source_project(project_yml, identity, mode))
    failures = [item["name"] for item in checks if not item["ok"]]
    return {
        "mode": mode,
        "identity": identity.as_json(),
        "sourceRef": commit,
        "checks": checks,
        "failures": failures,
        "ok": not failures,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app")
    parser.add_argument("--ipa")
    parser.add_argument("--allow-signed", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--mode", choices=MODES, default=QUALIFICATION)
    parser.add_argument(
        "--derive-mode", action="store_true",
        help="print qualification or product-qualification from trusted project "
             "source and exit (no app/IPA verification)",
    )
    parser.add_argument("--project", default=str(Path(__file__).resolve().parent.parent / "project.yml"))
    parser.add_argument("--repo-root")
    parser.add_argument("--source-ref")
    parser.add_argument("--expected-version")
    parser.add_argument("--expected-build")
    parser.add_argument("--bundle-id",
                        help="explicit host bundle ID for private re-signed verification; "
                             "public unsigned verification stays canonical")
    parser.add_argument("--check", action="store_true",
                        help="read-only project/lock validation; never writes the lock")
    args = parser.parse_args()

    if args.mode == RELEASE and args.allow_signed:
        parser.error(
            "release public IPAs are unsigned; --allow-signed is private qualification-only"
        )
    if args.mode == RELEASE and args.bundle_id:
        parser.error("public release verification requires the canonical bundle IDs")
    if args.mode == RELEASE and args.derive_mode:
        parser.error("--derive-mode reports the private qualification mode only")
    if args.bundle_id and not args.allow_signed:
        parser.error("--bundle-id is for private re-signed verification; add --allow-signed")
    if args.bundle_id and args.check:
        parser.error("--bundle-id is only for signed app/IPA verification, not project --check")
    if args.derive_mode:
        project_yml = Path(args.project).resolve()
        repo_root = Path(args.repo_root).resolve() if args.repo_root else project_yml.parent.parent
        try:
            print(derive_verification_mode(project_yml, repo_root, args.source_ref))
        except IdentityError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        return 0
    if not args.check and not args.app and not args.ipa:
        parser.error("provide --app and/or --ipa, or use --check")

    try:
        bundle_ids = derive_bundle_ids(args.bundle_id or HOST_ID)
    except IdentityError as error:
        parser.error(str(error))

    project_yml = Path(args.project).resolve()
    repo_root = Path(args.repo_root).resolve() if args.repo_root else project_yml.parent.parent

    if args.check:
        try:
            result = check_project(
                project_yml, repo_root, args.mode, args.source_ref,
                args.expected_version, args.expected_build,
            )
        except IdentityError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            print(f"project identity ok={result['ok']} mode={result['mode']}")
            for item in result["checks"]:
                print(f"  {'OK' if item['ok'] else 'FAIL'}  {item['name']}: {item['detail']}")
        return 0 if result["ok"] else 1

    try:
        identity, commit = load_identity_for_source(project_yml, repo_root, args.source_ref)
        identity = apply_identity_overrides(identity, args.expected_version, args.expected_build)
        identity = validate_identity(identity, args.mode)
    except IdentityError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    require_unsigned = not args.allow_signed
    probe = SystemMachOProbe()
    source_root = project_yml.parent
    result = {
        "mode": args.mode,
        "identity": identity.as_json(),
        "bundleIds": bundle_ids,
        "sourceRef": commit,
    }
    ok = True
    if args.app:
        result["app"] = check_app(
            Path(args.app), require_unsigned=require_unsigned, mode=args.mode,
            identity=identity, bundle_ids=bundle_ids, probe=probe,
            source_root=source_root, project_yml=project_yml,
        )
        ok = ok and result["app"]["ok"]
    if args.ipa:
        result["ipa"] = check_ipa(
            Path(args.ipa), require_unsigned=require_unsigned, mode=args.mode,
            identity=identity, bundle_ids=bundle_ids, probe=probe,
            source_root=source_root, project_yml=project_yml,
        )
        ok = ok and result["ipa"]["ok"]
    result["ok"] = ok

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        print(f"mode={args.mode} identity={identity.marketing_version} ({identity.build_number}) ok={ok}")
        for section in ("app", "ipa"):
            if section in result:
                print(f"[{section}] ok={result[section]['ok']}")
                for item in result[section]["checks"]:
                    print(f"  {'OK' if item['ok'] else 'FAIL'}  {item['name']}: {item['detail']}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
