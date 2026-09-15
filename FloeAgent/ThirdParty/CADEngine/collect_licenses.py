#!/usr/bin/env python3
"""Collect notices from the exact Cargo-resolved sources, never a moving website."""
import json
import os
from pathlib import Path
import tomllib

root = Path(__file__).resolve().parent
metadata = json.loads((root / 'dependency-metadata.json').read_text())
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
            'sha256': checksums[(package['name'], package['version'])]}
    inventory.append(item)
    notices.append(f"\n## {item['name']} {item['version']} — {item['license']}\nSource: {item['source']}\nSHA-256: {item['sha256']}\n")
    for file in files:
        assert file.stat().st_size <= 256 * 1024, file
        notices.append(f"\n### {file.name}\n\n" + file.read_text(errors='strict').replace('\r\n', '\n') + '\n')
out = root / 'pkg'
out.mkdir(exist_ok=True)
(out / 'CAD_NOTICES.txt').write_text(''.join(notices))
(out / 'CAD_SOURCES.json').write_text(json.dumps({'sourceSHA': os.environ['GITHUB_SHA'], 'packages': inventory}, indent=2) + '\n')
print(f"Retained notices and pinned source references for {len(inventory)} resolved packages")
