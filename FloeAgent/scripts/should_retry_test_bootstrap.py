#!/usr/bin/env python3
"""Allow one IDE UI rerun only for an XCTest runner startup failure."""

import json
import pathlib
import sys


def should_retry(summary: dict, log: str) -> bool:
    if summary.get("testsStarted"):
        return False
    if summary.get("exitCode") == 124 and summary.get("reason") == "stalled":
        return True
    return (
        summary.get("exitCode") == 65
        and "Early unexpected exit, operation never finished bootstrapping" in log
        and "The test runner crashed while preparing to run tests" in log
    )


if __name__ == "__main__":
    summary = json.loads(pathlib.Path(sys.argv[1]).read_text())
    log = pathlib.Path(sys.argv[2]).read_text(errors="replace")
    sys.exit(0 if should_retry(summary, log) else 1)
