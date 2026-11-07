#!/usr/bin/env python3
"""Read-only checks. Generating a manifest requires --write-manifest explicitly."""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import sys

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent
FILES=["biology_worker.py","bio_common.py","bio_sequence_structure.py","bio_image_omics.py","bio_network.py","bio_sbml.py","bio_tiff.py","requirements.lock","dependency-licenses.json","verify_backend.py"]

def manifest():
    entries=[]
    for name in FILES:
        path=ROOT/name
        if path.is_symlink():raise ValueError("Symbolic resource is not accepted")
        data=path.read_bytes()
        entries.append(dict(file=name,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
    return dict(schema="floe.biology.worker.resources.v1",files=entries)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check",action="store_true")
    mode.add_argument("--write-manifest",action="store_true")
    parser.add_argument("--runtime",action="store_true")
    args=parser.parse_args()
    expected=manifest();path=ROOT/"worker-manifest.json"
    if args.write_manifest:path.write_text(json.dumps(expected,indent=2)+"\n")
    elif json.loads(path.read_text())!=expected:raise ValueError("Worker resources changed; review changes and regenerate the manifest explicitly")
    checked=0
    if args.runtime:
        for line in (ROOT/"requirements.lock").read_text().splitlines():
            if not line or line.startswith("#"):continue
            package,version=line.split("==")
            actual=importlib.metadata.version(package)
            if actual!=version:raise ValueError(f"{package}: expected {version}, found {actual}")
            checked+=1
    print(json.dumps(dict(success=True,resources=len(expected["files"]),runtimePackages=checked,readOnly=args.check)))

if __name__=="__main__":main()
