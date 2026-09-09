#!/usr/bin/env python3
"""Qualify a synthetic Word attachment using independent olefile/oletools readers.

Requires oletools 0.60.2. Never activates an embedded object. This verifies the
named structural checks only; UI, undo, visual layout and Office reopening are
separate acceptance gates.
"""
import argparse
import hashlib
import io
import json
import posixpath
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

import olefile
from oletools.oleobj import OleNativeStream

NS = {
    'w': 'http://schemas.openxmlformats.org/wordprocessingml/2006/main',
    'o': 'urn:schemas-microsoft-com:office:office',
    'v': 'urn:schemas-microsoft-com:vml',
    'r': 'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
}


def inspect(saved, attachment, paragraph_index):
    checks = []
    def check(name, expected, actual):
        checks.append(dict(name=name, expected=expected, actual=actual, passed=expected == actual))
    expected_bytes = attachment.read_bytes()
    expected_sha = hashlib.sha256(expected_bytes).hexdigest()
    with zipfile.ZipFile(saved) as doc:
        document = ET.fromstring(doc.read('word/document.xml'))
        relations = {x.attrib['Id']: x.attrib for x in ET.fromstring(doc.read('word/_rels/document.xml.rels'))}
        objects = document.findall('.//w:object', NS)
        check('one embedded display object', 1, len(objects))
        check('object in selected paragraph', True,
              len(document.findall('w:body/w:p', NS)) > paragraph_index and
              document.findall('w:body/w:p', NS)[paragraph_index].find('.//w:object', NS) is not None)
        for index, item in enumerate(objects):
            ole = item.find('o:OLEObject', NS)
            check(f'{index} OLE declaration', True, ole is not None)
            if ole is None:
                continue
            check(f'{index} embedded not linked', 'Embed', ole.get('Type'))
            check(f'{index} package class', 'Package', ole.get('ProgID'))
            check(f'{index} icon presentation', 'Icon', ole.get('DrawAspect'))
            relation = relations.get(ole.get('{%s}id' % NS['r']), {})
            check(f'{index} internal relationship', False, relation.get('TargetMode') == 'External')
            target = posixpath.normpath(posixpath.join('word', relation.get('Target', '')))
            check(f'{index} embedded payload part', True, target.startswith('word/embeddings/') and target in doc.namelist())
            if not target.startswith('word/embeddings/') or target not in doc.namelist():
                continue
            with olefile.OleFileIO(io.BytesIO(doc.read(target))) as storage:
                check(f'{index} Package compound class', '0003000C-0000-0000-C000-000000000046', storage.root.clsid.upper())
                native = OleNativeStream(storage.openstream('\x01Ole10Native').read())
                check(f'{index} file is embedded', False, native.is_link)
                check(f'{index} original byte length', len(expected_bytes), native.actual_size)
                check(f'{index} original byte hash', expected_sha, hashlib.sha256(native.data or b'').hexdigest())
                check(f'{index} original filename', attachment.name, native.filename)
            image = item.find('.//v:imagedata', NS)
            image_relation = relations.get(image.get('{%s}id' % NS['r']) if image is not None else None, {})
            image_path = posixpath.normpath(posixpath.join('word', image_relation.get('Target', '')))
            check(f'{index} icon image stored', True, image_path.startswith('word/media/') and image_path in doc.namelist())
    return dict(sourceAttachmentSHA256=expected_sha, savedSHA256=hashlib.sha256(saved.read_bytes()).hexdigest(),
                checks=checks, allNamedChecksPassed=all(c['passed'] for c in checks),
                undoRedoPassed=False, visualFidelityPassed=False, microsoftOfficeReopenPassed=False,
                originalFileWritebackPassed=False, physicalDevicePassed=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('saved', type=Path)
    parser.add_argument('attachment', type=Path)
    parser.add_argument('--paragraph', type=int, default=0)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = inspect(args.saved, args.attachment, args.paragraph)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(0 if result['allNamedChecksPassed'] else 1)
