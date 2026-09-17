"""Fixture checks for the bounded xcodebuild package-resolution helper.

The build 182 SDK 27 release job aborted on a transient `curl 56` clone
timeout followed by a GitHub DNS failure, and reported only the downstream
"binary target ... could not be mapped to an artifact" error. These tests pin
the intended contract of `scripts/resolve_xcode_dependencies.sh`:

* only explicit network signatures (DNS / timeout / connection / truncated
  transfer) are retried, at most the configured number of attempts;
* a strong deterministic error (checksum / manifest / authentication) wins
  over an earlier network line in the same log and is never retried, while the
  real build-182 artifact-mapping + DNS cascade still gets a bounded retry;
* `--max-attempts` is a bounded 1..3, not any positive integer;
* pre-flight mkdir/backup/hash failures stop before `xcodebuild` runs;
* every raw attempt is written to its own log;
* the tracked host `Package.resolved` is backed up, and a rewrite is rejected
  with the original restored and the changed bytes kept as evidence;
* the actual Xcode workspace lock is seeded from the committed HEAD lock on
  first use, verified with the shared `resolved_pins` schema handling
  (including app-only WhisperKit) and never overwritten when it already
  disagrees. Because Xcode may legitimately rewrite originHash metadata, the
  v1/v3 schema or formatting, a byte change is re-checked by normalized pins:
  equivalent rewrites pass and keep before/after copies, while a real
  revision/version/location drift is rejected with the drift bytes kept;
* the resolve command mirrors the real build's project, scheme, configuration,
  destination, `-packageCachePath` and `-derivedDataPath`, and the two release
  SDK jobs wire the same helper, canonical lock and Xcode lock in.

No test touches the network, CI, Xcode or a real build: `xcodebuild` is a
synthetic executable whose stdout and exit status are scripted per attempt,
and pre-flight failures are injected with PATH shims.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
HELPER = REPO_ROOT / "FloeAgent" / "scripts" / "resolve_xcode_dependencies.sh"
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "release-unsigned-ipa.yml"
BASH = shutil.which("bash") or "/bin/bash"

FAKE_XCODEBUILD = r'''#!/usr/bin/env python3
import json
import os
import sys

with open(os.environ["FAKE_ARGV_LOG"], "a") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\n")

counter = os.environ["FAKE_COUNTER"]
attempt = int(open(counter).read()) if os.path.exists(counter) else 0
attempt += 1
open(counter, "w").write(str(attempt))

lines = [line for line in open(os.environ["FAKE_SEQUENCE"]).read().splitlines() if line]
code, body = lines[attempt - 1].split("|", 1)
print(body)

def _rewrite(path, text):
    with open(path, "w") as handle:
        handle.write(text)

xcode_lock = os.environ.get("FAKE_XCODE_LOCK") or ""
if "__REWRITE_LOCK__" in body:
    _rewrite(os.environ["FAKE_RESOLVED"], '{"pins": ["mutated"]}\n')
if "__DELETE_LOCK__" in body:
    os.remove(os.environ["FAKE_RESOLVED"])
if xcode_lock and "__REWRITE_XCODE_LOCK__" in body:
    _rewrite(xcode_lock, '{"version": 3, "pins": []}\n')
if xcode_lock and "__REWRITE_XCODE_ORIGINHASH__" in body:
    document = json.load(open(xcode_lock))
    document["originHash"] = "sha256:0123456789abcdef"
    _rewrite(xcode_lock, json.dumps(document))
if xcode_lock and "__REWRITE_XCODE_V1__" in body:
    document = json.load(open(xcode_lock))
    legacy_pins = [
        {"package": p["identity"], "repositoryURL": p["location"],
         "state": dict(p["state"])}
        for p in document["pins"]
    ]
    _rewrite(xcode_lock, json.dumps(
        {"version": 1, "object": {"pins": legacy_pins}}))
if xcode_lock and "__REWRITE_XCODE_DRIFT__" in body:
    document = json.load(open(xcode_lock))
    document["pins"][0]["state"]["revision"] = "f" * 40
    _rewrite(xcode_lock, json.dumps(document))
if xcode_lock and "__DELETE_XCODE_LOCK__" in body:
    os.remove(xcode_lock)
sys.exit(int(code))
'''

NETWORK_CLONE_ERROR = (
    "error: RPC failed; curl 56 Recv failure: Operation timed out"
)
NETWORK_DNS_ERROR = (
    "fatal: unable to access 'https://github.com/ml-explore/mlx-c/': "
    "Could not resolve host: github.com"
)
ARTIFACT_MAPPING_ERROR = (
    "xcodebuild: error: Could not resolve package dependencies:\n"
    "  binary target 'LlamaFramework' could not be mapped to an artifact "
    "with expected name 'LlamaFramework'\n"
    "  Couldn\u2019t update repository submodules"
)
CHECKSUM_ERROR = "error: checksum mismatch for binary artifact 'libssh2'"

ALPHA_REVISION = "a" * 40
WHISPER_REVISION = "b" * 40


def pin(identity, location, *, version=None, revision=ALPHA_REVISION):
    state = {"revision": revision}
    if version is not None:
        state["version"] = version
    return {"identity": identity, "location": location, "state": state}


ALPHA = pin("alpha", "https://example.org/alpha.git", version="1.0.0")
WHISPER = pin(
    "whisperkit", "https://github.com/argmaxinc/WhisperKit.git",
    revision=WHISPER_REVISION)


def one_line(text):
    """Flatten a log fragment: the fake attempt sequence is one line per attempt."""
    return " ".join(text.split())


def lock_json(pins):
    return json.dumps({"version": 3, "pins": pins}) + "\n"


CANONICAL = lock_json([ALPHA, WHISPER])
CANONICAL_HOST_ONLY = lock_json([ALPHA])
PROJECT_YML = (
    "name: FloeAgent\n"
    "packages:\n"
    "  WhisperKit:\n"
    "    url: https://github.com/argmaxinc/WhisperKit.git\n"
    "    revision: %s\n"
    "  FloeAgentPackages:\n"
    "    path: .\n"
    "targets:\n"
    "  FloeAgent:\n"
    "    type: application\n"
) % WHISPER_REVISION


class ResolveHelperFixture(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.cache = self.root / "FloePackageCache"
        self.derived = self.root / "FloeDerivedData"
        self.cache.mkdir()
        self.derived.mkdir()
        self.log_dir = self.root / "logs" / "transport"
        self.resolved = self.root / "Package.resolved"
        self.resolved.write_text("ORIGINAL-LOCK\n", encoding="utf-8")
        self.canonical = self.root / "FloeCanonicalPackage.resolved"
        self.project_yml = self.root / "project.yml"
        self.project_yml.write_text(PROJECT_YML, encoding="utf-8")
        self.fake = self.root / "fake_xcodebuild"
        self.fake.write_text(FAKE_XCODEBUILD, encoding="utf-8")
        self.fake.chmod(0o755)
        self._run_index = 0

    def tearDown(self):
        self._tmp.cleanup()

    def xcode_lock_path(self):
        return (self.root / "FloeAgent.xcodeproj" / "project.xcworkspace"
                / "xcshareddata" / "swiftpm" / "Package.resolved")

    def run_helper(self, attempts, *, max_attempts=3, config="Debug",
                   destination="generic/platform=iOS Simulator",
                   derived=None, log_dir=None, sdk=None,
                   resolved_content="ORIGINAL-LOCK\n",
                   xcode_lock=None, canonical=None, project_yml=None,
                   xcode_lock_content=None, create_xcode_lock=False,
                   shim=None):
        self._run_index += 1
        sequence = self.root / ("sequence-%d.txt" % self._run_index)
        sequence.write_text("\n".join(attempts) + "\n", encoding="utf-8")
        argv_log = self.root / ("argv-%d.log" % self._run_index)
        counter = self.root / ("counter-%d.txt" % self._run_index)
        self.resolved.write_text(resolved_content, encoding="utf-8")
        derived = derived or self.derived
        log_dir = log_dir or self.log_dir
        lock_path = None
        if xcode_lock is not None:
            lock_path = Path(xcode_lock)
            if create_xcode_lock:
                lock_path.parent.mkdir(parents=True, exist_ok=True)
                lock_path.write_text(
                    xcode_lock_content if xcode_lock_content is not None else CANONICAL,
                    encoding="utf-8")
        command = [
            BASH, str(HELPER),
            "--project", "FloeAgent.xcodeproj",
            "--scheme", "FloeAgent",
            "--configuration", config,
            "--destination", destination,
            "--package-cache-path", str(self.cache),
            "--derived-data-path", str(derived),
            "--resolved-file", str(self.resolved),
            "--log-dir", str(log_dir),
            "--max-attempts", str(max_attempts),
            "--retry-delay", "0",
            "--xcodebuild", str(self.fake),
        ]
        if sdk:
            command += ["--sdk", sdk]
        if canonical is not None:
            command += ["--canonical-lock", str(canonical)]
        if xcode_lock is not None:
            command += ["--xcode-lock", str(lock_path)]
        if project_yml is not None:
            command += ["--project-yml", str(project_yml)]
        env = dict(os.environ,
                   FAKE_SEQUENCE=str(sequence),
                   FAKE_ARGV_LOG=str(argv_log),
                   FAKE_COUNTER=str(counter),
                   FAKE_RESOLVED=str(self.resolved),
                   FAKE_XCODE_LOCK="" if lock_path is None else str(lock_path))
        if shim:
            shim_dir = self.root / ("shim-%s" % shim)
            shim_dir.mkdir(exist_ok=True)
            shim_path = shim_dir / shim
            shim_path.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            shim_path.chmod(0o755)
            env["PATH"] = str(shim_dir) + os.pathsep + env.get("PATH", "")
        result = subprocess.run(command, capture_output=True, text=True, env=env)
        return result, argv_log, counter, log_dir

    def attempts(self, argv_log):
        if not argv_log.exists():
            return []
        return [line for line in argv_log.read_text(encoding="utf-8").splitlines()
                if line]

    def logs(self, log_dir):
        return sorted(p.name for p in Path(log_dir).glob("resolve-attempt-*.log"))


class NetworkRetryTests(ResolveHelperFixture):
    def test_success_on_first_attempt_keeps_raw_log(self):
        result, argv_log, counter, log_dir = self.run_helper(["0|Resolved packages"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.attempts(argv_log)), 1)
        self.assertEqual(self.logs(log_dir), ["resolve-attempt-1.log"])
        self.assertIn("Resolved packages",
                      (Path(log_dir) / "resolve-attempt-1.log").read_text())
        self.assertEqual(self.resolved.read_text(), "ORIGINAL-LOCK\n")
        summary = (Path(log_dir) / "resolve-summary.txt").read_text()
        self.assertIn("classification=success", summary)
        self.assertIn("attempts=1", summary)
        self.assertIn("xcode_lock_status=not-configured", summary)

    def test_curl_timeout_then_dns_then_success_retries_with_each_log(self):
        result, argv_log, counter, log_dir = self.run_helper([
            "74|%s" % NETWORK_CLONE_ERROR,
            "74|%s" % NETWORK_DNS_ERROR,
            "0|Resolved packages",
        ])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.attempts(argv_log)), 3)
        self.assertEqual(self.logs(log_dir), [
            "resolve-attempt-1.log", "resolve-attempt-2.log", "resolve-attempt-3.log"])
        first = (Path(log_dir) / "resolve-attempt-1.log").read_text()
        second = (Path(log_dir) / "resolve-attempt-2.log").read_text()
        self.assertIn("curl 56", first)
        self.assertIn("Could not resolve host", second)
        self.assertIn("classification=success", (Path(log_dir) / "resolve-summary.txt").read_text())

    def test_network_failure_is_bounded_and_propagates_exit(self):
        result, argv_log, counter, log_dir = self.run_helper(
            ["74|%s" % NETWORK_CLONE_ERROR] * 3, max_attempts=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.attempts(argv_log)), 3)
        self.assertEqual(len(self.logs(log_dir)), 3)
        summary = (Path(log_dir) / "resolve-summary.txt").read_text()
        self.assertIn("classification=network-exhausted", summary)
        self.assertIn("attempts=3", summary)
        self.assertIn("network resolution failed after 3 attempts", result.stderr)

    def test_max_attempts_one_is_honoured(self):
        result, argv_log, _, _ = self.run_helper(
            ["74|Could not resolve host: github.com"], max_attempts=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.attempts(argv_log)), 1)

    def test_artifact_mapping_with_dns_cascade_is_still_retried(self):
        # The real build-182 final error is a downstream symptom of the DNS
        # cascade; it must not block the bounded retry.
        cascade = one_line("%s\n%s" % (NETWORK_DNS_ERROR, ARTIFACT_MAPPING_ERROR))
        result, argv_log, _, _ = self.run_helper([
            "74|%s" % cascade,
            "0|Resolved packages",
        ])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.attempts(argv_log)), 2)


class DeterministicPriorityTests(ResolveHelperFixture):
    def test_artifact_mapping_alone_is_not_retried(self):
        result, argv_log, counter, log_dir = self.run_helper(
            ["74|%s" % ARTIFACT_MAPPING_ERROR, "0|would have retried"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.attempts(argv_log)), 1,
                         "a non-network error must not consume a second attempt")
        self.assertEqual(self.logs(log_dir), ["resolve-attempt-1.log"])
        summary = (Path(log_dir) / "resolve-summary.txt").read_text()
        self.assertIn("classification=deterministic", summary)
        self.assertIn("not retried", result.stderr)

    def test_network_then_checksum_error_is_not_retried(self):
        # A deterministic checksum failure later in the same log outranks the
        # earlier network noise; retrying cannot repair a corrupt artifact.
        body = one_line("%s\n%s" % (NETWORK_CLONE_ERROR, CHECKSUM_ERROR))
        result, argv_log, _, log_dir = self.run_helper([f"74|{body}", "0|unused"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.attempts(argv_log)), 1)
        self.assertIn("classification=deterministic",
                      (Path(log_dir) / "resolve-summary.txt").read_text())

    def test_network_then_authentication_error_is_not_retried(self):
        body = one_line(
            "%s fatal: Authentication failed for 'https://github.com/x/y/'"
            % NETWORK_DNS_ERROR)
        result, argv_log, _, _ = self.run_helper([f"74|{body}", "0|unused"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.attempts(argv_log)), 1)

    def test_compile_style_error_is_not_retried(self):
        result, argv_log, _, log_dir = self.run_helper([
            "65|error: cannot find type 'GitHubActionsJob' in scope",
            "0|unused",
        ])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.attempts(argv_log)), 1)


class AttemptBoundTests(ResolveHelperFixture):
    def test_zero_is_rejected(self):
        result, argv_log, _, _ = self.run_helper(["0|ok"], max_attempts=0)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("between 1 and 3", result.stderr)
        self.assertEqual(self.attempts(argv_log), [])

    def test_four_is_rejected(self):
        result, argv_log, _, _ = self.run_helper(["0|ok"], max_attempts=4)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("between 1 and 3", result.stderr)
        self.assertEqual(self.attempts(argv_log), [])

    def test_non_integer_is_rejected(self):
        result, argv_log, _, _ = self.run_helper(["0|ok"], max_attempts="many")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("between 1 and 3", result.stderr)
        self.assertEqual(self.attempts(argv_log), [])


class PreflightFailureTests(ResolveHelperFixture):
    def test_mkdir_failure_stops_before_xcodebuild(self):
        result, argv_log, _, _ = self.run_helper(["0|ok"], shim="mkdir")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot create log directory", result.stderr)
        self.assertEqual(self.attempts(argv_log), [])

    def test_backup_failure_stops_before_xcodebuild(self):
        result, argv_log, _, _ = self.run_helper(["0|ok"], shim="cp")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot back up tracked lock", result.stderr)
        self.assertEqual(self.attempts(argv_log), [])

    def test_hash_failure_stops_before_xcodebuild(self):
        result, argv_log, _, _ = self.run_helper(["0|ok"], shim="shasum")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot hash tracked lock", result.stderr)
        self.assertEqual(self.attempts(argv_log), [])


class HostLockTests(ResolveHelperFixture):
    def test_lock_rewrite_is_rejected_and_original_restored(self):
        result, argv_log, _, log_dir = self.run_helper(
            ["0|__REWRITE_LOCK__ resolved"], resolved_content="ORIGINAL-LOCK\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.resolved.read_text(), "ORIGINAL-LOCK\n")
        self.assertEqual(len(self.attempts(argv_log)), 1)
        self.assertIn("rewrote", result.stderr)
        self.assertIn("classification=lock-mutated",
                      (Path(log_dir) / "resolve-summary.txt").read_text())
        self.assertEqual(
            (Path(log_dir) / "Package.resolved.original").read_text(),
            "ORIGINAL-LOCK\n")
        # The rewritten bytes are retained so the diff is not lost.
        self.assertEqual(
            (Path(log_dir) / "Package.resolved.mutated").read_text(),
            '{"pins": ["mutated"]}\n')

    def test_lock_deletion_is_rejected_and_original_restored(self):
        result, argv_log, _, _ = self.run_helper(["0|__DELETE_LOCK__ resolved"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.resolved.read_text(), "ORIGINAL-LOCK\n")

    def test_lock_mutation_on_failed_attempt_stops_before_retry(self):
        result, argv_log, _, _ = self.run_helper([
            "74|%s __REWRITE_LOCK__" % NETWORK_CLONE_ERROR,
            "0|unused",
        ])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.attempts(argv_log)), 1)
        self.assertEqual(self.resolved.read_text(), "ORIGINAL-LOCK\n")


class XcodeLockTests(ResolveHelperFixture):
    def test_missing_xcode_lock_is_initialized_from_committed_lock(self):
        lock = self.xcode_lock_path()
        self.assertFalse(lock.exists())
        result, argv_log, _, log_dir = self.run_helper(
            ["0|Resolved packages"],
            xcode_lock=lock, canonical=self.canonical_path(),
            resolved_content=CANONICAL)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(lock.exists())
        self.assertEqual(lock.read_text(), CANONICAL)
        self.assertEqual(len(self.attempts(argv_log)), 1)
        summary = (Path(log_dir) / "resolve-summary.txt").read_text()
        self.assertIn("xcode_lock_status=initialized-from-committed", summary)
        self.assertIn("xcode_lock=%s" % lock, summary)

    def test_existing_matching_xcode_lock_is_verified_not_rewritten(self):
        lock = self.xcode_lock_path()
        result, argv_log, _, log_dir = self.run_helper(
            ["0|Resolved packages"],
            xcode_lock=lock, canonical=self.canonical_path(),
            resolved_content=CANONICAL, create_xcode_lock=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(lock.read_text(), CANONICAL)
        self.assertIn("xcode_lock_status=existing-verified",
                      (Path(log_dir) / "resolve-summary.txt").read_text())

    def test_existing_mismatched_xcode_lock_is_not_overwritten(self):
        drifted = lock_json([pin("alpha", "https://example.org/alpha.git",
                                 version="9.9.9", revision="c" * 40), WHISPER])
        lock = self.xcode_lock_path()
        result, argv_log, _, log_dir = self.run_helper(
            ["0|would have run"],
            xcode_lock=lock, canonical=self.canonical_path(),
            resolved_content=CANONICAL, create_xcode_lock=True,
            xcode_lock_content=drifted)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.attempts(argv_log), [],
                         "resolution must not start against a mismatched lock")
        self.assertEqual(lock.read_text(), drifted,
                         "the mismatched lock must not be overwritten")
        self.assertIn("not overwriting", result.stderr)
        summary = (Path(log_dir) / "resolve-summary.txt").read_text()
        self.assertIn("classification=xcode-lock-mismatch", summary)
        self.assertIn("xcode_lock_status=existing-mismatch", summary)

    def test_xcode_lock_missing_app_only_pin_is_rejected(self):
        # The committed HEAD lock carries app-only WhisperKit. An existing
        # workspace lock that dropped it must fail before xcodebuild.
        lock = self.xcode_lock_path()
        result, argv_log, _, _ = self.run_helper(
            ["0|would have run"],
            xcode_lock=lock, canonical=self.canonical_path(),
            project_yml=self.project_yml,
            resolved_content=CANONICAL, create_xcode_lock=True,
            xcode_lock_content=CANONICAL_HOST_ONLY)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.attempts(argv_log), [])
        self.assertIn("missing", result.stderr)

    def test_v3_originhash_change_is_allowed_with_before_after_copies(self):
        # Xcode may add/update originHash metadata while keeping every pin;
        # that is not a dependency update and must not fail the resolve.
        lock = self.xcode_lock_path()
        result, _, _, log_dir = self.run_helper(
            ["0|__REWRITE_XCODE_ORIGINHASH__ resolved"],
            xcode_lock=lock, canonical=self.canonical_path(),
            resolved_content=CANONICAL, create_xcode_lock=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        written = json.loads(lock.read_text())
        self.assertEqual(written["originHash"], "sha256:0123456789abcdef")
        self.assertEqual(written["pins"], json.loads(CANONICAL)["pins"])
        self.assertEqual(
            (Path(log_dir) / "Package.resolved.xcode.before").read_text(),
            CANONICAL)
        after = Path(log_dir) / "Package.resolved.xcode.after"
        self.assertEqual(json.loads(after.read_text())["originHash"],
                         "sha256:0123456789abcdef")
        summary = (Path(log_dir) / "resolve-summary.txt").read_text()
        self.assertIn("xcode_lock_bytes=reformatted", summary)
        self.assertIn("xcode_lock_status=format-normalized", summary)

    def test_v1_equivalent_transcription_is_allowed(self):
        # Xcode may serialize the same resolution as schema v1; the normalized
        # pins are unchanged, so the resolve succeeds and both copies remain.
        lock = self.xcode_lock_path()
        result, _, _, log_dir = self.run_helper(
            ["0|__REWRITE_XCODE_V1__ resolved"],
            xcode_lock=lock, canonical=self.canonical_path(),
            resolved_content=CANONICAL, create_xcode_lock=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        written = json.loads(lock.read_text())
        self.assertEqual(written["version"], 1)
        self.assertEqual(
            (Path(log_dir) / "Package.resolved.xcode.before").read_text(),
            CANONICAL)
        after = json.loads(
            (Path(log_dir) / "Package.resolved.xcode.after").read_text())
        self.assertEqual(after["version"], 1)
        self.assertEqual(
            {p["repositoryURL"] for p in after["object"]["pins"]},
            {p["location"] for p in json.loads(CANONICAL)["pins"]})

    def test_single_revision_drift_is_rejected_with_evidence(self):
        # One changed revision is real dependency drift, not formatting.
        lock = self.xcode_lock_path()
        result, _, _, log_dir = self.run_helper(
            ["0|__REWRITE_XCODE_DRIFT__ resolved"],
            xcode_lock=lock, canonical=self.canonical_path(),
            resolved_content=CANONICAL, create_xcode_lock=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(lock.read_text(), CANONICAL,
                         "drift must be rejected and the committed lock restored")
        summary = (Path(log_dir) / "resolve-summary.txt").read_text()
        self.assertIn("classification=xcode-lock-mutated", summary)
        self.assertIn("xcode_lock_bytes=drifted", summary)
        drifted = json.loads(
            (Path(log_dir) / "Package.resolved.xcode.mutated").read_text())
        self.assertEqual(drifted["pins"][0]["state"]["revision"], "f" * 40)

    def test_xcode_lock_rewrite_is_kept_as_evidence_and_restored(self):
        lock = self.xcode_lock_path()
        result, argv_log, _, log_dir = self.run_helper(
            ["0|__REWRITE_XCODE_LOCK__ resolved"],
            xcode_lock=lock, canonical=self.canonical_path(),
            resolved_content=CANONICAL, create_xcode_lock=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(lock.read_text(), CANONICAL)
        self.assertEqual(len(self.attempts(argv_log)), 1)
        self.assertIn("classification=xcode-lock-mutated",
                      (Path(log_dir) / "resolve-summary.txt").read_text())
        self.assertEqual(
            (Path(log_dir) / "Package.resolved.xcode.mutated").read_text(),
            '{"version": 3, "pins": []}\n')

    def test_xcode_lock_deleted_during_resolution_is_restored(self):
        lock = self.xcode_lock_path()
        result, argv_log, _, log_dir = self.run_helper(
            ["0|__DELETE_XCODE_LOCK__ resolved"],
            xcode_lock=lock, canonical=self.canonical_path(),
            resolved_content=CANONICAL, create_xcode_lock=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(lock.read_text(), CANONICAL)
        self.assertIn("classification=xcode-lock-missing",
                      (Path(log_dir) / "resolve-summary.txt").read_text())

    def canonical_path(self):
        self.canonical.write_text(CANONICAL, encoding="utf-8")
        return self.canonical


class CommandParameterTests(ResolveHelperFixture):
    def test_command_mirrors_the_build_parameters(self):
        result, argv_log, _, _ = self.run_helper(["0|ok"])
        self.assertEqual(result.returncode, 0, result.stderr)
        argv = self.attempts(argv_log)[0]
        for token in (
            "-resolvePackageDependencies",
            "-project FloeAgent.xcodeproj",
            "-scheme FloeAgent",
            "-configuration Debug",
            "-destination generic/platform=iOS Simulator",
            "-packageCachePath %s" % self.cache,
            "-derivedDataPath %s" % self.derived,
            "-skipPackagePluginValidation",
            "-skipMacroValidation",
        ):
            self.assertIn(token, argv)

    def test_both_sdk_parameter_sets_are_distinct_and_consistent(self):
        sdk27 = self.root / "sdk27-dd"
        stable = self.root / "stable-dd"
        sdk27.mkdir()
        stable.mkdir()
        logs27 = self.root / "logs" / "sdk27"
        logs_stable = self.root / "logs" / "accepted"
        result27, argv27, _, _ = self.run_helper(
            ["0|ok"], config="Debug",
            destination="generic/platform=iOS Simulator", derived=sdk27, log_dir=logs27)
        result_stable, argv_stable, _, _ = self.run_helper(
            ["0|ok"], config="Release", destination="generic/platform=iOS",
            derived=stable, log_dir=logs_stable, sdk="iphoneos")
        self.assertEqual(result27.returncode, 0, result27.stderr)
        self.assertEqual(result_stable.returncode, 0, result_stable.stderr)

        sdk27_cmd = self.attempts(argv27)[0]
        stable_cmd = self.attempts(argv_stable)[0]
        self.assertIn("-configuration Debug", sdk27_cmd)
        self.assertIn("-destination generic/platform=iOS Simulator", sdk27_cmd)
        self.assertIn("-configuration Release", stable_cmd)
        self.assertIn("-destination generic/platform=iOS", stable_cmd)
        self.assertIn("-sdk iphoneos", stable_cmd)
        # Both legs resolve through the same package cache and lock file.
        for command in (sdk27_cmd, stable_cmd):
            self.assertIn("-packageCachePath %s" % self.cache, command)
            self.assertIn("-resolvePackageDependencies", command)

    def test_unknown_option_and_missing_value_fail_cleanly(self):
        result = subprocess.run(
            [BASH, str(HELPER), "--project", "FloeAgent.xcodeproj", "--bogus"],
            capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown option", result.stderr)
        result = subprocess.run(
            [BASH, str(HELPER), "--project"],
            capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing value", result.stderr)


class WordingTests(unittest.TestCase):
    def test_overbroad_git_phrases_are_not_network_signatures(self):
        regex_lines = [
            line for line in HELPER.read_text(encoding="utf-8").splitlines()
            if line.startswith("NETWORK_REGEX=") or line.startswith("NETWORK_REGEX+=")
        ]
        self.assertTrue(regex_lines)
        regex = "\n".join(regex_lines)
        self.assertNotIn("RPC failed", regex,
                         "a bare RPC failed also covers authentication errors")
        self.assertNotIn("SSL_ERROR", regex,
                         "a bare SSL_ERROR is not an unambiguous transient failure")

    def test_freeze_flag_wording_does_not_promise_offline(self):
        helper = " ".join(HELPER.read_text(encoding="utf-8").split())
        self.assertIn("does not make the build offline", helper)
        workflow = " ".join(WORKFLOW.read_text(encoding="utf-8").split())
        self.assertIn("do not make the build offline", workflow)


class WorkflowWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = WORKFLOW.read_text(encoding="utf-8")
        cls.source = source
        cls.sdk27 = source.split("\n  build-verify-release:", 1)[1] \
            .split("\n  accepted-sdk-build:", 1)[0]
        cls.stable = source.split("\n  accepted-sdk-build:", 1)[1] \
            .split("\n  testflight:", 1)[0]

    def test_both_sdk_jobs_use_the_same_helper(self):
        for job in (self.sdk27, self.stable):
            self.assertEqual(job.count("scripts/resolve_xcode_dependencies.sh"), 1)
            self.assertIn("--package-cache-path \"$FLOE_SPM_CACHE_ROOT\"", job)
            self.assertIn("--resolved-file Package.resolved", job)
            self.assertIn("--max-attempts 3", job)
            self.assertIn("FloeDependencyTransport", job)
        self.assertIn("--derived-data-path \"$RUNNER_TEMP/FloeAppRegressionDerivedData\"",
                      self.sdk27)
        self.assertIn("--configuration Debug", self.sdk27)
        self.assertIn("--destination 'generic/platform=iOS Simulator'", self.sdk27)
        self.assertIn("--derived-data-path \"$RUNNER_TEMP/FloeStableDeviceDerivedData\"",
                      self.stable)
        self.assertIn("--configuration Release", self.stable)
        self.assertIn("--destination 'generic/platform=iOS'", self.stable)

    def test_both_sdk_jobs_protect_the_actual_xcode_lock(self):
        for job in (self.sdk27, self.stable):
            self.assertIn(
                "--canonical-lock \"$RUNNER_TEMP/FloeCanonicalPackage.resolved\"",
                job)
            self.assertIn(
                "--xcode-lock FloeAgent.xcodeproj/project.xcworkspace/"
                "xcshareddata/swiftpm/Package.resolved", job)
            self.assertIn("--project-yml project.yml", job)
            # The canonical baseline is the committed HEAD lock, not the
            # working host lock that swift package resolve may rewrite.
            self.assertIn(
                "git show HEAD:FloeAgent/Package.resolved > "
                "\"$RUNNER_TEMP/FloeCanonicalPackage.resolved\"", job)

    def test_every_real_build_freezes_the_resolved_versions(self):
        for job in (self.sdk27, self.stable):
            self.assertGreaterEqual(
                job.count("-onlyUsePackageVersionsFromResolvedFile"), 2)
            self.assertIn("CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build-for-testing", job)
        self.assertNotIn("continue-on-error", self.source)

    def test_raw_logs_are_uploaded_on_failure(self):
        for job, name in (
            (self.sdk27, "sdk27-dependency-transport"),
            (self.stable, "accepted-sdk-dependency-transport"),
        ):
            self.assertIn(name, job)
            self.assertIn("if: always()", job)

    def test_new_helper_test_is_part_of_the_release_test_entry(self):
        self.assertIn("python3 scripts/tests/test_resolve_xcode_dependencies.py",
                      self.sdk27)
        resolve_step = self.sdk27.split("Resolve and verify pinned dependencies", 1)[1]
        self.assertIn("scripts/tests/test_resolve_xcode_dependencies.py", resolve_step)

    def test_actionlint_passes(self):
        actionlint = shutil.which("actionlint")
        if actionlint is None:
            self.skipTest("actionlint is not installed")
        result = subprocess.run(
            [actionlint, str(WORKFLOW)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
