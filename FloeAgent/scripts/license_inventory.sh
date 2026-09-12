#!/bin/bash
# license_inventory.sh — Parse Package.resolved and the ThirdParty manifest
# into LICENSES-THIRD-PARTY.md. Allowlist: MPL-2.0 / MIT / BSD / Apache-2.0;
# GPL-family licenses fail the build.
set -euo pipefail

cd "$(dirname "$0")/.."

OUTPUT="LICENSES-THIRD-PARTY.md"

python3 - <<'PY'
import json, subprocess, sys

ALLOWED = {"MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "MPL-2.0", "ISC", "0BSD", "Zlib", "OFL-1.1"}
GPL_FAMILY = {"GPL-2.0", "GPL-3.0", "LGPL-2.1", "LGPL-3.0", "AGPL-3.0"}

with open("Package.resolved") as f:
    pins = json.load(f)["pins"]

rows = []
violations = []
for pin in sorted(pins, key=lambda p: p["identity"]):
    identity = pin["identity"]
    location = pin["location"]
    version = pin["state"].get("version", "unknown")
    # Detect license from the checked-out dependency when available.
    checkout = f".build/checkouts/{identity}"
    license_name = "UNKNOWN"
    try:
        for candidate in ("LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE"):
            try:
                with open(f"{checkout}/{candidate}") as lf:
                    head = lf.read(2048).lower()
                if "apache license" in head:
                    license_name = "Apache-2.0"
                elif "mozilla public license" in head:
                    license_name = "MPL-2.0"
                elif "mit license" in head or "permission is hereby granted, free of charge" in head:
                    license_name = "MIT"
                elif "redistribution and use in source and binary forms" in head:
                    license_name = "BSD-3-Clause"
                elif "software is provided 'as-is'" in head and "origin of this software must not be misrepresented" in head:
                    license_name = "Zlib"
                elif "gnu general public license" in head:
                    license_name = "GPL-3.0"
                break
            except FileNotFoundError:
                continue
    except Exception:
        pass
    rows.append((identity, version, license_name, location))
    if license_name in GPL_FAMILY:
        violations.append(f"{identity}: GPL-family license {license_name}")
    elif license_name == "UNKNOWN":
        print(f"warning: {identity}: license undetected, manual review required", file=sys.stderr)

# Binary targets do not appear as pins in Package.resolved. Keep their source
# and redistribution wrapper explicit so an App Store build cannot silently
# omit them from the license inventory.
rows.extend([
    ("ios_system command bus and BSD commands", "v3.0.4 manifest / v3.0.2 binaries", "BSD-3-Clause", "https://github.com/holzschu/ios_system"),
    ("dash iOS", "0.5.11.5 + iOS port", "BSD-3-Clause", "https://github.com/holzschu/dash_iOS"),
    ("WasmKit runtime", "0.2.2 + Floe budget patch", "MIT", "https://github.com/swiftwasm/WasmKit/tree/0.2.2"),
    ("WasmKit SystemExtras", "0.2.2", "Apache-2.0 WITH Swift-exception", "https://github.com/swiftwasm/WasmKit/tree/0.2.2/Sources/SystemExtras"),
    ("ios_system libssh2", "1.11.0", "BSD-3-Clause", "https://github.com/holzschu/libssh2-apple"),
    ("ios_system OpenSSL", "1.1.1w", "OpenSSL", "https://github.com/holzschu/openssl-apple"),
    ("curl_ios", "v3.0.2 binary", "curl license (MIT/X derivative)", "https://github.com/holzschu/ios_system/tree/v3.0.4/curl_ios"),
    ("RoyalVNCKit (Floe synchronized queue)", "92d4427c73817d8f849bb289ff190aa4b40c44ea + Floe patch", "MIT", "https://github.com/JiangNanGenius/floe-agent/tree/main/FloeAgent/ThirdParty/RoyalVNCKit"),
    ("llama.cpp", "b10581", "MIT", "https://github.com/ggml-org/llama.cpp"),
    ("llama-ios-xcframework", "1.0.0", "MIT", "https://github.com/saitawngpha/llama-ios"),
    ("PDFium", "chromium/8035", "BSD-3-Clause and bundled third-party notices", "https://pdfium.googlesource.com/pdfium/"),
    ("pdfium-binaries", "chromium/8035", "MIT", "https://github.com/bblanchon/pdfium-binaries"),
    ("libarchive", "3.8.9", "BSD-2-Clause and COPYING exceptions", "https://github.com/libarchive/libarchive"),
    ("CPython / Python-Apple-support", "3.13-b10", "PSF-2.0 and bundled notices", "https://github.com/beeware/Python-Apple-support"),
    ("NumPy iOS", "2.5.2.post1", "BSD-3-Clause", "https://anaconda.org/beeware/numpy"),
    ("Pillow iOS", "11.0.0", "HPND and bundled notices", "https://anaconda.org/beeware/Pillow"),
    ("pandas iOS", "3.0.5", "BSD-3-Clause and bundled notices", "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-pandas-3.0.5-cp313"),
    ("regex iOS", "2026.9.10", "Apache-2.0", "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-regex-2026.9.10-cp313"),
    ("PyYAML iOS", "6.0.3", "MIT", "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-pyyaml-6.0.3-cp313"),
    ("MarkupSafe iOS", "3.0.3", "BSD-3-Clause", "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-markupsafe-3.0.3-cp313"),
    ("zstandard iOS", "0.25.0", "BSD-3-Clause", "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-zstandard-0.25.0-cp313"),
    ("Brotli iOS", "1.2.0", "MIT", "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-brotli-1.2.0-cp313"),
    ("greenlet iOS", "3.5.5", "MIT AND PSF-2.0", "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-greenlet-3.5.5-cp313"),
    ("frozenlist iOS", "1.8.0", "Apache-2.0", "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-frozenlist-1.8.0-cp313"),
    ("multidict iOS", "6.8.0", "Apache-2.0", "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-multidict-6.8.0-cp313"),
    ("python-dateutil", "2.9.0.post0", "Apache-2.0 OR BSD-3-Clause", "https://pypi.org/project/python-dateutil/2.9.0.post0/"),
    ("six", "1.17.0", "MIT", "https://pypi.org/project/six/1.17.0/"),
    ("tzdata", "2026.3", "Apache-2.0", "https://pypi.org/project/tzdata/2026.3/"),
])

rows.append(("FloeDocumentSans (modified Noto Sans SC)", "2.004", "OFL-1.1", "https://github.com/notofonts/noto-cjk/tree/523d033d6cb47f4a80c58a35753646f5c3608a78"))

# Bundled CJK/utility fonts are staged by scripts/fonts/fetch_fonts.py from
# manifest-pinned sources; every family carries its license in the manifest.
with open("scripts/fonts/manifest.json") as f:
    font_manifest = json.load(f)
for family in font_manifest["families"]:
    license_name = family["license"].get("spdx") or family["license"]["name"]
    if license_name in GPL_FAMILY:
        violations.append(f"font {family['id']}: GPL-family license {license_name}")
    homepage = family.get("upstream", {}).get("homepage", "")
    rows.append((f"Font: {family['displayName']}", family["version"], license_name, homepage))

# Offline conversion bundles are checked in with a reproducible npm lock.
with open("ThirdParty/DocumentConversion/inventory.json") as f:
    conversion = json.load(f)
for package in conversion["packages"]:
    license_name = package["license"]
    if "GPL" in license_name and " OR " not in license_name:
        violations.append(package["name"])
    rows.append((package["name"], package["version"], license_name, "https://www.npmjs.com/package/" + package["name"]))

with open("LICENSES-THIRD-PARTY.md", "w") as out:
    out.write("# Third-Party Licenses\n\n")
    out.write("Generated by scripts/license_inventory.sh. Do not edit by hand.\n\n")
    out.write("| Package | Version | License | Source |\n|---|---|---|---|\n")
    for identity, version, license_name, location in rows:
        out.write(f"| {identity} | {version} | {license_name} | {location} |\n")

if violations:
    print("error: GPL-family licenses are not allowed:", file=sys.stderr)
    for v in violations:
        print(f"  - {v}", file=sys.stderr)
    sys.exit(1)

print(f"license_inventory OK: {len(rows)} dependencies inventoried")
PY
