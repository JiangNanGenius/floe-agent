#!/bin/bash
# sbom.sh — Generate an SPDX SBOM with syft. Output: sbom.spdx.json
# (git-ignored; uploaded as a CI artifact).
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v syft >/dev/null 2>&1; then
    echo "error: syft not installed (brew install syft)" >&2
    exit 1
fi

syft scan . -o spdx-json=sbom.spdx.json

echo "sbom OK: sbom.spdx.json generated"
