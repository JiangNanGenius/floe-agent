#!/usr/bin/env python3
"""Persistence gate for the Notes-committed PPTX after the edit scenario.

Notes storage is content-addressed: the committed resource is the file
``<resources dir>/<sha256-of-content>``. This gate reads the imported-fixture
receipt (written by the DEBUG-only qualification plumbing at import time),
then requires, fail closed:

* the original seeded resource still present with the pinned fixture SHA-256;
* at least one NEW resource whose content hash (its file name) matches its
  bytes, validates as OOXML, contains the seeded two slides plus the two
  inserted slides (one per edit session), and still carries the fixture marker text — the exact saved
  file the edit produced;
* no resource named by a hash that does not match its content.

A changed hash alone is not accepted: the new file must be a real PPTX.
"""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

EXPECTED_FINAL_SLIDES = 4
MARKER_TOKENS = ('Floe SIM QUAL',)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def pptx_facts(path):
    try:
        with zipfile.ZipFile(path) as archive:
            if archive.testzip() is not None:
                return None
            names = archive.namelist()
            slides = sorted(name for name in names
                            if name.startswith('ppt/slides/slide') and name.endswith('.xml'))
            text = ''
            for name in slides:
                try:
                    text += archive.read(name).decode('utf-8', errors='ignore')
                except KeyError:
                    return None
    except (OSError, zipfile.BadZipFile):
        return None
    return {'slides': len(slides),
            'markers': [token for token in MARKER_TOKENS if token in text]}


def check_saved_document(resources_dir, import_receipt_path):
    resources_dir = Path(resources_dir)
    receipt = json.loads(Path(import_receipt_path).read_text())
    original_hash = receipt.get('originalResourceSHA256')
    failures = []
    if not original_hash:
        failures.append('import receipt lacks the original resource hash')
    original = resources_dir / original_hash if original_hash else None
    if original_hash:
        if not original.is_file():
            failures.append('original seeded resource missing from Notes storage')
        elif sha256(original) != original_hash:
            failures.append('original seeded resource content does not match its pinned hash')

    candidates = []
    for path in sorted(resources_dir.iterdir()):
        if not path.is_file() or path.name.startswith('.'):
            continue
        content_hash = sha256(path)
        if path.name != content_hash:
            failures.append(f'resource name/content hash mismatch: {path.name}')
            continue
        facts = pptx_facts(path)
        if facts is None:
            continue
        facts['hash'] = content_hash
        facts['size'] = path.stat().st_size
        candidates.append(facts)

    edited = [facts for facts in candidates
              if facts['hash'] != original_hash
              and facts['slides'] == EXPECTED_FINAL_SLIDES
              and facts['markers']]
    result = {
        'resourcesDir': str(resources_dir),
        'originalResourcePresent': bool(original_hash and original.is_file()),
        'pptxResources': len(candidates),
        'editedCandidates': edited,
        'failures': failures,
        'persistencePassed': not failures and bool(edited),
        'checkKind': 'notes-content-addressed-resource',
        'hostKind': 'fullFloeAppSimulator',
    }
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('resources_dir', type=Path,
                        help='Notes Resources directory inside the app data container')
    parser.add_argument('--import-receipt', type=Path, required=True,
                        help='office-real-engine-import.json from the app container')
    parser.add_argument('--output', type=Path, default=None)
    args = parser.parse_args()
    result = check_saved_document(args.resources_dir, args.import_receipt)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    if not result['persistencePassed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
