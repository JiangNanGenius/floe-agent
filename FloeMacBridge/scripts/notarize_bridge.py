#!/usr/bin/env python3
"""Source-bound Floe Bridge notarization helper using Apple's notarytool.

The helper runs on macOS only. It never reads or exports the Developer ID
private key: signing stays on the release Mac, while this helper verifies the
signed, source-bound app (or a DMG containing the already-stapled app), submits
the artifact with the existing App Store Connect API key, and staples the
accepted result.

Safety properties:
  * The artifact must be a regular file and within a fixed size bound.
  * A zip must contain exactly one top-level ``Floe Bridge.app`` with a
    ``Contents/Resources/source-commit.txt`` beginning with the exact 40-hex
    source commit. Absolute paths, traversal, symlinks and oversized archives
    are rejected before extraction.
  * The app must have bundle ID ``org.floeagent.macbridge``, the expected
    executable, a Developer ID Application authority for the expected Team ID,
    the hardened-runtime flag and an arm64 executable.
  * A DMG is mounted read-only and its app must already be stapled; this
    prevents notarizing a DMG that contains an unstapled app.
  * No build is run and no private key material is read. Errors are redacted.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from typing import Any

BUNDLE_ID = "org.floeagent.macbridge"
EXECUTABLE = "FloeMacBridge"
SOURCE_RE = re.compile(r"^([0-9a-f]{40})(?:\s|$)")
TEAM_RE = re.compile(r"^[A-Z0-9]{10}$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
TIMEOUT_RE = re.compile(r"^[1-9][0-9]{0,2}[mh]$")
MAX_ARTIFACT_BYTES = 500 * 1024 * 1024
MAX_ZIP_ENTRIES = 5000
MAX_ZIP_UNCOMPRESSED = 1024 * 1024 * 1024
MAX_LOG_ISSUES = 5
TERMINAL_STATUSES = {"Accepted", "Invalid", "Rejected"}
PENDING_STATUSES = {"In Progress", "Submitted", "Pending", "Unknown"}
UUID_SEARCH = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

_SECRET_PATTERNS = [
    re.compile(r"-----BEGIN [A-Z0-9 ]+-----.*?-----END [A-Z0-9 ]+-----", re.S),
    re.compile(r"(?i)bearer\s+[A-Za-z0-9._~+/=-]{16,}"),
    re.compile(r"[A-Za-z0-9+/]{120,}={0,2}"),
]


class HelperError(Exception):
    def __init__(self, message: str, exit_code: int = 2) -> None:
        super().__init__(message)
        self.message = message
        self.exit_code = exit_code


def redact(value: Any) -> str:
    text = str(value)
    for pattern in _SECRET_PATTERNS:
        text = pattern.sub("<redacted>", text)
    text = text.replace(str(Path.home()), "~")
    return text.replace("\x00", "")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def run_tool(args: list[str], *, timeout: int = 120, input_bytes: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(
            args,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=timeout,
        )
    except FileNotFoundError as error:
        raise HelperError(f"Required macOS tool not found: {args[0]}") from error
    except subprocess.TimeoutExpired as error:
        raise HelperError(f"Command timed out: {args[0]}") from error


def run_checked(args: list[str], what: str, *, timeout: int = 120) -> bytes:
    result = run_tool(args, timeout=timeout)
    if result.returncode != 0:
        detail = redact(result.stderr.decode("utf-8", "replace")).strip()[:500]
        if not detail:
            detail = redact(result.stdout.decode("utf-8", "replace")).strip()[:500]
        raise HelperError(f"{what} failed" + (f": {detail}" if detail else ""))
    return result.stdout


def parse_codesign_dv(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        # codesign emits flags inside the CodeDirectory record, rather than
        # as a separate key, on current macOS releases.
        if line.startswith("CodeDirectory "):
            flag_match = re.search(r"(?:^|\s)flags=(\S+)", line)
            if flag_match:
                values.setdefault("flags", flag_match.group(1))
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key == "Authority" and value.startswith("Developer ID Application:") and "authority" not in values:
            values["authority"] = value
        elif key in ("TeamIdentifier", "Identifier", "flags") and key not in values:
            values[key] = value
    return values


def verify_app(app: Path, source_sha: str, team_id: str, *, require_stapled: bool) -> dict[str, Any]:
    if not app.is_dir() or app.suffix != ".app":
        raise HelperError("Expected exactly one top-level .app bundle")
    info_path = app / "Contents" / "Info.plist"
    executable = app / "Contents" / "MacOS" / EXECUTABLE
    source_path = app / "Contents" / "Resources" / "source-commit.txt"
    for required in (info_path, executable, source_path):
        if not required.is_file():
            raise HelperError(f"App bundle is missing required file: {required.name}")
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise HelperError("Could not read the app Info.plist") from error
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise HelperError(f"Unexpected bundle identifier: {info.get('CFBundleIdentifier')!r}")
    if info.get("CFBundleExecutable") != EXECUTABLE:
        raise HelperError(f"Unexpected bundle executable: {info.get('CFBundleExecutable')!r}")
    version = str(info.get("CFBundleShortVersionString") or "")
    build = str(info.get("CFBundleVersion") or "")
    if not version or not build:
        raise HelperError("App Info.plist is missing its version or build number")

    source_text = source_path.read_text(encoding="utf-8", errors="strict").strip()
    match = SOURCE_RE.match(source_text)
    if not match:
        raise HelperError(
            "source-commit.txt must begin with the full 40-hex source SHA; "
            "the current artifact looks like an older build. Rebuild with FloeMacBridge/scripts/build_app.sh."
        )
    if match.group(1) != source_sha:
        raise HelperError(
            f"source-commit.txt does not match the requested source SHA ({match.group(1)} != {source_sha})"
        )

    run_checked(["codesign", "--verify", "--strict", "--deep", str(app)], "codesign verification")
    dv_result = run_tool(["codesign", "-dv", "--verbose=4", str(app)])
    dv = parse_codesign_dv(dv_result.stderr.decode("utf-8", "replace"))
    authority = dv.get("authority", "")
    if not authority.startswith("Developer ID Application:"):
        raise HelperError("App is not signed with a Developer ID Application certificate")
    if not authority.endswith(f"({team_id})"):
        raise HelperError(f"App Developer ID authority does not belong to Team ID {team_id}")
    if dv.get("TeamIdentifier") != team_id:
        raise HelperError(f"App TeamIdentifier does not match {team_id}")
    if dv.get("Identifier") != BUNDLE_ID:
        raise HelperError(f"App code-signing identifier does not match {BUNDLE_ID}")
    if "runtime" not in dv.get("flags", ""):
        raise HelperError("App signature does not show the hardened-runtime flag")

    archs = run_checked(["lipo", "-archs", str(executable)], "architecture inspection").decode("ascii", "replace").split()
    if "arm64" not in archs:
        raise HelperError(f"Expected an arm64 bridge executable, found: {', '.join(archs) or 'none'}")

    stapled = False
    if require_stapled:
        run_checked(["xcrun", "stapler", "validate", str(app)], "stapler validation of the app inside the DMG")
        stapled = True

    return {
        "bundleId": BUNDLE_ID,
        "version": version,
        "build": build,
        "sourceSha": source_sha,
        "authority": authority,
        "teamId": dv.get("TeamIdentifier"),
        "identifier": dv.get("Identifier"),
        "runtime": "runtime" in dv.get("flags", ""),
        "architectures": archs,
        "stapled": stapled,
    }


def validate_zip(zip_path: Path) -> None:
    if not zip_path.is_file():
        raise HelperError(f"Artifact not found: {zip_path.name}")
    size = zip_path.stat().st_size
    if not 1 <= size <= MAX_ARTIFACT_BYTES:
        raise HelperError("Artifact size is outside the accepted range")
    try:
        with zipfile.ZipFile(zip_path) as archive:
            infos = archive.infolist()
            if not infos:
                raise HelperError("Artifact zip is empty")
            if len(infos) > MAX_ZIP_ENTRIES:
                raise HelperError("Artifact zip has too many entries")
            total = 0
            for info in infos:
                name = info.filename
                if not name or "\x00" in name or name.startswith("/") or "\\" in name:
                    raise HelperError("Artifact zip contains an unsafe path")
                parts = Path(name).parts
                if any(part in ("", ".", "..") for part in parts):
                    raise HelperError("Artifact zip contains a traversal path")
                mode = (info.external_attr >> 16) & 0o170000
                if stat.S_ISLNK(mode):
                    raise HelperError("Artifact zip contains a symbolic link")
                total += info.file_size
                if total > MAX_ZIP_UNCOMPRESSED:
                    raise HelperError("Artifact zip exceeds the uncompressed size bound")
    except zipfile.BadZipFile as error:
        raise HelperError("Artifact is not a valid zip archive") from error


def extract_zip(zip_path: Path, destination: Path) -> None:
    validate_zip(zip_path)
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path) as archive:
        for info in archive.infolist():
            target = destination / info.filename
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(info) as source, target.open("wb") as sink:
                shutil.copyfileobj(source, sink, length=1024 * 1024)
            mode = (info.external_attr >> 16) & 0o777
            if mode:
                target.chmod(mode)


def find_single_app(root: Path) -> Path:
    apps = sorted(path for path in root.iterdir() if path.is_dir() and path.suffix == ".app")
    if len(apps) != 1:
        raise HelperError(f"Expected exactly one top-level .app bundle, found {len(apps)}")
    return apps[0]


def preflight_zip(zip_path: Path, source_sha: str, team_id: str) -> dict[str, Any]:
    validate_zip(zip_path)
    with tempfile.TemporaryDirectory(prefix="floe-bridge-app-") as temporary:
        root = Path(temporary)
        extract_zip(zip_path, root)
        app = find_single_app(root)
        app_summary = verify_app(app, source_sha, team_id, require_stapled=False)
    return {
        "kind": "app-zip",
        "artifact": zip_path.name,
        "artifactSha256": sha256_file(zip_path),
        "app": app_summary,
    }


def dmg_signature(dmg_path: Path) -> dict[str, str]:
    result = run_tool(["codesign", "-dv", "--verbose=4", str(dmg_path)])
    if result.returncode != 0:
        return {"status": "unsigned-or-unreadable"}
    parsed = parse_codesign_dv(result.stderr.decode("utf-8", "replace"))
    return {
        "status": "signed" if parsed.get("authority") else "unsigned",
        "authority": parsed.get("authority", ""),
        "teamId": parsed.get("TeamIdentifier", ""),
    }


def preflight_dmg(dmg_path: Path, source_sha: str, team_id: str) -> dict[str, Any]:
    if not dmg_path.is_file():
        raise HelperError(f"Artifact not found: {dmg_path.name}")
    size = dmg_path.stat().st_size
    if not 1 <= size <= MAX_ARTIFACT_BYTES:
        raise HelperError("Artifact size is outside the accepted range")
    mount = Path(tempfile.mkdtemp(prefix="floe-bridge-mnt-"))
    attached = False
    try:
        run_checked(
            ["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", str(mount), str(dmg_path)],
            "DMG attach",
            timeout=180,
        )
        attached = True
        app = find_single_app(mount)
        app_summary = verify_app(app, source_sha, team_id, require_stapled=True)
        signature = dmg_signature(dmg_path)
    finally:
        if attached:
            detach = run_tool(["hdiutil", "detach", str(mount)], timeout=120)
            if detach.returncode != 0:
                run_tool(["hdiutil", "detach", "-force", str(mount)], timeout=120)
        try:
            mount.rmdir()
        except OSError:
            pass
    return {
        "kind": "dmg",
        "artifact": dmg_path.name,
        "artifactSha256": sha256_file(dmg_path),
        "dmgSignature": signature,
        "app": app_summary,
    }


def preflight(artifact: Path, kind: str, source_sha: str, team_id: str) -> dict[str, Any]:
    if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise HelperError("--source-sha must be 40 lowercase hex")
    if not TEAM_RE.fullmatch(team_id):
        raise HelperError("--team-id must be a 10-character Apple Team ID")
    if kind == "auto":
        if artifact.suffix.lower() == ".zip":
            kind = "app-zip"
        elif artifact.suffix.lower() == ".dmg":
            kind = "dmg"
        else:
            raise HelperError("Artifact must end in .zip or .dmg")
    if kind == "app-zip":
        return preflight_zip(artifact, source_sha, team_id)
    if kind == "dmg":
        return preflight_dmg(artifact, source_sha, team_id)
    raise HelperError("Unsupported artifact kind")


def parse_json_output(stdout: bytes, stderr: bytes, what: str) -> dict[str, Any]:
    text = stdout.decode("utf-8", "replace").strip()
    if not text:
        text = stderr.decode("utf-8", "replace").strip()
    try:
        value = json.loads(text)
        if isinstance(value, dict):
            return value
    except json.JSONDecodeError:
        pass
    first = text.find("{")
    last = text.rfind("}")
    if first >= 0 and last > first:
        try:
            value = json.loads(text[first:last + 1])
            if isinstance(value, dict):
                return value
        except json.JSONDecodeError:
            pass
    raise HelperError(f"{what} did not return a JSON object")


def notarytool_common(key: Path, key_id: str, issuer: str) -> list[str]:
    if not key.is_file():
        raise HelperError("App Store Connect key file is missing")
    if not key_id.strip() or not issuer.strip():
        raise HelperError("App Store Connect key ID and issuer are required")
    return ["--key", str(key), "--key-id", key_id, "--issuer", issuer]


def timeout_to_seconds(value: str) -> int:
    if not TIMEOUT_RE.fullmatch(value):
        raise HelperError("--timeout must look like 30m or 2h")
    number = int(value[:-1])
    seconds = number * (60 if value[-1] == "m" else 3600)
    if not 60 <= seconds <= 10800:
        raise HelperError("--timeout must be between 1m and 3h")
    return seconds


def now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def write_submission_receipt(
    out_dir: Path,
    *,
    submission_id: str,
    status: str,
    artifact: Path,
    artifact_sha256: str,
    source_sha: str,
    team_id: str,
    timed_out: bool = False,
    last_error: str | None = None,
    stapled: bool = False,
) -> dict[str, Any]:
    receipt = {
        "submissionId": submission_id,
        "status": status,
        "artifact": artifact.name,
        "artifactSha256": artifact_sha256,
        "sourceSha": source_sha,
        "teamId": team_id,
        "timedOut": timed_out,
        "lastError": redact(last_error)[:500] if last_error else None,
        "stapled": stapled,
        "updatedAt": now_iso(),
        "resumeOperation": "bridge-notary-resume",
        "note": "Do not resubmit this artifact. Use bridge-notary-resume with this submission UUID; if Accepted, it staples the same source-bound artifact without a new submission.",
    }
    write_json(out_dir / "submission.json", receipt)
    return receipt


def poll_submission(
    submission_id: str,
    info_func,
    timeout_seconds: int,
    interval_seconds: int,
    *,
    clock=time.monotonic,
    sleep_func=time.sleep,
) -> tuple[dict[str, Any], str | None]:
    deadline = clock() + timeout_seconds
    last: dict[str, Any] = {"id": submission_id, "status": "Unknown"}
    last_error: str | None = None
    attempts = 0
    while True:
        attempts += 1
        try:
            payload = info_func()
            if isinstance(payload, dict):
                last = payload
                status = str(payload.get("status") or "")
                if status in TERMINAL_STATUSES:
                    return payload, None
        except HelperError as error:
            last_error = error.message
        remaining = deadline - clock()
        if remaining <= 0:
            result = dict(last)
            result["_pollTimedOut"] = True
            result["_pollAttempts"] = attempts
            if last_error:
                result["_lastError"] = last_error
            return result, last_error
        sleep_func(min(interval_seconds, max(0.0, remaining)))


def notarytool_submit(
    artifact: Path,
    key: Path,
    key_id: str,
    issuer: str,
) -> dict[str, Any]:
    """Start a submission without --wait; return the known submission ID."""
    args = [
        "xcrun",
        "notarytool",
        "submit",
        str(artifact),
        *notarytool_common(key, key_id, issuer),
        "--output-format",
        "json",
    ]
    result = run_tool(args, timeout=600)
    stdout = result.stdout.decode("utf-8", "replace")
    stderr = result.stderr.decode("utf-8", "replace")
    payload: dict[str, Any] | None
    try:
        payload = parse_json_output(result.stdout, result.stderr, "notarytool submit")
    except HelperError:
        payload = None
    if payload is not None and payload.get("id"):
        if result.returncode != 0:
            print(
                f"warning: notarytool submit exited {result.returncode} but returned "
                f"submission {payload.get('id')}; retaining it for resume",
                file=sys.stderr,
            )
        return payload
    if result.returncode != 0:
        detail = redact(stderr).strip()[:500] or redact(stdout).strip()[:500]
        raise HelperError("notarytool submit failed without a known submission ID" + (f": {detail}" if detail else ""))
    raise HelperError("notarytool submit did not return a known submission ID")


def notarytool_log(submission_id: str, key: Path, key_id: str, issuer: str, destination: Path) -> dict[str, Any] | None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    args = [
        "xcrun",
        "notarytool",
        "log",
        submission_id,
        *notarytool_common(key, key_id, issuer),
        "--output",
        str(destination),
    ]
    result = run_tool(args, timeout=180)
    if result.returncode != 0:
        return None
    try:
        payload = json.loads(destination.read_text(encoding="utf-8"))
        return payload if isinstance(payload, dict) else None
    except (OSError, json.JSONDecodeError):
        return None


def print_log_issues(payload: dict[str, Any] | None) -> None:
    if not payload:
        return
    issues = payload.get("issues")
    if not isinstance(issues, list):
        return
    for issue in issues[:MAX_LOG_ISSUES]:
        if not isinstance(issue, dict):
            continue
        path = redact(issue.get("path", ""))[:160]
        message = redact(issue.get("message", ""))[:240]
        severity = redact(issue.get("severity", ""))[:40]
        print(f"notary-issue severity={severity} path={path} message={message}", file=sys.stderr)


def staple_app_zip(zip_path: Path, out_dir: Path, source_sha: str, team_id: str) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="floe-bridge-staple-") as temporary:
        root = Path(temporary)
        extract_zip(zip_path, root)
        app = find_single_app(root)
        app_summary = verify_app(app, source_sha, team_id, require_stapled=False)
        run_checked(["xcrun", "stapler", "staple", str(app)], "stapler staple of the app")
        run_checked(["xcrun", "stapler", "validate", str(app)], "stapler validation of the app")
        run_checked(
            ["spctl", "--assess", "--type", "execute", "--verbose=2", str(app)],
            "Gatekeeper assessment of the app",
        )
        destination = out_dir / "Floe-Bridge-stapled.zip"
        if destination.exists():
            raise HelperError("Refusing to overwrite an existing stapled zip")
        run_checked(
            ["ditto", "-c", "-k", "--keepParent", str(app), str(destination)],
            "creation of the stapled app zip",
        )
    payload = {
        "kind": "app-zip",
        "artifact": destination.name,
        "artifactSha256": sha256_file(destination),
        "sourceSha": source_sha,
        "teamId": team_id,
        "app": app_summary,
        "stapled": True,
    }
    write_json(out_dir / "stapled.json", payload)
    return payload


def staple_dmg(dmg_path: Path, out_dir: Path, source_sha: str, team_id: str) -> dict[str, Any]:
    run_checked(["xcrun", "stapler", "staple", str(dmg_path)], "stapler staple of the DMG")
    run_checked(["xcrun", "stapler", "validate", str(dmg_path)], "stapler validation of the DMG")
    run_checked(
        ["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", str(dmg_path)],
        "Gatekeeper assessment of the DMG",
    )
    destination = out_dir / "Floe-Bridge-stapled.dmg"
    if destination.exists():
        raise HelperError("Refusing to overwrite an existing stapled DMG")
    shutil.copy2(dmg_path, destination)
    payload = {
        "kind": "dmg",
        "artifact": destination.name,
        "artifactSha256": sha256_file(destination),
        "sourceSha": source_sha,
        "teamId": team_id,
        "stapled": True,
    }
    write_json(out_dir / "stapled.json", payload)
    return payload


def notarize(args: argparse.Namespace) -> dict[str, Any]:
    artifact = Path(args.artifact).expanduser().resolve()
    out_dir = args.out_dir
    summary = preflight(artifact, args.kind, args.source_sha, args.team_id)
    resolved_kind = summary["kind"]
    write_json(out_dir / "preflight.json", summary)
    print(json.dumps({"preflight": summary}, indent=2, sort_keys=True))
    key = Path(args.key).expanduser().resolve()
    artifact_sha = sha256_file(artifact)
    poll_timeout_seconds = timeout_to_seconds(args.timeout)
    payload = notarytool_submit(artifact, key, args.key_id, args.issuer)
    submission_id = str(payload.get("id") or "")
    if not submission_id:
        raise HelperError("notarytool submit returned no submission ID")
    status = str(payload.get("status") or "Submitted")
    write_submission_receipt(
        out_dir,
        submission_id=submission_id,
        status=status,
        artifact=artifact,
        artifact_sha256=artifact_sha,
        source_sha=args.source_sha,
        team_id=args.team_id,
    )
    print(f"submission-started id={submission_id} status={status}; polling with the same UUID", flush=True)
    info_payload, last_error = poll_submission(
        submission_id,
        lambda: notarytool_info(submission_id, key, args.key_id, args.issuer),
        poll_timeout_seconds,
        args.poll_interval,
    )
    final_status = str(info_payload.get("status") or status)
    if info_payload.get("_pollTimedOut"):
        last_error = info_payload.get("_lastError") or last_error
        write_submission_receipt(
            out_dir,
            submission_id=submission_id,
            status=final_status,
            artifact=artifact,
            artifact_sha256=artifact_sha,
            source_sha=args.source_sha,
            team_id=args.team_id,
            timed_out=True,
            last_error=last_error,
        )
        raise HelperError(
            f"Notarization did not reach a terminal state (last status={final_status}); "
            f"submission {submission_id} was retained. Do not resubmit; use "
            "bridge-notary-resume with this UUID to check and staple an accepted result.",
            exit_code=3,
        )
    if final_status != "Accepted":
        log_payload = notarytool_log(submission_id, key, args.key_id, args.issuer, out_dir / "notary-log.json")
        print_log_issues(log_payload)
        write_submission_receipt(
            out_dir,
            submission_id=submission_id,
            status=final_status,
            artifact=artifact,
            artifact_sha256=artifact_sha,
            source_sha=args.source_sha,
            team_id=args.team_id,
            last_error=f"notary status {final_status}",
        )
        raise HelperError(
            f"Notarization was not accepted (status={final_status}); submission {submission_id} "
            "was retained. Do not resubmit; inspect the retained log.",
            exit_code=2,
        )
    write_submission_receipt(
        out_dir,
        submission_id=submission_id,
        status="Accepted",
        artifact=artifact,
        artifact_sha256=artifact_sha,
        source_sha=args.source_sha,
        team_id=args.team_id,
        stapled=False,
    )
    stapled = (
        staple_app_zip(artifact, out_dir, args.source_sha, args.team_id)
        if resolved_kind == "app-zip"
        else staple_dmg(artifact, out_dir, args.source_sha, args.team_id)
    )
    receipt = write_submission_receipt(
        out_dir,
        submission_id=submission_id,
        status="Accepted",
        artifact=artifact,
        artifact_sha256=artifact_sha,
        source_sha=args.source_sha,
        team_id=args.team_id,
        stapled=True,
    )
    result = {
        "operation": "notarize",
        "artifact": artifact.name,
        "artifactSha256": artifact_sha,
        "sourceSha": args.source_sha,
        "teamId": args.team_id,
        "submissionId": submission_id,
        "status": "Accepted",
        "message": redact(info_payload.get("message", ""))[:500],
        "createdDate": info_payload.get("createdDate"),
        "stapled": stapled,
        "receipt": receipt,
    }
    write_json(out_dir / "notarization.json", result)
    print(json.dumps(result, indent=2, sort_keys=True))
    return result


def notarytool_info(submission_id: str, key: Path, key_id: str, issuer: str) -> dict[str, Any]:
    args = [
        "xcrun",
        "notarytool",
        "info",
        submission_id,
        *notarytool_common(key, key_id, issuer),
        "--output-format",
        "json",
    ]
    result = run_tool(args, timeout=120)
    if result.returncode != 0:
        detail = redact(result.stderr.decode("utf-8", "replace")).strip()[:400]
        raise HelperError(f"notarytool info failed" + (f": {detail}" if detail else ""))
    return parse_json_output(result.stdout, result.stderr, "notarytool info")


def resume(args: argparse.Namespace) -> dict[str, Any]:
    """Check an existing submission; staple the same artifact if Accepted.

    This command never calls notarytool submit.
    """
    if not UUID_RE.fullmatch(args.submission_id):
        raise HelperError("--submission-id must be a notary submission UUID")
    artifact = Path(args.artifact).expanduser().resolve()
    out_dir = args.out_dir
    summary = preflight(artifact, args.kind, args.source_sha, args.team_id)
    resolved_kind = summary["kind"]
    write_json(out_dir / "preflight.json", summary)
    key = Path(args.key).expanduser().resolve()
    artifact_sha = sha256_file(artifact)
    payload = notarytool_info(args.submission_id, key, args.key_id, args.issuer)
    status = str(payload.get("status") or "")
    submission_sha = str(payload.get("sha256") or "").lower()
    if submission_sha and submission_sha != artifact_sha:
        raise HelperError(
            f"Submission {args.submission_id} is bound to a different artifact SHA-256; "
            "refusing to staple this artifact",
            exit_code=2,
        )
    write_submission_receipt(
        out_dir,
        submission_id=args.submission_id,
        status=status or "Unknown",
        artifact=artifact,
        artifact_sha256=artifact_sha,
        source_sha=args.source_sha,
        team_id=args.team_id,
    )
    if status == "Accepted":
        stapled = (
            staple_app_zip(artifact, out_dir, args.source_sha, args.team_id)
            if resolved_kind == "app-zip"
            else staple_dmg(artifact, out_dir, args.source_sha, args.team_id)
        )
        receipt = write_submission_receipt(
            out_dir,
            submission_id=args.submission_id,
            status="Accepted",
            artifact=artifact,
            artifact_sha256=artifact_sha,
            source_sha=args.source_sha,
            team_id=args.team_id,
            stapled=True,
        )
        result = {
            "operation": "resume",
            "submissionId": args.submission_id,
            "status": "Accepted",
            "artifact": artifact.name,
            "artifactSha256": artifact_sha,
            "sourceSha": args.source_sha,
            "teamId": args.team_id,
            "stapled": stapled,
            "receipt": receipt,
        }
        write_json(out_dir / "resume.json", result)
        print(json.dumps(result, indent=2, sort_keys=True))
        return result
    if status in ("Invalid", "Rejected"):
        log_payload = notarytool_log(args.submission_id, key, args.key_id, args.issuer, out_dir / "notary-log.json")
        print_log_issues(log_payload)
        write_json(out_dir / "resume.json", {"operation": "resume", "submissionId": args.submission_id, "status": status})
        raise HelperError(
            f"Submission {args.submission_id} is {status}; no staple was performed. Do not resubmit.",
            exit_code=2,
        )
    write_json(out_dir / "resume.json", {"operation": "resume", "submissionId": args.submission_id, "status": status or "Unknown"})
    raise HelperError(
        f"Submission {args.submission_id} is not accepted (status={status or 'unknown'}); "
        "no staple was performed. Re-run resume later; do not submit again.",
        exit_code=3,
    )


def status(args: argparse.Namespace) -> dict[str, Any]:
    if not UUID_RE.fullmatch(args.submission_id):
        raise HelperError("--submission-id must be a notary submission UUID")
    key = Path(args.key).expanduser().resolve()
    payload = notarytool_info(args.submission_id, key, args.key_id, args.issuer)
    summary = {
        "submissionId": args.submission_id,
        "status": payload.get("status"),
        "message": redact(payload.get("message", ""))[:500],
        "createdDate": payload.get("createdDate"),
    }
    write_json(args.out_dir / "status.json", summary)
    if args.log:
        log_payload = notarytool_log(args.submission_id, key, args.key_id, args.issuer, args.out_dir / "notary-log.json")
        print_log_issues(log_payload)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return summary


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    subparsers = parser.add_subparsers(dest="command", required=True)

    for name in ("preflight", "notarize", "resume"):
        sub = subparsers.add_parser(name)
        sub.add_argument("--artifact", required=True, help="Signed app zip or signed/notarizable DMG")
        sub.add_argument("--kind", choices=("auto", "app-zip", "dmg"), default="auto")
        sub.add_argument("--source-sha", required=True)
        sub.add_argument("--team-id", required=True)
        sub.add_argument("--out-dir", required=True)
        if name in ("notarize", "resume"):
            sub.add_argument("--key", required=True, help="App Store Connect API private key path")
            sub.add_argument("--key-id", required=True)
            sub.add_argument("--issuer", required=True)
        if name == "notarize":
            sub.add_argument("--timeout", default="30m", help="Poll deadline after the submission is started")
            sub.add_argument("--poll-interval", type=int, default=15, help="Seconds between status checks")
        if name == "resume":
            sub.add_argument("--submission-id", required=True)

    status_parser = subparsers.add_parser("status")
    status_parser.add_argument("--submission-id", required=True)
    status_parser.add_argument("--key", required=True)
    status_parser.add_argument("--key-id", required=True)
    status_parser.add_argument("--issuer", required=True)
    status_parser.add_argument("--out-dir", required=True)
    status_parser.add_argument("--log", action="store_true")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    args.out_dir = Path(args.out_dir).expanduser().resolve()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    try:
        if args.command == "preflight":
            artifact = Path(args.artifact).expanduser().resolve()
            summary = preflight(artifact, args.kind, args.source_sha, args.team_id)
            write_json(args.out_dir / "preflight.json", summary)
            print(json.dumps(summary, indent=2, sort_keys=True))
            return 0
        if args.command == "notarize":
            if not 1 <= args.poll_interval <= 300:
                raise HelperError("--poll-interval must be between 1 and 300 seconds")
            notarize(args)
            return 0
        if args.command == "resume":
            resume(args)
            return 0
        if args.command == "status":
            status(args)
            return 0
        raise HelperError("Unsupported command")
    except HelperError as error:
        failure = {
            "operation": args.command,
            "message": redact(error.message),
            "checkedAt": now_iso(),
        }
        write_json(args.out_dir / "error.json", failure)
        print(f"error: {failure['message']}", file=sys.stderr)
        return error.exit_code
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
