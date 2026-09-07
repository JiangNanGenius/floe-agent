#!/usr/bin/env python3
"""Build pinned BSD libarchive for bounded on-device RAR reads (no CLI)."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
VERSION = "3.8.9"
SHA = "f5a6539059cf5e597dbeda37bfa4874b1e8dea063c8d93bf85a2b44af90a5bd4"


def main():
    destination = ROOT / "Vendor/LibArchive/LibArchive.xcframework"
    stamp = destination.parent / "pins.json"
    pins = dict(version=VERSION, sha256=SHA, architectures=["iphoneos-arm64", "iphonesimulator-arm64"])
    if destination.exists() and stamp.exists() and json.loads(stamp.read_text()) == pins:
        print("Pinned libarchive XCFramework already prepared")
        return
    if destination.exists():
        raise RuntimeError("Existing libarchive differs from pins; explicitly remove its generated directory first")
    cache = Path(tempfile.gettempdir()) / "floe-libarchive"
    cache.mkdir(exist_ok=True)
    archive = cache / f"libarchive-{VERSION}.tar.gz"
    if not archive.exists():
        urllib.request.urlretrieve(f"https://github.com/libarchive/libarchive/releases/download/v{VERSION}/libarchive-{VERSION}.tar.gz", archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA:
        raise RuntimeError("libarchive checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="floe-libarchive-build-") as temporary:
        temporary = Path(temporary)
        with tarfile.open(archive) as source:
            for item in source.getmembers():
                if not (item.isfile() or item.isdir()) or item.name.startswith("/") or ".." in Path(item.name).parts:
                    raise RuntimeError("Unsafe upstream archive")
            source.extractall(temporary)
        source = temporary / f"libarchive-{VERSION}"
        command = ["xcodebuild", "-create-xcframework"]
        for sdk in ["iphoneos", "iphonesimulator"]:
            build = temporary / sdk
            sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
            flags = ["-DENABLE_" + option + "=OFF" for option in ["TEST", "TAR", "CPIO", "CAT", "UNZIP", "OPENSSL", "MBEDTLS", "NETTLE", "LIBB2", "LZMA", "LZO", "LZ4", "ZSTD", "BZip2", "LIBXML2", "EXPAT", "PCREPOSIX", "PCRE2POSIX", "ICONV", "ACL", "XATTR"]]
            subprocess.run(["cmake", "-S", str(source), "-B", str(build), "-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0", "-DCMAKE_OSX_SYSROOT=" + sdk_path, "-DCMAKE_BUILD_TYPE=Release", "-DENABLE_ZLIB=ON", "-DBUILD_SHARED_LIBS=OFF"] + flags, check=True)
            subprocess.run(["cmake", "--build", str(build), "--target", "archive_static", "--parallel", "2"], check=True)
            framework = build / "CArchive.framework"
            headers = framework / "Headers"
            headers.mkdir(parents=True)
            for name in ["archive.h", "archive_entry.h"]:
                shutil.copy2(source / "libarchive" / name, headers / name)
            (headers / "CArchive.h").write_text('#include "archive.h"\n#include "archive_entry.h"\n')
            (framework / "Modules").mkdir()
            (framework / "Modules/module.modulemap").write_text('framework module CArchive { umbrella header "CArchive.h" export * }\n')
            shutil.copy2(build / "libarchive/libarchive.a", framework / "CArchive")
            (framework / "Info.plist").write_bytes(plistlib.dumps(dict(CFBundleIdentifier="org.floeagent.libarchive", CFBundleName="CArchive", CFBundleExecutable="CArchive", CFBundlePackageType="FMWK", CFBundleShortVersionString=VERSION, CFBundleVersion="389", CFBundleSupportedPlatforms=["iPhoneOS" if sdk == "iphoneos" else "iPhoneSimulator"], MinimumOSVersion="17.0")))
            command += ["-framework", str(framework)]
        destination.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(command + ["-output", str(destination)], check=True)
        notices = ROOT / "FloeApp/Resources/LibArchiveLicenses"
        notices.mkdir(exist_ok=True)
        shutil.copy2(source / "COPYING", notices / "COPYING")
        stamp.write_text(json.dumps(pins, sort_keys=True))


if __name__ == "__main__":
    main()
