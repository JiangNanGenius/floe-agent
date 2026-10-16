"""Check bilingual quick-add links, upstream app badges and the shared feed."""

import json
from html import unescape
from urllib.parse import parse_qs, urlparse
import re
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[3]
README_PATHS = [REPOSITORY / "README.md", REPOSITORY / "README.zh-CN.md"]
QUICK_ADD_BADGES = {
    "README.md": {
        "alt": "Add to Feather",
        "href": "https://altdirect.app/?url=https%3A%2F%2Fraw.githubusercontent.com%2FJiangNanGenius%2Ffloe-agent%2Fmain%2Ffeather.json&r=feather",
        "src": "docs/images/badge-add-to-feather.png",
        "releases_label": "Download releases",
    },
    "README.zh-CN.md": {
        "alt": "添加到 Feather",
        "href": "https://altdirect.app/?url=https%3A%2F%2Fraw.githubusercontent.com%2FJiangNanGenius%2Ffloe-agent%2Fmain%2Ffeather.json&r=feather",
        "src": "docs/images/badge-add-to-feather.png",
        "releases_label": "下载发布版本",
    },
}
ALTSTORE_BADGE = {
    "README.md": {"alt": "Add to AltStore", "src": "docs/images/badge-add-to-altstore.png"},
    "README.zh-CN.md": {"alt": "添加到 AltStore", "src": "docs/images/badge-add-to-altstore.png"},
}
ALTSTORE_HREF = "https://altdirect.app/?url=https%3A%2F%2Fraw.githubusercontent.com%2FJiangNanGenius%2Ffloe-agent%2Fmain%2Ffeather.json&r=altstore"
GITHUB_RELEASES_URL = "https://github.com/JiangNanGenius/floe-agent/releases"
DOWNLOAD_PAGE_URL = "https://www.floe-agent.com/#download"
FEATHER_QUICK_ADD_URL = "https://altdirect.app/?url=https%3A%2F%2Fraw.githubusercontent.com%2FJiangNanGenius%2Ffloe-agent%2Fmain%2Ffeather.json&r=feather"
SOURCE_URL = "https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json"
# GitHub keeps these schemes in rendered Markdown; anything else is removed.
GITHUB_SAFE_SCHEMES = ("http://", "https://", "mailto:")
ANCHOR_RE = re.compile(r'<a\s+[^>]*href="([^"]+)"[^>]*>(.*?)</a>', re.S)
IMG_RE = re.compile(r"<img\s+[^>]*>", re.S)


def anchors(html):
    return [(unescape(href.strip()), re.sub(r"<[^>]+>", "", body).strip())
            for href, body in ANCHOR_RE.findall(html)]


def badge_anchor_href(html, alt):
    """Return the href of the anchor that wraps the badge <img> with this alt."""
    for href, body in ANCHOR_RE.findall(html):
        if f'alt="{alt}"' in body:
            return unescape(href.strip())
    return None


def badge_img_src(html, alt):
    for tag in IMG_RE.findall(html):
        if f'alt="{alt}"' in tag:
            src = re.search(r'src="([^"]+)"', tag)
            return src.group(1) if src else None
    return None


class ReadmeSourceLinkTests(unittest.TestCase):
    def test_quick_add_icons_link_to_app_specific_redirects(self):
        for path in README_PATHS:
            with self.subTest(readme=path.name):
                html = path.read_text(encoding="utf-8")
                feather = QUICK_ADD_BADGES[path.name]
                altstore = ALTSTORE_BADGE[path.name]
                # Each badge image is wrapped in an anchor whose href is the
                # app-specific HTTPS redirect, not a custom scheme.
                self.assertEqual(badge_anchor_href(html, feather["alt"]), feather["href"],
                                 f"{path.name}: Feather badge must link to its HTTPS endpoint")
                self.assertEqual(badge_anchor_href(html, altstore["alt"]), ALTSTORE_HREF,
                                 f"{path.name}: AltStore badge must link to its HTTPS endpoint")
                self.assertEqual(badge_img_src(html, feather["alt"]), feather["src"],
                                 f"{path.name}: Feather badge must use the local badge image")
                self.assertEqual(badge_img_src(html, altstore["alt"]), altstore["src"],
                                 f"{path.name}: AltStore badge must use the local badge image")
                # The badge assets must exist in the repository.
                self.assertTrue((REPOSITORY / feather["src"]).is_file(),
                                f"{path.name}: missing badge asset {feather['src']}")
                self.assertTrue((REPOSITORY / altstore["src"]).is_file(),
                                f"{path.name}: missing badge asset {altstore['src']}")
                # The plain release download entry stays a separate text link.
                found = anchors(html)
                releases = [href for href, body in found if body == feather["releases_label"]]
                self.assertEqual(releases, [GITHUB_RELEASES_URL],
                                 f"{path.name}: release download link must stay separate")
                # No anchor anywhere in the README may use a scheme GitHub strips.
                for href, _ in found:
                    self.assertTrue(
                        href.startswith(("http://", "https://", "mailto:", "#"))
                        or not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", href),
                        f"{path.name}: link target uses a scheme GitHub strips: {href}",
                    )

    def test_quick_add_anchors_are_present_in_both_readmes(self):
        # The endpoints are part of the public website; keep the exact paths
        # pinned so a typo cannot 404 the badges.
        for path in README_PATHS:
            with self.subTest(readme=path.name):
                html = path.read_text(encoding="utf-8")
                for endpoint in (FEATHER_QUICK_ADD_URL, ALTSTORE_HREF):
                    self.assertIn(endpoint, [href for href, _ in anchors(html)])

    def test_redirects_select_the_correct_app_and_exact_source(self):
        for app, endpoint in (("feather", FEATHER_QUICK_ADD_URL), ("altstore", ALTSTORE_HREF)):
            parsed = urlparse(endpoint)
            self.assertEqual(parsed.scheme, "https")
            self.assertEqual(parsed.netloc, "altdirect.app")
            self.assertEqual(parse_qs(parsed.query), {"url": [SOURCE_URL], "r": [app]})

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
        for endpoint in ("https://www.floe-agent.com/add/feather", "https://www.floe-agent.com/add/altstore", DOWNLOAD_PAGE_URL):
            self.assertIn(endpoint, docs)


if __name__ == "__main__":
    unittest.main()
