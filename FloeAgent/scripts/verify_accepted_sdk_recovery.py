#!/usr/bin/env python3
"""Strict verification for the accepted-SDK (Xcode 26.6) release recovery.

A release can reach the App Store accepted toolchain, produce a retained
unsigned device application and pass the focused App regressions, then lose its
runner to a per-step timeout while a later UI leg is still running. The
accepted-SDK distribution input is then never staged even though everything
before it is valid.

This helper makes the recovery trustworthy before anything is rebuilt, signed
or uploaded:

* ``source-run`` proves that the reused device and App-diagnostics artifacts
  really belong to the same push of the same tag at the same commit and attempt
  in this repository, that the SDK 27 sibling job passed, that every required
  accepted-SDK step succeeded, that the Notes qualification is present either as
  the legacy single step or as both per-device steps, that at least one step
  failed, that the three staging steps are still skipped, and that the pinned
  artifact ids and digests match. It refuses a run that already produced a
  distribution input.
* ``device-archive`` proves the retained device zip matches its recorded
  SHA-256, extracts it with traversal-safe bounds, and proves the payload is the
  unsigned pre-normalization application with the expected bundle id, version
  and build.

The archive code deliberately mirrors the vetted traversal/link/size policy of
``verify_compiled_test_host.safe_extract``; that module stays the single place
where the tar policy lives, while ZIP members are validated with the same
semantics before a single byte is written.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import posixpath
import re
import stat
import sys
import zipfile
from pathlib import Path

TRUSTED_REPOSITORY = "JiangNanGenius/floe-agent"
TRUSTED_WORKFLOW_PATH = ".github/workflows/release-unsigned-ipa.yml"
TRUSTED_EVENT = "push"
SDK27_JOB = "build-verify-release"
ACCEPTED_JOB = "Qualify and build the accepted SDK in parallel"
# Older tags ran both devices inside one Notes step. Newer tags split them so
# one device can never consume the other's budget; both shapes are valid source
# evidence and the recovery must accept either without loosening any other
# check. The per-device names match release-unsigned-ipa.yml and the recovery
# workflow itself.
NOTES_STEP = "Require iPad and iPhone Notes import with the accepted SDK"
NOTES_IPAD_STEP = "Require Notes import on the iPad simulator with the accepted SDK"
NOTES_IPHONE_STEP = "Require Notes import on the iPhone simulator with the accepted SDK"
NOTES_PER_DEVICE_STEPS = (NOTES_IPAD_STEP, NOTES_IPHONE_STEP)
# The accepted-SDK job must have reached staging; these three steps stay skipped
# because the Notes timeout aborted the job before them.
STAGING_STEPS = (
    "Normalize reviewed App Store bundle defects before signing",
    "Stage the qualified accepted-SDK application without rebuilding it",
    "Retain the accepted-SDK distribution input",
)
# Every step that must have completed successfully before the artifact is trusted.
REQUIRED_ACCEPTED_STEPS = (
    "Rebuild the exact tag with the accepted App Store SDK",
    "Preserve the completed device build before simulator qualification",
    "Retain the device build even if later qualification fails",
    "Build accepted-SDK simulator test hosts once",
    "Verify focused app regressions with the accepted App Store SDK",
    "Preserve accepted-SDK App regression diagnostics",
)
DEVICE_ARTIFACT_PREFIX = "accepted-sdk-device-recovery-"
DIAGNOSTICS_ARTIFACT_PREFIX = "accepted-sdk-app-diagnostics-"
INPUT_ARTIFACT_PREFIX = "accepted-sdk-input-"
DEVICE_ZIP_NAME = "accepted-sdk-device-recovery.zip"
RECOVERY_STAGE = "unsigned_device_build_before_normalization_and_tests"
BUNDLE_ID = "org.floeagent.ios"

MAX_ZIP_MEMBERS = 400_000
MAX_ZIP_UNCOMPRESSED_BYTES = 16 * 1024 * 1024 * 1024
_FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_DRIVE = re.compile(r"^[A-Za-z]:")


class RecoveryVerificationError(ValueError):
    """The reused evidence is not a trusted, intact accepted-SDK artifact."""


def _require(condition: object, message: str) -> None:
    if not condition:
        raise RecoveryVerificationError(message)


def _normalize_digest(value: object, label: str) -> str:
    text = str(value or "").strip().lower()
    if text.startswith("sha256:"):
        text = text[len("sha256:"):]
    _require(bool(_SHA256.match(text)), f"{label} is not a SHA-256 digest")
    return text


def device_artifact_name(version: str, build: str) -> str:
    return f"{DEVICE_ARTIFACT_PREFIX}{version}-build{build}"


def diagnostics_artifact_name(version: str, build: str) -> str:
    return f"{DIAGNOSTICS_ARTIFACT_PREFIX}{version}-build{build}"


def input_artifact_name(version: str, build: str) -> str:
    return f"{INPUT_ARTIFACT_PREFIX}{version}-build{build}"


def _one(items, predicate, message):
    matches = [item for item in items if isinstance(item, dict) and predicate(item)]
    _require(len(matches) == 1, message)
    return matches[0]


def _resolve_notes_steps(steps: dict) -> dict:
    """Return the Notes step records for either the legacy or split shape.

    A tag released before the per-device split has one ``NOTES_STEP``; a newer
    tag has one step per simulator. Accepting both keeps already-retained build
    179 evidence verifiable while new releases get stricter per-device gating.
    Mixing the two shapes, or dropping one per-device leg, is refused so a
    partial run cannot pass as complete.
    """
    present: dict = {}
    legacy = steps.get(NOTES_STEP)
    if legacy is not None:
        present[NOTES_STEP] = legacy
    for name in NOTES_PER_DEVICE_STEPS:
        step = steps.get(name)
        if step is not None:
            present[name] = step
    _require(present,
             "missing Notes step: neither the legacy Notes step nor the "
             "per-device Notes steps are present")
    if legacy is not None:
        _require(len(present) == 1,
                 "the accepted-SDK job mixes the legacy single Notes step with "
                 "per-device Notes steps")
    else:
        missing = [name for name in NOTES_PER_DEVICE_STEPS if name not in present]
        _require(not missing,
                 f"the accepted-SDK job is missing per-device Notes step(s): {missing}")
    return present


def _artifact_run_id(artifact: dict):
    """Return the owning run id from either real API or flattened metadata.

    The live ``actions/runs/<id>/artifacts`` payload nests the owner as
    ``workflow_run.id``; the workflow's own metadata builder flattens it to
    ``workflow_run_id``. Accepting the nested field is what makes the check run
    against the real API instead of only against a mirrored fixture.
    """
    owner = artifact.get("workflow_run")
    if isinstance(owner, dict):
        return owner.get("id")
    return artifact.get("workflow_run_id")


def verify_source_run(run: dict, jobs_response: dict, artifacts_response: dict, *,
                      source_sha: str, source_run: str, source_attempt: str,
                      tag: str, version: str, build: str,
                      device_artifact_id: int, device_artifact_digest: str,
                      diagnostics_artifact_id: int,
                      diagnostics_artifact_digest: str,
                      repository: str = TRUSTED_REPOSITORY,
                      workflow_path: str = TRUSTED_WORKFLOW_PATH) -> dict:
    """Prove the reused artifacts came from the exact trusted release attempt."""
    _require(isinstance(run, dict), "run metadata must be a JSON object")
    _require(bool(_FULL_SHA.match(source_sha or "")),
             "source SHA must be a full 40-hex lowercase commit")
    _require(str(source_run).isdigit() and int(source_run) > 0,
             "source run must be a positive integer")
    _require(str(source_attempt).isdigit() and int(source_attempt) >= 1,
             "source attempt must be a positive integer")
    _require(str(version) == version and version, "version must be a non-empty string")
    _require(str(build).isdigit() and int(build) > 0, "build must be a positive integer")

    _require(run.get("repository", {}).get("full_name") == repository,
             f"run does not belong to the trusted repository {repository}")
    _require(run.get("head_repository", {}).get("full_name") == repository,
             f"run head repository is not the trusted repository {repository}")
    _require(run.get("path", "").split("@")[0] == workflow_path,
             f"run is not the trusted workflow {workflow_path}")
    _require(run.get("event") == TRUSTED_EVENT,
             f"run event {run.get('event')!r} is not a trusted push")
    _require(run.get("head_branch") == tag,
             "run head branch is not the requested release tag")
    _require(run.get("head_sha") == source_sha,
             "run head SHA does not match the requested full source SHA")
    _require(str(run.get("id")) == str(source_run), "run id does not match the request")
    _require(str(run.get("run_attempt")) == str(source_attempt),
             "run attempt does not match the request")
    _require(run.get("status") == "completed" and run.get("conclusion") == "failure",
             "the source run must be the completed failed release run")

    jobs = jobs_response.get("jobs") if isinstance(jobs_response, dict) else jobs_response
    _require(isinstance(jobs, list) and jobs, "jobs response has no jobs")
    artifacts = (artifacts_response.get("artifacts")
                 if isinstance(artifacts_response, dict) else artifacts_response)
    _require(isinstance(artifacts, list), "artifacts response has no artifacts")

    sdk27 = _one(jobs, lambda job: job.get("name") == SDK27_JOB,
                 f"expected exactly one {SDK27_JOB} job")
    _require(sdk27.get("conclusion") == "success",
             "the SDK 27 sibling job did not succeed")
    accepted = _one(jobs, lambda job: job.get("name") == ACCEPTED_JOB,
                    f"expected exactly one {ACCEPTED_JOB} job")
    _require(accepted.get("conclusion") == "failure",
             "the accepted-SDK job must be the failed source of this recovery")

    steps = {step.get("name"): step for step in (accepted.get("steps") or [])
             if isinstance(step, dict)}
    for name in REQUIRED_ACCEPTED_STEPS:
        step = steps.get(name)
        _require(step is not None, f"required accepted-SDK step is missing: {name}")
        _require(step.get("conclusion") == "success",
                 f"required accepted-SDK step did not succeed: {name}")
    notes_steps = _resolve_notes_steps(steps)
    # The recovery re-runs the Notes legs from the tagged source, so the source
    # Notes step(s) may have passed or failed. What matters is that the job failed
    # before staging; record every failed step as evidence instead of assuming
    # which gate timed out.
    failed_steps = [name for name, step in steps.items()
                    if step.get("conclusion") in ("failure", "timed_out")]
    _require(failed_steps,
             "the accepted-SDK job has no failed step; nothing needs recovery")
    for name in STAGING_STEPS:
        step = steps.get(name)
        _require(step is not None, f"staging step is missing: {name}")
        _require(step.get("conclusion") == "skipped",
                 f"staging step {name} is not skipped; a distribution input may already exist")
    # A completed distribution input in the source run means there is nothing to
    # recover and the caller must not re-sign or re-upload.
    input_name = input_artifact_name(version, build)
    _require(not [item for item in artifacts
                  if isinstance(item, dict) and item.get("name") == input_name],
             f"{input_name} already exists; the source run was not incomplete")

    def pinned(prefix: str, wanted_id: int, digest: str, label: str) -> dict:
        name = f"{prefix}{version}-build{build}"
        artifact = _one(artifacts, lambda item: item.get("name") == name,
                        f"expected exactly one artifact named {name}")
        _require(artifact.get("expired") is False, f"{label} artifact is expired")
        _require(str(_artifact_run_id(artifact)) == str(run.get("id")),
                 f"{label} artifact does not belong to the requested run")
        _require(int(artifact.get("id") or 0) == int(wanted_id),
                 f"{label} artifact id does not match the pinned request")
        actual_digest = _normalize_digest(artifact.get("digest"), f"{label} artifact digest")
        _require(actual_digest == _normalize_digest(digest, f"pinned {label} digest"),
                 f"{label} artifact digest does not match the pinned digest")
        _require(int(artifact.get("size_in_bytes") or 0) > 0,
                 f"{label} artifact is empty")
        return {"id": int(artifact["id"]), "name": name, "digest": actual_digest,
                "size_in_bytes": int(artifact["size_in_bytes"])}

    device = pinned(DEVICE_ARTIFACT_PREFIX, device_artifact_id,
                    device_artifact_digest, "device-recovery")
    diagnostics = pinned(DIAGNOSTICS_ARTIFACT_PREFIX, diagnostics_artifact_id,
                         diagnostics_artifact_digest, "app-diagnostics")
    return {
        "repository": repository,
        "workflow_path": workflow_path,
        "event": TRUSTED_EVENT,
        "head_branch": tag,
        "head_sha": source_sha,
        "run_id": int(source_run),
        "run_attempt": int(source_attempt),
        "run_conclusion": "failure",
        "sdk27_job_id": int(sdk27.get("id") or 0),
        "accepted_sdk_job_id": int(accepted.get("id") or 0),
        "failed_steps": sorted(failed_steps),
        "notes_steps": {name: step.get("conclusion")
                        for name, step in notes_steps.items()},
        "notes_step_conclusion": ("failure"
                                  if any(step.get("conclusion") in ("failure", "timed_out")
                                         for step in notes_steps.values())
                                  else "success"),
        "device_artifact": device,
        "diagnostics_artifact": diagnostics,
        "policy": ("reuse the accepted-SDK device build and App diagnostics; "
                   "rebuild only the simulator test host"),
    }


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _within(dest: Path, candidate: Path) -> bool:
    return candidate == dest or dest in candidate.parents


def _validate_zip_member(info: zipfile.ZipInfo, dest: Path, seen: set) -> str:
    raw = info.filename
    _require(isinstance(raw, str) and raw != "", "archive member has an empty name")
    _require("\x00" not in raw, "archive member name contains a NUL byte")
    _require(not raw.startswith(("/", "\\")), f"archive member {raw!r} is absolute")
    _require(not _DRIVE.match(raw), f"archive member {raw!r} has a drive prefix")
    _require("\\" not in raw, f"archive member {raw!r} uses a backslash path separator")
    mode = info.external_attr >> 16
    _require(not stat.S_ISLNK(mode), f"archive member {raw!r} is a symbolic link")
    _require(stat.S_IFMT(mode) in (0, stat.S_IFREG, stat.S_IFDIR),
             f"archive member {raw!r} is not a regular file or directory")
    parts = [part for part in raw.rstrip("/").split("/") if part not in ("", ".")]
    _require(parts and ".." not in parts,
             f"archive member {raw!r} escapes the extraction directory")
    normalized = posixpath.join(*parts)
    _require(normalized not in seen,
             f"archive member {raw!r} repeats the normalized path {normalized!r}")
    target = dest.joinpath(*parts)
    _require(_within(dest, target.resolve()),
             f"archive member {raw!r} escapes the extraction directory")
    seen.add(normalized)
    return normalized


def safe_extract_zip(zip_path: Path, dest: Path) -> int:
    """Extract a validated ZIP archive and return the member count.

    Mirrors ``verify_compiled_test_host.safe_extract``: only regular files and
    directories are accepted, every symlink/device/FIFO/special member is
    rejected before any byte is written, duplicate normalized names are refused,
    and absolute/``..``/NUL/drive/backslash names and members resolving outside
    the destination are rejected up front. The destination must be empty.
    """
    zip_path = Path(zip_path)
    dest = Path(dest)
    _require(zip_path.is_file(), f"{zip_path.name} is missing")
    if dest.exists():
        _require(dest.is_dir() and not any(dest.iterdir()),
                 f"extraction directory {dest} must be empty")
    else:
        dest.mkdir(parents=True)
    dest = dest.resolve()

    with zipfile.ZipFile(zip_path) as archive:
        members = archive.infolist()
        _require(0 < len(members) <= MAX_ZIP_MEMBERS,
                 f"archive has {len(members)} members, outside the allowed range")
        seen: set = set()
        total = 0
        for info in members:
            _validate_zip_member(info, dest, seen)
            total += max(info.file_size, 0)
            _require(total <= MAX_ZIP_UNCOMPRESSED_BYTES,
                     "archive expands beyond the allowed uncompressed size")
        # Validation already refused every non-file/directory member.
        archive.extractall(dest, members=members)
    return len(members)


def verify_device_archive(artifact_dir: Path, *, source_sha: str, version: str,
                          build: str, extract_dir: Path,
                          device_zip_name: str = DEVICE_ZIP_NAME) -> dict:
    """Prove the retained device zip is intact and holds the expected app."""
    artifact_dir = Path(artifact_dir)
    _require(artifact_dir.is_dir(),
             f"artifact directory {artifact_dir} does not exist")
    zips = sorted(path for path in artifact_dir.iterdir()
                  if path.is_file() and path.name == device_zip_name)
    _require(len(zips) == 1,
             f"expected exactly one {device_zip_name} in the downloaded artifact")
    zip_path = zips[0]
    digest = _sha256(zip_path)
    sidecar = artifact_dir / f"{device_zip_name}.sha256"
    _require(sidecar.is_file(), f"{device_zip_name}.sha256 is missing")
    recorded = _normalize_digest(sidecar.read_text(encoding="utf-8").split()[0],
                                 "device zip sidecar digest")
    _require(digest == recorded,
             "device zip does not match its recorded SHA-256 sidecar")

    entries = safe_extract_zip(zip_path, Path(extract_dir))
    payload = Path(extract_dir).resolve() / "FloeSignedPayload"
    _require(payload.is_dir(), "device zip did not contain FloeSignedPayload")
    _require((payload / "SOURCE-SHA.txt").is_file(),
             "device zip did not record SOURCE-SHA.txt")
    _require((payload / "SOURCE-SHA.txt").read_text(encoding="utf-8").strip() == source_sha,
             "device zip SOURCE-SHA.txt does not match the requested source SHA")
    stage_file = payload / "RECOVERY-STAGE.txt"
    _require(stage_file.is_file(), "device zip did not record RECOVERY-STAGE.txt")
    stage = stage_file.read_text(encoding="utf-8").strip()
    _require(stage == RECOVERY_STAGE,
             f"device zip recovery stage {stage!r} is not the pre-normalization device build")

    apps = sorted(path for path in (payload / "Payload").glob("*.app")
                  if path.is_dir() and not path.is_symlink())
    _require(len(apps) == 1,
             f"device zip must contain exactly one top-level .app, found {len(apps)}")
    app = apps[0].resolve()
    _require(_within(payload.resolve(), app),
             "application path escaped the extracted device payload")
    info_path = app / "Info.plist"
    _require(info_path.is_file(), "application is missing Info.plist")
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    _require(info.get("CFBundleIdentifier") == BUNDLE_ID,
             "application bundle identifier is not org.floeagent.ios")
    _require(info.get("CFBundleShortVersionString") == version,
             "application marketing version does not match the release")
    _require(info.get("CFBundleVersion") == build,
             "application build number does not match the release")
    # The retained device application must have been built with an iOS 26 SDK
    # (the App Store accepted Xcode 26.6 toolchain), not a newer SDK.
    dtsdk = info.get("DTSDKName")
    if dtsdk is not None:
        _require(str(dtsdk).startswith("iphoneos26."),
                 f"application was not built with an iOS 26 SDK: {dtsdk!r}")
    _require(not (app / "embedded.mobileprovision").exists(),
             "retained device build unexpectedly contains a provisioning profile")
    _require(not (app / "_CodeSignature").exists(),
             "retained device build is already signed")

    return {
        "device_zip_sha256": digest,
        "entries": entries,
        "app_path": str(app),
        "bundle_id": BUNDLE_ID,
        "version": version,
        "build": build,
        "recovery_stage": stage,
    }


def _append_output(path: str, key: str, value: str) -> None:
    _require("\n" not in value and "\r" not in value,
             f"refusing to write a multiline {key} to GITHUB_OUTPUT")
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(f"{key}={value}\n")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    source = subparsers.add_parser("source-run", help="verify trusted run provenance")
    source.add_argument("--run", required=True)
    source.add_argument("--jobs", required=True)
    source.add_argument("--artifacts", required=True)
    source.add_argument("--source-sha", required=True)
    source.add_argument("--source-run", required=True)
    source.add_argument("--source-attempt", default="1")
    source.add_argument("--tag", required=True)
    source.add_argument("--version", required=True)
    source.add_argument("--build", required=True)
    source.add_argument("--device-artifact-id", required=True, type=int)
    source.add_argument("--device-artifact-digest", required=True)
    source.add_argument("--diagnostics-artifact-id", required=True, type=int)
    source.add_argument("--diagnostics-artifact-digest", required=True)
    source.add_argument("--repository", default=TRUSTED_REPOSITORY)
    source.add_argument("--workflow-path", default=TRUSTED_WORKFLOW_PATH)
    source.add_argument("--report", default="")

    device = subparsers.add_parser("device-archive",
                                   help="verify and safely extract the retained device zip")
    device.add_argument("--artifact-dir", required=True)
    device.add_argument("--source-sha", required=True)
    device.add_argument("--version", required=True)
    device.add_argument("--build", required=True)
    device.add_argument("--extract-dir", required=True)
    device.add_argument("--device-zip-name", default=DEVICE_ZIP_NAME)
    device.add_argument("--report", default="")
    device.add_argument("--github-output", default="")

    args = parser.parse_args(argv)
    try:
        if args.command == "source-run":
            report = verify_source_run(
                json.loads(Path(args.run).read_text(encoding="utf-8")),
                json.loads(Path(args.jobs).read_text(encoding="utf-8")),
                json.loads(Path(args.artifacts).read_text(encoding="utf-8")),
                source_sha=args.source_sha,
                source_run=args.source_run,
                source_attempt=args.source_attempt,
                tag=args.tag,
                version=args.version,
                build=args.build,
                device_artifact_id=args.device_artifact_id,
                device_artifact_digest=args.device_artifact_digest,
                diagnostics_artifact_id=args.diagnostics_artifact_id,
                diagnostics_artifact_digest=args.diagnostics_artifact_digest,
                repository=args.repository,
                workflow_path=args.workflow_path,
            )
        else:
            report = verify_device_archive(
                Path(args.artifact_dir),
                source_sha=args.source_sha,
                version=args.version,
                build=args.build,
                extract_dir=Path(args.extract_dir),
                device_zip_name=args.device_zip_name,
            )
    except (RecoveryVerificationError, json.JSONDecodeError,
            plistlib.InvalidFileException, OSError) as error:
        print(f"accepted-SDK recovery verification failed: {error}", file=sys.stderr)
        return 1

    if args.report:
        Path(args.report).write_text(json.dumps(report, indent=2) + "\n",
                                     encoding="utf-8")
    if getattr(args, "github_output", "") and args.command == "device-archive":
        _append_output(args.github_output, "app_path", report["app_path"])
        _append_output(args.github_output, "device_zip_sha256",
                       report["device_zip_sha256"])
    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
