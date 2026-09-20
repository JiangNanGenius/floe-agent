#!/bin/bash
# license_inventory.sh — Parse Package.resolved and the ThirdParty manifest
# into LICENSES-THIRD-PARTY.md. Allowlist: MPL-2.0 / MIT / BSD / Apache-2.0;
# GPL-family licenses fail the build.
set -euo pipefail

cd "$(dirname "$0")/.."

OUTPUT="LICENSES-THIRD-PARTY.md"

python3 - <<'PY'
import json, subprocess, sys
sys.path.insert(0, "scripts")
from resolved_pins import resolved_pins, application_pins, verify_resolution

ALLOWED = {"MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "MPL-2.0", "ISC", "0BSD", "Zlib", "OFL-1.1"}
GPL_FAMILY = {"GPL-2.0", "GPL-3.0", "LGPL-2.1", "LGPL-3.0", "AGPL-3.0"}

with open("Package.resolved") as f:
    pins = resolved_pins(json.load(f))
committed = json.loads(subprocess.check_output(
    ["git", "show", "HEAD:FloeAgent/Package.resolved"], text=True))
with open("project.yml") as f:
    pins = verify_resolution(pins, resolved_pins(committed), application_pins(f.read()))

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
    ("VideoEditorKit", "c917b1e99ddc631b754a43704c05dfe3836e8183", "MIT", "https://github.com/didisouzacosta/VideoEditorKit"),
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
    ("TinyEMU / FloeTinyEMU engine", "2019-12-21 + Floe patches", "MIT", "https://bellard.org/tinyemu/tinyemu-2019-12-21.tar.gz"),
    ("TinyEMU slirp (compiled subset)", "2019-12-21", "BSD-2-Clause (Danny Gasparovski files) and BSD-3-Clause (UC Regents files)", "https://bellard.org/tinyemu/tinyemu-2019-12-21.tar.gz"),
    ("PDFium", "chromium/8035", "BSD-3-Clause and bundled third-party notices", "https://pdfium.googlesource.com/pdfium/"),
    ("pdfium-binaries", "chromium/8035", "MIT", "https://github.com/bblanchon/pdfium-binaries"),
    ("libarchive", "3.8.9", "BSD-2-Clause and COPYING exceptions", "https://github.com/libarchive/libarchive"),
    ("Floe Linux guest component (Debian 13 riscv64 userland, kernel, bbl, static glibc; downloadable image)", "pinned catalog image", "Floe runner MPL-2.0; Debian package licenses; kernel GPL-2.0; bbl BSD-3-Clause; static glibc LGPL-2.1", "https://bellard.org/tinyemu/ plus the pinned Floe image manifest provenance"),
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

# Fixed offline IDE distributions; their original notices ship with the App.
rows.extend([
    ("OpenSumi CodeBlitz", "2.4.6", "MIT", "https://github.com/opensumi/codeblitz"),
    ("OpenSumi Monaco", "3.6.5-next-1766394426.0", "MIT", "https://github.com/opensumi/monaco-editor"),
    ("vscode-oniguruma", "1.5.1", "MIT and Oniguruma notices", "https://github.com/microsoft/vscode-oniguruma"),
    ("Microsoft Codicons", "0.0.35", "CC-BY-4.0", "https://github.com/microsoft/vscode-codicons"),
])

with open("LICENSES-THIRD-PARTY.md", "w") as out:
    out.write("# Third-Party Licenses\n\n")
    out.write("Generated by scripts/license_inventory.sh. Do not edit by hand.\n\n")
    out.write("| Package | Version | License | Source |\n|---|---|---|---|\n")
    for identity, version, license_name, location in rows:
        out.write(f"| {identity} | {version} | {license_name} | {location} |\n")
    out.write("\n" + open("FloeApp/Resources/IDE/NOTICE.md").read())

if violations:
    print("error: GPL-family licenses are not allowed:", file=sys.stderr)
    for v in violations:
        print(f"  - {v}", file=sys.stderr)
    sys.exit(1)

print(f"license_inventory OK: {len(rows)} dependencies inventoried")
PY
