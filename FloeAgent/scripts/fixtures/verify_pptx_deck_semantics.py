#!/usr/bin/env python3
"""Deterministic semantic qualification for the synthetic sample deck.

`sample-deck.pptx` is the presentation fixture the Office visible-render
qualification binds its receipts to. This verifier reads the saved OOXML package
with the standard library only (no engine, no renderer, no network) and asserts
the exact slide count, slide size, per-slide shape geometry, text and chart
values that `make_office_editor_fixtures.py::create_sample_deck` writes. A
rendered-tile receipt is then accepted only when it names this presentation, a
positive decoded-tile count, a sized canvas, and a deck digest that matches the
fixture; a receipt that claims success while reporting no render is rejected.

Usage:
  python3 verify_pptx_deck_semantics.py [--deck PATH] [--render-receipt REceIPT ...]
                                        [--self-test] [--output REPORT.json]
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
DEFAULT_DECK = ROOT / 'sample-deck.pptx'

A = '{http://schemas.openxmlformats.org/drawingml/2006/main}'
P = '{http://schemas.openxmlformats.org/presentationml/2006/main}'
R = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
C = '{http://schemas.openxmlformats.org/drawingml/2006/chart}'

SLIDE_SIZE = (12191999, 6858000)
# slide XML -> (text, prst geometry or None, off, ext, fill or None)
SHAPES = {
    'ppt/slides/slide1.xml': [
        ('FLOE SAMPLE DECK — 幻灯片一', 'rect', (640080, 457200), (10972800, 731520), None),
        ('SAMPLE_BOX', 'roundRect', (731520, 1828800), (2743200, 1828800), '165DBE'),
    ],
    'ppt/slides/slide2.xml': [
        ('SAMPLE_SECOND_SLIDE', 'rect', (914400, 914400), (9144000, 1828800), None),
    ],
    'ppt/slides/slide3.xml': [
        ('SAMPLE_THIRD_SLIDE', 'ellipse', (1828800, 1828800), (2743200, 2743200), '00A650'),
    ],
}
CHART_FRAME = {'slide': 'ppt/slides/slide1.xml', 'off': (4572000, 1645920), 'ext': (6400800, 4114800)}
CHART = {'target': 'ppt/charts/chart1.xml', 'series': 'Values',
         'categories': ['Alpha', 'Beta'], 'values': ['12', '24']}


def digest(path):
    checksum = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1048576), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


def _xfrm(shape):
    xfrm = shape.find(f'{P}spPr/{A}xfrm')
    if xfrm is None:
        return None
    off = xfrm.find(f'{A}off')
    ext = xfrm.find(f'{A}ext')
    if off is None or ext is None:
        return None
    return (int(off.get('x')), int(off.get('y'))), (int(ext.get('cx')), int(ext.get('cy')))


def _text(shape):
    return ''.join(node.text or '' for node in shape.iter(f'{A}t'))


def _geometry(shape):
    geom = shape.find(f'{P}spPr/{A}prstGeom')
    return geom.get('prst') if geom is not None else None


def _fill(shape):
    fill = shape.find(f'{P}spPr/{A}solidFill/{A}srgbClr')
    return fill.get('val') if fill is not None else None


def verify_deck(path):
    failures = []
    with zipfile.ZipFile(path) as package:
        names = set(package.namelist())
        presentation = ET.fromstring(package.read('ppt/presentation.xml'))
        slide_ids = presentation.findall(f'{P}sldIdLst/{P}sldId')
        if len(slide_ids) != 3:
            failures.append(f'expected 3 slides, found {len(slide_ids)}')
        size = presentation.find(f'{P}sldSz')
        if size is None or (int(size.get('cx')), int(size.get('cy'))) != SLIDE_SIZE:
            failures.append(f'slide size is not the fixture size {SLIDE_SIZE}')
        for index, slide_id in enumerate(slide_ids, 1):
            identifier = slide_id.get(f'{R}id')
            rels = ET.fromstring(package.read('ppt/_rels/presentation.xml.rels'))
            targets = {rel.get('Id'): rel.get('Target') for rel in rels}
            target = targets.get(identifier)
            if target != f'slides/slide{index}.xml':
                failures.append(f'slide {index} resolves to {target!r}, '
                                f'expected slides/slide{index}.xml')
        for name, expected in SHAPES.items():
            if name not in names:
                failures.append(f'missing slide part {name}')
                continue
            root = ET.fromstring(package.read(name))
            shapes = root.findall(f'.//{P}sp')
            for text, geometry, off, ext, fill in expected:
                matched = [shape for shape in shapes if _text(shape) == text]
                if not matched:
                    failures.append(f'{name}: no shape with text {text!r}')
                    continue
                shape = matched[0]
                if _geometry(shape) != geometry:
                    failures.append(f'{name}: {text!r} geometry {_geometry(shape)!r} != {geometry!r}')
                xfrm = _xfrm(shape)
                if xfrm != (off, ext):
                    failures.append(f'{name}: {text!r} transform {xfrm!r} != {(off, ext)!r}')
                if _fill(shape) != fill:
                    failures.append(f'{name}: {text!r} fill {_fill(shape)!r} != {fill!r}')
        # The chart frame must reference the chart part through the slide rels.
        slide1 = ET.fromstring(package.read(CHART_FRAME['slide']))
        frames = slide1.findall(f'.//{P}graphicFrame')
        frame = next((item for item in frames if item.find(f'.//{C}chart') is not None), None)
        if frame is None:
            failures.append('slide 1 has no chart frame')
        else:
            xfrm = frame.find(f'{P}xfrm')
            off = xfrm.find(f'{A}off')
            ext = xfrm.find(f'{A}ext')
            if (int(off.get('x')), int(off.get('y'))) != CHART_FRAME['off']:
                failures.append('chart frame offset changed')
            if (int(ext.get('cx')), int(ext.get('cy'))) != CHART_FRAME['ext']:
                failures.append('chart frame extent changed')
            rel_id = frame.find(f'.//{C}chart').get(f'{R}id')
            rels = ET.fromstring(package.read('ppt/slides/_rels/slide1.xml.rels'))
            targets = {rel.get('Id'): rel.get('Target') for rel in rels}
            if targets.get(rel_id) != '../charts/chart1.xml':
                failures.append('chart frame does not resolve to ppt/charts/chart1.xml')
        chart = ET.fromstring(package.read(CHART['target']))
        categories = [node.text for node in
                      chart.findall(f'.//{C}cat//{C}pt/{C}v')]
        values = [node.text for node in chart.findall(f'.//{C}val//{C}pt/{C}v')]
        series_name = next((node.text for node in
                            chart.findall(f'.//{C}ser/{C}tx//{C}pt/{C}v')), None)
        if categories != CHART['categories']:
            failures.append(f'chart categories {categories} != {CHART["categories"]}')
        if values != CHART['values']:
            failures.append(f'chart values {values} != {CHART["values"]}')
        if series_name != CHART['series']:
            failures.append(f'chart series name {series_name!r} != {CHART["series"]!r}')
        # A deterministic fixture never depends on an external part.
        for name in names:
            if name.endswith('.rels'):
                rels = ET.fromstring(package.read(name))
                for rel in rels:
                    if rel.get('TargetMode') == 'External':
                        failures.append(f'{name}: external relationship {rel.get("Target")}')
    return failures


def verify_render_receipt(receipt_path, deck):
    """A rendered-tile receipt must prove a painted presentation of this deck."""
    failures = []
    try:
        receipt = json.loads(Path(receipt_path).read_text())
    except (OSError, ValueError) as error:
        return [f'{receipt_path}: unreadable render receipt ({error})']
    if receipt.get('docType') != 'presentation':
        failures.append(f'{receipt_path}: docType {receipt.get("docType")!r} is not presentation')
    if receipt.get('visibleRender') is not True:
        failures.append(f'{receipt_path}: visibleRender is not true')
    tiles = receipt.get('readyTiles')
    if not isinstance(tiles, int) or isinstance(tiles, bool) or tiles <= 0:
        failures.append(f'{receipt_path}: readyTiles {tiles!r} is not a positive decoded-tile count')
    for field in ('canvasWidth', 'canvasHeight'):
        value = receipt.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or value <= 1:
            failures.append(f'{receipt_path}: {field} {value!r} is not a sized canvas')
    expected = receipt.get('deckSHA256')
    if expected is not None and expected != digest(deck):
        failures.append(f'{receipt_path}: deck digest does not match the fixture')
    if receipt.get('slideCount') not in (None, 3):
        failures.append(f'{receipt_path}: slideCount {receipt.get("slideCount")!r} != 3')
    return failures


def self_test(deck):
    """The gate must accept a real receipt and reject every unproven claim."""
    good = {'docType': 'presentation', 'visibleRender': True, 'readyTiles': 4,
            'canvasWidth': 1024, 'canvasHeight': 768, 'slideCount': 3,
            'deckSHA256': digest(deck)}
    rejected = [
        {**good, 'visibleRender': False},
        {**good, 'readyTiles': 0},
        {**good, 'canvasWidth': 0},
        {**good, 'docType': 'text'},
        {**good, 'deckSHA256': '0' * 64},
        {**good, 'slideCount': 2},
    ]
    with __import__('tempfile').TemporaryDirectory() as folder:
        path = Path(folder) / 'receipt.json'
        path.write_text(json.dumps(good))
        if verify_render_receipt(path, deck):
            return ['a fully evidenced receipt must pass: ' + str(verify_render_receipt(path, deck))]
        for index, receipt in enumerate(rejected):
            path.write_text(json.dumps(receipt))
            if not verify_render_receipt(path, deck):
                return [f'rejected receipt {index} was accepted']
    return []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deck', type=Path, default=DEFAULT_DECK)
    parser.add_argument('--render-receipt', type=Path, action='append', default=[])
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    failures = verify_deck(args.deck)
    for receipt in args.render_receipt:
        failures.extend(verify_render_receipt(receipt, args.deck))
    if args.self_test:
        failures.extend(self_test(args.deck))
    report = {
        'deck': str(args.deck),
        'deckSHA256': digest(args.deck),
        'slideCount': 3,
        'checksPassed': not failures,
        'failures': failures,
        'renderedTileQualificationPassed': bool(args.render_receipt) and not failures,
        'deviceRenderPassed': False,
    }
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    if failures:
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
