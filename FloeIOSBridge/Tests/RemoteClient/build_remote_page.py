#!/usr/bin/env python3
"""Build Resources/BridgeRemote/REMOTE.html from the checked-in template.

The remote page must stay a single self-contained HTML file (the canonical
Bridge HTTP surface only serves the page at GET /remote; there is no generic
static-asset route). CSP hashes therefore have to be computed from the exact
inline scripts/style that ship. This script injects:

  * the retained Floe Bridge icon as a data: PNG (a mechanical 180x180
    downscale of Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png; no new
    artwork),
  * the SHA-256 CSP hashes for the two inline scripts and the inline style,
  * the page/version notice.

Run it from the repository root or from anywhere; paths are derived from this
file. `--check` verifies the checked-in HTML is current without rewriting it.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
PROJECT = HERE.parent.parent
TEMPLATE = HERE / "remote_page.src.html"
OUTPUT = PROJECT / "Resources" / "BridgeRemote" / "REMOTE.html"
ICON_SOURCE = HERE / "fixtures" / "floe-bridge-180.png"
PAGE_VERSION = "1.0.0"

STYLE_RE = re.compile(r"<style>\n(.*?)\n</style>", re.S)
SCRIPT_RE = re.compile(r"<script id=\"(floe-core|floe-ui)\">\n(.*?)\n</script>", re.S)


def csp_hash(data: bytes) -> str:
    return "sha256-" + base64.b64encode(hashlib.sha256(data).digest()).decode("ascii")


def icon_data_uri() -> str:
    source = ICON_SOURCE.read_bytes()
    if not source.startswith(b"\x89PNG\r\n\x1a\n"):
        raise SystemExit("selected app icon is not a PNG")
    print("icon source sha256: %s" % hashlib.sha256(source).hexdigest(), file=sys.stderr)
    return "data:image/png;base64," + base64.b64encode(source).decode("ascii")


def build(template: str) -> str:
    style_match = STYLE_RE.search(template)
    if not style_match:
        raise SystemExit("template has no <style> block")
    scripts = {name: body for name, body in SCRIPT_RE.findall(template)}
    if set(scripts) != {"floe-core", "floe-ui"}:
        raise SystemExit("template must contain exactly the floe-core and floe-ui scripts")
    # CSP hashes cover the element text, including the newlines that follow
    # the opening tag and precede the closing tag.
    style_hash = csp_hash(("\n" + style_match.group(1) + "\n").encode("utf-8"))
    core_hash = csp_hash(("\n" + scripts["floe-core"] + "\n").encode("utf-8"))
    ui_hash = csp_hash(("\n" + scripts["floe-ui"] + "\n").encode("utf-8"))

    page = template
    page = page.replace("__CSP_STYLE_HASH__", style_hash)
    page = page.replace("__CSP_CORE_HASH__", core_hash)
    page = page.replace("__CSP_UI_HASH__", ui_hash)
    page = page.replace("__ICON_DATA_URI__", icon_data_uri())
    page = page.replace("__PAGE_VERSION__", PAGE_VERSION)
    if "__" in page and "CSP_" in page:
        raise SystemExit("unreplaced CSP placeholder remains")
    if "__ICON_DATA_URI__" in page or "__PAGE_VERSION__" in page:
        raise SystemExit("unreplaced template placeholder remains")
    return page


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="verify the checked-in page is current")
    args = ap.parse_args()

    template = TEMPLATE.read_text(encoding="utf-8")
    page = build(template)
    if args.check:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current != page:
            print("REMOTE.html is stale; run %s" % (HERE / "build_remote_page.py"), file=sys.stderr)
            return 1
        print("REMOTE.html is current (%d bytes)" % len(page.encode("utf-8")))
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(page, encoding="utf-8")
    print("wrote %s (%d bytes)" % (OUTPUT, len(page.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
