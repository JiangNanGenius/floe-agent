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
sources = json.loads((root / 'CAD_SOURCES.json').read_text())
assert len(sources['sourceSHA']) == 40
cad = next(p for p in sources['packages'] if p['name'] == 'acadrust')
assert cad['version'] == '0.5.5' and cad['license'] == 'MPL-2.0'
assert cad['sha256'] == '6298485f7afd00af7880f285f01ab387143a1fbb20c42f9048830c95b19dda5d'
assert (root / 'floe_cad_engine_bg.wasm').read_bytes().startswith(b'\x00asm')
assert (root / 'CAD_NOTICES.txt').stat().st_size > 1000
assert "'wasm-unsafe-eval'" in html
print(f'Engineering viewer: {len(manifest)} hashes, closed network policy and notices verified')
