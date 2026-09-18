#!/usr/bin/env python3
"""Stage one compilepending language artifact without signing anything.

This is the mechanical half of promotion. It never edits ``MANIFEST``,
``catalog.json`` or ``catalog.sig``. It copies a locally built or verified
artifact into ``capability-hub/packages`` (immutably: existing bytes with a
different digest are refused), validates the declared identity/digest/size
against the fixed candidate metadata in ``build.py``, and writes a promotion
record under ``capability-hub/candidates`` that a reviewer uses to move the
entry into ``MANIFEST``.

Usage:
    python3 capability-hub/stage_artifact.py --id floe/ruby --artifact ruby.wasm
    python3 capability-hub/stage_artifact.py --id floe/php --artifact php-cgi.wasm --evidence DIR
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path

import build

WASM_MAGIC = b'\0asm\x01\0\0\0'


def sha256_of(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def evidence_digests(directory):
    """Digest every regular file in an evidence directory, sorted by name."""
    if directory is None:
        return {}
    directory = Path(directory)
    if not directory.exists():
        raise RuntimeError(f'evidence directory does not exist: {directory}')
    return {
        str(path.relative_to(directory)): sha256_of(path)
        for path in sorted(directory.rglob('*')) if path.is_file()
    }


def stage(identifier, artifact, evidence=None, base=build.ROOT):
    base = Path(base)
    candidate = next((item for item in build.validate_candidates() if item['id'] == identifier), None)
    if candidate is None:
        raise RuntimeError(f'{identifier} is not a registered compilepending candidate')
    data = Path(artifact).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    limits = build.entry_limits(candidate)
    if len(data) > limits['moduleMaxBytes']:
        raise RuntimeError(f'{identifier} artifact exceeds its declared moduleMaxBytes')
    if not data.startswith(WASM_MAGIC):
        raise RuntimeError(f'{identifier} artifact is not a WASM module')
    expected_member = candidate['source'].get('memberSha256')
    if expected_member and expected_member != digest:
        raise RuntimeError(f'{identifier} artifact does not match the pinned member digest')
    # The staged filename comes from the artifact itself so a CLI or CGI PHP
    # build both stage cleanly; it must stay inside the declared package
    # directory and share the command's base name.
    expected_dir = Path(candidate['artifactPath']).parent
    filename = Path(artifact).name
    base_name = candidate['command'].removeprefix('floe-')
    if not filename.endswith('.wasm') or not filename.startswith(base_name):
        raise RuntimeError(f'{identifier} artifact name {filename} does not match command {candidate["command"]}')
    relative_path = expected_dir / filename
    destination = base / relative_path
    if destination.exists() and destination.read_bytes() != data:
        raise RuntimeError(f'{relative_path} already exists with different bytes; '
                           'increment the package version instead of overwriting a staged artifact')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    record = {
        'id': candidate['id'],
        'command': candidate['command'],
        'version': candidate['version'],
        'minimumAppVersion': candidate['minimumAppVersion'],
        'status': 'compilepending',
        'artifactPath': str(relative_path),
        'artifactSha256': digest,
        'artifactSizeBytes': len(data),
        'limits': limits,
        'source': candidate['source'],
        'stagedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'evidence': evidence_digests(evidence),
        'note': 'staged only; promotion into MANIFEST is a reviewed change and signing stays in capability-hub.yml',
    }
    record_path = base / 'candidates' / (identifier.replace('/', '-') + '.json')
    record_path.parent.mkdir(parents=True, exist_ok=True)
    record_path.write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    return record


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--id', required=True)
    parser.add_argument('--artifact', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, default=None)
    arguments = parser.parse_args()
    staged = stage(arguments.id, arguments.artifact, arguments.evidence)
    print(json.dumps({
        'id': staged['id'],
        'artifactPath': staged['artifactPath'],
        'artifactSha256': staged['artifactSha256'],
        'artifactSizeBytes': staged['artifactSizeBytes'],
        'limits': staged['limits'],
        'status': staged['status'],
    }, indent=2, sort_keys=True))
    print('staged without signing; promote the entry in capability-hub/build.py MANIFEST after review')
