"""Offline CLI contract tests; all inputs are synthetic temporary plists."""

import base64
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check_ota_lineage.py"
KEY = base64.b64encode(bytes(range(32))).decode("ascii")
OTHER_KEY = base64.b64encode(bytes(range(1, 33))).decode("ascii")
URL = "https://updates.example.invalid/appcast.xml"


def valid_info(build):
    return {
        "CFBundleIdentifier": "org.floeagent.macbridge",
        "CFBundleVersion": build,
        "SUPublicEDKey": KEY,
        "SUFeedURL": URL,
    }


class OTALineageTests(unittest.TestCase):
    def run_check(self, old, new):
        with tempfile.TemporaryDirectory() as directory:
            old_path = Path(directory) / "old.plist"
            new_path = Path(directory) / "new.plist"
            old_path.write_bytes(plistlib.dumps(old))
            new_path.write_bytes(plistlib.dumps(new))
            return subprocess.run([sys.executable, str(SCRIPT), str(old_path), str(new_path)],
                                  capture_output=True, text=True, check=False)

    def test_bridge_build_8_to_9_succeeds_with_explicit_limits(self):
        result = self.run_check(valid_info("8"), valid_info("9"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("metadata compatible", result.stdout)
        self.assertIn("Not verified", result.stdout)

    def test_dotted_numeric_versions_compare_numerically(self):
        self.assertEqual(self.run_check(valid_info("8.9"), valid_info("8.10")).returncode, 0)
        self.assertNotEqual(self.run_check(valid_info("8"), valid_info("8.0.0")).returncode, 0)

    def test_invalid_bundle_identifier_fails_on_either_side(self):
        for side in ("old", "new"):
            for value in (None, "org.floeagent.mac", "$(PRODUCT_BUNDLE_IDENTIFIER)"):
                with self.subTest(side=side, value=value):
                    old, new = valid_info("8"), valid_info("9")
                    info = old if side == "old" else new
                    if value is None:
                        del info["CFBundleIdentifier"]
                    else:
                        info["CFBundleIdentifier"] = value
                    result = self.run_check(old, new)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("CFBundleIdentifier", result.stderr)

    def test_invalid_missing_or_nonincreasing_version_fails(self):
        for build in ("8", "7", "9-beta", "9.0.0.1", "$(CURRENT_PROJECT_VERSION)", "9" * 19, "", 9):
            with self.subTest(build=build):
                new = valid_info(build)
                result = self.run_check(valid_info("8"), new)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("CFBundleVersion", result.stderr)
        old = valid_info("8")
        del old["CFBundleVersion"]
        self.assertNotEqual(self.run_check(old, valid_info("9")).returncode, 0)

    def test_missing_invalid_or_changed_public_key_fails(self):
        for side, value in (("old", None), ("new", None), ("new", "not-base64!"),
                            ("new", base64.b64encode(b"short").decode()),
                            ("new", OTHER_KEY), ("new", "$(SPARKLE_KEY)")):
            with self.subTest(side=side, value=value):
                old, new = valid_info("8"), valid_info("9")
                info = old if side == "old" else new
                if value is None:
                    del info["SUPublicEDKey"]
                else:
                    info["SUPublicEDKey"] = value
                result = self.run_check(old, new)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("SUPublicEDKey", result.stderr)

    def test_missing_invalid_or_changed_feed_fails(self):
        for side, value in (("old", None), ("new", None), ("new", "http://example.invalid/feed"),
                            ("new", "https://user:pass@example.invalid/feed"),
                            ("new", "https://example.invalid/feed#fragment"),
                            ("new", "https://example.invalid:99999/feed"),
                            ("new", "https://other.example.invalid/feed"),
                            ("new", "$(FEED_URL)")):
            with self.subTest(side=side, value=value):
                old, new = valid_info("8"), valid_info("9")
                info = old if side == "old" else new
                if value is None:
                    del info["SUFeedURL"]
                else:
                    info["SUFeedURL"] = value
                result = self.run_check(old, new)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("SUFeedURL", result.stderr)

    def test_unreadable_and_malformed_plists_fail_cleanly(self):
        with tempfile.TemporaryDirectory() as directory:
            invalid = Path(directory) / "invalid.plist"
            missing = Path(directory) / "missing.plist"
            for content in ("not a plist", "<?xml version='1.0'?><plist><dict>"):
                with self.subTest(content=content):
                    invalid.write_text(content, encoding="utf-8")
                    result = subprocess.run([sys.executable, str(SCRIPT), str(invalid), str(missing)],
                                            capture_output=True, text=True, check=False)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("cannot read Info.plist", result.stderr)
                    self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
