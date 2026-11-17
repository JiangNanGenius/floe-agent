#!/usr/bin/env python3
"""Record and recheck both locked OCCT slices after strict qualification.

This helper belongs to the infrastructure commit, not the product checkout.
The workflow must separately run bootstrap --release-check before and after build.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re

PREFIX = 'Vendor/OCCT.xcframework/'
MAX_RECEIPT = 1024 * 1024
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
        tool = data['toolchain']
        require((tool.get('xcodeVersion'), tool.get('xcodeBuild'), tool.get('sdkVersion')) ==
                ('27.1', '27A9275', '27.1'), 'OCCT derivation toolchain mismatch')
        result[name] = {'archiveSHA256': lock['sha256'], 'archiveBytes': lock['size'],
                        'receiptSHA256': sha(receipt), 'derivationToolchain': data['toolchain']}
    return result


def capture(root, evidence):
    result = checked_files(root)
    with evidence.open('x') as stream:
        json.dump({'slices': result}, stream, indent=2, sort_keys=True)
        stream.write('\n')


def verify(root, evidence):
    original = json.loads(evidence.read_text())
    require(checked_files(root) == original['slices'], 'OCCT inputs or receipts changed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('capture', 'verify'))
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    if args.operation == 'capture':
        capture(args.root.resolve(), args.evidence)
    else:
        verify(args.root.resolve(), args.evidence)


if __name__ == '__main__':
    main()
