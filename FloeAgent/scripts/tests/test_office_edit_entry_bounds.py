#!/usr/bin/env python3
"""Source-invariant bounds for the packaged Office edit-entry/render chains.

The Build 223 PPT edit stall was born in the packaged host's edit-mode
initialization: single-shot `evaluateJavaScript` probes with short budgets and
completion-driven deadlines that a slow or busy engine page (the multi-megabyte
editor bundle) outlives, plus native continuations that could be lost silently.
These tests pin the shipped bounds so a later refactor cannot quietly restore
the fragile chain:

1. the render probe's deadline is wall-clock driven (a timer reports the
   bounded outcome even when a probe eval never completes);
2. the permission probe's budget outlasts a cold device page load, and its
   give-up reports the truthful unknown state;
3. the edit entry retries a not-ready/busy page, bounded, and never loses a
   completion silently (`if (!host) return;` is gone from the chain);
4. the App's edit acknowledgement is bounded, so a lost native completion can
   never wedge the session's `operating` lock;
5. the pin is never rewritten to a hash the artifact was not built from: the
   check fails closed with the rebuild workflow until CI rebuilds the host.
"""

import json
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
HOST_SOURCE = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm"
APP_SOURCE = REPO_ROOT / "FloeAgent/FloeApp/Workspace/OfficeDocumentEditorView.swift"
LOCK = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/engine.lock.json"


class EditEntryChainBounds(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.host = HOST_SOURCE.read_text()
        cls.app = APP_SOURCE.read_text()

    def test_render_probe_deadline_is_wall_clock_driven(self):
        """The bounded render outcome fires at the deadline even if an eval wedges."""
        self.assertIn("DISPATCH_SOURCE_TYPE_TIMER", self.host,
                      "the render probe needs a wall-clock deadline timer")
        probe = self.host.split("// FLOE_RENDER_PROBE_BEGIN", 1)[1].split("// FLOE_RENDER_PROBE_END", 1)[0]
        self.assertIn("_deadlineTimer", probe)
        self.assertIn("invalidateDeadlineTimer", probe)
        self.assertIn('finishWithStage:@"deadline"', probe)

    def test_permission_probe_budget_outlasts_a_cold_page_load(self):
        """The probe budget must cover a multi-second editor-bundle page load."""
        self.assertIn("attempts >= 150", self.host,
                      "the permission probe must not give up at the old 4s budget")
        self.assertNotIn("attempts >= 40", self.host)

    def test_edit_entry_retries_transient_states_and_never_loses_a_completion(self):
        """A not-ready/busy page is retried, bounded; completions always settle."""
        self.assertIn("attemptEngineEditEntryWithAttempts", self.host)
        self.assertIn('"not-ready"', self.host)
        chain = self.host.split("attemptEngineEditEntryWithAttempts", 1)[1]
        self.assertIn("attempts < 24", chain)
        # No silent completion loss anywhere in the edit-entry/permission chain.
        for marker in ("attemptEngineEditEntryWithAttempts", "probeEnginePermissionWithAttempts"):
            segment = self.host.split(marker, 1)[1].split("}", 1)[0]
            self.assertNotIn("if (!host) return;", segment,
                             f"{marker} must settle its completion when the controller is gone")

    def test_app_edit_acknowledgement_is_bounded(self):
        """A lost native edit-entry completion can never wedge the session."""
        self.assertIn("OfficeEditEntryAck", self.app)
        self.assertIn("ack.resolve((true, false))", self.app,
                      "the edit-entry timeout must read as unverified-read-only")
        self.assertNotIn(
            "await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, Bool), Never>) in\n"
            "            native.enterEditMode",
            self.app,
            "the unbounded edit-entry continuation must not come back")

    def test_pin_fails_closed_until_ci_rebuilds_the_host(self):
        """The host sources lead the pinned framework; the release path fails closed.

        The edit-entry repair changes `FloeOfficeNative.mm`, so the pinned
        artifact (run 35668651442, source `c4ff0dde`) predates it. The pin must
        NOT be rewritten to the new hash (that would claim the artifact matches
        a source it was never built from): the check reports SOURCE AHEAD OF
        ARTIFACT and names the rebuild workflow until CI rebuilds and re-pins.
        """
        import hashlib
        import subprocess
        pin = json.loads(LOCK.read_text())["qualifiedHostArtifact"]
        digest = hashlib.sha256(HOST_SOURCE.read_bytes()).hexdigest()
        if digest == pin["hostSourceSHA256"]["FloeOfficeNative.mm"]:
            self.skipTest("host artifact already rebuilt from these sources")
        self.assertNotEqual(pin["hostSourceSHA256"]["FloeOfficeNative.mm"], digest,
                            "the pinned hash must never claim an artifact built from other sources")
        check = subprocess.run(
            [sys.executable, str(REPO_ROOT / "FloeAgent/scripts/pin_office_host_artifact.py"), "--check"],
            capture_output=True, text=True, check=False, timeout=60,
        )
        self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
        self.assertIn("SOURCE AHEAD OF ARTIFACT", check.stdout)
        self.assertIn("office-native-host.yml", check.stdout)


if __name__ == "__main__":
    unittest.main()
