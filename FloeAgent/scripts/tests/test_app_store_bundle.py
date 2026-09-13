import hashlib
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_app_store_bundle import normalize, arm64_slice


def thin(subtype=0):
    return struct.pack("<8I", 0xFEEDFACF, 0x100000C, subtype, 6, 0, 0, 0, 0)


class AppStoreBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Fixture.app"
        self.app.mkdir()
        (self.app / "Fixture").write_bytes(thin())
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Fixture", "MinimumOSVersion": "26.0"}))

    def run_policy(self, **kwargs):
        return normalize(self.app, self.root / "report.json", **kwargs)

    def test_valid_bundle_and_repeat_are_unchanged(self):
        before = (self.app / "Fixture").read_bytes()
        for _ in range(2):
            self.assertEqual(self.run_policy()["removed_non_ios_addons"], [])
        self.assertEqual((self.app / "Fixture").read_bytes(), before)

    def test_reviewed_addon_removed_and_executable_retained(self):
        addon = self.app / "addon.node"
        addon.write_bytes(thin())
        expected = {"addon.node": hashlib.sha256(addon.read_bytes()).hexdigest()}
        self.assertEqual(self.run_policy(addon_hashes=expected)["removed_non_ios_addons"], ["addon.node"])
        self.assertFalse(addon.exists())
        self.assertEqual((self.app / "Fixture").read_bytes(), thin())

    def test_changed_addon_is_not_deleted(self):
        addon = self.app / "addon.node"
        addon.write_bytes(thin())
        with self.assertRaisesRegex(ValueError, "Unreviewed addon"):
            self.run_policy(addon_hashes={"addon.node": "0" * 64})
        self.assertTrue(addon.exists())

    def test_unknown_native_resource_blocks_all_changes(self):
        (self.app / "reviewed.node").write_bytes(thin())
        (self.app / "unknown.node").write_bytes(thin())
        with self.assertRaisesRegex(ValueError, "Standalone native binary"):
            self.run_policy(addon_hashes={"reviewed.node": hashlib.sha256(thin()).hexdigest()})
        self.assertTrue((self.app / "reviewed.node").exists())

    def test_unknown_invalid_minimum_fails(self):
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Fixture", "MinimumOSVersion": "ios_version_min"}))
        with self.assertRaisesRegex(ValueError, "Invalid MinimumOSVersion"):
            self.run_policy()

    def test_foreign_script_template_remains_data(self):
        template = self.app / "script-template.exe"
        template.write_bytes(b"MZsupplier-template")
        self.run_policy()
        self.assertEqual(template.read_bytes(), b"MZsupplier-template")

    def test_executable_cannot_escape_bundle(self):
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "../Fixture", "MinimumOSVersion": "26.0"}))
        with self.assertRaisesRegex(ValueError, "Invalid bundle executable"):
            self.run_policy()

    def test_fat_slice_preserves_generic_arm64_exactly(self):
        a, e = thin(), thin(2)
        header = struct.pack(">II", 0xCAFEBABE, 2)
        header += struct.pack(">5I", 0x100000C, 0, 64, len(a), 0)
        header += struct.pack(">5I", 0x100000C, 2, 96, len(e), 0)
        fat = header.ljust(64, b"\0") + a + e
        self.assertEqual(arm64_slice(fat), a)
        self.assertEqual(arm64_slice(a), a)

    def test_bad_fat_bounds_and_arm64e_only_fail(self):
        with self.assertRaises(ValueError):
            arm64_slice(thin(2))
        bad = struct.pack(">II5I", 0xCAFEBABE, 1, 0x100000C, 0, 1000, 32, 0)
        with self.assertRaisesRegex(ValueError, "bounds"):
            arm64_slice(bad)


if __name__ == "__main__":
    unittest.main()
