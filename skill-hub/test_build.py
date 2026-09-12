"""Release metadata must decode with the app's localized catalog contract."""
import copy
import json
import unittest

from build import IDS, ROOT, validate_release, validate_guide_metadata


class ReleaseMetadataTests(unittest.TestCase):
    def setUp(self):
        self.release = json.loads((ROOT / "sources/floe-office/release.json").read_bytes())

    def test_all_published_source_metadata(self):
        for skill_id in IDS:
            with self.subTest(skill_id=skill_id):
                folder = ROOT / "sources" / skill_id
                release = json.loads((folder / "release.json").read_bytes())
                validate_release(release)
                validate_guide_metadata((folder / "SKILL.md").read_text(), json.loads((folder / "floe.json").read_bytes()), release)

    def test_package_and_discovery_metadata_cannot_drift(self):
        folder = ROOT / "sources/floe-office"
        manifest = json.loads((folder / "floe.json").read_bytes())
        markdown = (folder / "SKILL.md").read_text()
        for field in ("name", "description"):
            changed = dict(self.release, **{field: "Different discovery metadata"})
            with self.assertRaises(ValueError):
                validate_guide_metadata(markdown, manifest, changed)
        with self.assertRaises(ValueError):
            validate_guide_metadata(markdown, dict(manifest, id="wrong-id"), self.release)

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

class ModelExclusionTests(unittest.TestCase):
    def test_excluded_models_require_reason_and_no_files(self):
        import tempfile
        from pathlib import Path
        from unittest.mock import patch
        import build
        entry = {"id": "floe/test", "skillID": "floe-video", "capability": "video.interpolate",
                 "license": "CC-BY-NC-4.0", "status": "excluded", "notes": "Not in the current distribution scope", "files": []}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(build, 'ROOT', root):
                for change, accepted in [({}, True), ({"notes": ""}, False), ({"files": [{"url": "https://example.invalid/file"}]}, False), ({"status": "pending-assets"}, False)]:
                    (root / 'models.json').write_text(json.dumps({"models": [dict(entry, **change)]}))
                    if accepted:
                        self.assertEqual(len(build.load_models()), 1)
                    else:
                        with self.assertRaises(ValueError):
                            build.load_models()
