#!/usr/bin/env python3
"""Verify Notes UI; explicitly record device-only Office coverage on simulators."""
import argparse
import json
from pathlib import Path
from verify_app_regression_xcresult import nodes, required_count, xcresult_json

SUITE = "NotesWorkspaceImportUITests"
OFFICE = f"{SUITE}/testOfficeHeaderAssistantSaveAndReopen"
REQUIRED = (
    f"{SUITE}/testWorkspaceImportAndDocumentAssistant",
    f"{SUITE}/testPencilToolsAndFocusedLayout",
    f"{SUITE}/testDocumentTabsAndBodySearch",
    f"{SUITE}/testNotesLibraryCardsShowRealContentCovers",
    OFFICE,
)
# The class is selected as a whole by CI and release workflows. These two
# additional opt-in cases may consequently appear in the result: the hidden
# workbook pixel proof and the Office pen-toolbar qualification. Their absence
# keeps legacy results valid; when present they must be honestly Passed or
# Skipped, never Failed, and they never satisfy a mandatory requirement.
OPT_IN = (
    f"{SUITE}/testHiddenWorkbookCardsAreVisibleWithTheSummaryBadge",
    f"{SUITE}/testOfficePencilToolbarToggleAndSettings",
)
OPT_IN_RESULTS = {"Passed", "Skipped"}


def verify(summary, tree, *, simulator_without_office=False):
    counts = {key: required_count(summary, key) for key in
              ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")}
    cases = [node for node in nodes(tree) if node.get("nodeType") == "Test Case"]
    identities = [str(case.get("nodeIdentifier", "")).removesuffix("()") for case in cases]
    results = dict(zip(identities, (case.get("result") for case in cases)))

    expected_results = {name: "Passed" for name in REQUIRED}
    if simulator_without_office:
        expected_results[OFFICE] = "Skipped"
    present_opt_in = {name: results[name] for name in OPT_IN if name in results}

    # Only the mandatory identities and the exactly named opt-in cases may
    # contribute to the reported totals. Unknown extras, duplicates and a
    # missing mandatory case are rejected instead of being absorbed by a
    # summary count that happens to match.
    expected_total = len(REQUIRED) + len(present_opt_in)
    expected_passed = (sum(result == "Passed" for result in expected_results.values())
                       + sum(result == "Passed" for result in present_opt_in.values()))
    expected_skipped = (sum(result == "Skipped" for result in expected_results.values())
                        + sum(result == "Skipped" for result in present_opt_in.values()))

    problems = []
    if len(set(identities)) != len(identities):
        problems.append("duplicate test case identities")
    if len(identities) != expected_total:
        problems.append(f"test case count {len(identities)} != {expected_total}")
    unknown = sorted(set(identities) - set(REQUIRED) - set(OPT_IN))
    if unknown:
        problems.append(f"unknown test cases {unknown}")
    missing = sorted(set(REQUIRED) - set(identities))
    if missing:
        problems.append(f"missing mandatory test cases {missing}")
    wrong_required = sorted(name for name, result in expected_results.items()
                            if results.get(name) != result)
    if wrong_required:
        problems.append(f"unexpected results for mandatory test cases {wrong_required}")
    wrong_opt_in = sorted(name for name, result in present_opt_in.items()
                          if result not in OPT_IN_RESULTS)
    if wrong_opt_in:
        problems.append(f"unexpected results for opt-in test cases {wrong_opt_in}")
    if summary.get("result") != "Passed":
        problems.append(f"summary result is {summary.get('result')!r}")
    if counts["totalTestCount"] != expected_total:
        problems.append(f"totalTestCount {counts['totalTestCount']} != {expected_total}")
    if counts["passedTests"] != expected_passed:
        problems.append(f"passedTests {counts['passedTests']} != {expected_passed}")
    if counts["skippedTests"] != expected_skipped:
        problems.append(f"skippedTests {counts['skippedTests']} != {expected_skipped}")
    if counts["failedTests"]:
        problems.append(f"failedTests is {counts['failedTests']}")
    if counts["expectedFailures"]:
        problems.append(f"expectedFailures is {counts['expectedFailures']}")
    if problems:
        raise ValueError("Notes UI gate failed: " + "; ".join(problems))

    return counts | {"tests": expected_results, "optInTests": present_opt_in,
                     "result": "Passed",
                     "nativeOfficeAccepted": not simulator_without_office,
                     "coverage": "simulator-notes-and-content-covers" if simulator_without_office
                     else "notes-and-native-office"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--result-bundle", required=True)
    parser.add_argument("--summary-output", required=True)
    parser.add_argument("--simulator-without-office", action="store_true",
                        help="Only for simulator builds that do not link FloeOfficeNative; never claims Office acceptance")
    args = parser.parse_args()
    evidence = verify(xcresult_json(args.result_bundle, "summary"), xcresult_json(args.result_bundle, "tests"),
                      simulator_without_office=args.simulator_without_office)
    Path(args.summary_output).write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence))


if __name__ == "__main__":
    main()
