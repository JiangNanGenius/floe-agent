#!/usr/bin/env python3
"""Durable recovery of the pinned Floe native Office host component.

The qualification pin in ``ThirdParty/Collabora/engine.lock.json`` is the only
trust root.  GitHub Actions artifacts are a short-lived transport: this module
stores the *exact same* qualified archive, its manifest/executable identity and
the Office engine licensing in a separate immutable GitHub Release tagged from
the pinned archive SHA-256::

    office-native-host-<archive sha256>

The release is public and deliberately small.  It must never contain the
qualified dSYM, signing material, local paths, transport contents or an App
IPA.  The matching private dSYM is emitted to a separate private output
directory/artifact for the root to export immediately; only its digest, size
and executable UUID are recorded in the public descriptor.  Metadata is not
evidence that the symbols exist: the producer verifies the *actual* private
archive, and bootstrap never downloads it.

Recovery never treats a successful download as proof.  The release descriptor,
sidecar and archive are compared with the pin/lock, safe extraction is repeated
by the normal bootstrap install path, and the host executable UUID is checked
against the descriptor's private-symbol binding.  When the pin carries an
optional ``componentRelease`` block its recorded descriptor/symbol hashes are
enforced; an older pin without the block derives the same tag deterministically,
so existing pins keep working.

Publication is verified from the canonical GitHub REST JSON (``releases/tags``,
``git/ref/tags``, an annotated ``git/tags`` object and ``releases/latest``),
not from ``gh release view`` fields.  The immutable tag must peel to the actual
producer commit recorded by the descriptor transport, every remote asset must
match the local bytes by sha256/size, and the component must not own the App
latest pointer or appear in ``feather.json``.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import struct
import subprocess
import time
import zipfile

SCHEMA = 'floe-office-component-release/v1'
KIND = 'floe-office-native-host-component'
DEFAULT_REPOSITORY = 'JiangNanGenius/floe-agent'
TAG_PREFIX = 'office-native-host-'

HOST_ASSET = 'OfficeNativeHost.zip'
HOST_SIDECAR = HOST_ASSET + '.sha256'
DESCRIPTOR_ASSET = 'office-component.json'
# The dSYM is a PRIVATE asset name.  It is never part of PUBLIC_ASSETS and must
# never be uploaded to the public component release or any App release/feed.
SYMBOLS_ASSET = 'FloeOfficeNative.framework.dSYM.zip'
LICENSES_ASSET = 'office-component-licenses.zip'
LICENSES_ROOT = 'OfficeEngine'
SYMBOLS_ROOT = 'FloeOfficeNative.framework.dSYM'

PUBLIC_ASSETS = (HOST_ASSET, HOST_SIDECAR, DESCRIPTOR_ASSET, LICENSES_ASSET)
PUBLIC_ASSET_SET = frozenset(PUBLIC_ASSETS)
PUBLIC_AUXILIARY = frozenset({'OFFICE_COMPONENT_RELEASE.md', 'pin-block.json'})
PRIVATE_SYMBOLS_METADATA = 'private-symbols.json'

MAX_DESCRIPTOR_BYTES = 2 * 1024 * 1024
MAX_MANIFEST_BYTES = 32 * 1024 * 1024
MAX_SIDECAR_BYTES = 4096
MAX_ARCHIVE_BYTES = 768 * 1024 * 1024
MAX_SYMBOLS_BYTES = 1024 * 1024 * 1024
MAX_LICENSES_BYTES = 64 * 1024 * 1024
MAX_MACHO_PREFIX = 1024 * 1024
MAX_LOAD_COMMANDS = 1024 * 1024
MAX_ZIP_ENTRIES = 20000

LIFECYCLE_OVERLAYS = (
    ('schemeTaskLifecycleOverlay', 'schemeOverlaySHA256', 'schemeTaskLifecycle'),
    ('forwardingLifecycleOverlay', 'forwardingOverlaySHA256', 'forwardingLifecycle'),
    ('kitCallbackLifecycleOverlay', 'kitCallbackOverlaySHA256', 'kitCallbackLifecycle'),
    ('embeddedLifecycleOverlay', 'embeddedLifecycleOverlaySHA256', 'embeddedLifecycle'),
)

# Names/extensions that can only belong to private symbol or signing material.
# The patterns are intentionally narrow: the real host archive ships many
# `symbolshapes` SVG resources that are not symbols.
_PRIVATE_SUFFIXES = (
    '.dsym.zip', '.symbols.zip', '.symbols.tar', '.symbols.tar.gz',
    '.bcsymbolmap', '.p12', '.mobileprovision', '.provisionprofile',
    '.xcarchive', '.ipa',
)
_PRIVATE_SYMBOLS_NAME = re.compile(
    r'(^|[/._-])symbols?(?:[._-][^/]*)?\.(?:zip|tar|tgz|tar\.gz|json)$', re.I)


class RecoveryCancelled(Exception):
    """The caller cancelled recovery before the staged commit point."""


def digest(path):
    checksum = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(chunk)
    return checksum.hexdigest()


def canonical_digest(value):
    payload = json.dumps(value, sort_keys=True, separators=(',', ':'),
                         ensure_ascii=False).encode('utf-8')
    return hashlib.sha256(payload).hexdigest()


def safe_relative(name):
    path = PurePosixPath(name)
    if (not name or path.is_absolute() or '..' in path.parts or '\\' in name
            or '\x00' in name or str(path) != name.rstrip('/')):
        raise ValueError('Invalid component release path: ' + repr(name))
    return path


def read_bounded(path, limit, label):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'The {label} is missing or is not a regular file')
    size = path.stat().st_size
    if size <= 0 or size > limit:
        raise ValueError(f'The {label} size is outside its accepted bound')
    return path.read_bytes()


def component_tag(archive_sha256):
    if (not isinstance(archive_sha256, str) or len(archive_sha256) != 64
            or any(char not in '0123456789abcdef' for char in archive_sha256)):
        raise ValueError('A component tag requires the pinned archive SHA-256')
    return TAG_PREFIX + archive_sha256


def private_material_failures(names, label):
    """Return every name that looks like private symbol/signing material.

    Used both for the public asset allowlist and for archive members, so a dSYM
    or signing file accidentally nested inside an otherwise public ZIP fails
    before publication or recovery.
    """
    failures = []
    for raw in names:
        name = str(raw)
        lowered = name.lower()
        parts = [part.lower() for part in PurePosixPath(name).parts]
        nested_dwarf = ('/contents/resources/dwarf/' in '/' + lowered
                        or any(part == 'dwarf' for part in parts))
        if (any(part.endswith('.dsym') for part in parts)
                or any(part == '_codesignature' for part in parts)
                or nested_dwarf
                or lowered.endswith(_PRIVATE_SUFFIXES)
                or _PRIVATE_SYMBOLS_NAME.search(lowered)):
            failures.append(f'{label} carries private symbol/signing material: {name}')
    return failures


def assert_public_asset_name(name, label):
    failures = private_material_failures([name], label)
    if failures:
        raise ValueError('; '.join(failures))


def inspect_public_archive(path, label):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'The {label} is missing or is not a regular file')
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
    failures = private_material_failures(names, label)
    if failures:
        raise ValueError('; '.join(failures))
    return len(names)


def required_claims(lock, pin):
    """The exact claim set a descriptor must repeat for this pin.

    Overlay patch hashes are copied directly.  Structured pin blocks are bound
    by canonical JSON digests so the descriptor stays small while still
    covering every byte of the browser, filter, compiled-lifecycle and engine
    repair contracts.
    """
    claims = {'overlaySHA256': pin['overlaySHA256']}
    for _, claim_key, _ in LIFECYCLE_OVERLAYS:
        if claim_key in pin:
            claims[claim_key] = pin[claim_key]
    if 'engineRepair' in pin:
        claims['engineRepairSHA256'] = canonical_digest(pin['engineRepair'])
    if 'browserResources' in pin:
        claims['browserResourcesSHA256'] = canonical_digest(pin['browserResources'])
    if 'filterOverlay' in pin:
        claims['filterOverlaySHA256'] = canonical_digest(pin['filterOverlay'])
    if 'embeddedLifecycleMember' in pin:
        claims['embeddedLifecycleMemberSHA256'] = canonical_digest(
            pin['embeddedLifecycleMember'])
    return claims


def expected_transport(pin):
    storage = pin.get('localStorageArtifact') or {}
    transport = {
        'runID': str(pin.get('runID') or ''),
        'workflowCommit': str(pin.get('workflowCommit') or ''),
        'artifactName': str(pin.get('artifactName') or ''),
        'nativeProducer': (storage.get('nativeProducer') or 'actions-native-build'),
    }
    return transport


def expected_contract(lock, pin, repository=None):
    """Derive the only acceptable component release identity for a pin."""
    block = pin.get('componentRelease')
    if repository is None and isinstance(block, dict):
        repository = block.get('repository')
    repository = repository or DEFAULT_REPOSITORY
    if not isinstance(repository, str) or repository.count('/') != 1:
        raise ValueError('Invalid component release repository')
    archive = pin.get('archiveSHA256')
    tag = component_tag(archive)
    if block is not None:
        if not isinstance(block, dict):
            raise ValueError('The pin component release block is not an object')
        unexpected = set(block) - {'schema', 'repository', 'tag', 'archiveSHA256',
                                   'descriptorSHA256', 'symbolsSHA256'}
        if unexpected:
            raise ValueError('The pin component release block carries unexpected fields: '
                             + ', '.join(sorted(unexpected)))
        if block.get('schema') not in (None, SCHEMA):
            raise ValueError('The pin component release schema is not supported')
        if block.get('repository') not in (None, repository):
            raise ValueError('The pin component release repository differs from the tracked one')
        if block.get('tag') not in (None, tag):
            raise ValueError('The pin component release tag is not derived from the pinned archive')
        if block.get('archiveSHA256') not in (None, archive):
            raise ValueError('The pin component release archive differs from the pinned archive')
        if block.get('descriptorSHA256') is not None:
            value = block['descriptorSHA256']
            if (not isinstance(value, str) or len(value) != 64
                    or any(char not in '0123456789abcdef' for char in value)):
                raise ValueError('The pin component release descriptor hash is malformed')
        if block.get('symbolsSHA256') is not None:
            value = block['symbolsSHA256']
            if (not isinstance(value, str) or len(value) != 64
                    or any(char not in '0123456789abcdef' for char in value)):
                raise ValueError('The pin component release symbols hash is malformed')
    return {
        'schema': SCHEMA,
        'repository': repository,
        'tag': tag,
        'archiveSHA256': archive,
        'sourceCommit': lock['commit'],
        'claims': required_claims(lock, pin),
        'transport': expected_transport(pin),
        'descriptorSHA256': (block or {}).get('descriptorSHA256'),
        # Digest of the PRIVATE dSYM archive.  This never authorizes a public
        # symbols asset; it lets a retained private copy be re-verified.
        'symbolsSHA256': (block or {}).get('symbolsSHA256'),
    }


def _uuid(value):
    if not isinstance(value, str):
        raise ValueError('A Mach-O UUID is missing')
    compact = value.replace('-', '').upper()
    if len(compact) != 32 or any(char not in '0123456789ABCDEF' for char in compact):
        raise ValueError('A Mach-O UUID is malformed')
    return '-'.join((compact[0:8], compact[8:12], compact[12:16],
                     compact[16:20], compact[20:32]))


def _uuid_from_thin(prefix, offset, endian, is_64):
    header_size = 32 if is_64 else 28
    if offset + header_size > len(prefix):
        raise ValueError('A Mach-O header is truncated')
    ncmds, sizeofcmds = struct.unpack_from(endian + 'II', prefix, offset + 16)
    if ncmds == 0 or ncmds > 65535 or sizeofcmds > MAX_LOAD_COMMANDS:
        raise ValueError('A Mach-O load command table is outside its accepted bound')
    position = offset + header_size
    end = min(position + sizeofcmds, len(prefix))
    if end < position + sizeofcmds and sizeofcmds > MAX_MACHO_PREFIX:
        raise ValueError('A Mach-O load command table exceeds the inspected prefix')
    for _ in range(ncmds):
        if position + 8 > end:
            raise ValueError('A Mach-O load command table is truncated')
        command, size = struct.unpack_from(endian + 'II', prefix, position)
        if size < 8 or position + size > end:
            raise ValueError('A Mach-O load command size is invalid')
        if command == 0x1b:
            if size < 24:
                raise ValueError('A Mach-O UUID load command is truncated')
            raw = prefix[position + 8:position + 24]
            return _uuid(raw.hex())
        position += size
    raise ValueError('The Mach-O executable carries no LC_UUID')


def macho_uuid_bytes(payload):
    """Return the LC_UUID of a thin or universal Mach-O prefix."""
    if len(payload) < 8:
        raise ValueError('A Mach-O header is truncated')
    magic = payload[:4]
    if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        count = struct.unpack_from('>I', payload, 4)[0]
        if count == 0 or count > 32:
            raise ValueError('A universal Mach-O architecture count is invalid')
        is_64 = magic == b'\xca\xfe\xba\xbf'
        entry_size = 32 if is_64 else 20
        table_end = 8 + count * entry_size
        if table_end > len(payload):
            raise ValueError('A universal Mach-O architecture table is truncated')
        failures = []
        for index in range(count):
            base = 8 + index * entry_size
            if is_64:
                offset, size = struct.unpack_from('>QQ', payload, base + 8)
            else:
                offset, size = struct.unpack_from('>II', payload, base + 8)
            if size == 0 or offset + size > len(payload):
                failures.append('a universal slice lies outside the inspected prefix')
                continue
            try:
                return _parse_thin(payload, offset)
            except ValueError as failure:
                failures.append(str(failure))
        raise ValueError('No universal Mach-O slice carries a usable LC_UUID: '
                         + '; '.join(failures))
    return _parse_thin(payload, 0)


def _parse_thin(payload, offset):
    magic = payload[offset:offset + 4]
    if magic == b'\xcf\xfa\xed\xfe':
        return _uuid_from_thin(payload, offset, '<', True)
    if magic == b'\xce\xfa\xed\xfe':
        return _uuid_from_thin(payload, offset, '<', False)
    if magic == b'\xfe\xed\xfa\xcf':
        return _uuid_from_thin(payload, offset, '>', True)
    if magic == b'\xfe\xed\xfa\xce':
        return _uuid_from_thin(payload, offset, '>', False)
    raise ValueError('The file is not a Mach-O executable')


def macho_uuid(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError('A Mach-O executable is missing')
    with path.open('rb') as stream:
        payload = stream.read(MAX_MACHO_PREFIX)
    return macho_uuid_bytes(payload)


def _zip_member_prefix(archive, name):
    try:
        info = archive.getinfo(name)
    except KeyError:
        raise ValueError('A required archive member is missing: ' + name)
    if info.file_size <= 0 or info.file_size > MAX_ARCHIVE_BYTES:
        raise ValueError('A required archive member is outside its accepted size')
    with archive.open(info) as stream:
        return stream.read(min(MAX_MACHO_PREFIX, info.file_size))


def host_archive_uuid(archive):
    """Read the host executable LC_UUID without extracting the archive."""
    with zipfile.ZipFile(archive) as source:
        name = 'OfficeNativeHost/FloeOfficeNative.framework/FloeOfficeNative'
        try:
            prefix = _zip_member_prefix(source, name)
        except KeyError:
            raise ValueError('The host archive carries no framework executable')
    return macho_uuid_bytes(prefix)


def inspect_symbol_archive(path):
    """Bind a private dSYM archive to the executable UUID it describes."""
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError('The private dSYM archive is missing or is not a regular file')
    if path.stat().st_size > MAX_SYMBOLS_BYTES:
        raise ValueError('The symbols archive exceeds its accepted size')
    files = 0
    uuid = None
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) > MAX_ZIP_ENTRIES or len(names) != len(set(names)):
            raise ValueError('The symbols archive has too many or duplicate entries')
        roots = set()
        dwarf = []
        for name in names:
            relative = safe_relative(name)
            if relative.parts[0] != SYMBOLS_ROOT:
                raise ValueError('The symbols archive root is not the qualified dSYM')
            roots.add(relative.parts[0])
            if any(part.startswith('.') for part in relative.parts):
                raise ValueError('The symbols archive contains a hidden entry')
            info = archive.getinfo(name)
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode) or stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError('The symbols archive contains an alias or special file')
            if not info.is_dir():
                files += 1
            if relative.as_posix().endswith('/Contents/Resources/DWARF/FloeOfficeNative'):
                dwarf.append(name)
        if roots != {SYMBOLS_ROOT}:
            raise ValueError('The symbols archive must contain one qualified dSYM root')
        if len(dwarf) != 1:
            raise ValueError('The symbols archive must contain exactly one DWARF executable')
        uuid = macho_uuid_bytes(_zip_member_prefix(archive, dwarf[0]))
    if files == 0:
        raise ValueError('The symbols archive is empty')
    return {
        'asset': SYMBOLS_ASSET,
        'sha256': digest(path),
        'bytes': path.stat().st_size,
        'executableUUID': uuid,
        'files': files,
        'visibility': 'private',
    }


def inspect_license_archive(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError('The licensing archive is missing or is not a regular file')
    if path.stat().st_size > MAX_LICENSES_BYTES:
        raise ValueError('The licensing archive exceeds its accepted size')
    files = {}
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) > MAX_ZIP_ENTRIES or len(names) != len(set(names)):
            raise ValueError('The licensing archive has too many or duplicate entries')
        for name in names:
            relative = safe_relative(name)
            if relative.parts[0] != LICENSES_ROOT:
                raise ValueError('The licensing archive root is not the Office engine directory')
            info = archive.getinfo(name)
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode) or stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError('The licensing archive contains an alias or special file')
            if info.is_dir():
                continue
            if info.file_size > MAX_LICENSES_BYTES:
                raise ValueError('A licensing file exceeds its accepted size')
            relative_name = PurePosixPath(*relative.parts[1:]).as_posix()
            files[relative_name] = hashlib.sha256(archive.read(info)).hexdigest()
    for required in ('LICENSE', 'COPYING.MPL', 'NOTICE'):
        if required not in files:
            raise ValueError('The licensing archive omits ' + required)
    if not files:
        raise ValueError('The licensing archive is empty')
    return {
        'asset': LICENSES_ASSET,
        'sha256': digest(path),
        'bytes': path.stat().st_size,
        'root': LICENSES_ROOT,
        'files': dict(sorted(files.items())),
    }


def write_deterministic_zip(source, destination, root):
    """Package a directory byte-deterministically for a private or public asset."""
    safe_relative(root)
    if '/' in root:
        raise ValueError('A component asset root must be one directory name')
    source = Path(source)
    if source.is_symlink() or not source.is_dir():
        raise ValueError('A component asset source is not an owned directory')
    destination = Path(destination)
    if destination.resolve().is_relative_to(source.resolve()):
        raise ValueError('A component asset cannot be written inside its source')
    entries = []
    total = 0
    for path in sorted(source.rglob('*')):
        if path.is_symlink():
            raise ValueError('A component asset source contains an alias')
        relative = path.relative_to(source)
        if any(part.startswith('.') for part in relative.parts):
            raise ValueError('A component asset source contains a hidden entry')
        info = stat.S_IMODE(path.lstat().st_mode)
        if path.is_file():
            total += path.stat().st_size
            if total > MAX_SYMBOLS_BYTES:
                raise ValueError('A component asset source exceeds its accepted size')
            if len(entries) >= MAX_ZIP_ENTRIES:
                raise ValueError('A component asset source has too many entries')
            entries.append((relative, path, False))
        elif path.is_dir():
            entries.append((relative, path, True))
        else:
            raise ValueError('A component asset source contains a special file')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, 'w') as archive:
        for relative, path, is_directory in entries:
            name = PurePosixPath(root, *relative.parts).as_posix()
            if is_directory:
                name += '/'
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 3
            info.external_attr = ((0o40755 if is_directory else 0o100644) << 16)
            if is_directory:
                archive.writestr(info, b'')
            else:
                with path.open('rb') as source_stream, archive.open(info, 'w') as target:
                    shutil.copyfileobj(source_stream, target, 1024 * 1024)
    return destination


def build_descriptor(lock, manifest, hashes, archive, *, repository=DEFAULT_REPOSITORY,
                     claims=None, transport=None, symbols=None, symbols_archive=None,
                     licenses=None):
    """Create the canonical public release descriptor for one qualified archive.

    ``claims``/``transport`` are supplied by the producer after it has verified
    the artifact against the tracked source contract.  The archive, manifest and
    executable hashes are always recomputed from the actual bytes.  The private
    dSYM identity is likewise computed from the *actual* private archive: a
    caller cannot claim symbol possession with metadata alone.
    """
    archive = Path(archive)
    archive_sha = digest(archive)
    tag = component_tag(archive_sha)
    if hashes['manifestSHA256'] != digest_of_manifest(archive):
        raise ValueError('The artifact manifest does not match its archive')
    if hashes['executableSHA256'] != digest_of_executable(archive):
        raise ValueError('The artifact executable does not match its archive')
    uuid = host_archive_uuid(archive)
    if symbols_archive is None:
        raise ValueError('A component release requires the actual qualified private dSYM '
                         'archive, not only its metadata')
    inspected = inspect_symbol_archive(symbols_archive)
    if not isinstance(symbols, dict):
        raise ValueError('A component release requires its private dSYM identity')
    for key in ('asset', 'sha256', 'bytes', 'executableUUID', 'files'):
        if symbols.get(key) != inspected.get(key):
            raise ValueError('The private dSYM metadata does not match the actual archive: ' + key)
    if inspected['executableUUID'] != uuid:
        raise ValueError('The dSYM executable UUID differs from the host executable')
    symbols_block = dict(inspected)
    symbols_block['visibility'] = 'private'
    if not isinstance(licenses, dict):
        raise ValueError('A component release requires its Office licensing identity')
    if not isinstance(claims, dict) or 'overlaySHA256' not in claims:
        raise ValueError('A component release requires its source claim set')
    if not isinstance(transport, dict) or not transport.get('runID'):
        raise ValueError('A component release requires a real transport identity')
    descriptor = {
        'schema': SCHEMA,
        'kind': KIND,
        'repository': repository,
        'tag': tag,
        'sourceCommit': lock['commit'],
        'platform': f"{manifest.get('sdk', 'iphoneos')}-{manifest.get('arch', 'arm64')}",
        'archive': {'name': HOST_ASSET, 'sha256': archive_sha,
                    'bytes': archive.stat().st_size},
        'manifest': {
            'name': 'native-host.json',
            'sha256': hashes['manifestSHA256'],
            'executableSHA256': hashes['executableSHA256'],
            'hostSourceSHA256': dict(manifest['hostSourceSHA256']),
        },
        'claims': claims,
        'transport': transport,
        'symbols': symbols_block,
        'licenses': licenses,
    }
    return descriptor


def digest_of_manifest(archive):
    with zipfile.ZipFile(archive) as source:
        names = [name for name in source.namelist()
                 if name.endswith('/native-host.json') and name.count('/') == 1]
        if len(names) != 1:
            raise ValueError('The host archive must carry exactly one native-host.json')
        info = source.getinfo(names[0])
        if info.file_size <= 0 or info.file_size > MAX_MANIFEST_BYTES:
            raise ValueError('The host manifest size is outside its accepted bound')
        checksum = hashlib.sha256()
        with source.open(info) as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                checksum.update(chunk)
        return checksum.hexdigest()


def digest_of_executable(archive):
    with zipfile.ZipFile(archive) as source:
        name = 'OfficeNativeHost/FloeOfficeNative.framework/FloeOfficeNative'
        try:
            info = source.getinfo(name)
        except KeyError:
            raise ValueError('The host archive carries no framework executable')
        checksum = hashlib.sha256()
        with source.open(info) as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                checksum.update(chunk)
        return checksum.hexdigest()


def descriptor_failures(descriptor, lock, pin, *, descriptor_sha256=None,
                        require_symbols=True, require_licenses=True):
    """Every reason a public release descriptor cannot represent this pin."""
    failures = []
    expected = expected_contract(lock, pin)
    if not isinstance(descriptor, dict):
        return ['the component descriptor is not an object']
    for key, value in (('schema', SCHEMA), ('kind', KIND)):
        if descriptor.get(key) != value:
            failures.append(f'the component descriptor {key} is not {value}')
    if descriptor.get('repository') != expected['repository']:
        failures.append('the component descriptor repository differs from the tracked repository')
    if descriptor.get('tag') != expected['tag']:
        failures.append('the component descriptor tag is not derived from the pinned archive')
    if descriptor.get('sourceCommit') != expected['sourceCommit']:
        failures.append('the component descriptor source commit differs from the engine lock')
    if descriptor.get('platform') not in ('iphoneos-arm64',):
        failures.append('the component descriptor platform is not the qualified device platform')
    archive = descriptor.get('archive')
    if not isinstance(archive, dict):
        failures.append('the component descriptor carries no archive identity')
    else:
        if archive.get('name') != HOST_ASSET:
            failures.append('the component descriptor names a different host archive')
        if archive.get('sha256') != expected['archiveSHA256']:
            failures.append('the component descriptor archive hash differs from the pin')
        if not isinstance(archive.get('bytes'), int) or archive.get('bytes', 0) <= 0:
            failures.append('the component descriptor archive size is invalid')
    manifest = descriptor.get('manifest')
    if not isinstance(manifest, dict):
        failures.append('the component descriptor carries no manifest identity')
    else:
        if manifest.get('name') != 'native-host.json':
            failures.append('the component descriptor names a different manifest')
        if manifest.get('sha256') != pin.get('manifestSHA256'):
            failures.append('the component descriptor manifest hash differs from the pin')
        if manifest.get('executableSHA256') != pin.get('executableSHA256'):
            failures.append('the component descriptor executable hash differs from the pin')
        if manifest.get('hostSourceSHA256') != pin.get('hostSourceSHA256'):
            failures.append('the component descriptor host sources differ from the pin')
    if descriptor.get('claims') != expected['claims']:
        failures.append('the component descriptor source claims differ from the pin contract')
    if descriptor.get('transport') != expected['transport']:
        failures.append('the component descriptor transport identity differs from the pin')
    if require_symbols:
        symbols = descriptor.get('symbols')
        if not isinstance(symbols, dict):
            failures.append('the component descriptor carries no private dSYM identity')
        else:
            if symbols.get('asset') != SYMBOLS_ASSET:
                failures.append('the component descriptor names a different private dSYM asset')
            if symbols.get('visibility') != 'private':
                failures.append('the component descriptor dSYM is not marked as private')
            if not isinstance(symbols.get('sha256'), str) or len(symbols['sha256']) != 64:
                failures.append('the component descriptor dSYM hash is malformed')
            elif expected['symbolsSHA256'] and symbols['sha256'] != expected['symbolsSHA256']:
                failures.append('the component descriptor dSYM hash differs from the pin')
            if not isinstance(symbols.get('bytes'), int) or symbols.get('bytes', 0) <= 0:
                failures.append('the component descriptor dSYM size is invalid')
            if not isinstance(symbols.get('files'), int) or symbols.get('files', 0) <= 0:
                failures.append('the component descriptor dSYM file count is invalid')
            try:
                _uuid(symbols.get('executableUUID'))
            except ValueError as failure:
                failures.append(str(failure))
    if require_licenses:
        licenses = descriptor.get('licenses')
        if not isinstance(licenses, dict):
            failures.append('the component descriptor carries no Office licensing identity')
        else:
            if licenses.get('asset') != LICENSES_ASSET:
                failures.append('the component descriptor names a different licensing asset')
            if not isinstance(licenses.get('sha256'), str) or len(licenses['sha256']) != 64:
                failures.append('the component descriptor licensing hash is malformed')
            if not isinstance(licenses.get('bytes'), int) or licenses.get('bytes', 0) <= 0:
                failures.append('the component descriptor licensing size is invalid')
            if licenses.get('root') != LICENSES_ROOT:
                failures.append('the component descriptor licensing root is not the Office engine set')
            files = licenses.get('files')
            if not isinstance(files, dict) or not files:
                failures.append('the component descriptor licensing file map is empty')
            else:
                for name, checksum in files.items():
                    try:
                        safe_relative(name)
                    except ValueError:
                        failures.append('the component descriptor licensing path is invalid')
                        break
                    if (not isinstance(checksum, str) or len(checksum) != 64
                            or any(char not in '0123456789abcdef' for char in checksum)):
                        failures.append('the component descriptor licensing file hash is malformed')
                        break
    if expected['descriptorSHA256'] and descriptor_sha256 != expected['descriptorSHA256']:
        failures.append('the component descriptor hash differs from the pin')
    return failures


def _inventory(directory, expected):
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('The component release directory is not owned')
    entries = list(directory.iterdir())
    if any(path.is_symlink() or not path.is_file() for path in entries):
        raise ValueError('The component release directory contains an alias or directory')
    names = {path.name for path in entries}
    if names != set(expected):
        raise ValueError('The component release asset set differs from its contract: '
                         + ', '.join(sorted(names ^ set(expected))))
    for name in names:
        assert_public_asset_name(name, 'the component release')
    return {name: directory / name for name in expected}


def _parse_sidecar(path):
    payload = read_bounded(path, MAX_SIDECAR_BYTES, 'component checksum sidecar')
    try:
        text = payload.decode('ascii')
    except UnicodeDecodeError:
        raise ValueError('The component checksum sidecar is not ASCII')
    if not text.endswith('\n') or text.count('\n') != 1:
        raise ValueError('The component checksum sidecar must contain one line')
    parts = text[:-1].split('  ')
    if len(parts) != 2 or parts[1] != HOST_ASSET:
        raise ValueError('The component checksum sidecar must name the host archive')
    return parts[0]


def verify_private_symbols(private_symbols, descriptor, *, host_archive=None):
    """Verify the ACTUAL private dSYM archive against the public metadata.

    Public metadata alone can never satisfy this: the bytes must exist at an
    explicit trusted private path, match the recorded digest/size, describe the
    same executable UUID and (when available) the same host archive.
    """
    private = Path(private_symbols)
    if private.is_symlink() or not private.is_file():
        raise ValueError(
            'The actual qualified private dSYM archive is missing at the explicit '
            'private path; metadata alone is not evidence of symbol qualification')
    symbols = descriptor.get('symbols') if isinstance(descriptor, dict) else None
    if not isinstance(symbols, dict):
        raise ValueError('The component descriptor carries no private dSYM identity')
    if symbols.get('asset') != SYMBOLS_ASSET:
        raise ValueError('The component descriptor names a different private dSYM asset')
    if symbols.get('visibility') != 'private':
        raise ValueError('The component descriptor dSYM is not marked private')
    if private.stat().st_size != symbols.get('bytes'):
        raise ValueError('The private dSYM archive size differs from the descriptor')
    if digest(private) != symbols.get('sha256'):
        raise ValueError('The private dSYM archive digest differs from the descriptor')
    inspected = inspect_symbol_archive(private)
    expected_uuid = _uuid(symbols.get('executableUUID'))
    if inspected['executableUUID'] != expected_uuid:
        raise ValueError('The private dSYM archive UUID differs from the descriptor binding')
    if inspected['files'] != symbols.get('files'):
        raise ValueError('The private dSYM archive file count differs from the descriptor')
    if host_archive is not None and host_archive_uuid(host_archive) != expected_uuid:
        raise ValueError('The private dSYM does not belong to the host executable')
    return inspected


def verify_component_directory(directory, lock, pin, *, repository=None,
                               private_symbols=None):
    """Verify a downloaded PUBLIC release set against the tracked pin.

    The public set carries no dSYM.  When a trusted private symbols archive is
    supplied it is verified byte-for-byte; otherwise the summary explicitly
    reports that symbols were not verified.
    """
    contract = expected_contract(lock, pin, repository=repository)
    files = _inventory(directory, PUBLIC_ASSET_SET)
    descriptor_bytes = read_bounded(files[DESCRIPTOR_ASSET], MAX_DESCRIPTOR_BYTES,
                                    'component descriptor')
    try:
        descriptor = json.loads(descriptor_bytes)
    except json.JSONDecodeError:
        raise ValueError('The component descriptor is not valid JSON')
    failures = descriptor_failures(
        descriptor, lock, pin, descriptor_sha256=hashlib.sha256(descriptor_bytes).hexdigest(),
        require_symbols=True, require_licenses=True)
    if failures:
        raise ValueError('The component release identity does not match the pin: '
                         + '; '.join(failures))
    archive = files[HOST_ASSET]
    if archive.stat().st_size != descriptor['archive']['bytes']:
        raise ValueError('The component archive size differs from its descriptor')
    if digest(archive) != contract['archiveSHA256']:
        raise ValueError('The component archive checksum differs from the pin')
    if _parse_sidecar(files[HOST_SIDECAR]) != contract['archiveSHA256']:
        raise ValueError('The component checksum sidecar differs from the pin')
    inspect_public_archive(archive, 'the component host archive')
    symbols = descriptor.get('symbols')
    if not isinstance(symbols, dict):
        raise ValueError('The component descriptor carries no private dSYM identity')
    if host_archive_uuid(archive) != _uuid(symbols['executableUUID']):
        raise ValueError('The component host executable UUID differs from its dSYM binding')
    licenses_block = descriptor.get('licenses')
    if not isinstance(licenses_block, dict):
        licenses_block = {}
    summary = {
        'tag': contract['tag'],
        'repository': contract['repository'],
        'archiveSHA256': contract['archiveSHA256'],
        'manifestSHA256': pin['manifestSHA256'],
        'executableUUID': _uuid(symbols['executableUUID']),
        'symbolsSHA256': symbols['sha256'],
        'symbolsBytes': symbols['bytes'],
        'symbolsVisibility': symbols.get('visibility'),
        'symbolsVerified': False,
        'licensesSHA256': licenses_block.get('sha256'),
        'verifiedFiles': len(files),
        'publicAssets': sorted(files),
    }
    if digest(files[LICENSES_ASSET]) != licenses_block['sha256']:
        raise ValueError('The component licensing archive checksum differs from its descriptor')
    inspected = inspect_license_archive(files[LICENSES_ASSET])
    if inspected['files'] != licenses_block['files']:
        raise ValueError('The component licensing files differ from their descriptor')
    summary['licenseFiles'] = len(inspected['files'])
    if private_symbols is not None:
        symbols_inspected = verify_private_symbols(private_symbols, descriptor,
                                                   host_archive=archive)
        summary['symbolsVerified'] = True
        summary['symbolsFiles'] = symbols_inspected['files']
    return summary


def verify_self_contained(directory, *, private_symbols=None, lock=None, pin=None,
                          repository=None, require_private_symbols=True):
    """Producer-side verification of a staged PUBLIC release set.

    The host archive must already be present in ``directory`` (the publication
    job assembles it beside the metadata).  Auxiliary notes/pin-block files are
    allowed but never uploaded.  Qualification always requires the actual
    private dSYM archive at an explicit path outside this directory.
    """
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError('The component release directory is not owned')
    entries = list(directory.iterdir())
    if any(path.is_symlink() or not path.is_file() for path in entries):
        raise ValueError('The component release directory contains an alias or directory')
    actual = {path.name for path in entries}
    unexpected = actual - PUBLIC_ASSET_SET - PUBLIC_AUXILIARY
    if unexpected:
        private_hits = private_material_failures(unexpected, 'the public component release')
        if private_hits:
            raise ValueError('; '.join(private_hits) + '; private symbols/signing material must '
                             'be stored as a separate private artifact, never a release asset')
        raise ValueError('The component release asset set is incomplete: '
                         + ', '.join(sorted(unexpected)))
    missing = PUBLIC_ASSET_SET - actual
    if missing:
        raise ValueError('The component release asset set is incomplete: '
                         + ', '.join(sorted(missing)))
    for name in PUBLIC_ASSET_SET:
        assert_public_asset_name(name, 'the public component release')
    descriptor_bytes = read_bounded(directory / DESCRIPTOR_ASSET, MAX_DESCRIPTOR_BYTES,
                                    'component descriptor')
    try:
        descriptor = json.loads(descriptor_bytes)
    except json.JSONDecodeError:
        raise ValueError('The component descriptor is not valid JSON')
    if descriptor.get('schema') != SCHEMA or descriptor.get('kind') != KIND:
        raise ValueError('The component descriptor schema is not supported')
    for block in ('archive', 'manifest', 'symbols', 'licenses'):
        if not isinstance(descriptor.get(block), dict):
            raise ValueError('The component descriptor carries no ' + block + ' identity')
    if lock is not None and pin is not None:
        failures = descriptor_failures(
            descriptor, lock, pin,
            descriptor_sha256=hashlib.sha256(descriptor_bytes).hexdigest(),
            require_symbols=True, require_licenses=True)
        if failures:
            raise ValueError('The component release identity does not match the pin: '
                             + '; '.join(failures))
    archive = directory / HOST_ASSET
    inspect_public_archive(archive, 'the component host archive')
    if archive.stat().st_size != descriptor['archive']['bytes']:
        raise ValueError('The component archive size differs from its descriptor')
    if digest(archive) != descriptor['archive']['sha256']:
        raise ValueError('The component archive hash differs from its descriptor')
    if descriptor['tag'] != component_tag(descriptor['archive']['sha256']):
        raise ValueError('The component tag is not derived from its archive hash')
    if _parse_sidecar(directory / HOST_SIDECAR) != descriptor['archive']['sha256']:
        raise ValueError('The component checksum sidecar differs from its archive')
    if digest_of_manifest(archive) != descriptor['manifest']['sha256']:
        raise ValueError('The component manifest hash differs from its descriptor')
    if digest_of_executable(archive) != descriptor['manifest']['executableSHA256']:
        raise ValueError('The component executable hash differs from its descriptor')
    uuid = host_archive_uuid(archive)
    if uuid != _uuid(descriptor['symbols']['executableUUID']):
        raise ValueError('The component executable UUID differs from its dSYM binding')
    licenses_block = descriptor.get('licenses')
    if digest(directory / LICENSES_ASSET) != licenses_block['sha256']:
        raise ValueError('The component licensing hash differs from its descriptor')
    licenses = inspect_license_archive(directory / LICENSES_ASSET)
    if licenses['files'] != licenses_block['files']:
        raise ValueError('The component licensing files differ from their descriptor')
    symbols_verified = False
    symbols_files = None
    if private_symbols is None:
        if require_private_symbols:
            raise ValueError(
                'The actual qualified private dSYM archive is required for component '
                'qualification and was not supplied; metadata alone is not evidence and '
                'no symbols qualification may be claimed')
    else:
        inspected = verify_private_symbols(private_symbols, descriptor, host_archive=archive)
        symbols_verified = True
        symbols_files = inspected['files']
    return {
        'tag': descriptor['tag'],
        'archiveSHA256': descriptor['archive']['sha256'],
        'executableUUID': uuid,
        'symbolsSHA256': descriptor['symbols']['sha256'],
        'symbolsBytes': descriptor['symbols']['bytes'],
        'symbolsVisibility': descriptor['symbols'].get('visibility'),
        'symbolsVerified': symbols_verified,
        'symbolsFiles': symbols_files,
        'licensesSHA256': descriptor['licenses']['sha256'],
        'publicAssets': sorted(PUBLIC_ASSET_SET),
        'assets': sorted(actual),
    }


def _download(repository, tag, asset, output, *, runner, timeout, attempts, sleep,
              cancel_check, max_bytes):
    output = Path(output)
    failures = []
    for attempt in range(attempts):
        if cancel_check:
            cancel_check()
        try:
            runner(['gh', 'release', 'download', tag, '--repo', repository,
                    '--pattern', asset, '--output', str(output), '--clobber'],
                   check=True, timeout=timeout)
            if not output.is_file() or output.stat().st_size <= 0:
                raise ValueError(f'the component release did not provide {asset}')
            if output.stat().st_size > max_bytes:
                output.unlink(missing_ok=True)
                raise ValueError(f'the component release asset {asset} exceeds its accepted size')
            return output
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as failure:
            output.unlink(missing_ok=True)
            failures.append(f'{asset}: {failure}')
            if attempt + 1 < attempts:
                sleep(min(5 * (attempt + 1), 15))
    raise ValueError('component release download failed: ' + '; '.join(failures))


def recover_into(directory, lock, pin, *, repository=None, runner=subprocess.run,
                 cancel_check=None, attempts=2, timeout=1800, sleep=time.sleep):
    """Download and verify the exact pinned PUBLIC component into staging.

    The descriptor, checksum sidecar, exact host archive and the public
    licensing archive are fetched and verified.  The private dSYM is never
    downloaded or required at build time: the host executable UUID is checked
    against the descriptor's recorded private-symbol binding, and the returned
    transport summary explicitly reports that the actual private symbols were
    not verified here.  Nothing is installed here; the caller commits the
    verified archive through the normal bootstrap path.
    """
    contract = expected_contract(lock, pin, repository=repository)
    directory = Path(directory)
    if directory.is_symlink():
        raise ValueError('The component staging directory is aliased')
    directory.mkdir(parents=True, exist_ok=True)
    if not directory.is_dir():
        raise ValueError('The component staging directory is not a directory')
    produced = []
    try:
        descriptor_path = directory / DESCRIPTOR_ASSET
        _download(contract['repository'], contract['tag'], DESCRIPTOR_ASSET,
                  descriptor_path, runner=runner, timeout=timeout,
                  attempts=attempts, sleep=sleep, cancel_check=cancel_check,
                  max_bytes=MAX_DESCRIPTOR_BYTES)
        produced.append(descriptor_path)
        descriptor_bytes = read_bounded(descriptor_path, MAX_DESCRIPTOR_BYTES,
                                        'component descriptor')
        try:
            descriptor = json.loads(descriptor_bytes)
        except json.JSONDecodeError:
            raise ValueError('The component descriptor is not valid JSON')
        failures = descriptor_failures(
            descriptor, lock, pin, descriptor_sha256=hashlib.sha256(descriptor_bytes).hexdigest(),
            require_symbols=True, require_licenses=True)
        if failures:
            raise ValueError('The component release identity does not match the pin: '
                             + '; '.join(failures))
        if descriptor['archive']['sha256'] != contract['archiveSHA256']:
            raise ValueError('The component release names a different archive')
        if cancel_check:
            cancel_check()
        sidecar_path = directory / HOST_SIDECAR
        _download(contract['repository'], contract['tag'], HOST_SIDECAR,
                  sidecar_path, runner=runner, timeout=timeout,
                  attempts=attempts, sleep=sleep, cancel_check=cancel_check,
                  max_bytes=MAX_SIDECAR_BYTES)
        produced.append(sidecar_path)
        if _parse_sidecar(sidecar_path) != contract['archiveSHA256']:
            raise ValueError('The component checksum sidecar differs from the pin')
        if cancel_check:
            cancel_check()
        archive_path = directory / HOST_ASSET
        _download(contract['repository'], contract['tag'], HOST_ASSET,
                  archive_path, runner=runner, timeout=timeout,
                  attempts=attempts, sleep=sleep, cancel_check=cancel_check,
                  max_bytes=MAX_ARCHIVE_BYTES)
        produced.append(archive_path)
        if archive_path.stat().st_size > MAX_ARCHIVE_BYTES:
            raise ValueError('The component archive exceeds its accepted size')
        if archive_path.stat().st_size != descriptor['archive']['bytes']:
            raise ValueError('The component archive size differs from its descriptor')
        if digest(archive_path) != contract['archiveSHA256']:
            raise ValueError('The component archive checksum differs from the pin')
        if host_archive_uuid(archive_path) != _uuid(descriptor['symbols']['executableUUID']):
            raise ValueError('The component host executable UUID differs from its dSYM binding')
        if cancel_check:
            cancel_check()
        # The licensing asset is public and small.  Bootstrap verifies it too,
        # so a public component release is proven complete and legal without
        # ever downloading the private dSYM bytes.
        licenses_path = directory / LICENSES_ASSET
        _download(contract['repository'], contract['tag'], LICENSES_ASSET,
                  licenses_path, runner=runner, timeout=timeout,
                  attempts=attempts, sleep=sleep, cancel_check=cancel_check,
                  max_bytes=MAX_LICENSES_BYTES)
        produced.append(licenses_path)
        if licenses_path.stat().st_size <= 0 or licenses_path.stat().st_size > MAX_LICENSES_BYTES:
            raise ValueError('The component licensing archive size is invalid')
        if digest(licenses_path) != descriptor['licenses']['sha256']:
            raise ValueError('The component licensing archive checksum differs from its descriptor')
        inspected_licenses = inspect_license_archive(licenses_path)
        if inspected_licenses['files'] != descriptor['licenses']['files']:
            raise ValueError('The component licensing files differ from their descriptor')
        if cancel_check:
            cancel_check()
    except RecoveryCancelled:
        for path in produced:
            Path(path).unlink(missing_ok=True)
        raise
    except BaseException:
        for path in produced:
            Path(path).unlink(missing_ok=True)
        raise
    symbols_metadata = {
        'asset': descriptor['symbols']['asset'],
        'sha256': descriptor['symbols']['sha256'],
        'bytes': descriptor['symbols']['bytes'],
        'executableUUID': _uuid(descriptor['symbols']['executableUUID']),
        'visibility': descriptor['symbols']['visibility'],
        'verified': False,
    }
    return archive_path, {
        'kind': 'component-release',
        'tag': contract['tag'],
        'repository': contract['repository'],
        'archiveSHA256': contract['archiveSHA256'],
        'executableUUID': symbols_metadata['executableUUID'],
        'symbolsSHA256': symbols_metadata['sha256'],
        'symbolsMetadata': symbols_metadata,
        'symbolsVisibility': 'private',
        'symbolsVerified': False,
        'licensesSHA256': descriptor['licenses']['sha256'],
    }


def peel_tag_commit(tag_ref, tag_object, expected_tag):
    """Return (commit, style) bound by the actual Git tag objects.

    The ref name, ref object SHA, annotated tag object SHA/name and peeled
    commit must agree, so an unrelated tag object can never substitute the
    expected producer source.
    """
    if not isinstance(tag_ref, dict):
        raise ValueError('The tag ref read-back is not an object')
    if tag_ref.get('ref') != f'refs/tags/{expected_tag}':
        raise ValueError(f"The tag ref names {tag_ref.get('ref')!r}, expected "
                         f"'refs/tags/{expected_tag}'")
    reference = tag_ref.get('object')
    sha_pattern = re.compile(r'^[0-9a-f]{40}$')
    if (not isinstance(reference, dict) or reference.get('type') not in ('tag', 'commit')
            or not sha_pattern.fullmatch(str(reference.get('sha') or ''))):
        raise ValueError('The tag ref has no usable object {type, sha}')
    if reference['type'] == 'commit':
        return reference['sha'], 'lightweight'
    if not isinstance(tag_object, dict):
        raise ValueError('The annotated tag read-back is missing')
    if tag_object.get('sha') != reference['sha']:
        raise ValueError('The tag object is not the ref object')
    if tag_object.get('tag') != expected_tag:
        raise ValueError('The tag object names a different tag')
    inner = tag_object.get('object')
    if (not isinstance(inner, dict) or inner.get('type') != 'commit'
            or not sha_pattern.fullmatch(str(inner.get('sha') or ''))):
        raise ValueError('The annotated tag does not peel to a commit')
    return inner['sha'], 'annotated'


def feed_failures(feed, tag):
    """Reasons the component tag appears in the App/Feather feed."""
    if not isinstance(feed, dict):
        raise ValueError('The Feather feed read-back is not an object')
    serialized = json.dumps(feed, sort_keys=True, ensure_ascii=False)
    failures = []
    if tag in serialized:
        failures.append(f'the component tag {tag} appears in the Feather feed')
    if TAG_PREFIX in serialized:
        failures.append('a component release tag prefix appears in the Feather feed')
    if f'/releases/download/{tag}/' in serialized:
        failures.append('a feed download URL points at the component release')
    return failures


def verify_publication(release, tag_ref, tag_object, latest, *, expected_tag,
                       expected_source_commit, release_dir, lock_path,
                       feed=None, private_symbols=None):
    """Verify the canonical GitHub API read-back of a component publication.

    ``expected_source_commit`` is the ACTUAL producer source recorded by the
    descriptor transport (not the pinned upstream engine commit).  The tag ref
    must peel to it.  Remote assets must match the local public bytes exactly.
    """
    if not isinstance(release, dict):
        raise ValueError('The release read-back is not an object')
    if release.get('tag_name') != expected_tag:
        raise ValueError('The release read-back names a different tag')
    if release.get('draft') is not False:
        raise ValueError('The component release is still a draft')
    if release.get('prerelease') is not False:
        raise ValueError('The component release must be stable, never a prerelease')
    if not release.get('published_at'):
        raise ValueError('The component release has no published_at timestamp')
    if not isinstance(release.get('id'), int) or release['id'] <= 0:
        raise ValueError('The release read-back has no numeric release id')
    source_commit, tag_style = peel_tag_commit(tag_ref, tag_object, expected_tag)
    if source_commit != expected_source_commit:
        raise ValueError(f'The immutable tag peels to {source_commit}, not the actual '
                         f'producer source {expected_source_commit}')
    lock = json.loads(Path(lock_path).read_text())
    pin = lock['qualifiedHostArtifact']
    summary = verify_self_contained(
        release_dir, private_symbols=private_symbols, lock=lock, pin=pin,
        require_private_symbols=True)
    descriptor_bytes = read_bounded(Path(release_dir) / DESCRIPTOR_ASSET,
                                    MAX_DESCRIPTOR_BYTES, 'component descriptor')
    descriptor = json.loads(descriptor_bytes)
    transport = descriptor.get('transport') if isinstance(descriptor.get('transport'), dict) else {}
    if transport.get('workflowCommit') != expected_source_commit:
        raise ValueError('The component descriptor transport does not name the actual '
                         'producer source; refusing to bind the tag to a different build')
    assets = release.get('assets')
    if not isinstance(assets, list):
        raise ValueError('The release read-back carries no asset list')
    index = {}
    for asset in assets:
        if not isinstance(asset, dict) or not isinstance(asset.get('name'), str):
            raise ValueError('The release read-back carries a malformed asset')
        index.setdefault(asset['name'], []).append(asset)
    unexpected = set(index) - PUBLIC_ASSET_SET
    if unexpected:
        private_hits = private_material_failures(unexpected, 'the published component release')
        if private_hits:
            raise ValueError('; '.join(private_hits) + '; the qualified dSYM/signing material '
                             'must remain a separate private artifact, never a release asset')
        raise ValueError('The published component asset set differs from its contract: '
                         + ', '.join(sorted(unexpected)))
    failures = []
    for name in PUBLIC_ASSETS:
        matches = index.get(name, [])
        if len(matches) != 1:
            failures.append(f'expected exactly one {name!r} asset')
            continue
        asset = matches[0]
        if asset.get('state') != 'uploaded':
            failures.append(f'asset {name!r} is not uploaded (state {asset.get("state")!r})')
        if not isinstance(asset.get('size'), int) or asset['size'] <= 0:
            failures.append(f'asset {name!r} has no real size')
            continue
        remote_digest = asset.get('digest')
        if (not isinstance(remote_digest, str) or not remote_digest.startswith('sha256:')
                or len(remote_digest) != 71):
            failures.append(f'asset {name!r} carries no sha256 digest')
            continue
        local = Path(release_dir) / name
        local_bytes = local.read_bytes()
        local_digest = hashlib.sha256(local_bytes).hexdigest()
        if asset['size'] != len(local_bytes):
            failures.append(f'published {name!r} size differs from the local bytes')
        if remote_digest != 'sha256:' + local_digest:
            failures.append(f'published {name!r} digest differs from the local bytes')
    if failures:
        raise ValueError('The published component release does not match its local '
                         'contract: ' + '; '.join(failures))
    if not isinstance(latest, dict) or not latest.get('tag_name'):
        raise ValueError('The latest-release read-back is missing')
    latest_tag = latest['tag_name']
    if latest_tag == expected_tag or str(latest_tag).startswith(TAG_PREFIX):
        raise ValueError('The component release owns the App latest pointer; a component '
                         'release must never become latest')
    if feed is None:
        raise ValueError('The Feather feed read-back is required to prove the component '
                         'is not an App feed entry')
    failures = feed_failures(feed, expected_tag)
    if failures:
        raise ValueError('; '.join(failures))
    return {
        'kind': 'office-component-release',
        'tag': expected_tag,
        'tagStyle': tag_style,
        'producerSourceCommit': source_commit,
        'engineSourceCommit': descriptor['sourceCommit'],
        'releaseId': release['id'],
        'releaseUrl': release.get('html_url'),
        'publishedAt': release.get('published_at'),
        'assets': [
            {'name': name, 'size': index[name][0]['size'],
             'digest': index[name][0]['digest']}
            for name in PUBLIC_ASSETS
        ],
        'latestTag': latest_tag,
        'feedEntry': False,
        'symbolsSHA256': summary['symbolsSHA256'],
        'symbolsUUID': summary['executableUUID'],
        'symbolsVisibility': 'private',
        'symbolsVerified': summary['symbolsVerified'],
    }


def write_release_notes(directory, descriptor):
    tag = descriptor['tag']
    lines = [
        f'# Floe Office native host component {tag}',
        '',
        'Immutable, source-bound storage for the qualified iOS native Office host.',
        'This component release is separate from App releases and is never `latest`.',
        '',
        f'- Engine/source commit: `{descriptor["sourceCommit"]}`',
        f'- Host archive: `{HOST_ASSET}` `{descriptor["archive"]["sha256"]}`',
        f'- Qualification manifest: `{descriptor["manifest"]["sha256"]}`',
        f'- Executable: `{descriptor["manifest"]["executableSHA256"]}`',
        f'- Private dSYM binding: `{descriptor["symbols"]["executableUUID"]}`',
        '',
        'The qualified dSYM is stored separately as a private artifact for the',
        'root to export and retain; it is not a release asset and is never',
        'downloaded by App bootstrap.',
        '',
        'Recovery is performed by `FloeAgent/scripts/bootstrap_office_host.py`;',
        'the tracked `engine.lock.json` pin remains the only trust root.',
        '',
    ]
    path = Path(directory) / 'OFFICE_COMPONENT_RELEASE.md'
    path.write_text('\n'.join(lines))
    return path


def _prepare_assets(args):
    source = Path(args.source)
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    write_deterministic_zip(source, output / args.asset, args.root)
    print(json.dumps(inspect_symbol_archive(output / args.asset)
                     if args.asset == SYMBOLS_ASSET
                     else inspect_license_archive(output / args.asset), indent=2))


def _load(path):
    return json.loads(Path(path).read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    package = sub.add_parser('package-asset', help='deterministically package one asset')
    package.add_argument('--source', type=Path, required=True)
    package.add_argument('--output', type=Path, required=True)
    package.add_argument('--asset', choices=(SYMBOLS_ASSET, LICENSES_ASSET), required=True)
    package.add_argument('--root', required=True)
    package.set_defaults(func=_prepare_assets)
    verify = sub.add_parser('verify-release-directory',
                            help='verify an assembled release set before a tag exists')
    verify.add_argument('directory', type=Path)
    verify.add_argument('--private-symbols', type=Path, required=True,
                        help='actual qualified private dSYM archive (never a public asset)')
    verify.add_argument('--lock', type=Path,
                        help='engine.lock.json; required to bind the descriptor to the pin')
    verify.set_defaults(func=lambda args: print(json.dumps(
        verify_self_contained(
            args.directory, private_symbols=args.private_symbols,
            lock=_load(args.lock) if args.lock else None,
            pin=(_load(args.lock)['qualifiedHostArtifact'] if args.lock else None)),
        indent=2)))
    publication = sub.add_parser(
        'verify-publication',
        help='verify canonical GitHub API JSON read-back of a component release')
    publication.add_argument('release', type=Path,
                             help='gh api repos/<repo>/releases/tags/<tag> JSON dump')
    publication.add_argument('--tag', required=True)
    publication.add_argument('--source-commit', required=True,
                             help='actual producer commit recorded by the descriptor transport')
    publication.add_argument('--tag-ref', type=Path, required=True)
    publication.add_argument('--tag-object', type=Path)
    publication.add_argument('--latest', type=Path, required=True)
    publication.add_argument('--feed', type=Path, required=True,
                             help='read-back of the public Feather feed')
    publication.add_argument('--release-dir', type=Path, required=True)
    publication.add_argument('--lock', type=Path, required=True)
    publication.add_argument('--private-symbols', type=Path, required=True)
    publication.set_defaults(func=lambda args: print(json.dumps(
        verify_publication(
            _load(args.release),
            _load(args.tag_ref),
            _load(args.tag_object) if args.tag_object else None,
            _load(args.latest), expected_tag=args.tag,
            expected_source_commit=args.source_commit,
            release_dir=args.release_dir, lock_path=args.lock,
            feed=_load(args.feed), private_symbols=args.private_symbols),
        indent=2)))
    args = parser.parse_args()
    try:
        args.func(args)
    except ValueError as failure:
        parser.exit(2, f'component: {failure}\n')


if __name__ == '__main__':
    main()
