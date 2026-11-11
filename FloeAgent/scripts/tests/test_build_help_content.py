# SPDX-License-Identifier: MPL-2.0
"""Tests for FloeAgent/scripts/build_help_content.py.

Builds from the maintained public guides and tests platform isolation with
synthetic catalogs. No private snapshot is required by CI.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "FloeAgent" / "scripts" / "build_help_content.py"
SNAPSHOT_DOCS = ROOT / "docs"

sys.path.insert(0, str(SCRIPT.parent))
import build_help_content as bhc  # noqa: E402

IDENTIFIER_RE = re.compile(r"^[a-z0-9]+([.-][a-z0-9]+)*$")


def blob_base():
    return "https://github.com/JiangNanGenius/floe-agent/blob/main"


def run_cli(*args):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True, text=True,
        env=dict(os.environ, FLOE_HELP_SOURCE_REVISION=""),
    )


class GeneratorFixtureTests(unittest.TestCase):
    """Build the package from the fixed input snapshot."""

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.mkdtemp(prefix="help-gen-test-")
        cls.builtin = Path(cls.temp) / "builtin"
        cls.authoring = Path(cls.temp) / "authoring"
        proc = run_cli(
            "build",
            "--docs-dir", str(SNAPSHOT_DOCS),
            "--builtin-out", str(cls.builtin),
            "--authoring-out", str(cls.authoring),
        )
        assert proc.returncode == 0, proc.stderr
        cls.files = {
            str(path.relative_to(cls.builtin)): path.read_bytes()
            for path in cls.builtin.rglob("*") if path.is_file()
        }

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.temp, ignore_errors=True)

    def load_json(self, relative):
        return json.loads(self.files[relative].decode("utf-8"))

    # -- Package shape -------------------------------------------------

    def test_package_shape_and_bounds(self):
        self.assertEqual(len(self.files), 25)
        for relative, data in self.files.items():
            if relative in ("content.json", "help/manifest.json"):
                self.assertLessEqual(len(data), 262_144, relative)
            else:
                self.assertLessEqual(len(data), 1_048_576, relative)
        self.assertIn("help/index/en.json", self.files)
        self.assertIn("help/index/zh-Hans.json", self.files)
        self.assertIn("index.md", self.files)
        self.assertIn("index.zh-Hans.md", self.files)

    def test_article_ids_are_stable(self):
        index = self.load_json("help/index/en.json")
        ids = [article["id"] for article in index["articles"]]
        self.assertEqual(
            ids,
            ["quickstart", "shared-basics", "user-manual", "workspaces",
             "input.keyboard", "voice.output", "environment.memory"],
        )
        for article in index["articles"]:
            self.assertTrue(IDENTIFIER_RE.match(article["id"]))
            section_ids = [section["id"] for section in article["sections"]]
            self.assertEqual(len(section_ids), len(set(section_ids)), article["id"])
            for section_id in section_ids:
                self.assertTrue(IDENTIFIER_RE.match(section_id), section_id)
                self.assertLessEqual(len(section_id.encode("utf-8")), 128)

    def test_major_chapter_anchor_parity_across_locales(self):
        en = self.load_json("help/index/en.json")
        zh = self.load_json("help/index/zh-Hans.json")
        en_chapters = {
            article["id"]: [s["id"] for s in article["sections"] if s["level"] == 2]
            for article in en["articles"]
        }
        zh_chapters = {
            article["id"]: [s["id"] for s in article["sections"] if s["level"] == 2]
            for article in zh["articles"]
        }
        self.assertEqual(en_chapters, zh_chapters)

    def test_manual_anchor_uniqueness_and_no_source_duplicates(self):
        index = self.load_json("help/index/en.json")
        manual = next(a for a in index["articles"] if a["id"] == "user-manual")
        section_ids = [s["id"] for s in manual["sections"]]
        self.assertEqual(len(section_ids), len(set(section_ids)))
        # The source docs carry two `doc-anchor: section-19` comments; the
        # generated identity scheme must not inherit that collision.
        self.assertEqual(section_ids.count("section-19"), 1)
        self.assertIn("section-19", section_ids)
        self.assertIn("section-15", section_ids)
        self.assertIn("overview", section_ids)

    def test_howto_setting_ids_and_paths(self):
        index = self.load_json("help/index/zh-Hans.json")
        by_id = {article["id"]: article for article in index["articles"]}
        self.assertEqual(by_id["input.keyboard"]["settingIDs"], ["general.hardwareReturn"])
        self.assertEqual(by_id["voice.output"]["settingIDs"], ["general.voiceOutput"])
        self.assertEqual(by_id["environment.memory"]["settingIDs"], ["execution.memory"])
        memory_text = by_id["environment.memory"]["sections"][0]["text"]
        self.assertIn("设置 > 执行环境 > 共享运行环境 > 内存", memory_text)
        keyboard_html = self.files["help/articles/en/input.keyboard.html"].decode("utf-8")
        self.assertIn("Settings &gt; General &gt; Hardware Keyboard &gt; Return Key", keyboard_html)

    def test_search_corpus_terms_present(self):
        en = self.load_json("help/index/en.json")
        zh = self.load_json("help/index/zh-Hans.json")

        def blob(index):
            return "\n".join(
                section["text"] + " " + " ".join(section["aliases"])
                for article in index["articles"]
                for section in article["sections"]
            )

        en_text = blob(en).lower()
        zh_text = blob(zh)
        for term in ("apple pencil", "pencil", "keyboard", "voice", "linux", "memory",
                     "temporary chat", "office", "notes"):
            self.assertIn(term, en_text, term)
        for term in ("手记", "笔记", "语音", "临时会话", "权限", "内存", "键盘"):
            self.assertIn(term, zh_text, term)
        # The notes section carries the no-space alias too.
        manual_en = next(a for a in en["articles"] if a["id"] == "user-manual")
        notes = next(s for s in manual_en["sections"] if s["id"] == "section-7")
        self.assertIn("applepencil", [a.lower() for a in notes["aliases"]])

    # -- Links ---------------------------------------------------------

    def test_links_resolve_in_package_or_public_https(self):
        blob = "https://github.com/JiangNanGenius/floe-agent/blob/main/"
        for locale in ("en", "zh-Hans"):
            for name in ("quickstart", "user-manual", "workspaces",
                         "input.keyboard", "voice.output", "environment.memory"):
                body = self.files[f"help/articles/{locale}/{name}.html"].decode("utf-8")
                for href in re.findall(r'href="([^"]+)"', body):
                    self.assertFalse(href.startswith("http://"), href)
                    if href == "../../styles/help.css" or href.startswith("#"):
                        continue
                    if href.startswith("https://"):
                        # External documentation targets are public HTTPS
                        # (repository blobs, pinned-branch blobs or the
                        # official website); local markdown paths are never
                        # kept in the package.
                        if href.startswith(blob):
                            rewritten = href[len(blob):]
                            self.assertNotIn("..", rewritten, href)
                            self.assertFalse(rewritten.endswith("/"), href)
                        continue
                    if href.endswith(".html") or ".html#" in href:
                        target = href.split("#", 1)[0]
                        self.assertIn(
                            f"help/articles/{locale}/{target}", self.files,
                            f"{locale}/{name}: {href}")
                        if "#" in href:
                            anchor = href.split("#", 1)[1]
                            self.assertIn(f'id="{anchor}"', self.files[
                                f"help/articles/{locale}/{target}"].decode("utf-8"))
                    else:
                        self.fail(f"unexpected local href {href} in {locale}/{name}")
                for src in re.findall(r'<img src="([^"]+)"', body):
                    self.assertTrue(src.startswith("../../assets/guide/"), src)
                    self.assertTrue(src.endswith(".webp"), src)
                    self.assertIn("help/assets/guide/" + src.rsplit("/", 1)[1], self.files)

    def test_repository_relative_links_normalize_to_repo_paths(self):
        en = self.files["help/articles/en/user-manual.html"].decode("utf-8")
        self.assertIn(f"{blob_base()}/SECURITY.md", en)
        self.assertIn(f"{blob_base()}/SUPPORT.md", en)
        self.assertIn(f"{blob_base()}/skill-hub/README.md", en)
        self.assertNotIn("docs/SECURITY.md", en)
        self.assertNotIn("docs/skill-hub/README.md", en)

    def test_new_help_entry_fragment_links(self):
        en = self.files["help/articles/en/user-manual.html"].decode("utf-8")
        zh = self.files["help/articles/zh-Hans/user-manual.html"].decode("utf-8")
        self.assertIn('href="#section-1-2"', en)
        self.assertIn('id="section-1-2"', en)
        self.assertIn('href="#section-1-2"', zh)
        self.assertIn('id="section-1-2"', zh)

    def test_raw_heading_text_fragments_map_to_real_anchors(self):
        # Maintained guides also link with raw heading text, not only slugs.
        en = self.files["help/articles/en/user-manual.html"].decode("utf-8")
        zh = self.files["help/articles/zh-Hans/user-manual.html"].decode("utf-8")
        for bad in ('#1. Installation and first use', '#Help and guides', '#目录',
                    '#9. 本地终端与 Linux 性能配置'):
            self.assertNotIn(f'href="{bad}"', en)
            self.assertNotIn(f'href="{bad}"', zh)
        self.assertIn('href="#section-1"', en)
        self.assertIn('href="#overview"', zh)

    def test_no_local_markdown_paths_or_scripts(self):
        for relative, data in self.files.items():
            if not relative.endswith(".html"):
                continue
            text = data.decode("utf-8")
            self.assertNotIn("<script", text, relative)
            for href in re.findall(r'href="([^"]+)"', text):
                if href.startswith("#") or href.startswith("https://") \
                        or href == "../../styles/help.css":
                    continue
                self.assertFalse(href.endswith(".md"), f"{relative}: {href}")
                self.assertFalse(".md#" in href, f"{relative}: {href}")

    # -- Manifest ------------------------------------------------------

    def test_manifest_matches_content_and_files(self):
        content = self.load_json("content.json")
        manifest = self.load_json("help/manifest.json")
        self.assertEqual(content["schemaVersion"], 1)
        self.assertEqual(content["id"], "floe.help.quickstart")
        self.assertEqual(content["version"], "1.2.0")
        self.assertEqual(content["kind"], "help")
        self.assertEqual(content["helpManifest"], "help/manifest.json")
        self.assertEqual(content["sourceRevision"], "")
        self.assertEqual(manifest["sourceRevision"], content["sourceRevision"])
        self.assertEqual(manifest["id"], content["id"])
        self.assertEqual(manifest["version"], content["version"])
        self.assertEqual(set(manifest["indexPaths"]), {"en", "zh-Hans"})
        listed = {resource["path"] for resource in manifest["resources"]}
        expected = set(self.files) - {"content.json", "help/manifest.json"}
        self.assertEqual(listed, expected)
        for resource in manifest["resources"]:
            data = self.files[resource["path"]]
            self.assertEqual(resource["byteCount"], len(data), resource["path"])
            self.assertEqual(resource["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(
                resource["mimeType"], bhc.mime_for(resource["path"]), resource["path"])

    def test_categories_reference_real_sections(self):
        index = self.load_json("help/index/en.json")
        sections = {
            article["id"]: {section["id"] for section in article["sections"]}
            for article in index["articles"]
        }
        self.assertEqual(len(index["categories"]), 7)
        seen_categories = set()
        for category in index["categories"]:
            self.assertTrue(IDENTIFIER_RE.match(category["id"]))
            self.assertNotIn(category["id"], seen_categories)
            seen_categories.add(category["id"])
            for entry in category["entries"]:
                self.assertIn(entry["articleID"], sections)
                if entry["sectionID"] is not None:
                    self.assertIn(entry["sectionID"], sections[entry["articleID"]])

    # -- Legacy projection ---------------------------------------------

    def test_legacy_projection_documents(self):
        content = self.load_json("content.json")
        self.assertEqual(content["documents"],
                         {"en": "index.md", "zh-Hans": "index.zh-Hans.md"})
        en = self.files["index.md"].decode("utf-8")
        zh = self.files["index.zh-Hans.md"].decode("utf-8")
        for name in ("From installation to your first result",
                     "Floe Agent User Manual", "Space and specialist workbenches",
                     "Hardware keyboard Return key", "Shared runtime memory"):
            self.assertIn(name, en)
        for name in ("从安装到第一个成果", "使用手册", "空间与专用工作台",
                     "实体键盘回车键", "共享运行环境内存"):
            self.assertIn(name, zh)


class GeneratorCliTests(unittest.TestCase):
    """CLI behaviour: determinism and the read-only check mode."""

    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="help-cli-test-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.builtin = self.temp / "builtin"
        self.authoring = self.temp / "authoring"

    def build(self):
        return run_cli(
            "build",
            "--docs-dir", str(SNAPSHOT_DOCS),
            "--builtin-out", str(self.builtin),
            "--authoring-out", str(self.authoring),
        )

    def snapshot_tree(self, root: Path):
        return {
            str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in root.rglob("*") if path.is_file()
        }

    def test_build_is_deterministic(self):
        self.assertEqual(self.build().returncode, 0)
        first = self.snapshot_tree(self.builtin)
        self.assertEqual(self.build().returncode, 0)
        second = self.snapshot_tree(self.builtin)
        self.assertEqual(first, second)

    def test_check_is_read_only(self):
        self.assertEqual(self.build().returncode, 0)
        before_builtin = self.snapshot_tree(self.builtin)
        before_authoring = self.snapshot_tree(self.authoring)
        proc = run_cli(
            "check",
            "--docs-dir", str(SNAPSHOT_DOCS),
            "--builtin-out", str(self.builtin),
            "--authoring-out", str(self.authoring),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("check OK", proc.stdout)
        self.assertEqual(before_builtin, self.snapshot_tree(self.builtin))
        self.assertEqual(before_authoring, self.snapshot_tree(self.authoring))

    def test_check_flag_alias_is_read_only(self):
        self.assertEqual(self.build().returncode, 0)
        before = self.snapshot_tree(self.builtin)
        proc = run_cli(
            "--check",
            "--docs-dir", str(SNAPSHOT_DOCS),
            "--builtin-out", str(self.builtin),
            "--authoring-out", str(self.authoring),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(before, self.snapshot_tree(self.builtin))

    def test_check_detects_tampering(self):
        self.assertEqual(self.build().returncode, 0)
        target = self.builtin / "help" / "styles" / "help.css"
        target.write_bytes(target.read_bytes() + b"/* tampered */")
        proc = run_cli(
            "check",
            "--docs-dir", str(SNAPSHOT_DOCS),
            "--builtin-out", str(self.builtin),
            "--authoring-out", str(self.authoring),
        )
        self.assertEqual(proc.returncode, 1)
        self.assertIn("CHECK FAIL", proc.stderr)

    def test_rejects_bad_source_revision(self):
        proc = run_cli(
            "build", "--source-revision", "NOT-A-REVISION",
            "--docs-dir", str(SNAPSHOT_DOCS),
            "--builtin-out", str(self.builtin),
            "--authoring-out", str(self.authoring),
        )
        self.assertEqual(proc.returncode, 2)

    def test_empty_and_hex_source_revision_accepted(self):
        for revision in ("", "a" * 40):
            proc = run_cli(
                "build", "--source-revision", revision,
                "--docs-dir", str(SNAPSHOT_DOCS),
                "--builtin-out", str(self.builtin),
                "--authoring-out", str(self.authoring),
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            content = json.loads((self.builtin / "content.json").read_text())
            manifest = json.loads((self.builtin / "help" / "manifest.json").read_text())
            self.assertEqual(content["sourceRevision"], revision)
            self.assertEqual(manifest["sourceRevision"], revision)


class ImageCodecTests(unittest.TestCase):
    """Lossless, bounded image conversion with pixel-faithful decode."""

    @classmethod
    def setUpClass(cls):
        cls.temp = Path(tempfile.mkdtemp(prefix="help-img-test-"))
        cls.addClassCleanup(shutil.rmtree, str(cls.temp), True)
        cls.converted = bhc.convert_images()

    def test_all_images_bounded(self):
        self.assertEqual(len(self.converted), 4)
        for path, data in self.converted.items():
            self.assertLessEqual(len(data), 1_048_576, path)
            self.assertGreater(len(data), 1000, path)

    def test_lossless_pixels_preserved(self):
        """Decoded package WebP pixels must equal the source PNG pixels.

        Independent decoders (Pillow performs no ICC color management by
        default) compare the original PNG against the package WebP; lossless
        conversion must preserve every RGBA byte.
        """
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow not installed")
        for path, data in self.converted.items():
            name = path.rsplit("/", 1)[1][:-5]
            source_png = SNAPSHOT_DOCS / "assets" / "guide" / f"{name}.png"
            package_webp = self.temp / f"{name}.webp"
            package_webp.write_bytes(data)
            with Image.open(source_png) as original, Image.open(package_webp) as converted:
                original_rgba = original.convert("RGBA").tobytes()
                converted_rgba = converted.convert("RGBA").tobytes()
            self.assertEqual(original.size, converted.size, name)
            self.assertEqual(original_rgba, converted_rgba, name)


if __name__ == "__main__":
    unittest.main()
