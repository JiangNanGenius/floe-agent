#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read-only validator for the reconciled G02 feature baseline and fixtures.

Verifies, without writing anything:
  1. Fixture integrity: every inventory.json entry exists with matching
     SHA-256 and byte count; the artifact/version metadata and 33-entry count
     match this revision; no fixture file is absent from the inventory.
  2. Expected basic structures: per-format structural probes must satisfy the
     recorded expectations (DOCX/XLSX/PPTX parts and content, PDF/xref,
     DXF/OBJ entity and vertex counts, WAV header, MP4 box scan, PNG IHDR,
     SRT/VTT cue counts, CSV formula cell, JSON schemas, encoding traits).
     The two attachment-contract fixtures are additionally simulated: MIME
     sniffing, size caps, revoked URI, cancel/cleanup, idempotent retry,
     stale callback rejection and temporary-mode ceiling.
  3. Baseline references: the feature baseline parses, operation IDs are
     unique, every iOS evidence path+symbol still exists in the current
     working tree, goals are G01-G15, channels are full/play, every
     referenced fixture exists, and every inventory operation ID exists.
  4. Coverage: all section-2 feature rows of the plan document are claimed
     by exactly one family; FND is the only family allowed to omit a row and
     must appear exactly once. Family work-package IDs must exist in the
     85-package ledger.
  5. G02 reconciliation: baselineHistory must prove the original 170 IDs,
     36 families and 85 work-package IDs are frozen, exactly the two
     CHA-ATTACH-* operations were appended with planned initial records, the
     two fixtures map both ways, the wire-identity assertions stay under the
     original PRV-CONFIG-VALIDATE, and the plan still carries the attachment
     authority (P2.2/G02/17.5). On top of that frozen history, the settings
     record stays byte-frozen at its 182/40/33 declaration and the NEW
     goalCoreRunControlAdditive record must prove exactly ONE added planned
     operation (CHA-MANUAL-COMPACT), ZERO added fixtures (33 actual inventory
     entries, correcting the incoming 35 proposal error), and the unchanged
     historical validations run on the exact prior 182-operation projection
     with only the approved goal-core addition removed.

Operation statuses use the plan's six-state vocabulary (planned,
implementing, component_verified, app_verified, samsung_verified, delivered).
The four verified states require a nonempty ``evidence`` list of nonempty
references. This is structural checking only: it does not prove a referenced
command, test or device run happened, and it is not qualification evidence.

Historical status digests stored in ``baselineHistory`` are compared against
frozen G01 constants and must not be rewritten. Live operation and
work-package statuses are deliberately not compared to those historical
digests: later qualification may legitimately advance or regress them through
the generic status-vocabulary and evidence-reference checks above.

`--check` is the explicit (default) read-only mode; this script has no write
mode. Exit code 0 = all pass.
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
import re
import struct
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]  # repository root
FIXDIR = ROOT / "FloeAndroid" / "fixtures"
INVENTORY = FIXDIR / "inventory.json"
BASELINE = ROOT / "FloeAndroid" / "planning" / "feature-baseline.json"
WORK_PACKAGES = ROOT / "FloeAndroid" / "planning" / "work-packages.json"
PLAN = ROOT / "docs" / "FLOE_ANDROID_IMPLEMENTATION_PLAN.zh-CN.md"


def _load_goal_core_contract():
    """Load the sibling standalone contract module robustly.

    Works when this file is executed directly and when a test imports it via
    importlib (plain `import goal_core_contract` would then miss the path).
    """
    try:
        import goal_core_contract  # type: ignore
        return goal_core_contract
    except ImportError:
        import importlib.util
        path = Path(__file__).resolve().parent / "goal_core_contract.py"
        spec = importlib.util.spec_from_file_location("goal_core_contract",
                                                      path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module


G = _load_goal_core_contract()

# Current reconciled G02 baseline: the frozen Settings-domain ledger plus the
# one approved goal-core planned operation. The original G01 IDs and the prior
# 172/182 reconciliations are frozen by digest in the baseline's
# baselineHistory / settingsDomainAdditive records and re-checked below on the
# exact prior projection (approved goal-core additions removed only).
EXPECTED_OPERATION_COUNT = G.EXPECTED_OPERATIONS        # 183
EXPECTED_G02_OPERATION_COUNT = G.EXPECTED_G02_OPERATIONS  # 41
EXPECTED_FAMILY_COUNT = G.EXPECTED_FAMILIES             # 36
EXPECTED_WORK_PACKAGE_COUNT = G.EXPECTED_PACKAGES       # 85
EXPECTED_FIXTURE_COUNT = G.EXPECTED_FIXTURES            # 33, unchanged
EXPECTED_BASELINE_VERSION = G.BASELINE_VERSION_CURRENT  # g02.2026-10-21.2
# The fixture SET itself did not change with the goal-core batch: no fixture
# was added, regenerated or rewritten, so the fixture version stays pinned to
# the Settings-domain revision that last changed fixture content.
EXPECTED_FIXTURE_VERSION = "g02.2026-10-19.1"
HISTORICAL_SETTINGS_VERSION = G.BASELINE_VERSION_PREVIOUS  # g02.2026-10-19.1
# The prior reconciled G02 baseline (172 operations / 30 G02 / 26 fixtures).
PRIOR_172_OPERATION_ID_DIGEST = (
    "9c176375513bec3a3fd98ce35796d4c251ce61a24cc334d66027084cd9fd5252")
PRIOR_172_OPERATION_GOAL_DIGEST = (
    "ef3b34295131c51fee3b546a00f62e4288f448dccd33a89f326230a1c3281dec")
PRIOR_172_OPERATION_STATUS_DIGEST = (
    "0b92a1ffb309669eb56187c0200f7c26b81fb28dccbf290d92ed3340dc4f9dab")
PRIOR_172_FAMILY_GOAL_DIGEST = (
    "d0bf7c06112499ddac48e3cb3a1cdbecad46b62347c6d26957c396fd572f8dca")
PRIOR_172_WORK_PACKAGE_GOAL_DIGEST = (
    "84ae0f94db4ada2aeb5e5a5bd365f075b7abb745f5925786c2e4b865a91c0d46")
PRIOR_172_WORK_PACKAGE_STATUS_DIGEST = (
    "df403a256f2318b67239ee78d74ce4c05700f0b36f385af28fe4187dfd1612f7")
ADDITIVE_10_OPERATION_ID_DIGEST = (
    "eb0b8379d8f37241073e60e91ce1e364cb6bde5df1f1ab77e750bbb0a6049cac")
ADDITIVE_10_OPERATION_STATUS_DIGEST = (
    "5acd2aac81aecf7272521ab770233c5408d40f4d2165c5d7d93ca00ecad68e36")
EXPECTED_FIXTURE_ARTIFACT = "floe-android-g02-synthetic-fixtures"
ORIGINAL_OPERATION_ID_DIGEST = (
    "bfd576ea8210c1876ac159bef278e776f7e54e6d143d471724a337aaafa233a1")
ORIGINAL_FAMILY_ID_DIGEST = (
    "1c21802b6eca9999064102d94ecae18b810e458fee11ead6585bc328738611c4")
ORIGINAL_WORK_PACKAGE_ID_DIGEST = (
    "fcb81cb237d3ab67c96c0d902884117a29f94990716243805ff8d428aaebf8f0")
# Frozen G01 status digests, kept only to verify the historical values recorded
# in baselineHistory. Live statuses are intentionally not compared to these:
# real later qualification may legitimately advance or regress them under the
# status vocabulary and evidence rules, without rewriting history.
ORIGINAL_OPERATION_STATUS_DIGEST = (
    "06ba9111efa9eee52605537b73526ab9e8b5efdebb801027d03ee0deb0c2c788")
ORIGINAL_WORK_PACKAGE_STATUS_DIGEST = (
    "df403a256f2318b67239ee78d74ce4c05700f0b36f385af28fe4187dfd1612f7")
ORIGINAL_CHA_OPERATION_IDS = (
    "CHA-PLAN-GOAL",
    "CHA-FOLLOWUP-HISTORY",
    "CHA-SEARCH",
    "CHA-ARCHIVE-BULK",
    "CHA-RESUME-RUN",
    "CHA-DRAFT-KEEP",
)
ATTACHMENT_OPERATION_IDS = (
    "CHA-ATTACH-INGEST-AND",
    "CHA-ATTACH-LIFECYCLE-AND",
)
ATTACHMENT_FIXTURES = {
    "CHA-ATTACH-INGEST-AND": ["attachments/ingest-scenarios.json"],
    "CHA-ATTACH-LIFECYCLE-AND": ["attachments/lifecycle-scenarios.json"],
}
ATTACHMENT_FIXTURE_FORMATS = {
    "attachments/ingest-scenarios.json": "attachment-ingest-scenarios",
    "attachments/lifecycle-scenarios.json": "attachment-lifecycle-scenarios",
}
ATTACHMENT_WORK_PACKAGES = {
    "CHA-ATTACH-INGEST-AND": ["P2.2", "P2.7"],
    "CHA-ATTACH-LIFECYCLE-AND": ["P2.2", "P2.3", "P2.7"],
}
ATTACHMENT_SCENARIO_REQUIREMENTS = {
    "CHA-ATTACH-INGEST-AND": {
        "positive-bounded-commit",
        "reject-oversized",
        "reject-mime-spoof",
        "reject-revoked-uri",
    },
    "CHA-ATTACH-LIFECYCLE-AND": {
        "cancel-mid-transfer-no-orphan",
        "cancel-preserves-prior-commit",
        "retry-idempotent-same-digest",
        "stale-callback-other-task-dropped",
    },
}

SET_OPERATION_IDS = (
    "SET-DEFAULTS-TYPED",
    "SET-MEMORY-INVENTORY",
    "SET-MEMORY-SEARCH",
    "SET-MEMORY-CANDIDATE-REVIEW",
    "SET-MEMORY-ORGANIZE",
    "SET-PERSONALIZATION-DOCUMENTS",
    "SET-PERSONALIZATION-GENERATE",
    "SET-USAGE-AGGREGATE",
    "SET-HISTORY-CLEAR",
    "SET-MODELCFG-CLEAR",
)
SET_OPERATION_WORK_PACKAGES = {
    "SET-DEFAULTS-TYPED": ["P2.2", "P2.13"],
    "SET-MEMORY-INVENTORY": ["P1.2", "P2.13"],
    "SET-MEMORY-SEARCH": ["P1.2"],
    "SET-MEMORY-CANDIDATE-REVIEW": ["P2.3"],
    "SET-MEMORY-ORGANIZE": ["P2.3", "P2.13"],
    "SET-PERSONALIZATION-DOCUMENTS": ["P1.2", "P2.13"],
    "SET-PERSONALIZATION-GENERATE": ["P2.2", "P2.3"],
    "SET-USAGE-AGGREGATE": ["P1.2", "P2.2"],
    "SET-HISTORY-CLEAR": ["P2.7"],
    "SET-MODELCFG-CLEAR": ["P2.7"],
}
SET_OPERATION_FIXTURES = {
    "SET-DEFAULTS-TYPED": ["settings/defaults-cas.json"],
    "SET-MEMORY-INVENTORY": ["memory/inventory.json"],
    "SET-MEMORY-SEARCH": ["memory/inventory.json"],
    "SET-MEMORY-CANDIDATE-REVIEW": ["memory/candidates.json"],
    "SET-MEMORY-ORGANIZE": ["memory/organizer-model-output.json"],
    "SET-PERSONALIZATION-DOCUMENTS": ["personalization/documents.json"],
    "SET-PERSONALIZATION-GENERATE": ["personalization/documents.json"],
    "SET-USAGE-AGGREGATE": ["usage/aggregates.json"],
    "SET-HISTORY-CLEAR": ["privacy/identity-streams.json"],
    "SET-MODELCFG-CLEAR": ["privacy/identity-streams.json"],
}
SET_OPERATION_COMMANDS = {
    "SET-DEFAULTS-TYPED": ["config.defaults.get", "config.defaults.save"],
    "SET-MEMORY-INVENTORY": ["memory.list", "memory.get", "memory.add",
                             "memory.update", "memory.delete", "memory.delete.bulk"],
    "SET-MEMORY-SEARCH": ["memory.search"],
    "SET-MEMORY-CANDIDATE-REVIEW": ["memory.candidates.list",
                                    "memory.candidate.resolve"],
    "SET-MEMORY-ORGANIZE": ["memory.organize.start",
                            "memory.organize.proposal.read",
                            "memory.organize.apply", "memory.organize.cancel"],
    "SET-PERSONALIZATION-DOCUMENTS": ["personalization.get",
                                      "personalization.revision.read",
                                      "personalization.save",
                                      "personalization.rollback",
                                      "personalization.automatic.set",
                                      "content.read"],
    "SET-PERSONALIZATION-GENERATE": ["personalization.generate",
                                     "personalization.generate.cancel"],
    "SET-USAGE-AGGREGATE": ["usage.statistics.get"],
    "SET-HISTORY-CLEAR": ["privacy.summary.get", "privacy.history.clear"],
    "SET-MODELCFG-CLEAR": ["privacy.modelConfiguration.clear"],
}
SET_FIXTURE_FORMATS = {
    "settings/defaults-cas.json": "settings-defaults-cas",
    "memory/inventory.json": "memory-inventory",
    "memory/candidates.json": "memory-candidates",
    "personalization/documents.json": "personalization-documents",
    "usage/aggregates.json": "usage-aggregates",
    "privacy/identity-streams.json": "privacy-identity-streams",
    "memory/organizer-model-output.json": "organizer-model-output",
}
SET_FIXTURE_OPERATIONS = {
    "settings/defaults-cas.json": ["SET-DEFAULTS-TYPED"],
    "memory/inventory.json": ["SET-MEMORY-INVENTORY", "SET-MEMORY-SEARCH"],
    "memory/candidates.json": ["SET-MEMORY-CANDIDATE-REVIEW"],
    "personalization/documents.json": ["SET-PERSONALIZATION-DOCUMENTS",
                                       "SET-PERSONALIZATION-GENERATE"],
    "usage/aggregates.json": ["SET-USAGE-AGGREGATE"],
    "privacy/identity-streams.json": ["SET-HISTORY-CLEAR", "SET-MODELCFG-CLEAR"],
    "memory/organizer-model-output.json": ["SET-MEMORY-ORGANIZE"],
}
SET_FIXTURE_EXPECT = {
    "settings/defaults-cas.json": {
        "schema": "floe.settings-defaults.fixture/1",
        "domain": "floe.settings-defaults.v2",
        "vectorIds": ["absent-set", "null-vs-literal", "delimiter-and-unicode",
                      "numeric-types"],
        "caseIds": ["stale-cas", "atomic-multi-key", "unknown-field",
                    "invalid-enum", "corrupt-row"],
    },
    "memory/inventory.json": {
        "schema": "floe.memory-entry.fixture/1",
        "domain": "floe.memory-entry.v3",
        "vectorIds": ["column-order", "content-boundaries", "unicode-cjk-emoji",
                      "paging-120", "ownership-detach", "same-second-change"],
        "caseIds": ["stale-update", "duplicate-add", "oversize-add",
                    "secret-like", "bulk-stale", "bulk-replay",
                    "search-fresh-diff", "search-deleted-between"],
    },
    "memory/candidates.json": {
        "schema": "floe.memory-candidate.fixture/1",
        "domain": "floe.memory-candidate.v1",
        "vectorIds": ["pending-row", "expired-row", "redacted-evidence",
                      "same-second-change"],
        "caseIds": ["duplicate-accept", "expiry-during-await",
                    "fail-after-memory-write", "no-unbounded-load"],
    },
    "personalization/documents.json": {
        "schema": "floe.personalization-document.fixture/1",
        "domain": "floe.personalization-cursor.v1",
        "vectorIds": ["active-and-drafts", "revision-metadata", "content-24000-cjk",
                      "inline-versus-handle", "cursor-absent-and-present"],
        "caseIds": ["save-stale", "draft-no-contention", "oversize-save",
                    "generate-active", "generate-draft-active-slot",
                    "generate-draft-source-race", "generate-cursor-preserved"],
    },
    "usage/aggregates.json": {
        "schema": "floe.usage-aggregate.fixture/1",
        "domain": "floe.run-usage.aggregate",
        "vectorIds": ["null-metrics", "legacy-fallbacks", "thirty-day-window",
                      "paged-5000-conversations"],
        "caseIds": ["null-not-zero", "empty-db-totals", "bounded-paging",
                    "equivalence-golden"],
    },
    "privacy/identity-streams.json": {
        "schema": "floe.privacy-identity.fixture/1",
        "domain": "floe.privacy-history.v3",
        "vectorIds": ["conversation-run-grant-streams",
                      "model-config-secret-references",
                      "archived-exclusion", "in-memory-bracket"],
        "caseIds": ["equal-size-replacement", "run-state-change",
                    "new-during-await", "archived-excluded",
                    "unstable-grant-snapshot", "gateway-unregistered",
                    "partial-failure"],
    },
    "memory/organizer-model-output.json": {
        "schema": "floe.organizer-output.fixture/1",
        "domain": "floe.memory-entry.v3",
        "vectorIds": ["valid-suggestions", "invented-ids",
                      "exact-duplicate-from-model",
                      "single-id-possible-duplicate", "oversize-stream"],
        "caseIds": ["changed-but-existing", "reowned-preferred",
                    "cloud-await-change", "batch-replay", "review-first-gating"],
    },
}

# Prior attachment scenario bytes keep their original version.
G02_FIXTURE_VERSION = "g02.2026-10-18.1"

GOALS = {"G%02d" % i for i in range(1, 16)}
# Same vocabulary as check-plan.py, from plan section 11.1.
STATUSES = (
    "planned",
    "implementing",
    "component_verified",
    "app_verified",
    "samsung_verified",
    "delivered",
)
VERIFIED_STATUSES = {
    "component_verified",
    "app_verified",
    "samsung_verified",
    "delivered",
}
failures = []
warnings = []
_inventory_paths = set()


def fail(msg):
    failures.append(msg)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def digest_lines(lines):
    """Stable digest used by baselineHistory for sorted field preservation."""
    return sha256(("\n".join(sorted(lines)) + "\n").encode("utf-8"))


def digest_ids(ids):
    """Stable digest used by baselineHistory for sorted ID preservation."""
    return digest_lines(ids)


def sniff_mime(data):
    """Small synthetic-fixture MIME sniff; not a production content scanner."""
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"%PDF-"):
        return "application/pdf"
    if data.startswith(b"PK\x03\x04"):
        return "application/zip"
    if b"\x00" not in data:
        try:
            data.decode("utf-8")
            return "text/plain"
        except UnicodeDecodeError:
            pass
    return "application/octet-stream"


FORBIDDEN_FIXTURE_TEXT = re.compile(
    r"(content://|file://|https?://|/Users/|/home/|"
    r"(^|[^A-Za-z0-9])sk-[A-Za-z0-9]{8,}|"
    r"Bearer\s|BEGIN [A-Z ]*PRIVATE KEY)"
)


def synthetic_guard(doc, where):
    """Reject real-looking URIs, user paths, API keys or bearer material."""
    def walk(value):
        if isinstance(value, str):
            match = FORBIDDEN_FIXTURE_TEXT.search(value)
            if match:
                fail("%s: fixture contains forbidden real-looking text %r"
                     % (where, match.group(0)))
        elif isinstance(value, dict):
            for key, item in value.items():
                walk(key)
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)
    walk(doc)


def fixture_ref_bytes(ref, where):
    """Read a referenced fixture, refusing absolute/escaping/unknown paths."""
    if not isinstance(ref, str) or not ref:
        fail("%s: payload ref must be a nonempty string" % where)
        return None
    path = Path(ref)
    if path.is_absolute() or ".." in path.parts:
        fail("%s: payload ref must stay inside fixtures/: %r" % (where, ref))
        return None
    if ref not in _inventory_paths:
        fail("%s: payload ref is not a recorded fixture: %s" % (where, ref))
        return None
    full = FIXDIR / ref
    if not full.exists():
        fail("%s: payload ref missing on disk: %s" % (where, ref))
        return None
    return full.read_bytes()


def evidence_references(item):
    """Return the evidence list when it is structurally valid, else None."""
    evidence = item.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        return None
    if any(not isinstance(ref, str) or not ref.strip() for ref in evidence):
        return None
    return evidence


# ---------------------------------------------------------------- inventory

def check_inventory():
    global _inventory_paths
    if not INVENTORY.exists():
        fail("inventory.json missing")
        return None
    inv = json.loads(INVENTORY.read_text(encoding="utf-8"))
    if inv.get("artifact") != EXPECTED_FIXTURE_ARTIFACT:
        fail("inventory artifact is %r, expected %r"
             % (inv.get("artifact"), EXPECTED_FIXTURE_ARTIFACT))
    if inv.get("baselineVersion") != EXPECTED_BASELINE_VERSION:
        fail("inventory baselineVersion is %r, expected %r"
             % (inv.get("baselineVersion"), EXPECTED_BASELINE_VERSION))
    if inv.get("fixtureVersion") != EXPECTED_FIXTURE_VERSION:
        fail("inventory fixtureVersion is %r, expected %r"
             % (inv.get("fixtureVersion"), EXPECTED_FIXTURE_VERSION))
    if inv.get("previousFixtureCount") != 26:
        fail("inventory previousFixtureCount is %r, expected 26"
             % (inv.get("previousFixtureCount"),))
    entries = inv.get("entries")
    if not isinstance(entries, list):
        fail("inventory has no entries list")
        return inv
    if len(entries) != EXPECTED_FIXTURE_COUNT:
        fail("inventory lists %d fixtures, expected %d"
             % (len(entries), EXPECTED_FIXTURE_COUNT))
    paths = set()
    for e in entries:
        if e["path"] in paths:
            fail("duplicate inventory path: %s" % e["path"])
        paths.add(e["path"])
        f = FIXDIR / e["path"]
        if not f.exists():
            fail("missing fixture file: %s" % e["path"])
            continue
        data = f.read_bytes()
        if len(data) != e["bytes"]:
            fail("byte count mismatch: %s" % e["path"])
        if sha256(data) != e["sha256"]:
            fail("SHA-256 mismatch: %s" % e["path"])
    _inventory_paths = set(paths)
    # The original baseline count/digests stay frozen. G05 render samples
    # are an explicit, separately checked additive set, not hidden extras.
    additive = inv.get("officePreviewAdditive", {})
    additive_names = {
        "office/docx/blank-preview.docx", "office/pptx/two-slides-preview.pptx",
        "office/pptx/generate_two_slides_preview.py", "office/pptx/README.md",
    }
    if additive:
        if additive.get("schema") != "floe-office-preview-fixtures/1" or additive.get("baselineEntryCount") != 33:
            fail("Office preview additive fixture schema/baseline mismatch")
        extra_entries = additive.get("files", [])
        extra_paths = [e.get("path") for e in extra_entries]
        if len(extra_paths) != len(additive_names) or set(extra_paths) != additive_names or paths & additive_names:
            fail("Office preview additive fixture set mismatch")
        for e in extra_entries:
            name = e.get("path")
            if name not in additive_names:
                continue
            fixture = FIXDIR / name
            if not fixture.is_file() or fixture.is_symlink():
                fail("Office preview additive file missing/linked: %s" % name)
                continue
            body = fixture.read_bytes()
            if len(body) != e.get("bytes") or sha256(body) != e.get("sha256"):
                fail("Office preview additive file digest mismatch: %s" % name)
            paths.add(name)
    # no unrecorded extra files (excluding generator/README/inventory/pyc)
    for p in FIXDIR.rglob("*"):
        if p.is_file():
            rel = str(p.relative_to(FIXDIR))
            if rel in ("inventory.json", "README.md", "generate.py"):
                continue
            if rel.startswith("__pycache__") or rel.endswith(".pyc"):
                continue
            if rel not in paths:
                fail("fixture not recorded in inventory: %s" % rel)
    return inv


# ---------------------------------------------------------------- structure

def zip_parts(data):
    zf = zipfile.ZipFile(io.BytesIO(data))
    return zf, {n: zf.read(n) for n in zf.namelist()}


def strip_ns(xml_bytes):
    text = xml_bytes.decode("utf-8", errors="replace")
    return re.sub(r"\sxmlns(:\w+)?=\"[^\"]*\"", "", text, count=0)


def check_docx(e, data):
    exp = e["expect"]
    try:
        zf, parts = zip_parts(data)
    except Exception as exc:
        if e["format"] == "docx-corrupt":
            return
        fail("docx unreadable %s: %s" % (e["path"], exc))
        return
    has_ct = "[Content_Types].xml" in parts
    if exp.get("hasContentTypes") is False:
        if has_ct:
            fail("%s: expected missing [Content_Types].xml" % e["path"])
        return
    for p in exp["parts"]:
        if p not in parts:
            fail("%s: missing part %s" % (e["path"], p))
    if has_ct and "word/document.xml" in parts:
        body = parts["word/document.xml"].decode("utf-8")
        if body.count("<w:p>") != exp["paragraphCount"] and \
                body.count("<w:p>") + body.count("<w:p ") < exp["paragraphCount"]:
            fail("%s: paragraph count %d != expected %d"
                 % (e["path"], body.count("<w:p>"), exp["paragraphCount"]))
        for t in exp["texts"]:
            if t not in body:
                fail("%s: text missing: %r" % (e["path"], t))
        if body.count("<w:numPr>") != exp["listItemCount"]:
            fail("%s: list item count wrong" % e["path"])


def check_xlsx(e, data):
    exp = e["expect"]
    zf, parts = zip_parts(data)
    wb = parts["xl/workbook.xml"].decode("utf-8")
    if wb.count("<sheet ") != exp["sheetCount"]:
        fail("%s: sheet count wrong" % e["path"])
    if exp["sheetName"] not in wb:
        fail("%s: unicode sheet name missing" % e["path"])
    sheet = parts["xl/worksheets/sheet1.xml"].decode("utf-8")
    for ref, formula in exp.get("formulas", {}).items():
        if '<c r="%s"><f>%s</f>' % (ref, formula) not in sheet:
            fail("%s: formula %s=%s not found" % (e["path"], ref, formula))
    for ref, val in exp.get("cachedValues", {}).items():
        if "<f>" in sheet and ("<v>%s</v>" % val) not in sheet:
            fail("%s: cached value %s missing" % (e["path"], val))
    for ref, err in exp.get("errorCells", {}).items():
        if err not in sheet:
            fail("%s: error cell value missing: %s" % (e["path"], err))
    sst = parts["xl/sharedStrings.xml"].decode("utf-8")
    inj = exp.get("injectionString")
    if inj and inj not in sst:
        fail("%s: injection literal missing from shared strings" % e["path"])


def check_pptx(e, data):
    exp = e["expect"]
    zf, parts = zip_parts(data)
    for p in exp["slideParts"]:
        if p not in parts:
            fail("%s: missing slide part %s" % (e["path"], p))
    s1 = parts.get("ppt/slides/slide1.xml", b"").decode("utf-8")
    if exp["titleText"] not in s1:
        fail("%s: title text missing" % e["path"])
    s2 = parts.get("ppt/slides/slide2.xml", b"").decode("utf-8")
    body = s2[s2.index('type="body"'):]
    if body.count("<a:p>") != exp["bulletCount"]:
        fail("%s: bullet count wrong" % e["path"])
    pres = parts["ppt/presentation.xml"].decode("utf-8")
    if pres.count("<p:sldId ") != exp["slideCount"]:
        fail("%s: sldIdLst count wrong" % e["path"])


def check_pdf(e, data):
    exp = e["expect"]
    if not data.startswith(exp["header"].encode("ascii")):
        fail("%s: pdf header wrong" % e["path"])
    if exp.get("pageCount") is not None:
        m = re.search(rb"/Count (\d+)", data)
        if not m or int(m.group(1)) != exp["pageCount"]:
            fail("%s: page count wrong" % e["path"])
        if data.count(b"/Type /Page ") != exp["pageCount"] and \
                data.count(b"/Type /Page\n") + data.count(b"/Type /Page ") < exp["pageCount"]:
            fail("%s: page objects missing" % e["path"])
    if exp.get("containsTexts"):
        for t in exp["containsTexts"]:
            if t.encode("latin-1") not in data:
                fail("%s: text missing: %r" % (e["path"], t))
    has_xref = b"\nxref\n" in data and b"%%EOF" in data[-8:]
    if e["format"] == "pdf" and not data.endswith(b"%%EOF\n"):
        fail("%s: pdf must end with %%EOF marker" % e["path"])
    if e["format"] == "pdf" and not has_xref:
        fail("%s: valid pdf lacks xref table/EOF" % e["path"])
    if exp.get("hasXref") is False and has_xref:
        fail("%s: truncated pdf unexpectedly has xref/EOF" % e["path"])
    if exp.get("hasXref") is False and b"startxref" in data:
        fail("%s: truncated pdf unexpectedly has startxref" % e["path"])


def check_dxf(e, data):
    """ASCII DXF as strict code/value pairs (even index = group code)."""
    exp = e["expect"]
    lines = data.decode("utf-8").rstrip("\n").splitlines()
    if len(lines) % 2:
        fail("%s: odd line count; code/value pairing broken" % e["path"])
        return
    pairs = list(zip(lines[0::2], lines[1::2]))
    codes = {c for c, _ in pairs}
    known = {"0", "1", "2", "5", "6", "8", "9", "10", "11", "20", "21",
             "40", "62", "70"}
    unknown = codes - known
    if unknown:
        fail("%s: non-code lines at even positions: %s" % (e["path"], unknown))
    acadver = None
    for i, (code, val) in enumerate(pairs):
        if code == "9" and val == "$ACADVER" and i + 1 < len(pairs) \
                and pairs[i + 1][0] == "1":
            acadver = pairs[i + 1][1]
            break
    if acadver != exp["acadver"]:
        fail("%s: acadver wrong: %s" % (e["path"], acadver))
    layer_names = []
    ent_counts = {}
    pending = None
    for code, val in pairs:
        if code == "0":
            pending = val
            if val in ("LINE", "CIRCLE", "TEXT"):
                ent_counts[val] = ent_counts.get(val, 0) + 1
        elif code == "2" and pending == "LAYER":
            layer_names.append(val)
    if sorted(layer_names) != sorted(exp["layers"]):
        fail("%s: layers mismatch: %s" % (e["path"], layer_names))
    if ent_counts != exp["entities"]:
        fail("%s: entity counts %s != %s" % (e["path"], ent_counts, exp["entities"]))
    if exp["textValue"].encode("utf-8") not in data:
        fail("%s: unicode TEXT value missing" % e["path"])


def check_obj(e, data):
    exp = e["expect"]
    lines = data.decode("utf-8").splitlines()
    if sum(1 for l in lines if l.startswith("v ")) != exp["vertices"]:
        fail("%s: vertex count wrong" % e["path"])
    if sum(1 for l in lines if l.startswith("f ")) != exp["faces"]:
        fail("%s: face count wrong" % e["path"])
    if exp["group"] not in data.decode("utf-8"):
        fail("%s: group name missing" % e["path"])


def check_wav(e, data):
    exp = e["expect"]
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        fail("%s: not RIFF/WAVE" % e["path"])
        return
    (_, aformat, channels, rate, _, _, bits) = struct.unpack("<IHHIIHH",
                                                              data[16:36])
    if aformat != 1 or channels != exp["channels"] or rate != exp["sampleRate"] \
            or bits != exp["bits"]:
        fail("%s: wav header fields wrong" % e["path"])
    frames = struct.unpack("<I", data[40:44])[0] // 2
    if frames != exp["frames"]:
        fail("%s: frame count wrong" % e["path"])


def check_mp4(e, data):
    exp = e["expect"]
    boxes = []
    pos = 0
    while pos + 8 <= len(data):
        size = struct.unpack(">I", data[pos:pos + 4])[0]
        typ = data[pos + 4:pos + 8]
        if size < 8 or pos + size > len(data):
            break
        boxes.append(typ.decode("latin-1"))
        pos += size
    for b in exp["boxes"]:
        if b not in boxes:
            fail("%s: missing box %s (top-level: %s)" % (e["path"], b, boxes))
    if b"tkhd" not in data or b"mvhd" not in data:
        fail("%s: tkhd/mvhd missing" % e["path"])


def check_png(e, data):
    exp = e["expect"]
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        fail("%s: png signature wrong" % e["path"])
        return
    w, h, depth, ctype = struct.unpack(">IIBB", data[16:26])
    if (w, h, depth, ctype) != (exp["width"], exp["height"], exp["bitDepth"],
                                 exp["colorType"]):
        fail("%s: IHDR mismatch" % e["path"])
    if b"IEND" not in data[-12:]:
        fail("%s: missing IEND" % e["path"])


def check_srt(e, data):
    text = data.decode("utf-8")
    cues = re.findall(r"\d{2}:\d{2}:\d{2},\d{3} --> ", text)
    if len(cues) != e["expect"]["cueCount"]:
        fail("%s: cue count wrong" % e["path"])
    if e["expect"]["lastCueText"] not in text:
        fail("%s: last cue text missing" % e["path"])


def check_vtt(e, data):
    text = data.decode("utf-8")
    if not text.startswith(e["expect"]["header"]):
        fail("%s: WEBVTT header missing" % e["path"])
    cues = re.findall(r"\d{2}:\d{2}:\d{2}\.\d{3} --> ", text)
    if len(cues) != e["expect"]["cueCount"]:
        fail("%s: cue count wrong" % e["path"])


def check_csv(e, data):
    exp = e["expect"]
    rows = list(csv.reader(io.StringIO(data.decode("utf-8"))))
    if len(rows) != exp["rows"]:
        fail("%s: row count wrong" % e["path"])
    flat = [c for r in rows for c in r]
    if exp["formulaCell"] not in flat:
        fail("%s: formula-like cell value not preserved as text" % e["path"])


def check_code(e, data):
    exp = e["expect"]
    text = data.decode("utf-8")
    for s in exp["symbols"]:
        if s not in text:
            fail("%s: symbol missing %s" % (e["path"], s))
    if exp.get("containsText") and exp["containsText"] not in text:
        fail("%s: text missing" % e["path"])


def check_encoding_text(e, data):
    exp = e["expect"]
    text = data.decode("utf-8")
    if "crlfLineCount" in exp and text.count("\r\n") != exp["crlfLineCount"]:
        fail("%s: CRLF count wrong" % e["path"])
    if exp.get("startsUtf8Bom") and not data.startswith(b"\xef\xbb\xbf"):
        fail("%s: BOM missing" % e["path"])
    if "longestLineChars" in exp and \
            max(len(l) for l in text.splitlines()) != exp["longestLineChars"]:
        fail("%s: long line length wrong" % e["path"])


def check_notes_json(e, data):
    doc = json.loads(data.decode("utf-8"))
    exp = e["expect"]
    if doc.get("schema") != exp["schema"]:
        fail("%s: schema wrong" % e["path"])
    if doc.get("title") != exp["title"]:
        fail("%s: title wrong" % e["path"])
    if len(doc.get("blocks", [])) != exp["blockCount"]:
        fail("%s: block count wrong" % e["path"])
    if [b["type"] for b in doc.get("blocks", [])] != exp["blockTypes"]:
        fail("%s: block types wrong" % e["path"])
    if doc.get("chatSessionId") != exp["chatSessionId"]:
        fail("%s: chatSessionId must stay null (notes/chat independence)"
             % e["path"])


def check_canvas_json(e, data):
    doc = json.loads(data.decode("utf-8"))
    exp = e["expect"]
    if doc.get("schema") != exp["schema"]:
        fail("%s: schema wrong" % e["path"])
    if len(doc.get("nodes", [])) != exp["nodeCount"]:
        fail("%s: node count wrong" % e["path"])
    if len(doc.get("edges", [])) != exp["edgeCount"]:
        fail("%s: edge count wrong" % e["path"])
    refs = {n.get("fixtureRef") for n in doc["nodes"]}
    missing = sum(1 for n in doc["nodes"] if n["kind"] == "asset"
                  and (n.get("fixtureRef") is None or
                       not (FIXDIR / str(n.get("fixtureRef"))).exists()))
    if missing != exp["danglingAssetRefs"]:
        fail("%s: dangling asset refs %d != expected %d"
             % (e["path"], missing, exp["danglingAssetRefs"]))


def check_svg(e, data):
    root = ET.fromstring(data)
    exp = e["expect"]
    if not root.tag.endswith(exp["root"]):
        fail("%s: root element wrong" % e["path"])
    tags = [el.tag.split("}")[-1] for el in root.iter()]
    if tags.count("path") != exp["pathCount"] or tags.count("circle") != \
            exp["circleCount"]:
        fail("%s: shape counts wrong" % e["path"])


def parse_json_fixture(e, data):
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        fail("%s: invalid JSON fixture: %s" % (e["path"], exc))
        return None


def require(condition, message):
    if not condition:
        fail(message)
    return condition


def check_synthetic_owner(owner, where):
    if not isinstance(owner, dict):
        fail("%s: owner must be an object" % where)
        return False
    ok = True
    ok &= require(isinstance(owner.get("taskId"), str)
                  and owner["taskId"].startswith("task-synthetic-"),
                  "%s: taskId must be synthetic" % where)
    ok &= require(isinstance(owner.get("runId"), str)
                  and owner["runId"].startswith("run-synthetic-"),
                  "%s: runId must be synthetic" % where)
    ok &= require(isinstance(owner.get("epoch"), int)
                  and not isinstance(owner.get("epoch"), bool)
                  and owner["epoch"] > 0,
                  "%s: epoch must be a positive integer" % where)
    return bool(ok)


def check_attachment_ingest(e, data):
    """Validate the declarative G02 ingest contract and its negative cases."""
    doc = parse_json_fixture(e, data)
    if doc is None:
        return
    where = e["path"]
    if doc.get("schema") != e["expect"].get("schema") or \
            doc.get("schema") != "floe-android.attachment-ingest-scenarios.v0":
        fail("%s: unexpected ingest fixture schema %r"
             % (where, doc.get("schema")))
    if doc.get("fixtureVersion") != G02_FIXTURE_VERSION:
        fail("%s: fixtureVersion is %r, expected %r"
             % (where, doc.get("fixtureVersion"), G02_FIXTURE_VERSION))
    synthetic_guard(doc, where)

    limits = doc.get("limits")
    if not isinstance(limits, dict):
        fail("%s: limits must be an object" % where)
        return
    max_bytes = limits.get("maxBytes")
    if not isinstance(max_bytes, int) or isinstance(max_bytes, bool) \
            or max_bytes <= 0:
        fail("%s: maxBytes must be a positive integer" % where)
        return
    allowed = limits.get("allowedMime")
    if not isinstance(allowed, list) or not allowed or \
            not all(isinstance(m, str) and m for m in allowed):
        fail("%s: allowedMime must be a nonempty string list" % where)
        return
    expected_temp = {
        "store": "ram",
        "allowedTools": ["text", "public-web"],
        "fsToolEnabled": False,
        "plaintextTempDisk": False,
    }
    if doc.get("temporaryMode") != expected_temp:
        fail("%s: temporaryMode weakened or changed: %r"
             % (where, doc.get("temporaryMode")))

    payloads = doc.get("payloads")
    if not isinstance(payloads, dict) or not payloads:
        fail("%s: payloads must be a nonempty object" % where)
        return
    payload_data = {}
    for name, payload in payloads.items():
        pwhere = "%s:payload:%s" % (where, name)
        if not isinstance(payload, dict):
            fail("%s: payload must be an object" % pwhere)
            continue
        raw = fixture_ref_bytes(payload.get("ref"), pwhere)
        if raw is None:
            continue
        payload_data[name] = raw
        if payload.get("bytes") != len(raw):
            fail("%s: byte count %r != actual %d"
                 % (pwhere, payload.get("bytes"), len(raw)))
        if payload.get("sha256") != sha256(raw):
            fail("%s: digest does not match referenced payload" % pwhere)
        if payload.get("declaredMime") not in allowed:
            fail("%s: declaredMime must be one of the allowed MIME types"
                 % pwhere)
        if payload.get("uriState") not in ("granted", "revoked"):
            fail("%s: uriState must be granted or revoked" % pwhere)

    scenarios = doc.get("scenarios")
    if not isinstance(scenarios, list) or not scenarios:
        fail("%s: scenarios must be a nonempty list" % where)
        return
    seen = set()
    committed = set()
    for scenario in scenarios:
        sid = scenario.get("id")
        if not isinstance(sid, str) or not sid:
            fail("%s: scenario needs a nonempty id" % where)
            continue
        if sid in seen:
            fail("%s: duplicate scenario id %s" % (where, sid))
        seen.add(sid)
        swhere = "%s:%s" % (where, sid)
        if not check_synthetic_owner(scenario.get("owner"), swhere):
            continue
        payload_name = scenario.get("payload")
        payload = payloads.get(payload_name)
        raw = payload_data.get(payload_name)
        if not isinstance(payload, dict) or raw is None:
            fail("%s: unknown payload %r" % (swhere, payload_name))
            continue
        expected = scenario.get("expect")
        if not isinstance(expected, dict):
            fail("%s: expect must be an object" % swhere)
            continue

        if payload.get("uriState") == "revoked":
            decision, reason = "rejected", "uri_permission_revoked"
        elif len(raw) > max_bytes:
            decision, reason = "rejected", "size_exceeds_cap"
        elif payload.get("declaredMime") not in allowed:
            decision, reason = "rejected", "mime_not_allowed"
        elif sniff_mime(raw) != payload.get("declaredMime"):
            decision, reason = "rejected", "mime_mismatch"
        else:
            decision, reason = "committed", "within-bounds"

        computed = {
            "decision": decision,
            "reason": reason,
            "durableRecords": 1 if decision == "committed" else 0,
            "stagingRemoved": True,
            "autoSent": False,
            "autoExecuted": False,
        }
        if decision == "committed":
            committed.add(sid)
            computed["commitBytes"] = len(raw)
            computed["commitSha256"] = sha256(raw)
        for key, value in expected.items():
            if key not in computed:
                fail("%s: unknown expectation field %r" % (swhere, key))
            elif computed[key] != value:
                fail("%s: %s expected %r, computed %r"
                     % (swhere, key, value, computed[key]))

    required = ATTACHMENT_SCENARIO_REQUIREMENTS["CHA-ATTACH-INGEST-AND"]
    missing = required - seen
    if missing:
        fail("%s: missing required ingest scenarios: %s"
             % (where, sorted(missing)))
    if e["expect"].get("committedScenario") not in committed:
        fail("%s: expected committed scenario %r did not commit"
             % (where, e["expect"].get("committedScenario")))
    if e["expect"].get("maxBytes") != max_bytes:
        fail("%s: expect.maxBytes %r != limits.maxBytes %r"
             % (where, e["expect"].get("maxBytes"), max_bytes))


def check_attachment_lifecycle(e, data):
    """Validate cancel/retry/stale-callback lifecycle facts and cleanup."""
    doc = parse_json_fixture(e, data)
    if doc is None:
        return
    where = e["path"]
    if doc.get("schema") != e["expect"].get("schema") or \
            doc.get("schema") != "floe-android.attachment-lifecycle-scenarios.v0":
        fail("%s: unexpected lifecycle fixture schema %r"
             % (where, doc.get("schema")))
    if doc.get("fixtureVersion") != G02_FIXTURE_VERSION:
        fail("%s: fixtureVersion is %r, expected %r"
             % (where, doc.get("fixtureVersion"), G02_FIXTURE_VERSION))
    synthetic_guard(doc, where)

    owner = doc.get("owner")
    if not check_synthetic_owner(owner, where + ":owner"):
        return
    if not check_synthetic_owner(doc.get("otherOwner"), where + ":otherOwner"):
        return

    payloads = doc.get("payloads")
    if not isinstance(payloads, dict) or not payloads:
        fail("%s: payloads must be a nonempty object" % where)
        return
    payload_data = {}
    for name, payload in payloads.items():
        pwhere = "%s:payload:%s" % (where, name)
        if not isinstance(payload, dict):
            fail("%s: payload must be an object" % pwhere)
            continue
        raw = fixture_ref_bytes(payload.get("ref"), pwhere)
        if raw is None:
            continue
        payload_data[name] = raw
        if payload.get("bytes") != len(raw):
            fail("%s: byte count %r != actual %d"
                 % (pwhere, payload.get("bytes"), len(raw)))
        if payload.get("sha256") != sha256(raw):
            fail("%s: digest does not match referenced payload" % pwhere)

    scenarios = doc.get("scenarios")
    if not isinstance(scenarios, list) or not scenarios:
        fail("%s: scenarios must be a nonempty list" % where)
        return
    seen = set()
    for scenario in scenarios:
        sid = scenario.get("id")
        if not isinstance(sid, str) or not sid:
            fail("%s: scenario needs a nonempty id" % where)
            continue
        if sid in seen:
            fail("%s: duplicate scenario id %s" % (where, sid))
        seen.add(sid)
        swhere = "%s:%s" % (where, sid)
        payload_name = scenario.get("payload")
        raw = payload_data.get(payload_name)
        if raw is None:
            fail("%s: unknown payload %r" % (swhere, payload_name))
            continue
        digest = sha256(raw)
        expected = scenario.get("expect")
        if not isinstance(expected, dict):
            fail("%s: expect must be an object" % swhere)
            continue

        computed = {
            "durableRecords": 0,
            "partialDurableRecords": 0,
            "stagingRemoved": True,
            "autoSent": False,
            "autoExecuted": False,
        }
        if "callback" in scenario:
            callback = scenario.get("callback")
            if not check_synthetic_owner(callback, swhere + ":callback"):
                continue
            stale = (callback["taskId"] != owner["taskId"] or
                     callback["runId"] != owner["runId"] or
                     callback["epoch"] < owner["epoch"])
            computed["state"] = "stale-dropped" if stale else "committed"
            if not stale:
                computed["durableRecords"] = 1
            else:
                computed["crossTaskRecords"] = 0
            if callback.get("digest") != digest:
                fail("%s: callback digest does not match payload" % swhere)
        elif "attempts" in scenario:
            attempts = scenario.get("attempts")
            if not isinstance(attempts, list) or len(attempts) < 2:
                fail("%s: retry needs at least two attempts" % swhere)
                continue
            digests = [a.get("digest") for a in attempts
                       if isinstance(a, dict)]
            if len(digests) != len(attempts) or \
                    any(d != digest for d in digests):
                fail("%s: every retry attempt must carry the payload digest"
                     % swhere)
            computed.update({
                "state": "committed",
                "durableRecords": 1,
                "duplicateRecords": 0,
                "commitSha256": digest,
            })
        elif "events" in scenario:
            events = scenario.get("events")
            if not isinstance(events, list) or not events:
                fail("%s: events must be a nonempty list" % swhere)
                continue
            received = []
            valid_events = []
            for event in events:
                if not isinstance(event, dict):
                    fail("%s: event must be an object" % swhere)
                    continue
                value = event.get("received")
                if not isinstance(value, int) or isinstance(value, bool) \
                        or value < 0 or value > len(raw):
                    fail("%s: received must be 0..%d" % (swhere, len(raw)))
                    continue
                received.append(value)
                valid_events.append(event)
            if not valid_events:
                continue
            if received != sorted(received):
                fail("%s: progress is not monotonic" % swhere)
            last = valid_events[-1]
            prior_name = scenario.get("priorCommitted")
            if prior_name is not None:
                prior = payloads.get(prior_name)
                if not isinstance(prior, dict) or prior_name not in payload_data:
                    fail("%s: unknown priorCommitted payload %r"
                         % (swhere, prior_name))
                    continue
                computed["preservedSha256"] = prior["sha256"]
                computed["durableRecords"] = 1
            if last.get("cancelled"):
                computed["state"] = "cancelled"
            elif last.get("completed") and received[-1] == len(raw):
                computed["state"] = "committed"
                computed["durableRecords"] = 1
                computed["progressMonotonic"] = True
                computed["commitSha256"] = digest
            else:
                fail("%s: lifecycle scenario must end cancelled or completed"
                     % swhere)
                continue
        else:
            fail("%s: scenario needs events, attempts or callback" % swhere)
            continue

        for key, value in expected.items():
            if key not in computed:
                fail("%s: unknown expectation field %r" % (swhere, key))
            elif computed[key] != value:
                fail("%s: %s expected %r, computed %r"
                     % (swhere, key, value, computed[key]))

    required = ATTACHMENT_SCENARIO_REQUIREMENTS["CHA-ATTACH-LIFECYCLE-AND"]
    missing = required - seen
    if missing:
        fail("%s: missing required lifecycle scenarios: %s"
             % (where, sorted(missing)))



def check_settings_fixture(e, data):
    """Structural/declarative checks for the seven Settings-domain fixtures.

    These files are synthetic contract vectors. They must never claim that a
    test ran, a command executed or a capability became available.
    """
    path = e["path"]
    if path not in SET_FIXTURE_EXPECT:
        fail("%s: unexpected settings fixture" % path)
        return
    try:
        doc = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        fail("%s: not valid UTF-8 JSON: %s" % (path, exc))
        return
    if not isinstance(doc, dict):
        fail("%s: fixture root must be an object" % path)
        return
    expected = SET_FIXTURE_EXPECT[path]
    if doc.get("schema") != expected["schema"]:
        fail("%s: schema %r != %r"
             % (path, doc.get("schema"), expected["schema"]))
    if doc.get("declarativeOnly") is not True:
        fail("%s: declarativeOnly must be true" % path)
    vectors = doc.get("vectors")
    cases = doc.get("cases")
    if not isinstance(vectors, list) or not vectors:
        fail("%s: vectors must be a nonempty list" % path)
    else:
        ids = [item.get("id") for item in vectors if isinstance(item, dict)]
        if ids != expected["vectorIds"]:
            fail("%s: vector ids %r != %r"
                 % (path, ids, expected["vectorIds"]))
    if not isinstance(cases, list) or not cases:
        fail("%s: cases must be a nonempty list" % path)
    else:
        ids = [item.get("id") for item in cases if isinstance(item, dict)]
        if ids != expected["caseIds"]:
            fail("%s: case ids %r != %r"
                 % (path, ids, expected["caseIds"]))

    def walk(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if key in ("executed", "passed", "verified") and item is True:
                    fail("%s: fixture claims execution via %r" % (path, key))
                if key == "status" and item in (
                        "executed", "passed", "verified",
                        "component_verified", "app_verified"):
                    fail("%s: fixture claims status %r" % (path, item))
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)
    walk(doc)
    synthetic_guard(doc, path)

    if path == "memory/inventory.json":
        if doc.get("columnCount") != 23 or len(doc.get("columns", [])) != 23:
            fail("%s: expected 23 memory_entries non-id columns" % path)
        paging = next((v for v in (vectors or [])
                       if isinstance(v, dict) and v.get("id") == "paging-120"), None)
        if not paging or paging.get("wireDefaultLimit") != 50 or \
                paging.get("nativeDefaultLimit") != 100:
            fail("%s: paging vector must record wire 50 / native 100" % path)
        fresh = next((c for c in (cases or [])
                      if isinstance(c, dict) and c.get("id") == "search-fresh-diff"), None)
        if not fresh or fresh.get("handleStores") != "ranking only" or \
                fresh.get("freshPageRead") is not True or \
                fresh.get("recallReplay") is not False:
            fail("%s: search-fresh vector must record ranking-only/fresh-page" % path)
    elif path == "memory/candidates.json":
        if doc.get("columnCount") != 18 or len(doc.get("columns", [])) != 18:
            fail("%s: expected 18 memory_candidates non-id columns" % path)
    elif path == "settings/defaults-cas.json":
        if doc.get("keys") != ["agent.defaultMode", "agent.runningInputMode",
                               "agent.verifyFinalAnswer"]:
            fail("%s: defaults whitelist changed" % path)
    elif path == "personalization/documents.json":
        if not isinstance(doc.get("domains"), dict):
            fail("%s: missing closed digest domains" % path)
        budget = next((v for v in (vectors or [])
                       if isinstance(v, dict) and v.get("id") == "content-24000-cjk"), None)
        if not budget or budget.get("frameBound") != 65_536 or \
                budget.get("inlineRule") != "complete encoded response" or \
                budget.get("extraInlineCap") is not None:
            fail("%s: content-budget vector must record frame/actual-inline rule" % path)
    elif path == "privacy/identity-streams.json":
        domains = doc.get("domains")
        if not isinstance(domains, dict) or set(domains) != {
                "history", "modelConfiguration"}:
            fail("%s: missing privacy digest domains" % path)
        secrets = next((v for v in (vectors or [])
                        if isinstance(v, dict)
                        and v.get("id") == "model-config-secret-references"), None)
        expected = {
            "account": "opaque text|null",
            "synchronizable": "Bool|null",
            "credentialRecords": "excluded",
            "secretBytes": "never",
        }
        if not secrets or secrets.get("secretReference") != expected:
            fail("%s: model-config secret-reference shape changed" % path)
    elif path == "memory/organizer-model-output.json":
        if len(doc.get("closedSuggestionKinds", [])) != 5:
            fail("%s: organizer suggestion enum must stay closed at 5" % path)
    elif path == "usage/aggregates.json":
        if not any(isinstance(v, dict) and v.get("id") == "null-metrics"
                   for v in (vectors or [])):
            fail("%s: null-metrics vector missing" % path)


STRUCTURE_CHECKS = {
    "docx": check_docx, "docx-corrupt": check_docx,
    "xlsx": check_xlsx, "pptx": check_pptx,
    "pdf": check_pdf, "pdf-corrupt": check_pdf,
    "dxf": check_dxf, "obj": check_obj, "wav": check_wav, "mp4": check_mp4,
    "png": check_png, "srt": check_srt, "vtt": check_vtt, "csv": check_csv,
    "python": check_code, "kotlin": check_code, "typescript": check_code,
    "text": check_encoding_text, "notes-json": check_notes_json,
    "canvas-json": check_canvas_json, "svg": check_svg,
    "attachment-ingest-scenarios": check_attachment_ingest,
    "attachment-lifecycle-scenarios": check_attachment_lifecycle,
    "settings-defaults-cas": check_settings_fixture,
    "memory-inventory": check_settings_fixture,
    "memory-candidates": check_settings_fixture,
    "personalization-documents": check_settings_fixture,
    "usage-aggregates": check_settings_fixture,
    "privacy-identity-streams": check_settings_fixture,
    "organizer-model-output": check_settings_fixture,
}


def check_structures(inv):
    for e in inv["entries"]:
        f = FIXDIR / e["path"]
        if not f.exists():
            continue
        fn = STRUCTURE_CHECKS.get(e["format"])
        if fn is None:
            warnings.append("no structure check for format %s" % e["format"])
            continue
        fn(e, f.read_bytes())


# ---------------------------------------------------------------- baseline

def section2_rows():
    text = PLAN.read_text(encoding="utf-8")
    m = re.search(r"## 2 完整功能对齐台账\n(.*?)\n## 3 ", text, re.S)
    if not m:
        fail("cannot locate plan section 2")
        return set()
    rows = set()
    for line in m.group(1).splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if not cells or cells[0] in ("功能域", "") or set(cells[0]) <= set("- "):
            continue
        rows.add(cells[0])
    return rows


def check_family_coverage(data):
    """Enforce family-level section-2 traceability, not operation mappings."""
    families = data.get("families")
    if not isinstance(families, list):
        fail("feature baseline has no families list")
        return
    ids = [fam.get("id") for fam in families]
    names = [fam.get("name") for fam in families]
    for label, values in (("family id", ids), ("family name", names)):
        dupes = sorted({str(v) for v in values if v and values.count(v) > 1})
        if dupes:
            fail("%s duplicates: %s" % (label, dupes))
    if any(not isinstance(fid, str) or not fid.strip() for fid in ids):
        fail("every family needs a nonempty string id")

    fnd = [fam for fam in families if fam.get("id") == "FND"]
    if len(fnd) != 1:
        fail("expected exactly one FND family, found %d" % len(fnd))

    rows = section2_rows()
    claimed = []
    for fam in families:
        fid = fam.get("id") or "<missing-id>"
        row = fam.get("section2Row")
        if fid == "FND":
            if row is not None:
                fail("FND must not claim a section-2 row")
            continue
        if not isinstance(row, str) or not row.strip():
            fail("%s: non-FND family must claim a section-2 row" % fid)
            continue
        if row not in rows:
            fail("%s: unknown section-2 row %r" % (fid, row))
            continue
        claimed.append(row)

    dupes = sorted({row for row in claimed if claimed.count(row) > 1})
    if dupes:
        fail("section-2 rows claimed twice: %s" % dupes)
    missing = rows - set(claimed)
    if missing:
        fail("section-2 rows not covered: %s" % sorted(missing))


def check_work_package_links(data):
    if not WORK_PACKAGES.exists():
        fail("work-package ledger missing: %s" % WORK_PACKAGES)
        return
    try:
        ledger = json.loads(WORK_PACKAGES.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        fail("work-package ledger unreadable: %s" % exc)
        return
    packages = ledger.get("packages")
    if not isinstance(packages, list):
        fail("work-package ledger has no packages list")
        return
    ledger_ids = [item.get("id") for item in packages]
    if len(ledger_ids) != 85:
        fail("work-package ledger lists %d packages, expected 85"
             % len(ledger_ids))
    ledger_dupes = sorted({pid for pid in ledger_ids
                           if pid and ledger_ids.count(pid) > 1})
    if ledger_dupes:
        fail("work-package ledger duplicate ids: %s" % ledger_dupes)
    known = set(ledger_ids)

    for fam in data.get("families", []):
        fid = fam.get("id") or "<missing-id>"
        work_packages = fam.get("workPackages")
        if not isinstance(work_packages, list) or not work_packages:
            fail("%s: family needs a nonempty workPackages list" % fid)
            continue
        dupes = sorted({wp for wp in work_packages
                        if isinstance(wp, str) and work_packages.count(wp) > 1})
        if dupes:
            fail("%s: duplicate work package links: %s" % (fid, dupes))
        for wp in work_packages:
            if not isinstance(wp, str) or wp not in known:
                fail("%s: unknown work package link %r" % (fid, wp))


def check_attachment_fixture_records(inv):
    if inv is None:
        return
    entries = {e["path"]: e for e in inv.get("entries", [])}
    for oid, fixtures in ATTACHMENT_FIXTURES.items():
        for path in fixtures:
            entry = entries.get(path)
            if entry is None:
                fail("%s: required attachment fixture missing from inventory: %s"
                     % (oid, path))
                continue
            expected_format = ATTACHMENT_FIXTURE_FORMATS[path]
            if entry.get("format") != expected_format:
                fail("%s: fixture format %r, expected %r"
                     % (path, entry.get("format"), expected_format))
            if entry.get("operations") != [oid]:
                fail("%s: inventory operations must be exactly [%s]"
                     % (path, oid))


def check_baseline_history(data, ops, inv):
    """Prove the frozen prior reconciliations and the additive 182 delta.

    The previous ``baselineHistory`` object (G01 170 -> G02 172 with the two
    CHA attachment operations) must stay exactly as recorded. The new
    ``settingsDomainAdditive`` record adds ten SET-family operations and seven
    fixtures while preserving the prior 172 identities, goals and statuses and
    the 36 family / 85 package inventories.
    """
    history = data.get("baselineHistory")
    if not isinstance(history, dict):
        fail("feature baseline has no baselineHistory")
        return
    if data.get("version") != EXPECTED_BASELINE_VERSION:
        fail("baseline version is %r, expected %r"
             % (data.get("version"), EXPECTED_BASELINE_VERSION))
    if history.get("previousVersion") != "g01.2026-10-18.2":
        fail("baselineHistory.previousVersion is %r, expected g01.2026-10-18.2"
             % (history.get("previousVersion"),))
    previous_counts = {
        "families": 36,
        "operations": 170,
        "g02Operations": 28,
        "workPackages": 85,
        "fixtures": 24,
    }
    current_counts = {
        "families": 36,
        "operations": 172,
        "g02Operations": 30,
        "workPackages": 85,
        "fixtures": 26,
    }
    if history.get("previousDeclaredCounts") != previous_counts:
        fail("baselineHistory.previousDeclaredCounts is %r, expected %r"
             % (history.get("previousDeclaredCounts"), previous_counts))
    if history.get("currentDeclaredCounts") != current_counts:
        fail("baselineHistory.currentDeclaredCounts is %r, expected %r"
             % (history.get("currentDeclaredCounts"), current_counts))

    additive_ids = history.get("additiveOperationIds")
    if additive_ids != list(ATTACHMENT_OPERATION_IDS):
        fail("baselineHistory.additiveOperationIds is %r, expected %r"
             % (additive_ids, list(ATTACHMENT_OPERATION_IDS)))
        additive_ids = list(ATTACHMENT_OPERATION_IDS)
    expected_mapping = [
        {
            "id": oid,
            "family": "CHA",
            "goal": "G02",
            "status": "planned",
            "workPackages": ATTACHMENT_WORK_PACKAGES[oid],
            "fixture": ATTACHMENT_FIXTURES[oid][0],
        }
        for oid in ATTACHMENT_OPERATION_IDS
    ]
    if history.get("additiveOperations") != expected_mapping:
        fail("baselineHistory.additiveOperations mapping differs from the "
             "declared work-package/fixture mapping")

    ids = [op["id"] for fam in data.get("families", [])
           for op in fam.get("operations", [])]
    family_ids = [fam.get("id") for fam in data.get("families", [])]
    g02 = sum(1 for fam in data.get("families", [])
              for op in fam.get("operations", [])
              if op.get("goal") == "G02")
    if len(ids) != EXPECTED_OPERATION_COUNT:
        fail("baseline lists %d operations, expected %d"
             % (len(ids), EXPECTED_OPERATION_COUNT))
    if g02 != EXPECTED_G02_OPERATION_COUNT:
        fail("baseline lists %d G02 operations, expected %d"
             % (g02, EXPECTED_G02_OPERATION_COUNT))
    if len(family_ids) != EXPECTED_FAMILY_COUNT:
        fail("baseline lists %d families, expected %d"
             % (len(family_ids), EXPECTED_FAMILY_COUNT))

    additive_set = set(ATTACHMENT_OPERATION_IDS)
    original_current_digest = digest_ids(set(ids) - additive_set
                                         - set(SET_OPERATION_IDS)
                                         - {G.GOALCORE_OPERATION_ID})
    if original_current_digest != ORIGINAL_OPERATION_ID_DIGEST:
        fail("original operation IDs changed: digest %s != frozen %s"
             % (original_current_digest, ORIGINAL_OPERATION_ID_DIGEST))
    if history.get("previousOperationIdDigest") != ORIGINAL_OPERATION_ID_DIGEST:
        fail("baselineHistory.previousOperationIdDigest was rewritten")
    if history.get("previousOperationStatusDigest") != \
            ORIGINAL_OPERATION_STATUS_DIGEST:
        fail("baselineHistory.previousOperationStatusDigest was rewritten")
    family_digest = digest_ids(family_ids)
    if family_digest != ORIGINAL_FAMILY_ID_DIGEST:
        fail("family IDs changed: digest %s != frozen %s"
             % (family_digest, ORIGINAL_FAMILY_ID_DIGEST))
    if history.get("previousFamilyIdDigest") != ORIGINAL_FAMILY_ID_DIGEST:
        fail("baselineHistory.previousFamilyIdDigest was rewritten")

    try:
        ledger = json.loads(WORK_PACKAGES.read_text(encoding="utf-8"))
        ledger_ids = [item.get("id") for item in ledger["packages"]]
    except (OSError, ValueError, KeyError) as exc:
        fail("cannot read work-package IDs: %s" % exc)
        return
    work_digest = digest_ids(ledger_ids)
    if len(ledger_ids) != EXPECTED_WORK_PACKAGE_COUNT:
        fail("work-package ledger lists %d packages, expected %d"
             % (len(ledger_ids), EXPECTED_WORK_PACKAGE_COUNT))
    if work_digest != ORIGINAL_WORK_PACKAGE_ID_DIGEST:
        fail("work-package IDs changed: digest %s != frozen %s"
             % (work_digest, ORIGINAL_WORK_PACKAGE_ID_DIGEST))
    if history.get("previousWorkPackageIdDigest") != \
            ORIGINAL_WORK_PACKAGE_ID_DIGEST:
        fail("baselineHistory.previousWorkPackageIdDigest was rewritten")
    if history.get("previousWorkPackageStatusDigest") != \
            ORIGINAL_WORK_PACKAGE_STATUS_DIGEST:
        fail("baselineHistory.previousWorkPackageStatusDigest was rewritten")

    # ---- New additive Settings-domain record -----------------------------
    add = data.get("settingsDomainAdditive")
    if not isinstance(add, dict):
        fail("feature baseline has no settingsDomainAdditive record")
        return
    if add.get("version") != HISTORICAL_SETTINGS_VERSION:
        fail("settingsDomainAdditive.version is %r, expected the frozen "
             "historical %r" % (add.get("version"), HISTORICAL_SETTINGS_VERSION))
    if add.get("previousVersion") != "g02.2026-10-18.1":
        fail("settingsDomainAdditive.previousVersion changed")
    if add.get("contractSHA256") != \
            "f3ddecdca061ae17fbe4280b7bfb549d8a1673fd8d9ae6e1ba363332ef5db46c":
        fail("settingsDomainAdditive.contractSHA256 changed")
    if add.get("previousDeclaredCounts") != current_counts:
        fail("settingsDomainAdditive.previousDeclaredCounts is %r, expected %r"
             % (add.get("previousDeclaredCounts"), current_counts))
    additive_counts = {
        "families": 36,
        "operations": 182,
        "g02Operations": 40,
        "workPackages": 85,
        "fixtures": 33,
    }
    if add.get("currentDeclaredCounts") != additive_counts:
        fail("settingsDomainAdditive.currentDeclaredCounts is %r, expected %r"
             % (add.get("currentDeclaredCounts"), additive_counts))
    if add.get("additiveOperationIds") != list(SET_OPERATION_IDS):
        fail("settingsDomainAdditive.additiveOperationIds changed")
    expected_set_mapping = [
        {
            "id": oid,
            "family": "SET",
            "goal": "G02",
            "status": "planned",
            "workPackages": SET_OPERATION_WORK_PACKAGES[oid],
            "fixture": SET_OPERATION_FIXTURES[oid][0],
        }
        for oid in SET_OPERATION_IDS
    ]
    if add.get("additiveOperations") != expected_set_mapping:
        fail("settingsDomainAdditive.additiveOperations mapping differs from "
             "the declared work-package/fixture mapping")
    expected_paths = sorted({p for oid in SET_OPERATION_IDS
                             for p in SET_OPERATION_FIXTURES[oid]})
    if add.get("additiveFixturePaths") != expected_paths:
        fail("settingsDomainAdditive.additiveFixturePaths is %r, expected %r"
             % (add.get("additiveFixturePaths"), expected_paths))
    expected_fixture_ids = [
        "FIX-SET-DEFAULTS-CAS", "FIX-MEM-INVENTORY", "FIX-MEM-CANDIDATES",
        "FIX-PER-DOCUMENTS", "FIX-USE-AGGREGATES", "FIX-PRVC-IDENTITY",
        "FIX-ORG-MODEL-OUTPUT",
    ]
    if add.get("additiveFixtureIds") != expected_fixture_ids:
        fail("settingsDomainAdditive.additiveFixtureIds changed")

    # The unchanged historical validation runs on the exact prior 182-operation
    # ledger: the live ID set minus the frozen Settings-domain addition and
    # minus ONLY the approved goal-core operation. It executes regardless of
    # the live count, so a changed count can never skip the frozen identity,
    # goal, status, family and work-package proofs.
    prior_ids = [oid for oid in ids if oid not in set(SET_OPERATION_IDS)
                 and oid != G.GOALCORE_OPERATION_ID]
    if len(prior_ids) != 172:
        fail("prior operation set is %d, expected 172" % len(prior_ids))
    prior_ops = [ops[oid] for oid in prior_ids]
    prior_goal_digest = digest_lines(
        ["%s:%s" % (op["id"], op["goal"]) for op in prior_ops])
    prior_status_digest = digest_lines(
        ["%s:%s" % (op["id"], op["status"]) for op in prior_ops])
    if digest_ids(prior_ids) != PRIOR_172_OPERATION_ID_DIGEST:
        fail("prior 172 operation IDs changed: digest %s != frozen %s"
             % (digest_ids(prior_ids), PRIOR_172_OPERATION_ID_DIGEST))
    if prior_goal_digest != PRIOR_172_OPERATION_GOAL_DIGEST:
        fail("prior 172 operation goals changed: digest %s != frozen %s"
             % (prior_goal_digest, PRIOR_172_OPERATION_GOAL_DIGEST))
    if prior_status_digest != PRIOR_172_OPERATION_STATUS_DIGEST:
        fail("prior 172 operation statuses changed: digest %s != frozen %s"
             % (prior_status_digest, PRIOR_172_OPERATION_STATUS_DIGEST))
    if add.get("previousOperationIdDigest") != PRIOR_172_OPERATION_ID_DIGEST:
        fail("settingsDomainAdditive.previousOperationIdDigest changed")
    if add.get("previousOperationGoalDigest") != PRIOR_172_OPERATION_GOAL_DIGEST:
        fail("settingsDomainAdditive.previousOperationGoalDigest changed")
    if add.get("previousOperationStatusDigest") != \
            PRIOR_172_OPERATION_STATUS_DIGEST:
        fail("settingsDomainAdditive.previousOperationStatusDigest changed")
    family_goal_digest = digest_lines(
        ["%s:%s" % (fam["id"], fam["androidOwnerGoal"])
         for fam in data["families"]])
    if family_goal_digest != PRIOR_172_FAMILY_GOAL_DIGEST:
        fail("family owner goals changed: digest %s != frozen %s"
             % (family_goal_digest, PRIOR_172_FAMILY_GOAL_DIGEST))
    if add.get("previousFamilyGoalDigest") != PRIOR_172_FAMILY_GOAL_DIGEST:
        fail("settingsDomainAdditive.previousFamilyGoalDigest changed")
    package_goal_digest = digest_lines(
        ["%s:%s" % (item["id"], item["implementationGoal"])
         for item in ledger["packages"]])
    package_status_digest = digest_lines(
        ["%s:%s" % (item["id"], item["status"])
         for item in ledger["packages"]])
    if package_goal_digest != PRIOR_172_WORK_PACKAGE_GOAL_DIGEST:
        fail("work-package goals changed: digest %s != frozen %s"
             % (package_goal_digest, PRIOR_172_WORK_PACKAGE_GOAL_DIGEST))
    if package_status_digest != PRIOR_172_WORK_PACKAGE_STATUS_DIGEST:
        fail("work-package statuses changed: digest %s != frozen %s"
             % (package_status_digest, PRIOR_172_WORK_PACKAGE_STATUS_DIGEST))
    if add.get("previousWorkPackageGoalDigest") != \
            PRIOR_172_WORK_PACKAGE_GOAL_DIGEST:
        fail("settingsDomainAdditive.previousWorkPackageGoalDigest changed")
    if add.get("previousWorkPackageStatusDigest") != \
            PRIOR_172_WORK_PACKAGE_STATUS_DIGEST:
        fail("settingsDomainAdditive.previousWorkPackageStatusDigest changed")
    new_ids = [oid for oid in ids if oid in set(SET_OPERATION_IDS)]
    if digest_ids(new_ids) != ADDITIVE_10_OPERATION_ID_DIGEST:
        fail("additive operation IDs changed: digest %s != frozen %s"
             % (digest_ids(new_ids), ADDITIVE_10_OPERATION_ID_DIGEST))
    new_status_digest = digest_lines(
        ["%s:%s" % (oid, ops.get(oid, {}).get("status"))
         for oid in SET_OPERATION_IDS])
    if new_status_digest != ADDITIVE_10_OPERATION_STATUS_DIGEST:
        fail("additive statuses changed: digest %s != frozen %s"
             % (new_status_digest, ADDITIVE_10_OPERATION_STATUS_DIGEST))
    if add.get("additiveOperationIdDigest") != \
            ADDITIVE_10_OPERATION_ID_DIGEST:
        fail("settingsDomainAdditive.additiveOperationIdDigest changed")
    if add.get("additiveOperationStatusDigest") != \
            ADDITIVE_10_OPERATION_STATUS_DIGEST:
        fail("settingsDomainAdditive.additiveOperationStatusDigest changed")

    # ---- New goal-core run-control record --------------------------------
    # Independently prove the ONE planned operation and ZERO fixtures against
    # the approved delta and the actual live numbers (the incoming record's
    # 35-fixture claim was a proposal error; the real inventory is 33).
    goalcore_failures = G.validate_goalcore_record(
        data.get("goalCoreRunControlAdditive"), ops,
        0 if inv is None else len(inv.get("entries", [])), g02)
    for message in goalcore_failures:
        fail("goalCoreRunControlAdditive: %s" % message)
    record = data.get("goalCoreRunControlAdditive")
    if isinstance(record, dict):
        cha_family = next((fam for fam in data.get("families", [])
                           if fam.get("id") == "CHA"), None)
        if cha_family is not None:
            family_wps = set(cha_family.get("workPackages", []))
            for wp in G.GOALCORE_OPERATION_WORK_PACKAGES:
                if wp not in family_wps:
                    fail("goal-core work package %s is not in the CHA family "
                         "mapping" % wp)
        goalcore_ids = [oid for oid in ids if oid == G.GOALCORE_OPERATION_ID]
        if digest_ids(goalcore_ids) != G.GOALCORE_OPERATION_ID_DIGEST:
            fail("goal-core operation ID digest differs from the approved one")

    if inv is not None:
        if len(inv.get("entries", [])) != EXPECTED_FIXTURE_COUNT:
            fail("inventory fixture count differs from %d"
                 % EXPECTED_FIXTURE_COUNT)
        # Actual header must match the new baseline...
        if inv.get("baselineVersion") != data.get("version"):
            fail("inventory baselineVersion %r != baseline version %r"
                 % (inv.get("baselineVersion"), data.get("version")))
        # ...while the historical Settings-era inventory consistency check
        # runs on the SAME entries with only the header projected back to the
        # frozen Settings-era baseline version: that record declared exactly
        # 33 fixtures at g02.2026-10-19.1, the live inventory still has
        # exactly those 33 entries (per-entry SHA-256/byte integrity is
        # proven in check_inventory, no regeneration or SHA rewrite), and the
        # fixtureVersion is unchanged, so the goal-core batch added zero
        # fixtures. If the projected historical header ever stops matching
        # the frozen Settings-era fixture declaration, this fails.
        historical_fixture_claim = \
            add.get("currentDeclaredCounts", {}).get("fixtures")
        projected_inv = dict(inv)
        projected_inv["baselineVersion"] = HISTORICAL_SETTINGS_VERSION
        if projected_inv["baselineVersion"] != add.get("version"):
            fail("projected inventory header does not match the frozen "
                 "settingsDomainAdditive.version %r" % add.get("version"))
        if len(inv.get("entries", [])) != historical_fixture_claim:
            fail("Settings-era declared fixture count %r no longer equals the "
                 "live inventory size %d"
                 % (historical_fixture_claim, len(inv.get("entries", []))))
        if inv.get("fixtureVersion") != HISTORICAL_SETTINGS_VERSION:
            fail("inventory fixtureVersion %r no longer matches the frozen "
                 "Settings-era fixture content version"
                 % inv.get("fixtureVersion"))


def check_settings_operations(data, ops, inv):
    """Verify the ten additive SET operations and their explicit mapping."""
    set_family = next((fam for fam in data.get("families", [])
                       if fam.get("id") == "SET"), None)
    if set_family is None:
        fail("SET family missing")
        return
    if set_family.get("section2Row") != "设置与数据管理":
        fail("SET section-2 row changed")
    set_ids = [op.get("id") for op in set_family.get("operations", [])]
    original_set_ids = [
        "SET-CACHE-INSTALL-SIZE", "SET-SAFE-CLEANUP", "SET-FONT-DIAG",
        "SET-CAPABILITY-STATUS",
    ]
    if set_ids[:4] != original_set_ids:
        fail("original SET operations changed: %r" % set_ids[:4])
    if set_ids[4:] != list(SET_OPERATION_IDS):
        fail("SET additive operations are %r, expected %r"
             % (set_ids[4:], list(SET_OPERATION_IDS)))

    ledger_ids = set()
    try:
        ledger = json.loads(WORK_PACKAGES.read_text(encoding="utf-8"))
        ledger_ids = {item.get("id") for item in ledger["packages"]}
    except (OSError, ValueError, KeyError):
        pass

    tokens = {
        "SET-DEFAULTS-TYPED": ("atomic", "stalerevision", "unknown"),
        "SET-MEMORY-INVENTORY": ("23", "unique", "same-batchid"),
        "SET-MEMORY-SEARCH": ("hybridrecall", "reinforcedcount"),
        "SET-MEMORY-CANDIDATE-REVIEW": ("candidatenotpending", "one transaction"),
        "SET-MEMORY-ORGANIZE": ("same pre-await snapshot", "freshness"),
        "SET-PERSONALIZATION-DOCUMENTS": ("activeid.activerevision", "48kib"),
        "SET-PERSONALIZATION-GENERATE": ("generatenow/savedocument",
                                          "storedasdraft"),
        "SET-USAGE-AGGREGATE": ("null", "not reported"),
        "SET-HISTORY-CLEAR": ("count/max", "stalerevision"),
        "SET-MODELCFG-CLEAR": ("gatewayunregistered", "previous+1"),
    }
    for oid in SET_OPERATION_IDS:
        op = ops.get(oid)
        if op is None:
            fail("required Settings operation missing: %s" % oid)
            continue
        if op.get("goal") != "G02":
            fail("%s: goal must be G02" % oid)
        if op.get("status") != "planned":
            fail("%s: additive operation status must be planned" % oid)
        if op.get("alignment") != "built-in-equivalent":
            fail("%s: unexpected alignment %r" % (oid, op.get("alignment")))
        if op.get("iosState") != "implemented":
            fail("%s: iosState must stay implemented" % oid)
        if op.get("channel") != ["full", "play"]:
            fail("%s: channel must be full+play" % oid)
        if op.get("verify") != ["G12", "G13"]:
            fail("%s: verify goals must be G12+G13" % oid)
        if op.get("workPackages") != SET_OPERATION_WORK_PACKAGES[oid]:
            fail("%s: workPackages %r != %r"
                 % (oid, op.get("workPackages"),
                    SET_OPERATION_WORK_PACKAGES[oid]))
        if op.get("fixtures") != SET_OPERATION_FIXTURES[oid]:
            fail("%s: fixtures %r != %r"
                 % (oid, op.get("fixtures"), SET_OPERATION_FIXTURES[oid]))
        if op.get("commands") != SET_OPERATION_COMMANDS[oid]:
            fail("%s: commands %r != %r"
                 % (oid, op.get("commands"), SET_OPERATION_COMMANDS[oid]))
        for wp in op.get("workPackages", []):
            if wp not in set_family.get("workPackages", []):
                fail("%s: work package %s is not in the SET family mapping"
                     % (oid, wp))
            if ledger_ids and wp not in ledger_ids:
                fail("%s: unknown work package %s" % (oid, wp))
        if not op.get("op") or not op.get("input") or not op.get("output"):
            fail("%s: op/input/output must be nonempty" % oid)
        joined = " ".join([op.get("op", ""), op.get("input", ""),
                           op.get("output", "")]
                          + op.get("assertions", [])).lower()
        for token in tokens[oid]:
            if token not in joined:
                fail("%s: assertions/input lack required token %r"
                     % (oid, token))
        if inv is not None:
            for path in op.get("fixtures", []):
                entry = next((e for e in inv.get("entries", [])
                              if e.get("path") == path), None)
                if entry is None:
                    fail("%s: fixture %s is not inventoried" % (oid, path))
                elif oid not in entry.get("operations", []):
                    fail("%s: fixture %s does not reference the operation"
                         % (oid, path))


def check_settings_fixture_records(inv):
    if inv is None:
        return
    entries = {e["path"]: e for e in inv.get("entries", [])}
    for path, fmt in SET_FIXTURE_FORMATS.items():
        entry = entries.get(path)
        if entry is None:
            fail("settings fixture missing from inventory: %s" % path)
            continue
        if entry.get("format") != fmt:
            fail("%s: format %r != %r" % (path, entry.get("format"), fmt))
        if entry.get("operations") != SET_FIXTURE_OPERATIONS[path]:
            fail("%s: operations %r != %r"
                 % (path, entry.get("operations"),
                    SET_FIXTURE_OPERATIONS[path]))
        if entry.get("expect") != SET_FIXTURE_EXPECT[path]:
            fail("%s: expect metadata differs from the declared vectors"
                 % path)
        if entry.get("determinism") != "stdlib":
            fail("%s: settings fixture must be stdlib-deterministic" % path)
    for path in entries:
        if path in SET_FIXTURE_FORMATS:
            continue
        if entries[path].get("format") in set(SET_FIXTURE_FORMATS.values()):
            fail("unexpected settings fixture path: %s" % path)


def check_attachment_operations(data, ops, inv):
    cha = next((fam for fam in data.get("families", [])
                if fam.get("id") == "CHA"), None)
    if cha is None:
        fail("CHA family missing")
        return
    cha_ids = [op.get("id") for op in cha.get("operations", [])]
    expected_cha_ids = list(ORIGINAL_CHA_OPERATION_IDS) + \
        list(ATTACHMENT_OPERATION_IDS) + [G.GOALCORE_OPERATION_ID]
    if cha_ids != expected_cha_ids:
        fail("CHA operations are %r, expected original six followed by %r "
             "then the approved goal-core operation %r"
             % (cha_ids, list(ATTACHMENT_OPERATION_IDS),
                G.GOALCORE_OPERATION_ID))
    ledger_ids = set()
    try:
        ledger = json.loads(WORK_PACKAGES.read_text(encoding="utf-8"))
        ledger_ids = {item.get("id") for item in ledger["packages"]}
    except (OSError, ValueError, KeyError):
        pass

    required_tokens = {
        "CHA-ATTACH-INGEST-AND": (
            "size", "mime", "content-uri/path", "digest", "idempotent",
            "orphan", "auto-send", "temporary",
        ),
        "CHA-ATTACH-LIFECYCLE-AND": (
            "cancel", "preserves", "late callbacks", "task", "epoch",
            "partial",
        ),
    }
    for oid in ATTACHMENT_OPERATION_IDS:
        op = ops.get(oid)
        if op is None:
            fail("required attachment operation missing: %s" % oid)
            continue
        if op.get("goal") != "G02":
            fail("%s: goal must be G02" % oid)
        # Live status/evidence is validated generically in check_baseline; the
        # initial planned status is frozen only in baselineHistory below.
        if op.get("channel") != ["full", "play"]:
            fail("%s: channel must be full+play" % oid)
        if op.get("verify") != ["G12", "G13"]:
            fail("%s: verify goals must be G12+G13" % oid)
        if op.get("alignment") != "built-in-equivalent":
            fail("%s: unexpected alignment %r" % (oid, op.get("alignment")))
        if op.get("iosState") != "implemented":
            fail("%s: iosState must stay implemented" % oid)
        if op.get("workPackages") != ATTACHMENT_WORK_PACKAGES[oid]:
            fail("%s: workPackages %r != expected %r"
                 % (oid, op.get("workPackages"),
                    ATTACHMENT_WORK_PACKAGES[oid]))
        for wp in op.get("workPackages", []):
            if wp not in cha.get("workPackages", []):
                fail("%s: work package %s is not in the CHA family mapping"
                     % (oid, wp))
            if ledger_ids and wp not in ledger_ids:
                fail("%s: unknown work package %s" % (oid, wp))
        if op.get("fixtures") != ATTACHMENT_FIXTURES[oid]:
            fail("%s: fixtures %r != expected %r"
                 % (oid, op.get("fixtures"), ATTACHMENT_FIXTURES[oid]))
        joined = " ".join(op.get("assertions", [])).lower()
        for token in required_tokens[oid]:
            if token not in joined:
                fail("%s: assertions lack required token %r" % (oid, token))
        if inv is not None:
            entry = next((e for e in inv.get("entries", [])
                          if e.get("path") == ATTACHMENT_FIXTURES[oid][0]),
                         None)
            if entry is None or oid not in entry.get("operations", []):
                fail("%s: fixture %s does not reference the operation"
                     % (oid, ATTACHMENT_FIXTURES[oid][0]))

    # ---- Approved goal-core manual compaction operation -------------------
    compact = ops.get(G.GOALCORE_OPERATION_ID)
    if compact is None:
        fail("required goal-core operation missing: %s"
             % G.GOALCORE_OPERATION_ID)
    else:
        if compact.get("goal") != "G02":
            fail("%s: goal must be G02" % G.GOALCORE_OPERATION_ID)
        if compact.get("status") != "planned":
            fail("%s: goal-core operation status must be planned"
                 % G.GOALCORE_OPERATION_ID)
        if compact.get("channel") != ["full", "play"]:
            fail("%s: channel must be full+play" % G.GOALCORE_OPERATION_ID)
        if compact.get("verify") != ["G12", "G13"]:
            fail("%s: verify goals must be G12+G13" % G.GOALCORE_OPERATION_ID)
        if compact.get("alignment") != "built-in-equivalent":
            fail("%s: unexpected alignment %r"
                 % (G.GOALCORE_OPERATION_ID, compact.get("alignment")))
        if compact.get("iosState") != "implemented":
            fail("%s: iosState must stay implemented"
                 % G.GOALCORE_OPERATION_ID)
        for wp in G.GOALCORE_OPERATION_WORK_PACKAGES:
            if wp not in cha.get("workPackages", []):
                fail("%s: goal-core work package %s not in the CHA family"
                     % (G.GOALCORE_OPERATION_ID, wp))
        joined = " ".join(compact.get("assertions", [])).lower()
        for token in ("reservation", "writer transaction"):
            if token not in joined:
                fail("%s: assertions lack required token %r"
                     % (G.GOALCORE_OPERATION_ID, token))

    if "PRV-IDENTITY-WIRE-SPLIT-AND" in ops:
        fail("a new model-identity operation was added; the wire split must "
             "stay as assertions under PRV-CONFIG-VALIDATE")


def check_wire_identity(ops):
    prv = ops.get("PRV-CONFIG-VALIDATE")
    if prv is None:
        fail("PRV-CONFIG-VALIDATE missing")
        return
    expected_tail = [
        "display rename never changes the durable wire model id",
        "request builder emits ModelProfile.remoteModelID, never displayName "
        "or a preset alias",
    ]
    if prv.get("assertions", [])[-2:] != expected_tail:
        fail("PRV-CONFIG-VALIDATE must end with the two additive wire-identity "
             "assertions")
    joined = " ".join(prv.get("assertions", [])).lower()
    for token in ("display rename never changes", "remotemodelid",
                  "never displayname", "preset alias"):
        if token not in joined:
            fail("PRV-CONFIG-VALIDATE lacks wire-identity token %r" % token)


def check_plan_authority():
    """The attachment contract must stay anchored in the plan, not invented."""
    try:
        text = PLAN.read_text(encoding="utf-8")
    except OSError as exc:
        fail("cannot read plan for attachment authority: %s" % exc)
        return
    p22 = re.search(r"^\| P2\.2 .*$", text, re.M)
    if p22 is None or "附件" not in p22.group(0):
        fail("plan P2.2 no longer lists 附件")
    g02 = re.search(r"^\| G02 .*$", text, re.M)
    if g02 is None or "附件" not in g02.group(0):
        fail("plan G02 row no longer lists 附件")
    for phrase in (
        "收到分享时先显示来源与目标任务/项目",
        "接收不等于自动发送模型/执行命令",
        "验证内容、路径与大小",
        "不信任外部自报taskID",
    ):
        if phrase not in text:
            fail("plan section 17.5 lost attachment requirement: %s" % phrase)


def check_baseline(inv):
    if not BASELINE.exists():
        fail("feature-baseline.json missing")
        return None
    data = json.loads(BASELINE.read_text(encoding="utf-8"))
    ops = {}
    for fam in data["families"]:
        for op in fam["operations"]:
            if op["id"] in ops:
                fail("duplicate operation id: %s" % op["id"])
            ops[op["id"]] = op
            if op["goal"] not in GOALS:
                fail("%s: bad goal %s" % (op["id"], op["goal"]))
            if not op["verify"] or not set(op["verify"]) <= GOALS:
                fail("%s: bad verify goals" % op["id"])
            if not set(op["channel"]) <= {"full", "play"}:
                fail("%s: bad channel" % op["id"])
            status = op.get("status")
            if status not in STATUSES:
                fail("%s: unknown status %r (allowed: %s)"
                     % (op["id"], status, ", ".join(STATUSES)))
            elif status in VERIFIED_STATUSES and \
                    evidence_references(op) is None:
                fail("%s: status %s requires a nonempty evidence list"
                     % (op["id"], status))
            elif "evidence" in op and evidence_references(op) is None:
                fail("%s: evidence must be a nonempty list of nonempty "
                     "references" % op["id"])
            if op["alignment"] not in data["alignmentLegend"]:
                fail("%s: unknown alignment %s" % (op["id"], op["alignment"]))
            if op["iosState"] == "not-on-ios" and op["ios"]:
                fail("%s: not-on-ios must not claim ios paths" % op["id"])
            for ev in op["ios"]:
                f = ROOT / ev["path"]
                if not f.exists():
                    fail("%s: ios evidence path missing: %s" % (op["id"], ev["path"]))
                elif ev["symbol"] not in f.read_text(encoding="utf-8",
                                                     errors="replace"):
                    fail("%s: ios symbol %s not found in %s"
                         % (op["id"], ev["symbol"], ev["path"]))
    check_family_coverage(data)
    check_work_package_links(data)
    check_attachment_fixture_records(inv)
    check_baseline_history(data, ops, inv)
    check_attachment_operations(data, ops, inv)
    check_settings_operations(data, ops, inv)
    check_settings_fixture_records(inv)
    check_wire_identity(ops)
    check_plan_authority()
    return ops


def check_cross_references(inv, ops):
    if inv is None or ops is None:
        return
    fixture_paths = {e["path"] for e in inv["entries"]}
    for op in ops.values():
        for fx in op.get("fixtures", []):
            if fx not in fixture_paths:
                fail("%s references unknown fixture %s" % (op["id"], fx))
    for e in inv["entries"]:
        for oid in e["operations"]:
            if oid not in ops:
                fail("inventory %s references unknown operation %s"
                     % (e["path"], oid))
    for oid, fixtures in ATTACHMENT_FIXTURES.items():
        for path in fixtures:
            entry = next((e for e in inv["entries"]
                          if e["path"] == path), None)
            if entry is None:
                fail("%s: missing attachment fixture %s" % (oid, path))
            elif oid not in entry.get("operations", []):
                fail("%s: fixture %s does not map back to the operation"
                     % (oid, path))


def main(argv):
    if len(argv) > 1 and argv[1] not in ("--check",):
        print("usage: check-fixtures.py [--check]   (read-only validator)")
        return 2
    inv = check_inventory()
    if inv is not None:
        check_structures(inv)
    ops = check_baseline(inv)
    check_cross_references(inv, ops)
    n_fam = n_ops = 0
    if ops is not None:
        n_ops = len(ops)
        n_fam = len(json.loads(BASELINE.read_text(encoding="utf-8"))["families"])
    for w in warnings:
        print("WARN %s" % w)
    for f_ in failures:
        print("FAIL %s" % f_)
    print("check-fixtures: %d inventory entries, %d families, %d operations, "
          "%d failures" % (0 if inv is None else len(inv["entries"]),
                           n_fam, n_ops, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
