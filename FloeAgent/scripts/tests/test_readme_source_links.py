"""Static checks for the README quick-add buttons and the Feather feed.

GitHub's Markdown sanitizer strips `href` attributes whose scheme it does not
allow (it keeps `http`, `https` and `mailto`). The top-of-README "Add to
Feather" / "Add to AltStore" buttons therefore cannot use `feather://` or
`altstore://`; the working entry is the official download page, which performs
the custom-scheme navigation from a normal web page. These tests pin that
contract, the shared source URL, and the feed's AltStore-compatible shape so a
future edit cannot silently reintroduce dead buttons.
"""

import json
import re
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[3]
README_PATHS = [REPOSITORY / "README.md", REPOSITORY / "README.zh-CN.md"]
QUICK_ADD_LABELS = {
    "README.md": ("Add to Feather", "Add to AltStore"),
    "README.zh-CN.md": ("添加到 Feather", "添加到 AltStore"),
}
OFFICIAL_DOWNLOAD_URL = "https://www.floe-agent.com/#download"
SOURCE_URL = "https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json"
# GitHub keeps these schemes in rendered Markdown; anything else is removed.
GITHUB_SAFE_SCHEMES = ("http://", "https://", "mailto:")
ANCHOR_RE = re.compile(r'<a\s+[^>]*href="([^"]+)"[^>]*>(.*?)</a>', re.S)


def anchors(html):
    return [(href.strip(), re.sub(r"<[^>]+>", "", body).strip())
            for href, body in ANCHOR_RE.findall(html)]


class ReadmeSourceLinkTests(unittest.TestCase):
    def test_quick_add_buttons_use_github_safe_targets(self):
        for path in README_PATHS:
            with self.subTest(readme=path.name):
                html = path.read_text(encoding="utf-8")
                found = anchors(html)
                for label in QUICK_ADD_LABELS[path.name]:
                    matches = [href for href, body in found if body == label]
                    self.assertEqual(len(matches), 1,
                                     f"{path.name}: expected exactly one '{label}' button")
                    href = matches[0]
                    self.assertTrue(href.startswith(GITHUB_SAFE_SCHEMES),
                                    f"{path.name}: '{label}' uses a scheme GitHub strips: {href}")
                    self.assertEqual(href, OFFICIAL_DOWNLOAD_URL,
                                     f"{path.name}: '{label}' must open the official quick-add entry")
                # No anchor anywhere in the README may use a scheme GitHub strips.
                for href, _ in found:
                    self.assertTrue(
                        href.startswith(("http://", "https://", "mailto:", "#"))
                        or not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", href),
                        f"{path.name}: link target uses a scheme GitHub strips: {href}",
                    )

    def test_readmes_publish_the_stable_source_url(self):
        for path in README_PATHS:
            with self.subTest(readme=path.name):
                self.assertIn(SOURCE_URL, path.read_text(encoding="utf-8"))

    def test_feed_matches_the_published_source_url_and_is_altstore_compatible(self):
        feed = json.loads((REPOSITORY / "feather.json").read_text(encoding="utf-8"))
        self.assertEqual(feed["sourceURL"], SOURCE_URL)
        self.assertTrue(feed["identifier"])
        self.assertTrue(feed["name"])
        self.assertTrue(feed["apps"], "the feed must publish at least one app")
        for app in feed["apps"]:
            self.assertTrue(app["bundleIdentifier"])
            self.assertTrue(app["versions"], "every app needs a version entry")
            for version in app["versions"]:
                self.assertRegex(version["downloadURL"], r"^https://github\.com/")
                self.assertRegex(version["sha256"], r"^[0-9a-f]{64}$")
                self.assertGreater(version["size"], 0)
                self.assertTrue(version["version"])
                self.assertTrue(version["buildVersion"])

    def test_generator_and_docs_share_the_source_url(self):
        generator = (REPOSITORY / "FloeAgent/scripts/generate_feather_source.py").read_text(encoding="utf-8")
        self.assertIn('SOURCE_URL = f"https://raw.githubusercontent.com/{REPOSITORY}/main/feather.json"',
                      generator)
        docs = (REPOSITORY / "docs/FEATHER_SOURCE.md").read_text(encoding="utf-8")
        self.assertIn(SOURCE_URL, docs)


if __name__ == "__main__":
    unittest.main()
