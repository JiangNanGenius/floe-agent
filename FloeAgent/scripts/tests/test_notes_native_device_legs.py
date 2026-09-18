"""Executed-shell regression tests for the Notes native dual-device legs.

``.github/workflows/notes-native-qualification.yml`` qualifies the native Notes
component host on an iPad simulator first and an iPhone simulator second inside
one ``shell: bash`` step. GitHub executes that step as
``/bin/bash --noprofile --norc -e -o pipefail {0}`` (development job log of run
35299478950, where the iPad leg's exit 65 aborted the step before any iPhone leg
ran). These tests extract the real ``run:`` scripts from the workflow and
execute them under that exact strict shell, driving them with stub
``xcodebuild``/``xcrun`` binaries on a temporary PATH. No simulator is booted,
no Xcode project is generated and no real build or test is launched.

Covered per extracted script (development and compatibility jobs):

* both families pass, iPad before iPhone;
* the iPad leg fails and iPhone still runs, the iPad status is kept as the
  aggregate step status and the iPad log/result bundle are preserved;
* the iPhone leg fails after a passing iPad and its own status is kept;
* a missing iPad simulator fails that family explicitly and the iPhone family
  still runs;
* a missing iPhone simulator fails explicitly after the iPad family passed;
* a failing ``| tee`` log pipeline is not silently treated as a pass;
* the separate ``Run strict Quick Look diagnostics (diagnostic, non-gating)``
  step runs the strict diagnostic class on both families with its own result
  bundle, log and recorded original exit code; only a fully executed 7/7 run
  with xcodebuild's test-failure exit 65 whose only failures are the fixed QL
  assertion markers is non-gating, while an empty selector, a partial run, a
  skipped case, a missing result bundle, a forged log, a timeout/kill exit or
  any other assertion failure fails the step as a coverage gap.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "notes-native-qualification.yml"
STEP_NAME = "Test iPad first, then iPhone"
DIAGNOSTIC_STEP_NAME = "Run strict Quick Look diagnostics (diagnostic, non-gating)"
STRICT_DIAGNOSTIC_CLASS = "NativeNotesTests/NotesOfficeThumbnailDiagnosticsTests"
# The observed GitHub Actions runner shell (`shell: bash`) command line.
BASH = "/bin/bash" if Path("/bin/bash").exists() else "bash"
# A global `set +e` line, as opposed to the token appearing in a comment.
GLOBAL_ERREXIT_OFF = re.compile(r"(?m)^\s*set \+e\b")


def existing_developer_dir():
    """A real DEVELOPER_DIR so the macOS /usr/bin/python3 shim can run.

    The workflow step only echoes this variable, but the fixture invokes the
    real ``python3`` for destination selection; pointing DEVELOPER_DIR at a
    non-existent Xcode would break that shim before the selection code runs.
    """
    candidates = [os.environ.get("DEVELOPER_DIR", "")]
    try:
        selected = subprocess.run(
            ["xcode-select", "-p"], capture_output=True, text=True)
        candidates.append(selected.stdout.strip())
    except OSError:
        pass
    candidates.extend([
        "/Library/Developer/CommandLineTools",
        "/Applications/Xcode.app/Contents/Developer",
    ])
    for candidate in candidates:
        if candidate and Path(candidate).is_dir():
            return candidate
    raise AssertionError("no existing DEVELOPER_DIR found for the fixture")

IPAD_DESTINATION = "IPAD-AIR-UDID"
IPHONE_DESTINATION = "IPHONE-17PRO-UDID"

XCODEBUILD_STUB = r"""#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-version" ]; then
  printf 'Xcode 27.0\nBuild version 27A266a\n'
  exit 0
fi
result_bundle=""
destination=""
previous=""
for argument in "$@"; do
  if [ "$previous" = "-resultBundlePath" ]; then
    result_bundle="$argument"
  fi
  if [ "$previous" = "-destination" ]; then
    destination="$argument"
  fi
  previous="$argument"
done
family="${result_bundle#notes-}"
family="${family%.xcresult}"
printf 'RUN family=%s destination=%s\n' "$family" "$destination" >> "$STUB_INVOCATION_LOG"
if [ -n "${STUB_RESULT_CONTENT_DIR:-}" ] && [ -f "$STUB_RESULT_CONTENT_DIR/$family" ]; then
  cat "$STUB_RESULT_CONTENT_DIR/$family"
else
  printf 'stub xcodebuild ran the %s leg\n' "$family"
fi
if [ -n "$result_bundle" ]; then
  if [ -z "${STUB_SKIP_BUNDLE_DIR:-}" ] || [ ! -f "$STUB_SKIP_BUNDLE_DIR/$family" ]; then
    mkdir -p "$result_bundle"
    printf 'stub xcresult for %s\n' "$family" > "$result_bundle/Info.plist"
  fi
fi
if [ -f "$STUB_EXIT_DIR/$family" ]; then
  exit "$(cat "$STUB_EXIT_DIR/$family")"
fi
exit 0
"""

XCRUN_STUB = r"""#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "simctl" ] && [ "${2:-}" = "list" ]; then
  cat "$STUB_DEVICES_JSON"
  exit 0
fi
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


def device_payload(*, include_ipad=True, include_iphone=True):
    """Minimal ``xcrun simctl list devices available -j`` payload.

    Each family carries two candidates so the real destination-selection
    snippet in the workflow decides the UDID: the Air 13 iPad and the iPhone 17
    Pro must win over the iPad Pro and the iPhone 16e.
    """
    devices = []
    if include_ipad:
        devices.extend([
            {"name": "iPad Pro (M4)", "udid": "IPAD-PRO-UDID",
             "isAvailable": True, "state": "Shutdown"},
            {"name": "iPad Air 13-inch (M4)", "udid": IPAD_DESTINATION,
             "isAvailable": True, "state": "Shutdown"},
        ])
    if include_iphone:
        devices.extend([
            {"name": "iPhone 16e", "udid": "IPHONE-16E-UDID",
             "isAvailable": True, "state": "Shutdown"},
            {"name": "iPhone 17 Pro", "udid": IPHONE_DESTINATION,
             "isAvailable": True, "state": "Shutdown"},
        ])
    return {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-27-0": devices}}


DIAGNOSTIC_CLASS = "NotesOfficeThumbnailDiagnosticsTests"
DIAGNOSTIC_CASES = 7

DIAGNOSTIC_CASE_IDS = (
    "NotesOfficeThumbnailDiagnosticsTests/testStrictQuickLookRendersWordBusinessWeekly",
    "NotesOfficeThumbnailDiagnosticsTests/testStrictQuickLookRendersWordMeetingNotes",
    "NotesOfficeThumbnailDiagnosticsTests/testStrictQuickLookRendersExcelQuarterlySummary",
    "NotesOfficeThumbnailDiagnosticsTests/testStrictQuickLookRendersExcelBudgetForecast",
    "NotesOfficeThumbnailDiagnosticsTests/testStrictQuickLookRendersPowerPointProductRoadmap",
    "NotesOfficeThumbnailDiagnosticsTests/testStrictQuickLookRendersPowerPointDesignReview",
    "NotesOfficeThumbnailDiagnosticsTests/testCoverServiceReturnsQuickLookContentForEachOfficeType",
)

# The fixed marker the Swift diagnostics suite attaches only to the explicit
# system-Quick-Look-unavailable content assertion.
QUICKLOOK_CONTENT_MARKER = "[floe-ql-diagnostic:content]"
CONTENT_ASSERTION_FAILURE = (
    'XCTAssertEqual failed: ("officeContentSummary") is not equal to '
    '("quickLookThumbnail") - budget-forecast.xlsx must come from a real Quick '
    'Look content representation, not officeContentSummary (native content '
    'summary) ' + QUICKLOOK_CONTENT_MARKER
)


def diagnostic_case_node(identifier, result="Passed", messages=()):
    node = {
        "nodeType": "Test Case",
        "name": identifier.split("/")[-1] + "()",
        "nodeIdentifier": identifier + "()",
        "result": result,
    }
    if messages:
        node["children"] = [
            {
                "nodeType": "Failure Message",
                "name": message,
                "sourceLocation": {
                    "filePath": ("/Users/runner/work/floe-agent/floe-agent/FloeAgent/"
                                 "Qualification/NativeNotes/Tests/NotesOfficeThumbnailDiagnosticsTests.swift"),
                    "lineNumber": 120 + index,
                },
            }
            for index, message in enumerate(messages)
        ]
    return node


def diagnostic_tests(case_ids=DIAGNOSTIC_CASE_IDS, failures=None, skipped=()):
    """A real ``xcresulttool get test-results tests`` shape."""
    failures = failures or {}
    cases = []
    for identifier in case_ids:
        if identifier in skipped:
            cases.append(diagnostic_case_node(identifier, result="Skipped"))
        elif identifier in failures:
            cases.append(diagnostic_case_node(
                identifier, result="Failed", messages=failures[identifier]))
        else:
            cases.append(diagnostic_case_node(identifier))
    return {"testNodes": [{
        "nodeType": "Test Plan",
        "name": "FloeNotesNativeQualification",
        "result": "Failed" if failures else "Passed",
        "children": [{
            "nodeType": "Unit test bundle",
            "name": "NativeNotesTests",
            "result": "Failed" if failures else "Passed",
            "children": cases,
        }],
    }]}


def diagnostic_summary(total=DIAGNOSTIC_CASES, passed=DIAGNOSTIC_CASES, failed=0,
                       skipped=0, expected_failures=0, warnings=()):
    """A real ``xcresulttool get test-results summary`` shape."""
    return {
        "devicesAndConfigurations": [
            {"device": {"deviceName": "iPad Air 13-inch (M4)", "platform": "iOS Simulator"}}],
        "environmentDescription": "FloeNotesNativeQualification fixture",
        "expectedFailures": expected_failures,
        "failedTests": failed,
        "passedTests": passed,
        "result": "Failed" if failed else "Passed",
        "runtimeWarnings": list(warnings),
        "skippedTests": skipped,
        "totalTestCount": total,
    }


def passing_diagnostic_bundle():
    return {"summary": diagnostic_summary(), "tests": diagnostic_tests()}


def failing_diagnostic_bundle(identifier=DIAGNOSTIC_CASE_IDS[3],
                              message=CONTENT_ASSERTION_FAILURE):
    return {
        "summary": diagnostic_summary(passed=DIAGNOSTIC_CASES - 1, failed=1),
        "tests": diagnostic_tests(failures={identifier: [message]}),
    }


def diagnostic_log(executed=DIAGNOSTIC_CASES, failures=0, extra=()):
    """A realistic xcodebuild/XCTest log for the strict diagnostic class."""
    suite_state = "passed" if failures == 0 else "failed"
    plural = "failure" if failures == 1 else "failures"
    lines = [
        "Test Suite 'Selected tests' started at 2026-09-18 00:00:00.000",
        "Test Suite '{}' started at 2026-09-18 00:00:01.000".format(DIAGNOSTIC_CLASS),
        "Test Case '-[NativeNotesTests.{} testCoverServiceReturnsQuickLookContentForEachOfficeType]' {}.".format(
            DIAGNOSTIC_CLASS, suite_state),
        "Executed {} tests, with {} {} (0 unexpected) in 1.000 seconds".format(
            executed, failures, plural),
        "Test Suite '{}' {} at 2026-09-18 00:00:02.000".format(DIAGNOSTIC_CLASS, suite_state),
        "Executed {} tests, with {} {} (0 unexpected) in 2.000 seconds".format(
            executed, failures, plural),
        "** TEST {} **".format("SUCCEEDED" if failures == 0 else "FAILED"),
    ]
    lines.extend(extra)
    return "\n".join(lines) + "\n"


def diagnostic_assertion_failure_log(executed=DIAGNOSTIC_CASES, failures=1):
    return diagnostic_log(executed=executed, failures=failures, extra=[
        "NotesOfficeThumbnailDiagnosticsTests.swift:141: error: "
        "-[NativeNotesTests.{} testStrictQuickLookRendersExcelBudgetForecast] : "
        "XCTAssertEqual failed: (\"officeContentSummary\") is not equal to (\"quickLookThumbnail\")".format(
            DIAGNOSTIC_CLASS),
    ])


def diagnostic_zero_tests_log():
    return "\n".join([
        "Test Suite 'Selected tests' started at 2026-09-18 00:00:00.000",
        "Test Suite 'Selected tests' passed at 2026-09-18 00:00:00.500",
        "Executed 0 tests, with 0 failures (0 unexpected) in 0.001 seconds",
        "** TEST SUCCEEDED **",
    ]) + "\n"


def diagnostic_launch_failure_log():
    return "\n".join([
        "Test Suite 'Selected tests' started at 2026-09-18 00:00:00.000",
        "Early unexpected exit, operation never finished bootstrapping - no restart will be attempted",
        "Testing failed:",
        "  Test runner exited before starting test execution.",
        "** TEST FAILED **",
    ]) + "\n"


def extract_step_scripts(workflow_text, step_name=STEP_NAME):
    """Return ``(job, script)`` for every step named ``step_name``.

    The extraction is indentation based so the tests do not need a YAML
    dependency, and it fails loudly if the workflow shape changes instead of
    silently testing nothing.
    """
    lines = workflow_text.splitlines()
    steps = []
    job = "unknown"
    index = 0
    while index < len(lines):
        line = lines[index]
        job_match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if job_match:
            job = job_match.group(1)
            index += 1
            continue
        if line.strip() != "- name: {}".format(step_name):
            index += 1
            continue
        indent = len(line) - len(line.lstrip(" "))
        run_index = index + 1
        while run_index < len(lines) and lines[run_index].strip() != "run: |":
            run_index += 1
        if run_index >= len(lines):
            raise AssertionError("no 'run: |' block for step {!r}".format(step_name))
        body = []
        body_indent = None
        cursor = run_index + 1
        while cursor < len(lines):
            current = lines[cursor]
            if current.strip():
                current_indent = len(current) - len(current.lstrip(" "))
                if current_indent <= indent:
                    break
                if body_indent is None:
                    body_indent = current_indent
            body.append(current)
            cursor += 1
        if body_indent is None:
            raise AssertionError("empty 'run: |' block for step {!r}".format(step_name))
        script = "\n".join(
            current[body_indent:] if current.strip() else "" for current in body)
        steps.append((job, script + "\n"))
        index = cursor
    return steps


def write_stub(path, body):
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)


class ExecutedStep:
    def __init__(self, completed, work, runner_temp, invocations):
        self.returncode = completed.returncode
        self.stdout = completed.stdout
        self.stderr = completed.stderr
        self.work = work
        self.runner_temp = runner_temp
        self.invocations = invocations

    @property
    def runs(self):
        entries = []
        for line in self.invocations:
            match = re.match(r"RUN family=(\S+) destination=(.*)$", line)
            if match:
                entries.append({"family": match.group(1),
                                "destination": match.group(2)})
        return entries

    @property
    def families(self):
        return [entry["family"] for entry in self.runs]

    def destination(self, family):
        for entry in self.runs:
            if entry["family"] == family:
                return entry["destination"]
        return None

    def output(self):
        return self.stdout + self.stderr


def execute_step(script, root, *, devices, exit_codes=None,
                 ipad_log_is_directory=False, result_content=None,
                 skip_bundle=None, xcresult_json=None):
    """Execute one extracted step script under the GitHub Actions bash flags.

    ``xcresult_json`` maps a diagnostic family to its real xcresult
    summary/tests payloads; the stub ``xcrun xcresulttool`` serves them, so the
    workflow's helper really parses structures instead of a log line.
    """
    root = Path(root)
    bin_dir = root / "bin"
    runner_temp = root / "runner"
    work = root / "work"
    exit_dir = root / "exits"
    content_dir = root / "results"
    skip_dir = root / "skip-bundle"
    json_dir = root / "xcresult-json"
    for directory in (bin_dir, runner_temp, work, exit_dir, content_dir, skip_dir, json_dir):
        directory.mkdir(parents=True, exist_ok=True)
    write_stub(bin_dir / "xcodebuild", XCODEBUILD_STUB)
    write_stub(bin_dir / "xcrun", XCRUN_STUB)
    devices_json = root / "devices.json"
    devices_json.write_text(json.dumps(devices), encoding="utf-8")
    for family, code in (exit_codes or {}).items():
        (exit_dir / family).write_text("{}\n".format(code), encoding="utf-8")
    for family, content in (result_content or {}).items():
        (content_dir / family).write_text(content, encoding="utf-8")
    for family in (skip_bundle or set()):
        (skip_dir / family).write_text("skip\n", encoding="utf-8")
    for family, payload in (xcresult_json or {}).items():
        bundle = "notes-{}.xcresult".format(family)
        (json_dir / "{}.summary.json".format(bundle)).write_text(
            json.dumps(payload["summary"]), encoding="utf-8")
        (json_dir / "{}.tests.json".format(bundle)).write_text(
            json.dumps(payload["tests"]), encoding="utf-8")
    script_path = root / "step.sh"
    script_path.write_text(script, encoding="utf-8")
    if ipad_log_is_directory:
        (work / "notes-iPad.log").mkdir()
    invocation_log = root / "invocations.txt"
    environment = dict(os.environ)
    environment.update({
        "PATH": "{}{}{}".format(bin_dir, os.pathsep, environment.get("PATH", "")),
        "RUNNER_TEMP": str(runner_temp),
        "GITHUB_WORKSPACE": str(REPO_ROOT),
        "DEVELOPER_DIR": existing_developer_dir(),
        "STUB_DEVICES_JSON": str(devices_json),
        "STUB_EXIT_DIR": str(exit_dir),
        "STUB_INVOCATION_LOG": str(invocation_log),
        "STUB_RESULT_CONTENT_DIR": str(content_dir),
        "STUB_SKIP_BUNDLE_DIR": str(skip_dir),
        "STUB_XCRESULT_JSON_DIR": str(json_dir),
    })
    completed = subprocess.run(
        [BASH, "--noprofile", "--norc", "-e", "-o", "pipefail", str(script_path)],
        cwd=str(work), env=environment, capture_output=True, text=True)
    invocations = []
    if invocation_log.exists():
        invocations = invocation_log.read_text(encoding="utf-8").splitlines()
    return ExecutedStep(completed, work, runner_temp, invocations)


class DeviceLegExecutionTests(unittest.TestCase):
    def setUp(self):
        self.scripts = extract_step_scripts(WORKFLOW.read_text(encoding="utf-8"))
        self.assertEqual(
            len(self.scripts), 2,
            "expected the dual-device step in exactly the development and "
            "compatibility jobs")

    def test_both_legs_pass_and_run_ipad_then_iphone(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                run = execute_step(script, root, devices=device_payload())
                self.assertEqual(run.returncode, 0, run.output())
                self.assertEqual(run.families, ["iPad", "iPhone"], run.output())
                self.assertIn("id={}".format(IPAD_DESTINATION),
                              run.destination("iPad"))
                self.assertIn("id={}".format(IPHONE_DESTINATION),
                              run.destination("iPhone"))
                for family in ("iPad", "iPhone"):
                    log = run.work / "notes-{}.log".format(family)
                    self.assertTrue(log.is_file(), log)
                    self.assertIn("stub xcodebuild ran the {} leg".format(family),
                                  log.read_text(encoding="utf-8"))
                    self.assertTrue(
                        (run.work / "notes-{}.xcresult".format(family)).is_dir())
                self.assertNotIn("::error::", run.output())

    def test_ipad_failure_still_runs_iphone_and_keeps_first_status(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                run = execute_step(script, root, devices=device_payload(),
                                   exit_codes={"iPad": 65})
                self.assertEqual(run.returncode, 65, run.output())
                self.assertEqual(run.families, ["iPad", "iPhone"], run.output())
                self.assertTrue((run.work / "notes-iPad.log").is_file())
                self.assertTrue((run.work / "notes-iPad.xcresult").is_dir(),
                                "the failing iPad result bundle is preserved")
                iphone_log = run.work / "notes-iPhone.log"
                self.assertTrue(iphone_log.is_file())
                self.assertIn("stub xcodebuild ran the iPhone leg",
                              iphone_log.read_text(encoding="utf-8"))
                self.assertIn("iPad leg failed with exit 65", run.output())
                self.assertIn("first device-family failure exit 65",
                              run.output())

    def test_iphone_failure_keeps_its_own_status(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                run = execute_step(script, root, devices=device_payload(),
                                   exit_codes={"iPhone": 66})
                self.assertEqual(run.returncode, 66, run.output())
                self.assertEqual(run.families, ["iPad", "iPhone"], run.output())
                self.assertIn("iPhone leg failed with exit 66", run.output())
                self.assertNotIn("iPad leg failed", run.output())

    def test_first_failure_wins_when_both_families_fail(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                run = execute_step(script, root, devices=device_payload(),
                                   exit_codes={"iPad": 65, "iPhone": 70})
                self.assertEqual(run.returncode, 65, run.output())
                self.assertEqual(run.families, ["iPad", "iPhone"], run.output())
                self.assertIn("iPad leg failed with exit 65", run.output())
                self.assertIn("iPhone leg failed with exit 70", run.output())
                self.assertIn("first device-family failure exit 65",
                              run.output())

    def test_missing_ipad_device_fails_explicitly_and_iphone_still_runs(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                run = execute_step(script, root,
                                   devices=device_payload(include_ipad=False))
                self.assertNotEqual(run.returncode, 0, run.output())
                self.assertEqual(run.families, ["iPhone"], run.output())
                self.assertIn("::error::No iPad simulator destination resolved",
                              run.output())
                self.assertFalse((run.work / "notes-iPad.log").exists())
                self.assertTrue((run.work / "notes-iPhone.log").is_file())
                self.assertIn("first device-family failure exit",
                              run.output())

    def test_missing_iphone_device_fails_explicitly_after_ipad_passed(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                run = execute_step(
                    script, root, devices=device_payload(include_iphone=False))
                self.assertNotEqual(run.returncode, 0, run.output())
                self.assertEqual(run.families, ["iPad"], run.output())
                self.assertIn("::error::No iPhone simulator destination resolved",
                              run.output())
                self.assertTrue((run.work / "notes-iPad.log").is_file())
                self.assertFalse((run.work / "notes-iPhone.log").exists())

    def test_failed_log_pipeline_is_not_a_silent_pass(self):
        # xcodebuild succeeds but tee cannot write the iPad log (the path is a
        # directory), so the pipeline fails. Under `-e -o pipefail` the `||`
        # guard must turn that into the iPad leg's status, not a silent pass.
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                run = execute_step(script, root, devices=device_payload(),
                                   ipad_log_is_directory=True)
                self.assertEqual(run.returncode, 1, run.output())
                self.assertEqual(run.families, ["iPad", "iPhone"], run.output())
                self.assertIn("iPad leg failed with exit 1", run.output())
                self.assertTrue((run.work / "notes-iPhone.log").is_file())


class DiagnosticStepExecutionTests(unittest.TestCase):
    """Executed-shell checks for the strict Quick Look diagnostic step.

    The strict ``NotesOfficeThumbnailDiagnosticsTests`` class is excluded from
    the functional legs and run here on both device families with its own
    result bundle, log and recorded original exit code. The step classifies
    through ``FloeAgent/scripts/verify_quicklook_diagnostics.py`` reading the
    real xcresult summary/tests structures: a fully executed 7/7 run with
    xcodebuild's test-failure exit 65 whose only failures are the fixed-marker
    Quick Look content assertions is non-gating, while an empty selector, a
    partial run, a skipped or missing case, a missing result bundle, a
    runner/host crash, a forged log, a timeout/kill exit or any other assertion
    failure fails this step.
    """

    def setUp(self):
        self.scripts = extract_step_scripts(
            WORKFLOW.read_text(encoding="utf-8"), DIAGNOSTIC_STEP_NAME)
        self.assertEqual(
            len(self.scripts), 2,
            "expected the diagnostic step in exactly the development and "
            "compatibility jobs")

    def diagnostic_family(self, family):
        return "diagnostic-{}".format(family)

    def passing_content(self):
        return {self.diagnostic_family(family): diagnostic_log()
                for family in ("iPad", "iPhone")}

    def passing_xcresult(self):
        return {self.diagnostic_family(family): passing_diagnostic_bundle()
                for family in ("iPad", "iPhone")}

    def status_path(self, run, family):
        return (run.runner_temp / "notes-cloud-gates" /
                "notes-{}.status".format(self.diagnostic_family(family)))

    def failures_path(self, run, family):
        return Path(str(self.status_path(run, family)) + ".failures.txt")

    def test_both_legs_run_and_step_passes(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                run = execute_step(script, root, devices=device_payload(),
                                   result_content=self.passing_content(),
                                   xcresult_json=self.passing_xcresult())
                self.assertEqual(run.returncode, 0, run.output())
                self.assertEqual(
                    run.families,
                    [self.diagnostic_family("iPad"), self.diagnostic_family("iPhone")],
                    run.output())
                self.assertIn("id={}".format(IPAD_DESTINATION),
                              run.destination(self.diagnostic_family("iPad")))
                self.assertIn("id={}".format(IPHONE_DESTINATION),
                              run.destination(self.diagnostic_family("iPhone")))
                for family in ("iPad", "iPhone"):
                    diagnostic = self.diagnostic_family(family)
                    log = run.work / "notes-{}.log".format(diagnostic)
                    self.assertTrue(log.is_file(), log)
                    self.assertIn(DIAGNOSTIC_CLASS, log.read_text(encoding="utf-8"))
                    self.assertTrue(
                        (run.work / "notes-{}.xcresult".format(diagnostic)).is_dir())
                    status = self.status_path(run, family)
                    self.assertTrue(status.is_file(), status)
                    text = status.read_text(encoding="utf-8")
                    self.assertIn("classification=PASS", text)
                    self.assertIn("executed={}".format(DIAGNOSTIC_CASES), text)
                    self.assertIn("failures=0", text)
                    self.assertIn("bundle=present", text)
                    self.assertIn("original exit=0", text)
                self.assertNotIn("::error::", run.output())
                self.assertIn("diagnostic non-gating", run.output())
                self.assertIn("passed (7/7 executed)", run.output())

    def test_fully_executed_strict_assertion_failure_is_recorded_not_gating(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                content = {self.diagnostic_family(family): diagnostic_assertion_failure_log()
                           for family in ("iPad", "iPhone")}
                bundles = {self.diagnostic_family(family): failing_diagnostic_bundle()
                           for family in ("iPad", "iPhone")}
                run = execute_step(script, root, devices=device_payload(),
                                   exit_codes={"diagnostic-iPad": 65,
                                               "diagnostic-iPhone": 65},
                                   result_content=content,
                                   xcresult_json=bundles)
                self.assertEqual(run.returncode, 0,
                                 "a fully executed strict assertion failure must stay "
                                 "non-gating: " + run.output())
                self.assertEqual(
                    run.families,
                    [self.diagnostic_family("iPad"), self.diagnostic_family("iPhone")])
                for family, code in (("iPad", 65), ("iPhone", 65)):
                    status = self.status_path(run, family)
                    text = status.read_text(encoding="utf-8")
                    self.assertIn("classification=ASSERTION_FAILURE", text)
                    self.assertIn("executed={}".format(DIAGNOSTIC_CASES), text)
                    self.assertIn("failures=1", text)
                    self.assertIn("original exit={}".format(code), text)
                    failures = self.failures_path(run, family)
                    self.assertTrue(failures.is_file(), failures)
                    original = failures.read_text(encoding="utf-8")
                    self.assertIn("XCTAssertEqual failed", original)
                    self.assertIn(QUICKLOOK_CONTENT_MARKER, original)
                self.assertIn("diagnostic non-gating iPad strict Quick Look content "
                              "assertion failed after a complete 7/7 run (original exit 65)",
                              run.output())
                self.assertIn("diagnostic non-gating iPhone strict Quick Look content "
                              "assertion failed after a complete 7/7 run (original exit 65)",
                              run.output())
                self.assertNotIn("::error::", run.output())

    def test_non_test_failure_exit_with_a_marked_run_still_gates(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                # 124 (timeout) / 137 (killed) are not xcodebuild test
                # failures; the classifier must not swallow them even though
                # the complete 7/7 run already carries a marked QL failure.
                bundles = {self.diagnostic_family(family): failing_diagnostic_bundle()
                           for family in ("iPad", "iPhone")}
                run = execute_step(script, root, devices=device_payload(),
                                   exit_codes={"diagnostic-iPad": 124,
                                               "diagnostic-iPhone": 137},
                                   result_content=self.passing_content(),
                                   xcresult_json=bundles)
                self.assertNotEqual(run.returncode, 0,
                                    "a timeout/kill exit must gate: " + run.output())
                for family, code in (("iPad", 124), ("iPhone", 137)):
                    status = self.status_path(run, family)
                    text = status.read_text(encoding="utf-8")
                    self.assertIn("classification=NOT_EXECUTED", text)
                    self.assertIn("original exit={}".format(code), text)
                    failures = self.failures_path(run, family)
                    self.assertIn(QUICKLOOK_CONTENT_MARKER,
                                  failures.read_text(encoding="utf-8"))
                self.assertIn("::error::", run.output())

    def test_zero_selected_tests_with_a_forged_log_are_not_masked(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                # The tee'd log claims a clean 7/7 pass while the real result
                # bundle says nothing ran: the classifier must trust only the
                # xcresult structures.
                forged = (
                    "Test Suite '{}' passed at 2026-09-18 00:00:02.000\n"
                    "Executed 7 tests, with 0 failures (0 unexpected) in 2.000 seconds\n"
                    "** TEST SUCCEEDED **\n".format(DIAGNOSTIC_CLASS))
                content = {self.diagnostic_family(family): forged
                           for family in ("iPad", "iPhone")}
                bundles = {
                    self.diagnostic_family(family): {
                        "summary": diagnostic_summary(total=0, passed=0),
                        "tests": diagnostic_tests(case_ids=()),
                    } for family in ("iPad", "iPhone")}
                run = execute_step(script, root, devices=device_payload(),
                                   result_content=content, xcresult_json=bundles)
                self.assertNotEqual(run.returncode, 0,
                                    "an empty selector must fail the diagnostic step: "
                                    + run.output())
                for family in ("iPad", "iPhone"):
                    status = self.status_path(run, family)
                    text = status.read_text(encoding="utf-8")
                    self.assertIn("classification=NOT_EXECUTED", text)
                    self.assertIn("executed=0", text)
                self.assertIn("::error::", run.output())
                self.assertIn("did not fully execute", run.output())
                self.assertIn("coverage failure", run.output())

    def test_partial_execution_is_not_masked(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                bundles = {
                    self.diagnostic_family("iPad"): {
                        "summary": diagnostic_summary(total=3, passed=2, failed=1),
                        "tests": diagnostic_tests(
                            case_ids=DIAGNOSTIC_CASE_IDS[:3],
                            failures={DIAGNOSTIC_CASE_IDS[0]: [CONTENT_ASSERTION_FAILURE]}),
                    },
                    self.diagnostic_family("iPhone"): passing_diagnostic_bundle(),
                }
                run = execute_step(script, root, devices=device_payload(),
                                   exit_codes={"diagnostic-iPad": 65},
                                   result_content=self.passing_content(),
                                   xcresult_json=bundles)
                self.assertNotEqual(run.returncode, 0,
                                    "a partial run must not be accepted as an assertion "
                                    "failure: " + run.output())
                ipad_status = self.status_path(run, "iPad")
                text = ipad_status.read_text(encoding="utf-8")
                self.assertIn("classification=NOT_EXECUTED", text)
                self.assertIn("executed=3", text)
                self.assertIn("::error::", run.output())
                iphone_status = self.status_path(run, "iPhone")
                self.assertIn("classification=PASS",
                              iphone_status.read_text(encoding="utf-8"))

    def test_skipped_case_is_not_masked(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                skipped = (DIAGNOSTIC_CASE_IDS[0],)
                bundles = {
                    self.diagnostic_family(family): {
                        "summary": diagnostic_summary(passed=6, skipped=1),
                        "tests": diagnostic_tests(skipped=skipped),
                    } for family in ("iPad", "iPhone")}
                run = execute_step(script, root, devices=device_payload(),
                                   result_content=self.passing_content(),
                                   xcresult_json=bundles)
                self.assertNotEqual(run.returncode, 0,
                                    "a skipped diagnostic must fail the step: " + run.output())
                for family in ("iPad", "iPhone"):
                    text = self.status_path(run, family).read_text(encoding="utf-8")
                    self.assertIn("classification=NOT_EXECUTED", text)

    def test_unexpected_assertion_failure_after_complete_run_is_not_masked(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                bundles = {
                    self.diagnostic_family(family): failing_diagnostic_bundle(
                        message="XCTAssertTrue failed - staged copy leaked")
                    for family in ("iPad", "iPhone")}
                run = execute_step(script, root, devices=device_payload(),
                                   exit_codes={"diagnostic-iPad": 65,
                                               "diagnostic-iPhone": 65},
                                   result_content=self.passing_content(),
                                   xcresult_json=bundles)
                self.assertNotEqual(run.returncode, 0,
                                    "an unmarked assertion must gate: " + run.output())
                for family in ("iPad", "iPhone"):
                    status = self.status_path(run, family)
                    self.assertIn("classification=NOT_EXECUTED",
                                  status.read_text(encoding="utf-8"))
                    failures = self.failures_path(run, family)
                    self.assertIn("staged copy leaked",
                                  failures.read_text(encoding="utf-8"))
                self.assertIn("::error::", run.output())

    def test_missing_result_bundle_is_not_masked(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                run = execute_step(script, root, devices=device_payload(),
                                   result_content=self.passing_content(),
                                   xcresult_json=self.passing_xcresult(),
                                   skip_bundle={self.diagnostic_family("iPad"),
                                                self.diagnostic_family("iPhone")})
                self.assertNotEqual(run.returncode, 0,
                                    "a missing result bundle must fail the diagnostic "
                                    "step: " + run.output())
                for family in ("iPad", "iPhone"):
                    text = self.status_path(run, family).read_text(encoding="utf-8")
                    self.assertIn("classification=NOT_EXECUTED", text)
                    self.assertIn("bundle=missing", text)
                self.assertIn("::error::", run.output())

    def test_launch_failure_is_not_masked(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                content = {self.diagnostic_family(family): diagnostic_launch_failure_log()
                           for family in ("iPad", "iPhone")}
                run = execute_step(script, root, devices=device_payload(),
                                   exit_codes={"diagnostic-iPad": 65,
                                               "diagnostic-iPhone": 65},
                                   result_content=content)
                self.assertNotEqual(run.returncode, 0,
                                    "a launch failure must fail the diagnostic step: "
                                    + run.output())
                for family in ("iPad", "iPhone"):
                    text = self.status_path(run, family).read_text(encoding="utf-8")
                    self.assertIn("classification=NOT_EXECUTED", text)
                    self.assertIn("executed=None", text)
                self.assertIn("::error::", run.output())

    def test_diagnostic_script_targets_only_the_strict_class_without_building(self):
        for job, script in self.scripts:
            with self.subTest(job=job):
                self.assertIn("-only-testing:{}".format(STRICT_DIAGNOSTIC_CLASS), script)
                self.assertIn("CODE_SIGNING_ALLOWED=NO test-without-building", script)
                self.assertNotIn("| tee \"notes-$family.log\"", script)
                self.assertIn("for family in iPad iPhone; do", script)
                self.assertIn("NOT_EXECUTED", script)
                self.assertIn("ASSERTION_FAILURE", script)
                self.assertTrue(script.rstrip().endswith('exit "$incomplete"'),
                                "incomplete diagnostics must fail the step")
                self.assertNotIn("exit 0", script.split("incomplete=0")[-1])

    def test_diagnostic_script_classifies_through_the_stdlib_helper(self):
        for job, script in self.scripts:
            with self.subTest(job=job):
                self.assertIn(
                    '"$GITHUB_WORKSPACE/FloeAgent/scripts/verify_quicklook_diagnostics.py"',
                    script)
                self.assertIn('--result-bundle "notes-diagnostic-$family.xcresult"', script)
                self.assertIn('--log "notes-diagnostic-$family.log"', script)
                self.assertIn('--family "$family"', script)
                self.assertIn('--original-exit "$result"', script)
                self.assertIn('--status-output "$evidence_dir/notes-diagnostic-$family.status"', script)
                self.assertIn(
                    '--failures-output "$evidence_dir/notes-diagnostic-$family.status.failures.txt"',
                    script)
                # No log-text classification may remain in the workflow.
                self.assertNotIn("Executed (\\d+) tests", script)
                self.assertNotIn("import pathlib, re, sys", script)

    def test_missing_diagnostic_destination_is_a_coverage_failure(self):
        for job, script in self.scripts:
            with self.subTest(job=job), tempfile.TemporaryDirectory() as root:
                bundles = {self.diagnostic_family("iPhone"): passing_diagnostic_bundle()}
                run = execute_step(script, root,
                                   devices=device_payload(include_ipad=False),
                                   result_content={self.diagnostic_family("iPhone"):
                                                   diagnostic_log()},
                                   xcresult_json=bundles)
                self.assertNotEqual(run.returncode, 0, run.output())
                self.assertEqual(run.families, [self.diagnostic_family("iPhone")])
                self.assertIn("no iPad simulator destination", run.output())
                self.assertIn("::error::", run.output())
                ipad_status = self.status_path(run, "iPad")
                self.assertIn("classification=NOT_EXECUTED",
                              ipad_status.read_text(encoding="utf-8"))
                iphone_status = self.status_path(run, "iPhone")
                self.assertIn("classification=PASS",
                              iphone_status.read_text(encoding="utf-8"))


class WorkflowContractTests(unittest.TestCase):
    def setUp(self):
        self.source = WORKFLOW.read_text(encoding="utf-8")
        self.scripts = extract_step_scripts(self.source)
        self.assertEqual(len(self.scripts), 2)
        self.diagnostic_scripts = extract_step_scripts(
            self.source, DIAGNOSTIC_STEP_NAME)
        self.assertEqual(len(self.diagnostic_scripts), 2)

    def test_no_global_errexit_suppression_and_each_pipeline_is_guarded(self):
        self.assertNotRegex(self.source, GLOBAL_ERREXIT_OFF)
        for job, script in self.scripts + self.diagnostic_scripts:
            with self.subTest(job=job):
                self.assertIn("set -o pipefail", script)
                # The old ${PIPESTATUS[0]} line was unreachable under -e, so a
                # guarded pipeline (not PIPESTATUS) must carry the status.
                self.assertNotIn("PIPESTATUS", script)
        for job, script in self.scripts:
            with self.subTest(job=job):
                self.assertIn("|| result=$?", script)
                self.assertIn("first_failure=0", script)
                self.assertIn('exit "$first_failure"', script)

    def test_functional_run_excludes_the_strict_diagnostic_class(self):
        for job, script in self.scripts:
            with self.subTest(job=job):
                self.assertIn("-skip-testing:{}".format(STRICT_DIAGNOSTIC_CLASS), script)
                self.assertNotIn("-only-testing:", script)
                self.assertNotIn("test-without-building", script)

    def test_strict_diagnostics_are_separate_and_explicitly_non_gating(self):
        self.assertNotRegex(self.source, r"(?m)^\s+continue-on-error\s*:")
        self.assertEqual(
            len(re.findall(r"(?m)^        if: always\(\)$", self.source)), 4,
            "two functional artifact steps plus two diagnostic steps")
        self.assertEqual(self.source.count(
            "notes-diagnostic-$family.xcresult"), 4,
                         "each job's xcodebuild and its classifier name the bundle")
        self.assertEqual(self.source.count("notes-diagnostic-$family.log"), 4,
                         "each job tees the diagnostic log and passes it to the classifier")
        self.assertEqual(self.source.count(
            '--status-output "$evidence_dir/notes-diagnostic-$family.status"'), 2)
        self.assertEqual(self.source.count(
            '--failures-output "$evidence_dir/notes-diagnostic-$family.status.failures.txt"'), 2)
        for job, script in self.diagnostic_scripts:
            with self.subTest(job=job):
                self.assertIn("diagnostic non-gating", script)
                self.assertIn("-only-testing:{}".format(STRICT_DIAGNOSTIC_CLASS), script)
                self.assertIn("NOT_EXECUTED", script)
                self.assertIn("ASSERTION_FAILURE", script)
                self.assertIn("verify_quicklook_diagnostics.py", script)
                self.assertIn("::error::", script)
                self.assertIn("::warning::", script)
                self.assertTrue(script.rstrip().endswith('exit "$incomplete"'),
                                "only a fully executed assertion failure is non-gating")
        for job, script in self.scripts:
            with self.subTest(job=job):
                # the functional step stays the one that fails the job
                self.assertIn("::error::", script)
                self.assertIn('exit "$first_failure"', script)

    def test_device_selection_bounds_and_no_retry_are_unchanged(self):
        for job, script in self.scripts:
            with self.subTest(job=job):
                self.assertIn("for family in iPad iPhone; do", script)
                self.assertEqual(script.count("CODE_SIGNING_ALLOWED=NO test"), 1)
                self.assertIn('-resultBundlePath "notes-$family.xcresult"', script)
                self.assertIn("-parallel-testing-enabled NO", script)
                self.assertIn("-test-timeouts-enabled YES", script)
                self.assertIn("-default-test-execution-time-allowance 90", script)
                self.assertIn("-maximum-test-execution-time-allowance 180", script)
                self.assertIn("-collect-test-diagnostics never", script)
                self.assertIn(
                    "xcodebuild-version-{}.txt".format(job), script)
                for forbidden in ("-retry-tests-on-failure", "-test-iterations"):
                    self.assertNotIn(forbidden, script)
                self.assertNotRegex(script, GLOBAL_ERREXIT_OFF)

    def test_artifact_preservation_steps_are_kept_for_both_jobs(self):
        self.assertEqual(self.source.count("notes-*.xcresult"), 2)
        self.assertEqual(self.source.count("notes-*.log"), 2)
        self.assertEqual(self.source.count("if-no-files-found: warn"), 2)


if __name__ == "__main__":
    unittest.main()
