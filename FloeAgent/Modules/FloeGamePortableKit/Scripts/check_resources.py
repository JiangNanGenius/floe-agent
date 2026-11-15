#!/usr/bin/env python3
"""Read-only verification of one prepared resource against its manifest."""
import argparse
from pathlib import Path
import make_resource_manifest as mrm

ap = argparse.ArgumentParser()
ap.add_argument('--root', required=True)
ap.add_argument('--manifest', required=True)
args = ap.parse_args()
mrm.check(Path(args.root), Path(args.manifest))
print('OK', args.root)
