#!/bin/bash
# pin_check.sh — Verify Package.resolved matches the exact pins declared in
# Package.swift and has not drifted. Dependency pinning is a supply-chain
# control; silent drift fails CI.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f Package.resolved ]; then
    echo "error: Package.resolved missing; run 'swift package resolve' and commit it" >&2
    exit 1
fi

# Every pin must be immutable: either an exact semantic version or a commit
# revision. Branch pins are intentionally rejected.
python3 - <<'PY'
import json, sys

with open("Package.resolved") as f:
    resolved = json.load(f)

pins = resolved.get("pins", [])
errors = []
for pin in pins:
    state = pin.get("state", {})
    if "version" not in state and "revision" not in state:
        errors.append(f"{pin.get('identity')}: not pinned to a version or revision ({state})")
    if "branch" in state and "revision" not in state:
        errors.append(f"{pin.get('identity')}: branch pins are mutable ({state})")

if errors:
    print("error: unpinned dependencies found:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(f"pin_check OK: {len(pins)} dependencies pinned to versions or revisions")
PY
