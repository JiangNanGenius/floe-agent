#!/usr/bin/env python3
"""Read-only exact source/license check. Never rewrites manifests or checkouts."""
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parent
expected={name:digest for digest,name in (line.split("  ",1) for line in (root/"FLOE_SHA256SUMS").read_text().splitlines())}
actual={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob("*") if p.is_file() and not any(part in {".git",".build",".swiftpm","__pycache__"} for part in p.parts) and p.name!="FLOE_SHA256SUMS"}
if actual!=expected:raise SystemExit("Vendor digest mismatch; restore/review the exact pinned source, do not rewrite checksums to pass.")
p=json.loads((root/"PROVENANCE.json").read_text())
assert p["revision"]=="ae8562f895de06ccb86fdb1cbb65fd99c8976e12" and actual["LICENSE"]==p["licenseSHA256"]
for line in (root/"UPSTREAM_SHA256SUMS").read_text().splitlines():
 digest,name=line.split("  ",1);assert actual[name]==digest,name
print("PASS: exact upstream source/license and additive file-channel API")
