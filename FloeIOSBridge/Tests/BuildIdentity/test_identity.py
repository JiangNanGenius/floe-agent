#!/usr/bin/env python3
"""Check installed bundle identity resolution without installing an app."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


class InstalledIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.project = Path(__file__).resolve().parents[2]
        scratch = Path(os.environ["FLOE_BRIDGE_IDENTITY_SCRATCH"])
        scratch.mkdir(parents=True, exist_ok=True)
        cls.temporary = tempfile.TemporaryDirectory(prefix="identity-", dir=scratch)
        cls.work = Path(cls.temporary.name)
        main = cls.work / "main.swift"
        main.write_text('''import Foundation
let identity = ["host": BridgeBuild.hostBundleIdentifier,
                "tunnel": BridgeBuild.tunnelBundleIdentifier,
                "core": BridgeBuild.coreBundleIdentifier]
print(String(data: try JSONSerialization.data(withJSONObject: identity), encoding: .utf8)!)
''')
        cls.binary = cls.work / "identity-probe"
        subprocess.run([
            "xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "6",
            str(cls.project / "Sources/BridgeCore/BridgeBuild.swift"), str(main),
            "-o", str(cls.binary),
        ], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def check_bundle(self, extension, bundle_identifier, expected_host):
        bundle = self.work / (bundle_identifier + "." + extension)
        executable = bundle / "Contents/MacOS/identity-probe"
        executable.parent.mkdir(parents=True)
        shutil.copy2(self.binary, executable)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_identifier,
            "CFBundleExecutable": "identity-probe",
            "CFBundlePackageType": "APPL" if extension == "app" else "XPC!",
        }))
        result = json.loads(subprocess.check_output([str(executable)], text=True))
        self.assertEqual(result, {
            "host": expected_host,
            "tunnel": expected_host + ".tunnel",
            "core": expected_host + ".core",
        })

    def test_original_host_upgrade(self):
        self.check_bundle("app", "org.floeagent.iosbridge", "org.floeagent.iosbridge")

    def test_original_extension_upgrade(self):
        self.check_bundle("appex", "org.floeagent.iosbridge.tunnel", "org.floeagent.iosbridge")

    def test_resigned_host(self):
        self.check_bundle("app", "dev.example.personalbridge", "dev.example.personalbridge")

    def test_resigned_extension(self):
        self.check_bundle("appex", "dev.example.personalbridge.tunnel", "dev.example.personalbridge")


if __name__ == "__main__":
    unittest.main(verbosity=2)
