#!/usr/bin/env python3
"""Negative/tamper tests for scripts/verify_step_independent.py.

The verifier is a restricted fixture geometry checker: it must PASS the real
plate/hole export and FAIL when the file's unit, topology class or analytic
cylinder is tampered with. These tests run it as a subprocess against mutated
copies, so the exit status and the reported failure are both asserted.

Run:
    python3 scripts/test_verify_step_independent.py

The real fixture is located through FLOE_STEP_FIXTURE or the simulator's
Documents evidence directory; when it is absent the pass-through tests are
reported as SKIPPED (never silently passed).
"""

from __future__ import annotations

import glob
import math
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "verify_step_independent.py"
EXPECTED_VOLUME = 60000.0 - 250.0 * math.pi
EXPECTED_THICKNESS = 10.0


def find_fixture() -> str | None:
    env = os.environ.get("FLOE_STEP_FIXTURE")
    if env and Path(env).is_file():
        return env
    patterns = [
        str(Path.home() / "Library/Developer/CoreSimulator/Devices/*/data/Documents/"
            "floe-cad-evidence/plate-10mm.step"),
        str(Path.home() / "Library/Developer/CoreSimulator/Devices/*/data/tmp/"
            "floe-cad-evidence/plate-10mm.step"),
    ]
    for pattern in patterns:
        hits = glob.glob(pattern)
        if hits:
            return hits[0]
    return None


def run_verifier(path: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), path,
         "--expect-thickness", str(EXPECTED_THICKNESS),
         "--expect-volume", repr(EXPECTED_VOLUME)],
        capture_output=True, text=True)


class VerifyStepIndependentTests(unittest.TestCase):

    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture = find_fixture()

    def _copy_fixture(self, tmp: str) -> str | None:
        if not self.fixture:
            return None
        target = Path(tmp) / "plate.step"
        target.write_text(Path(self.fixture).read_text(encoding="utf-8", errors="replace"))
        return str(target)

    # --- decimal handling -------------------------------------------------

    def test_decimal_forms_keep_their_value(self) -> None:
        sys.path.insert(0, str(SCRIPT.parent))
        import verify_step_independent as verifier

        self.assertEqual(verifier.num(".5"), 0.5)
        self.assertEqual(verifier.num("1."), 1.0)
        self.assertEqual(verifier.num("1.5E-7"), 1.5e-7)
        self.assertEqual(verifier.num("2.5D-3"), 2.5e-3)
        self.assertEqual(verifier.num("-2.25"), -2.25)
        with self.assertRaises(ValueError):
            verifier.num("INF")

    # --- negative: a missing fixture is a skip, not a pass ----------------

    def test_unmodified_fixture_passes(self) -> None:
        if not self.fixture:
            self.skipTest("no exported STEP fixture found; run the FloeCAD fixture test first")
        result = run_verifier(self.fixture)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("analytic volume", result.stdout)

    def test_centimetre_unit_tamper_fails(self) -> None:
        if not self.fixture:
            self.skipTest("no exported STEP fixture found")
        with tempfile.TemporaryDirectory() as tmp:
            path = self._copy_fixture(tmp)
            text = Path(path).read_text()
            self.assertIn(".MILLI.", text, "fixture must declare millimetres to tamper with")
            Path(path).write_text(text.replace(".MILLI.", ".CENTI."))
            result = run_verifier(path)
            self.assertNotEqual(result.returncode, 0, "centimetre units must fail the mm check")
            self.assertIn("units", result.stdout)

    def test_cylinder_radius_tamper_fails(self) -> None:
        if not self.fixture:
            self.skipTest("no exported STEP fixture found")
        with tempfile.TemporaryDirectory() as tmp:
            path = self._copy_fixture(tmp)
            text = Path(path).read_text()
            mutated, count = re.subn(r"(CYLINDRICAL_SURFACE\('',#\d+,)5\.(\))",
                                     r"\g<1>7.\g<2>", text)
            self.assertEqual(count, 1, "fixture must carry exactly one analytic cylinder")
            Path(path).write_text(mutated)
            result = run_verifier(path)
            self.assertNotEqual(result.returncode, 0, "a 14 mm hole must fail the Ø10 check")
            self.assertIn("hole diameter", result.stdout)

    def test_missing_solid_tamper_fails(self) -> None:
        if not self.fixture:
            self.skipTest("no exported STEP fixture found")
        with tempfile.TemporaryDirectory() as tmp:
            path = self._copy_fixture(tmp)
            text = Path(path).read_text()
            mutated, count = re.subn(r"MANIFOLD_SOLID_BREP\('',#\d+\);", "", text)
            self.assertEqual(count, 1)
            Path(path).write_text(mutated)
            result = run_verifier(path)
            self.assertNotEqual(result.returncode, 0, "zero solids must fail the topology check")
            self.assertIn("solid count", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
