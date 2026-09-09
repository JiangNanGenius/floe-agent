#!/usr/bin/env python3
"""Check that chart references resolve to embedded workbook cells and current caches.

Read-only qualification. This does not regenerate workbooks or claim visual fidelity.
Unsupported range expressions fail explicitly instead of counting cached data as success.
"""
import argparse
import hashlib
import io
import json
import math
from pathlib import Path
import posixpath
import re
import xml.etree.ElementTree as ET
import zipfile

C = '{http://schemas.openxmlformats.org/drawingml/2006/chart}'
S = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
R = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
P = '{http://schemas.openxmlformats.org/package/2006/relationships}'


def relations(package, owner):
    path = posixpath.join(posixpath.dirname(owner), '_rels', posixpath.basename(owner) + '.rels')
    if path not in package.namelist():
        return {}
    result = {}
    for item in ET.fromstring(package.read(path)).findall(P + 'Relationship'):
        identity = item.get('Id')
        if not identity or identity in result:
            raise ValueError('Missing or duplicate relationship ID')
        result[identity] = dict(item.attrib)
    return result


def target(owner, relation):
    value = relation.get('Target', '')
    if not value or relation.get('TargetMode') == 'External' or ':' in value or '\\' in value:
        raise ValueError('Expected internal package target')
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(owner), value))
    if resolved.startswith('/'):
        resolved = resolved[1:]
    if resolved == '..' or resolved.startswith('../'):
        raise ValueError('Relationship escapes package')
    return resolved


def cell_position(value):
    match = re.fullmatch(r'\$?([A-Z]{1,3})\$?([1-9][0-9]*)', value)
    if not match:
        raise ValueError('Unsupported cell address: ' + value)
    column = 0
    for char in match[1]:
        column = column * 26 + ord(char) - ord('A') + 1
    row = int(match[2])
    if column > 16384 or row > 1048576:
        raise ValueError('Cell address exceeds XLSX bounds')
    return row, column


def workbook_values(blob, formula):
    match = re.fullmatch(r"(?:'((?:[^']|'')+)'|([^'!\[\]]+))!([^!]+)", formula)
    if not match:
        raise ValueError('Expected workbook cell reference, found: ' + formula)
    sheet_name = match[1].replace("''", "'") if match[1] is not None else match[2]
    addresses = match[3].split(':')
    if len(addresses) not in (1, 2):
        raise ValueError('Unsupported range expression')
    first, last = cell_position(addresses[0]), cell_position(addresses[-1])
    if last[0] < first[0] or last[1] < first[1] or (last[0] - first[0] + 1) * (last[1] - first[1] + 1) > 100000:
        raise ValueError('Invalid or excessive chart range')
    with zipfile.ZipFile(io.BytesIO(blob)) as workbook:
        sheets = ET.fromstring(workbook.read('xl/workbook.xml')).findall(S + 'sheets/' + S + 'sheet')
        selected = [sheet for sheet in sheets if sheet.get('name') == sheet_name]
        if len(selected) != 1:
            raise ValueError('Chart sheet is missing or ambiguous: ' + sheet_name)
        rels = relations(workbook, 'xl/workbook.xml')
        sheet_path = target('xl/workbook.xml', rels[selected[0].get(R + 'id')])
        shared = []
        for rel in rels.values():
            if rel.get('Type', '').endswith('/sharedStrings'):
                shared = [''.join(item.itertext()) for item in
                          ET.fromstring(workbook.read(target('xl/workbook.xml', rel))).findall(S + 'si')]
        values = {}
        for cell in ET.fromstring(workbook.read(sheet_path)).iter(S + 'c'):
            position = cell_position(cell.get('r', ''))
            value = cell.findtext(S + 'v')
            kind = cell.get('t')
            if kind == 's':
                value = shared[int(value)]
            elif kind == 'inlineStr':
                value = ''.join(cell.find(S + 'is').itertext())
            elif kind == 'b':
                value = value == '1'
            elif value is not None and kind not in ('str', 'e'):
                value = float(value)
            if cell.find(S + 'f') is not None and value is None:
                raise ValueError('Formula cell has no calculated value')
            values[position] = value
        return [values.get((row, column)) for row in range(first[0], last[0] + 1)
                for column in range(first[1], last[1] + 1)]


def inspect(path):
    checks = []
    with zipfile.ZipFile(path) as package:
        charts = sorted(name for name in package.namelist()
                        if re.fullmatch(r'ppt/charts/chart[^/]*\.xml', name))
        checks.append({'name': 'has chart fixtures', 'passed': bool(charts)})
        for name in charts:
            root = ET.fromstring(package.read(name))
            blob = None
            try:
                external = root.find(C + 'externalData')
                if external is None:
                    raise ValueError('Chart has no externalData workbook relationship')
                rel = relations(package, name)[external.get(R + 'id')]
                if not rel.get('Type', '').endswith('/package'):
                    raise ValueError('Chart relationship is not a workbook package')
                blob = package.read(target(name, rel))
                with zipfile.ZipFile(io.BytesIO(blob)) as workbook:
                    workbook.read('xl/workbook.xml')
                checks.append({'name': name + ' workbook payload', 'passed': True,
                               'sha256': hashlib.sha256(blob).hexdigest()})
            except (ValueError, KeyError, zipfile.BadZipFile, ET.ParseError) as error:
                checks.append({'name': name + ' workbook payload', 'passed': False, 'error': str(error)})
            for reference in root.iter():
                if reference.tag not in (C + 'numRef', C + 'strRef', C + 'multiLvlStrRef'):
                    continue
                formula = reference.findtext(C + 'f', '')
                check = {'name': name + ' range ' + formula, 'formula': formula, 'passed': False}
                try:
                    # Validate the formula even when the entire workbook was lost.
                    if '!' not in formula:
                        raise ValueError('Internal model label is not an Excel range: ' + formula)
                    if blob is None:
                        raise ValueError('Cannot resolve range without embedded workbook')
                    values = workbook_values(blob, formula)
                    if reference.tag == C + 'multiLvlStrRef':
                        raise ValueError('Multilevel category layout requires a dedicated fixture')
                    numeric = reference.tag == C + 'numRef'
                    cache = reference.find(C + ('numCache' if numeric else 'strCache'))
                    if cache is None or int(cache.find(C + 'ptCount').get('val')) != len(values):
                        raise ValueError('Cache count differs from workbook range')
                    points = {}
                    for point in cache.findall(C + 'pt'):
                        index = int(point.get('idx'))
                        if index in points or index < 0 or index >= len(values):
                            raise ValueError('Invalid cache point index')
                        raw = point.findtext(C + 'v', '')
                        points[index] = float(raw) if numeric else raw
                    actual = [points.get(i) for i in range(len(values))]
                    def equal(a, b):
                        if numeric and isinstance(a, (int, float)) and isinstance(b, (int, float)):
                            return math.isclose(a, b, rel_tol=1e-12, abs_tol=1e-12)
                        return a == b
                    check.update(workbookValues=values, cacheValues=actual,
                                 passed=all(equal(a, b) for a, b in zip(values, actual)))
                except (ValueError, KeyError, AttributeError, IndexError, ET.ParseError, zipfile.BadZipFile) as error:
                    check['error'] = str(error)
                checks.append(check)
    return {'sourceSHA256': hashlib.sha256(Path(path).read_bytes()).hexdigest(), 'checks': checks,
            'allNamedChecksPassed': all(item['passed'] for item in checks),
            'scope': 'Embedded chart workbook relationships, resolvable rectangular cell ranges and cache agreement only; not full Office fidelity.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = inspect(args.file)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'passed': result['allNamedChecksPassed'],
                      'failures': [item for item in result['checks'] if not item['passed']]}, ensure_ascii=False))
    raise SystemExit(0 if result['allNamedChecksPassed'] else 1)
