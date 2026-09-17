#!/usr/bin/env python3
"""Build/sign the official WASI capability catalog; never rewrites released bytes.

The manifest below is the single fixed source of truth. Every id, command,
version, artifact path and pinned digest is explicit; catalog URLs are built
only from the immutable 40-hex committed revision supplied by CI. Nothing is
derived from a mutable branch, a network response or a local cache.

* ``assembled`` packages are rebuilt from the pinned WAT source and must match
  the released artifact bytes.
* ``committed`` packages ship as reviewed bytes (Lua 5.4.8) and are only
  verified against their pinned size and SHA-256; a mismatch, a missing file or
  an attempt to replace released bytes fails instead of publishing.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives import serialization

ROOT = Path(__file__).resolve().parent
PUBLIC_KEY = ROOT.parent / 'skill-hub/public-key.json'
DOMAIN = b'FLOE-CAPABILITY-CATALOG-V1\n'
URL_PREFIX = 'https://raw.githubusercontent.com/JiangNanGenius/floe-agent'

# Fixed manifest: no version, command, path, size or digest is discovered at
# runtime. `floe/lua` is the committed 5.4.8 interpreter; `floe/wasm-text`
# keeps its existing generated artifact.
MANIFEST = (
    {
        'id': 'floe/wasm-text',
        'command': 'floe-text',
        'version': '1.0.0',
        'minimumAppVersion': '1.6.7',
        'kind': 'assembled',
        'source': 'Sources/floe-text.wat',
        'path': 'packages/floe-text/1.0.0/floe-text.wasm',
    },
    {
        'id': 'floe/lua',
        'command': 'floe-lua',
        'version': '5.4.8',
        'minimumAppVersion': '1.7.0',
        'kind': 'committed',
        'path': 'packages/floe-lua/5.4.8/lua.wasm',
        'sha256': '81ad32f4eca06d232598ad7bf6f4f92bab4864a5b5d0f4da036e159b2efdf049',
        'sizeBytes': 671143,
    },
)


def assemble(source, destination):
    """Assemble the pinned WAT source with the checked-out CapabilityAssembler."""
    subprocess.run(['swift', 'run', '--package-path', str(ROOT), '--jobs', '2',
                    'CapabilityAssembler', str(source), str(destination)], check=True)


def verify_committed(entry, data):
    """Reject committed artifacts that do not match their pinned immutable digest."""
    expected = entry.get('sha256')
    size = entry.get('sizeBytes')
    if not expected or size is None:
        raise RuntimeError(f"{entry['path']} requires a pinned sha256 and size")
    if len(data) != size or hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError(f"{entry['path']} does not match its pinned immutable digest")
    if not data.startswith(b'\0asm\x01\0\0\0'):
        raise RuntimeError(f"{entry['path']} is not a WASM module")


def place_immutable(path, data, label):
    """Write ``data`` only when ``path`` is absent; never replace released bytes."""
    path = Path(path)
    if path.exists():
        if path.read_bytes() != data:
            raise RuntimeError(f"{label} already exists with different bytes; "
                               "increment the package version instead of overwriting released artifacts")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)


def artifact_bytes(entry, output, assembler=assemble):
    """Return the verified artifact bytes for one manifest entry."""
    output = Path(output)
    committed = ROOT / entry['path']
    destination = output / entry['path']
    if entry['kind'] == 'assembled':
        candidate = destination.with_suffix('.candidate.wasm')
        candidate.parent.mkdir(parents=True, exist_ok=True)
        try:
            assembler(ROOT / entry['source'], candidate)
            data = candidate.read_bytes()
        finally:
            candidate.unlink(missing_ok=True)
        if committed.exists() and committed.read_bytes() != data:
            raise RuntimeError(f"{entry['path']} would change released bytes; increment the package version")
    elif entry['kind'] == 'committed':
        data = committed.read_bytes()
        verify_committed(entry, data)
    else:
        raise RuntimeError(f"Unknown manifest kind for {entry['id']}")
    place_immutable(destination, data, entry['path'])
    return data


def catalog_payload(artifacts, revision):
    """Canonical catalog payload for a committed revision.

    The revision is validated as immutable 40-hex by ``build`` for official
    signing; the temporary test-key path may use a non-releasable placeholder.
    """
    packages = []
    for entry in MANIFEST:
        data = artifacts[entry['id']]
        packages.append({
            'id': entry['id'],
            'version': entry['version'],
            'command': entry['command'],
            'minimumAppVersion': entry['minimumAppVersion'],
            'sha256': hashlib.sha256(data).hexdigest(),
            'url': f"{URL_PREFIX}/{revision}/capability-hub/{entry['path']}",
        })
    return {'schemaVersion': 1, 'packages': packages}


def sign_catalog(catalog, key):
    return base64.b64encode(key.sign(DOMAIN + catalog)).decode()


def verify_catalog(catalog, signature_b64, public_key_bytes):
    Ed25519PublicKey.from_public_bytes(public_key_bytes).verify(
        base64.b64decode(signature_b64, validate=True), DOMAIN + catalog)


def build(output, test_key=False, revision=None, assembler=assemble):
    output = Path(output)
    if revision is None:
        revision = os.environ.get('FLOE_CAPABILITY_REVISION', 'main' if test_key else '')
    if not test_key and (len(revision) != 40 or any(c not in '0123456789abcdef' for c in revision)):
        raise RuntimeError('Official catalog requires the committed artifact revision')
    artifacts = {entry['id']: artifact_bytes(entry, output, assembler) for entry in MANIFEST}
    payload = catalog_payload(artifacts, revision)
    catalog = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
    if test_key:
        key = Ed25519PrivateKey.generate()
    else:
        encoded = os.environ.get('FLOE_SKILL_HUB_SIGNING_KEY')
        if not encoded:
            raise RuntimeError('Official signing key is unavailable')
        key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(encoded, validate=True))
        trusted = json.loads(PUBLIC_KEY.read_text())
        public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        if public != base64.b64decode(trusted['publicKey']):
            raise RuntimeError('Signing key does not match the pinned official identity')
    signature = sign_catalog(catalog, key)
    (output / 'catalog.json').write_bytes(catalog)
    (output / 'catalog.sig').write_text(signature + '\n')
    if not test_key:
        bundle = ROOT.parent / 'FloeAgent/FloeApp/Resources/Capabilities'
        bundle.mkdir(parents=True, exist_ok=True)
        for name in ['catalog.json', 'catalog.sig']:
            shutil.copyfile(output / name, bundle / name)
        shutil.copyfile(PUBLIC_KEY, bundle / 'public-key.json')
    public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    print('WASI packages and signed catalog verified; no app version published')
    return {'payload': payload, 'catalog': catalog, 'signature': signature, 'publicKey': public}


def check(base=ROOT, public_key_path=None):
    """Read-only verification of the committed signed catalog against the manifest.

    Never signs, writes or rebuilds. The committed catalog must contain exactly
    the manifest packages, pin the same digests and use immutable full-SHA URLs.
    """
    base = Path(base)
    catalog = (base / 'catalog.json').read_bytes()
    signature = (base / 'catalog.sig').read_text().strip()
    trusted = base64.b64decode(json.loads(Path(public_key_path or PUBLIC_KEY).read_text())['publicKey'])
    verify_catalog(catalog, signature, trusted)
    payload = json.loads(catalog)
    if payload.get('schemaVersion') != 1:
        raise RuntimeError('Unsupported catalog schema version')
    expected = {entry['id']: entry for entry in MANIFEST}
    revisions = set()
    for package in payload.get('packages', []):
        entry = expected.get(package.get('id'))
        if entry is None:
            raise RuntimeError(f"Unexpected catalog entry {package.get('id')}")
        match = re.fullmatch(
            rf"{re.escape(URL_PREFIX)}/([0-9a-f]{{40}})/capability-hub/{re.escape(entry['path'])}",
            package.get('url', ''))
        if not match:
            raise RuntimeError(f"{entry['id']} does not use an immutable artifact URL")
        revisions.add(match.group(1))
        for field in ('version', 'command', 'minimumAppVersion'):
            if package.get(field) != entry[field]:
                raise RuntimeError(f"{entry['id']} catalog {field} does not match the manifest")
        data = (base / entry['path']).read_bytes()
        if entry['kind'] == 'committed':
            verify_committed(entry, data)
        if hashlib.sha256(data).hexdigest() != package.get('sha256'):
            raise RuntimeError(f"{entry['id']} artifact digest does not match the signed catalog")
        expected.pop(entry['id'])
    if expected:
        raise RuntimeError('Committed catalog is missing manifest packages: ' + ', '.join(sorted(expected)))
    if len(revisions) != 1:
        raise RuntimeError('Catalog mixes multiple artifact revisions')
    return payload


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT)
    parser.add_argument('--test-key', action='store_true')
    parser.add_argument('--check', action='store_true',
                        help='read-only: verify the committed signed catalog against the fixed manifest')
    args = parser.parse_args()
    if args.check:
        if args.test_key:
            parser.error('--check verifies the committed catalog; do not pass --test-key')
        check()
        print('Committed signed catalog matches the fixed manifest; nothing written')
    else:
        if args.test_key and args.output.resolve() == ROOT:
            parser.error('Test signatures must use a separate output directory')
        build(args.output, args.test_key)
