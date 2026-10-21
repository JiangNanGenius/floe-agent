#!/usr/bin/env python3
"""Source contract audit and deterministic public Symbol PPTX fixture.

This does not qualify glyph rendering. Run the native App test and review its
actual surface captures after producing the new device/simulator components.
"""
import argparse
import difflib
import hashlib
import io
import json
from pathlib import Path
import re
import zipfile

from office_compiled_lifecycle import contract, source_bytes

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'ThirdParty/Collabora/engine.lock.json'
SOURCE = 'engine/vcl/source/font/fontcache.cxx'


def audit(engine_source, lock_path=LOCK):
    lock_path = Path(lock_path)
    lock = json.loads(lock_path.read_text())
    hashes = {}
    for platform in ('IOS', 'IOSSIMULATOR'):
        selected = contract(lock, platform)
        spec = selected['additionalMembers']['fontcache.o']
        if spec['sourceFile'] != SOURCE:
            raise ValueError('Symbol repair source differs')
        original = source_bytes(engine_source, spec, lock['commit'])
        if original.count(b'#ifdef MACOSX\n') != 1:
            raise ValueError('Symbol repair guard is ambiguous')
        patched = original.replace(b'#ifdef MACOSX\n', b'#if defined(MACOSX) || defined(IOS)\n')
        expected = ''.join(difflib.unified_diff(original.decode().splitlines(True),
            patched.decode().splitlines(True), fromfile='a/' + SOURCE, tofile='b/' + SOURCE)).encode()
        patch = (lock_path.parent / spec['patch']).read_bytes()
        if patch != expected or hashlib.sha256(patch).hexdigest() != spec['patchSHA256']:
            raise ValueError('Symbol repair must change only the existing Apple guard')
        if hashlib.sha256(patched).hexdigest() != spec['patchedSHA256']:
            raise ValueError('Symbol repaired source differs')
        block = patched.split(b'#if defined(MACOSX) || defined(IOS)\n', 1)[1].split(b'#endif', 1)[0]
        for condition in (b'!pFontInstance->mpConversion',
            b'aFontSelData.maTargetName.equalsIgnoreAsciiCase("symbol")',
            b'aFontSelData.maSearchName.equalsIgnoreAsciiCase("symbol")',
            b'ConvertChar::GetRecodeData( u"Symbol", u"AppleSymbol" )'):
            if block.count(condition) != 1:
                raise ValueError('Symbol repair lost its narrow font/conversion gate')
        hashes[platform] = spec['originalMemberSHA256']
    if hashes['IOS'] == hashes['IOSSIMULATOR']:
        raise ValueError('Symbol repair must bind each actual platform member')
    # Read the actual pinned upstream mapping, never a replacement converter.
    recode_source = 'engine/unotools/source/misc/fontcvt.cxx'
    import os
    import subprocess
    env = dict(os.environ, GIT_NO_LAZY_FETCH='1', GIT_TERMINAL_PROMPT='0')
    data = subprocess.check_output(['git', '-C', str(engine_source), 'cat-file', 'blob',
        lock['commit'] + ':' + recode_source], env=env, timeout=30)
    match = re.search(rb'aAdobeSymbolToAppleSymbolTab\[224\]\s*=\s*\{(.*?)\};', data, re.S)
    if match is None:
        raise ValueError('Pinned Adobe/Apple mapping unavailable')
    table = re.sub(rb'//[^\n]*', b'', match[1])
    values = [int(value, 16) for value in re.findall(rb'0x([0-9A-Fa-f]+)', table)]
    if len(values) != 224 or values[0xF0B7 - 0xF020] != 0x2022:
        raise ValueError('Pinned Symbol F0B7 mapping is not the Unicode bullet')
    return {'sourceCommit': lock['commit'], 'originalMembers': hashes,
            'symbolBullet': 'U+F0B7 -> U+2022', 'renderingQualified': False}


def fixture_bytes():
    """Two bullet controls plus an ordinary PUA body run, on one 4:3 slide."""
    ns = 'http://schemas.openxmlformats.org'
    def shape(identifier, y, paragraph):
        return f'''<p:sp><p:nvSpPr><p:cNvPr id="{identifier}" name="Symbol QA {identifier}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="914400" y="{y}"/><a:ext cx="7315200" cy="914400"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/>{paragraph}</p:txBody></p:sp>'''
    def paragraph(text, bullet=None, font='Arial'):
        props = ('<a:buFont typeface="' + font + '"/><a:buChar char="' + bullet + '"/>') if bullet else '<a:buNone/>'
        return f'''<a:p><a:pPr marL="457200" indent="-342900">{props}</a:pPr><a:r><a:rPr lang="en-US" sz="3200"><a:solidFill><a:srgbClr val="000000"/></a:solidFill><a:latin typeface="Arial"/></a:rPr><a:t>{text}</a:t></a:r><a:endParaRPr lang="en-US" sz="3200"/></a:p>'''
    content = shape(2, 914400, paragraph('SYMBOL BULLET', '\uf0b7', 'Symbol'))
    content += shape(3, 2286000, paragraph('UNICODE BULLET', '\u2022'))
    content += shape(4, 3657600, paragraph('BODY PUA \uf0b7 KEEP'))
    parts = {
        '[Content_Types].xml': f'''<Types xmlns="{ns}/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/></Types>''',
        '_rels/.rels': f'''<Relationships xmlns="{ns}/package/2006/relationships"><Relationship Id="rId1" Type="{ns}/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>''',
        'ppt/presentation.xml': f'''<p:presentation xmlns:p="{ns}/presentationml/2006/main" xmlns:r="{ns}/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>''',
        'ppt/_rels/presentation.xml.rels': f'''<Relationships xmlns="{ns}/package/2006/relationships"><Relationship Id="rId1" Type="{ns}/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/></Relationships>''',
        'ppt/slides/slide1.xml': f'''<p:sld xmlns:p="{ns}/presentationml/2006/main" xmlns:a="{ns}/drawingml/2006/main"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>{content}</p:spTree></p:cSld></p:sld>''',
    }
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, value in sorted(parts.items()):
            entry = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' + value).encode())
    return output.getvalue()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine-source', type=Path)
    parser.add_argument('--fixture', type=Path, help='New synthetic PPTX output; refuses overwrite')
    args = parser.parse_args()
    if not args.engine_source and not args.fixture:
        parser.error('Specify --engine-source and/or --fixture')
    if args.engine_source:
        print(json.dumps(audit(args.engine_source), sort_keys=True))
    if args.fixture:
        data = fixture_bytes()
        with args.fixture.open('xb') as stream:
            stream.write(data)
        print(json.dumps({'fixture': str(args.fixture), 'sha256': hashlib.sha256(data).hexdigest(),
                          'renderingQualified': False}, sort_keys=True))
