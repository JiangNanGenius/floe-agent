"""Fixture tests for the Notes UI pre-test retry classifier.

The positive fixture is the exact attempt log and diagnostics summary retained
from release run 35292395886, job 105437894361 (SDK 27 iPhone Notes leg,
`Local/Artifacts/build185-release/sdk27-notes-ui-1.7.0-build185/`). The
executed-failure negative is the exact SDK 27 iPad leg that failed the Office
cover assertion, so a bounded retry can never turn that failure into a pass.
Modeled negatives (application crash, ambiguous bootstrap error, malformed or
missing evidence) are labelled as such; no such logs were retained.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from notes_ui_startup_retry import classify  # noqa: E402

HELPER = SCRIPTS / "notes_ui_startup_retry.py"
WORKFLOW = Path(__file__).resolve().parents[3] / ".github/workflows/release-unsigned-ipa.yml"

# Exact observed summary: iPhone-attempt-1/summary.json from job 105437894361.
OBSERVED_BOOTSTRAP_SUMMARY = {
    "exitCode": 65,
    "reason": "exited",
    "elapsedSeconds": 276.735,
    "testsStarted": False,
}

# Exact observed attempt log (tests.log plus the summary line run_test_with_
# diagnostics.py prints) from the same leg.
OBSERVED_BOOTSTRAP_LOG = """Command line invocation:
    /Applications/Xcode_27_Release_Candidate.app/Contents/Developer/usr/bin/xcodebuild -xctestrun /Users/runner/work/_temp/FloeAppRegressionDerivedData/Build/Products/FloeAgent_iphonesimulator27.0-arm64.xctestrun -destination "platform=iOS Simulator,id=A0124FEC-82F3-4102-BFC1-F9194D9AD410" -resultBundlePath /Users/runner/work/_temp/FloeSDK27-Notes/iphone-attempt-1.xcresult -collect-test-diagnostics never "-only-testing:FloeAgentUITests/NotesWorkspaceImportUITests" -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 360 CODE_SIGNING_ALLOWED=NO test-without-building

Build settings from command line:
    CODE_SIGNING_ALLOWED = NO

Writing result bundle at path:
\t/Users/runner/work/_temp/FloeSDK27-Notes/iphone-attempt-1.xcresult

2026-09-18 01:45:42.826079+0000 FloeAgentUITests-Runner[5415:482608] [Default] Running tests...
2026-09-18 01:48:12.967 xcodebuild[4909:480044] [MT] IDETestOperationsObserverDebug: 268.792 elapsed -- Testing started completed.
2026-09-18 01:48:12.968 xcodebuild[4909:480044] [MT] IDETestOperationsObserverDebug: 0.000 sec, +0.000 sec -- start
2026-09-18 01:48:12.968 xcodebuild[4909:480044] [MT] IDETestOperationsObserverDebug: 268.792 sec, +268.792 sec -- end

Test session results, code coverage, and logs:
\t/Users/runner/work/_temp/FloeSDK27-Notes/iphone-attempt-1.xcresult

Testing failed:
\tFloeAgentUITests-Runner (5415) encountered an error (Early unexpected exit, operation never finished bootstrapping - no restart will be attempted. (Underlying Error: The test runner crashed while preparing to run tests: FloeAgentUITests-Runner at -[XCTWaiter(StallHandling) handleStalledWait:]))

** TEST EXECUTE FAILED **

Testing started
{"exitCode": 65, "reason": "exited", "elapsedSeconds": 276.735, "testsStarted": false}
"""

# Exact observed summary: SDK 27 iPad-attempt-1/summary.json from the same job.
OBSERVED_EXECUTED_SUMMARY = {
    "exitCode": 65,
    "reason": "exited",
    "elapsedSeconds": 812.339,
    "testsStarted": True,
}

# Exact observed executed-failure lines from that leg: the Office cover
# assertion must stay a failure and can never be retried.
OBSERVED_EXECUTED_LOG = """Test Suite 'Selected tests' started at 2026-09-18 01:32:38.448.
Test Suite 'FloeAgentUITests.xctest' started at 2026-09-18 01:32:38.449.
Test Suite 'NotesWorkspaceImportUITests' started at 2026-09-18 01:32:38.449.
Test Case '-[FloeAgentUITests.NotesWorkspaceImportUITests testDocumentTabsAndBodySearch]' started.
Test Case '-[FloeAgentUITests.NotesWorkspaceImportUITests testDocumentTabsAndBodySearch]' passed (186.271 seconds).
Test Case '-[FloeAgentUITests.NotesWorkspaceImportUITests testNotesLibraryCardsShowRealContentCovers]' started.
/Users/runner/work/floe-agent/floe-agent/FloeAgent/Tests/FloeAgentUITests/NotesWorkspaceImportUITests.swift:264: error: -[FloeAgentUITests.NotesWorkspaceImportUITests testNotesLibraryCardsShowRealContentCovers] : XCTAssertTrue failed - office 封面验收-Word cover source 'unsupported' is not a real content source ["quickLook"]
Test Case '-[FloeAgentUITests.NotesWorkspaceImportUITests testNotesLibraryCardsShowRealContentCovers]' failed (140.788 seconds).
\t Executed 5 tests, with 1 test skipped and 1 failure (0 unexpected) in 650.517 (650.531) seconds
Failing tests:
\tNotesWorkspaceImportUITests.testNotesLibraryCardsShowRealContentCovers()

** TEST EXECUTE FAILED **
{"exitCode": 65, "reason": "exited", "elapsedSeconds": 812.339, "testsStarted": true}
"""

# Modeled (not observed): an App-under-test crash must not be retried even
# when the summary looks like a pre-test exit.
APPLICATION_CRASH_LOG = """Testing failed:
\tFloeAgentUITests-Runner (5415) encountered an error (Failed to launch the test runner: The application 'Floe Agent' crashed during launch.)

** TEST EXECUTE FAILED **
"""

# Modeled (not observed): a different runner bootstrap error with the same
# wording but not the retained stall-handling frame stays non-retryable.
AMBIGUOUS_BOOTSTRAP_LOG = """Testing failed:
\tFloeAgentUITests-Runner (5415) encountered an error (Early unexpected exit, operation never finished bootstrapping - no restart will be attempted. (Underlying Error: The test runner crashed while preparing to run tests: FloeAgentUITests-Runner at -[XCTRunnerIDESession waitForQuiescence:]))

** TEST EXECUTE FAILED **
"""

# Modeled (not observed): a broad nonzero exit without the known signature.
BROAD_NONZERO_LOG = """Testing failed:
\tFloeAgentUITests-Runner (5415) encountered an error (Test runner exited before starting test execution.)

** TEST EXECUTE FAILED **
"""

# Modeled: the pre-existing stall shape still classifies as retryable.
STALLED_SUMMARY = {"exitCode": 124, "reason": "stalled",
                   "elapsedSeconds": 420.0, "testsStarted": False}
STALLED_LOG = """Command line invocation:
    xcodebuild -xctestrun host.xctestrun test-without-building

Test output stalled; capturing owned test processes.
{"exitCode": 124, "reason": "stalled", "elapsedSeconds": 420.0, "testsStarted": false}
"""


class RetryClassifierTests(unittest.TestCase):
    def assert_not_retryable(self, summary, log_text, classification=None, attempt=1):
        result = classify(summary, log_text, attempt=attempt)
        self.assertFalse(result["retry"], result)
        if classification is not None:
            self.assertEqual(result["classification"], classification, result)
        return result

    def test_observed_bootstrap_crash_is_retryable_once(self):
        result = classify(OBSERVED_BOOTSTRAP_SUMMARY, OBSERVED_BOOTSTRAP_LOG)
        self.assertTrue(result["retry"], result)
        self.assertEqual(result["classification"], "bootstrap-crash-before-tests", result)

    def test_second_attempt_is_never_retryable(self):
        self.assert_not_retryable(OBSERVED_BOOTSTRAP_SUMMARY, OBSERVED_BOOTSTRAP_LOG,
                                  classification="attempt-limit", attempt=2)
        self.assert_not_retryable(STALLED_SUMMARY, STALLED_LOG,
                                  classification="attempt-limit", attempt=3)

    def test_existing_stalled_before_tests_is_still_retryable(self):
        result = classify(STALLED_SUMMARY, STALLED_LOG)
        self.assertTrue(result["retry"], result)
        self.assertEqual(result["classification"], "stalled-before-tests", result)

    def test_stall_after_tests_started_is_not_retryable(self):
        summary = dict(STALLED_SUMMARY, testsStarted=True)
        self.assert_not_retryable(summary, STALLED_LOG,
                                  classification="tests-started-or-unknown")

    def test_stalled_reason_with_wrong_exit_code_is_not_retryable(self):
        summary = dict(STALLED_SUMMARY, exitCode=65)
        self.assert_not_retryable(summary, STALLED_LOG,
                                  classification="unexpected-exit-code")

    def test_timeout_is_not_retryable(self):
        summary = dict(STALLED_SUMMARY, reason="timeout")
        self.assert_not_retryable(summary, STALLED_LOG,
                                  classification="unexpected-reason")

    def test_observed_office_cover_failure_is_never_retried(self):
        self.assert_not_retryable(OBSERVED_EXECUTED_SUMMARY, OBSERVED_EXECUTED_LOG,
                                  classification="tests-started-or-unknown")

    def test_executed_log_beats_a_contradictory_summary(self):
        summary = dict(OBSERVED_BOOTSTRAP_SUMMARY, testsStarted=False)
        log = OBSERVED_BOOTSTRAP_LOG + OBSERVED_EXECUTED_LOG
        self.assert_not_retryable(summary, log, classification="executed-test-evidence")

    def test_application_crash_is_not_retryable(self):
        result = self.assert_not_retryable(OBSERVED_BOOTSTRAP_SUMMARY, APPLICATION_CRASH_LOG)
        self.assertEqual(result["classification"], "application-crash-evidence", result)

    def test_ambiguous_bootstrap_error_is_not_retryable(self):
        self.assert_not_retryable(OBSERVED_BOOTSTRAP_SUMMARY, AMBIGUOUS_BOOTSTRAP_LOG,
                                  classification="unknown-bootstrap-error")

    def test_broad_nonzero_65_is_not_retryable(self):
        self.assert_not_retryable(OBSERVED_BOOTSTRAP_SUMMARY, BROAD_NONZERO_LOG,
                                  classification="unknown-bootstrap-error")

    def test_wrong_exit_code_for_bootstrap_crash_is_not_retryable(self):
        summary = dict(OBSERVED_BOOTSTRAP_SUMMARY, exitCode=70)
        self.assert_not_retryable(summary, OBSERVED_BOOTSTRAP_LOG,
                                  classification="unexpected-exit-code")

    def test_malformed_or_missing_summary_is_not_retryable(self):
        for summary, classification in (
                (None, "malformed-evidence"),
                ([], "malformed-evidence"),
                ({"reason": "exited"}, "tests-started-or-unknown"),
                ({"exitCode": 65, "reason": "exited", "testsStarted": "false"},
                 "tests-started-or-unknown"),
                ({"exitCode": "65", "reason": "exited", "testsStarted": False},
                 "malformed-evidence"),
                ({"exitCode": True, "reason": "stalled", "testsStarted": False},
                 "malformed-evidence")):
            self.assert_not_retryable(summary, OBSERVED_BOOTSTRAP_LOG,
                                      classification=classification)

    def test_workflow_cli_accepts_the_observed_crash(self):
        with tempfile.TemporaryDirectory() as root:
            summary_path, log_path = self.write_evidence(
                root, OBSERVED_BOOTSTRAP_SUMMARY, OBSERVED_BOOTSTRAP_LOG)
            result = self.run_cli(summary_path, log_path)
            self.assertEqual(result.returncode, 0, result.stderr)
            verdict = json.loads(result.stdout)
            self.assertTrue(verdict["retry"], verdict)
            self.assertEqual(verdict["classification"], "bootstrap-crash-before-tests")

    def test_workflow_cli_rejects_executed_failure(self):
        with tempfile.TemporaryDirectory() as root:
            summary_path, log_path = self.write_evidence(
                root, OBSERVED_EXECUTED_SUMMARY, OBSERVED_EXECUTED_LOG)
            result = self.run_cli(summary_path, log_path)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertFalse(json.loads(result.stdout)["retry"])

    def test_workflow_cli_fails_closed_on_malformed_or_missing_evidence(self):
        with tempfile.TemporaryDirectory() as root:
            valid_summary = Path(root) / "valid-summary.json"
            valid_summary.write_text(json.dumps(STALLED_SUMMARY) + "\n", encoding="utf-8")
            valid_log = Path(root) / "attempt-1.log"
            valid_log.write_text(STALLED_LOG, encoding="utf-8")
            bad = Path(root) / "summary.json"
            bad.write_text("{not json", encoding="utf-8")
            missing_summary = self.run_cli(Path(root) / "absent.json", valid_log)
            self.assertEqual(missing_summary.returncode, 1, missing_summary.stdout)
            self.assertFalse(json.loads(missing_summary.stdout)["retry"])
            self.assertEqual(
                json.loads(missing_summary.stdout)["classification"], "missing-evidence")
            invalid_json = self.run_cli(bad, valid_log)
            self.assertEqual(invalid_json.returncode, 1, invalid_json.stdout)
            self.assertFalse(json.loads(invalid_json.stdout)["retry"])
            empty_log = Path(root) / "empty.log"
            empty_log.write_text("", encoding="utf-8")
            empty = self.run_cli(valid_summary, empty_log)
            self.assertEqual(empty.returncode, 1, empty.stdout)
            self.assertFalse(json.loads(empty.stdout)["retry"])
            self.assertEqual(json.loads(empty.stdout)["classification"], "missing-evidence")
            missing_log = self.run_cli(valid_summary, Path(root) / "absent.log")
            self.assertEqual(missing_log.returncode, 1, missing_log.stdout)
            self.assertFalse(json.loads(missing_log.stdout)["retry"])

    def test_classifier_reads_evidence_without_modifying_it(self):
        with tempfile.TemporaryDirectory() as root:
            summary_path, log_path = self.write_evidence(
                root, OBSERVED_BOOTSTRAP_SUMMARY, OBSERVED_BOOTSTRAP_LOG)
            before = (summary_path.read_bytes(), log_path.read_bytes())
            self.run_cli(summary_path, log_path)
            self.assertEqual((summary_path.read_bytes(), log_path.read_bytes()), before)

    def write_evidence(self, root, summary, log_text):
        summary_path = Path(root) / "summary.json"
        summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        log_path = Path(root) / "attempt-1.log"
        log_path.write_text(log_text, encoding="utf-8")
        return summary_path, log_path

    def run_cli(self, summary_path, log_path, attempt="1"):
        return subprocess.run(
            [sys.executable, str(HELPER), "--summary", str(summary_path),
             "--log", str(log_path), "--attempt", attempt],
            capture_output=True, text=True)


class WorkflowWiringTests(unittest.TestCase):
    def test_all_four_notes_legs_use_only_the_classifier_for_the_bounded_retry(self):
        source = WORKFLOW.read_text(encoding="utf-8")
        # Four retry calls, plus the release-step invocation of this test file.
        self.assertGreaterEqual(source.count("notes_ui_startup_retry.py"), 4)
        self.assertEqual(
            source.count("python3 scripts/notes_ui_startup_retry.py"), 4)
        self.assertEqual(source.count('--summary "$diag_dir/summary.json"'), 4)
        self.assertEqual(
            source.count('--log "$qualification/$NOTES_NAME-attempt-$leg_attempt.log"'), 4)
        self.assertEqual(source.count('--attempt "$leg_attempt"'), 4)
        # The classifier is the only retry decision point. The legacy inline
        # stall predicate that overrode a classifier rejection is gone: a
        # missing helper or missing/rejected evidence must fail closed.
        self.assertNotIn('s.get("reason")=="stalled"', source)
        self.assertNotIn('s.get("testsStarted")', source)
        self.assertNotIn("sys.exit(0 if", source)
        # One bounded second attempt per leg, still test-without-building.
        self.assertEqual(source.count("leg_attempt=2"), 4)
        self.assertGreaterEqual(source.count("-xctestrun \"$xctestrun\""), 4)
        self.assertGreaterEqual(source.count("-only-testing:FloeAgentUITests/"
                                             "NotesWorkspaceImportUITests"), 4)


if __name__ == "__main__":
    unittest.main()
