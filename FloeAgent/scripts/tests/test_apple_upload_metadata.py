import importlib.util
import json
import plistlib
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("apple_upload_metadata", ROOT / "scripts/verify_apple_upload_metadata.py")
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
INPUTS = ("project.yml", "FloeApp/Entitlements/Floe.entitlements", "FloeApp/Resources/Info.plist", "FloeApp/Resources/InfoPlist.xcstrings")


class AppleUploadMetadataTests(unittest.TestCase):
    def setUp(self):
        scratch = ROOT.parent / "Local/Scratch"
        scratch.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="upload-metadata-test-", dir=scratch)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for relative in INPUTS:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)

    def mutate_catalog(self, change):
        path = self.root / "FloeApp/Resources/InfoPlist.xcstrings"
        catalog = json.loads(path.read_text())
        change(catalog["strings"])
        path.write_text(json.dumps(catalog))

    def source_replace(self, old, new):
        path = self.root / "project.yml"
        text = path.read_text()
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1))

    def test_current_committed_inputs(self):
        self.assertEqual(metadata.problems(self.root), [])

    def test_original_rejected_nfc_and_health_omissions(self):
        self.source_replace("          - TAG", "          - NDEF")
        source = self.root / "project.yml"
        source.write_text("\n".join(line for line in source.read_text().splitlines() if not line.startswith("        NSHealthUpdateUsageDescription:")) + "\n")
        ent = self.root / "FloeApp/Entitlements/Floe.entitlements"
        data = plistlib.loads(ent.read_bytes()); data[metadata.FORMATS] = ["NDEF"]
        ent.write_bytes(plistlib.dumps(data))
        info = self.root / "FloeApp/Resources/Info.plist"
        data = plistlib.loads(info.read_bytes()); data.pop("NSHealthUpdateUsageDescription")
        info.write_bytes(plistlib.dumps(data))
        self.mutate_catalog(lambda strings: strings.pop("NSHealthUpdateUsageDescription"))
        failures = metadata.problems(self.root)
        self.assertTrue(any("NFC formats" in failure for failure in failures))
        self.assertTrue(any("NSHealthUpdateUsageDescription" in failure for failure in failures))

    def test_generation_would_restore_rejected_source(self):
        self.source_replace("          - TAG", "          - NDEF")
        failures = metadata.problems(self.root)
        self.assertTrue(any("project.yml: NFC formats" in failure for failure in failures))
        self.assertFalse(any("Floe.entitlements:" in failure for failure in failures))

    def test_missing_chinese_purpose(self):
        self.mutate_catalog(lambda strings: strings["NSHealthUpdateUsageDescription"]["localizations"].pop("zh-Hans"))
        self.assertTrue(any("zh-Hans/NSHealthUpdateUsageDescription" in failure for failure in metadata.problems(self.root)))

    def test_divergent_english_purpose(self):
        def change(strings):
            strings["NSHealthUpdateUsageDescription"]["localizations"]["en"]["stringUnit"]["value"] = "Divergent purpose"
        self.mutate_catalog(change)
        self.assertTrue(any("English source mismatch" in failure for failure in metadata.problems(self.root)))

    def test_duplicate_tag_format_is_not_a_single_tag(self):
        self.source_replace("          - TAG", "          - TAG\n          - TAG")
        self.assertTrue(any("project.yml: NFC formats" in failure for failure in metadata.problems(self.root)))

    def test_equivalent_quoted_project_scalars(self):
        self.source_replace("          - TAG", '          - "TAG"')
        value = plistlib.loads((self.root / "FloeApp/Resources/Info.plist").read_bytes())["NSHealthUpdateUsageDescription"]
        self.source_replace("NSHealthUpdateUsageDescription: " + value, "NSHealthUpdateUsageDescription: " + json.dumps(value))
        self.assertEqual(metadata.problems(self.root), [])


if __name__ == "__main__":
    unittest.main()
