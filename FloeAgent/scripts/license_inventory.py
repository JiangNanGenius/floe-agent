#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Generate Floe's third-party declaration from its actual pins and licenses.

Single source of truth for the in-app and repository license declaration. The
generator reads, in this order:

* ``Package.resolved`` (host lock, verified against ``HEAD`` and the Xcode app
  pins in ``project.yml``) for every Swift package;
* the resolved checkout license files under ``.build/checkouts`` for the
  license text itself — never a hand-maintained table;
* repository pins for the vendored engines and runtimes (``ThirdParty/**``
  locks, font manifest, conversion inventory, office engine lock);
* ``project.yml`` resources to prove that every notice declared here really is
  copied into the app bundle at the path the app reads.

Artifacts (relative to ``FloeAgent/``)::

    LICENSES-THIRD-PARTY.md                                release table
    FloeApp/Resources/Licenses/third-party-inventory.json  packaged manifest
    FloeApp/Resources/Licenses/libgit2-COPYING.txt         linked libgit2 text
    scripts/license-evidence.json                          detection evidence

``--check`` is read-only: it recomputes every artifact in memory, compares the
committed bytes, verifies the recorded license evidence hashes, the bundle
mapping, the localization keys and the GPL gate, and exits non-zero on drift.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent  # FloeAgent/
REPO = ROOT.parent  # repository root

sys.path.insert(0, str(HERE))
from resolved_pins import resolved_pins, application_pins, verify_resolution  # noqa: E402

MARKDOWN = ROOT / "LICENSES-THIRD-PARTY.md"
MANIFEST = ROOT / "FloeApp/Resources/Licenses/third-party-inventory.json"
EVIDENCE = HERE / "license-evidence.json"
XSTRINGS = ROOT / "FloeApp/Resources/Localizable.xcstrings"
PROJECT_YML = ROOT / "project.yml"
FONTS_MANIFEST = HERE / "fonts/manifest.json"
CONVERSION_INVENTORY = ROOT / "ThirdParty/DocumentConversion/inventory.json"
IDE_NOTICE = ROOT / "FloeApp/Resources/IDE/NOTICE.md"
LIBGIT2_COPYING = ROOT / "FloeApp/Resources/Licenses/libgit2-COPYING.txt"
CHECKOUTS = ROOT / ".build/checkouts"
PACKAGE_RESOLVED = ROOT / "Package.resolved"

REPOSITORY = "https://github.com/JiangNanGenius/floe-agent"
INVENTORY_REPOSITORY_PATH = "FloeAgent/LICENSES-THIRD-PARTY.md"
MANIFEST_BUNDLE_PATH = "Licenses/third-party-inventory.json"
LIBGIT2_COPYING_BUNDLE_PATH = "Licenses/libgit2-COPYING.txt"
LIBGIT2_EVIDENCE = ".build/checkouts/libgit2/COPYING"

LICENSE_FILE_CANDIDATES = (
    "LICENSE",
    "LICENSE.md",
    "LICENSE.txt",
    "LICENCE",
    "COPYING",
    "COPYING.txt",
    "COPYING.md",
)

# SPDX expressions accepted without review. Everything GPL/LGPL/AGPL fails the
# build unless it is one of the explicitly recorded exception strings below —
# the app must never gain a copyleft dependency by accident.
ALLOWED_EXACT = {
    "MIT",
    "MIT AND PSF-2.0",
    "Apache-2.0",
    "Apache-2.0 WITH Swift-exception",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "BSD",
    "ISC",
    "0BSD",
    "Zlib",
    "OFL-1.1",
    "CC-BY-4.0",
    "MPL-2.0",
    "OpenSSL",
    "PSF-2.0",
    "HPND",
    "PHP-3.01",
    "BSD-2-Clause and COPYING exceptions",
    "BlueOak-1.0.0",
    "(MPL-2.0 OR Apache-2.0)",
    "(MIT AND Zlib)",
    "Apache-2.0 OR BSD-3-Clause",
    "curl license (MIT/X derivative)",
}
# Explicit, individually reviewed exceptions. Each still prints a notice.
EXCEPTIONS = {
    "GPL-2.0 WITH libgit2 linking exception": (
        "libgit2's linking exception permits unlimited linking into this "
        "application; the GPL-2.0 text ships in the app bundle"
    ),
    "LGPL-2.1 with OCCT exception": (
        "OCCT's LGPL-2.1 is bundled as a WebAssembly viewer with its exception "
        "and complete texts, not linked into the app binary"
    ),
    "Debian package licenses; kernel GPL-2.0; bbl BSD-3-Clause; static glibc LGPL-2.1": (
        "the Linux guest is a separately distributed downloadable image; its "
        "source and license texts are recorded in the pinned image manifest"
    ),
}

# Localization keys owned by this generator (the app reads them but they are
# not part of the generated JSON, so the check validates them here).
CHROME_KEYS = (
    "settings.diagnostics.licenses",
    "settings.diagnostics.privacy.note",
    "settings.diagnostics.tinyemu_licenses.footer",
    "settings.diagnostics.tinyemu_licenses.unavailable",
    "settings.licenses.bundled.footer",
    "settings.licenses.bundled.header",
    "settings.licenses.count",
    "settings.licenses.document.font",
    "settings.licenses.inventory.footer",
    "settings.licenses.inventory.header",
    "settings.licenses.inventory.link",
    "settings.licenses.inventory.search",
    "settings.licenses.inventory.title",
    "settings.licenses.manifest_missing",
    "settings.licenses.notes.header",
    "settings.licenses.repository_license",
    "settings.licenses.this_app",
)

# Section ids and their English fallbacks; keys are settings.licenses.section.<id>.
SECTIONS = (
    ("engines", "Engines and runners"),
    ("office", "Office engine"),
    ("swift", "Swift packages"),
    ("python", "Python runtimes and packages"),
    ("conversion", "Document conversion"),
    ("web", "Bundled web and data scripts"),
    ("documents", "Documents and archives"),
    ("engineering", "Engineering viewers"),
    ("speech", "Speech"),
    ("ide", "Offline IDE"),
    ("media", "Image and media"),
    ("fonts", "Bundled fonts"),
)

KINDS = {
    "full_text": "settings.licenses.kind.full_text",
    "notices": "settings.licenses.kind.notices",
    "provenance": "settings.licenses.kind.provenance",
    "grant": "settings.licenses.kind.grant",
}

NOTES = (
    (
        "libgit2",
        "libgit2 is licensed under GPL-2.0 with a linking exception that "
        "explicitly permits linking it into this application. The complete "
        "GPL-2.0 text ships in this app as Licenses/libgit2-COPYING.txt, and "
        "libgit2's source is the pinned repository in the component list.",
    ),
    (
        "occt",
        "Open CASCADE Technology and occt-import-js are LGPL-2.1 with the "
        "OCCT exception; their complete texts and the exception ship in the "
        "app bundle.",
    ),
    (
        "guest_image",
        "The Linux guest is a separately distributed downloadable image built "
        "from Debian 13 riscv64 packages plus a pinned kernel, bbl and static "
        "glibc. Its source and license texts are recorded in the pinned image "
        "manifest; they are not linked into the app binary.",
    ),
    (
        "office",
        "The native Office engine is Collabora Online (LibreOffice-based) at "
        "the pinned commit, MPL-2.0. The qualified engine bundle retains its "
        "upstream third-party license files; the complete engine notice "
        "inventory remains a separate office qualification gate.",
    ),
    (
        "verification",
        "Every Swift package license was read from the resolved checkout "
        "license file. scripts/license-evidence.json records the exact file "
        "and sha256, and this generator re-verifies them when a checkout is "
        "present.",
    ),
)

# (name, version, license, source, section, noteKey)
STATIC_COMPONENTS = (
    # Engineering engines and runtimes.
    (
        "TinyEMU / FloeTinyEMU engine",
        "2019-12-21 + Floe patches",
        "MIT",
        "https://bellard.org/tinyemu/tinyemu-2019-12-21.tar.gz",
        "engines",
        None,
    ),
    (
        "TinyEMU slirp (compiled subset)",
        "2019-12-21",
        "BSD-2-Clause (Gasparovski files) and BSD-3-Clause (UC Regents files)",
        "https://bellard.org/tinyemu/tinyemu-2019-12-21.tar.gz",
        "engines",
        None,
    ),
    (
        "Floe Linux guest component (Debian 13 riscv64 userland, kernel, bbl, static glibc)",
        "pinned catalog image",
        "Debian package licenses; kernel GPL-2.0; bbl BSD-3-Clause; static glibc LGPL-2.1",
        "https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-guest-20260920.1",
        "engines",
        "settings.licenses.note.guest_image",
    ),
    (
        "VideoEditorKit",
        "c917b1e99ddc631b754a43704c05dfe3836e8183",
        "MIT",
        "https://github.com/didisouzacosta/VideoEditorKit",
        "engines",
        None,
    ),
    (
        "FloeShellEngine (BSD shell core)",
        "upstream + Floe patch",
        "BSD-3-Clause",
        "https://github.com/holzschu/ios_system",
        "engines",
        None,
    ),
    (
        "ios_system command bus and BSD commands",
        "v3.0.4 manifest / v3.0.2 binaries",
        "BSD-3-Clause",
        "https://github.com/holzschu/ios_system",
        "engines",
        None,
    ),
    (
        "dash iOS",
        "0.5.11.5 + iOS port",
        "BSD-3-Clause",
        "https://github.com/holzschu/dash_iOS",
        "engines",
        None,
    ),
    (
        "ios_system libssh2",
        "1.11.0",
        "BSD-3-Clause",
        "https://github.com/holzschu/libssh2-apple",
        "engines",
        None,
    ),
    (
        "ios_system OpenSSL",
        "1.1.1w",
        "OpenSSL",
        "https://github.com/holzschu/openssl-apple",
        "engines",
        None,
    ),
    (
        "curl_ios",
        "v3.0.2 binary",
        "curl license (MIT/X derivative)",
        "https://github.com/holzschu/ios_system/tree/v3.0.4/curl_ios",
        "engines",
        None,
    ),
    (
        "FreeRDP bridge",
        "3.31.1",
        "Apache-2.0",
        "https://github.com/FreeRDP/FreeRDP",
        "engines",
        None,
    ),
    (
        "WasmKit runtime",
        "0.2.2 + Floe budget patch",
        "MIT",
        "https://github.com/swiftwasm/WasmKit/tree/0.2.2",
        "engines",
        None,
    ),
    (
        "WasmKit SystemExtras",
        "0.2.2",
        "Apache-2.0 WITH Swift-exception",
        "https://github.com/swiftwasm/WasmKit/tree/0.2.2/Sources/SystemExtras",
        "engines",
        None,
    ),
    (
        "PHP WASI runtime",
        "8.2.33",
        "PHP-3.01",
        "https://www.php.net/distributions/php-8.2.33.tar.gz",
        "engines",
        None,
    ),
    (
        "Lua WASI runtime",
        "5.4.8",
        "MIT",
        "https://www.lua.org/ftp/lua-5.4.8.tar.gz",
        "engines",
        None,
    ),
    (
        "Ruby WASI runtime",
        "3.4.1 (ruby.wasm 2.10.1)",
        "MIT (ruby.wasm tooling) and Ruby license (BSD-2-Clause dual)",
        "https://github.com/ruby/ruby.wasm",
        "engines",
        None,
    ),
    (
        "RoyalVNCKit (Floe synchronized queue)",
        "92d4427c73817d8f849bb289ff190aa4b40c44ea + Floe patch",
        "MIT",
        "https://github.com/JiangNanGenius/floe-agent/tree/main/FloeAgent/ThirdParty/RoyalVNCKit",
        "engines",
        None,
    ),
    (
        "llama.cpp",
        "b10581",
        "MIT",
        "https://github.com/ggml-org/llama.cpp",
        "engines",
        None,
    ),
    (
        "llama-ios-xcframework",
        "1.0.0 (upstream b9754 simulator slice)",
        "MIT",
        "https://github.com/saitawngpha/llama-ios",
        "engines",
        None,
    ),
    (
        "PDFium",
        "chromium/8035",
        "BSD-3-Clause and bundled third-party notices",
        "https://pdfium.googlesource.com/pdfium/",
        "engines",
        None,
    ),
    (
        "pdfium-binaries",
        "chromium/8035",
        "MIT",
        "https://github.com/bblanchon/pdfium-binaries",
        "engines",
        None,
    ),
    (
        "libarchive",
        "3.8.9",
        "BSD-2-Clause and COPYING exceptions",
        "https://github.com/libarchive/libarchive",
        "engines",
        None,
    ),
    # Office engine (Collabora Online) and its pinned external headers.
    (
        "Collabora Online native Office engine (LibreOffice-based)",
        "27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc",
        "MPL-2.0",
        "https://github.com/CollaboraOnline/online.mirror",
        "office",
        "settings.licenses.note.office",
    ),
    (
        "mdds (Office chart filter headers)",
        "3.1.0",
        "MIT",
        "https://gitlab.com/mdds/mdds/-/tree/3.1.0",
        "office",
        None,
    ),
    (
        "frozen (Office JSON headers)",
        "1.2.0",
        "Apache-2.0",
        "https://github.com/serge-sans-paille/frozen",
        "office",
        None,
    ),
    # Python runtime and data packages.
    (
        "CPython / Python-Apple-support",
        "3.13-b10",
        "PSF-2.0 and bundled notices",
        "https://github.com/beeware/Python-Apple-support",
        "python",
        None,
    ),
    (
        "NumPy iOS",
        "2.5.2.post1",
        "BSD-3-Clause",
        "https://anaconda.org/beeware/numpy",
        "python",
        None,
    ),
    (
        "Pillow iOS",
        "11.0.0",
        "HPND and bundled notices",
        "https://anaconda.org/beeware/Pillow",
        "python",
        None,
    ),
    (
        "pandas iOS",
        "3.0.5",
        "BSD-3-Clause and bundled notices",
        "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-pandas-3.0.5-cp313",
        "python",
        None,
    ),
    (
        "lxml iOS",
        "6.1.3",
        "BSD-3-Clause, PSF-2.0 and bundled notices",
        "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-lxml-6.1.3-cp313",
        "python",
        None,
    ),
    (
        "libxml2 (lxml static dependency)",
        "2.14.6",
        "MIT and bundled notices",
        "https://gitlab.gnome.org/GNOME/libxml2",
        "python",
        None,
    ),
    (
        "libxslt/libexslt (lxml static dependency)",
        "1.1.45",
        "MIT and bundled notices",
        "https://gitlab.gnome.org/GNOME/libxslt",
        "python",
        None,
    ),
    (
        "python-docx",
        "1.2.0",
        "MIT",
        "https://pypi.org/project/python-docx/1.2.0/",
        "python",
        None,
    ),
    (
        "python-pptx",
        "1.0.2",
        "MIT",
        "https://pypi.org/project/python-pptx/1.0.2/",
        "python",
        None,
    ),
    (
        "regex iOS",
        "2026.9.10",
        "Apache-2.0",
        "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-regex-2026.9.10-cp313",
        "python",
        None,
    ),
    (
        "PyYAML iOS",
        "6.0.3",
        "MIT",
        "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-pyyaml-6.0.3-cp313",
        "python",
        None,
    ),
    (
        "MarkupSafe iOS",
        "3.0.3",
        "BSD-3-Clause",
        "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-markupsafe-3.0.3-cp313",
        "python",
        None,
    ),
    (
        "zstandard iOS",
        "0.25.0",
        "BSD-3-Clause",
        "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-zstandard-0.25.0-cp313",
        "python",
        None,
    ),
    (
        "Brotli iOS",
        "1.2.0",
        "MIT",
        "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-brotli-1.2.0-cp313",
        "python",
        None,
    ),
    (
        "greenlet iOS",
        "3.5.5",
        "MIT AND PSF-2.0",
        "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-greenlet-3.5.5-cp313",
        "python",
        None,
    ),
    (
        "frozenlist iOS",
        "1.8.0",
        "Apache-2.0",
        "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-frozenlist-1.8.0-cp313",
        "python",
        None,
    ),
    (
        "multidict iOS",
        "6.8.0",
        "Apache-2.0",
        "https://github.com/JiangNanGenius/floe-agent/releases/tag/runtime-multidict-6.8.0-cp313",
        "python",
        None,
    ),
    (
        "python-dateutil",
        "2.9.0.post0",
        "Apache-2.0 OR BSD-3-Clause",
        "https://pypi.org/project/python-dateutil/2.9.0.post0/",
        "python",
        None,
    ),
    (
        "six",
        "1.17.0",
        "MIT",
        "https://pypi.org/project/six/1.17.0/",
        "python",
        None,
    ),
    (
        "tzdata",
        "2026.3",
        "Apache-2.0",
        "https://pypi.org/project/tzdata/2026.3/",
        "python",
        None,
    ),
    # Bundled JavaScriptCore UMD packages (FloeExecution/JSPackages.swift).
    (
        "lodash (JavaScriptCore package)",
        "bundled UMD build",
        "MIT",
        "https://www.npmjs.com/package/lodash",
        "web",
        None,
    ),
    (
        "dayjs (JavaScriptCore package)",
        "bundled UMD build",
        "MIT",
        "https://www.npmjs.com/package/dayjs",
        "web",
        None,
    ),
    (
        "marked (JavaScriptCore package)",
        "12.0.0",
        "MIT",
        "https://www.npmjs.com/package/marked",
        "web",
        None,
    ),
    (
        "uuid (JavaScriptCore package)",
        "8.3.2",
        "MIT",
        "https://www.npmjs.com/package/uuid",
        "web",
        None,
    ),
    (
        "zod (JavaScriptCore package)",
        "bundled UMD build",
        "MIT",
        "https://www.npmjs.com/package/zod",
        "web",
        None,
    ),
    (
        "pdf-lib (JavaScriptCore package)",
        "1.17.1",
        "MIT",
        "https://www.npmjs.com/package/pdf-lib",
        "web",
        None,
    ),
    # Engineering viewers explicitly listed in the bundled notices.
    (
        "@simonwep/pickr",
        "1.9.0",
        "MIT",
        "https://github.com/simonwep/pickr",
        "engineering",
        None,
    ),
    (
        "dxf-viewer",
        "1.0.48",
        "MPL-2.0",
        "https://github.com/vagran/dxf-viewer",
        "engineering",
        None,
    ),
    (
        "gerber-to-svg",
        "4.2.8",
        "MIT",
        "https://github.com/tracespace/tracespace",
        "engineering",
        None,
    ),
    (
        "Open CASCADE Technology (OCCT)",
        "pinned by EngineeringViewers",
        "LGPL-2.1 with OCCT exception",
        "https://github.com/Open-Cascade-SAS/OCCT",
        "engineering",
        "settings.licenses.note.occt",
    ),
    (
        "occt-import-js",
        "pinned by EngineeringViewers",
        "LGPL-2.1 with OCCT exception",
        "https://github.com/kovacsv/occt-import-js",
        "engineering",
        "settings.licenses.note.occt",
    ),
    # Offline IDE distributions.
    (
        "OpenSumi CodeBlitz",
        "2.4.6",
        "MIT",
        "https://github.com/opensumi/codeblitz",
        "ide",
        None,
    ),
    (
        "OpenSumi Monaco",
        "3.6.5-next-1766394426.0",
        "MIT",
        "https://github.com/opensumi/monaco-editor",
        "ide",
        None,
    ),
    (
        "vscode-oniguruma",
        "1.5.1",
        "MIT and Oniguruma notices",
        "https://github.com/microsoft/vscode-oniguruma",
        "ide",
        None,
    ),
    (
        "Microsoft Codicons",
        "0.0.35",
        "CC-BY-4.0",
        "https://github.com/microsoft/vscode-codicons",
        "ide",
        None,
    ),
    # Media.
    (
        "ZLImageEditor",
        "upstream + Floe integration",
        "MIT",
        "https://github.com/longitachi/ZLPhotoBrowser",
        "media",
        None,
    ),
    (
        "FloeDocumentSans (modified Noto Sans SC)",
        "2.004",
        "OFL-1.1",
        "https://github.com/notofonts/noto-cjk/tree/523d033d6cb47f4a80c58a35753646f5c3608a78",
        "media",
        None,
    ),
)

# (id, repositoryPath, bundlePath, titleKey, title, titleArgument, license, kind, required, section)
DOCUMENTS = (
    (
        "tinyemu",
        "FloeApp/Resources/TinyEMU-LICENSES.txt",
        "TinyEMU-LICENSES.txt",
        "settings.licenses.document.tinyemu.title",
        "TinyEMU 2019-12-21 and slirp",
        None,
        "MIT / BSD-2-Clause / BSD-3-Clause",
        "full_text",
        True,
        "engines",
    ),
    (
        "libgit2",
        "FloeApp/Resources/Licenses/libgit2-COPYING.txt",
        "Licenses/libgit2-COPYING.txt",
        "settings.licenses.document.libgit2.title",
        "libgit2",
        None,
        "GPL-2.0 with linking exception",
        "full_text",
        True,
        "engines",
    ),
    (
        "pdfium",
        "FloeApp/Resources/PDFiumLicenses/LICENSE",
        "PDFiumLicenses/LICENSE",
        "settings.licenses.document.pdfium.title",
        "PDFium",
        None,
        "BSD-3-Clause",
        "full_text",
        True,
        "documents",
    ),
    (
        "libarchive",
        "FloeApp/Resources/LibArchiveLicenses/COPYING",
        "LibArchiveLicenses/COPYING",
        "settings.licenses.document.libarchive.title",
        "libarchive",
        None,
        "BSD-2-Clause",
        "full_text",
        True,
        "documents",
    ),
    (
        "conversion-notices",
        "FloeApp/Resources/DocumentConversion/THIRD-PARTY-NOTICES.txt",
        "DocumentConversion/THIRD-PARTY-NOTICES.txt",
        "settings.licenses.document.conversion_third_party.title",
        "Offline document conversion",
        None,
        None,
        "notices",
        False,
        "conversion",
    ),
    (
        "conversion-fonts",
        "FloeApp/Resources/DocumentConversion/FONT-LICENSE.txt",
        "DocumentConversion/FONT-LICENSE.txt",
        "settings.licenses.document.conversion_fonts.title",
        "Conversion document fonts",
        None,
        None,
        "grant",
        False,
        "conversion",
    ),
    (
        "viewers-notices",
        "FloeApp/Resources/EngineeringViewers/THIRD_PARTY_NOTICES.txt",
        "EngineeringViewers/THIRD_PARTY_NOTICES.txt",
        "settings.licenses.document.viewers.title",
        "Engineering viewers",
        None,
        None,
        "notices",
        False,
        "engineering",
    ),
    (
        "cad-notices",
        "FloeApp/Resources/EngineeringViewers/CAD_NOTICES.txt",
        "EngineeringViewers/CAD_NOTICES.txt",
        "settings.licenses.document.cad.title",
        "Floe CAD engine",
        None,
        None,
        "notices",
        False,
        "engineering",
    ),
    (
        "occt",
        "FloeApp/Resources/EngineeringViewers/license.occt.txt",
        "EngineeringViewers/license.occt.txt",
        "settings.licenses.document.occt.title",
        "Open CASCADE Technology (OCCT)",
        None,
        "LGPL-2.1",
        "full_text",
        False,
        "engineering",
    ),
    (
        "occt-import-js",
        "FloeApp/Resources/EngineeringViewers/license.occt-import-js.txt",
        "EngineeringViewers/license.occt-import-js.txt",
        "settings.licenses.document.occt_import_js.title",
        "occt-import-js",
        None,
        "LGPL-2.1",
        "full_text",
        False,
        "engineering",
    ),
    (
        "occt-exception",
        "FloeApp/Resources/EngineeringViewers/OCCT_LGPL_EXCEPTION.txt",
        "EngineeringViewers/OCCT_LGPL_EXCEPTION.txt",
        "settings.licenses.document.occt_exception.title",
        "OCCT LGPL exception",
        None,
        None,
        "full_text",
        False,
        "engineering",
    ),
    (
        "gerber-notices",
        "FloeApp/Resources/EngineeringViewers/gerber-to-svg.min.js.LICENSE.txt",
        "EngineeringViewers/gerber-to-svg.min.js.LICENSE.txt",
        "settings.licenses.document.gerber.title",
        "gerber-to-svg bundle notices",
        None,
        None,
        "notices",
        False,
        "engineering",
    ),
    (
        "dxf-notices",
        "FloeApp/Resources/EngineeringViewers/dxf.js.LEGAL.txt",
        "EngineeringViewers/dxf.js.LEGAL.txt",
        "settings.licenses.document.dxf.title",
        "dxf.js bundle notices",
        None,
        None,
        "notices",
        False,
        "engineering",
    ),
    (
        "mesh-notices",
        "FloeApp/Resources/EngineeringViewers/mesh.js.LEGAL.txt",
        "EngineeringViewers/mesh.js.LEGAL.txt",
        "settings.licenses.document.mesh.title",
        "mesh.js bundle notices",
        None,
        None,
        "notices",
        False,
        "engineering",
    ),
    (
        "whisper-model",
        "FloeApp/Resources/Whisper/NOTICE.txt",
        "Whisper/NOTICE.txt",
        "settings.licenses.document.whisper_model.title",
        "Whisper model and tokenizer",
        None,
        None,
        "provenance",
        False,
        "speech",
    ),
    (
        "whisperkit",
        "FloeApp/Resources/Whisper/WhisperKit-LICENSE.txt",
        "Whisper/WhisperKit-LICENSE.txt",
        "settings.licenses.document.whisperkit.title",
        "WhisperKit",
        None,
        "MIT",
        "full_text",
        False,
        "speech",
    ),
    (
        "whisper-tokenizer",
        "FloeApp/Resources/Whisper/Tokenizer-LICENSE.txt",
        "Whisper/Tokenizer-LICENSE.txt",
        "settings.licenses.document.whisper_tokenizer.title",
        "Whisper tokenizer",
        None,
        "Apache-2.0",
        "full_text",
        False,
        "speech",
    ),
    (
        "ide-notice",
        "FloeApp/Resources/IDE/NOTICE.md",
        "IDE/NOTICE.md",
        "settings.licenses.document.ide.title",
        "CodeBlitz IDE",
        None,
        "MIT",
        "notices",
        False,
        "ide",
    ),
    (
        "ide-vendor",
        "FloeApp/Resources/IDE/vendor/LICENSE",
        "IDE/vendor/LICENSE",
        "settings.licenses.document.ide_vendor.title",
        "CodeBlitz bundled dependencies",
        None,
        None,
        "notices",
        False,
        "ide",
    ),
    (
        "monaco",
        "FloeApp/Resources/IDE/vendor/MONACO-LICENSE",
        "IDE/vendor/MONACO-LICENSE",
        "settings.licenses.document.monaco.title",
        "OpenSumi Monaco",
        None,
        "MIT",
        "full_text",
        False,
        "ide",
    ),
    (
        "oniguruma",
        "FloeApp/Resources/IDE/vendor/ONIGURUMA-LICENSE",
        "IDE/vendor/ONIGURUMA-LICENSE",
        "settings.licenses.document.oniguruma.title",
        "vscode-oniguruma",
        None,
        "MIT and Oniguruma notices",
        "full_text",
        False,
        "ide",
    ),
    (
        "codicons",
        "FloeApp/Resources/IDE/vendor/CODICONS-LICENSE",
        "IDE/vendor/CODICONS-LICENSE",
        "settings.licenses.document.codicons.title",
        "Microsoft Codicons",
        None,
        "CC-BY-4.0",
        "full_text",
        False,
        "ide",
    ),
    (
        "codeblitz-bundle",
        "FloeApp/Resources/IDE/vendor/codeblitz.global-with-react.min.js.LICENSE.txt",
        "IDE/vendor/codeblitz.global-with-react.min.js.LICENSE.txt",
        "settings.licenses.document.codeblitz_bundle.title",
        "CodeBlitz bundle notices",
        None,
        None,
        "notices",
        False,
        "ide",
    ),
    (
        "zlimageeditor",
        "FloeApp/Resources/ZLImageEditor-LICENSE.txt",
        "ZLImageEditor-LICENSE.txt",
        "settings.licenses.document.zlimageeditor.title",
        "ZLImageEditor",
        None,
        "MIT",
        "full_text",
        False,
        "media",
    ),
    (
        "royalvnc",
        "ThirdParty/RoyalVNCKit/LICENSE",
        "LICENSE",
        "settings.licenses.document.royalvnc.title",
        "RoyalVNCKit",
        None,
        "MIT",
        "full_text",
        False,
        "media",
    ),
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def classify_license(text: str) -> str | None:
    """Map the first screen of an upstream license file to an SPDX expression."""
    lowered = text.lower()
    if "mozilla public license" in lowered:
        return "MPL-2.0"
    if "apache license" in lowered and "version 2.0" in lowered:
        return "Apache-2.0"
    if "sil open font license" in lowered:
        return "OFL-1.1"
    if "gnu general public license" in lowered:
        if "linking exception" in lowered:
            return "GPL-2.0 WITH libgit2 linking exception"
        return "GPL-3.0" if "version 3" in lowered else "GPL-2.0"
    if "permission is hereby granted, free of charge" in lowered or "mit license" in lowered:
        return "MIT"
    if "redistribution and use in source and binary forms" in lowered:
        return "BSD-3-Clause" if "neither the name" in lowered else "BSD-2-Clause"
    if "software is provided 'as-is'" in lowered and "origin of this software must not be misrepresented" in lowered:
        return "Zlib"
    if "permission to use, copy, modify, and/or distribute this software" in lowered:
        return "ISC"
    if "boost software license" in lowered:
        return "BSL-1.0"
    if "creative commons" in lowered and "attribution 4.0" in lowered:
        return "CC-BY-4.0"
    return None


def load_pins() -> list[dict]:
    with open(PACKAGE_RESOLVED) as handle:
        current = json.load(handle)
    committed = json.loads(
        subprocess.check_output(
            ["git", "show", "HEAD:FloeAgent/Package.resolved"], cwd=REPO, text=True
        )
    )
    pins = verify_resolution(
        resolved_pins(current),
        resolved_pins(committed),
        application_pins(PROJECT_YML.read_text()),
    )
    rows = []
    for pin in pins:
        state = pin["state"]
        rows.append(
            {
                "identity": pin["identity"],
                "location": pin["location"],
                "version": state.get("version") or state["revision"],
            }
        )
    return rows


def detect_pin_license(identity: str) -> tuple[str | None, str | None, str | None]:
    """Read the upstream license of a resolved package from its checkout."""
    checkout = CHECKOUTS / identity
    for name in LICENSE_FILE_CANDIDATES:
        path = checkout / name
        if path.is_file():
            return (
                classify_license(path.read_text(encoding="utf-8", errors="replace")),
                f".build/checkouts/{identity}/{name}",
                sha256_file(path),
            )
    if identity == "whisperkit":
        # Xcode app-only package: the license ships as a bundled notice.
        path = ROOT / "FloeApp/Resources/Whisper/WhisperKit-LICENSE.txt"
        if path.is_file():
            return (
                classify_license(path.read_text(encoding="utf-8", errors="replace")),
                "FloeApp/Resources/Whisper/WhisperKit-LICENSE.txt",
                sha256_file(path),
            )
    return None, None, None


def load_evidence() -> dict[str, dict]:
    if not EVIDENCE.is_file():
        return {}
    document = json.loads(EVIDENCE.read_text())
    return {row["identity"]: row for row in document.get("licenses", [])}


def resolve_pins(pins: list[dict], recorded: dict[str, dict], problems: list[str]):
    """Resolve licenses for pins from actual files, verifying recorded evidence."""
    rows = []
    evidence = []
    for pin in pins:
        identity = pin["identity"]
        license_name, evidence_path, digest = detect_pin_license(identity)
        note = None
        if license_name is None:
            previous = recorded.get(identity)
            if previous:
                license_name = previous["license"]
                evidence_path = previous["evidence"]
                digest = previous["sha256"]
                note = f"checkout unavailable; reusing recorded evidence for {identity}"
            else:
                problems.append(
                    f"{identity}: license undetected and no recorded evidence; "
                    "manual review required"
                )
                license_name = "UNKNOWN"
        elif identity in recorded and recorded[identity]["sha256"] != digest:
            previous = recorded[identity]
            problems.append(
                f"{identity}: upstream license changed since the recorded evidence "
                f"({previous['evidence']} {previous['sha256'][:12]} -> "
                f"{evidence_path} {digest[:12]}); review before regenerating"
            )
        if note:
            print(f"note: {note}", file=sys.stderr)
        if identity not in recorded or recorded[identity]["sha256"] != digest:
            print(
                f"note: recording license evidence for {identity}: "
                f"{license_name} from {evidence_path}",
                file=sys.stderr,
            )
        evidence.append(
            {
                "identity": identity,
                "license": license_name,
                "evidence": evidence_path,
                "sha256": digest,
            }
        )
        rows.append({"pin": pin, "license": license_name, "evidence": evidence_path})
    return rows, evidence


PIN_NOTES = {
    "libgit2": "settings.licenses.note.libgit2",
}

# Notices that already carry a translated note in the catalog.
DOCUMENT_NOTES = {
    "tinyemu": "settings.diagnostics.tinyemu_licenses.footer",
}

# Where each static component's license was read from. Committed repository
# evidence is preferred; upstream fetches are named by the pinned tag so a
# reviewer can repeat the read.
STATIC_EVIDENCE = {
    "TinyEMU / FloeTinyEMU engine": "ThirdParty/TinyEMU/LICENSE-INVENTORY.md (per-file inventory of the pinned tarball)",
    "TinyEMU slirp (compiled subset)": "ThirdParty/TinyEMU/LICENSE-INVENTORY.md and the restored slirp COPYRIGHT text",
    "VideoEditorKit": "ThirdParty/VideoEditorKit/FLOE_PROVENANCE.md pinned commit",
    "FloeShellEngine (BSD shell core)": "ThirdParty/FloeShellEngine sources and ThirdParty/DashIOS/COPYING",
    "ios_system command bus and BSD commands": "ThirdParty/FloeShellEngine manifest",
    "dash iOS": "ThirdParty/DashIOS/COPYING",
    "FreeRDP bridge": "ThirdParty/FreeRDP/runtime.lock.json license",
    "WasmKit runtime": "ThirdParty/WasmKit/LICENSE",
    "WasmKit SystemExtras": "ThirdParty/WasmKit/LICENSE",
    "PHP WASI runtime": "ThirdParty/PHPWASI/runtime.lock.json source.license",
    "Lua WASI runtime": "ThirdParty/LuaWASI/runtime.lock.json license",
    "Ruby WASI runtime": "ThirdParty/RubyWASI/runtime.lock.json runtime.license",
    "RoyalVNCKit (Floe synchronized queue)": "ThirdParty/RoyalVNCKit/FLOE_PATCHES.md and Package.swift pin",
    "llama.cpp": "FloeAgent/Package.swift LlamaFramework binary target pin",
    "llama-ios-xcframework": "FloeAgent/Package.swift LlamaFramework binary target comment",
    "PDFium": "scripts/bootstrap_pdfium.py pinned bblanchon/pdfium-binaries chromium/8035",
    "pdfium-binaries": "scripts/bootstrap_pdfium.py release URL",
    "libarchive": "scripts/bootstrap_libarchive.py VERSION/SHA pin",
    "Collabora Online native Office engine (LibreOffice-based)": "ThirdParty/Collabora/engine.lock.json pin; upstream COPYING at the pinned commit (MPL-2.0)",
    "mdds (Office chart filter headers)": "upstream LICENSE at tag 3.1.0 (MIT)",
    "frozen (Office JSON headers)": "upstream LICENSE at tag 1.2.0 (Apache-2.0)",
    "lodash (JavaScriptCore package)": "bundled UMD banner (MIT)",
    "dayjs (JavaScriptCore package)": "upstream repository LICENSE (MIT); bundled build carries no banner",
    "marked (JavaScriptCore package)": "bundled UMD banner (MIT, v12.0.0)",
    "uuid (JavaScriptCore package)": "bundled UMD banner (MIT, 8.3.2)",
    "zod (JavaScriptCore package)": "upstream repository LICENSE (MIT); bundled build carries no banner",
    "pdf-lib (JavaScriptCore package)": "bundled UMD banner (MIT; TypeScript helper notices Apache-2.0)",
    "@simonwep/pickr": "FloeApp/Resources/EngineeringViewers/THIRD_PARTY_NOTICES.txt",
    "dxf-viewer": "FloeApp/Resources/EngineeringViewers/THIRD_PARTY_NOTICES.txt",
    "gerber-to-svg": "FloeApp/Resources/EngineeringViewers/gerber-to-svg.min.js.LICENSE.txt",
    "Open CASCADE Technology (OCCT)": "FloeApp/Resources/EngineeringViewers/license.occt.txt",
    "occt-import-js": "FloeApp/Resources/EngineeringViewers/license.occt-import-js.txt",
    "OpenSumi CodeBlitz": "FloeApp/Resources/IDE/vendor/LICENSE and manifest.json",
    "OpenSumi Monaco": "FloeApp/Resources/IDE/vendor/MONACO-LICENSE",
    "vscode-oniguruma": "FloeApp/Resources/IDE/vendor/ONIGURUMA-LICENSE",
    "Microsoft Codicons": "FloeApp/Resources/IDE/vendor/CODICONS-LICENSE",
    "ZLImageEditor": "FloeApp/Resources/ZLImageEditor-LICENSE.txt",
    "FloeDocumentSans (modified Noto Sans SC)": "FloeApp/Resources/DocumentConversion/FONT-LICENSE.txt",
}


def build_components(pin_rows: list[dict], font_families: list[dict], npm_packages: list[dict]):
    components = []
    for row in pin_rows:
        pin = row["pin"]
        components.append(
            {
                "name": pin["identity"],
                "version": pin["version"],
                "license": row["license"],
                "source": pin["location"],
                "section": "swift",
                "noteKey": PIN_NOTES.get(pin["identity"]),
                "evidence": row["evidence"],
            }
        )
    for name, version, license_name, source, section, note_key in STATIC_COMPONENTS:
        components.append(
            {
                "name": name,
                "version": version,
                "license": license_name,
                "source": source,
                "section": section,
                "noteKey": note_key,
                "evidence": STATIC_EVIDENCE.get(name),
            }
        )
    for family in sorted(font_families, key=lambda item: item["id"]):
        license_name = family["license"].get("spdx") or family["license"]["name"]
        components.append(
            {
                "name": f"Font: {family['displayName']} ({family['id']})",
                "version": family["version"],
                "license": license_name,
                "source": family.get("upstream", {}).get("homepage", ""),
                "section": "fonts",
                "noteKey": None,
                "evidence": None,
            }
        )
    for package in sorted(npm_packages, key=lambda item: item["name"]):
        components.append(
            {
                "name": package["name"],
                "version": package["version"],
                "license": package["license"],
                "source": "https://www.npmjs.com/package/" + package["name"],
                "section": "conversion",
                "noteKey": None,
                "evidence": None,
            }
        )
    core = [family for family in font_families if family.get("tier") != "optional"]
    components.append(
        {
            "name": "Bundled CJK/utility fonts (staged core set)",
            "version": f"{len(core)} families staged / {len(font_families)} licensed families",
            "license": "OFL-1.1 or vendor font grants (full texts bundled per family)",
            "source": "https://github.com/JiangNanGenius/floe-agent/tree/main/FloeAgent/FloeApp/Resources/Fonts/Bundled",
            "section": "fonts",
            "noteKey": None,
            "evidence": None,
        }
    )
    return components


def build_documents(font_families: list[dict]):
    documents = []
    for (
        doc_id,
        repository_path,
        bundle_path,
        title_key,
        title,
        title_argument,
        license_name,
        kind,
        required,
        section,
    ) in DOCUMENTS:
        if repository_path is None:
            # Offline runtime license text stays in the runtime's own lock; the
            # component row is the declaration and no bundle file is claimed.
            continue
        if not bundle_path:
            continue
        documents.append(
            {
                "id": doc_id,
                "repositoryPath": repository_path,
                "bundlePath": bundle_path,
                "titleKey": title_key,
                "titleFallback": title,
                "titleArgument": title_argument,
                "license": license_name,
                "kindKey": KINDS[kind],
                "required": required,
                "section": section,
                "noteKey": DOCUMENT_NOTES.get(doc_id),
            }
        )
    for family in sorted(font_families, key=lambda item: item["id"]):
        if family.get("tier") == "optional":
            continue
        license_name = family["license"].get("spdx") or family["license"]["name"]
        documents.append(
            {
                "id": f"font-{family['id']}",
                "repositoryPath": f"FloeApp/Resources/Fonts/Bundled/{family['id']}/LICENSE.txt",
                "bundlePath": f"Bundled/{family['id']}/LICENSE.txt",
                "titleKey": "settings.licenses.document.font",
                "titleFallback": f"Font: {family['displayName']}",
                "titleArgument": family["displayName"],
                "license": license_name,
                "kindKey": KINDS["grant"],
                "required": False,
                "section": "fonts",
            }
        )
    return documents


def build_manifest(components, documents):
    counts = {
        "components": len(components),
        "documents": len(documents),
        "pins": sum(1 for item in components if item["section"] == "swift"),
    }
    return {
        "schemaVersion": 1,
        "generatedBy": "scripts/license_inventory.sh",
        "appLicense": "MPL-2.0",
        "repository": REPOSITORY,
        "inventoryPath": INVENTORY_REPOSITORY_PATH,
        "sections": [
            {
                "id": section_id,
                "titleKey": f"settings.licenses.section.{section_id}",
                "fallback": title,
            }
            for section_id, title in SECTIONS
        ],
        "documents": documents,
        "components": components,
        "notes": [
            {
                "id": note_id,
                "textKey": f"settings.licenses.note.{note_id}",
                "fallback": text,
            }
            for note_id, text in NOTES
        ],
        "counts": counts,
    }


def render_markdown(manifest) -> str:
    by_section: dict[str, list[dict]] = {}
    for component in manifest["components"]:
        by_section.setdefault(component["section"], []).append(component)
    lines = [
        "# Third-Party Licenses",
        "",
        "Generated by scripts/license_inventory.sh. Do not edit by hand.",
        "",
        "The app shows the same generated inventory (third-party-inventory.json, "
        "bundled under Licenses/) together with the complete notice texts copied "
        "into the app bundle.",
        "",
    ]
    for section_id, title in SECTIONS:
        rows = by_section.get(section_id)
        if not rows:
            continue
        lines += [f"## {title}", "", "| Package | Version | License | Source |", "|---|---|---|---|"]
        for component in rows:
            lines.append(
                f"| {component['name']} | {component['version']} | "
                f"{component['license']} | {component['source']} |"
            )
        lines.append("")
    lines += ["## License notes", ""]
    for note_id, text in NOTES:
        lines.append(f"- **{note_id}.** {text}")
    lines.append("")
    if IDE_NOTICE.is_file():
        lines.append(IDE_NOTICE.read_text().rstrip())
        lines.append("")
    return "\n".join(lines)


def render_json(document) -> str:
    return json.dumps(document, ensure_ascii=False, indent=2) + "\n"


# MARK: - project.yml resource mapping


def _looks_like_file(path: str) -> bool:
    name = path.rsplit("/", 1)[-1]
    return "." in name or name.upper() in {"LICENSE", "LICENCE", "COPYING", "NOTICE"}


def bundle_rules(project_text: str):
    """Derive (repository prefix, bundle path) rules from project.yml resources."""
    rules = []
    in_sources = False
    entry: dict | None = None
    for raw_line in project_text.splitlines():
        if re.match(r"^    sources:\s*$", raw_line):
            in_sources = True
            continue
        if in_sources and re.match(r"^    \S", raw_line):
            break
        if not in_sources:
            continue
        match = re.match(r"^      - path: (\S+)\s*$", raw_line)
        if match:
            if entry:
                rules.append(entry)
            entry = {"path": match.group(1), "folder": False, "optional": False, "excludes": []}
            continue
        if entry is None:
            continue
        if re.match(r"^        type: folder\s*$", raw_line):
            entry["folder"] = True
        elif re.match(r"^        optional: true\s*$", raw_line):
            entry["optional"] = True
        else:
            exclude = re.match(r"^          - (\S+)\s*$", raw_line)
            if exclude and raw_line.startswith("          - "):
                entry["excludes"].append(exclude.group(1))
    if entry:
        rules.append(entry)

    resolved = []
    for rule in rules:
        source = f"FloeAgent/{rule['path']}".rstrip("/")
        if rule["folder"]:
            resolved.append(
                {
                    "kind": "folder",
                    "source": source,
                    "bundle": rule["path"].rstrip("/").rsplit("/", 1)[-1] + "/",
                    "excludes": [],
                }
            )
        elif (REPO / source).is_dir() or not _looks_like_file(rule["path"]):
            resolved.append(
                {
                    "kind": "loose",
                    "source": source + "/",
                    "bundle": "",
                    "excludes": [
                        f"FloeAgent/{rule['path']}/{item}".rstrip("/") + "/"
                        for item in rule["excludes"]
                    ],
                }
            )
        else:
            resolved.append(
                {
                    "kind": "file",
                    "source": source,
                    "bundle": rule["path"].rsplit("/", 1)[-1],
                    "excludes": [],
                }
            )
    return resolved


def bundle_path_for(rules, repository_path: str) -> str | None:
    repository_path = repository_path.lstrip("./")
    for rule in rules:
        if rule["kind"] == "folder" and repository_path.startswith(rule["source"] + "/"):
            return rule["bundle"] + repository_path[len(rule["source"]) + 1 :]
        if rule["kind"] == "file" and repository_path == rule["source"]:
            return rule["bundle"]
        if rule["kind"] == "loose" and repository_path.startswith(rule["source"]):
            if any(repository_path.startswith(item) for item in rule["excludes"]):
                continue
            return repository_path.rsplit("/", 1)[-1]
    return None


def localization_problems(manifest, path: Path) -> list[str]:
    catalog = json.loads(path.read_text(encoding="utf-8"))
    strings = catalog.get("strings", {})
    keys = set(CHROME_KEYS)
    for section in manifest["sections"]:
        keys.add(section["titleKey"])
    for document in manifest["documents"]:
        keys.add(document["titleKey"])
        keys.add(document["kindKey"])
        if document.get("noteKey"):
            keys.add(document["noteKey"])
    for component in manifest["components"]:
        if component.get("noteKey"):
            keys.add(component["noteKey"])
    for note in manifest["notes"]:
        keys.add(note["textKey"])
    problems = []
    for key in sorted(keys):
        entry = strings.get(key)
        if not isinstance(entry, dict):
            problems.append(f"missing localization key: {key}")
            continue
        localizations = entry.get("localizations", {})
        for locale in ("en", "zh-Hans"):
            unit = localizations.get(locale, {}).get("stringUnit", {})
            if not (unit.get("value") or "").strip():
                problems.append(f"{key}: missing {locale} value")
    return problems


def license_gate(components) -> tuple[list[str], list[str]]:
    violations = []
    notices = []
    copyleft = re.compile(r"\b(?:A?GPL|LGPL)(?:-[0-9.]+)?\b")
    for component in components:
        name = component["name"]
        license_name = component["license"]
        if license_name == "UNKNOWN":
            violations.append(f"{name}: license UNKNOWN")
            continue
        if " OR " in license_name:
            continue
        if license_name in ALLOWED_EXACT:
            continue
        if copyleft.search(license_name):
            if license_name in EXCEPTIONS:
                notices.append(f"{name}: {license_name} ({EXCEPTIONS[license_name]})")
                continue
            violations.append(f"{name}: copyleft license {license_name}")
            continue
        # Non-SPDX descriptive values from repository manifests are recorded as
        # data; they are reviewed with the component and never auto-detected.
        notices.append(f"{name}: descriptive license value {license_name!r}")
    return violations, notices


def validate(manifest, evidence_document, libgit2_bytes, problems, warnings):
    rules = bundle_rules(PROJECT_YML.read_text())
    for document in manifest["documents"]:
        expected = bundle_path_for(rules, "FloeAgent/" + document["repositoryPath"])
        if expected != document["bundlePath"]:
            problems.append(
                "notice not bundled by project.yml: "
                f"{document['repositoryPath']} maps to {expected!r}, "
                f"declared {document['bundlePath']!r}"
            )
    expected_manifest_path = bundle_path_for(rules, "FloeAgent/FloeApp/Resources/Licenses/third-party-inventory.json")
    if expected_manifest_path != MANIFEST_BUNDLE_PATH:
        problems.append(
            f"packaged manifest is not a declared resource: {expected_manifest_path!r}"
        )
    expected_libgit2 = bundle_path_for(rules, "FloeAgent/FloeApp/Resources/Licenses/libgit2-COPYING.txt")
    if expected_libgit2 != LIBGIT2_COPYING_BUNDLE_PATH:
        problems.append(f"libgit2 notice is not a declared resource: {expected_libgit2!r}")
    for document in manifest["documents"]:
        if document["required"] and not (ROOT / document["repositoryPath"]).is_file():
            warnings.append(f"required notice is not staged in this checkout: {document['repositoryPath']}")
    libgit2_record = next(
        (row for row in evidence_document["licenses"] if row["identity"] == "libgit2"), None
    )
    if libgit2_record and libgit2_record["evidence"] == LIBGIT2_EVIDENCE:
        source = ROOT / LIBGIT2_EVIDENCE
        if source.is_file() and sha256_file(source) != libgit2_record["sha256"]:
            problems.append("libgit2 COPYING no longer matches the recorded evidence")
        if libgit2_bytes is not None and hashlib.sha256(libgit2_bytes).hexdigest() != libgit2_record["sha256"]:
            problems.append("bundled libgit2 COPYING does not match the recorded evidence")
    problems.extend(localization_problems(manifest, XSTRINGS))
    violations, notices = license_gate(manifest["components"])
    problems.extend(violations)
    for notice in notices:
        print(f"note: {notice}", file=sys.stderr)


def build():
    pins = load_pins()
    recorded = load_evidence()
    problems: list[str] = []
    warnings: list[str] = []
    pin_rows, evidence_rows = resolve_pins(pins, recorded, problems)
    font_families = json.loads(FONTS_MANIFEST.read_text())["families"]
    npm_packages = json.loads(CONVERSION_INVENTORY.read_text())["packages"]
    components = build_components(pin_rows, font_families, npm_packages)
    documents = build_documents(font_families)
    manifest = build_manifest(components, documents)
    evidence_document = {
        "schemaVersion": 1,
        "generatedBy": "scripts/license_inventory.sh",
        "note": (
            "Recorded license detection evidence for the resolved Swift packages. "
            "sha256 binds the exact upstream license file the license was read from; "
            "--check re-verifies it whenever the checkout is present."
        ),
        "licenses": sorted(evidence_rows, key=lambda row: row["identity"]),
    }
    libgit2_bytes = None
    source = ROOT / LIBGIT2_EVIDENCE
    if source.is_file():
        libgit2_bytes = source.read_bytes()
    validate(manifest, evidence_document, libgit2_bytes, problems, warnings)
    return {
        "manifest": manifest,
        "evidence": evidence_document,
        "markdown": render_markdown(manifest),
        "manifest_text": render_json(manifest),
        "evidence_text": render_json(evidence_document),
        "libgit2_bytes": libgit2_bytes,
        "problems": problems,
        "warnings": warnings,
    }


def report_drift(path: Path) -> int:
    print(f"drift: {path.relative_to(REPO)}", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate or check the third-party declaration")
    parser.add_argument(
        "--check",
        action="store_true",
        help="read-only: verify committed artifacts, evidence, bundle mapping and localization",
    )
    args = parser.parse_args(argv)

    result = build()
    problems = result["problems"]
    warnings = result["warnings"]
    manifest_text = result["manifest_text"]
    evidence_text = result["evidence_text"]
    markdown = result["markdown"]
    libgit2_bytes = result["libgit2_bytes"]

    if args.check:
        # Tracked artifacts must exist and match byte for byte.
        for path, expected in (
            (MANIFEST, manifest_text),
            (EVIDENCE, evidence_text),
        ):
            if not path.is_file():
                problems.append(f"missing generated artifact: {path.relative_to(REPO)}")
                continue
            actual = path.read_text(encoding="utf-8")
            if actual != expected:
                problems.append(f"committed artifact differs from the generator: {path.relative_to(REPO)}")
                report_drift(path)
                for line in difflib_unified(actual, expected):
                    print(line, file=sys.stderr)
        # The release table is git-ignored and generated on demand; compare it
        # when it is present so a stale local copy is still caught.
        if MARKDOWN.is_file():
            actual = MARKDOWN.read_text(encoding="utf-8")
            if actual != markdown:
                problems.append(f"committed artifact differs from the generator: {MARKDOWN.relative_to(REPO)}")
                report_drift(MARKDOWN)
                for line in difflib_unified(actual, markdown):
                    print(line, file=sys.stderr)
        else:
            warnings.append(
                f"{MARKDOWN.relative_to(REPO)} is not generated in this checkout "
                "(release artifact; run without --check to write it)"
            )
        if libgit2_bytes is not None:
            if not LIBGIT2_COPYING.is_file() or LIBGIT2_COPYING.read_bytes() != libgit2_bytes:
                problems.append(f"committed artifact differs from the generator: {LIBGIT2_COPYING.relative_to(REPO)}")
                report_drift(LIBGIT2_COPYING)
        elif not LIBGIT2_COPYING.is_file():
            problems.append(f"missing generated artifact: {LIBGIT2_COPYING.relative_to(REPO)}")
    else:
        MANIFEST.parent.mkdir(parents=True, exist_ok=True)
        MANIFEST.write_text(manifest_text, encoding="utf-8")
        MARKDOWN.write_text(markdown, encoding="utf-8")
        EVIDENCE.write_text(evidence_text, encoding="utf-8")
        if libgit2_bytes is not None:
            if not LIBGIT2_COPYING.is_file() or LIBGIT2_COPYING.read_bytes() != libgit2_bytes:
                LIBGIT2_COPYING.write_bytes(libgit2_bytes)
        elif not LIBGIT2_COPYING.is_file():
            problems.append(
                "libgit2 COPYING is neither in the checkout nor committed; "
                "resolve the package before generating"
            )
        print(
            "license_inventory wrote "
            f"{MARKDOWN.relative_to(REPO)}, {MANIFEST.relative_to(REPO)} and "
            f"{EVIDENCE.relative_to(REPO)}"
        )

    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    if problems:
        print("error: license inventory problems:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    counts = result["manifest"]["counts"]
    if args.check:
        print(
            "license_inventory --check OK: "
            f"{counts['components']} components, {counts['documents']} bundled notices, "
            f"{counts['pins']} resolved Swift pins"
        )
    else:
        print(f"license_inventory OK: {counts['components']} dependencies inventoried")
    return 0


def difflib_unified(actual: str, expected: str, context: int = 2, limit: int = 60):
    import difflib

    lines = list(
        difflib.unified_diff(
            actual.splitlines(),
            expected.splitlines(),
            fromfile="committed",
            tofile="generated",
            lineterm="",
            n=context,
        )
    )
    return lines[:limit] + (["... diff truncated ..."] if len(lines) > limit else [])


if __name__ == "__main__":
    sys.exit(main())
