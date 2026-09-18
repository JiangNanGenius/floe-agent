"""Fixture tests for the strict Quick Look diagnostics classifier.

``FloeAgent/scripts/verify_quicklook_diagnostics.py`` decides whether a
completed ``NotesOfficeThumbnailDiagnosticsTests`` run is a permitted,
non-gating system-Quick-Look diagnostic or a coverage failure. These tests call
the real helper (imported directly and through its CLI with a stub
``xcresulttool``) with realistic xcresult summary/tests structures modelled on
the checked-in build 186 artifact:

* complete 7/7 pass -> PASS;
* a complete 7/7 run whose only failures are the fixed-marker Quick Look
  content, timeout or icon assertions -> ASSERTION_FAILURE (recorded, with the
  raw failure text and original exit code preserved);
* complete 7/7 but any other assertion, an unwrap throw, a host/runner crash,
  a skipped case, a missing or extra case, 0 cases, a missing bundle or a
  forged log -> NOT_EXECUTED (fail closed, the workflow gates).

The last class also checks the Swift diagnostics suite against the helper's
fixed markers, so the two sides cannot drift apart silently.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = REPO_ROOT / "FloeAgent" / "scripts"
SWIFT_DIAGNOSTICS = (REPO_ROOT / "FloeAgent" / "Qualification" / "NativeNotes" /
                     "Tests" / "NotesOfficeThumbnailDiagnosticsTests.swift")
sys.path.insert(0, str(SCRIPTS))

import verify_quicklook_diagnostics as vqd  # noqa: E402

CONTENT_FAILURE = (
    'XCTAssertEqual failed: ("officeContentSummary") is not equal to '
    '("quickLookThumbnail") - budget-forecast.xlsx must come from a real Quick '
    'Look content representation, not officeContentSummary (native content '
    'summary) [floe-ql-diagnostic:content]'
)
TIMEOUT_FAILURE = (
    'XCTAssertFalse failed - budget-forecast.xlsx must settle with content, '
    'not the request deadline [floe-ql-diagnostic:timeout]'
)
ICON_FAILURE = (
    'XCTAssertFalse failed - budget-forecast.xlsx returned a generic file icon, '
    'not content [floe-ql-diagnostic:icon]'
)
# Regression text for the former `list(spec.get("extra", ()))` bug: every
# character of ("quickLookThumbnail") is present, but the expected-value token
# never is. The whole token must be required.
BROKEN_CONTENT_FAILURE = (
    'XCTAssertEqual failed: ("quickLookThumbnai") is not equal to ("l)") - '
    'budget-forecast.xlsx must come from a real Quick Look content '
    'representation [floe-ql-diagnostic:content]'
)
BUDGET = "NotesOfficeThumbnailDiagnosticsTests/testStrictQuickLookRendersExcelBudgetForecast"

XCRUN_STUB = r"""#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "xcresulttool" ]; then
  section=""
  path=""
  previous=""
  for argument in "$@"; do
    if [ "$previous" = "test-results" ]; then section="$argument"; fi
    if [ "$previous" = "--path" ]; then path="$argument"; fi
    previous="$argument"
  done
  key="$(basename "$path")"
  if [ -d "$path" ] && [ -n "${STUB_XCRESULT_JSON_DIR:-}" ] \
     && [ -f "$STUB_XCRESULT_JSON_DIR/$key.$section.json" ]; then
    cat "$STUB_XCRESULT_JSON_DIR/$key.$section.json"
    exit 0
  fi
  printf 'stub xcrun: no %s data for %s\n' "$section" "$path" >&2
  exit 1
fi
printf 'unexpected xcrun invocation: %s\n' "$*" >&2
exit 1
"""


def case(identifier, result="Passed", messages=(), source=None):
    node = {
        "nodeType": "Test Case",
        "name": identifier.split("/")[-1] + "()",
        "nodeIdentifier": identifier + "()",
        "result": result,
    }
    if messages:
        if source is None:
            source = "/Users/runner/work/floe-agent/floe-agent/FloeAgent/Qualification/"
            source += "NativeNotes/Tests/{}".format(vqd.DIAGNOSTIC_SOURCE)
        node["children"] = [
            {
                "nodeType": "Failure Message",
                "name": message,
                "sourceLocation": {"filePath": source, "lineNumber": 120 + index},
            }
            for index, message in enumerate(messages)
        ]
    return node


def tests_tree(failures=None, *, skipped=(), only=None, unlocated=(), wrong_source=()):
    """Build the real ``xcresulttool get test-results tests`` shape."""
    failures = failures or {}
    case_names = list(only) if only is not None else sorted(vqd.EXPECTED_CASES)
    cases = []
    for identifier in case_names:
        if identifier in skipped:
            cases.append(case(identifier, result="Skipped"))
        elif identifier in failures:
            messages = failures[identifier]
            if identifier in unlocated:
                cases.append(case(identifier, result="Failed", messages=messages,
                                  source=""))
            elif identifier in wrong_source:
                cases.append(case(
                    identifier, result="Failed", messages=messages,
                    source="/tmp/NotesOfficeThumbnailTests.swift"))
            else:
                cases.append(case(identifier, result="Failed", messages=messages))
        else:
            cases.append(case(identifier))
    return {
        "testNodes": [{
            "nodeType": "Test Plan",
            "name": "FloeNotesNativeQualification",
            "result": "Failed" if failures else "Passed",
            "children": [{
                "nodeType": "Unit test bundle",
                "name": "NativeNotesTests",
                "result": "Failed" if failures else "Passed",
                "children": cases,
            }],
        }],
    }


def summary(total=7, passed=7, failed=0, skipped=0, expected_failures=0,
            warnings=(), result=None):
    if result is None:
        result = "Failed" if failed else "Passed"
    return {
        "devicesAndConfigurations": [{"device": {"deviceName": "iPad Air 13-inch (M4)"}}],
        "environmentDescription": "FloeNotesNativeQualification fixture",
        "expectedFailures": expected_failures,
        "failedTests": failed,
        "passedTests": passed,
        "result": result,
        "runtimeWarnings": list(warnings),
        "skippedTests": skipped,
        "totalTestCount": total,
    }


class VerifyStructureTests(unittest.TestCase):
    """Direct calls to the helper's classifier (no subprocess, no Xcode)."""

    def test_complete_seven_of_seven_pass_is_pass(self):
        evidence = vqd.verify(summary(), tests_tree(), original_exit=0, family="iPad")
        self.assertEqual(evidence["classification"], "PASS")
        self.assertEqual(evidence["executed"], 7)
        self.assertEqual(evidence["failures"], 0)
        self.assertEqual(evidence["original_exit"], 0)
        self.assertEqual(evidence["failure_originals"], [])

    def test_allowed_quicklook_content_failure_is_non_gating(self):
        evidence = vqd.verify(
            summary(passed=6, failed=1), tests_tree({BUDGET: [CONTENT_FAILURE]}),
            original_exit=65, family="iPad")
        self.assertEqual(evidence["classification"], "ASSERTION_FAILURE")
        self.assertEqual(evidence["failures"], 1)
        self.assertIn("XCTAssertEqual failed", evidence["failure_originals"][0])
        self.assertIn("[floe-ql-diagnostic:content]", evidence["failure_originals"][0])

    def test_content_marker_requires_the_whole_quicklook_expected_value(self):
        # Each character of ("quickLookThumbnail") appears in the message, but
        # the token itself does not: the classifier must still gate.
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(passed=6, failed=1),
                       tests_tree({BUDGET: [BROKEN_CONTENT_FAILURE]}),
                       original_exit=65)

    def test_allowed_timeout_and_icon_failures_are_non_gating(self):
        for marker_failure in (TIMEOUT_FAILURE, ICON_FAILURE):
            with self.subTest(failure=marker_failure[-40:]):
                evidence = vqd.verify(
                    summary(passed=6, failed=1),
                    tests_tree({BUDGET: [marker_failure]}),
                    original_exit=vqd.TEST_FAILURE_EXIT, family="iPad")
                self.assertEqual(evidence["classification"], "ASSERTION_FAILURE")

    def test_test_failure_exit_must_be_exactly_65(self):
        # 124/137/143 and any other non-zero code are timeouts/kills/crashes,
        # never a test-content failure, even with a complete marked run.
        for exit_code in (124, 137, 143, 1, 70, 71):
            with self.subTest(exit_code=exit_code):
                with self.assertRaises(vqd.NotExecuted):
                    vqd.verify(summary(passed=6, failed=1),
                               tests_tree({BUDGET: [CONTENT_FAILURE]}),
                               original_exit=exit_code)

    def test_complete_run_with_other_assertion_fails_closed(self):
        unexpected = 'XCTAssertTrue failed - the staged copy must exist'
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(passed=6, failed=1), tests_tree({BUDGET: [unexpected]}),
                       original_exit=65)

    def test_throw_or_unwrap_failure_fails_closed(self):
        thrown = 'XCTUnwrap failed: expected non-nil value - file.docx cover must be an actual image'
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(passed=6, failed=1), tests_tree({BUDGET: [thrown]}),
                       original_exit=65)

    def test_marker_copied_onto_the_wrong_assertion_shape_fails_closed(self):
        wrong_shape = 'XCTAssertTrue failed - something else [floe-ql-diagnostic:content]'
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(passed=6, failed=1), tests_tree({BUDGET: [wrong_shape]}),
                       original_exit=65)

    def test_two_markers_on_one_failure_fails_closed(self):
        doubled = CONTENT_FAILURE + " " + TIMEOUT_FAILURE
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(passed=6, failed=1), tests_tree({BUDGET: [doubled]}),
                       original_exit=65)

    def test_complete_pass_with_nonzero_exit_is_a_crash_or_runner_failure(self):
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(), tests_tree(), original_exit=65)

    def test_failed_run_with_zero_exit_is_inconsistent(self):
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(passed=6, failed=1), tests_tree({BUDGET: [CONTENT_FAILURE]}),
                       original_exit=0)

    def test_runtime_warning_fails_closed_even_with_complete_pass(self):
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(warnings=["Restarting after unexpected exit"]),
                       tests_tree(), original_exit=0)

    def test_zero_cases_fail_closed(self):
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(total=0, passed=0), tests_tree(only=[]), original_exit=0)

    def test_partial_execution_fails_closed(self):
        partial = sorted(vqd.EXPECTED_CASES)[:3]
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(total=3, passed=3), tests_tree(only=partial), original_exit=0)

    def test_missing_case_fails_closed(self):
        partial = sorted(vqd.EXPECTED_CASES)[:-1]
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(total=6, passed=6), tests_tree(only=partial), original_exit=0)

    def test_extra_unexpected_case_fails_closed(self):
        extra = sorted(vqd.EXPECTED_CASES) + ["NotesOfficeThumbnailDiagnosticsTests/testNewDiagnostic"]
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(total=8, passed=8), tests_tree(only=extra), original_exit=0)

    def test_skipped_case_fails_closed(self):
        skipped = sorted(vqd.EXPECTED_CASES)[:1]
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(total=7, passed=6, skipped=1),
                       tests_tree(skipped=set(skipped)), original_exit=0)

    def test_summary_and_tree_failure_counts_must_agree(self):
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(passed=6, failed=1), tests_tree(), original_exit=65)

    def test_content_marker_on_the_cover_service_method_is_allowed(self):
        # The cover-service method contains the same source-content assertion.
        evidence = vqd.verify(
            summary(passed=6, failed=1),
            tests_tree({vqd.COVER_SERVICE_CASE: [CONTENT_FAILURE]}),
            original_exit=65)
        self.assertEqual(evidence["classification"], "ASSERTION_FAILURE")

    def test_timeout_marker_is_only_allowed_on_a_strict_sample_method(self):
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(passed=6, failed=1),
                       tests_tree({vqd.COVER_SERVICE_CASE: [TIMEOUT_FAILURE]}),
                       original_exit=65)

    def test_icon_marker_is_only_allowed_on_a_strict_sample_method(self):
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(passed=6, failed=1),
                       tests_tree({vqd.COVER_SERVICE_CASE: [ICON_FAILURE]}),
                       original_exit=65)

    def test_allowed_marker_without_a_source_location_fails_closed(self):
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(passed=6, failed=1),
                       tests_tree({BUDGET: [CONTENT_FAILURE]}, unlocated={BUDGET}),
                       original_exit=65)

    def test_allowed_marker_from_another_source_file_fails_closed(self):
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(passed=6, failed=1),
                       tests_tree({BUDGET: [CONTENT_FAILURE]}, wrong_source={BUDGET}),
                       original_exit=65)

    def test_unknown_summary_result_fails_closed(self):
        with self.assertRaises(vqd.NotExecuted):
            vqd.verify(summary(result="Unknown"), tests_tree(), original_exit=0)


class CliFixture:
    """A temp repo-like tree with a fake xcresult bundle and stub xcrun."""

    def __init__(self, root):
        self.root = Path(root)
        self.bin_dir = self.root / "bin"
        self.json_dir = self.root / "json"
        self.bin_dir.mkdir(parents=True, exist_ok=True)
        self.json_dir.mkdir(parents=True, exist_ok=True)
        stub = self.bin_dir / "xcrun"
        stub.write_text(XCRUN_STUB, encoding="utf-8")
        stub.chmod(0o755)
        self.bundle = self.root / "notes-diagnostic-iPad.xcresult"
        self.log = self.root / "notes-diagnostic-iPad.log"
        self.status = self.root / "notes-diagnostic-iPad.status"
        self.failures = self.root / "notes-diagnostic-iPad.status.failures.txt"

    def make_bundle(self, summary_payload, tests_payload):
        self.bundle.mkdir(parents=True, exist_ok=True)
        (self.bundle / "Info.plist").write_text("fixture\n", encoding="utf-8")
        key = self.bundle.name
        (self.json_dir / "{}.summary.json".format(key)).write_text(
            json.dumps(summary_payload), encoding="utf-8")
        (self.json_dir / "{}.tests.json".format(key)).write_text(
            json.dumps(tests_payload), encoding="utf-8")

    def write_log(self, text="fixture xcodebuild log\n"):
        self.log.write_text(text, encoding="utf-8")

    def run_cli(self, original_exit="0"):
        environment = dict(os.environ)
        environment["PATH"] = "{}{}{}".format(
            self.bin_dir, os.pathsep, environment.get("PATH", ""))
        environment["STUB_XCRESULT_JSON_DIR"] = str(self.json_dir)
        return subprocess.run(
            [sys.executable, str(SCRIPTS / "verify_quicklook_diagnostics.py"),
             "--result-bundle", str(self.bundle),
             "--log", str(self.log),
             "--family", "iPad",
             "--original-exit", original_exit,
             "--status-output", str(self.status),
             "--failures-output", str(self.failures)],
            env=environment, capture_output=True, text=True)

    def status_text(self):
        return self.status.read_text(encoding="utf-8")

    def failures_text(self):
        return self.failures.read_text(encoding="utf-8")


class CliContractTests(unittest.TestCase):
    """The helper through its real CLI and the real xcresulttool call shape."""

    def test_cli_pass_records_status_and_original_exit(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = CliFixture(root)
            fixture.make_bundle(summary(), tests_tree())
            fixture.write_log()
            result = fixture.run_cli("0")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "PASS")
            status = fixture.status_text()
            self.assertIn("classification=PASS", status)
            self.assertIn("executed=7", status)
            self.assertIn("failures=0", status)
            self.assertIn("bundle=present", status)
            self.assertIn("original exit=0", status)
            self.assertEqual(fixture.failures_text(), "")

    def test_cli_allowed_failure_is_recorded_not_gating(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = CliFixture(root)
            fixture.make_bundle(summary(passed=6, failed=1),
                                tests_tree({BUDGET: [CONTENT_FAILURE]}))
            fixture.write_log()
            result = fixture.run_cli("65")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "ASSERTION_FAILURE")
            status = fixture.status_text()
            self.assertIn("classification=ASSERTION_FAILURE", status)
            self.assertIn("executed=7", status)
            self.assertIn("failures=1", status)
            self.assertIn("original exit=65", status)
            self.assertIn("XCTAssertEqual failed", fixture.failures_text())
            self.assertIn("[floe-ql-diagnostic:content]", fixture.failures_text())

    def test_cli_forged_log_with_zero_case_bundle_fails_closed(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = CliFixture(root)
            fixture.make_bundle(summary(total=0, passed=0), tests_tree(only=[]))
            fixture.write_log(
                "Test Suite 'NotesOfficeThumbnailDiagnosticsTests' passed at 2026-09-18\n"
                "Executed 7 tests, with 0 failures (0 unexpected) in 1.000 seconds\n"
                "** TEST SUCCEEDED **\n")
            result = fixture.run_cli("0")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "NOT_EXECUTED")
            self.assertIn("classification=NOT_EXECUTED", fixture.status_text())

    def test_cli_missing_bundle_fails_closed(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = CliFixture(root)
            # No bundle is created; the stub xcrun must refuse to serve JSON.
            fixture.write_log()
            result = fixture.run_cli("0")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "NOT_EXECUTED")
            status = fixture.status_text()
            self.assertIn("classification=NOT_EXECUTED", status)
            self.assertIn("bundle=missing", status)
            self.assertIn("original exit=0", status)

    def test_cli_unmarked_failure_fails_closed(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = CliFixture(root)
            fixture.make_bundle(
                summary(passed=6, failed=1),
                tests_tree({BUDGET: ["XCTAssertTrue failed - staged copy leaked"]}))
            fixture.write_log()
            result = fixture.run_cli("65")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "NOT_EXECUTED")
            self.assertIn("classification=NOT_EXECUTED", fixture.status_text())
            self.assertIn("staged copy leaked", fixture.failures_text())

    def test_cli_missing_log_is_an_evidence_gap(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = CliFixture(root)
            fixture.make_bundle(summary(), tests_tree())
            # no log written
            result = fixture.run_cli("0")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), "NOT_EXECUTED")
            self.assertIn("classification=NOT_EXECUTED", fixture.status_text())


class SwiftMarkerContractTests(unittest.TestCase):
    """The Swift suite and the Python marker set must not drift apart."""

    def test_swift_markers_match_the_helper_exactly(self):
        source = SWIFT_DIAGNOSTICS.read_text(encoding="utf-8")
        for category, spec in vqd.ALLOWED_FAILURE_MARKERS.items():
            with self.subTest(category=category):
                self.assertEqual(source.count('"{}"'.format(spec["marker"])), 1,
                                 "each marker must be declared exactly once in Swift")
                self.assertIn(spec["detail"], source,
                              "each allowed marker must bind to the exact assertion phrase "
                              "that exists in the Swift diagnostics source")

    def test_only_explicit_quicklook_assertions_carry_markers(self):
        source = SWIFT_DIAGNOSTICS.read_text(encoding="utf-8")
        self.assertEqual(source.count("QuickLookDiagnosticMarker.content"), 2,
                         "content marker: cover-service source assertion + strict sample source assertion")
        self.assertEqual(source.count("QuickLookDiagnosticMarker.timeout"), 1)
        self.assertEqual(source.count("QuickLookDiagnosticMarker.icon"), 1)
        # Resource invariants stay unmarked so an unexpected error cannot pass
        # as a permitted Quick Look outage.
        for unmarked in ("XCTUnwrap(outcome.image",
                         "XCTAssertGreaterThan(image.size.width, 0",
                         "XCTAssertNotNil(image.cgImage"):
            self.assertIn(unmarked, source)
            marker_window = source.split(unmarked, 1)[1].split(")", 1)[0]
            self.assertNotIn("floe-ql-diagnostic", marker_window)


if __name__ == "__main__":
    unittest.main()
