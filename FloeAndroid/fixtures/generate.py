#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Deterministic synthetic fixture generator for Floe Android G01.

Generates small, valid, fully synthetic test documents under this fixtures/
directory plus inventory.json. All content is authored here; no customer data,
no network access and no credentials are used.

Modes:
  python3 generate.py            Generate/refresh fixtures and inventory.json.
  python3 generate.py --check    Read-only verification: regenerate every
                                 stdlib-deterministic fixture in memory and
                                 compare bytes + SHA-256 with what is on disk.
                                 NEVER writes or rewrites any file.
  python3 generate.py --verify-ffmpeg
                                 In addition to --check, re-run the pinned
                                 ffmpeg recipe into the repository scratch
                                 area and compare. Still never rewrites
                                 fixtures/.

Stdlib output is byte-reproducible (ZIP_STORED, fixed timestamps, fixed
ordering, zlib level 0 for PNG). The MP4 sample depends on the recorded ffmpeg
version/argv; see README.md for the reproducibility note and coverage gaps.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib
from io import BytesIO
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent  # repository root (contains FloeAndroid/)
INVENTORY_NAME = "inventory.json"

FFMPEG_RECIPES = {
    "media/video/floe-test.mp4": [
        "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc=size=320x240:rate=15:duration=1",
        "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=44100:duration=1",
        "-c:v", "libx264", "-preset", "ultrafast", "-profile:v", "baseline",
        "-pix_fmt", "yuv420p", "-g", "15",
        "-c:a", "aac", "-b:a", "48k",
        "-shortest", "-movflags", "+faststart",
    ],
}

XML_DECL = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def zip_bytes(entries):
    """Deterministic ZIP: fixed order, ZIP_STORED, fixed 1980-01-01 stamp."""
    buf = BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, payload in entries:
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            info.external_attr = 0o644 << 16
            if isinstance(payload, str):
                payload = payload.encode("utf-8")
            zf.writestr(info, payload)
    return buf.getvalue()


def pdf_document(pages):
    """Minimal but structurally valid PDF 1.4 with computed xref offsets."""
    catalog_num, pages_num = 1, 2
    page_defs = []  # (page_obj, content_obj)
    next_num = 3
    for _ in pages:
        page_defs.append((next_num, next_num + 1))
        next_num += 2
    font_num = next_num
    kids = " ".join("%d 0 R" % n for n, _ in page_defs)
    objs = []
    objs.append((catalog_num, "<< /Type /Catalog /Pages %d 0 R >>" % pages_num))
    objs.append((pages_num,
                 "<< /Type /Pages /Count %d /Kids [%s] >>" % (len(page_defs), kids)))
    for (page_num, content_num), text in zip(page_defs, pages):
        objs.append((page_num,
                     "<< /Type /Page /Parent %d 0 R /MediaBox [0 0 612 792] "
                     "/Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>"
                     % (pages_num, font_num, content_num)))
        stream = ("BT /F1 24 Tf 72 700 Td (%s) Tj ET" % text).encode("latin-1")
        objs.append((content_num,
                     "<< /Length %d >>\nstream\n%s\nendstream"
                     % (len(stream), stream.decode("latin-1"))))
    objs.append((font_num,
                 "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"))

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    max_num = max(n for n, _ in objs)
    for num, body in objs:
        offsets[num] = len(out)
        out += ("%d 0 obj\n" % num).encode("ascii")
        out += body.encode("latin-1")
        out += b"\nendobj\n"
    xref_pos = len(out)
    out += ("xref\n0 %d\n" % (max_num + 1)).encode("ascii")
    out += b"0000000000 65535 f \n"
    for num in range(1, max_num + 1):
        out += ("%010d 00000 n \n" % offsets[num]).encode("ascii")
    out += (("trailer\n<< /Size %d /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n"
             % (max_num + 1, catalog_num, xref_pos)).encode("ascii"))
    return bytes(out)


def png_8x8_gradient():
    """8x8 RGB PNG using zlib stored blocks (deterministic byte-for-byte)."""
    raw = bytearray()
    for y in range(8):
        raw.append(0)  # filter type: None
        for x in range(8):
            raw += bytes([x * 32, y * 32, 255 - (x + y) * 12])
    comp = zlib.compressobj(0, zlib.DEFLATED, 15)
    data = comp.compress(bytes(raw)) + comp.flush()

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", data)
            + chunk(b"IEND", b""))


def sine_wav(sample_rate=44100, frames=22050, freq=440.0):
    import math
    pcm = bytearray()
    peak = 0
    for i in range(frames):
        v = int(29000 * math.sin(2.0 * math.pi * freq * i / sample_rate))
        peak = max(peak, abs(v))
        pcm += struct.pack("<h", v)
    header = (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVE"
              + b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, sample_rate,
                                      sample_rate * 2, 2, 16)
              + b"data" + struct.pack("<I", len(pcm)))
    return header + bytes(pcm), {"sampleRate": sample_rate, "frames": frames,
                                 "seconds": frames / sample_rate,
                                 "channels": 1, "bits": 16,
                                 "peakAmplitude": peak}


# --------------------------------------------------------------------------
# OOXML content
# --------------------------------------------------------------------------

DOCX_PARAGRAPH_TEXTS = [
    "手记 § Baseline 🧪",
    "Floe G01 synthetic paragraph with bold and italic runs.",
    "مرحبا שלום mixed RTL",
    "alpha list one",
    "beta list two",
    "γ § 3 list three",
]


def build_docx(with_content_types=True):
    ct = XML_DECL + (
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
        '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>'
        '</Types>')
    root_rels = XML_DECL + (
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>')
    doc_rels = XML_DECL + (
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>'
        '</Relationships>')
    styles = XML_DECL + (
        '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
        '<w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/>'
        '<w:pPr><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>'
        '</w:styles>')
    numbering = XML_DECL + (
        '<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/>'
        '<w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl></w:abstractNum>'
        '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>')
    ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'

    def para(text, style=None, bold=False, italic=False, list_item=False):
        ppr = ""
        if style:
            ppr += '<w:pStyle w:val="%s"/>' % style
        if list_item:
            ppr += '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>'
        rpr = ("<w:rPr>%s%s</w:rPr>" % ("<w:b/>" if bold else "",
                                         "<w:i/>" if italic else "")).replace("<w:rPr></w:rPr>", "")
        return "<w:p>%s<w:r>%s<w:t xml:space=\"preserve\">%s</w:t></w:r></w:p>" % (
            ("<w:pPr>%s</w:pPr>" % ppr) if ppr else "", rpr, text)

    body = "".join([
        para(DOCX_PARAGRAPH_TEXTS[0], style="Heading1"),
        para(DOCX_PARAGRAPH_TEXTS[1], bold=True),
        para(DOCX_PARAGRAPH_TEXTS[2], italic=True),
        para(DOCX_PARAGRAPH_TEXTS[3], list_item=True),
        para(DOCX_PARAGRAPH_TEXTS[4], list_item=True),
        para(DOCX_PARAGRAPH_TEXTS[5], list_item=True),
        '<w:p><w:pPr><w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:pPr></w:p>',
    ])
    document = XML_DECL + (
        '<w:document %s><w:body>%s</w:body></w:document>' % (ns, body))
    entries = []
    if with_content_types:
        entries.append(("[Content_Types].xml", ct))
    entries += [
        ("_rels/.rels", root_rels),
        ("word/document.xml", document),
        ("word/_rels/document.xml.rels", doc_rels),
        ("word/styles.xml", styles),
        ("word/numbering.xml", numbering),
    ]
    return zip_bytes(entries)


XLSX_SHEET_NAME = "数据 § Sales"
XLSX_SHARED_STRINGS = ["名称 Name", "价格", "Σ total 🧪",
                       "widget", "=HYPERLINK(\"https://example.invalid/x\")"]


def build_xlsx(with_error_formulas=True):
    sheet_name = XLSX_SHEET_NAME
    strings = XLSX_SHARED_STRINGS[:4]
    cells = [
        ('<c r="A1" t="s"><v>0</v></c>', "header string"),
        ('<c r="B1" t="s"><v>1</v></c>', ""),
        ('<c r="A2" t="s"><v>3</v></c>', ""),
        ('<c r="B2"><v>10</v></c>', ""),
        ('<c r="B3"><v>20</v></c>', ""),
        ('<c r="B4"><v>30</v></c>', ""),
        ('<c r="C2"><f>SUM(B2:B4)</f><v>60</v></c>', "formula"),
        ('<c r="A5" t="s"><v>2</v></c>', ""),
    ]
    if with_error_formulas:
        strings = XLSX_SHARED_STRINGS  # includes injection literal
        cells += [
            ('<c r="D2"><f>10/0</f><v>#DIV/0!</v></c>', "error"),
            ('<c r="A7" t="s"><v>4</v></c>', "injection literal"),
        ]
    sst = XML_DECL + (
        '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'count="%d" uniqueCount="%d">%s</sst>'
        % (len(strings), len(strings),
           "".join("<si><t>%s</t></si>" % s for s in strings)))
    worksheet = XML_DECL + (
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<sheetData>%s</sheetData></worksheet>'
        % ("".join('<row r="%s">%s</row>' % pair
                   for pair in _xlsx_rows([c for c, _ in cells]))))
    ct = XML_DECL + (
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
        '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
        '</Types>')
    root_rels = XML_DECL + (
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '</Relationships>')
    workbook = XML_DECL + (
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="%s" sheetId="1" r:id="rId1"/></sheets></workbook>' % sheet_name)
    wb_rels = XML_DECL + (
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
        '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>'
        '</Relationships>')
    styles = XML_DECL + (
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="1"><font><sz val="11"/></font></fonts>'
        '<fills count="1"><fill><patternFill patternType="none"/></fill></fills>'
        '<borders count="1"><border/></borders>'
        '<cellStyleXfs count="1"><xf/></cellStyleXfs>'
        '<cellXfs count="1"><xf xfId="0"/></cellXfs></styleSheet>')
    return zip_bytes([
        ("[Content_Types].xml", ct),
        ("_rels/.rels", root_rels),
        ("xl/workbook.xml", workbook),
        ("xl/_rels/workbook.xml.rels", wb_rels),
        ("xl/styles.xml", styles),
        ("xl/sharedStrings.xml", sst),
        ("xl/worksheets/sheet1.xml", worksheet),
    ])


def _xlsx_rows(cells):
    from collections import OrderedDict
    rows = OrderedDict()
    for cell in cells:
        ref = cell.split('r="')[1].split('"')[0]
        col = "".join(ch for ch in ref if ch.isalpha())
        r = "".join(ch for ch in ref if ch.isdigit())
        rows.setdefault(r, []).append(cell)
    ordered = sorted(rows.keys(), key=int)
    return [(r, "".join(rows[r])) for r in ordered]


def build_pptx():
    ns = ('xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
          'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"')
    title = PPTX_TITLE
    bullets = PPTX_BULLETS
    ct = XML_DECL + (
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
        '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>'
        '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>'
        '<Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'
        '<Override PartName="/ppt/slides/slide2.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'
        '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>'
        '</Types>')
    root_rels = XML_DECL + (
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>'
        '</Relationships>')
    pres = XML_DECL + (
        '<p:presentation %s><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
        '<p:sldIdLst><p:sldId id="256" r:id="rId2"/><p:sldId id="257" r:id="rId3"/></p:sldIdLst>'
        '<p:sldSz cx="9144000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>' % ns)
    pres_rels = XML_DECL + (
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>'
        '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/>'
        '</Relationships>')
    master = XML_DECL + (
        '<p:sldMaster %s><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/>'
        '<p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>'
        '<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>' % ns)
    master_rels = XML_DECL + (
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>'
        '</Relationships>')
    layout = XML_DECL + (
        '<p:sldLayout %s type="blank"><p:cSld><p:spTree><p:nvGrpSpPr>'
        '<p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
        '<p:grpSpPr/></p:spTree></p:cSld></p:sldLayout>' % ns)
    layout_rels = XML_DECL + (
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>'
        '</Relationships>')

    def sp(ph_type, sid, name, texts):
        txbody = '<p:txBody><a:bodyPr/><a:lstStyle/>%s</p:txBody>' % "".join(
            "<a:p><a:r><a:t>%s</a:t></a:r></a:p>" % t for t in texts)
        return ('<p:sp><p:nvSpPr><p:cNvPr id="%d" name="%s"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>'
                '<p:nvPr><p:ph type="%s"/></p:nvPr></p:nvSpPr><p:spPr/>%s</p:sp>'
                % (sid, name, ph_type, txbody))

    slide1 = XML_DECL + (
        '<p:sld %s><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/>'
        '<p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>%s</p:spTree></p:cSld></p:sld>'
        % (ns, sp("title", 2, "Title 1", [title])))
    slide2 = XML_DECL + (
        '<p:sld %s><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/>'
        '<p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>%s%s</p:spTree></p:cSld></p:sld>'
        % (ns, sp("title", 2, "Title 1", ["Bullet slide"]),
           sp("body", 3, "Content 1", bullets)))
    slide_rels = XML_DECL + (
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>'
        '</Relationships>')
    theme = XML_DECL + (
        '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Floe">'
        '<a:themeElements><a:clrScheme name="Floe"><a:dk1><a:srgbClr val="000000"/></a:dk1>'
        '<a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="000000"/></a:dk2>'
        '<a:lt2><a:srgbClr val="FFFFFF"/></a:lt2><a:accent1><a:srgbClr val="3B82F6"/></a:accent1>'
        '<a:accent2><a:srgbClr val="8B5CF6"/></a:accent2><a:accent3><a:srgbClr val="22C55E"/></a:accent3>'
        '<a:accent4><a:srgbClr val="EAB308"/></a:accent4><a:accent5><a:srgbClr val="F97316"/></a:accent5>'
        '<a:accent6><a:srgbClr val="EF4444"/></a:accent6><a:hlink><a:srgbClr val="3B82F6"/></a:hlink>'
        '<a:folHlink><a:srgbClr val="8B5CF6"/></a:folHlink></a:clrScheme>'
        '<a:fontScheme name="Floe"><a:majorFont><a:latin typeface="Calibri"/>'
        '<a:ea typeface=""/><a:cs typeface=""/></a:majorFont>'
        '<a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>'
        '<a:fmtScheme name="Floe"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
        '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>'
        '<a:lnStyleLst><a:ln><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
        '<a:ln><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
        '<a:ln><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>'
        '<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle>'
        '<a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>'
        '<a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
        '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>'
        '</a:fmtScheme></a:themeElements></a:theme>')
    return zip_bytes([
        ("[Content_Types].xml", ct),
        ("_rels/.rels", root_rels),
        ("ppt/presentation.xml", pres),
        ("ppt/_rels/presentation.xml.rels", pres_rels),
        ("ppt/theme/theme1.xml", theme),
        ("ppt/slideMasters/slideMaster1.xml", master),
        ("ppt/slideMasters/_rels/slideMaster1.xml.rels", master_rels),
        ("ppt/slideLayouts/slideLayout1.xml", layout),
        ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", layout_rels),
        ("ppt/slides/slide1.xml", slide1),
        ("ppt/slides/_rels/slide1.xml.rels", slide_rels),
        ("ppt/slides/slide2.xml", slide2),
        ("ppt/slides/_rels/slide2.xml.rels", slide_rels),
    ]), title, bullets


PPTX_TITLE, PPTX_BULLETS = "手记 § Deck 🧪", ["alpha bullet", "β § two", "done bullet"]

DXF_LINES = 2
DXF_EXPECT = {
    "acadver": "AC1009",
    "layers": ["0", "hidden", "文本-Text"],
    "entities": {"LINE": 2, "CIRCLE": 1, "TEXT": 1},
    "textValue": "手记 § test",
}


def build_dxf():
    parts = []
    parts += ["0", "SECTION", "2", "HEADER", "9", "$ACADVER", "1", DXF_EXPECT["acadver"], "0", "ENDSEC"]
    parts += ["0", "SECTION", "2", "TABLES", "0", "TABLE", "2", "LAYER",
              "70", str(len(DXF_EXPECT["layers"]))]
    for layer in DXF_EXPECT["layers"]:
        parts += ["0", "LAYER", "2", layer, "70", "0", "62", "7", "6", "Continuous"]
    parts += ["0", "ENDTAB", "0", "ENDSEC"]
    parts += ["0", "SECTION", "2", "ENTITIES"]
    parts += ["0", "LINE", "8", "0", "10", "0", "20", "0", "11", "40", "21", "30"]
    parts += ["0", "LINE", "8", "hidden", "10", "40", "20", "0", "11", "40", "21", "30"]
    parts += ["0", "CIRCLE", "8", "0", "10", "20", "20", "15", "40", "8"]
    parts += ["0", "TEXT", "8", "文本-Text", "10", "12", "20", "34", "40", "2.5",
              "1", DXF_EXPECT["textValue"]]
    parts += ["0", "ENDSEC", "0", "EOF"]
    return "\n".join(parts) + "\n"


OBJ_EXPECT = {
    "vertices": 8, "faces": 6, "normals": 0, "group": "cube § main",
}


def build_obj():
    lines = [
        "# Floe G01 synthetic cube — 手记 § 测试 🧪",
        "o %s" % OBJ_EXPECT["group"],
    ]
    for z in (0, 1):
        for y in (0, 1):
            for x in (0, 1):
                lines.append("v %d %d %d" % (x, y, z))
    faces = [(1, 2, 4, 3), (5, 7, 8, 6), (1, 5, 6, 2),
             (3, 7, 8, 4), (1, 3, 4, 2), (5, 2, 6, 8)]
    for f in faces:
        lines.append("f %s" % " ".join(str(i) for i in f))
    return "\n".join(lines) + "\n"


NOTES_EXPECT = {
    "schema": "floe-android.notes.sample.v0",
    "title": "手记 § Baseline 🧪",
    "revision": 3,
    "blockCount": 3,
    "blockTypes": ["text", "todo", "code"],
    "chatSessionId": None,
    "attachmentRef": "assets/png/gradient-8.png",
}


def build_notes_json():
    doc = {
        "schema": NOTES_EXPECT["schema"],
        "title": NOTES_EXPECT["title"],
        "revision": NOTES_EXPECT["revision"],
        "blocks": [
            {"id": "b1", "type": "text", "text": "Independent notes workspace — 手记不是聊天。"},
            {"id": "b2", "type": "todo", "checked": False, "text": "β § two"},
            {"id": "b3", "type": "code", "language": "python",
             "text": "print('Floe')  # γ § 3"},
        ],
        "attachments": [{"id": "att-1", "fixtureRef": NOTES_EXPECT["attachmentRef"]}],
        "chatSessionId": None,
    }
    return json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


CANVAS_EXPECT = {
    "schema": "floe-android.canvas.sample.v0",
    "revision": 7,
    "nodeCount": 3,
    "edgeCount": 2,
    "danglingAssetRefs": 1,
    "knownAssetRefs": 1,
    "owner": "task-g01-demo",
}


def build_canvas_json():
    doc = {
        "schema": CANVAS_EXPECT["schema"],
        "revision": CANVAS_EXPECT["revision"],
        "ownerTaskId": CANVAS_EXPECT["owner"],
        "nodes": [
            {"id": "n1", "kind": "text", "text": "手记 § node 🧪"},
            {"id": "n2", "kind": "asset", "assetId": "att-known",
             "fixtureRef": "assets/png/gradient-8.png"},
            {"id": "n3", "kind": "asset", "assetId": "att-missing", "fixtureRef": None},
        ],
        "edges": [{"from": "n1", "to": "n2"}, {"from": "n2", "to": "n3"}],
        "notes": "n3 references a missing asset on purpose (failure path).",
    }
    return json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


SAMPLE_PY = '''# Floe G01 synthetic Python sample — 手记 § 测试 🧪
PI_APPROX = 22 / 7


def area(radius):
    """Circle area helper with unicode docstring — α β γ."""
    return 3.14159 * radius * radius


if __name__ == "__main__":
    print(area(2))
'''

SAMPLE_KT = '''// Floe G01 synthetic Kotlin sample — 手记 § 测试 🧪
package com.floe.android.fixtures

fun greeting(): String = "你好, Floe"

fun main() {
    println(greeting())
}
'''

SAMPLE_TS = '''// Floe G01 synthetic TypeScript sample — 手记 § 测试 🧪
export const greeting = "Hola, Floe";

export function twice(n: number): number {
  return n * 2;
}
'''

CSV_EXPECT = {
    "rows": 4,
    "formulaCell": '=HYPERLINK("https://example.invalid/x")',
    "note": "formula-like text must render as text, never execute",
}

SRT_EXPECT = {"cueCount": 3, "lastCueText": "γ 结束 🧪"}
VTT_EXPECT = {"cueCount": 2, "header": "WEBVTT"}

SVG_BODY = (
    '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">'
    '<path d="M3 3h18v18H3z" fill="none" stroke="#3B82F6"/>'
    '<circle cx="12" cy="12" r="4" fill="#22C55E"/>'
    '</svg>\n')


def build_srt():
    cues = [
        (1, "00:00:00,000", "00:00:00,500", "手记 § start"),
        (2, "00:00:00,500", "00:00:01,000", "مرحبا subtitle"),
        (3, "00:00:01,000", "00:00:01,400", SRT_EXPECT["lastCueText"]),
    ]
    out = []
    for idx, start, end, text in cues:
        out.append("%d\n%s --> %s\n%s\n" % (idx, start, end, text))
    return "\n".join(out)


def build_vtt():
    return ("WEBVTT\n\n"
            "00:00:00.000 --> 00:00:00.700\nβ § two\n\n"
            "00:00:00.700 --> 00:00:01.200\ntail 手记\n")


def csv_body():
    cell = CSV_EXPECT["formulaCell"].replace('"', '""')
    return ('名称 Name,价格,备注\n'
            'widget,10,"plain text"\n'
            'gadget,20,"%s"\n'
            '测试,30,"=1+1 literal text"\n' % cell)


# --------------------------------------------------------------------------
# ffmpeg (optional, pinned recipe)
# --------------------------------------------------------------------------

def ffmpeg_binary():
    for candidate in (os.environ.get("FFMPEG_BIN"), shutil.which("ffmpeg")):
        if candidate and os.path.exists(candidate):
            return candidate
    return None


def ffmpeg_version(binary):
    try:
        out = subprocess.run([binary, "-version"], capture_output=True,
                             text=True, timeout=30).stdout
        return out.splitlines()[0] if out else "unknown"
    except Exception:
        return "unknown"


SCRATCH_DIR = REPO_ROOT / "Local" / "Scratch" / "android-g01-fixtures"


def run_ffmpeg(recipe_args, dest: Path):
    binary = ffmpeg_binary()
    if binary is None:
        return None, "ffmpeg-unavailable"
    SCRATCH_DIR.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix="floe-fixture-", dir=str(SCRATCH_DIR)))
    tmp_path = tmp / dest.name
    try:
        proc = subprocess.run([binary] + recipe_args + [str(tmp_path)],
                              capture_output=True, text=True, timeout=180)
        if proc.returncode != 0 or not tmp_path.exists():
            return None, (proc.stderr or proc.stdout or "ffmpeg-failed")[:400]
        return tmp_path.read_bytes(), None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------
# fixture table
# --------------------------------------------------------------------------

def build_stdlib_fixtures():
    """Returns dict path -> (bytes, format, expect)."""
    fx = {}
    fx["office/docx/paragraphs-unicode.docx"] = (
        build_docx(True), "docx", {
            "parts": ["[Content_Types].xml", "word/document.xml",
                      "word/styles.xml", "word/numbering.xml"],
            "paragraphCount": 7, "listItemCount": 3,
            "headingStyle": "Heading1", "texts": DOCX_PARAGRAPH_TEXTS})
    fx["office/docx/corrupt-missing-content-types.docx"] = (
        build_docx(False), "docx-corrupt", {
            "zipReadable": True, "hasContentTypes": False,
            "expectedFailure": "OPC reader must reject with a structured error"})
    fx["office/xlsx/formula-basic.xlsx"] = (
        build_xlsx(False), "xlsx", {
            "sheetCount": 1, "sheetName": XLSX_SHEET_NAME,
            "formulas": {"C2": "SUM(B2:B4)"},
            "cachedValues": {"C2": "60"}, "numericCells": 3})
    fx["office/xlsx/formula-error-and-injection.xlsx"] = (
        build_xlsx(True), "xlsx", {
            "sheetCount": 1, "sheetName": XLSX_SHEET_NAME,
            "formulas": {"C2": "SUM(B2:B4)", "D2": "10/0"},
            "errorCells": {"D2": "#DIV/0!"},
            "cachedValues": {"C2": "60"},
            "injectionString": XLSX_SHARED_STRINGS[4],
            "numericCells": 3})
    fx["office/pptx/two-slides.pptx"] = (
        build_pptx()[0], "pptx", {
            "slideCount": 2, "slideParts": ["ppt/slides/slide1.xml",
                                            "ppt/slides/slide2.xml"],
            "titleText": PPTX_TITLE, "bulletCount": 3})
    fx["pdf/two-page-basic.pdf"] = (
        pdf_document(["Floe G01 fixture page one",
                      "Floe G01 fixture page two"]), "pdf", {
            "header": "%PDF-1.4", "pageCount": 2, "rootObject": 1,
            "containsTexts": ["Floe G01 fixture page one",
                              "Floe G01 fixture page two"]})
    full = fx["pdf/two-page-basic.pdf"][0]
    fx["pdf/truncated.pdf"] = (
        full[: len(full) // 2], "pdf-corrupt", {
            "header": "%PDF-1.4", "hasXref": False,
            "expectedFailure": "parser must reject incomplete xref, not render pages"})
    fx["cad/dxf/lines-text-layers.dxf"] = (
        build_dxf().encode("utf-8"), "dxf", DXF_EXPECT)
    fx["cad/obj/cube.obj"] = (
        build_obj().encode("utf-8"), "obj", OBJ_EXPECT)
    fx["notes/note-basic.json"] = (
        build_notes_json().encode("utf-8"), "notes-json", NOTES_EXPECT)
    fx["canvas/canvas-with-assets.json"] = (
        build_canvas_json().encode("utf-8"), "canvas-json", CANVAS_EXPECT)
    fx["text/code/sample.py"] = (SAMPLE_PY.encode("utf-8"), "python",
                                 {"symbols": ["PI_APPROX", "area"],
                                  "containsText": "手记 § 测试 🧪"})
    fx["text/code/sample.kt"] = (SAMPLE_KT.encode("utf-8"), "kotlin",
                                 {"symbols": ["greeting", "main"],
                                  "containsText": "你好, Floe"})
    fx["text/code/sample.ts"] = (SAMPLE_TS.encode("utf-8"), "typescript",
                                 {"symbols": ["greeting", "twice"],
                                  "containsText": "Hola, Floe"})
    crlf = "line one\r\nline two β § 2\r\nline three\r\n"
    fx["text/encoding/crlf.txt"] = (crlf.encode("utf-8"), "text",
                                    {"crlfLineCount": 3, "preserved": "CRLF"})
    fx["text/encoding/utf8-bom.txt"] = (b"\xef\xbb\xbf" + "BOM 手记 🧪".encode("utf-8"),
                                         "text", {"startsUtf8Bom": True})
    fx["text/encoding/long-line.txt"] = (("x" * 4096 + "\n").encode("utf-8"), "text",
                                         {"longestLineChars": 4096})
    fx["text/csv/formula-injection.csv"] = (csv_body().encode("utf-8"), "csv",
                                            CSV_EXPECT)
    wav, wav_expect = sine_wav()
    fx["media/audio/tone-440.wav"] = (wav, "wav", dict(wav_expect,
                                                       frequency=440.0))
    fx["media/subtitles/captions.srt"] = (build_srt().encode("utf-8"), "srt",
                                          SRT_EXPECT)
    fx["media/subtitles/captions.vtt"] = (build_vtt().encode("utf-8"), "vtt",
                                          VTT_EXPECT)
    fx["assets/png/gradient-8.png"] = (png_8x8_gradient(), "png",
                                       {"width": 8, "height": 8, "bitDepth": 8,
                                        "colorType": 2})
    fx["assets/svg/marker.svg"] = (SVG_BODY.encode("utf-8"), "svg",
                                   {"root": "svg", "pathCount": 1,
                                    "circleCount": 1})
    return fx


FIXTURE_OPERATIONS = {
    "office/docx/paragraphs-unicode.docx": [
        "OFC-PREVIEW-DOCX", "OFC-EDIT-PARAGRAPH", "OFC-SAVE-REOPEN",
        "OFC-REVISION-TRACKING", "OFC-PDF-EXPORT", "NOT-IMPORT",
        "DSN-ENTRY-ANCHORS", "BAK-VERSIONED-PACKAGE", "PDF-EXPORT-REOPEN"],
    "office/docx/corrupt-missing-content-types.docx": [
        "OFC-PREVIEW-DOCX", "BAK-VERIFY-REJECT-UNKNOWN"],
    "office/xlsx/formula-basic.xlsx": [
        "OFC-PREVIEW-XLSX", "OFC-CELL-FORMULA-RECALC", "OFC-SAVE-REOPEN"],
    "office/xlsx/formula-error-and-injection.xlsx": [
        "OFC-CELL-FORMULA-RECALC", "OFC-CSV-SECURITY"],
    "office/pptx/two-slides.pptx": [
        "OFC-PREVIEW-PPTX", "OFC-SLIDES-EDIT", "OFC-CREATE-NEW",
        "OFC-SAVE-REOPEN"],
    "pdf/two-page-basic.pdf": [
        "PDF-READ-PAGES", "PDF-SELECT-ANNOTATE", "PDF-EXPORT-REOPEN",
        "OFC-PDF-EXPORT"],
    "pdf/truncated.pdf": ["PDF-READ-PAGES", "BAK-VERIFY-REJECT-UNKNOWN"],
    "cad/dxf/lines-text-layers.dxf": [
        "CAD-LAYER-SELECT-EDIT", "CAD-MEASURE", "CAD-UNKNOWN-PRESERVE",
        "CAD-IMPORT-EXPORT", "CAD-SAVE-REOPEN", "NOT-COVER-READ"],
    "cad/obj/cube.obj": [
        "CAD-IMPORT-EXPORT", "CAD3D-MODEL-KERNEL", "CAD3D-EXPORT",
        "CAD-SAVE-REOPEN"],
    "notes/note-basic.json": [
        "NOT-STORAGE-INDEP", "NOT-EDIT-UNDO", "NOT-SEARCH",
        "NOT-AI-ASSISTANT", "NOT-EXPORT", "NOT-COVER-READ",
        "BAK-VERSIONED-PACKAGE"],
    "canvas/canvas-with-assets.json": [
        "CNV-NODES-EDGES", "CNV-ASSET-OWNERSHIP", "CNV-SAVE-RESTORE-BACKUP",
        "CNV-VARIANTS", "BAK-VERSIONED-PACKAGE"],
    "text/code/sample.py": ["PY-JOB-OUTPUT", "IDE-TREE-EDIT", "IDE-LANG-SUPPORT",
                            "GIT-DIFF-STAGE-COMMIT"],
    "text/code/sample.kt": ["IDE-TREE-EDIT", "IDE-UNDO-DRAFT", "IDE-LANG-SUPPORT"],
    "text/code/sample.ts": ["IDE-SEARCH-REPLACE", "IDE-LANG-SUPPORT", "IDE-DIFF"],
    "text/encoding/crlf.txt": ["IDE-ENCODING-LINES"],
    "text/encoding/utf8-bom.txt": ["IDE-ENCODING-LINES"],
    "text/encoding/long-line.txt": ["IDE-ENCODING-LINES"],
    "text/csv/formula-injection.csv": ["OFC-CSV-SECURITY", "APR-UNTRUSTED-NO-GRANT"],
    "media/audio/tone-440.wav": [
        "MED-PLAYBACK-CODECS", "MED-TIMELINE-TRIM", "MED-EXPORT-VERIFY",
        "MED-SUBTITLES-AUDIO", "VOI-FILE-TRANSCRIBE"],
    "media/video/floe-test.mp4": [
        "MED-PLAYBACK-CODECS", "MED-TIMELINE-TRIM", "MED-EXPORT-VERIFY",
        "ENH-IN-OUT-CONTRACT", "ENH-NO-FAKE-UPSCALE"],
    "media/subtitles/captions.srt": ["MED-SUBTITLES-AUDIO", "VOI-FILE-TRANSCRIBE"],
    "media/subtitles/captions.vtt": ["MED-SUBTITLES-AUDIO"],
    "assets/png/gradient-8.png": [
        "CNV-ASSET-OWNERSHIP", "GEN-DOWNLOAD-ARCHIVE", "WSF-EXPORT",
        "BRW-LOCAL-PREVIEW"],
    "assets/svg/marker.svg": ["CNV-ASSET-OWNERSHIP", "BRW-LOCAL-PREVIEW"],
}





# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------

def write_mode(verify_ffmpeg=False):
    fx = build_stdlib_fixtures()
    entries = []
    problems = []
    for path in sorted(fx.keys()) + sorted(FFMPEG_RECIPES.keys()):
        if path in fx:
            data, fmt, expect = fx[path]
            determinism = "stdlib"
            recipe = None
        else:
            binary = ffmpeg_binary()
            if binary is None:
                problems.append("%s: ffmpeg unavailable — recorded as recipe "
                                "gap, binary NOT fabricated" % path)
                continue
            data, err = run_ffmpeg(FFMPEG_RECIPES[path], Path(path))
            if data is None:
                problems.append("%s: ffmpeg failed: %s" % (path, err))
                continue
            fmt, expect = "mp4", {
                "boxes": ["ftyp", "moov", "mdat"],
                "width": 320, "height": 240, "secondsApprox": 1.0}
            determinism = "ffmpeg-version-pinned"
            recipe = {"argv": [binary] + FFMPEG_RECIPES[path] + ["<output>"],
                      "version": ffmpeg_version(binary)}
        payload = {
            "path": path,
            "bytes": len(data),
            "sha256": sha256(data),
            "format": fmt,
            "determinism": determinism,
            "expect": expect,
            "operations": FIXTURE_OPERATIONS.get(path, []),
        }
        if recipe:
            payload["recipe"] = recipe
        dest = HERE / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        entries.append(payload)

    inventory = {
        "schemaVersion": 1,
        "artifact": "floe-android-g01-synthetic-fixtures",
        "baselineRef": "FloeAndroid/planning/feature-baseline.json",
        "determinismNote": ("stdlib entries are byte-reproducible; mp4 entries "
                            "require the pinned ffmpeg version — see README.md"),
        "entries": entries,
    }
    rendered = json.dumps(inventory, ensure_ascii=False, indent=2,
                          sort_keys=True) + "\n"
    (HERE / INVENTORY_NAME).write_text(rendered, encoding="utf-8")
    return len(entries), problems


def check_mode(verify_ffmpeg=False):
    """Read-only. Never writes or rewrites fixture files."""
    problems = []
    if not HERE.joinpath(INVENTORY_NAME).exists():
        return -1, ["inventory.json missing"]
    current = json.loads((HERE / INVENTORY_NAME).read_text(encoding="utf-8"))
    fx = build_stdlib_fixtures()
    checked = 0
    seen = set()
    for entry in current["entries"]:
        path = entry["path"]
        seen.add(path)
        on_disk = HERE / path
        if not on_disk.exists():
            problems.append("missing on disk: %s" % path)
            continue
        disk = on_disk.read_bytes()
        if sha256(disk) != entry["sha256"]:
            problems.append("inventory sha mismatch vs disk: %s" % path)
            continue
        if entry["bytes"] != len(disk):
            problems.append("byte count mismatch vs inventory: %s" % path)
            continue
        if path in fx:
            if sha256(fx[path][0]) != entry["sha256"]:
                problems.append("regenerated stdlib bytes differ: %s" % path)
                continue
        elif path in FFMPEG_RECIPES:
            if verify_ffmpeg:
                data, err = run_ffmpeg(FFMPEG_RECIPES[path], Path(path))
                if data is None:
                    problems.append("ffmpeg regen failed: %s (%s)"
                                    % (path, err))
                    continue
                if sha256(data) != entry["sha256"]:
                    problems.append("ffmpeg bytes drifted from pin: %s "
                                    "(re-record README pin, do not force)" % path)
                    continue
        else:
            problems.append("unknown fixture in inventory: %s" % path)
            continue
        checked += 1
    for path in fx:
        if path not in seen:
            problems.append("stdlib fixture not recorded in inventory: %s"
                            % path)
    return checked, problems


def main(argv):
    mode = argv[1] if len(argv) > 1 else "--generate"
    if mode in ("--help", "-h"):
        print(__doc__)
        return 0
    if mode == "--check":
        count, problems = check_mode(verify_ffmpeg=False)
        if problems or count < 0:
            for p in problems:
                print("FAIL %s" % p)
            print("generate --check: %d ok, %d problems" % (count, len(problems)))
            return 1
        print("generate --check: %d fixtures verified (stdlib byte-reproducible, "
              "recorded entries intact); no files written" % count)
        return 0
    if mode == "--verify-ffmpeg":
        count, problems = check_mode(verify_ffmpeg=True)
        status = 0 if not problems and count >= 0 else 1
        for p in problems:
            print("FAIL %s" % p)
        print("generate --verify-ffmpeg: %d ok, %d problems" % (count, len(problems)))
        return status
    if mode != "--generate":
        print("unknown mode %s" % mode)
        return 2
    count, problems = write_mode()
    for p in problems:
        print("WARN %s" % p)
    print("generated %d fixtures + inventory.json" % count)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
