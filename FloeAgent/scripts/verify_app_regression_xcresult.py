#!/usr/bin/env python3
"""Fail unless every focused iOS regression suite actually ran and passed."""

from __future__ import annotations

import argparse
import collections
import json
import pathlib
import subprocess
from typing import Any, Iterator


SUITE_MINIMUMS = {
    "CanvasTouchInteractionTests": 3,
    "CanvasSavedImageBatchAtomicityTests": 9,
    "CanvasAgentToolContractTests": 8,
    "CrashAndFeedbackRegressionTests": 38,
    "ThreadTimelineTests": 18,
    "BrowserProtocolTests": 6,
    "MailConnectorTests": 5,
    "SkillLifecycleTests": 1,
}


def xcresult_json(result_bundle: str, section: str) -> dict[str, Any]:
    output = subprocess.check_output(
        [
            "xcrun",
            "xcresulttool",
            "get",
            "test-results",
            section,
            "--path",
            result_bundle,
            "--compact",
        ],
        text=True,
    )
    value = json.loads(output)
    if not isinstance(value, dict):
        raise SystemExit(f"xcresult {section} output is not an object")
    return value


def nodes(value: Any) -> Iterator[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


def required_count(summary: dict[str, Any], name: str) -> int:
    value = summary.get(name)
    if type(value) is not int:
        raise SystemExit(
            f"xcresult summary is missing integer {name}: {value!r}"
        )
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result-bundle", required=True)
    parser.add_argument("--github-output")
    parser.add_argument("--summary-output")
    args = parser.parse_args()

    summary = xcresult_json(args.result_bundle, "summary")
    test_tree = xcresult_json(args.result_bundle, "tests")
    total = required_count(summary, "totalTestCount")
    passed = required_count(summary, "passedTests")
    failed = required_count(summary, "failedTests")
    skipped = required_count(summary, "skippedTests")
    expected_failures = required_count(summary, "expectedFailures")
    result = summary.get("result")

    suite_counts: collections.Counter[str] = collections.Counter()
    nonpassing_cases: list[str] = []
    for node in nodes(test_tree):
        if node.get("nodeType") != "Test Case":
            continue
        identifier = node.get("nodeIdentifier")
        if not isinstance(identifier, str) or "/" not in identifier:
            raise SystemExit(f"test case has no stable identifier: {identifier!r}")
        suite = identifier.split("/", 1)[0]
        if suite in SUITE_MINIMUMS:
            suite_counts[suite] += 1
            if node.get("result") != "Passed":
                nonpassing_cases.append(identifier)

    missing = {
        suite: (suite_counts[suite], minimum)
        for suite, minimum in SUITE_MINIMUMS.items()
        if suite_counts[suite] < minimum
    }
    minimum_total = sum(SUITE_MINIMUMS.values())
    print(
        "canvas-pip-timeline-app-regression-summary "
        f"total={total} passed={passed} failed={failed} skipped={skipped} "
        f"expectedFailures={expected_failures} result={result}"
    )
    for suite, minimum in SUITE_MINIMUMS.items():
        print(
            "canvas-pip-timeline-suite-summary "
            f"suite={suite} executed={suite_counts[suite]} minimum={minimum}"
        )

    if (
        result != "Passed"
        or total < minimum_total
        or failed != 0
        or skipped != 0
        or expected_failures != 0
        or passed != total
        or missing
        or nonpassing_cases
    ):
        raise SystemExit(
            "Canvas, PiP, and timeline focused test gate failed: "
            f"missing={missing!r} nonpassing={nonpassing_cases!r}"
        )

    lines = [
        "suite=canvas-pip-timeline-app-regression",
        f"total={total}",
        f"passed={passed}",
        f"failed={failed}",
        f"skipped={skipped}",
        f"expected_failures={expected_failures}",
        f"result={result}",
    ]
    lines.extend(
        f"suite_{suite}={suite_counts[suite]}"
        for suite in SUITE_MINIMUMS
    )
    if args.summary_output:
        pathlib.Path(args.summary_output).write_text(
            "\n".join(lines) + "\n", encoding="utf-8"
        )
    if args.github_output:
        pathlib.Path(args.github_output).open("a", encoding="utf-8").write(
            "\n".join(lines[1:6]) + "\n"
        )


if __name__ == "__main__":
    main()
