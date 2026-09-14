#!/usr/bin/env python3
"""Require the real Notes workspace import UI case, with no skips or failures."""
import argparse
import json
from pathlib import Path
from verify_app_regression_xcresult import nodes, required_count, xcresult_json


def verify(summary, tree):
    counts = {key: required_count(summary, key) for key in
              ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")}
    cases = [node for node in nodes(tree) if node.get("nodeType") == "Test Case"]
    expected = "NotesWorkspaceImportUITests/testWorkspaceImportTabsFocusAndBodySearch"
    identity = str(cases[0].get("nodeIdentifier", "")).removesuffix("()") if len(cases) == 1 else ""
    if (summary.get("result") != "Passed" or counts["totalTestCount"] != 1
            or counts["passedTests"] != 1 or any(counts[key] for key in
                ("failedTests", "skippedTests", "expectedFailures"))
            or identity != expected or cases[0].get("result") != "Passed"):
        raise ValueError("Notes workspace import UI did not execute and pass exactly once")
    return counts | {"test": identity, "result": "Passed"}


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
