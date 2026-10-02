#!/usr/bin/env python3
"""Fail-closed tests for the native Office host pin's engine repair claim.

The tracked single-member engine repair is part of the host identity now.  A
pin must carry exactly the canonical claim; a missing claim means the pinned
framework predates the repair (SOURCE AHEAD), while a present-but-different
claim (wrong SHA/platform/member/lock or an extra diagnostic field such as an
absolute receipt path) is corrupt and must be rejected outright.  ``--check``
stays strictly read-only.
"""
import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPTS = REPO_ROOT / "FloeAgent/scripts"
sys.path.insert(0, str(SCRIPTS))

import office_engine_repair as repair  # noqa: E402
import pin_office_host_artifact as pin  # noqa: E402

TRACKED_LOCK = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/engine.lock.json"
PATCH_LOCK = REPO_ROOT / "FloeAgent/ThirdParty/Collabora/engine.patch.lock.json"


class PinEngineRepairClaim(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.lock = self.root / "engine.lock.json"
        self.lock.write_text(TRACKED_LOCK.read_text())
        # The pin script resolves the sibling engine contract next to the lock.
        (self.root / "engine.patch.lock.json").symlink_to(PATCH_LOCK)
        self.repair_lock, self.section, _ = repair.load_lock(
            PATCH_LOCK, "IOS")
        self.claim = repair.expected_manifest_block(self.repair_lock, self.section)

    def run_check(self, lock_path=None):
        return subprocess.run(
            [sys.executable, str(SCRIPTS / "pin_office_host_artifact.py"),
             "--lock", str(lock_path or self.lock), "--check"],
            capture_output=True, text=True, check=False, timeout=120)

    def write_pin(self, mutate):
        lock = json.loads(TRACKED_LOCK.read_text())
        mutate(lock["qualifiedHostArtifact"])
        self.lock.write_text(json.dumps(lock, indent=2) + "\n")

    def test_missing_claim_reports_source_ahead(self):
        completed = self.run_check()
        self.assertEqual(completed.returncode, 1, completed.stdout + completed.stderr)
        self.assertIn("SOURCE AHEAD OF ARTIFACT", completed.stdout)
        self.assertIn("engine repair", completed.stdout)

    def test_canonical_claim_matches(self):
        self.write_pin(lambda pin_block: pin_block.update(engineRepair=self.claim))
        completed = self.run_check()
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        self.assertIn("matches the current host sources", completed.stdout)

    def test_wrong_claim_values_are_rejected(self):
        def wrong_archive(block):
            block["engineRepair"]["patchedArchiveSHA256"] = "0" * 64

        def wrong_platform(block):
            block["engineRepair"]["platform"] = "IOSSIMULATOR"

        def wrong_member(block):
            block["engineRepair"]["member"]["patchedSHA256"] = "0" * 64

        def wrong_lock(block):
            block["engineRepair"]["lockSHA256"] = "0" * 64

        def extra_field(block):
            block["engineRepair"]["receiptPath"] = "/tmp/absolute/engine-repair.json"

        def missing_field(block):
            block["engineRepair"].pop("upstreamCommit")

        mutations = {
            "patched archive SHA": wrong_archive,
            "platform": wrong_platform,
            "member SHA": wrong_member,
            "lock SHA": wrong_lock,
            "extra field": extra_field,
            "missing field": missing_field,
        }
        for label, mutate in mutations.items():
            with self.subTest(label):
                def apply_mutation(block, _mutate=mutate):
                    block.update(engineRepair=copy.deepcopy(self.claim))
                    _mutate(block)
                self.write_pin(apply_mutation)
                completed = self.run_check()
                self.assertEqual(completed.returncode, 2, completed.stdout)
                self.assertIn("REJECTED engine repair claim", completed.stdout)

    def test_check_is_read_only(self):
        self.write_pin(lambda block: block.update(engineRepair=self.claim))
        before = self.lock.stat().st_mtime_ns, self.lock.read_bytes()
        self.run_check()
        after = self.lock.stat().st_mtime_ns, self.lock.read_bytes()
        self.assertEqual(before, after)

    def test_provenance_failures_are_strict(self):
        self.assertEqual(pin.engine_repair_provenance_failures(
            {"engineRepair": self.claim}, self.claim), [])
        extra = dict(self.claim, receiptPath="/tmp/x")
        failures = pin.engine_repair_provenance_failures(
            {"engineRepair": extra}, self.claim)
        self.assertTrue(any("unexpected fields" in failure for failure in failures))
        missing = {key: value for key, value in self.claim.items()
                   if key != "member"}
        failures = pin.engine_repair_provenance_failures(
            {"engineRepair": missing}, self.claim)
        self.assertTrue(any("omits member" in failure for failure in failures))
        wrong = copy.deepcopy(self.claim)
        wrong["member"]["patchedSHA256"] = "0" * 64
        failures = pin.engine_repair_provenance_failures(
            {"engineRepair": wrong}, self.claim)
        self.assertTrue(any("member" in failure for failure in failures))


if __name__ == "__main__":
    unittest.main()
