"""Fixture checks for the compiled-test-host recovery entry.

These tests pin both halves of the recovery feature:

* the verifier rejects a host whose trusted run, full source SHA, artifact
  name/run, digest, toolchain or archive contents do not match, and never
  extracts a traversal, symlink-escape or nested-symlink member outside the
  destination directory;
* the dispatch-only workflow rebuilds nothing, runs both device families
  without fail-fast, and executes the original three IDE UI tests through the
  original selector, diagnostic wrapper and strict xcresult verifier.

Every archive is a synthetic fixture built in a temporary directory; no test
touches the network, CI or a real compiled host.
"""
from __future__ import annotations

import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import verify_compiled_test_host as host  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "ide-host-recovery.yml"

SOURCE_SHA = "2e2a34c9f9d6a06d10b804df81ee1d92ec3f1381"
SOURCE_RUN = "35223435570"
SOURCE_ATTEMPT = "1"
TOOLCHAIN = "Xcode 27.0\nBuild version 27A5252f\n"

GOOD_ENTRIES = [
    ("Products/", "dir", None),
    ("Products/FloeAgent_iphonesimulator27.0-arm64.xctestrun", "file", b"{}"),
    ("Products/Debug-iphonesimulator/", "dir", None),
    ("Products/Debug-iphonesimulator/FloeAgentUITests-Runner.app/", "dir", None),
    ("Products/Debug-iphonesimulator/FloeAgentUITests-Runner.app/Info.plist",
     "file", b"plist"),
]


def write_archive(path: Path, entries) -> None:
    with tarfile.open(path, "w:gz") as archive:
        for name, kind, payload in entries:
            info = tarfile.TarInfo(name)
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                archive.addfile(info)
            elif kind == "file":
                data = payload if isinstance(payload, bytes) else payload.encode()
                info.type = tarfile.REGTYPE
                info.size = len(data)
                info.mode = 0o644
                archive.addfile(info, io.BytesIO(data))
            elif kind == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = payload
                archive.addfile(info)
            elif kind == "hardlink":
                info.type = tarfile.LNKTYPE
                info.linkname = payload
                archive.addfile(info)
            elif kind == "fifo":
                info.type = tarfile.FIFOTYPE
                archive.addfile(info)
            elif kind == "contig":
                info.type = tarfile.CONTTYPE
                archive.addfile(info)
            elif kind == "device":
                info.type = tarfile.CHRTYPE
                info.devmajor = 1
                info.devminor = 3
                archive.addfile(info)
            else:
                raise AssertionError(f"unknown entry kind {kind!r}")


def make_artifact(root: Path, *, entries=GOOD_ENTRIES, source_sha=SOURCE_SHA,
                  source_run=SOURCE_RUN, source_attempt=SOURCE_ATTEMPT,
                  toolchain=TOOLCHAIN, digest_line=None, stale_digest=False):
    artifact = Path(root) / "artifact"
    artifact.mkdir(parents=True, exist_ok=True)
    tar_path = artifact / "Products.tar.gz"
    write_archive(tar_path, entries)
    actual = host._sha256(tar_path)
    if digest_line is None:
        digest_line = "0" * 64 if stale_digest else actual
    (artifact / "Products.tar.gz.sha256").write_text(
        f"{digest_line}  Products.tar.gz\n", encoding="utf-8")
    (artifact / "SOURCE-SHA.txt").write_text(source_sha + "\n", encoding="utf-8")
    (artifact / "SOURCE-RUN.txt").write_text(str(source_run) + "\n", encoding="utf-8")
    (artifact / "SOURCE-ATTEMPT.txt").write_text(str(source_attempt) + "\n",
                                                 encoding="utf-8")
    (artifact / "TOOLCHAIN.txt").write_text(toolchain, encoding="utf-8")
    return artifact, actual


def metadata(**overrides) -> dict:
    base = {
        "repository": host.TRUSTED_REPOSITORY,
        "workflow_path": host.TRUSTED_WORKFLOW_PATH,
        "event": "workflow_dispatch",
        "head_sha": SOURCE_SHA,
        "run_id": int(SOURCE_RUN),
        "run_attempt": int(SOURCE_ATTEMPT),
        "status": "in_progress",
        "jobs": [{
            "name": host.HOST_JOB,
            "steps": [
                {"name": "Build App regression host once",
                 "status": "completed", "conclusion": "success"},
                {"name": host.HOST_RETAIN_STEP,
                 "status": "completed", "conclusion": "success"},
                {"name": host.HOST_UPLOAD_STEP,
                 "status": "completed", "conclusion": "success"},
                {"name": "Verify IDE native saves and retain workbench screenshots",
                 "status": "in_progress", "conclusion": None},
            ],
        }],
        "artifacts": [{
            "id": 10497993199,
            "name": host.artifact_name(SOURCE_SHA),
            "expired": False,
            "workflow_run_id": int(SOURCE_RUN),
            "size_in_bytes": 631916016,
        }],
    }
    base.update(overrides)
    return base


class MetadataProvenanceTests(unittest.TestCase):
    def verify(self, value):
        return host.verify_metadata(
            value, source_sha=SOURCE_SHA, source_run=SOURCE_RUN,
            source_attempt=SOURCE_ATTEMPT)

    def test_trusted_metadata_passes(self):
        result = self.verify(metadata())
        self.assertEqual(result["artifact_name"], host.artifact_name(SOURCE_SHA))
        self.assertEqual(result["run_id"], int(SOURCE_RUN))

    def test_failed_ui_step_still_passes_when_upload_succeeded(self):
        # The source run may have failed or still be running its UI phase; only
        # a successful host upload matters for recovery.
        value = metadata(status="completed")
        value["jobs"][0]["steps"][-1]["conclusion"] = "failure"
        self.verify(value)

    def test_other_repository_is_rejected(self):
        with self.assertRaises(host.HostVerificationError):
            self.verify(metadata(repository="attacker/floe-agent"))

    def test_untrusted_workflow_is_rejected(self):
        with self.assertRaises(host.HostVerificationError):
            self.verify(metadata(workflow_path=".github/workflows/fork.yml"))

    def test_external_pull_request_event_is_rejected(self):
        for event in ("pull_request", "pull_request_target", "workflow_run",
                      "issue_comment"):
            with self.subTest(event=event):
                with self.assertRaises(host.HostVerificationError):
                    self.verify(metadata(event=event))

    def test_push_event_is_trusted(self):
        self.verify(metadata(event="push"))

    def test_short_or_mismatched_source_sha_is_rejected(self):
        short = metadata(head_sha=SOURCE_SHA[:9])
        short["artifacts"][0]["name"] = "compiled-test-host-2e2a34c9"
        with self.assertRaises(host.HostVerificationError):
            self.verify(short)
        with self.assertRaises(host.HostVerificationError):
            self.verify(metadata(head_sha="f" * 40))

    def test_invalid_request_sha_is_rejected(self):
        with self.assertRaises(host.HostVerificationError):
            host.verify_metadata(metadata(), source_sha="not-a-sha",
                                 source_run=SOURCE_RUN, source_attempt=SOURCE_ATTEMPT)

    def test_mismatched_run_and_attempt_are_rejected(self):
        with self.assertRaises(host.HostVerificationError):
            self.verify(metadata(run_id=int(SOURCE_RUN) + 1))
        with self.assertRaises(host.HostVerificationError):
            self.verify(metadata(run_attempt=2))

    def test_missing_or_duplicate_artifact_is_rejected(self):
        with self.assertRaises(host.HostVerificationError):
            self.verify(metadata(artifacts=[]))
        duplicate = metadata()
        duplicate["artifacts"].append(dict(duplicate["artifacts"][0]))
        with self.assertRaises(host.HostVerificationError):
            self.verify(duplicate)

    def test_artifact_name_mismatch_is_rejected(self):
        value = metadata()
        value["artifacts"][0]["name"] = "compiled-test-host-" + "f" * 40
        with self.assertRaises(host.HostVerificationError):
            self.verify(value)

    def test_expired_artifact_is_rejected(self):
        value = metadata()
        value["artifacts"][0]["expired"] = True
        with self.assertRaises(host.HostVerificationError):
            self.verify(value)

    def test_artifact_from_another_run_is_rejected(self):
        value = metadata()
        value["artifacts"][0]["workflow_run_id"] = int(SOURCE_RUN) + 1
        with self.assertRaises(host.HostVerificationError):
            self.verify(value)

    def test_metadata_without_a_built_host_is_rejected(self):
        # A run that never reached the upload step (no host build) can never be
        # recovered, even if a same-named artifact somehow existed.
        no_upload = metadata()
        no_upload["jobs"][0]["steps"] = no_upload["jobs"][0]["steps"][:2]
        with self.assertRaises(host.HostVerificationError):
            self.verify(no_upload)

        no_job = metadata(jobs=[{"name": "appstore-sdk-compatibility", "steps": []}])
        with self.assertRaises(host.HostVerificationError):
            self.verify(no_job)

    def test_failed_host_upload_step_is_rejected(self):
        value = metadata()
        value["jobs"][0]["steps"][2]["conclusion"] = "failure"
        with self.assertRaises(host.HostVerificationError):
            self.verify(value)


class ArchiveVerificationTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.extract = self.root / "extract"

    def tearDown(self):
        self._tmp.cleanup()

    def verify(self, artifact, extract=None, products_sha256="", toolchain=TOOLCHAIN):
        return host.verify_archive(
            artifact, source_sha=SOURCE_SHA, source_run=SOURCE_RUN,
            source_attempt=SOURCE_ATTEMPT, toolchain=toolchain,
            extract_dir=extract or self.extract,
            products_sha256=products_sha256)

    def test_matching_archive_passes_and_reports_host_paths(self):
        artifact, digest = make_artifact(self.root)
        result = self.verify(artifact)
        self.assertEqual(result["products_sha256"], digest)
        self.assertTrue(result["xctestrun"].endswith(
            "FloeAgent_iphonesimulator27.0-arm64.xctestrun"))
        self.assertTrue(result["uitest_runner"].endswith(
            "FloeAgentUITests-Runner.app"))
        self.assertTrue(Path(result["xctestrun"]).is_file())

    def test_pinned_digest_matches_or_is_rejected(self):
        artifact, digest = make_artifact(self.root)
        self.verify(artifact, extract=self.root / "extract-pinned",
                    products_sha256=digest)
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact, extract=self.root / "extract-bad",
                        products_sha256="a" * 64)

    def test_embedded_digest_mismatch_is_rejected(self):
        artifact, _ = make_artifact(self.root, stale_digest=True)
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact)

    def test_toolchain_mismatch_is_rejected(self):
        artifact, _ = make_artifact(self.root)
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact, toolchain="Xcode 26.6\nBuild version 26A1\n")

    def test_source_metadata_mismatch_is_rejected(self):
        artifact, _ = make_artifact(self.root, source_run=int(SOURCE_RUN) + 1)
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact)

    def test_missing_xctestrun_is_rejected(self):
        entries = [entry for entry in GOOD_ENTRIES
                   if not entry[0].endswith(".xctestrun")]
        artifact, _ = make_artifact(self.root, entries=entries)
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact)

    def test_missing_uitest_runner_is_rejected(self):
        entries = [entry for entry in GOOD_ENTRIES
                   if "UITests-Runner.app" not in entry[0]]
        artifact, _ = make_artifact(self.root, entries=entries)
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact)

    def test_traversal_and_absolute_members_are_rejected(self):
        attacks = {
            "parent": GOOD_ENTRIES + [("../escaped.txt", "file", b"owned")],
            "absolute": GOOD_ENTRIES + [("/tmp/floe-escaped.txt", "file", b"owned")],
            "nested": GOOD_ENTRIES + [("Products/../../escaped.txt", "file", b"owned")],
        }
        for name, entries in attacks.items():
            with self.subTest(name=name):
                root = self.root / name
                artifact, _ = make_artifact(root, entries=entries)
                extract = root / "extract"
                with self.assertRaises(host.HostVerificationError):
                    self.verify(artifact, extract=extract)
                self.assertFalse((root / "escaped.txt").exists())
                self.assertFalse(Path("/tmp/floe-escaped.txt").exists())
                if extract.exists():
                    self.assertEqual(list(extract.rglob("*")), [])

    def test_escaping_symlink_is_rejected(self):
        entries = GOOD_ENTRIES + [
            ("Products/escape", "symlink", "../../outside"),
            ("Products/absolute", "symlink", "/etc/passwd"),
        ]
        artifact, _ = make_artifact(self.root, entries=entries)
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact)

    def test_any_symlink_or_hardlink_member_is_rejected(self):
        # The real host is a plain file/directory tree, so every link is refused
        # without trying to reason about its target. This blocks an ordered
        # symlink/hardlink chain that only escapes once earlier members exist.
        attacks = {
            "symlink_inside": ("Products/inside", "symlink", "Products"),
            "symlink_chain": ("Products/a", "symlink", "Products/b"),
            "hardlink": ("Products/hard", "hardlink", "Products/xctestrun"),
        }
        for name, entry in attacks.items():
            with self.subTest(name=name):
                root = self.root / name
                artifact, _ = make_artifact(root, entries=GOOD_ENTRIES + [entry])
                with self.assertRaises(host.HostVerificationError):
                    self.verify(artifact, extract=root / "extract")
                if (root / "extract").exists():
                    self.assertEqual(list((root / "extract").rglob("*")), [])

    def test_chained_symlink_escape_is_rejected(self):
        # ``Products/a -> b`` looks contained, ``Products/b -> ../../outside``
        # escapes; because no link member is ever extracted the chain can never
        # be assembled and the destination stays empty.
        entries = [
            ("Products/", "dir", None),
            ("Products/FloeAgent_iphonesimulator27.0-arm64.xctestrun", "file", b"{}"),
            ("Products/Debug-iphonesimulator/FloeAgentUITests-Runner.app/", "dir", None),
            ("Products/a", "symlink", "b"),
            ("Products/b", "symlink", "../../outside"),
        ]
        root = self.root / "chain"
        artifact, _ = make_artifact(root, entries=entries)
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact, extract=root / "extract")
        self.assertEqual(list((root / "extract").rglob("*")), [])

    def test_duplicate_normalized_members_are_rejected(self):
        # ``Products`` and ``Products/`` normalize to the same path; letting
        # both through would make the extracted result order-dependent.
        entries = GOOD_ENTRIES + [("Products", "dir", None)]
        root = self.root / "duplicate"
        artifact, _ = make_artifact(root, entries=entries)
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact, extract=root / "extract")

    def test_nested_member_under_symlink_is_rejected(self):
        entries = [
            ("Products/", "dir", None),
            ("Products/FloeAgent_iphonesimulator27.0-arm64.xctestrun", "file", b"{}"),
            ("Products/link", "symlink", "sub"),
            ("Products/link/evil.txt", "file", b"owned"),
        ]
        artifact, _ = make_artifact(self.root, entries=entries)
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact)

    def test_device_members_are_rejected(self):
        entries = GOOD_ENTRIES + [("Products/pipe", "fifo", None)]
        artifact, _ = make_artifact(self.root, entries=entries)
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact)

    def test_special_and_contiguous_members_are_rejected(self):
        # Not just links: device nodes and contiguous/sparse type codes are not
        # "regular files or directories" either.
        attacks = {
            "device": ("Products/node", "device", None),
            "contiguous": ("Products/sparse", "contig", b"data"),
        }
        for name, entry in attacks.items():
            with self.subTest(name=name):
                root = self.root / name
                artifact, _ = make_artifact(root, entries=GOOD_ENTRIES + [entry])
                with self.assertRaises(host.HostVerificationError):
                    self.verify(artifact, extract=root / "extract")

    def test_refuses_to_extract_into_a_nonempty_directory(self):
        artifact, _ = make_artifact(self.root)
        self.extract.mkdir(parents=True)
        (self.extract / "keep.txt").write_text("owned", encoding="utf-8")
        with self.assertRaises(host.HostVerificationError):
            self.verify(artifact)
        self.assertEqual((self.extract / "keep.txt").read_text(), "owned")


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.script = SCRIPTS / "verify_compiled_test_host.py"

    def tearDown(self):
        self._tmp.cleanup()

    def run_cli(self, artifact, metadata_path, *, extra=()):
        return subprocess.run(
            [sys.executable, str(self.script),
             "--metadata", str(metadata_path),
             "--artifact-dir", str(artifact),
             "--source-sha", SOURCE_SHA,
             "--source-run", SOURCE_RUN,
             "--source-attempt", SOURCE_ATTEMPT,
             "--extract-dir", str(self.root / "extract"),
             *extra],
            capture_output=True, text=True)

    def test_success_writes_report_and_github_output(self):
        artifact, _ = make_artifact(self.root)
        metadata_path = self.root / "meta.json"
        metadata_path.write_text(json.dumps(metadata()), encoding="utf-8")
        report = self.root / "report.json"
        output = self.root / "github-output.txt"
        result = self.run_cli(artifact, metadata_path,
                              extra=("--report", str(report),
                                     "--github-output", str(output)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(report.is_file())
        self.assertIn("xctestrun=", output.read_text(encoding="utf-8"))
        self.assertIn("Products", output.read_text(encoding="utf-8"))

    def test_failure_returns_nonzero(self):
        artifact, _ = make_artifact(
            self.root, entries=GOOD_ENTRIES + [("../escaped.txt", "file", b"x")])
        metadata_path = self.root / "meta.json"
        metadata_path.write_text(json.dumps(metadata()), encoding="utf-8")
        result = self.run_cli(artifact, metadata_path)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("host verification failed", result.stderr)


class RecoveryLoopTests(unittest.TestCase):
    """Execute the workflow's IDE leg loop with controlled test drivers."""

    @classmethod
    def setUpClass(cls):
        source = WORKFLOW.read_text(encoding="utf-8")
        step = source.split(
            "- name: Run the three original IDE UI tests without rebuilding", 1)[1]
        step = step.split("- name: Upload recovered IDE evidence", 1)[0]
        cls.run_block = textwrap.dedent(step.split("run: |", 1)[1])

    def run_loop(self, fake_test_code, fake_verify_code, root):
        # A successful test command must still reach the strict xcresult
        # verifier; a verifier failure must fail the leg; a failed test command
        # must never be reported as acceptance.
        functions = r'''
xcrun() { return 0; }
python3() {
  case "$1" in
    scripts/select_test_simulator.py)
      echo "00000000-0000-0000-0000-000000000000"; return 0 ;;
    scripts/run_test_with_diagnostics.py)
      mkdir -p "FloeAgent-IDE-$SIM_NAME.xcresult"; return "$FAKE_TEST_CODE" ;;
    scripts/verify_ide_ui_xcresult.py)
      : > "$VERIFIER_MARKER"; return "$FAKE_VERIFY_CODE" ;;
    *) return 99 ;;
  esac
}
'''
        (Path(root) / "original-source" / "FloeAgent").mkdir(parents=True)
        marker = Path(root) / "verified"
        env = dict(
            os.environ,
            RUNNER_TEMP=root,
            XCTESTRUN="/tmp/host/Products/FloeAgent.xctestrun",
            SIM_DEVICE="iPad mini (A17 Pro)",
            SIM_NAME="ipad",
            VERIFIER_MARKER=str(marker),
            FAKE_TEST_CODE=str(fake_test_code),
            FAKE_VERIFY_CODE=str(fake_verify_code),
        )
        return subprocess.run(
            ["bash", "-eo", "pipefail", "-c", functions + self.run_block],
            cwd=root, env=env, capture_output=True, text=True), marker

    def test_passing_run_reaches_the_strict_verifier(self):
        with tempfile.TemporaryDirectory() as root:
            result, marker = self.run_loop(0, 0, root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(marker.exists(), result.stderr)

    def test_verifier_failure_fails_the_leg(self):
        with tempfile.TemporaryDirectory() as root:
            result, marker = self.run_loop(0, 7, root)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertTrue(marker.exists(), result.stderr)

    def test_failed_test_execution_is_not_reported_as_acceptance(self):
        with tempfile.TemporaryDirectory() as root:
            result, _ = self.run_loop(65, 0, root)
            self.assertNotEqual(result.returncode, 0, result.stdout)


class RunnerToolchainTests(unittest.TestCase):
    """Execute the workflow's pre-download runner toolchain check for real."""

    MATCHING = "Xcode 27.0\nBuild version 27A5252f"

    @classmethod
    def setUpClass(cls):
        source = WORKFLOW.read_text(encoding="utf-8")
        step = source.split(
            "- name: Verify the runner toolchain matches the archive request", 1)[1]
        step = step.split("\n      - name:", 1)[0]
        cls.run_block = textwrap.dedent(step.split("run: |", 1)[1])

    def run_check(self, xcodebuild_version, sdk_version="27.0"):
        # The fixture executes the real workflow shell with a controlled
        # ``xcodebuild``/``xcrun`` so a mismatch is rejected by the actual check,
        # not by a static string assertion.
        functions = '''
xcodebuild() { printf '%s' "$FAKE_XCODEBUILD_VERSION"; }
xcrun() { printf '%s' "$FAKE_SDK_VERSION"; }
'''
        env = dict(
            os.environ,
            XCODE_VERSION="27.0",
            XCODE_BUILD="27A5252f",
            FAKE_XCODEBUILD_VERSION=xcodebuild_version,
            FAKE_SDK_VERSION=sdk_version,
        )
        return subprocess.run(
            ["bash", "-eo", "pipefail", "-c", functions + self.run_block],
            env=env, capture_output=True, text=True)

    def test_matching_runner_is_accepted(self):
        result = self.run_check(self.MATCHING)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("iPhoneSimulator SDK 27.0", result.stdout)

    def test_mismatched_runner_version_is_rejected(self):
        for actual in ("Xcode 26.6\nBuild version 26A1",
                       "Xcode 27.0\nBuild version 27A0000",
                       "Xcode 27.1\nBuild version 27A5252f"):
            with self.subTest(actual=actual):
                result = self.run_check(actual)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("does not match the requested toolchain",
                              result.stderr)

    def test_wrong_sdk_major_is_rejected(self):
        for sdk in ("26.0", "28.0", "", "27"):
            with self.subTest(sdk=sdk):
                result = self.run_check(self.MATCHING, sdk_version=sdk)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("SDK major is not 27", result.stderr)


class RecoveryWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = WORKFLOW.read_text(encoding="utf-8")

    def test_workflow_is_dispatch_only(self):
        on_block = self.source.split("\non:", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("workflow_dispatch:", on_block)
        self.assertNotIn("push:", on_block)
        self.assertNotIn("pull_request", on_block)
        self.assertNotIn("schedule:", on_block)
        self.assertIn("source_sha must be lowercase hex", self.source)

    def test_workflow_rebuilds_nothing(self):
        for forbidden in ("build-for-testing", "xcodebuild -scheme",
                          "xcodebuild -project", "actions/cache@",
                          "brew install", "swift build", "xcodegen"):
            self.assertNotIn(forbidden, self.source, forbidden)
        self.assertEqual(self.source.count("test-without-building"), 1)

    def test_workflow_has_no_release_or_publish_path(self):
        lowered = self.source.lower()
        for forbidden in ("action-gh-release", "testflight", "app-store-connect",
                          "release-unsigned-ipa", "publish", "secrets."):
            self.assertNotIn(forbidden, lowered, forbidden)

    def test_both_devices_run_without_fail_fast(self):
        self.assertIn("fail-fast: false", self.source)
        self.assertIn("iPad mini (A17 Pro)", self.source)
        self.assertIn("iPhone 17 Pro", self.source)
        self.assertIn("name: ipad", self.source)
        self.assertIn("name: iphone", self.source)

    def test_original_source_and_controller_are_checked_out_separately(self):
        self.assertIn("ref: ${{ inputs.source_sha }}", self.source)
        self.assertIn("path: original-source", self.source)
        self.assertIn("path: recovery-controller", self.source)
        self.assertIn("needs: validate-controller", self.source)
        self.assertNotIn(
            "original-source/FloeAgent/scripts/verify_compiled_test_host.py",
            self.source)

    def test_runs_the_original_three_tests_through_original_helpers(self):
        for helper in (
                "recovery-controller/FloeAgent/scripts/verify_compiled_test_host.py",
                "scripts/select_test_simulator.py",
                "scripts/run_test_with_diagnostics.py",
                "scripts/verify_ide_ui_xcresult.py"):
            self.assertIn(helper, self.source, helper)
        self.assertIn("-only-testing:FloeAgentUITests/WorkspaceIDEUITests",
                      self.source)
        self.assertNotIn("-skip-testing", self.source)
        # The only retry is a stall before any test started.
        self.assertIn('reason")=="stalled" and not s.get("testsStarted")',
                      self.source)

    def test_failure_evidence_is_retained(self):
        for pattern in (
                "FloeAgent-IDE-*.log", "FloeAgent-IDE-*.xcresult",
                "FloeAgent-IDE-Screenshots", "host-verification.json",
                "host-metadata.json", "SwiftTestDiagnostics"):
            self.assertIn(pattern, self.source, pattern)

    def test_runner_toolchain_is_checked_before_any_download(self):
        # The actual runner `xcodebuild -version` and simulator SDK major must be
        # proven before the host artifact is downloaded or extracted.
        toolchain = self.source.index(
            "Verify the runner toolchain matches the archive request")
        download = self.source.index("Download the compiled test host artifact")
        self.assertLess(toolchain, download)
        self.assertIn("xcodebuild -version", self.source)
        self.assertIn("--show-sdk-version", self.source)
        self.assertIn("iPhoneSimulator SDK major is not 27", self.source)

    def test_permissions_are_read_only(self):
        block = self.source.split("\npermissions:", 1)[1].split("\nconcurrency:", 1)[0]
        self.assertIn("contents: read", block)
        self.assertIn("actions: read", block)
        self.assertNotIn("write", block)

    def test_actionlint_passes(self):
        actionlint = shutil.which("actionlint")
        if actionlint is None:
            self.skipTest("actionlint is not installed")
        result = subprocess.run([actionlint, str(WORKFLOW)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0,
                         result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
