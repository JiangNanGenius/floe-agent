import importlib.util
import plistlib
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("feather_source", Path(__file__).parents[1] / "generate_feather_source.py")
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


class FeatherSourceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.ipa = Path(self.directory.name) / "Floe-Agent-1.7.0-build167-unsigned.ipa"

    def write_ipa(self, bundle="org.floeagent.ios", signed=False, duplicate=False):
        info = {"CFBundleIdentifier": bundle, "CFBundleShortVersionString": "1.7.0",
                "CFBundleVersion": "167", "MinimumOSVersion": "26.0"}
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr("Payload/Floe Agent.app/Info.plist", plistlib.dumps(info))
            if signed:
                archive.writestr("Payload/Floe Agent.app/_CodeSignature/CodeResources", b"signature")
            if duplicate:
                archive.writestr("Payload/Other.app/Info.plist", plistlib.dumps(info))

    def generate(self, **kwargs):
        return feed.generate(self.ipa, "v1.7.0-beta.24", "a" * 40, "2026-09-14T12:00:00Z", **kwargs)

    def test_actual_binary_metadata_and_feather_legacy_fields_agree(self):
        self.write_ipa()
        app = self.generate()["apps"][0]
        version = app["versions"][0]
        self.assertEqual(version["buildVersion"], "167")
        self.assertEqual(version["minOSVersion"], "26.0")
        self.assertEqual(version["size"], self.ipa.stat().st_size)
        self.assertEqual(app["downloadURL"], version["downloadURL"])
        self.assertEqual(app["size"], version["size"])
        self.assertEqual(len(version["sha256"]), 64)
        self.assertIn("/v1.7.0-beta.24/", version["downloadURL"])

    def test_foreign_signed_or_ambiguous_binaries_are_rejected(self):
        for options in ({"bundle": "example.foreign"}, {"signed": True}, {"duplicate": True}):
            with self.subTest(options=options):
                self.write_ipa(**options)
                with self.assertRaises(ValueError):
                    self.generate()

    def test_republishing_is_idempotent_and_preserves_history(self):
        self.write_ipa()
        first = self.generate()
        self.assertEqual(first, self.generate(previous=first))
        old = dict(first["apps"][0]["versions"][0], buildVersion="166")
        first["apps"][0]["versions"].append(old)
        self.assertEqual(self.generate(previous=first)["apps"][0]["versions"][1], old)

    def test_rollback_and_tag_mismatch_are_rejected(self):
        self.write_ipa()
        previous = self.generate()
        previous["apps"][0]["versions"][0]["buildVersion"] = "168"
        with self.assertRaises(ValueError):
            self.generate(previous=previous)
        with self.assertRaises(ValueError):
            feed.generate(self.ipa, "v1.8.0-beta.1", "a" * 40, "2026-09-14T12:00:00Z")


if __name__ == "__main__":
    unittest.main()
