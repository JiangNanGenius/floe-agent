#!/usr/bin/env python3
"""Harvest existing zh->en translation pairs from the codebase.

Sources:
  - translation-map.json (coordinator hand translations, 254)
  - inline bilingual helpers: X.t("zh", "en"), canvasLocalized(...),
    engineeringReviewText(...), say('zh','en') in JS
  - current catalog zh-Hans value -> en value
Output: JSON dict zh -> en on stdout.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REPO = ROOT  # .../FloeAgent


def load_translation_map():
    p = "/Volumes/TECLAST/IOS AI AGENT/Local/Artifacts/floe-promo-en/evidence/translation-map.json"
    if os.path.exists(p):
        return json.load(open(p))
    return {}


def load_catalog_pairs():
    cat = json.load(open(os.path.join(REPO, "FloeApp/Resources/Localizable.xcstrings")))
    pairs = {}
    for key, entry in cat["strings"].items():
        loc = entry.get("localizations", {})
        zh = loc.get("zh-Hans", {}).get("stringUnit", {}).get("value")
        en = loc.get("en", {}).get("stringUnit", {}).get("value")
        if zh and en and re.search(r"[一-鿿]", zh):
            pairs.setdefault(zh, en)
    return pairs


SWIFT_HELPERS = (
    "WorkbenchText.t", "IDELanguageRunText.t", "OfficeInkText.t",
    "FloeLocalized.t", "BackgroundExecutionPreferenceText.t",
    "canvasLocalized", "engineeringReviewText",
)

# Match  t("zh", "en") / t("zh","en") allowing multiline; zh first.
CALL_RE = re.compile(
    r"(?:" + "|".join(re.escape(h.split(".")[-1]) for h in SWIFT_HELPERS) + r")\(\s*"
    r"(@\"(?:[^\"\\]|\\.)*\"|\"(?:[^\"\\]|\\.)*\")\s*,\s*"
    r"(@\"(?:[^\"\\]|\\.)*\"|\"(?:[^\"\\]|\\.)*\")\s*[\),]",
    re.S)

# free enum form: IDENativeTextText.t(
NATIVE_RE = re.compile(
    r"IDENativeTextText\.t\(\s*\"((?:[^\"\\]|\\.)*)\"\s*,\s*\"((?:[^\"\\]|\\.)*)\"\s*\)",
    re.S)

JS_SAY_RE = re.compile(r"say\(\s*'([^']*[一-鿿][^']*)'\s*,\s*'([^']*)'\s*\)")
JS_T_OBJ_RE = re.compile(r"\{\s*zh:\s*'([^']*)'\s*,\s*en:\s*'([^']*)'\s*\}")


def unescape_swift(s):
    return (s.replace("\\n", "\n").replace('\\"', '"')
             .replace("\\\\", "\\"))


def harvest_swift():
    pairs = {}
    out = subprocess.run(
        ["rg", "-l", r"[一-鿿]", "-g", "*.swift",
         os.path.join(REPO, "FloeApp"), os.path.join(REPO, "Sources")],
        capture_output=True, text=True).stdout.splitlines()
    for path in out:
        src = open(path, encoding="utf-8").read()
        for m in CALL_RE.finditer(src):
            zh = unescape_swift(m.group(1).strip('"'))
            en = unescape_swift(m.group(2).strip('"'))
            if re.search(r"[一-鿿]", zh):
                pairs.setdefault(zh, en)
        for m in NATIVE_RE.finditer(src):
            pairs.setdefault(m.group(1), m.group(2))
    return pairs


def harvest_js():
    pairs = {}
    base = os.path.join(REPO, "FloeApp/Resources/EngineeringViewers")
    if not os.path.isdir(base):
        return pairs
    for fn in os.listdir(base):
        if not fn.endswith(".js"):
            continue
        src = open(os.path.join(base, fn), encoding="utf-8").read()
        for m in JS_SAY_RE.finditer(src):
            pairs.setdefault(m.group(1), m.group(2))
        for m in JS_T_OBJ_RE.finditer(src):
            pairs.setdefault(m.group(1), m.group(2))
    return pairs


def main():
    merged = {}
    report = {}
    for name, fn in [
        ("catalog", load_catalog_pairs),
        ("translation_map", load_translation_map),
        ("swift_inline", harvest_swift),
        ("js_inline", harvest_js),
    ]:
        part = fn()
        report[name] = len(part)
        for k, v in part.items():
            merged.setdefault(k, v)  # catalog (first) wins over other seeds
    report["merged_unique"] = len(merged)
    json.dump(merged, sys.stdout, ensure_ascii=False, indent=1, sort_keys=True)
    sys.stderr.write(json.dumps(report) + "\n")


if __name__ == "__main__":
    main()
