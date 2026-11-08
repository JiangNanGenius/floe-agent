#!/usr/bin/env python3
"""Contract checks; tiny hand-authored Mach-O fixtures are never executed."""

import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

import normalize_simulator_runpaths as subject


MUTABLE = "/owned/Build/Products/Debug-iphonesimulator/PackageFrameworks"
CODE = bytes.fromhex("c0035fd6")  # ARM64 ret; this fixture is never launched.


def string_command(command, value, fixed=12):
    data = value.encode() + b"\0"
    size = (fixed + len(data) + 7) & ~7
    return struct.pack("<III", command, size, fixed) + bytes(fixed - 12) + data + bytes(size - fixed - len(data))


def macho(path, *, platform=7, filetype=2, rpaths=(), dependencies=(), install_name=None):
    commands = [struct.pack("<IIIIII", 0x32, 24, platform, 0x1A0000, 0x1B0200, 0),
                struct.pack("<II16s", 0x1B, 24, bytes(range(16)))]
    # Headers are padded so install_name_tool/codesign can change load commands.
    commands.append(struct.pack("<II16sQQQQIIII", 0x19, 152, b"__TEXT", 0x100000000, 0x1000,
                                0, 0x1000, 7, 5, 1, 0)
                    + struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", 0x100000800,
                                  len(CODE), 0x800, 2, 0, 0, 0x80000400, 0, 0, 0))
    commands.append(struct.pack("<II16sQQQQIIII", 0x19, 72, b"__LINKEDIT", 0x100001000, 0x1000,
                                0x1000, 0x1000, 7, 1, 0, 0))
    if filetype == 2:
        commands.append(struct.pack("<IIQQ", 0x80000028, 24, 0x800, 0))
        commands.append(string_command(0xE, "/usr/lib/dyld"))
    if install_name:
        commands.append(string_command(0xD, install_name, 24))
    commands.extend(string_command(subject.LC_RPATH, value) for value in rpaths)
    commands.extend(string_command(0xC, value, 24) for value in dependencies)
    table = b"".join(commands)
    header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, filetype,
                         len(commands), len(table), 0x200004, 0)
    result = bytearray(8192)
    result[:len(header + table)] = header + table
    result[0x800:0x800 + len(CODE)] = CODE
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(result)
    path.chmod(0o755)


def bundle(root, *, dependency=True):
    app = root / "Fixture.app"
    app.mkdir()
    info = {"CFBundleExecutable": "Fixture", "CFBundleIdentifier": "org.floeagent.runpath-fixture",
            "CFBundlePackageType": "APPL", "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
            "DTPlatformName": "iphonesimulator"}
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    reference = "@rpath/Owned.framework/Owned"
    macho(app / "Fixture", rpaths=["@loader_path", MUTABLE, "@executable_path/Frameworks"],
          dependencies=[reference] if dependency else [])
    if dependency:
        framework = app / "Frameworks/Owned.framework"
        macho(framework / "Owned", filetype=6, rpaths=["@loader_path", MUTABLE], install_name=reference,
              dependencies=["/System/Library/Frameworks/WebKit.framework/WebKit"])
        (framework / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Owned",
                                                             "CFBundleIdentifier": "org.floeagent.owned",
                                                             "CFBundlePackageType": "FMWK"}))
    return app


def tree_hashes(app):
    return {str(path.relative_to(app)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in app.rglob("*") if path.is_file()}


class RunpathContractTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="floe-runpath-contract-")
        self.root = Path(self.temporary.name).resolve()
        self.app = bundle(self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def check(self):
        return subject.normalize(self.app, self.root, check=True, seal_bundle=True)

    def test_complete_bundle_resolves_owned_framework_and_check_does_not_write(self):
        before = tree_hashes(self.app)
        report = self.check()
        self.assertEqual(report["imageCount"], 2)
        self.assertEqual(len(report["wouldChange"]), 2)
        targets = [entry["target"] for entry in report["dependencies"] if not entry["system"]]
        self.assertEqual(targets, ["Frameworks/Owned.framework/Owned"])
        self.assertEqual(report["imagesBefore"]["Fixture"][0]["codeSections"][0]["sha256"], hashlib.sha256(CODE).hexdigest())
        self.assertEqual(tree_hashes(self.app), before)

    def test_missing_dependency_refuses_before_any_mutation(self):
        shutil.rmtree(self.app / "Frameworks")
        before = tree_hashes(self.app)
        with self.assertRaisesRegex(subject.InvalidBundle, "Unresolved bundled dependency"):
            subject.normalize(self.app, self.root, seal_bundle=True)
        self.assertEqual(tree_hashes(self.app), before)

    def test_iphoneos_metadata_cannot_opt_in(self):
        info = plistlib.loads((self.app / "Info.plist").read_bytes())
        info["DTPlatformName"] = "iphoneos"
        (self.app / "Info.plist").write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(subject.InvalidBundle, "not an identified iOS Simulator"):
            self.check()

    def test_device_image_hidden_in_simulator_bundle_refuses(self):
        macho(self.app / "Frameworks/Owned.framework/Owned", platform=2, filetype=6)
        with self.assertRaisesRegex(subject.InvalidBundle, "Only iOS Simulator"):
            self.check()

    def test_hardlinked_image_refuses_without_touching_shared_source(self):
        shared = self.root / "shared-MachO"
        os.link(self.app / "Fixture", shared)
        original = shared.read_bytes()
        with self.assertRaisesRegex(subject.InvalidBundle, "Hardlinked file"):
            self.check()
        self.assertEqual(shared.read_bytes(), original)

    def test_outside_symlink_refuses(self):
        (self.root / "outside").write_text("protected")
        (self.app / "escape").symlink_to("../outside")
        with self.assertRaisesRegex(subject.InvalidBundle, "Escaping or dangling symlink"):
            self.check()

    def test_internal_resource_symlink_is_allowed(self):
        (self.app / "resource").write_text("owned")
        (self.app / "alias").symlink_to("resource")
        self.assertEqual(self.check()["imageCount"], 2)

    def test_app_alias_and_unbounded_owner_root_refuse(self):
        alias = self.root / "Alias.app"
        alias.symlink_to(self.app)
        for app, owner in [(alias, self.root), (self.app, Path("/")), (self.app, self.app)]:
            with self.assertRaisesRegex(subject.InvalidBundle, "explicit, non-aliased owner root"):
                subject.normalize(app, owner, check=True)

    def test_unexpected_mutable_absolute_runpath_refuses(self):
        macho(self.app / "Fixture", rpaths=["/another/mutable/Frameworks"])
        with self.assertRaisesRegex(subject.InvalidBundle, "Non-system absolute runpath"):
            self.check()

    def test_relative_runpath_cannot_escape_bundle(self):
        macho(self.app / "Fixture", rpaths=["@loader_path/../../"])
        with self.assertRaisesRegex(subject.InvalidBundle, "Relative runpath escapes bundle"):
            self.check()

    def test_absolute_dependency_cannot_read_host_file(self):
        macho(self.app / "Fixture", dependencies=["/tmp/unowned.dylib"])
        with self.assertRaisesRegex(subject.InvalidBundle, "Dependency escapes bundle"):
            self.check()

    def test_test_runtime_is_never_a_main_app_fallback(self):
        macho(self.app / "Fixture", dependencies=["@rpath/XCTest.framework/XCTest"])
        with self.assertRaisesRegex(subject.InvalidBundle, "Unresolved bundled dependency"):
            self.check()

    @unittest.skipUnless(sys.platform == "darwin", "Xcode Simulator test runtime required")
    def test_only_actual_xctest_root_may_require_official_test_runtime(self):
        test = self.app / "PlugIns/Tests.xctest"
        macho(test / "Tests", filetype=8, dependencies=list(subject.TEST_RUNTIME))
        (test / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Tests"}))
        entries = [entry for entry in self.check()["dependencies"] if entry.get("requiresXcodeTestRuntime")]
        self.assertEqual({entry["name"] for entry in entries}, set(subject.TEST_RUNTIME))
        for entry in entries:
            self.assertEqual(entry["officialRuntime"]["image"]["platforms"], [7])
            self.assertEqual(entry["officialRuntime"]["image"]["cpu"], 0x100000C)
            self.assertIn("iPhoneSimulator.platform", entry["officialRuntime"]["path"])

    def test_truncated_macho_refuses(self):
        (self.app / "Fixture").write_bytes(b"\xcf\xfa\xed\xfe" + bytes(3))
        with self.assertRaisesRegex(subject.InvalidBundle, "Truncated Mach-O"):
            self.check()

    @unittest.skipUnless(sys.platform == "darwin" and Path("/usr/bin/codesign").exists(), "Apple Mach-O tools required")
    def test_native_edit_seal_metadata_idempotence_and_late_resource_reseal(self):
        # Establish explicit metadata before editing; the signature may be
        # discarded by install_name_tool. No fixture is launched or installed.
        entitlements = self.root / "fixture-entitlements.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
        for target, identifier in [(self.app / "Frameworks/Owned.framework", "retained.framework"),
                                   (self.app, "retained.app")]:
            command = ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
                       "--identifier", identifier, "--options", "0x20000"]
            if target == self.app:
                command += ["--entitlements", str(entitlements)]
            subprocess.run(command + [str(target)], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        first = subject.normalize(self.app, self.root, seal_bundle=True)
        self.assertEqual(len(first["changedImages"]), 2)
        self.assertTrue(first["strictBundleSignatureVerified"])
        self.assertTrue(first["codeSectionsUnchanged"])
        for action in first["signatureActions"]:
            self.assertEqual(action["before"]["identifier"], action["after"]["identifier"])
            self.assertEqual(action["before"]["entitlements"], action["after"]["entitlements"])
            self.assertEqual(action["before"]["flags"] & ~subject.SIGNATURE_ORIGIN_FLAGS,
                             action["after"]["flags"] & ~subject.SIGNATURE_ORIGIN_FLAGS)
            self.assertEqual(action["after"]["flags"], 0x2)
            if action["target"] == ".":
                self.assertTrue(action["after"]["entitlements"]["com.apple.security.get-task-allow"])
        before_second = tree_hashes(self.app)
        second = subject.normalize(self.app, self.root, seal_bundle=True)
        self.assertEqual(second["changedImages"], [])
        self.assertEqual(second["signedTargets"], [])
        self.assertEqual(tree_hashes(self.app), before_second)
        # Simulates a later build-for-testing copy after the main target hook.
        (self.app / "late-test-resource.txt").write_text("arrived after main target")
        self.assertFalse(subject._signature_valid(self.app, deep=True))
        third = subject.normalize(self.app, self.root, seal_bundle=True)
        self.assertEqual(third["changedImages"], [])
        self.assertEqual(third["signedTargets"], ["."])
        self.assertTrue(subject._signature_valid(self.app, deep=True))


if __name__ == "__main__":
    unittest.main()
