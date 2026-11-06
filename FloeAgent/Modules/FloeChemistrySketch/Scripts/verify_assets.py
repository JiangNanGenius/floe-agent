#!/usr/bin/env python3
"""Read-only verification of the pinned offline chemistry distribution."""
import argparse, hashlib, json, pathlib

parser=argparse.ArgumentParser()
parser.add_argument('--check',action='store_true',required=True)
parser.parse_args()
module=pathlib.Path(__file__).resolve().parents[1]
root=module/'Sources/FloeChemistrySketch/Resources/Ketcher'
record=json.loads((module/'UPSTREAM.json').read_text())
expected=record['bundledFiles']
actual={str(p.relative_to(root)):p for p in root.rglob('*') if p.is_file()}
if set(actual)!=set(expected):raise SystemExit('Offline chemistry asset inventory differs from the pin')
for name,digest in expected.items():
    path=actual[name]
    if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest()!=digest:
        raise SystemExit('Offline chemistry asset changed: '+name)
print('Pinned offline chemistry assets verified; no files changed')
