from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from verify_notes_ui_xcresult import verify


class NotesUIGateTests(unittest.TestCase):
    def fixture(self):
        return ({"result": "Passed", "totalTestCount": 5, "passedTests": 5,
                 "failedTests": 0, "skippedTests": 0, "expectedFailures": 0},
                {"children": [{"nodeType": "Test Case", "result": "Passed", "nodeIdentifier":
                 "NotesWorkspaceImportUITests/testWorkspaceImportAndDocumentAssistant()"},
                 {"nodeType": "Test Case", "result": "Passed", "nodeIdentifier":
                 "NotesWorkspaceImportUITests/testOfficeHeaderAssistantSaveAndReopen()"},
                 {"nodeType": "Test Case", "result": "Passed", "nodeIdentifier": "NotesWorkspaceImportUITests/testPencilToolsAndFocusedLayout()"},
                 {"nodeType": "Test Case", "result": "Passed", "nodeIdentifier": "NotesWorkspaceImportUITests/testDocumentTabsAndBodySearch()"},
                 {"nodeType": "Test Case", "result": "Passed", "nodeIdentifier": "NotesWorkspaceImportUITests/testNotesLibraryCardsShowRealContentCovers()"}]})

    def test_actual_case_passes(self):
        summary, tree = self.fixture()
        self.assertEqual(verify(summary, tree)["passedTests"], 5)

    def test_explicit_simulator_scope_never_claims_native_office_passed(self):
        summary, tree = self.fixture()
        summary.update(passedTests=4, skippedTests=1)
        tree['children'][1]['result'] = 'Skipped'
        with self.assertRaises(ValueError):
            verify(summary, tree)
        result = verify(summary, tree, simulator_without_office=True)
        self.assertFalse(result['nativeOfficeAccepted'])
        self.assertEqual(result['coverage'], 'simulator-notes-and-content-covers')
        tree['children'][0]['result'] = 'Skipped'
        with self.assertRaises(ValueError):
            verify(summary, tree, simulator_without_office=True)

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
