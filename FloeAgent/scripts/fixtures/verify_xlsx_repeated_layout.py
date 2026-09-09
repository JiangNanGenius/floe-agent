#!/usr/bin/env python3
"""Compare untouched column widths and OLE geometry between native XLSX saves.

Use only when the intervening edit does not change columns or attachment layout.
This inspects ZIP/XML without opening and resaving through an Office library.
It does not certify charts, rendering, payload bytes or Microsoft Office behavior.
"""
import argparse
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import posixpath
import zipfile
from xml.etree import ElementTree as ET

SHEET = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
REL = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
VML = '{urn:schemas-microsoft-com:vml}'
CLIENT = '{urn:schemas-microsoft-com:office:excel}'


def relationships(package, part):
    name = posixpath.join(posixpath.dirname(part), '_rels', posixpath.basename(part) + '.rels')
    return {item.get('Id'): item.attrib for item in ET.fromstring(package.read(name))} if name in package.namelist() else {}


def target(part, relation):
    name = relation.get('Target', '')
    if not name or relation.get('TargetMode') == 'External':
        raise ValueError('Expected an internal document relationship')
    name = name.lstrip('/') if name.startswith('/') else posixpath.normpath(posixpath.join(posixpath.dirname(part), name))
    if name.startswith('../'):
        raise ValueError('Relationship escapes package')
    return name


def number(value):
    return None if value is None else str(Decimal(value).normalize())


def point_geometry(style):
    values = dict(entry.strip().split(':', 1) for entry in style.split(';') if ':' in entry)
    result = {}
    for name in ('margin-left', 'margin-top', 'width', 'height'):
        value = values.get(name, '').strip()
        if not value.endswith('pt'):
            raise ValueError('Expected absolute point geometry for ' + name)
        # The native model stores integer hundredths of millimeters. Ignore
        # decimal-string formatting noise, but retain a single model-unit drift.
        result[name] = int((Decimal(value[:-2]) * Decimal(2540) / Decimal(72)).to_integral_value())
    return result


def client_flag(client, name):
    child = client.find(CLIENT + name) if client is not None else None
    if child is None:
        return True
    value = (child.text or '').strip().lower()
    if value not in ('', 'true', 'false', '1', '0'):
        raise ValueError('Invalid VML movement flag')
    # Match the pinned Excel importer: absent means enabled, blank means
    # disabled. Excel's VML convention differs from the generic schema prose.
    return value in ('true', '1')


def snapshot(path):
    result = {}
    with zipfile.ZipFile(path) as package:
        book_part = 'xl/workbook.xml'
        book = ET.fromstring(package.read(book_part))
        book_relations = relationships(package, book_part)
        for sheet in book.findall(SHEET + 'sheets/' + SHEET + 'sheet'):
            part = target(book_part, book_relations[sheet.get(REL + 'id')])
            root = ET.fromstring(package.read(part))
            default = root.find(SHEET + 'sheetFormatPr')
            default_width = number(default.get('defaultColWidth')) if default is not None else None
            columns = []
            for col in root.findall(SHEET + 'cols/' + SHEET + 'col'):
                columns.append((int(col.get('min')), int(col.get('max')),
                                number(col.get('width')) or default_width))
            rels = relationships(package, part)
            objects = list(root.iter(SHEET + 'oleObject'))
            geometry = []
            if objects:
                legacy = root.find(SHEET + 'legacyDrawing')
                if legacy is None:
                    raise ValueError('Missing OLE VML drawing')
                drawing = ET.fromstring(package.read(target(part, rels[legacy.get(REL + 'id')])))
                for item in objects:
                    matches = [shape for shape in drawing.iter(VML + 'shape')
                               if shape.get('id') == '_x0000_s' + item.get('shapeId', '')]
                    if len(matches) != 1:
                        raise ValueError('Ambiguous or absent OLE VML shape')
                    shape = matches[0]
                    client = shape.find(CLIENT + 'ClientData')
                    anchor = item.find(SHEET + 'objectPr/' + SHEET + 'anchor')
                    if anchor is None:
                        raise ValueError('Missing modern OLE anchor')
                    geometry.append({'hmm': point_geometry(shape.get('style', '')),
                                     'moveWithCells': anchor.get('moveWithCells', 'false') in ('1', 'true'),
                                     'sizeWithCells': anchor.get('sizeWithCells', 'false') in ('1', 'true'),
                                     'vmlImportedMoveWithCells': client_flag(client, 'MoveWithCells'),
                                     'vmlImportedSizeWithCells': client_flag(client, 'SizeWithCells')})
            base_width = number(default.get('baseColWidth', '8')) if default is not None else '8'
            result[sheet.get('name')] = {'defaultWidth': default_width, 'baseWidth': base_width,
                                       'columns': columns, 'objects': geometry}
    return result


def effective_width(sheet, col):
    value = sheet['defaultWidth']
    for start, end, width in sheet['columns']:
        if start <= col <= end:
            value = width
    return value


def compare(before, after):
    checks = []
    def check(name, expected, actual):
        checks.append(dict(name=name, expected=expected, actual=actual, passed=expected == actual))
    check('sheet order', list(before), list(after))
    for name in (name for name in before if name in after):
        old, new = before[name], after[name]
        check(name + ' default column width', old['defaultWidth'], new['defaultWidth'])
        check(name + ' base column width', old['baseWidth'], new['baseWidth'])
        bounds = {1, 16385}
        for sheet in (old, new):
            for start, end, _ in sheet['columns']:
                bounds.update((start, end + 1))
        bounds = sorted(bounds)
        for start, stop in zip(bounds, bounds[1:]):
            check(f'{name} columns {start}-{stop - 1} width',
                  effective_width(old, start), effective_width(new, start))
        check(name + ' ordered attachment geometry and movement', old['objects'], new['objects'])
        for index, item in enumerate(new['objects']):
            check(f'{name} attachment {index} VML and modern movement agree',
                  [item['moveWithCells'], item['sizeWithCells']],
                  [item['vmlImportedMoveWithCells'], item['vmlImportedSizeWithCells']])
    return checks


def inspect(before, after):
    old, new = snapshot(before), snapshot(after)
    checks = compare(old, new)
    return dict(beforeSHA256=hashlib.sha256(before.read_bytes()).hexdigest(),
                afterSHA256=hashlib.sha256(after.read_bytes()).hexdigest(),
                before=old, after=new, checks=checks,
                allNamedChecksPassed=all(item['passed'] for item in checks),
                visualFidelityPassed=False, microsoftOfficeReopenPassed=False,
                scope='Untouched widths and ordered OLE geometry between two XLSX saves only')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    report = inspect(args.before, args.after)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'passed': report['allNamedChecksPassed'],
                      'failures': [item for item in report['checks'] if not item['passed']]}, ensure_ascii=False))
    raise SystemExit(0 if report['allNamedChecksPassed'] else 1)
