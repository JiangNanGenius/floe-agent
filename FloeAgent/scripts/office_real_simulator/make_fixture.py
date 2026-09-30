#!/usr/bin/env python3
"""Generate the deterministic synthetic PPTX for the simulator qualification.

No user document, no network, no third-party module: the file is built with
stdlib zipfile from fixed OOXML. Two slides, a visible title marker and a solid
shape so a rendered frame is not a blank white page. The ZIP entries, timestamps
and UUIDs are fixed so the fixture SHA-256 is reproducible and the persistence
gate can compare the seeded file against what survives close/reopen.
"""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

from sim_paths import FIXTURE_BASENAME, FIXTURE_SHA256, FIXTURE_SLIDE_COUNT

MARKER_TITLE = 'Floe SIM QUAL'
MARKER_SUBTITLE = 'Synthetic PPTX - two slides'
FIXED_DT = (2026, 1, 1, 0, 0, 0)

NS = (
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"'
)

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
</Types>"""

ROOT_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
</Relationships>"""

PRESENTATION = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:presentation {NS}>
<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
<p:sldIdLst>
<p:sldId id="256" r:id="rId2"/>
<p:sldId id="257" r:id="rId3"/>
</p:sldIdLst>
<p:sldSz cx="9144000" cy="6858000"/>
<p:notesSz cx="6858000" cy="9144000"/>
</p:presentation>"""

PRESENTATION_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/>
<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/>
</Relationships>"""

SLIDE_MASTER = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldMaster {NS}>
<p:cSld><p:spTree>
<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
<p:grpSpPr/>
</p:spTree></p:cSld>
<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
</p:sldMaster>"""

SLIDE_MASTER_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>
</Relationships>"""

SLIDE_LAYOUT = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldLayout type="blank" preserve="1" {NS}>
<p:cSld name="Blank"><p:spTree>
<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
<p:grpSpPr/>
</p:spTree></p:cSld>
<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sldLayout>"""

SLIDE_LAYOUT_RELS = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>
</Relationships>"""

THEME = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<a:theme {NS} name="Office">
<a:themeElements>
<a:clrScheme name="Office">
<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>
<a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>
<a:dk2><a:srgbClr val="1F2937"/></a:dk2>
<a:lt2><a:srgbClr val="F3F4F6"/></a:lt2>
<a:accent1><a:srgbClr val="2563EB"/></a:accent1>
<a:accent2><a:srgbClr val="EA580C"/></a:accent2>
<a:accent3><a:srgbClr val="16A34A"/></a:accent3>
<a:accent4><a:srgbClr val="CA8A04"/></a:accent4>
<a:accent5><a:srgbClr val="9333EA"/></a:accent5>
<a:accent6><a:srgbClr val="0891B2"/></a:accent6>
<a:hlink><a:srgbClr val="2563EB"/></a:hlink>
<a:folHlink><a:srgbClr val="9333EA"/></a:folHlink>
</a:clrScheme>
<a:fontScheme name="Office"><a:majorFont><a:latin typeface="Arial"/></a:majorFont><a:minorFont><a:latin typeface="Arial"/></a:minorFont></a:fontScheme>
<a:fmtScheme name="Office">
<a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>
<a:lnStyleLst><a:ln><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>
<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>
<a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>
</a:fmtScheme>
</a:themeElements>
</a:theme>"""


def _text_shape(shape_id, name, x, y, cx, cy, text, size=2800, bold=False,
                color='1F2937'):
    b = ' b="1"' if bold else ''
    return f"""<p:sp>
<p:nvSpPr><p:cNvPr id="{shape_id}" name="{name}"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
<p:spPr><a:xfrm><a:off x="{x}" y="{y}"/><a:ext cx="{cx}" cy="{cy}"/></a:xfrm>
<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
<p:txXfrm><a:off x="{x}" y="{y}"/><a:ext cx="{cx}" cy="{cy}"/></p:txXfrm>
<p:txBody><a:bodyPr/><a:lstStyle/>
<a:p><a:r><a:rPr lang="en-US" sz="{size}"{b}><a:solidFill><a:srgbClr val="{color}"/></a:solidFill></a:rPr><a:t>{text}</a:t></a:r></a:p>
</p:txBody></p:sp>"""


SLIDE1 = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld {NS}>
<p:cSld><p:spTree>
<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
{_text_shape(2, 'Title', 457200, 381000, 8229600, 1143000, MARKER_TITLE, size=4000, bold=True, color='1D4ED8')}
{_text_shape(3, 'Subtitle', 457200, 1600200, 8229600, 685800, MARKER_SUBTITLE, size=2000, color='374151')}
<p:sp>
<p:nvSpPr><p:cNvPr id="4" name="Accent Bar"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
<p:spPr><a:xfrm><a:off x="457200" y="1371600"/><a:ext cx="2743200" height="91440"/></a:xfrm>
<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
<a:solidFill><a:srgbClr val="EA580C"/></a:solidFill></p:spPr>
<p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp>
</p:spTree></p:cSld>
<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sld>"""

# Note: <a:ext ... height="91440"/> is invalid OOXML (cx/cy only); fixed below.
SLIDE1 = SLIDE1.replace('height="91440"', 'cy="91440"')

SLIDE2 = f"""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld {NS}>
<p:cSld><p:spTree>
<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
{_text_shape(2, 'Title', 457200, 381000, 8229600, 1143000, 'Slide 2', size=4000, bold=True, color='1D4ED8')}
<p:sp>
<p:nvSpPr><p:cNvPr id="3" name="Green Circle"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
<p:spPr><a:xfrm><a:off x="3200400" y="2286000"/><a:ext cx="2743200" cy="2743200"/></a:xfrm>
<a:prstGeom prst="ellipse"><a:avLst/></a:prstGeom>
<a:solidFill><a:srgbClr val="16A34A"/></a:solidFill></p:spPr>
<p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp>
</p:spTree></p:cSld>
<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sld>"""

SLIDE_REL = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
</Relationships>"""

ENTRIES = [
    '[Content_Types].xml', CONTENT_TYPES,
    '_rels/.rels', ROOT_RELS,
    'ppt/presentation.xml', PRESENTATION,
    'ppt/_rels/presentation.xml.rels', PRESENTATION_RELS,
    'ppt/slideMasters/slideMaster1.xml', SLIDE_MASTER,
    'ppt/slideMasters/_rels/slideMaster1.xml.rels', SLIDE_MASTER_RELS,
    'ppt/slideLayouts/slideLayout1.xml', SLIDE_LAYOUT,
    'ppt/slideLayouts/_rels/slideLayout1.xml.rels', SLIDE_LAYOUT_RELS,
    'ppt/slides/slide1.xml', SLIDE1,
    'ppt/slides/_rels/slide1.xml.rels', SLIDE_REL,
    'ppt/slides/slide2.xml', SLIDE2,
    'ppt/slides/_rels/slide2.xml.rels', SLIDE_REL,
    'ppt/theme/theme1.xml', THEME,
]


def build_bytes():
    pairs = list(zip(ENTRIES[0::2], ENTRIES[1::2]))
    # Deterministic order; ZIP stores names only once.
    names = [name for name, _ in pairs]
    assert len(names) == len(set(names)), names
    import io
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name, content in pairs:
            info = zipfile.ZipInfo(name, FIXED_DT)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            archive.writestr(info, content)
    return buffer.getvalue()


def validate(data):
    """Structural self-check; raises on a malformed fixture."""
    import io
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        bad = archive.testzip()
        assert bad is None, bad
        names = set(archive.namelist())
        required = {
            '[Content_Types].xml', '_rels/.rels', 'ppt/presentation.xml',
            'ppt/_rels/presentation.xml.rels', 'ppt/slides/slide1.xml',
            'ppt/slides/slide2.xml', 'ppt/slideMasters/slideMaster1.xml',
            'ppt/slideLayouts/slideLayout1.xml', 'ppt/theme/theme1.xml',
        }
        missing = required - names
        assert not missing, missing
        slide1 = archive.read('ppt/slides/slide1.xml').decode('utf-8')
        assert MARKER_TITLE in slide1 and MARKER_SUBTITLE in slide1
        count = sum(1 for name in names if
                    name.startswith('ppt/slides/slide') and name.endswith('.xml'))
        assert count == FIXTURE_SLIDE_COUNT, count
    return {'slideCount': count, 'markers': [MARKER_TITLE, MARKER_SUBTITLE]}


def write_fixture(destination, expected_sha256=None):
    data = build_bytes()
    facts = validate(data)
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    digest = hashlib.sha256(data).hexdigest()
    if expected_sha256 and digest != expected_sha256:
        raise ValueError(
            f'fixture sha256 {digest} != pinned {expected_sha256}; the fixture '
            'generator or the pin drifted, refusing to seed a different file')
    return {
        'path': str(destination),
        'basename': destination.name,
        'size': len(data),
        'sha256': digest,
        **facts,
        'synthetic': True,
        'userContent': False,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', default=None,
                        help=f'Default: <cwd>/{FIXTURE_BASENAME}')
    parser.add_argument('--receipt', default=None)
    parser.add_argument('--expected-sha256', default=None,
                        help='Fail if the generated fixture hash differs')
    args = parser.parse_args()
    output = args.output or str(Path.cwd() / FIXTURE_BASENAME)
    receipt = write_fixture(output, args.expected_sha256)
    if args.receipt:
        Path(args.receipt).parent.mkdir(parents=True, exist_ok=True)
        Path(args.receipt).write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    main()
