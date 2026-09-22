"""Static checks for the README quick-add badges and the Feather feed.

GitHub's Markdown sanitizer strips `href` attributes whose scheme it does not
allow (it keeps `http`, `https` and `mailto`). The top-of-README quick-add
entries therefore cannot use `feather://` or `altstore://` directly. Instead
each README shows two badge images linked to the official site's stable HTTPS
quick-add endpoints (/add/feather and /add/altstore), which attempt the exact
custom-scheme launch on the device and always render a manual/download
fallback. These tests pin that contract, the shared source URL, the badge
assets, and the feed's AltStore-compatible shape so a future edit cannot
silently reintroduce dead buttons.
"""

import json
import re
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[3]
README_PATHS = [REPOSITORY / "README.md", REPOSITORY / "README.zh-CN.md"]
QUICK_ADD_BADGES = {
    "README.md": {
        "alt": "Add to Feather",
        "href": "https://www.floe-agent.com/add/feather",
        "src": "docs/images/badge-add-to-feather.svg",
        "releases_label": "Download releases",
    },
    "README.zh-CN.md": {
        "alt": "添加到 Feather",
        "href": "https://www.floe-agent.com/add/feather",
        "src": "docs/images/badge-add-to-feather.svg",
        "releases_label": "下载发布版本",
    },
}
ALTSTORE_BADGE = {
    "README.md": {"alt": "Add to AltStore", "src": "docs/images/badge-add-to-altstore.svg"},
    "README.zh-CN.md": {"alt": "添加到 AltStore", "src": "docs/images/badge-add-to-altstore.svg"},
}
ALTSTORE_HREF = "https://www.floe-agent.com/add/altstore"
GITHUB_RELEASES_URL = "https://github.com/JiangNanGenius/floe-agent/releases"
DOWNLOAD_PAGE_URL = "https://www.floe-agent.com/#download"
FEATHER_QUICK_ADD_URL = "https://www.floe-agent.com/add/feather"
SOURCE_URL = "https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json"
# GitHub keeps these schemes in rendered Markdown; anything else is removed.
GITHUB_SAFE_SCHEMES = ("http://", "https://", "mailto:")
ANCHOR_RE = re.compile(r'<a\s+[^>]*href="([^"]+)"[^>]*>(.*?)</a>', re.S)
IMG_RE = re.compile(r"<img\s+[^>]*>", re.S)


def anchors(html):
    return [(href.strip(), re.sub(r"<[^>]+>", "", body).strip())
            for href, body in ANCHOR_RE.findall(html)]


def badge_anchor_href(html, alt):
    """Return the href of the anchor that wraps the badge <img> with this alt."""
    for href, body in ANCHOR_RE.findall(html):
        if f'alt="{alt}"' in body:
            return href.strip()
    return None


def badge_img_src(html, alt):
    for tag in IMG_RE.findall(html):
        if f'alt="{alt}"' in tag:
            src = re.search(r'src="([^"]+)"', tag)
            return src.group(1) if src else None
    return None


class ReadmeSourceLinkTests(unittest.TestCase):
    def test_quick_add_badges_link_to_official_https_endpoints(self):
        for path in README_PATHS:
            with self.subTest(readme=path.name):
                html = path.read_text(encoding="utf-8")
                feather = QUICK_ADD_BADGES[path.name]
                altstore = ALTSTORE_BADGE[path.name]
                # Each badge image is wrapped in an anchor whose href is the
                # official HTTPS quick-add endpoint, not a custom scheme.
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

    def test_quick_add_anchors_resolve_to_live_endpoint_paths(self):
        # The endpoints are part of the public website; keep the exact paths
        # pinned so a typo cannot 404 the badges.
        for path in README_PATHS:
            with self.subTest(readme=path.name):
                html = path.read_text(encoding="utf-8")
                for endpoint in (FEATHER_QUICK_ADD_URL, ALTSTORE_HREF):
                    self.assertIn(f'href="{endpoint}"', html)

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
        for endpoint in (FEATHER_QUICK_ADD_URL, ALTSTORE_HREF, DOWNLOAD_PAGE_URL):
            self.assertIn(endpoint, docs)


if __name__ == "__main__":
    unittest.main()
