from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from verify_notes_ui_xcresult import verify


class NotesUIGateTests(unittest.TestCase):
    def fixture(self):
        return ({"result": "Passed", "totalTestCount": 2, "passedTests": 2,
                 "failedTests": 0, "skippedTests": 0, "expectedFailures": 0},
                {"children": [{"nodeType": "Test Case", "result": "Passed", "nodeIdentifier":
                 "NotesWorkspaceImportUITests/testWorkspaceImportTabsFocusAndBodySearch()"},
                 {"nodeType": "Test Case", "result": "Passed", "nodeIdentifier":
                 "NotesWorkspaceImportUITests/testOfficeHeaderAssistantSaveAndReopen()"}]})

    def test_actual_case_passes(self):
        summary, tree = self.fixture()
        self.assertEqual(verify(summary, tree)["passedTests"], 2)

    def test_empty_skipped_and_expected_failures_do_not_pass(self):
        for change in ({"totalTestCount": 0, "passedTests": 0}, {"skippedTests": 1}, {"expectedFailures": 1}):
            summary, tree = self.fixture()
            with self.assertRaises(ValueError):
                verify(summary | change, tree)

    def test_wrong_missing_or_failed_case_does_not_pass(self):
        for tree in ({}, {"nodeType": "Test Case", "result": "Passed", "nodeIdentifier": "Other/test"},
                     {"children": [case | {"result": "Failed"} for case in self.fixture()[1]["children"]]},
                     {"children": [self.fixture()[1]["children"][0]] * 2}):
            with self.assertRaises(ValueError):
                verify(self.fixture()[0], tree)


if __name__ == "__main__":
    unittest.main()
