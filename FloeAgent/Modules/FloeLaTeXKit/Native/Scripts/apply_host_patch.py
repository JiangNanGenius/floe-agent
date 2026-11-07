#!/usr/bin/env python3
"""Verify the exact reviewed source delta, or apply it to the pinned upstream."""
from pathlib import Path
import argparse,hashlib,json,subprocess
native=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--check',action='store_true');args=p.parse_args()
manifest=json.loads((native/'patches/source-manifest.json').read_text())
patch=native/'patches/apple-and-embedded.patch'
if hashlib.sha256(patch.read_bytes()).hexdigest()!=manifest['patchSHA256']:raise SystemExit('The reviewed patch digest changed')
state=[]
for path,expected in manifest['files'].items():
 file=native/'tectonic'/path
 actual=hashlib.sha256(file.read_bytes()).hexdigest()
 if actual==expected['patchedSHA256']:state.append('patched')
 elif actual==expected['upstreamSHA256']:state.append('upstream')
 else:raise SystemExit('Unexpected source change: '+path)
if all(s=='patched' for s in state):print('Verified pinned Apple/embedded source patch');raise SystemExit(0)
if args.check:raise SystemExit('The pinned source requires the reviewed Apple/embedded patch')
if not all(s=='upstream' for s in state):raise SystemExit('Source contains a partial patch; preserve and reconcile it before building')
subprocess.run(['patch','--dry-run','-p1','-i',str(patch.resolve())],cwd=native/'tectonic',check=True)
subprocess.run(['patch','-p1','-i',str(patch.resolve())],cwd=native/'tectonic',check=True)
subprocess.run(['python3',str(Path(__file__).resolve()),'--check'],check=True)
