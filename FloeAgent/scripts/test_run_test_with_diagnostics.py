import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import run_test_with_diagnostics as runner


class TestDiagnosticRunner(unittest.TestCase):
    def invoke(self, code, *options):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / "evidence"
            arguments = ["runner", "--output-dir", str(output), *options, "--", sys.executable, "-c", code]
            # The runner forwards bytes as well as its own textual messages.
            stream = io.TextIOWrapper(io.BytesIO(), encoding="utf-8")
            with patch.object(sys, "argv", arguments), contextlib.redirect_stdout(stream):
                result = runner.main()
            return result, json.loads((output / "summary.json").read_text()), (output / "tests.log").read_text()

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


if __name__ == "__main__":
    unittest.main()
