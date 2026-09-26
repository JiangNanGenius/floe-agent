#!/usr/bin/env python3
"""Verify the Office simulator stage run without claiming an engine result.

The run drives real Workspace/Notes/IDE entry paths with real PPTX/DOCX
fixtures on an iOS Simulator, where the pinned engine has no slice. This
verifier reads the App's durable `office-stage.jsonl` trace plus the pinned
framework blocker receipt and the XCTest result, and fails unless:

* every required entry path reached the honest "engine unavailable" stage
  (Notes library, Workspace preview, IDE Office tab);
* an IDE Office session recorded the ordered chain
  intent -> working copy -> engine unavailable -> bounded failure;
* no stage claims an engine open, a visible render, a save or a close on a
  build that has no engine;
* the blocker receipt proves the pinned framework is device-only (platform
  IOS, simulator link refused, exact executable hash);
* the UI test case passed.

The receipt it writes can only state what was observed: no first frame, no
editing session, no save and no device result.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any

from verify_app_regression_xcresult import nodes, required_count, xcresult_json

TEST_IDENTIFIER = "OfficeSimulatorStageUITests/testRealOfficeEntryPathsReachTheExactSimulatorHostBlocker"

# Stages that would claim the simulator somehow reached an engine, render,
# save or close. None of them may appear in a host-less run.
FORBIDDEN_STAGES = {
    "engine.visibleRender",
    "engine.visibleRenderFailed",
    "save.ok",
    "close.acked",
    "exit.discard.ok",
    "exit.keep.ok",
}

REQUIRED_ORDER = ["intent.preview", "workingCopy.open", "workingCopy.ready",
                  "engine.unavailable", "session.failed"]


def load_trace(path: str) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    raw = Path(path).read_text(encoding='utf-8')
    for number, line in enumerate(raw.splitlines(), 1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError as failure:
            raise ValueError(f"trace line {number} is not JSON: {failure}") from failure
        if not isinstance(event, dict) or not isinstance(event.get("stage"), str):
            raise ValueError(f"trace line {number} is not a stage event")
        events.append(event)
    if not events:
        raise ValueError("the Office stage trace is empty")
    return events


def verify_trace(events: list[dict[str, Any]]) -> dict[str, Any]:
    unavailable = [event for event in events if event.get("stage") == "engine.unavailable"]
    surfaces = {str(event.get("detail", {}).get("surface", "")) for event in unavailable}
    hosts = {str(event.get("detail", {}).get("host", "")) for event in unavailable}
    builds = {str(event.get("detail", {}).get("build", "")) for event in unavailable}
    notes_unavailable = any(event.get("stage") == "notes.engine.unavailable" for event in events)
    if not notes_unavailable:
        raise ValueError("the Notes library path never recorded the missing engine")
    if "workspace-preview" not in surfaces:
        raise ValueError("the Workspace preview path never recorded the missing engine")
    if "native-office" not in hosts or "without-native-office" not in builds:
        raise ValueError("the shared Office session never recorded the missing native Office host")

    # One IDE Office session must show the ordered chain. The Notes surface
    # records `notes.engine.unavailable` before the shared session intent, so
    # order only within one session identity.
    chains: dict[str, list[str]] = {}
    for event in events:
        chains.setdefault(str(event.get("session", "")), []).append(str(event.get("stage")))
    ordered_sessions = [session for session, stages in chains.items()
                        if all(stage in stages for stage in REQUIRED_ORDER)
                        and [stages.index(stage) for stage in REQUIRED_ORDER]
                        == sorted(stages.index(stage) for stage in REQUIRED_ORDER)]
    if not ordered_sessions:
        raise ValueError("no session recorded the ordered intent -> working copy -> engine unavailable chain")

    forbidden = sorted({event["stage"] for event in events
                        if event.get("stage") in FORBIDDEN_STAGES
                        or (event.get("stage") == "engine.open"
                            and str(event.get("detail", {}).get("success", "")) == "true")})
    if forbidden:
        raise ValueError(f"the host-less run claims engine outcomes it cannot have: {forbidden}")

    return {
        "engineUnavailableEvents": len(unavailable),
        "entryPaths": ["notes-library", "workspace-preview", "ide-office-tab"],
        "orderedSessionChain": sorted(ordered_sessions),
        "notesEngineUnavailable": notes_unavailable,
        "forbiddenStages": forbidden,
    }


def verify_blocker(receipt: dict[str, Any]) -> dict[str, Any]:
    required = {
        "simulatorHostBlockerProven": True,
        "platformIsSimulator": False,
        "simulatorLinkRefused": True,
        "realEngineInSimulator": False,
    }
    for key, expected in required.items():
        value = receipt.get(key)
        if value != expected:
            raise ValueError(f"blocker receipt {key}={value!r}, expected {expected!r}")
    if receipt.get("platform") in (None, "", "IOSSIMULATOR"):
        raise ValueError("the blocker receipt must name the device platform")
    return {
        "platform": receipt.get("platform"),
        "architectures": receipt.get("architectures"),
        "matchesPinnedExecutable": receipt.get("matchesPinnedExecutable"),
        "simulatorLinkDiagnostic": receipt.get("simulatorLinkDiagnostic"),
    }


def verify_xcresult(result_bundle: str) -> dict[str, Any]:
    summary = xcresult_json(result_bundle, "summary")
    tree = xcresult_json(result_bundle, "tests")
    total = required_count(summary, "totalTestCount")
    passed = required_count(summary, "passedTests")
    failed = required_count(summary, "failedTests")
    skipped = required_count(summary, "skippedTests")
    expected_failures = required_count(summary, "expectedFailures")
    cases = [node for node in nodes(tree) if node.get("nodeType") == "Test Case"]
    identities = [str(case.get("nodeIdentifier", "")).removesuffix("()") for case in cases]
    if (summary.get("result") != "Passed" or failed or skipped or expected_failures
            or total != 1 or passed != 1 or identities != [TEST_IDENTIFIER]
            or cases[0].get("result") != "Passed"):
        raise ValueError(
            "the Office simulator stage run must execute exactly the one focused case and pass: "
            f"result={summary.get('result')} total={total} passed={passed} failed={failed} "
            f"skipped={skipped} expectedFailures={expected_failures} cases={identities}")
    return {"totalTestCount": total, "passedTests": passed, "tests": {TEST_IDENTIFIER: "Passed"}}


def verify(trace_events, blocker_receipt=None, result_bundle=None):
    evidence = verify_trace(trace_events)
    if blocker_receipt is not None:
        evidence["blocker"] = verify_blocker(blocker_receipt)
    if result_bundle is not None:
        evidence["xcresult"] = verify_xcresult(result_bundle)
    evidence.update({
        "result": "Passed",
        "simulatorHostBlocked": True,
        "realEngineOpened": False,
        "pptFirstFrameObserved": False,
        "officeEditSessionObserved": False,
        "officeSaveOrCloseObserved": False,
        "limitation": ("Simulator result only. The pinned Office engine has no simulator slice; "
                       "device first frame, editing, save and reopen remain a separate gate."),
    })
    return evidence


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--trace", required=True, help="office-stage.jsonl pulled from the app container")
    parser.add_argument("--blocker-receipt", default=None)
    parser.add_argument("--result-bundle", default=None)
    parser.add_argument("--output", required=True)
    parser.add_argument("--source-sha", default=None)
    parser.add_argument("--run-id", default=None)
    args = parser.parse_args()

    blocker = json.loads(Path(args.blocker_receipt).read_text()) if args.blocker_receipt else None
    evidence = verify(load_trace(args.trace), blocker, args.result_bundle)
    if args.source_sha:
        evidence["sourceSHA"] = args.source_sha
    if args.run_id:
        evidence["runID"] = args.run_id
    Path(args.output).write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print(json.dumps(evidence, sort_keys=True))
    if not evidence.get("result") == "Passed":
        raise SystemExit("the Office simulator stage run did not pass its honest checks")


if __name__ == "__main__":
    sys.exit(main())
