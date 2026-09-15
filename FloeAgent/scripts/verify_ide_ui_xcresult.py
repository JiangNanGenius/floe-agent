#!/usr/bin/env python3
"""Require the actual workbench cold-save/reopen test; skips are not acceptance."""
import argparse
import json
from pathlib import Path
from verify_app_regression_xcresult import nodes, xcresult_json


def verify(summary, tree):
    cases = [n for n in nodes(tree) if n.get("nodeType") == "Test Case"]
    expected = {
        "WorkspaceIDEUITests/testNativeWorkbenchSaveAndColdReopen",
        "WorkspaceIDEUITests/testEngineeringDrawingInlineAndFullScreen",
    }
    found = {str(case.get("nodeIdentifier", "")).removesuffix("()") for case in cases}
    if (summary.get("result") != "Passed" or summary.get("totalTestCount") != len(expected)
            or summary.get("passedTests") != len(expected) or summary.get("failedTests") != 0
            or summary.get("skippedTests") != 0 or summary.get("expectedFailures") != 0
            or len(cases) != len(expected) or found != expected
            or any(case.get("result") != "Passed" for case in cases)):
        raise ValueError("Native IDE save/reopen and engineering preview did not both pass")
    return {"tests": sorted(expected), "result": "Passed", "coverage": "app-workbench-native-save-cold-reopen-and-engineering-preview"}



if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--result-bundle", required=True)
    parser.add_argument("--summary-output", required=True)
    args = parser.parse_args()
    evidence = verify(xcresult_json(args.result_bundle, "summary"), xcresult_json(args.result_bundle, "tests"))
    Path(args.summary_output).write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence))
