import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("prepare_usb_driver", Path(__file__).with_name("prepare_usb_driver.py"))
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)

# This is a synthetic metadata fixture, not a descriptor read, authorization or
# compatibility result for a physical CP210x device.
EXACT_FIXTURE = {"idVendor": 0x10C4, "idProduct": 0xEA60, "bConfigurationValue": 1,
    "bInterfaceNumber": 0, "bInterfaceClass": 255, "bInterfaceSubClass": 0, "bInterfaceProtocol": 0}


class USBDriverPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="floe-usb-package-")
        self.root = Path(self.temp.name)
        self.app = self.root / "AppSource"
        self.app.mkdir()
        (self.app / "Host.entitlements").write_bytes(plistlib.dumps({"existing.document.scope": ["keep"]}))
        self.app_spec = {"targets": {"FloeAgent": {
            "settings": {"base": {"DEVELOPMENT_TEAM": "AAAAAAAAAA", "PRODUCT_BUNDLE_IDENTIFIER": "org.floeagent.ios"}},
            "entitlements": {"path": "Host.entitlements"},
        }}}

    def tearDown(self):
        self.temp.cleanup()

    def manifest(self, matches):
        path = self.root / "matches.json"
        path.write_text(json.dumps({"schemaVersion": 1, "matches": matches}))
        return path

    def test_empty_review_does_not_emit_app_overlay_or_wildcard(self):
        output = self.root / "review"
        packaging.prepare(self.app, output, packaging.read_matches(self.manifest([])), self.app_spec)
        self.assertFalse((output / "app-overlay.json").exists())
        info = plistlib.loads((output / "Driver-Info.plist").read_bytes())
        self.assertEqual(info["IOKitPersonalities"], {})
        entitlements = plistlib.loads((output / "Driver.entitlements").read_bytes())
        self.assertEqual(entitlements["com.apple.developer.driverkit.transport.usb"], [])
        self.assertNotIn("com.apple.developer.driverkit.allow-third-party-userclients", entitlements)
        plan = json.loads((output / "packaging-plan.json").read_text())
        for key in ["entitlementGrantVerified", "profileVerified", "compiled", "installed", "hardwareVerified", "appOverlayProduced"]:
            self.assertIs(plan[key], False)

    def test_exact_fixture_has_same_team_driver_class_and_existing_host_entitlements(self):
        output = self.root / "explicit-review"
        source = (self.app / "Host.entitlements").read_bytes()
        matches = packaging.read_matches(self.manifest([EXACT_FIXTURE]))
        packaging.prepare(self.app, output, matches, self.app_spec)
        info = plistlib.loads((output / "Driver-Info.plist").read_bytes())
        personality = next(iter(info["IOKitPersonalities"].values()))
        self.assertEqual({key: personality[key] for key in packaging.MATCH_FIELDS}, EXACT_FIXTURE)
        self.assertEqual(personality["IOUserServerName"], packaging.DRIVER_ID)
        self.assertEqual(personality["FloeUSBUserClientProperties"], {"IOClass": "IOUserUserClient", "IOUserClass": packaging.USER_CLIENT})
        driver = plistlib.loads((output / "Driver.entitlements").read_bytes())
        self.assertEqual(driver, {"com.apple.developer.driverkit": True, "com.apple.developer.driverkit.transport.usb": matches})
        host = plistlib.loads((output / "Host.entitlements").read_bytes())
        self.assertEqual(host["existing.document.scope"], ["keep"])
        self.assertIs(host["com.apple.developer.driverkit.communicates-with-drivers"], True)
        self.assertEqual((self.app / "Host.entitlements").read_bytes(), source)
        overlay = json.loads((output / "app-overlay.json").read_text())
        target = overlay["targets"][packaging.SERVICE]
        self.assertEqual(target["settings"]["base"]["DEVELOPMENT_TEAM"], "AAAAAAAAAA")
        self.assertEqual(target["settings"]["base"]["SDKROOT"], "driverkit")
        self.assertEqual(target["settings"]["base"]["SUPPORTED_PLATFORMS"], "driverkit")
        names = {Path(row["path"]).name for row in target["sources"]}
        self.assertTrue({"FloeUSBSerialDriver.iig", "FloeUSBSerialUserClient.iig", "FloeUSBSerialDriver.cpp", "USBSerialBackend.cpp", "FloeUSBWire.c"}.issubset(names))
        host_deps = overlay["targets"]["FloeAgent"]["dependencies"]
        self.assertEqual(host_deps[0], {"package": "FloeToolbox", "product": "FloeToolboxUSB"})
        self.assertEqual(host_deps[1]["copy"], {"destination": "productsDirectory", "subpath": "$(SYSTEM_EXTENSIONS_FOLDER_PATH)"})
        self.assertFalse(host_deps[1]["link"])
        self.assertTrue(host_deps[1]["codeSign"])

    def test_unknown_pairs_missing_interfaces_wildcards_booleans_duplicates_and_limits_fail(self):
        invalid = []
        for key, value in [("idVendor", "*"), ("idVendor", True), ("idVendor", 0xFFFF),
                           ("idProduct", 0xFFFF), ("bConfigurationValue", 0), ("bInterfaceNumber", 256),
                           ("bInterfaceClass", 255.5)]:
            row = dict(EXACT_FIXTURE); row[key] = value; invalid.append([row])
        missing = dict(EXACT_FIXTURE); del missing["bInterfaceNumber"]; invalid.append([missing])
        extra = dict(EXACT_FIXTURE); extra["IOPropertyMatch"] = {}; invalid.append([extra])
        invalid += [[EXACT_FIXTURE, EXACT_FIXTURE], [EXACT_FIXTURE] * 33]
        for matches in invalid:
            with self.subTest(matches=matches):
                with self.assertRaises(ValueError):
                    packaging.read_matches(self.manifest(matches))

    def test_existing_output_and_source_tree_are_never_overwritten(self):
        output = self.root / "saved-review"
        output.mkdir(); (output / "recovery.txt").write_text("keep")
        with self.assertRaises(ValueError):
            packaging.prepare(self.app, output, [], self.app_spec)
        self.assertEqual((output / "recovery.txt").read_text(), "keep")
        with self.assertRaises(ValueError):
            packaging.prepare(self.app, self.app / "Generated", [], self.app_spec)

    def test_candidate_pairs_stay_equal_to_existing_core_source(self):
        app_root = Path(os.environ.get("FLOE_USB_PACKAGING_TEST_APP_ROOT", Path(__file__).resolve().parents[4]))
        core = (app_root / "Modules/FloeToolbox/Sources/FloeToolboxCore/USBSerialPlans.swift").read_text()
        source = core.split("public static func candidate(", 1)[1].split("public static func configuration(", 1)[0]
        actual = {}
        for vendor, products in re.findall(r"if vendor == (0x[0-9a-f]+), \[([^\]]+)\]\.contains\(product\)", source):
            actual[int(vendor, 16)] = {int(value.strip(), 16) for value in products.split(",")}
        for vendor, product in re.findall(r"if vendor == (0x[0-9a-f]+), product == (0x[0-9a-f]+)", source):
            actual.setdefault(int(vendor, 16), set()).add(int(product, 16))
        self.assertEqual(actual, packaging.KNOWN_PAIRS)

    def test_cli_reads_the_real_base_spec_without_mutating_its_sources(self):
        app_root = Path(os.environ.get("FLOE_USB_PACKAGING_TEST_APP_ROOT", Path(__file__).resolve().parents[4]))
        entitlements = app_root / "FloeApp/Entitlements/Floe.entitlements"
        before = entitlements.read_bytes()
        output = self.root / "cli-review"
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("prepare_usb_driver.py")),
            "--app-root", str(app_root), "--output", str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(entitlements.read_bytes(), before)
        self.assertTrue((output / "driver-project.json").is_file())
        self.assertFalse((output / "app-overlay.json").exists())


if __name__ == "__main__":
    unittest.main()
