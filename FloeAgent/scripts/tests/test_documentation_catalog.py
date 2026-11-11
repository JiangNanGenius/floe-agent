# SPDX-License-Identifier: MPL-2.0
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "FloeAgent/scripts"))
from documentation_catalog import load_catalog, select_documents
import build_help_content as help_builder


class DocumentationPlatformTests(unittest.TestCase):
    def setUp(self):
        self.catalog = load_catalog(ROOT / "docs/DOCUMENTATION_CATALOG.json")

    def test_shared_source_is_reused_and_platform_sources_are_separate(self):
        ios = {d["id"]: d for d in select_documents(self.catalog, "ios", help_only=True)}
        android = {d["id"]: d for d in select_documents(self.catalog, "android", help_only=True)}
        self.assertEqual(set(ios) & set(android), {"shared-basics"})
        self.assertEqual(ios["shared-basics"]["sources"], android["shared-basics"]["sources"])
        self.assertIn("user-manual", ios)
        self.assertNotIn("android-guide", ios)
        self.assertIn("android-guide", android)
        self.assertNotIn("user-manual", android)

    def test_android_only_article_never_enters_ios_resources_or_search(self):
        files = help_builder.build_package("", with_images=False)
        manifest = json.loads(files["help/manifest.json"])
        self.assertEqual(manifest["platform"], "ios")
        self.assertEqual(set(manifest["sourceAudiences"].values()), {"shared", "ios"})
        for locale in ("en", "zh-Hans"):
            index = json.loads(files[f"help/index/{locale}.json"])
            by_id = {article["id"]: article for article in index["articles"]}
            self.assertIn("shared-basics", by_id)
            self.assertNotIn("android-guide", by_id)
            self.assertEqual({article["audience"] for article in by_id.values()}, {"shared", "ios"})
            text = files[f"help/index/{locale}.json"].decode().lower()
            for marker in ("self-adb", "shizuku", "内嵌 adb", "安卓网络工作台"):
                self.assertNotIn(marker, text)
        self.assertFalse(any("android" in name.lower() for name in files))

    def test_unknown_platform_cannot_fall_back_to_all_documents(self):
        for platform in ("", "all", "ipados", "Android"):
            with self.assertRaises(ValueError):
                select_documents(self.catalog, platform)

    def test_bad_classification_and_paths_fail_closed(self):
        variants = []
        for key, value in (("audience", "all"), ("audience", None), ("help", "true"),
                           ("sources", {"en": "../ANDROID_GUIDE.md", "zh-Hans": "x.md"}),
                           ("sources", {"en": "A.md"})):
            data = copy.deepcopy(self.catalog)
            data["documents"][0][key] = value
            variants.append(data)
        duplicate = copy.deepcopy(self.catalog)
        duplicate["documents"].append(duplicate["documents"][0])
        variants.append(duplicate)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "catalog.json"
            for data in variants:
                path.write_text(json.dumps(data))
                with self.assertRaises(ValueError):
                    load_catalog(path)

    def test_missing_catalog_does_not_enable_glob_discovery(self):
        original = help_builder.DOCS_DIR
        try:
            with tempfile.TemporaryDirectory() as folder:
                help_builder.DOCS_DIR = folder
                with self.assertRaises(help_builder.BuildError):
                    help_builder.build_package("", with_images=False)
        finally:
            help_builder.DOCS_DIR = original


if __name__ == "__main__":
    unittest.main()
