from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from verify_notes_ui_xcresult import verify

SUITE = "NotesWorkspaceImportUITests"
OFFICE = f"{SUITE}/testOfficeHeaderAssistantSaveAndReopen"
HIDDEN_WORKBOOK = f"{SUITE}/testHiddenWorkbookCardsAreVisibleWithTheSummaryBadge"
PENCIL_TOOLBAR = f"{SUITE}/testOfficePencilToolbarToggleAndSettings"
MANDATORY = [
    f"{SUITE}/testWorkspaceImportAndDocumentAssistant",
    OFFICE,
    f"{SUITE}/testPencilToolsAndFocusedLayout",
    f"{SUITE}/testDocumentTabsAndBodySearch",
    f"{SUITE}/testNotesLibraryCardsShowRealContentCovers",
]
OPT_IN = [HIDDEN_WORKBOOK, PENCIL_TOOLBAR]


def case(identifier, result):
    return {"nodeType": "Test Case", "result": result, "nodeIdentifier": f"{identifier}()"}


def fixture(cases, *, result="Passed"):
    summary = {"result": result, "totalTestCount": len(cases),
               "passedTests": sum(value == "Passed" for _, value in cases),
               "failedTests": sum(value == "Failed" for _, value in cases),
               "skippedTests": sum(value == "Skipped" for _, value in cases),
               "expectedFailures": sum(value == "Expected Failure" for _, value in cases)}
    return summary, {"children": [case(identifier, value) for identifier, value in cases]}


def mandatory_cases(office="Passed"):
    return [(identifier, office if identifier == OFFICE else "Passed") for identifier in MANDATORY]


class NotesUIGateTests(unittest.TestCase):
    def fixture(self):
        return fixture(mandatory_cases())

    def test_actual_case_passes(self):
        summary, tree = self.fixture()
        result = verify(summary, tree)
        self.assertEqual(result["passedTests"], 5)
        self.assertEqual(result["totalTestCount"], 5)
        self.assertEqual(result["tests"], {identifier: "Passed" for identifier in MANDATORY})
        self.assertEqual(result["optInTests"], {})
        self.assertTrue(result["nativeOfficeAccepted"])

    def test_explicit_simulator_scope_never_claims_native_office_passed(self):
        summary, tree = fixture(mandatory_cases(office="Skipped"))
        with self.assertRaises(ValueError):
            verify(summary, tree)
        result = verify(summary, tree, simulator_without_office=True)
        self.assertFalse(result["nativeOfficeAccepted"])
        self.assertEqual(result["coverage"], "simulator-notes-and-content-covers")
        self.assertEqual(result["tests"][OFFICE], "Skipped")
        self.assertEqual(result["optInTests"], {})
        tree["children"][0]["result"] = "Skipped"
        with self.assertRaises(ValueError):
            verify(summary, tree, simulator_without_office=True)

    def test_empty_skipped_and_expected_failures_do_not_pass(self):
        for change in ({"totalTestCount": 0, "passedTests": 0}, {"skippedTests": 1}, {"expectedFailures": 1}):
            summary, tree = self.fixture()
            with self.assertRaises(ValueError):
                verify(summary | change, tree)

    def test_wrong_missing_or_failed_case_does_not_pass(self):
        for tree in ({}, {"nodeType": "Test Case", "result": "Passed", "nodeIdentifier": "Other/test"},
                     {"children": [case(identifier, "Failed") for identifier in MANDATORY]},
                     {"children": [self.fixture()[1]["children"][0]] * 2}):
            with self.assertRaises(ValueError):
                verify(self.fixture()[0], tree)

    def test_current_class_with_skipped_opt_ins_is_accepted_and_recorded(self):
        summary, tree = fixture(mandatory_cases(office="Skipped")
                                + [(identifier, "Skipped") for identifier in OPT_IN])
        result = verify(summary, tree, simulator_without_office=True)
        self.assertEqual((result["totalTestCount"], result["passedTests"], result["skippedTests"]),
                         (7, 4, 3))
        self.assertEqual(result["optInTests"], {identifier: "Skipped" for identifier in OPT_IN})
        self.assertEqual(result["tests"], {identifier: ("Skipped" if identifier == OFFICE else "Passed")
                                          for identifier in MANDATORY})
        self.assertFalse(result["nativeOfficeAccepted"])

    def test_realistic_current_class_simulator_mix_is_accepted(self):
        summary, tree = fixture(mandatory_cases(office="Skipped")
                                + [(HIDDEN_WORKBOOK, "Passed"), (PENCIL_TOOLBAR, "Skipped")])
        result = verify(summary, tree, simulator_without_office=True)
        self.assertEqual((result["totalTestCount"], result["passedTests"], result["skippedTests"]),
                         (7, 5, 2))
        self.assertEqual(result["optInTests"], {HIDDEN_WORKBOOK: "Passed", PENCIL_TOOLBAR: "Skipped"})
        self.assertFalse(result["nativeOfficeAccepted"])

    def test_explicit_passed_opt_ins_are_accepted_and_recorded(self):
        for extra in ([HIDDEN_WORKBOOK], OPT_IN):
            with self.subTest(extra=extra):
                summary, tree = fixture(mandatory_cases() + [(identifier, "Passed") for identifier in extra])
                result = verify(summary, tree)
                self.assertEqual(result["totalTestCount"], 5 + len(extra))
                self.assertEqual(result["passedTests"], 5 + len(extra))
                self.assertEqual(result["optInTests"], {identifier: "Passed" for identifier in extra})
                self.assertTrue(result["nativeOfficeAccepted"])

    def test_failed_or_expected_failure_opt_in_is_rejected(self):
        for identifier in OPT_IN:
            for outcome in ("Failed", "Expected Failure"):
                with self.subTest(identifier=identifier, outcome=outcome):
                    summary, tree = fixture(mandatory_cases() + [(identifier, outcome)])
                    with self.assertRaises(ValueError):
                        verify(summary, tree)

    def test_unknown_extra_case_is_rejected(self):
        summary, tree = fixture(mandatory_cases() + [(f"{SUITE}/testNotInTheContract", "Passed")])
        with self.assertRaises(ValueError):
            verify(summary, tree)

    def test_duplicate_test_identity_is_rejected(self):
        for duplicate in (MANDATORY[0], HIDDEN_WORKBOOK):
            with self.subTest(duplicate=duplicate):
                cases = mandatory_cases() + [(identifier, "Passed") for identifier in OPT_IN]
                summary, tree = fixture(cases + [(duplicate, "Passed")])
                with self.assertRaises(ValueError):
                    verify(summary, tree)

    def test_mandatory_skip_cannot_be_compensated_by_opt_in_passes(self):
        cases = [(identifier, "Skipped" if identifier == MANDATORY[3] else "Passed")
                 for identifier in MANDATORY]
        cases += [(identifier, "Passed") for identifier in OPT_IN]
        summary, tree = fixture(cases)
        self.assertEqual((summary["totalTestCount"], summary["passedTests"], summary["skippedTests"]),
                         (7, 6, 1))
        with self.assertRaises(ValueError):
            verify(summary, tree)

    def test_office_skip_on_device_cannot_be_compensated_by_opt_in_passes(self):
        summary, tree = fixture(mandatory_cases(office="Skipped")
                                + [(identifier, "Passed") for identifier in OPT_IN])
        with self.assertRaises(ValueError):
            verify(summary, tree)

    def test_missing_mandatory_cannot_be_filled_by_opt_in_cases(self):
        cases = [(identifier, "Passed") for identifier in MANDATORY if identifier != OFFICE]
        cases += [(identifier, "Passed") for identifier in OPT_IN]
        summary, tree = fixture(cases)
        with self.assertRaises(ValueError):
            verify(summary, tree)

    def test_summary_counts_and_result_must_match_the_exact_case_set(self):
        summary, tree = fixture(mandatory_cases(office="Skipped")
                                + [(identifier, "Skipped") for identifier in OPT_IN])
        for change in ({"totalTestCount": 5}, {"totalTestCount": 6}, {"passedTests": 5},
                       {"skippedTests": 2}, {"failedTests": 1}, {"expectedFailures": 1},
                       {"result": "Failed"}):
            with self.subTest(change=change):
                with self.assertRaises(ValueError):
                    verify(summary | change, tree, simulator_without_office=True)


if __name__ == "__main__":
    unittest.main()
