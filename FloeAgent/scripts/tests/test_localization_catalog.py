"""Exercise the standalone localization catalog validator used by release preflight.

The validator is the pre-build twin of FloeCoreTests' LocalizationCompletenessTests,
so these tests run the real script against the real catalog and against temporary
invalid catalogs; they never compile the app.
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "scripts" / "validate_localization_catalog.py"
REAL_CATALOG = ROOT / "FloeApp" / "Resources" / "Localizable.xcstrings"
KEY = "notes.navigation.backToNotes"


def run_validator(path):
    return subprocess.run(
        [sys.executable, str(VALIDATOR), str(path)],
        capture_output=True,
        text=True,
    )


def valid_catalog():
    return {
        "sourceLanguage": "en",
        "version": "1.0",
        "strings": {
            KEY: {
                "localizations": {
                    "en": {"stringUnit": {"state": "translated", "value": "Back to Notes"}},
                    "zh-Hans": {"stringUnit": {"state": "translated", "value": "返回手记"}},
                }
            }
        },
    }


class LocalizationCatalogValidatorTests(unittest.TestCase):
    def write(self, catalog, directory, raw=False):
        path = Path(directory) / "Localizable.xcstrings"
        if raw:
            path.write_text(catalog, encoding="utf-8")
        else:
            path.write_text(json.dumps(catalog, ensure_ascii=False), encoding="utf-8")
        return path

    def assert_rejected(self, catalog, *expected, raw=False):
        with tempfile.TemporaryDirectory(prefix="floe-catalog-test-") as temp:
            path = self.write(catalog, temp, raw=raw)
            result = run_validator(path)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        for fragment in expected:
            self.assertIn(fragment, result.stderr)

    def test_real_catalog_passes(self):
        result = run_validator(REAL_CATALOG)
        self.assertEqual(result.returncode, 0, result.stderr)
        entries = len(json.loads(REAL_CATALOG.read_text(encoding="utf-8"))["strings"])
        self.assertIn("localization catalog OK", result.stdout)
        self.assertIn(f"{entries} entries", result.stdout)

    def test_valid_catalog_passes(self):
        with tempfile.TemporaryDirectory(prefix="floe-catalog-test-") as temp:
            result = run_validator(self.write(valid_catalog(), temp))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 entries", result.stdout)

    def test_missing_catalog_and_directory_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="floe-catalog-test-") as temp:
            missing = Path(temp) / "FloeApp" / "Resources" / "Localizable.xcstrings"
            result = run_validator(missing)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("catalog missing", result.stderr)

    def test_invalid_json_is_rejected(self):
        self.assert_rejected("{\n", "not valid JSON", raw=True)

    def test_empty_catalog_is_rejected(self):
        self.assert_rejected({"strings": {}}, "catalog is empty")

    def test_strings_not_an_object_is_rejected(self):
        self.assert_rejected({"strings": []}, "'strings' must be a JSON object")

    def test_unnamespaced_key_is_rejected(self):
        catalog = valid_catalog()
        catalog["strings"]["backToNotes"] = catalog["strings"].pop(KEY)
        self.assert_rejected(catalog, "non-namespaced key: 'backToNotes'", "error: localization catalog incomplete")

    def test_missing_localizations_is_rejected(self):
        catalog = valid_catalog()
        catalog["strings"][KEY] = {}
        self.assert_rejected(catalog, f"{KEY}: no localizations")

    def test_missing_english_is_rejected(self):
        catalog = valid_catalog()
        del catalog["strings"][KEY]["localizations"]["en"]
        self.assert_rejected(catalog, f"{KEY}: missing en")

    def test_missing_chinese_is_rejected(self):
        catalog = valid_catalog()
        del catalog["strings"][KEY]["localizations"]["zh-Hans"]
        self.assert_rejected(catalog, f"{KEY}: missing zh-Hans")

    def test_empty_english_is_rejected(self):
        catalog = valid_catalog()
        catalog["strings"][KEY]["localizations"]["en"]["stringUnit"]["value"] = " \t "
        self.assert_rejected(catalog, f"{KEY}: en empty")

    def test_empty_chinese_is_rejected(self):
        catalog = valid_catalog()
        catalog["strings"][KEY]["localizations"]["zh-Hans"]["stringUnit"]["value"] = ""
        self.assert_rejected(catalog, f"{KEY}: zh-Hans empty")

    def test_all_problems_are_reported_together(self):
        catalog = valid_catalog()
        catalog["strings"]["settings.appearance"] = {}
        del catalog["strings"][KEY]["localizations"]["zh-Hans"]
        self.assert_rejected(catalog, f"{KEY}: missing zh-Hans", "settings.appearance: no localizations")


if __name__ == "__main__":
    unittest.main()
