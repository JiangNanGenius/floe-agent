#!/usr/bin/env python3
"""Build/sign the official WASI capability catalog; never rewrites released bytes."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

ROOT = Path(__file__).resolve().parent
DOMAIN = b'FLOE-CAPABILITY-CATALOG-V1\n'


def build(output, test_key=False):
    output = Path(output)
    artifact = output / 'packages/floe-text/1.0.0/floe-text.wasm'
    artifact.parent.mkdir(parents=True, exist_ok=True)
    candidate = artifact.with_suffix('.candidate.wasm')
    try:
        subprocess.run(['swift', 'run', '--package-path', str(ROOT), '--jobs', '2', 'CapabilityAssembler', str(ROOT / 'Sources/floe-text.wat'), str(candidate)], check=True)
        data = candidate.read_bytes()
        if artifact.exists() and artifact.read_bytes() != data:
            raise RuntimeError('Published WASM artifact differs; increment the package version')
        if not artifact.exists():
            candidate.replace(artifact)
    finally:
        candidate.unlink(missing_ok=True)
    revision = os.environ.get('FLOE_CAPABILITY_REVISION', 'main' if test_key else '')
    if not test_key and (len(revision) != 40 or any(c not in '0123456789abcdef' for c in revision)):
        raise RuntimeError('Official catalog requires the committed artifact revision')
    payload = {'schemaVersion': 1, 'packages': [{
        'id': 'floe/wasm-text', 'version': '1.0.0', 'command': 'floe-text',
        'minimumAppVersion': '1.6.7', 'sha256': hashlib.sha256(data).hexdigest(),
        'url': f'https://raw.githubusercontent.com/JiangNanGenius/floe-agent/{revision}/capability-hub/packages/floe-text/1.0.0/floe-text.wasm'
    }]}
    catalog = json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()
    if test_key:
        key = Ed25519PrivateKey.generate()
    else:
        encoded = os.environ.get('FLOE_SKILL_HUB_SIGNING_KEY')
        if not encoded:
            raise RuntimeError('Official signing key is unavailable')
        key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(encoded, validate=True))
        trusted = json.loads((ROOT.parent / 'skill-hub/public-key.json').read_text())
        public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        if public != base64.b64decode(trusted['publicKey']):
            raise RuntimeError('Signing key does not match the pinned official identity')
    (output / 'catalog.json').write_bytes(catalog)
    (output / 'catalog.sig').write_text(base64.b64encode(key.sign(DOMAIN + catalog)).decode() + '\n')
    if not test_key:
        bundle = ROOT.parent / 'FloeAgent/FloeApp/Resources/Capabilities'
        bundle.mkdir(parents=True, exist_ok=True)
        for name in ['catalog.json', 'catalog.sig']:
            shutil.copyfile(output / name, bundle / name)
        shutil.copyfile(ROOT.parent / 'skill-hub/public-key.json', bundle / 'public-key.json')
    print('WASI package and catalog verified and signed; no app version published')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT)
    parser.add_argument('--test-key', action='store_true')
    args = parser.parse_args()
    if args.test_key and args.output.resolve() == ROOT:
        parser.error('Test signatures must use a separate output directory')
    build(args.output, args.test_key)
