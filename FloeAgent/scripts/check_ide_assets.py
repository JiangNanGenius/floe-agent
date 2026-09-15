#!/usr/bin/env python3
"""Read-only integrity validation of pinned offline IDE distributions."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1] / 'FloeApp/Resources/IDE'
vendor = root / 'vendor'
count = 0
for manifest in [vendor / 'manifest.json', vendor / 'codicons-manifest.json', vendor / 'supplemental-manifest.json']:
    records = json.loads(manifest.read_text())
    for record in records if isinstance(records, list) else [records]:
        for name, expected in record['files'].items():
            assert '/' not in name and '\\' not in name, name
            actual = hashlib.sha256((vendor / name).read_bytes()).hexdigest()
            assert actual == expected, f'IDE asset integrity mismatch: {name}'
            count += 1
for name in ['525.js', 'a5d01a41d1b288b6934e.module.wasm']:
    assert (root / name).read_bytes() == (vendor / name).read_bytes(), name
print(f'IDE offline assets: {count} pinned hashes and 2 webpack resource aliases verified')
