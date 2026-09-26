#!/usr/bin/env python3
"""Focused checks for the Office simulator stage-trace verifier.

These tests feed the verifier synthetic traces and blocker receipts. They pin
the honesty rules: a host-less run must record every entry path's missing
engine, must never claim an engine open/render/save/close, and must fail closed
when a stage or the blocker proof is missing.
"""

import json
from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

import verify_office_simulator_stage_trace as verifier  # noqa: E402


def event(session, generation, stage, detail=None):
    return {"session": session, "generation": generation, "stage": stage,
            "detail": detail or {}, "at": "2026-09-26T00:00:00Z"}


def honest_trace():
    return [
        event("notes-1", 0, "notes.engine.unavailable", {"format": "pptx"}),
        event("workspace-preview-1", 0, "engine.unavailable",
              {"surface": "workspace-preview", "format": "pptx"}),
        event("ide-1", 1, "intent.preview", {"format": "pptx"}),
        event("ide-1", 1, "workingCopy.open", {"format": "pptx"}),
        event("ide-1", 1, "workingCopy.ready"),
        event("ide-1", 1, "engine.unavailable", {"host": "native-office", "build": "without-native-office", "format": "pptx"}),
        event("ide-1", 1, "session.failed", {"domain": "NSCocoaErrorDomain", "code": "3328"}),
    ]


def honest_blocker():
    return {
        "platform": "IOS",
        "platformIsSimulator": False,
        "architectures": ["arm64"],
        "simulatorLinkRefused": True,
        "simulatorHostBlockerProven": True,
        "realEngineInSimulator": False,
        "matchesPinnedExecutable": True,
        "simulatorLinkDiagnostic": "ld: building for 'iOS-simulator', but linking in dylib (...) built for 'iOS'",
    }


class StageTraceVerifierTests(unittest.TestCase):
    def test_honest_trace_and_blocker_pass(self):
        evidence = verifier.verify(honest_trace(), honest_blocker())
        self.assertEqual(evidence["result"], "Passed")
        self.assertTrue(evidence["simulatorHostBlocked"])
        self.assertFalse(evidence["realEngineOpened"])
        self.assertFalse(evidence["pptFirstFrameObserved"])
        self.assertEqual(evidence["blocker"]["platform"], "IOS")

    def test_notes_path_is_required(self):
        trace = [item for item in honest_trace() if item["stage"] != "notes.engine.unavailable"]
        with self.assertRaises(ValueError):
            verifier.verify(trace)

    def test_workspace_preview_path_is_required(self):
        trace = [item for item in honest_trace() if item["session"] != "workspace-preview-1"]
        with self.assertRaises(ValueError):
            verifier.verify(trace)

    def test_ordered_session_chain_is_required(self):
        trace = honest_trace()
        trace.append(event("ide-1", 1, "engine.unavailable", {"host": "native-office", "build": "without-native-office"}))
        # The required order must exist within one session; a shuffled trace
        # with the same stages is rejected.
        shuffled = [item for item in honest_trace() if item["stage"] != "workingCopy.ready"]
        shuffled.append(event("ide-1", 1, "workingCopy.ready"))
        with self.assertRaises(ValueError):
            verifier.verify(shuffled)

    def test_engine_success_claims_are_rejected(self):
        for stage in ("engine.visibleRender", "save.ok", "close.acked"):
            trace = honest_trace() + [event("ide-1", 1, stage)]
            with self.assertRaises(ValueError, msg=stage):
                verifier.verify(trace)
        claimed_open = honest_trace() + [event("ide-1", 1, "engine.open", {"success": "true"})]
        with self.assertRaises(ValueError):
            verifier.verify(claimed_open)

    def test_blocker_receipt_must_prove_the_device_only_slice(self):
        blocker = honest_blocker()
        blocker["platform"] = "IOSSIMULATOR"
        with self.assertRaises(ValueError):
            verifier.verify(honest_trace(), blocker)
        blocker = honest_blocker()
        blocker["simulatorLinkRefused"] = False
        with self.assertRaises(ValueError):
            verifier.verify(honest_trace(), blocker)

    def test_trace_loading_rejects_empty_and_malformed_files(self):
        path = Path('/tmp/floe-office-stage-test.jsonl')
        path.write_text('')
        with self.assertRaises(ValueError):
            verifier.load_trace(str(path))
        path.write_text('not json\n')
        with self.assertRaises(ValueError):
            verifier.load_trace(str(path))
        path.write_text(json.dumps(honest_trace()[0]) + '\n')
        self.assertEqual(len(verifier.load_trace(str(path))), 1)
        path.unlink()


if __name__ == '__main__':
    unittest.main()
