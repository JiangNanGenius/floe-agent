#!/usr/bin/env python3
"""Decide whether a Notes UI attempt may be retried once (read-only).

The release workflow runs each Notes workspace UI leg at most twice: attempt 1
keeps its own diagnostics directory, attempt log and result bundle, and a second
attempt is allowed only when attempt 1 proves it never executed a test.
Exactly two infrastructure shapes qualify:

* ``stalled`` before the first test (exit 124), the pre-existing retry; or
* the narrowly known XCTest runner bootstrap crash observed on Xcode 27:
  ``Early unexpected exit`` / ``test runner crashed while preparing to run
  tests`` at ``-[XCTWaiter(StallHandling) handleStalledWait:]`` (exit 65).

Anything else -- an executed test failure, an assertion, an App crash, a
different bootstrap error, a timeout after tests started, contradictory or
malformed evidence -- is reported as not retryable. The workflow treats this
helper as the only decision point: if the helper itself or either evidence file
is missing or unreadable, the leg fails closed instead of retrying.

This helper only reads the attempt summary and its original attempt log; it
does not touch result bundles, simulators or the compiled test host. Exit code
0 means "one retry is eligible", 1 means "not retryable"; the JSON verdict is
printed to stdout either way.
"""
import argparse
import json
import re
import sys
from pathlib import Path

# The exact runner bootstrap failure retained from run 35292395886, job
# 105437894361 (SDK 27 iPhone Notes leg): all three tokens must appear on the
# same xcodebuild error line, plus the stall-handling frame of that crash.
KNOWN_BOOTSTRAP_MARKERS = (
    "Early unexpected exit, operation never finished bootstrapping",
    "test runner crashed while preparing to run tests:",
)
RUNNER_STALL_FRAME = re.compile(
    r"-Runner at -\[XCTWaiter\(StallHandling\) handleStalledWait:\]")

# Evidence that XCTest executed (or failed) real tests. Any of these means the
# attempt is a real signal and must never be retried into a pass: failed Office
# cover assertions and every other executed failure land here.
EXECUTED_MARKERS = (
    "Test Case '-[",
    "Test Suite '",
    "Test run started",
    "Failing tests:",
    "error: -[",
    "Executed ",
    "XCTAssert",
)

# Evidence that the App under test (or its launch) crashed rather than the
# runner stalling before bootstrap.
APPLICATION_CRASH_MARKERS = (
    "Application 'Floe Agent' crashed",
    'Application "Floe Agent" crashed',
    "crashed during launch",
    "Failed to launch",
    "failed to launch",
    "terminated unexpectedly",
)


def known_bootstrap_crash(log_text):
    """True only for the observed runner stall-handling bootstrap crash."""
    for line in log_text.splitlines():
        if (all(marker in line for marker in KNOWN_BOOTSTRAP_MARKERS)
                and RUNNER_STALL_FRAME.search(line)):
            return True
    return False


def evidence_blockers(log_text):
    """Return the executed-test/App-crash markers present in the log."""
    return [marker for marker in EXECUTED_MARKERS + APPLICATION_CRASH_MARKERS
            if marker in log_text]


def _blocked(result, blockers):
    if any(marker in EXECUTED_MARKERS for marker in blockers):
        result["classification"] = "executed-test-evidence"
        result["detail"] = "executed test evidence present: " + ", ".join(blockers)
    else:
        result["classification"] = "application-crash-evidence"
        result["detail"] = "application crash evidence present: " + ", ".join(blockers)
    return result


def classify(summary, log_text, attempt=1):
    """Classify one attempt from its parsed summary and original log text."""
    result = {"retry": False, "classification": "not-retryable", "detail": "",
              "exitCode": None, "reason": None, "testsStarted": None}
    if isinstance(attempt, bool) or not isinstance(attempt, int) or attempt != 1:
        result["classification"] = "attempt-limit"
        result["detail"] = "only attempt 1 is eligible for a single retry"
        return result
    if not isinstance(summary, dict):
        result["classification"] = "malformed-evidence"
        result["detail"] = "summary is not a JSON object"
        return result
    result["exitCode"] = summary.get("exitCode")
    result["reason"] = summary.get("reason")
    result["testsStarted"] = summary.get("testsStarted")
    if summary.get("testsStarted") is not False:
        result["classification"] = "tests-started-or-unknown"
        result["detail"] = "testsStarted is not exactly false"
        return result
    reason = summary.get("reason")
    exit_code = summary.get("exitCode")
    if isinstance(exit_code, bool) or not isinstance(exit_code, int):
        result["classification"] = "malformed-evidence"
        result["detail"] = "summary exitCode is missing or not an integer"
        return result
    if reason == "stalled":
        if exit_code != 124:
            result["classification"] = "unexpected-exit-code"
            result["detail"] = "stalled reason requires exit 124, got %s" % exit_code
            return result
    elif reason == "exited":
        if exit_code != 65:
            result["classification"] = "unexpected-exit-code"
            result["detail"] = "bootstrap crash requires exit 65, got %s" % exit_code
            return result
    else:
        result["classification"] = "unexpected-reason"
        result["detail"] = "reason %r is not a retryable pre-test shape" % (reason,)
        return result

    # Executed-test and App-crash evidence outranks the bootstrap shape: a log
    # that contains either is a real signal and is never retried.
    blockers = evidence_blockers(log_text)
    if blockers:
        return _blocked(result, blockers)
    if reason == "exited" and not known_bootstrap_crash(log_text):
        result["classification"] = "unknown-bootstrap-error"
        result["detail"] = ("log lacks the observed Early unexpected exit / "
                            "handleStalledWait runner bootstrap signature")
        return result

    result["retry"] = True
    result["classification"] = ("stalled-before-tests" if reason == "stalled"
                                else "bootstrap-crash-before-tests")
    result["detail"] = "no test case, suite or App crash evidence in the attempt log"
    return result


def _load_evidence(summary_path, log_path):
    try:
        summary = json.loads(Path(summary_path).read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeDecodeError) as error:
        return None, None, "summary unreadable or not JSON: %s" % error
    try:
        log_text = Path(log_path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        return None, None, "attempt log unreadable: %s" % error
    if not log_text.strip():
        return None, None, "attempt log is empty"
    return summary, log_text, None


def _parse_attempt(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", required=True,
                        help="run_test_with_diagnostics.py summary.json")
    parser.add_argument("--log", required=True,
                        help="original attempt log (the tee'd xcodebuild output)")
    parser.add_argument("--attempt", default=1,
                        help="attempt number; only 1 may retry (default: 1)")
    args = parser.parse_args(argv)
    attempt = _parse_attempt(args.attempt)
    if attempt is None:
        result = {"retry": False, "classification": "malformed-evidence",
                  "detail": "--attempt is not an integer", "exitCode": None,
                  "reason": None, "testsStarted": None}
    else:
        summary, log_text, error = _load_evidence(args.summary, args.log)
        if error is not None:
            result = {"retry": False, "classification": "missing-evidence",
                      "detail": error, "exitCode": None, "reason": None,
                      "testsStarted": None}
        else:
            result = classify(summary, log_text, attempt=attempt)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result["retry"] else 1


if __name__ == "__main__":
    sys.exit(main())
