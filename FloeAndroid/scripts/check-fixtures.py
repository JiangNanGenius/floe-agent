#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read-only validator for the G01 feature baseline and synthetic fixtures.

Verifies, without writing anything:
  1. Fixture integrity: every inventory.json entry exists with matching
     SHA-256 and byte count; no fixture file is absent from the inventory.
  2. Expected basic structures: per-format structural probes must satisfy the
     recorded expectations (DOCX/XLSX/PPTX parts and content, PDF/xref,
     DXF/OBJ entity and vertex counts, WAV header, MP4 box scan, PNG IHDR,
     SRT/VTT cue counts, CSV formula cell, JSON schemas, encoding traits).
  3. Baseline references: the feature baseline parses, operation IDs are
     unique, every iOS evidence path+symbol still exists in the current
     working tree, goals are G01-G15, channels are full/play, every
     referenced fixture exists, and every inventory operation ID exists.
  4. Coverage: all section-2 feature rows of the plan document are claimed
     by exactly one family; FND is the only family allowed to omit a row and
     must appear exactly once. Family work-package IDs must exist in the
     85-package ledger.

Operation statuses use the plan's six-state vocabulary (planned,
implementing, component_verified, app_verified, samsung_verified, delivered).
The four verified states require a nonempty ``evidence`` list of nonempty
references. This is structural checking only: it does not prove a referenced
command, test or device run happened, and it is not qualification evidence.

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


def fail(msg):
    failures.append(msg)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


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
    if not INVENTORY.exists():
        fail("inventory.json missing")
        return None
    inv = json.loads(INVENTORY.read_text(encoding="utf-8"))
    paths = set()
    for e in inv["entries"]:
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
    # no unrecorded extra files (excluding generator/README/inventory/pyc)
    known = {e["path"] for e in inv["entries"]}
    for p in FIXDIR.rglob("*"):
        if p.is_file():
            rel = str(p.relative_to(FIXDIR))
            if rel in ("inventory.json", "README.md", "generate.py"):
                continue
            if rel.startswith("__pycache__") or rel.endswith(".pyc"):
                continue
            if rel not in known:
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


STRUCTURE_CHECKS = {
    "docx": check_docx, "docx-corrupt": check_docx,
    "xlsx": check_xlsx, "pptx": check_pptx,
    "pdf": check_pdf, "pdf-corrupt": check_pdf,
    "dxf": check_dxf, "obj": check_obj, "wav": check_wav, "mp4": check_mp4,
    "png": check_png, "srt": check_srt, "vtt": check_vtt, "csv": check_csv,
    "python": check_code, "kotlin": check_code, "typescript": check_code,
    "text": check_encoding_text, "notes-json": check_notes_json,
    "canvas-json": check_canvas_json, "svg": check_svg,
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


def check_baseline():
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


def main(argv):
    if len(argv) > 1 and argv[1] not in ("--check",):
        print("usage: check-fixtures.py [--check]   (read-only validator)")
        return 2
    inv = check_inventory()
    if inv is not None:
        check_structures(inv)
    ops = check_baseline()
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
