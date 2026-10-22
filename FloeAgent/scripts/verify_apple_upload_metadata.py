#!/usr/bin/env python3
"""Read-only guard for the shipping iOS 26+/SDK 27 upload metadata.

Uses only the standard library. Checks project inputs and generated resources;
actual device bundles, signed entitlements and Apple acceptance remain separate.
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import sys

FORMATS = "com.apple.developer.nfc.readersession.formats"
PURPOSES = ("NSHealthShareUsageDescription", "NSHealthUpdateUsageDescription", "NFCReaderUsageDescription")


def plain_scalar(value):
    value = value.strip()
    if value.startswith('"'):
        return json.loads(value)
    if value.startswith("'") and value.endswith("'"):
        return value[1:-1].replace("''", "'")
    return value


def problems(root):
    errors = []
    source = (root / "project.yml").read_text(encoding="utf-8")
    entitlements = plistlib.loads((root / "FloeApp/Entitlements/Floe.entitlements").read_bytes())
    info = plistlib.loads((root / "FloeApp/Resources/Info.plist").read_bytes())
    catalog = json.loads((root / "FloeApp/Resources/InfoPlist.xcstrings").read_text(encoding="utf-8"))["strings"]
    # This is the checked-in host's scalar/list layout, not a general YAML parser.
    # Refuse unsupported or duplicate declarations rather than guessing a target.
    blocks = re.findall(r"^        " + re.escape(FORMATS) + r": *\n((?:          - [^\n]+\n)+)", source, re.M)
    formats = [plain_scalar(line.strip()[2:]) for line in blocks[0].splitlines()] if len(blocks) == 1 else None
    if formats != ["TAG"]:
        errors.append("project.yml: NFC formats must be exactly TAG for this shipping SDK baseline")
    if entitlements.get(FORMATS) != ["TAG"]:
        errors.append("Floe.entitlements: NFC formats must be exactly TAG")
    for key in PURPOSES:
        values = re.findall(r"^        " + re.escape(key) + r": ([^\n]+)$", source, re.M)
        value = plain_scalar(values[0]) if len(values) == 1 else None
        if not isinstance(value, str) or not value.strip() or value == key:
            errors.append("project.yml: missing or ambiguous purpose " + key)
        if not isinstance(info.get(key), str) or not info[key].strip() or info[key] != value:
            errors.append("Info.plist: missing or divergent purpose " + key)
        for locale in ("en", "zh-Hans"):
            unit = catalog.get(key, {}).get("localizations", {}).get(locale, {}).get("stringUnit", {})
            localized = unit.get("value")
            if not isinstance(localized, str) or not localized.strip() or localized == key or unit.get("state") != "translated":
                errors.append("InfoPlist catalog: missing translated " + locale + "/" + key)
            elif locale == "en" and localized != value:
                errors.append("InfoPlist catalog: English source mismatch " + key)
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        errors = problems(args.source_root)
    except (OSError, ValueError, TypeError, KeyError) as error:
        print("Upload metadata unreadable: " + str(error), file=sys.stderr)
        return 1
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Apple upload metadata: TAG source/generated formats and translated Health/NFC purposes match")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
