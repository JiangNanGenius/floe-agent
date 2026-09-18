#!/usr/bin/env python3
"""Fail closed unless the strict Quick Look diagnostics fully executed.

``NotesOfficeThumbnailDiagnosticsTests`` is a non-gating system-diagnostic
suite: a failure of an explicit "the system Quick Look host could not produce
content" assertion after a complete run is recorded, not treated as a product
failure. That allowance must never cover a diagnostic that did not really run,
a wrong document/CAS payload, an unexpected error, a throw or a host crash.

This classifier therefore reads the real result bundle through
``xcresulttool get test-results summary`` and ``tests`` and requires:

* exactly the 7 known diagnostic methods are present in the tests tree, each
  with a ``Passed``/``Failed`` result (never ``Skipped`` and never a missing or
  extra case);
* the summary counts agree with the tree (executed/passed/failed/skipped/
  expected failures) and no runtime warning or unknown summary state exists;
* when tests failed, every structured failure message is one of the fixed
  markers the Swift suite attaches to the explicit Quick Look content, timeout
  or icon assertions, in the exact assertion shape for that marker; any other
  failure text (throw, crash, wrong content, resource invariant) is rejected;
* a clean 7/7 run exits 0 and a failed run exits non-zero.

The xcodebuild log is required to exist as raw evidence, but its text is never
used for classification, so a forged log cannot make an empty or crashed run
look like a permitted Quick Look outage. Classification prints to stdout and
the original exit code and raw failure text are written to the status and
failures files. Every unknown state is ``NOT_EXECUTED``, which the workflow
treats as a coverage failure; only ``PASS`` and ``ASSERTION_FAILURE`` are
non-gating.
"""
from __future__ import annotations

import argparse
import pathlib
import sys

from verify_app_regression_xcresult import nodes, required_count, xcresult_json

SUITE_NAME = "NotesOfficeThumbnailDiagnosticsTests"
COVER_SERVICE_CASE = "{}/testCoverServiceReturnsQuickLookContentForEachOfficeType".format(SUITE_NAME)
STRICT_SAMPLE_CASES = frozenset({
    "{}/testStrictQuickLookRendersWordBusinessWeekly".format(SUITE_NAME),
    "{}/testStrictQuickLookRendersWordMeetingNotes".format(SUITE_NAME),
    "{}/testStrictQuickLookRendersExcelQuarterlySummary".format(SUITE_NAME),
    "{}/testStrictQuickLookRendersExcelBudgetForecast".format(SUITE_NAME),
    "{}/testStrictQuickLookRendersPowerPointProductRoadmap".format(SUITE_NAME),
    "{}/testStrictQuickLookRendersPowerPointDesignReview".format(SUITE_NAME),
})
EXPECTED_CASES = STRICT_SAMPLE_CASES | {COVER_SERVICE_CASE}

DIAGNOSTIC_SOURCE = "NotesOfficeThumbnailDiagnosticsTests.swift"

# `xcodebuild test` exits 65 when tests failed. Every other non-zero exit
# (124 timeout, 137/143 killed/crashed, build errors, ...) is not a test
# failure and must stay gating even when a complete 7/7 run already contains a
# marked Quick Look assertion failure.
TEST_FAILURE_EXIT = 65

# Fixed markers the Swift diagnostics suite attaches only to the explicit
# system-Quick-Look-unavailability assertions. Each category is bound to (a)
# the exact assertion shape and phrase it belongs to, (b) the exact diagnostic
# methods that contain that assertion, and (c) a real source location inside
# the diagnostics Swift file. A marker copied onto any other method, assertion
# or free text therefore still fails closed.
ALLOWED_FAILURE_MARKERS = {
    "content": {
        "marker": "[floe-ql-diagnostic:content]",
        "assertion": "XCTAssertEqual failed",
        "detail": "must come from a real Quick Look content representation",
        "extra": '("quickLookThumbnail")',
        "methods": EXPECTED_CASES,
    },
    "timeout": {
        "marker": "[floe-ql-diagnostic:timeout]",
        "assertion": "XCTAssertFalse failed",
        "detail": "must settle with content, not the request deadline",
        "methods": STRICT_SAMPLE_CASES,
    },
    "icon": {
        "marker": "[floe-ql-diagnostic:icon]",
        "assertion": "XCTAssertFalse failed",
        "detail": "returned a generic file icon, not content",
        "methods": STRICT_SAMPLE_CASES,
    },
}


class NotExecuted(Exception):
    """The diagnostic did not fully and cleanly execute; the step must gate.

    ``originals`` carries any raw failure text that was already read from the
    result bundle, so even a fail-closed classification preserves the original
    failure evidence in the failures file.
    """

    def __init__(self, reason, originals=(), executed=None, failures=None):
        super().__init__(reason)
        self.originals = list(originals)
        self.executed = executed
        self.failures = failures


def _case_identifier(node):
    identifier = node.get("nodeIdentifier")
    if not isinstance(identifier, str) or not identifier:
        raise NotExecuted("a test case has no stable nodeIdentifier")
    return identifier.removesuffix("()")


def _failure_records(case):
    """Return the structured failure records of one test case.

    Each record keeps the verbatim failure text and the source location the
    test runner reported, so an allowed failure can be bound to a real
    assertion in the diagnostics source rather than to arbitrary text.
    """
    records = []
    children = case.get("children")
    if children is None:
        return records
    if not isinstance(children, list):
        raise NotExecuted("test case children are not a list")
    for child in children:
        if not isinstance(child, dict):
            raise NotExecuted("test case child is not an object")
        if child.get("nodeType") != "Failure Message":
            continue
        name = child.get("name")
        if not isinstance(name, str) or not name:
            raise NotExecuted("failure message has no text")
        location = child.get("sourceLocation")
        if not isinstance(location, dict):
            raise NotExecuted("failure message has no source location")
        file_path = location.get("filePath")
        line_number = location.get("lineNumber")
        if not isinstance(file_path, str) or not file_path:
            raise NotExecuted("failure message has no source file")
        if type(line_number) is not int or line_number <= 0:
            raise NotExecuted("failure message has no source line")
        records.append({"message": name, "file": file_path, "line": line_number})
    return records


def _allowed_failure(record, method):
    """True only for a marker on its exact method and real assertion.

    ``record`` is one structured failure (verbatim text + source location) and
    ``method`` is the identity of the test case that failed.
    """
    message = record["message"]
    matched = [category for category, spec in ALLOWED_FAILURE_MARKERS.items()
               if spec["marker"] in message]
    if len(matched) != 1:
        return False
    spec = ALLOWED_FAILURE_MARKERS[matched[0]]
    if method not in spec["methods"]:
        return False
    if not record["file"].endswith("/" + DIAGNOSTIC_SOURCE) and record["file"] != DIAGNOSTIC_SOURCE:
        return False
    tokens = [spec["marker"], spec["assertion"], spec["detail"]]
    extra = spec.get("extra")
    if extra is not None:
        # Append the whole expected-value token; iterating a string here would
        # silently accept any failure that merely contains each character.
        tokens.append(extra)
    return all(token in message for token in tokens)


def verify(summary, tree, *, original_exit, family="unknown"):
    """Classify one diagnostic result bundle or raise ``NotExecuted``.

    ``summary`` and ``tree`` are the parsed ``xcresulttool`` structures;
    ``original_exit`` is xcodebuild's raw exit code for this leg.
    """
    if not isinstance(summary, dict) or not isinstance(tree, dict):
        raise NotExecuted("xcresult summary/tests output is not an object")
    executed = required_count(summary, "totalTestCount")
    passed = required_count(summary, "passedTests")
    failed = required_count(summary, "failedTests")
    skipped = required_count(summary, "skippedTests")
    expected_failures = required_count(summary, "expectedFailures")
    originals = []

    def gate(reason):
        # Every fail-closed classification preserves whatever counts and raw
        # failure text were already read from the result bundle.
        raise NotExecuted(reason, originals, executed=executed, failures=failed)

    result = summary.get("result")
    if result not in ("Passed", "Failed"):
        gate("unknown summary result {!r}".format(result))
    if summary.get("runtimeWarnings") != []:
        # A warning/restart entry is an unknown execution state, not a plain
        # Quick Look content failure.
        gate("unexpected runtime warnings in the result bundle")
    if executed != len(EXPECTED_CASES):
        gate("executed {} test(s), expected {}".format(executed, len(EXPECTED_CASES)))
    if passed + failed != executed:
        gate("passed+failed != executed")
    if skipped or expected_failures:
        gate("skipped={} expectedFailures={}".format(skipped, expected_failures))

    cases = []
    for node in nodes(tree):
        if node.get("nodeType") == "Test Case":
            cases.append((_case_identifier(node), node))
    identities = [identity for identity, _ in cases]
    records_by_case = {identity: _failure_records(case) for identity, case in cases}
    originals.extend("{}: {}".format(identity, record["message"])
                     for identity in sorted(records_by_case)
                     for record in records_by_case[identity])

    if len(identities) != executed or len(set(identities)) != len(identities):
        gate("tests tree has {} case(s) for {} executed".format(
            len(identities), executed))
    if set(identities) != EXPECTED_CASES:
        gate("diagnostic case set mismatch: missing={} unexpected={}".format(
            sorted(EXPECTED_CASES - set(identities)),
            sorted(set(identities) - EXPECTED_CASES)))

    failed_cases = {}
    for identity, case in cases:
        case_result = case.get("result")
        if case_result not in ("Passed", "Failed"):
            gate("{} has unknown result {!r}".format(identity, case_result))
        records = records_by_case[identity]
        if case_result == "Failed":
            if not records:
                gate("{} failed without a structured failure message".format(identity))
            failed_cases[identity] = records
        elif records:
            gate("{} passed but still carries failure text".format(identity))
    if len(failed_cases) != failed:
        gate("summary failedTests={} but {} case(s) failed".format(
            failed, len(failed_cases)))
    if (result == "Passed") != (failed == 0):
        gate("summary result {!r} contradicts failedTests={}".format(result, failed))

    if failed == 0:
        if original_exit != 0:
            gate("clean 7/7 run but original exit {}".format(original_exit))
        classification = "PASS"
    else:
        if original_exit != TEST_FAILURE_EXIT:
            gate("diagnostic failures require xcodebuild test-failure exit {}, got {}".format(
                TEST_FAILURE_EXIT, original_exit))
        if not all(_allowed_failure(record, identity)
                   for identity, records in failed_cases.items()
                   for record in records):
            gate("failure is not the exact marked Quick Look "
                 "content/timeout/icon assertion of its diagnostic method")
        classification = "ASSERTION_FAILURE"
    return {
        "classification": classification,
        "family": family,
        "executed": executed,
        "passed": passed,
        "failures": failed,
        "expected": len(EXPECTED_CASES),
        "result": result,
        "bundle": "present",
        "original_exit": original_exit,
        "failure_originals": originals,
    }


def _write_evidence(status_path, failures_path, evidence):
    status_lines = [
        "classification={}".format(evidence["classification"]),
        "diagnostic family={} exit={} executed={} failures={} expected={} result={} bundle={}".format(
            evidence["family"], evidence["original_exit"], evidence["executed"],
            evidence["failures"], evidence["expected"], evidence["result"],
            evidence["bundle"]),
        "original exit={}".format(evidence["original_exit"]),
    ]
    if evidence.get("reason"):
        status_lines.append("reason={}".format(evidence["reason"]))
    pathlib.Path(status_path).write_text("\n".join(status_lines) + "\n", encoding="utf-8")
    originals = evidence.get("failure_originals") or []
    if not originals and evidence.get("reason"):
        originals = [evidence["reason"]]
    pathlib.Path(failures_path).write_text(
        "".join("{}\n".format(line) for line in originals), encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result-bundle", required=True)
    parser.add_argument("--log", required=True, help="raw xcodebuild log (presence-checked evidence only)")
    parser.add_argument("--family", default="unknown")
    parser.add_argument("--original-exit", required=True, help="xcodebuild raw exit code for this leg")
    parser.add_argument("--status-output", required=True)
    parser.add_argument("--failures-output", required=True)
    args = parser.parse_args(argv)

    evidence = {
        "classification": "NOT_EXECUTED",
        "family": args.family,
        "executed": None,
        "failures": None,
        "expected": len(EXPECTED_CASES),
        "result": "missing",
        "bundle": "missing",
        "original_exit": None,
        "failure_originals": [],
        "reason": "",
    }
    try:
        original_exit = int(args.original_exit)
        evidence["original_exit"] = original_exit
    except ValueError:
        evidence["reason"] = "invalid original exit {!r}".format(args.original_exit)
    else:
        bundle = pathlib.Path(args.result_bundle)
        log = pathlib.Path(args.log)
        bundle_present = bundle.is_dir() and any(bundle.iterdir())
        evidence["bundle"] = "present" if bundle_present else "missing"
        try:
            if not bundle_present:
                raise NotExecuted("result bundle is missing or empty")
            if not log.is_file() or log.stat().st_size == 0:
                raise NotExecuted("xcodebuild log is missing or empty")
            evidence.update(verify(
                xcresult_json(args.result_bundle, "summary"),
                xcresult_json(args.result_bundle, "tests"),
                original_exit=original_exit,
                family=args.family))
        except Exception as error:  # fail closed on every unknown state
            evidence["classification"] = "NOT_EXECUTED"
            evidence["result"] = "missing" if not bundle_present else "unknown"
            evidence["failure_originals"] = list(getattr(error, "originals", []) or [])
            evidence["executed"] = getattr(error, "executed", None)
            evidence["failures"] = getattr(error, "failures", None)
            evidence["reason"] = str(error)[:240] or error.__class__.__name__

    try:
        _write_evidence(args.status_output, args.failures_output, evidence)
    except Exception as error:  # cannot record evidence -> the step must gate
        sys.stderr.write("failed to write diagnostic evidence: {}\n".format(error))
        print("NOT_EXECUTED")
        return 1
    print(evidence["classification"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
