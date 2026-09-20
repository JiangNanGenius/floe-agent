#!/usr/bin/env python3
"""Build pinned static XML dependencies; never use Homebrew/macOS libraries."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request

SOURCES = (
    ("libxml2", "2.14.6", "2.14", "7ce458a0affeb83f0b55f1f4f9e0e55735dbfc1a9de124ee86fb4a66b597203a"),
    ("libxslt", "1.1.45", "1.1", "9acfe68419c4d06a45c550321b3212762d92f41465062ca4ea19e632ee5d216e"),
)


def run(*arguments):
    subprocess.run(arguments, check=True)


def prepare(project):
    root = project / "floe-native"
    root.mkdir(exist_ok=True)
    evidence = []
    setup = project / "setup.py"
    text = setup.read_text()
    needle = "'lxml.includes': ["
    if text.count(needle) != 1:
        raise ValueError("Unreviewed lxml package data layout")
    setup.write_text(text.replace(needle, needle + "\n            'floe_native_licenses/*.txt',"))
    for name, version, series, digest in SOURCES:
        url = f"https://download.gnome.org/sources/{name}/{series}/{name}-{version}.tar.xz"
        archive = root / f"{name}.tar.xz"
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read(20_000_001)
        if len(data) > 20_000_000 or hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f"Source verification failed: {name}")
        archive.write_bytes(data)
        with tarfile.open(archive) as bundle:
            bundle.extractall(root, filter="data")
        evidence.append(dict(name=name, version=version, url=url, sha256=digest))

    for sdk in ("iphoneos", "iphonesimulator"):
        prefix = root / sdk
        for name, version, _, _ in SOURCES:
            source = root / f"{name}-{version}"
            build = root / f"build-{sdk}-{name}"
            options = ["-DCMAKE_SYSTEM_NAME=iOS", f"-DCMAKE_OSX_SYSROOT={sdk}",
                       "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0",
                       "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF",
                       "-DCMAKE_POSITION_INDEPENDENT_CODE=ON", f"-DCMAKE_INSTALL_PREFIX={prefix}",
                       f"-DCMAKE_PREFIX_PATH={prefix}"]
            feature = "LIBXML2" if name == "libxml2" else "LIBXSLT"
            options += [f"-D{feature}_WITH_{part}=OFF" for part in ("PYTHON", "PROGRAMS", "TESTS", "MODULES")]
            if name == "libxml2":
                options += ["-DLIBXML2_WITH_ICONV=ON", "-DLIBXML2_WITH_ZLIB=ON", "-DLIBXML2_WITH_LZMA=OFF", "-DLIBXML2_WITH_ICU=OFF"]
            else:
                # iOS cross-root lookup does not search an arbitrary install
                # prefix. Bind the package to this slice's generated config.
                xml_config = prefix / "lib/cmake/libxml2-2.14.6"
                if not (xml_config / "libxml2-config.cmake").is_file():
                    raise ValueError("Target libxml2 CMake configuration is missing")
                options += [f"-DLibXml2_DIR={xml_config}"]
            run("cmake", "-S", str(source), "-B", str(build), "-G", "Ninja", *options)
            run("cmake", "--build", str(build), "--parallel", "3")
            run("cmake", "--install", str(build))
            # Preserve the exact linked dependency licenses in lxml's wheel data.
            licenses = project / "src/lxml/includes/floe_native_licenses"
            licenses.mkdir(exist_ok=True)
            for license_name in ("Copyright", "COPYING", "COPYING.LIB"):
                if (source / license_name).is_file():
                    shutil.copy2(source / license_name, licenses / f"{name}-{license_name}.txt")
        for library in ("libxml2.a", "libxslt.a", "libexslt.a"):
            if not (prefix / "lib" / library).is_file():
                raise ValueError(f"Missing target library: {sdk}/{library}")
    (root / "sources.json").write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    prepare(Path(sys.argv[1]).resolve())
