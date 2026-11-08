#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Namespace static-library headers without touching the archived libraries."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('xcframework', type=Path)
parser.add_argument('--check', action='store_true', help='Validate only; do not modify files')
args = parser.parse_args()
root = args.xcframework
info_path = root / 'Info.plist'
info = plistlib.loads(info_path.read_bytes())
normalization_path = root / 'normalization-manifest.json'
normalization = json.loads(normalization_path.read_text())
expected = {'ios-arm64', 'ios-arm64-simulator', 'macos-arm64'}
assert {entry['LibraryIdentifier'] for entry in info['AvailableLibraries']} == expected
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
records = {}
for entry in info['AvailableLibraries']:
    identifier = entry['LibraryIdentifier']
    slice_root = root / identifier
    archive = slice_root / entry['LibraryPath']
    # Refuse any binary drift before making a packaging-only change.
    binary_hash = digest(archive)
    assert binary_hash == normalization[identifier]['consumer']['sha256'], identifier
    assert archive.stat().st_size == normalization[identifier]['consumer']['byteCount']
    include = slice_root / 'include'
    namespace = include / 'FloeFontCompiler'
    if not args.check:
        previous = slice_root / entry['HeadersPath']
        if previous != include:
            assert not include.exists(), include
            previous.rename(include)
        namespace.mkdir(exist_ok=True)
        for name in ['FloeFontCompiler.h', 'module.modulemap']:
            flat = include / name
            if flat.exists():
                assert not (namespace / name).exists(), name
                flat.rename(namespace / name)
        entry['HeadersPath'] = 'include'
    assert entry['HeadersPath'] == 'include'
    assert not (include / 'module.modulemap').exists()
    assert (namespace / 'module.modulemap').read_text().strip() == 'module FloeFontCompiler { header "FloeFontCompiler.h" export * }'
    assert (namespace / 'FloeFontCompiler.h').is_file()
    record = {'headersPath': 'include', 'moduleMap': 'include/FloeFontCompiler/module.modulemap',
              'moduleMapSHA256': digest(namespace / 'module.modulemap'),
              'header': 'include/FloeFontCompiler/FloeFontCompiler.h',
              'headerSHA256': digest(namespace / 'FloeFontCompiler.h'),
              'binarySHA256': binary_hash, 'binaryBytesUnchanged': True}
    records[identifier] = record
    if args.check:
        assert normalization[identifier]['headerLayout'] == record
    else:
        normalization[identifier]['headerLayout'] = record
if not args.check:
    info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False))
    normalization_path.write_text(json.dumps(normalization, indent=2) + '\n')
layout = {'reason': 'Static XCFramework consumers share Products/include; module.modulemap must have a module-specific subdirectory.',
          'infoPlistSHA256': digest(info_path), 'slices': records}
manifest = root / 'header-layout-manifest.json'
if args.check:
    assert json.loads(manifest.read_text()) == layout
else:
    manifest.write_text(json.dumps(layout, indent=2) + '\n')
print(json.dumps({'verified': True, 'headersPath': 'include', 'moduleNamespace': 'FloeFontCompiler', 'slices': sorted(records), 'binariesUnchanged': True}))
