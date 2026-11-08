import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import license_inventory as li


class ClipperLicenseTests(unittest.TestCase):
    def test_real_pinned_source_full_text_and_generated_row(self):
        result = li.build()
        self.assertEqual(result["problems"], [])
        spec = next(item for item in li.VENDORED_PACKAGES if item["identity"] == "clipper2")
        source = li.ROOT / spec["path"] / "LICENSE"
        self.assertEqual(li.sha256_file(source), "c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566")
        component = next(row for row in result["manifest"]["components"] if row["name"] == "clipper2")
        self.assertEqual(component["version"], "2.0.1")
        self.assertEqual(component["license"], "BSL-1.0")
        self.assertTrue(component["source"].endswith("/tree/b496b454df168a2280354857c1cd90bd6fa7b4dd"))
        destination = spec["document"]["repositoryPath"]
        self.assertEqual(result["vendored_copies"][destination], source.read_bytes())
        self.assertEqual((li.ROOT / destination).read_bytes(), source.read_bytes())
        row = next(row for row in result["evidence"]["licenses"] if row["identity"] == "clipper2")
        self.assertEqual(row["revision"], spec["revision"])
        self.assertEqual(row["sha256"], hashlib.sha256(source.read_bytes()).hexdigest())
        catalog = json.loads(li.XSTRINGS.read_text())["strings"]
        for key in [spec["document"]["titleKey"], "settings.licenses.note.clipper2_vendor"]:
            for locale in ["en", "zh-Hans"]:
                self.assertTrue(catalog[key]["localizations"][locale]["stringUnit"]["value"])

    def test_an_edited_license_cannot_be_regenerated_under_the_same_pin(self):
        spec = next(item for item in li.VENDORED_PACKAGES if item["identity"] == "clipper2")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); target = root / spec["path"] / "LICENSE"
            target.parent.mkdir(parents=True)
            target.write_bytes((li.ROOT / spec["path"] / "LICENSE").read_bytes() + b"\nmodified\n")
            problems = []
            with mock.patch.object(li, "VENDORED_PACKAGES", (spec,)):
                li.resolve_vendored_packages([], problems, root=root)
            self.assertTrue(any("differs from its reviewed source pin" in text for text in problems))


if __name__ == "__main__":
    unittest.main()
