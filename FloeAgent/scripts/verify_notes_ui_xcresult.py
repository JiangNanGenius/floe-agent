#!/usr/bin/env python3
"""Verify Notes UI; explicitly record device-only Office coverage on simulators."""
import argparse
import json
from pathlib import Path
from verify_app_regression_xcresult import nodes, required_count, xcresult_json


def verify(summary, tree, *, simulator_without_office=False):
    counts = {key: required_count(summary, key) for key in
              ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")}
    cases = [node for node in nodes(tree) if node.get("nodeType") == "Test Case"]
    expected = {"NotesWorkspaceImportUITests/testWorkspaceImportAndDocumentAssistant",
                "NotesWorkspaceImportUITests/testPencilToolsAndFocusedLayout",
                "NotesWorkspaceImportUITests/testDocumentTabsAndBodySearch",
                "NotesWorkspaceImportUITests/testNotesLibraryCardsShowRealContentCovers",
                "NotesWorkspaceImportUITests/testOfficeHeaderAssistantSaveAndReopen"}
    identities = [str(case.get("nodeIdentifier", "")).removesuffix("()") for case in cases]
    office = "NotesWorkspaceImportUITests/testOfficeHeaderAssistantSaveAndReopen"
    expected_results = {name: "Passed" for name in expected}
    if simulator_without_office:
        expected_results[office] = "Skipped"
    skipped = int(simulator_without_office)
    if (summary.get("result") != "Passed" or counts["totalTestCount"] != len(expected)
            or counts["passedTests"] != len(expected) - skipped or counts["skippedTests"] != skipped
            or any(counts[key] for key in ("failedTests", "expectedFailures"))
            or len(identities) != len(expected) or set(identities) != expected
            or any(case.get("result") != expected_results.get(identity) for case, identity in zip(cases, identities))):
        raise ValueError("Notes must pass; Office must pass on device or be explicitly recorded as unavailable on simulator")
    return counts | {"tests": expected_results, "result": "Passed",
                     "nativeOfficeAccepted": not simulator_without_office,
                     "coverage": "simulator-notes-and-content-covers" if simulator_without_office else "notes-and-native-office"}


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
