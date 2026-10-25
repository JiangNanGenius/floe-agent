#!/usr/bin/env python3
"""Deterministic stdlib generator for two-slides-preview.pptx.

Self-authored two-slide PPTX render fixture for the FloeAndroid G05-R1 native
Office visual acceptance lane. Unlike the original parser-test synthetic
two-slides.pptx (placeholder shapes with empty spPr and a blank layout/master),
every shape here carries explicit a:xfrm geometry, so a conforming renderer
must paint visible content on both pages.

Standards basis (primary source): ECMA-376-1 Office Open XML, placeholder
geometry inheritance (p:ph + spPr) — a placeholder without explicit xfrm
inherits from the matching placeholder in slideLayout then slideMaster; the
old fixture's layout/master spTree are empty, so its placeholders resolve to
no rectangle and legitimately render zero-size (white page).

Usage:
  python3 generate_two_slides_preview.py [OUT]   # write deterministic fixture
  python3 generate_two_slides_preview.py --check [OUT]  # read-only verify

Stdlib only (zipfile/hashlib/xml). ZIP_STORED, fixed 1980-01-01 timestamps,
fixed entry order -> byte-reproducible output.
"""
from __future__ import annotations

import argparse
import hashlib
import sys
import zipfile
from xml.etree import ElementTree as ET

FIXED_DT = (1980, 1, 1, 0, 0, 0)
OUT_DEFAULT_REL = (
    "../../../android-g03-20261022/r2/native-integration/"
    "native-source-20261022a/FloeAndroid/fixtures/office/pptx/"
    "two-slides-preview.pptx"
)

NS = {
    "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
    "p": "http://schemas.openxmlformats.org/presentationml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    "pr": "http://schemas.openxmlformats.org/package/2006/relationships",
    "ct": "http://schemas.openxmlformats.org/package/2006/content-types",
}

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>
  <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>
  <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>
  <Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
  <Override PartName="/ppt/slides/slide2.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
  <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
</Types>
"""

ROOT_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
</Relationships>
"""

PRESENTATION = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:sldMasterIdLst>
    <p:sldMasterId id="2147483648" r:id="rId1"/>
  </p:sldMasterIdLst>
  <p:sldIdLst>
    <p:sldId id="256" r:id="rId2"/>
    <p:sldId id="257" r:id="rId3"/>
  </p:sldIdLst>
  <p:sldSz cx="9144000" cy="6858000"/>
  <p:notesSz cx="6858000" cy="9144000"/>
</p:presentation>
"""

PRESENTATION_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/>
  <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
</Relationships>
"""

THEME = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="FloePreviewTheme">
  <a:themeElements>
    <a:clrScheme name="FloePreview">
      <a:dk1><a:srgbClr val="000000"/></a:dk1>
      <a:lt1><a:srgbClr val="FFFFFF"/></a:lt1>
      <a:dk2><a:srgbClr val="1F3864"/></a:dk2>
      <a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>
      <a:accent1><a:srgbClr val="C00000"/></a:accent1>
      <a:accent2><a:srgbClr val="2E7D32"/></a:accent2>
      <a:accent3><a:srgbClr val="1F4E79"/></a:accent3>
      <a:accent4><a:srgbClr val="BF9000"/></a:accent4>
      <a:accent5><a:srgbClr val="7030A0"/></a:accent5>
      <a:accent6><a:srgbClr val="117A8B"/></a:accent6>
      <a:hlink><a:srgbClr val="0563C1"/></a:hlink>
      <a:folHlink><a:srgbClr val="954F72"/></a:folHlink>
    </a:clrScheme>
    <a:fontScheme name="FloePreviewFonts">
      <a:majorFont>
        <a:latin typeface="Arial"/>
        <a:ea typeface=""/>
        <a:cs typeface=""/>
      </a:majorFont>
      <a:minorFont>
        <a:latin typeface="Arial"/>
        <a:ea typeface=""/>
        <a:cs typeface=""/>
      </a:minorFont>
    </a:fontScheme>
    <a:fmtScheme name="FloePreviewFmt">
      <a:fillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"><a:tint val="65000"/></a:schemeClr></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"><a:shade val="80000"/></a:schemeClr></a:solidFill>
      </a:fillStyleLst>
      <a:lnStyleLst>
        <a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
        <a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
        <a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>
      </a:lnStyleLst>
      <a:effectStyleLst>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        <a:effectStyle><a:effectLst/></a:effectStyle>
        <a:effectStyle><a:effectLst/></a:effectStyle>
      </a:effectStyleLst>
      <a:bgFillStyleLst>
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"><a:tint val="95000"/></a:schemeClr></a:solidFill>
        <a:solidFill><a:schemeClr val="phClr"><a:shade val="90000"/></a:schemeClr></a:solidFill>
      </a:bgFillStyleLst>
    </a:fmtScheme>
  </a:themeElements>
</a:theme>
"""

SLIDE_MASTER = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:cSld name="Floe Preview Master">
    <p:spTree>
      <p:nvGrpSpPr>
        <p:cNvPr id="1" name=""/>
        <p:cNvGrpSpPr/>
        <p:nvPr/>
      </p:nvGrpSpPr>
      <p:grpSpPr/>
    </p:spTree>
  </p:cSld>
  <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
  <p:sldLayoutIdLst>
    <p:sldLayoutId id="2147483649" r:id="rId1"/>
  </p:sldLayoutIdLst>
  <p:txStyles>
    <p:titleStyle>
      <a:lvl1pPr><a:defRPr sz="4400" b="1"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:defRPr></a:lvl1pPr>
    </p:titleStyle>
    <p:bodyStyle>
      <a:lvl1pPr><a:defRPr sz="1800"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:defRPr></a:lvl1pPr>
    </p:bodyStyle>
    <p:otherStyle>
      <a:lvl1pPr><a:defRPr sz="1800"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill></a:defRPr></a:lvl1pPr>
    </p:otherStyle>
  </p:txStyles>
</p:sldMaster>
"""

SLIDE_MASTER_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
</Relationships>
"""

SLIDE_LAYOUT = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">
  <p:cSld name="Floe Preview Blank">
    <p:spTree>
      <p:nvGrpSpPr>
        <p:cNvPr id="1" name=""/>
        <p:cNvGrpSpPr/>
        <p:nvPr/>
      </p:nvGrpSpPr>
      <p:grpSpPr/>
    </p:spTree>
  </p:cSld>
  <p:clrMapOvr>
    <a:masterClrMapping/>
  </p:clrMapOvr>
</p:sldLayout>
"""

SLIDE_LAYOUT_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
</Relationships>
"""

SLIDE1_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
</Relationships>
"""

SLIDE2_RELS = SLIDE1_RELS


def _sp(shape_id: int, name: str, x: int, y: int, cx: int, cy: int,
        paragraphs: str, fill: str | None = None, ln: str | None = None,
        prst: str = "rect") -> str:
    """Explicit-geometry text/shape sp with required a:xfrm (EMU ints)."""
    fill_xml = f'<a:solidFill><a:srgbClr val="{fill}"/></a:solidFill>' if fill else "<a:noFill/>"
    ln_xml = (
        f'<a:ln w="12700"><a:solidFill><a:srgbClr val="{ln}"/></a:solidFill></a:ln>'
        if ln else "<a:ln><a:noFill/></a:ln>"
    )
    return f"""    <p:sp>
      <p:nvSpPr>
        <p:cNvPr id="{shape_id}" name="{name}"/>
        <p:cNvSpPr/>
        <p:nvPr/>
      </p:nvSpPr>
      <p:spPr>
        <a:xfrm>
          <a:off x="{x}" y="{y}"/>
          <a:ext cx="{cx}" cy="{cy}"/>
        </a:xfrm>
        <a:prstGeom prst="{prst}"><a:avLst/></a:prstGeom>
        {fill_xml}
        {ln_xml}
      </p:spPr>
      <p:txBody>
        <a:bodyPr wrap="square"/>
        <a:lstStyle/>
{paragraphs}
      </p:txBody>
    </p:sp>"""


def _cxn(shape_id: int, name: str, x: int, y: int, cx: int, cy: int,
         color: str, width_emu: int = 28575) -> str:
    """Explicit-geometry straight connector (line)."""
    return f"""    <p:cxnSp>
      <p:nvCxnSpPr>
        <p:cNvPr id="{shape_id}" name="{name}"/>
        <p:cNvCxnSpPr/>
        <p:nvPr/>
      </p:nvCxnSpPr>
      <p:spPr>
        <a:xfrm>
          <a:off x="{x}" y="{y}"/>
          <a:ext cx="{cx}" cy="{cy}"/>
        </a:xfrm>
        <a:prstGeom prst="line"><a:avLst/></a:prstGeom>
        <a:ln w="{width_emu}"><a:solidFill><a:srgbClr val="{color}"/></a:solidFill></a:ln>
      </p:spPr>
    </p:cxnSp>"""


def _run(text: str, size: int, color: str, bold: bool = False, lang: str = "en-US") -> str:
    b = ' b="1"' if bold else ""
    return (
        f'<a:r><a:rPr lang="{lang}" sz="{size}"{b}>'
        f'<a:solidFill><a:srgbClr val="{color}"/></a:solidFill>'
        f'</a:rPr><a:t>{text}</a:t></a:r>'
    )


def _para(runs: str, bullet: bool = False) -> str:
    ppr = (
        '<a:pPr><a:buFont typeface="Arial"/><a:buChar char="•"/></a:pPr>'
        if bullet else '<a:pPr><a:buNone/></a:pPr>'
    )
    return f"        <a:p>{ppr}{runs}</a:p>"


def _slide(shapes: str) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:cSld>
    <p:spTree>
      <p:nvGrpSpPr>
        <p:cNvPr id="1" name=""/>
        <p:cNvGrpSpPr/>
        <p:nvPr/>
      </p:nvGrpSpPr>
      <p:grpSpPr/>
{shapes}
    </p:spTree>
  </p:cSld>
</p:sld>
"""


# ---- Slide 1: title + subtitle, red/green rectangles, bottom marker, horizontal line
_S1_TITLE = _para(_run("Floe Preview Deck — Slide 1", 4000, "1F3864", bold=True), bullet=False)
_S1_SUB = _para(_run("visible text A · 第一页 · § 2026-10-26", 2400, "404040"), bullet=False)
_S1_MARKER = _para(_run("bottom marker 底部署名 PPTX", 1800, "7030A0"), bullet=False)

SLIDE1 = _slide("\n".join([
    _sp(2, "S1 Title", 457200, 274320, 8229600, 1097280, _S1_TITLE),
    _sp(3, "S1 Subtitle", 457200, 1463040, 8229600, 822960, _S1_SUB),
    _sp(4, "S1 RedRect", 457200, 2651760, 3657600, 1828800, _para(_run("red 红", 2000, "FFFFFF", bold=True), bullet=False), fill="C00000", ln="000000"),
    _sp(5, "S1 GreenRect", 4389120, 2651760, 3657600, 1828800, _para(_run("green 绿", 2000, "FFFFFF", bold=True), bullet=False), fill="2E7D32", ln="000000"),
    _sp(6, "S1 BottomMarker", 457200, 4754880, 8229600, 548640, _S1_MARKER),
    _cxn(7, "S1 RuleLine", 457200, 5943600, 8229600, 0, "1F4E79", width_emu=28575),
]))

# ---- Slide 2: different geometry/colors/text so page-switch is discriminable
_S2_TITLE = _para(_run("Geometry Check — Slide 2", 3600, "833C00", bold=True), bullet=False)
_S2_BODY = "\n".join([
    _para(_run("beta bullet visible", 2000, "17365D"), bullet=True),
    _para(_run("第二段 中文文本", 2000, "17365D", lang="zh-CN"), bullet=True),
    _para(_run("third line § done", 2000, "17365D"), bullet=True),
])
_S2_MARKER = _para(_run("page 2 bottom marker · PPTX 可见", 1800, "0F6674"), bullet=False)

SLIDE2 = _slide("\n".join([
    _sp(2, "S2 Title", 457200, 274320, 8229600, 914400, _S2_TITLE),
    _sp(3, "S2 Bullets", 457200, 1371600, 5486400, 1828800, _S2_BODY),
    _sp(4, "S2 BlueRect", 6400800, 1371600, 2286000, 1828800, "", fill="1F4E79", ln="000000"),
    _sp(5, "S2 YellowRect", 457200, 3657600, 2743200, 1371600, _para(_run("yellow 黄", 1800, "000000", bold=True), bullet=False), fill="BF9000", ln="000000"),
    _sp(6, "S2 TealRect", 3352800, 3657600, 2743200, 1371600, _para(_run("teal 青", 1800, "FFFFFF", bold=True), bullet=False), fill="117A8B", ln="000000"),
    _sp(7, "S2 PurpleRect", 6248400, 3657600, 2438400, 1371600, _para(_run("purple 紫", 1800, "FFFFFF", bold=True), bullet=False), fill="7030A0", ln="000000"),
    _sp(8, "S2 BottomMarker", 457200, 5303520, 8229600, 548640, _S2_MARKER),
    _cxn(9, "S2 DiagonalLine", 457200, 6126480, 8229600, 320040, "C00000", width_emu=28575),
]))

PARTS = [
    ("[Content_Types].xml", CONTENT_TYPES),
    ("_rels/.rels", ROOT_RELS),
    ("ppt/presentation.xml", PRESENTATION),
    ("ppt/_rels/presentation.xml.rels", PRESENTATION_RELS),
    ("ppt/theme/theme1.xml", THEME),
    ("ppt/slideMasters/slideMaster1.xml", SLIDE_MASTER),
    ("ppt/slideMasters/_rels/slideMaster1.xml.rels", SLIDE_MASTER_RELS),
    ("ppt/slideLayouts/slideLayout1.xml", SLIDE_LAYOUT),
    ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", SLIDE_LAYOUT_RELS),
    ("ppt/slides/slide1.xml", SLIDE1),
    ("ppt/slides/_rels/slide1.xml.rels", SLIDE1_RELS),
    ("ppt/slides/slide2.xml", SLIDE2),
    ("ppt/slides/_rels/slide2.xml.rels", SLIDE2_RELS),
]


def build_bytes() -> bytes:
    import io
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_STORED) as zf:
        for name, xml in PARTS:
            info = zipfile.ZipInfo(name, date_time=FIXED_DT)
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 0
            info.external_attr = 0
            zf.writestr(info, xml.encode("utf-8"))
    return buf.getvalue()


def check(data: bytes) -> list[str]:
    """Read-only structural probes. Returns list of failure strings (empty = ok)."""
    failures: list[str] = []
    import io
    zf = zipfile.ZipFile(io.BytesIO(data))
    if zf.testzip() is not None:
        failures.append("zip CRC failure")
    names = zf.namelist()
    if names != [n for n, _ in PARTS]:
        failures.append(f"entry order mismatch: {names}")
    # XML well-formedness
    for n in names:
        if n.endswith((".xml", ".rels")):
            try:
                ET.fromstring(zf.read(n))
            except ET.ParseError as e:
                failures.append(f"XML parse error {n}: {e}")
    # content types cover every part
    ct_root = ET.fromstring(zf.read("[Content_Types].xml"))
    overrides = {el.get("PartName") for el in ct_root.findall("{" + NS["ct"] + "}Override")}
    defaults = {el.get("Extension") for el in ct_root.findall("{" + NS["ct"] + "}Default")}
    for n in names:
        if f"/{n}" not in overrides:
            ext = n.rsplit(".", 1)[-1]
            if ext not in defaults:
                failures.append(f"no content type for {n}")
    # no external relationships (no network/embedded refs)
    for n in names:
        if n.endswith(".rels"):
            root = ET.fromstring(zf.read(n))
            for rel in root:
                if rel.get("TargetMode") == "External":
                    failures.append(f"external rel in {n}")
    # rel targets exist (targets resolve against the describing part's directory)
    import posixpath
    for n in names:
        if n.endswith(".rels"):
            if n == "_rels/.rels":
                part_dir = ""
            else:
                part_dir = n.rsplit("/_rels/", 1)[0] + "/"
            root = ET.fromstring(zf.read(n))
            for rel in root:
                tgt = rel.get("Target")
                if rel.get("TargetMode") == "External":
                    continue
                full = posixpath.normpath(posixpath.join(part_dir, tgt))
                if full not in names:
                    failures.append(f"missing rel target {full} from {n}")
    # every shape on both slides has explicit a:xfrm with off+ext (no placeholder inheritance)
    for slide in ("ppt/slides/slide1.xml", "ppt/slides/slide2.xml"):
        root = ET.fromstring(zf.read(slide))
        for tag in (f"{{{NS['p']}}}sp", f"{{{NS['p']}}}cxnSp"):
            for el in root.iter(tag):
                nv = el.find(f".//{{{NS['p']}}}nvPr")
                if nv is not None and nv.find(f"{{{NS['p']}}}ph") is not None:
                    failures.append(f"placeholder shape in {slide} (must be explicit geometry)")
                xfrm = el.find(f".//{{{NS['a']}}}xfrm")
                if xfrm is None:
                    failures.append(f"shape without a:xfrm in {slide}")
                else:
                    off = xfrm.find(f"{{{NS['a']}}}off")
                    ext = xfrm.find(f"{{{NS['a']}}}ext")
                    if off is None or ext is None or int(ext.get("cx")) <= 0:
                        failures.append(f"bad xfrm geometry in {slide}")
    # deterministic regeneration
    if build_bytes() != data:
        failures.append("non-deterministic regeneration")
    return failures


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("out", nargs="?", default=None)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args(argv)

    data = build_bytes()
    sha = hashlib.sha256(data).hexdigest()

    if args.check:
        import os
        out = args.out
        if out is None:
            here = os.path.dirname(os.path.abspath(__file__))
            out = os.path.normpath(os.path.join(here, OUT_DEFAULT_REL))
        failures = check(data)
        disk = None
        if os.path.exists(out):
            with open(out, "rb") as fh:
                disk = fh.read()
        status = {
            "generated_sha256": sha,
            "generated_bytes": len(data),
            "on_disk_sha256": hashlib.sha256(disk).hexdigest() if disk is not None else None,
            "on_disk_bytes": len(disk) if disk is not None else None,
            "byte_identical_to_regeneration": disk == data if disk is not None else None,
            "checks": failures if failures else "ok",
        }
        import json
        print(json.dumps(status, indent=2, ensure_ascii=False))
        return 1 if failures or disk != data else 0

    out = args.out
    if out is None:
        import os
        here = os.path.dirname(os.path.abspath(__file__))
        out = os.path.normpath(os.path.join(here, OUT_DEFAULT_REL))
    with open(out, "wb") as fh:
        fh.write(data)
    print(f"wrote {out} ({len(data)} bytes) sha256={sha}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
