#!/usr/bin/env python3
"""Install/check the two locked OCCT slices from an independently bound ZIP.

The caller must authenticate the draft release, asset ID and expected ZIP SHA.
This helper is infrastructure, never taken from the product checkout.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import zipfile

PREFIX = 'Vendor/OCCT.xcframework/'
MAX_RECEIPT = 1024 * 1024
MAX_ZIP = 400 * 1024 * 1024
EXPECTED_SLICES = {'ios-arm64/libOCCT-OS64.a', 'ios-arm64-simulator/libOCCT-SIMULATORARM64.a'}


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def constraints(root):
    lock = json.loads((root / 'DEPENDENCIES.json').read_text())
    result = {}
    for item in lock['artifacts']:
        path = item['installPath']
        require(path.startswith(PREFIX), 'Unexpected OCCT install path')
        relative = path[len(PREFIX):]
        require(relative in EXPECTED_SLICES and relative not in result, 'Unexpected OCCT slice')
        derived = item['derivation']
        require(derived['receiptPath'] == path + '.derivation.json', 'Unexpected receipt path')
        expected = derived['expectedResult']
        require(isinstance(expected['size'], int) and expected['size'] > 0 and
                re.fullmatch(r'[0-9a-f]{64}', expected['sha256']), 'Invalid lock result')
        result[relative] = expected
    require(set(result) == EXPECTED_SLICES, 'Both locked slices are required')
    return result


def checked_base(root):
    current = root
    for part in PurePosixPath(PREFIX).parts:
        current = current / part
        require(current.is_dir() and not current.is_symlink(), 'Unsafe OCCT input directory')
    require(current.resolve().is_relative_to(root.resolve()), 'OCCT input directory escaped checkout')
    return current


def checked_files(root):
    expected = constraints(root)
    base = checked_base(root)
    result = {}
    for name, lock in sorted(expected.items()):
        path = base / name
        receipt = base / (name + '.derivation.json')
        require(path.is_file() and not path.is_symlink() and receipt.is_file() and not receipt.is_symlink(), 'Missing input')
        require(path.stat().st_size == lock['size'] and sha(path) == lock['sha256'], 'Locked slice mismatch')
        require(0 < receipt.stat().st_size <= MAX_RECEIPT, 'Receipt size invalid')
        data = json.loads(receipt.read_bytes())
        require(data['archive']['size'] == lock['size'] and data['archive']['sha256'] == lock['sha256'], 'Receipt result mismatch')
        result[name] = {'archiveSHA256': lock['sha256'], 'archiveBytes': lock['size'],
                        'receiptSHA256': sha(receipt), 'derivationToolchain': data['toolchain']}
    return result


def install(root, archive, digest, evidence):
    require(re.fullmatch(r'[0-9a-f]{64}', digest), 'Expected ZIP digest missing')
    require(archive.is_file() and 0 < archive.stat().st_size <= MAX_ZIP and sha(archive) == digest, 'OCCT transport mismatch')
    expected = constraints(root)
    members = {name: row['size'] for name, row in expected.items()}
    members.update({name + '.derivation.json': MAX_RECEIPT for name in expected})
    with zipfile.ZipFile(archive) as source:
        infos = source.infolist()
        require(len(infos) == len(members), 'Unexpected transport member count')
        names = [entry.filename for entry in infos]
        require(len(set(names)) == len(names) and set(names) == set(members), 'Unexpected or duplicate transport member')
        for entry in infos:
            name = entry.filename; path = PurePosixPath(name); mode = entry.external_attr >> 16
            require(not path.is_absolute() and '..' not in path.parts and '\\' not in name and
                    not entry.is_dir() and not (entry.flag_bits & 1) and
                    stat.S_IFMT(mode) in (0, stat.S_IFREG), 'Unsafe transport entry')
            require(0 < entry.file_size <= members[name], 'Unexpected transport size')
            if name in expected:
                require(entry.file_size == expected[name]['size'], 'Slice size mismatch')
        require(source.testzip() is None, 'OCCT transport CRC mismatch')
        # Validate all bytes before placing any of them in the product checkout.
        temp = archive.parent / 'occt-extracted'
        require(not temp.exists(), 'Extraction staging already exists')
        temp.mkdir(mode=0o700)
        for entry in infos:
            dest = temp / entry.filename
            dest.parent.mkdir(parents=True, exist_ok=True)
            with source.open(entry) as inp, dest.open('xb') as out:
                for block in iter(lambda: inp.read(8 * 1024 * 1024), b''):
                    out.write(block)
        for name, lock in expected.items():
            require(sha(temp / name) == lock['sha256'], 'OCCT archive differs from lock')
            receipt = json.loads((temp / (name + '.derivation.json')).read_bytes())
            require(receipt['archive']['sha256'] == lock['sha256'] and receipt['archive']['size'] == lock['size'], 'OCCT receipt mismatch')
        base = checked_base(root)
        for name in names:
            dest = base / name
            require(not dest.exists() and not dest.is_symlink(), 'Refusing to replace a product input')
            require(dest.parent.is_dir() and not dest.parent.is_symlink() and dest.parent.resolve().is_relative_to(base.resolve()), 'Unsafe install directory')
        for name in names:
            dest = base / name
            with (temp / name).open('rb') as inp, dest.open('xb') as out:
                for block in iter(lambda: inp.read(8 * 1024 * 1024), b''):
                    out.write(block)
    result = checked_files(root)
    with evidence.open('x') as stream:
        json.dump({'transportSHA256': digest, 'slices': result}, stream, indent=2, sort_keys=True)
        stream.write('\n')


def verify(root, evidence):
    original = json.loads(evidence.read_text())
    require(checked_files(root) == original['slices'], 'OCCT inputs or receipts changed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('install', 'verify'))
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--sha256')
    args = parser.parse_args()
    if args.operation == 'install':
        require(args.archive is not None, 'Archive required')
        install(args.root.resolve(), args.archive, args.sha256 or '', args.evidence)
    else:
        verify(args.root.resolve(), args.evidence)


if __name__ == '__main__':
    main()
