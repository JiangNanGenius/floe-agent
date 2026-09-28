#!/usr/bin/env python3
"""Focused checks for zh-CN/zh-TW Office UI resource packaging (R5).

The pinned engine is configured `--with-lang=en-US zh-CN zh-TW`, but the
upstream iOS resource target currently emits only en-US registry/langpack
files. These tests prove the audit is honest and complete:

* every language resource file actually produced by the host build is detected
  and reported per language;
* a packaging copy regression (a host file missing from the app) fails;
* a language the upstream build did not emit is reported as a gap, never
  fabricated and never silently treated as available.
"""
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import office_font_config as config  # noqa: E402

VENDOR_RESOURCES = (
    config.ROOT / "Vendor/Office/35668651442/OfficeNativeHost/OfficeRuntimeResources"
)


class LanguageResourceReportTests(unittest.TestCase):
    def make_tree(self, files):
        folder = Path(tempfile.mkdtemp(prefix="floe-office-language-"))
        for relative in files:
            path = folder / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"<x/>")
        return folder

    def test_all_produced_languages_are_reported(self):
        root = self.make_tree([
            "share/registry/Langpack-en-US.xcd",
            "share/registry/res/registry_en-US.xcd",
            "share/registry/res/fcfg_langpack_en-US.xcd",
            "share/registry/Langpack-zh-CN.xcd",
            "share/registry/res/registry_zh-CN.xcd",
            "share/registry/res/fcfg_langpack_zh-CN.xcd",
            "share/registry/Langpack-zh-TW.xcd",
        ])
        report = config.language_resource_report(root)
        self.assertEqual(report["availableLanguages"], ["en-US", "zh-CN", "zh-TW"])
        self.assertEqual(report["missingLanguages"], [])
        self.assertEqual(report["files"]["zh-CN"], [
            "share/registry/Langpack-zh-CN.xcd",
            "share/registry/res/fcfg_langpack_zh-CN.xcd",
            "share/registry/res/registry_zh-CN.xcd",
        ])

    def test_missing_configured_language_is_a_recorded_gap(self):
        root = self.make_tree([
            "share/registry/Langpack-en-US.xcd",
            "share/registry/res/registry_en-US.xcd",
        ])
        report = config.language_resource_report(root)
        self.assertEqual(report["availableLanguages"], ["en-US"])
        self.assertEqual(report["missingLanguages"], ["zh-CN", "zh-TW"])
        # The gap must never be turned into an available language.
        self.assertNotIn("zh-CN", report["files"])

    def test_packaging_failure_when_host_file_missing_from_app(self):
        host = {"files": {"zh-CN": ["share/registry/Langpack-zh-CN.xcd"],
                          "en-US": ["share/registry/Langpack-en-US.xcd"]}}
        app = {"files": {"en-US": ["share/registry/Langpack-en-US.xcd"]}}
        failures = config.language_packaging_failures(host, app)
        self.assertEqual(len(failures), 1)
        self.assertIn("Langpack-zh-CN.xcd", failures[0])
        failures = config.language_packaging_failures(host, host)
        self.assertEqual(failures, [])

    def test_real_pinned_host_output_reports_reality(self):
        if not VENDOR_RESOURCES.is_dir():
            self.skipTest("pinned Office host output is not installed")
        report = config.language_resource_report(VENDOR_RESOURCES)
        # The pinned artifact ships en-US only; the zh gap stays visible. If a
        # future engine build emits zh files this assertion flips to present,
        # and the packaging gate requires them to reach the app.
        self.assertIn("en-US", report["availableLanguages"])
        self.assertEqual(
            report["missingLanguages"],
            [language for language in config.CONFIGURED_ENGINE_LANGUAGES
             if language not in report["availableLanguages"]])
        for paths in report["files"].values():
            self.assertTrue(all(path.endswith(".xcd") for path in paths))


if __name__ == "__main__":
    unittest.main(verbosity=2)
