import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_app_regression_xcresult as verifier


class AppRegressionGateTests(unittest.TestCase):
    def run_gate(self, counts):
        cases = [{"nodeType": "Test Case", "nodeIdentifier": f"{suite}/test{index}()", "result": "Passed"}
                 for suite, count in counts.items() for index in range(count)]
        summary = {"totalTestCount": len(cases), "passedTests": len(cases), "failedTests": 0,
                   "skippedTests": 0, "expectedFailures": 0, "result": "Passed"}
        with patch.object(sys, "argv", ["verify", "--result-bundle", "fixture"]), \
             patch.object(verifier, "xcresult_json", side_effect=[summary, {"children": cases}]), \
             contextlib.redirect_stdout(io.StringIO()):
            verifier.main()

    def test_both_home_suites_are_required_and_accepted(self):
        counts = dict(verifier.SUITE_MINIMUMS)
        self.assertEqual(counts["HomeChatSeparationTests"], 6)
        self.assertEqual(counts["HomeTaskCreationTests"], 2)
        self.run_gate(counts)

    def test_navigation_success_cannot_hide_omitted_task_creation(self):
        counts = dict(verifier.SUITE_MINIMUMS)
        counts["HomeChatSeparationTests"] = 8
        del counts["HomeTaskCreationTests"]
        with self.assertRaisesRegex(SystemExit, "HomeTaskCreationTests"):
            self.run_gate(counts)

    def test_task_creation_cannot_replace_a_missing_navigation_case(self):
        counts = dict(verifier.SUITE_MINIMUMS)
        counts["HomeChatSeparationTests"] = 5
        counts["HomeTaskCreationTests"] = 3
        with self.assertRaisesRegex(SystemExit, "HomeChatSeparationTests"):
            self.run_gate(counts)

    def test_ci_and_both_release_sdks_select_task_creation(self):
        root = Path(__file__).resolve().parents[3]
        for workflow in ("ci.yml", "release-unsigned-ipa.yml"):
            source = (root / ".github/workflows" / workflow).read_text()
            self.assertEqual(source.count("-only-testing:FloeAppTests/HomeTaskCreationTests "), 2, workflow)

    def test_retired_native_runtime_suites_are_not_required_or_selected(self):
        root = Path(__file__).resolve().parents[3]
        retired = ("LocalPythonRuntimeTests", "LocalServiceLifecycleTests")
        for suite in retired:
            self.assertNotIn(suite, verifier.SUITE_MINIMUMS)
        for workflow in ("ci.yml", "release-unsigned-ipa.yml"):
            source = (root / ".github/workflows" / workflow).read_text()
            for suite in retired:
                self.assertNotIn(f"-only-testing:FloeAppTests/{suite} ", source, workflow)


if __name__ == "__main__":
    unittest.main()
