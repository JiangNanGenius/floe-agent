#!/usr/bin/env python3
"""Regenerate scripts/python_bundled_packages.lock.json from PyPI.

For each requested distribution this resolves the newest release that ships a
pure-Python py3-none-any wheel, records the wheel URL and SHA-256, and writes
the lock consumed by install_python_bundled_packages.py. Run this only when
intentionally bumping the bundled preset set; the lock is authoritative and
reviewed like any dependency change.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path

LOCK_PATH = Path(__file__).resolve().parent / "python_bundled_packages.lock.json"

DEFAULT_PACKAGES = [
    "attrs", "beautifulsoup4", "chardet", "click", "defusedxml", "et-xmlfile",
    "feedparser", "filelock", "fonttools", "fpdf2", "html5lib", "humanize",
    "icalendar", "jmespath", "jsonlines", "Markdown", "openpyxl", "packaging",
    "platformdirs", "pypdf", "pyparsing", "pytz", "python-slugify", "six", "feedparser-sgmllib",
    "soupsieve", "sqlparse", "tabulate", "tenacity", "text-unidecode", "tomli",
    "typing-extensions", "vobject", "webencodings", "XlsxWriter",
]


def fetch_json(url: str) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": "floe-agent-pin/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def resolve(package: str) -> dict:
    metadata = fetch_json(f"https://pypi.org/pypi/{package}/json")
    version = metadata["info"]["version"]
    files = metadata.get("releases", {}).get(version, [])
    wheel = next(
        (item for item in files if item.get("filename", "").endswith("-none-any.whl")),
        None,
    )
    if wheel is None:
        raise SystemExit(f"{package}: no py3-none-any wheel for latest release {version}")
    return {
        "name": metadata["info"]["name"],
        "version": version,
        "url": wheel["url"],
        "sha256": wheel["digests"]["sha256"],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("packages", nargs="*", default=DEFAULT_PACKAGES)
    args = parser.parse_args()
    packages = []
    for name in args.packages:
        entry = resolve(name)
        packages.append(entry)
        print(f"{entry['name']}=={entry['version']} {entry['sha256'][:12]}…")
    payload = {
        "schemaVersion": 1,
        "generatedBy": "FloeAgent/scripts/pin_python_bundled_packages.py",
        "packages": packages,
    }
    LOCK_PATH.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(f"wrote {LOCK_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
