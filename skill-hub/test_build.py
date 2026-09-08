"""Release metadata must decode with the app's localized catalog contract."""
import copy
import json
import unittest

from build import IDS, ROOT, validate_release


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.release = json.loads((ROOT / "sources/floe-office/release.json").read_bytes())

    def test_all_published_source_metadata(self):
        for skill_id in IDS:
            with self.subTest(skill_id=skill_id):
                validate_release(json.loads((ROOT / "sources" / skill_id / "release.json").read_bytes()))

    def test_rejects_previously_signed_string_and_missing_translations(self):
        for notes in ("previously accepted string", {}, {"en": "English"},
                      {"zh-Hans": "中文", "en": " "},
                      {"zh-Hans": "中文", "en": "English", "fr": 123}):
            with self.subTest(notes=notes):
                release = copy.deepcopy(self.release)
                release["releaseNotes"] = notes
                with self.assertRaises(ValueError):
                    validate_release(release)

    def test_rejects_invalid_app_versions(self):
        for version in (None, 153, "1.5", "1.05.3", "v1.5.3", "1.5.3-beta"):
            with self.subTest(version=version):
                release = copy.deepcopy(self.release)
                release["minimumAppVersion"] = version
                with self.assertRaises(ValueError):
                    validate_release(release)


if __name__ == "__main__":
    unittest.main()
