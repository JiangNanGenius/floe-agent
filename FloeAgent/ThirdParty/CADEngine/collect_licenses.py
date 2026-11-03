#!/usr/bin/env python3
"""Collect notices from the exact Cargo-resolved sources, never a moving website."""
import json
import hashlib
import os
from pathlib import Path
import tomllib

root = Path(__file__).resolve().parent
metadata = json.loads(Path(os.environ.get('FLOE_CAD_METADATA', root / 'dependency-metadata.json')).read_text())
patch = json.loads((root / 'vendor/ACADRUST_PATCHES.json').read_text())
lock = tomllib.loads((root / 'Cargo.lock').read_text())
checksums = {(p['name'], p['version']): p.get('checksum') for p in lock['package']}
notices = ['# Floe CAD engine third-party notices\n\nFloe wrapper: MPL-2.0.\n']
inventory = []
nodes = {n['id']: n for n in metadata['resolve']['nodes']}
reachable, pending = set(), [metadata['resolve']['root']]
while pending:
    node = pending.pop()
    if node in reachable:
        continue
    reachable.add(node)
    pending.extend(d['pkg'] for d in nodes[node]['deps'])
for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
    if package['name'] == 'floe-cad-engine' or package['id'] not in reachable:
        continue
    folder = Path(package['manifest_path']).parent
    files = sorted(p for p in folder.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE', 'LICENCE', 'COPYING', 'NOTICE')))
    if package.get('license_file'):
        candidate = folder / package['license_file']
        if candidate.is_file() and candidate not in files:
            files.append(candidate)
    assert files, f"Missing upstream license text: {package['name']}"
    item = {'name': package['name'], 'version': package['version'], 'license': package.get('license'),
            'source': f"https://crates.io/api/v1/crates/{package['name']}/{package['version']}/download",
            'sha256': checksums.get((package['name'], package['version']))}
    if package['name'] == 'acadrust':
        assert package['version'] == patch['upstream']['version']
        item['sha256'] = patch['upstream']['crateSHA256']
        item['localPatchSHA256'] = {entry['file']: hashlib.sha256((folder / entry['file']).read_bytes()).hexdigest() for entry in patch['patches']}
    assert item['sha256'], f"Missing pinned upstream checksum: {package['name']}"
    inventory.append(item)
    notices.append(f"\n## {item['name']} {item['version']} — {item['license']}\nSource: {item['source']}\nSHA-256: {item['sha256']}\n")
    for file in files:
        assert file.stat().st_size <= 256 * 1024, file
        notices.append(f"\n### {file.name}\n\n" + file.read_text(errors='strict').replace('\r\n', '\n') + '\n')
out = Path(os.environ.get('FLOE_CAD_LICENSE_OUT', root / 'pkg'))
out.mkdir(exist_ok=True)
notices.append('\n## Floe local acadrust patches\n\nThe pinned MPL-2.0 acadrust 0.5.5 source is retained under CADEngine/vendor. Local DWG writer patches preserve explicit NULL dictionary entries and inherited NULL text styles in stored modern table cell styles. See vendor/ACADRUST_PATCHES.json for exact upstream provenance and patch scope.\n')
(out / 'CAD_NOTICES.txt').write_text(''.join(notices))
inputs = [*root.glob('src/**/*.rs'), *root.glob('src/fixtures/*'), root / 'Cargo.toml', root / 'Cargo.lock', root / 'rust-toolchain.toml', root / 'collect_licenses.py', root / 'vendor/ACADRUST_PATCHES.json']
source_hashes = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(inputs)}
vendor_hash = hashlib.sha256()
for p in sorted((root / 'vendor/acadrust-0.5.5').rglob('*')):
    if p.is_file(): vendor_hash.update((str(p.relative_to(root)) + '\0' + hashlib.sha256(p.read_bytes()).hexdigest() + '\n').encode())
(out / 'CAD_SOURCES.json').write_text(json.dumps({'sourceSHA': os.environ['GITHUB_SHA'], 'sourceState': 'base commit plus exact wrapperSourceSHA256 and vendorSourceTreeSHA256 inputs', 'packages': inventory, 'wrapperSourceSHA256': source_hashes, 'vendorSourceTreeSHA256': vendor_hash.hexdigest(), 'build': {'rust': 'rustc 1.98.1', 'wasmBindgen': '0.2.126', 'target': 'wasm32-unknown-unknown', 'maxLinearMemoryBytes': 402653184}}, indent=2) + '\n')
print(f"Retained notices and pinned source references for {len(inventory)} resolved packages")
