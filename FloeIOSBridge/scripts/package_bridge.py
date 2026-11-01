#!/usr/bin/env python3
"""Assemble a Floe iOS Bridge IPA with parameterized, source-bound evidence.

The script keeps two clearly separated products:

* a private manifest containing the full source file list, local build command,
  absolute artifact paths and git status; and
* a minimal public summary plus canonical ``.sha256`` sidecar for a release.

Modes:

* ``qualification`` keeps the legacy private prototype lane and records
  provenance deviations without failing;
* ``product-qualification`` packages product content with release-shaped
  source provenance but a private filename and no public summary;
* ``release`` packages the canonical unsigned public artifact.

Both product modes require an explicit committed source ref.  Every file under
the Bridge project must match that ref's git tree; tracked modifications,
untracked files, missing files and escaping symlinks are rejected.  Root
changes outside the Bridge project are never included.

Read-only ``--check`` validates project identity, pins and provenance and never
rewrites the idevice lock or any other file.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verify_bridge  # noqa: E402

HOST_APP = "BridgeHost.app"
TEST_BUNDLE = "BridgeTests.xctest"
APPEX = "BridgeTunnel.appex"
APPEX_BUNDLE = "BridgeTunnel.appex"
CANONICAL_PREFIX = "Floe-iOS-Bridge"
PUBLIC_SCHEMA = "floe-ios-bridge-public-summary/v1"
PRIVATE_SCHEMA = "floe-ios-bridge-private-manifest/v1"
GENERATED_IGNORED_PREFIXES = (
    "FloeIOSBridge/Frameworks/IDevice.xcframework",
)
IGNORED_FILE_NAMES = {".DS_Store"}
IGNORED_DIR_NAMES = {"__pycache__", ".pytest_cache"}
IGNORED_SUFFIXES = {".pyc", ".pyo"}
SAFE_IPA_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.ipa$")
PUBLIC_FORBIDDEN_KEYS = {
    "buildCommand", "sourceRoot", "gitStatusForProject", "gitHead",
    "files", "hostLoads", "hostRpaths", "testLoads", "testRpaths",
    "dSYM", "dSYMs", "profile", "profiles", "udid", "UDID", "pairing",
    "pairingKey", "controlKey", "bearer", "token", "secret", "credential",
}
PUBLIC_FORBIDDEN_VALUE_PATTERNS = (
    re.compile(r"/Users/[^/\s\"']+"),
    re.compile(r"/Volumes/[^/\s\"']+"),
    re.compile(r"file://"),
    re.compile(r"/private/[^/\s\"']+"),
    re.compile(r"(?i)embedded\.mobileprovision"),
    re.compile(r"(?i)embedded\.provisionprofile"),
    re.compile(r"(?i)provisioning profile"),
    re.compile(r"\bUDID\b", re.IGNORECASE),
    re.compile(r"(?i)\bpairing\b"),
    re.compile(r"(?i)\bcontrolKey\b"),
    re.compile(r"(?i)\bbearer\b"),
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git_blob_sha1(data: bytes) -> str:
    header = b"blob " + str(len(data)).encode("ascii") + b"\0"
    return hashlib.sha1(header + data).hexdigest()


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def run(command: list[str], cwd: Path | None = None) -> str:
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"command failed ({result.returncode}): {' '.join(command)}\n{result.stderr}"
        )
    return result.stdout


def git_run(repo_root: Path, arguments: list[str], text: bool = True):
    command = ["git", "-C", str(repo_root), *arguments]
    result = subprocess.run(command, text=text, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(
            "git command failed: "
            + " ".join(command)
            + "\n"
            + (result.stderr if text else result.stderr.decode("utf-8", "replace"))
        )
    return result.stdout


def _project_relative(repo_root: Path, project_root: Path) -> str:
    repo_root = Path(repo_root).resolve()
    project_root = Path(project_root).resolve()
    try:
        relative = project_root.relative_to(repo_root)
    except ValueError as error:
        raise ValueError("project root is outside the repository root") from error
    value = relative.as_posix()
    return "" if value == "." else value


def _source_prefix(project_relative: str) -> str:
    return f"{project_relative}/" if project_relative else ""


def _path_is_ignored(relative: str, ignored: set[str]) -> bool:
    return any(
        relative == item or relative.startswith(item + "/")
        for item in ignored
    )


def _ignored_worktree_paths(repo_root: Path, project_relative: str) -> set[str]:
    prefix = _source_prefix(project_relative)
    if not prefix:
        return set()
    result = subprocess.run(
        [
            "git", "-C", str(repo_root), "ls-files", "--others", "--ignored",
            "--exclude-standard", "-z", "--", prefix,
        ],
        text=False, capture_output=True,
    )
    if result.returncode != 0:
        return set()
    values = set()
    for item in result.stdout.decode("utf-8", "surrogateescape").split("\0"):
        item = item.rstrip("/")
        if item:
            values.add(item)
    return values


def _allowed_ignored_path(relative: str, project_prefix: str) -> bool:
    allowed = {project_prefix + "Frameworks/IDevice.xcframework"}
    if relative in allowed or any(relative.startswith(item + "/") for item in allowed):
        return True
    path = Path(relative)
    if path.name == ".DS_Store" or path.suffix.lower() in {".pyc", ".pyo"}:
        return True
    if any(part in IGNORED_DIR_NAMES for part in path.parts):
        return True
    return False


def _symlink_escapes(relative: str, target: str) -> bool:
    if os.path.isabs(target):
        return True
    parent = os.path.dirname(relative)
    combined = os.path.normpath(os.path.join(parent, target))
    return combined == ".." or combined.startswith("../") or os.path.isabs(combined)


def _git_tree_entries(repo_root: Path, commit: str, project_relative: str) -> dict[str, dict]:
    prefix = _source_prefix(project_relative)
    output = subprocess.run(
        [
            "git", "-C", str(repo_root), "ls-tree", "-r", "-z",
            "--full-tree", commit, "--", prefix,
        ],
        text=False, capture_output=True,
    )
    if output.returncode != 0:
        raise RuntimeError(
            "could not read source tree at "
            + commit
            + ": "
            + output.stderr.decode("utf-8", "replace")
        )
    entries: dict[str, dict] = {}
    for record in output.stdout.decode("utf-8", "surrogateescape").split("\0"):
        if not record:
            continue
        before, _, path = record.partition("\t")
        parts = before.split()
        if len(parts) != 3:
            raise RuntimeError(f"unexpected git ls-tree record: {record!r}")
        mode, kind, object_id = parts
        entries[path] = {"mode": mode, "kind": kind, "object": object_id}
    return entries


def _read_blob(repo_root: Path, object_id: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repo_root), "cat-file", "blob", object_id],
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"could not read git blob {object_id}")
    return result.stdout


def _worktree_source_entry(
    path: Path,
    repo_root: Path,
    project_relative: str,
    ignored: set[str],
) -> tuple[dict | None, str | None]:
    relative = path.relative_to(repo_root).as_posix()
    suffix = path.suffix.lower()
    if path.name in IGNORED_FILE_NAMES or suffix in IGNORED_SUFFIXES:
        return None, "ignored-suffix"
    if any(part in IGNORED_DIR_NAMES for part in path.parts):
        return None, "ignored-directory"
    if _path_is_ignored(relative, ignored):
        return None, "ignored-generated"
    if path.is_symlink():
        try:
            target = os.readlink(path)
        except OSError as error:
            return None, f"symlink-read-error: {error}"
        if _symlink_escapes(relative, target):
            return None, "escaping-symlink"
        data = target.encode("utf-8", "surrogateescape")
        return {
            "path": relative,
            "kind": "symlink",
            "mode": "120000",
            "bytes": len(data),
            "sha256": sha256_bytes(data),
            "blob": git_blob_sha1(data),
            "linkTarget": target,
        }, None
    if not path.is_file():
        return None, "not-a-regular-file"
    try:
        data = path.read_bytes()
    except OSError as error:
        return None, f"read-error: {error}"
    executable = bool(path.stat().st_mode & 0o111)
    return {
        "path": relative,
        "kind": "file",
        "mode": "100755" if executable else "100644",
        "bytes": len(data),
        "sha256": sha256_bytes(data),
        "blob": git_blob_sha1(data),
    }, None


def _walk_worktree(repo_root: Path, project_root: Path, ignored: set[str]) -> tuple[list[dict], list[dict], list[str]]:
    project_relative = _project_relative(repo_root, project_root)
    files: list[dict] = []
    deviations: list[dict] = []
    skipped: list[str] = []
    root = Path(project_root).resolve()
    for current, directories, filenames in os.walk(root, followlinks=False):
        current_path = Path(current)
        relative_dir = current_path.relative_to(root).as_posix()
        for directory in list(directories):
            candidate = current_path / directory
            relative = (
                candidate.relative_to(repo_root).as_posix()
            )
            if _path_is_ignored(relative, ignored):
                directories.remove(directory)
                skipped.append(relative)
                continue
            if candidate.is_symlink():
                directories.remove(directory)
                entry, problem = _worktree_source_entry(candidate, repo_root, project_relative, ignored)
                if entry is not None:
                    files.append(entry)
                elif problem:
                    deviations.append({"kind": problem, "path": relative})
        for filename in filenames:
            path = current_path / filename
            relative = path.relative_to(repo_root).as_posix()
            entry, problem = _worktree_source_entry(path, repo_root, project_relative, ignored)
            if entry is not None:
                files.append(entry)
            elif problem == "escaping-symlink":
                deviations.append({"kind": problem, "path": relative})
            elif problem and not problem.startswith("ignored"):
                deviations.append({"kind": problem, "path": relative})
    return sorted(files, key=lambda item: item["path"]), deviations, sorted(set(skipped))


def compute_provenance(
    repo_root: Path,
    project_root: Path,
    mode: str,
    source_ref: str | None = None,
) -> dict:
    """Bind the worktree source subtree to an explicit committed ref.

    Both product modes are strict.  Legacy qualification records deviations
    but still succeeds, because a private DDI candidate may legitimately
    contain uncommitted work.  The private manifest always retains deviations.
    """
    repo_root = Path(repo_root).resolve()
    project_root = Path(project_root).resolve()
    project_relative = _project_relative(repo_root, project_root)
    project_prefix = _source_prefix(project_relative)
    strict = mode in verify_bridge.PRODUCT_MODES

    resolved_ref: str | None = None
    expected: dict[str, dict] = {}
    if source_ref:
        resolved_ref = verify_bridge.resolve_ref(repo_root, source_ref)
        expected = _git_tree_entries(repo_root, resolved_ref, project_relative)
        if not expected:
            raise RuntimeError(
                f"source ref {resolved_ref} contains no files under {project_prefix or '.'}"
            )

    ignored = _ignored_worktree_paths(repo_root, project_relative)
    files, walk_deviations, skipped = _walk_worktree(repo_root, project_root, ignored)
    seen = {item["path"] for item in files}
    deviations = list(walk_deviations)
    if strict:
        for path in sorted(ignored):
            if not _allowed_ignored_path(path, project_prefix):
                deviations.append({"kind": "ignored-unexpected", "path": path})

    if resolved_ref:
        for path, entry in sorted(expected.items()):
            if not path.startswith(project_prefix):
                deviations.append({"kind": "outside-source-prefix", "path": path})
                continue
            if path not in seen:
                deviations.append({"kind": "missing", "path": path})
        for item in files:
            expected_entry = expected.get(item["path"])
            if expected_entry is None:
                deviations.append({"kind": "untracked", "path": item["path"]})
                continue
            if expected_entry["kind"] != "blob":
                deviations.append({
                    "kind": "unsupported-git-kind",
                    "path": item["path"],
                    "detail": expected_entry["kind"],
                })
                continue
            if expected_entry["mode"] == "120000":
                if item["kind"] != "symlink":
                    deviations.append({"kind": "symlink-type-mismatch", "path": item["path"]})
                    continue
                target = _read_blob(repo_root, expected_entry["object"]).decode(
                    "utf-8", "surrogateescape"
                )
                if item.get("linkTarget") != target:
                    deviations.append({"kind": "symlink-target-mismatch", "path": item["path"]})
                if _symlink_escapes(item["path"], target):
                    deviations.append({"kind": "escaping-symlink", "path": item["path"]})
            else:
                if item["kind"] != "file":
                    deviations.append({"kind": "type-mismatch", "path": item["path"]})
                elif item["blob"] != expected_entry["object"]:
                    deviations.append({"kind": "modified", "path": item["path"]})
    else:
        for path, entry in expected.items():
            if not path.startswith(project_prefix):
                deviations.append({"kind": "outside-source-prefix", "path": path})

    files_for_hash = []
    if resolved_ref:
        expected_paths = set(expected)
        for item in files:
            if item["path"] in expected_paths:
                files_for_hash.append(item)
    else:
        files_for_hash = files
    canonical_lines = []
    for item in sorted(files_for_hash, key=lambda value: value["path"]):
        canonical_lines.append(
            f"{item['mode']} {item['blob']} {item['path']}\n".encode("utf-8", "surrogateescape")
        )
    source_tree_sha256 = hashlib.sha256(b"".join(canonical_lines)).hexdigest()
    strict_deviations = [
        item for item in deviations
        if item["kind"] not in {"ignored-generated", "ignored-suffix", "ignored-directory"}
    ]
    ok = True if not strict else not strict_deviations
    return {
        "mode": mode,
        "strict": strict,
        "ok": ok,
        "sourceRef": resolved_ref,
        "sourceRefInput": source_ref,
        "sourcePrefix": project_prefix,
        "sourceTreeSHA256": source_tree_sha256,
        "sourceFileCount": len(files_for_hash),
        "files": files_for_hash if strict else files,
        "deviations": deviations,
        "strictDeviations": strict_deviations,
        "skippedIgnored": skipped,
        "ignoredPaths": sorted(ignored),
        "rootHead": git_run(repo_root, ["rev-parse", "HEAD"]).strip(),
        "gitStatusForProject": [
            line for line in git_run(
                repo_root, ["status", "--short", "--", project_prefix or "."]
            ).splitlines()
            if line
        ],
    }


def canonical_ipa_name(marketing_version: str) -> str:
    return f"{CANONICAL_PREFIX}-{marketing_version}-unsigned.ipa"


def validate_ipa_name(name: str) -> str:
    if not SAFE_IPA_NAME_RE.fullmatch(name):
        raise ValueError(
            "IPA name must be a plain .ipa filename without directories: "
            + repr(name)
        )
    return name


def resolve_ipa_name(
    mode: str,
    identity: verify_bridge.BuildIdentity,
    requested: str | None,
) -> str:
    """Public release names are canonical; private modes may use their own name."""
    if mode == verify_bridge.RELEASE:
        expected = canonical_ipa_name(identity.marketing_version)
        if requested and requested != expected:
            raise ValueError(
                f"release IPA name must be {expected!r}, not {requested!r}"
            )
        return validate_ipa_name(expected)
    if mode == verify_bridge.PRODUCT_QUALIFICATION:
        return validate_ipa_name(requested or "FloeBridge-product-unsigned.ipa")
    return validate_ipa_name(requested or "FloeBridge-unsigned.ipa")


def determine_identity(args) -> tuple[verify_bridge.BuildIdentity, str | None, Path, Path]:
    project_yml = Path(args.project).resolve()
    project_root = project_yml.parent
    repo_root = Path(args.repo_root).resolve() if args.repo_root else project_root.parent
    identity, commit = verify_bridge.load_identity_for_source(
        project_yml, repo_root, args.source_ref
    )
    identity = verify_bridge.apply_identity_overrides(
        identity, args.marketing_version, args.build_number
    )
    identity = verify_bridge.validate_identity(identity, args.mode)
    return identity, commit, project_root, repo_root


def _read_build_command(output_dir: Path) -> str:
    command_file = output_dir / "build-command.txt"
    return command_file.read_text().strip() if command_file.is_file() else ""


def _xcode_version() -> str:
    developer_dir = Path("/Applications/Xcode-27.1.app/Contents/Developer")
    if developer_dir.is_dir():
        result = subprocess.run(
            [str(developer_dir / "usr/bin/xcodebuild"), "-version"],
            text=True, capture_output=True,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    return ""


def _private_manifest(
    output_dir: Path,
    identity: verify_bridge.BuildIdentity,
    mode: str,
    provenance: dict,
    app_result: dict,
    ipa_result: dict,
    ipa_path: Path,
    artifact_app: Path,
    appex: Path,
    test_bundle: Path,
    dsym_result: dict,
    build_command: str,
    project_root: Path,
) -> dict:
    host_binary = artifact_app / "BridgeHost"
    appex_binary = appex / "BridgeTunnel"
    test_binary = test_bundle / "BridgeTests"
    core_binary = artifact_app / "Frameworks" / "BridgeCore.framework" / "BridgeCore"
    return {
        "schema": PRIVATE_SCHEMA,
        "generatedAt": timestamp(),
        "mode": mode,
        "artifactKind": "unsigned-source-package",
        "identity": identity.as_json(),
        "artifact": {
            "ipa": str(ipa_path),
            "ipaBytes": ipa_path.stat().st_size,
            "ipaSHA256": sha256(ipa_path),
            "app": str(artifact_app),
            "hostBinarySHA256": sha256(host_binary),
            "appexBinarySHA256": sha256(appex_binary),
            "testBinarySHA256": sha256(test_binary),
            "coreBinarySHA256": sha256(core_binary),
            "signed": False,
            "hostBundleIdentifier": verify_bridge.HOST_ID,
            "marketingVersion": identity.marketing_version,
            "buildNumber": identity.build_number,
        },
        "source": {
            **provenance,
            "buildCommand": build_command,
            "xcodeVersion": _xcode_version(),
            "idevice": _load_idevice_lock(project_root),
        },
        "verification": {
            "appOK": app_result["ok"],
            "ipaOK": ipa_result["ok"],
            "checks": len(app_result["checks"]) + len(ipa_result["checks"]),
            "hostLoads": app_result.get("hostLoads", []),
            "hostRpaths": app_result.get("hostRpaths", []),
            "testLoads": app_result.get("testLoads", []),
            "testRpaths": app_result.get("testRpaths", []),
            "uuids": app_result.get("uuids", {}),
        },
        "symbols": dsym_result,
    }


def _load_idevice_lock(project_root: Path) -> dict:
    lock_path = Path(project_root) / "Vendor" / "idevice.lock.json"
    try:
        return json.loads(lock_path.read_text())
    except (OSError, ValueError):
        return {}


def build_public_summary(
    identity: verify_bridge.BuildIdentity,
    ipa_path: Path,
    provenance: dict,
    app_result: dict,
    ipa_result: dict,
    dsym_result: dict,
) -> dict:
    return {
        "schema": PUBLIC_SCHEMA,
        "product": "Floe iOS Bridge",
        "mode": verify_bridge.RELEASE,
        "marketingVersion": identity.marketing_version,
        "buildNumber": identity.build_number,
        "bundleIdentifier": verify_bridge.HOST_ID,
        "applicationExtensionBundleIdentifier": verify_bridge.TUNNEL_ID,
        "coreBundleIdentifier": verify_bridge.CORE_ID,
        "sourceRef": provenance.get("sourceRef"),
        "sourceTreeSHA256": provenance.get("sourceTreeSHA256"),
        "sourceFileCount": provenance.get("sourceFileCount"),
        "artifact": {
            "filename": ipa_path.name,
            "sha256": sha256(ipa_path),
            "bytes": ipa_path.stat().st_size,
        },
        "topology": {
            "topLevelApps": 1,
            "appExtensions": 1,
            "xctests": 1,
            "nestedApps": 0,
        },
        "verification": {
            "mode": verify_bridge.RELEASE,
            "checks": len(app_result["checks"]) + len(ipa_result["checks"]),
            "failed": 0,
            "unsigned": True,
            "noDDI": True,
            "hostNoXCTest": True,
            "arm64IPhoneOS": True,
            "roleVersionsAgree": True,
            "symbolsVerified": bool(dsym_result.get("ok")),
        },
        "limitations": [
            "Static package verification only; runtime behavior, runtime closure, "
            "signing, install and device acceptance are not proven by this summary."
        ],
    }


def _walk_public_values(value, path: str = "$"):
    if isinstance(value, dict):
        for key, item in value.items():
            yield path + "." + str(key), key, item
            yield from _walk_public_values(item, path + "." + str(key))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from _walk_public_values(item, f"{path}[{index}]")
    else:
        yield path, None, value


def public_summary_failures(summary: dict) -> list[str]:
    failures = []
    for location, key, value in _walk_public_values(summary):
        if key is not None and key in PUBLIC_FORBIDDEN_KEYS:
            failures.append(f"forbidden public key {location}")
        if isinstance(value, str):
            for pattern in PUBLIC_FORBIDDEN_VALUE_PATTERNS:
                if pattern.search(value):
                    failures.append(f"forbidden public value at {location}: {pattern.pattern}")
                    break
            if value.startswith("/") and not value.startswith("/System/") and not value.startswith("/usr/"):
                failures.append(f"absolute local path at {location}")
    return sorted(set(failures))


def _dsym_role(path: Path) -> str | None:
    for suffix, role in verify_bridge.DSYM_ROLE_SUFFIXES:
        if path.name == suffix:
            return role
    return None


def _copy_dsym(value: str, output_dir: Path, overwrite: bool = False) -> tuple[str | None, Path | None]:
    source = Path(value).resolve()
    role = _dsym_role(source)
    if role is None:
        raise RuntimeError(f"unrecognized dSYM name: {source.name}")
    target = output_dir / source.name
    if target.exists():
        if not overwrite:
            raise RuntimeError(f"dSYM already exists: {target}")
        shutil.rmtree(target)
    shutil.copytree(source, target, symlinks=True)
    return role, target


def _unsigned_preflight(app: Path) -> None:
    signatures = [str(path.relative_to(app)) for path in app.rglob("_CodeSignature")]
    profiles = [
        str(path.relative_to(app)) for path in app.rglob("*")
        if path.is_file() and path.name in verify_bridge.PROFILE_NAMES
    ]
    credentials = [
        str(path.relative_to(app)) for path in app.rglob("*")
        if path.is_file() and path.suffix.lower() in verify_bridge.SIGNING_FILE_SUFFIXES
    ]
    if signatures or profiles or credentials:
        raise RuntimeError(
            "unsigned packaging input contains signature/profile material: "
            + json.dumps({
                "signatures": signatures[:5],
                "profiles": profiles[:5],
                "credentials": credentials[:5],
            })
        )


def _output_exists(output_dir: Path, name: str) -> bool:
    return (output_dir / name).exists()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app")
    parser.add_argument("--xctest")
    parser.add_argument("--appex")
    parser.add_argument("--output-dir")
    parser.add_argument("--repo-root")
    parser.add_argument("--project", default=str(Path(__file__).resolve().parent.parent / "project.yml"))
    parser.add_argument("--mode", choices=verify_bridge.MODES, default=verify_bridge.QUALIFICATION)
    parser.add_argument("--source-ref")
    parser.add_argument("--marketing-version")
    parser.add_argument("--build-number")
    parser.add_argument("--ipa-name")
    parser.add_argument("--public-summary")
    parser.add_argument("--dsym", "--dSYM", dest="dsym", action="append", default=[])
    parser.add_argument("--overwrite", action="store_true")
    parser.add_argument("--json", action="store_true",
                        help="accepted for compatibility; check/package output is JSON")
    parser.add_argument("--check", action="store_true",
                        help="read-only identity/lock/provenance validation; writes nothing")
    args = parser.parse_args()

    if args.mode in verify_bridge.PRODUCT_MODES and not args.source_ref:
        print(
            f"error: {args.mode} packaging requires an explicit --source-ref",
            file=sys.stderr,
        )
        return 2
    try:
        identity, source_commit, project_root, repo_root = determine_identity(args)
    except (ValueError, RuntimeError, verify_bridge.IdentityError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    if args.check:
        try:
            provenance = compute_provenance(
                repo_root, project_root, args.mode, args.source_ref
            )
            lock_checks = verify_bridge.validate_lock(project_root)
            project_checks = verify_bridge.check_source_project(
                project_root / "project.yml", identity, args.mode
            )
        except (ValueError, RuntimeError, verify_bridge.IdentityError) as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        checks = [
            {"name": "project-identity", "ok": True,
             "detail": json.dumps(identity.as_json(), sort_keys=True)},
            {"name": "source-ref", "ok": source_commit is not None or args.mode == verify_bridge.QUALIFICATION,
             "detail": source_commit or "<not supplied>"},
            {"name": "provenance", "ok": provenance["ok"],
             "detail": json.dumps({
                 "sourceRef": provenance["sourceRef"],
                 "sourceTreeSHA256": provenance["sourceTreeSHA256"],
                 "sourceFileCount": provenance["sourceFileCount"],
                 "deviations": provenance["strictDeviations"],
             }, sort_keys=True)},
        ]
        checks.extend(lock_checks)
        checks.extend(project_checks)
        failures = [item["name"] for item in checks if not item["ok"]]
        result = {
            "checkOnly": True,
            "mode": args.mode,
            "identity": identity.as_json(),
            "sourceRef": source_commit,
            "sourceTreeSHA256": provenance["sourceTreeSHA256"],
            "sourceFileCount": provenance["sourceFileCount"],
            "provenanceDeviations": provenance["strictDeviations"],
            "checks": checks,
            "failures": failures,
            "ok": not failures,
        }
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["ok"] else 1

    if not args.app or not args.xctest or not args.output_dir:
        parser.error("--app, --xctest and --output-dir are required (or use --check)")

    build_app = Path(args.app).resolve()
    build_xctest = Path(args.xctest).resolve()
    output_dir = Path(args.output_dir).resolve()
    if not build_app.is_dir():
        print(f"error: app not found: {build_app}", file=sys.stderr)
        return 2
    if not build_xctest.is_dir():
        print(f"error: xctest not found: {build_xctest}", file=sys.stderr)
        return 2

    try:
        ipa_name = resolve_ipa_name(args.mode, identity, args.ipa_name)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    try:
        provenance = compute_provenance(repo_root, project_root, args.mode, args.source_ref)
    except (ValueError, RuntimeError, verify_bridge.IdentityError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if args.mode in verify_bridge.PRODUCT_MODES and not provenance["ok"]:
        print(json.dumps({
            "error": "source provenance does not match the explicit source ref",
            "deviations": provenance["strictDeviations"],
        }, indent=2, sort_keys=True), file=sys.stderr)
        return 1

    source_appex = Path(args.appex).resolve() if args.appex else build_app / "PlugIns" / APPEX
    if not source_appex.is_dir():
        print(f"error: app extension not found: {source_appex}", file=sys.stderr)
        return 2

    _unsigned_preflight(build_app)
    _unsigned_preflight(source_appex)

    output_dir.mkdir(parents=True, exist_ok=True)
    artifact_app = output_dir / HOST_APP
    ipa_path = output_dir / ipa_name
    summary_path = output_dir / (
        args.public_summary or f"{CANONICAL_PREFIX}-{identity.marketing_version}-public.json"
    )
    if args.public_summary:
        if Path(args.public_summary).name != args.public_summary or Path(args.public_summary).is_absolute():
            print("error: --public-summary must be a plain filename inside --output-dir", file=sys.stderr)
            return 2
        if summary_path.name == ipa_name or summary_path.name in {
            "manifest.json", "verify-app.json", "verify-ipa.json", "dsym.json",
            "package-result.json", "build-command.txt",
        }:
            print("error: --public-summary collides with a packaging output", file=sys.stderr)
            return 2
    for target in (artifact_app, ipa_path):
        if target.exists() and not args.overwrite:
            print(f"error: output already exists (use --overwrite): {target}", file=sys.stderr)
            return 2
    if args.mode == verify_bridge.RELEASE:
        sidecar_path = Path(str(ipa_path) + ".sha256")
        if (summary_path.exists() or sidecar_path.exists()) and not args.overwrite:
            print("error: public summary or .sha256 sidecar already exists", file=sys.stderr)
            return 2

    if artifact_app.exists():
        shutil.rmtree(artifact_app)
    shutil.copytree(build_app, artifact_app, symlinks=True)
    appex = artifact_app / "PlugIns" / APPEX
    if not appex.is_dir():
        appex.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source_appex, appex, symlinks=True)
    destination_xctest = artifact_app / "PlugIns" / TEST_BUNDLE
    if destination_xctest.exists():
        shutil.rmtree(destination_xctest)
    shutil.copytree(build_xctest, destination_xctest, symlinks=True)

    app_result = verify_bridge.check_app(
        artifact_app,
        require_unsigned=True,
        mode=args.mode,
        identity=identity,
        source_root=project_root,
        project_yml=project_root / "project.yml",
    )
    (output_dir / "verify-app.json").write_text(
        json.dumps(app_result, indent=2, sort_keys=True) + "\n"
    )
    if not app_result["ok"]:
        for failure in app_result["failures"]:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1

    dsym_result = {"checks": [], "failures": [], "ok": True, "uuids": {}}
    copied_dsyms = []
    for value in args.dsym:
        try:
            role, target = _copy_dsym(value, output_dir, overwrite=args.overwrite)
        except RuntimeError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        copied_dsyms.append(target)
    if copied_dsyms:
        dsym_result = verify_bridge.check_dsyms(
            app_result, copied_dsyms, mode=args.mode
        )
        if not dsym_result["ok"]:
            for failure in dsym_result["failures"]:
                print(f"FAIL: {failure}", file=sys.stderr)
            return 1
    elif args.mode == verify_bridge.RELEASE:
        print("error: release packaging requires --dsym for host, appex, core and test", file=sys.stderr)
        return 2
    (output_dir / "dsym.json").write_text(
        json.dumps(dsym_result, indent=2, sort_keys=True) + "\n"
    )

    if ipa_path.exists():
        ipa_path.unlink()
    with tempfile.TemporaryDirectory(prefix="floe-bridge-package-") as temporary:
        payload = Path(temporary) / "Payload"
        payload.mkdir()
        shutil.copytree(artifact_app, payload / HOST_APP, symlinks=True)
        run([
            "/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
            str(payload), str(ipa_path),
        ], cwd=output_dir)

    ipa_result = verify_bridge.check_ipa(
        ipa_path,
        require_unsigned=True,
        mode=args.mode,
        identity=identity,
        source_root=project_root,
        project_yml=project_root / "project.yml",
    )
    (output_dir / "verify-ipa.json").write_text(
        json.dumps(ipa_result, indent=2, sort_keys=True) + "\n"
    )
    if not ipa_result["ok"]:
        for failure in ipa_result["failures"]:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1

    manifest = _private_manifest(
        output_dir, identity, args.mode, provenance, app_result, ipa_result,
        ipa_path, artifact_app, appex, destination_xctest, dsym_result,
        _read_build_command(output_dir), project_root,
    )
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )
    (output_dir / "otool-host.txt").write_text(
        "\n".join(app_result.get("hostLoads", [])) + "\n"
    )
    (output_dir / "otool-test.txt").write_text(
        "\n".join(app_result.get("testLoads", [])) + "\n"
    )

    sidecar_path = None
    if args.mode == verify_bridge.RELEASE:
        summary = build_public_summary(
            identity, ipa_path, provenance, app_result, ipa_result, dsym_result
        )
        failures = public_summary_failures(summary)
        if failures:
            print("error: public summary is not public-safe: " + json.dumps(failures), file=sys.stderr)
            return 1
        summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
        sidecar_path = Path(str(ipa_path) + ".sha256")
        sidecar_path.write_text(f"{summary['artifact']['sha256']}  {ipa_path.name}\n")
        readback = sidecar_path.read_text(encoding="utf-8").split()
        if readback != [summary["artifact"]["sha256"], ipa_path.name]:
            print("error: .sha256 sidecar read-back mismatch", file=sys.stderr)
            return 1
        if json.loads(summary_path.read_text(encoding="utf-8")) != summary:
            print("error: public summary read-back mismatch", file=sys.stderr)
            return 1

    print(json.dumps({
        "ipa": str(ipa_path),
        "ipaSHA256": manifest["artifact"]["ipaSHA256"],
        "ipaBytes": manifest["artifact"]["ipaBytes"],
        "appOK": app_result["ok"],
        "ipaOK": ipa_result["ok"],
        "mode": args.mode,
        "identity": identity.as_json(),
        "sourceRef": provenance["sourceRef"],
        "sourceTreeSHA256": provenance["sourceTreeSHA256"],
        "sourceFileCount": provenance["sourceFileCount"],
        "provenanceDeviations": len(provenance["strictDeviations"]),
        "publicSummary": str(summary_path) if sidecar_path else None,
        "sha256Sidecar": str(sidecar_path) if sidecar_path else None,
        "manifest": str(output_dir / "manifest.json"),
    }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
