#!/usr/bin/env python3
"""Verify the exact bundled worker payload. --check never writes or refreshes a digest."""
import argparse, hashlib, json, pathlib

ROOT = pathlib.Path(__file__).resolve().parent
NAMES = ['chemistry_worker.py','science_worker.py','quantum_worker.py','requirements-rdkit.txt','requirements-science.txt']

def main():
    parser=argparse.ArgumentParser()
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check',action='store_true')
    mode.add_argument('--refresh',action='store_true')
    args=parser.parse_args()
    value=dict(protocolVersion=1,files={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in NAMES})
    path=ROOT/'WorkerManifest.json'
    if args.refresh:
        staging=path.with_suffix('.json.tmp')
        staging.write_text(json.dumps(value,indent=2,sort_keys=True)+'\n')
        staging.replace(path)
        print('Refreshed manifest for',len(NAMES),'worker files')
    else:
        if json.loads(path.read_text()) != value:
            raise SystemExit('Worker resource manifest does not match the source files')
        print('Verified',len(NAMES),'worker files; protocol version 1')

if __name__=='__main__': main()
