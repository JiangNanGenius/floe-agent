from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from verify_notes_ui_xcresult import verify


class NotesUIGateTests(unittest.TestCase):
    def fixture(self):
        return ({"result": "Passed", "totalTestCount": 1, "passedTests": 1,
                 "failedTests": 0, "skippedTests": 0, "expectedFailures": 0},
                {"nodeType": "Test Case", "result": "Passed", "nodeIdentifier":
                 "NotesWorkspaceImportUITests/testWorkspacePDFImportOpensFullscreenAndSearchesBody()"})

    def test_actual_case_passes(self):
        summary, tree = self.fixture()
        self.assertEqual(verify(summary, tree)["passedTests"], 1)

    def test_empty_skipped_and_expected_failures_do_not_pass(self):
        for change in ({"totalTestCount": 0, "passedTests": 0}, {"skippedTests": 1}, {"expectedFailures": 1}):
            summary, tree = self.fixture()
            with self.assertRaises(ValueError):
                verify(summary | change, tree)

    def test_wrong_missing_or_failed_case_does_not_pass(self):
        for tree in ({}, {"nodeType": "Test Case", "result": "Passed", "nodeIdentifier": "Other/test"},
                     self.fixture()[1] | {"result": "Failed"}):
            with self.assertRaises(ValueError):
                verify(self.fixture()[0], tree)


if __name__ == "__main__":
    unittest.main()
