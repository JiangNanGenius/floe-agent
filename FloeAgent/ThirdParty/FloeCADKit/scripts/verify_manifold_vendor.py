#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Read-only verification of the packaged, source-pinned Manifold core."""
from pathlib import Path
import hashlib
import json
import plistlib

root = Path(__file__).resolve().parents[1] / "Vendor"
manifest = json.loads((root / "Manifold-SOURCE.json").read_bytes())
assert manifest["sourceCommit"] == "ce50d78021d64507f89e8c9fc2c2e51018117857"
assert manifest["version"] == "3.5.4" and manifest["license"] == "Apache-2.0"
assert manifest["archiveSHA256"] == "c7b3626593380866b599f7b5927de857d4780e94fdb97bf2f015a879d7084537"
package = root / "ManifoldCore.xcframework"
actual = {str(p.relative_to(package)): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in package.rglob("*") if p.is_file() and not p.is_symlink()}
assert actual == manifest["files"], "Manifold package contents or hashes changed"
assert not any(p.is_symlink() for p in package.rglob("*")), "Unexpected package symlink"
slices = plistlib.loads((package / "Info.plist").read_bytes())["AvailableLibraries"]
assert {x["LibraryIdentifier"] for x in slices} == {"ios-arm64", "ios-arm64-simulator", "macos-arm64"}
for item in slices:
    assert item["SupportedArchitectures"] == ["arm64"]
    assert item["LibraryPath"] == "libmanifold.a"
    archive = package / item["LibraryIdentifier"] / item["LibraryPath"]
    assert archive.read_bytes().startswith(b"!<arch>\n"), "Expected native static archive"
assert b"Apache License" in (root / "Manifold-LICENSE.txt").read_bytes()
print(f"Manifold 3.5.4: {len(slices)} native slices, {len(actual)} pinned files verified")
