#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Generate Floe's third-party declaration from its actual pins and licenses.

Single source of truth for the in-app and repository license declaration. The
generator reads, in this order:

* ``Package.resolved`` (host lock, verified against ``HEAD`` and the Xcode app
  pins in ``project.yml``) for every Swift package;
* the resolved checkout license files under ``.build/checkouts`` for the
  license text itself — never a hand-maintained table;
* the tracked LICENSE of a repository-vendored package (``ThirdParty/**``)
  that replaced a formerly resolved remote pin, bound to the declared upstream
  commit and copied into the app bundle for the full notice text;
* the FloeCADKit package lock (``ThirdParty/FloeCADKit/Package.resolved``) for
  the app-graph-only native CAD dependencies — every declared row is bound to
  the exact lock revision and to the digest of the complete upstream license
  text tracked under ``FloeApp/Resources/Licenses``;
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

``FLOE_LICENSE_CHECKOUTS`` may point a read-only qualification run at an
explicit checkout root — an empty directory reproduces the clean-clone contract
of ``docs/FLOE_LOCAL_QUALIFICATION.md``. Unset (the default, and in CI), the
generator reads the real ``.build/checkouts`` and a checkout whose revision does
not match its declared pin still fails closed.

Revision binding
----------------

Every recorded evidence row is bound to the exact pin ``revision`` and
``location``. A license is accepted only from

* a resolved checkout whose ``HEAD`` equals the declared revision (the
  generator never checks out, fetches or resets anything itself),
* a repository-tracked notice for an app-only package, or
* a recorded row whose revision *and* source still match.

A changed or unreadable checkout revision, and a changed pin revision without a
verified checkout, fail explicitly instead of silently keeping the license
text of an older version. ``--check`` therefore works in a clean checkout with
no ``.build`` as long as every recorded row still matches its declared pin.

Regenerating after a dependency change (for the primary agent)
--------------------------------------------------------------

1. Update the dependency the normal way (``Package.resolved``; ``project.yml``
   for an Xcode app-only package). Never hand-edit the generated artifacts.
2. Resolve the package so ``.build/checkouts/<identity>`` matches the pin
   (``swift package resolve``). For an Xcode app-only package, refresh its
   repository notice under ``FloeApp/Resources/Licenses`` in the same review.
   The generator never performs the checkout itself.
3. Run ``scripts/license_inventory.sh`` and review the diff of
   ``scripts/license-evidence.json`` and the packaged manifest (new revision,
   source and sha256), then commit them together with the pin change.
4. ``scripts/license_inventory.sh --check`` (and CI) fails on a stale tracked
   manifest instead of rewriting it.

A future pinned dependency needs no catalog edit: the generator discovers it
from the lock and its checkout, and the same steps apply. Nothing here guesses
a dependency that does not exist yet.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
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
LIBGIT2_COPYING = ROOT / "FloeApp/Resources/Licenses/libgit2-COPYING.txt"
PACKAGE_RESOLVED = ROOT / "Package.resolved"
# Resolved checkouts are shared, mutable build cache: another worktree may have
# resolved a different revision graph in the same .build. A read-only
# qualification run may point at an explicit checkout root instead — including
# an empty directory, which reproduces the clean-clone contract of
# docs/FLOE_LOCAL_QUALIFICATION.md (reuse each recorded, revision-bound evidence
# row without reading the shared cache). Unset in normal use and in CI, so the
# default stays the real .build/checkouts and a mismatched revision still fails
# closed.
CHECKOUTS = Path(os.environ.get("FLOE_LICENSE_CHECKOUTS") or (ROOT / ".build/checkouts"))

REPOSITORY = "https://github.com/JiangNanGenius/floe-agent"
INVENTORY_REPOSITORY_PATH = "FloeAgent/LICENSES-THIRD-PARTY.md"
MANIFEST_BUNDLE_PATH = "Licenses/third-party-inventory.json"
LIBGIT2_COPYING_BUNDLE_PATH = "Licenses/libgit2-COPYING.txt"
LIBGIT2_EVIDENCE = ".build/checkouts/libgit2/COPYING"
# Recorded evidence under this prefix comes from a resolved checkout and is
# expected to be absent in a clean tree; anything else must stay readable.
CHECKOUT_EVIDENCE_PREFIX = ".build/checkouts/"

# Xcode app-only packages never appear in .build/checkouts. Their license text
# is repository-tracked here, so it is reviewable in the same commit as the pin
# and is still bound to the declared revision by the recorded evidence row.
APP_ONLY_NOTICES = {
    "whisperkit": "FloeApp/Resources/Whisper/WhisperKit-LICENSE.txt",
}

# Packages vendored under ThirdParty/ that replaced a formerly resolved remote
# pin (Package.swift now uses a path dependency, so Package.resolved no longer
# declares the identity). While the lock still declares the identity, the
# resolved pin remains the single declaration and the generated artifacts do not
# change. Once it is gone, the repository copy is declared from its tracked
# LICENSE: the evidence row binds the copy to the exact upstream commit it was
# taken from, and the complete notice text is copied into the app bundle at the
# declared document path (compared byte for byte by --check).
VENDORED_PACKAGES = (
    {
        "identity": "mlx-swift-lm",
        "path": "ThirdParty/MLXSwiftLM",
        "revision": "d5d8b290e601ac1bf11f24635f8f811a83b98bf8",
        "upstream": "https://github.com/ml-explore/mlx-swift-lm.git",
        "license": "MIT",
        "note": (
            "mlx_vendor",
            "mlx-swift-lm is vendored at ThirdParty/MLXSwiftLM from upstream "
            "commit d5d8b290e601ac1bf11f24635f8f811a83b98bf8 with a minimal Floe "
            "prefill-stability patch; the complete MIT text ships in the app as "
            "Licenses/MLXSwiftLM-LICENSE.txt.",
        ),
        "document": {
            "id": "mlx-swift-lm",
            "repositoryPath": "FloeApp/Resources/Licenses/MLXSwiftLM-LICENSE.txt",
            "bundlePath": "Licenses/MLXSwiftLM-LICENSE.txt",
            "titleKey": "settings.licenses.document.mlx_swift_lm.title",
            "titleFallback": "mlx-swift-lm",
            "kind": "full_text",
            "required": True,
            "section": "swift",
        },
    },
)
VENDORED_LICENSE_NAME = "LICENSE"

# The app graph additionally resolves the native CAD kernel's dependencies
# through the FloeCADKit package lock (``ThirdParty/FloeCADKit/Package.resolved``
# is the single pin authority for them). Only the packages actually linked into
# the app are declared: the FloeCAD product depends on Euclid and ShapeScript,
# and ShapeScript on Euclid, LRUCache and SVGPath. Each reviewed row binds an
# identity to the exact lock revision and to the digest of the complete
# upstream license text (including its copyright line) tracked under
# ``FloeApp/Resources/Licenses``; a moved pin, an edited copy or a different
# checkout license fails instead of silently reusing another revision's text.
CAD_LOCK = ROOT / "ThirdParty/FloeCADKit/Package.resolved"
CAD_MANIFEST = ROOT / "ThirdParty/FloeCADKit/Package.swift"
CAD_LINKED_PACKAGES = (
    {
        "identity": "euclid",
        "revision": "a123b1cbbb5b7aab49a8b57e12783f7bd39f0cac",
        "version": "0.9.6",
        "title": "Euclid",
        "license": "MIT",
        "sha256": "2323c3f51cc56987ff8e8ddac1d239276072188c615cf991921163173e5eafb3",
        "notice": "FloeApp/Resources/Licenses/Euclid-LICENSE.txt",
    },
    {
        "identity": "lrucache",
        "revision": "f0570e943ea4445d258113ba73f50cb2b7e564ac",
        "version": "1.3.0",
        "title": "LRUCache",
        "license": "MIT",
        "sha256": "cc59ff976bc639612b7f2e92c6ecfad42e93b70099c7b950acd1b3651def10ab",
        "notice": "FloeApp/Resources/Licenses/LRUCache-LICENSE.txt",
    },
    {
        "identity": "shapescript",
        "revision": "cda3024b2f17ac06aef23aae7ddcf39c217c6237",
        "version": "1.11.6",
        "title": "ShapeScript",
        "license": "MIT",
        "sha256": "2323c3f51cc56987ff8e8ddac1d239276072188c615cf991921163173e5eafb3",
        "notice": "FloeApp/Resources/Licenses/ShapeScript-LICENSE.txt",
    },
    {
        "identity": "svgpath",
        "revision": "892e57b71c26937863a53a7459051ef329cfd6b4",
        "version": "1.3.1",
        "title": "SVGPath",
        "license": "MIT",
        "sha256": "cc59ff976bc639612b7f2e92c6ecfad42e93b70099c7b950acd1b3651def10ab",
        "notice": "FloeApp/Resources/Licenses/SVGPath-LICENSE.txt",
    },
)
CAD_NOTE_KEY = "settings.licenses.note.cad_packages"
# Declared by the same CAD lock but referenced only by ShapeScript's HelpBuilder
# executable: they are not linked into the FloeCAD product or the app and are
# deliberately not part of the shipped inventory. They are acknowledged here so
# an unexpected new lock identity is still caught for review.
CAD_BUILD_ONLY_PACKAGES = {
    "swift-cmark": (
        "resolved only for ShapeScript's HelpBuilder executable; not linked into "
        "FloeCAD or the app"
    ),
    "swift-markdown": (
        "resolved only for ShapeScript's HelpBuilder executable; not linked into "
        "FloeCAD or the app"
    ),
}

# FloeCADKit itself is a locally modified extraction of OpenShape3D's geometry
# kernel; OpenShape3D is not a resolved package (FloeCADKit is the extraction),
# so there is no lock pin to verify it against. Its provenance record is
# ``ThirdParty/FloeCADKit/DEPENDENCIES.json``, and the complete upstream MIT
# notice is tracked under ``ThirdParty/FloeCADKit`` with byte-identical bytes
# bundled for the app. The reviewed row below binds that record and both copies;
# FloeCADKit carries Floe's own modifications (PATCHES.md), so the component is
# declared as a derived extraction, never as an unmodified upstream library.
OPENSHAPE_COMPONENT = {
    "identity": "openshape3d",
    "title": "OpenShape3D (FloeCADKit extraction)",
    "revision": "30b3c7c1784754f237466e093ab42ff085175d40",
    "license": "MIT",
    "sha256": "dbdeb16766c9aae5eb59d4f184e6222727a23a44698fdea275e4fd0857339a83",
    "upstream": "https://github.com/laanlabs/OpenShape3D.git",
    "repositoryWeb": "https://github.com/laanlabs/OpenShape3D",
    "notice": "FloeApp/Resources/Licenses/OpenShape3D-LICENSE.txt",
    "packageCopy": "ThirdParty/FloeCADKit/LICENSE-OpenShape3D-MIT.txt",
    "dependencies": "ThirdParty/FloeCADKit/DEPENDENCIES.json",
}
OPENSHAPE_NOTE_KEY = "settings.licenses.note.openshape3d"

# The bundled, app-readable record for the statically linked native OCCT
# libraries; its facts are re-verified against ThirdParty/FloeCADKit/
# DEPENDENCIES.json, OCCT_RELINK.md and the retained relink inputs.
OCCT_NATIVE_NOTICE = "FloeApp/Resources/Licenses/OCCT-Native-SOURCE-OFFER.txt"
OCCT_NATIVE_NAME = "Open CASCADE Technology (OCCT) native static libraries (FloeCADKit)"
OCCT_NATIVE_LICENSE = (
    "LGPL-2.1 with OCCT exception (native static libraries linked via the "
    "FloeCADKit OCCT binaryTarget; source, relink kit and exception recorded)"
)

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
        "the EngineeringViewers WebAssembly bundle ships OCCT/occt-import-js "
        "with the exception and the complete texts and runs in the bundled "
        "WebAssembly runtime, not as linked native code; the separately linked "
        "native OCCT static libraries have their own recorded exception entry"
    ),
    OCCT_NATIVE_LICENSE: (
        "OCCT 7.8.1 is linked into the app as unmodified upstream static "
        "libraries (Vendor/OCCT.xcframework, pinned by size and SHA-256 in "
        "ThirdParty/FloeCADKit/DEPENDENCIES.json); the LGPL-2.1 text and the "
        "Open CASCADE exception 1.0 ship in the app bundle, and the complete "
        "source route and the retained rebuild/relink kit are recorded in "
        "ThirdParty/FloeCADKit/OCCT_RELINK.md and relink/SOURCE_OFFER.md. "
        "This is an engineering record, not a legal certification."
    ),
    "Debian package licenses; kernel GPL-2.0; bbl BSD-3-Clause; static glibc LGPL-2.1": (
        "the Linux guest is a separately distributed downloadable image; its "
        "source and license texts are recorded in the pinned image manifest"
    ),
    "GPL-2.0 (Linux kernel; bundled separate data blob, not linked into the app binary; corresponding source, config and license text recorded)": (
        "the bundled Linux guest kernel Image is a separate data resource that "
        "runs inside the TinyEMU virtual machine; it is not linked into the app "
        "or the engine binary, its complete GPL-2.0 text ships in the app as "
        "Licenses/LinuxBootPair-LICENSES.txt, and its unmodified upstream "
        "corresponding source, exact build config and build recipe are recorded "
        "in ThirdParty/TinyEMU/guest-image/BOOT-PAIR-LICENSES.md"
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
        "Open CASCADE Technology and occt-import-js are bundled for the "
        "engineering viewer as WebAssembly modules under LGPL-2.1 with the OCCT "
        "exception; their complete texts and the exception ship in the app "
        "bundle. The separately linked native OCCT 7.8.1 static libraries are "
        "declared as their own component with a recorded relink and source "
        "offer.",
    ),
    (
        "occt_native",
        "The native CAD engine links Open CASCADE Technology 7.8.1 as unmodified "
        "upstream static libraries for iOS device and simulator, pinned by tag "
        "V7_8_1 (commit bd2a789f15235755ce4d1a3b07379a2e062fdc2e), size and "
        "SHA-256 in ThirdParty/FloeCADKit/DEPENDENCIES.json. OCCT is licensed "
        "under LGPL-2.1 with the Open CASCADE exception 1.0; the complete texts "
        "and the exception ship in this app (EngineeringViewers/license.occt.txt, "
        "EngineeringViewers/OCCT_LGPL_EXCEPTION.txt). The record of where the "
        "exact corresponding source and the retained build inputs are available "
        "for rebuilding or relinking is bundled as "
        "Licenses/OCCT-Native-SOURCE-OFFER.txt. Floe has not independently "
        "rebuilt OCCT and claims no byte-identical local reproduction; these are "
        "engineering records, not a legal certification.",
    ),
    (
        "cad_packages",
        "The Floe CAD kernel links four Swift packages that only the app "
        "dependency graph resolves, pinned by "
        "ThirdParty/FloeCADKit/Package.resolved: Euclid and ShapeScript (the "
        "FloeCAD product depends on both) plus ShapeScript's Euclid, LRUCache "
        "and SVGPath dependencies. Their complete MIT license texts, including "
        "the copyright lines, ship in this app under Licenses/.",
    ),
    (
        "openshape3d",
        "FloeCADKit, the app's native CAD kernel package, is Floe's locally "
        "modified extraction of OpenShape3D's geometry kernel, feature graph, "
        "editor state machine and Metal viewport (upstream commit "
        "30b3c7c1784754f237466e093ab42ff085175d40, MIT; the modification record "
        "is ThirdParty/FloeCADKit/PATCHES.md, provenance in UPSTREAM.md). It is "
        "a derived, modified copy, not an unmodified upstream library. "
        "OpenShape3D's complete MIT license text, including the copyright line, "
        "ships in this app as Licenses/OpenShape3D-LICENSE.txt.",
    ),
    (
        "guest_image",
        "The Linux guest is a separately distributed downloadable image built "
        "from Debian 13 riscv64 packages plus a pinned kernel, bbl and static "
        "glibc. Its source and license texts are recorded in the pinned image "
        "manifest; they are not linked into the app binary.",
    ),
    (
        "linux_boot_pair",
        "The app bundles the verified Linux 6.18.56 kernel Image and OpenSBI "
        "1.9 fw_jump firmware as separate data resources that run inside the "
        "TinyEMU virtual machine; they are not linked into the app or engine "
        "binary. The kernel is unmodified upstream Linux (GPL-2.0 with the "
        "Linux syscall note) and the firmware is OpenSBI (BSD-2-Clause). Their "
        "complete license texts, the exact build configuration and the "
        "corresponding-source references ship in the app as "
        "Licenses/LinuxBootPair-LICENSES.txt.",
    ),
    (
        "office",
        "The native Office engine is Collabora Online (LibreOffice-based) at "
        "commit 27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc, MPL-2.0. Its complete "
        "upstream legal files ship in this app under Licenses/OfficeEngine/: "
        "the licensing and legal information statement with the MPL 2.0 text "
        "and third-party library notices, the MPL 2.0, LGPL 3.0 and GPL 3.0 "
        "license texts, the MPL source notice, the third-party license file "
        "and the Apache NOTICE. Licenses/OfficeEngine-SOURCE-OFFER.txt records "
        "where the exact source and Floe patches are available. The texts are "
        "copied byte-for-byte from the verified engine build; Floe makes no "
        "relicensing claim.",
    ),
    (
        "verification",
        "Every Swift package license was read from the resolved checkout at the "
        "exact revision declared in the lock; scripts/license-evidence.json "
        "records the file, its sha256 and the pin revision+source, and this "
        "generator re-verifies them whenever a checkout is present.",
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
    # The modern boot pair ships inside the app as separate data resources
    # (LinuxBootPair-LICENSES.txt; pin: ThirdParty/TinyEMU/guest-image/
    # boot-pair-v2.manifest.json). The legacy guest image above keeps its own
    # original kernel/bbl pair as rollback and its download manifest.
    (
        "Linux guest boot kernel (bundled 6.18.56 Image)",
        "6.18.56 (build #7)",
        "GPL-2.0 (Linux kernel; bundled separate data blob, not linked into the app binary; corresponding source, config and license text recorded)",
        "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.56.tar.xz",
        "engines",
        "settings.licenses.note.linux_boot_pair",
    ),
    (
        "Linux guest boot firmware (bundled OpenSBI v1.9 fw_jump)",
        "v1.9",
        "BSD-2-Clause",
        "https://github.com/riscv-software-src/opensbi/releases/tag/v1.9",
        "engines",
        "settings.licenses.note.linux_boot_pair",
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
        "v3.0.4 manifest / v3.0.2 binaries; shell+text locally rebuilt from v3.0.2 + Floe privacy patch (scripts/privacy-rebuild, hashes in PROVENANCE.json)",
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
    # The native OCCT static libraries are linked into FloeCAD (via the
    # OCCTShim/OCCT binaryTarget); the EngineeringViewers entries below remain
    # the separately bundled WebAssembly viewer and occt-import-js build.
    (
        OCCT_NATIVE_NAME,
        "7.8.1",
        OCCT_NATIVE_LICENSE,
        "https://github.com/Open-Cascade-SAS/OCCT/tree/bd2a789f15235755ce4d1a3b07379a2e062fdc2e",
        "engineering",
        "settings.licenses.note.occt_native",
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
        "pip-ambient-meditation",
        "FloeApp/Resources/Licenses/PiPAmbientMeditation-CC0.txt",
        "Licenses/PiPAmbientMeditation-CC0.txt",
        "settings.licenses.document.pip_meditation.title",
        "Meditation music — Yoiyami",
        None,
        "CC0-1.0",
        "notices",
        True,
        "media",
    ),
    (
        "pip-ambient-expansion",
        "FloeApp/Resources/Licenses/PiPAmbientExpansion-CC0.txt",
        "Licenses/PiPAmbientExpansion-CC0.txt",
        "settings.licenses.document.pip_ambient_expansion.title",
        "Additional meditation music — Yoiyami",
        None,
        "CC0-1.0",
        "notices",
        True,
        "media",
    ),
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
        "linux-boot-pair",
        "FloeApp/Resources/Licenses/LinuxBootPair-LICENSES.txt",
        "Licenses/LinuxBootPair-LICENSES.txt",
        "settings.licenses.document.linux_boot_pair.title",
        "Linux guest boot pair (kernel + firmware)",
        None,
        "GPL-2.0 (kernel), BSD-2-Clause (OpenSBI)",
        "full_text",
        True,
        "engines",
    ),
    (
        "office-engine-license",
        "FloeApp/Resources/Licenses/OfficeEngine/LICENSE",
        "Licenses/OfficeEngine/LICENSE",
        "settings.licenses.document.office_engine_license.title",
        "Collabora Online engine — licensing and legal information",
        None,
        "MPL-2.0 and bundled third-party licenses",
        "full_text",
        True,
        "office",
    ),
    (
        "office-engine-mpl",
        "FloeApp/Resources/Licenses/OfficeEngine/COPYING.MPL",
        "Licenses/OfficeEngine/COPYING.MPL",
        "settings.licenses.document.office_engine_mpl.title",
        "Collabora Online engine — Mozilla Public License 2.0",
        None,
        "MPL-2.0",
        "full_text",
        True,
        "office",
    ),
    (
        "office-engine-lgpl",
        "FloeApp/Resources/Licenses/OfficeEngine/COPYING.LGPL",
        "Licenses/OfficeEngine/COPYING.LGPL",
        "settings.licenses.document.office_engine_lgpl.title",
        "Collabora Online engine — GNU Lesser General Public License 3.0",
        None,
        "LGPL-3.0",
        "full_text",
        True,
        "office",
    ),
    (
        "office-engine-gpl",
        "FloeApp/Resources/Licenses/OfficeEngine/COPYING",
        "Licenses/OfficeEngine/COPYING",
        "settings.licenses.document.office_engine_gpl.title",
        "Collabora Online engine — GNU General Public License 3.0",
        None,
        "GPL-3.0",
        "full_text",
        True,
        "office",
    ),
    (
        "office-engine-source-notice",
        "FloeApp/Resources/Licenses/OfficeEngine/SOURCE-COPYING.txt",
        "Licenses/OfficeEngine/SOURCE-COPYING.txt",
        "settings.licenses.document.office_engine_source_notice.title",
        "Collabora Online engine — MPL source notice",
        None,
        "MPL-2.0",
        "notices",
        True,
        "office",
    ),
    (
        "office-engine-third-party",
        "FloeApp/Resources/Licenses/OfficeEngine/THIRDPARTYLICENSES",
        "Licenses/OfficeEngine/THIRDPARTYLICENSES",
        "settings.licenses.document.office_engine_third_party.title",
        "Collabora Online engine — third-party licenses",
        None,
        None,
        "notices",
        True,
        "office",
    ),
    (
        "office-engine-notice",
        "FloeApp/Resources/Licenses/OfficeEngine/NOTICE",
        "Licenses/OfficeEngine/NOTICE",
        "settings.licenses.document.office_engine_notice.title",
        "Collabora Online engine — NOTICE",
        None,
        None,
        "notices",
        True,
        "office",
    ),
    (
        "office-engine-source-offer",
        "FloeApp/Resources/Licenses/OfficeEngine-SOURCE-OFFER.txt",
        "Licenses/OfficeEngine-SOURCE-OFFER.txt",
        "settings.licenses.document.office_engine_source_offer.title",
        "Collabora Online engine source offer",
        None,
        "MPL-2.0",
        "full_text",
        True,
        "office",
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
        "occt-native",
        OCCT_NATIVE_NOTICE,
        "Licenses/OCCT-Native-SOURCE-OFFER.txt",
        "settings.licenses.document.occt_native.title",
        "OCCT 7.8.1 native static libraries (source offer)",
        None,
        "LGPL-2.1 with OCCT exception",
        "full_text",
        True,
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
    committed_pins = resolved_pins(committed)
    verified_pins = verify_resolution(
        resolved_pins(current),
        committed_pins,
        application_pins(PROJECT_YML.read_text()),
    )
    # SwiftPM may rewrite a GitHub URL with or without its optional .git
    # suffix on another host. verify_resolution has already established that
    # this is the same immutable pin. Emit the committed spelling so a cloud
    # checkout cannot spuriously change the recorded license source.
    committed_by_identity = {pin["identity"]: pin for pin in committed_pins}
    pins = [committed_by_identity.get(pin["identity"], pin) for pin in verified_pins]
    rows = []
    for pin in pins:
        state = pin["state"]
        # The revision is what the evidence binds to; the version is only the
        # display value. A pin that carries a semver still keeps its revision so
        # a changed revision can never reuse the license of another revision.
        revision = state.get("revision")
        if not revision:
            raise ValueError(f"resolved pin without an immutable revision: {pin['identity']}")
        rows.append(
            {
                "identity": pin["identity"],
                "location": pin["location"],
                "revision": revision,
                "version": state.get("version") or revision,
            }
        )
    return rows


def read_checkout_revision(identity: str, checkouts: Path | None = None) -> tuple[str, str | None]:
    """Probe ``.build/checkouts/<identity>`` without touching it.

    Returns ``("absent", None)`` when there is no checkout, ``("ok", revision)``
    when HEAD is a readable commit, and ``("unknown", detail)`` when a checkout
    exists but its revision cannot be established. Nothing is fetched, checked
    out or reset here.
    """
    if checkouts is None:
        checkouts = CHECKOUTS
    checkout = checkouts / identity
    if not checkout.exists():
        return "absent", None
    try:
        completed = subprocess.run(
            ["git", "-C", str(checkout), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
        )
    except OSError as error:  # git missing or unreadable directory
        return "unknown", str(error)
    revision = completed.stdout.strip()
    if completed.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", revision):
        detail = completed.stderr.strip() or f"unexpected git output {revision!r}"
        return "unknown", detail
    return "ok", revision


def detect_pin_license(
    identity: str, checkouts: Path | None = None
) -> tuple[str | None, str | None, str | None]:
    """Read the upstream license of a checkout whose revision was verified."""
    if checkouts is None:
        checkouts = CHECKOUTS
    checkout = checkouts / identity
    for name in LICENSE_FILE_CANDIDATES:
        path = checkout / name
        if path.is_file():
            return (
                classify_license(path.read_text(encoding="utf-8", errors="replace")),
                f".build/checkouts/{identity}/{name}",
                sha256_file(path),
            )
    return None, None, None


def detect_bundled_notice(
    identity: str, root: Path | None = None
) -> tuple[str | None, str | None, str | None]:
    """Read the repository-tracked notice of an Xcode app-only package."""
    if root is None:
        root = ROOT
    relative = APP_ONLY_NOTICES.get(identity)
    if relative is None:
        return None, None, None
    path = root / relative
    if not path.is_file():
        return None, None, None
    return (
        classify_license(path.read_text(encoding="utf-8", errors="replace")),
        relative,
        sha256_file(path),
    )


def load_evidence() -> dict[str, dict]:
    if not EVIDENCE.is_file():
        return {}
    document = json.loads(EVIDENCE.read_text())
    return {row["identity"]: row for row in document.get("licenses", [])}


def resolve_pins(
    pins: list[dict],
    recorded: dict[str, dict],
    problems: list[str],
    checkouts: Path | None = None,
    root: Path | None = None,
) -> tuple[list[dict], list[dict], dict[str, int]]:
    """Resolve licenses for pins and bind each evidence row to its exact pin.

    Evidence is accepted only from a checkout whose HEAD equals the declared
    revision, from a repository-tracked app-only notice, or from a recorded row
    whose revision and source still match. A stale or unreadable checkout is
    never read, and a changed pin revision without a verified checkout fails
    explicitly instead of reusing the license text of an older revision.
    """
    if checkouts is None:
        checkouts = CHECKOUTS
    if root is None:
        root = ROOT
    rows = []
    evidence = []
    stats = {"checkout": 0, "notice": 0, "recorded": 0, "unknown": 0}
    for pin in pins:
        identity = pin["identity"]
        revision = pin["revision"]
        source = pin["location"]
        previous = recorded.get(identity)
        bound = (
            previous is not None
            and previous.get("revision") == revision
            and previous.get("source") == source
            and bool(previous.get("sha256"))
        )
        # A row that actually recorded a revision/source and no longer matches
        # is a moved pin; a legacy identity-only row is not.
        moved = (
            previous is not None
            and bool(previous.get("revision"))
            and bool(previous.get("source"))
            and not bound
        )
        state, actual = read_checkout_revision(identity, checkouts)
        conflict = state == "unknown" or (state == "ok" and actual != revision)
        if state == "ok" and actual != revision:
            problems.append(
                f"{identity}: checkout HEAD {actual} does not match the declared pin "
                f"revision {revision}; refusing to read its license (resolve the "
                "dependency; the generator never resets a checkout)"
            )
        elif state == "unknown":
            problems.append(
                f"{identity}: a checkout exists but its revision could not be read "
                f"({actual}); refusing to accept an unverified revision"
            )

        license_name = evidence_path = digest = None
        origin = None
        if not conflict:
            # An app-only package may also exist as an Xcode SourcePackages
            # checkout (WhisperKit). The tracked notice is the reviewable,
            # shipped spelling that --check compares against, so a
            # same-revision build-cache checkout must not rewrite the
            # recorded evidence path to ".build/checkouts/...".
            if identity not in APP_ONLY_NOTICES and state == "ok":
                license_name, evidence_path, digest = detect_pin_license(identity, checkouts)
                if license_name is not None:
                    origin = "checkout"
            if license_name is None:
                license_name, evidence_path, digest = detect_bundled_notice(identity, root)
                if license_name is not None:
                    origin = "notice"

        if license_name is None:
            if bound:
                license_name = previous["license"]
                evidence_path = previous["evidence"]
                digest = previous["sha256"]
                origin = "recorded"
                if state == "absent":
                    print(
                        f"note: checkout unavailable for {identity}; reusing evidence "
                        f"recorded for revision {revision}",
                        file=sys.stderr,
                    )
                elif state == "ok" and not conflict:
                    # The checkout is at the declared revision but carries no
                    # classifiable license file; a mismatching checkout was
                    # already reported above and is not "verified".
                    problems.append(
                        f"{identity}: no classifiable license file in the verified checkout "
                        f"at {revision}; reusing the recorded digest, review the checkout"
                    )
                if evidence_path and not evidence_path.startswith(CHECKOUT_EVIDENCE_PREFIX):
                    recorded_file = root / evidence_path
                    if not recorded_file.is_file():
                        problems.append(
                            f"{identity}: recorded evidence file is missing: {evidence_path}"
                        )
                    elif sha256_file(recorded_file) != digest:
                        problems.append(
                            f"{identity}: recorded evidence file changed since it was "
                            f"recorded: {evidence_path}"
                        )
            else:
                if previous is None:
                    problems.append(
                        f"{identity}: license undetected and no recorded evidence; "
                        "manual review required"
                    )
                else:
                    problems.append(
                        f"{identity}: cannot verify revision {revision} / {source}: recorded "
                        f"evidence is bound to {previous.get('revision') or 'no revision'} / "
                        f"{previous.get('source') or 'no source'} and no verified checkout or "
                        "repository notice is available; resolve the dependency, then regenerate"
                    )
                license_name = "UNKNOWN"
                origin = "unknown"
        elif origin in ("checkout", "notice"):
            if bound:
                if previous["sha256"] != digest:
                    problems.append(
                        f"{identity}: upstream license changed since the recorded evidence "
                        f"({previous['evidence']} {previous['sha256'][:12]} -> "
                        f"{evidence_path} {digest[:12]}); review before regenerating"
                    )
            elif moved and origin == "notice":
                problems.append(
                    f"{identity}: pin moved to revision {revision} / {source} while only the "
                    f"repository notice {evidence_path} is available; verify it matches the "
                    "new revision, then regenerate"
                )
            else:
                print(
                    f"note: recording license evidence for {identity}: "
                    f"{license_name} from {evidence_path}",
                    file=sys.stderr,
                )

        stats[origin or "unknown"] += 1
        evidence.append(
            {
                "identity": identity,
                "license": license_name,
                "evidence": evidence_path,
                "sha256": digest,
                "revision": revision,
                "source": source,
            }
        )
        rows.append({"pin": pin, "license": license_name, "evidence": evidence_path})
    return rows, evidence, stats


def resolve_vendored_packages(
    pins: list[dict],
    problems: list[str],
    root: Path | None = None,
) -> dict:
    """Declare repository-vendored packages that replaced a resolved remote pin.

    A spec is active only while the lock no longer declares its identity, so the
    generator produces identical artifacts before and after the switch: with the
    pin present the resolved checkout stays the single declaration, and after the
    pin is removed the vendored copy is declared instead. The vendored LICENSE is
    repository-tracked, so its text and sha256 are read on every run rather than
    reused from the recorded evidence file.
    """
    if root is None:
        root = ROOT
    declared = {pin["identity"] for pin in pins}
    result: dict = {
        "components": [],
        "documents": [],
        "evidence": [],
        "copies": {},
        "notes": [],
    }
    for spec in VENDORED_PACKAGES:
        identity = spec["identity"]
        if identity in declared:
            continue
        relative = f"{spec['path']}/{VENDORED_LICENSE_NAME}"
        license_path = root / spec["path"] / VENDORED_LICENSE_NAME
        if not license_path.is_file():
            problems.append(
                f"{identity}: the lock no longer declares this pin and the vendored "
                f"copy {spec['path']} has no {VENDORED_LICENSE_NAME}; restore the "
                "vendored package (or the pin) before regenerating"
            )
            continue
        license_bytes = license_path.read_bytes()
        license_name = classify_license(license_bytes.decode("utf-8", errors="replace"))
        if license_name != spec["license"]:
            problems.append(
                f"{identity}: vendored license {relative} reads as "
                f"{license_name or 'UNKNOWN'}, expected {spec['license']}"
            )
        note_id, note_text = spec["note"]
        note_key = f"settings.licenses.note.{note_id}"
        document = spec["document"]
        if document["repositoryPath"] in result["copies"]:
            raise ValueError(f"duplicate vendored document path: {document['repositoryPath']}")
        result["copies"][document["repositoryPath"]] = license_bytes
        result["components"].append(
            {
                "name": identity,
                "version": spec["revision"],
                "license": license_name or spec["license"],
                "source": f"{spec['upstream'].removesuffix('.git')}/tree/{spec['revision']}",
                "section": "swift",
                "noteKey": note_key,
                "evidence": relative,
            }
        )
        result["documents"].append(
            {
                "id": document["id"],
                "repositoryPath": document["repositoryPath"],
                "bundlePath": document["bundlePath"],
                "titleKey": document["titleKey"],
                "titleFallback": document["titleFallback"],
                "titleArgument": None,
                "license": license_name or spec["license"],
                "kindKey": KINDS[document["kind"]],
                "required": document["required"],
                "section": document["section"],
                "noteKey": note_key,
            }
        )
        result["evidence"].append(
            {
                "identity": identity,
                "license": license_name or spec["license"],
                "evidence": relative,
                "sha256": sha256_file(license_path),
                "revision": spec["revision"],
                "source": spec["upstream"],
            }
        )
        result["notes"].append((note_id, note_text))
    return result


def resolve_cad_packages(
    problems: list[str], checkouts: Path | None = None, root: Path | None = None
) -> dict:
    """Declare the linked FloeCAD Swift packages from the CAD package lock.

    ``ThirdParty/FloeCADKit/Package.resolved`` is the single pin authority. Only
    the packages actually linked into FloeCAD/the app are declared; every
    reviewed row must still match the lock identity, revision and license text,
    and the complete upstream license is a reviewed tracked copy that is
    re-read on every run. When a checkout of the same revision is present, its
    license file is verified against that copy — a copy that no longer matches
    the pinned revision fails instead of being recorded silently. The evidence
    path stays the tracked copy, so a build-cache checkout can never rewrite
    the shipped spelling.
    """
    if checkouts is None:
        checkouts = CHECKOUTS
    if root is None:
        root = ROOT
    result: dict = {
        "components": [],
        "documents": [],
        "evidence": [],
        "stats": {"checkout": 0, "copy": 0},
    }
    lock_path = root / "ThirdParty/FloeCADKit/Package.resolved"
    manifest_path = root / "ThirdParty/FloeCADKit/Package.swift"
    if not lock_path.is_file():
        problems.append(
            "the FloeCADKit package lock is missing: ThirdParty/FloeCADKit/Package.resolved; "
            "restore it before generating (the CAD dependencies cannot be declared)"
        )
        return result
    try:
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
        pins = resolved_pins(lock)
    except (ValueError, json.JSONDecodeError) as error:
        problems.append(
            "the FloeCADKit package lock cannot be read: "
            f"ThirdParty/FloeCADKit/Package.resolved: {error}"
        )
        return result
    if manifest_path.is_file() and lock.get("originHash"):
        manifest_digest = sha256_file(manifest_path)
        if manifest_digest != lock["originHash"]:
            problems.append(
                "the FloeCADKit package lock is stale relative to "
                "ThirdParty/FloeCADKit/Package.swift (originHash "
                f"{lock['originHash'][:12]} != manifest {manifest_digest[:12]}); resolve the "
                "package, then regenerate this inventory"
            )
    by_identity = {pin["identity"]: pin for pin in pins}
    reviewed = {spec["identity"] for spec in CAD_LINKED_PACKAGES}
    for identity in sorted(set(by_identity) - reviewed - set(CAD_BUILD_ONLY_PACKAGES)):
        problems.append(
            f"{identity}: the FloeCADKit package lock declares an unreviewed identity; decide "
            "whether it is linked into the app and declare it (or record it as build-only) "
            "before regenerating"
        )
    for spec in CAD_LINKED_PACKAGES:
        identity = spec["identity"]
        pin = by_identity.get(identity)
        if pin is None:
            problems.append(
                f"{identity}: no longer declared by ThirdParty/FloeCADKit/Package.resolved; "
                "restore the pin or update the reviewed CAD table before regenerating"
            )
            continue
        revision = pin["state"].get("revision")
        source = pin["location"]
        if revision != spec["revision"]:
            problems.append(
                f"{identity}: the FloeCADKit pin moved to {revision or 'no revision'} / {source} "
                f"(reviewed {spec['revision']}); review the new revision's license text, update "
                "the reviewed CAD row and the tracked copy, then regenerate"
            )
            continue
        notice_path = root / spec["notice"]
        if not notice_path.is_file():
            problems.append(
                f"{identity}: the reviewed license copy is missing: {spec['notice']}; "
                "restore the complete upstream license text before regenerating"
            )
            continue
        license_name = classify_license(notice_path.read_text(encoding="utf-8", errors="replace"))
        digest = sha256_file(notice_path)
        if digest != spec["sha256"]:
            problems.append(
                f"{identity}: the reviewed license copy {spec['notice']} changed "
                f"({spec['sha256'][:12]} -> {digest[:12]}); review it against the pinned "
                "revision before regenerating"
            )
        if license_name != spec["license"]:
            problems.append(
                f"{identity}: the reviewed license copy {spec['notice']} reads as "
                f"{license_name or 'UNKNOWN'}, expected {spec['license']}"
            )
        state, actual = read_checkout_revision(identity, checkouts)
        verified_checkout = False
        if state == "unknown":
            problems.append(
                f"{identity}: a CAD checkout exists but its revision could not be read "
                f"({actual}); refusing to accept an unverified revision"
            )
        elif state == "ok" and actual != revision:
            problems.append(
                f"{identity}: checkout HEAD {actual} does not match the declared CAD pin "
                f"revision {revision}; refusing to read its license (resolve the dependency; "
                "the generator never resets a checkout)"
            )
        elif state == "ok":
            checkout_license = detect_pin_license(identity, checkouts)
            if checkout_license[2] is None:
                problems.append(
                    f"{identity}: the verified checkout at {revision} has no classifiable "
                    "license file; review the checkout before regenerating"
                )
            elif checkout_license[2] != digest:
                problems.append(
                    f"{identity}: the reviewed copy {spec['notice']} does not match the license "
                    f"file in the verified checkout at {revision} "
                    f"({digest[:12]} != {checkout_license[2][:12]}); refresh the copy from the "
                    "pinned revision"
                )
            else:
                verified_checkout = True
        result["stats"]["checkout" if verified_checkout else "copy"] += 1
        result["components"].append(
            {
                "name": identity,
                "version": spec["version"],
                "license": license_name or spec["license"],
                "source": source,
                "section": "swift",
                "noteKey": CAD_NOTE_KEY,
                "evidence": spec["notice"],
            }
        )
        result["documents"].append(
            {
                "id": identity,
                "repositoryPath": spec["notice"],
                "bundlePath": "Licenses/" + spec["notice"].rsplit("/", 1)[-1],
                "titleKey": f"settings.licenses.document.{identity}.title",
                "titleFallback": spec["title"],
                "titleArgument": None,
                "license": license_name or spec["license"],
                "kindKey": KINDS["full_text"],
                "required": True,
                "section": "swift",
                "noteKey": None,
            }
        )
        result["evidence"].append(
            {
                "identity": identity,
                "license": license_name or spec["license"],
                "evidence": spec["notice"],
                "sha256": digest,
                "revision": revision,
                "source": source,
            }
        )
    return result


def resolve_openshape_attribution(problems: list[str], root: Path | None = None) -> dict:
    """Declare FloeCADKit's OpenShape3D-derived MIT code.

    OpenShape3D is not a resolved Swift package — ``ThirdParty/FloeCADKit`` is
    the modified extraction — so the reviewed row is bound to the recorded
    source in ``ThirdParty/FloeCADKit/DEPENDENCIES.json`` instead of a lock pin.
    The complete upstream MIT notice is tracked under ``ThirdParty/FloeCADKit``
    and byte-identical bytes ship in the app as ``OPENSHAPE_COMPONENT['notice']``;
    both copies are re-read on every run, and a moved recorded commit or source,
    an edited copy, a different license text or a bundled copy that no longer
    matches the linked package's copy fails instead of being recorded silently.
    """
    if root is None:
        root = ROOT
    spec = OPENSHAPE_COMPONENT
    result: dict = {"components": [], "documents": [], "evidence": []}
    dependencies_path = root / spec["dependencies"]
    if not dependencies_path.is_file():
        problems.append(
            "the OpenShape3D source record is missing: "
            f"{spec['dependencies']}; restore it before regenerating"
        )
        return result
    try:
        dependencies = json.loads(dependencies_path.read_text(encoding="utf-8"))
        source = dependencies["sources"][spec["identity"]]
    except (ValueError, KeyError, TypeError) as error:
        problems.append(
            "the OpenShape3D source record cannot be read: "
            f"{spec['dependencies']}: {error}"
        )
        return result
    for label, recorded, reviewed in (
        ("commit", source.get("commit"), spec["revision"]),
        ("repositoryClone", source.get("repositoryClone"), spec["upstream"]),
        ("repositoryWeb", source.get("repositoryWeb"), spec["repositoryWeb"]),
    ):
        if recorded != reviewed:
            problems.append(
                f"openshape3d: the recorded source {label} moved to {recorded!r} "
                f"(reviewed {reviewed!r}); review the new source and its license "
                "text, update the reviewed row and the tracked copies, then "
                "regenerate"
            )
    package_copy = root / spec["packageCopy"]
    if not package_copy.is_file():
        problems.append(
            "openshape3d: the tracked upstream MIT notice is missing: "
            f"{spec['packageCopy']}; restore the linked package's license copy "
            "before regenerating"
        )
        return result
    license_name = classify_license(package_copy.read_text(encoding="utf-8", errors="replace"))
    package_digest = sha256_file(package_copy)
    if package_digest != spec["sha256"]:
        problems.append(
            f"openshape3d: the tracked MIT notice {spec['packageCopy']} changed "
            f"({spec['sha256'][:12]} -> {package_digest[:12]}); review it "
            "against the recorded upstream commit before regenerating"
        )
    if license_name != spec["license"]:
        problems.append(
            f"openshape3d: the tracked MIT notice {spec['packageCopy']} reads as "
            f"{license_name or 'UNKNOWN'}, expected {spec['license']}"
        )
    notice_path = root / spec["notice"]
    if not notice_path.is_file():
        problems.append(
            f"openshape3d: the bundled MIT notice is missing: {spec['notice']}; "
            f"copy the complete upstream text from {spec['packageCopy']} before "
            "regenerating"
        )
        return result
    digest = sha256_file(notice_path)
    if digest != package_digest:
        problems.append(
            f"openshape3d: the bundled notice {spec['notice']} no longer matches "
            f"the linked package's copy {spec['packageCopy']}; refresh it from the "
            "recorded upstream commit"
        )
    result["components"].append(
        {
            "name": spec["identity"],
            "version": spec["revision"],
            "license": license_name or spec["license"],
            "source": f"{spec['repositoryWeb']}/tree/{spec['revision']}",
            "section": "swift",
            "noteKey": OPENSHAPE_NOTE_KEY,
            "evidence": spec["notice"],
        }
    )
    result["documents"].append(
        {
            "id": spec["identity"],
            "repositoryPath": spec["notice"],
            "bundlePath": "Licenses/" + spec["notice"].rsplit("/", 1)[-1],
            "titleKey": f"settings.licenses.document.{spec['identity']}.title",
            "titleFallback": spec["title"],
            "titleArgument": None,
            "license": license_name or spec["license"],
            "kindKey": KINDS["full_text"],
            "required": True,
            "section": "swift",
            "noteKey": None,
        }
    )
    result["evidence"].append(
        {
            "identity": spec["identity"],
            "license": license_name or spec["license"],
            "evidence": spec["notice"],
            "sha256": digest,
            "revision": spec["revision"],
            "source": spec["upstream"],
        }
    )
    return result


def occt_native_problems(problems: list[str], root: Path | None = None) -> None:
    """Verify the bundled native-OCCT record against the pinned artifacts.

    The notice that ships in the app must carry the exact OCCT commit, tag,
    source route, slice SHA-256 values and retained build-input hashes read from
    ``ThirdParty/FloeCADKit/DEPENDENCIES.json``; the retained relink files and
    the package license/exception texts must still match that pin, including the
    byte-identical app-bundled copies. Facts are re-read here, never guessed
    from the notice text.
    """
    if root is None:
        root = ROOT
    package = root / "ThirdParty/FloeCADKit"
    dependencies_path = package / "DEPENDENCIES.json"
    notice_path = root / OCCT_NATIVE_NOTICE
    if not dependencies_path.is_file():
        problems.append(
            "the OCCT artifact pins are missing: ThirdParty/FloeCADKit/DEPENDENCIES.json; "
            "restore the pinned slice/relink record before regenerating"
        )
        return
    try:
        dependencies = json.loads(dependencies_path.read_text(encoding="utf-8"))
        relink = dependencies["relink"]
        occt = relink["occt"]
    except (ValueError, KeyError, TypeError) as error:
        problems.append(
            "the OCCT artifact pins cannot be read: "
            f"ThirdParty/FloeCADKit/DEPENDENCIES.json: {error}"
        )
        return
    facts = [
        ("OCCT commit", occt.get("commit")),
        ("OCCT tag", occt.get("tag")),
        ("OCCT source archive", occt.get("sourceArchive")),
        ("relink record", "ThirdParty/FloeCADKit/OCCT_RELINK.md"),
        ("relink procedure", "relink/README.md"),
        ("source offer", "relink/SOURCE_OFFER.md"),
    ]
    for relative in ("OCCT_RELINK.md", "relink/README.md", "relink/SOURCE_OFFER.md"):
        if not (package / relative).is_file():
            problems.append(f"the OCCT relink record is missing: ThirdParty/FloeCADKit/{relative}")
    if not notice_path.is_file():
        problems.append(
            f"the bundled OCCT source offer is missing: {OCCT_NATIVE_NOTICE}; "
            "restore the complete record before regenerating"
        )
    else:
        notice = notice_path.read_text(encoding="utf-8")
        for artifact in dependencies.get("artifacts", ()):
            facts.append((f"slice {artifact.get('name')} SHA-256", artifact.get("sha256")))
        for label, value in facts:
            if not value:
                problems.append(
                    f"the OCCT pin record is incomplete ({label}): "
                    "ThirdParty/FloeCADKit/DEPENDENCIES.json"
                )
            elif value not in notice:
                problems.append(
                    f"the bundled OCCT source offer does not record the pinned {label} "
                    f"({value[:16]}...); update {OCCT_NATIVE_NOTICE}"
                )
    for key, hash_field in (("buildProgram", "sha256"), ("toolchain", "fileSha256")):
        entry = relink.get(key) or {}
        relative = entry.get("retainedCopy")
        expected = entry.get(hash_field)
        if not relative or not expected:
            problems.append(
                f"the OCCT pin record is incomplete (relink.{key}.{hash_field}/retainedCopy): "
                "ThirdParty/FloeCADKit/DEPENDENCIES.json"
            )
            continue
        retained = package / relative
        if not retained.is_file():
            problems.append(f"the retained OCCT relink input is missing: ThirdParty/FloeCADKit/{relative}")
        elif sha256_file(retained) != expected:
            problems.append(
                f"the retained OCCT relink input changed: ThirdParty/FloeCADKit/{relative} "
                f"({sha256_file(retained)[:12]} != {expected[:12]})"
            )
        if notice_path.is_file() and expected not in notice_path.read_text(encoding="utf-8"):
            problems.append(
                f"the bundled OCCT source offer does not record the pinned {key} SHA-256 "
                f"({expected[:16]}...); update {OCCT_NATIVE_NOTICE}"
            )
    for relative, bundled in (
        ("license.occt.txt", "FloeApp/Resources/EngineeringViewers/license.occt.txt"),
        (
            "OCCT_LGPL_EXCEPTION.txt",
            "FloeApp/Resources/EngineeringViewers/OCCT_LGPL_EXCEPTION.txt",
        ),
    ):
        package_copy = package / relative
        bundled_copy = root / bundled
        if not package_copy.is_file():
            problems.append(f"the OCCT license text is missing: ThirdParty/FloeCADKit/{relative}")
        elif not bundled_copy.is_file():
            problems.append(f"the bundled OCCT license text is missing: {bundled}")
        elif sha256_file(package_copy) != sha256_file(bundled_copy):
            problems.append(
                f"the bundled OCCT license text {bundled} no longer matches the linked "
                f"library's copy ThirdParty/FloeCADKit/{relative}"
            )


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
    "Linux guest boot kernel (bundled 6.18.56 Image)": "ThirdParty/TinyEMU/guest-image/BOOT-PAIR-LICENSES.md and config_linux_riscv64_6.18.56; full GPL-2.0 text in FloeApp/Resources/Licenses/LinuxBootPair-LICENSES.txt",
    "Linux guest boot firmware (bundled OpenSBI v1.9 fw_jump)": "ThirdParty/TinyEMU/guest-image/BOOT-PAIR-LICENSES.md; OpenSBI COPYING.BSD text in FloeApp/Resources/Licenses/LinuxBootPair-LICENSES.txt",
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
    "Collabora Online native Office engine (LibreOffice-based)": "ThirdParty/Collabora/engine.lock.json pin; upstream LICENSE and COPYING.MPL at the pinned commit (MPL-2.0); legal files copied under FloeApp/Resources/Licenses/OfficeEngine",
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
    OCCT_NATIVE_NAME: (
        "ThirdParty/FloeCADKit/DEPENDENCIES.json (pinned slices), OCCT_RELINK.md and "
        "relink/SOURCE_OFFER.md; bundled record " + OCCT_NATIVE_NOTICE
    ),
    "Open CASCADE Technology (OCCT)": "FloeApp/Resources/EngineeringViewers/license.occt.txt",
    "occt-import-js": "FloeApp/Resources/EngineeringViewers/license.occt-import-js.txt",
    "ZLImageEditor": "FloeApp/Resources/ZLImageEditor-LICENSE.txt",
    "FloeDocumentSans (modified Noto Sans SC)": "FloeApp/Resources/DocumentConversion/FONT-LICENSE.txt",
}


def build_components(
    pin_rows: list[dict],
    font_families: list[dict],
    npm_packages: list[dict],
    vendored_components: list[dict] | None = None,
    cad_components: list[dict] | None = None,
):
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
    # A vendored package took over a formerly resolved pin; it keeps the Swift
    # package section so the dependency stays in its original inventory place.
    components.extend(vendored_components or [])
    # The linked FloeCAD packages come from the FloeCADKit lock instead of the
    # host lock; they stay Swift package rows under the same section.
    components.extend(cad_components or [])
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


def build_manifest(components, documents, extra_notes=()):
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
            for note_id, text in tuple(NOTES) + tuple(extra_notes)
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
        "Regenerate with FloeAgent/scripts/license_inventory.sh after changing a "
        "declared pin. `--check` is read-only and fails on a stale manifest or on "
        "evidence that is no longer bound to the exact pin revision and source; it "
        "never checks out or resets a dependency.",
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


def validate(
    pins,
    manifest,
    evidence_document,
    libgit2_bytes,
    problems,
    warnings,
    vendored=None,
    cad=None,
    openshape=None,
):
    vendored = vendored or {}
    cad = cad or {}
    openshape = openshape or {}
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
    generated_copies = set(vendored.get("copies", {}))
    for document in manifest["documents"]:
        if (
            document["required"]
            and not (ROOT / document["repositoryPath"]).is_file()
            and document["repositoryPath"] not in generated_copies
        ):
            warnings.append(f"required notice is not staged in this checkout: {document['repositoryPath']}")
    # Every recorded evidence row must stay bound to the exact declared pin, so
    # a later pin edit can never silently inherit another revision's license.
    evidence_by_identity = {row["identity"]: row for row in evidence_document["licenses"]}
    for pin in pins:
        row = evidence_by_identity.get(pin["identity"])
        if row is None:
            problems.append(f"missing license evidence row: {pin['identity']}")
            continue
        if row.get("revision") != pin["revision"] or row.get("source") != pin["location"]:
            problems.append(
                f"{pin['identity']}: evidence is not bound to the declared pin "
                f"({row.get('revision')} / {row.get('source')} != "
                f"{pin['revision']} / {pin['location']})"
            )
    # A vendored package is bound to its declared upstream revision and
    # repository copy instead of a lock pin. The LICENSE text is tracked, so the
    # freshly generated row always reflects the current file and --check catches
    # a changed copy or a stale recorded evidence path as drift.
    for row in vendored.get("evidence", ()):
        identity = row["identity"]
        recorded_row = evidence_by_identity.get(identity)
        if recorded_row is None:
            problems.append(f"missing license evidence row: {identity} (vendored package)")
            continue
        for field in ("license", "evidence", "sha256", "revision", "source"):
            if recorded_row.get(field) != row[field]:
                problems.append(
                    f"{identity}: vendored evidence is not bound to "
                    f"{row['evidence']} at {row['revision']} "
                    f"({field}: {recorded_row.get(field)!r} != {row[field]!r})"
                )
    # The linked FloeCAD packages are declared from the FloeCADKit lock instead
    # of a host pin; their evidence rows bind the tracked reviewed license copy
    # to the exact lock revision and source the same way.
    for row in cad.get("evidence", ()):
        identity = row["identity"]
        recorded_row = evidence_by_identity.get(identity)
        if recorded_row is None:
            problems.append(f"missing license evidence row: {identity} (FloeCADKit package)")
            continue
        for field in ("license", "evidence", "sha256", "revision", "source"):
            if recorded_row.get(field) != row[field]:
                problems.append(
                    f"{identity}: FloeCADKit evidence is not bound to "
                    f"{row['evidence']} at {row['revision']} "
                    f"({field}: {recorded_row.get(field)!r} != {row[field]!r})"
                )
    # FloeCADKit's OpenShape3D-derived code is bound to its recorded source
    # record and the tracked/bundled MIT copies instead of a lock pin.
    for row in openshape.get("evidence", ()):
        identity = row["identity"]
        recorded_row = evidence_by_identity.get(identity)
        if recorded_row is None:
            problems.append(f"missing license evidence row: {identity} (OpenShape3D attribution)")
            continue
        for field in ("license", "evidence", "sha256", "revision", "source"):
            if recorded_row.get(field) != row[field]:
                problems.append(
                    f"{identity}: OpenShape3D evidence is not bound to "
                    f"{row['evidence']} at {row['revision']} "
                    f"({field}: {recorded_row.get(field)!r} != {row[field]!r})"
                )
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
    pin_rows, evidence_rows, stats = resolve_pins(pins, recorded, problems)
    vendored = resolve_vendored_packages(pins, problems)
    cad = resolve_cad_packages(problems)
    openshape = resolve_openshape_attribution(problems)
    occt_native_problems(problems)
    font_families = json.loads(FONTS_MANIFEST.read_text())["families"]
    npm_packages = json.loads(CONVERSION_INVENTORY.read_text())["packages"]
    components = build_components(
        pin_rows,
        font_families,
        npm_packages,
        vendored["components"],
        cad["components"] + openshape["components"],
    )
    documents = (
        build_documents(font_families)
        + vendored["documents"]
        + cad["documents"]
        + openshape["documents"]
    )
    manifest = build_manifest(components, documents, vendored["notes"])
    evidence_document = {
        "schemaVersion": 2,
        "generatedBy": "scripts/license_inventory.sh",
        "note": (
            "Recorded license detection evidence for the resolved Swift packages. "
            "revision+source bind each row to the exact declared pin; sha256 binds "
            "the exact upstream license file the license was read from. A missing "
            "checkout may only reuse a row whose revision and source still match, "
            "and --check never checks out or resets a dependency."
        ),
        "licenses": sorted(
            evidence_rows + vendored["evidence"] + cad["evidence"] + openshape["evidence"],
            key=lambda row: row["identity"],
        ),
    }
    libgit2_bytes = None
    source = ROOT / LIBGIT2_EVIDENCE
    if source.is_file():
        libgit2_bytes = source.read_bytes()
    validate(
        pins,
        manifest,
        evidence_document,
        libgit2_bytes,
        problems,
        warnings,
        vendored,
        cad,
        openshape,
    )
    return {
        "manifest": manifest,
        "evidence": evidence_document,
        "stats": stats,
        "markdown": render_markdown(manifest),
        "manifest_text": render_json(manifest),
        "evidence_text": render_json(evidence_document),
        "libgit2_bytes": libgit2_bytes,
        "vendored_copies": vendored["copies"],
        "cad_stats": cad["stats"],
        "openshape_components": len(openshape["components"]),
        "problems": problems,
        "warnings": warnings,
    }


def vendored_copy_drift(copies: dict[str, bytes], root: Path) -> list[tuple[Path, str]]:
    """Report generated notice copies that are missing or stale under ``root``."""
    drift = []
    for repository_path, expected in copies.items():
        target = root / repository_path
        if not target.is_file():
            drift.append((target, "missing generated artifact"))
        elif target.read_bytes() != expected:
            drift.append((target, "committed artifact differs from the generator"))
    return drift


def report_drift(path: Path) -> int:
    print(f"drift: {path.relative_to(REPO)}", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Generate or check the third-party declaration")
    parser.add_argument(
        "--check",
        action="store_true",
        help=(
            "read-only: verify committed artifacts, revision-bound evidence, bundle "
            "mapping and localization; never writes or checks out anything"
        ),
    )
    args = parser.parse_args(argv)

    result = build()
    problems = result["problems"]
    warnings = result["warnings"]
    manifest_text = result["manifest_text"]
    evidence_text = result["evidence_text"]
    markdown = result["markdown"]
    libgit2_bytes = result["libgit2_bytes"]
    vendored_copies = result["vendored_copies"]

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
        for target, message in vendored_copy_drift(vendored_copies, ROOT):
            problems.append(f"{message}: {target.relative_to(REPO)}")
            report_drift(target)
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
        for repository_path, expected in vendored_copies.items():
            target = ROOT / repository_path
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.is_file() or target.read_bytes() != expected:
                target.write_bytes(expected)
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
    stats = result["stats"]
    binding = (
        f"{stats['checkout']} verified checkouts, {stats['notice']} repository notices, "
        f"{stats['recorded']} recorded reuse, {stats['unknown']} unknown"
    )
    if vendored_copies:
        binding += f", {len(vendored_copies)} vendored package notices"
    cad_stats = result.get("cad_stats")
    if cad_stats:
        binding += (
            f", {cad_stats['checkout']} verified FloeCAD checkouts, "
            f"{cad_stats['copy']} reviewed FloeCAD copies"
        )
    if result.get("openshape_components"):
        binding += f", {result['openshape_components']} bundled OpenShape3D notice"
    if args.check:
        print(
            "license_inventory --check OK: "
            f"{counts['components']} components, {counts['documents']} bundled notices, "
            f"{counts['pins']} Swift package rows ({binding})"
        )
    else:
        print(
            f"license_inventory OK: {counts['components']} dependencies inventoried "
            f"({binding})"
        )
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
