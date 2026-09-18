import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock

SCRIPT = Path(__file__).resolve().parents[1] / "prepare_ui_simulator.py"
spec = importlib.util.spec_from_file_location("prepare_ui_simulator", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
DEVICE = "FA4E2F7A-87DE-46BF-82D5-AF1EF61F7869"


class SimulatorPreparationTests(unittest.TestCase):
    def invoke(self, runner):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "preflight"
            result = module.prepare(DEVICE, output, runner=runner)
            self.assertEqual(result, json.loads((output / "summary.json").read_text()))
            self.assertTrue((output / "boot.log").exists())
        return result

    def test_ready_boot_waits_only_for_selected_device(self):
        runner = Mock(return_value=subprocess.CompletedProcess([], 0))
        self.assertTrue(self.invoke(runner)["ready"])
        self.assertEqual(runner.call_count, 1)
        self.assertEqual(runner.call_args.args[0], ["xcrun", "simctl", "bootstatus", DEVICE, "-b"])
        self.assertEqual(runner.call_args.kwargs["timeout"], 180)

    def test_failed_boot_is_not_retried_or_accepted(self):
        runner = Mock(return_value=subprocess.CompletedProcess([], 149))
        result = self.invoke(runner)
        self.assertFalse(result["ready"])
        self.assertEqual(result["exitCode"], 149)
        self.assertEqual(runner.call_count, 1)

    def test_timeout_retains_failed_preparation(self):
        result = self.invoke(Mock(side_effect=subprocess.TimeoutExpired("simctl", 180)))
        self.assertFalse(result["ready"])
        self.assertEqual(result["exitCode"], 124)

    def test_missing_tool_fails_closed(self):
        self.assertFalse(self.invoke(Mock(side_effect=FileNotFoundError("xcrun")))["ready"])

    def test_malformed_identifier_never_executes(self):
        runner = Mock()
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                module.prepare("all", Path(directory) / "preflight", runner=runner)
        runner.assert_not_called()

    def test_release_legs_prepare_before_test_without_building(self):
        workflow = (SCRIPT.parents[2] / ".github/workflows/release-unsigned-ipa.yml").read_text()
        legs = workflow.split("- name: Require Notes import on the ")[1:]
        self.assertEqual(len(legs), 4)
        for leg in legs:
            step = leg.split("\n      - name:", 1)[0]
            self.assertLess(step.index("scripts/prepare_ui_simulator.py"), step.index("scripts/run_test_with_diagnostics.py"))
            self.assertIn('--simulator-id "$test_device"', step)
            self.assertIn('|| exit 1', step)


if __name__ == "__main__":
    unittest.main()
