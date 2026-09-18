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
* a failing ``| tee`` log pipeline is not silently treated as a pass.
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
printf 'stub xcodebuild ran the %s leg\n' "$family"
if [ -n "$result_bundle" ]; then
  mkdir -p "$result_bundle"
  printf 'stub xcresult for %s\n' "$family" > "$result_bundle/Info.plist"
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


def extract_step_scripts(workflow_text):
    """Return ``(job, script)`` for every ``Test iPad first, then iPhone`` step.

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
        if line.strip() != "- name: {}".format(STEP_NAME):
            index += 1
            continue
        indent = len(line) - len(line.lstrip(" "))
        run_index = index + 1
        while run_index < len(lines) and lines[run_index].strip() != "run: |":
            run_index += 1
        if run_index >= len(lines):
            raise AssertionError("no 'run: |' block for step {!r}".format(STEP_NAME))
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
            raise AssertionError("empty 'run: |' block for step {!r}".format(STEP_NAME))
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
                 ipad_log_is_directory=False):
    """Execute one extracted step script under the GitHub Actions bash flags."""
    root = Path(root)
    bin_dir = root / "bin"
    runner_temp = root / "runner"
    work = root / "work"
    exit_dir = root / "exits"
    for directory in (bin_dir, runner_temp, work, exit_dir):
        directory.mkdir(parents=True, exist_ok=True)
    write_stub(bin_dir / "xcodebuild", XCODEBUILD_STUB)
    write_stub(bin_dir / "xcrun", XCRUN_STUB)
    devices_json = root / "devices.json"
    devices_json.write_text(json.dumps(devices), encoding="utf-8")
    for family, code in (exit_codes or {}).items():
        (exit_dir / family).write_text("{}\n".format(code), encoding="utf-8")
    script_path = root / "step.sh"
    script_path.write_text(script, encoding="utf-8")
    if ipad_log_is_directory:
        (work / "notes-iPad.log").mkdir()
    invocation_log = root / "invocations.txt"
    environment = dict(os.environ)
    environment.update({
        "PATH": "{}{}{}".format(bin_dir, os.pathsep, environment.get("PATH", "")),
        "RUNNER_TEMP": str(runner_temp),
        "DEVELOPER_DIR": existing_developer_dir(),
        "STUB_DEVICES_JSON": str(devices_json),
        "STUB_EXIT_DIR": str(exit_dir),
        "STUB_INVOCATION_LOG": str(invocation_log),
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


class WorkflowContractTests(unittest.TestCase):
    def setUp(self):
        self.source = WORKFLOW.read_text(encoding="utf-8")
        self.scripts = extract_step_scripts(self.source)
        self.assertEqual(len(self.scripts), 2)

    def test_no_global_errexit_suppression_and_each_pipeline_is_guarded(self):
        self.assertNotRegex(self.source, GLOBAL_ERREXIT_OFF)
        for job, script in self.scripts:
            with self.subTest(job=job):
                self.assertIn("set -o pipefail", script)
                self.assertIn("|| result=$?", script)
                self.assertIn("first_failure=0", script)
                self.assertIn('exit "$first_failure"', script)
                # The old ${PIPESTATUS[0]} line was unreachable under -e, so a
                # guarded pipeline (not PIPESTATUS) must carry the status.
                self.assertNotIn("PIPESTATUS", script)

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
        self.assertEqual(self.source.count("if: always()"), 2)
        self.assertEqual(self.source.count("notes-*.xcresult"), 2)
        self.assertEqual(self.source.count("notes-*.log"), 2)
        self.assertEqual(self.source.count("if-no-files-found: warn"), 2)


if __name__ == "__main__":
    unittest.main()
