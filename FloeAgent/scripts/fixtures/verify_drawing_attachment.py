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


def inspect(saved, attachment, part):
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
                if item.get('progId') == 'Package':
                    objects.append((name, item))
        check('one live Package attachment', 1, len(objects))
        for index, (name, item) in enumerate(objects):
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
    args = parser.parse_args()
    if args.saved.suffix.lower() not in ('.xlsx', '.pptx') or args.part < 1:
        parser.error('Choose XLSX/PPTX and a positive part number')
    result = inspect(args.saved, args.attachment, args.part)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if result['allNamedChecksPassed'] else 1)
