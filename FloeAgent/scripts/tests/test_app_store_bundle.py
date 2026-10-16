import hashlib
import json
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_app_store_bundle import (PRIVACY_MANIFEST_ROOT, normalize, arm64_slice)


def thin(subtype=0):
    return struct.pack("<8I", 0xFEEDFACF, 0x100000C, subtype, 6, 1, 24, 0, 0) + struct.pack("<6I", 0x32, 24, 2, 26 << 16, (26 << 16) | (5 << 8), 0)


def thin_with_symbols(undefined=(), exports=(), subtype=0):
    """A minimal arm64 Mach-O with a symbol table, so required-reason detection
    can be exercised without a real toolchain build."""
    symbols = [(name, 0x01, 0, 0) for name in undefined] + [(name, 0x0F, 1, 0) for name in exports]
    string_table = b"\0"
    entries = []
    for name, n_type, n_sect, n_value in symbols:
        entries.append(struct.pack("<IBBHQ", len(string_table), n_type, n_sect, 0, n_value))
        string_table += name.encode() + b"\0"
    header_size = 32 + 24 + 24
    symoff = header_size
    stroff = symoff + sum(len(entry) for entry in entries)
    header = struct.pack("<8I", 0xFEEDFACF, 0x100000C, subtype, 6, 2, 48, 0, 0)
    build = struct.pack("<6I", 0x32, 24, 2, 26 << 16, (26 << 16) | (5 << 8), 0)
    symtab = struct.pack("<6I", 0x2, 24, symoff, len(entries), stroff, len(string_table))
    return header + build + symtab + b"".join(entries) + string_table


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

    def add_framework(self, name, binary, executable=None, identifier=None, minimum="26.0"):
        root = self.app / "Frameworks" / f"{name}.framework"
        root.mkdir(parents=True)
        executable = executable or name
        (root / executable).write_bytes(binary)
        (root / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": identifier or f"dev.floe.{name}",
            "CFBundleShortVersionString": "1.0",
            "MinimumOSVersion": minimum,
        }))
        return root

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

    def test_numeric_minimum_cannot_understate_binary(self):
        p = self.app / "Info.plist"
        p.write_bytes(plistlib.dumps({"CFBundleExecutable": "Fixture", "MinimumOSVersion": "14.0"}))
        with self.assertRaisesRegex(ValueError, "understates"):
            self.run_policy()

    def test_dash_metadata_uses_actual_binary_and_keeps_code(self):
        root = self.app / "Frameworks/dash.framework"
        root.mkdir(parents=True)
        (root / "dash").write_bytes(thin())
        (root / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "dash", "MinimumOSVersion": "14.0",
            "CFBundleIdentifier": "dev.floe.dash", "CFBundleShortVersionString": "1.0", "DTSDKName": "iphoneos14.0", "DTXcode": "1010"}))
        for _ in range(2):
            self.run_policy()
            info = plistlib.loads((root / "Info.plist").read_bytes())
            self.assertEqual(info["MinimumOSVersion"], "26.0")
            self.assertEqual(info["DTSDKName"], "iphoneos26.5")
            self.assertNotIn("DTXcode", info)
            self.assertEqual((root / "dash").read_bytes(), thin())

    def test_fat_slice_preserves_generic_arm64_exactly(self):
        a, e = thin(), thin(2)
        header = struct.pack(">II", 0xCAFEBABE, 2)
        header += struct.pack(">5I", 0x100000C, 0, 64, len(a), 0)
        header += struct.pack(">5I", 0x100000C, 2, 128, len(e), 0)
        fat = (header.ljust(64, b"\0") + a).ljust(128, b"\0") + e
        self.assertEqual(arm64_slice(fat), a)
        self.assertEqual(arm64_slice(a), a)

    def test_bad_fat_bounds_and_arm64e_only_fail(self):
        with self.assertRaises(ValueError):
            arm64_slice(thin(2))
        bad = struct.pack(">II5I", 0xCAFEBABE, 1, 0x100000C, 0, 1000, 32, 0)
        with self.assertRaisesRegex(ValueError, "bounds"):
            arm64_slice(bad)


class PrivacyManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Fixture.app"
        self.app.mkdir()
        (self.app / "Fixture").write_bytes(thin())
        (self.app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Fixture", "MinimumOSVersion": "26.0"}))

    def add_framework(self, name, binary, executable=None, minimum="26.0"):
        root = self.app / "Frameworks" / f"{name}.framework"
        root.mkdir(parents=True)
        executable = executable or name
        (root / executable).write_bytes(binary)
        (root / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": f"dev.floe.{name}",
            "CFBundleShortVersionString": "1.0",
            "MinimumOSVersion": minimum,
        }))
        return root

    def run_policy(self, **kwargs):
        return normalize(self.app, self.root / "report.json", **kwargs)

    def test_unknown_framework_with_api_use_is_rejected(self):
        self.add_framework("mystery", thin_with_symbols(undefined=["_stat"]))
        with self.assertRaisesRegex(ValueError, "Unreviewed embedded framework mystery.framework"):
            self.run_policy()

    def test_reviewed_clean_framework_with_api_use_is_rejected(self):
        self.add_framework("awk", thin_with_symbols(undefined=["_fstat"]))
        with self.assertRaisesRegex(ValueError, "reviewed as clean but now uses"):
            self.run_policy()

    def test_controlled_manifest_is_injected_without_touching_binary(self):
        root = self.add_framework("CPDFium", thin())
        binary_before = (root / "CPDFium").read_bytes()
        report = self.run_policy()
        injected = root / "PrivacyInfo.xcprivacy"
        expected = (PRIVACY_MANIFEST_ROOT / "CPDFium" / "PrivacyInfo.xcprivacy").read_bytes()
        self.assertEqual(injected.read_bytes(), expected)
        self.assertEqual((root / "CPDFium").read_bytes(), binary_before)
        self.assertEqual(report["privacy_manifests"]["injected"][0]["path"],
                         "Frameworks/CPDFium.framework/PrivacyInfo.xcprivacy")
        self.assertEqual(report["privacy_manifests"]["frameworks"][0]["executable_sha256"],
                         hashlib.sha256(binary_before).hexdigest())

    def test_unpatched_shell_statfs_fails_with_rebuild_pointer(self):
        self.add_framework("shell", thin_with_symbols(undefined=["_stat", "_lstat", "_statfs"]))
        with self.assertRaisesRegex(ValueError, "rebuild_shell_frameworks.py"):
            self.run_policy()

    def test_app_manifest_must_cover_detected_categories(self):
        (self.app / "Fixture").write_bytes(thin_with_symbols(undefined=["_stat"]))
        (self.app / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({
            "NSPrivacyAccessedAPITypes": [{
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                "NSPrivacyAccessedAPITypeReasons": ["CA92.1"],
            }]}))
        with self.assertRaisesRegex(ValueError, "does not declare it"):
            self.run_policy()

    def test_unapproved_reason_is_rejected(self):
        (self.app / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({
            "NSPrivacyAccessedAPITypes": [{
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryDiskSpace",
                "NSPrivacyAccessedAPITypeReasons": ["FAKE.1"],
            }]}))
        with self.assertRaisesRegex(ValueError, "Unapproved reason"):
            self.run_policy()

    def test_key_string_usage_requires_declaration(self):
        # NSFileSystemFreeSize has no unique symbol; only the key string.
        (self.app / "Fixture").write_bytes(thin_with_symbols(
            undefined=["_stat"], exports=["_main"]) + b"NSFileSystemFreeSize")
        (self.app / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({
            "NSPrivacyAccessedAPITypes": [{
                "NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
                "NSPrivacyAccessedAPITypeReasons": ["C617.1"],
            }]}))
        with self.assertRaisesRegex(ValueError, "NSPrivacyAccessedAPICategoryDiskSpace"):
            self.run_policy()
        (self.app / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps({
            "NSPrivacyAccessedAPITypes": [
                {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
                 "NSPrivacyAccessedAPITypeReasons": ["C617.1"]},
                {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryDiskSpace",
                 "NSPrivacyAccessedAPITypeReasons": ["E174.1"]},
            ]}))
        self.run_policy()

    # --- privacy rebuild substitution ------------------------------------

    def make_rebuild_directory(self, shell_binary, text_binary, shell_exports, text_exports,
                               tamper_hash=False, exports_mismatch=False, name="rebuilt"):
        directory = self.root / name
        (directory / "shell.framework").mkdir(parents=True, exist_ok=True)
        (directory / "text.framework").mkdir(parents=True, exist_ok=True)
        targets = {}
        for target, binary, exports in (("shell", shell_binary, shell_exports),
                                        ("text", text_binary, text_exports)):
            rebuilt = thin_with_symbols(
                undefined=["_stat", "_lstat"] if target == "shell" else ["_stat", "_fstat", "_lstat"],
                exports=["_other"] if exports_mismatch else exports)
            path = directory / f"{target}.framework" / target
            path.write_bytes(rebuilt)
            plist = directory / f"{target}.framework" / "Info.plist"
            plist.write_bytes(plistlib.dumps({"CFBundleExecutable": target,
                                              "MinimumOSVersion": "26.0"}))
            targets[target] = {
                "framework": f"{target}.framework",
                "executable": target,
                "executableSHA256": hashlib.sha256(b"tampered" if tamper_hash else rebuilt).hexdigest(),
                "infoPlistSHA256": hashlib.sha256(plist.read_bytes()).hexdigest(),
            }
        (directory / "PROVENANCE.json").write_text(json.dumps({
            "generator": "floe-ios_system-privacy-rebuild-v1", "targets": targets}))
        return directory

    def test_rebuilt_substitution_replaces_only_the_two_binaries(self):
        shell = self.add_framework("shell", thin_with_symbols(
            undefined=["_stat", "_lstat", "_statfs"], exports=["_main", "_helper"]))
        text = self.add_framework("text", thin_with_symbols(
            undefined=["_stat", "_fstat", "_lstat", "_fstatfs"], exports=["_tmain"]))
        with self.assertRaisesRegex(ValueError, "rebuild_shell_frameworks.py"):
            self.run_policy()
        directory = self.make_rebuild_directory(
            shell_binary=(shell / "shell").read_bytes(),
            text_binary=(text / "text").read_bytes(),
            shell_exports=["_main", "_helper"], text_exports=["_tmain"])
        report = self.run_policy(rebuilt_frameworks=directory)
        self.assertEqual((shell / "shell").read_bytes(),
                         (directory / "shell.framework/shell").read_bytes())
        self.assertEqual((text / "text").read_bytes(),
                         (directory / "text.framework/text").read_bytes())
        self.assertEqual(len(report["rebuilt_privacy_frameworks"]), 2)
        self.assertTrue((shell / "PrivacyInfo.xcprivacy").exists())
        self.assertTrue((text / "PrivacyInfo.xcprivacy").exists())

    def test_rebuilt_substitution_rejects_hash_and_abi_mismatch(self):
        self.add_framework("shell", thin_with_symbols(
            undefined=["_stat", "_statfs"], exports=["_main", "_helper"]))
        self.add_framework("text", thin_with_symbols(
            undefined=["_stat", "_fstatfs"], exports=["_tmain"]))
        tampered = self.make_rebuild_directory(
            (self.app / "Frameworks/shell.framework/shell").read_bytes(),
            (self.app / "Frameworks/text.framework/text").read_bytes(),
            ["_main", "_helper"], ["_tmain"], tamper_hash=True, name="tampered")
        with self.assertRaisesRegex(ValueError, "does not match its provenance"):
            self.run_policy(rebuilt_frameworks=tampered)
        abi = self.make_rebuild_directory(
            (self.app / "Frameworks/shell.framework/shell").read_bytes(),
            (self.app / "Frameworks/text.framework/text").read_bytes(),
            ["_main", "_helper"], ["_tmain"], exports_mismatch=True, name="abi")
        with self.assertRaisesRegex(ValueError, "not ABI-compatible"):
            self.run_policy(rebuilt_frameworks=abi)


if __name__ == "__main__":
    unittest.main()
