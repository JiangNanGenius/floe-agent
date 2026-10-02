#!/usr/bin/env python3
"""Fail-closed tests for the bootstrap engine repair claim handling.

``checked_lock`` must accept the pending-transition case (an old IOS pin with
no repair claim can still prepare a local simulator App component) but once a
pin claims the repair it must be exactly the canonical tracked identity: a
wrong value or an unexpected extra field can never pass, so the release source
check cannot be satisfied by a pre-repair or corrupted pin.
"""
import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = REPO_ROOT / "FloeAgent/scripts"
sys.path.insert(0, str(SCRIPTS))

import bootstrap_office_host as bootstrap  # noqa: E402
import office_engine_repair as repair  # noqa: E402

TRACKED_LOCK = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/engine.lock.json"
PATCH_LOCK = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/engine.patch.lock.json"
COLLAB = REPO_ROOT / "FloeAgent/ThirdParty/Collabora"


class BootstrapEngineRepairClaim(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        # checked_lock resolves the host sources and the adjacent locks
        # relative to the lock directory: mirror the tracked layout.
        for name in ("FloeOfficeNative", "patches"):
            (self.root / name).symlink_to(COLLAB / name)
        for name in ("engine.patch.lock.json", "filter-overlay.lock.json"):
            (self.root / name).symlink_to(COLLAB / name)
        self.lock = self.root / "engine.lock.json"
        self.lock.write_text(TRACKED_LOCK.read_text())
        self.repair_lock, self.section, _ = repair.load_lock(PATCH_LOCK, "IOS")
        self.claim = repair.expected_manifest_block(self.repair_lock, self.section)

    def write_pin(self, engine_repair):
        lock = json.loads(TRACKED_LOCK.read_text())
        if engine_repair is None:
            lock["qualifiedHostArtifact"].pop("engineRepair", None)
        else:
            lock["qualifiedHostArtifact"]["engineRepair"] = engine_repair
        self.lock.write_text(json.dumps(lock, indent=2) + "\n")

    def test_old_pin_without_claim_stays_usable_for_local_preparation(self):
        self.write_pin(None)
        lock, pin = bootstrap.checked_lock(self.lock)
        self.assertNotIn("engineRepair", pin)

    def test_canonical_claim_passes(self):
        self.write_pin(copy.deepcopy(self.claim))
        _, pin = bootstrap.checked_lock(self.lock)
        self.assertEqual(pin["engineRepair"], self.claim)

    def test_wrong_claim_value_is_rejected(self):
        wrong = copy.deepcopy(self.claim)
        wrong["member"]["patchedSHA256"] = "0" * 64
        self.write_pin(wrong)
        with self.assertRaisesRegex(ValueError, "engine repair claim"):
            bootstrap.checked_lock(self.lock)

    def test_extra_receipt_path_is_rejected(self):
        extra = dict(copy.deepcopy(self.claim))
        extra["receiptPath"] = "/tmp/absolute/engine-repair.json"
        self.write_pin(extra)
        with self.assertRaisesRegex(ValueError, "engine repair claim"):
            bootstrap.checked_lock(self.lock)

    def test_missing_claim_field_is_rejected(self):
        missing = copy.deepcopy(self.claim)
        missing.pop("upstreamCommit")
        self.write_pin(missing)
        with self.assertRaisesRegex(ValueError, "engine repair claim"):
            bootstrap.checked_lock(self.lock)


if __name__ == "__main__":
    unittest.main()
