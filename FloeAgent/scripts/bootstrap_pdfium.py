#!/usr/bin/env python3
"""Package pinned, non-V8/non-XFA PDFium iOS libraries as signed app frameworks.

Upstream build provenance: bblanchon/pdfium-binaries chromium/8035.
Never downloads executable app code at runtime. All inputs are SHA256 pinned.
"""
import hashlib
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
PINS = {
    "device-arm64": "6aff8be7e86e5559ef3f401b9c278662230d6049017fb53048229b7a972b245a",
    "simulator-arm64": "39bb635c13c1a060f578600ad8838f47047182f4fcaa5d7db3950a4e2e031b05",
}


def main():
    destination = ROOT / "Vendor/PDFium/PDFium.xcframework"
    stamp = destination.parent / "pins.json"
    if destination.exists() and stamp.exists() and json.loads(stamp.read_text()) == PINS:
        print("Pinned PDFium XCFramework already prepared")
        return
    if destination.exists():
        raise RuntimeError("Existing PDFium differs from pins; remove only its generated directory before rebuilding")
    cache = Path(tempfile.gettempdir()) / "floe-pdfium-8035"
    cache.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="floe-pdfium-build-") as staging:
        staging = Path(staging)
        command = ["xcodebuild", "-create-xcframework"]
        for platform, sha in PINS.items():
            archive = cache / (platform + ".tgz")
            if not archive.exists():
                urllib.request.urlretrieve(f"https://github.com/bblanchon/pdfium-binaries/releases/download/chromium/8035/pdfium-ios-{platform}.tgz", archive)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != sha:
                raise RuntimeError("PDFium checksum mismatch: " + platform)
            extracted = staging / platform
            extracted.mkdir()
            with tarfile.open(archive) as source:
                for entry in source.getmembers():
                    if not (entry.isfile() or entry.isdir()) or entry.name.startswith("/") or ".." in Path(entry.name).parts:
                        raise RuntimeError("unsafe upstream archive")
                # Members are validated above, including links; support the
                # system Python on macOS as well as newer CI Pythons.
                source.extractall(extracted)
            args = (extracted / "args.gn").read_text()
            if "pdf_enable_v8 = false" not in args or "pdf_enable_xfa = false" not in args:
                raise RuntimeError("Unexpected active-content build")
            framework = extracted / "CPDFium.framework"
            headers = framework / "Headers"
            headers.mkdir(parents=True)
            for header in (extracted / "include").glob("*.h"):
                shutil.copy2(header, headers / header.name)
            (headers / "CPDFium.h").write_text("\n".join('#include "' + h.name + '"' for h in sorted(headers.glob("*.h"))) + "\n")
            modules = framework / "Modules"
            modules.mkdir()
            (modules / "module.modulemap").write_text('framework module CPDFium {\n  umbrella header "CPDFium.h"\n  export *\n}\n')
            binary = framework / "CPDFium"
            shutil.copy2(extracted / "lib/libpdfium.dylib", binary)
            subprocess.run(["install_name_tool", "-id", "@rpath/CPDFium.framework/CPDFium", str(binary)], check=True)
            platform_name = "iPhoneOS" if platform.startswith("device") else "iPhoneSimulator"
            (framework / "Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier="org.floeagent.pdfium", CFBundleName="CPDFium", CFBundleExecutable="CPDFium", CFBundlePackageType="FMWK", CFBundleShortVersionString="8035.0.0", CFBundleVersion="8035", CFBundleSupportedPlatforms=[platform_name], MinimumOSVersion="17.0")))
            command += ["-framework", str(framework)]
            if platform == "device-arm64":
                notices = ROOT / "FloeApp/Resources/PDFiumLicenses"
                notices.mkdir(exist_ok=True)
                shutil.copy2(extracted / "LICENSE", notices / "LICENSE")
                shutil.copytree(extracted / "licenses", notices / "licenses", dirs_exist_ok=True)
        destination.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(command + ["-output", str(destination)], check=True)
        stamp.write_text(json.dumps(PINS, sort_keys=True))


if __name__ == "__main__":
    main()
