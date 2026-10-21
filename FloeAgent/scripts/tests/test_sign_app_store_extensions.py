"""Prepared signing contracts; no certificate, profile or Apple access."""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sign_app_store_extensions import APP_ID, EXTENSIONS, TEAM, inventory, validated_entitlements


class ExtensionSigningTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 10, 22, tzinfo=timezone.utc)
        self.identifier = APP_ID + ".widgets"
        self.declared = {"com.apple.security.application-groups": ["group." + APP_ID]}
        self.profile = {
            "TeamIdentifier": [TEAM], "ExpirationDate": self.now + timedelta(days=2),
            "Entitlements": {
                **self.declared, "application-identifier": TEAM + "." + self.identifier,
                "keychain-access-groups": [TEAM + ".*"],
                "get-task-allow": False, "beta-reports-active": True,
            },
        }

    def validate(self, profile=None, declared=None):
        return validated_entitlements(profile or self.profile, declared or self.declared,
                                      self.identifier, self.now)

    def test_only_declared_capabilities_and_exact_identity_are_signed(self):
        self.profile["Entitlements"]["unrequested-capability"] = True
        result = self.validate()
        self.assertNotIn("unrequested-capability", result)
        self.assertEqual(result["application-identifier"], TEAM + "." + self.identifier)
        self.assertEqual(result["keychain-access-groups"], [TEAM + "." + self.identifier])

    def test_wrong_app_wildcard_team_expiry_and_development_refused(self):
        variants = [
            ("application-identifier", TEAM + ".*"),
            ("get-task-allow", True), ("beta-reports-active", False),
            ("com.apple.security.application-groups", ["group.other"]),
            ("keychain-access-groups", ["OTHER.*"]),
        ]
        for key, value in variants:
            with self.subTest(key=key):
                profile = deepcopy(self.profile)
                profile["Entitlements"][key] = value
                with self.assertRaises(ValueError): self.validate(profile)
        for patch in ({"TeamIdentifier": ["OTHER"]}, {"ExpirationDate": self.now},
                      {"ProvisionedDevices": ["device"]}, {"ProvisionsAllDevices": True}):
            with self.subTest(patch=patch):
                with self.assertRaises(ValueError): self.validate({**self.profile, **patch})

    def test_new_host_capabilities_must_be_granted_not_assumed(self):
        requested = {**self.declared, "com.apple.developer.healthkit": True,
                     "com.apple.developer.nfc.readersession.formats": ["NDEF"]}
        with self.assertRaises(ValueError): self.validate(declared=requested)
        self.profile["Entitlements"].update({
            "com.apple.developer.healthkit": True,
            "com.apple.developer.nfc.readersession.formats": ["NDEF", "TAG"],
        })
        self.assertEqual(self.validate(declared=requested)[
            "com.apple.developer.nfc.readersession.formats"], ["NDEF"])

    def test_source_group_is_not_optional_or_foreign(self):
        with self.assertRaises(ValueError): self.validate(declared={"other": True})
        with self.assertRaises(ValueError): self.validate(declared={
            "com.apple.security.application-groups": ["group." + APP_ID, "group.other"]})

    def test_inventory_requires_all_four_unique_matching_extensions(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Floe.app"
            plugins = app / "PlugIns"
            plugins.mkdir(parents=True)
            host = {"CFBundleIdentifier": APP_ID, "CFBundleShortVersionString": "1.8.0",
                    "CFBundleVersion": "999"}
            (app / "Info.plist").write_bytes(plistlib.dumps(host))
            for identifier, (name, _, _) in EXTENSIONS.items():
                extension = plugins / (name + ".appex")
                extension.mkdir()
                (extension / "Info.plist").write_bytes(plistlib.dumps({
                    **host, "CFBundleIdentifier": identifier}))
            self.assertEqual(set(inventory(app)), set(EXTENSIONS))
            info_path = plugins / "FloeShare.appex/Info.plist"
            original = info_path.read_bytes()
            info_path.write_bytes(plistlib.dumps({**host,
                "CFBundleIdentifier": APP_ID + ".share", "CFBundleVersion": "998"}))
            with self.assertRaises(ValueError): inventory(app)
            info_path.write_bytes(original)
            info_path.unlink()
            with self.assertRaises(ValueError): inventory(app)


if __name__ == "__main__":
    unittest.main()
