#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Read the explicit documentation audiences; never discover App help by glob."""
import json
from pathlib import Path
import re

PLATFORMS = frozenset(("ios", "android"))
LOCALES = frozenset(("en", "zh-Hans"))


def load_catalog(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("schemaVersion") != 1 or not isinstance(data.get("documents"), list):
        raise ValueError("unsupported documentation catalog")
    if not 1 <= len(data["documents"]) <= 64:
        raise ValueError("documentation catalog size out of bounds")
    ids, sources = set(), set()
    for entry in data["documents"]:
        if not isinstance(entry, dict):
            raise ValueError("invalid documentation entry")
        identity = entry.get("id", "")
        if not isinstance(identity, str) or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", identity) or identity in ids:
            raise ValueError("invalid or duplicate documentation id")
        ids.add(identity)
        if entry.get("audience") not in PLATFORMS | {"shared"} or type(entry.get("help")) is not bool:
            raise ValueError("documentation requires an explicit audience and help flag")
        translations = entry.get("sources")
        if not isinstance(translations, dict) or not translations or not set(translations) <= LOCALES:
            raise ValueError("invalid documentation locales")
        if entry["help"] and set(translations) != LOCALES:
            raise ValueError("App help requires both locales")
        for source in translations.values():
            if not isinstance(source, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+\.md", source) or ".." in source or source in sources:
                raise ValueError("invalid or duplicate documentation source")
            sources.add(source)
    return data


def select_documents(catalog, platform, *, help_only=False):
    if platform not in PLATFORMS:
        raise ValueError("unknown documentation platform")
    return [entry for entry in catalog["documents"]
            if entry["audience"] in ("shared", platform) and (not help_only or entry["help"])]
