#!/usr/bin/env python3
"""Create synthetic anchor-mode inputs from an actual one-OLE XLSX save.

Test data only: this is never part of document import, editing or persistence.
Each variant changes only explicit movement flags; geometry and embedded bytes
remain those from the native saved fixture. Run the real editor on each variant.
"""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile
from xml.etree import ElementTree as ET

from verify_xlsx_repeated_layout import SHEET, CLIENT, VML, relationships, target


def generate(source, output):
    output.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(source) as package:
        part = 'xl/worksheets/sheet2.xml'
        sheet = ET.fromstring(package.read(part))
        objects = sheet.findall(SHEET + 'oleObjects/' + SHEET + 'oleObject')
        if len(objects) != 1:
            raise ValueError('Expected exactly one synthetic OLE object on sheet 2')
        anchor = objects[0].find(SHEET + 'objectPr/' + SHEET + 'anchor')
        rels = relationships(package, part)
        drawing = sheet.find(SHEET + 'legacyDrawing')
        rel_ns = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
        vml_part = target(part, rels[drawing.get(rel_ns + 'id')])
        vml = ET.fromstring(package.read(vml_part))
        shapes = [shape for shape in vml.iter(VML + 'shape')
                  if shape.get('id') == '_x0000_s' + objects[0].get('shapeId')]
        if len(shapes) != 1 or anchor is None:
            raise ValueError('Expected one matching VML shape and a modern anchor')
        client = shapes[0].find(CLIENT + 'ClientData')
        if client is None:
            raise ValueError('Expected VML client data')
        manifest = {'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
                    'purpose': 'Synthetic native-editor regression inputs only', 'variants': {}}
        for mode, move, resize in [('page', False, False), ('move', True, False), ('resize', True, True)]:
            anchor.set('moveWithCells', str(move).lower())
            anchor.set('sizeWithCells', str(resize).lower())
            for name, enabled in [('MoveWithCells', move), ('SizeWithCells', resize)]:
                for old in client.findall(CLIENT + name):
                    client.remove(old)
                if not enabled:  # Excel compatibility: empty disables; absence enables.
                    ET.SubElement(client, CLIENT + name)
            path = output / f'fixture-anchor-{mode}.xlsx'
            if path.exists():
                raise FileExistsError(path)
            changed = {part: ET.tostring(sheet, encoding='utf-8', xml_declaration=True),
                       vml_part: ET.tostring(vml, encoding='utf-8', xml_declaration=True)}
            with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as result:
                for item in package.infolist():
                    result.writestr(item.filename, changed.get(item.filename, package.read(item.filename)))
            manifest['variants'][mode] = {'file': path.name, 'moveWithCells': move,
                'sizeWithCells': resize, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        (output / 'anchor-fixtures.json').write_text(json.dumps(manifest, indent=2) + '\n')
        return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(json.dumps(generate(args.source, args.output), indent=2))
