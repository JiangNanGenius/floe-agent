#!/usr/bin/env python3
"""Check actual XLSX/PPTX Package bytes with independent olefile/oletools.

This does not certify geometry, rendering, undo, original-file writeback or
Microsoft Office compatibility. Run it on the saved/reopened native artifact,
never on an import sidecar. Dependencies match verify_office_attachment.py.
"""
import argparse
import hashlib
import io
import json
import posixpath
import struct
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

import olefile
from oletools.oleobj import OleNativeStream

REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
SHEET = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
SLIDE = 'http://schemas.openxmlformats.org/presentationml/2006/main'
DRAWING = 'http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing'
VML = 'urn:schemas-microsoft-com:vml'


def spreadsheet_display_checks(document, worksheet, item, check, prefix, expected_cell=None):
    """Independently follow the worksheet -> VML -> image graph and cell anchor.

    These checks prove saved relationships and named coordinates, not rendering.
    The XLSX object properties and VML fallback must identify the same live object.
    """
    def relationships(part):
        path = posixpath.join(posixpath.dirname(part), '_rels', posixpath.basename(part) + '.rels')
        return {element.get('Id'): element.attrib
                for element in ET.fromstring(document.read(path))} if path in document.namelist() else {}

    def target(part, relation):
        value = relation.get('Target', '')
        if not value or relation.get('TargetMode') == 'External':
            return None
        path = value.lstrip('/') if value.startswith('/') else posixpath.normpath(
            posixpath.join(posixpath.dirname(part), value))
        return path if path in document.namelist() and not path.startswith('../') else None

    sheet_xml = ET.fromstring(document.read(worksheet))
    sheet_relations = relationships(worksheet)
    legacy = sheet_xml.find(f'{{{SHEET}}}legacyDrawing')
    relation = sheet_relations.get(legacy.get(f'{{{REL}}}id'), {}) if legacy is not None else {}
    drawing_path = target(worksheet, relation)
    check(prefix + ' VML drawing relationship', REL + '/vmlDrawing', relation.get('Type'))
    check(prefix + ' VML drawing exists', True, drawing_path is not None)
    if drawing_path is None:
        return
    drawing = ET.fromstring(document.read(drawing_path))
    shapes = [shape for shape in drawing.iter(f'{{{VML}}}shape')
              if shape.get('id') == '_x0000_s' + item.get('shapeId', '')]
    check(prefix + ' exactly one corresponding VML shape', 1, len(shapes))
    if len(shapes) != 1:
        return
    shape_type = shapes[0].get('type', '')
    matching_types = [value for value in drawing.iter(f'{{{VML}}}shapetype')
                      if shape_type == '#' + value.get('id', '')]
    check(prefix + ' exactly one corresponding VML shape type', 1, len(matching_types))
    image = shapes[0].find(f'{{{VML}}}imagedata')
    image_relation = relationships(drawing_path).get(image.get(f'{{{REL}}}id'), {}) if image is not None else {}
    image_path = target(drawing_path, image_relation)
    check(prefix + ' VML image relationship', REL + '/image', image_relation.get('Type'))
    check(prefix + ' nonempty VML preview image', True,
          image_path is not None and bool(document.read(image_path)))
    properties = item.find(f'{{{SHEET}}}objectPr')
    check(prefix + ' modern embedded object properties', True, properties is not None)
    if properties is None:
        return
    properties_relation = sheet_relations.get(properties.get(f'{{{REL}}}id'), {})
    properties_image = target(worksheet, properties_relation)
    check(prefix + ' worksheet preview image relationship', REL + '/image', properties_relation.get('Type'))
    check(prefix + ' modern and VML preview bytes agree', True,
          image_path is not None and properties_image is not None
          and document.read(image_path) == document.read(properties_image))
    anchor = properties.find(f'{{{SHEET}}}anchor')
    markers = []
    for name in ('from', 'to'):
        marker = anchor.find(f'{{{SHEET}}}{name}') if anchor is not None else None
        values = []
        for coordinate in ('col', 'colOff', 'row', 'rowOff'):
            child = marker.find(f'{{{DRAWING}}}{coordinate}') if marker is not None else None
            try:
                values.append(int(child.text) if child is not None else None)
            except (ValueError, TypeError):
                values.append(None)
        check(prefix + ' ' + name + ' complete nonnegative cell marker', True,
              all(value is not None and value >= 0 for value in values))
        markers.append(values)
    if expected_cell is not None:
        check(prefix + ' selected starting cell and zero offsets',
              [expected_cell[0], 0, expected_cell[1], 0], markers[0])
    if all(value is not None for values in markers for value in values):
        first, last = markers
        check(prefix + ' positive anchor width', True, (last[0], last[1]) > (first[0], first[1]))
        check(prefix + ' positive anchor height', True, (last[2], last[3]) > (first[2], first[3]))


def inspect(saved, attachment, part, expected_cell=None):
    checks = []
    def check(name, expected, actual):
        checks.append(dict(name=name, expected=expected, actual=actual, passed=expected == actual))

    expected = attachment.read_bytes()
    expected_sha = hashlib.sha256(expected).hexdigest()
    root = 'xl' if saved.suffix.lower() == '.xlsx' else 'ppt'
    folder = 'worksheets' if root == 'xl' else 'slides'
    filename = ('sheet' if root == 'xl' else 'slide') + str(part) + '.xml'
    namespace, tag = (SHEET, 'oleObject') if root == 'xl' else (SLIDE, 'oleObj')
    selected = f'{root}/{folder}/{filename}'
    with zipfile.ZipFile(saved) as document:
        check('selected sheet or slide exists', True, selected in document.namelist())
        objects = []
        for name in document.namelist():
            if not name.startswith(f'{root}/{folder}/') or not name.endswith('.xml') or '/_rels/' in name:
                continue
            xml = ET.fromstring(document.read(name))
            for item in xml.iter(f'{{{namespace}}}{tag}'):
                objects.append((name, item))
        check('one embedded object in attachment fixture', 1, len(objects))
        for index, (name, item) in enumerate(objects):
            check(f'{index} declared Package type', 'Package', item.get('progId'))
            check(f'{index} attachment in selected sheet or slide', selected, name)
            relation_path = posixpath.join(posixpath.dirname(name), '_rels', posixpath.basename(name) + '.rels')
            relations = {x.attrib['Id']: x.attrib for x in ET.fromstring(document.read(relation_path))}
            relation = relations.get(item.get(f'{{{REL}}}id'), {})
            check(f'{index} embedded object relationship', REL + '/oleObject', relation.get('Type'))
            check(f'{index} not an external link', False, relation.get('TargetMode') == 'External')
            target = relation.get('Target', '')
            target = target.lstrip('/') if target.startswith('/') else posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
            exists = target.startswith(root + '/embeddings/') and target in document.namelist()
            check(f'{index} payload inside document', True, exists)
            if not exists:
                continue
            if root == 'ppt':
                check(f'{index} embedded not linked', True, item.find(f'{{{SLIDE}}}embed') is not None)
                check(f'{index} icon presentation', True, item.get('showAsIcon') in ('1', 'true'))
            else:
                check(f'{index} icon presentation', 'DVASPECT_ICON', item.get('dvAspect'))
                spreadsheet_display_checks(document, name, item, check, str(index), expected_cell)
            with olefile.OleFileIO(io.BytesIO(document.read(target))) as storage:
                check(f'{index} Package compound class', '0003000C-0000-0000-C000-000000000046', storage.root.clsid.upper())
                stream = io.BytesIO(storage.openstream('\x01Ole10Native').read())
                native = OleNativeStream(stream)
                payload = stream.read(native.actual_size)
                check(f'{index} embedded bytes not a link', False, native.is_link)
                check(f'{index} original byte length', len(expected), native.actual_size)
                check(f'{index} original byte hash', expected_sha, hashlib.sha256(payload).hexdigest())
                for field in ('command', 'label', 'filename'):
                    length = struct.unpack('<I', stream.read(4))[0]
                    if length > 32768:
                        raise ValueError('Attachment Unicode field exceeds the fixture limit')
                    encoded = stream.read(length * 2)
                    if len(encoded) != length * 2:
                        raise ValueError('Truncated attachment Unicode field')
                    check(f'{index} Unicode {field}', attachment.name, encoded.decode('utf-16le'))
                check(f'{index} complete native stream parsed', '', stream.read().hex())
    return dict(sourceAttachmentSHA256=expected_sha, savedSHA256=hashlib.sha256(saved.read_bytes()).hexdigest(),
                checks=checks, allNamedChecksPassed=all(c['passed'] for c in checks),
                geometryPassed=False, visualFidelityPassed=False, undoRedoPassed=False,
                microsoftOfficeReopenPassed=False, originalFileWritebackPassed=False, physicalDevicePassed=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('saved', type=Path)
    parser.add_argument('attachment', type=Path)
    parser.add_argument('--part', type=int, default=1, help='One-based sheet/slide XML part number')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--expected-cell', type=int, nargs=2, metavar=('COL', 'ROW'),
                        help='Expected zero-based XLSX starting cell, with zero EMU offsets')
    args = parser.parse_args()
    if args.saved.suffix.lower() not in ('.xlsx', '.pptx') or args.part < 1:
        parser.error('Choose XLSX/PPTX and a positive part number')
    if args.expected_cell is not None and (args.saved.suffix.lower() != '.xlsx' or min(args.expected_cell) < 0):
        parser.error('Expected cell requires XLSX and nonnegative column/row indices')
    result = inspect(args.saved, args.attachment, args.part, args.expected_cell)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if result['allNamedChecksPassed'] else 1)
