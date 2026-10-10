#!/usr/bin/env python3
"""Generate semantic catalog keys and apply source rewrites.

Inputs (all in /tmp unless --out given):
  l10n-plan.json          keep occurrences + classification
  l10n-seeds.json         zh -> en harvested from existing sources
  /tmp/l10n-tr/*.json     curated translations (batch files)
  Localizable.xcstrings   existing catalog (for key reuse)

Outputs:
  <out>/Localizable.xcstrings.new   merged catalog (dotted keys only)
  <out>/key-map.json                canonical zh -> key
  <out>/rewrite-report.json         per-file applied/skipped edits
Source files are rewritten in place (idempotent via --apply; dry-run default
prints counts).
"""
import argparse
import collections
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOG = os.path.join(REPO, "FloeApp/Resources/Localizable.xcstrings")

# Feature prefix by path fragment.
PREFIX_BY_DIR = {
    "App": "app", "Home": "home", "Chat": "chat", "Conversations": "conversations",
    "Notes": "notes", "Workspace": "workspace", "Workbench": "workbench",
    "Settings": "settings", "Providers": "providers", "Media": "media",
    "Memory": "memory", "Hosts": "hosts", "Skills": "skills", "Voice": "voice",
    "Browser": "browser", "Canvas": "canvas", "More": "more", "Files": "files",
    "Execution": "execution", "Platform": "platform", "Remote": "remote",
    "Shortcuts": "shortcuts", "Terminal": "terminal", "Shell": "shell",
    "VNC": "vnc", "Apple": "apple", "ScreenShare": "screenshare",
    "Design": "design", "Entitlements": "entitlements", "Fonts": "fonts",
    "Onboarding": "onboarding", "FloeWidgets": "widget",
    "FloeShare": "share", "FloeScreenShare": "screenshare",
}
PREFIX_BY_MODULE = {
    "FloeCore": "core", "FloeModels": "models", "FloeProviders": "providers",
    "FloeTools": "tools", "FloeAgentRuntime": "runtime", "FloeSkills": "skills",
    "FloeSecurity": "security", "FloePersistence": "persistence",
    "FloeExecution": "execution", "FloeWorkspace": "workspace",
    "FloeEnvironments": "environments", "FloePackages": "packages",
    "FloeNotes": "notes", "FloeMedia": "media", "FloeWorkbench": "workbench",
    "FloeLocalModels": "localmodels", "FloeLocalModelCatalog": "localmodels",
    "FloeDocuments": "documents", "FloeSync": "sync", "FloeSyncCore": "sync",
    "FloeSSH": "ssh", "FloeVNC": "vnc", "FloeGit": "git",
    "FloeMarkdown": "markdown", "FloeImages": "images",
}

SWIFTUI_KEYED = "swiftui_keyed"
PLAIN_KINDS = {"plain_string", "plain_interp", "swiftui_interp"}
REVIEW_ALLOWED_DECLS = {
    "errorDescription", "failureReason", "recoverySuggestion", "helpAnchor",
    "localizedTitle", "localizedDescription", "approvalModeTitle", "explanation",
    "title", "subtitle", "placeholder", "label", "providerMessage", "displayName",
    "sendAccessibilityLabel", "accessibilityLabel", "body", "detail", "progress",
    "headline", "message", "statusText", "shortTitle", "summary", "localizedStatus",
    "progressText", "hint", "footer", "header", "statusTitle", "statusLabel",
    "surfaceLabel", "manualControlTitle", "continuationTitle", "voiceCaptureTitle",
    "unavailableMessage", "interactionHint", "canvasVoiceError", "scopeTitle",
    "accessibilityName", "colorLabel", "sourceName", "stateTitle", "warning",
    "outcome", "role", "type", "scope", "named", "quickOrganize",
}
REVIEW_ALLOWED_CALLS = {
    "FloeError.validationFailed", "FloeError.invalidConfiguration",
    "FloeError.syncUnavailable", "FloeError.internalError",
    "NoteError.invalidOperation", "NoteError.invalidDocument",
    "BackupError.corrupt", "BackupError.sourceFile",
    "RemoteImageError.requestFailed",
    "StorageUsageRow", "SlashAction", "BackgroundWorkSnapshot",
    "CanvasPatchOperation", "ManagementRow", "CreativeAssetRecord",
    "OfficeOpeningWarning", "NSError", "TaskSchedule",
}
# Declarations/callees whose Chinese values are matching data, AI prompts or
# protocol identifiers. These must never be routed through the catalog.
REVIEW_EXCLUDED_DECL_RE = re.compile(
    r"(markers?$|Markers$|synonym|alias|prefix|denial|Terms?$|chinese|CapabilityGroups"
    r"|intent|Intent|nonSecretValues|quotedSpan|requestsAction|requestsExplicit"
    r"|requestsInventory|asksFor|explanatory|negation|prompt|Prompt|instruction|Instruction"
    r"|canvasAgentContext|stageSelection|researchGoal|toolDescription|namedTool"
    r"|futureMarkers|actionMarkers|enumCase|heavyRuntimeConflictMessage"
    r"|titleZH|titleEN)")

REVIEW_ALLOWED_LABELS = {
    "title", "message", "subtitle", "label", "placeholder", "prompt", "text",
    "reason", "headline", "detail", "detailZh", "progress", "progressText",
    "issue", "fallbackTitle", "shortTitle", "summary", "statusText", "name",
    "accessibilityLabel", "localizedTitle",
}


def norm(t):
    return re.sub(r"\s+", " ", t).strip()


def swift_unescape(s):
    """Decode standard Swift escapes so catalog values hold real characters."""
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n == "n":
                out.append("\n"); i += 2; continue
            if n == "t":
                out.append("\t"); i += 2; continue
            if n == "r":
                out.append("\r"); i += 2; continue
            if n == "\"":
                out.append('"'); i += 2; continue
            if n == "'":
                out.append("'"); i += 2; continue
            if n == "\\":
                out.append("\\"); i += 2; continue
            if n == "0":
                out.append("\0"); i += 2; continue
            if n == "u" and i + 2 < len(s) and s[i + 2] == "{":
                j = s.find("}", i + 3)
                if j != -1:
                    try:
                        out.append(chr(int(s[i + 3:j], 16)))
                        i = j + 1
                        continue
                    except ValueError:
                        pass
        out.append(c); i += 1
    return "".join(out)


def slug(en, max_words=6):
    s = en.lower()
    s = re.sub(r"%[.0-9@lldf]+", "", s)
    words = re.findall(r"[a-z0-9]+", s)
    return "_".join(words[:max_words]) or "text"


def prefix_for(path):
    parts = path.split("/")
    if parts[0] == "Sources" and len(parts) > 1:
        return PREFIX_BY_MODULE.get(parts[1], "core")
    if parts[0] == "FloeApp" and len(parts) > 1:
        return PREFIX_BY_DIR.get(parts[1], "app")
    if parts[0].startswith("Floe"):
        return PREFIX_BY_DIR.get(parts[0], "app")
    return "app"


def file_slug(path):
    name = os.path.basename(path).replace(".swift", "")
    s = re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()
    s = re.sub(r"_+", "_", s)
    return s


def should_rewrite(o):
    # App Intents metadata is installed from a template by apply_special with
    # static catalog-key literals; never migrate it generically.
    if o["file"].endswith("FloeApp/Shortcuts/FloeShortcuts.swift"):
        return None
    k = o["kind"]
    if k == SWIFTUI_KEYED and not o["interpolated"]:
        return "keyed"
    if k in PLAIN_KINDS:
        return "lookup"
    # Policy inversion: any review-classified string that survived the
    # triage in plan.py is user-facing unless its declaration/callee is a
    # known data/prompt/protocol surface.
    # Pure separators / punctuation are layout glyphs, not translatable prose.
    if re.sub(r"[\s·.,:;/\\%@0-9A-Za-z'\"()\-→↑↓、，。；：！？#*]+", "", o["text"]).strip() == "":
        return None
    decl = o.get("declName") or ""
    if REVIEW_EXCLUDED_DECL_RE.search(decl):
        return None
    bare_review = o.get("bareCallName") or ""
    if REVIEW_EXCLUDED_DECL_RE.search(bare_review):
        return None
    if k in ("review", "review_callarg", "review_labeled"):
        return "lookup"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--out", default="/tmp/l10n-out")
    cli = ap.parse_args()
    os.makedirs(cli.out, exist_ok=True)

    plan = json.load(open("/tmp/l10n-plan.json"))
    seeds = json.load(open("/tmp/l10n-seeds.json"))
    curated = {}
    curated_dirs = [
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "translations"),
        "/tmp/l10n-tr",
    ]
    for directory in curated_dirs:
        if not os.path.isdir(directory):
            continue
        for fn in sorted(os.listdir(directory)):
            if not fn.endswith(".json"):
                continue
            curated.update(json.load(open(os.path.join(directory, fn))))
    # Normalize consistently with canonical_norm: unescape first (so real
    # newlines appear), then collapse whitespace for matching.
    curated = {norm(swift_unescape(k)): swift_unescape(v)
               for k, v in curated.items()}
    seeds = {norm(swift_unescape(k)): swift_unescape(v)
             for k, v in seeds.items()}

    catalog = json.load(open(CATALOG))
    strings = catalog["strings"]

    # zh -> unique existing dotted key (reuse only when unambiguous).
    zh2keys = collections.defaultdict(set)
    for key, entry in strings.items():
        if "." not in key:
            continue
        zh = entry.get("localizations", {}).get("zh-Hans", {}) \
            .get("stringUnit", {}).get("value")
        if zh:
            zh2keys[norm(zh)].add(key)
    unique_reuse = {z: next(iter(ks)) for z, ks in zh2keys.items() if len(ks) == 1}

    def english_for(template):
        t = norm(template)
        if t in curated:
            return curated[t]
        return seeds.get(t)

    # Assign keys per canonical template.
    key_map = {}          # canonical zh template -> catalog key
    used_keys = set(k for k in strings if "." in k)
    new_entries = {}
    skipped_residual = []

    # Group kept occurrences by template for prefix voting.
    template_files = collections.defaultdict(collections.Counter)
    raw_template = {}
    for o in plan["keep"]:
        tpl = canonical_norm(o)
        template_files[tpl][(prefix_for(o["file"]), file_slug(o["file"]))] += 1
        raw_template.setdefault(tpl, canonical(o))

    for tpl, files in template_files.items():
        en = english_for(tpl)
        if en is None:
            skipped_residual.append(("no-translation", tpl))
            continue
        if tpl in unique_reuse:
            key_map[tpl] = unique_reuse[tpl]
            continue
        (pfx, fslug), _n = files.most_common(1)[0]
        base = f"{pfx}.{fslug}.{slug(en)}"
        key = base
        i = 2
        while key in used_keys:
            key = f"{base}_{i}"
            i += 1
        used_keys.add(key)
        key_map[tpl] = key
        new_entries[key] = (en, raw_template.get(tpl, tpl))

    # Build per-file offset maps. Outer literals are rewritten by the Swift
    # AST rewriter; nested fallback literals (inside an outer interpolation)
    # are translated as arguments, so they appear in the same map and the
    # rewriter recurses into them. Byte ranges never overlap because the AST
    # rewriter rebuilds each targeted node.
    by_file = collections.defaultdict(dict)
    file_meta = collections.defaultdict(list)
    not_rewritten = []

    planned = []
    for o in plan["keep"]:
        mode = should_rewrite(o)
        key = key_map.get(canonical_norm(o)) if mode else None
        if mode is None or key is None:
            not_rewritten.append(o)
        else:
            planned.append((o, key, mode))

    outer_intervals = collections.defaultdict(list)
    for o, _k, _m in planned:
        if o["interpolated"]:
            outer_intervals[o["file"]].append(
                (o["offset"], o["offset"] + o["length"]))

    def is_nested(o):
        s, e = o["offset"], o["offset"] + o["length"]
        return any(s2 <= s and e <= e2 and (s2, e2) != (s, e)
                   for s2, e2 in outer_intervals.get(o["file"], []))

    for o, key, mode in planned:
        # Nested CJK literals are value expressions: always emit as lookup.
        effective_mode = "lookup" if is_nested(o) else mode
        by_file[o["file"]][str(o["offset"])] = {
            "key": key, "mode": effective_mode}
        file_meta[o["file"]].append((o, key, effective_mode))

    map_dir = os.path.join(cli.out, "maps")
    if cli.apply:
        os.makedirs(map_dir, exist_ok=True)
        for path, mapping in by_file.items():
            outp = os.path.join(map_dir, path.replace("/", "__") + ".json")
            json.dump(mapping, open(outp, "w"), ensure_ascii=False)

    report = collections.defaultdict(lambda: {"applied": 0, "lookup": 0,
                                              "keyed": 0})
    for path, items in file_meta.items():
        for _o, _key, mode in items:
            report[path]["applied"] += 1
            bucket = mode if mode in ("lookup", "keyed") else "lookup"
            report[path][bucket] += 1

    # Build merged catalog: remove non-dotted keys; keep dotted, add new.
    merged = {k: v for k, v in strings.items() if "." in k}
    for key, (en, zh) in new_entries.items():
        merged[key] = {
            "extractionState": "manual",
            "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": en}},
                "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}},
            },
        }
    out_cat = dict(catalog)
    out_cat["strings"] = dict(sorted(merged.items()))
    cat_out = os.path.join(cli.out, "Localizable.xcstrings")
    if cli.apply:
        json.dump(out_cat, open(cat_out, "w", encoding="utf-8"),
                  ensure_ascii=False, indent=2)
        json.dump(key_map, open(os.path.join(cli.out, "key-map.json"), "w"),
                  ensure_ascii=False, indent=1)

    # Residual report.
    res = collections.Counter((o["kind"], o.get("declName"))
                              for o in not_rewritten)
    summary = {
        "templates": len(template_files),
        "keys_reused": sum(1 for k in key_map.values() if k in strings),
        "new_keys": len(new_entries),
        "files_touched": len(by_file),
        "edits_applied": sum(r["applied"] for r in report.values()),
        "edits_keyed": sum(r["keyed"] for r in report.values()),
        "edits_lookup": sum(r["lookup"] for r in report.values()),
        "occurrences_not_rewritten": len(not_rewritten),
        "residual_top": res.most_common(40),
    }
    json.dump({"summary": summary,
               "files": {k: dict(v) for k, v in report.items()},
               "residual": not_rewritten},
              open(os.path.join(cli.out, "rewrite-report.json"), "w"),
              ensure_ascii=False, indent=1)
    print(json.dumps(summary, ensure_ascii=False, indent=1))


def canonical(o):
    """Decoded template (escapes resolved), preserving newlines/tabs."""
    if not o["interpolated"]:
        return o["text"]
    return "".join(s["value"] if s["kind"] == "text" else "%@"
                   for s in o["segments"])


def canonical_norm(o):
    """Whitespace-collapsed template used for dictionary matching only."""
    return norm(canonical(o))


if __name__ == "__main__":
    main()
