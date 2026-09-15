#!/usr/bin/env python3
"""Read-only verification of the bundled engineering viewer distribution."""
import hashlib
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1] / 'FloeApp/Resources/EngineeringViewers'
manifest = json.loads((root / 'asset-hashes.json').read_text())
actual_files = {p.name for p in root.iterdir() if p.name != 'asset-hashes.json'}
assert actual_files == set(manifest), 'Viewer asset inventory differs from the pinned manifest'
for name, expected in manifest.items():
    assert '/' not in name and '\\' not in name and not name.startswith('.'), name
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, name
html = (root / 'index.html').read_text()
assert "default-src 'none'" in html and "connect-src 'self' blob:" in html
assert 'https:' not in html and 'http:' not in html
assert (root / 'THIRD_PARTY_NOTICES.txt').stat().st_size > 1000
print(f'Engineering viewer: {len(manifest)} hashes, closed network policy and notices verified')
