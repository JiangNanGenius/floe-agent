import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import run_test_with_diagnostics as runner

RUNNER = Path(__file__).with_name("run_test_with_diagnostics.py")


class TestDiagnosticRunner(unittest.TestCase):
    def test_sampling_delay_preserves_first_expired_deadline(self):
        self.assertEqual(runner.expired_deadline_reason(10, 0, 0, 4, 0.5, True), "stalled")
        self.assertEqual(runner.expired_deadline_reason(10, 0, 3.8, 4, 0.5, True), "timeout")
        self.assertEqual(runner.expired_deadline_reason(10, 0, 0, 4, 0.5, False), "timeout")
        self.assertIsNone(runner.expired_deadline_reason(0.25, 0, 0, 4, 0.5, True))

    def invoke(self, code, *options):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / "evidence"
            arguments = ["runner", "--output-dir", str(output), *options, "--", sys.executable, "-c", code]
            # The runner forwards bytes as well as its own textual messages.
            stream = io.TextIOWrapper(io.BytesIO(), encoding="utf-8")
            with patch.object(sys, "argv", arguments), contextlib.redirect_stdout(stream):
                result = runner.main()
            return result, json.loads((output / "summary.json").read_text()), (output / "tests.log").read_text()

    def run_runner_subprocess(self, output, code, *options):
        """Drive the real script in a real child process, like CI does."""
        return subprocess.run(
            [sys.executable, str(RUNNER), "--output-dir", str(output), *options,
             "--", sys.executable, "-c", code],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)

    def test_preserves_successful_execution_and_output(self):
        result, summary, log = self.invoke("print('Test run started'); print('real output')")
        self.assertEqual(result, 0)
        self.assertEqual(summary["reason"], "exited")
        self.assertIn("real output", log)

    def test_hung_process_is_bounded_before_first_test(self):
        result, summary, _ = self.invoke("import time; time.sleep(30)", "--timeout", "0.5")
        self.assertEqual(result, 124)
        self.assertEqual(summary["reason"], "timeout")
        self.assertFalse(summary["testsStarted"])

    @patch.object(runner, "sample_simulator")
    @patch.object(runner, "sample_children")
    def test_prebuilt_simulator_launch_stall_collects_evidence(self, children, simulator):
        identifier = "11111111-2222-3333-4444-555555555555"
        result, summary, _ = self.invoke("import time; time.sleep(30)", "--timeout", "5",
                                         "--stall-timeout", "0.6", "--simulator-id", identifier)
        self.assertEqual(result, 124)
        self.assertEqual(summary["reason"], "stalled")
        children.assert_called_once()
        simulator.assert_called_once()
        self.assertEqual(simulator.call_args.args[0], identifier)

    @patch.object(runner, "sample_simulator")
    @patch.object(runner, "sample_children")
    def test_combined_build_waits_for_tests_before_quiet_deadline(self, children, simulator):
        result, summary, _ = self.invoke("import time; time.sleep(1.2); print('Test run started')",
            "--timeout", "5", "--stall-timeout", "0.6", "--defer-stall-until-tests",
            "--simulator-id", "11111111-2222-3333-4444-555555555555")
        self.assertEqual(result, 0)
        self.assertEqual(summary["reason"], "exited")
        children.assert_not_called()
        simulator.assert_not_called()

    @patch.object(runner, "sample_simulator")
    @patch.object(runner, "sample_children")
    def test_combined_build_still_bounds_shutdown_after_tests(self, children, simulator):
        result, summary, _ = self.invoke("import time; print('Test run started', flush=True); time.sleep(30)",
            "--timeout", "5", "--stall-timeout", "0.6", "--defer-stall-until-tests",
            "--simulator-id", "11111111-2222-3333-4444-555555555555")
        self.assertEqual(result, 124)
        self.assertEqual(summary["reason"], "stalled")
        simulator.assert_called_once()

    @patch.object(runner, "sample_simulator")
    @patch.object(runner, "sample_children")
    def test_startup_deadline_is_generous_while_test_deadline_stays_tight(self, children, simulator):
        # A silent start longer than the test-quiet deadline must survive the
        # startup phase, then still be bounded once tests begin.
        code = "import time; time.sleep(0.7); print('Test run started', flush=True); time.sleep(30)"
        result, summary, _ = self.invoke(
            code, "--timeout", "5", "--stall-timeout", "0.5", "--startup-stall-timeout", "2.0",
            "--simulator-id", "11111111-2222-3333-4444-555555555555")
        self.assertEqual(result, 124)
        self.assertEqual(summary["reason"], "stalled")
        self.assertTrue(summary["testsStarted"])

    def test_silent_startup_stall_then_retry_keeps_both_attempts(self):
        # The exact CI shape: attempt 1 stalls with no test output at all, and
        # the retry runs from a fresh directory that must not collide with it.
        identifier = "11111111-2222-3333-4444-555555555555"
        with tempfile.TemporaryDirectory() as root:
            first = Path(root) / "ide-ipad-attempt-1"
            second = Path(root) / "ide-ipad-attempt-2"
            stalled = self.run_runner_subprocess(
                first, "import time; time.sleep(30)",
                "--timeout", "4", "--stall-timeout", "0.4", "--startup-stall-timeout", "0.5",
                "--simulator-id", identifier)
            self.assertEqual(stalled.returncode, 124, stalled.stdout)
            first_summary = json.loads((first / "summary.json").read_text())
            self.assertEqual(first_summary["reason"], "stalled")
            self.assertFalse(first_summary["testsStarted"])
            self.assertTrue((first / "tests.log").exists())
            first_log = (first / "tests.log").read_bytes()

            retry = self.run_runner_subprocess(
                second, "print('Test run started'); print('retry output')",
                "--timeout", "10", "--stall-timeout", "5")
            self.assertEqual(retry.returncode, 0, retry.stdout)
            second_summary = json.loads((second / "summary.json").read_text())
            self.assertEqual(second_summary["reason"], "exited")
            self.assertTrue(second_summary["testsStarted"])
            self.assertIn("retry output", (second / "tests.log").read_text())
            # The retry never rewrote the first attempt's evidence.
            self.assertFalse(json.loads((first / "summary.json").read_text())["testsStarted"])
            self.assertEqual((first / "tests.log").read_bytes(), first_log)

    @patch.object(runner.sys, "platform", "darwin")
    def test_sample_children_only_samples_owned_marked_processes(self):
        rows = "\n".join([
            "  100     1 /usr/bin/init",
            "  200   100 /usr/bin/swiftpm-testing",
            "  201   100 /usr/bin/xcodebuild",
            "  202   100 /usr/bin/unrelated-worker",
            "  300     1 /usr/bin/PackageTests",  # marker, but not our descendant
        ])
        recorded = []

        def fake_run(command, *args, **kwargs):
            recorded.append(command)
            return subprocess.CompletedProcess(command, 0)

        with patch.object(runner.subprocess, "check_output", return_value=rows), \
                patch.object(runner.subprocess, "run", side_effect=fake_run):
            runner.sample_children(100, Path("/tmp/does-not-matter"))

        sampled = [command[1] for command in recorded if command[0] == "sample"]
        self.assertEqual(sampled, ["200", "201"])

    @patch.object(runner.sys, "platform", "darwin")
    def test_sample_simulator_only_samples_this_app_and_survives_no_match(self):
        identifier = "11111111-2222-3333-4444-555555555555"
        other = "99999999-8888-7777-6666-555555555555"
        device = f"/Users/x/Library/Developer/CoreSimulator/Devices/{identifier}/data/Containers/Bundle/Application"
        rows = "\n".join([
            f"   10 {device}/com.apple.WebKit.WebContent",
            f"   11 {device}/Floe Agent.app/Floe Agent",
            f"   12 {device}/FloeAgentUITests-Runner.app/FloeAgentUITests-Runner",
            "   13 /Users/x/Library/Developer/CoreSimulator/Devices/"
            f"{other}/data/Containers/Bundle/Application/Floe Agent.app/Floe Agent",
        ])
        recorded = []

        def fake_run(command, *args, **kwargs):
            recorded.append(command)
            # model a failing device screenshot so the error evidence path runs
            return subprocess.CompletedProcess(command, 1 if command[:2] == ["xcrun", "simctl"] else 0)

        with tempfile.TemporaryDirectory() as root:
            destination = Path(root)
            with patch.object(runner.subprocess, "check_output", return_value=rows), \
                    patch.object(runner.subprocess, "run", side_effect=fake_run):
                runner.sample_simulator(identifier, destination)

            sampled = [command[1] for command in recorded if command[0] == "sample"]
            self.assertEqual(sampled, ["11", "12"])
            screenshots = [command for command in recorded if command[:3] == ["xcrun", "simctl", "io"]]
            self.assertEqual(len(screenshots), 1)
            # A failed screenshot must leave visible evidence, not vanish.
            self.assertTrue((destination / "simulator-screenshot-error.txt").exists())

            # The earlier indentation bug raised NameError when no App process
            # was found; an unmatched list must stay a no-op with one try.
            recorded.clear()
            with patch.object(runner.subprocess, "check_output", return_value=rows.splitlines()[0]), \
                    patch.object(runner.subprocess, "run", side_effect=fake_run):
                runner.sample_simulator(identifier, destination)
        self.assertEqual([command for command in recorded if command[0] == "sample"], [])
        self.assertEqual(len([command for command in recorded if command[:3] == ["xcrun", "simctl", "io"]]), 1)


if __name__ == "__main__":
    unittest.main()
