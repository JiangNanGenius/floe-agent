#!/usr/bin/env python3
"""Derive a public-safe device component ZIP; never rewrite the private input.

This is packaging only. Existing transport/pin/bootstrap/component validators
must validate the derived ZIP before storage/publication. No compile, release,
capability promotion, lock update or signing occurs here.
"""
import argparse
import copy
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile
from urllib.parse import unquote
import zipfile

import validate_local_office_transport as transport
from office_component_recovery import private_material_failures

SCHEMA = 1
HELPER_NAME = 'FloeAgent/scripts/office_component_public_metadata.py'
MANIFEST = 'OfficeNativeHost/native-host.json'
BINARY = 'OfficeNativeHost/FloeOfficeNative.framework/FloeOfficeNative'
HEADER = 'FloeOfficeNative.framework/FloeOfficeNative:'
REMOVED_FIELDS = (
    ('command',), ('engineRepairReceiptPath',),
    ('filterOverlay', 'compileCommand'), ('filterOverlay', 'compileCommands'),
    ('filterOverlay', 'archive'), ('filterOverlay', 'selectedArchive'),
    ('filterOverlay', 'serializationDelta', 'command'),
)
HEADER_FIELDS = ('platformLoadCommands', 'dynamicLibraries')
PRIVATE = re.compile(r'(?:/(?:Users|Volumes|home|private|tmp)(?:/|$)|'
                     r'/var/(?:folders|tmp)(?:/|$)|'
                     r'(?:^|[/\s])Local/(?:Private|Artifacts|Scratch|Worktrees)(?:/|$)|'
                     r'file://|(?:^|[\s=\"\x27])~[/\\]|'
                     r'(?:^|[\s=\"\x27])[A-Za-z]:[/\\]|\\\\)', re.I)
ABSOLUTE = re.compile(r'(?:^|[\s=\"\x27(:])(/[^\s\"\x27<>]*)')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(data)
    return result.hexdigest()


def path_failures(text, *, allow_system_libraries=False):
    """Reject paths without echoing their private values into logs/errors."""
    variants = [text]
    for _ in range(2):
        decoded = unquote(variants[-1])
        if decoded == variants[-1]:
            break
        variants.append(decoded)
    variants += [value.replace('\\', '/') for value in variants if '\\' in value]
    for value in variants:
        if PRIVATE.search(value) or PRIVATE.search(value.replace('\\', '/')):
            return True
        for match in ABSOLUTE.finditer(value):
            candidate = match.group(1)
            if (candidate.startswith('//')
                    and re.search(r'[A-Za-z][A-Za-z0-9+.-]*:$', value[:match.start(1)])):
                # A real URL scheme may contain //; a bare //server/share is
                # an absolute filesystem path and must fail closed.
                continue
            if allow_system_libraries and candidate.startswith(('/System/Library/', '/usr/lib/')):
                continue
            return True
    return False


def assert_public_metadata(value, path=()):
    if isinstance(value, dict):
        for key, child in value.items():
            require(isinstance(key, str) and not path_failures(key),
                    'Metadata contains an unsafe key (value withheld)')
            assert_public_metadata(child, path + (key,))
    elif isinstance(value, list):
        for child in value:
            assert_public_metadata(child, path + ('[]',))
    elif isinstance(value, str):
        require(not path_failures(value, allow_system_libraries=path == ('dynamicLibraries',)),
                'Metadata contains an unrecognized local/private path (value withheld)')
    else:
        require(value is None or type(value) in (bool, int, float), 'Unsupported metadata value')


def normalize_manifest(original):
    require(isinstance(original, dict), 'Manifest must be an object')
    require(original.get('sdk') == 'iphoneos' and original.get('arch') == 'arm64',
            'Only the arm64 device component can be normalized')
    result = copy.deepcopy(original)
    changed = []
    for path in REMOVED_FIELDS:
        parent = result
        for key in path[:-1]:
            if not isinstance(parent, dict) or key not in parent:
                parent = None
                break
            parent = parent[key]
        if isinstance(parent, dict) and path[-1] in parent:
            del parent[path[-1]]
            changed.append({'field': '.'.join(path), 'operation': 'remove-diagnostic'})
    for field in HEADER_FIELDS:
        if field not in result:
            continue
        text = result[field]
        require(isinstance(text, str), 'Native load-command diagnostic must be text')
        lines = text.splitlines(keepends=True)
        if lines and lines[0].strip() != HEADER:
            first = lines[0].rstrip('\r\n')
            # Only the exact native executable diagnostic header is rewritten.
            # A private path in the body/unknown header remains an error.
            if first.endswith('/FloeOfficeNative:') and first.startswith('/'):
                ending = lines[0][len(first):]
                result[field] = HEADER + ending + ''.join(lines[1:])
                changed.append({'field': field, 'operation': 'artifact-relative-header'})
    assert_public_metadata(result)
    # Establish a single bounded transformation, not a recursive redactor that
    # can accidentally change provenance/hash/ABI/capability fields.
    projected = copy.deepcopy(original)
    for item in changed:
        path = item['field'].split('.')
        parent = projected
        for key in path[:-1]:
            parent = parent[key]
        if item['operation'] == 'remove-diagnostic':
            del parent[path[-1]]
        else:
            parent[path[-1]] = result[path[-1]]
    require(projected == result, 'Unexpected non-diagnostic manifest change')
    return result, changed


def _destination(path):
    path = Path(path).absolute()
    require(not path.exists() and not path.is_symlink(), 'Destination already exists; refusing overwrite')
    require(path.parent.is_dir(), 'Destination parent must already exist')
    for parent in (path.parent, *path.parent.parents):
        require(not parent.is_symlink(), 'Destination parent is an alias')
    return path


def derive_public_zip(input_zip, output_zip, receipt, *, packaging_source_commit):
    require(isinstance(packaging_source_commit, str)
            and re.fullmatch('[0-9a-f]{40}', packaging_source_commit) is not None,
            'An exact packaging source commit is required')
    input_zip = Path(input_zip).absolute()
    output_zip, receipt = _destination(output_zip), _destination(receipt)
    require(len({input_zip, output_zip, receipt}) == 3, 'Input/output/receipt must be distinct')
    require(input_zip.is_file() and not input_zip.is_symlink(), 'Private input ZIP must be a regular file')
    require(0 < input_zip.stat().st_size <= transport.MAX_ARCHIVE_BYTES, 'Private input ZIP exceeds transport bound')
    original_archive_hash = sha(input_zip)
    committed = []
    with ExitStack() as stack:
        staging = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='.office-public-', dir=output_zip.parent)))
        receipt_stage = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='.office-receipt-', dir=receipt.parent)))
        # Existing ZIP boundary rejects traversal, duplicates, links, special
        # modes, encryption, unsupported compression and expansion/entry limits.
        folder = transport.safe_extract(input_zip, staging / 'expanded')
        require({p.name for p in folder.iterdir()} ==
                {'FloeOfficeNative.framework', 'OfficeRuntimeResources', 'native-host.json'},
                'Unexpected component root structure')
        require((folder / 'FloeOfficeNative.framework').is_dir()
                and (folder / 'OfficeRuntimeResources').is_dir()
                and (folder / 'native-host.json').is_file(), 'Invalid component root types')
        transport.device_macho(folder / 'FloeOfficeNative.framework/FloeOfficeNative')
        with zipfile.ZipFile(input_zip) as archive:
            infos = archive.infolist()
            names = [entry.filename for entry in infos]
            require(not private_material_failures(names, 'component'), 'Private symbol/signing material refused')
            require(all(not path_failures(name) for name in names), 'Private paths in ZIP member names refused')
            manifest_info = archive.getinfo(MANIFEST)
            require(0 < manifest_info.file_size <= transport.MAX_MANIFEST_BYTES, 'Manifest size outside bound')
            original_manifest = archive.read(MANIFEST)
        require(0 < len(original_manifest) <= transport.MAX_MANIFEST_BYTES, 'Manifest size outside bound')
        original = transport.read_json(folder / 'native-host.json')
        normalized, changed = normalize_manifest(original)
        normalized_bytes = (json.dumps(normalized, ensure_ascii=False, sort_keys=True,
                                       indent=2, allow_nan=False) + '\n').encode('utf-8')
        require(len(normalized_bytes) <= transport.MAX_MANIFEST_BYTES, 'Public manifest exceeds bound')
        (folder / 'native-host.json').write_bytes(normalized_bytes)
        staged_zip = staging / 'public.zip'
        file_hashes = {}
        with zipfile.ZipFile(staged_zip, 'w', compression=zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
            for source_info in sorted(infos, key=lambda item: item.filename):
                info = zipfile.ZipInfo(source_info.filename, (2026, 1, 1, 0, 0, 0))
                info.create_system = 3
                permissions = (source_info.external_attr >> 16) & 0o777
                info.external_attr = ((stat.S_IFDIR if source_info.is_dir() else stat.S_IFREG)
                                      | permissions) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                if source_info.is_dir():
                    archive.writestr(info, b'')
                else:
                    file = staging / 'expanded' / source_info.filename
                    with file.open('rb') as incoming, archive.open(info, 'w', force_zip64=True) as outgoing:
                        digest = hashlib.sha256()
                        for data in iter(lambda: incoming.read(1024 * 1024), b''):
                            outgoing.write(data); digest.update(data)
                    file_hashes[source_info.filename] = digest.hexdigest()
        # Read both actual ZIPs back: exact member set, every non-manifest file
        # unchanged, executable bytes/UUID therefore unchanged. No extraction
        # or metadata assertion substitutes for this byte comparison.
        with zipfile.ZipFile(input_zip) as before, zipfile.ZipFile(staged_zip) as after:
            require(set(before.namelist()) == set(after.namelist()), 'Component member inventory changed')
            for name in file_hashes:
                with before.open(name) as incoming, after.open(name) as outgoing:
                    original_hash, public_hash = hashlib.sha256(), hashlib.sha256()
                    while True:
                        old, new = incoming.read(1024 * 1024), outgoing.read(1024 * 1024)
                        if not old and not new:
                            break
                        original_hash.update(old); public_hash.update(new)
                        if name != MANIFEST:
                            require(old == new, 'A non-manifest component file changed')
                require(public_hash.hexdigest() == file_hashes[name], 'Public ZIP read-back differs')
                if name == MANIFEST:
                    require(original_hash.hexdigest() == hashlib.sha256(original_manifest).hexdigest(),
                            'Private manifest changed during packaging')
        require(sha(input_zip) == original_archive_hash, 'Private input changed during packaging')
        result = {
            'schemaVersion': SCHEMA, 'kind': 'office-public-metadata-packaging',
            'originalArchiveSHA256': original_archive_hash,
            'originalManifestSHA256': hashlib.sha256(original_manifest).hexdigest(),
            'publicArchiveSHA256': sha(staged_zip), 'publicManifestSHA256': file_hashes[MANIFEST],
            'executableSHA256': file_hashes[BINARY],
            'changedFields': changed, 'nonManifestBytesPreserved': True,
            'memberInventoryPreserved': True,
            'packagingSource': {'callerSuppliedCommit': packaging_source_commit,
                'script': HELPER_NAME, 'scriptSHA256': sha(Path(__file__))},
            'qualification': 'packaging-only-existing-transport-pin-bootstrap-validation-required',
        }
        assert_public_metadata(result)
        staged_receipt = receipt_stage / 'receipt.json'
        staged_receipt.write_text(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + '\n')
        zip_identity = staged_zip.stat()
        receipt_identity = staged_receipt.stat()
        try:
            # Atomic no-overwrite commits, even if another task creates a
            # destination after the initial check. Both staging files reside on
            # their respective destination filesystem.
            os.link(staged_zip, output_zip)
            committed.append((output_zip, zip_identity.st_dev, zip_identity.st_ino))
            os.link(staged_receipt, receipt)
            committed.append((receipt, receipt_identity.st_dev, receipt_identity.st_ino))
        except BaseException:
            for path, device, inode in reversed(committed):
                current = path.lstat() if path.exists() or path.is_symlink() else None
                if current is not None and (current.st_dev, current.st_ino) == (device, inode):
                    path.unlink()
            raise
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-zip', type=Path, required=True)
    parser.add_argument('--output-zip', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--packaging-source-commit', required=True,
                        help='Actual packaging checkout commit supplied by root; script hash is independently measured')
    args = parser.parse_args()
    try:
        result = derive_public_zip(args.input_zip, args.output_zip, args.receipt,
                                   packaging_source_commit=args.packaging_source_commit)
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        # Never echo input path values in a public terminal/provenance log.
        print('Public Office packaging refused: ' + type(error).__name__)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
