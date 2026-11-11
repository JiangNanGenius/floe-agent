#!/usr/bin/env python3
"""Read-only verification of the shipped static GPU dependency."""
import hashlib
import json
import plistlib
from pathlib import Path


def main():
    root = Path(__file__).resolve().parent
    record = json.loads((root / "PROVENANCE.json").read_text())
    framework = root / "FloeGPU.xcframework"
    actual = {str(p.relative_to(framework)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in framework.rglob("*") if p.is_file()}
    assert actual == record["frameworkFilesSHA256"], "GPU artifact/header drift"
    for name, expected in record["librariesSHA256"].items():
        assert actual[name] == expected, name
    info = plistlib.loads((framework / "Info.plist").read_bytes())
    assert {row["LibraryIdentifier"] for row in info["AvailableLibraries"]} == {
        "ios-arm64", "ios-arm64-simulator", "macos-arm64"}
    for row in info["AvailableLibraries"]:
        assert row["SupportedArchitectures"] == ["arm64"]
        assert not (framework / row["LibraryIdentifier"] / row["HeadersPath"] / "module.modulemap").exists(), \
            "Binary-root modulemaps collide in Xcode's flat static-library header output; use the FloeVirtualGPU C wrapper"
        archive = framework / row["LibraryIdentifier"] / row["LibraryPath"]
        assert archive.read_bytes().startswith(b"!<arch>\n"), archive.name
    patch = root.parents[1] / "ThirdParty/FloeVirtualGPU/patches/0001-floe-vkr-accounting.patch"
    assert hashlib.sha256(patch.read_bytes()).hexdigest() == record["renderer"]["patchSHA256"]
    for name, expected in record["licensesSHA256"].items():
        assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, name
    print("FloeGPU: three static arm64 slices, headers, licenses and renderer patch verified")


if __name__ == "__main__":
    main()
