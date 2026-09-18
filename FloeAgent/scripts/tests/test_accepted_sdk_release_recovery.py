"""Fixture and control-flow checks for the accepted-SDK release recovery.

These tests pin the recovery contract:

* ``verify_accepted_sdk_recovery.py`` accepts only the exact trusted failed
  release run of the requested tag/commit/attempt, requires every pre-stage step
  to have succeeded, requires the staging steps to still be skipped, and pins
  both artifact ids and digests. It never hardcodes a version, build or test
  count, so the same controller serves a later tag.
* the device zip is restored with the same traversal/link/size policy as the
  vetted compiled-host extractor; a traversal, link, duplicate, oversized or
  wrong-bundle archive is refused before signing.
* the workflow checks out the source tag and uses that tag's original Notes
  selector and verifier, runs each device in its own 25-minute step, and never
  writes a release, tag or TestFlight upload outside the dedicated sign job.
* the per-device shell loop is executed for real with controlled test drivers:
  a passing run reaches the strict verifier, a verifier failure fails the leg, a
  real test failure is never retried into a pass, and only a stall *before any
  test started* gets a second attempt.
"""
from __future__ import annotations

import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest
import zipfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import bind_notes_scope  # noqa: E402
import verify_accepted_sdk_recovery as recovery  # noqa: E402
import verify_compiled_test_host as host  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "accepted-sdk-release-recovery.yml"

SOURCE_SHA = "a510ea6df8ff4a366e237ad5bad3410e5023c92b"
SOURCE_RUN = "35228451173"
SOURCE_ATTEMPT = "1"
TAG = "v1.7.0-beta.36"
VERSION = "1.7.0"
BUILD = "179"
DEVICE_ID = 10501886517
DEVICE_DIGEST = "sha256:e8c408771aa8537bd35f92012e52ecf536e3a45562a369029b7bd39a94ed1db6"
DIAGNOSTICS_ID = 10503430246
DIAGNOSTICS_DIGEST = "sha256:7880883dcace0877ba7a39c1be505669b1dc8461ff2fc4ae9a450e617f7418ad"
HOST_SHA = "1" * 40


def run_metadata(**overrides) -> dict:
    base = {
        "repository": {"full_name": recovery.TRUSTED_REPOSITORY},
        "head_repository": {"full_name": recovery.TRUSTED_REPOSITORY},
        "path": recovery.TRUSTED_WORKFLOW_PATH,
        "event": "push",
        "head_branch": TAG,
        "head_sha": SOURCE_SHA,
        "id": int(SOURCE_RUN),
        "run_attempt": int(SOURCE_ATTEMPT),
        "status": "completed",
        "conclusion": "failure",
    }
    base.update(overrides)
    return base


def accepted_steps(**conclusions) -> list:
    names = list(recovery.REQUIRED_ACCEPTED_STEPS) + [
        recovery.NOTES_STEP, *recovery.STAGING_STEPS]
    steps = []
    for name in names:
        if name in conclusions:
            value = conclusions[name]
        elif name in recovery.REQUIRED_ACCEPTED_STEPS:
            value = "success"
        elif name == recovery.NOTES_STEP:
            value = "failure"
        else:
            value = "skipped"
        steps.append({"name": name, "status": "completed", "conclusion": value})
    return steps


def accepted_steps_per_device(**conclusions) -> list:
    """The newer shape: one Notes step per simulator, no shared budget."""
    names = list(recovery.REQUIRED_ACCEPTED_STEPS) + [
        *recovery.NOTES_PER_DEVICE_STEPS, *recovery.STAGING_STEPS]
    steps = []
    for name in names:
        if name in conclusions:
            value = conclusions[name]
        elif name in recovery.REQUIRED_ACCEPTED_STEPS:
            value = "success"
        elif name == recovery.NOTES_IPAD_STEP:
            value = "failure"
        elif name == recovery.NOTES_IPHONE_STEP:
            value = "success"
        else:
            value = "skipped"
        steps.append({"name": name, "status": "completed", "conclusion": value})
    return steps


def jobs_with_accepted_steps(accepted: list, *, conclusion: str = "failure") -> dict:
    return {
        "jobs": [
            {"id": 111, "name": recovery.SDK27_JOB, "conclusion": "success",
             "steps": []},
            {"id": 222, "name": recovery.ACCEPTED_JOB, "conclusion": conclusion,
             "steps": accepted},
        ]
    }


def jobs_response(**overrides) -> dict:
    base = {
        "jobs": [
            {"id": 111, "name": recovery.SDK27_JOB, "conclusion": "success",
             "steps": []},
            {"id": 222, "name": recovery.ACCEPTED_JOB, "conclusion": "failure",
             "steps": accepted_steps()},
        ]
    }
    base.update(overrides)
    return base


def artifacts_response(*, device_id=DEVICE_ID, device_digest=DEVICE_DIGEST,
                       diagnostics_id=DIAGNOSTICS_ID,
                       diagnostics_digest=DIAGNOSTICS_DIGEST,
                       extra=()) -> dict:
    # The live actions/runs/<id>/artifacts API nests the owner run as
    # workflow_run.id; use that exact shape so the fixture cannot hide a
    # mismatch that only appears against GitHub.
    owner = {"id": int(SOURCE_RUN), "head_sha": SOURCE_SHA, "head_branch": TAG}
    return {"artifacts": [
        {"id": device_id,
         "name": recovery.device_artifact_name(VERSION, BUILD),
         "expired": False, "workflow_run": owner,
         "digest": device_digest, "size_in_bytes": 802999588},
        {"id": diagnostics_id,
         "name": recovery.diagnostics_artifact_name(VERSION, BUILD),
         "expired": False, "workflow_run": owner,
         "digest": diagnostics_digest, "size_in_bytes": 459254},
        *extra,
    ]}


class SourceRunVerificationTests(unittest.TestCase):
    def verify(self, run=None, jobs=None, artifacts=None, **overrides):
        kwargs = dict(
            source_sha=SOURCE_SHA, source_run=SOURCE_RUN,
            source_attempt=SOURCE_ATTEMPT, tag=TAG, version=VERSION, build=BUILD,
            device_artifact_id=DEVICE_ID, device_artifact_digest=DEVICE_DIGEST,
            diagnostics_artifact_id=DIAGNOSTICS_ID,
            diagnostics_artifact_digest=DIAGNOSTICS_DIGEST)
        kwargs.update(overrides)
        return recovery.verify_source_run(
            run if run is not None else run_metadata(),
            jobs if jobs is not None else jobs_response(),
            artifacts if artifacts is not None else artifacts_response(),
            **kwargs)

    def test_trusted_failed_release_passes(self):
        report = self.verify()
        self.assertEqual(report["run_id"], int(SOURCE_RUN))
        self.assertEqual(report["head_branch"], TAG)
        self.assertEqual(report["device_artifact"]["id"], DEVICE_ID)
        self.assertEqual(report["diagnostics_artifact"]["id"], DIAGNOSTICS_ID)
        self.assertEqual(report["failed_steps"], [recovery.NOTES_STEP])

    def test_same_run_for_a_different_tag_or_commit_is_rejected(self):
        # The build 179 package must never be paired with another tag, commit or
        # version, which is exactly what would silently mis-attribute evidence.
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(run_metadata(head_branch="v1.7.0-beta.37"))
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(run_metadata(head_sha="f" * 40))
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(version="1.7.1")
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(build="180")

    def test_other_repository_or_workflow_is_rejected(self):
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(run_metadata(repository={"full_name": "attacker/floe"}))
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(run_metadata(head_repository={"full_name": "attacker/floe"}))
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(run_metadata(path=".github/workflows/fork.yml"))

    def test_untrusted_events_and_successful_runs_are_rejected(self):
        for event in ("pull_request", "workflow_run", "schedule", "workflow_dispatch"):
            with self.subTest(event=event):
                with self.assertRaises(recovery.RecoveryVerificationError):
                    self.verify(run_metadata(event=event))
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(run_metadata(conclusion="success"))

    def test_run_id_and_attempt_must_match(self):
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(run_metadata(id=int(SOURCE_RUN) + 1))
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(run_metadata(run_attempt=2))

    def test_sdk27_sibling_job_must_have_succeeded(self):
        jobs = jobs_response()
        jobs["jobs"][0]["conclusion"] = "failure"
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(jobs=jobs)
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(jobs={"jobs": jobs["jobs"][1:]})

    def test_missing_or_failed_prerequisite_step_is_rejected(self):
        jobs = jobs_response()
        jobs["jobs"][1]["steps"] = jobs["jobs"][1]["steps"][1:]
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(jobs=jobs)
        failed = jobs_response()
        for step in failed["jobs"][1]["steps"]:
            if step["name"] == "Rebuild the exact tag with the accepted App Store SDK":
                step["conclusion"] = "failure"
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(jobs=failed)

    def test_staging_step_that_still_succeeded_is_rejected(self):
        # A completed staging step means the distribution input may already
        # exist, so recovery must refuse rather than sign it twice.
        for name in recovery.STAGING_STEPS:
            with self.subTest(name=name):
                jobs = jobs_response()
                for step in jobs["jobs"][1]["steps"]:
                    if step["name"] == name:
                        step["conclusion"] = "success"
                with self.assertRaises(recovery.RecoveryVerificationError):
                    self.verify(jobs=jobs)

    def test_existing_distribution_input_artifact_is_rejected(self):
        existing = {"id": 5, "name": recovery.input_artifact_name(VERSION, BUILD),
                    "expired": False, "workflow_run_id": int(SOURCE_RUN),
                    "digest": "sha256:" + "a" * 64, "size_in_bytes": 1}
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifacts=artifacts_response(extra=(existing,)))

    def test_artifact_id_and_digest_are_pinned(self):
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifacts=artifacts_response(device_id=DEVICE_ID + 1))
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifacts=artifacts_response(device_digest="sha256:" + "b" * 64))
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifacts=artifacts_response(diagnostics_id=1))
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifacts=artifacts_response(diagnostics_digest="not-a-digest"))

    def test_expired_or_foreign_artifact_is_rejected(self):
        artifacts = artifacts_response()
        artifacts["artifacts"][0]["expired"] = True
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifacts=artifacts)
        artifacts = artifacts_response()
        artifacts["artifacts"][0]["workflow_run"] = {"id": int(SOURCE_RUN) + 1}
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifacts=artifacts)
        # A flattened workflow_run_id (the recovery workflow's own builder) is
        # still accepted, but must belong to the requested run.
        artifacts = artifacts_response()
        for artifact in artifacts["artifacts"]:
            artifact["workflow_run_id"] = artifact.pop("workflow_run")["id"]
        self.verify(artifacts=artifacts)
        artifacts["artifacts"][0]["workflow_run_id"] = int(SOURCE_RUN) + 1
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifacts=artifacts)

    def test_a_job_without_any_failed_step_is_rejected(self):
        jobs = jobs_response()
        for step in jobs["jobs"][1]["steps"]:
            if step["name"] == recovery.NOTES_STEP:
                step["conclusion"] = "success"
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(jobs=jobs)

    def test_per_device_notes_steps_accept_one_failed_leg(self):
        # A newer tag splits the Notes step per device. Either single leg may be
        # the failure that makes the job recoverable; both legs must be present.
        report = self.verify(jobs=jobs_with_accepted_steps(accepted_steps_per_device()))
        self.assertEqual(report["failed_steps"], [recovery.NOTES_IPAD_STEP])
        self.assertEqual(report["notes_steps"], {
            recovery.NOTES_IPAD_STEP: "failure",
            recovery.NOTES_IPHONE_STEP: "success"})
        self.assertEqual(report["notes_step_conclusion"], "failure")

    def test_per_device_notes_steps_accept_the_other_failed_leg(self):
        steps = accepted_steps_per_device(
            **{recovery.NOTES_IPAD_STEP: "success",
               recovery.NOTES_IPHONE_STEP: "failure"})
        report = self.verify(jobs=jobs_with_accepted_steps(steps))
        self.assertEqual(report["failed_steps"], [recovery.NOTES_IPHONE_STEP])

    def test_per_device_notes_steps_require_both_legs(self):
        steps = [step for step in accepted_steps_per_device()
                 if step["name"] != recovery.NOTES_IPHONE_STEP]
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(jobs=jobs_with_accepted_steps(steps))

    def test_mixed_legacy_and_per_device_notes_steps_are_rejected(self):
        steps = accepted_steps_per_device()
        steps.append({"name": recovery.NOTES_STEP, "status": "completed",
                      "conclusion": "failure"})
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(jobs=jobs_with_accepted_steps(steps))

    def test_per_device_both_legs_passing_is_not_recoverable(self):
        steps = accepted_steps_per_device(
            **{recovery.NOTES_IPAD_STEP: "success",
               recovery.NOTES_IPHONE_STEP: "success"})
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(jobs=jobs_with_accepted_steps(steps))

    def test_cli_source_run_passes_and_reports_failure(self):
        # Exercise the real command line, not only the imported function.
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            run = root / "run.json"
            jobs = root / "jobs.json"
            artifacts = root / "artifacts.json"
            report = root / "report.json"
            run.write_text(json.dumps(run_metadata()), encoding="utf-8")
            jobs.write_text(json.dumps(jobs_response()), encoding="utf-8")
            artifacts.write_text(json.dumps(artifacts_response()), encoding="utf-8")
            command = [
                sys.executable, str(SCRIPTS / "verify_accepted_sdk_recovery.py"),
                "source-run", "--run", str(run), "--jobs", str(jobs),
                "--artifacts", str(artifacts),
                "--source-sha", SOURCE_SHA, "--source-run", SOURCE_RUN,
                "--source-attempt", SOURCE_ATTEMPT, "--tag", TAG,
                "--version", VERSION, "--build", BUILD,
                "--device-artifact-id", str(DEVICE_ID),
                "--device-artifact-digest", DEVICE_DIGEST,
                "--diagnostics-artifact-id", str(DIAGNOSTICS_ID),
                "--diagnostics-artifact-digest", DIAGNOSTICS_DIGEST,
                "--report", str(report)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(report.read_text())
            self.assertEqual(payload["notes_step_conclusion"], "failure")
            self.assertEqual(payload["device_artifact"]["id"], DEVICE_ID)

            run.write_text(json.dumps(run_metadata(head_branch="v9")),
                           encoding="utf-8")
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("verification failed", result.stderr)


def device_entry(name: str, data: bytes | None = None, *, kind="file") -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name)
    if kind == "dir":
        info.external_attr = (stat.S_IFDIR | 0o755) << 16
    elif kind == "symlink":
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
    else:
        info.external_attr = (stat.S_IFREG | 0o644) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    return info


PLIST = {
    "CFBundleIdentifier": recovery.BUNDLE_ID,
    "CFBundleShortVersionString": VERSION,
    "CFBundleVersion": BUILD,
    "DTSDKName": "iphoneos26.5",
}


def write_zip(path: Path, entries) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        for name, info, data in entries:
            archive.writestr(info, data if data is not None else b"")


def make_device_artifact(root: Path, *, source_sha=SOURCE_SHA, stage=recovery.RECOVERY_STAGE,
                         plist=None, entries=None, zip_name=recovery.DEVICE_ZIP_NAME):
    payload = root / "payload"
    payload.mkdir(parents=True, exist_ok=True)
    if entries is None:
        app = "FloeSignedPayload/Payload/Floe Agent.app/Info.plist"
        entries = [
            ("FloeSignedPayload/SOURCE-SHA.txt", device_entry("FloeSignedPayload/SOURCE-SHA.txt"),
             (source_sha + "\n").encode()),
            ("FloeSignedPayload/RECOVERY-STAGE.txt",
             device_entry("FloeSignedPayload/RECOVERY-STAGE.txt"), (stage + "\n").encode()),
            ("FloeSignedPayload/Payload/", device_entry("FloeSignedPayload/Payload/", kind="dir"), b""),
            ("FloeSignedPayload/Payload/Floe Agent.app/",
             device_entry("FloeSignedPayload/Payload/Floe Agent.app/", kind="dir"), b""),
            (app, device_entry(app),
             plistlib.dumps(plist or PLIST)),
        ]
    zip_path = payload / zip_name
    write_zip(zip_path, entries)
    artifact = root / "artifact"
    artifact.mkdir(exist_ok=True)
    shutil.copy2(zip_path, artifact / zip_name)
    digest = recovery._sha256(artifact / zip_name)
    (artifact / f"{zip_name}.sha256").write_text(
        f"{digest}  {zip_name}\n", encoding="utf-8")
    return artifact, digest


class DeviceArchiveTests(unittest.TestCase):
    def test_zip_restores_executable_permissions_without_special_bits(self):
        binary = device_entry("Payload/test-binary")
        binary.create_system = 3
        binary.external_attr = (stat.S_IFREG | 0o6755) << 16
        archive = self.root / "executable.zip"
        write_zip(archive, [(binary.filename, binary, b"executable")])
        recovery.safe_extract_zip(archive, self.extract)
        self.assertEqual((self.extract / binary.filename).stat().st_mode & 0o7777, 0o755)

    def test_stage_record_matches_release_producer(self):
        workflow = (SCRIPTS.parents[1] / ".github/workflows/release-unsigned-ipa.yml").read_text()
        marker = "stage=" + recovery.RECOVERY_STAGE
        self.assertIn("'" + marker + "'", workflow)
        artifact, _ = make_device_artifact(self.root, stage=marker)
        self.assertEqual(self.verify(artifact)["recovery_stage"], recovery.RECOVERY_STAGE)

    def test_keyed_wrong_stage_rejected(self):
        artifact, _ = make_device_artifact(self.root, stage="stage=normalized")
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifact)

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.extract = self.root / "extract"

    def tearDown(self):
        self._tmp.cleanup()

    def verify(self, artifact, extract=None, **overrides):
        kwargs = dict(source_sha=SOURCE_SHA, version=VERSION, build=BUILD,
                      extract_dir=extract or self.extract)
        kwargs.update(overrides)
        return recovery.verify_device_archive(artifact, **kwargs)

    def test_matching_device_zip_passes(self):
        artifact, digest = make_device_artifact(self.root)
        result = self.verify(artifact)
        self.assertEqual(result["device_zip_sha256"], digest)
        self.assertEqual(result["bundle_id"], recovery.BUNDLE_ID)
        self.assertTrue(result["app_path"].endswith("Floe Agent.app"))
        self.assertTrue(Path(result["app_path"]).is_dir())

    def test_sidecar_digest_mismatch_is_rejected(self):
        artifact, _ = make_device_artifact(self.root)
        (artifact / f"{recovery.DEVICE_ZIP_NAME}.sha256").write_text(
            f"{'0' * 64}  {recovery.DEVICE_ZIP_NAME}\n", encoding="utf-8")
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifact, extract=self.root / "e1")

    def test_wrong_source_or_bundle_is_rejected(self):
        artifact, _ = make_device_artifact(self.root, source_sha="f" * 40)
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifact, extract=self.root / "e1")
        artifact, _ = make_device_artifact(
            self.root / "wrong", plist=PLIST | {"CFBundleVersion": "180"})
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifact, extract=self.root / "e2")
        artifact, _ = make_device_artifact(
            self.root / "sdk", plist=PLIST | {"DTSDKName": "iphoneos27.0"})
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifact, extract=self.root / "e3")

    def test_wrong_recovery_stage_is_rejected(self):
        artifact, _ = make_device_artifact(self.root, stage="normalized")
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifact, extract=self.root / "e1")

    def test_traversal_absolute_and_link_members_are_rejected(self):
        attacks = {
            "parent": sorted([
                ("FloeSignedPayload/SOURCE-SHA.txt",
                 device_entry("FloeSignedPayload/SOURCE-SHA.txt"), (SOURCE_SHA + "\n").encode()),
                ("FloeSignedPayload/RECOVERY-STAGE.txt",
                 device_entry("FloeSignedPayload/RECOVERY-STAGE.txt"), (recovery.RECOVERY_STAGE + "\n").encode()),
                ("../escaped.txt", device_entry("../escaped.txt"), b"owned"),
            ]),
            "absolute": sorted([
                ("FloeSignedPayload/SOURCE-SHA.txt",
                 device_entry("FloeSignedPayload/SOURCE-SHA.txt"), (SOURCE_SHA + "\n").encode()),
                ("/tmp/floe-escaped.txt", device_entry("/tmp/floe-escaped.txt"), b"owned"),
            ]),
            "symlink": sorted([
                ("FloeSignedPayload/SOURCE-SHA.txt",
                 device_entry("FloeSignedPayload/SOURCE-SHA.txt"), (SOURCE_SHA + "\n").encode()),
                ("FloeSignedPayload/escape", device_entry("FloeSignedPayload/escape", kind="symlink"), b"../../outside"),
            ]),
            "duplicate": sorted([
                ("FloeSignedPayload/SOURCE-SHA.txt",
                 device_entry("FloeSignedPayload/SOURCE-SHA.txt"), (SOURCE_SHA + "\n").encode()),
                ("FloeSignedPayload", device_entry("FloeSignedPayload", kind="dir"), b""),
                ("FloeSignedPayload/", device_entry("FloeSignedPayload/", kind="dir"), b""),
            ]),
        }
        for name, entries in attacks.items():
            with self.subTest(name=name):
                root = self.root / name
                artifact, _ = make_device_artifact(root, entries=entries)
                extract = root / "extract"
                with self.assertRaises(recovery.RecoveryVerificationError):
                    self.verify(artifact, extract=extract)
                self.assertFalse((root / "escaped.txt").exists())
                self.assertFalse(Path("/tmp/floe-escaped.txt").exists())
                if extract.exists():
                    self.assertEqual(list(extract.rglob("*")), [])

    def test_refuses_a_nonempty_extraction_directory(self):
        artifact, _ = make_device_artifact(self.root)
        self.extract.mkdir(parents=True)
        (self.extract / "keep.txt").write_text("owned", encoding="utf-8")
        with self.assertRaises(recovery.RecoveryVerificationError):
            self.verify(artifact)
        self.assertEqual((self.extract / "keep.txt").read_text(), "owned")

    def test_cli_writes_report_and_outputs(self):
        artifact, digest = make_device_artifact(self.root)
        report = self.root / "report.json"
        output = self.root / "out.txt"
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "verify_accepted_sdk_recovery.py"),
             "device-archive", "--artifact-dir", str(artifact),
             "--source-sha", SOURCE_SHA, "--version", VERSION, "--build", BUILD,
             "--extract-dir", str(self.root / "cli-extract"),
             "--report", str(report), "--github-output", str(output)],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(report.read_text())["device_zip_sha256"], digest)
        self.assertIn("app_path=", output.read_text())

    def test_cli_failure_returns_nonzero(self):
        artifact, _ = make_device_artifact(
            self.root, entries=[("../escape.txt", device_entry("../escape.txt"), b"x")])
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "verify_accepted_sdk_recovery.py"),
             "device-archive", "--artifact-dir", str(artifact),
             "--source-sha", SOURCE_SHA, "--version", VERSION, "--build", BUILD,
             "--extract-dir", str(self.root / "cli-extract")],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("verification failed", result.stderr)


class ReleaseHostMetadataTests(unittest.TestCase):
    """The mature compiled-host verifier accepts a release-side host run."""

    def host_metadata(self, **overrides) -> dict:
        base = {
            "repository": recovery.TRUSTED_REPOSITORY,
            "workflow_path": ".github/workflows/accepted-sdk-release-recovery.yml",
            "event": "workflow_dispatch",
            "head_sha": HOST_SHA,
            "run_id": 4242,
            "run_attempt": 1,
            "status": "completed",
            "jobs": [{
                "name": "recover-notes-qualification",
                "steps": [
                    {"name": "Retain the compiled accepted-SDK simulator host",
                     "status": "completed", "conclusion": "success"},
                    {"name": "Upload recoverable accepted-SDK simulator host",
                     "status": "completed", "conclusion": "success"},
                ],
            }],
            "artifacts": [{
                "id": 77,
                "name": f"accepted-sdk26-simulator-host-{HOST_SHA}",
                "expired": False,
                "workflow_run_id": 4242,
                "size_in_bytes": 1234,
            }],
        }
        base.update(overrides)
        return base

    def verify(self, value):
        return host.verify_metadata(
            value, source_sha=HOST_SHA, source_run="4242", source_attempt="1",
            workflow_path=".github/workflows/accepted-sdk-release-recovery.yml",
            host_job="recover-notes-qualification",
            upload_step="Upload recoverable accepted-SDK simulator host",
            retain_step="Retain the compiled accepted-SDK simulator host",
            artifact_prefix="accepted-sdk26-simulator-host")

    def test_release_host_run_passes(self):
        result = self.verify(self.host_metadata())
        self.assertEqual(result["artifact_name"],
                         f"accepted-sdk26-simulator-host-{HOST_SHA}")

    def test_default_host_prefix_is_not_accepted_for_release_run(self):
        with self.assertRaises(host.HostVerificationError):
            host.verify_metadata(
                self.host_metadata(), source_sha=HOST_SHA, source_run="4242",
                source_attempt="1",
                workflow_path=".github/workflows/accepted-sdk-release-recovery.yml",
                host_job="recover-notes-qualification",
                upload_step="Upload recoverable accepted-SDK simulator host",
                retain_step="Retain the compiled accepted-SDK simulator host")

    def test_failed_upload_or_retain_step_is_rejected(self):
        value = self.host_metadata()
        value["jobs"][0]["steps"][1]["conclusion"] = "failure"
        with self.assertRaises(host.HostVerificationError):
            self.verify(value)
        value = self.host_metadata()
        value["jobs"][0]["steps"][0]["conclusion"] = "failure"
        with self.assertRaises(host.HostVerificationError):
            self.verify(value)


CONTROLLER_SHA = "c" * 40
CHECKOUT_STEP = "Check out the exact tagged application source"
VERIFY_STEP = "Require the tagged source and accepted toolchain"
HOST_JOB = "recover-notes-qualification"
HOST_UPLOAD = "Upload recoverable accepted-SDK simulator host"
HOST_RETAIN = "Retain the compiled accepted-SDK simulator host"


def controller_host_metadata(**overrides) -> dict:
    base = {
        "repository": recovery.TRUSTED_REPOSITORY,
        "workflow_path": ".github/workflows/accepted-sdk-release-recovery.yml",
        "event": "workflow_dispatch",
        "head_sha": CONTROLLER_SHA,
        "run_id": 4242,
        "run_attempt": 1,
        "status": "completed",
        "jobs": [{
            "name": HOST_JOB,
            "steps": [
                {"name": CHECKOUT_STEP, "status": "completed", "conclusion": "success"},
                {"name": VERIFY_STEP, "status": "completed", "conclusion": "success"},
                {"name": HOST_RETAIN, "status": "completed", "conclusion": "success"},
                {"name": HOST_UPLOAD, "status": "completed", "conclusion": "success"},
            ],
        }],
        "artifacts": [{
            "id": 77,
            "name": f"accepted-sdk26-simulator-host-{HOST_SHA}",
            "expired": False,
            "workflow_run_id": 4242,
            "size_in_bytes": 1234,
        }],
    }
    base.update(overrides)
    return base


class HostControllerBindingTests(unittest.TestCase):
    """A recovery-built host is bound to the controller commit, not loosened."""

    def verify_metadata(self, value, **overrides):
        kwargs = dict(
            source_sha=HOST_SHA, source_run="4242", source_attempt="1",
            workflow_path=".github/workflows/accepted-sdk-release-recovery.yml",
            host_job=HOST_JOB, upload_step=HOST_UPLOAD, retain_step=HOST_RETAIN,
            artifact_prefix="accepted-sdk26-simulator-host",
            controller_sha=CONTROLLER_SHA,
            source_checkout_step=CHECKOUT_STEP, source_verify_step=VERIFY_STEP)
        kwargs.update(overrides)
        return host.verify_metadata(value, **kwargs)

    def test_controller_head_sha_distinct_from_source_sha_passes(self):
        result = self.verify_metadata(controller_host_metadata())
        self.assertEqual(result["binding"], "controller")
        self.assertEqual(result["controller_sha"], CONTROLLER_SHA)
        self.assertEqual(result["source_sha"], HOST_SHA)

    def test_head_sha_that_is_not_the_controller_commit_is_rejected(self):
        with self.assertRaises(host.HostVerificationError):
            self.verify_metadata(controller_host_metadata(head_sha="f" * 40))

    def test_controller_binding_requires_workflow_dispatch(self):
        with self.assertRaises(host.HostVerificationError):
            self.verify_metadata(controller_host_metadata(event="push"))

    def test_controller_binding_requires_source_steps(self):
        value = controller_host_metadata()
        value["jobs"][0]["steps"][0]["conclusion"] = "failure"
        with self.assertRaises(host.HostVerificationError):
            self.verify_metadata(value)
        value = controller_host_metadata()
        value["jobs"][0]["steps"] = value["jobs"][0]["steps"][1:]
        with self.assertRaises(host.HostVerificationError):
            self.verify_metadata(value)
        value = controller_host_metadata()
        value["jobs"][0]["steps"][1]["conclusion"] = "skipped"
        with self.assertRaises(host.HostVerificationError):
            self.verify_metadata(value)

    def test_source_binding_steps_without_controller_sha_are_rejected(self):
        with self.assertRaises(host.HostVerificationError):
            self.verify_metadata(controller_host_metadata(), controller_sha="")

    def test_metadata_head_sha_is_recorded_not_the_source_sha(self):
        result = self.verify_metadata(controller_host_metadata())
        self.assertEqual(result["head_sha"], CONTROLLER_SHA)


def make_host_artifact(root: Path, *, controller_sha="",
                       source_sha=HOST_SHA, source_run="4242",
                       source_attempt="1",
                       toolchain="Xcode 26.6\nBuild version 17F113\n") -> Path:
    artifact = root / "host"
    artifact.mkdir(parents=True, exist_ok=True)
    products = root / "build" / "Products"
    (products / "FloeAgentUITests-Runner.app").mkdir(parents=True)
    (products / "FloeAgent.xctestrun").write_bytes(b"xctestrun")
    (products / "FloeAgentUITests-Runner.app" / "Runner").write_bytes(b"runner")
    tar_path = artifact / "Products.tar.gz"
    with tarfile.open(tar_path, "w:gz") as archive:
        archive.add(products, arcname="Products")
    digest = host._sha256(tar_path)
    (artifact / "Products.tar.gz.sha256").write_text(
        f"{digest}  Products.tar.gz\n", encoding="utf-8")
    (artifact / "SOURCE-SHA.txt").write_text(source_sha + "\n", encoding="utf-8")
    (artifact / "SOURCE-RUN.txt").write_text(source_run + "\n", encoding="utf-8")
    (artifact / "SOURCE-ATTEMPT.txt").write_text(source_attempt + "\n", encoding="utf-8")
    (artifact / "TOOLCHAIN.txt").write_text(toolchain, encoding="utf-8")
    if controller_sha:
        (artifact / "CONTROLLER-SHA.txt").write_text(
            controller_sha + "\n", encoding="utf-8")
    return artifact


class HostArchiveControllerBindingTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def verify(self, artifact, extract, controller_sha=CONTROLLER_SHA):
        return host.verify_archive(
            artifact, source_sha=HOST_SHA, source_run="4242",
            source_attempt="1",
            toolchain="Xcode 26.6\nBuild version 17F113\n",
            extract_dir=extract, controller_sha=controller_sha)

    def test_matching_controller_sha_is_accepted(self):
        artifact = make_host_artifact(self.root, controller_sha=CONTROLLER_SHA)
        result = self.verify(artifact, self.root / "out")
        self.assertEqual(result["controller_sha"], CONTROLLER_SHA)

    def test_missing_controller_sha_is_rejected_when_expected(self):
        artifact = make_host_artifact(self.root)
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact, self.root / "out")

    def test_controller_sha_mismatch_is_rejected(self):
        artifact = make_host_artifact(self.root, controller_sha="d" * 40)
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact, self.root / "out")

    def test_malformed_controller_sha_is_rejected(self):
        artifact = make_host_artifact(self.root, controller_sha="not-a-sha")
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact, self.root / "out")

    def test_same_source_different_sdk_host_is_not_reused(self):
        # Identical source SHA but an SDK 27 host: the toolchain pin must refuse
        # it so an iPhoneOS 27 simulator host can never run as the accepted
        # Xcode 26.6 qualification, and the prefix stays SDK-specific.
        artifact = make_host_artifact(
            self.root, controller_sha=CONTROLLER_SHA,
            toolchain="Xcode 27.0\nBuild version 27A5252f\n")
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact, self.root / "out")

    def test_cli_controller_binding_passes_and_requires_the_record(self):
        artifact = make_host_artifact(self.root, controller_sha=CONTROLLER_SHA)
        metadata = self.root / "metadata.json"
        metadata.write_text(json.dumps(controller_host_metadata()), encoding="utf-8")
        report = self.root / "report.json"
        command = [sys.executable, str(SCRIPTS / "verify_compiled_test_host.py"),
                   "--metadata", str(metadata), "--artifact-dir", str(artifact),
                   "--source-sha", HOST_SHA, "--source-run", "4242",
                   "--source-attempt", "1", "--xcode-version", "26.6",
                   "--xcode-build", "17F113",
                   "--workflow-path", ".github/workflows/accepted-sdk-release-recovery.yml",
                   "--host-job", HOST_JOB, "--upload-step", HOST_UPLOAD,
                   "--retain-step", HOST_RETAIN,
                   "--artifact-prefix", "accepted-sdk26-simulator-host",
                   "--controller-sha-binding",
                   "--source-checkout-step", CHECKOUT_STEP,
                   "--source-verify-step", VERIFY_STEP,
                   "--extract-dir", str(self.root / "cli-out"),
                   "--report", str(report)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(report.read_text())
        self.assertEqual(payload["source"]["binding"], "controller")
        self.assertEqual(payload["archive"]["controller_sha"], CONTROLLER_SHA)


class NotesScopeBindingTests(unittest.TestCase):
    """The Notes selector and Office scope come from the tag, not a caller."""

    def test_real_release_workflow_derives_the_canonical_scope(self):
        text = (REPO_ROOT / ".github" / "workflows" /
                "release-unsigned-ipa.yml").read_text(encoding="utf-8")
        selector, without_office = bind_notes_scope.derive_scope(text)
        self.assertEqual(selector, "FloeAgentUITests/NotesWorkspaceImportUITests")
        self.assertTrue(without_office)

    def test_two_ui_selectors_are_rejected(self):
        text = ("-only-testing:FloeAgentUITests/A\n"
                "--simulator-without-office\n"
                "-only-testing:FloeAgentUITests/B\n")
        with self.assertRaises(bind_notes_scope.ScopeBindingError):
            bind_notes_scope.derive_scope(text)

    def test_mixed_office_scope_is_rejected(self):
        text = ("-only-testing:FloeAgentUITests/A\n"
                "python3 scripts/verify_notes_ui_xcresult.py --simulator-without-office \\\n"
                "python3 scripts/verify_notes_ui_xcresult.py --result-bundle x\n")
        with self.assertRaises(bind_notes_scope.ScopeBindingError):
            bind_notes_scope.derive_scope(text)

    def test_missing_verifier_is_rejected(self):
        with self.assertRaises(bind_notes_scope.ScopeBindingError):
            bind_notes_scope.derive_scope("-only-testing:FloeAgentUITests/A\n")

    def test_cli_writes_github_env_and_fails_loudly(self):
        with tempfile.TemporaryDirectory() as root:
            workflow = Path(root) / "release-unsigned-ipa.yml"
            workflow.write_text(
                "-only-testing:FloeAgentUITests/NotesWorkspaceImportUITests\n"
                "python3 scripts/verify_notes_ui_xcresult.py --simulator-without-office \\\n",
                encoding="utf-8")
            env_file = Path(root) / "env"
            result = subprocess.run(
                [sys.executable, str(SCRIPTS / "bind_notes_scope.py"),
                 "--workflow", str(workflow), "--github-env", str(env_file)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("NOTES_TEST_SELECTOR=FloeAgentUITests/NotesWorkspaceImportUITests",
                          env_file.read_text())
            self.assertIn("NOTES_SIMULATOR_WITHOUT_OFFICE=true", env_file.read_text())

            workflow.write_text(
                "-only-testing:FloeAgentUITests/A\n"
                "-only-testing:FloeAgentUITests/B\n", encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPTS / "bind_notes_scope.py"),
                 "--workflow", str(workflow), "--github-env", str(env_file)],
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("binding failed", result.stderr)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("ditto"),
                     "real ditto metadata needs macOS ditto")
class DittoZipMetadataTests(unittest.TestCase):
    """Real ditto zips must not be refused for benign AppleDouble metadata."""

    def make_payload(self, root: Path, *, symlink: bool) -> Path:
        payload = root / "payload" / "FloeSignedPayload"
        app = payload / "Payload" / "Floe Agent.app"
        (app / "Frameworks" / "Some.framework").mkdir(parents=True)
        (app / "Info.plist").write_bytes(plistlib.dumps(PLIST))
        (app / "Frameworks" / "Some.framework" / "Some").write_bytes(b"bin")
        if symlink:
            (app / "Frameworks" / "Some.framework" / "Current").symlink_to("Some")
        (payload / "SOURCE-SHA.txt").write_text(SOURCE_SHA + "\n", encoding="utf-8")
        (payload / "RECOVERY-STAGE.txt").write_text(
            recovery.RECOVERY_STAGE + "\n", encoding="utf-8")
        return payload

    def ditto_zip(self, payload: Path, artifact: Path) -> None:
        artifact.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
             str(payload), str(artifact / recovery.DEVICE_ZIP_NAME)],
            check=True)
        digest = recovery._sha256(artifact / recovery.DEVICE_ZIP_NAME)
        (artifact / f"{recovery.DEVICE_ZIP_NAME}.sha256").write_text(
            f"{digest}  {recovery.DEVICE_ZIP_NAME}\n", encoding="utf-8")

    def test_benign_ditto_metadata_is_extracted_not_refused(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            payload = self.make_payload(root, symlink=False)
            artifact = root / "artifact"
            self.ditto_zip(payload, artifact)
            with zipfile.ZipFile(artifact / recovery.DEVICE_ZIP_NAME) as archive:
                names = archive.namelist()
            self.assertTrue(any(name.startswith("__MACOSX/") for name in names),
                            "ditto did not emit AppleDouble metadata; fixture is not real")
            result = recovery.verify_device_archive(
                artifact, source_sha=SOURCE_SHA, version=VERSION, build=BUILD,
                extract_dir=root / "extract")
            self.assertEqual(result["bundle_id"], recovery.BUNDLE_ID)
            self.assertTrue(Path(result["app_path"]).is_dir())

    def test_real_ditto_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            payload = self.make_payload(root, symlink=True)
            artifact = root / "artifact"
            self.ditto_zip(payload, artifact)
            with zipfile.ZipFile(artifact / recovery.DEVICE_ZIP_NAME) as archive:
                modes = [info.external_attr >> 16 for info in archive.infolist()]
            self.assertTrue(any(stat.S_ISLNK(mode) for mode in modes),
                            "ditto did not record the symlink as a link member")
            with self.assertRaises(recovery.RecoveryVerificationError):
                recovery.verify_device_archive(
                    artifact, source_sha=SOURCE_SHA, version=VERSION, build=BUILD,
                    extract_dir=root / "extract")


# --- Execute the real per-device shell loop with controlled drivers ---------

LEG_STEP_NAME = "Require Notes import on the iPad simulator with the accepted SDK"
NEXT_STEP_NAME = "Require Notes import on the iPhone simulator with the accepted SDK"
VERIFIER_STUB = r'''
xcrun() {
  case " $* " in
    *" --show-sdk-version "*) echo "26.0"; return 0 ;;
    *" list devices "*) echo "{}"; return 0 ;;
    *" export attachments "*) return 0 ;;
    *) return 0 ;;
  esac
}
xcodebuild() { return 0; }
python3() {
  case "$1" in
    -c) command python3 "$@" ;;
    *select_test_simulator.py) echo "00000000-0000-0000-0000-000000000000"; return 0 ;;
    *run_test_with_diagnostics.py)
      call=$(( $(cat "$FAKE_STATE/calls" 2>/dev/null || echo 0) + 1 ))
      echo "$call" > "$FAKE_STATE/calls"
      diag=""; bundle=""
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          --output-dir) diag="$2"; shift 2 ;;
          -resultBundlePath) bundle="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      mkdir -p "$diag" "$bundle"
      reason="$(sed -n "${call}p" "$FAKE_STATE/reasons")"
      started="$(sed -n "${call}p" "$FAKE_STATE/started")"
      code="$(sed -n "${call}p" "$FAKE_STATE/codes")"
      [ -n "$reason" ] || reason=exited
      [ -n "$started" ] || started=true
      [ -n "$code" ] || code=0
      printf '{"reason":"%s","testsStarted":%s}\n' "$reason" "$started" > "$diag/summary.json"
      return "$code" ;;
    *verify_notes_ui_xcresult.py)
      printf '%s\n' "$@" > "$VERIFIER_ARGS"
      : > "$VERIFIER_MARKER"
      return "$FAKE_VERIFY_CODE" ;;
    *) return 99 ;;
  esac
}
'''


class NotesLegControlFlowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = WORKFLOW.read_text(encoding="utf-8")
        step = source.split(f"- name: {LEG_STEP_NAME}", 1)[1]
        step = step.split(f"- name: {NEXT_STEP_NAME}", 1)[0]
        cls.run_block = textwrap.dedent(step.split("run: |", 1)[1])

    def run_leg(self, codes, reasons, started, verify_code, root,
                without_office="true"):
        state = Path(root) / "state"
        state.mkdir(parents=True, exist_ok=True)
        (state / "codes").write_text("\n".join(str(c) for c in codes) + "\n")
        (state / "reasons").write_text("\n".join(reasons) + "\n")
        (state / "started").write_text("\n".join(str(s) for s in started) + "\n")
        workspace = Path(root) / "ws"
        (workspace / "original-source/FloeAgent/scripts").mkdir(parents=True)
        marker = Path(root) / "verified"
        args = Path(root) / "verifier-args"
        env = dict(
            os.environ,
            GITHUB_WORKSPACE=str(workspace),
            RUNNER_TEMP=root,
            FLOE_XCTESTRUN="/tmp/host/Products/FloeAgent.xctestrun",
            SIM_DEVICE="iPad mini (A17 Pro)",
            SIM_NAME="ipad",
            NOTES_TEST_SELECTOR="FloeAgentUITests/NotesWorkspaceImportUITests",
            NOTES_SIMULATOR_WITHOUT_OFFICE=without_office,
            FAKE_STATE=str(state),
            VERIFIER_MARKER=str(marker),
            VERIFIER_ARGS=str(args),
            FAKE_VERIFY_CODE=str(verify_code),
        )
        result = subprocess.run(
            ["bash", "-o", "pipefail", "-c", VERIFIER_STUB + self.run_block],
            cwd=root, env=env, capture_output=True, text=True)
        return result, marker, args

    def test_passing_run_reaches_the_strict_verifier(self):
        with tempfile.TemporaryDirectory() as root:
            result, marker, args = self.run_leg([0], ["exited"], ["true"], 0, root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(marker.exists(), result.stderr)
            self.assertIn("--simulator-without-office", args.read_text())

    def test_verifier_failure_fails_the_leg(self):
        with tempfile.TemporaryDirectory() as root:
            result, marker, _ = self.run_leg([0], ["exited"], ["true"], 7, root)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertTrue(marker.exists(), result.stderr)

    def test_office_flag_can_be_disabled_for_a_newer_tag_verifier(self):
        with tempfile.TemporaryDirectory() as root:
            result, marker, args = self.run_leg(
                [0], ["exited"], ["true"], 0, root, without_office="false")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(marker.exists(), result.stderr)
            self.assertNotIn("--simulator-without-office", args.read_text())

    def test_real_test_failure_is_not_retried_into_a_pass(self):
        with tempfile.TemporaryDirectory() as root:
            result, _, args = self.run_leg([65], ["exited"], ["true"], 0, root)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertEqual(int((Path(root) / "state/calls").read_text()), 1)

    def test_pre_test_stall_is_retried_once_and_can_pass(self):
        with tempfile.TemporaryDirectory() as root:
            result, marker, _ = self.run_leg(
                [124, 0], ["stalled", "exited"], ["false", "true"], 0, root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(marker.exists(), result.stderr)
            self.assertEqual(int((Path(root) / "state/calls").read_text()), 2)
            bundle_dir = Path(root) / "FloeAcceptedSDKNotes"
            self.assertTrue((bundle_dir / "ipad-attempt-2.xcresult").is_dir())
            self.assertTrue((bundle_dir / "ipad-attempt-1.xcresult").is_dir())

    def test_stall_after_tests_started_is_not_retried(self):
        with tempfile.TemporaryDirectory() as root:
            result, _, _ = self.run_leg([124], ["stalled"], ["true"], 0, root)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertEqual(int((Path(root) / "state/calls").read_text()), 1)


class RecoveryWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = WORKFLOW.read_text(encoding="utf-8")

    def test_workflow_is_dispatch_only_and_read_only(self):
        on_block = self.source.split("\non:", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("workflow_dispatch:", on_block)
        self.assertNotIn("push:", on_block)
        self.assertNotIn("pull_request", on_block)
        self.assertNotIn("schedule:", on_block)
        permissions = self.source.split("\npermissions:", 1)[1].split("\nconcurrency:", 1)[0]
        self.assertIn("contents: read", permissions)
        self.assertIn("actions: read", permissions)
        self.assertNotIn("contents: write", permissions)

    def test_dispatch_inputs_are_within_the_github_limit(self):
        # GitHub allows at most 25 top-level workflow_dispatch inputs (the old
        # 10-input limit no longer applies); keep the controller inside it and
        # free of duplicate keys.
        inputs_block = self.source.split("\n    inputs:", 1)[1].split(
            "\npermissions:", 1)[0]
        keys = re.findall(r"^      ([a-z_]+):$", inputs_block, re.M)
        self.assertLessEqual(len(keys), 25)
        self.assertEqual(len(keys), len(set(keys)), keys)

    def test_no_tag_push_publish_or_expedited_waiver(self):
        for forbidden in ("git tag", "git push", "gh release", "action-gh-release",
                          "recover_build_156", "expedited-testflight",
                          "testflight-from-artifact", "inputs.publish"):
            self.assertNotIn(forbidden, self.source, forbidden)
        self.assertIn("standard_release_gates_no_expedited_waiver", self.source)

    def test_source_tag_and_controller_are_separate_checkouts(self):
        self.assertIn("ref: ${{ inputs.tag }}", self.source)
        self.assertIn("path: original-source", self.source)
        self.assertIn("path: recovery-controller", self.source)
        self.assertIn("recovery-controller/FloeAgent/scripts/verify_accepted_sdk_recovery.py",
                      self.source)
        # The verifier is the source tag's own, not a controller-provided copy.
        self.assertIn("original-source/FloeAgent/scripts/verify_notes_ui_xcresult.py",
                      self.source)
        self.assertIn("original-source/FloeAgent/scripts/verify_app_regression_xcresult.py",
                      self.source)

    def test_no_version_or_test_count_is_hardcoded_in_the_controller_helper(self):
        helper = (SCRIPTS / "verify_accepted_sdk_recovery.py").read_text(encoding="utf-8")
        for forbidden in ("passedTests=3", "passedTests == 3", "build179", "1.7.0"):
            self.assertNotIn(forbidden, helper, forbidden)
        # Version/build and artifact identities are pinned dispatch inputs.
        for required in ("inputs.version", "inputs.build",
                         "inputs.device_artifact_id", "inputs.device_artifact_digest"):
            self.assertIn(required, self.source, required)

    def test_notes_scope_cannot_be_weakened_by_dispatch_inputs(self):
        # The selector and Office scope are derived from the source tag, not
        # supplied by a caller who could narrow the suite.
        self.assertNotIn("notes_test_selector", self.source)
        self.assertNotIn("notes_simulator_without_office", self.source)
        self.assertIn("bind_notes_scope.py", self.source)
        self.assertIn("--workflow original-source/.github/workflows/release-unsigned-ipa.yml",
                      self.source)
        self.assertIn('--github-env "$GITHUB_ENV"', self.source)
        # The recovery itself still runs the source tag's verifier.
        self.assertIn("original-source/FloeAgent/scripts/verify_notes_ui_xcresult.py",
                      self.source)

    def test_per_device_steps_have_separate_time_budgets(self):
        self.assertEqual(self.source.count("- name: Require Notes import on the"), 2)
        ipad = self.source.split(LEG_STEP_NAME, 1)[1].split(NEXT_STEP_NAME, 1)[0]
        iphone = self.source.split(NEXT_STEP_NAME, 1)[1]
        for block in (ipad, iphone):
            self.assertIn("timeout-minutes: 25", block)
        self.assertIn("SIM_DEVICE: iPad mini (A17 Pro)", self.source)
        self.assertIn("SIM_DEVICE: iPhone 17 Pro", self.source)

    def test_original_selector_retry_and_diagnostics_are_used(self):
        self.assertIn('"$NOTES_TEST_SELECTOR"', self.source)
        self.assertNotIn("-retry-tests-on-failure", self.source)
        self.assertIn("run_test_with_diagnostics.py", self.source)
        self.assertIn('reason")=="stalled" and not s.get("testsStarted")', self.source)
        self.assertIn("-parallel-testing-enabled NO -test-timeouts-enabled YES", self.source)
        self.assertNotIn("-skip-testing", self.source)

    def test_device_is_reused_and_host_is_rebuilt_or_reused(self):
        self.assertIn("accepted-sdk-device-recovery", self.source)
        self.assertIn("accepted-sdk-app-diagnostics", self.source)
        self.assertIn("device-archive", self.source)
        self.assertIn("verify_compiled_test_host.py", self.source)
        self.assertIn("accepted-sdk26-simulator-host-", self.source)
        self.assertNotIn("xcodebuild -scheme FloeAgent -configuration Release", self.source)
        self.assertNotIn("Build unsigned device application", self.source)

    def test_failure_evidence_is_retained(self):
        for pattern in ("FloeAcceptedSDKNotes/", "FloeAcceptedSDKNotesDiagnostics/",
                        "FloeAcceptedSDKHost/", "RECOVERY-SOURCE-PROVENANCE.json",
                        "device-archive-verification.json", "host-metadata/"):
            self.assertIn(pattern, self.source, pattern)

    def test_actionlint_passes(self):
        actionlint = shutil.which("actionlint")
        if actionlint is None:
            self.skipTest("actionlint is not installed")
        result = subprocess.run([actionlint, str(WORKFLOW)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
