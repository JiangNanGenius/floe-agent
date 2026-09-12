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

# SwiftPM binary artifacts are not reliably discovered by directory scans.
python3 - <<'PYTHON'
import json, re
from pathlib import Path
path = Path("sbom.spdx.json")
document = json.loads(path.read_text())
manifest = Path("ThirdParty/FloeShellEngine/Package.swift").read_text()
for name, url, checksum in re.findall(r'name: "([^"]+)",\s*url: "([^"]+)",\s*checksum: "([0-9a-f]+)"', manifest):
    identifier = "SPDXRef-FloeShellEngine-" + name.replace("_", "-")
    document.setdefault("packages", []).append({
        "name": name, "SPDXID": identifier, "downloadLocation": url,
        "versionInfo": "ios-system-v3.0.4-manifest", "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION", "licenseDeclared": "NOASSERTION",
        "copyrightText": "NOASSERTION",
        "checksums": [{"algorithm": "SHA256", "checksumValue": checksum}]
    })
    document.setdefault("relationships", []).append({
        "spdxElementId": document["SPDXID"], "relationshipType": "DESCRIBES", "relatedSpdxElement": identifier
    })
path.write_text(json.dumps(document, indent=2) + "\n")
PYTHON

echo "sbom OK: sbom.spdx.json generated"
