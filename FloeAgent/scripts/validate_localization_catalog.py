#!/usr/bin/env python3
"""Check Localizable.xcstrings completeness without building the app.

This mirrors the checks in
FloeAgent/Tests/FloeCoreTests/LocalizationCompletenessTests.swift so an
unnamespaced, missing or empty bilingual entry fails release preflight before
any build starts, instead of surfacing in module tests after a full compile.
Standard library only.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

LOCALES = ("en", "zh-Hans")
DEFAULT_CATALOG = Path("FloeApp/Resources/Localizable.xcstrings")


def _blank(value: object) -> bool:
    return not isinstance(value, str) or not value.strip()


def check_catalog(path: Path) -> tuple[int, list[str]]:
    """Return (entry count, problems) for a string catalog.

    An empty problem list means the catalog is complete: valid non-empty JSON,
    dotted key namespaces, and non-empty en/zh-Hans stringUnit values.
    """
    if not path.exists():
        return 0, [f"catalog missing: {path}"]
    if not path.is_file():
        return 0, [f"catalog is not a file: {path}"]
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as error:
        return 0, [f"catalog unreadable: {path}: {error}"]
    try:
        catalog = json.loads(raw)
    except json.JSONDecodeError as error:
        return 0, [f"catalog is not valid JSON: {error}"]
    if not isinstance(catalog, dict):
        return 0, ["catalog root must be a JSON object"]
    strings = catalog.get("strings")
    if not isinstance(strings, dict):
        return 0, ["catalog 'strings' must be a JSON object"]
    if not strings:
        return 0, ["catalog is empty: 'strings' has no entries"]

    problems: list[str] = []
    for key in strings:
        if "." not in key:
            problems.append(f"non-namespaced key: {key!r}")
    for key, entry in strings.items():
        localizations = entry.get("localizations") if isinstance(entry, dict) else None
        if not isinstance(localizations, dict):
            problems.append(f"{key}: no localizations")
            continue
        for locale in LOCALES:
            localization = localizations.get(locale)
            unit = localization.get("stringUnit") if isinstance(localization, dict) else None
            value = unit.get("value") if isinstance(unit, dict) else None
            if value is None:
                problems.append(f"{key}: missing {locale}")
            elif _blank(value):
                problems.append(f"{key}: {locale} empty")
    return len(strings), problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "catalog",
        nargs="?",
        type=Path,
        default=DEFAULT_CATALOG,
        help="path to Localizable.xcstrings (default: %(default)s)",
    )
    args = parser.parse_args(argv)
    count, problems = check_catalog(args.catalog)
    if problems:
        print(f"error: localization catalog incomplete: {args.catalog}", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    print(
        f"localization catalog OK: {count} entries, dotted namespaces, "
        "en + zh-Hans complete"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
