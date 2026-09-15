#!/usr/bin/env python3
"""Require real Notes import and native Office flows, with no skips or failures."""
import argparse
import json
from pathlib import Path
from verify_app_regression_xcresult import nodes, required_count, xcresult_json


def verify(summary, tree):
    counts = {key: required_count(summary, key) for key in
              ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")}
    cases = [node for node in nodes(tree) if node.get("nodeType") == "Test Case"]
    expected = {"NotesWorkspaceImportUITests/testWorkspaceImportTabsFocusAndBodySearch",
                "NotesWorkspaceImportUITests/testOfficeHeaderAssistantSaveAndReopen"}
    identities = [str(case.get("nodeIdentifier", "")).removesuffix("()") for case in cases]
    if (summary.get("result") != "Passed" or counts["totalTestCount"] != len(expected)
            or counts["passedTests"] != len(expected) or any(counts[key] for key in
                ("failedTests", "skippedTests", "expectedFailures"))
            or len(identities) != len(expected) or set(identities) != expected
            or any(case.get("result") != "Passed" for case in cases)):
        raise ValueError("Notes import and Office UI must each execute and pass exactly once")
    return counts | {"tests": sorted(identities), "result": "Passed"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--result-bundle", required=True)
    parser.add_argument("--summary-output", required=True)
    args = parser.parse_args()
    evidence = verify(xcresult_json(args.result_bundle, "summary"), xcresult_json(args.result_bundle, "tests"))
    Path(args.summary_output).write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence))


if __name__ == "__main__":
    main()
