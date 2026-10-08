#!/usr/bin/env python3
"""Plan the localization migration.

Reads the extractor JSON and the seed dictionary, classifies occurrences into
skip vs localize buckets, computes unique zh templates (interpolations
normalized to %@), reports seed coverage, and writes:
  /tmp/l10n-plan.json   (machine-readable)
"""
import json
import os
import re
import sys
from collections import Counter, defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Files that are entirely non-UI (NLU tables, prompts, diagnostics fixtures).
SKIP_FILE_PATTERNS = [
    r"FloeTools/ToolCapabilityGroups\.swift$",
    r"FloeTools/ToolAliasTable\.swift$",
    r"FloeSecurity/ApprovalPolicy\.swift$",
    r"FloeSecurity/ApprovalDecisionParser\.swift$",
    r"LocalModelToolPolicy\.swift$",
    r"ActionClaimGate\.swift$",
]

# Decl/property names that hold NLU keyword data (matching content, not UI).
NLU_DECLS = {
    "synonyms", "componentSynonyms", "intentPrefixes", "mediaTerms", "aliases",
    "denials", "namedToolNegationMarkers", "chineseObjectMarkers", "actionMarkers",
    "namedToolExplanatoryMarkers", "futureMarkers", "liveWebIntentTerms",
    "namedToolQuestionMarkers", "markers", "chinese", "chineseVerbs",
    "intentKeywords", "negationMarkers", "questionMarkers", "explanatoryMarkers",
}

# Declarations that build AI prompts / tool protocol descriptions. These are
# not user-facing UI and must stay untranslated by design.
PROMPT_DECLS = {
    "prompt", "buildPrompt", "toolDescription", "researchGoal",
    "legacyAssistantBootstrap", "stageSelection", "systemPrompt",
    "foregroundDeferredEvent",
}

# Decl names that are user-facing even though review.
USER_FACING_DECLS = {
    "errorDescription", "failureReason", "recoverySuggestion", "helpAnchor",
    "localizedTitle", "localizedDescription", "approvalModeTitle", "explanation",
    "title", "subtitle", "placeholder", "label", "providerMessage", "displayName",
    "sendAccessibilityLabel", "accessibilityLabel", "body", "detail", "progress",
    "outcome", "headline", "message", "statusText", "shortTitle", "summary",
    "localizedStatus", "progressText", "hint", "footer", "header",
}

LOGGING_CALL_HINTS = ("logger", "Logger", "log.", "os_log", "print", "debugPrint",
                      "NSLog", "assertion", "precondition", "fatalError",
                      "FloeLogger", "record(")


def normalize_template(text):
    """Collapse whitespace; return cleaned zh template."""
    return re.sub(r"\s+", " ", text).strip()


def canonical_template(o):
    """Build zh template with %@ placeholders from AST segments."""
    if not o.get("interpolated"):
        return normalize_template(o["text"])
    parts = []
    for seg in o.get("segments", []):
        if seg["kind"] == "text":
            parts.append(seg["value"])
        else:
            parts.append("%@")
    return normalize_template("".join(parts))


def is_logging(o):
    cn = o.get("bareCallName") or o.get("callName") or ""
    if any(h in cn for h in LOGGING_CALL_HINTS):
        return True
    return False


FIXTURE_FILE_RE = re.compile(
    r"(Fixture|Probe|Preview|Demo|Mock|Fake|Stub|Sample|TestHarness)", re.I)

# Regex / pattern / non-prose literals.
REGEX_HINTS = ("(?<", "(?i", "(?s", "[^", "\\p{", "\\d", "\\s", "\\w",
               ".*", ".+", "\\b", "?:", "\\r", "\\n(?![a-zA-Z])")


def is_pattern_literal(text, o):
    t = text
    if "(?" in t and ("[" in t or "\\" in t):
        return True
    if re.search(r"\[\^|\\p\{|\(\?[is<]!?", t):
        return True
    if t.startswith("(?") or t.startswith("^") or t.endswith("$"):
        return True
    # SQL fragments
    if re.search(r"\bSELECT\b.+\bFROM\b|\bINSERT\b|\bCREATE TABLE\b", t, re.I):
        return True
    # JSON payloads (protocol data, not UI prose).
    if t.lstrip().startswith('{"') and '":"' in t.replace(" ", ""):
        return True
    return False


# Call sites that construct data payloads, not UI.
DATA_CALL_HINTS = (
    "NSPredicate", "NSRegularExpression", "Regex", "matches", "contains(",
    "hasPrefix", "hasSuffix", "containsAny", "split", "range(of",
    "localizedCaseInsensitiveContains", "folding",
)


def should_skip(o):
    path = o["file"]
    text = o["text"]
    for pat in SKIP_FILE_PATTERNS:
        if re.search(pat, path):
            if o.get("declName") in USER_FACING_DECLS - {"body", "detail", "outcome"}:
                return False
            if o["kind"] in ("swiftui_keyed", "swiftui_interp", "plain_string", "plain_interp"):
                return False
            return True
    if o.get("inDebugConfig"):
        return True
    if o["kind"] == "skip_log" or is_logging(o):
        return True
    if o.get("declName") in NLU_DECLS:
        return True
    if o.get("declName") in PROMPT_DECLS:
        return True
    if is_pattern_literal(text, o):
        return True
    # Pure punctuation/separator literals are not translatable prose.
    if not re.search(r"[一-鿿A-Za-z0-9]", text):
        return True
    # Punctuation palettes used for trimming/splitting are data, not UI.
    stripped = text.strip()
    residual = re.sub(r"[\s`\"'“”‘’「」『』《》，。、；：·…\-\[\]\(\)\{\}!！?？#*.,:;\\tnr]+",
                      "", stripped)
    if residual == "":
        return True
    # Lists of protocol/service identifiers with only incidental CJK.
    if re.fullmatch(r"[A-Za-z0-9 ./·%@+\-_]+", stripped) and re.search(r"[A-Za-z]{3,}", stripped):
        return True

    # Protocol / SQL / prompt text: mostly-Latin strings with structural
    # keywords and only incidental CJK (embedded notice, fallback labels).
    structural = ('"state"', '"decision"', "SELECT ", "COALESCE", "CREATE TABLE",
                  "toolDescription", "documentID=", "Return exactly one JSON",
                  "Do not ", "Never ", "web.search", "action=apply",
                  "section=office", "section=nodes", "notes.read", "notes.edit",
                  "video.status", "video.models", "npm ", "pnpm", "pip ",
                  "Content summary", "package.json", "packageManager",
                  "markdown", "Markdown\\n")
    latin = len(re.findall(r"[A-Za-z0-9]", text))
    han = len(re.findall(r"[一-鿿]", text))
    if latin > 25 and latin > han * 3 and any(k in text for k in structural):
        return True
    # Long mostly-Latin prompt/instruction blobs.
    if latin > 40 and latin > han * 2 and re.search(
            r"(?i)\b(return|never|do not|must|instruction|prompt|JSON|tool)\b", text):
        return True
    # Regex character classes / punctuation palettes containing CJK glyphs.
    if re.fullmatch(r"[\[\]\(\)\?\\p\{\}\^\!\|A-Za-z0-9\s\.\*\+\-\{\},_:;，。、；：·“”‘’\"'`#！？!?…\\]+", text) \
            and han <= 6 and ("[" in text or "\\p" in text):
        return True
    # Markdown starter templates for AI-written content.
    if text.startswith("# ") and latin > han:
        return True
    if FIXTURE_FILE_RE.search(path.split("/")[-1]):
        # Fixture/probe files are not user-facing (synthetic acceptance data).
        if o["kind"] in ("swiftui_keyed", "swiftui_interp"):
            return False
        return True
    bare = o.get("bareCallName") or (o.get("callName") or "").split(".")[-1]
    full = o.get("callName") or ""
    if any(h in bare for h in DATA_CALL_HINTS) and o["kind"].startswith("review"):
        return True
    # Inline bilingual helpers already honor the language override and carry
    # curated English; leave them as-is (no catalog migration needed).
    if bare == "t" and any(h in full for h in
       ("Text", "Workbench", "IDELanguageRun", "OfficeInk", "FloeLocalized",
        "BackgroundExecution", "IDENativeText")):
        return True
    if bare in ("canvasLocalized", "engineeringReviewText"):
        return True
    return False


def main():
    occ_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/l10n-occ.json"
    seeds = json.load(open("/tmp/l10n-seeds.json"))
    occs = json.load(open(occ_path))

    keep, skipped = [], []
    for o in occs:
        (skipped if should_skip(o) else keep).append(o)

    unique_templates = set()
    for o in keep:
        unique_templates.add(canonical_template(o))

    covered = sorted(t for t in unique_templates if t in seeds)
    missing = sorted(t for t in unique_templates if t not in seeds)

    # Representative context per missing template.
    context = {}
    for o in keep:
        t = canonical_template(o)
        if t in seeds:
            continue
        context.setdefault(t, {
            "file": o["file"], "line": o["line"], "kind": o["kind"],
            "call": o.get("callName"), "decl": o.get("declName"),
            "interpolated": o["interpolated"], "occurrences": 0,
        })["occurrences"] += 1

    by_kind = Counter(o["kind"] for o in keep)
    skip_by_kind = Counter(o["kind"] for o in skipped)
    skip_files = Counter(o["file"].split("/")[-1] for o in skipped)

    worksheet = [
        {"zh": t, "context": context.get(t, {})} for t in missing
    ]
    plan = {
        "occurrences_total": len(occs),
        "occurrences_keep": len(keep),
        "occurrences_skip": len(skipped),
        "keep_by_kind": dict(by_kind),
        "skip_by_kind": dict(skip_by_kind),
        "unique_templates": len(unique_templates),
        "templates_with_seed": len(covered),
        "templates_missing_seed": len(missing),
        "missing": missing,
        "worksheet": worksheet,
        "keep": keep,
        "top_skip_files": dict(skip_files.most_common(20)),
    }
    json.dump(plan, open("/tmp/l10n-plan.json", "w"),
              ensure_ascii=False, indent=1)

    print("total occurrences:", len(occs))
    print("keep:", len(keep), "skip:", len(skipped))
    print("keep by kind:", dict(by_kind))
    print("unique templates:", len(unique_templates))
    print("with seed:", len(covered), "missing:", len(missing))
    print("interpolated kept:", sum(1 for o in keep if o["interpolated"]))


if __name__ == "__main__":
    main()
